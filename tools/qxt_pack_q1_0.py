#!/data/data/com.termux/files/usr/bin/python3
"""qxt_pack_q1_0.py — 一步到位: Q8_0 源 -> Q1T 码 -> 官方 Q1_0 容器 (224MB).

Q1T (b=1 lloyd 双值) 每 32 元素块 = { scale_table[sc]; 32x1bit code } = 5B.
官方 Q1_0 容器每 32 元素块 = { half d; 32bit 位图 } = 6B.
两者同构: 写 d = scale_table[sc], 位图 = code, 即 Q1T 内容直接落进官方 Q1_0,
不经大壳中转, 不经 llama-quantize requantize. 就是老版 224MB 构建路径.

非 q8_0 权重张量 (f32 等) 及 token_embd 原样复制.
"""
import sys, os, time, struct
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mxfp4_regress as M
import qxt_fidelity_scan as Q
import qxt_pack_q1t as P

SRC = "/data/data/com.termux/files/home/models/rStar-Coder-Qwen3-0.6B.Q8_0.gguf"

QK = 32
BLOCK_BYTES_Q1_0 = 6  # half d (2B) + 4B 位图


def write_gguf_header(f, kv, tensor_count):
    f.write(b"GGUF")
    f.write(struct.pack("<I", 3))
    f.write(struct.pack("<Q", tensor_count))
    f.write(struct.pack("<Q", len(kv)))
    for k, v in kv.items():
        kb = k.encode("utf-8")
        f.write(struct.pack("<Q", len(kb)))
        f.write(kb)
        tag = type_to_tag(v)
        f.write(struct.pack("<I", tag))
        write_tagged(f, v)


def type_to_tag(v):
    if isinstance(v, bool):
        return 0
    if isinstance(v, np.integer) or isinstance(v, int):
        return 4 if -2147483648 <= v <= 2147483647 else 5
    if isinstance(v, np.floating) or isinstance(v, float):
        return 7
    if isinstance(v, np.ndarray):
        if v.dtype.kind in "iu":
            return 3 if str(v.dtype) == "int64" else 0 if str(v.dtype) in ("bool",) or v.dtype.kind == "b" else 2
        if v.dtype.kind == "f":
            return 3 if str(v.dtype) == "float64" else 7 if str(v.dtype) == "float32" else 1 if str(v.dtype) == "float16" else 2
    if isinstance(v, str):
        return 6
    if isinstance(v, (list, tuple)):
        return 9
    return 5


def write_tagged(f, v):
    if isinstance(v, bool):
        f.write(struct.pack("<B", int(v)))
    elif isinstance(v, np.integer) or isinstance(v, int):
        f.write(struct.pack("<q", int(v)))
    elif isinstance(v, np.floating) or isinstance(v, float):
        f.write(struct.pack("<f", float(v)))
    elif isinstance(v, np.ndarray):
        if v.dtype == bool or v.dtype.kind == "b":
            f.write(v.astype(np.int8).tobytes())
        elif v.dtype.kind in "iu":
            f.write(v.astype(np.int8 if v.dtype == bool else np.int32 if v.dtype.itemsize <= 4 else np.int64).tobytes())
        elif v.dtype.kind == "f":
            f.write(v.astype(np.float32).tobytes())
    elif isinstance(v, str):
        sb = v.encode("utf-8")
        f.write(struct.pack("<Q", len(sb)))
        f.write(sb)
    elif isinstance(v, (list, tuple)):
        f.write(struct.pack("<Q", len(v)))
        for x in v:
            write_tagged(f, x)


def main():
    b = int(sys.argv[1]) if len(sys.argv) > 1 else 1
    src = sys.argv[2] if len(sys.argv) > 2 else SRC
    base = os.path.splitext(os.path.basename(src))[0]
    dst = f"/data/data/com.termux/files/home/models/qxt/{base}-Q1T_as_Q1_0_rebuild.gguf"

    kv, infos, ds = M.read_gguf(src)

    cb, nsamp = P.train_cb(src, b)
    print(f"codebook (b={b}) = {cb.round(5)}", flush=True)

    # 写 header + tensor 信息, 再写数据区
    t0 = time.time()
    # GGUF: header + tensor meta 先写, 数据区紧随其后
    # 但 tensor meta 含 offset, 需先占位再回填 -> 用两阶段写文件不太可行.
    # 改为: 直接构造, tensor info offset = 累计数据偏移 (相对数据区起点),
    # 数据区紧接 meta 之后, 对齐 32B 后开始.
    with open(dst, "wb") as f:
        # 占位 header (后面回填)
        f.write(b"\0" * 0)
        # 我们先算 tensor meta: 每个张量的类型与字节数
        # 再写 header + meta, 然后数据区.
        # 为简化, 用临时缓冲记录数据, 或先写 header 后 meta 后数据.
        pass

    # 用一次性内存镜像方式: 构造整个文件字节
    # 先准备 tensor infos (name, dims, new_type, data_bytes)
    entries = []
    for t in infos:
        nb = int(np.prod(t.dims))
        if t.type == M.GGML_TYPE_Q8_0 and len(t.dims) >= 2 and t.name != "token_embd.weight":
            nb_blocks = nb // QK
            data_bytes = nb_blocks * BLOCK_BYTES_Q1_0
            new_type = M.GGML_TYPE_Q1_0
        else:
            # 原样复制: 计算源数据字节
            if t.type == M.GGML_TYPE_Q8_0:
                data_bytes = (nb // 32) * M.BLOCK_BYTES[M.GGML_TYPE_Q8_0]
            elif t.type == M.GGML_TYPE_F32:
                data_bytes = nb * 4
            else:
                raise RuntimeError(f"unsupported type {t.type} for {t.name}")
            new_type = t.type
        entries.append({"name": t.name, "dims": t.dims, "type": new_type,
                        "data_bytes": data_bytes, "src_offset": t.offset})

    # serialize header + metas into in-memory buf, then data
    import io
    buf = io.BytesIO()
    buf.write(b"GGUF")
    buf.write(struct.pack("<I", 3))
    buf.write(struct.pack("<Q", len(entries)))
    buf.write(struct.pack("<Q", len(kv)))

    # kv entries: 复用 M.read_gguf 返回的 kv dict (已还原为 python 对象)
    # 参考 M 的实现写出 kv
    def wstr(s):
        sb = s.encode() if isinstance(s, str) else s
        buf.write(struct.pack("<Q", len(sb)))
        buf.write(sb)

    for k, v in kv.items():
        wstr(k)
        # tag 映射
        if isinstance(v, bool):
            tag = 0
        elif isinstance(v, int):
            tag = 5 if not (-2147483648 <= v <= 2147483647) else 4
        elif isinstance(v, float):
            tag = 7
        elif isinstance(v, str):
            tag = 6
        elif isinstance(v, np.ndarray):
            dt = v.dtype
            if dt.kind in "iu" or dt.kind == "b":
                tag = 2 if dt.kind == "b" else 3 if dt == np.int32 else 4 if dt == np.int64 else 5 if dt == np.uint64 else 2
            elif dt.kind == "f":
                tag = 1 if dt == np.float16 else 7 if dt == np.float32 else 3 if dt == np.float64 else 2
            else:
                tag = 2
        elif isinstance(v, (list, tuple)):
            tag = 9
        else:
            tag = 5
        buf.write(struct.pack("<I", tag))
        # 值
        if isinstance(v, bool):
            buf.write(struct.pack("<B", int(v)))
        elif isinstance(v, int):
            buf.write(struct.pack("<q", v))
        elif isinstance(v, float):
            buf.write(struct.pack("<f", v))
        elif isinstance(v, str):
            sb = v.encode()
            buf.write(struct.pack("<Q", len(sb)))
            buf.write(sb)
        elif isinstance(v, np.ndarray):
            if v.dtype.kind in "iu" or v.dtype.kind == "b":
                if v.dtype == np.int8 or v.dtype.kind == "b":
                    buf.write(v.astype(np.int8).tobytes())
                elif v.dtype == np.int16:
                    buf.write(v.astype(np.int16).tobytes())
                elif v.dtype == np.int32:
                    buf.write(v.astype(np.int32).tobytes())
                elif v.dtype == np.int64:
                    buf.write(v.astype(np.int64).tobytes())
                else:
                    buf.write(v.astype(np.int64).tobytes())
            elif v.dtype.kind == "f":
                if v.dtype == np.float16:
                    buf.write(v.astype(np.float16).tobytes())
                elif v.dtype == np.float32:
                    buf.write(v.astype(np.float32).tobytes())
                else:
                    buf.write(v.astype(np.float32).tobytes())
        elif isinstance(v, (list, tuple)):
            buf.write(struct.pack("<Q", len(v)))
            for x in v:
                if isinstance(x, (str, int, float, bool)):
                    wstr(str(x)) if isinstance(x, str) else buf.write(struct.pack("<i", int(x)) if isinstance(x, bool) else struct.pack("<q", int(x))) if isinstance(x, int) else buf.write(struct.pack("<f", float(x)))
        # fallthrough: 其它类型写 int64 0 (极少)

    # tensor meta entries
    data_offset = 0
    for e in entries:
        wstr(e["name"])
        nd = len(e["dims"])
        buf.write(struct.pack("<I", nd))
        for d in e["dims"]:
            buf.write(struct.pack("<q", d))
        buf.write(struct.pack("<I", e["type"]))
        buf.write(struct.pack("<Q", data_offset))
        data_offset += e["data_bytes"]

    # 数据区起点对齐
    base_off = buf.tell()
    pad = (-base_off) % 32
    buf.write(b"\0" * pad)

    hdr = buf.getvalue()
    data_start = len(hdr)
    # 修正 offset: 数据区从 data_start 开始, 之前的 offset 是相对数据区, gguf 用相对数据区起点, 无需改.
    # 但 buffer 已写完, 我们直接在文件里写 hdr 然后逐张量写数据
    with open(dst, "wb") as f:
        f.write(hdr)
        srcf = open(src, "rb")
        for e in entries:
            if e["type"] == M.GGML_TYPE_Q1_0:
                # 编码源 q8_0 张量 -> 写 Q1_0 块
                n_in, n_out = e["dims"][0], e["dims"][1] if len(e["dims"]) > 1 else 1
                nb = int(n_in * n_out) // QK
                chunk = 32768
                for b0 in range(0, nb, chunk):
                    nbw = min(chunk, nb - b0)
                    W = M.dequant_blocks(src, info_lookup(e["name"], infos), ds, b0, nbw).reshape(-1, QK)
                    sc, cod = P.enc_batch_vec(W, cb, b)
                    d = Q.scale_table().astype(np.float64)[sc.astype(np.int64)].astype(np.float16)
                    blk = np.empty((nbw, BLOCK_BYTES_Q1_0), np.uint8)
                    blk[:, 0:2] = d.view(np.uint8).reshape(-1, 2)
                    blk[:, 2:] = cod
                    f.write(blk.tobytes())
                print(f"  {e['name']}", flush=True)
            else:
                # 原样复制源数据
                srcf.seek(ds + e["src_offset"])
                # 按块读取防内存暴涨
                for off in range(0, e["data_bytes"], 1 << 22):
                    f.write(srcf.read(min(1 << 22, e["data_bytes"] - off)))
        srcf.close()

    # 校验: 数据区偏移与 meta 一致
    print(f"wrote {dst}  {data_offset/1e6:.1f} MB  ({time.time()-t0:.1f}s)")
    print(f"tensor_count={len(entries)}  data_bytes={data_offset/1e6:.1f}MB")


def info_lookup(name, infos):
    for t in infos:
        if t.name == name:
            return t
    raise KeyError(name)


if __name__ == "__main__":
    main()