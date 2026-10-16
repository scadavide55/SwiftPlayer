# Playback improvements review

Reviewed October 16, 2026. Changes build on the existing native AVFoundation
engine. Each implementation was checked before its separate commit.

## Changes and focused verification

| Commit | Change | Verification before commit |
| --- | --- | --- |
| `feb8e16` | Optional normalization and linked peak protection, with saved preferences | Seven audio tests, including rendered mono/stereo samples, unclipped protected peaks, disabled protection, quiet noise, silence, and preference changes without replacing playback |
| `2e9099c` | Saved end-of-file actions: stay, rewind/pause, repeat, close | Two action tests and the 100-scenario playback matrix, including natural EOF and stopping repeat |
| `8183336` | Bounded per-file track choices, external subtitle bookmark, and timing | Seventeen focused tests, including reopening an external file, Off, selection races, persistence limits, and native audio-language restoration |
| `7484bcb` | Preserve loaded captions if a replacement subtitle file cannot be read | Reproduced failure first; confirmed the replacement error leaves existing cues, selection, and name intact |
| `4d38da2` | Authorized subtitle folders, matching-language discovery, embedded/external timing | Twenty-three focused tests, including native embedded text delivered early from local HD media, bounded history, folder bookmarks, Off, and matching exclusions |
| `ff82f8e` | Throttled native seek thumbnails with bounded image caching | Four preview tests, including playing/paused HD and 8K extraction, coalesced requests, cache eviction, canceled callbacks, and repeated close/detach |

## Behavior and resource limits

- Peak protection defaults on; normalization defaults off. Channels share the
  same gain envelope. Normalization uses a bounded gain range and a quiet-input
  gate. The audio callback adds no allocation, lock, extra clock, or lookahead
  buffer. Disabling peak protection permits hard clipping when boosting audio.
- Ordinary playback seeks retain AVFoundation's normal tolerance. Native
  thumbnail extraction has its own relaxed tolerance and does not seek the
  playing item. Playback speed retains the existing pitch-preserving algorithm.
- End actions reuse or close the existing player. No completion dialog blocks
  playback. The default stays on the final frame.
- Per-file memory holds at most 100 entries. Individual option/bookmark payloads
  are bounded; the stored document has an 8 MiB read limit. Disabling the feature
  clears saved choices. Explicit choices made during loading supersede pending
  restoration. Missing saved tracks fall back to automatic selection.
- Subtitle discovery searches at most eight user-authorized folders, 2,000
  entries per folder, and 128 matches per folder/result list. Hidden files,
  symbolic links, and subdirectories are excluded. Background work is canceled
  when media changes or closes. Search access is read-only.
- Subtitle delay is bounded to ±30 seconds. Native embedded text uses a fixed
  delegate advance configured before attachment and a bounded transition
  timeline: at most 512 events, 8,192 UTF-16 units per event, and a 90-second
  history window plus one predecessor. Seek flushes clear the old sequence.
  Picture in Picture retains native system subtitle rendering and timing;
  external captions remain in the main window.
- Thumbnails are at most 320 × 180 pixels. Requests coalesce over 120 ms and
  share one native generator per attached asset. The memory-only cache holds
  at most 32 images and 8 MiB of image storage; it clears on media replacement
  or closure. AVFoundation's internal decoder buffers are outside that budget.
  Audio-only media falls back to a time display.

## Final verification

The final complete run passed all 123 tests with zero failures and zero skipped
tests, including the opt-in local HD and 8K checks and generated chapter/audio
fixture. All 900 unique numbered scenarios passed: 100 each for compatibility,
core, interaction, loading, memory, Picture in Picture, playback, seeking, and
subtitles. The test suite completed in approximately 228 seconds.

The 100 memory-matrix cleanup snapshots ranged from 359 to 369 MiB in the shared
test process. These are post-cleanup samples, not peak decoder memory measurements
or a guarantee of leak-free behavior under every media file or workload.

The final Release build and static analysis passed. All four shared-core
platform checks passed with zero source warnings. Xcode emitted its metadata
extraction warning because this app does not depend on AppIntents; this was the
only warning in the Release build/analysis log.

The earlier full-run attempt stalled in native video-layer/Picture in Picture
cleanup without an assertion failure. A fresh isolated 100-scenario Picture in
Picture run passed. The cause of the stall was not established; no speculative
workaround or test exclusion was added. The final complete run passed all 100
Picture in Picture scenarios without reproducing that stall.

Native menu/settings checks confirmed the new audio switches, all four EOF
actions, subtitle-folder controls, adding a folder through the system picker,
and opening generated media. The remaining visual hover and subtitle-display
checks were interrupted by a locked desktop. Computer-use tools are unavailable
in this continuation, so those visual checks are not claimed as complete.

The platform script checks shared-source availability on macOS (Apple Silicon
and Intel), iOS/iPadOS, and visionOS. It does not establish mobile runtime
playback, audio-session behavior, or presentation support.

## Scope and privacy

A–B repeat and frame stepping were excluded as requested. A future small
diagnostics view could show playback state and the native reason for waiting.
Renderer statistics require separate investigation, especially for local media;
no diagnostics panel was added in this batch.

Test media, actual media filenames, user paths, subtitle dialogue, screenshots,
and raw diagnostic logs remain local and are excluded from this review and
published changes. Preferences and file references remain on the device.
