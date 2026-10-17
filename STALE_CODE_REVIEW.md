# Stale-code review across eight divisions

Review started from `cdf4263`. Static analysis was combined with production and
test reference tracing, callback ownership review, and inspection of duplicated
UI paths. Tests can keep obsolete application paths reachable, so a clean
whole-project scan alone was not treated as proof that no stale code exists.

| Division | Review and disposition |
| --- | --- |
| Loading and cancellation | Preparation, replacement, cancellation guards, scoped access, and temporary-file cleanup remain active. No additional obsolete path confirmed. |
| Playback state | Removed the former application-volume key helpers and migrated keyboard coverage to the current system-volume controller, including its fixed 100% ceiling. Core attenuation, gain processing, normalization, and mute-state tests remain. |
| Seeking and scrubbing | Discrete tap anchors, held-key scheduling, frame steps, scrubber callbacks, and preview cancellation have active callers. No additional obsolete path confirmed. |
| Memory and ownership | Removed superseded fullscreen forwarding, its initial callback task, and two redundant notification registrations from the window-observer bridge. The active window controller remains responsible for fullscreen state. Focus loss, reattachment, and teardown checks remain. |
| Compatibility and rendering | HEVC retagging, clone/fallback copying, native rendering, and registered C audio callbacks remain active. Platform-specific bookmark handling is retained. No additional obsolete path confirmed. |
| Subtitles | Text/styled/bitmap decoders, legacy formats and encodings, search, selection, timing, and image cancellation remain active. Removed the test-only rendered-frame UUID; the cache regression now checks actual CGImage identity. |
| Windows and interaction | Removed a stale single-child wrapper and repeated button style. Corrected the fullscreen tooltip that was overriding Picture in Picture help. Removed application mute from the menu snapshot because the Audio menu observes system mute directly. |
| PiP and video layers | Layer setup, controller observation, delegate callbacks, stop/detach paths, and native layer cleanup remain active. The PiP button now exposes its own help text. |

## Scanner findings and retained test support

The initial production-only Periphery scan reported six symbols. The two
application-volume key helpers were obsolete and removed. The rendered-frame
UUID was also replaced with a direct image-identity assertion. Three test support
symbols remain deliberately:

- `DisplaySleepController.isPreventingSleep`: checks activity ownership/release.
- `FrameCaptureController.capture(to:)`: exercises the file-export path without
  opening a save panel.
- `PlaybackDiagnostics.isSampling`: checks sampling task start/stop behavior.

These symbols have concrete regression callers. They are not suppressed with
new exclusions or baselines. Synthesized equality retention uses the existing
Periphery configuration. Runtime delegates, required native initializers,
observation tokens, and serialized compatibility fields were also checked
before considering removal.

## Validation

Each cleanup was checked before its separate commit. Focused checks cover
system-volume keyboard routing, core audio state, fullscreen/focus isolation,
observer and callback release, PiP layers, and menu invalidation. The PiP help
mismatch was observed in the native accessibility tree before the change.

Separate verified cleanup commits:

- `5e1548c`: obsolete application-volume key helpers and keyboard tests.
- `3af6752`: superseded fullscreen callback and notification forwarding.
- `2ec38b4`: application mute no longer consumed by the menu snapshot.
- `3eea25d`: redundant subtitle UUID replaced with rendered-image identity checks.
- `286cf18`: stale toolbar wrapper, repeated style, and misplaced help.

A focused PiP run stalled during native attached-layer deallocation. A clean
retry and the PiP matrix in the full regression run both completed all 100
scenarios. The pre-change tooltip mismatch was observed in the native
accessibility tree. Post-change inspection in the updated player confirmed
that the PiP button exposes “Enter Picture in Picture” help and the fullscreen
control remains labeled “Enter Full Screen.” Native PiP/controller checks and
the release build passed.

Final results:

- 220 XCTest methods passed, zero failures and zero skips.
- All eight division matrices passed 100 scenarios each (800 total), plus
  100 additional shared-core scenarios.
- The full run included local HD/8K navigation, rendering, capture, preview,
  repeated playback/teardown, and memory checks.
- Fresh whole-project Periphery scan: zero findings.
- Fresh production-only scan: exactly the three intentional test helpers listed
  above; no unreviewed finding remains.
- Release build and static analysis passed.
- Shared-core source checks passed on Apple Silicon/Intel macOS, iOS/iPadOS,
  and visionOS. Runtime checks ran on macOS.
The eight 100-case matrices are behavioral scenario/input combinations, not
800 repeated static scans. No claim is made that finite static/runtime checks
prove the absence of every possible unused or dynamically referenced path.

Media identifiers, contents, local filesystem paths, and raw diagnostic logs
are excluded from published changes. Existing unrelated project formatting is
preserved.
