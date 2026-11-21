#!/usr/bin/env bash
# Check FLAC files below a folder for corruption. Runs on any Linux/macOS box
# (not part of the streamer deployment).
#
#   check_flac.sh [-j JOBS] [-m MANIFEST] FOLDER
#
# Uses `flac -t` (decodes everything and verifies the frame CRCs and the MD5 of
# the audio stored in the file). Falls back to `ffmpeg -v error ... -f null -`
# if flac is not installed. Exit status: 0 all good, 1 corrupt files found,
# 2 usage/tool error.
#
# -m MANIFEST also writes "sha1  relative/path" for every file, so the same
# list can be checked on the streamer with `sha1sum -c` (run from the music
# folder) to tell a bad copy from bad source files.
set -u

jobs=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)
manifest=""
while getopts "j:m:h" o; do
  case $o in
    j) jobs=$OPTARG ;;
    m) manifest=$OPTARG ;;
    *) sed -n '2,15p' "$0"; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
[ $# -eq 1 ] && [ -d "$1" ] || { sed -n '2,15p' "$0"; exit 2; }
root=$(cd "$1" && pwd)

if command -v flac >/dev/null; then
  tool=flac
elif command -v ffmpeg >/dev/null; then
  tool=ffmpeg
else
  echo "need flac (preferred) or ffmpeg installed" >&2; exit 2
fi
echo "Checking $root with $tool, $jobs parallel jobs" >&2

check_one() {  # prints "OK path" or "BAD path: reason"
  f=$1
  if [ "$2" = flac ]; then
    out=$(flac -t -s -- "$f" 2>&1) && echo "OK  $f" || echo "BAD $f: $(echo "$out" | tr '\n' ' ' | cut -c1-200)"
  else
    out=$(ffmpeg -v error -err_detect crccheck+bitstream+explode -i "$f" -f null - 2>&1)
    [ -z "$out" ] && echo "OK  $f" || echo "BAD $f: $(echo "$out" | tr '\n' ' ' | cut -c1-200)"
  fi
}
export -f check_one

res=$(mktemp); trap 'rm -f "$res"' EXIT
find "$root" -type f -iname '*.flac' -print0 | sort -z |
  xargs -0 -n1 -P "$jobs" bash -c 'check_one "$2" "$1"' _ "$tool" >"$res" 2>&1

total=$(wc -l <"$res"); bad=$(grep -c '^BAD' "$res")
grep '^BAD' "$res" | sort
echo "---"
echo "$total files checked, $bad corrupt"

if [ -n "$manifest" ]; then
  (cd "$root" && find . -type f -iname '*.flac' -print0 | sort -z | xargs -0 sha1sum) >"$manifest"
  echo "SHA1 manifest written to $manifest"
fi
[ "$bad" -eq 0 ]
