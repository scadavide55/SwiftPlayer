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

The final code at `84faeac` passed **96 XCTest methods** and all **900 numbered
scenarios** on October 16, 2026, with zero failures and zero skips. This run
includes the local HD/8K media, synthetic chapter fixture, and final
selector-cleanup correction. The final Release build, static analysis, and all
four shared-core platform checks also passed.

Earlier full reruns encountered intermittent system-audio startup timeouts,
which were also reproduced on the earlier main commit and with a bare
AVPlayer after the compatibility workload. After the Mac was unlocked and
audio availability was confirmed, the complete final-code rerun passed. This
review does not claim a precise OS/device cause for those earlier timeouts.

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

## Menu stability follow-up — October 16, 2026

Playback ticks and decoded captions previously invalidated menu views through
broad observations of the player and media controllers. The scene's command
context was also reconstructed with each playback-view update. A dedicated
macOS menu adapter now publishes only changed command state; an equatable focus
view keeps each window's command context stable. Playback and caption updates
continue reaching the player UI without rebuilding tracked menus.

Playback, Audio, and Subtitles retain their commands when no player window is
active, disabling unavailable actions rather than substituting a placeholder.
This follows Apple's [menu-bar guidance](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar)
on consistent command placement and availability. Standard menus and shortcuts
remain intact; playback navigation is separated from transport controls.

Verification: 99 tests and all 900 numbered scenarios passed with zero failures
or skips, including local HD/8K checks. The menu regression delivers 100 rounds
of time, external-caption, and embedded-caption updates without a menu change,
then verifies speed, mute, and subtitle changes still update commands. Separate
checks cover distinct window targets and release of closed menu/player owners.
Release build and static analysis passed. Native accessibility inspection
confirmed the same Playback menu entries through loading, playback, ending,
and Settings focus, with unavailable commands disabled. Screen capture was
unavailable, so no pixel-level visual verification is claimed.
