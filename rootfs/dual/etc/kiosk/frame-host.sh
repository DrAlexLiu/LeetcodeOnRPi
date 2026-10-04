#!/bin/sh
# Ubuntu Frame display host for the dual-screen kiosk.
#
# ACL model (deliberately minimal): connecting to a unix socket needs only
# search (x) on the directory path plus rw on the socket itself. We do NOT
# grant w on /run/user/@FRAME_UID@ -- with write permission a client could create,
# delete or replace wayland-0 inside the compositor's own runtime dir, which
# would contradict the "leetcode and coder are equal, powerless clients"
# design. The default ACL supplies rw to whatever socket Frame creates.
#
# ACL is applied in a loop after the socket appears because Frame sometimes
# recreates the socket, and because the mask must be set explicitly: without
# an explicit `m::`, getfacl shows `user:leetcode:rw- #effective:---` and the
# clients fail with EACCES while the declared permissions still look correct.
setfacl -m u:leetcode:x,u:coder:x,m::rx /run/user/@FRAME_UID@
setfacl -d -m u:leetcode:rw,u:coder:rw,m::rw /run/user/@FRAME_UID@
/snap/bin/ubuntu-frame --vt-switching=0 >>/var/log/kiosk/frame.log 2>&1 &
FRAME_PID=$!
for i in $(seq 1 60); do
  [ -S "/run/user/@FRAME_UID@/wayland-0" ] && break
  sleep 0.5
done
for attempt in 1 2 3 4 5; do
  setfacl -m u:leetcode:rw,u:coder:rw,m::rw /run/user/@FRAME_UID@/wayland-0 2>/dev/null
  sleep 1
done
wait "$FRAME_PID"
