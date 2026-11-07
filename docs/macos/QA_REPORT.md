# ClipDiary verification report

Date: 2026-10-18 (Asia/Kolkata)

The original ClipDiary 1.0.0 verification is recorded below. The user explicitly agreed to perform remaining Mac-specific manual checks after delivery; this is not a claim that every manual acceptance case has passed. This report distinguishes checks actually run from product acceptance still requiring an interactive Mac session. Planning requirements are in PROJECT_PLAN.md.

## Observed checks

| Check | Result |
| --- | --- |
| `for script in scripts/*.sh; do bash -n "$script"; done` | Passed. |
| `/usr/bin/plutil -lint Resources/Info.plist` | Passed. |
| Release Swift build and `.app` assembly | Final `scripts/test.sh` and `scripts/package.sh` passed. Release bundle assembled and ad hoc signed; installed executable and ZIP executable hashes match. |
| Core automated checks | Engineer reports standalone runtime checks passed: text/image snippet independence across expiry/restart; exact whitespace; screenshot deduplication opt-out; corrupt-image rejection; delete-all cleanup; orphan reconciliation; newer-schema rejection without rewriting. Final native Command Line Tools standalone CoreChecks run passed, including preserved original copy time for text/image snippets. XCTest unavailable in Command Line Tools; 11 XCTest cases remain unexecuted. |
| App service integration | Final standalone service harness passed 21/21 synthetic checks with native macOS service access and a private named pasteboard; no real clipboard inspected. Includes Unicode, self-copy suppression, pause/sensitive markers, image capture, initial-folder skip, directory-event import within 0.95 seconds for the fixture, TIFF/PNG cross-source pairing, 96-hour purge, independent snippets, source preservation, no reimport after purge/restart, downtime recovery, paused-folder behavior, cancellation after pause/clear/stop, and asynchronous persistence of a synthetic 12-megapixel image. Large-image normalization/hashing runs serially off the main thread, with at most three queued payloads and generation guards against stale commits. |
| Synthetic core performance | Engineer reports: store open 1.72 ms; first durable text insert 0.42 ms; 10,000-record fixture retrieval of 9,999 rows median 6.39 ms and selective search median 2.25 ms across five runs. These are core fixture measurements, not panel latency, idle CPU or real-world image-memory results. |
| Storage/privacy core checks | Engineer reports 512 MiB accounting-limit fixture, 1 MiB text/25 MiB image rejection, combined 10,000-row cap, snippets preserved at limits, deleted sentinel absent from active DB, no remaining journal/WAL, alias-path image durability and persisted backup exclusion xattr. A final rerun also observed the Foundation backup resource flag true; persisted xattr validity passed. |
| Native app icon | AppKit-generated PNG iconset inspected visually; Apple iconutil successfully generated AppIcon.icns with native service access. |
| Bundle signature verification | Final installed app passed `codesign --verify --strict`. ZIP CRCs and executable equality with the installed release passed. |
| ZIP packaging and installation | `dist/ClipDiary-1.0.0-arm64.zip` created (1,263,381 bytes); installed at `/Users/yashmodi/Applications/ClipDiary.app` and launched with capture active. |
| Narrow-panel visual check | Root visually verified the redesigned 440 × 696-point single-column panel in CUA: no right detail column, Copy buttons or visible metadata. Accessory activation policy in all modes plus LSUIElement confirmed in source/Info.plist. Final separately identified QA bundle verified single-click text copying, arrow selection + Command-C, and image-row copying into a private pasteboard: exactly three writes for three actions; image retained 80×60 dimensions. Dismissal/focus stays on the manual checklist because observer activation can reopen the panel. |
| Snippet UI persistence | Root created a synthetic snippet using CUA and verified its permanent SQLite record in an earlier UI build. This does not yet verify the redesigned click/Command-C flow. |
| Process network restriction | Tester ran the latest standalone 21-check harness in three profiles: normal; allow-default process sandbox; and allow-default with outbound remote IP denied. All three passed 21/21. No system network settings were changed; this verifies those synthetic service workflows under that process restriction, not every GUI workflow or all possible network transports. |
| Static network audit | Searched Sources, Package.swift, and scripts for URLSession, URLRequest, Network/NWConnection, sockets, HTTP URLs, and process launches. No runtime network client found; the UI opens a local System Settings URL. Process-restricted standalone service results are recorded above; full GUI network-disabled acceptance remains pending. |

## Manual acceptance pending

- Verify interactive behavior on the visually checked 440 × 696-point panel and confirm no Dock icon at runtime in normal or preview mode. Invoke with Command-D, select by arrows, single-click a card and separately use Command-C; each copy must close the panel and restore source-app focus. Verify exactly one copy per click and no accidental copy from snippet/menu controls.
- Verify source and copy time appear only in hover tooltips and accessible descriptions, with no visible relative times or live countdowns; confirm hover itself does not copy or dismiss. Check clipping on smaller displays, large text, light/dark appearance, and keyboard focus.
- Copy Unicode/multiline text and raster images from real apps; search and copy them back; paste an image into a compatible application.
- Verify Command-D and a changed shortcut, including registration errors and conflicts with app commands.
- Enable screenshot import for a dedicated folder, save a screenshot without clicking Copy, and verify preview delay, folder changes, duplicate suppression, wake/relaunch recovery, and source-file preservation.
- Verify pause, app exclusions, supported sensitive clipboard markers, clipboard permission denial, and protected-folder denial.
- Verify 96-hour history expiry, Clear History, independent text/image snippets, restart persistence, and stale screenshots not being reimported after expiry.
- Installed app Settings reports Start automatically at login ON and “Starts automatically after you sign in”; capture active and pause OFF. Real sign-out/restart behavior remains a user manual check.
- Exercise complete GUI capture/search/snippet/screenshot workflows under an appropriate network restriction; standalone service checks and the static audit already passed, but neither establishes every GUI workflow.
- Measure idle CPU, image memory use, search latency, and storage-limit behavior against the product budgets.
- Verify the Application Support backup-exclusion attribute, including the documented consequence for snippets; verify update/rollback compatibility, quit, login-item removal, and data removal.

The outbound-IP-denied standalone profile was:

```scheme
(version 1)
(allow default)
(deny network-outbound (remote ip "*:*"))
```

The importer now falls back to an ordinary bookmark for a selected readable folder when a security-scoped bookmark is unavailable in the unsandboxed local build. This grants no new permission and preserves macOS access checks. Protected-folder denial/recovery remains a manual gate.

The restricted agent sandbox blocks native pasteboard service lookup. Service checks were therefore run with approved native macOS service access; run the test script in a normal local Terminal. The icon compiler similarly required native service access. These are development-environment restrictions, not missing backend dependencies.

Passing automated checks does not establish every interactive OS integration result above. Do not call the app fully accepted until the relevant manual checks are recorded with observed outcomes.

Latest one-line refinement: verify truncation in text rows, hover preview cap of 600 characters/12 lines, and full untruncated text on copy. Image thumbnails remain independent.

## Final installed-app observations

- Runtime `NSRunningApplication.activationPolicy` is `.accessory`: no Dock tile. Temporary QA copies were closed; installed app remains running.
- Installed executable passed all 21 synthetic integration checks with outbound IP denied, using the profile above.
- Command-D registration reports success and no shortcut error. Synthetic CUA Command-D from Settings did not produce an observable panel switch; code review found no concrete handler defect. The physical-key global invocation check is explicitly pending in MANUAL_CHECKS.md. Menu-bar invocation remains available.
- One-line text display and bounded hover preview are implemented; complete original text is used for copying. Source/copy-time metadata is tooltip-only. Saved snippets preserve original copy time.
- Superseded by 1.0.1 automatic screenshot destination discovery described below.
- The app is local and ad hoc signed for personal use, not a notarized public distribution. XCTest is unavailable in this Command Line Tools installation; standalone checks were used rather than claiming XCTest success.

Resource snapshot: the installed process was alive with Settings opened during verification and RSS 113,696 KiB (about 111 MiB). This is not a five-minute idle average; the proposed 100 MiB resident-memory target is not established and was exceeded in this interactive snapshot. No lower memory figure is claimed.

## 1.0.1 fast fix

Automatic screenshot capture now discovers the macOS screenshot destination, defaults to Desktop, imports only macOS-tagged screenshots, and backfills the last 96 hours. Explicit folder selection retains all-image import behavior. No system screenshot preferences are changed. All 27 service checks passed normally and with outbound IP blocked using temporary folders; actual Desktop permission and screenshots remain user checks.

The panel shows newest items at the bottom and opens scrolled to the latest item. Guide text was removed. Hover previews now use an immediate native popover with animation disabled instead of the delayed system tooltip. Real pointer timing and scrolling remain user checks.

## 1.0.2 hover and performance fixes

Release capture harness passed 30/30 checks, including partial screenshot rejection/retry and a 12-megapixel screenshot timing gate. Completed-file-to-persisted-item latency measured 0.190 seconds for the small fixture and 0.272 seconds for the 12-megapixel fixture. Tester debug run independently passed 30/30 with 0.187/0.285 seconds, compared with 0.266 seconds for the baseline small fixture. These are individual synthetic measurements, not p95 or actual macOS keypress-to-history timings.

Six native hover-layout cases passed with a maximum release construction/layout time of 12.75 ms. Preview ownership is now singular, scroll updates are settled for 80 ms, menus/covered windows are suppressed, thumbnail decoding is cached, and unchanged status strings avoid publications. The panel explicitly accepts mouse movement so same-row hover can resume after dismissal. Interactive pointer behavior remains a manual check. Core storage checks passed, including expiry-aware single-item lookup, ordering index, limits, and asset cleanup without loading text. See PERFORMANCE_REVIEW.md for each agent's findings.

## 1.0.3 source-preserving recopy — 2026-10-19

Final combined scripts/test.sh passed: storage CoreChecks, six native hover layouts, and 51/51 capture/model checks. The 21 added model checks exercise the same copySelected method used by both row click and Command-C with an isolated database and private pasteboard. No real clipboard or user history was inspected.

Ordinary history copies keep their public identifier, source, exact contents, title, byte accounting and image paths. Capture time is updated and expiry renewed for 96 hours. Internal SQLite row ordering breaks identical-time ties so the copied item is latest. Snippet copies create independent history records/assets and do not change permanent snippet metadata. Automatic self-capture remains suppressed. Explicit copies still work while automatic capture is paused or excluded.

Verified restart order, image independence, missing/expired rejection, cap-safe promotion, and a SQLite-trigger-induced persistence failure after clipboard success: the partial-success error remains visible and the prior timestamp remains unchanged. Product manager, software engineer, designer and tester reviewed this change before installation-package replacement. Real click/keyboard focus and macOS permission/login acceptance remain on the manual checklist.

Release delivery: built and packaged dist/ClipDiary-1.0.3-arm64.zip after all four signoffs. ZIP integrity passed, installed bundle signature verified, version confirmed 1.0.3, installed executable SHA-256 matched the packaged app, and the app was relaunched. Existing data/preferences were retained.

## 1.0.4 parameterized snippets and editor/navigation fixes — 2026-10-26

Combined scripts/test.sh passed: CoreChecks (including a real schema-1 database migrated to schema 2), six native hover layouts, and 62/62 capture/model checks. Parameter checks cover explicit opt-in, unique repeated names, Unicode names, literal nonrecursive replacement, blank/missing values, cancel-before-copy, persisted mode, unchanged templates/source, exact rendered history, expansion limits before clipboard mutation, and ordinary rendered history without prompting. Collection switches select the newest item; a fresh collection scroll view and deferred bottom scrolling prevent stale offsets.

Native editor checks exercise insertion, undo, redo, and installed Edit-menu actions on the same editor factory used in the actual snippet window. Copy/paste key dispatch and visible scrolling remain interactive manual checks; no general clipboard or user history was used in automated checks. Added standard responder-chain Edit commands and an undo-enabled plain NSTextView. Parameters are offered only for saved text snippets, through their context menu or edit toggle. Existing snippets remain literal by default; no snippet data is rewritten by rendering.

Delivery: ClipDiary 1.0.4 ZIP integrity passed; installed bundle signature and version verified; installed executable SHA-256 matches dist. App relaunched. Existing database migrates transactionally; no user clipboard/history contents were inspected for verification.

## 1.0.5 maintenance code review

Scope: inspected all production Swift modules, native platform integration, storage and template logic, release scripts, package/resources, and existing verification coverage. Product, engineering, design and testing agents reviewed their areas. The user explicitly selected bug fixes only; export/import, tags/folders and OCR were not implemented. UI layout, row appearance, navigation model and existing features remain unchanged.

| Verified bug | Fix and regression evidence |
| --- | --- |
| Embedded null characters truncated text/title/source | Explicit SQLite UTF-8 byte lengths on binding and decoding; exact round-trip checks |
| Failed image deletion persisted until restart | Retain failed owned-asset removals and retry on normal purge; permission failure/recovery fixture |
| Linked database could modify unrelated data | SQLite no-follow open with physical root resolution; external sentinel database remains unchanged and legitimate root aliases work |
| Expired history could become permanent through Save as Snippet | Use expiry-aware lookup; exact expired-row rejection |
| Failed screenshot-folder choice dropped an already queued clipboard image | Validate destination before advancing capture generation; reproduced pre-fix failure now passes |
| Wake/session event could release a separate screen lock | Track suspension reasons independently; overlap/release checks |
| Screenshot path could change between scan and read | Open without following links and verify descriptor identity, size and times before/after bounded read; link/replacement/mutation checks |
| Corrupt explicit-folder bookmark could enable automatic capture elsewhere | Preserve explicit source intent instead of falling back to Desktop; corrupt-bookmark fixture |
| Deleted duplicate row could suppress an incoming screenshot | Pair only with a still-existing history record; deletion-between-arrivals check |
| Incomplete PNG could decode and enter history | PNG-signature-specific terminal IEND validation; incomplete/repaired fixture, TIFF/HEIC behavior retained |
| Command-C stole selected search text | Leave selected text to native Copy; retain row copy when no text is selected |
| Shift arrows/IME navigation were intercepted | Preserve native selection/composition keys; unmodified row navigation remains |
| Recording Command-Q could execute Quit | Focused recorder consumes key equivalents; actual NSWindow dispatch fixture |

Engineering reproduced the storage failures and passed the full standalone CoreChecks after fixes, including existing migrations, parameterization, recopy, caps and asset durability. Tester reproduced queued-copy loss and incomplete-PNG acceptance before their fixes. The final integrated debug app passed 74/74 service/model/template checks, six native hover layouts, and the keyboard-routing checks. Screenshot fixtures measured 0.198 seconds after completed save, and 0.275 seconds for 12 MP; these are individual fixtures, not user latency percentiles.

Tests use isolated stores and private pasteboards. No real clipboard content or history was inspected. Physical global shortcuts, system permission prompts and sign-in behavior remain the existing manual acceptance checks, not newly claimed verified outcomes. This review is evidence of the fixes listed above, not a claim that every possible bug is eliminated.

Release verification: packaged 1.0.5 executable independently passed 74/74 service/model/template checks, keyboard routing and six hover layouts. Fixture import timings were 0.157 seconds (small) and 0.272 seconds (12 MP). ZIP integrity, shell syntax and Info.plist validation passed. Installed version is 1.0.5; strict signature verification passed; installed executable SHA-256 matches the packaged executable (`6f947840462327d387a2911d9656fd73f22a0c01e530f6e1636279b53e97a113`). App was restarted with the existing data directory and preferences retained.

Completion audit: production source and release tooling reviewed; 13 confirmed defects fixed with regression evidence; no feature additions (user declined export/import); layout/view composition unchanged; existing agents consulted; current source, release ZIP and installed app aligned. Existing manual OS acceptance limits remain documented separately and do not represent newly verified results.


## ClipDiary 1.0.6 reliability, security and performance review

Date: 6 November 2026. The user approved internal and UX improvements while requiring the visual UI to stay unchanged. Product management, storage engineering, capture/testing and design reviewed their areas; root handled integration and release operations. See MAINTENANCE_REVIEW.md for role reports.

Changes in this patch:

- Collection queries return bounded text/title/source previews; full records are resolved for copying, editing and parameter discovery. Hidden panels release their rows, background maintenance avoids materializing history, and unchanged visible lists are not republished. Startup asset reconciliation reads metadata only.
- Search remains a literal substring search, with Unicode case matching and canonical normalization applied only during search. Query punctuation is escaped, stored/copied text stays unchanged, and matching still includes content beyond the preview. The product review explicitly rejected introducing a whole-grapheme-only search restriction.
- Storage capacity now includes title/source bytes, with per-field limits; shrinking edits remain possible in a legacy over-budget store. Expired history is purged before snippet capacity checks. Public item-size display and schema 2 remain unchanged.
- Moving a complete data directory preserves matching UUID-owned image/snippet assets and thumbnails. Reconciliation rebases only the corresponding regular files in app-owned folders.
- Screenshot reads are anchored to the selected directory's identity and use relative descriptor opens. Replacing that directory cannot silently redirect capture. Temporary storage failures back off rather than repeatedly decoding images; errors persist until resolved. Oversized images report their limit and empty files remain retryable until written.
- Failed parameter copies retain the form and entered values. Successful copy uses an explicit result and clears stale errors. Cancel, Escape and the titlebar close path return to the panel; completed auxiliary windows release their hosted content.

Security scope: no runtime network client or third-party package was introduced or found in the source/manifest scan. Tests use disposable stores and private pasteboards, not the user's clipboard or saved contents. This is a source and regression review, not a claim of a formal penetration test or absence of every vulnerability. macOS security updates and notarized public distribution are outside this app patch.

Visual regression evidence: a source comparison against the previous release confirmed identical panel/row composition, hover implementation and native snippet/parameter form views. The editor action now retrieves complete text; the Settings version label changes. Physical interaction, focus restoration, permission and login checks remain documented in MANUAL_CHECKS.md. In particular, the visible failed-parameter sheet and X/Cancel/Escape flow need the user's interactive check; model result/retention dependencies and native window cleanup are exercised automatically.

Final release verification: the packaged 1.0.6 executable passed 86/86 service checks, 35 model assertions, keyboard routing and six native hover layouts. Maximum hover construction/layout was 13.21 ms. The packaged screenshot fixtures measured 0.202 seconds (small), 0.278 seconds (12 MP), and 1.582 seconds for twelve 12-MP files with at most three queued preparations. These are individual synthetic samples, not user-facing latency percentiles.

Engineering's final standalone core regression pass succeeded, including Unicode literal-search policy, embedded NUL, metadata budgets, expired capacity, relocated assets, migration, recopy, deletion, and parameterization. Real 500-MiB and near-1-MiB parser stress results and the remaining 3.60-second worst-case synchronous Unicode scan are detailed in PERFORMANCE_REVIEW.md. The original 1.0.5 native baseline also passed all 74 checks before changes. XCTest remains unavailable in the installed Command Line Tools; no claim is made that the separate XCTest sources were run.

Packaging, ZIP CRC verification, shell syntax, Info.plist lint and strict signature checks passed. Native build access was needed after the restricted environment blocked debug-symbol generation; the subsequent native release build completed. Installed bundle version is 1.0.6 (build 7). Installed and packaged executable SHA-256 match: `8566c6cdae04b55c8d9c01e3a896bf5326bb34ac7986dd82eea13202bf8878d8`. The update replaced only the application bundle and relaunched it without `--show`; existing data and preferences were not reset. The shareable artifact is `dist/ClipDiary-1.0.6-arm64.zip`.

This completes the scoped maintenance pass. Remaining manual interactions and the documented extreme-search limit are not represented as passed or eliminated.
