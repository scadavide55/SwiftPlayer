# Consistent discrete navigation

Settled paused taps previously added each jump to the last native landing. Seek
allowance and timestamp rounding could therefore accumulate over many taps. A
baseline three-run measurement of 80 right taps requested approximately
400.055 seconds and landed approximately 400.086 seconds beyond its start.

Discrete navigation now preserves the intended paused target sequence and native
rational timestamp precision. Eighty right taps request exactly 400 seconds;
eighty left taps return to the starting target. Slider seeks, transport changes,
frame stepping, media replacement, and native clock changes rebase navigation.
Playing taps use the live clock, so ordinary playback time still contributes to
the elapsed position. Rapid pending taps continue to accumulate their targets.

The discrete landing allowance is reduced from 250 ms to 125 ms. Zero allowance
and tighter tested allowances, including 100 ms, left stale paused pictures at
some open-GOP HEVC
boundaries in the generated test video. Native clock checks alone missed this;
decoded frame checks and a visible timestamp test exposed it. The 125 ms allowance
refreshed those frames. Targets remain five seconds apart even when a landing
moves slightly. Frame quantization and bounded native landing offsets still
apply; this does not promise an identical frame count for every tap.

Held-key repeat timing and its 250 ms allowance remain unchanged. Timeline seeks
retain AVFoundation's ordinary tolerance. No per-tap media conversion or frame
extraction is added.

Validation:

- 480 settled taps: 80 right and 80 left across three runs, checking every target,
  native endpoint, decoded picture timestamp, and paused state.
- 20 local 8K taps with matching decoded pictures and preserved paused state.
- Explicit/native seeks and an active slider rebase the target sequence.
- Existing consecutive/rapid taps, playing/paused navigation, holds, and Shift
  shuttle restoration checks pass.
- Full regression: 219 tests passed, zero failures and zero skips, including
  all 900 numbered matrix scenarios and the opt-in local 8K checks.
- Release build and static analysis pass.
- Shared playback core checks pass for Apple Silicon and Intel macOS, iOS/iPadOS,
  and visionOS.

Test fixtures, media identifiers, screenshots, and raw diagnostics remain local.
