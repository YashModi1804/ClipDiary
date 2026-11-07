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

Pending final integrated build and packaging.
