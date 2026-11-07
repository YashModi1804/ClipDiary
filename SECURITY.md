# Security

ClipDiary stores clipboard data locally under the current user's account. It uses no runtime network service or telemetry. Database and image files are protected with user-only permissions where supported, but application storage is not encrypted. Operating-system account and disk protection still matter.

Supported sensitive/transient clipboard markers and excluded apps are skipped on a best-effort basis; this is not universal secret detection. Four-day expiry deletes app-owned history; it cannot erase the system clipboard, screenshot originals, other clipboard managers, snapshots or backups. Snippets remain until explicitly deleted.

Report security defects privately through [GitHub private vulnerability reporting](https://github.com/YashModi1804/ClipDiary/security/advisories/new). Use synthetic content in bug reports, and never attach your real history database or private screenshots. Public issues are suitable for non-sensitive bugs only.

Security fixes target the latest source on `main` and the next release. Older binaries are not separately maintained. Windows remains a beta pending manual native acceptance; do not assume older builds contain current fixes.

Automated checks cover dependency advisories, source analysis, secret scanning and focused retention/path/privacy regressions. They do not establish that all vulnerabilities are absent. Native Windows acceptance is tracked separately from portable Mac-run checks. Public release signing and notarization are not configured; current checksums identify files but do not prove publisher identity or byte-for-byte reproducibility.
