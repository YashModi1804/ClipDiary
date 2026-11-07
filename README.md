# ClipDiary

A local clipboard diary for macOS and Windows. Text, copied images, screenshot history and permanent parameterized snippets stay on your own computer. No account or runtime server is required.

## Platforms

- **macOS:** the existing native Swift/SwiftUI/AppKit app, version 1.0.6. [Build and use it](macos/README.md).
- **Windows:** native C#/.NET 10 WPF implementation under development alongside the Mac app. Platform validation is tracked in [the Windows guide](windows/README.md).

```text
macos/     Swift app, storage, checks and Mac build tooling
windows/   Windows app, portable storage and checks
docs/      Product requirements, platform parity and test evidence
scripts/   Compatible entry points for Mac builds
```

The existing commands still work from the repository root:

```sh
./scripts/test.sh
./scripts/package.sh
./scripts/install.sh --replace
```

Mac bundles and ZIPs remain in `dist/`. Windows builds and installers go to `artifacts/windows/`. Both directories, local databases, signing keys and user settings are excluded from Git.

## Version history

Real local Git history starts with the saved Mac 1.0.6 source. Earlier release binaries exist locally, but older source states were not committed. New changes are recorded as ordinary commits under the configured GitHub author identity. There are no fabricated historical commits.

This repository can be pushed to a GitHub repository later with its complete local commit history. A remote repository has not been configured or published.
