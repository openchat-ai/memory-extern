"""解码 research-cli 的 tok[N] = id 日志为文本。
用法: python decode_toks.py <gguf模型> <research-cli.log>
输出: 每行 tok[N] = id [token文本]
"""
import sys, struct

def read_gguf_tokens(path):
    with open(path, "rb") as f:
        magic = f.read(4)
        assert magic == b"GGUF", f"bad magic {magic}"
        ver, = struct.unpack("<I", f.read(4))
        n_tensors, n_kv = struct.unpack("<QQ", f.read(16))
        tokens = None
        for _ in range(n_kv):
            nlen, = struct.unpack("<Q", f.read(8))
            key = f.read(nlen).decode("utf-8", "replace")
            vtype, = struct.unpack("<I", f.read(4))
            def skip_val():
                if vtype == 0:  # u8
                    f.read(1)
                elif vtype in (1,):  # i8
                    f.read(1)
                elif vtype in (2, 3):
                    f.read(2)
                elif vtype in (4, 5, 6):
                    f.read(4)
                elif vtype == 7:
                    f.read(1)
                elif vtype == 8:  # string
                    l, = struct.unpack("<Q", f.read(8))
                    f.read(l)
                elif vtype == 9:  # array
                    et, = struct.unpack("<I", f.read(4))
                    cnt, = struct.unpack("<Q", f.read(8))
                    if et == 8:
                        for _ in range(cnt):
                            l, = struct.unpack("<Q", f.read(8))
                            f.read(l)
                    elif et == 0:
                        f.read(cnt)
                    elif et == 1:
                        f.read(cnt)
                    elif et in (2, 3):
                        f.read(2 * cnt)
                    elif et in (4, 5, 6):
                        f.read(4 * cnt)
                    elif et in (10, 11, 12):
                        f.read(8 * cnt)
                    elif et == 7:
                        f.read(cnt)
                    else:
                        raise ValueError(f"arr elem type {et}")
                elif vtype in (10, 11, 12):
                    f.read(8)
                else:
                    raise ValueError(f"vtype {vtype} for key {key}")
            if key == "tokenizer.ggml.tokens" and vtype == 9:
                et, = struct.unpack("<I", f.read(4))
                cnt, = struct.unpack("<Q", f.read(8))
                assert et == 8, f"token array elem type {et}"
                toks = []
                for _ in range(cnt):
                    l, = struct.unpack("<Q", f.read(8))
                    toks.append(f.read(l).decode("utf-8", "replace"))
                tokens = toks
            else:
                skip_val()
        return tokens

def main():
    gguf_path, log_path = sys.argv[1], sys.argv[2]
    toks = read_gguf_tokens(gguf_path)
    ids = []
    with open(log_path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            if "tok[" not in line:
                continue
            # tok[N] = M
            try:
                rhs = line.split("] = ", 1)[1].strip()
                tid = int(rhs)
            except (IndexError, ValueError):
                continue
            ids.append(tid)
    print(f"# {len(ids)} tokens decoded")
    for i, tid in enumerate(ids):
        t = toks[tid] if tid < len(toks) else f"<unk:{tid}>"
        print(f"tok[{i}] = {tid}  {t!r}")

if __name__ == "__main__":
    main()