# Native frame stepping review

Reviewed October 16, 2026.

Control–Left/Right invokes Previous Frame/Next Frame for the focused player.
The same commands appear under Playback and are disabled for audio-only media,
unready items, and unsupported directions. Each command pauses playback, stops
held-key seeking, invalidates old seek completions, and uses the native
`AVPlayerItem.step(byCount:)` command. Ordinary seeking keeps its default
tolerance. Native frame timestamps drive stepping; nominal frame rate is not
used to calculate a destination. Repeated steps while already paused do not
force a history/resume preferences write per frame.

The existing native time observer updates position and text captions after a
step. Selected playback speed and pitch-preservation settings remain unchanged;
pressing Play resumes at the selected speed. Closing or replacing media uses
the existing cancellation and decoder teardown. No additional production video
output, frame cache, timer, or playback clock was introduced.

## Verification

Before commit, all 48 focused frame-stepping, lifecycle, menu, and interaction
tests passed without failures or skips. This includes 100 numbered interaction
scenarios. The six added tests cover:

- Control arrows, key repeats, additional modifier rejection, ordinary arrow
  routing, and callback release on dismantling.
- Audio-only, unready, invalid-direction, replacement, and closed states.
- Generated variable-frame-rate HEVC with alternating frame intervals: exact
  forward/backward timestamps, three rapid steps, paused transport, menu
  enablement, and caption updates.
- Pausing active playback without changing selected speed, canceling a held
  reverse seek and an ordinary seek, and rejecting stale seek completions.
- Beginning/end boundaries without invoking the automatic Close end action.
- Local 8K stepping against adjacent compressed video-sample timestamps.

Native frame-accuracy tests attach a video output, corresponding to an active
video presentation. A transport-only player without video output did not
reliably step by video-frame intervals. The app already supplies its native
player layer; production stepping adds no second video output. The 8K test
reads at most 128 compressed sample buffers from the beginning to obtain real
timestamps, avoiding partial samples introduced by a clipped reader range.
All diagnostic exploration remained local.

All four shared-core source platform checks passed: macOS on Apple Silicon and
Intel, iOS/iPadOS, and visionOS. These are availability checks, not device
runtime or mobile UI verification.

The complete regression passed all 168 tests with zero failures or skips and
no test-host restart, including local HD/8K and generated chapter/audio checks.
All 900 unique numbered scenarios passed across the nine debugging areas. Test
execution took approximately 240 seconds. The memory matrix's 100 post-cleanup
process-footprint samples ranged from 375 to 383 MiB; these include framework
caches in the shared test process and are not a controlled comparison against
earlier runs or decoder-peak measurements.

Final Release build and static analysis passed without warnings.

Computer-use tools are unavailable in this continuation. Physical-key/menu
visual checks remain pending. macOS may consume Control–Left/Right for switching
Spaces before delivery to the app; the Playback menu provides an alternative,
and users can change those system shortcut assignments if desired. No system
keyboard settings were changed.

## Privacy

Only generated fixture content and generic test assertions are committed.
Actual media, identifying filenames, local media paths, captured images, and
raw diagnostic logs are excluded from published changes.
