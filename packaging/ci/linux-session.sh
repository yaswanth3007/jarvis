#!/usr/bin/env bash
# What a Linux desktop session provides, for headless tests (CI and the local container):
# an X11 display (Xvfb), a D-Bus session bus, the AT-SPI accessibility bus, and a PulseAudio
# server whose default output is a virtual sink and whose default input listens to it — so a
# recording played by Jarvis's player is what Jarvis's microphone hears.
#   packaging/ci/linux-session.sh <command…>
set -euo pipefail
export DISPLAY=:99 XDG_SESSION_TYPE=x11 XDG_CURRENT_DESKTOP=${XDG_CURRENT_DESKTOP:-XFCE}
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/tmp/runtime-$(id -u)}
mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
Xvfb :99 -screen 0 1280x800x24 -nolisten tcp >/tmp/jarvis-xvfb.log 2>&1 &
for _ in $(seq 50); do xdpyinfo -display :99 >/dev/null 2>&1 && break; sleep 0.1; done
eval "$(dbus-launch --sh-syntax)"
export DBUS_SESSION_BUS_ADDRESS
export NO_AT_BRIDGE=0 GTK_MODULES=gail:atk-bridge
for launcher in /usr/libexec/at-spi-bus-launcher /usr/lib/at-spi2-core/at-spi-bus-launcher; do
  [ -x "$launcher" ] && { "$launcher" --launch-immediately >/tmp/jarvis-atspi.log 2>&1 & break; }
done
# A window manager, so windows can be focused and closed politely (wmctrl needs EWMH).
if command -v openbox >/dev/null; then openbox >/tmp/jarvis-wm.log 2>&1 & fi
if command -v pulseaudio >/dev/null; then
  pulseaudio --start --exit-idle-time=-1 --daemonize=yes >/dev/null 2>&1 || true
  for _ in $(seq 50); do pactl info >/dev/null 2>&1 && break; sleep 0.1; done
  pactl load-module module-null-sink sink_name=jarvis_test sink_properties=device.description=JarvisTest >/dev/null
  pactl set-default-sink jarvis_test
  pactl set-default-source jarvis_test.monitor
fi
sleep 1
exec "$@"
