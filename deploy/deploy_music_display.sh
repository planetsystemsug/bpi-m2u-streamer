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
apt-get install -y --no-install-recommends python3 python3-pil fonts-dejavu-core gcc libc6-dev

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
import fcntl
import hashlib
import io
import json
import os
import signal
import socket
import struct
import sys
import time
import urllib.request
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageOps

CONFIG_PATH = Path('/etc/music-display/config.json')
STATE_PATH = Path('/var/lib/music-display/spotify.json')
CACHE_DIR = Path('/var/cache/music-display')
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
        try:
            fcntl.ioctl(self.fd, FBIOBLANK, struct.pack('i', 0))
        except OSError as exc:
            print(f'Framebuffer blank ioctl unsupported; continuing: {exc}', flush=True)

        self._converter_lib = ctypes.CDLL('/opt/music-display/libfbconvert.so')
        self._convert_rgb565 = self._converter_lib.rgb888_to_fb
        self._convert_rgb565.argtypes = [
            ctypes.c_void_p, ctypes.c_void_p,
            ctypes.c_int, ctypes.c_int, ctypes.c_int,
            *([ctypes.c_uint] * 9),
        ]
        self._convert_rgb565.restype = None

    def show(self, image):
        image = image.convert('RGB')
        if image.size != (self.width, self.height):
            image = image.resize((self.width, self.height), Image.Resampling.LANCZOS)
        # Rotate the complete framebuffer image 180 degrees in software.
        image = image.transpose(Image.Transpose.ROTATE_180)
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
    key = get(song, 'Id') or file_name or f'{title}|{artist}|{album}'
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
    if source in ('auto', 'spotify'):
        spotify = read_spotify_state(cfg.get('spotify_state', str(STATE_PATH)))
        if source != 'auto':
            return spotify or idle_snapshot()
        if spotify and spotify.get('state') == 'play':
            return spotify
        if mpd and mpd.get('state') in ('play', 'pause'):
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


def create_idle_logo(size=96):
    # Recreate the exact central artwork from boot_splash.py (crop 110,42 to 370,302).
    # The original splash gradient is retained inside the circular logo.
    logo = Image.new('RGB', (260, 260), '#000000')
    draw = ImageDraw.Draw(logo)

    for y in range(260):
        global_y = y + 42
        t = global_y / 320
        color = (
            int(8 + 7 * t),
            int(15 + 13 * t),
            int(29 + 19 * t),
        )
        draw.line((0, y, 259, y), fill=color)

    draw.ellipse((0, 0, 260, 260), outline='#203B50', width=2)
    draw.ellipse((18, 18, 242, 242), outline='#1B3448', width=1)

    cx, cy = 130, 73
    heights = [15, 28, 43, 57, 43, 28, 15]
    for i, height in enumerate(heights):
        x = cx - 42 + i * 14
        draw.rounded_rectangle(
            (x, cy - height // 2, x + 6, cy + height // 2),
            radius=3,
            fill='#63D8B6',
        )

    title = font(FONT_BOLD, 29)
    subtitle = font(FONT_BOLD, 19)
    draw.text((130, 138), 'BPi M2U', font=title, fill='#F0F4FA', anchor='mm')
    draw.text((130, 169), 'STREAMER', font=subtitle, fill='#63D8B6', anchor='mm')

    mask = Image.new('L', (260, 260), 0)
    ImageDraw.Draw(mask).ellipse((0, 0, 259, 259), fill=255)
    result = logo.convert('RGBA')
    result.putalpha(mask)
    return result.resize((size, size), Image.Resampling.LANCZOS)


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
    d.text((16, 290), fmt_time(position), font=f_time, fill='#B7C3CF')
    end = fmt_time(duration) if duration else '--:--'
    end_w = d.textbbox((0, 0), end, font=f_time)[2]
    d.text((464 - end_w, 290), end, font=f_time, fill='#B7C3CF')
    return im


def main():
    cfg = read_config()
    poll = max(0.5, min(5.0, float(cfg.get('poll_seconds', 2.0))))
    idle_clear_seconds = max(0.0, float(cfg.get('idle_clear_seconds', 300)))
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
    idle_frame_interval = 0.4  # 2.5 FPS
    running = True

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
            state = str(snapshot.get('state', 'stop')).lower()

            # Only load artwork while a track is active or paused.
            key = snapshot.get('track_key') or 'idle'
            if state != 'stop':
                if key != last_key or (art is None and now - last_art_attempt > 15):
                    last_art_attempt = now
                    art = load_art(snapshot, cfg) if snapshot.get('title') else None
                    last_key = key

            # Animate the circular boot logo after the timeout in both pause and stop.
            if state in ('stop', 'pause'):
                if idle_since is None:
                    idle_since = now

                if now - idle_since >= idle_clear_seconds:
                    if not screen_cleared:
                        idle_logo = create_idle_logo(96)
                        idle_x = (WIDTH - idle_logo.width) / 2
                        idle_y = (HEIGHT - idle_logo.height) / 2
                        idle_last_frame = 0.0
                        screen_cleared = True
                        print(
                            f'Idle BPi M2U logo animation started: '
                            f'{idle_logo.width}x{idle_logo.height}',
                            flush=True,
                        )

                    if idle_last_frame == 0.0 or now - idle_last_frame >= idle_frame_interval:
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
                        frame.paste(idle_logo, (int(idle_x), int(idle_y)), idle_logo)
                        fb.show(frame)
                        idle_last_frame = time.monotonic()

                    # Keep framebuffer updates and MPD polling near 2.5 FPS while animating.
                    time.sleep(max(0.05, idle_frame_interval - (time.monotonic() - idle_last_frame)))
                    continue
            else:
                idle_since = None
                if screen_cleared:
                    screen_cleared = False
                    idle_logo = None
                    idle_last_frame = 0.0
                    last_render_key = None
                    print('Display resumed', flush=True)

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
            time.sleep(max(0.05, poll - elapsed))
    finally:
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
  "idle_clear_seconds": 300,
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
cfg.setdefault("idle_clear_seconds", 300)
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
echo "Idle behaviour: pause/stop = circular 96x96 BPi M2U logo bouncing on black after configured timeout (default 300s)."
echo "Animation cadence: approximately 2.5 FPS; normal display is restored when playback resumes."
echo "The working FBTFT overlay, SPI, GPIO and kernel driver were not modified."
