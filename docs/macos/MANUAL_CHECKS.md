# ClipDiary 1.0.6 — your Mac checks

Automated storage, capture, model, keyboard and native layout results are recorded in QA_REPORT.md. These checks cover the remaining interactions in your own apps.

1. **Open and copy:** press `⌘D` from another app. The panel should be narrow and tall, with no Dock icon. Click a text row: the panel should close. Paste with `⌘V` in your destination app.
2. **Keyboard and hover:** open again, select with ↑/↓ and press `⌘C`. It should copy and close. Text rows stay on one line; hover shows up to 600 characters or 12 lines, plus source and copy time. Copying uses the complete text, regardless of preview truncation.
3. **Images:** copy actual image content from a browser or Preview, find its thumbnail, click it, and paste into an app that accepts images. A copied image-file path or URL is different from copied image pixels.
4. **Automatic screenshots:** take a normal screenshot with `⌘⇧3` or `⌘⇧4`. ClipDiary automatically watches the macOS screenshot destination (Desktop by default). Allow folder access if prompted. It should appear after macOS saves it, without clicking the preview. Turn off Show Floating Thumbnail in `⌘⇧5` → Options for faster saving. Originals remain untouched. Newest history should appear at the bottom; scroll up for older items. Hover previews should appear immediately.
5. **Snippets:** right-click a history row → Save as Snippet. Open Snippets; right-click to edit. Snippets remain until you delete them. Four-day history expiry and independence are already covered by automated tests.
6. **Daily background operation:** check Start automatically at login in Settings. When convenient, sign out and back in or restart. The menu-bar icon should return without a main window or Dock icon, and new copies should be captured. Check your preferred custom shortcut, pause/resume, exclusions, and any macOS permission prompts.

If something fails, report the action, expected result, observed result, and the app you were using. You do not need to share private clipboard contents.

Hover regression: rapidly cross several rows, scroll with the pointer stationary, and stop over a row. Only one preview should ever be visible. During momentum scrolling the preview stays hidden; it returns for the row under the pointer about 80 ms after scrolling settles. Search/filter changes, menus, and panel dismissal should remove stale previews. Check long text and portrait/landscape images.

Recopy: select an older text item, click it, paste elsewhere, and reopen History. It should be the latest bottom row with the original source and a new copy time, without a duplicate old row. Repeat using Command-C and an image. Copy a snippet and confirm it appears in History while the saved snippet remains unchanged. Repeat while automatic capture is paused.

Parameterized snippets: create `connect <instance> / <region> / <instance>`, save, then enable Make Parameterized. Click or Command-C; supply instance, leave region blank, and Copy. Paste should contain the instance twice and literal `<region>`. History must contain that result; the snippet must keep its template. Repeat Cancel and verify clipboard/history unchanged. Disable Parameters to copy literally again. In Edit Snippet, verify Command-A/C/V/X/Z and Shift-Command-Z. Switch Snippets → close/reopen → History and verify latest at bottom.

Maintenance keyboard checks: select text in the search field and press Command-C; it should copy that selected text without closing the panel. With no search-text selection, Command-C still copies the selected history row. Shift-Up/Down and input-method candidate navigation should stay in the text editor. In shortcut recording, entering Command-Q should be recorded rather than quitting the app.

Maintenance workflow checks: enter parameter values, then trigger the expanded-text size limit with a very large repeated value. After dismissing the error sheet, all entered values should remain available. Correct the value and copy; the form should close and the complete result should paste correctly. Separately try Cancel, Escape and the titlebar close button in both editor and parameter forms: each should return to History once, without copying. Search for text near the end of a long snippet and edit it; the entire original must remain present despite bounded list previews.

After repeated panel open/close and collection switches, the newest history item must still be at the bottom. The panel dimensions, controls, row styling and hover layout should match the previous release.
