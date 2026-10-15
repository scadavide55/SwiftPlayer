# Playback controls and preferences review

Implemented October 15, 2026 for the requested local-fork feature set. The
multiple-file queue remains deferred.

## Delivered behavior

| Area | Behavior |
| --- | --- |
| Embedded subtitles | Off, Automatic, individual options, external-file selection, and preferred language. Automatic favors full captions rather than the forced-only default. |
| Caption appearance | Installed font families, size, four readable colors, outline, background opacity, and top/center/bottom position; a live settings preview. |
| Audio | Individual track selection or Automatic with a preferred language; explicit choices remain in effect when preferences change. |
| Playback | Jump to Time, chapter navigation, speed selection, and optional resume that preserves pause. |
| Recent files | Ten local entries with read-only security-scoped bookmarks, deduplication, stale-bookmark refresh, and Clear Menu. |
| Media information | Current duration and stream codecs, resolution, frame rate, language, channels, and sample rate. |
| Preferences | Persistent language, appearance, volume/mute preferences, and opt-in resume with bounded local history. Turning resume off clears saved positions. |

The track, chapter, language, and preference logic stays in PlaybackCore without
presentation-framework imports. The macOS menus, font enumeration, caption
views, information panels, file pickers, and bookmark storage stay outside it.

AVFoundation's native text style rules apply only to WebVTT, so the main window
uses AVPlayerItemLegibleOutput text for embedded captions, including tx3g. This
makes the requested appearance controls effective for that format. Native
rendering is suppressed in the main window to avoid duplicate captions and
restored for Picture in Picture. External captions use the existing bounded
background parser and timing index.

## Commits and verified corrections

The initial core feature commit is `8baa6df`. Each subsequent confirmed
correction was checked before its separate commit:

| Commit | Correction | Verification |
| --- | --- | --- |
| `db2c740` | Restore saved position when a paused item becomes ready; do not depend on playback ticks | Paused resume and disabled-resume checks plus lifecycle suite passed |
| `043da1b` | Fall back to available chapter locales when unlabelled chapter titles do not match preferred languages | Synthetic two-chapter fixture and preferred-audio selection passed |
| `32e61f3` | Preserve the current caption when appearance changes or a preference keeps the same track selected | Native embedded-caption retention checks passed |
| `48690f2` | Apply track selections once the item is ready, preventing startup defaults from replacing the intended choice | Ten consecutive local media loads retained full subtitles |
| `dc08390` | Show 1.25× accurately rather than rounding its label to 1.2× | Quarter-step label regression passed |
| `b424a56` | Honor the latest native transport command during readiness; ignore events from replaced items | The reproduced rapid-command failure passed after the fix; 40 repeated readiness/pause loads and the core matrix passed |
| `bed56de` | Keep a newer subtitle selection when an external-file load completes | Off remained selected after asynchronous loading; the loaded external file remained available for later selection |
| `9006d34` | Respect script and region distinctions when matching language preferences | Traditional/Simplified Chinese, exact English region, regional fallback, and unavailable-language checks passed |
| `3e12f63` | Reset selectors when their track lists are cleared on close | Closed-state assertions and all nine focused track/external-selection checks passed |

## Validation

A full run passed **96 XCTest methods**, all **900 numbered scenarios**, with
zero failures and zero skips, including local HD/8K and the synthetic chapter
fixture. After the final selector-cleanup correction, all nine focused media
and external-selection tests passed. The final Release build, static analysis,
and all four shared-core platform checks passed.

A subsequent full rerun encountered system-audio startup timeouts in a later test process. The same startup failure was reproduced on the earlier main commit
and with a bare AVPlayer after the compatibility workload. A bare AVPlayer in
an isolated fresh process also passed, so the observed condition is intermittent;
this review does not claim its precise OS/device cause. A healthy-audio full
rerun is still pending, and the pull request remains a draft until that check
can finish. The earlier 96-test pass predates the final selector-cleanup change;
it is not represented as a complete full-suite pass of the final tree.

Native UI inspection verified the Settings tabs, font and appearance controls,
live preview layout, Playback chapter menu, and Jump to Time dialog. Jumping
updated position without starting playback. The normal sandboxed Release app
recorded a recent file, preserved it after quitting and relaunching, and reopened
it from its saved bookmark. Media Information displayed the synthetic fixture's
streams. This verification used generated content for screenshots.

The optional fixture generator creates two silent audio tracks with different
languages and two chapter titles. It requires ffmpeg only when generating that
fixture. The application and normal test fixtures add no third-party runtime
dependency.

## Limits and privacy

Runtime verification covers the current macOS/Apple Silicon machine. Core
source checks do not constitute an iOS, iPadOS, or visionOS app or device test.
Installed fonts vary by device. Caption appearance is applied in the main
window; Picture in Picture uses the system's native embedded-caption appearance,
and external subtitle files remain in the main window. Subtitle decoding still
depends on AVFoundation's supported media formats.

The existing manual coverage limits for live system PiP, fullscreen animations,
and pointer-drag scrubbing remain. No claim is made about every subtitle codec,
all languages, audiovisual synchronization, or unlimited-duration playback.

Preferences, recent bookmarks, and saved positions remain in local app storage.
Actual media content, identifying filenames and paths, screenshots of that
content, and raw diagnostic logs are excluded from repository changes.
