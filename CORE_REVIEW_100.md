# Shared playback core review

Scope: **100 new focused core rounds**, each a distinct deterministic
scenario/input combination with behavioral assertions. These are not 100
whole-suite repetitions. The existing eight-area matrices run another 800
combinations during the full regression run.

Validation completed October 15, 2026 on macOS with Apple Silicon and Xcode 27.
All 100 new core rounds passed, alongside the previous 800 rounds. The full
suite passed 82 XCTest methods with zero failures and zero skips, including
the opt-in HD and 8K checks. Release build and static analysis passed.

## Verified fixes

Each defect was reproduced, fixed, and checked before its separate commit.

| Commit | Defect | Verified behavior |
| --- | --- | --- |
| `8d286f6` | Native AVPlayer pause and speed changes left shared playback intent and selected speed stale; a later speed selection could resume a native pause | Read the latest native rate, synchronize intent and ordinary selected speed, and preserve internal held-key intent; native-control, lifecycle, playback, and seeking regressions passed |
| `7b2fa73` | Scanning a container with many tiny top-level boxes retained Foundation read buffers until the worker returned | Drain read buffers per metadata box; the one-million-box fixture's incremental process footprint fell from about 53 MiB to below 1 MiB in the focused comparison; all container tests passed |
| `a5d7afa` | Rejecting NaN or infinite volume restored the valid value but unexpectedly removed mute | Preserve mute during invalid-value rollback; nine volume/invalid-value combinations and normal volume behavior passed |
| `2c35ab7` | Captions displayed WebVTT named escapes literally | Strip actual markup first, decode the six WebVTT named escapes once, preserve literal encoded tags, unknown escapes, emoji, and combining marks; parser tests and all 100 subtitle rounds passed |
| `adaae19` | Native volume and mute changes did not update the shared audio state | Observe both properties, read their latest values, and suppress the model's unmute-on-adjustment policy during synchronization; the native audio regression and lifecycle suite passed |

The caption escape set follows the [WebVTT specification](https://www.w3.org/TR/webvtt1/).
Playback intent remains separate from whether media is currently advancing,
consistent with [Apple's transport behavior guidance](https://developer.apple.com/documentation/avfoundation/controlling-the-transport-behavior-of-a-player).
Ordinary scrubber and keyboard seeks retain AVFoundation's default tolerance.

## Shared source boundary

`SwiftPlayer/PlaybackCore` holds PlayerModel, SubtitleParser, and
HEVCCompatibility. The source group imports Foundation, AVFoundation, Combine,
and Darwin. Time formatting remains in the presentation sources. Decoder
failure text no longer assumes the device is a Mac.

`scripts/check-core-platforms.sh` rejects presentation framework imports and
type-checks the core for these deployment targets with the installed SDKs:

| Source target | Result |
| --- | --- |
| macOS 13, Apple Silicon | PASS |
| macOS 13, Intel | PASS |
| iOS/iPadOS 17, ARM64 | PASS |
| visionOS 1, ARM64 | PASS |

This remains a shared source group inside the existing macOS app target. It is
not yet an independent module, package, iOS app, or visionOS app. Availability
checks do not establish device decoding capability or mobile runtime behavior.
Platform app targets still need presentation, audio session/route/interruption
handling, document access, and lifecycle integration. Darwin and Apple's media
frameworks also mean this is not a Windows, Android, or Linux playback backend.

## New 100-round matrix

The sanitized [round ledger](CORE_ROUNDS_100.csv) records the executed cases.
Each family has ten input, rate, size, timing, or cancellation variants.

| Rounds | Family | Assertions |
| --- | --- | --- |
| 001–010 | Native transport controls | Native pause, selected speed without resuming, native play, toggle pause |
| 011–020 | Rapid transport commands | The newest native command determines final playback intent and speed |
| 021–030 | Held-key intent | Internal pauses and accelerated playback preserve selected speed and prior intent |
| 031–040 | Close with queued events | Replaced-item notifications are ignored; close releases model and current item |
| 041–050 | Audio state | Invalid volume preserves mute; native gain and mute synchronize without feedback |
| 051–060 | Subtitle lookup | Exact boundaries, overlaps, backward lookup, offsets, and up to 10,000 cues |
| 061–070 | Caption escapes | Named, nested, unknown, markup, and encoded literal tag inputs |
| 071–080 | Header scanning | 10,000–100,000 tiny boxes preserve original bytes and avoid needless copies |
| 081–090 | Preparation cancellation | A canceled worker reaches preparation, throws cancellation, and preserves source bytes |
| 091–100 | Local HD and 8K playback | Five cases per resolution verify decoded frames before and after ordinary seeks, native pause, and compatibility-copy cleanup |

## Regression results and limits

The full run passed all 900 numbered combinations across nine matrix methods,
plus focused regressions: 82 XCTest methods in total, zero failures, zero skips.
The one-million-header scan reported less than 1 MiB incremental growth. Ten
local 8K playback/seek/teardown cycles each recorded 213 MiB process footprint
after cleanup. This process also exercised generated HEVC and HD media.

The focused memory comparison measures incremental process footprint during a
synthetic scan before the worker's autorelease scope drains. It is not a live
playback memory limit. Framework caches and asynchronous decoder cleanup affect
whole-process footprint. The full suite also checks object release, a 512 MiB
fallback copy, cancellation during copying, and repeated local 8K teardown.

Runtime tests cover the current macOS machine. They do not measure audiovisual
synchronization or certify every codec, decoder, device, long-running playback
session, mobile audio interruption, live system PiP presentation, or fullscreen
animation. The sample content and subtitle appearance are not inspected.

Local media, identifying filenames and paths, content, and raw diagnostic logs
are excluded from repository changes. The ledger contains generic scenario
descriptions and outcomes only.
