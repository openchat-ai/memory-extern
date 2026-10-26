"""侧支 #39: 白化写入在 fact key 上的有效增益 r = (phi.Wt.phi)/(phi.Wt^2.phi)."""
import sys, os
import numpy as np
sys.path.insert(0, os.path.dirname(__file__))
from hebb_write import HebbWriter

LAM = 0.1
L = [18, 19, 20, 21, 22]
D = "/data/data/com.termux/files/home/sram/data"

H = HebbWriter()
E = H.eng
A = np.load(f"{D}/aux_phi_all.npy")
FACTS = [("The largest planet in our solar system is", "Jupiter"),
         ("The color of a clear daytime sky is", "blue"),
         ("The continent that contains Egypt is", "Africa")]

print("层  fact      |phi|     r=(phiWtphi)/(phiWt2phi)   主方向占比  aux子空间占比")
for i in L:
    Af = A[:, i, :].astype(np.float64)
    cov = (Af.T @ Af) / len(Af)
    Wt = np.linalg.solve(cov + LAM * np.eye(H.F), np.eye(H.F))
    ev, evec = np.linalg.eigh(cov)
    top = evec[:, np.argsort(ev)[::-1][:30]]
    for kp, val in FACTS:
        phi = H.capture_phi(np.array(E.encode(kp), np.int64))[i].astype(np.float64)
        pk = phi @ Wt
        num = float(phi @ pk)
        den = float(pk @ pk)
        r = num / den
        tot = float(phi @ phi)
        in_aux = float((phi @ top) @ (phi @ top))
        print(f"{i}   {val:8s} |phi|={np.linalg.norm(phi):8.3f}  r={r:12.6f}  "
              f"主方向 {float((phi@top[:,0])**2)/tot:8.5f}  aux {in_aux/tot:8.3f}")
print("\n[注] r 就是“实际写入的有效振幅 / c”的倍数")
