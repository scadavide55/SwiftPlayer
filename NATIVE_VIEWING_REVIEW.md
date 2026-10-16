# Native viewing controls review

Reviewed October 16, 2026. This batch implements the selected IINA-inspired
features independently using Apple frameworks and SwiftPlayer's existing engine.

## Separate checked changes

| Commit | Change | Checks before commit |
| --- | --- | --- |
| `e8793fc` | Display sleep activity while a window actually plays video; saved setting | Five tests, including native HD pause/replacement, audio-only exclusion, multiple activities, preference changes, and activity release |
| `b632233` | Main-actor annotation for the activity factory | Rebuilt and reran the five sleep tests; the reproduced compiler isolation warning disappeared |
| `c22893b` | Legacy subtitle encoding, import preview, successful-choice memory | Thirty-six combined sleep/parser/encoding/per-file/menu tests passed without skips; known Big5/GB18030/Shift-JIS bytes, Unicode BOMs, legacy memory decoding, failed reload preservation, Off, and native language restoration |
| `00fb4ad` | Window-owned viewing controls and native video layout | Thirteen tests passed, including all 100 PiP scenarios, actual native layer layout, Retina sizing, screen bounds, level restoration, foreign-window notification filtering, and native HD presentation size |
| `4cb080b` | Double-click fullscreen on the video surface | Eleven viewing/window/double-click tests passed; ordinary/modified clicks and control hit targets do not invoke the double-click callback; dismantling releases it |
| `f21e3fb` | Save/copy PNG with optional subtitles and user-selected destination write capability | Nine capture/menu tests passed, including real HD and 8K extraction, playing/paused transport preservation, EOF capture, caption rendering, global coordination, cancellation, clipboard preservation, and controller release |

## Implementation and bounds

- Each window owns its display-sleep activity. It is released on pause, failure,
  close, audio-only replacement, or disabling the preference. Activities aggregate
  through the operating system; stopping one window does not release another's.
- Subtitle input remains bounded to 16 MiB. Automatic reads Unicode; ambiguous
  legacy encodings require an explicit choice. Preview work is canceled when
  its encoding changes or the sheet closes. A failed reload does not erase
  captions, change the successful saved encoding, or enable subtitles from Off.
- Video scaling and aspect selection change native layer layout/gravity without
  adding a video composition or decoded-frame output. Original aspect is the
  default. Window presets map source pixels to display pixels and clamp to the
  visible screen. Fullscreen and floating level changes target the owning window;
  repeated fullscreen commands are gated during a transition.
- A plain left-button double-click on the native video surface requests
  fullscreen. Native hit testing leaves buttons and scrubber controls in charge
  of their own events. Modified clicks are preserved.
- Frame export snapshots the native clock, asset, and optional displayed text.
  It does not seek, pause, or replace the playing item. Explicit image extraction
  uses exact generator tolerance; ordinary player seeks and interactive previews
  keep their existing tolerance.
- Images are bounded to 8192 pixels per side. Full-resolution extraction is
  serialized across windows, including while canceled native/encoding work is
  unwinding. CoreText drawing and PNG encoding run off the main thread inside
  an autorelease pool. There is no full-resolution image cache. A large image
  still requires decoder, image, rendering, and compression buffers; the seek
  thumbnail cache's 8 MiB limit does not apply to export.
- PNG output uses sRGB SDR and the video's preferred orientation. Main-window
  stretching/cropping from Fit/Fill or aspect selection is excluded. Optional
  captions use current text/font/color/outline/background/position with scaled
  sizing; this is a separate text renderer, not a pixel-exact window screenshot.
  PiP rendering continues to use the system presentation.
- Save uses a system-selected PNG destination and an atomic write. The signed
  app remains sandboxed and now has user-selected read/write capability for
  export. Media reads and saved playback/subtitle bookmarks remain read-only
  in application code. No media file is rewritten. Cancellation is checked
  before writing; an atomic write already in progress may complete.

## Final validation

The final complete regression passed all 146 tests with zero failures and zero
skips, including the opt-in local HD/8K and generated chapter/audio fixtures.
All 900 unique numbered scenarios passed: 100 each for compatibility, core,
interaction, loading, memory, PiP, playback, seeking, and subtitles. The suite
completed in approximately 229 seconds.

The 100 memory-matrix post-cleanup snapshots ranged from 283 to 291 MiB in the
shared test process. These are not export/decoder peak measurements, a guaranteed
application memory limit, or a controlled comparison with earlier runs.

Final Release build and static analysis passed. All four shared-core platform
checks passed without warnings. The signed Release entitlements confirm the
sandbox and user-selected read/write capability. The Release log had no source
warnings; Xcode emitted its missing-AppIntents metadata notice.

The window, layer, mouse-event, save-to-file, clipboard, and extraction tests run
programmatically. Computer-use tools are unavailable in this continuation, so
manual checks of menu appearance, Spaces/PiP transitions, the encoding preview
sheet, and system save-dialog interaction are not claimed as complete.
Shared-core platform checks establish source availability, not mobile runtime
playback or platform UI behavior.

## Privacy

Test media, identifying filenames, local user paths, raw diagnostics, and actual
subtitle dialogue remain local. Captions used in assertions are generated test
text. Published changes contain no media or captured images. Save filenames
default to a generic name; images are exported only by explicit user actions.
