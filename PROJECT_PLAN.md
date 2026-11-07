# Local Clipboard — product and delivery brief

Date: 18 October 2026 · Status: implemented local release candidate; automated core/service checks pass, with interactive UI, login, offline-runtime and performance acceptance still pending. See QA_REPORT.md for observed evidence.

## 1. Purpose and feasibility

Build a personal macOS clipboard manager that quietly remembers copied text and images, automatically imports new screenshots, makes it quick to retrieve, and keeps selected reusable snippets indefinitely. It must run entirely on this Mac without an account, subscription, backend, hosted database, cloud sync, or external AI service.

**Feasible:** use a native Swift app, macOS clipboard APIs, and an embedded SQLite file. SQLite is a local database library, not a database server. The installed app should work with networking disabled.

“Always active” means running in the signed-in user's session, starting automatically at login after initial setup. It cannot capture before login, during sleep, while powered off, after an explicit quit, or while macOS denies clipboard access. Closing the panel must leave capture running. Ordinary app termination/crash recovery must be investigated and tested rather than advertised as guaranteed uptime.

Observed development machine: Apple Silicon, macOS 26.7.1, Swift 6.4, selected developer directory `/Library/Developer/CommandLineTools`. Full Xcode availability has not been verified. The repository now contains the native app, local SQLite/image store, screenshot importer, standalone checks, local release scripts and an ad hoc signed application bundle. The configured deployment target is macOS 14; this build has been compiled on the observed Mac, but running on macOS 14 itself remains unverified. This Mac is the first release target.

## 2. Research and resulting product choices

| Evidence | What we adopt |
| --- | --- |
| [Maccy official site](https://maccy.app/) emphasizes local storage, speed, native UI, keyboard access and password-manager safety. Its [source repository](https://github.com/p0deje/Maccy) provides an open-source reference. | Keep the app small, offline and keyboard-first. Respect sensitive clipboard markers. Build our own scoped implementation; assess licenses before reusing code. |
| [Paste's Mac guide](https://pasteapp.io/help/paste-on-mac) describes search, previews, source metadata, configurable invocation and copy fallback when direct paste is unavailable. | Provide fast retrieval and a reliable copy action. Treat automatic paste as a separately permissioned enhancement. |
| [Paste pinboards](https://pasteapp.io/help/organize-with-pinboards) separate reusable saved content from chronological history. | Give Snippets a separate lifetime and view. |
| [Apple's Spotlight guide](https://support.apple.com/en-ie/guide/mac-help/mchl40d5b86b/27/mac/27) documents built-in clipboard-history search. | Differentiate through explicit four-day retention, permanent snippets, privacy controls and a custom invocation shortcut; do not claim macOS has no history feature. |
| Apple documents [NSPasteboard](https://developer.apple.com/documentation/appkit/nspasteboard), [changeCount](https://developer.apple.com/documentation/appkit/nspasteboard/changecount), and [pasteboard access behavior](https://developer.apple.com/documentation/appkit/nspasteboard/accessbehavior-86972). | Monitor clipboard changes using supported APIs; account for OS-specific access restrictions and revocation. |
| Apple documents [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice) and [mainApp](https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp). | Use the supported per-user login-item mechanism, showing its actual registration status. |

These are product and architecture recommendations derived from research, not claims that this project's features already work. Sources accessed 18 October 2026. Only the official `maccy.app` site and linked repository are used as Maccy sources.

## 3. Required first release

| ID | Requirement | Acceptance condition |
| --- | --- | --- |
| P0-01 | Automatically capture plain text, including URLs and code as text. | Text copied from representative apps is persisted with Unicode, whitespace and line breaks intact. No HTML execution or automatic URL fetching. |
| P0-02 | Run as a menu-bar utility. | Hiding/closing the panel keeps capture active; startup opens no main window after onboarding; menu offers Open, Pause/Resume, Settings and Quit. No Dock icon appears in normal or preview mode. |
| P0-03 | Start at login. | After one-time setup and macOS approval, login starts capture without a manual app launch. Disabled/denied registration is visible and recoverable. |
| P0-04 | Configurable global invocation shortcut. | Requested `⌘D` works if registration succeeds; users can record another combination. Registration failure preserves the last working choice. |
| P0-05 | Search and retrieve rapidly. | Search locally in a narrow single-column panel; oldest-to-newest cards with latest at the bottom; arrow-key selection; single-clicking an item or pressing Command-C with an item selected copies and dismisses; Escape dismisses and restores previous focus. No separate detail column or Copy buttons. |
| P0-06 | Permanent Snippets section. | Save any history item as an independent snippet; create, title, edit, search and delete snippets. Cleanup, Clear History and restarts preserve snippets. |
| P0-07 | Four-day automatic history retention. | History expires after a rolling 96 hours under the rules below. Expired content never appears in normal results. |
| P0-08 | Individual deletion and Clear History. | Remove a selected record or all history; Clear History explicitly preserves snippets. Delete All Local Data is a separate confirmed action. |
| P0-09 | Pause and privacy exclusions. | Paused automatic capture and configured app exclusions prevent passive recording; explicit user copies still refresh recency. Pause state remains visible. Skip supported sensitive/transient markers before persistence. |
| P0-10 | Durable local storage and truthful errors. | Committed data survives restart. Storage failure reports that capture is unavailable; never show a false saved/success state. |
| P0-11 | No network dependence. | All core workflows pass offline, and the app makes no application-owned outbound requests or content-bearing telemetry. |
| P0-12 | Clipboard image history. | Supported copied raster images persist locally with in-list thumbnails; clicking a card or Command-C copies the full image and dismisses. Four-day expiry includes image assets. |
| P0-13 | Automatic screenshot import. | After one-time opt-in folder setup, newly saved screenshots enter history without a preview/copy click; incomplete files, permissions and duplicates are handled. |
| P0-14 | Image snippets. | Save an image independently as a titled snippet; history expiry and source-file deletion preserve its full image and thumbnail. |

`⌘D` is the user's preferred shortcut. It already serves commands in other applications, so assigning it globally may override those commands; explain that during shortcut setup. Detect registration conflicts where possible, but do not claim every application shortcut conflict can be detected. Menu-bar invocation must remain available.

### Retention and snippet semantics

1. Persist UTC `capturedAt` and `expiresAt = capturedAt + 96 hours`. “Four days” is a rolling duration, not four calendar dates.
2. Exclude expired records at query time. Purge on launch, wake, before opening/searching history, and at least once per minute while awake. Remove a selected expired item while the panel remains open.
3. During sleep/offline app time, physical deletion cannot run. Purge on resume before returning results. Already-deleted records must never return after a clock change; define and test handling of large clock adjustments.
4. Saving a snippet creates a separate record in a transaction. Its source history item can remain in history and expire normally. Snippets never expire. The initial implementation rejects new writes at its storage limit rather than evicting saved records.
5. Collapse consecutive identical external copies without refreshing the original expiry. A new external copy after intervening clipboard content can create a new record. Preserve exact text; do not trim to determine identity.
6. Copying an item through this app must not recapture it or extend its lifetime. Track app-originated pasteboard writes and test races with external copies.
7. Clear History deletes only history. Deleting a snippet does not implicitly delete a separate history record. State these scopes in the UI.
8. Deletion includes app-owned rows, indexes, previews, caches and relevant database journal remnants. Use a tested SQLite cleanup policy; see [SQLite secure_delete](https://www.sqlite.org/pragma.html#pragma_secure_delete).
9. Promise removal from app-controlled storage, not forensic erasure from SSD/APFS snapshots, Time Machine, user exports, or other apps' histories. The app does not control the current system clipboard or Spotlight's separate history; clearing history does not silently clear either.
10. Generate no automatic clipboard-content exports or backup copies. Mark the entire app-managed storage directory as excluded from normal system backup, including history and snippets, and verify the attribute. Existing snapshots remain outside our control. Permanent snippets therefore also need an explicit future export/backup option.


## 3A. Image and automatic screenshot addition — 18 October 2026

The user explicitly expanded the first release beyond text. Product-manager, software-engineer and tester reviews recommend **clipboard images plus opt-in screenshot-folder import**. A custom screenshot capture overlay is not needed for this workflow.

### Daily workflow and setup

- Images copied as actual raster clipboard content from supported applications enter history automatically. Copying an image URL or a Finder file reference is not automatically equivalent to copying image pixels; arbitrary file ingestion remains separately scoped.
- During setup, choose a dedicated local screenshot folder and grant access. Guide the user to `⌘⇧5 → Options → Save to → Other Location` and select that folder. Do not silently change system preferences. Avoid iCloud-backed Desktop/Documents for the local-only workflow.
- Continue using native `⌘⇧3`, `⌘⇧4`, or `⌘⇧5`. Watch the destination and import supported completed image files automatically, without clicking the preview or choosing Copy to Clipboard.
- Import occurs **after macOS writes the file**, not at the exact shutter instant. Recommend disabling Show Floating Thumbnail for prompt saving; keep the choice explicit. While markup/preview is open, import may wait or receive only the final saved version.
- Alternative native shortcuts `⌃⌘⇧3` and `⌃⌘⇧4` put screenshots directly on the clipboard, so the image monitor can record them without folder import. This is an alternative, not a requirement to change the user's existing shortcut habits.
- Folder import stores an internal image copy without replacing the system clipboard. The user can click its image card or press Command-C on the selected card later. Automatic screenshot-to-system-clipboard writes would be a separate setting, because they could overwrite copied text unexpectedly.

Apple documents destination selection, thumbnail behavior and clipboard screenshot shortcuts in its [screenshot guide](https://support.apple.com/en-gb/102646) and [Screenshot app guide](https://support.apple.com/en-euro/guide/mac-help/mh26782/mac). Filesystem monitoring is supported through [DispatchSource](https://developer.apple.com/documentation/dispatch/dispatchsource). The proposed import design is an engineering inference from those facilities and still needs a prototype on this Mac.

### Image behavior and storage

- Show image thumbnails within the single-column history list. Source and copy/capture time appear only in hover tooltips; do not show visible timestamps, relative-time labels or live expiry countdowns. No separate detail column or Copy buttons. Provide All / Text / Images filters. Search image titles/filenames and metadata; text inside pixels is not searchable until later OCR work.
- Copy restores image content, not merely a filename/path. Support common raster inputs through ImageIO/AppKit, with validated PNG/TIFF/JPEG clipboard decoding and screenshot PNG/HEIF support where the OS supplies them. Preserve transparency and source fidelity; validate HDR handling instead of assuming every screenshot is PNG.
- Save an image as an independent permanent snippet with an optional editable title; image editing/cropping is later scope. A shared internal asset may use reference tracking, but must remain until its last history/snippet owner is deleted.
- Put metadata in SQLite and full images/thumbnails in the app's private asset directory. Use atomic writes, bounded decoding, lazy previews, a small decoded-image cache and orphan reconciliation after crashes. Do not load every full-size image into memory.
- Apply the same 96-hour expiry to ordinary image history. Cleanup removes unreferenced internal originals and thumbnails as well as metadata. A permanent image snippet protects its own asset.
- Source screenshot files saved by macOS remain untouched. App retention cannot delete those originals or their backups. Do not imply four-day cleanup removes screenshots from the source folder.

### Import correctness and privacy

- Begin with new screenshots after setup. Do not silently import existing pictures. A dedicated folder has the clearest scope; watching a mixed Desktop requires validated screenshot identification, not an English filename prefix alone.
- Filesystem events are hints: rescan/reconcile, wait for stable readable images, reject malformed/oversized content and retry transient incomplete writes with bounds. Never follow symlinks outside the chosen folder or fetch remote image URLs.
- Track processed file identities/versions and an import baseline so launches, renames, reconciliation and history expiry do not repeatedly import the same surviving source file. Keep this metadata content-free; do not persist titles or image hashes in diagnostic logs.
- Reconcile eligible missed files after restart only within the configured import window and 96-hour lifetime; use the saved file's capture/creation time where trustworthy rather than granting an old screenshot four fresh days. Folder copies/backdated files need a documented conservative rule.
- Pause applies to both clipboard and screenshot import. Advance the paused baseline so shots deliberately skipped while paused/locked are not later backfilled. Make inaccessible/moved folders visible and let users reselect them.
- Deduplicate repeated events and, when matching representations permit it, the same shot arriving via clipboard and folder. Bound any cross-route matching window so legitimate future re-copies are not suppressed forever.
- Importing an existing image file does not itself capture the screen, so this design does not require Screen Recording permission for our app. Folder access and clipboard permissions still need validation. Source-app exclusions cannot reliably determine which applications are visible inside a screenshot; explain that and provide an independent screenshot-import toggle.
- An optional future app-owned screenshot shortcut could capture directly into history. That is a separate feature with selection UI and screen-capture permission, documented by [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit); do not request that permission just to import saved screenshot files.

### Updated role handoffs

PM owns screenshot onboarding and retention wording; engineer owns image/asset handling, folder monitoring, cross-route deduplication and permission recovery; designer deliverables expand to thumbnails, image previews, filters and folder setup; tester covers image round trips, original-file preservation, import timing, pause/restart reconciliation, storage cleanup and image-snippet lifetime; release engineering covers folder access persistence and asset migration/rollback. Image support is now P0; OCR and a custom screenshot capture tool remain later features.

## 4. Privacy and permission behavior

- Store data only in the app's per-user Application Support directory, outside this Git repository. Settings belong in UserDefaults. Never commit real clipboard data or store it in development fixtures.
- Do not log clipboard bodies, previews, search queries, snippet titles, secrets, or content-derived hashes. Diagnostics can contain operation names, timings and error codes.
- Respect supported concealed/transient pasteboard types, including password-manager markers. Marker filtering is best effort, not universal password or token detection. Do not claim arbitrary secrets can be recognized safely.
- Allow exclusions by application bundle identifier. Source attribution can be imperfect; label unknown source honestly. Pause capture on lock, then rebaseline on unlock so content copied during the paused interval is not imported later.
- Clipboard-read access and Accessibility permission are separate concerns. Check API availability and observed macOS behavior; surface denied clipboard access and stop repeated prompts. Capture must not claim to work if reads are blocked.
- The baseline copies the selected text or full image to the clipboard for manual `⌘V`. Optional direct paste later may need Accessibility permission; denial must leave capture/search/snippets/copy usable when clipboard reads are allowed.
- Do not request Screen Recording, Full Disk Access, admin access, or broad input monitoring without a separately justified feature.
- First version uses ordinary local SQLite protected by macOS user-file access, not an advertised encrypted vault. FileVault is user-managed. Application-level encryption would require a separate Keychain/key-recovery design and deletion review before any such claim.

## 5. Interaction and visual design

Use SwiftUI for views with AppKit integration for a menu-bar status item and floating panel. The user's updated design overrides the earlier wide preview layout: use a sleek, narrow vertical rectangle approximately **440 × 696 points**, about 20% taller than the previous 580-point panel and substantially narrower than 820 points. Fit to the active display when its usable area is smaller. Use a single list column with in-card text excerpts and image thumbnails; remove the right detail column entirely. Support light/dark appearance, VoiceOver, keyboard focus, sufficient contrast and reduced motion. Keep accessory/menu-bar activation policy in every mode, including preview; never add a Dock icon.

```text
┌────────────────────────────┐
│ ClipDiary          Settings│
│ Search…                    │
│ History       Snippets     │
├────────────────────────────┤
│ Copied text card…          │
│                            │
│ Image thumbnail card      │
│                            │
│ Another copied item…      │
│                            │
│                            │
├────────────────────────────┤
│ ↑↓ Select · ⌘C Copy · Esc   │
└────────────────────────────┘
```

- Invocation remains Command-D by default and focuses search. Arrow keys select cards without copying. Single-clicking the card body copies its text or full image, closes the panel and restores the previous application's focus. Command-C performs the same action on the selected card. No visible Copy/Copy Image buttons, and no second click or confirmation is required.
- Source and copy/capture time belong in hover tooltips only. Do not show live countdowns, relative times or visible source/time metadata in rows or a detail area. Retention checks continue in the background; hiding timers does not change the 96-hour policy.
- Tab follows normal focus order; Command-1/Command-2 switch History/Snippets; Escape closes. Define snippet-editor and text-editing contexts so collection shortcuts do not corrupt snippet text.
- Save/Edit/Delete controls or context-menu actions must remain available without triggering the card's single-click copy action. Hover information must also have an accessible description for VoiceOver users.
- Save as Snippet opens a small editor with an optional title. Confirm success only after durable save. Original history remains eligible for ordinary expiry.
- Settings groups: General (shortcut/login), History (96-hour rule/storage), Privacy (excluded apps/pause), and Permissions (actual status/recovery).
- Empty history explains how to copy text; empty snippets explains saving; no results offers clearing search. These must be distinct states.
- Show capture paused, clipboard access denied, shortcut unavailable, storage full/unavailable, item expired and oversized item skipped states. Avoid notification spam for every copied item.
- Clear History and Delete All Local Data need scope-aware confirmation. Snippets must never be included accidentally.

## 6. Native implementation design

| Component | Responsibility |
| --- | --- |
| App coordinator | Menu-bar lifecycle, panel visibility, app activation/focus restoration. |
| Clipboard monitor | Poll `NSPasteboard.general.changeCount` at a measured interval; inspect supported types, permissions and markers; decode bounded text/images; suppress own writes. |
| Screenshot importer | Monitor the chosen folder, wait for completed supported images, reconcile filesystem events and import once. |
| Asset store | Atomic app-owned image writes, bounded thumbnail generation, ownership tracking and deletion of unreferenced assets. |
| Capture policy | Pause/lock state, exclusions, consecutive deduplication and size limits before persistence. |
| Local repository | Serialized SQLite access, prepared statements, schema migrations and transactional writes/deletes. |
| Retention service | Injectable clock; query filtering and expiry cleanup on timer/lifecycle events. |
| History/snippet models | Separate lifetimes, search and snippet editing. |
| Shortcut service | Global registration, configurable key recorder, validation and actionable failure. Prototype the supported registration approach before committing to a library/API. |
| Login service | `SMAppService.mainApp`, actual registration status and System Settings recovery. |
| Optional paste service | Later: restore target app and issue paste only after permission and focus checks. |

Initial clipboard polling proposal: approximately 500 ms while active; suspend on sleep/lock and rebaseline appropriately. Benchmark before fixing the interval. Polling sees the current clipboard state and cannot guarantee recovery of every intermediate copy when multiple writes happen between polls. Do not install a keyboard logger to compensate.

Suggested schema:

```text
history_items(id, kind, text?, asset_id?, title?, captured_at, expires_at, origin, source_bundle_id?, source_name?, byte_count)
snippets(id, kind, title?, text?, asset_id?, created_at, updated_at)
assets(id, relative_path, thumbnail_path?, media_type, width, height, byte_count)
screenshot_import_state(folder_identity, baseline, processed_file_identity, processed_version)
schema_migrations(version, applied_at)
```

Index expiry and capture time. For the bounded first release, use parameterized local substring search without a content-duplicating full-text index; measure it. Consider FTS only after proving it improves performance and its deleted-content cleanup works. Do not make snippets depend on a cascading foreign key to expiring history.

Initial implemented limits: 1 MiB UTF-8 text per captured item, 25 MiB encoded per image and 50 megapixels decoded. The combined tracked-content budget is 512 MiB for history, snippets, originals and thumbnails; SQLite/filesystem overhead is additional. These limits are fixed in the initial build. At capacity, reject new saves with an explicit error; do not evict existing history or snippets or silently truncate. Users can delete unwanted items or wait for ordinary history expiry. Measure peak decoding memory before revising these limits. A 10,000-record limit across history and snippets also rejects new records until records are removed or ordinary history expires; existing snippets are protected. The same count is a performance benchmark dataset.

Proposed performance targets on this Mac, to verify with synthetic data: panel usable within 200 ms at p95; search within 100 ms at p95 for 10,000 bounded text entries; idle CPU below 1% averaged over five minutes; resident memory below 100 MiB in the text-only baseline; image-preview memory and decoded-image cache budgets require separate measured targets. Record dataset size, OS/build and measurement method; these are targets, not results.

## 7. Later features and deliberate exclusions

| Phase | Features |
| --- | --- |
| P1, after reliable core | Optional direct paste; snippet folders/tags; explicit local snippet import/export; configurable retention; plain-text transformations; quick-number item selection. |
| P2, independently scoped | Rich text/file references; on-device OCR; more advanced filtering. Snippet parameters are already implemented as an opt-in setting. Each needs storage, permission, retention and resource budgets. |
| Excluded | Servers, hosted databases, accounts, subscriptions, cloud sync, mobile clients, team sharing, remote AI, analytics and hosted update infrastructure. |

No need to reproduce every paid application's feature. Retrieval speed, predictable lifetime, durable snippets and low background cost define success.

## 8. Role assignments and handoffs

Specialist planning reviews were requested for the roles below. These are implementation work packages, not claims of delivered software.

| Role | Work package and deliverables | Handoff / completion gate |
| --- | --- | --- |
| Product manager | Own this scope, requirement IDs, assumptions, prioritization and acceptance decisions. Resolve retention/cap wording and feature tradeoffs. | Each shipped feature maps to requirements; later features cannot expand P0 silently. |
| Designer | Panel, snippet editor, onboarding/settings layouts; keyboard/focus map; light/dark/accessibility states; error and permission copy. | Engineer receives all normal, empty, denied and failure states before UI completion. |
| Software engineer | Native app shell, clipboard/image monitor, screenshot importer, asset store, policy, repository/migrations, expiry, snippets, search, shortcuts, login integration and failure handling. | Buildable app plus tests for the meaningful data/lifecycle rules; no content logging or runtime network dependencies. |
| Tester | Controlled-clock retention tests, privacy and race cases, UI/lifecycle/manual acceptance matrix and release report. | P0 gates below pass on the installed app; unresolved defects documented. |
| DevOps / release engineer | Local build/test/package scripts, versions, optional signing, installation/update/rollback instructions and privacy-safe diagnostics. | Reproducible local `.app` artifact; cold-start/login/offline smoke checks; no server required. |

Suggested future code ownership: engineer owns `Sources/` and repository migrations; tester owns `Tests/` and QA evidence; designer owns `docs/design/`; release engineer owns `scripts/` and packaging docs; product manager owns this brief. Coordinate shared interfaces before simultaneous edits. Do not create all these directories until they have content.

## 9. Delivery sequence

1. **Feasibility spike — engineer + release engineer:** build a bundled menu-bar app locally; verify text/image capture permission and screenshot-folder import timing/access on macOS 26.7.1, chosen shortcut, correct focus and login registration from an installed location. Confirm available build tools. Record limitations before UI expansion.
2. **Core data — engineer + tester:** implement local repository/migrations, image assets/thumbnails, screenshot import, bounded capture, filtering, own-write suppression, precise expiry and independent snippets. Test time and persistence rules using synthetic content.
3. **Daily-use UI — designer + engineer:** panel/search/preview, snippet editor, settings, keyboard flow and all denied/failure states. PM checks requirement coverage.
4. **Reliability — tester + engineer:** reboot/login, sleep/wake, lock/unlock, app exclusions, clipboard access changes, disk failure and capacity behavior. Measure resources and perform a working-day soak.
5. **Personal release — release engineer + tester:** create/install a versioned local app, document launch/login and update/rollback, run offline acceptance and produce a QA report. Then use the app personally before P1.

## 10. Release acceptance matrix

| Area | Required checks |
| --- | --- |
| Text integrity | Unicode/emoji, multiline code, whitespace, empty/non-text boards, URLs as text, boundary/oversized input and supported source apps. |
| Images/screenshots | Clipboard PNG/TIFF/JPEG and screenshot PNG/HEIF where supported; transparent/HDR/large/corrupt images; actual image paste; partial writes; thumbnail delay; screenshot folder changes/revocation; multi-display shots; duplicate imports; no unrelated Desktop files or expired-file reimport. |
| Retention | Controlled times just before/at/after 96 hours; purge before UI/search; timer while panel open; long sleep; time zone/clock changes; no expired record restored. |
| Snippets | Text and images: save just before expiry; restart; source deletion; Clear History; edit/search/delete; no snippet loss at history cap. |
| Clipboard races | Consecutive duplicate; external A→B→A; self-copy without recapture; rapid copies; pasteboard changes during read; skipped item never imported later after pause. |
| Lifecycle | First install, login launch, denied/disabled login registration, no startup window, hide vs quit, sleep/wake, lock/unlock and relaunch after crash. |
| Shortcuts/focus | `⌘D` and another choice; registration failure; repeat invocation; Escape restores focus; multiple displays/Spaces/full-screen; menu-bar fallback. |
| Privacy | Sensitive marker exclusions; excluded apps; unknown source; pause; access denial/revocation; no content in logs, Git, caches or test artifacts. |
| Storage | Restart durability; disk full/unavailable; migration failure without destructive reset; bounded history; deletion and journal/cache inspection using synthetic sentinels. |
| Offline/resources | Network-disabled complete workflows; inspect app-owned network activity; CPU/memory/search/panel measurements; long-running capture soak. |
| Accessibility | Keyboard-only complete flows, VoiceOver labels/focus, contrast and light/dark/reduced-motion behavior. |

The supplied Command Line Tools lack XCTest. The default test script therefore runs a standalone core assertion executable plus app service integration checks on an isolated named pasteboard; failures must return a nonzero exit status. An explicit `--xctest` option additionally runs XCTest when a full Xcode toolchain provides it. No missing-test fallback may report success. Use unit tests where they verify substantive logic (expiry, policy, migrations, lifetime independence and suppression); use installed-app/manual checks for login, global shortcuts and OS permission behavior. Do not substitute mocked tests for macOS integration evidence.

## 11. Local delivery and maintenance

- Prefer native system frameworks and the system SQLite library. Dependencies need a concrete benefit, pinned versions and license review. No package may add runtime telemetry or network calls.
- Proposed build path: Swift Package Manager for shared logic/tests plus local scripts assembling the executable, resources and Info.plist into an arm64 `.app`. Verify the available SDK with a minimal SwiftUI/AppKit build first. Supply `scripts/build.sh`, `scripts/test.sh` and `scripts/package.sh` when implementation starts. Full Xcode may be needed for chosen UI-test/archive workflows; inspect tools before installing anything. No cloud CI is required.
- Develop/test in a separate data directory with synthetic clipboard values. Build products, local databases, journal files, exports, signing secrets and real-user QA captures must be ignored by Git.
- Package a versioned `.app`; install it in a stable location before login integration checks. Keep bundle identity stable so updates do not unnecessarily break stored data or permissions.
- Start with ad hoc signing for the personal local build and test macOS permission persistence across rebuilds. If necessary, evaluate a stable local signing identity. Install into `~/Applications` through a documented local step; test duplicate-instance prevention and fast-user switching without crossing user accounts.
- Manual local updates are sufficient. Quit cleanly, replace the bundle, relaunch and validate login status/data compatibility. Rollback must check schema compatibility; never open a newer incompatible database with an older build or silently reset it.
- Keep diagnostics metadata-only. Uninstall instructions must cover login-item removal, app bundle removal and an explicit choice about deleting local snippets/history.
- A personal local build does not need a hosted release system. If public distribution is later requested, consider Developer ID signing and notarization as a separate release workflow. Apple's [distribution guidance](https://developer.apple.com/macos/distribution/) and [notarization documentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) describe that process. It can involve Apple credentials/services; no paid account or upload is assumed for this personal-project phase.

## 12. Decisions recorded and remaining validation

**Recorded defaults:** text and raster images in v1; opt-in automatic screenshot-folder import; native Swift; local SQLite; rolling 96-hour history; independent snippets retained until deletion; requested `⌘D` configurable; menu-bar UI; launch at login; single-click/Command-C copies and dismisses; narrow single-column panel with tooltip-only source/time; no Dock icon in any mode; no runtime network or subscription.

**Implemented candidate:** native menu-bar UI, configurable Carbon global shortcut, local text/image capture, screenshot folder import with persistent ledger and recovery scans, independent snippets, SQLite retention and bounded content storage, launch-at-login integration, privacy controls, local packaging and native generated icon. Initial standalone core checks and 21 service checks passed; see QA_REPORT.md for the expanded current suite and release results. The redesigned 440 × 696 panel has been visually inspected. See QA_REPORT.md for exact coverage and limitations. Cross-source screenshot deduplication pairs equal decoded sRGB images once within three seconds; identical independent arrivals across sources can also be paired in this brief window.

**Release acceptance still required:** final rebuilt artifact/signature/package verification; actual UI focus and shortcut use; real applications and permissions; login registration after installation and sign-in; complete GUI workflows under network restriction; measured image memory/idle CPU/panel responsiveness and real-workload storage behavior (synthetic core measurements are recorded in QA_REPORT.md); protected-folder recovery; update and rollback compatibility; oldest-supported-macOS runtime. Standalone fixtures do not establish all these outcomes. No backend is required, and this candidate must not be described as fully accepted before the relevant gates are observed.

Latest interaction refinement: all text cards are one line with tail truncation. Hover shows the text preview capped at 600 characters or 12 lines, followed by source/copy-time metadata. Copied content remains complete and unchanged; image cards retain thumbnails.

Delivery: ClipDiary 1.0.0 installed at `/Users/yashmodi/Applications/ClipDiary.app`, signed ZIP in `dist/`, final core and 21 service checks passed. User accepted the remaining manual Mac checks documented in MANUAL_CHECKS.md. Installation startup registration reports enabled; real restart/hardware shortcut/paste-target checks remain manual.

## 1.0.3 explicit recopy behavior

Both click and Command-C preserve the original source when copying an item from ClipDiary. Ordinary history is promoted in place with a new capture time and 96-hour expiry; content and asset references do not change. A snippet produces an independent history item without changing the saved snippet. Automatic self-recapture remains suppressed, while explicit user copies refresh recency even when automatic capture is paused.

## Maintenance review scope

User requested a full code review and autonomous bug fixes, while preserving design and UX. The user chose bug fixes only when offered local snippet export/import. Export/import, folders/tags and screenshot OCR remain unapproved and unimplemented. The current release changes correctness, privacy boundaries and native keyboard routing, not the panel layout or feature set.


## 6 November 2026 maintenance pass

The user approved internal/UX improvements while preserving the existing visual UI and local-only product. ClipDiary 1.0.6 includes bounded list loading, Unicode literal search, storage-budget/relocation fixes, screenshot retry/directory-identity protection, and parameter-form recovery/cleanup. Product, engineering, design and testing reviewed their areas; root packaged and installed the verified release. No OCR, direct paste, export/import or new visual controls were added. MAINTENANCE_REVIEW.md contains the role report; QA_REPORT.md and PERFORMANCE_REVIEW.md record observed tests and the remaining extreme-search/manual-OS limits.
