"""行级 CRNN+CTC 训练 (纯 numpy)。

数据: 转曲 CAD 图纸的 410 行裁剪图 + 簇标签拼接成的行级字符串。
诚实声明: 全部来自同一张图纸, 留出集只能衡量"对未见行的拟合", 不代表跨图泛化。
"""
import sys, os, json, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
from PIL import Image
import crnn

WORK = '/data/data/com.termux/files/usr/tmp/opencode'
SRC = os.path.join(WORK, 'ocr', 'v_r12')
H = 32
WMAX = 288
BLANK = 0


def load_all():
    items = json.load(open(os.path.join(WORK, 'ocr', 'dataset.json')))
    chars = sorted({c for it in items for c in it['txt']})
    stoi = {c: i + 1 for i, c in enumerate(chars)}
    imgs, labs, lens = [], [], []
    for it in items:
        p = os.path.join(SRC, it['name'] + '.png')
        if not os.path.exists(p):
            continue
        a = np.asarray(Image.open(p).convert('L'), dtype=np.float64)
        ink = (255.0 - a) / 255.0
        h, w = ink.shape
        scale = H / h
        nw = min(WMAX, max(8, int(round(w * scale))))
        im = np.asarray(Image.fromarray((ink * 255).astype(np.uint8))
                        .resize((nw, H), Image.BILINEAR), dtype=np.float64) / 255.0
        ids = [stoi.get(c, 1) for c in it['txt']]
        if not ids or len(ids) > nw:
            continue
        imgs.append(im)
        labs.append(ids)
        lens.append(len(ids))
    return [im for im in imgs], labs, np.array(lens), chars


def make_batch(imgs, labs, idx, Tcap):
    """按批内最大宽度补零, 时间步随之缩短"""
    w = max(imgs[i].shape[1] for i in idx)
    w = (w + 3) // 4 * 4          # 对齐到 4 的倍数, 避免池化丢列
    n = len(idx)
    X = np.zeros((n, 1, H, w))
    M = np.zeros((n, w), dtype=np.int64)
    for k, i in enumerate(idx):
        im = imgs[i]
        X[k, 0, :, :im.shape[1]] = im
        M[k, :len(labs[i])] = labs[i]
    return X, M


def forward(model, X):
    x = X
    for c, p in zip(model['convs'], model['pools']):
        x = c.forward(x)
        x = p.forward(x)
    x = x.mean(axis=2).transpose(0, 2, 1)
    x = model['gru'].forward(x)
    return model['head'].forward(x)


def backward(model, dlogp):
    """logits 梯度 -> 各级参数梯度"""
    d = model['head'].backward(dlogp)
    d, ggrad = model['gru'].backward(d)
    d = d.transpose(0, 2, 1)                       # (N,C,T)
    hc = model['hc']                                # 卷积栈输出高度
    d = np.repeat(d[:, :, None, :], hc, axis=2) / hc
    for i in range(len(model['pools']) - 1, -1, -1):
        d = model['pools'][i].backward(d)
        d = model['convs'][i].backward(d)
    return ggrad


def greedy(lp, vocab):
    best = lp.argmax(axis=-1)
    out = []
    prev = -1
    for t in range(best.shape[0]):
        k = best[t]
        if k != prev and k != BLANK:
            out.append(vocab[k - 1])
        prev = k
    return ''.join(out)


def main():
    imgs, labs, lens, vocab = load_all()
    N = len(imgs)
    ws = [im.shape[1] for im in imgs]
    print('样本 %d  高 %d  宽度 %d..%d (中位 %d)  字符表 %d  最长标签 %d'
          % (N, H, min(ws), max(ws), sorted(ws)[N // 2], len(vocab), lens.max()))
    rng = np.random.default_rng(0)
    perm = rng.permutation(N)
    nte = max(20, N // 5)
    te, tr = perm[:nte], perm[nte:]
    print('训练 %d  留出 %d' % (len(tr), len(te)))

    convs = [crnn.Conv(1, 16, 3, 1, 1, rng), crnn.Conv(16, 32, 3, 1, 1, rng),
             crnn.Conv(32, 32, 3, 1, 1, rng)]
    pools = [crnn.MaxPool(2, 2), crnn.MaxPool(2, 1), crnn.MaxPool(2, 1)]
    gru = crnn.Bigram(32, 48, rng)
    head = crnn.Linear(96, len(vocab) + 1, rng)
    hc = H
    for p_ in pools:
        hc //= p_.kh
    model = {'convs': convs, 'pools': pools, 'gru': gru, 'head': head, 'hc': hc}
    params = {}
    for i, c in enumerate(convs):
        params['c%d.w' % i] = c.w
        params['c%d.b' % i] = c.b
    for tg in ('f', 'r'):
        cell = gru.f if tg == 'f' else gru.r
        for gg in cell.GATES:
            params['g%s.%s.W' % (tg, gg)] = cell.W[gg]
            params['g%s.%s.U' % (tg, gg)] = cell.U[gg]
            params['g%s.%s.b' % (tg, gg)] = cell.b[gg]
    params['head.w'] = head.w
    params['head.b'] = head.b
    opt = crnn.Adam(params, lr=3e-3)
    CLIP = 5.0

    EPOCHS, BS = 200, 16
    tr_sorted = np.array(tr)[np.argsort([ws[i] for i in tr], kind='stable')]
    te_sorted = np.array(te)[np.argsort([ws[i] for i in te], kind='stable')]
    batches = [tr_sorted[s:s + BS] for s in range(0, len(tr_sorted), BS)]
    batches = [bb for bb in batches if len(bb) >= 2]
    best = None
    for ep in range(1, EPOCHS + 1):
        t0 = time.time()
        order = rng.permutation(len(batches))
        tot = 0.0
        nb = 0
        for bi in order:
            idx = batches[bi]
            xb, mb = make_batch(imgs, labs, idx, WMAX)
            lb = lens[idx]
            b = len(idx)
            logits = forward(model, xb)
            ct = crnn.CTC()
            loss = ct.forward(crnn.log_softmax(logits, -1), mb, lb)
            d = crnn.log_softmax_backward(ct.backward(1.0), logits)
            ggrad = backward(model, d)
            grads = {}
            for i, c in enumerate(convs):
                grads['c%d.w' % i] = c.dw / b
                grads['c%d.b' % i] = c.db / b
            for k, v in ggrad.items():
                tg, gg, kind = k.split('_')
                grads['g%s.%s.%s' % (tg, gg, kind)] = v / b
            grads['head.w'] = head.dw / b
            grads['head.b'] = head.db / b
            gn = float(np.sqrt(sum((v * v).sum() for v in grads.values())))
            if CLIP > 0 and gn > CLIP:
                sc = CLIP / gn
                for v in grads.values():
                    v *= sc
            opt.step(grads)
            tot += loss
            nb += 1
        if ep % 5 == 0 or ep == EPOCHS:
            hits = 0
            exact = 0
            for i in te_sorted:
                xb, mb = make_batch(imgs, labs, [i], WMAX)
                lg = forward(model, xb)
                lp = crnn.log_softmax(lg, -1)[0]
                pred = greedy(lp, vocab)
                gold = ''.join(vocab[k - 1] for k in labs[i])
                if pred == gold:
                    exact += 1
                m = sum(1 for x, y in zip(pred, gold) if x == y)
                if m:
                    hits += m
            nchar = int(lens[te].sum())
            print('epoch %2d  loss %.4f  留出逐字 %.1f%%  整行全对 %d/%d  %.0fs'
                  % (ep, tot / max(nb, 1), 100.0 * hits / nchar, exact, len(te),
                     time.time() - t0), flush=True)
            if best is None or exact > best:
                best = exact
    np.savez(os.path.join(WORK, 'ocr_crnn.npz'), **params)
    json.dump(vocab, open(os.path.join(WORK, 'ocr_vocab.json'), 'w'),
              ensure_ascii=False)
    print('权重已存 ocr_crnn.npz, 字符表已存 ocr_vocab.json')
    print('训练完成, 最佳整行全对 %d/%d' % (best, len(te)))
    print('注: 410 行全部来自同一张图纸, 以上不是跨图泛化指标')


if __name__ == '__main__':
    main()