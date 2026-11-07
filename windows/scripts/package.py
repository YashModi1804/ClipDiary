#!/usr/bin/env python3
"""Build self-contained Windows releases on Windows, macOS or Linux (Python 3.9+)."""
import argparse
import base64
import datetime
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
PUBLISH_INPUTS = ROOT / "windows/publish-runtime-lock.json"


def run(arguments, **kwargs):
    subprocess.run([str(a) for a in arguments], check=True, cwd=ROOT, **kwargs)


def source_state(allow_dirty=False):
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    dirty = bool(subprocess.check_output(["git", "status", "--porcelain", "--untracked-files=all"], cwd=ROOT))
    if dirty and not allow_dirty:
        raise RuntimeError("Release packaging requires a clean committed worktree. Commit inputs first, or use --allow-dirty for a clearly marked development build.")
    return revision, dirty


def compiler_version(compiler):
    prefix = "/" if os.name == "nt" else "-"
    return subprocess.check_output([compiler, prefix + "VERSION"], cwd=ROOT, text=True).strip().removeprefix("v")


def package_cache(dotnet):
    result = subprocess.check_output([dotnet, "nuget", "locals", "global-packages", "--list"], cwd=ROOT, text=True)
    for line in result.splitlines():
        if line.strip().lower().startswith("global-packages:"):
            return Path(line.split(":", 1)[1].strip())
    raise RuntimeError("Cannot locate the restored NuGet package cache.")


def verified_runtime_archives(cache, inputs, required=None):
    archives = {}
    for name, expected in inputs["packages"].items():
        if required is not None and name not in required:
            continue
        archive = cache / name / expected["version"] / (name + "." + expected["version"] + ".nupkg")
        digest = hashlib.sha512()
        with archive.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
        if base64.b64encode(digest.digest()).decode("ascii") != expected["sha512"]:
            raise RuntimeError("Locked runtime package failed SHA512 verification: " + name)
        archives[name] = archive
    return archives


def copy_runtime_notices(archives, runtime, destination):
    for package in ["microsoft.netcore.app.runtime." + runtime,
                    "microsoft.windowsdesktop.app.runtime." + runtime]:
        if package not in archives:
            raise RuntimeError("No locked runtime archive: " + package)
        with zipfile.ZipFile(archives[package]) as archive:
            notices = [name for name in archive.namelist() if "/" not in name and "\\" not in name and
                       ("license" in name.lower() or "notice" in name.lower())]
            if not any("license" in name.lower() for name in notices):
                raise RuntimeError("Locked runtime package is missing its license: " + package)
            if package.startswith("microsoft.netcore.") and not any("third-party" in name.lower() for name in notices):
                raise RuntimeError("Locked .NET runtime package is missing its third-party notices.")
            for name in notices:
                (destination / (package + "-" + archives[package].parent.name + "-" + name)).write_bytes(archive.read(name))


def sdk_pack_locations(dotnet):
    result = subprocess.check_output([dotnet, "msbuild", PROJECT,
        "-getProperty:NETCoreSdkRuntimeIdentifier,NetCoreTargetingPackRoot"], cwd=ROOT, text=True)
    properties = json.loads(result)["Properties"]
    return properties["NETCoreSdkRuntimeIdentifier"], Path(properties["NetCoreTargetingPackRoot"])


def verify_download_versions(inputs, sdk_rid, sdk_packs, runtime=None):
    assets = json.loads((PROJECT.parent / "obj/project.assets.json").read_text(encoding="utf-8"))
    downloads = {}
    for framework in assets["project"]["frameworks"].values():
        downloads.update({item["name"].lower(): item["version"] for item in framework.get("downloadDependencies", [])})
    external, sdk_provided = set(), []
    for name, expected in inputs["packages"].items():
        # A native restore need not acquire packs for a different publication RID.
        if runtime is not None and name != "microsoft.windowsdesktop.app.ref" and not name.endswith("." + runtime):
            continue
        version = expected["version"]
        if name in downloads:
            if downloads[name] != "[" + version + ", " + version + "]":
                raise RuntimeError("Publish resolved a runtime/reference pack outside its lock: " + name)
            external.add(name)
            continue
        # Windows SDKs can pre-provision the reference pack and selected apphost.
        # Other hosts download those exact packs; an unrelated RID is never required.
        if name == "microsoft.windowsdesktop.app.ref":
            supplied = sdk_packs / "Microsoft.WindowsDesktop.App.Ref" / version / "ref/net10.0/PresentationCore.dll"
        elif name.startswith("microsoft.netcore.app.host."):
            host_rid = name.removeprefix("microsoft.netcore.app.host.")
            supplied = sdk_packs / ("Microsoft.NETCore.App.Host." + host_rid) / version / "runtimes" / host_rid / "native/apphost.exe"
        else:
            raise RuntimeError("Required publication pack was not resolved: " + name)
        if not supplied.is_file():
            raise RuntimeError("The locked SDK-provided pack is missing: " + name + " " + version)
        sdk_provided.append(name)
    return external, sdk_provided


def write_archive(publish, archive, timestamp):
    moment = datetime.datetime.fromtimestamp(max(timestamp, 315532800), datetime.timezone.utc)
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as target:
        for path in sorted(publish.rglob("*")):
            if path.is_file():
                entry = zipfile.ZipInfo(path.relative_to(publish).as_posix(), moment.timetuple()[:6])
                entry.compress_type = zipfile.ZIP_DEFLATED
                entry.create_system = 3
                entry.external_attr = 0o100644 << 16
                target.writestr(entry, path.read_bytes(), compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
    with zipfile.ZipFile(archive) as target:
        if target.testzip() is not None:
            raise RuntimeError("The release ZIP failed its integrity check.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", choices=["win-x64", "win-arm64"], default="win-x64")
    parser.add_argument("--installer", action="store_true", help="Also compile an NSIS setup executable")
    parser.add_argument("--allow-dirty", action="store_true", help="Development builds only: mark uncommitted source explicitly in BUILD_INFO")
    args = parser.parse_args()
    revision, dirty = source_state(args.allow_dirty)
    inputs = json.loads(PUBLISH_INPUTS.read_text(encoding="utf-8"))
    if inputs.get("formatVersion") != 1:
        parser.error("Unsupported publication input lock.")
    dotnet = os.environ.get("DOTNET_COMMAND") or shutil.which("dotnet")
    if not dotnet:
        parser.error("Install the .NET 10 SDK, or set DOTNET_COMMAND to its executable.")
    compiler = os.environ.get("NSIS_COMPILER") or shutil.which("makensis")
    if args.installer and not compiler:
        parser.error("Install NSIS 3, or set NSIS_COMPILER to makensis.")
    sdk_version = subprocess.check_output([dotnet, "--version"], cwd=ROOT, text=True).strip()
    if sdk_version != inputs["sdkVersion"]:
        parser.error("Release packaging requires the locked .NET SDK " + inputs["sdkVersion"] + ".")
    if args.installer and compiler_version(compiler) != inputs["nsisVersion"]:
        parser.error("Release packaging requires NSIS " + inputs["nsisVersion"] + ".")
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
    publication = ["-p:RuntimeIdentifier=" + args.runtime, "-p:SelfContained=true", "-p:PublishSingleFile=true",
                   "-p:IncludeNativeLibrariesForSelfExtract=true", "-p:PublishTrimmed=false"]
    # Restore the same graph that is actually bundled, using committed publish locks.
    run([dotnet, "restore", PROJECT, "--locked-mode", *publication])
    external, sdk_provided = verify_download_versions(inputs, *sdk_pack_locations(dotnet), runtime=args.runtime)
    runtime_archives = verified_runtime_archives(package_cache(dotnet), inputs, external)
    run([dotnet, "publish", PROJECT, "-c", "Release", "--no-restore", *publication,
         "-p:DebugType=None", "-p:DebugSymbols=false", "-o", publish])
    final_revision, final_dirty = source_state(args.allow_dirty)
    if final_revision != revision:
        raise RuntimeError("Source HEAD changed during publication; retry from a stable checkout.")
    dirty = dirty or final_dirty
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
    shutil.copy2(ROOT / "docs/OPEN_SOURCE_REVIEW.md", publish / "docs/OPEN_SOURCE_REVIEW.md")
    shutil.copy2(ROOT / "docs/CODEQL_TRIAGE.md", publish / "docs/CODEQL_TRIAGE.md")
    shutil.copy2(ROOT / "docs/SECURITY_EXPERT_REVIEW.md", publish / "docs/SECURITY_EXPERT_REVIEW.md")
    shutil.copy2(ROOT / "docs/DEVOPS_SECURITY_REVIEW.md", publish / "docs/DEVOPS_SECURITY_REVIEW.md")
    shutil.copy2(ROOT / "windows/ClipDiary.Windows/Platform/TESTABILITY.md", publish / "docs/TESTABILITY.md")
    (publish / "BUILD_INFO.json").write_text(json.dumps({"version": version, "runtime": args.runtime,
        "sourceCommit": revision, "sourceDirty": dirty, "sdkVersion": sdk_version,
        "runtimeVersion": inputs["runtimeVersion"], "installerCompiler": ("NSIS " + inputs["nsisVersion"]) if args.installer else None,
        "runtimePackageHashes": {name: value for name, value in inputs["packages"].items() if name in runtime_archives},
        "sdkProvidedPacks": sdk_provided,
        "nativeWindowsValidated": False}, indent=2) + "\n", encoding="utf-8")
    shutil.copytree(ROOT / "windows/licenses", publish / "licenses", dirs_exist_ok=True)
    copy_runtime_notices(runtime_archives, args.runtime, publish / "licenses")
    archive = output / f"ClipDiary-{version}-{args.runtime}.zip"
    timestamp = int(subprocess.check_output(["git", "show", "-s", "--format=%ct", revision], cwd=ROOT, text=True))
    write_archive(publish, archive, timestamp)
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
    completed_revision, completed_dirty = source_state(args.allow_dirty)
    if completed_revision != revision or completed_dirty != dirty:
        raise RuntimeError("Source HEAD or dirty state changed while packaging; retry from a stable checkout.")
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
