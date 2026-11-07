# Move this project to GitHub

The local repository has genuine development commits authored as Yash Modi using the verified GitHub noreply identity from the Project repository. History begins with the current Mac1.0.6 checkpoint; older development commits were never recorded and are not fabricated.

The public repository is [YashModi1804/ClipDiary](https://github.com/YashModi1804/ClipDiary). Its publishing branch is `main`, and `origin` points to that repository. For another clone or fork, connect your chosen remote:

```sh
git remote add origin https://github.com/YashModi1804/ClipDiary.git
git push -u origin main
```

All existing commits are preserved. If a remote already exists, inspect it first rather than overwriting another project. Choose public visibility when ready to publish the MIT-licensed source. No credentials or signing keys belong in the repository.

`artifacts/ClipDiary-history.bundle` is a portable Git copy containing the source and commit history. On another computer:

```sh
git clone ClipDiary-history.bundle ClipDiary
cd ClipDiary
```

Connect the clone to your chosen GitHub remote and push. The bundle does not contain generated installers, existing clipboard databases, private snippets or your Git authentication credentials.

After push, inspect the Actions results. Native Windows tests require an unlocked interactive runner; a workflow file alone is not a test result. Run the documented manual acceptance too. Create a GitHub Release and attach the matching Mac ZIP and Windows setup/ZIP/checksum files from `dist/` and `artifacts/windows/`. Keep Windows0.1.0 labeled a prerelease until native acceptance passes. End users should download release assets, not source-code archives, unless they intend to build.

The app has no runtime server. GitHub hosts source, tests and optional downloads; each user's clipboard data stays local.
