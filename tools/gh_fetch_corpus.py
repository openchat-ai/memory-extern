#!/data/data/com.termux/files/usr/bin/python3
"""gh_fetch_corpus.py — 并发从 GitHub 抓真实 Python 代码语料.

动机: 教师软目标在本机只能以 9.1 tok/s 提取 (Q4T 前向), 跑满 11.5 小时也只有
378K tokens; 而真实代码可以近乎免费获取. 教师 Q4T 的困惑度上界是 52.9,
本身并不强 —— 在"数据是瓶颈"的前提下, 直接用真实代码做 CE 训练很可能优于
蒸馏一个弱教师.

网络条件 (本机实测):
  - raw.githubusercontent.com  可用
  - api.github.com           可用, 未认证配额 60 次/小时
  - github.com:443 (git)     不通, git clone 不可用

策略: 每个仓库只用 1 次 API 调用取整棵树
(``/repos/{o}/{r}/git/trees/{branch}?recursive=1``), 之后全部走 raw 下载.
实测单线程下载受往返延迟限制 (~6 s/文件, 仅 3 KB/s), 故用线程池并发.
"""
import os
import sys
import json
import time
import threading
import queue
import urllib.request

RAW = "https://raw.githubusercontent.com/%s/%s/%s/%s"
API = "https://api.github.com/repos/%s/%s/git/trees/%s?recursive=1"

REPOS = [
    ("pallets", "click"), ("pallets", "flask"), ("psf", "requests"),
    ("pallets", "jinja"), ("pallets", "werkzeug"), ("pallets", "itsdangerous"),
    ("pallets", "markupsafe"), ("psf", "black"), ("psf", "isort"),
    ("pallets", "sqlalchemy"), ("encode", "httpx"), ("encode", "starlette"),
    ("tiangolo", "fastapi"), ("pydantic", "pydantic"), ("pytest-dev", "pytest"),
    ("scikit-learn", "scikit-learn"), ("python", "cpython"),
    ("psf", "rich"), ("Textualize", "rich-cli"), ("tox-dev", "filelock"),
    ("agronholm", "anyio"), ("dask", "dask"), ("jupyter", "nbformat"),
    ("jupyter", "nbclient"), ("sympy", "sympy"), ("networkx", "networkx"),
    ("pypa", "pip"), ("pypa", "setuptools"), ("pypa", "virtualenv"),
    ("aio-libs", "aiohttp"), ("Delgan", "loguru"), ("python-attrs", "attrs"),
    ("pallets", "marshmallow"), ("PrefectHQ", "prefect"),
    ("cookiecutter", "cookiecutter"), ("python-poetry", "poetry"),
    ("Textualize", "textual"), ("argcomplete", "argcomplete"),
    ("dbcli", "pgcli"), ("dbcli", "mycli"), ("dbcli", "litecli"),
    ("urwid", "urwid"), ("benoitc", "gunicorn"), ("benoitc", "fabric"),
    # --- 第二批: 扩大覆盖面 (第一轮 44 个仓库只有 15 个成功, 且 cpython
    #     + scikit-learn 占 70%, 语料偏得厉害, 需要更多不同领域的项目)
    ("psf", "httpie"), ("httpie", "httpie"), ("dbcli", "iredis"),
    ("urllib3", "urllib3"), ("certifi", "certifi"), ("python-jsonschema", "jsonschema"),
    ("python-jsonschema", "referencing"), ("pypa", "distlib"),
    ("hukkinen", "tomlkit"), ("uiri", "toml"), ("python-poetry", "cleo"),
    ("python-poetry", "crashtest"), ("sdispater", "pendulum"),
    ("dateutil", "python-dateutil"), ("arrow-py", "arrow"),
    ("yaml", "pyyaml"), ("zulip", "markdown"), ("python-telegram-bot", "ptbcontrib"),
    ("Textualize", "textual"), ("ccxt", "ccxt"), ("mwaskom", "seaborn"),
    ("plotly", "plotly.py"), ("bokeh", "bokeh"), ("streamlit", "streamlit"),
    ("gradio-app", "gradio"), ("huggingface", "transformers"),
    ("huggingface", "datasets"), ("huggingface", "accelerate"),
    ("scikit-hep", "hist"), ("matplotlib", "mpl_toolkits"),
    ("pandas-dev", "pandas"), ("numpy", "numpy"), ("scipy", "scipy"),
    ("xarray", "xarray"), ("dask", "distributed"), ("rapidsai", "cudf"),
    ("ansible", "ansible"), ("saltstack", "salt"), ("ceph", "ceph"),
    ("kubernetes", "client-python"), ("docker", "docker-py"),
    ("hvac", "hvac"), ("boto", "boto"), ("pulumi", "pulumi"),
    ("Azure", "azure-sdk-for-python"), ("googleapis", "google-cloud-python"),
    ("gspread", "gspread"), ("openpyxl", "openpyxl"), ("pandas-dev", "tablib"),
    ("jazzband", "tablib"), ("xlsxwriter", "xlsxwriter"), ("PyPDF2", "PyPDF2"),
    ("pdfplumber", "pdfplumber"), ("mendeley", "crossref-rest-py"),
    ("tweepy", "tweepy"), ("PyGithub", "PyGithub"), ("slackapi", "python-slack-sdk"),
    ("twilio", "twilio-python"), ("sendgrid", "sendgrid-python"),
    ("stripe", "stripe-python"), ("boto3", "boto3"), ("redis", "redis-py"),
    ("elastic", "elasticsearch-py"), ("mongodb", "mongo-python-driver"),
    ("psycopg", "psycopg2"), ("PyMySQL", "PyMySQL"), ("pymongo", "pymongo"),
    ("kennethreitz", "requests-toolbelt"), ("urllib3", "urllib3"),
    ("Textualize", "yoga"), ("pydantic", "pydantic-core"),
    ("aio-libs", "asyncpg"), ("MagicStack", "uv"), ("astral-sh", "ruff"),
]

_state = {"files": 0, "bytes": 0}
_lock = threading.Lock()


def get(url, tries=2):
    for i in range(tries):
        try:
            req = urllib.request.Request(url, headers={
                "User-Agent": "corpus-fetch", "Accept": "application/vnd.github+json"})
            with urllib.request.urlopen(req, timeout=30) as r:
                return r.read()
        except Exception:
            if i == tries - 1:
                return None
            time.sleep(1.0 * (i + 1))
    return None


def worker(q, out_dir, cap_bytes):
    while True:
        with _lock:
            if _state["bytes"] >= cap_bytes:
                return
        try:
            owner, repo, branch, path = q.get_nowait()
        except queue.Empty:
            return
        data = get(RAW % (owner, repo, branch, path))
        if not data or len(data) < 400:
            continue
        dst = os.path.join(out_dir, f"{owner}_{repo}__{path.replace('/', '_')}")
        try:
            with open(dst, "wb") as f:
                f.write(data)
        except OSError:
            continue
        with _lock:
            _state["files"] += 1
            _state["bytes"] += len(data)
            n, b = _state["files"], _state["bytes"]
        if n % 200 == 0:
            print(f"  {n} 文件 {b/1e6:.1f}MB", flush=True)


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "corpus_gh"
    cap_mb = float(sys.argv[2]) if len(sys.argv) > 2 else 60.0
    nthread = int(sys.argv[3]) if len(sys.argv) > 3 else 24
    os.makedirs(out_dir, exist_ok=True)
    cap = cap_mb * 1e6
    t0 = time.time()
    q = queue.Queue()
    ntree = 0
    for owner, repo in REPOS:
        blob = None
        for branch in ("main", "master"):
            blob = get(API % (owner, repo, branch), tries=1)
            if blob:
                break
        if not blob:
            print(f"  [tree 失败] {owner}/{repo}", flush=True)
            continue
        try:
            tree = json.loads(blob).get("tree", [])
        except Exception:
            continue
        paths = [x["path"] for x in tree
                 if x.get("type") == "blob" and x["path"].endswith(".py")
                 and x.get("size", 0) > 800]
        ntree += len(paths)
        for p in paths:
            q.put((owner, repo, branch, p))
    print(f"[tree] {len(REPOS)} 仓库, 共 {ntree} 个 .py 待取", flush=True)

    ths = [threading.Thread(target=worker, args=(q, out_dir, cap), daemon=True)
           for _ in range(nthread)]
    for t in ths:
        t.start()
    for t in ths:
        t.join()
    el = time.time() - t0
    print(f"[done] {_state['files']} 文件 / {_state['bytes']/1e6:.1f} MB / "
          f"{el:.0f}s = {_state['bytes']/el/1e3:.0f} KB/s")


if __name__ == "__main__":
    main()