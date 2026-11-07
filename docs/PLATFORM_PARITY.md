# Platform parity

ClipDiary is one open-source repository with independent native platform implementations. The Mac app stays Swift/SwiftUI/AppKit; Windows uses .NET 10 WPF, Win32 and Microsoft.Data.Sqlite. Shared behavior is the product contract, not a shared binary or database file format.

| User behavior | macOS | Windows implementation |
| --- | --- | --- |
| Background access | Menu bar, no Dock | Tray, no taskbar window |
| Invoke shortcut | Configurable, default Command-D | Configurable RegisterHotKey, default Ctrl+Alt+D; conflicts keep access through tray |
| Start after sign-in | ServiceManagement login registration | Current-user Run entry and duplicate-instance protection |
| Capture text/images | Pasteboard polling | Clipboard format notifications, bounded asynchronous image preparation |
| Screenshots without preview clicks | Saved OS screenshot files and clipboard images | Snipping Tool clipboard images, auto-detected local Screenshots folders, explicit folder override |
| Sensitive data | Source markers, exclusions, pause/session guards | Windows history-exclusion formats, source-process exclusions, pause/session guards |
| History retention | Rolling96h; originals untouched | Rolling96h; originals untouched |
| Copy again | Promote history in place, preserve source; independent snippet copy | Same behavior, timestamp renewed, source/template/assets preserved |
| Snippets | Permanent text/images, independent assets | Same; native editor and persistent opt-in parameter flag |
| Parameters | Multiple names, repeated names share values; blank retains placeholders | Same single-pass behavior; virtualized input rows keep values offscreen |
| UI | Narrow single column, one-line text, one hover preview | 440×696 logical-pixel panel, one-line rows, virtualized list, one popup and bounded cached thumbnails |
| Copy action | Click/Command-C, close/restore app | Click/Ctrl-C, close/best-effort Windows focus restoration |
| Storage | Embedded SQLite, private assets and thumbnails | Embedded SQLite, user ACLs, private assets and thumbnails |
| Caps | 10k rows/512MiB,1MiB text,25MiB images,50MP | Same policy, with metadata-aware capacity |
| Cancellation/recovery | Pause/clear/session/folder generations | Linked cancellation, serialized store, safe path identities, retries and durable ledger |
| Distribution | Locally signed Mac ZIP | Self-contained x64/ARM64 ZIPs and per-user NSIS setup executables |

Windows beta status is separate from feature implementation. The Windows app and portable checks compile/run where applicable on this Mac; Win32/WPF operation and installer behavior need real Windows acceptance before a stable Windows release. The repository's Windows CI job is prepared to execute synthetic native tests. It has not run merely because its YAML exists.

Windows Unicode case handling follows .NET literal matching and can differ from Mac ICU for unusual multi-character case folds. Windows Startup Apps, elevated desktops, DLP tools and cloud-file availability can restrict OS integrations. No paid runtime, server, account, telemetry, cloud sync or auto-paste injection is introduced.
