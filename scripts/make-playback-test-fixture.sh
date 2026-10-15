#!/bin/bash
set -euo pipefail
if [[ $# -ne 1 ]]; then
    echo "Usage: $0 output.m4a" >&2
    exit 1
fi
command -v ffmpeg >/dev/null || { echo "This optional test-fixture generator requires ffmpeg." >&2; exit 1; }
fixture_metadata="$(mktemp "${TMPDIR:-/tmp}/SwiftPlayer-chapters.XXXXXX")"
trap 'rm -f "$fixture_metadata"' EXIT
cat > "$fixture_metadata" <<'META'
;FFMETADATA1
[CHAPTER]
TIMEBASE=1/1000
START=0
END=10000
title=First Chapter
[CHAPTER]
TIMEBASE=1/1000
START=10000
END=20000
title=Second Chapter
META
ffmpeg -hide_banner -loglevel error -nostdin \
    -f lavfi -i 'anullsrc=r=48000:cl=mono' \
    -f lavfi -i 'anullsrc=r=48000:cl=mono' \
    -f ffmetadata -i "$fixture_metadata" \
    -map 0:a -map 1:a -map_metadata 2 -map_chapters 2 \
    -metadata:s:a:0 language=eng -metadata:s:a:1 language=jpn \
    -t 20 -c:a aac -movflags +faststart "$1"
