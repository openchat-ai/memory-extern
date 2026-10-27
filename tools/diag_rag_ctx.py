"""§10.39b 模型到底读不读 context? 用编造实体(参数里不可能有)判定."""
import sys, numpy as np
sys.path.insert(0,'tools')
from hebb_write import HebbWriter
E = HebbWriter().eng
def gen(p, n=6):
    ids = list(E.encode(p)); lg, cache = E.forward(np.array(ids, np.int64)); out=[]
    for _ in range(n):
        t=int(np.argmax(lg)); out.append(t); ids.append(t)
        lg, cache = E.forward(np.array([t], np.int64), cache)
    return E.decode_text(out).strip()
cases = [
 ("编造+context", "Fact: The capital of Zorbania is Quux.\nQuestion: What city is the capital of Zorbania?\nAnswer:"),
 ("编造无context", "Question: What city is the capital of Zorbania?\nAnswer:"),
 ("真事实+错context", "Fact: The capital of Japan is Tokyo.\nQuestion: What city is the capital of France?\nAnswer:"),
 ("真事实无context", "Question: What city is the capital of France?\nAnswer:"),
]
for tag, p in cases:
    g = gen(p)
    print(f"[{tag}]\n  {g!r}", flush=True)
