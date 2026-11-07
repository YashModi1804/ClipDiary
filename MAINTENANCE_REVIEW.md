# ClipDiary maintenance review

Date: 6 November 2026 · Status: completed; ClipDiary 1.0.6 packaged, verified and installed.

## Authorized scope

The user authorized extensive bug, security, performance, and behind-the-scenes UX improvements. **The existing visual UI must remain unchanged**, and all existing features must continue working. This review permits changes to internal data handling, resource use, error recovery, keyboard routing, and existing window lifecycles; it does not authorize a redesign or removal of features.

Preserve the narrow menu-bar panel, row styling, one-line text cards, existing hover previews, collection/filter controls, and existing editor/settings/parameter forms. No Dock icon, cloud service, account, telemetry, remote AI, paid dependency, or server is introduced.

## Existing behavior to preserve

- Click or Command-C copies the full selected content and closes the panel. Ordinary history is promoted in place, retaining source/content/assets and renewing its rolling 96-hour expiry; newest remains at the bottom.
- Snippets remain independent and permanent until deletion. Copying one creates independent ordinary history. Explicit copying remains available while automatic capture is paused.
- Parameterized snippets remain opt-in. Repeated names share an input, empty values preserve placeholders, substitutions are literal and single-pass, and Cancel changes neither clipboard nor history. Entered values must not become saved template defaults.
- Automatic clipboard/image/screenshot capture stays local. Original screenshot files remain untouched. Pause, exclusions, lock/session state, permission checks, and queued-work cancellation must retain their existing privacy behavior.
- Clear History preserves snippets. Expiry removes app-owned content and associated assets. Existing error reporting must describe partial success honestly.

## Confirmed findings and changes visible in source

| Area | Observed issue | Implementation direction/current source |
| --- | --- | --- |
| Large-history responsiveness | List refresh and startup reconciliation materialized full stored text; hidden panels retained/rendered collections unnecessarily. Short-text fixtures did not represent near-capacity content. | Core now exposes bounded text/title/source projections for list queries; full-record lookup remains separate for copying/editing. Startup asset reconciliation reads only asset metadata. The model avoids retaining a rendered list when hidden and suppresses unchanged list publication. |
| International search | SQLite `lower()` substring matching failed case-insensitive examples such as `ÉCOLE` versus `école` and Cyrillic case pairs in a local query reproduction. | Core source now registers a Unicode-aware substring function. Preserve substring semantics and full-content searching even when displayed rows use bounded previews. Native regression checks cover case pairs, literal punctuation, NUL, canonical equivalence and matches beyond preview limits. |
| Resource accounting | User-edited titles had no size bound, and title/source bytes could bypass the content budget. | Core source now validates metadata sizes and includes title/source bytes in capacity admission. Existing records/snippets must survive rejected writes; in-place history promotion must retain its established behavior. |
| Store relocation and linked paths | Absolute asset references could become stale after moving a store; database links could redirect migrations/cleanup. | Core source now opens the physically resolved database path with no-follow protection and rebases only matching UUID-owned regular asset files during reconciliation. Original screenshot files and unrelated files must remain protected. |
| Screenshot failure visibility/retries | Oversized screenshots could be silently rejected and status reset to “Watching.” Empty/in-progress files and transient failures needed bounded retry behavior. | Capture source now retains folder/item issues in the existing status field, reports oversized images, and schedules deferred retries. It must clear resolved issues without repeated notification spam or unbounded polling. |
| Parameter-copy failure recovery | The parameter form closed before render/size validation, discarding entered values on failure. Global alert state could also make a successful copy reopen history. | Copy now returns an explicit result; the parameter window stays available for correction/retry on failure. Existing alert presentation reports the problem; no new controls are required. |
| Auxiliary-window cleanup | The titlebar close button bypassed Cancel’s return flow; closed forms retained hosting views and drafts. | Shared close handling now returns to the panel for user cancellation and clears closed-window content/references. Programmatic successful copy must restore the destination rather than reopen history. |

Final automated and release evidence is recorded below; physical OS acceptance remains separate. The current work also builds on earlier fixes for embedded-NUL text preservation, retrying failed asset deletion, native keyboard/IME routing, shortcut recording, and capture-generation cancellation; those behaviors remain regression requirements.

## Role reports

- **Product manager:** mapped findings to existing promises and kept the visual UI/features fixed. Prioritized reliable copying, retained parameter inputs after failure, truthful status, bounded local resources, and search correctness. No broad feature additions are necessary for this maintenance pass.
- **Software engineer/storage review:** responsible for bounded collection previews, complete-record retrieval, Unicode substring search, metadata limits/accounting, relocation safety, and realistic capacity/performance fixtures. Schema compatibility, snippet independence, and source provenance remain mandatory.
- **Capture/test review:** responsible for persistent screenshot issues, bounded retries, queued-work cancellation, source-file/access checks, and privacy/lifecycle regressions. Capture fixtures must use synthetic content and a private named pasteboard.
- **Design review:** reviewed actual source changes and confirmed no blocking visual or workflow regression. Requested full-content lookups, retained parameter values after failure, fresh latest-item selection on reopening, and manual X/Cancel/Escape acceptance.
- **Root integration and release operations:** responsible for hidden-panel refresh/loading, full-content editor/copy paths, parameter-window failure handling, auxiliary-window cleanup, and keeping all existing visual layout/styling intact. Root records final build, tests, package/signature, and installation evidence separately.

## Validation boundaries

Required regression coverage includes bounded row previews versus complete copied/edited text; Unicode and embedded NUL; parameter substitution/Cancel/failure retry; text/image recopy provenance and expiry; history/snippet independence; full-store rejection; relocation/link safety; asset deletion retry; screenshot error recovery; pause/lock/exclusion changes; and suppression of stale queued commits.

Performance evidence must distinguish synthetic short-row fixtures from large-content or near-capacity stress fixtures. Record the row count, payload distribution, data volume, operation measured, and measurement method. Core query time is not panel-open latency; process RSS is not an isolated decoded-image allocation measure. Do not claim idle CPU, image-memory, or p95 UI targets from a single core benchmark.

Automated fixtures cannot establish real login/restart behavior, all clipboard permission paths, real screenshot-preview save timing, input methods in every app, actual paste compatibility, or operation across every supported macOS release. Network-restricted process tests establish only the workflows and restriction actually exercised. Preserve these distinctions in QA_REPORT.md and MANUAL_CHECKS.md.

## Deferred scope

No OCR, direct paste, export/import, cloud synchronization, new organization controls, or new feature promises are included. Export/import was previously declined and is not reopened by this review. Future feature work requires a separate concrete decision.

## Final evidence

The packaged 1.0.6 app passed 86 service checks, 35 model assertions, six hover layouts and keyboard checks. Engineering's standalone core suite and real 500-MiB stress fixtures passed. Twelve 12-MP screenshots drained in 1.582 seconds in the final packaged run, with a maximum queue of three. A 500-MiB text fixture retained 1.95 MiB of list text previews; complete copies remained exact.

Source comparisons confirmed unchanged panel/row, hover, editor/settings and parameter-form appearance, aside from the version label and internal editor action. ZIP integrity, bundle signature and installed/package executable equality passed. The installed app was restarted; its data directory and preferences were not reset.

The extreme 500-MiB emoji-heavy Unicode no-match search remains synchronous and measured 3.60 seconds. Parser stress did not test a visible form with 128,854 fields. Failed-copy form retention, X/Cancel/Escape, focus restoration, login and permission flows still have manual acceptance steps. See QA_REPORT.md, PERFORMANCE_REVIEW.md and MANUAL_CHECKS.md for exact evidence and limits.
