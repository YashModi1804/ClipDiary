# Contributing

ClipDiary is an MIT-licensed, local-first clipboard manager. Keep the Mac and Windows apps in this repository and preserve their documented behavior.

## Development

- Mac: install Apple Command Line Tools, then run `./scripts/test.sh`.
- Windows core: install the exact .NET SDK specified in `global.json`, then run `dotnet run --project windows/ClipDiary.CoreChecks -c Release`. This also works on macOS.
- Windows app: build on Windows with `dotnet build windows/ClipDiary.Windows -c Release`. Cross-compilation uses `EnableWindowsTargeting`; it cannot establish native runtime behavior on a Mac.

Use a focused branch and small commits. Write short messages explaining the change, for example “Fix screenshot retries.” Test real behavior with synthetic data. Do not commit generated builds, local settings, clipboard history, screenshot originals, credentials or signing certificates.

Keep capture asynchronous and bounded. Cancellation must stop queued writes after pause, clear-history, lock or shutdown. Preserve literal template substitution, original snippets, provenance, four-day expiry, and the latest-at-bottom workflow. Never introduce a runtime server, telemetry, automatic cloud sync or network dependency without a separate product decision.

For a pull request, describe the user-visible change, the tests you actually ran and any platform checks still pending. Never claim a Windows integration check passed merely because the project compiled elsewhere.

## Security and release inputs

Report sensitive defects through [private vulnerability reporting](https://github.com/YashModi1804/ClipDiary/security/advisories/new), rather than a public issue. Use synthetic fixtures for regression coverage.

Dependency and SDK updates must refresh the normal and single-file publish lockfiles, plus the versions and verified archive hashes in `windows/publish-runtime-lock.json`. Review upstream licenses and advisories before updating these inputs. Run the packager from a clean committed checkout; `--allow-dirty` marks a development build and must not be used for release artifacts. Keep action references pinned to full commit IDs and review automated updates before merging.
