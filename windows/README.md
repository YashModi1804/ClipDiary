# ClipDiary for Windows

A native, local-only Windows replica of ClipDiary, written in C#/.NET 10 with WPF and SQLite. Windows version **0.1.0 is a beta until native Windows acceptance is recorded**. Cross-compilation and portable tests on macOS are useful evidence, but do not certify Windows clipboard, tray, focus, login or installer behavior. See [validation status](../docs/WINDOWS_VALIDATION.md).

## Install and use

Use the `win-x64` download for Intel/AMD PCs, or `win-arm64` for Windows on ARM. Windows 11 is recommended; older systems need an OS edition supported by .NET 10.

Run `ClipDiary-0.1.0-<architecture>-Setup.exe`. Installation is per user, with no administrator account required. Setup creates a Start menu entry; updates keep history and snippets. The unsigned beta installer may show an unknown-publisher warning. A portable ZIP is also built: extract it to a permanent folder and open `ClipDiary.exe`. The .NET runtime is included, so ordinary users do not need to install an SDK or database.

The app lives in the tray and stays out of the taskbar. Copy text or an image, then press **Ctrl+Alt+D**. Change the shortcut in Settings if another app uses it. Click a row, or select it and press Ctrl+C, to copy and return to the previous app. Newest history is at the bottom. The operating system may restrict restoring focus in elevated/secure windows.

- Text stays on one line. A single hover preview shows bounded text, source and copy time.
- Search and the content filter work across history or permanent snippets.
- Save a row as a snippet, or create/edit a text snippet. The editor supports normal copy/paste/undo/redo.
- Enable parameters after saving a snippet. `<instance>` and other `<parameter_name>` placeholders prompt once per unique name; blank values preserve placeholders. Copying stores the rendered result as ordinary history and leaves the template unchanged. Failed parameter copies keep entered values.
- History expires after a rolling 96 hours. Snippets remain until deletion. Copying history renews its time and keeps its source; copying a snippet makes an independent history entry.
- Start-at-login is enabled by default and can be disabled in Settings. Windows Startup Apps can independently block startup. Tray Quit stops capture.

Screenshots enter history when Snipping Tool copies image pixels to the clipboard or saves to a watched local screenshot directory. Automatic mode discovers Windows screenshot locations; a dedicated folder can also be selected. Disable screenshot capture separately when needed. Originals are never deleted or modified. Shots that Windows neither copies nor saves cannot be captured this way. Windows/cloud-provider save delays remain separate from ClipDiary's import delay.

Storage is under `%LOCALAPPDATA%\ClipDiary`: SQLite, private original images, thumbnails, settings and a durable screenshot ledger. It is independent of the Mac database; cross-platform history import/sync is not implemented. Limits are 10,000 combined items and 512 MiB including metadata, 1 MiB UTF-8 text per item/metadata field, 25 MiB encoded images and 50 million decoded pixels. Explicit copies work while automatic capture is paused.

Local files are protected for the current account but not encrypted by ClipDiary. Pause and application exclusions support privacy; sensitive clipboard markers are best effort. Local hydrated screenshot files can be read; network shares and files needing cloud recall are rejected. See [security](../SECURITY.md).

## Build

Install the [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0) and Python 3.9+. To build installers, install [NSIS 3](https://nsis.sourceforge.io/Download). Source dependencies restore from NuGet; there is no runtime server.

```powershell
dotnet run --project windows/ClipDiary.CoreChecks -c Release
dotnet run --project windows/ClipDiary.PlatformChecks -c Release
dotnet build windows/ClipDiary.sln -c Release
python windows/scripts/package.py --runtime win-x64 --installer
python windows/scripts/package.py --runtime win-arm64 --installer
```

`windows/scripts/build.ps1 -Runtime win-x64 -Installer` is a PowerShell entry point for the same helper. Output is `artifacts/windows/`, including setup executables, portable ZIPs and SHA256 checksum files. Set `DOTNET_COMMAND` or `NSIS_COMPILER` when the tools are not on PATH. A Mac/Linux host can cross-build using the project's Windows targeting setting, but cannot run WPF/Win32 integration checks.

On a disposable interactive Windows desktop, close the normal app, then run:

```powershell
$exe = Resolve-Path windows/ClipDiary.Windows/bin/Release/net10.0-windows/ClipDiary.exe
$p = Start-Process $exe -ArgumentList '--windows-checks --report artifacts/windows-checks.log' -Wait -PassThru
if ($p.ExitCode -ne 0) { throw 'Native checks failed; inspect artifacts/windows-checks.log' }
```

These explicit native checks replace the test session's clipboard with synthetic data, do not read prior clipboard contents, and use temporary stores/folders. They do not register startup or touch real history. The [platform test boundary](ClipDiary.Windows/Platform/TESTABILITY.md) lists remaining physical checks.

## Remove or recover

Uninstall through Windows Settings. App removal keeps `%LOCALAPPDATA%\ClipDiary`; remove that folder yourself only when you intend to permanently delete history and snippets. Preserve important snippets elsewhere.

If the screenshot ledger is corrupt, file ingestion stops and preserves the file while ordinary clipboard capture continues. Quit the app and recover the ledger from a known copy, or deliberately move it aside before restarting. Resetting a ledger may import eligible screenshots again; it must be an explicit recovery action. Settings/database errors do not silently reset your saved data.

## Platform notes

Ctrl/Ctrl+Alt replace Mac Command shortcuts. Tray/Run-key registration replace the macOS menu bar/login service. Unicode search uses normalized literal .NET matching; unusual multi-character case folds can differ from macOS ICU. Screenshot permissions and clipboard behavior follow Windows. The code contains no account, telemetry, cloud synchronization, auto-paste injection or runtime network client.
