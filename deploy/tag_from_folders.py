#!/usr/bin/env python3
"""Tag audio files with artist/album derived from folder structure.

Expected layout: <root>/<Artist>/<Album>/track.flac
Usage: tag_from_folders.py [root]   (default /mnt/music_library)
"""
import sys
from pathlib import Path

AUDIO_EXTS = {".flac", ".mp3", ".m4a", ".ogg", ".opus"}


def set_tags(path, artist, album):
    if path.suffix.lower() == ".flac":
        from mutagen.flac import FLAC
        f = FLAC(path)
        f["artist"] = [artist]
        f["album"] = [album]
        f.save()
    elif path.suffix.lower() == ".mp3":
        from mutagen.mp3 import MP3
        f = MP3(path)
        if f.tags is None:
            f.add_tags()
        f["TPE1"] = artist
        f["TALB"] = album
        f.save()
    elif path.suffix.lower() in (".m4a", ".mp4"):
        from mutagen.mp4 import MP4
        f = MP4(path)
        f["\xa9ART"] = (artist,)
        f["\xa9alb"] = (album,)
        f.save()
    else:
        from mutagen import File
        f = File(path, easy=True)
        if f is None:
            return False
        f.artist = artist
        f.album = album
        f.save()
    return True


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else "/mnt/music_library")
    tagged, skipped = 0, []
    for p in sorted(root.rglob("*")):
        if not (p.is_file() and p.suffix.lower() in AUDIO_EXTS):
            continue
        rel = p.relative_to(root)
        parts = rel.parts
        if len(parts) < 3:
            skipped.append(str(rel))
            continue
        tagged += set_tags(p, parts[0], parts[1])
    print(f"tagged {tagged} files")
    for s in skipped:
        print("skipped (not Artist/Album/file):", s)


if __name__ == "__main__":
    main()
