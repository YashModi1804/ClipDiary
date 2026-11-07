# Third-party notices

ClipDiary's own code and original icon artwork are MIT licensed; see LICENSE. Dependencies keep their own licenses. Versions and content hashes are committed in the .NET package lockfiles.

## Windows

- Microsoft.Data.Sqlite / Microsoft.Data.Sqlite.Core 10.0.14: MIT; copyright Microsoft Corporation and .NET Foundation contributors. Full license: `windows/licenses/Microsoft.Data.Sqlite.txt`. [Upstream](https://github.com/dotnet/efcore).
- SQLitePCLRaw.core, provider.e_sqlite3, bundle_e_sqlite3 and lib.e_sqlite3 2.1.13: Apache-2.0; copyright 2014–2024 SourceGear, LLC. Full license: `windows/licenses/SQLitePCLRaw.txt`. [Upstream](https://github.com/ericsink/SQLitePCL.raw).
- SQLite itself is public domain. [Upstream copyright statement](https://www.sqlite.org/copyright.html).
- The self-contained Windows release includes .NET and Windows Desktop runtime components. The .NET MIT license is in `windows/licenses/DotNet.txt`; the packaging helper also copies license/third-party notice files from the exact restored runtime packages into the distributed `licenses/` folder. These components have their own included third-party notices. [Runtime sources](https://github.com/dotnet/runtime).
- NSIS is used to create Windows installers. Its compiler/installer components include zlib/bzip2 licenses and the LZMA module under the Common Public License 1.0 with its special linking exception; the full notices are in `windows/licenses/NSIS.txt`. [Upstream licenses](https://nsis.sourceforge.io/License). No NSIS compiler is required to run ClipDiary.

## macOS

The Mac app uses Apple system frameworks and the system SQLite library, with no third-party Swift package dependencies. Apple frameworks remain subject to Apple's platform terms; they are not redistributed as ClipDiary source.

The build SDK, installer compiler and GitHub Actions are development tools, not runtime services. Network access is used only to acquire build dependencies or run explicitly configured repository automation. ClipDiary itself does not contact a server.
