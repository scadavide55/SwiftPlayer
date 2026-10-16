# Playback history and diagnostics review

Reviewed October 16, 2026. This implements the selected IINA-inspired history
browser and playback information additions using the existing native engine.

## Separate checked commits

| Commit | Change | Checks before commit |
| --- | --- | --- |
| `c212f5a` | Bounded local playback history, explicit continuation, and finished-state memory | Twenty history/preferences/menu/end-action tests passed without skips, including native chapter/audio language restoration |
| `d35f38b` | On-demand native playback diagnostics and bounded buffer summaries | Ten diagnostics/menu tests passed without skips, including real HD/8K presentation sizes, native transport, memory readings, sampling cancellation/restart, and ownership |

The history checks cover ten-second throttling, 200-entry/retention bounds,
discarding invalid storage, read-only bookmarks, unavailable files, removed and
cleared session invalidation, explicit paused Continue while automatic resume is
off, explicit beginning overriding automatic resume, replacement races, natural
EOF, menu stability, and closed-player release.

A failing regression reproduced automatic Rewind and Pause changing completed
history back to unfinished. Completion is now preserved through the automatic
rewind/pause and close; beginning playback again starts a new watch checkpoint.
The failing test was rerun successfully with the other history/end-action tests
before the history commit.

The diagnostics checks cover overlapping/duplicate/gapped buffer ranges,
unavailable and malformed data, the 256-range processing bound, startup/waiting
reason classification, real playing/paused/failed/closed state, native
presentation sizes, sampling only while active, rapid restarts, no menu
invalidation, and no retained closed player or sampler.

## Behavior and resource limits

- History is enabled by default, with 90-day retention. Settings offers 30, 90,
  or 365 days; at most 200 entries are kept. Stored data reads are capped at
  8 MiB, individual read-only bookmarks at 16 KiB, and identifiers/names are
  bounded. Invalid entries and duplicate keys/IDs are discarded. Retention
  pruning runs on load, updates, and retention changes and persists the result.
- Ordinary progress checkpoints are throttled to ten wall-clock seconds.
  Pause, completed paused seeks, EOF, and teardown save additional checkpoints.
  There is no per-frame preferences write or thumbnail cache in history.
- Clear, remove, and disable invalidate existing session updates. Disabling
  recording clears history. An active cleared session cannot repopulate the
  list. A subsequently opened ready file can start a new session if enabled.
- Continue is an explicit start-position request and works while automatic
  resume is off. Play for a finished entry explicitly starts at zero, overriding
  automatic resume. Positions are validated and clamped to the loaded duration;
  the existing normal AVFoundation seek tolerance and pause intent are preserved.
- The history sheet closes before requesting an existing-player replacement
  alert, and the chosen continuation position is retained through confirmation.
  Unavailable files produce a generic message and remain removable. Automatic
  resume, Open Recent, and per-file track memory retain separate storage/controls.
- Diagnostics runs a cancelable one-second task only while the Playback
  information tab is visible. It holds a weak player-model reference and only
  its latest value snapshot. Hiding/removing the tab stops sampling; generation
  checks prevent an old task from stopping a newer session.
- Buffer data is read from native loaded ranges and flags. At most 256 ranges
  are inspected, overlaps are merged, gaps are excluded, and unavailable values
  stay unavailable. The UI shows at most eight merged ranges plus a count.
  Truncated range collections are labeled as samples.
- App memory is the current process physical footprint across all windows and
  framework buffers. It is not a per-file allocation count or decoder peak.
  Nominal frame-rate metadata remains under Streams. No live renderer/drop
  counters, raw access logs, URL diagnostics, or automatic log export are added.

## Final validation

The final full regression passed all 161 tests with zero failures and zero
skipped tests, including the local HD/8K and generated chapter/audio fixtures.
All 900 unique numbered scenarios passed: 100 each for compatibility, core,
interaction, loading, memory, PiP, playback, seeking, and subtitles. The suite
completed in approximately 236 seconds.

The memory matrix's 100 post-cleanup process-footprint samples ranged from
280 to 289 MiB. These are not decoder/export peak measurements or a controlled
comparison against earlier runs.

Final Release build and static analysis passed without warnings. All four
shared-core platform checks passed without warnings.

Programmatic native playback and ownership checks are covered. Computer-use
tools are unavailable in this continuation, so manual history-sheet/menu,
replacement-alert, preference layout, and diagnostics-panel visual checks remain
pending. Shared-core platform checks establish source availability, not mobile
runtime playback or a completed platform UI.

## Privacy

Actual media, identifying filenames, user paths, subtitle dialogue, captured
images, and raw diagnostics remain local and are excluded from published
changes. Runtime history intentionally stores names, references, and progress
locally for the browser; users can clear or disable it. No network service or
telemetry was added.
