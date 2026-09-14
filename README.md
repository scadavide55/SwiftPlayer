![Stars](https://img.shields.io/github/stars/scadavide55/SwiftPlayer)
![Release](https://img.shields.io/github/v/release/scadavide55/SwiftPlayer)
![Downloads](https://img.shields.io/github/downloads/scadavide55/SwiftPlayer/total)
![macOS](https://img.shields.io/badge/macOS-13.0%2B-blue?logo=apple)
![Swift](https://img.shields.io/badge/Swift-6.0-orange?logo=swift)
![License](https://img.shields.io/github/license/scadavide55/SwiftPlayer)
# SwiftPlayer

A minimal, fully native video and audio player for macOS built entirely with SwiftUI and AVFoundation. No third-party dependencies—just Apple's own frameworks.

## Features

- **Zero dependencies** – Pure Swift using only AVFoundation and SwiftUI
- **Hardware-accelerated decoding** – Video is decoded through AVFoundation/VideoToolbox, which on Apple Silicon is handled by the dedicated media engine for smooth, power-efficient playback
- **Intuitive controls** – Play/pause, scrubber with time display, and keyboard shortcuts
- **Subtitle support** – SRT, VTT, and ASS/SSA formats with adjustable delay
- **Minimal UI** – Clean interface that fades away when idle, keeps focus on your content
- **Drag & drop** – Load media by dragging files directly onto the window
- **Keyboard navigation** – Arrow keys for seeking (5-second jumps or continuous fast-forward/reverse), space to play/pause

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

To run the unit tests (subtitle parsers):

```sh
xcodebuild -project SwiftPlayer.xcodeproj -scheme SwiftPlayer test
```

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
- **Home button** – Return to file selection screen

## License

Released under the [MIT License](LICENSE).

---

Built with Swift 6.3.3 using Xcode 26.6.
