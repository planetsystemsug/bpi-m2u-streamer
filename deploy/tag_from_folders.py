#!/usr/bin/env python3
"""Tag audio files with artist/album derived from folder structure.

Expected layout: <root>/<Artist>/<Album>/[subdirs/]track.flac

Usage: tag_from_folders.py [--dry-run] [--albumartist] [root]
  root           default /mnt/music_library
  --dry-run      show what would change, write nothing
  --albumartist  also set the album-artist tag (keeps compilations sane
                 when track artists are edited later)

Files whose tags already match are left untouched (no rewrite, no mtime
change, no needless MPD rescan). Errors on single files are reported and
do not abort the run. Needs python3-mutagen.
"""
import os
import sys
from pathlib import Path

from mutagen import MutagenError

AUDIO_EXTS = {".flac", ".mp3", ".m4a", ".mp4", ".ogg", ".opus"}


def _vorbis_like(f, wanted):
    """FLAC / Ogg Vorbis / Opus: dict of lowercase key -> list of str."""
    changed = False
    for key, value in wanted.items():
        if list(f.get(key, [])) != [value]:
            f[key] = [value]
            changed = True
    return changed


def _mp3(tags, wanted):
    from mutagen.id3 import TALB, TPE1, TPE2
    frames = {"artist": TPE1, "album": TALB, "albumartist": TPE2}
    changed = False
    for key, value in wanted.items():
        cls = frames[key]
        cur = tags.get(cls.__name__)
        if cur is None or list(cur.text) != [value]:
            tags.setall(cls.__name__, [cls(encoding=3, text=[value])])
            changed = True
    return changed


def _mp4(f, wanted):
    atoms = {"artist": "\xa9ART", "album": "\xa9alb", "albumartist": "aART"}
    changed = False
    for key, value in wanted.items():
        atom = atoms[key]
        if list(f.get(atom, [])) != [value]:
            f[atom] = [value]
            changed = True
    return changed


def _open(path):
    """Open with the format-specific class chosen by extension.

    mutagen.File() probes every supported format against the file header,
    which costs extra small reads per file; on an SD card that adds up.
    Returns (kind, object) or (None, None).
    """
    ext = path.suffix.lower()
    if ext == ".flac":
        from mutagen.flac import FLAC
        return "vorbis", FLAC(path)
    if ext == ".mp3":
        # ID3 only: skips the MPEG frame scan MP3() does for length/bitrate.
        from mutagen.id3 import ID3, ID3NoHeaderError
        try:
            return "mp3", ID3(path)
        except ID3NoHeaderError:
            tags = ID3()
            tags.filename = str(path)
            return "mp3", tags
    if ext in (".m4a", ".mp4"):
        from mutagen.mp4 import MP4
        return "mp4", MP4(path)
    if ext == ".ogg":
        from mutagen import File
        f = File(path)          # Vorbis or Opus-in-ogg or FLAC-in-ogg
        return ("vorbis", f) if f is not None else (None, None)
    if ext == ".opus":
        from mutagen.oggopus import OggOpus
        return "vorbis", OggOpus(path)
    return None, None


def set_tags(path, wanted, dry_run):
    """Return 'changed', 'unchanged' or 'unsupported'."""
    kind, f = _open(path)
    if kind is None:
        return "unsupported"
    if kind == "mp3":
        changed = _mp3(f, wanted)
    elif kind == "mp4":
        changed = _mp4(f, wanted)
    else:
        if f.tags is None:
            f.add_tags()
        changed = _vorbis_like(f, wanted)
    if changed and not dry_run:
        f.save()
    return "changed" if changed else "unchanged"


def iter_audio(root):
    """Yield (path, relative path) for audio files, sorted per directory.

    os.scandir gives file type from the directory entry without an extra
    stat() per file, and hidden entries (._ sidecars, .Trash) are pruned
    before descending.
    """
    stack = [root]
    while stack:
        d = stack.pop()
        try:
            with os.scandir(d) as it:
                entries = sorted(it, key=lambda e: e.name)
        except OSError as e:
            print("ERROR:", f"{d}: {e}", file=sys.stderr)
            continue
        subdirs = []
        for e in entries:
            if e.name.startswith("."):
                continue
            if e.is_dir(follow_symlinks=False):
                subdirs.append(Path(e.path))
            elif os.path.splitext(e.name)[1].lower() in AUDIO_EXTS and e.is_file():
                p = Path(e.path)
                yield p, p.relative_to(root)
        stack.extend(reversed(subdirs))


def main():
    args = sys.argv[1:]
    dry_run = "--dry-run" in args
    albumartist = "--albumartist" in args
    args = [a for a in args if not a.startswith("--")]
    root = Path(args[0] if args else "/mnt/music_library")
    if not root.is_dir():
        sys.exit(f"not a directory: {root}")

    counts = {"changed": 0, "unchanged": 0, "unsupported": 0}
    skipped, errors = [], []
    for p, rel in iter_audio(root):
        if len(rel.parts) < 3:
            skipped.append(str(rel))
            continue
        wanted = {"artist": rel.parts[0], "album": rel.parts[1]}
        if albumartist:
            wanted["albumartist"] = rel.parts[0]
        try:
            result = set_tags(p, wanted, dry_run)
        except (MutagenError, OSError) as e:
            errors.append(f"{rel}: {e}")
            continue
        counts[result] += 1
        if result == "changed":
            print(("would tag: " if dry_run else "tagged: ") + str(rel))
        elif result == "unsupported":
            print("unsupported format:", rel)

    verb = "would change" if dry_run else "changed"
    print(f"{verb} {counts['changed']}, already correct {counts['unchanged']}, "
          f"unsupported {counts['unsupported']}, errors {len(errors)}")
    for s in skipped:
        print("skipped (not Artist/Album/file):", s)
    for e in errors:
        print("ERROR:", e, file=sys.stderr)
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
