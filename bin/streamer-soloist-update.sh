#!/bin/bash
# Re-download the latest Soloist arm32 build and replace the installed one if
# it changed. Soloist builds expire 90 days after their build date (exit code
# 10), so this keeps the box on a fresh build via streamer-soloist-update.timer.
set -euo pipefail

URL=https://soloist-builds.spotifycdn.com/soloist_release_arm32.tar.gz
DEST=/opt/soloist
LINK=/usr/local/bin/soloist

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

curl -fsSL --retry 3 -m 180 -o "$STAGE/soloist.tar.gz" "$URL"
tar xzf "$STAGE/soloist.tar.gz" -C "$STAGE"
[ -x "$STAGE/soloist" ] || { logger -t streamer-soloist "downloaded archive has no executable"; exit 1; }

NEW_VER="$("$STAGE/soloist" -V | head -n1)"
OLD_VER="$( "$LINK" -V 2>/dev/null | head -n1 || true )"

if [ "$NEW_VER" = "$OLD_VER" ]; then
    logger -t streamer-soloist "up to date: $NEW_VER"
    exit 0
fi

install -d -m 0755 "$DEST"
cp -a "$STAGE/." "$DEST/"
chmod 0755 "$DEST/soloist"
ln -sf "$DEST/soloist" "$LINK"
logger -t streamer-soloist "updated: ${OLD_VER:-none} -> $NEW_VER"
systemctl try-restart soloist 2>/dev/null || true
