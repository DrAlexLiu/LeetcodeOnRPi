#!/bin/sh
exec google-chrome-stable \
  --ozone-platform=wayland \
  --kiosk \
  --no-first-run \
  --no-default-browser-check \
  "@START_URL@"
