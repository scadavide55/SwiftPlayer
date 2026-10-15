# Playback and memory review

Completed October 15, 2026. Thirty focused rounds covered playback state,
seeking, asynchronous replacement, subtitles, copying, decoder cleanup, and
native view lifetime. Regression runs exercise several independent rounds
together. Tests use generated fixtures; local 8K checks are opt-in.

## Confirmed fixes

- **End-of-playback ordering (`8e33982`):** the end observer queued an extra
  main-actor task, allowing an earlier end notification to override a newer
  seek/replay. The observer now handles the notification immediately on its
  configured main queue. The new regression failed before the fix; all 19
  lifecycle tests, including real EOF and replay, passed before committing.
- **Idle subtitle publications (`dbc7da7`):** with subtitles disabled or empty,
  every playback tick published the same empty string. Empty text is now
  published only when clearing a displayed caption. The new regression failed
  before the fix; publication, overlap, and teardown checks passed before
  committing.

Ordinary playback continues to use AVFoundation's normal seek tolerance.
Sample-accurate seeks remain confined to explicit decoding tests.

## Round results

| Round | Focus and evidence | Result |
| --- | --- | --- |
| 01 | Baseline: 42 tests, with two optional media checks skipped | Passed |
| 02 | End callback followed immediately by seek and play | Fixed and verified |
| 03 | Actual EOF, stopped state, and replay from the beginning | Passed |
| 04 | Speed changes while paused; invalid rates | Passed |
| 05 | Pause during preparation; explicit resume at selected speed | Passed |
| 06 | Rapid seek replacement, latest target, and clamped endpoints | Passed |
| 07 | Forward hold acceleration, release, and pause cancellation | Passed |
| 08 | Forward hold while paused preserves pause | Passed |
| 09 | Reverse hold, playback restoration, and weak model lifetime | Passed |
| 10 | Changing hold direction cancels the earlier seek loop | Passed |
| 11 | Key release before the hold threshold | Passed |
| 12 | Held keys at both timeline boundaries stop repeated seeks | Passed |
| 13 | Unloaded player, invalid directions, and non-finite seek inputs | Passed |
| 14 | Replacing media during an active reverse hold | Passed |
| 15 | Twenty load/seek/close cycles; model and item released each time | Passed |
| 16 | Ten failed-load/recovery cycles; stale errors cleared | Passed |
| 17 | Old-item notifications ignored; background EOF delivered safely | Passed |
| 18 | Repeated disabled/empty subtitle ticks; real caption clearing | Fixed and verified |
| 19 | Large subtitle load replaced by a newer load; latest cues retained | Passed |
| 20 | 10,000 unsorted/overlapping cues; backward lookup matches reference | Passed |
| 21 | Subtitle input above 16 MiB rejected before parsing | Passed |
| 22 | SRT/VTT/ASS/SSA timing, newlines, UTF-16, BOM, malformed input | Passed |
| 23 | Every truncated metadata prefix, invalid boxes, missing parameter sets | Passed |
| 24 | Read-only source; clone/fallback preserve original and patched copy | Passed |
| 25 | 512 MiB fallback copy stays within the 64 MiB memory-growth guard | Passed |
| 26 | Cancellation after fallback copy makes progress removes partial directory | Passed |
| 27 | Local 8K first frame, ordinary model seek, and frame after seek | Passed |
| 28 | Ten local 8K play/seek/teardown cycles; copies removed | Passed |
| 29 | Video layer resizing/dismantling, keyboard repeat/focus cleanup, PiP detach | Passed |
| 30 | Full 60-test suite including all local 8K checks; Release build and analysis | Passed |

## Validation and limits

The final full suite passed **60 tests with zero failures and zero skips**.
Release build and static analysis succeeded. In the ten-cycle 8K test,
post-teardown process physical footprint was **62–69 MiB**. Generated-file
tests also verify cancellation cleanup, source preservation, and weak object
release independently of process memory measurements.

These checks cover the tested macOS/Apple Silicon environment. Visible PiP,
fullscreen, and drag interactions were reviewed in source; automated native
tests cover their supporting cleanup and layout behavior. Long-running leaks
and all codec/hardware combinations are outside this finite test run.
