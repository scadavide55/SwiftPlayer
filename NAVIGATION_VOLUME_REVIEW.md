# Navigation and system-volume review

## Reproduced problems and fixes

| Problem | Verified change | Commit |
|---|---|---|
| Relaxed relative seeks could land on the same keyframe, swallowing repeated navigation commands. Audio-only tests missed the video failure. | Bound relative seeks to a non-zero tolerance of at most 0.25 seconds; verify both native position and decoded frames. Timeline seeks retain native default tolerance. | `f3b8d74` |
| A settled navigation command could use an older UI timestamp. | Use the native media clock after a seek settles; accumulate pending commands against their requested target. | `7460332` |
| Focused controls could consume player keys. | Handle keys within the owning player window while preserving text editing and clearing holds during teardown. | `da6551d` |
| Volume controls affected application gain rather than the requested Mac output volume. | Share a Core Audio output-device controller across windows; clamp to 0–100%, observe external changes and output switching, and disable unavailable hardware controls. | `7da04d2` |
| Held navigation used inconsistent forward-rate and reverse-jump behavior. | Jump immediately, wait 0.5 seconds, then repeat every 0.1 seconds in both directions. | `10badf6` |
| Sleeping after each seek added seek-handling cost to every repeat interval. | Anchor repeat deadlines to the original press rather than the end of the previous seek. | `54dd4e2` |
| Native reverse playback reaching the start incorrectly marked the file finished and displayed the end position. | Treat the reverse boundary separately; preserve position zero without running forward completion actions. | `33e304c` |
| Fast native playback needed a shortcut distinct from repeated jumps. | Shift + Left/Right holds select native ±4× playback, with jump fallback for unsupported formats and restoration on release. | `fe7d1ff`, `fc02f7c` |

Each change was checked before its individual commit. The original application-gain API remains available to the shared playback core; the Mac interface uses system volume and starts with unity application gain.

## Keyboard behavior

| Gesture | Behavior |
|---|---|
| Left / Right tap | −5 / +5 seconds |
| Single hold | Initial 5-second jump; another at 0.5 seconds, then one every 0.1 seconds |
| Shift + Left / Right hold | Initial normal 5-second jump; after 0.5 seconds, native −4× / +4× playback where supported |
| Control + Left / Right | Pause and step one native video frame |
| Up / Down | Mac output volume −5 / +5 percentage points, clamped to 0–100% |

Native autorepeat events do not add jumps or restart the hold delay. Unmodified rapid taps remain ordinary jumps; Shift selects native shuttle playback. Releasing a hold restores the prior playing/paused state and selected playback speed, unless a new transport command or forward completion has superseded it. Jump cadence is a scheduling target; decoding determines visible update frequency.

## Validation

- Generated long audio verifies the initial delay, repeat intervals, both directions and playing/paused restoration.
- A regression adds 25 ms of synchronous handling cost per jump. The old timer produced six actions instead of seven in the measurement window; fixed deadlines produce all seven. Timing checks allow late execution followed by catch-up while measuring drift against the scheduled deadlines.
- Opt-in local long-GOP video verifies consecutive and rapid taps, normal and Shift holds, native fast forward/reverse, decoded frames, and release against the native timebase.
- Reverse-boundary checks include the Close after playback setting and restoration from both playing and paused states.
- Keyboard tests cover control focus, editable text, modifier routing, rapid unmodified presses, native autorepeat, and dismantling.
- System-volume tests cover fixed limits, arbitrary existing levels, mute restoration, output changes, unavailable controls, failures, and controller release. Live hardware readback confirms that Up/Down and mute affect the Mac output.
- Final full regression: **215 tests passed, zero failures, zero skips**, including the opt-in local 8K checks.
- All **900 matrix scenarios passed**: 100 each for compatibility, core state, interaction, loading, memory, PiP, playback, seeking, and subtitles.
- The handling-cost timing regression also passed ten repeated runs.
- Release **build and static analysis passed**. Shared-core checks passed for macOS arm64, macOS Intel, iOS/iPadOS, and visionOS.
- The rebuilt Mac app passed live Shift forward/reverse holds while playing and paused, including state restoration on release. Earlier live checks covered ordinary consecutive arrows, ordinary holds, and real system-volume/mute readback.

Media, filenames, local paths, raw logs, screenshots, and copied media are excluded from published changes.

## API references

- [Apple: AVPlayer seeking and tolerances](https://developer.apple.com/documentation/avfoundation/avplayer/seek(to:tolerancebefore:toleranceafter:))
- [Apple: fast reverse capability](https://developer.apple.com/documentation/avfoundation/avplayeritem/canplayfastreverse)
- [Apple: playback rate](https://developer.apple.com/documentation/avfoundation/avplayer/rate)
- [Apple: virtual main output volume](https://developer.apple.com/documentation/audiotoolbox/kaudiohardwareservicedeviceproperty_virtualmainvolume)
