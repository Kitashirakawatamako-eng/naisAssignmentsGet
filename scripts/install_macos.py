"""Compile and install Assignment Overview for the current Mac."""
from argparse import ArgumentParser
from hashlib import file_digest
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
from zipfile import ZipFile


SOURCE = Path(__file__).resolve().parents[1]
APP_ID = "local.spassignments.desktop"
APP_NAME = "Assignment Overview"
LEGACY_APP_NAME = "作业速览"
BACKEND_FILES = (
    "desktop_bridge.py", "school_tasks.py", "school_keychain.py", "school_timetable.py",
    "task_records.py", "task_report.py", "report_template.html",
)
MODEL_FILES = (
    "README.md", "metadata.json", "sentencepiece.model",
    "model/config.json", "model/shared_vocabulary.json", "model/model.bin",
)
MODEL_SHA256 = "62e7af5a3a48b530e47b7b3e5c78c2de79073ecd815750d2bf3ab35b4a67da2d"


def run(*args, **kwargs):
    subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def install_model(folder, archive):
    print("Downloading the Chinese-to-English translation model…", flush=True)
    run("/usr/bin/curl", "--fail", "--location", "--silent", "--show-error", "--retry", 2,
        "--max-time", 240, "https://argos-net.com/v1/translate-zh_en-1_9.argosmodel", "-o", archive)
    with archive.open("rb") as handle:
        if file_digest(handle, "sha256").hexdigest() != MODEL_SHA256:
            raise ValueError("Translation model checksum failed; installation stopped.")
    with ZipFile(archive) as model:
        for name in MODEL_FILES:
            target = folder / name
            target.parent.mkdir(parents=True, exist_ok=True)
            with model.open("translate-zh_en-1_9/" + name) as before, target.open("wb") as after:
                shutil.copyfileobj(before, after)


def install_runtime(source_runtime, runtime):
    shutil.copytree(source_runtime, runtime, symlinks=True)
    library = runtime / "lib/python3.13"
    packages = library / "site-packages"
    print("Installing translation dependencies…", flush=True)
    run(sys.executable, "-I", "-B", "-m", "pip", "--isolated", "install", "--disable-pip-version-check",
        "--no-cache-dir", "--no-compile", "--only-binary=:all:", "--index-url", "https://pypi.org/simple",
        "--target", packages, "-r", SOURCE / "requirements.txt")
    for directory in (library / "ensurepip", packages / "pip", packages / "bin",
                      runtime / "include", runtime / "lib/pkgconfig", *packages.glob("pip-*.dist-info")):
        if directory.is_dir():
            shutil.rmtree(directory)
    for item in (runtime / "bin").iterdir():
        if item.name not in ("python", "python3", "python3.13") and (item.is_symlink() or item.is_file()):
            item.unlink()
    for binary in (runtime / "bin/python3.13", *runtime.rglob("*.dylib"), *runtime.rglob("*.so")):
        if binary.is_file() and not binary.is_symlink():
            run("/usr/bin/codesign", "--force", "--sign", "-", binary,
                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)


def build_app(stage, runtime, architecture):
    bundle = stage / f"{APP_NAME}.app"
    contents = bundle / "Contents"
    native = contents / "MacOS"
    resources = contents / "Resources"
    native.mkdir(parents=True)
    resources.mkdir()
    shutil.copyfile(SOURCE / "Desktop/Info.plist", contents / "Info.plist")
    shutil.copyfile(SOURCE / "Desktop/AppIcon.icns", resources / "AppIcon.icns")
    for name in ["ClassicIcon.icns", "CreatureIcon.icns", "OtterIcon.icns", "OtterTransparentIcon.icns", "CreatureTransparentIcon.icns"]:
        shutil.copyfile(SOURCE / "Desktop" / name, resources / name)
    for localization in (SOURCE / "Desktop").glob("*.lproj"):
        shutil.copytree(localization, resources / localization.name)
    backend = resources / "Backend"
    backend.mkdir()
    for name in BACKEND_FILES:
        shutil.copyfile(SOURCE / "backend" / name, backend / name)
    shutil.copyfile(SOURCE / "scripts/THIRD_PARTY.md", resources / "Third-Party Components.md")
    install_model(resources / "Models/zh-en", stage / "model.zip")
    (resources / "Python").mkdir()
    install_runtime(runtime, resources / "Python" / architecture)

    print("Building the macOS app…", flush=True)
    cache = stage / "SwiftModules"
    sources = sorted((SOURCE / "Desktop").glob("*.swift"))
    run("/usr/bin/xcrun", "swiftc", "-O", "-swift-version", "5", "-parse-as-library",
        "-target", f"{architecture}-apple-macosx14.0", "-module-cache-path", cache,
        *sources, "-o", native / "AssignmentDesktop")
    run("/usr/bin/codesign", "--force", "--sign", "-", bundle)
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", bundle)
    return bundle


def quit_installed_app(destination, stage):
    script = r"""
import AppKit
let target = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath().path
let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "local.spassignments.desktop")
    .filter { $0.bundleURL?.resolvingSymlinksInPath().path == target }
for app in apps where !app.isTerminated {
    guard app.terminate() else { exit(1) }
}
let deadline = Date().addingTimeInterval(10)
while apps.contains(where: { !$0.isTerminated }), Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
}
guard apps.allSatisfy(\.isTerminated) else { exit(2) }
"""
    run("/usr/bin/xcrun", "swift", "-module-cache-path", stage / "SwiftModules", "-", destination,
        input=script, text=True)


def install_app(bundle, destination, stage):
    if destination.is_symlink():
        raise ValueError("A same-named alias already exists in Applications. Move it and try again.")
    previous = stage / "previous.app"
    if destination.exists():
        path = destination / "Contents/Info.plist"
        if not path.is_file() or plistlib.loads(path.read_bytes()).get("CFBundleIdentifier") != APP_ID:
            raise ValueError("A different app with this name already exists in Applications. Move it and try again.")
        try:
            quit_installed_app(destination, stage)
        except subprocess.CalledProcessError:
            raise ValueError("The previous version is still running. Quit Assignment Overview and try again.") from None
        destination.rename(previous)
    try:
        bundle.rename(destination)
    except OSError:
        if previous.exists():
            previous.rename(destination)
        raise


def main():
    parser = ArgumentParser(description=__doc__)
    parser.add_argument("runtime", type=Path)
    parser.add_argument("architecture", choices=("arm64", "x86_64"))
    parser.add_argument("--app-dir", type=Path, default=Path.home() / "Applications")
    parser.add_argument("--no-open", action="store_true")
    args = parser.parse_args()
    apps = args.app_dir.expanduser().resolve()
    destination = apps / f"{APP_NAME}.app"
    apps.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".sp-install-", dir=apps) as stage:
        stage = Path(stage)
        bundle = build_app(stage, args.runtime.resolve(), args.architecture)
        legacy = apps / f"{LEGACY_APP_NAME}.app"
        archived_legacy = stage / "previous-legacy.app"
        if legacy.exists() and not destination.exists():
            legacy_info = legacy / "Contents/Info.plist"
            if legacy_info.is_file() and plistlib.loads(legacy_info.read_bytes()).get("CFBundleIdentifier") == APP_ID:
                try:
                    quit_installed_app(legacy, stage)
                except subprocess.CalledProcessError:
                    raise ValueError("The previous version is still running. Quit it and try again.") from None
                legacy.rename(archived_legacy)
        try:
            install_app(bundle, destination, stage)
        except OSError:
            if archived_legacy.exists() and not legacy.exists():
                archived_legacy.rename(legacy)
            raise
    print(f"Installation complete. {destination}", flush=True)
    if not args.no_open:
        run("/usr/bin/open", destination)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit(f"Installation failed. {error}")
