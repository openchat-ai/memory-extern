"""Demo external kernel: float32x4 accumulator with broadcast scalar scale.

Identical to the builtin vfmaq_n; exists only to show the --extra interface.
"""
import numpy as np


def dot(elem, lanes, scale):
    acc = np.zeros(4, dtype=np.float32)
    for k in range(lanes.shape[0]):
        for j in range(4):
            acc[j] = np.float32(acc[j] + np.float32(np.float32(lanes[k, j]) * scale[k]))
    return float(np.float32(acc.sum(dtype=np.float32)))
