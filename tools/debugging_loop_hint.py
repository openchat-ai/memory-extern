#!/usr/bin/env python3
"""debugging-loop-hint: detect repeated failures of the same command.

Usage:
    python3 tools/debugging_loop_hint.py <max_failures:int> -- <cmd>...
    # Run <cmd>. If the exact same <cmd> failed >= max_failures times
    # consecutively before this invocation, refuse to run and print analysis.

State file: ~/.cache/dlh/<md5(cmd)>.{count,err,last_ts}

Examples:
    python3 tools/debugging_loop_hint.py 2 -- git pull
    python3 tools/debugging_loop_hint.py 3 -- curl https://example.com

Reset:
    python3 tools/debugging_loop_hint.py --reset "git pull"
"""
import sys, os, hashlib, json, time, subprocess, shlex

STATE_DIR = os.path.join(os.path.expanduser("~/.cache/dlh"))


def cmd_key(argv):
    return hashlib.md5(" ".join(argv).encode()).hexdigest()


def state_path(key, suffix):
    os.makedirs(STATE_DIR, exist_ok=True)
    return os.path.join(STATE_DIR, f"{key}.{suffix}")


def load_count(key):
    p = state_path(key, "count")
    if os.path.exists(p):
        try:
            return int(open(p).read().strip())
        except Exception:
            return 0
    return 0


def load_err(key):
    p = state_path(key, "err")
    if os.path.exists(p):
        try:
            return open(p).read()
        except Exception:
            return ""
    return ""


def save(key, count, err_text):
    with open(state_path(key, "count"), "w") as f:
        f.write(str(count))
    with open(state_path(key, "err"), "w") as f:
        f.write(err_text)
    with open(state_path(key, "last_ts"), "w") as f:
        f.write(str(int(time.time())))


def load_last_ts(key):
    p = state_path(key, "last_ts")
    if os.path.exists(p):
        try:
            return int(open(p).read().strip())
        except Exception:
            return 0
    return 0


def diagnose(err):
    hints = []
    e = err.lower()
    if "connection" in e and ("refused" in e or "reset" in e or "timed out" in e or "could not connect" in e):
        hints.append("NETWORK: connection refused/reset/timed out")
        hints.append("  - Run: ping <host>  &&  nslookup <host>")
        hints.append("  - Run: curl -v <url>  to see handshake failure point")
        hints.append("  - Check proxy/firewall/WARP/VPN on this host")
    if "dns" in e or "getaddrinfo" in e or "no such host" in e:
        hints.append("DNS: hostname resolution failed")
        hints.append("  - Run: nslookup <host>  or  dig <host>")
    if "permission" in e or "denied" in e or "unauthorized" in e:
        hints.append("AUTH: permission denied or auth failed")
        hints.append("  - Check credentials, API tokens, file permissions")
    if "not found" in e or "no such file" in e:
        hints.append("PATH: file/path not found")
        hints.append("  - Check the path exists; use absolute path; check case sensitivity")
    if "not a git repository" in e or "fatal:" in e and "git" in e:
        hints.append("GIT: check `git remote -v` and `git status`")
    if "out of memory" in e or "oom" in e or "cannot allocate" in e:
        hints.append("MEMORY: OOM — reduce workload or check available RAM")
    if not hints:
        hints.append("UNKNOWN: review the error output above manually")
    return hints


def main():
    args = sys.argv[1:]
    # --reset "cmd"
    if "--reset" in args:
        idx = args.index("--reset")
        if idx + 1 >= len(args):
            print("Usage: debugging_loop_hint.py --reset \"<cmd>\"")
            sys.exit(1)
        cmd = shlex.split(args[idx + 1]) if " " in args[idx + 1] else [args[idx + 1]]
        key = cmd_key(cmd)
        for suffix in ("count", "err", "last_ts"):
            p = state_path(key, suffix)
            if os.path.exists(p):
                os.remove(p)
        print(f"Reset state for: {' '.join(cmd)}")
        return

    # --help
    if "--help" in args or "-h" in args:
        print(__doc__)
        sys.exit(0)

    # Normal: max_failures -- cmd...
    try:
        max_fails = int(args[0])
    except (ValueError, IndexError):
        print("Usage: debugging_loop_hint.py <max_failures:int> -- <cmd>...")
        sys.exit(1)

    if len(args) < 3 or args[1] != "--":
        print("Usage: debugging_loop_hint.py <max_failures:int> -- <cmd>...")
        sys.exit(1)

    cmd = args[2:]
    if not cmd:
        print("Error: no command specified after --")
        sys.exit(1)

    key = cmd_key(cmd)
    count = load_count(key)
    last_ts = load_last_ts(key)
    elapsed = time.time() - last_ts if last_ts else 0

    print(f"[dlh] {len(cmd)} args, max_fails={max_fails}, prior_failures={count}", file=sys.stderr)

    # Check if within 5 seconds of a prior run (likely a re-run loop)
    if count >= max_fails and elapsed < 120:
        err = load_err(key)
        print(file=sys.stderr)
        print(f"╔{'═'*60}╗", file=sys.stderr)
        print(f"║  DEBUGGING LOOP DETECTED — refusing to run again           ║", file=sys.stderr)
        print(f"╠{'═'*60}╣", file=sys.stderr)
        print(f"║  Command: {' '.join(cmd)}", file=sys.stderr)
        print(f"║  Consecutive failures: {count}", file=sys.stderr)
        print(f"║  Seconds since last failure: {elapsed:.0f}", file=sys.stderr)
        print(f"╠{'═'*60}╣", file=sys.stderr)
        print(f"║  Last error:", file=sys.stderr)
        for line in err.strip().split("\n"):
            print(f"║    {line}", file=sys.stderr)
        print(f"╠{'═'*60}╣", file=sys.stderr)
        print(f"║  Diagnosis:", file=sys.stderr)
        for h in diagnose(err):
            print(f"║    {h}", file=sys.stderr)
        print(f"╠{'═'*60}╣", file=sys.stderr)
        print(f"║  To retry (override):", file=sys.stderr)
        print(f"║    {shlex.join(sys.argv[:2])} {max_fails} -- {' '.join(cmd)}", file=sys.stderr)
        print(f"║  To reset state:", file=sys.stderr)
        print(f"║    {shlex.join(sys.argv[:2])} --reset {shlex.quote(' '.join(cmd))}", file=sys.stderr)
        print(f"╚{'═'*60}╝", file=sys.stderr)
        sys.exit(1)

    # Run the command
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    except subprocess.TimeoutExpired:
        msg = "TIMEOUT after 120s"
        save(key, count + 1, msg)
        print(f"[dlh] TIMEOUT ({count+1} failure)", file=sys.stderr)
        print(msg)
        sys.exit(124)
    except Exception as e:
        msg = f"EXCEPTION: {e}"
        save(key, count + 1, msg)
        print(f"[dlh] EXCEPTION ({count+1} failure)", file=sys.stderr)
        print(msg)
        sys.exit(1)

    # Reset counter on success
    save(key, 0, "")

    if result.returncode != 0:
        save(key, count + 1, result.stderr or result.stdout)
        print(f"[dlh] FAILED ({count+1} consecutive failure)", file=sys.stderr)

    # Print original output
    if result.stdout:
        sys.stdout.write(result.stdout)
    if result.stderr:
        sys.stderr.write(result.stderr)

    sys.exit(result.returncode)


if __name__ == "__main__":
    main()