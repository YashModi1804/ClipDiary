"""Portable release-guard tests; use synthetic archives and disposable Git repositories."""
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile

SPEC = importlib.util.spec_from_file_location("release_package", Path(__file__).parents[1] / "package.py")
package = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(package)


class PublicationGuards(unittest.TestCase):
    def test_source_guard_rejects_dirty_and_marks_explicit_development_build(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            def git(*args):
                subprocess.run(["git", "-c", "commit.gpgSign=false", "-c", "core.hooksPath=/dev/null", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", *args], cwd=root, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            git("init")
            (root / "source.txt").write_text("committed")
            (root / ".gitignore").write_text("artifacts/\n")
            git("add", "."); git("commit", "-m", "fixture")
            with patch.object(package, "ROOT", root):
                revision, dirty = package.source_state()
                self.assertFalse(dirty)
                (root / "artifacts").mkdir(); (root / "artifacts/output").write_text("ignored build")
                self.assertEqual(package.source_state(), (revision, False))
                (root / "source.txt").write_text("uncommitted")
                with self.assertRaisesRegex(RuntimeError, "clean committed"):
                    package.source_state()
                self.assertEqual(package.source_state(True), (revision, True))

    def test_zip_metadata_does_not_depend_on_workspace_mtime(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); source = root / "publish"; source.mkdir()
            (source / "ClipDiary.exe").write_bytes(b"synthetic executable")
            first, second = root / "one.zip", root / "two.zip"
            package.write_archive(source, first, 1700000000)
            os.utime(source / "ClipDiary.exe", (1000000000, 1000000000))
            package.write_archive(source, second, 1700000000)
            self.assertEqual(first.read_bytes(), second.read_bytes())

    def archive(self, cache, name, files):
        directory = cache / name / "10.0.14"; directory.mkdir(parents=True)
        archive = directory / (name + ".10.0.14.nupkg")
        with zipfile.ZipFile(archive, "w") as output:
            for key, value in files.items(): output.writestr(key, value)
        digest = base64.b64encode(hashlib.sha512(archive.read_bytes()).digest()).decode()
        return archive, {"version": "10.0.14", "sha512": digest}

    def test_archive_hash_rejects_modified_runtime(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); name = "microsoft.netcore.app.runtime.win-x64"
            archive, expected = self.archive(root, name, {"LICENSE.TXT": "license"})
            inputs = {"packages": {name: expected}}
            self.assertEqual(package.verified_runtime_archives(root, inputs)[name], archive)
            archive.write_bytes(archive.read_bytes() + b"tampering")
            with self.assertRaisesRegex(RuntimeError, "SHA512"):
                package.verified_runtime_archives(root, inputs)

    def test_exact_verified_runtime_notices_and_required_documents(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); destination = root / "licenses"; destination.mkdir()
            core = "microsoft.netcore.app.runtime.win-x64"; desktop = "microsoft.windowsdesktop.app.runtime.win-x64"
            first, _ = self.archive(root, core, {"LICENSE.TXT": "core license", "THIRD-PARTY-NOTICES.TXT": "core notices", "nested/LICENSE": "not selected"})
            second, _ = self.archive(root, desktop, {"LICENSE": "desktop license"})
            package.copy_runtime_notices({core: first, desktop: second}, "win-x64", destination)
            self.assertEqual(len(list(destination.iterdir())), 3)
            self.assertIn(b"core notices", [p.read_bytes() for p in destination.iterdir()])
            with zipfile.ZipFile(first, "w") as output: output.writestr("LICENSE.TXT", "license without notices")
            with self.assertRaisesRegex(RuntimeError, "third-party"):
                package.copy_runtime_notices({core: first, desktop: second}, "win-x64", destination)

    def sdk_fixture(self, root, downloads):
        project = root / "App.csproj"; (root / "obj").mkdir()
        (root / "obj/project.assets.json").write_text(json.dumps({"project": {"frameworks": {"net10.0-windows": {"downloadDependencies": [{"name": key, "version": value} for key, value in downloads.items()]}}}}))
        names = ["microsoft.netcore.app.runtime.win-x64", "microsoft.windowsdesktop.app.ref", "microsoft.netcore.app.host.win-x64"]
        inputs = {"packages": {key: {"version": "10.0.14"} for key in names}}
        packs = root / "sdk-packs"
        for path in [packs / "Microsoft.WindowsDesktop.App.Ref/10.0.14/ref/net10.0/PresentationCore.dll", packs / "Microsoft.NETCore.App.Host.win-x64/10.0.14/runtimes/win-x64/native/apphost.exe"]:
            path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(b"SDK supplied fixture")
        return project, inputs, packs

    def test_native_windows_sdk_supplied_reference_and_host_are_supported(self):
        with tempfile.TemporaryDirectory() as folder:
            project, inputs, packs = self.sdk_fixture(Path(folder), {"microsoft.netcore.app.runtime.win-x64": "[10.0.14, 10.0.14]"})
            with patch.object(package, "PROJECT", project):
                external, provided = package.verify_download_versions(inputs, "win-x64", packs)
                self.assertEqual(external, {"microsoft.netcore.app.runtime.win-x64"})
                self.assertEqual(len(provided), 2)
                (packs / "Microsoft.WindowsDesktop.App.Ref/10.0.14/ref/net10.0/PresentationCore.dll").unlink()
                with self.assertRaisesRegex(RuntimeError, "SDK-provided pack is missing"):
                    package.verify_download_versions(inputs, "win-x64", packs)

    def test_cross_host_packs_are_downloaded_and_versions_cannot_float(self):
        with tempfile.TemporaryDirectory() as folder:
            downloads = {key: "[10.0.14, 10.0.14]" for key in ["microsoft.netcore.app.runtime.win-x64", "microsoft.windowsdesktop.app.ref", "microsoft.netcore.app.host.win-x64"]}
            project, inputs, packs = self.sdk_fixture(Path(folder), downloads)
            with patch.object(package, "PROJECT", project):
                external, provided = package.verify_download_versions(inputs, "osx-arm64", packs)
                self.assertEqual(external, set(downloads)); self.assertEqual(provided, [])
                data = json.loads((Path(folder) / "obj/project.assets.json").read_text())
                data["project"]["frameworks"]["net10.0-windows"]["downloadDependencies"][0]["version"] = "[10.0.15, 10.0.15]"
                (Path(folder) / "obj/project.assets.json").write_text(json.dumps(data))
                with self.assertRaisesRegex(RuntimeError, "outside its lock"):
                    package.verify_download_versions(inputs, "osx-arm64", packs)

    def test_selected_rid_does_not_require_unrelated_architecture_packs(self):
        with tempfile.TemporaryDirectory() as folder:
            project, inputs, packs = self.sdk_fixture(Path(folder), {"microsoft.netcore.app.runtime.win-x64": "[10.0.14, 10.0.14]"})
            inputs["packages"].update({name: {"version": "10.0.14"} for name in
                ["microsoft.netcore.app.host.win-arm64", "microsoft.netcore.app.runtime.win-arm64", "microsoft.windowsdesktop.app.runtime.win-arm64"]})
            with patch.object(package, "PROJECT", project):
                external, provided = package.verify_download_versions(inputs, "win-x64", packs, runtime="win-x64")
                self.assertEqual(external, {"microsoft.netcore.app.runtime.win-x64"})
                self.assertEqual(set(provided), {"microsoft.windowsdesktop.app.ref", "microsoft.netcore.app.host.win-x64"})
                self.assertFalse(any(name.endswith("win-arm64") for name in external | set(provided)))

    def test_selected_cross_architecture_sdk_host_must_have_exact_locked_files(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            project, inputs, packs = self.sdk_fixture(root, {"microsoft.netcore.app.runtime.win-arm64": "[10.0.14, 10.0.14]"})
            inputs["packages"] = {name: {"version": "10.0.14"} for name in
                ["microsoft.windowsdesktop.app.ref", "microsoft.netcore.app.runtime.win-arm64", "microsoft.netcore.app.host.win-arm64", "microsoft.netcore.app.host.win-x64"]}
            host = packs / "Microsoft.NETCore.App.Host.win-arm64/10.0.14/runtimes/win-arm64/native/apphost.exe"
            host.parent.mkdir(parents=True); host.write_bytes(b"SDK provided ARM64 host fixture")
            with patch.object(package, "PROJECT", project):
                external, provided = package.verify_download_versions(inputs, "win-x64", packs, runtime="win-arm64")
                self.assertEqual(external, {"microsoft.netcore.app.runtime.win-arm64"})
                self.assertEqual(set(provided), {"microsoft.windowsdesktop.app.ref", "microsoft.netcore.app.host.win-arm64"})
                host.unlink()
                with self.assertRaisesRegex(RuntimeError, "SDK-provided pack is missing"):
                    package.verify_download_versions(inputs, "win-x64", packs, runtime="win-arm64")

    def test_nsis_version_is_normalized(self):
        with patch.object(package.subprocess, "check_output", return_value="v3.13\n"):
            self.assertEqual(package.compiler_version("synthetic makensis"), "3.13")


if __name__ == "__main__": unittest.main()
