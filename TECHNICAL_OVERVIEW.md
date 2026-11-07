# ClipDiary 1.0.6 — stack and codebase

Native macOS app using Swift, SwiftUI and AppKit, built with Swift Package Manager. There are no third-party package dependencies or runtime servers.

| Component | Implementation |
| --- | --- |
| Clipboard | NSPasteboard change polling, sensitive markers, pause/exclusions and own-write suppression |
| Images/screenshots | Filesystem events, background metadata/image preparation, bounded descriptor reads, directory/file identity checks, deferred failure retries and durable import ledger |
| Storage | Embedded SQLite plus private image assets, bounded list projections, Unicode literal search, rolling 96-hour history and independent permanent snippets |
| Parameters | Explicit per-snippet opt-in; literal substitution into copied history, preserving templates |
| UI | SwiftUI in AppKit floating panel, one shared native hover preview, native snippet text editor |
| Keyboard/startup | Carbon global shortcut registration; responder-aware panel keys; ServiceManagement login registration |
| Delivery | Local build/package/install scripts and ad hoc signing; no hosted updater |

Physical source lines including comments and blank lines, excluding generated artifacts and prose:

| Area | Lines |
| --- | ---: |
| ClipDiary app target (including native integration checks) | 2,822 |
| ClipDiaryCore storage and parameter logic | 577 |
| Standalone core verification executable | 641 |
| XCTest source | 166 |
| Package manifest and build/install/icon tooling | 183 |
| **Total** | **4,389** |

The app target includes opt-in verification helpers; its count is not a production-only LOC estimate. Current test evidence and remaining manual OS checks are in QA_REPORT.md and MANUAL_CHECKS.md. The maintenance release improves storage/capture safety and existing form workflows while preserving the visual layout and features. SQLite schema remains 2. The app loads list previews only while the panel is shown; copy/edit always resolve complete records. PERFORMANCE_REVIEW.md includes near-capacity measurements and the remaining synchronous-search limit.
