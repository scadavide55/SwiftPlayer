# Expanded external subtitle review

Reviewed October 16, 2026. The app continues to use AVFoundation and Apple
frameworks only. New codec/rendering code runs outside the playback thread.

## Checked commits

| Commit | Change | Verification before commit |
| --- | --- | --- |
| `2932768` | Bounded PGS image subtitle pipeline, preview, video overlay and optional PNG composition | 24 PGS/parser/selection tests passed without skips |
| `bbf592c` | Paired VobSub files, language selection, saved companion access and folder matching | 27 VobSub/PGS/preferences/history/workflow tests passed without skips, with local fixtures enabled |
| `2694ae5` | Native ASS/SSA styling, position, layers, movement and simple fades; appearance override | 35 ASS/parser/image/encoding tests passed without skips; a generated PNG was visually inspected |
| `dea8cbb` | Correct standard-definition PGS color conversion | A red SD palette fixture failed with an unwanted green component before the correction; 31 subtitle tests passed afterward, including distinct SD/HD expectations |
| `18974ae` | Capture captions at the native capture clock rather than using a potentially stale overlay | An inactive image caption incorrectly changed the saved PNG before the fix; 20 capture/image/ASS tests passed afterward, including active captions whose UI image has not arrived yet and local HD/8K exports |

The final full regression passed all 182 tests with zero failures or skipped
tests and no test-host restart, including the local HD/8K and generated chapter/
audio checks. All 900 unique numbered scenarios passed: 100 each for
compatibility, core, interaction, loading, memory, PiP, playback, seeking and
subtitles. Test execution took approximately 237 seconds. The memory matrix's
100 post-cleanup process-footprint samples ranged from 461 to 469 MiB. These
include shared-process framework/font/decoder caches and are not a controlled
comparison with earlier runs or decoder-peak measurements.

Shared-core source availability checks passed without warnings for macOS on
Apple Silicon and Intel, iOS/iPadOS, and visionOS. Final Release build and static
analysis passed without warnings.

## PGS and VobSub

PGS `.sup` files retain palette colors, alpha, canvas placement, fragmented
objects, crop regions, and window clipping. Empty display sets clear captions;
repeated clears cannot extend an already ended caption. Palette conversion uses
BT.601 for presentations up to 576 lines and BT.709 for larger presentations.
Input streams are limited to 128 MiB and 200,000 packets; retained compressed
caption data is limited to 64 MiB and 30,000 captions. Object-state storage is
limited to 64 objects/16 MiB, with at most eight palettes and two display objects.

VobSub requires the `.idx` index and `.sub` MPEG program-stream file. The file
picker requests access to both. Import offers indexed language tracks; Automatic
uses the subtitle-language preference, then the index default. Explicit choices
and both read-only file bookmarks are remembered with per-file subtitle settings.
Existing single-file bookmarks remain decodable. Folder matching lists an index
once only when its regular, non-symlink companion exists.

The decoder handles MPEG-1/2 private-stream PES packets, reassembles matching
substreams, reads DVD display/control sequences, and decodes alternating 2-bit
RLE fields with palette/alpha changes. Index files are limited to 2 MiB, image
files to 512 MiB, reads per caption to 128 KiB, and aggregate reads to 1 GiB.
Control traversal, cue counts and retained compressed data are bounded. HD-DVD
extensions, custom-color overrides and unsupported commands are rejected rather
than presented with invented colors or timing.

Images are decoded only for the active caption, with at most 32 MiB of final
decoded image pixels. No movie-length decoded bitmap cache is kept. The image
overlay follows Fit/Fill and aspect settings, subtitle delay, seeking and Off.
Font/encoding choices do not restyle image captions. Decode work is canceled
when the caption/file changes or closes; old task results cannot replace a newer
caption. Optional subtitle frame capture renders from the capture clock and
uses the global existing single-export bound.

An independent local check used FFmpeg to decode a generated PGS source and
encode a DVD subpicture in an MPEG program stream. SwiftPlayer then decoded that
VobSub stream with matching image dimensions and placement. FFmpeg is a test
tool only and is not linked or bundled into the application.

## ASS/SSA scope

The parser honors declared style/event field order, script canvas, installed
font names and sizes, primary/outline/shadow colors and alpha, bold, italic,
underline, outlines, shadows, opaque boxes, alignment, margins, positions,
layers, font scaling/spacing/rotation, movement and simple fades. SSA alignment
values are mapped to ASS anchors. Text commas and Unicode are preserved.
Concurrent events are composed by layer, with basic stacking for unpositioned
captions. Pausing freezes time-dependent rendering; the renderer samples the
media clock at most ten times per second and keeps the previous animation frame
until its replacement is ready.

Appearance offers **Use styles and positions from ASS/SSA files**, enabled by
default. Disabling it uses the existing plain-text font/appearance controls.
The preference persists locally. Unsupported effect tags produce a status
message, and vector drawing payloads are not displayed as dialogue.

This is a defined native subset, not full libass compatibility. Karaoke effects,
animated transforms, vector rendering, clipping effects, complex collision
rules and embedded font attachments are not implemented. Installed-font
fallback and CoreText layout may differ from a libass renderer.

Text inputs retain the 16 MiB file bound. Parsing limits styles to 256, events to
30,000, runs to 256 per event and 100,000 per document, and dialogue to 8,192
characters per event. Rendered frames are at most 1920 by 1080 pixels, with at
most 64 active events and 32,768 UTF-16 units processed per frame. There is no
additional playback clock or per-frame preferences write.

## Limits and privacy

These additions handle external files. They do not add MKV/container support or
extraction/decoding of unsupported embedded subtitle tracks. External subtitles
remain in the main player window during native Picture in Picture. Text `.sub`
formats such as MicroDVD/SubViewer, TTML, SAMI and broadcast subtitles are not
added by this change; `.sub` here means the image companion in a VobSub pair.

Computer-use tools are unavailable in this continuation. Native file-picker,
language-picker, menu and fullscreen-layout interaction checks remain pending;
the generated CoreText composition was inspected visually. Platform checks
establish source availability, not mobile device playback or completed mobile UI.

Only generated subtitle content and generic assertions are committed. Actual
media, identifying filenames, user paths, captured media images and raw logs
remain local. No telemetry, subtitle download service or network access is added.

Protocol/behavior references: [FFmpeg PGS decoder](https://github.com/FFmpeg/FFmpeg/blob/master/libavcodec/pgssubdec.c),
[FFmpeg DVD decoder](https://github.com/FFmpeg/FFmpeg/blob/master/libavcodec/dvdsubdec.c),
and [Aegisub ASS tag documentation](https://aegisub.org/docs/latest/ass_tags/).
