#!/usr/bin/env python3
"""Build self-contained Windows releases on Windows, macOS or Linux (Python 3.9+)."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[2]
PROJECT = ROOT / "windows/ClipDiary.Windows/ClipDiary.Windows.csproj"


def run(arguments, **kwargs):
    subprocess.run([str(a) for a in arguments], check=True, cwd=ROOT, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", choices=["win-x64", "win-arm64"], default="win-x64")
    parser.add_argument("--installer", action="store_true", help="Also compile an NSIS setup executable")
    args = parser.parse_args()
    dotnet = os.environ.get("DOTNET_COMMAND") or shutil.which("dotnet")
    if not dotnet:
        parser.error("Install the .NET 10 SDK, or set DOTNET_COMMAND to its executable.")
    compiler = os.environ.get("NSIS_COMPILER") or shutil.which("makensis")
    if args.installer and not compiler:
        parser.error("Install NSIS 3, or set NSIS_COMPILER to makensis.")
    version = ET.parse(PROJECT).findtext("./PropertyGroup/Version")
    if not version:
        parser.error("The Windows project has no release version.")
    output = ROOT / "artifacts/windows"
    publish = output / args.runtime / "publish"
    if not publish.resolve().is_relative_to(ROOT):
        parser.error("The generated output path must stay inside this repository.")
    if publish.exists():
        shutil.rmtree(publish)
    publish.mkdir(parents=True)
    run([dotnet, "publish", PROJECT, "-c", "Release", "-r", args.runtime,
         "--self-contained", "true", "-p:PublishSingleFile=true",
         "-p:IncludeNativeLibrariesForSelfExtract=true", "-p:PublishTrimmed=false",
         "-p:DebugType=None", "-p:DebugSymbols=false", "-o", publish])
    shutil.copy2(ROOT / "LICENSE", publish / "LICENSE")
    shutil.copy2(ROOT / "THIRD_PARTY_NOTICES.md", publish / "THIRD_PARTY_NOTICES.md")
    readme = (ROOT / "windows/README.md").read_text(encoding="utf-8")
    readme = readme.replace("../docs/WINDOWS_VALIDATION.md", "docs/WINDOWS_VALIDATION.md")
    readme = readme.replace("../SECURITY.md", "SECURITY.md")
    readme = readme.replace("ClipDiary.Windows/Platform/TESTABILITY.md", "docs/TESTABILITY.md")
    (publish / "README.md").write_text(readme, encoding="utf-8")
    (publish / "docs").mkdir()
    shutil.copy2(ROOT / "SECURITY.md", publish / "SECURITY.md")
    shutil.copy2(ROOT / "docs/WINDOWS_VALIDATION.md", publish / "docs/WINDOWS_VALIDATION.md")
    shutil.copy2(ROOT / "windows/ClipDiary.Windows/Platform/TESTABILITY.md", publish / "docs/TESTABILITY.md")
    revision = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, check=True, capture_output=True, text=True).stdout.strip()
    (publish / "BUILD_INFO.json").write_text(json.dumps({"version": version, "runtime": args.runtime,
        "sourceCommit": revision, "sdkVersion": subprocess.check_output([dotnet, "--version"], cwd=ROOT, text=True).strip(), "nativeWindowsValidated": False}, indent=2) + "\n", encoding="utf-8")
    shutil.copytree(ROOT / "windows/licenses", publish / "licenses", dirs_exist_ok=True)
    # Include the precise runtime pack notices that match this self-contained build.
    result = subprocess.run([dotnet, "nuget", "locals", "global-packages", "--list"],
                            check=True, capture_output=True, text=True, cwd=ROOT)
    package_cache = Path(result.stdout.strip().split(": ", 1)[1])
    for package in ["microsoft.netcore.app.runtime." + args.runtime,
                    "microsoft.windowsdesktop.app.runtime." + args.runtime]:
        directory = package_cache / package
        for notice in directory.glob("*/*"):
            if notice.is_file() and ("license" in notice.name.lower() or "notice" in notice.name.lower()):
                shutil.copy2(notice, publish / "licenses" / (package + "-" + notice.parent.name + "-" + notice.name))
    archive = output / f"ClipDiary-{version}-{args.runtime}.zip"
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as target:
        for path in sorted(publish.rglob("*")):
            if path.is_file():
                target.write(path, path.relative_to(publish))
    with zipfile.ZipFile(archive) as target:
        if target.testzip() is not None:
            raise RuntimeError("The release ZIP failed its integrity check.")
    artifacts = [archive]
    if args.installer:
        # Delete only files actually shipped, and remove only empty directories on uninstall.
        manifest = publish.parent / "uninstall-files.nsh"
        def nsis(value):
            return value.replace("$", "$$").replace('"', '$\\"')
        paths = sorted(publish.rglob("*"))
        lines = ['Delete "$INSTDIR\\' + nsis(str(p.relative_to(publish)).replace("/", "\\")) + '"'
                 for p in paths if p.is_file()]
        directories = sorted([p for p in paths if p.is_dir()], key=lambda p: len(p.parts), reverse=True)
        lines += ['RMDir "$INSTDIR\\' + nsis(str(p.relative_to(publish)).replace("/", "\\")) + '"' for p in directories]
        manifest.write_text("\n".join(lines) + "\n", encoding="utf-8")
        setup = output / f"ClipDiary-{version}-{args.runtime}-Setup.exe"
        prefix = "/" if os.name == "nt" else "-"
        definitions = {"APP_VERSION": version, "APP_RID": args.runtime, "PUBLISH_DIR": publish,
                       "OUTPUT_FILE": setup, "REPOSITORY": ROOT, "UNINSTALL_MANIFEST": manifest}
        run([compiler, prefix + "V2", *[prefix + "D" + key + "=" + str(value) for key, value in definitions.items()],
             ROOT / "windows/installer/ClipDiary.nsi"])
        artifacts.append(setup)
    checksum = output / f"ClipDiary-{version}-{args.runtime}-SHA256SUMS.txt"
    lines = []
    for artifact in artifacts:
        digest = hashlib.sha256()
        with artifact.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
        lines.append(digest.hexdigest() + "  " + artifact.name)
        print("Built", artifact)
    checksum.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("Checksums", checksum)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print("Packaging failed:", error, file=sys.stderr)
        sys.exit(1)
