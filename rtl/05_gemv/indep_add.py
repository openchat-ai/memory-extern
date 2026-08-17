#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""indep_add.py — f32_add 的独立 IEEE-754 验证器。

与 C golden（gen_add_cases.c）和 RTL（f32_add.v）实现方法完全不同：
这里用精确整数有理运算 + 单次 RN-even 舍入，去相关防止"共同错误"。

语义对齐（ARM FADD / C a+b）：
  - NaN：传播第一个 NaN 操作数并静默化（mantissa bit22 置 1）
  - inf - inf（异号 inf）→ 0x7FC00000
  - x + (-x) → +0（RN 下精确 0 舍入到 +0）
  - (-0) + (-0) → -0

用法：
  python3 indep_add.py --check-c     # 用 Python 重算现有 C 语料，交叉核对
  python3 indep_add.py               # 生成定向矩阵 + 随机用例 → py_a/py_b/py_e.hex + py_run.v
"""
import struct, random, sys

FMT = '<f'


def fbits(x: float) -> int:
    return struct.unpack('<I', struct.pack(FMT, x))[0]


def f32_add(a: int, b: int) -> int:
    sa, ea, ma = (a >> 31) & 1, (a >> 23) & 0xFF, a & 0x7FFFFF
    sb, eb, mb = (b >> 31) & 1, (b >> 23) & 0xFF, b & 0x7FFFFF
    if ea == 0xFF and ma != 0:
        return (sa << 31) | (0xFF << 23) | (ma | 0x400000)
    if eb == 0xFF and mb != 0:
        return (sb << 31) | (0xFF << 23) | (mb | 0x400000)
    a_inf = ea == 0xFF
    b_inf = eb == 0xFF
    if a_inf and b_inf:
        return (sa << 31) | (0xFF << 23) if sa == sb else 0x7FC00000
    if a_inf:
        return (sa << 31) | (0xFF << 23)
    if b_inf:
        return (sb << 31) | (0xFF << 23)

    def unpack(s, e, m):
        # 值 = M×2^emin，M 整数
        if e == 0:
            return (s, m, -149)
        return (s, (1 << 23) | m, e - 127 - 23)

    (sa, Ma, Ea), (sb, Mb, Eb) = unpack(sa, ea, ma), unpack(sb, eb, mb)
    if Ma == 0:
        if Mb == 0:
            return (0x80000000 if (sa and sb) else 0x00000000)
        return (sb << 31) | (eb << 23) | mb
    if Mb == 0:
        return (sa << 31) | (ea << 23) | ma

    emin = min(Ea, Eb)
    S = ((Ma if sa == 0 else -Ma) << (Ea - emin)) + \
        ((Mb if sb == 0 else -Mb) << (Eb - emin))
    if S == 0:
        return 0x00000000
    if S < 0:
        c, S = 1, -S
    else:
        c = 0

    L = S.bit_length()
    E = (L - 1) + emin
    if L > 24:
        sh = L - 24
        H = S >> sh
        D = S & ((1 << sh) - 1)
        half = 1 << (sh - 1)
        if D > half or (D == half and (H & 1)):
            H += 1
    else:
        H = S << (24 - L)
    if H == (1 << 24):
        H = 1 << 23
        E += 1
    if E > 127:
        return (c << 31) | 0x7F800000
    if E >= -126:
        return (c << 31) | ((E + 127) << 23) | (H & 0x7FFFFF)
    sh = -(E + 126)
    G = H >> sh
    D = H & ((1 << sh) - 1)
    half = 1 << (sh - 1)
    if D > half or (D == half and (G & 1)):
        G += 1
    if G == (1 << 23):
        return (c << 31) | (1 << 23)
    if G == 0:
        return (c << 31)
    return (c << 31) | G


def norm(s: int, e: int, m: int) -> int:
    return (s << 31) | (e << 23) | (m & 0x7FFFFF)


def sub(s: int, m: int) -> int:
    return (s << 31) | (m & 0x7FFFFF)


def self_test() -> None:
    T = [
        (0x3F7FFFFF, 0x3F800000, 0x40000000),   # (1-2^-24)+1 = 2，尾数进位
        (0x3F800000, 0xBF800000, 0x00000000),   # 1+(-1) = +0
        (0x80000000, 0x80000000, 0x80000000),   # (-0)+(-0) = -0
        (0x80000000, 0x00000000, 0x00000000),   # (-0)+(+0) = +0
        (0x7F800000, 0xFF800000, 0x7FC00000),   # inf + -inf = NaN
        (0xFF800000, 0xFF800000, 0xFF800000),   # -inf + -inf = -inf
        (0x7F800000, 0x7F800000, 0x7F800000),   # +inf + +inf = +inf
        (0x7F800000, 0x3F800000, 0x7F800000),   # inf + 1 = inf
        (0x00000001, 0x00000001, 0x00000002),   # 2^-149 + 同
        (0x007FFFFF, 0x007FFFFF, 0x00FFFFFE),   # max_sub×2 ≈ 2^-125（正规）
        (0x7F7FFFFF, 0x7F7FFFFF, 0x7F800000),   # max×2 = inf
        (0x3F800000, 0x00000001, 0x3F800000),   # 1 + 2^-149（sticky，不升）
        (0x3F800000, 0x33800000, 0x3F800000),   # 1 + 2^-24 = tie，偶数 → 不进
        (0x3F800001, 0x33800000, 0x3F800002),   # 1+2^-23（odd LSB） + tie → 进
        (0x7FA00000, 0x3F800000, 0x7FE00000),   # sNaN + 1 → 静默化
        (0x00000001, 0x80000001, 0x00000000),   # 次正规对消 → +0
    ]
    for a, b, w in T:
        g = f32_add(a, b)
        assert g == w, f"selftest FAIL a={a:08x} b={b:08x} got={g:08x} want={w:08x}"
    print(f"self-test: {len(T)} 例全过")


def check_c() -> int:
    n = 0
    with open('add_pairs_a.hex') as fa, open('add_pairs_b.hex') as fb, \
            open('add_expected.hex') as fe:
        for la, lb, le in zip(fa, fb, fe):
            a, b, e = int(la, 16), int(lb, 16), int(le, 16)
            g = f32_add(a, b)
            if g != e:
                print(f"C交叉: FAIL a={a:08x} b={b:08x} py={g:08x} c={e:08x}")
                n += 1
            if n > 15:
                break
    print(f"C 交叉核对: 不一致 {n} 处")
    return n


def directed_cases() -> list:
    cases = []

    # 1) 特殊值全组合
    sp = [0x00000000, 0x80000000, 0x3F800000, 0xBF800000,
          0x7F800000, 0xFF800000, 0x7FC00000, 0x7FA00000,
          0x00000001, 0x007FFFFF, 0x00800000, 0x7F7FFFFF,
          0xFF7FFFFF, 0x3F7FFFFF, 0x3E000000, 0x7F000000,
          0x7E7FFFFF, 0x00000002]
    for x in sp:
        for y in sp:
            cases.append((x, y))

    # 2) 指数差扫描（sticky/对齐边界）
    for m in (0, 1, 0x400000, 0x7FFFFF):
        X = norm(0, 127, m)
        for d in range(0, 41):
            b = norm(0, 127 + d, 0) if 127 + d <= 254 else sub(0, 1 << (41 - d))
            cases.append((X, b))
            cases.append((X, b ^ 0x80000000))

    # 3) RN-even 定点：尾数 LSB 奇/偶 × tie 上/下/恰
    for eu in (-126, -100, -50, -24, -1, 0, 1, 25, 50, 100, 125, 126):
        if eu - 24 < -149:
            continue
        for m in (0x000000, 0x000001, 0x7FFFFE, 0x7FFFFF):
            for s in (0, 1):
                X = norm(s, eu + 127, m)
                tie = 2.0 ** (eu - 24)
                for D in (tie, tie + tie / 2, tie / 2, tie + tie / 4,
                          tie - tie / 4, tie + tie / 8, tie - tie / 8):
                    cases.append((X, fbits(D)))
                    cases.append((X, fbits(-D)))

    # 4) 溢出边界：max finite 邻域 → ±inf / 保持有限
    A = norm(0, 254, 0x7FFFFF)          # (2-2^-23)×2^127 = 2^128-2^104
    for D in (2.0 ** 103, 2.0 ** 102, 2.0 ** 102 + 2.0 ** 101,
              2.0 ** 101, 2.0 ** 104, -2.0 ** 103, -2.0 ** 104):
        cases.append((A, fbits(D)))
        cases.append((A ^ 0x80000000, fbits(D)))

    # 5) 次正规边界与进位
    cases.append((0x007FFFFF, 0x007FFFFF))
    cases.append((0x003FFFFF, 0x00400000))
    cases.append((0x00000001, 0x00000001))
    cases.append((0x00800000, 0x00000001))     # 2^-126 + 2^-149
    cases.append((0x00800000, 0x00000002))
    cases.append((0x00800000, 0x007FFFFF))
    cases.append((0x00800000, 0x007FFFFF ^ 0x80000000))
    for d in (0x1, 0x2, 0x3, 0x7FFFFF):
        cases.append((0x00800000, d))
        cases.append((0x00800000, d ^ 0x80000000))

    # 6) 深对消：a + (-a)，近 a 对消（nz 1..24），次正规结果
    for a in (0x3F800000, 0x7F7FFFFF, 0x00000001, 0x00800000,
              0x7F000000, 0x7E7FFFFF, 0x00000002):
        cases.append((a, a ^ 0x80000000))
    for k in (1, 2, 5, 10, 17, 23, 24):
        for e in (2, 30, 90, 120, 126):
            cases.append((norm(0, e, 0x400000), norm(1, e, (0x400000 - (1 << k)) & 0x7FFFFF)))
    # 深层：结果落到次正规区
    for e in (2, 3, 5, 10):
        cases.append((norm(0, e, 0x000001), norm(1, e, 0x000000)))
        cases.append((norm(0, e, 0x400000), norm(1, e, 0x000001)))

    return cases


def random_cases(rng: random.Random, n: int) -> list:
    cases = []

    def rand_sub():
        return (rng.getrandbits(1) << 31) | rng.getrandbits(23)

    def rand_normal():
        return (rng.getrandbits(1) << 31) | (rng.randrange(1, 255) << 23) | rng.getrandbits(23)

    # 全随机（含 NaN/inf/零，~0.8% NaN）
    for _ in range(int(n * 0.30)):
        cases.append((rng.getrandbits(32), rng.getrandbits(32)))

    # 次正规密集
    for _ in range(int(n * 0.12)):
        cases.append((rand_sub(), rand_sub()))
        cases.append((rand_sub(), rand_normal()))

    # 大指数 → 溢出/进位
    for _ in range(int(n * 0.10)):
        ua = (rng.getrandbits(1) << 31) | (rng.randrange(240, 255) << 23) | rng.getrandbits(23)
        ub = (rng.getrandbits(1) << 31) | (rng.randrange(240, 255) << 23) | rng.getrandbits(23)
        cases.append((ua, ub))

    # 同号同指数大尾数 → msum[26] 进位
    for _ in range(int(n * 0.08)):
        e = rng.randrange(1, 253)
        s = rng.getrandbits(1)
        m1 = rng.randrange(0x400000, 0x800000)
        m2 = rng.randrange(0x400000, 0x800000)
        cases.append((norm(s, e, m1), norm(s, e, m2)))

    # 近值对消（同指数、尾数差小，异号为主）
    for _ in range(int(n * 0.15)):
        e = rng.randrange(1, 255)
        m1 = rng.getrandbits(23)
        m2 = (m1 + rng.randrange(-64, 65)) & 0x7FFFFF
        s1 = rng.getrandbits(1)
        s2 = s1 if rng.random() < 0.35 else 1 - s1
        cases.append((norm(s1, e, m1), norm(s2, e, m2)))

    # 深层对消 → 次正规/大 nz
    for _ in range(int(n * 0.10)):
        e = rng.randrange(2, 123)
        m1 = rng.getrandbits(23)
        k = rng.randrange(1, 27)
        m2 = (m1 - rng.randrange(1, 1 << min(k, 23))) & 0x7FFFFF
        cases.append((norm(0, e, m1), norm(1, e, m2)))

    # 舍入边界：X + 小 delta（指数差 ≤27 → g/r/s 活跃）
    for _ in range(int(n * 0.15)):
        if rng.random() < 0.5:
            dx = rand_sub()
            de = 0
        else:
            de = rng.randrange(0, 111)
            dx = norm(rng.getrandbits(1), de, rng.getrandbits(23))
        d = rng.randrange(1, 28)
        ex = min(254, de + d)
        X = norm(rng.getrandbits(1), ex, rng.getrandbits(23))
        cases.append((X, dx))

    return cases


def main() -> None:
    if '--check-c' in sys.argv:
        sys.exit(check_c())

    self_test()
    rng = random.Random(0x5EED)
    directed = directed_cases()
    rand = random_cases(rng, 900000)
    cases = directed + rand
    print(f"定向 {len(directed)} + 随机 {len(rand)} = {len(cases)} 用例")

    with open('py_a.hex', 'w') as fa, open('py_b.hex', 'w') as fb, \
            open('py_e.hex', 'w') as fe:
        for a, b in cases:
            fa.write(f"{a:08x}\n")
            fb.write(f"{b:08x}\n")
            fe.write(f"{f32_add(a, b):08x}\n")

    with open('py_run.v', 'w') as ft:
        ft.write(f"""`timescale 1ns/1ps
// py_run.v — 独立参考生成的用例，驱动 f32_add 逐位比对（自动生成）
module py_run;
    reg  [31:0] a, b;
    wire [31:0] s;
    f32_add dut (.a(a), .b(b), .y(s));
    parameter TOTAL = {len(cases)};
    reg [31:0] av [0:TOTAL-1];
    reg [31:0] bv [0:TOTAL-1];
    reg [31:0] ev [0:TOTAL-1];
    integer errors = 0, idx;
    initial begin
        $readmemh("py_a.hex", av);
        $readmemh("py_b.hex", bv);
        $readmemh("py_e.hex", ev);
        for (idx = 0; idx < TOTAL; idx = idx + 1) begin
            a = av[idx]; b = bv[idx];
            #1;
            if (s !== ev[idx]) begin
                if (errors < 15)
                    $display("FAIL #%0d: a=%08h b=%08h got=%08h want=%08h",
                             idx, a, b, s, ev[idx]);
                errors = errors + 1;
            end
        end
        $display("f32_add(indep): %0d 用例, %0d 错误", TOTAL, errors);
        if (errors == 0) $display("=== ALL PASS ===");
        else $display("=== %0d ERROR(S) ===", errors);
        $finish;
    end
endmodule
""")
    print("写: py_a.hex py_b.hex py_e.hex py_run.v")


if __name__ == '__main__':
    main()
