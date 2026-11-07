# Security

ClipDiary stores clipboard data locally under the current user's account. It uses no runtime network service or telemetry. Database and image files are protected with user-only permissions where supported, but application storage is not encrypted. Operating-system account and disk protection still matter.

Supported sensitive/transient clipboard markers and excluded apps are skipped on a best-effort basis; this is not universal secret detection. Four-day expiry deletes app-owned history; it cannot erase the system clipboard, screenshot originals, other clipboard managers, snapshots or backups. Snippets remain until explicitly deleted.

Report security defects privately using GitHub's private vulnerability reporting when enabled. If unavailable, contact the maintainer through the GitHub profile before posting sensitive details publicly. Use synthetic content in bug reports, and never attach your real history database or private screenshots.

Public release checks include dependency audits, safe-path and retention tests, source-preserving screenshot imports, native permission/session behavior and signed/reproducible artifact verification when signing is available. Signing credentials are not included in this repository. Windows native acceptance is tracked separately from Mac-run checks.
