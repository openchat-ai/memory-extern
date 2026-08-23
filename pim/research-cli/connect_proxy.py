import socket
import threading

LISTEN = ("127.0.0.1", 8899)
TARGET = ("github.com", 443)


def connect_target():
    last = None
    for _ in range(10):
        try:
            return socket.create_connection(TARGET, timeout=10)
        except OSError as e:
            last = e
    raise last


def relay(a, b):
    try:
        while True:
            d = a.recv(65536)
            if not d:
                break
            b.sendall(d)
    except OSError:
        pass
    try:
        b.shutdown(socket.SHUT_WR)
    except OSError:
        pass


def handle(c):
    req = b""
    while b"\r\n\r\n" not in req:
        d = c.recv(65536)
        if not d:
            c.close()
            return
        req += d
    try:
        t = connect_target()
    except OSError:
        c.sendall(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
        c.close()
        return
    c.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
    threading.Thread(target=relay, args=(c, t), daemon=True).start()
    relay(t, c)
    c.close()
    t.close()


def main():
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(LISTEN)
    srv.listen(16)
    print("connect-proxy ready on 127.0.0.1:8899", flush=True)
    while True:
        c, _ = srv.accept()
        threading.Thread(target=handle, args=(c,), daemon=True).start()


if __name__ == "__main__":
    main()