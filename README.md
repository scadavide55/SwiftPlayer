![Stars](https://img.shields.io/github/stars/scadavide55/SwiftPlayer)
![Release](https://img.shields.io/github/v/release/scadavide55/SwiftPlayer)
![Downloads](https://img.shields.io/github/downloads/scadavide55/SwiftPlayer/total)
![macOS](https://img.shields.io/badge/macOS-13.0%2B-blue?logo=apple)
![Swift](https://img.shields.io/badge/Swift-6.0-orange?logo=swift)
![License](https://img.shields.io/github/license/scadavide55/SwiftPlayer)
# SwiftPlayer

A minimal, fully native video and audio player for macOS built with SwiftUI and AVFoundation. No third-party dependencies—just Apple's own frameworks.

## Features

- **Zero dependencies** – Apple frameworks only; a small C audio callback uses lock-free gain updates
- **Hardware-accelerated decoding** – Video is decoded through AVFoundation/VideoToolbox, which on Apple Silicon is handled by the dedicated media engine for smooth, power-efficient playback
- **HEVC compatibility** – MP4/MOV/M4V files tagged `hev1` with VPS/SPS/PPS in their movie metadata open through a temporary `hvc1` compatibility copy. This preserves the original file, compressed video, audio, resolution, and quality. APFS uses a space-efficient clone; other volumes may require a full temporary copy. Temporary files are removed when playback closes or the file is replaced.
- **Intuitive controls** – Play/pause, scrubber with time display, and keyboard shortcuts
- **Pitch-preserving speed changes** – Playback uses AVFoundation's spectral time-pitch algorithm to keep voices and music at their original pitch as speed changes.
- **Subtitle support** – Embedded text tracks plus SRT, VTT, ASS/SSA, external PGS (`.sup`), and VobSub (`.idx` + `.sub`) files. Image subtitles retain their colors and positions, including in optional subtitle frame captures. VobSub import offers its available languages and remembers the paired read-only file references. Choose Off, Automatic, individual tracks, or an external file, and set a preferred language.
- **Subtitle appearance** – Choose a font, size, text color, outline, background opacity, and position with a live preview.
- **Audio languages** – Select an audio track or use a preferred language automatically.
- **Audio level controls** – Protect boosted peaks with a linked limiter, and optionally normalize quiet and loud passages. Peak protection is on by default; normalization is off.
- **After playback** – Stay at the end, rewind and pause, repeat the file, or close it, without a modal prompt.
- **Subtitle workflow** – Find matching files in folders you authorize, prefer your subtitle language, and adjust embedded or external subtitle timing.
- **Per-file choices** – Optionally remember audio/subtitle tracks, external subtitle references, and subtitle delay when reopening a file.
- **Seek previews** – Hover or drag over the timeline for a small thumbnail without seeking the playing video until you release the scrubber.
- **Native viewing controls** – Always on Top, Fit/Fill, aspect-ratio choices, Retina-aware window-size presets, and double-click fullscreen.
- **Frame capture** – Save or copy a PNG of the current video frame, optionally including styled text subtitles.
- **Legacy subtitle encodings** – Preview Big5, GB18030, or Shift-JIS subtitles before loading, and remember the successful encoding per media file.
- **Display sleep prevention** – Optionally keep the display awake only while video plays. Pausing, closing, or replacing it with audio-only playback releases the request.
- **Playback history** – Search watched files, filter unfinished/finished items, see progress, and explicitly continue from a saved position. Local history has configurable retention and clear/disable controls.
- **Live playback information** – Inspect playback/waiting state, reported buffer ranges, presentation size, and app-wide memory while the Playback information tab is visible.
- **Navigation and preferences** – Jump to a time, navigate chapters, reopen recent files, and optionally remember volume, mute, and playback position.
- **Media information** – Inspect codecs, resolution, frame rate, audio channels, and subtitle tracks from the Window menu.
- **Minimal UI** – Clean interface that fades away when idle, keeps focus on your content
- **Drag & drop** – Load media by dragging files directly onto the window
- **Keyboard navigation** – Left/Right seek (5-second jumps or continuous fast-forward/reverse), Up/Down adjust volume in 5-percentage-point steps, and Space plays/pauses. Volume defaults to a 200% ceiling; 0% mutes.
- **Frame stepping** – Control–Left/Right pauses and steps the video backward/forward by one native frame. Playback → Previous Frame/Next Frame provides the same controls where supported.

## Supported Formats

**Video:** MP4, MOV, M4V  
**Audio:** MP3, M4A, AAC, WAV, AIFF, CAF

## Installation

1. Download the latest `SwiftPlayer.app` from the [Releases page](https://github.com/scadavide55/SwiftPlayer/releases).
2. Move it to your `Applications` folder.
3. Launch it.

The app is **ad-hoc signed** (it has no Apple Developer Team ID), so macOS cannot verify the developer and Gatekeeper will block the first launch with a message along the lines of *"Apple cannot c[...]

**Option A — System Settings (works on macOS 15+)**

1. Launch the app and dismiss the Gatekeeper warning.
2. Open **System Settings** → **Privacy & Security**.
3. Scroll down and click **Open Anyway** next to SwiftPlayer.
4. The app will open, and you can use it normally on all future launches.

**Option B — Right-click to open (macOS 13–14 only)**

1. In Finder, right-click (or Control-click) `SwiftPlayer.app` and choose **Open**.
2. Click **Open** again in the confirmation dialog.

macOS remembers the exception, so subsequent launches work normally by double-clicking.

**Option C — Remove the quarantine attribute (all versions)**

```sh
xattr -dr com.apple.quarantine /Applications/SwiftPlayer.app
```

After that the app launches normally.

## Build from Source

Requirements: **Xcode 16 or later** and **macOS 13.0 or later**.

```sh
git clone https://github.com/scadavide55/SwiftPlayer.git
cd SwiftPlayer
open SwiftPlayer.xcodeproj
```

Select the `SwiftPlayer` scheme and press **Run** (⌘R). The project uses Xcode's file-system-synchronized groups, so no project-file edits are needed to add or rename source files.

To run the unit tests (subtitle parsers, playback lifecycle, and HEVC compatibility):

```sh
xcodebuild -project SwiftPlayer.xcodeproj -scheme SwiftPlayer test
```

To also verify decoding and seeking with a local 8192-pixel-wide video, set
`TEST_RUNNER_SWIFTPLAYER_TEST_MEDIA` to its absolute path when running the tests.
The default playback regression uses a small HEVC video generated by AVFoundation.
The opt-in 8K tests also repeat playback/seek/teardown cycles and record the test
process's physical memory footprint after cleanup; this is not a live playback
memory limit. Ordinary scrubber and keyboard seeks use AVFoundation's default
tolerance. Exact seeking is used only by the decoding regression tests.
The nine debugging matrices execute 100 numbered scenario/input combinations
per area. For the complete compatibility matrix, also set
`TEST_RUNNER_SWIFTPLAYER_TEST_HD_MEDIA` to a local 1920-pixel-wide `hev1` HEVC
sample. Its audio and subtitle track types are checked for preservation during
preparation. Test media remains local. See [the debugging review](DEBUG_REVIEW_800.md)
for the original eight areas, and [the core review](CORE_REVIEW_100.md) for the
additional core area. See [the playback improvements review](PLAYBACK_IMPROVEMENTS_REVIEW.md)
for the latest feature checks, results, and limitations.
Supported video resolutions and profiles still depend on the Mac's native decoder.
Retagging is a compatibility workaround, not a general HEVC conversion: streams
that depend on new parameter sets carried inside later frames may still fail.

Subtitle files load in the background, with a 16 MiB input limit. UTF-8 and
BOM-marked UTF-16 files are read automatically. The import preview and External
Text Encoding menu also support Big5, GB18030, and Shift-JIS without guessing
between ambiguous encodings. Replacing or closing playback cancels
pending preparation, seeks, subtitle loading, and held-key seeking, and releases
the previous media's subtitle and Picture in Picture resources.

External PGS image subtitles stream from files up to 128 MiB, with at most
30,000 captions and a 64 MiB retained compressed-data budget. Only the active
caption is rendered, with at most 32 MiB of decoded image pixels. Image
subtitles use their original colors and positions; font settings and text
encoding do not apply. They follow subtitle delay, Off, seeking, and video
scaling, and remain in the main window during Picture in Picture.
VobSub import requests both the index and image file through the system file
picker. Its language selector uses the subtitle-language preference while
Automatic is selected. Authorized-folder matching lists the index once, only
when its companion exists. Index files are limited to 2 MiB, image files to
512 MiB, and each caption read to 128 KiB; compressed retention and active image
limits match PGS. DVD 2-bit subpictures are supported. HD-DVD extensions,
custom-palette overrides, and unsupported control commands are rejected.

## Shared playback core

`SwiftPlayer/PlaybackCore` contains the AVPlayer state model, subtitle parser,
and HEVC preparation code, along with media preferences, audio processing, and
thumbnail generation, bounded history, and diagnostic sampling. It uses Foundation,
AVFoundation, Combine, CoreGraphics/CoreText, ImageIO, UniformTypeIdentifiers,
CoreFoundation, and Darwin without a presentation framework. Time formatting remains outside the
core with the macOS presentation code. This is a shared source group in the
existing app target, not a separate package or a completed mobile app.

With the corresponding SDKs installed, run `scripts/check-core-platforms.sh`
to type-check these sources for macOS 13 (Apple Silicon and Intel), iOS/iPadOS 17,
and visionOS 1. The check was verified with Xcode 27. These checks validate
source availability; mobile device decoding, audio sessions, interruption and
route handling, lifecycle integration, and platform presentation still need
app targets and runtime testing.

The additional core matrix runs 100 scenario/input combinations. Its complete
run requires both local media environment variables described above. See
[the core review](CORE_REVIEW_100.md) for the verified fixes and coverage limits.

## Playback menus and settings

- **File → Open File…** (`⌘O`) or **Open Recent** opens one file. Recent files use read-only security-scoped bookmarks, with up to ten entries. A multiple-file queue is deferred.
- **File → Playback History…** (`⇧⌘H`) searches up to 200 files, with All/Unfinished/Finished filters and per-file progress. Continue explicitly restores progress independently of automatic resume; finished files open from the beginning. Missing files remain listed until removed or expired. History is recorded by default, with 90-day retention; General settings offers 30/90/365 days, disable, and Clear History. Turning history off clears its list and progress. Clear/remove also invalidates existing playback sessions so they cannot silently recreate removed entries.
- **Playback → Jump to Time…** (`⌘J`) accepts seconds, minutes:seconds, or hours:minutes:seconds. Chapter navigation appears when the file supplies chapter titles. Changing position preserves pause.
- **Playback → Previous Frame / Next Frame** (`⌃←` / `⌃→`) pauses video and steps through its native timeline, including variable frame intervals. It cancels held-key seeking and pending ordinary seeks. Audio-only files and unsupported directions are disabled. Ordinary seeking retains the default AVFoundation tolerance. macOS may reserve these shortcuts for switching Spaces; if so, use the menu commands or change those assignments in System Settings → Keyboard → Keyboard Shortcuts → Mission Control.
- **Audio → Audio track** selects an embedded audio track. The preferred language applies while the selector is Automatic.
- **Subtitles → Subtitle track** offers Off, Automatic, embedded choices, and a loaded external file. Automatic prefers a full subtitle option in the preferred language, falling back to the first full option before forced-only captions. Explicit track choices take precedence over language preferences.
- **Subtitles → Appearance and Fonts…** styles decoded text captions in the main window. The caption popover also offers external-file loading and timing for embedded or external text. Positive delay displays captions later; negative delay displays them earlier, within a ±30-second range.
- **Subtitles → Find Matching Subtitles…** searches only folders added under Settings → Subtitle Files. Matching uses the media basename and optional language/forced-caption tags, without scanning subfolders. Automatic finding respects Off and explicit track choices. Option–Left/Right adjusts subtitle timing by 0.1 seconds.
- **Playback → After Playback** selects Stay at End, Rewind and Pause, Repeat File, or Close File. The same preference is available in General settings.
- **Video** offers Always on Top, Fit/Fill, Original/16:9/4:3/21:9/1:1 aspect ratios, and window-size presets. The 50%/100%/200% presets account for Retina scaling and fit within the screen's visible area. These presentation choices apply to the main window; PiP retains native video presentation. Always on Top is suspended in fullscreen and restored on exit.
- **Video → Capture Frame** saves a PNG through the system save dialog or copies it to the clipboard. Include Subtitles is off by default. Exports use the original video frame with its preferred orientation, independent of window scaling, at full resolution up to 8192 pixels per side; larger frames are downscaled. PNG output uses sRGB SDR color. Text captions use the current font, color, outline, background, and position, with size scaled for the exported image. No controls or window decorations are included.
- **Window → Media Information…** (`⌘I`) shows the current file's streams and duration. Select Playback for live state, waiting reason, selected/player/effective clock rates, native buffer flags, reported loaded ranges/time ahead, presentation size, and app memory across all windows. Player Rate is the native requested rate; Effective Clock Speed reads the media timebase and can be zero while waiting. Sampling runs once per second only while that tab is visible. Local files may not report loaded ranges; unavailable values are labeled accordingly. Stream frame rates are nominal media metadata; live renderer and dropped-frame counters are not collected.
- **SwiftPlayer → Settings…** (`⌘,`) saves language and appearance preferences, sets the maximum volume from 100% to 400% (200% by default), controls whether volume/mute are remembered, and enables optional automatic resume. Turning automatic resume off clears its separate saved positions. History progress is controlled separately. Automatic resume excludes positions near the start or end.

100% is the original audio level. Higher values amplify decoded audio through
AVFoundation audio taps, without changing the system volume or creating a
second audio playback clock. Peak protection is enabled by default in General settings:
a shared gain envelope preserves channel balance while keeping boosted peaks
below full scale. Disabling it restores hard clipping at the representable range.
Optional normalization adjusts level gradually, within a bounded gain range;
a quiet-input gate avoids trying to normalize silence or low-level noise.
These controls do not change pitch or introduce a second playback clock.
The audio graph stays in place when
volume changes, including when switching tracks. Lowering the configured
maximum clamps open players' volume while preserving mute.

Preferences, recent-file references, resume positions, and per-file track/timing
choices stay in local app storage. Turning off Remember tracks and subtitle
timing clears those saved per-file choices. Up to 100 files are remembered;
external subtitles and search folders use read-only security-scoped bookmarks.
Language preferences supply the fallback when a saved track is unavailable.
The selected external subtitle encoding is also remembered. Changing encoding
from the Subtitles menu reloads the file; a failed decode preserves existing
captions and the last successful encoding. Off stays Off during a reload.

History checkpoints progress at most once every ten seconds during playback,
with additional saves on pause, completed paused seeks, EOF, and close. Recording
starts only after a file becomes ready. Failed loads are not added. Entries,
read-only bookmarks, and progress stay in local app preferences; no media or
diagnostic logs are uploaded. History and automatic resume have separate clear
controls. Retention pruning runs when history is loaded, updated, or its retention
setting changes. See [the history and diagnostics review](HISTORY_DIAGNOSTICS_REVIEW.md)
for verification and limits.

Seek previews use a throttled native image generator with relaxed image-extraction
tolerance. Their memory-only image cache is limited to 32 thumbnails and 8 MiB,
and clears when the media closes or changes. This cache limit does not include
AVFoundation's internal decoder buffers. Audio-only files retain a time preview.

Full-resolution frame capture runs separately from seek previews and permits
one capture at a time across player windows. Image rendering/PNG encoding runs
off the main thread and keeps no full-resolution image cache. Closing or replacing
media cancels extraction and pending work; an atomic file write already in
progress may finish. Explicit frame extraction uses exact image-generator
tolerance without changing ordinary playback seeking. See
[the native viewing review](NATIVE_VIEWING_REVIEW.md) for checks and limitations.

Keep the display awake while video plays is enabled by default in General
settings. Each playing video window owns an activity, so pausing one window
does not release another's request. Audio-only playback does not hold a display
activity. The setting is applied while playback is running.
The main window uses decoded embedded text so appearance controls also work with
tx3g captions. Picture in Picture uses native embedded captions and the system's
appearance; external-file captions remain in the main window. Image-based or
otherwise unsupported subtitle codecs still depend on AVFoundation support.

For additional chapter, language, and paused-resume tests, the optional
`scripts/make-playback-test-fixture.sh output.m4a` generator creates a small
synthetic audio fixture using ffmpeg. Set
`TEST_RUNNER_SWIFTPLAYER_TEST_CHAPTER_MEDIA` to the fixture's absolute path.
ffmpeg is a fixture-generation tool only, not an application dependency.
See [the controls review](PLAYER_CONTROLS_REVIEW.md) for validation and limits.

## Compatibility

Runs on both **Apple Silicon** and **Intel-based Macs**.  
Minimum macOS version: **13.0 (Ventura)**.

Tested on: MacBook Air 2020 (Intel Core i3, dual-core) and MacBook Air M5 (2026).

## Usage

1. Launch the app and select a file (or drag one onto the window)
2. Hover your mouse to reveal controls
3. Controls hide automatically after 5 seconds of inactivity
4. Use the subtitle panel to load subtitles and adjust delay

## Keyboard Shortcuts

- **Space** – Play/pause
- **Left/Right Arrow** – Jump back/forward 5 seconds (hold to fast-seek)
- **Control–Left/Right Arrow** – Pause and step backward/forward one video frame
- **Up/Down Arrow** – Adjust volume by 5 percentage points
- **Option–Left/Right Arrow** – Display subtitles 0.1 seconds earlier/later
- **Control–Command–F** or **double-click the video** – Toggle fullscreen for that player window
- **Home button** – Return to file selection screen

## License

Released under the [MIT License](LICENSE).

---

Built with Swift 6.3.3 using Xcode 26.6.
