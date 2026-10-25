<div align="center">

# 🎬 SwiftPlayer

**A minimal, fully native video and audio player for macOS.**
Built entirely with SwiftUI and AVFoundation. No third-party dependencies, just Apple's own frameworks.

[![Stars](https://img.shields.io/github/stars/scadavide55/SwiftPlayer?style=for-the-badge&logo=github)](https://github.com/scadavide55/SwiftPlayer/stargazers)
[![Release](https://img.shields.io/github/v/release/scadavide55/SwiftPlayer?style=for-the-badge)](https://github.com/scadavide55/SwiftPlayer/releases)
[![Downloads](https://img.shields.io/github/downloads/scadavide55/SwiftPlayer/total?style=for-the-badge)](https://github.com/scadavide55/SwiftPlayer/releases)

![macOS](https://img.shields.io/badge/macOS-13.0%2B-blue?style=flat-square&logo=apple)
![Swift](https://img.shields.io/badge/Swift-6.0-orange?style=flat-square&logo=swift)
![Apple Silicon + Intel](https://img.shields.io/badge/Apple%20Silicon%20%2B%20Intel-supported-green?style=flat-square)
[![License](https://img.shields.io/github/license/scadavide55/SwiftPlayer?style=flat-square)](LICENSE)

[**⬇️ Download**](https://github.com/scadavide55/SwiftPlayer/releases) · [**📋 Changelog**](CHANGELOG.md) · [**🛠 Build from source**](#-build-from-source)

</div>

---

## ✨ What's new in 2.3

- 🕘 **Video history with resume**: recent files on the start screen, each picks up where you stopped
- 🎨 **More modern UI**
- 🛠 **Intel stability and performance fixes**

See the full [changelog](CHANGELOG.md).

---

## 🚀 Features

| | Feature | Details |
|---|---|---|
| 📦 | **Zero dependencies** | Pure Swift, using only AVFoundation and SwiftUI |
| ⚡ | **Hardware-accelerated decoding** | Decoded through AVFoundation/VideoToolbox; on Apple Silicon the dedicated media engine handles it for smooth, power-efficient playback |
| 🎛 | **Intuitive controls** | Play/pause, scrubber with time display, keyboard shortcuts |
| 💬 | **Subtitle support** | SRT, VTT and ASS/SSA, with adjustable delay |
| 🫥 | **Minimal UI** | Clean interface that fades away when idle, so the focus stays on your content |
| 🕘 | **Video history** | Recent files on the start screen, each resumes where you stopped |
| 🖱 | **Drag & drop** | Load media by dragging files onto the window |
| ⌨️ | **Keyboard navigation** | Arrow keys for seeking (5-second jumps or continuous fast-forward/reverse), space to play/pause |

### 🎞 Supported formats

| Type | Formats |
|---|---|
| **Video** | `MP4` `MOV` `M4V` |
| **Audio** | `MP3` `M4A` `AAC` `WAV` `AIFF` `CAF` |

---

## 📥 Installation

1. Download the latest `SwiftPlayer.app` from the [Releases page](https://github.com/scadavide55/SwiftPlayer/releases).
2. Move it to your `Applications` folder.
3. Launch it.

> [!IMPORTANT]
> The app is **ad-hoc signed** (it has no Apple Developer Team ID), so macOS cannot verify the developer and Gatekeeper will block the first launch with a message along the lines of *"Apple cannot check it for malicious software."* This is expected. Use one of the options below to open it once.

<details>
<summary><b>Option A: System Settings</b> (macOS 15+)</summary>

1. Launch the app and dismiss the Gatekeeper warning.
2. Open **System Settings** → **Privacy & Security**.
3. Scroll down and click **Open Anyway** next to SwiftPlayer.
4. The app will open, and you can use it normally on all future launches.

</details>

<details>
<summary><b>Option B: Right-click to open</b> (macOS 13–14 only)</summary>

1. In Finder, right-click (or Control-click) `SwiftPlayer.app` and choose **Open**.
2. Click **Open** again in the confirmation dialog.

macOS remembers the exception, so subsequent launches work normally by double-clicking.

</details>

<details>
<summary><b>Option C: Remove the quarantine attribute</b> (all versions)</summary>

```sh
xattr -dr com.apple.quarantine /Applications/SwiftPlayer.app
```

After that the app launches normally.

</details>

---

## 🛠 Build from source

**Requirements:** Xcode 16 or later, macOS 13.0 or later.

```sh
git clone https://github.com/scadavide55/SwiftPlayer.git
cd SwiftPlayer
open SwiftPlayer.xcodeproj
```

Select the `SwiftPlayer` scheme and press **Run** (<kbd>⌘</kbd> <kbd>R</kbd>). The project uses Xcode's file-system-synchronized groups, so no project-file edits are needed to add or rename source files.

Run the unit tests (subtitle parsers):

```sh
xcodebuild -project SwiftPlayer.xcodeproj -scheme SwiftPlayer test
```

---

## 💻 Compatibility

| | |
|---|---|
| **Architectures** | Apple Silicon and Intel |
| **Minimum macOS** | 13.0 (Ventura) |
| **Tested on** | MacBook Air 2020 (Intel Core i3, dual-core) · MacBook Air M5 (2026) |

---

## 📖 Usage

1. Launch the app and select a file (or drag one onto the window).
2. Hover your mouse to reveal controls.
3. Reopen recent files from the start screen; playback resumes where you stopped.
4. Controls hide automatically after 5 seconds of inactivity.
5. Use the subtitle panel to load subtitles and adjust delay.

### ⌨️ Keyboard shortcuts

| Key | Action |
|---|---|
| <kbd>Space</kbd> | Play / pause |
| <kbd>←</kbd> / <kbd>→</kbd> | Jump back / forward 5 seconds (hold to fast-seek) |
| <kbd>↑</kbd> / <kbd>↓</kbd> | Volume up / down |
| **Home button** | Return to file selection screen |

---

## 📄 License

Released under the [MIT License](LICENSE).

<div align="center">

<sub>Built with Swift 6.3.3 using Xcode 26.6.</sub>

</div>
