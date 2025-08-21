import socket

PORT = 9001
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind(("0.0.0.0", PORT))
print(f"listening on 0.0.0.0:{PORT}")

while True:
    data, addr = sock.recvfrom(65535)
    try:
        msg = data.decode("utf-8", errors="ignore")
    except Exception:
        msg = f"<{len(data)} bytes>"
    print(f"{addr}  {msg}")
