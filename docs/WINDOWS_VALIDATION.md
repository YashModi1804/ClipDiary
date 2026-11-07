# Windows validation

Date: 7 November 2026. Native Windows version 0.1.0 is a beta pending actual Windows execution.

Observed so far:

- Portable Windows core checks run on this Mac with .NET 10.0.403 and pinned Microsoft.Data.Sqlite 10.0.14: 79 assertions including stress passed.
- Portable capture-policy checks run on this Mac: 92 assertions passed, including local-cloud availability and dotted process-name cases.
- WPF UI cross-compilation and a complete Windows Release cross-build passed with no warnings or errors. The final integrated solution build passed with zero warnings/errors after target-lock and cancellation changes.
- Existing Mac root build commands still work after relocation: standalone core, 86 service checks, 35 model assertions, keyboard checks and six hover layouts passed. The Mac app source moved without functional changes.

Not executed on this Mac: Win32 clipboard notifications, Windows image codecs, native hotkeys, tray interaction, session lock/sleep, login registration, focus restoration, installer install/update/uninstall, or Windows UI pointer/keyboard acceptance. Cross-compiling an EXE does not count as running these tests. `ClipDiary.exe --windows-checks` and the GitHub Windows workflow provide an explicit execution path; a Windows result is required before promoting the beta to a validated release.

Stress samples are synthetic individual measurements, not p95 end-user latency. The 256×32-KiB core fixture retained about 8.39 MB for full text versus 1.05 MB for bounded previews; final core samples were about313ms inserts,4.7ms full read,7.4ms preview read and7.0ms search in the final root rerun. Larger combined Unicode/NUL text, UTF8 limits and cancellation were separately checked. Native UI responsiveness still requires Windows acceptance.

No real clipboard or history data was inspected. Dependency versions/hashes are locked; release artifacts include source/dependency licenses and checksums. Signing credentials and generated bundles are excluded from Git.

## Final results

The complete Windows solution cross-build passed with zero warnings/errors. After the minimized-window fix, both final self-contained publications compiled successfully and NSIS 3.13 generated per-user setup executables on this Mac. The x64 application PE machine is0x8664; the ARM64 application is0xAA64. Both ZIP CRC checks passed; independent SHA256 checks matched each ZIP and setup executable. Artifacts contain the MIT license, dependency/runtime notices, offline guides and BUILD_INFO.json linking the executable source to commit4c984a4 and SDK10.0.403.

| Artifact | Bytes |
| --- | ---: |
| ClipDiary-0.1.0-win-x64-Setup.exe | 51,046,296 |
| ClipDiary-0.1.0-win-x64.zip | 70,338,491 |
| ClipDiary-0.1.0-win-arm64-Setup.exe | 44,521,214 |
| ClipDiary-0.1.0-win-arm64.zip | 65,283,173 |

The current NuGet advisory query reported no vulnerable packages for the application/portable projects, including transitive dependencies. This is not a proof of absence of every native/library vulnerability. Standard credential/private-key patterns were not found in tracked source. No runtime HTTP/network client was found in the Mac/Windows application sources. Generated builds, audit output and real user data stay excluded from Git.

A real Windows-only UI smoke fixture now constructs the MainWindow using synthetic in-memory actions, checks440×696/taskbar-free presentation, minimize/reopen restoration and hiding, then closes the window in finally. It does not start a controller, access a database, clipboard, startup or tray. These four new state checks compiled but have not executed on this Mac.

The GitHub workflow is prepared for portable checks on Linux/macOS/Windows, Mac native checks plus XCTest under full Xcode, and synthetic native Windows checks followed by packaging. Workflow YAML parsed successfully; the repository is now connected to GitHub; check the [Actions runs](https://github.com/YashModi1804/ClipDiary/actions) for actual remote results. The local results recorded here do not claim a Windows CI pass. Local Command Line Tools lack XCTest, so the separate XCTest sources remain unexecuted here. Existing Mac standalone/native checks passed86 service/35 model assertions plus keyboard/six hover layouts. A public Mac ZIP was also rebuilt with license resources; it does not replace the user's installed app.

Windows-native acceptance remains pending. All Windows downloads must remain labeled beta until the real Windows checks and manual install/update/quit/login/clipboard/pointer scenarios are observed. No signing certificate or public GitHub release has been created. Source publication is separate from publishing signed release binaries.
