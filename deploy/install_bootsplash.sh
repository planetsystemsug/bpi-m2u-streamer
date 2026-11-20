#!/bin/bash
set -Eeuo pipefail

APP_DIR="/opt/music-display"
APP="$APP_DIR/music_display.py"
FB_LIB="$APP_DIR/libfbconvert.so"
BOOT_ENV="/boot/armbianEnv.txt"
SPLASH="$APP_DIR/boot_splash.py"
SPLASH_SERVICE="/etc/systemd/system/music-display-boot-splash.service"
DISPLAY_DROPIN="/etc/systemd/system/music-display.service.d/boot-splash.conf"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

trap 'echo "ERROR: Installation failed at line $LINENO (exit $?)."' ERR

# Check prerequisites
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run as root."
    exit 1
fi

for f in "$APP" "$FB_LIB" "$BOOT_ENV"; do
    [[ -f "$f" ]] || { echo "ERROR: Missing $f"; exit 1; }
done

[[ -c /dev/fb0 ]] || { echo "ERROR: /dev/fb0 not available."; exit 1; }

python3 -c 'from PIL import Image, ImageDraw, ImageFont' || {
    echo "ERROR: Python Pillow is unavailable."
    exit 1
}

# Back up existing configuration and application
cp -a "$APP" "$APP.backup-$TIMESTAMP"
cp -a "$BOOT_ENV" "$BOOT_ENV.backup-$TIMESTAMP"

if [[ -f "$SPLASH" ]]; then
    cp -a "$SPLASH" "$SPLASH.backup-$TIMESTAMP"
fi

# Configure boot console: serial only, quiet kernel and systemd
python3 - "$BOOT_ENV" <<'PY'
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    lines = f.readlines()

settings = {
    "verbosity": "0",
    "bootlogo": "false",
    "console": "serial",
}

extra_key = "extraargs"
extra_values = [
    "consoleblank=0",
    "quiet",
    "systemd.show_status=false",
    "udev.log_level=0",
]

result = []
seen = set()
extra = None

for line in lines:
    stripped = line.strip()

    if not stripped or stripped.startswith("#") or "=" not in stripped:
        result.append(line)
        continue

    key, value = stripped.split("=", 1)

    if key == extra_key:
        if extra is None:
            extra = value.split()
        continue

    if key in settings:
        if key not in seen:
            result.append(f"{key}={settings[key]}\n")
            seen.add(key)
        continue

    result.append(line)

for key, value in settings.items():
    if key not in seen:
        result.append(f"{key}={value}\n")

if extra is None:
    extra = []

for value in extra_values:
    if value not in extra:
        extra.append(value)

result.append(f"extraargs={' '.join(extra)}\n")

with open(path, "w", encoding="utf-8") as f:
    f.writelines(result)
PY

# Add idle timeout for stopped and paused playback
python3 - "$APP" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
source = path.read_text()

marker = "# BPI_IDLE_CLEAR_300"
if marker in source:
    print("Idle timeout already installed.")
    raise SystemExit(0)

target = "state = str(snapshot.get('state', 'stop')).lower()"
if source.count(target) != 1:
    raise SystemExit("ERROR: Could not uniquely locate MPD state assignment.")

if not re.search(r"^import time\s*$", source, re.M):
    source = "import time\n" + source

if not re.search(r"^from PIL import .*\\bImage\\b", source, re.M):
    source = "from PIL import Image\n" + source

block = '''state = str(snapshot.get('state', 'stop')).lower()
        # BPI_IDLE_CLEAR_300
        if not hasattr(main, "_idle_since"):
            main._idle_since = None
            main._idle_screen_cleared = False

        idle_clear_seconds = max(0.0, float(cfg.get("idle_clear_seconds", 300)))

        if state in ("stop", "pause"):
            if main._idle_since is None:
                main._idle_since = time.monotonic()
                main._idle_screen_cleared = False

            if (
                idle_clear_seconds > 0
                and not main._idle_screen_cleared
                and time.monotonic() - main._idle_since >= idle_clear_seconds
            ):
                fb.show(Image.new("RGB", (WIDTH, HEIGHT), "#000000"))
                main._idle_screen_cleared = True
                print("Display cleared after idle timeout", flush=True)
        else:
            main._idle_since = None
            main._idle_screen_cleared = False'''

source = source.replace(target, block, 1)

compile(source, str(path), "exec")
path.write_text(source)
print("Installed 300-second stop/pause idle timeout.")
PY

# Create graphical boot splash
cat > "$SPLASH" <<'PY'
#!/usr/bin/python3
import sys
import math
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, "/opt/music-display")
from music_display import Framebuffer

WIDTH, HEIGHT = 480, 320

def font(size):
    for path in (
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    ):
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            pass
    return ImageFont.load_default()

image = Image.new("RGB", (WIDTH, HEIGHT))
pixels = image.load()

# Background gradient
for y in range(HEIGHT):
    for x in range(WIDTH):
        factor = y / HEIGHT
        pixels[x, y] = (
            int(5 + factor * 5),
            int(15 + factor * 15),
            int(30 + factor * 25),
        )

draw = ImageDraw.Draw(image)

# Decorative circles
draw.ellipse((355, -100, 620, 165), outline=(15, 65, 90), width=2)
draw.ellipse((380, -75, 595, 140), outline=(15, 65, 90), width=1)
draw.ellipse((-150, 210, 120, 480), outline=(15, 65, 90), width=2)

# Audio waveform
points = []
for x in range(40, 440):
    amplitude = (
        13 * math.sin(x * 0.045)
        + 7 * math.sin(x * 0.13)
        + 4 * math.sin(x * 0.27)
    )
    points.append((x, 105 + amplitude))

draw.line(points, fill=(0, 190, 175), width=3)

# Logo / typography
draw.text((40, 145), "BPi M2U", font=font(37), fill=(235, 245, 255))
draw.text((42, 190), "STREAMER", font=font(25), fill=(0, 205, 180))
draw.text((42, 244), "NETWORK AUDIO PLAYER",
          font=font(14), fill=(145, 170, 190))
draw.text((42, 278), "INITIALIZING",
          font=font(12), fill=(0, 190, 175))

fb = Framebuffer("/dev/fb0")
try:
    fb.show(image)
finally:
    fb.close()

print("Boot splash displayed.", flush=True)
PY

chmod 755 "$SPLASH"

# Install splash systemd service
cat > "$SPLASH_SERVICE" <<'UNIT'
[Unit]
Description=BPi M2U Streamer Boot Splash
After=local-fs.target
Before=music-display.service

[Service]
Type=oneshot
ExecStartPre=/bin/sh -c 'for i in $(seq 1 100); do [ -c /dev/fb0 ] && exit 0; sleep 0.1; done; echo "Framebuffer unavailable" >&2; exit 1'
ExecStart=/usr/bin/python3 /opt/music-display/boot_splash.py
TimeoutStartSec=15
StandardOutput=journal
StandardError=journal
UNIT

# Ensure splash runs before the music display
mkdir -p "$(dirname "$DISPLAY_DROPIN")"

cat > "$DISPLAY_DROPIN" <<'UNIT'
[Unit]
Wants=music-display-boot-splash.service
After=music-display-boot-splash.service
UNIT

# Validate Python and systemd configuration
python3 -m py_compile "$APP" "$SPLASH"
systemd-analyze verify "$SPLASH_SERVICE" 2>&1

# Reload systemd without interrupting playback
systemctl daemon-reload

# Display configuration summary
echo
echo "===== INSTALLATION COMPLETE ====="
echo "Idle timeout:       300 seconds (stop + pause)"
echo "Boot splash:        $SPLASH"
echo "Splash service:     $SPLASH_SERVICE"
echo "Console:            serial only"
echo "Kernel verbosity:   0"
echo "Systemd status:     suppressed"
echo "Udev logging:       suppressed"
echo "Backups:            *backup-$TIMESTAMP"
echo
echo "A reboot is required to activate the boot configuration and splash."
echo "The running music-display service was not restarted."
echo "STATUS: SUCCESS"
