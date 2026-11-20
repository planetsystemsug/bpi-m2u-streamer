#!/bin/bash
# Manage the default ALSA output: prefer a USB sound card (the amp).
# The default is a dmix soft-mixer so multiple players (MPD + Soloist via
# PulseAudio) can share the card at once; plug handles per-client rate/format
# conversion.
# Each card gets its own dmix ipc_key, so switching cards never collides with
# a shared-memory segment left by the previous card's players.
#
# udev fires one event per sound subdevice (cardN, pcmC*DN*, controlCN), in no
# guaranteed order, and the card event can fire long before the USB audio
# driver has registered its PCM devices; udev then takes a few more seconds to
# set /dev/snd permissions from root:root 600 to root:audio 660. So every
# event recomputes the desired default from what is actually present:
# /etc/asound.conf is updated when it changes, and the players are restarted
# once the mpd user can actually open the target's playback and control
# devices (whichever event gets there first does it; a marker file in /run
# prevents repeat restarts). Modes add/remove/scan all do the same thing.
#
# The lock is only held for the short read/write sections, never while waiting
# for the device to become ready, so parallel udev workers don't queue up
# behind each other (which at boot can stall everything for minutes).
ACTION="$1"; CARD="${2:-}"; CARD="${CARD#card}"

exec 9>/run/streamer-audio.lock || exit 0

is_usb_card() { readlink -f "/sys/class/sound/card$1/device" 2>/dev/null | grep -q "usb"; }
conf_for() { printf 'pcm.dmixer {\n    type dmix\n    ipc_key %d\n    slave {\n        pcm "hw:%s"\n        rate 48000\n        channels 2\n        format S16_LE\n    }\n}\npcm.!default {\n    type plug\n    slave.pcm "dmixer"\n}\nctl.!default {\n    type hw\n    card %s\n}\n' $((5678293 + $1)) "$1" "$1"; }
usb_card() { for c in /sys/class/sound/card*; do n="${c##*/}"; n="${n#card}"; is_usb_card "$n" && { echo "$n"; return; }; done; }

marker_file=/run/streamer-audio-active

flock -x 9
logger -t streamer-audio "event: action=$ACTION card=${CARD:-none}"
target="$(usb_card)"
marker="$(cat "$marker_file" 2>/dev/null)"

cur="$(cat /etc/asound.conf 2>/dev/null)"
if [ -n "$target" ]; then want="$(conf_for "$target")"; else want=""; fi
if [ "$cur" != "$want" ]; then
    logger -t streamer-audio "asound.conf: switching to ${target:-onboard}"
    if [ -n "$target" ]; then conf_for "$target" > /etc/asound.conf; else rm -f /etc/asound.conf; fi
fi

need=0
[ "$marker" != "${target:-onboard}" ] && need=1
flock -u 9

# Players hold open ALSA handles, so they must be restarted when the default
# card changes. Wait (up to ~30 s) until the mpd user can actually play a few
# frames and read the mixer on the target; if that never happens this run, a
# later event will retry.
[ "$need" = 1 ] || exit 0
ready=1
i=0
while [ -n "$target" ] && ! runuser -u mpd -- bash -c "dd if=/dev/zero bs=96 count=2 2>/dev/null | aplay -q -D default -f S16_LE -r 48000 -c 2 && amixer -c $target sget PCM >/dev/null" 2>/dev/null; do
    ready=0
    i=$((i+1))
    [ $i -ge 60 ] && break
    sleep 0.5
done
[ "$ready" = 1 ] || exit 0

flock -x 9
target="$(usb_card)"
marker="$(cat "$marker_file" 2>/dev/null)"
if [ "$marker" != "${target:-onboard}" ]; then
    logger -t streamer-audio "restarting players for ${target:-onboard}"
    if [ -n "$target" ]; then
        amixer -c "$target" sset PCM 80% >/dev/null 2>&1 || true
    fi
    systemctl try-restart streamer-pulseaudio 2>/dev/null || true
    systemctl try-restart mpd soloist 2>/dev/null || true
    echo "${target:-onboard}" > "$marker_file"
fi
flock -u 9
