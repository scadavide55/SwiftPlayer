# Eight-area debugging follow-up

Fresh review based on `803b45f`, October 17, 2026. The existing deterministic
matrices run ten scenario families with ten input or timing variants per area:
**100 focused rounds in each of the eight agreed divisions, 800 total**.
Additional regressions target gaps found during source review of the expanded
player. The baseline matrix pass and the final pass are separate runs.

The sanitized [round ledger](DEBUG_FOLLOWUP_ROUNDS_800.csv) records the final
800 requested outcomes. Each row is a completed behavioral scenario with
assertions; several rounds share an XCTest method. Shared-core scenarios are
reported separately from the requested eight divisions.

## Final division results

| Division | Final result |
| --- | --- |
| Loading and cancellation | 100/100 passed |
| Playback state | 100/100 passed |
| Seeking and scrubbing | 100/100 passed |
| Memory and resource ownership | 100/100 passed |
| Media compatibility and rendering | 100/100 passed |
| Subtitles | 100/100 passed |
| Windows and interaction | 100/100 passed |
| Picture-in-Picture and video layers | 100/100 passed |

## Confirmed defects

Each defect failed its new regression before its production fix. Relevant
checks passed before its separate commit.

| Commit | Reproduced problem | Fix and verification before commit |
| --- | --- | --- |
| `c4d5e36` | After natural completion, a manual seek while paused left history marked finished at the end; Continue discarded the new position | Explicit seeking clears the completed-history state. Automatic rewind preserves completion. Nine history and two end-action methods passed, including real EOF, rewind, repeat, close, explicit continuation, and persistence after teardown |
| `5beb7e9` | ASS override parsing dropped empty/invalid numeric fields, transforming malformed position, movement, or fade arguments into other valid effects | Preserve field positions and reject the effect when any argument is invalid. Seven malformed inputs failed before fixing. All 25 selected methods passed, including valid effects, pixel rendering, parser behavior, and 100 subtitle scenarios |
| `2ca8583` | Playback diagnostics reported Paused during ordinary pending seeks because only dragging and held-key seeking were considered | Include the model's existing pending-seek state through read-only access. Four rapid seeks now report Seeking until the latest completes. Fifteen diagnostics/frame-step methods passed, including local HD/8K checks |

## Regression timing correction

A complete validation run exposed a pre-existing timing assumption in
`testNativePlayDuringReverseHoldCancelsRepeatedSeeks`. A focused probe reproduced
two failures in fifteen iterations: both sampled the clock before the final
reverse seek completed. Native audio startup also made a fixed 350 ms progress
threshold unreliable.

`3c4f37a` corrects the test to wait for the pending seek and native transport,
check that the timeline stops moving backward, and require resumed forward
progress within the existing timeout. It preserves the cancellation assertion
without imposing an unrelated throughput benchmark. **Twenty consecutive
focused iterations passed before this separate test-only commit.**

## Final validation

- **194 XCTest methods passed**, zero failures and zero skips, including all
  **800 requested rounds** and **100 additional shared-core rounds**.
- Local HD/8K decoding, ordinary seeking, native frame stepping and frame
  capture passed alongside generated chapter/audio-language and subtitle fixtures.
- All 100 ownership cases passed. Their process physical footprint ranged from
  **394–403 MiB** in the complete test host. Ten 8K post-teardown
  readings ranged from **371–390 MiB**. These include framework caches
  from encoding, image generation, native views and other tests; they are not
  a live-player memory limit or a controlled comparison with earlier runs.
- The 512 MiB fallback-copy memory bound, partial-copy cancellation cleanup,
  and bitmap subtitle parser/conversion regressions passed.
- **Release build and static analysis passed.**
- Shared-core compilation checks passed for **macOS 13 Apple Silicon/Intel,
  iOS/iPadOS 17, and visionOS 1**.

Ordinary AVFoundation seek tolerance is preserved. The diagnostics fix adds
no timer or extra playback polling. Existing project-file formatting changes
are preserved and excluded from commits. Test media, identifying filenames,
user paths, captured media, and raw diagnostic logs are excluded from public
changes.

## Coverage limits

Runtime tests ran on the available macOS/Apple Silicon environment. Platform
availability checks are compilation checks, not runtime validation on those
devices. Native tests exercise window isolation, keyboard/focus events,
controller and layer ownership, and hosted layout. Live PiP presentation,
fullscreen animations, interrupted pointer gestures, audiovisual
synchronization, every codec/hardware combination, and long-running framework
leaks remain outside these finite automated scenarios.
