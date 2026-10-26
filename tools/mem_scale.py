"""运行时记忆层规模测试: 检索命中率 / tie / 硬拒绝脆弱性 / 冲突.

用法: python tools/mem_scale.py [--gen]
  --gen  额外跑端到端生成 (慢, 每条约 2s)
"""
import sys, os, argparse, random
from collections import Counter
sys.path.insert(0, os.path.dirname(__file__))
from hebb_memory import HebbMemory

# 53 国 x 3 属性 = 159 条真实事实 (只用 key->value 的身份, 不校验事实正确性)
CT = [("Argentina","Buenos Aires","peso","Spanish"),("Australia","Canberra","dollar","English"),
("Austria","Vienna","euro","German"),("Belgium","Brussels","euro","Dutch"),
("Brazil","Brasilia","real","Portuguese"),("Canada","Ottawa","dollar","English"),
("Chile","Santiago","peso","Spanish"),("China","Beijing","yuan","Chinese"),
("Colombia","Bogota","peso","Spanish"),("Croatia","Zagreb","euro","Croatian"),
("Czechia","Prague","koruna","Czech"),("Denmark","Copenhagen","krone","Danish"),
("Egypt","Cairo","pound","Arabic"),("Estonia","Tallinn","euro","Estonian"),
("Finland","Helsinki","euro","Finnish"),("France","Paris","euro","French"),
("Germany","Berlin","euro","German"),("Greece","Athens","euro","Greek"),
("Hungary","Budapest","forint","Hungarian"),("Iceland","Reykjavik","krona","Icelandic"),
("India","New Delhi","rupee","Hindi"),("Indonesia","Jakarta","rupiah","Indonesian"),
("Iran","Tehran","rial","Persian"),("Ireland","Dublin","euro","English"),
("Israel","Jerusalem","shekel","Hebrew"),("Italy","Rome","euro","Italian"),
("Japan","Tokyo","yen","Japanese"),("Kenya","Nairobi","shilling","Swahili"),
("Malaysia","Kuala Lumpur","ringgit","Malay"),("Mexico","Mexico City","peso","Spanish"),
("Morocco","Rabat","dirham","Arabic"),("Netherlands","Amsterdam","euro","Dutch"),
("New Zealand","Wellington","dollar","English"),("Nigeria","Abuja","naira","English"),
("Norway","Oslo","krone","Norwegian"),("Pakistan","Islamabad","rupee","Urdu"),
("Peru","Lima","sol","Spanish"),("Philippines","Manila","peso","Filipino"),
("Poland","Warsaw","zloty","Polish"),("Portugal","Lisbon","euro","Portuguese"),
("Romania","Bucharest","leu","Romanian"),("Russia","Moscow","ruble","Russian"),
("Saudi Arabia","Riyadh","riyal","Arabic"),("South Africa","Pretoria","rand","English"),
("South Korea","Seoul","won","Korean"),("Spain","Madrid","euro","Spanish"),
("Sweden","Stockholm","krona","Swedish"),("Switzerland","Bern","franc","German"),
("Thailand","Bangkok","baht","Thai"),("Turkey","Ankara","lira","Turkish"),
("Ukraine","Kyiv","hryvnia","Ukrainian"),("United Kingdom","London","pound","English"),
("Vietnam","Hanoi","dong","Vietnamese")]

ATTR = [("capital", 1), ("currency", 2), ("language", 3)]
def real_facts():
    F = []
    for row in CT:
        for a, k in ATTR:
            F.append((f"The {a} of {row[0]} is", row[k], row[0], a))
    return F

def fake_name(i):
    syl = ["Zor","kav","mel","tris","vun","dral","osk","nim","bex","quel","farn","hul"]
    return "".join(syl[(i * 7 + j * 3) % len(syl)] for j in range(3)).capitalize()

def decoys(n):
    out = []
    for i in range(n):
        nm = fake_name(i) + str(i % 97)
        for a, _ in ATTR:
            out.append((f"The {a} of {nm} is", f"Val{i}", nm, a))
    return out

def reset(m):
    m.facts, m._toks, m._df, m._nums = [], [], Counter(), set()

QUERIES = {
    "Q1 精确key":      lambda k, c, a: k,
    "Q2 完整问句":     lambda k, c, a: f"What is the {a} of {c}?",
    "Q3 前置语序":     lambda k, c, a: f"{c}'s {a} is",
    "Q4 key+问号":     lambda k, c, a: k + "?",
    "Q5 只给实体":     lambda k, c, a: c,
}

def run(m, pool, n, label, soft, qpool=None):
    reset(m)
    m.soft = soft
    for k, v, *_ in pool[:n]:
        m.add(k, v)
    qpool = (qpool[:n] if qpool is not None else pool[:n])
    res = {}
    for qn, fn in QUERIES.items():
        ok = tie = rej = 0
        margins = []
        for k, v, c, a in qpool:
            q = fn(k, c, a)
            sc = [(m._score(q, kt), i) for i, kt in enumerate(m._toks)]
            sc.sort(reverse=True)
            s1 = sc[0][0]
            s2 = sc[1][0] if len(sc) > 1 else 0.0
            margins.append(s1 - s2)
            if s1 == 0.0:
                rej += 1
            elif s1 == s2:
                tie += 1
            if m.facts[sc[0][1]]["key"] == k:
                ok += 1
        res[qn] = (ok / len(qpool), tie, rej, sum(margins) / len(margins))
    print(f"\n[{label}] N={n} soft={soft}")
    for qn, (acc, tie, rej, mg) in res.items():
        print(f"  {qn:12s} 命中 {acc*100:5.1f}%  tie {tie:3d}  拒绝 {rej:3d}  平均margin {mg:.3f}")
    return res

def conflict(m):
    reset(m); m.soft = False
    m.add("The capital of France is", "Paris")
    m.add("The capital of France is", "Lyon")
    r = m.retrieve("The capital of France is", k=2)
    print("\n[冲突] 同一 key 两个 value ->", [(x["sim"], x["value"]) for x in r],
          "| 无任何冲突检测, 取 list 顺序")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gen", action="store_true")
    args = ap.parse_args()
    m = HebbMemory()
    R = real_facts()
    D = decoys(900)
    print(f"真实事实 {len(R)} 条 / 干扰事实 {len(D)} 条")
    for n in (10, 100, 500, 1000):
        run(m, R, min(n, len(R)), f"纯真实", False)
    for n in (159, 500, 1000):
        run(m, R + D, n, "真实+干扰(只查真实)", False, qpool=R)
    run(m, R + D, 1000, "真实+干扰(软拒绝,只查真实)", True, qpool=R)
    run(m, R, 159, "真实(软拒绝)", True)
    conflict(m)
    if args.gen:
        m2 = HebbMemory()
        F = [(f"The founder of {fake_name(i)} Labs is", f"Kestrel{i}", fake_name(i), "founder") for i in range(20)]
        for n in (20, 1000):
            pool = F + decoys(n - 20) if n > 20 else F
            reset(m2); m2.soft = False
            for k, v, *_ in pool: m2.add(k, v)
            ok = 0
            for k, v, c, a in F:
                info = m2.answer(k, n_new=12)
                if v.lower() in info["text"].lower(): ok += 1
            print(f"\n[端到端生成] N={n}: {ok}/20 输出含正确 value (route={info['route']})")

if __name__ == "__main__":
    main()
