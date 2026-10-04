import socket, sys, time
path = '/run/user/@FRAME_UID@/wayland-0'
for _ in range(60):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.connect(path)
        s.close()
        sys.exit(0)
    except Exception:
        s.close()
        time.sleep(0.5)
sys.exit(1)
