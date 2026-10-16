# Eight-area debugging refresh

Validation started from `297aca0` and completed October 17, 2026. The eight
agreed divisions were exercised with **100 focused scenario/input combinations
each, 800 total**. Existing deterministic matrices were rerun against the
expanded project, with additional regressions for newly confirmed defects.
These are behavioral scenarios, with several rounds sharing an XCTest method.

The [round ledger](DEBUG_REFRESH_ROUNDS_800.csv) records all 800 requested
results. An additional 100 shared-core scenarios also passed.

## Division results

| Division | Focus | Passed |
| --- | --- | --- |
| Loading and cancellation | Pause/load/replace/fail/close under ten asynchronous schedules | 100/100 |
| Playback state | Pause/resume, valid/invalid rates, volume/mute, EOF/replay and recovery | 100/100 |
| Seeking and scrubbing | Boundaries, rapid/latest seeks, scrub state, key timing and direction changes | 100/100 |
| Memory and ownership | Model/item release, tasks, observers and native callback ownership | 100/100 |
| Compatibility and rendering | HD/8K seeks, generated HEVC sizes, metadata, clone/fallback integrity | 100/100 |
| Subtitles | Formats, encodings, boundaries, offsets, overlap, replacement and input limits | 100/100 |
| Windows and interaction | Keyboard/focus, tracking, separate-window notifications, providers and layout | 100/100 |
| PiP and video layers | Attach/replace/stop/detach, foreign delegates, resizing and owner release | 100/100 |

## Separate bug-fix commits

Every defect first failed a regression. Its fix passed relevant checks before
its individual commit.

| Commit | Confirmed defect | Verification |
| --- | --- | --- |
| `a2ce7d7` | PGS parsing retained discarded segment read buffers for the background task's lifetime | Generated 64 MiB input now passes a 32 MiB footprint-growth guard; PGS/VobSub behavior checks passed |
| `091c9ac` | VobSub parsing retained large packet-padding buffers despite keeping tiny captions | Generated 64 MiB input passes the memory guard; first/last caption images, timing and pairing remain correct |
| `449552a` | Cancellation during bitmap RGBA conversion still completed an obsolete image | An 8-megapixel regression now throws cancellation; 16 image/styled subtitle checks passed |
| `a06ee0c` | Native Pause during an active forward hold resumed on release; native Play left a reverse-seek loop running | Both regressions, 40 lifecycle methods and all 100 seeking cases passed |
| `b31a6f0` | Invalid/empty VobSub numeric fields were silently dropped, changing timing, dimensions or palettes | Six malformed inputs reproduced it; 33 targeted checks passed after fixing |
| `e5d045a` | Native Play/Pause before the hold threshold left the delayed timer armed | Both regressions and the final full suite passed before committing |

Focused measurements sampled physical footprint at parser return, inside the
background worker before its surrounding autorelease pool ended. For generated
64 MiB inputs, PGS growth fell from approximately **91 MiB to 8–26 MiB** across
focused runs; VobSub growth fell from approximately **65 MiB to less than 1 MiB**.
These changes shorten temporary buffer lifetime. Decoded cues retain their
data independently of the drained read buffers.

## Final checks

- **191 XCTest methods passed**, zero failures and zero skips,
  including the requested 800 scenarios and 100 additional shared-core scenarios.
- Generated HD HEVC/AAC/timed-text and chapter/audio-language fixtures passed
  alongside the opt-in local 8K file. Media remains local.
- Ten repeated 8K play/seek/teardown cycles completed. Full test-host footprint
  after teardown was 364–398 MiB, including framework caches from encoding,
  native UI and image-generation checks.
- Release build and static analysis passed.
- Shared-core availability checks passed for macOS 13 on Apple Silicon/Intel,
  iOS/iPadOS 17 and visionOS 1. These are source checks; runtime tests ran on macOS.
- Remembered zero volume already restored consistent model/menu/native mute
  state; a supplemental regression passed without a production change.

Temporary fixtures/logs were unavailable after an interruption. Final results
come from a fresh complete run after restoring the local 8K copy and generating
anonymous HD and chapter fixtures. Ordinary seeks retain AVFoundation's default
tolerance. Existing user project-file formatting changes were preserved and
excluded from commits. Published changes contain no private media, identifying
filenames, local paths or raw diagnostic logs.

## Coverage limits

Native tests cover controller lifetime, window notification isolation, keyboard
and responder events, and hosted layout. Live system PiP presentation,
fullscreen animations and interrupted pointer gestures still require manual
interaction checks. Finite scenarios do not establish every codec/hardware
combination, audiovisual synchronization or absence of long-running framework leaks.
