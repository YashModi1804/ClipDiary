# ClipDiary

A personal, local macOS clipboard manager for text, copied images, saved snippets, and automatic screenshot-folder import. It uses Swift, Apple frameworks, and a local SQLite database. No account, paid dependency, server, cloud database, or runtime network service is required.

Requires macOS 14 or newer and Apple Command Line Tools with Swift 5.9 or newer to build. This first build targets the architecture of the Mac doing the build; it is not a universal binary. See [PROJECT_PLAN.md](../docs/macos/PROJECT_PLAN.md) for product requirements and [QA_REPORT.md](../docs/macos/QA_REPORT.md) for observed verification and remaining manual checks.

This release was built and exercised on macOS 26.7.1, Apple Silicon. Other macOS versions have not been runtime-tested. The remaining checks in your usual applications are listed in [MANUAL_CHECKS.md](../docs/macos/MANUAL_CHECKS.md).

Source builds need a recent Apple SDK containing `NSPasteboard.accessBehavior` (macOS 15.4 or later SDK); an older SDK can fail even when its Swift version satisfies the package manifest. See [TECHNICAL_OVERVIEW.md](../docs/macos/TECHNICAL_OVERVIEW.md) for the stack, file map and line counts.

## Build and run

From the repository root (one directory above this guide):

```sh
./scripts/test.sh
./scripts/build.sh
open dist/ClipDiary.app
```

The default test script runs standalone core assertions and app service integration checks using an isolated named pasteboard; it does not overwrite your normal clipboard. Command Line Tools on this Mac lack XCTest. With a full Xcode toolchain providing XCTest, `./scripts/test.sh --xctest` additionally runs the XCTest suite. A missing XCTest module is a development-tool limitation, not an app runtime dependency.

Build/test scripts place compiler and SwiftPM caches in the temporary directory and disable SwiftPM’s nested build sandbox for the restricted local agent environment. They do not bypass macOS clipboard or folder privacy permissions.

The app lives in the menu bar and never shows a Dock icon, including in preview mode. Use its menu to show the history panel. The initial invocation shortcut is Command-D; configure another if it conflicts with an application you use. A global shortcut may take precedence over another app's command even when registration succeeds.

A local release bundle is written to `dist/ClipDiary.app`, with the stable bundle identifier `com.local.ClipDiary` and ad hoc code signing. This supports personal local use; it is not a notarized public release. No Apple Developer membership is required for this build workflow. Verify launch and permissions on the actual Mac.

The included app icon is generated entirely with native AppKit vector drawing. Regenerate it with `./scripts/generate-icon.sh` if the artwork changes; no external assets or image-generation service are used.

To package a ZIP:

```sh
./scripts/package.sh
```

To install in your home Applications folder:

```sh
./scripts/install.sh
open "$HOME/Applications/ClipDiary.app"
```

For another destination, use `./scripts/install.sh --destination "/path/to/Applications"`. To update, quit ClipDiary, rebuild, then run `./scripts/install.sh --replace`. The installer does not automatically launch or register a login item. The app attempts login registration on its first normal launch. Check Start automatically at login in Settings after opening it from the final installation location, and approve the login item in macOS if requested. Login startup begins after your macOS account signs in; no capture is possible while the app is stopped or the Mac is off.

## Daily use

Copy text or an image normally, then press Command-D to open the narrow vertical history panel. Search or use the arrow keys to select an item. Click its card once, or press Command-C with the item selected: it copies and the panel closes so you can paste normally into your destination app. Copying an existing history item moves it to the newest position at the bottom, keeps its original source and content, and renews its 96-hour expiry. Copying a snippet creates an independent history entry while leaving the saved snippet unchanged. Explicit copies refresh history even when automatic capture is paused. There are no Copy buttons or separate detail column. Source and copy time appear in hover tooltips; no live timers or timestamps clutter the list. Capturing rapid intermediate clipboard changes is best effort; this app is not a guaranteed audit log.

Save important items as snippets. Snippets are independent saved copies and remain until you delete them. Ordinary history expires after a rolling 96 hours, rather than four calendar days. Clear History leaves snippets intact. The store budget is 512 MiB of tracked text, images, thumbnails, titles and source metadata, including snippets; SQLite overhead is additional. The existing size display reports content and thumbnail bytes. There is also a combined 10,000-record cap across history and snippets. When a cap is reached, new saves report an error rather than deleting snippets. Delete unwanted items to free space. Individual limits are 1 MiB of UTF-8 text, 1 MiB per title/source field and 25 MiB per encoded image; image capture also enforces decoded-size limits.

Image search uses titles or metadata; optical character recognition is outside this initial release. Copying an image's URL or a Finder file reference is different from copying image pixels.

## Automatic screenshots

ClipDiary automatically watches your macOS screenshot destination (Desktop by default), importing only files marked by macOS as screenshots. Recent screenshots from the last 96 hours are recovered on startup. Allow folder access if macOS asks. No screenshot setting needs to change.

For an explicit folder override, use Choose Screenshot Folder in Settings. An explicitly selected folder imports supported images, so choose a dedicated folder. Disconnect stops folder capture.

Import starts once macOS saves a readable image. The floating screenshot thumbnail can delay saving; turning off Show Floating Thumbnail in Command-Shift-5 → Options reduces that delay. Matching clipboard and folder images arriving within three seconds are paired once.

Folder import adds a private history copy without replacing the current system clipboard. Click the image card once, or select it with the keyboard and press Command-C, when you want to paste that image. Native Control-Command-Shift-3/4 clipboard screenshot shortcuts are also compatible with normal clipboard-image capture.

**History expiry removes only ClipDiary's stored copies. Screenshot originals in your selected folder remain untouched.** Saving a screenshot as a snippet preserves its independent app copy even after history expiry.

## Privacy and permissions

Clipboard contents are sensitive. Use Pause and app exclusions when needed. Supported source-provided sensitive/transient clipboard markers should be skipped, but this is not universal password detection. Clipboard text, images, snippet contents, and search queries must not appear in diagnostic logs.

macOS may request access when reading clipboard content or a protected screenshot folder. Grant access only when you want the corresponding capture feature. Reading saved screenshots does not require recording your screen; this release uses macOS's screenshot tool rather than providing its own screen-capture overlay. Ordinary copy-and-paste use does not require simulated keyboard input.

The app marks its entire data directory, including permanent snippets, as excluded from normal system backups. There is no snippet export feature yet, so do not rely on these snippets as your only copy of irreplaceable information. Verify backup exclusion on your Mac; existing backups are outside the app’s control.

Local storage does not mean encrypted application storage: macOS account access and disk protection remain relevant. Expiry cannot erase content from existing APFS snapshots, Time Machine, exported files, the source screenshot folder, other clipboard managers, or the current system clipboard. We do not promise forensic SSD erasure.

## Updating, rollback, and removal

Keep the previous app artifact before updating if you need a binary rollback. Database changes can prevent older versions from reading newer data; do not assume that replacing the executable reverses a migration. Avoid making plaintext clipboard-history backup copies as a routine update step.

To remove the app, disable Start at login, quit it, and remove the installed `ClipDiary.app`. App removal alone does not erase its Application Support data. The normal data directory is `~/Library/Application Support/ClipDiary` (the `CLIPDIARY_DATA_DIR` development override can change it). Deleting that directory removes stored history and snippets irreversibly. App settings and the screenshot-folder bookmark are separate macOS preferences for `com.local.ClipDiary`. No remote account or server needs removal.

## Release status

ClipDiary is built and signed locally. The latest bug-review results, check counts and release verification are recorded in [QA_REPORT.md](../docs/macos/QA_REPORT.md). The user will perform the remaining Mac-specific checks in [MANUAL_CHECKS.md](../docs/macos/MANUAL_CHECKS.md). Observed results and limits are recorded in [QA_REPORT.md](../docs/macos/QA_REPORT.md).

Text entries stay on one line. Hover to preview up to 600 characters or 12 lines plus source and copy time; copying always uses the complete saved text.

## Parameterized snippets

Save a text snippet first, then right-click it → Make Parameterized, or enable Parameterized in Edit Snippet. Use `<parameter_name>` placeholders, for example `connect <instance>`. Names may contain letters, numbers, underscores and hyphens. Repeated names share one input. Ordinary snippets remain literal until explicitly enabled.

Click or Command-C a parameterized snippet to enter values. Copy substitutes filled values; empty values preserve their original placeholders. Cancel changes neither the clipboard nor history. History stores the exact copied result with the original source; the saved template stays unchanged. Parameter values are not saved as template defaults. The expanded text is limited to 1 MiB.

The snippet editor supports standard Copy, Cut, Paste, Select All, Undo and Redo shortcuts. Returning to History resets selection and scroll position to the latest item at the bottom. A failed parameter copy keeps entered values available for correction or retry. Cancel and the window close button return to history; completing or cancelling a form releases its temporary values.

Version 1.0.4 migrates the local database from schema 1 to schema 2 to persist the parameter setting. Existing snippets default to ordinary literal mode. Older app versions cannot open the upgraded database; they reject it rather than overwrite it.
