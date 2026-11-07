# Windows platform test boundary

This implementation is a native Windows desktop layer. A macOS cross-build checks C# and Windows reference contracts; it does not execute Win32 clipboard, WPF codecs, tray, registry, session notifications or global hotkeys.

`CapturePolicy.cs` deliberately has no Windows desktop references. The portable PlatformChecks project can link it and run dimensions/overflow, UTF-8 text limits, PNG completeness, supported image extensions, retention boundaries, process normalization and retry limits on macOS/Linux/Windows.

`ClipDiary.exe --windows-checks` must run on an interactive Windows desktop. It refuses to run while the ordinary ClipDiary instance is running. It overwrites only the test session's OS clipboard with generated fixtures, never reads previous clipboard contents, and uses disposable stores/folders. It exercises listener startup baselining, Unicode, own writes, Windows privacy formats, exclusion/pause/independent suspension, codec validation, file ingestion, persistent ledger, replaced folders, corrupt-ledger isolation, native hotkey rollback and cancellation/queue bounds. It does not modify startup registration or user network settings. CI results must be obtained on Windows before describing these checks as passed.

## Required Windows acceptance checks

- Windows 10/11 installation, standard user, portable path and paths with spaces/non-ASCII characters.
- Login startup enabled/disabled, moved executable rebind and no duplicate normal instance. Startup uses the current user's Run key and a quoted executable path.
- Tray open/settings/pause/quit, restart, Explorer restart, multiple monitors and mixed DPI.
- Ctrl+Alt+D and a changed shortcut, conflict preserving the previous shortcut, full-screen apps and best-effort foreground restoration after explicit Copy. No paste or synthetic keyboard injection occurs.
- Copy from Notepad, browser and Office: text, Unicode, multiline, PNG, DIB/bitmap, transparency, large images and clipboard contention. Confirm original source process remains unchanged when controller promotes copied history.
- Session lock/unlock, sleep/resume while still locked, disconnect/reconnect; pending captures cannot commit after pause/clear/reconfiguration.
- Snipping Tool copy-only, auto-save enabled/disabled, Win+PrintScreen, existing and first-created Screenshots folder, user-chosen folder and OneDrive redirection. Test cloud-placeholder rejection without hydration/download, directory junctions/symlinks, source file replacement, incomplete writes and storage-full recovery.
- A corrupted screenshot ledger blocks only file ingestion, leaves the ledger untouched and keeps ordinary clipboard/history/settings usable. Preserve/recover the ledger before resetting it; changing folders does not silently erase consumed identities.
- Retention deletes app-owned history/assets only. Screenshot originals stay untouched; snippets remain independent. Reopening cannot reimport consumed screenshots after history expiry or deletion.

## Limits and safety

All persistence is local; no telemetry, account, network share, cloud synchronization or server is used. OneDrive paths are discovered as Windows local screenshot destinations only; symbolic links/junctions, online-only or partially hydrated cloud files, and network drives are rejected rather than fetched. Fully local Cloud Files entries are accepted after checking their native placeholder state and opening with no-recall semantics. Auto mode watches dedicated OS screenshot directories; explicit mode watches supported image files in the selected directory. It cannot acquire shots Snipping Tool never places on the clipboard or saves to a monitored local folder. Windows may delay saving, refuse clipboard access or restrict focus/shortcuts on secure/elevated desktops. Rapid intermediate clipboard changes are not guaranteed by Windows notification APIs. Marker/exclusion handling is best effort; unmarked secrets cannot be reliably recognized by content.

The encoded image limit is25 MiB, decoded dimensions50 MP, text1 MiB UTF-8, thumbnail320 px. A serial image worker accepts at most3 jobs across both sources; text delivery accepts16 outstanding items. Expensive retries back off to30 seconds, while a changed file signature becomes eligible again. Screenshot reads validate volume/file identity and stable metadata; unknown/link reparse points and cloud entries requiring recall are rejected. Persisted directory identities prevent a replaced path from silently redirecting capture. The consumed ledger is capped at100000 identities; it is not evicted in a way that resurrects deleted history.

Large stored JPEG/TIFF images can be copied through the lossless bitmap clipboard format even if re-encoding them as PNG would exceed25 MiB; PNG is an optional companion format for explicit Copy. Preparation/encoding runs on a worker; only the final clipboard ownership change is STA.

Native API references: [Microsoft clipboard privacy formats](https://learn.microsoft.com/en-us/windows/win32/dataxchg/clipboard-formats#cloud-clipboard-and-clipboard-history-formats) and [FOLDERID_Screenshots](https://learn.microsoft.com/en-us/windows/win32/shell/knownfolderid).
