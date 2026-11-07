# ClipDiary

An MIT-licensed, local clipboard diary for macOS and Windows. Text, copied images, screenshot history and permanent parameterized snippets stay on your own computer. No account or runtime server is required.

## Platforms

- **macOS:** the existing native Swift/SwiftUI/AppKit app, version 1.0.7. [Build and use it](macos/README.md).
- **Windows:** native C#/.NET 10 WPF implementation, version 0.1.1 beta. Automated native Windows checks passed; manual acceptance remains pending. Platform validation is tracked in [the Windows guide](windows/README.md).

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

The public repository is [YashModi1804/ClipDiary](https://github.com/YashModi1804/ClipDiary), published on the `main` branch.

## Open source

Use, modify and share ClipDiary under the [MIT license](LICENSE). [Contributing](CONTRIBUTING.md), [security reporting](SECURITY.md), [dependency notices](THIRD_PARTY_NOTICES.md) and [platform parity](docs/PLATFORM_PARITY.md) are included. The [open-source review](docs/OPEN_SOURCE_REVIEW.md) records security checks and remaining release limits.

Self-contained Windows setup executables/ZIPs and Mac ZIPs can be attached to GitHub Releases. Generated binaries stay outside Git. The included GitHub Actions workflow runs portable checks on three operating systems, Mac regressions, and native Windows checks before building installers. Passing native CI results and remaining manual acceptance are recorded in [Windows validation](docs/WINDOWS_VALIDATION.md).
