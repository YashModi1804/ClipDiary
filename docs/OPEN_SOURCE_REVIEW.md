# Open-source and security review

Reviewed 7 November 2026. This is an engineering review, not a penetration test or a guarantee that every vulnerability is absent. Public source publication is appropriate under MIT; Windows remains a beta and public signed releases are a separate milestone.

## Scope

Reviewed licensing and dependency notices, contribution/reporting paths, Git history, repository protections, CI dependencies, packaging, local storage cleanup and asynchronous copying. Tests use synthetic data; no real clipboard history was inspected. Application runtime remains local; GitHub scanning and dependency downloads are development services.

## Changes

- Private vulnerability reporting and a direct security-report link replace the ambiguous profile-contact fallback. Security fixes target current `main`; older binaries are not separately maintained.
- Dependabot alerts and automatic security updates are enabled alongside weekly NuGet/action update checks. CI treats dependency advisory and audit-feed failures as errors.
- CI action references use full immutable commit IDs. Workflow tokens default to read-only and cannot approve pull requests; external contributors require approval before workflow execution. NSIS is pinned to 3.13.
- `main` requires pull requests, up-to-date portable/Mac/Windows/secret checks and resolved discussions. Force pushes and branch deletion are disabled; the owner retains GitHub's emergency administrator bypass.
- CodeQL source analysis and a checksum-verified, full-history Gitleaks workflow supplement GitHub secret scanning and push protection.
- Windows explicit copies are invalidated by deletion, clearing, relevant snippet edits and shutdown, with final checks before clipboard writes. Copy preparation cannot revive a deleted/expired item.
- Settings saves reject a serialized file larger than the loader's 64 KiB bound before replacing the current working file.
- Failed deletion of a partial image file remains queued for periodic cleanup rather than waiting for application restart.
- Windows dependency locks cover single-file publishing, with toolchain/runtime verification and source-provenance checks. Runtime notices must correspond to the runtime actually packaged.
- License summaries include NSIS's LZMA CPL 1.0 terms and linking exception. Download documentation distinguishes temporary CI artifacts from official releases.
- Mac timestamp and Windows file-sharing test fixtures are corrected without changing the interface.

## Evidence and boundaries

The initial 12-commit history passed Gitleaks 8.30.1 with no findings. GitHub's initial secret and dependency alert queries returned no open alerts. These are point-in-time checks and do not cover every secret format or unreported dependency flaw.

The initial Windows CI job passed its native synthetic checks, WPF smoke checks and x64/ARM64 packaging. ARM64 packages were cross-built, not executed on ARM64 hardware. The separate Mac XCTest and Windows portable test failures were fixture issues addressed in this review. See [Actions](https://github.com/YashModi1804/ClipDiary/actions) for commit-specific reruns and [Windows validation](WINDOWS_VALIDATION.md) for manual acceptance boundaries.

The bundled SQLite engine was identified as 3.53.3. It is not the latest upstream SQLite; no specific unpatched advisory was established by this review. NuGet advisory checks do not establish complete native-library coverage. Track the [upstream changes](https://sqlite.org/changes.html) and [SQLite CVE assessment](https://sqlite.org/cves.html) when updating the provider/native package.

## Remaining release limits

- Application storage is not encrypted. OS account permissions and disk protection remain relevant. Secret exclusion is best effort.
- App-owned history expiry cannot erase screenshot originals, the system clipboard, snapshots, backups or data copied into other applications.
- Windows tray, focus, hotkey, login, lock/sleep, installer update/uninstall and pointer behavior still require manual acceptance. Native automated tests cover only their declared fixtures.
- Public signing/notarization and artifact provenance attestation are not configured. Checksums establish file integrity, not publisher identity. Pinned inputs and a clean commit do not establish byte-for-byte reproducible builds.
- No official GitHub Release was published as part of this review. Use source or clearly labeled CI beta artifacts until release acceptance is completed.
