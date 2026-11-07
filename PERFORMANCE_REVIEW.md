# ClipDiary 1.0.2 performance review

Date: 2026-10-18

The four requested agents reviewed the reported preview stacking, hover lag and screenshot delay. Root integrated the fixes. This record distinguishes fixture measurements from manual Mac acceptance.

| Role | Finding and resulting work |
| --- | --- |
| Product manager | Defined one preview for the current visible row, dismissal during scrolling/menus and no clipboard or selection side effects. Screenshot latency is measured after the file finishes saving, separately from macOS floating-preview delay. |
| Designer | Identified independent per-row popovers and repeated hosting-view construction. Reviewed a single shared native popover, pointer/visible-rectangle checks, topmost-window gating, menu suppression, same-ID content invalidation, and cancellation when filters/search/panel state change. Suggested actual native layout checks. |
| Software engineer | Added an ordering index, expiry-aware single-record lookup, and asset-only cleanup queries. Root uses direct lookup for copying, caches thumbnails across rows/previews, avoids unchanged status publications, and coalesces capture refreshes. |
| Tester | Measured completed-file-to-history delay, moved screenshot metadata scanning and bounded file reads/validation/hashing off the UI thread, coalesced scan requests, reduced safe settling waits, and removed duplicate refresh callbacks. Added partial-write/recovery checks while preserving generation cancellation, retention, deduplication, and source files. |

## Hover behavior

There is exactly one shared popover. It closes during scrolling and appears for the current row about 80 ms after scrolling settles, avoiding repeated layout during momentum. Normal pointer entry has no intentional dwell or animation. Search/filter/selection changes and panel dismissal suppress pending previews until actual pointer movement. Context menus suppress previews. Hidden/offscreen rows and covered windows cannot supply a preview.

The shared preview uses native labels and image views instead of constructing a new SwiftUI hosting controller for each hover. The thumbnail cache is bounded to 64 images and approximately 24 MiB of decoded-image cost.

## Verification

Core checks pass, including exact expiry-boundary lookup, missing IDs, independent snippets, image persistence, limits and secure deletion checks. A synthetic 10,000-item fixture measured a single-item lookup average of 0.010 ms over 100 reads. This is database time, not total click-to-copy latency.

Six actual AppKit layout cases passed: short/wrapped/unbroken/multiline text plus portrait and landscape images. Views were attached to a hidden temporary window and checked for bounded size, positive child heights and unambiguous layout. Maximum construction/layout time was 13.51 ms in the initial debug run; this is not a measured pointer-to-screen p95.

The pre-optimization screenshot service fixture measured 0.266 seconds after completed file write. The updated release passed all 30 service checks: small screenshot 0.190 seconds and 12-megapixel screenshot 0.272 seconds after completed save. These are individual fixture timings, not statistical percentiles. QA_REPORT.md records the final checks.

## Manual acceptance

Rapidly cross rows and scroll with a stationary pointer. Check that no previews accumulate and that only the current row appears after scrolling settles. Check search/filter changes, context menus, light/dark appearance and actual screenshot saving in the user's apps. These physical-pointer and OS screenshot workflows remain user checks.

macOS can keep a screenshot in its floating thumbnail before writing the image file. ClipDiary imports once a valid file is saved. Disabling Show Floating Thumbnail in macOS Screenshot Options can reduce that separate delay; the app does not change that setting.


## ClipDiary 1.0.6 maintenance measurements — 6 November 2026

The list now requests at most 4,096 Unicode scalars per text/title/source field. Copy, editing and parameter discovery still fetch the complete original record. Search examines complete stored content, and only search views are normalized. Hidden panels release their rows, background maintenance avoids collection materialization, and unchanged visible rows are not republished. Startup reconciliation reads asset metadata instead of every text payload.

Engineering used a real 500 MiB SQLite text fixture: 500 records close to the 1 MiB per-item limit. Each operation below was timed individually; these are development fixture samples, not p95 GUI latency or an idle-memory measurement. The final search algorithm was tested; the final per-row autorelease-pool refinement separately passed core regression checks.

| Operation | Observed result |
| --- | ---: |
| Open/reconcile large store | 69.5 ms |
| Full-record collection query | 166.9 ms, retaining 500 MiB of text |
| Bounded list query | 135.8 ms, retaining 1.95 MiB of text |
| ASCII prefix match across full fixture | 284 ms |
| ASCII no-match / end-of-payload match | 463 / 490 ms |
| Unicode needle absent from ASCII text | 281 ms |
| Unicode no-match in a separate 500 MiB emoji-heavy fixture | 3.60 seconds |

The initial Foundation case-insensitive implementation took 74.6 seconds for the absent Unicode needle against ASCII text. This implementation was rejected during review. The shipped algorithm caches an escaped literal matcher, normalizes search-only strings to NFC, and uses a safe ASCII path. Substring semantics are retained, including partial emoji/combining sequences; a whole-grapheme restriction was not part of the original product.

The 3.60-second emoji-heavy full scan is a remaining limit: searches still run synchronously and lack a dedicated substring index. The patch must not be described as making every near-capacity search instantaneous. A separate architecture change would be needed to guarantee responsiveness for that extreme workload while preserving SQLite deletion/privacy behavior.

Parser stress covered near-1-MiB repeated placeholders and 128,854 distinct placeholder names: name discovery took roughly 42–82 ms, oversize expansion rejection 55 ms, and rendering about 59 ms. This checks parser behavior, not construction or use of a form with that many fields.

The tester's native suite captured twelve 12-megapixel screenshots in 1.575 seconds, with a peak of three queued preparations; small and individual 12-megapixel imports took 0.196 and 0.277 seconds after completed save. The final packaged run is recorded in QA_REPORT.md. These are synthetic fixture timings, not macOS floating-preview delay.

The timed native suite reported maximum resident set size 746,061,824 bytes and peak memory footprint 120,538,024 bytes. These macOS counters cover the complete test process, synthetic image construction and frameworks, and are not an isolated app-idle or per-image allocation measurement. No claim of an idle CPU or total app-RAM target is made from them.
