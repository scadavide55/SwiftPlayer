# Viewer controls and playback review — October 17, 2026

## Changes

- Viewer menus are Play, Video, Audio, and Subtitles, in that order. Fullscreen is in Video. AppKit's regenerated View menu is removed while Edit, Window, and Help remain.
- Play / Pause uses Space. Control–Up/Down changes the selected speed by 0.05×, from 0.05× to 4×. Preset choices remain available. Plain Up/Down still changes Mac system volume, whose maximum remains 100%.
- Save Frame uses F5 and honors Include Subtitles. Both saving with subtitles and saving without them remain supported and documented in the guide.
- Preferred Language is first in Audio and Subtitles. Fonts, styling, and the default external text encoding are in Settings. Import previews can override the encoding; remembered per-file choices take priority.
- Forced aspect ratios, percentage window sizes, the Home button, the explicit New Player Window command, and audio normalization are removed. Native proportions, ordinary resizing, fullscreen, peak protection, troubleshooting, history, subtitle matching, and frame stepping remain.
- Opening another file creates another independent player when the current window already has media. Duplicate files can play in separate windows. The last window closed determines saved progress, including when one copy has finished and unloaded.
- Stop at End detaches the player item and native media selections, cancels tasks, clears subtitle buffers, and removes temporary preparation files. It retains lightweight file information and completed history. Replay reloads from the beginning; backward navigation reloads paused at its requested target. Repeat File keeps playback loaded and restarts it.
- Tabs and Picture in Picture remain available. Tabs share one window and show the selected player; separate windows allow simultaneous viewing. Picture in Picture is a floating video window; external subtitle files remain in the main player.

## Confirmed bug

Peak protection was bypassed at ordinary application gain because the C audio callback returned before applying its limiter. A generated stereo regression failed before the fix and passed afterward. The fix was verified and committed separately before normalization was removed. The limiter reduces digital peaks and clipping; physical output loudness also depends on the Mac volume and the connected output device.

## Verification

- Full Debug regression: **223 test methods passed, zero failures, zero skips**, including all opt-in local 8K, HD, navigation, consistency, and chapter checks.
- **900/900 matrix scenarios passed**: 100 each for loading, compatibility/rendering, playback, seeking/scrubbing, subtitles, Picture in Picture, interaction, memory, and shared core.
- Native core platform checks passed for macOS Apple Silicon, macOS Intel, iOS/iPadOS, and visionOS.
- Release build and static analysis passed.
- Fresh Periphery scan found **zero unused declarations or imports**.

Native UI checks used an anonymous generated clip in an isolated app:

- View is absent; Fullscreen enters from Video and exits through its shortcut.
- Space pauses playback. Three Control–Up presses change 1× to 1.15× while paused without adjusting system volume.
- F5 opens Save Current Frame.
- Opening the same file again creates a second player window.
- Preferred Language appears first in both menus, and subtitle encoding/styling appear in Settings.

Focused regressions also confirm item release with a weak reference, clearing subtitle buffers at completion, paused consecutive navigation after unloading, Replay with a new item, Repeat with the same item, speed changes during playing and paused states, and last-close progress in both window orders.

The matrix rounds are distinct scenario/input combinations, rather than repeated identical scans. Local media identifiers, media contents, paths, screenshots, and raw diagnostic logs are excluded from this report and published changes. The existing project-file formatting change was preserved and excluded from these commits.
