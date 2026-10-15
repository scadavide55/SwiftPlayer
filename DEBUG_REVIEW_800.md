# Eight-area playback debugging review

Requested scope: **100 focused rounds per area, 800 total**. Each numbered round
is a deterministic scenario/input combination with behavioral assertions.
Eight matrix test methods run those combinations; the existing regression suite
and focused bug regressions run alongside them. A round is not a whole-suite
repetition. The sanitized [round ledger](DEBUG_ROUNDS_800.csv) records individual
results without media identifiers or diagnostic logs.

**Completed October 15, 2026:** all **800 rounds passed**, 100 in every area.
The full regression run passed **74 XCTest methods with zero failures and zero
skips**, including all local 8K checks. The HD-backed PiP matrix also passed
all 100 rounds in a focused follow-up. Release build and static analysis
succeeded. The four confirmed fixes below were verified before their separate
commits.

## Areas and scenario design

| Area | Matrix | Combinations |
| --- | --- | --- |
| Loading and cancellation | Ten load/pause/replacement/failure/close sequences under ten asynchronous schedules | 100 |
| Playback state | Ten pause/resume/rate/volume/end/failure scenarios at ten selected rates | 100 |
| Seeking and scrubbing | Ten seek/key-hold/boundary scenarios with ten target, rate, or timing variants | 100 |
| Memory ownership | Ten model/item/task/observer/native-callback lifetime scenarios under ten volume/rate states | 100 |
| Compatibility and rendering | Ten decoding/container/copy/cancellation families, each with ten fixture, metadata, or seek variants | 100 |
| Subtitles | Ten format/encoding/timing/index/loading/malformed-input families with ten input variants | 100 |
| Windows and interaction | Ten keyboard/focus/tracking/window/provider/layout families with ten input variants | 100 |
| PiP and video layers | Ten attach/replace/detach/stop/delegate/layout/lifetime families with ten input variants | 100 |

Real-media compatibility checks include ten ordinary seeks each with local HD
and 8K samples. Generated HEVC fixtures cover ten dimensions. Preparation is
checked for preservation of track types, source bytes, and permissions, and
removal of temporary copies. Memory checks assert weak object release and
record process footprint; the existing suite separately exercises the 512 MiB
fallback-copy memory bound and cancellation after a copy has made progress.

In the full run, process footprint across the 100 ownership rounds ranged from
134–215 MiB, starting at 215 MiB and ending at 141 MiB. The ten repeated 8K
teardown measurements were 253–254 MiB in this process, which had also exercised
generated HEVC encoding, HD decoding, and native UI frameworks. These figures
include framework caches and should not be compared directly with a smaller
test process's footprint.

## Confirmed defects and separate commits

| Commit | Reproduced behavior | Verified change |
| --- | --- | --- |
| `9c5b285` | At an exact cue boundary, the previous caption remained selected; final captions remained at their end time | Expire cues at their end time; boundary and backward-lookup regressions passed before committing |
| `0ee2747` | Legacy SSA `Marked=` dialogue lines produced no cues; ten matrix inputs failed | Accept SSA's marked field alongside ASS's numeric layer; all parser regressions passed before committing |
| `f07f3bc` | An overflowing explicit WebVTT hours field was treated as an absent field and became zero; ten matrix inputs failed | Reject an unrepresentable explicit hours value while keeping valid short and long timestamps; parser suite and all 100 subtitle rounds passed before committing |
| `2e5bf93` | Fullscreen and focus notifications crossed player windows; a native two-window regression failed | Observe the containing window, ignore other windows, refresh ownership on reattachment, and clear observers/callbacks on disposal; focused and hosted-view tests passed before committing |

The caption boundary behavior follows the active-cue interval described in the
[HTML media specification](https://html.spec.whatwg.org/multipage/media.html#time-marches-on).
The legacy SSA fixture follows the marked dialogue field emitted by the
[Aegisub SSA writer](https://sources.debian.org/src/aegisub/3.2.2%2Bdfsg-7/src/subtitle_format_ssa.cpp/).

Ordinary player seeks retain AVFoundation's normal tolerance. These changes add
no playback polling, telemetry, or runtime test machinery.

## Coverage limits

Native tests cover keyboard events, responder transitions, separate windows,
notification isolation, hosted layout, PiP controller lifetime, foreign
delegate rejection, and layer cleanup. They do not drive live fullscreen
animations, a system PiP presentation, or a pointer dragging a scrubber on the
screen. Those remain manual interaction checks. Embedded subtitle track types
are preserved; their text and appearance are not inspected.

The matrices cover finite scenarios on the tested macOS/Apple Silicon machine.
They do not establish compatibility with every hardware decoder or codec,
measure audiovisual synchronization, or prove the absence of long-running
framework leaks. Process-footprint observations include framework caches and
are not a live playback memory limit.

Both local samples, their identifying filenames and paths, their content, and
raw logs are excluded from repository changes. The numbered ledger contains
only generic scenario descriptions and pass/fail outcomes.
