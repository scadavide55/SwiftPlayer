# SwiftPlayer

A minimal, fully native video and audio player for macOS built entirely with SwiftUI and AVFoundation. No third-party dependencies—just Apple's own frameworks.

## Features

- **Zero dependencies** – Pure Swift using only AVFoundation and SwiftUI
- **Hardware-accelerated playback** – Leverages Apple Silicon's dedicated video decoder for smooth, power-efficient performance
- **Intuitive controls** – Play/pause, scrubber with time display, and keyboard shortcuts
- **Subtitle support** – SRT, VTT, and ASS/SSA formats with adjustable delay
- **Minimal UI** – Clean interface that fades away when idle, keeps focus on your content
- **Drag & drop** – Load media by dragging files directly onto the window
- **Keyboard navigation** – Arrow keys for seeking (5-second jumps or continuous fast-forward/reverse), space to play/pause

## Supported Formats

**Video:** MP4, MOV, M4V  
**Audio:** MP3, M4A, AAC, WAV, AIFF, CAF

## Compatibility

Runs on both **Apple Silicon** and **Intel-based Macs**  
Tested on: MacBook Air 2020 (Intel i3 Duo Core) and MacBook Air M5 ( 2026) .

## Usage

1. Launch the app and select a file (or drag one onto the window)
2. Hover your mouse to reveal controls
3. Controls hide automatically after 5 seconds of inactivity
4. Use the subtitle panel to load subtitles and adjust delay

## Keyboard Shortcuts

- **Space** – Play/pause
- **Left/Right Arrow** – Jump back/forward 5 seconds (hold to fast-seek)
- **Home button** – Return to file selection screen

---

Built with Swift 5.9+ on macOS 26.5
