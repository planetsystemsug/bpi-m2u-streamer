#!/bin/bash
set -Eeuo pipefail

# BPi M2 Ultra music-display deployment / restore
# Run: sudo bash deploy_music_display.sh
# This script does NOT modify the device tree, SPI, GPIO, overlays or kernel modules.

if [[ $EUID -ne 0 ]]; then
    echo "Run as root: sudo bash $0" >&2
    exit 1
fi

FB=/sys/class/graphics/fb0
APP=/opt/music-display/music_display.py
SRC=/opt/music-display/rgb565.c
LIB=/opt/music-display/libfbconvert.so
CFG=/etc/music-display/config.json
SERVICE=/etc/systemd/system/music-display.service
SERVICE_DROPIN_DIR=/etc/systemd/system/music-display.service.d
CURSOR_DROPIN=/etc/systemd/system/music-display.service.d/disable-console-cursor.conf
CURSOR_SYSFS=/sys/class/graphics/fbcon/cursor_blink
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="/var/backups/music-display-${STAMP}"
WAS_ENABLED=0
WAS_ACTIVE=0
if systemctl is-enabled --quiet music-display.service 2>/dev/null; then WAS_ENABLED=1; fi
if systemctl is-active --quiet music-display.service 2>/dev/null; then WAS_ACTIVE=1; fi

# Validate the already-configured framebuffer. Hardware setup is intentionally untouched.
if [[ ! -r "$FB/virtual_size" || ! -r "$FB/bits_per_pixel" ]]; then
    echo "Framebuffer fb0 not found. Install/configure the working FBTFT driver first." >&2
    exit 1
fi
if [[ "$(cat "$FB/virtual_size")" != "480,320" ]]; then
    echo "Expected fb0 480,320; found $(cat "$FB/virtual_size"). Not installing." >&2
    exit 1
fi
if [[ "$(cat "$FB/bits_per_pixel")" != "16" ]]; then
    echo "Expected 16 bpp; found $(cat "$FB/bits_per_pixel"). Not installing." >&2
    exit 1
fi
FB_NAME=$(cat "$FB/name" 2>/dev/null || true)
if [[ "$FB_NAME" != "fb_ili9486" ]]; then
    echo "Expected fb_ili9486; found '${FB_NAME:-unknown}'. Not installing." >&2
    exit 1
fi
if [[ ! -c /dev/fb0 ]]; then
    echo "/dev/fb0 is not a character device." >&2
    exit 1
fi

# Preserve existing installation files before replacing them.
mkdir -p "$BACKUP_DIR"
for path in "$APP" "$SRC" "$LIB" "$CFG" "$SERVICE" "$CURSOR_DROPIN"; do
    if [[ -e "$path" ]]; then
        mkdir -p "$BACKUP_DIR$(dirname "$path")"
        cp -a "$path" "$BACKUP_DIR$path"
    fi
done

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends python3 python3-pil python3-qrcode fonts-dejavu-core gcc libc6-dev

getent group music-display >/dev/null || groupadd --system music-display
install -d -m 0755 /opt/music-display /etc/music-display
install -d -o root -g music-display -m 2775 /var/lib/music-display
install -d -o root -g root -m 0755 /var/cache/music-display

# Build the native RGB888 -> framebuffer pixel converter.
cat > "$SRC" <<'C'
typedef unsigned char u8;
typedef unsigned int u32;

static u32 reverse_bits(u32 value, u32 bits) {
    u32 result = 0, i;
    for (i = 0; i < bits; ++i) {
        result = (result << 1) | (value & 1U);
        value >>= 1;
    }
    return result;
}

static u32 component(u8 value, u32 length, u32 msb_right) {
    u32 maximum, scaled;
    if (length == 0) return 0;
    maximum = (1U << length) - 1U;
    scaled = ((u32)value * maximum + 127U) / 255U;
    return msb_right ? reverse_bits(scaled, length) : scaled;
}

void rgb888_to_fb(const u8 *src, u8 *dst, int width, int height, int stride,
                  u32 ro, u32 rl, u32 rr,
                  u32 go, u32 gl, u32 gr,
                  u32 bo, u32 bl, u32 br) {
    int x, y;
    for (y = 0; y < height; ++y) {
        const u8 *s = src + (y * width * 3);
        u8 *d = dst + (y * stride);
        for (x = 0; x < width; ++x) {
            u32 pixel = (component(s[x * 3], rl, rr) << ro) |
                        (component(s[x * 3 + 1], gl, gr) << go) |
                        (component(s[x * 3 + 2], bl, br) << bo);
            d[x * 2] = (u8)(pixel & 0xffU);
            d[x * 2 + 1] = (u8)((pixel >> 8) & 0xffU);
        }
    }
}
C

gcc -shared -fPIC -O3 -Wl,-z,noexecstack -o "$LIB" "$SRC"
chmod 0644 "$SRC" "$LIB"

# Install the complete display application.
cat > "$APP" <<'PYAPP'
#!/usr/bin/python3
import ctypes
import errno
import fcntl
import hashlib
import io
import json
import os
import queue
import signal
import socket
import struct
import subprocess
import sys
import threading
import time
import urllib.request
from array import array
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageOps

CONFIG_PATH = Path('/etc/music-display/config.json')
STATE_PATH = Path('/var/lib/music-display/spotify.json')
CACHE_DIR = Path('/var/cache/music-display')
SOLOIST_DATA_DIR = '/var/lib/soloist'   # same data dir as soloist.service / streamer-soloist-event
WIDTH, HEIGHT = 480, 320
FBIOGET_VSCREENINFO = 0x4600
FBIOGET_FSCREENINFO = 0x4602
FBIOBLANK = 0x4611


class FbBitfield(ctypes.Structure):
    _fields_ = [('offset', ctypes.c_uint32),
                ('length', ctypes.c_uint32),
                ('msb_right', ctypes.c_uint32)]


class FbVarScreeninfo(ctypes.Structure):
    _fields_ = [
        ('xres', ctypes.c_uint32), ('yres', ctypes.c_uint32),
        ('xres_virtual', ctypes.c_uint32), ('yres_virtual', ctypes.c_uint32),
        ('xoffset', ctypes.c_uint32), ('yoffset', ctypes.c_uint32),
        ('bits_per_pixel', ctypes.c_uint32), ('grayscale', ctypes.c_uint32),
        ('red', FbBitfield), ('green', FbBitfield),
        ('blue', FbBitfield), ('transp', FbBitfield),
        ('nonstd', ctypes.c_uint32), ('activate', ctypes.c_uint32),
        ('height', ctypes.c_uint32), ('width', ctypes.c_uint32),
        ('accel_flags', ctypes.c_uint32), ('pixclock', ctypes.c_uint32),
        ('left_margin', ctypes.c_uint32), ('right_margin', ctypes.c_uint32),
        ('upper_margin', ctypes.c_uint32), ('lower_margin', ctypes.c_uint32),
        ('hsync_len', ctypes.c_uint32), ('vsync_len', ctypes.c_uint32),
        ('sync', ctypes.c_uint32), ('vmode', ctypes.c_uint32),
        ('rotate', ctypes.c_uint32), ('colorspace', ctypes.c_uint32),
        ('reserved', ctypes.c_uint32 * 4),
    ]


class FbFixScreeninfo(ctypes.Structure):
    _fields_ = [
        ('id', ctypes.c_char * 16),
        ('smem_start', ctypes.c_ulong), ('smem_len', ctypes.c_uint32),
        ('type', ctypes.c_uint32), ('type_aux', ctypes.c_uint32),
        ('visual', ctypes.c_uint32),
        ('xpanstep', ctypes.c_uint16), ('ypanstep', ctypes.c_uint16),
        ('ywrapstep', ctypes.c_uint16), ('line_length', ctypes.c_uint32),
        ('mmio_start', ctypes.c_ulong), ('mmio_len', ctypes.c_uint32),
        ('accel', ctypes.c_uint32), ('capabilities', ctypes.c_uint16),
        ('reserved', ctypes.c_uint16 * 2),
    ]


def ioctl_struct(fd, request, cls):
    raw = bytearray(ctypes.sizeof(cls))
    fcntl.ioctl(fd, request, raw, True)
    return cls.from_buffer_copy(raw)


class Framebuffer:
    def __init__(self, path='/dev/fb0'):
        self.fd = os.open(path, os.O_RDWR | os.O_CLOEXEC)
        self.var = ioctl_struct(self.fd, FBIOGET_VSCREENINFO, FbVarScreeninfo)
        self.fix = ioctl_struct(self.fd, FBIOGET_FSCREENINFO, FbFixScreeninfo)
        self.flip = bool(read_config().get('flip', False))   # False = the panel's mounting rotation (180)
        self.width = int(self.var.xres)
        self.height = int(self.var.yres)
        self.bpp = int(self.var.bits_per_pixel)
        self.stride = int(self.fix.line_length)
        if (self.width, self.height) != (WIDTH, HEIGHT):
            raise RuntimeError(
                f'Expected framebuffer {WIDTH}x{HEIGHT}, got {self.width}x{self.height}. '
                'Check the FBTFT rotate property and reboot.'
            )
        if self.bpp != 16:
            raise RuntimeError(f'Expected 16 bpp RGB565 framebuffer, got {self.bpp} bpp')
        if self.stride < self.width * 2:
            raise RuntimeError(f'Invalid framebuffer line_length: {self.stride}')
        if not (self.var.red.length and self.var.green.length and self.var.blue.length):
            raise RuntimeError('Framebuffer RGB bitfields are not available')
        self._converter_lib = ctypes.CDLL('/opt/music-display/libfbconvert.so')
        self._convert_rgb565 = self._converter_lib.rgb888_to_fb
        self._convert_rgb565.argtypes = [
            ctypes.c_void_p, ctypes.c_void_p,
            ctypes.c_int, ctypes.c_int, ctypes.c_int,
            *([ctypes.c_uint] * 9),
        ]
        self._convert_rgb565.restype = None
        try:
            fcntl.ioctl(self.fd, FBIOBLANK, struct.pack('i', 0))
        except OSError as exc:
            if exc.errno not in (errno.EINVAL, errno.ENOTTY):
                raise
            print(f'Framebuffer blank ioctl unsupported; continuing: {exc}', file=sys.stderr, flush=True)

    @staticmethod
    def _component(value, field):
        length = int(field.length)
        maximum = (1 << length) - 1
        scaled = (value * maximum + 127) // 255
        if field.msb_right:
            bits = f'{scaled:0{length}b}'
            scaled = int(bits[::-1], 2)
        return scaled << int(field.offset)

    def show(self, image):
        image = image.convert('RGB')
        if not self.flip:
            image = image.transpose(Image.Transpose.ROTATE_180)
        if image.size != (self.width, self.height):
            image = image.resize((self.width, self.height), Image.Resampling.LANCZOS)
        source = image.tobytes()
        frame = bytearray(self.stride * self.height)
        source_ptr = ctypes.cast(ctypes.c_char_p(source), ctypes.c_void_p)
        destination = (ctypes.c_ubyte * len(frame)).from_buffer(frame)
        self._convert_rgb565(
            source_ptr, ctypes.cast(destination, ctypes.c_void_p),
            self.width, self.height, self.stride,
            self.var.red.offset, self.var.red.length, self.var.red.msb_right,
            self.var.green.offset, self.var.green.length, self.var.green.msb_right,
            self.var.blue.offset, self.var.blue.length, self.var.blue.msb_right,
        )
        os.lseek(self.fd, 0, os.SEEK_SET)
        view = memoryview(frame)
        while view:
            written = os.write(self.fd, view)
            if written <= 0:
                raise OSError('Short write to framebuffer')
            view = view[written:]

    def close(self):
        if getattr(self, 'fd', None) is not None:
            os.close(self.fd)
            self.fd = None


def read_config():
    defaults = {
        'source': 'auto',
        'poll_seconds': 1.0,
        'mpd': {'host': '127.0.0.1', 'port': 6600, 'password': ''},
        'spotify_state': str(STATE_PATH),
    }
    try:
        user = json.loads(CONFIG_PATH.read_text())
        defaults.update(user)
        defaults['mpd'] = {**defaults['mpd'], **user.get('mpd', {})}
    except FileNotFoundError:
        pass
    except Exception as exc:
        print(f'Config read error: {exc}', file=sys.stderr)
    return defaults


def mpd_open(cfg):
    mpd = cfg['mpd']
    sock = socket.create_connection((mpd.get('host', '127.0.0.1'), int(mpd.get('port', 6600))), timeout=1.5)
    sock.settimeout(1.5)
    reader = sock.makefile('rb')
    greeting = reader.readline()
    if not greeting.startswith(b'OK MPD'):
        reader.close()
        sock.close()
        raise RuntimeError('Invalid MPD greeting')
    password = mpd.get('password') or ''
    if password:
        escaped = str(password).replace('\\', '\\\\').replace('"', '\\"')
        sock.sendall(f'password "{escaped}"\n'.encode('utf-8'))
        response = mpd_read_lines(reader)
        if response and response[0].startswith('ACK'):
            reader.close()
            sock.close()
            raise RuntimeError('MPD authentication failed')
    return sock, reader


def mpd_read_lines(reader):
    result = []
    while True:
        line = reader.readline()
        if not line:
            raise ConnectionError('MPD disconnected')
        text = line.decode('utf-8', 'replace').rstrip('\r\n')
        if text == 'OK' or text.startswith('ACK'):
            if text.startswith('ACK'):
                result.append(text)
            return result
        result.append(text)


def mpd_pairs(lines):
    result = {}
    for line in lines:
        if ': ' not in line:
            continue
        key, value = line.split(': ', 1)
        result.setdefault(key, []).append(value)
    return result


def mpd_snapshot(cfg):
    sock, reader = mpd_open(cfg)
    try:
        sock.sendall(b'status\n')
        status_lines = mpd_read_lines(reader)
        sock.sendall(b'currentsong\n')
        song_lines = mpd_read_lines(reader)
    finally:
        reader.close()
        sock.close()
    status = mpd_pairs(status_lines)
    song = mpd_pairs(song_lines)
    get = lambda data, key, default='': (data.get(key) or [default])[0]
    state = get(status, 'state', 'stop').lower()
    elapsed = float(get(status, 'elapsed', '0') or 0)
    duration = float(get(status, 'duration', get(song, 'duration', '0')) or 0)
    file_name = get(song, 'file')
    title = get(song, 'Title') or get(song, 'Name')
    if not title and file_name:
        title = Path(file_name).name
    artist = ', '.join(song.get('Artist', []) or song.get('AlbumArtist', []))
    album = get(song, 'Album')
    key = file_name or get(song, 'Id') or f'{title}|{artist}|{album}'
    return {
        'source': 'MPD', 'state': state, 'title': title or 'Unknown track',
        'artist': artist, 'album': album, 'duration': max(0.0, duration),
        'position': max(0.0, elapsed), 'file': file_name, 'track_key': 'mpd:' + key,
        'art_urls': [], 'updated': time.time(),
    }


def mpd_binary_chunk(cfg, command, file_name, offset):
    sock, reader = mpd_open(cfg)
    try:
        escaped = file_name.replace('\\', '\\\\').replace('"', '\\"')
        sock.sendall(f'{command} "{escaped}" {offset}\n'.encode('utf-8'))
        headers, chunks = {}, []
        while True:
            line = reader.readline()
            if not line:
                raise ConnectionError('MPD disconnected during artwork transfer')
            text = line.decode('utf-8', 'replace').rstrip('\r\n')
            if text == 'OK':
                break
            if text.startswith('ACK'):
                raise RuntimeError(text)
            if text.startswith('binary: '):
                count = int(text.split(': ', 1)[1])
                data = reader.read(count)
                if len(data) != count:
                    raise ConnectionError('Incomplete MPD artwork chunk')
                chunks.append(data)
                reader.readline()  # newline following the binary block
            elif ': ' in text:
                key, value = text.split(': ', 1)
                headers[key] = value
        return headers, b''.join(chunks)
    finally:
        reader.close()
        sock.close()


def mpd_artwork(cfg, file_name):
    if not file_name:
        return None
    for command in ('albumart', 'readpicture'):
        try:
            offset, total, output = 0, None, bytearray()
            for _ in range(256):
                headers, data = mpd_binary_chunk(cfg, command, file_name, offset)
                if total is None:
                    total = int(headers.get('size', '0') or 0)
                if not data:
                    break
                output.extend(data)
                offset += len(data)
                if total and offset >= total:
                    return bytes(output[:total])
                if offset > 8 * 1024 * 1024:
                    break
            if output and (not total or len(output) >= total):
                return bytes(output[:total] if total else output)
        except Exception:
            continue
    return None


def read_spotify_state(path):
    try:
        state = json.loads(Path(path).read_text())
        if time.time() - float(state.get('updated', 0)) > 6 * 3600:
            return None
        state.setdefault('source', 'Spotify')
        state.setdefault('state', 'stop')
        state.setdefault('position', 0)
        state.setdefault('duration', 0)
        state.setdefault('art_urls', [])
        state['track_key'] = 'spotify:' + str(state.get('track_id') or (
            state.get('title', '') + '|' + state.get('artist', '') + '|' + state.get('album', '')
        ))
        if state.get('state') == 'play':
            state['position'] = float(state.get('position', 0)) + max(0, time.time() - float(state.get('updated', time.time())))
        return state
    except Exception:
        return None


def select_snapshot(cfg):
    source = str(cfg.get('source', 'auto')).lower()
    mpd = None
    if source in ('auto', 'mpd'):
        try:
            mpd = mpd_snapshot(cfg)
        except Exception:
            pass
    if source == 'mpd':
        return mpd or idle_snapshot()
    if source in ('auto', 'librespot', 'spotify'):
        # 'librespot_state' is the pre-Soloist config key; still honoured.
        spotify = read_spotify_state(cfg.get('spotify_state') or cfg.get('librespot_state') or str(STATE_PATH))
        if source != 'auto':
            return spotify or idle_snapshot()
        if spotify and spotify.get('state') == 'play':
            return spotify
        if mpd and mpd.get('state') == 'play':
            return mpd
        if spotify and spotify.get('state') in ('play', 'pause'):
            return spotify
        return mpd or spotify or idle_snapshot()
    return idle_snapshot()


def idle_snapshot():
    return {'source': '', 'state': 'stop', 'title': '', 'artist': '', 'album': '',
            'duration': 0, 'position': 0, 'file': '', 'track_key': 'idle', 'art_urls': []}


def download_art(url):
    if not isinstance(url, str) or not url.startswith(('http://', 'https://')):
        return None
    try:
        req = urllib.request.Request(url, headers={'User-Agent': 'MusicDisplay/1.0'})
        with urllib.request.urlopen(req, timeout=5) as response:
            data = response.read(8 * 1024 * 1024 + 1)
        if len(data) > 8 * 1024 * 1024:
            return None
        return data
    except Exception:
        return None


def load_art(snapshot, cfg):
    key = str(snapshot.get('track_key') or 'unknown')
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    cache = CACHE_DIR / (hashlib.sha256(key.encode('utf-8', 'replace')).hexdigest() + '.img')
    try:
        if cache.is_file() and cache.stat().st_size > 0:
            return Image.open(cache).convert('RGB')
    except Exception:
        try:
            cache.unlink()
        except OSError:
            pass
    data = None
    if snapshot.get('source') == 'MPD' and snapshot.get('file'):
        data = mpd_artwork(cfg, snapshot['file'])
    else:
        for url in snapshot.get('art_urls', []):
            data = download_art(url)
            if data:
                break
    if not data:
        return None
    try:
        image = Image.open(io.BytesIO(data)).convert('RGB')
        image.thumbnail((1000, 1000), Image.Resampling.LANCZOS)
        image.save(cache, format='JPEG', quality=90)
        return image
    except Exception:
        return None


def font(path, size):
    try:
        return ImageFont.truetype(path, size)
    except Exception:
        return ImageFont.load_default()


FONT_REG = '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf'
FONT_BOLD = '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf'


def wrap_lines(draw, text, fnt, max_width, max_lines=2):
    text = str(text or '').strip()
    if not text:
        return []
    words = text.split()
    lines, current = [], ''
    for word in words:
        candidate = (current + ' ' + word).strip()
        if draw.textbbox((0, 0), candidate, font=fnt)[2] <= max_width:
            current = candidate
        else:
            if current:
                lines.append(current)
            current = word
            if len(lines) >= max_lines:
                break
    if current and len(lines) < max_lines:
        lines.append(current)
    if lines:
        original = ' '.join(words)
        shown = ' '.join(lines)
        if shown != original:
            line = lines[-1]
            while line and draw.textbbox((0, 0), line + '…', font=fnt)[2] > max_width:
                line = line[:-1]
            lines[-1] = line.rstrip() + '…'
    return lines


def placeholder_art(size=190):
    im = Image.new('RGB', (size, size), '#152235')
    d = ImageDraw.Draw(im)
    d.ellipse((20, 20, size - 20, size - 20), fill='#1E3549', outline='#315B68', width=2)
    bars = [24, 48, 78, 55, 90, 63, 38]
    x0 = (size - (len(bars) * 13 + (len(bars) - 1) * 7)) // 2
    for i, h in enumerate(bars):
        x = x0 + i * 20
        y = (size - h) // 2
        d.rounded_rectangle((x, y, x + 12, y + h), radius=5, fill='#72C6B2')
    return im


# --- Touch play/pause button -------------------------------------------------
BTN_CX, BTN_CY, BTN_R = 436, 244, 22          # right side, above the timeline
BTN_HIT = 34                                  # generous touch target (px radius)
wake = threading.Event()
tap_event = threading.Event()                 # any touch: wake the idle screen
touch_state = {'visible': False, 'menu': False, 'source': '', 'state': 'stop'}


def toggle_playback(cfg):
    source = str(touch_state['source']).lower()
    playing = touch_state['state'] == 'play'
    print(f'Button tap: source={source or "none"} state={touch_state["state"]}', flush=True)
    try:
        if source == 'mpd':
            sock, reader = mpd_open(cfg)
            try:
                cmd = {'play': b'pause 1\n', 'pause': b'pause 0\n'}.get(touch_state['state'], b'play\n')
                sock.sendall(cmd)
                reply = mpd_read_lines(reader)
                print(f'MPD {cmd.decode().strip()}: {reply}', flush=True)
            finally:
                sock.close()
        elif source:
            action = 'pause' if playing else 'play'
            result = subprocess.run(['/usr/local/bin/soloist', 'ctl', '-D', SOLOIST_DATA_DIR, action],
                                    timeout=8, check=False, capture_output=True, text=True)
            print(f'soloist ctl {action}: rc={result.returncode} '
                  f'{(result.stdout + result.stderr).strip()[:120]}', flush=True)
        else:
            print('Button tap ignored: no active source', flush=True)
    except Exception as exc:
        print(f'Play/pause failed: {exc}', flush=True)
    wake.set()


def _ioc(direction, nr, size):
    return (direction << 30) | (size << 16) | (0xB4 << 8) | nr


GPIO_GET_LINEHANDLE = _ioc(3, 3, 364)
GPIOHANDLE_GET_VALUES = _ioc(3, 8, 64)
GPIOHANDLE_SET_VALUES = _ioc(3, 9, 64)
SPI_IOC_WR_MODE = 0x40016B01
SPI_IOC_WR_MAX_SPEED = 0x40046B04
SPI_IOC_MESSAGE_1 = 0x40206B00


class TouchPanel:
    """XPT2046/ADS7846 on /dev/spidev0.1, chip select and pen IRQ as plain GPIOs.

    The kernel ads7846 driver cannot be used: the pen IRQ (PI20, header pin 11)
    has no interrupt function on this SoC, so the pen line is polled."""

    def __init__(self, tcfg):
        self.chip = os.open(tcfg.get('gpiochip', '/dev/gpiochip0'), os.O_RDWR | os.O_CLOEXEC)
        self.cs = self._handle(int(tcfg.get('cs_line', 248)), 0x2, 1)    # PH24, output, idle high
        self.pen = self._handle(int(tcfg.get('pen_line', 276)), 0x1)     # PI20, input
        self.spi = os.open(tcfg.get('spidev', '/dev/spidev0.1'), os.O_RDWR | os.O_CLOEXEC)
        fcntl.ioctl(self.spi, SPI_IOC_WR_MODE, struct.pack('B', 0))
        fcntl.ioctl(self.spi, SPI_IOC_WR_MAX_SPEED, struct.pack('I', 2000000))
        self._tx = ctypes.create_string_buffer(3)
        self._rx = ctypes.create_string_buffer(3)
        self._msg = struct.pack('<QQIIHBBBBH', ctypes.addressof(self._tx), ctypes.addressof(self._rx),
                                3, 2000000, 0, 8, 0, 0, 0, 0)

    def _handle(self, line, flags, default=0):
        req = (struct.pack('<64I', line, *([0] * 63)) + struct.pack('<I', flags)
               + bytes([default]) + bytes(63) + b'music-display'.ljust(32, b'\0')
               + struct.pack('<I', 1) + struct.pack('<i', 0))
        buf = bytearray(req)
        fcntl.ioctl(self.chip, GPIO_GET_LINEHANDLE, buf, True)
        return struct.unpack_from('<i', buf, 360)[0]

    def pen_down(self):
        buf = bytearray(64)
        fcntl.ioctl(self.pen, GPIOHANDLE_GET_VALUES, buf, True)
        return buf[0] == 0                       # pen IRQ is active low

    def _read(self, command):
        self._tx.raw = bytes([command, 0, 0])
        fcntl.ioctl(self.cs, GPIOHANDLE_SET_VALUES, bytearray(64), True)           # CS low
        try:
            fcntl.ioctl(self.spi, SPI_IOC_MESSAGE_1, self._msg)
        finally:
            fcntl.ioctl(self.cs, GPIOHANDLE_SET_VALUES, bytearray([1]) + bytearray(63), True)
        return (((self._rx.raw[1] << 8) | self._rx.raw[2]) >> 3) & 0xFFF

    def sample(self):
        """One settled (x, y) raw reading, median of a few conversions."""
        xs, ys = [], []
        self._read(0xD0)                         # discard: channel settling
        for _ in range(5):
            xs.append(self._read(0xD0))
            ys.append(self._read(0x90))
        xs.sort()
        ys.sort()
        return xs[2], ys[2]


def touch_thread(cfg):
    """Poll the touch panel and fire a tap on the button when the finger lifts."""
    tcfg = cfg.get('touch', {})
    if not tcfg.get('enabled', True):
        return
    swap = bool(tcfg.get('swap_xy', True))
    inv_x, inv_y = bool(tcfg.get('invert_x', False)), bool(tcfg.get('invert_y', False))
    x_min, x_max = float(tcfg.get('x_min', 0)), float(tcfg.get('x_max', 4095))
    y_min, y_max = float(tcfg.get('y_min', 0)), float(tcfg.get('y_max', 4095))
    debug = bool(tcfg.get('debug'))
    flip = bool(cfg.get('flip', False))
    while True:
        try:
            panel = TouchPanel(tcfg)
            print('Touch panel ready (spidev, polled pen IRQ)', flush=True)
            last = None
            down_samples = 0
            while True:
                if panel.pen_down():
                    raw = panel.sample()
                    if panel.pen_down():             # still down: reading is valid
                        last = raw
                        down_samples += 1
                    time.sleep(0.01)
                    continue
                if last is not None and down_samples >= 2:
                    rx, ry = last
                    if swap:
                        rx, ry = ry, rx
                        lo_x, hi_x, lo_y, hi_y = y_min, y_max, x_min, x_max
                    else:
                        lo_x, hi_x, lo_y, hi_y = x_min, x_max, y_min, y_max
                    fx = min(1.0, max(0.0, (rx - lo_x) / (hi_x - lo_x)))
                    fy = min(1.0, max(0.0, (ry - lo_y) / (hi_y - lo_y)))
                    px = (1 - fx if inv_x else fx) * WIDTH
                    py = (1 - fy if inv_y else fy) * HEIGHT
                    if flip:                         # picture rotated by 180: the touch plane follows
                        px, py = WIDTH - px, HEIGHT - py
                    if debug:
                        print(f'Touch raw={last} -> {px:.0f},{py:.0f}', flush=True)
                    tap_event.set()
                    if touch_state['menu']:
                        ui_events.put(('tap', px, py))
                        wake.set()
                    elif touch_state['visible'] and px < MENU_HIT_W and py < MENU_HIT_H:
                        ui_events.put(('open',))
                        wake.set()
                    elif (touch_state['visible'] and abs(px - BTN_CX) <= BTN_HIT
                            and abs(py - BTN_CY) <= BTN_HIT):
                        toggle_playback(cfg)
                last, down_samples = None, 0
                time.sleep(0.03)
        except Exception as exc:
            print(f'Touch reader error: {exc}', flush=True)
        time.sleep(10)


# --- Setup menu (touch + IR remote) -------------------------------------------
# Opened by a tap on the header (left) or the remote's "menu" key. Everything it
# does goes through /usr/local/bin/streamer-config, the same code the web UI uses.
CTL_SOCKET = '/run/music-display.sock'        # streamer-ir sends menu keys here
MENU_FLAG = '/run/music-display-menu'         # exists while the menu is open (streamer-ir looks at it)
STREAMER_CONFIG = '/usr/local/bin/streamer-config'
MENU_TIMEOUT = 90.0                           # close after this long without input
MENU_HIT_W, MENU_HIT_H = 200, 44              # tap area in the header that opens the menu
ui_events = queue.Queue()


def ctl_thread():
    """Receive menu keys (up/down/ok/back/close/open) from streamer-ir."""
    while True:
        try:
            try:
                os.unlink(CTL_SOCKET)
            except FileNotFoundError:
                pass
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
            sock.bind(CTL_SOCKET)
            os.chmod(CTL_SOCKET, 0o660)
            while True:
                cmd = sock.recv(64).decode(errors='ignore').strip()
                if cmd in ('up', 'down', 'ok', 'back', 'close', 'open'):
                    ui_events.put((cmd,))
                    tap_event.set()
                    wake.set()
        except Exception as exc:
            print(f'Menu control socket error: {exc}', flush=True)
            time.sleep(5)


def set_menu_flag(on):
    try:
        if on:
            Path(MENU_FLAG).touch()
        else:
            Path(MENU_FLAG).unlink()
    except OSError:
        pass


def streamer_json(*args):
    try:
        r = subprocess.run([STREAMER_CONFIG, *args], capture_output=True, text=True, timeout=20)
        return json.loads(r.stdout)
    except Exception as exc:
        print(f'streamer-config {" ".join(args)} failed: {exc}', flush=True)
        return None


def qr_image(text, size):
    """QR code as an image of about `size` px, or None when python3-qrcode is not installed."""
    try:
        import qrcode
        qr = qrcode.QRCode(border=2, error_correction=qrcode.constants.ERROR_CORRECT_L)
        qr.add_data(text)
        qr.make(fit=True)
        matrix = qr.get_matrix()
    except Exception:
        return None
    scale = max(1, size // len(matrix))
    im = Image.new('RGB', (len(matrix) * scale,) * 2, 'white')
    d = ImageDraw.Draw(im)
    for y, line in enumerate(matrix):
        for x, black in enumerate(line):
            if black:
                d.rectangle((x * scale, y * scale, (x + 1) * scale - 1, (y + 1) * scale - 1), fill='black')
    return im


class Menu:
    TOP, ROW_H, ROWS = 40, 40, 5
    BAR_Y = 266

    def __init__(self):
        self.stack = []
        self.message = ('', 0.0)
        self.last_input = time.monotonic()
        self.dirty = True
        self.push(self.root_page())

    # -- pages ------------------------------------------------------------------
    def root_page(self):
        return {'title': 'Menu', 'index': 0, 'rows': [
            ('Info: address and PIN', lambda: self.push(self.info_page())),
            ('Audio output', lambda: self.push(self.audio_page())),
            ('Flip display 180°', self.flip),
            ('Setup hotspot', lambda: self.push(self.hotspot_page())),
            ('Reboot', lambda: self.push(self.confirm_page('Reboot', 'reboot'))),
            ('Power off', lambda: self.push(self.confirm_page('Power off', 'poweroff'))),
            ('Close menu', lambda: 'close'),
        ]}

    def info_page(self):
        info = streamer_json('info') or {}
        hs = info.get('hotspot')
        lines = [('Open on a phone or PC:', 'dim')]
        if info.get('url'):
            lines.append((info['url'].replace('http://', ''), 'big'))
        if info.get('mdns'):
            lines.append((info['mdns'].replace('http://', ''), 'dim'))
        if not info.get('url'):
            lines.append(('no network yet', 'warn'))
        lines.append(('', 'dim'))
        lines.append(('PIN  ' + str(info.get('pin', '------')), 'big'))
        qr_text = info.get('url')
        if hs:
            lines += [('', 'dim'), ('Hotspot: ' + hs['ssid'], 'dim'), ('Password: ' + hs['psk'], 'dim')]
            qr_text = f'WIFI:T:WPA;S:{hs["ssid"]};P:{hs["psk"]};;'
        return {'title': 'Info', 'index': 0, 'rows': [], 'lines': lines, 'qr': qr_text}

    def audio_page(self):
        data = streamer_json('audio-list') or {'cards': [], 'choice': 'auto'}
        rows = [(('• ' if data['choice'] == 'auto' else '') + 'Automatic (USB first)',
                 lambda: self.set_audio('auto'))]
        for c in data['cards']:
            label = ('• ' if data['choice'] == c['id'] else '') + c['name'][:30] + (' (USB)' if c['usb'] else '')
            rows.append((label, lambda cid=c['id']: self.set_audio(cid)))
        return {'title': 'Audio output', 'index': 0, 'rows': rows}

    def hotspot_page(self):
        return {'title': 'Setup hotspot', 'index': 0, 'rows': [
            ('Start hotspot', lambda: self.hotspot(True)),
            ('Stop hotspot', lambda: self.hotspot(False)),
        ], 'lines': None}

    def confirm_page(self, title, cmd):
        return {'title': title + '?', 'index': 1, 'rows': [
            ('Yes, ' + title.lower(), lambda: self.power(cmd)),
            ('Cancel', lambda: self.pop()),
        ]}

    # -- actions ------------------------------------------------------------------
    def say(self, text):
        self.message = (text, time.monotonic() + 5)
        self.dirty = True

    def push(self, page):
        self.stack.append(page)
        self.dirty = True

    def pop(self):
        if len(self.stack) > 1:
            self.stack.pop()
            self.dirty = True
            return None
        return 'close'

    def run_bg(self, args, then=None):
        def go():
            try:
                r = subprocess.run(args, capture_output=True, text=True, timeout=60)
                out = (r.stdout + r.stderr).strip().splitlines()
                self.say(out[-1][:60] if out and r.returncode else 'Done')
            except Exception as exc:
                self.say(f'Failed: {exc}'[:60])
            if then:
                ui_events.put((then,))
                wake.set()
        threading.Thread(target=go, daemon=True).start()

    def set_audio(self, card):
        self.say('Switching audio output...')
        self.run_bg([STREAMER_CONFIG, 'audio-set', card])
        self.stack = self.stack[:1]
        self.dirty = True

    def flip(self):
        self.say('Flipping, the display restarts...')
        subprocess.Popen([STREAMER_CONFIG, 'flip-toggle'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def hotspot(self, on):
        self.say('Starting hotspot, about 10 s...' if on else 'Stopping hotspot...')
        self.run_bg([STREAMER_CONFIG, 'hotspot', 'on' if on else 'off'], then='info')

    def power(self, cmd):
        self.say('Rebooting...' if cmd == 'reboot' else 'Shutting down...')
        subprocess.Popen([STREAMER_CONFIG, cmd], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return 'close'

    # -- input ------------------------------------------------------------------
    @property
    def page(self):
        return self.stack[-1]

    def activate(self):
        p = self.page
        if p['rows']:
            return p['rows'][p['index']][1]()
        return self.pop()

    def key(self, name):
        p = self.page
        if name == 'up':
            p['index'] = max(0, p['index'] - 1)
        elif name == 'down':
            p['index'] = min(max(0, len(p['rows']) - 1), p['index'] + 1)
        elif name == 'ok':
            r = self.activate()
            self.dirty = True
            return r
        elif name == 'back':
            return self.pop()
        elif name == 'close':
            return 'close'
        self.dirty = True
        return None

    def offset(self):
        p = self.page
        return max(0, min(p['index'] - 2, len(p['rows']) - self.ROWS))

    def tap(self, x, y):
        if y >= self.BAR_Y - 4:
            return self.key(['back', 'up', 'down', 'ok'][min(3, int(x // 120))])
        p = self.page
        if p['rows'] and self.TOP <= y < self.TOP + self.ROWS * self.ROW_H:
            idx = self.offset() + int((y - self.TOP) // self.ROW_H)
            if idx < len(p['rows']):
                if idx == p['index']:
                    return self.key('ok')
                p['index'] = idx
                self.dirty = True
        return None

    def tick(self):
        if self.message[0] and time.monotonic() > self.message[1]:
            self.message = ('', 0.0)
            self.dirty = True

    # -- drawing ----------------------------------------------------------------
    def render(self):
        im = Image.new('RGB', (WIDTH, HEIGHT), '#0B111A')
        d = ImageDraw.Draw(im)
        f_title, f_row = font(FONT_BOLD, 14), font(FONT_REG, 16)
        f_small, f_big = font(FONT_REG, 12), font(FONT_BOLD, 22)
        p = self.page
        d.rectangle((0, 0, WIDTH, 32), fill='#182634')
        crumbs = ' › '.join(['Menu'] + [s['title'] for s in self.stack[1:]]) if len(self.stack) > 1 else 'Menu'
        d.text((14, 8), crumbs, font=f_title, fill='#DDE7F2')
        if p['rows']:
            off = self.offset()
            for i, (label, _fn) in enumerate(p['rows'][off:off + self.ROWS]):
                y = self.TOP + i * self.ROW_H
                sel = (off + i) == p['index']
                d.rounded_rectangle((10, y, WIDTH - 10, y + self.ROW_H - 6), radius=8,
                                    fill='#18352F' if sel else '#121C28',
                                    outline='#70D0B2' if sel else None, width=2)
                d.text((24, y + 9), label, font=f_row, fill='#F2F5F8' if sel else '#B7C6D5')
            if len(p['rows']) > self.ROWS:
                d.text((WIDTH - 24, self.TOP + 2), '▲' if off > 0 else '', font=f_small, fill='#91A8BA')
                d.text((WIDTH - 24, self.TOP + self.ROWS * self.ROW_H - 22),
                       '▼' if off + self.ROWS < len(p['rows']) else '', font=f_small, fill='#91A8BA')
        if p.get('lines'):
            y = 46
            for text, style in p['lines']:
                fnt = f_big if style == 'big' else f_small if style == 'dim' else f_row
                d.text((16, y), text, font=fnt, fill={'big': '#F2F5F8', 'warn': '#F0B27A'}.get(style, '#9FB1C3'))
                y += 30 if style == 'big' else 20
        if p.get('qr'):
            qr = qr_image(p['qr'], 190)
            if qr:
                im.paste(qr, (WIDTH - qr.width - 12, 42))
        if self.message[0]:
            d.text((14, self.BAR_Y - 20), self.message[0], font=f_small, fill='#8DE0C2')
        for i, label in enumerate(['BACK', '▲', '▼', 'OK']):
            x0 = 10 + i * 118
            d.rounded_rectangle((x0, self.BAR_Y, x0 + 108, HEIGHT - 8), radius=8, fill='#182634')
            w = d.textbbox((0, 0), label, font=f_title)[2]
            d.text((x0 + (108 - w) // 2, self.BAR_Y + 12), label, font=f_title, fill='#DDE7F2')
        return im


def handle_ui(menu, ev):
    kind = ev[0]
    if kind == 'open':
        return menu or Menu()
    if menu is None:
        return None
    menu.last_input = time.monotonic()
    try:
        if kind == 'tap':
            result = menu.tap(ev[1], ev[2])
        elif kind == 'info':
            menu.push(menu.info_page())
            result = None
        else:
            result = menu.key(kind)
    except Exception as exc:                      # a failing menu action must never take the display down
        print(f'Menu error: {exc}', flush=True)
        menu.say(f'Failed: {exc}'[:60])
        result = None
    return None if result == 'close' else menu


def fmt_time(seconds):
    seconds = max(0, int(seconds or 0))
    return f'{seconds // 60}:{seconds % 60:02d}'


def render(snapshot, art, now):
    im = Image.new('RGB', (WIDTH, HEIGHT), '#0B111A')
    d = ImageDraw.Draw(im)
    f_header = font(FONT_BOLD, 11)
    f_title = font(FONT_BOLD, 23)
    f_artist = font(FONT_REG, 16)
    f_album = font(FONT_REG, 12)
    f_small = font(FONT_BOLD, 10)
    f_time = font(FONT_REG, 11)

    # Header
    d.ellipse((16, 17, 24, 25), fill='#68D4B0')
    for bar in range(3):                          # menu icon (tap the header to open the menu)
        d.rectangle((150, 15 + bar * 4, 164, 16 + bar * 4), fill='#91A8BA')
    d.text((32, 14), 'NOW PLAYING', font=f_header, fill='#DDE7F2')
    source = str(snapshot.get('source') or 'STREAMER').upper()
    source = source[:18]
    source_w = d.textbbox((0, 0), source, font=f_small)[2]
    d.rounded_rectangle((WIDTH - source_w - 34, 11, WIDTH - 14, 32), radius=9, fill='#182634')
    d.text((WIDTH - source_w - 24, 16), source, font=f_small, fill='#91A8BA')

    # Album artwork
    artwork = art.copy() if art is not None else placeholder_art(190)
    artwork = ImageOps.fit(artwork, (190, 190), method=Image.Resampling.LANCZOS)
    mask = Image.new('L', (190, 190), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, 189, 189), radius=13, fill=255)
    im.paste(artwork, (16, 49), mask)

    # Track metadata
    x, y, maxw = 224, 57, 240
    title = snapshot.get('title') or 'Waiting for music'
    title_lines = wrap_lines(d, title, f_title, maxw, 3)
    for line in title_lines:
        d.text((x, y), line, font=f_title, fill='#F2F5F8')
        y += 30
    y += 7
    artist = snapshot.get('artist') or ('Start playback from your phone' if not snapshot.get('title') else '')
    for line in wrap_lines(d, artist, f_artist, maxw, 2):
        d.text((x, y), line, font=f_artist, fill='#B7C6D5')
        y += 22
    y += 5
    album = snapshot.get('album') or ''
    for line in wrap_lines(d, album, f_album, maxw, 2):
        d.text((x, y), line, font=f_album, fill='#8294A6')
        y += 18

    state = str(snapshot.get('state', 'stop')).lower()
    state_label = {'play': 'PLAYING', 'pause': 'PAUSED', 'stop': 'STOPPED'}.get(state, state.upper())
    d.rounded_rectangle((224, 218, 224 + d.textbbox((0, 0), state_label, font=f_small)[2] + 20, 240), radius=9, fill='#18352F' if state == 'play' else '#26313E')
    d.text((234, 224), state_label, font=f_small, fill='#8DE0C2' if state == 'play' else '#AAB7C5')

    # Progress bar and timestamps
    duration = max(0.0, float(snapshot.get('duration') or 0))
    position = max(0.0, float(snapshot.get('position') or 0))
    if state == 'play' and snapshot.get('_position_monotonic'):
        position += max(0.0, now - snapshot['_position_monotonic'])
    position = min(position, duration) if duration > 0 else position
    left, right, bar_y = 16, 464, 276
    d.rounded_rectangle((left, bar_y, right, bar_y + 5), radius=3, fill='#263342')
    if duration > 0:
        fill_w = int((right - left) * min(1.0, position / duration))
        if fill_w > 0:
            d.rounded_rectangle((left, bar_y, left + fill_w, bar_y + 5), radius=3, fill='#70D0B2')
    # Play / pause touch button (right, above the timeline)
    d.ellipse((BTN_CX - BTN_R, BTN_CY - BTN_R, BTN_CX + BTN_R, BTN_CY + BTN_R), fill='#18352F', outline='#70D0B2', width=2)
    if state == 'play':
        d.rectangle((BTN_CX - 8, BTN_CY - 9, BTN_CX - 3, BTN_CY + 9), fill='#8DE0C2')
        d.rectangle((BTN_CX + 3, BTN_CY - 9, BTN_CX + 8, BTN_CY + 9), fill='#8DE0C2')
    else:
        d.polygon([(BTN_CX - 6, BTN_CY - 10), (BTN_CX - 6, BTN_CY + 10), (BTN_CX + 10, BTN_CY)], fill='#8DE0C2')
    d.text((16, 290), fmt_time(position), font=f_time, fill='#B7C3CF')
    end = fmt_time(duration) if duration else '--:--'
    end_w = d.textbbox((0, 0), end, font=f_time)[2]
    d.text((464 - end_w, 290), end, font=f_time, fill='#B7C3CF')
    return im


def main():
    cfg = read_config()
    poll = max(0.5, min(5.0, float(cfg.get('poll_seconds', 1.0))))
    idle_clear_seconds = max(0.0, float(cfg.get('idle_clear_seconds', 180)))
    fb = Framebuffer('/dev/fb0')
    print(f'Framebuffer ready: {fb.width}x{fb.height}, {fb.bpp} bpp, stride={fb.stride}', flush=True)
    last_key, art, last_art_attempt = None, None, 0.0
    last_render_key = None
    idle_since = None
    screen_cleared = False
    idle_logo = None
    idle_x = idle_y = 0.0
    idle_vx, idle_vy = 42.0, 30.0
    idle_last_frame = 0.0
    running = True
    threading.Thread(target=touch_thread, args=(cfg,), daemon=True).start()
    threading.Thread(target=ctl_thread, daemon=True).start()
    menu, menu_flag_on = None, False

    def stop_signal(_sig, _frame):
        nonlocal running
        running = False

    signal.signal(signal.SIGTERM, stop_signal)
    signal.signal(signal.SIGINT, stop_signal)

    try:
        while running:
            started = time.monotonic()
            snapshot = select_snapshot(cfg)
            now = time.monotonic()
            key = snapshot.get('track_key') or 'idle'

            if key != last_key or (art is None and now - last_art_attempt > 15):
                last_art_attempt = now
                art = load_art(snapshot, cfg) if snapshot.get('title') else None
                last_key = key

            state = str(snapshot.get('state', 'stop')).lower()
            touch_state.update(source=str(snapshot.get('source') or '').lower(), state=state, visible=False)

            # Setup menu: handle queued taps / remote keys; while it is open it replaces the track view.
            while True:
                try:
                    menu = handle_ui(menu, ui_events.get_nowait())
                except queue.Empty:
                    break
            if menu is not None and time.monotonic() - menu.last_input > MENU_TIMEOUT:
                menu = None
            if (menu is not None) != menu_flag_on:
                menu_flag_on = menu is not None
                set_menu_flag(menu_flag_on)
                last_render_key = None
            touch_state['menu'] = menu is not None
            if menu is not None:
                tap_event.clear()
                idle_since, screen_cleared, idle_logo, idle_last_frame = None, False, None, 0.0
                menu.tick()
                if menu.dirty:
                    menu.dirty = False
                    fb.show(menu.render())
                wake.wait(0.3)
                wake.clear()
                continue

            # A tap anywhere leaves the idle screen and restarts the idle timer,
            # so play can be pressed again after a stop/pause.
            if tap_event.is_set():
                tap_event.clear()
                if idle_since is not None:
                    idle_since = now
                if screen_cleared:
                    screen_cleared = False
                    idle_logo = None
                    idle_last_frame = 0.0
                    last_render_key = None
                    print('Display woken by touch', flush=True)

            # Start the idle timer when playback enters stopped state.
            if state in ('stop', 'pause'):
                if idle_since is None:
                    idle_since = now

                # Animate the boot logo after the configured idle timeout.
                if now - idle_since >= idle_clear_seconds:
                    if not screen_cleared:
                        from boot_splash import create_splash

                        # Extract the original circular BPi M2U artwork.
                        splash = create_splash()
                        logo_crop = splash.crop((110, 42, 370, 302)).convert('RGB')

                        # Mask the square crop into a circle.
                        logo_mask = Image.new('L', (260, 260), 0)
                        ImageDraw.Draw(logo_mask).ellipse(
                            (0, 0, 259, 259), fill=255
                        )

                        idle_logo = Image.new('RGB', (260, 260), '#000000')
                        idle_logo.paste(logo_crop, (0, 0), logo_mask)
                        idle_logo.thumbnail((96, 96), Image.Resampling.LANCZOS)

                        idle_x = (WIDTH - idle_logo.width) / 2
                        idle_y = (HEIGHT - idle_logo.height) / 2
                        idle_last_frame = 0.0
                        screen_cleared = True
                        print(
                            f'Idle logo animation started: {idle_logo.width}x{idle_logo.height}',
                            flush=True
                        )

                    # Limit framebuffer updates to approximately 2.5 FPS.
                    if idle_last_frame == 0.0 or now - idle_last_frame >= 0.4:
                        dt = min(max(now - idle_last_frame, 0.0), 0.5) if idle_last_frame else 0.0

                        idle_x += idle_vx * dt
                        idle_y += idle_vy * dt

                        max_x = WIDTH - idle_logo.width
                        max_y = HEIGHT - idle_logo.height

                        if idle_x <= 0:
                            idle_x = 0
                            idle_vx = abs(idle_vx)
                        elif idle_x >= max_x:
                            idle_x = max_x
                            idle_vx = -abs(idle_vx)

                        if idle_y <= 0:
                            idle_y = 0
                            idle_vy = abs(idle_vy)
                        elif idle_y >= max_y:
                            idle_y = max_y
                            idle_vy = -abs(idle_vy)

                        frame = Image.new('RGB', (WIDTH, HEIGHT), '#000000')
                        frame.paste(idle_logo, (int(idle_x), int(idle_y)))
                        fb.show(frame)
                        idle_last_frame = now

                    elapsed = time.monotonic() - started
                    wake.wait(max(0.05, poll - elapsed)); wake.clear()
                    continue
            else:
                idle_since = None

                # Force a complete redraw when playback resumes or is paused.
                if screen_cleared:
                    screen_cleared = False
                    idle_logo = None
                    idle_last_frame = 0.0
                    last_render_key = None
                    print('Display resumed', flush=True)

            touch_state['visible'] = True
            position_bucket = int(float(snapshot.get('position') or 0)) if state == 'play' else None
            render_key = (
                snapshot.get('track_key'), state, snapshot.get('source'),
                snapshot.get('title'), snapshot.get('artist'), snapshot.get('album'),
                bool(art), position_bucket,
            )

            if render_key != last_render_key:
                snapshot['_position_monotonic'] = time.monotonic()
                fb.show(render(snapshot, art, time.monotonic()))
                last_render_key = render_key

            elapsed = time.monotonic() - started
            wake.wait(max(0.05, poll - elapsed)); wake.clear()
    finally:
        set_menu_flag(False)
        fb.close()


if __name__ == '__main__':
    main()
PYAPP

chmod 0755 "$APP"
chmod 0644 "$LIB" "$SRC"

# Disable the framebuffer-console cursor, which otherwise remains visible over fb0.
# ExecStartPre reapplies this after fbcon initialization on every service start.
install -d -m 0755 "$SERVICE_DROPIN_DIR"
cat > "$CURSOR_DROPIN" <<'UNIT'
[Service]
ExecStartPre=/bin/sh -c 'if [ -w /sys/class/graphics/fbcon/cursor_blink ]; then echo 0 > /sys/class/graphics/fbcon/cursor_blink; fi'
UNIT
if [[ -w "$CURSOR_SYSFS" ]]; then
    printf '0\n' > "$CURSOR_SYSFS"
fi

# Keep an existing config intact; ensure the idle-animation timeout is configured.
if [[ ! -e "$CFG" ]]; then
    cat > "$CFG" <<'JSON'
{
  "source": "auto",
  "poll_seconds": 2.0,
  "idle_clear_seconds": 180,
  "flip": false,
  "mpd": {
    "host": "127.0.0.1",
    "port": 6600,
    "password": ""
  },
  "spotify_state": "/var/lib/music-display/spotify.json"
}
JSON
    chmod 0644 "$CFG"
else
    python3 - "$CFG" <<'PY'
import json
from pathlib import Path
import sys
p = Path(sys.argv[1])
cfg = json.loads(p.read_text())
cfg.setdefault("idle_clear_seconds", 180)
cfg.setdefault("flip", False)
# Migrate the pre-Soloist key (librespot.json is no longer written by anything).
legacy = cfg.pop("librespot_state", None)
if legacy and "spotify_state" not in cfg:
    cfg["spotify_state"] = "/var/lib/music-display/spotify.json"
cfg.setdefault("spotify_state", "/var/lib/music-display/spotify.json")
cfg.setdefault("poll_seconds", 2.0)
p.write_text(json.dumps(cfg, indent=2) + "\n")
PY
fi

# systemd service; no unsupported framebuffer sysfs blank write.
cat > "$SERVICE" <<'UNIT'
[Unit]
Description=480x320 standalone music now-playing display
After=local-fs.target getty@tty1.service
Conflicts=getty@tty1.service
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=simple
User=root
Group=music-display
UMask=0002
ExecStart=/usr/bin/python3 /opt/music-display/music_display.py
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

# Validate Python, Pillow, native library and RGB565 byte ordering before starting.
python3 -m py_compile "$APP"
python3 -c 'from PIL import Image, ImageDraw, ImageFont, ImageOps; print("Pillow import OK")'
python3 - <<'PY'
import ctypes
lib = ctypes.CDLL('/opt/music-display/libfbconvert.so')
fn = lib.rgb888_to_fb
fn.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int, ctypes.c_int,
               ctypes.c_int] + [ctypes.c_uint] * 9
fn.restype = None
src = bytes((255, 0, 0, 0, 255, 0, 0, 0, 255))
out = bytearray(6)
sp = ctypes.cast(ctypes.c_char_p(src), ctypes.c_void_p)
dst = (ctypes.c_ubyte * len(out)).from_buffer(out)
fn(sp, ctypes.cast(dst, ctypes.c_void_p), 3, 1, 6,
   11, 5, 0, 5, 6, 0, 0, 5, 0)
if out != bytes.fromhex('00f8e0071f00'):
    raise SystemExit(f'RGB565 self-test failed: {out.hex()}')
print('Native RGB565 converter self-test OK')
PY

# Enable and start; restore the previous installation on either immediate or delayed startup failure.
restore_previous() {
    systemctl stop music-display.service 2>/dev/null || true
    for path in "$APP" "$SRC" "$LIB" "$CFG" "$SERVICE" "$CURSOR_DROPIN"; do
        if [[ -e "$BACKUP_DIR$path" ]]; then
            mkdir -p "$(dirname "$path")"
            cp -a "$BACKUP_DIR$path" "$path"
        else
            rm -f "$path"
        fi
    done
    rmdir "$SERVICE_DROPIN_DIR" 2>/dev/null || true
    systemctl daemon-reload
    if [[ -f "$SERVICE" ]]; then
        if (( WAS_ENABLED )); then
            systemctl enable music-display.service 2>/dev/null || true
        else
            systemctl disable music-display.service 2>/dev/null || true
        fi
        if (( WAS_ACTIVE )); then
            systemctl reset-failed music-display.service 2>/dev/null || true
            systemctl restart music-display.service 2>/dev/null || true
        fi
    else
        systemctl disable music-display.service 2>/dev/null || true
    fi
}

systemctl stop music-display.service 2>/dev/null || true
systemctl daemon-reload
systemctl reset-failed music-display.service 2>/dev/null || true
systemctl enable music-display.service
if ! systemctl restart music-display.service; then
    echo "Service restart failed; restoring previous installation." >&2
    restore_previous
    exit 1
fi
sleep 5
if ! systemctl is-active --quiet music-display.service; then
    echo "Service did not remain active; restoring previous installation." >&2
    journalctl -u music-display.service -n 50 --no-pager || true
    restore_previous
    exit 1
fi

echo
echo "Music display deployed successfully."
echo "Backup:  $BACKUP_DIR"
echo "Status:  systemctl status music-display.service"
echo "Logs:    journalctl -fu music-display.service"
echo "Config:  $CFG"
echo "Cursor:  disabled via $CURSOR_DROPIN"
echo
echo "Spotify: state is written to /var/lib/music-display/spotify.json by"
echo "/usr/local/bin/streamer-soloist-event (Soloist event watcher)."
echo
echo "Idle behaviour: pause/stop = circular 96x96 BPi M2U logo bouncing on black after configured timeout (default 180s)."
echo "Animation cadence: approximately 2.5 FPS; normal display is restored when playback resumes."
echo "The working FBTFT overlay, SPI, GPIO and kernel driver were not modified."
