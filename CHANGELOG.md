# Changelog

All notable changes to SwiftPlayer will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.2] - Stable

### Added
- Picture in Picture support — pop the video out into a floating window with one click. Works system-wide and keeps playing while you use other apps. Button sits top-right, next to fullscreen and subtitles.
- Playback speed control — new menu in the controls bar with 0.5×, 0.75×, 1×, 1.25×, 1.5×, 2×. Speed persists across pause/resume. Fast-seek (hold left/right arrow) now multiplies the chosen speed instead of overriding it.
- Skip buttons — ⏪ 10s and ⏩ 10s on either side of play/pause. Clamps at the start and end of the file.
- Volume controls — volume slider and mute toggle in the controls bar. ↑/↓ arrow keys adjust volume in 5% steps, hold to ramp smoothly.
- Fullscreen button in the top-right corner.
- Filename display in the top-left corner while playing.
- Subtitle toggle in the subtitle panel to show/hide without unloading.

### Changed
- Seeking is faster and smoother — switched from sample-accurate seeking (`.zero` tolerance) to AVFoundation's default tolerance. Reduces decoding overhead during scrubbing, especially noticeable on Intel Macs. Thanks to u/Casfaber_ on Reddit for the suggestion.
- Play/pause state is now synced to the actual player instead of set optimistically — no more wrong icon when playback stalls.

### Fixed
- State no longer leaks between files on "Go Home" (subtitles, time, duration, filename now reset properly).
- Arrow key handling — holding left/right no longer fights itself between two seek loops.

### Distribution
- Now shipping both a `.dmg` and a `.app.zip` in Releases — pick whichever installation method you prefer.

## [2.1.1] - Stable

### Added
- Full Xcode project published to GitHub, with a rewritten README covering installation and building from source.
- Unit tests for the SRT, VTT, and ASS/SSA subtitle parsers.

### Fixed
- Real reverse playback — holding the Left Arrow key now plays backwards via AVPlayer's negative rate, instead of the previous simulated backward seek. Falls back to the old behavior on files that don't support reverse playback.
- Subtitle timestamp parsing — ASS/SSA cues using 3-digit millisecond timestamps were parsed 10x too large and appeared at the wrong time. Centisecond and millisecond forms are now both handled correctly.

## [2.1.0] - Stable

Initial stable release. Universal binary (Apple Silicon and Intel), minimum macOS 13.0 (Ventura).

[2.2]: https://github.com/scadavide55/SwiftPlayer/releases/tag/v2.2
[2.1.1]: https://github.com/scadavide55/SwiftPlayer/releases/tag/v2.1.1
[2.1.0]: https://github.com/scadavide55/SwiftPlayer/releases/tag/v2.1.0
