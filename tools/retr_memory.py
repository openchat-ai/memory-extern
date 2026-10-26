"""赫布式检索记忆: 用模型自身第 4/6 层 FFN 激活的均值池化作 key 向量.

与权重注入共用同一个点积 (phi·key), 但不改权重:
    index = [ (key, value, vec) ],  vec = mean_pool(phi_L4, phi_L6)
检索 = 两层余弦求和. 无训练, 无外部 embedding 模型.

用法:
    from retr_memory import RetrievalMemory
    m = RetrievalMemory("data/retr_index.npz")
    m.add("The capital of France is", "Paris")
    m.query("What city is the capital of France?", top=3)
"""
import os
import sys
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from hebb_write import HebbWriter

LAYERS = (4, 6)


def l2(a):
    return a / (np.linalg.norm(a) + 1e-9)


class RetrievalMemory:
    def __init__(self, path=None, writer=None, layers=LAYERS):
        self.path = path
        self.layers = tuple(layers)
        self.keys, self.values, self.vecs = [], [], []
        self._w = writer
        if path and os.path.exists(path):
            z = np.load(path, allow_pickle=True)
            self.keys = [str(x) for x in z["keys"]]
            self.values = [str(x) for x in z["values"]]
            self.vecs = [z["vecs"][i] for i in range(len(self.keys))]

    @property
    def writer(self):
        if self._w is None:
            self._w = HebbWriter()
        return self._w

    def encode(self, text):
        W = self.writer
        toks = np.array(list(W.eng.encode(text)), np.int64)
        _, p = W.capture_vecs(toks)
        return np.stack([p[L].mean(0) for L in self.layers]).astype(np.float32)

    def add(self, key, value, vec=None):
        self.keys.append(key)
        self.values.append(value)
        self.vecs.append(self.encode(key) if vec is None else vec)

    def __len__(self):
        return len(self.keys)

    def save(self, path=None):
        p = path or self.path
        if not p:
            raise ValueError("no path")
        np.savez(p, keys=np.array(self.keys), values=np.array(self.values),
                 vecs=np.stack(self.vecs), layers=np.array(self.layers))

    def scores(self, qvec, top=3):
        if not self.keys:
            return []
        A = np.stack(self.vecs)
        s = np.zeros(len(A))
        for i in range(len(self.layers)):
            Ai = A[:, i, :]
            s += (Ai / (np.linalg.norm(Ai, axis=1, keepdims=True) + 1e-9)) @ l2(qvec[i])
        order = np.argsort(-s)[:top]
        return [(self.keys[j], self.values[j], float(s[j])) for j in order]

    def query(self, text, top=3):
        return self.scores(self.encode(text), top)
