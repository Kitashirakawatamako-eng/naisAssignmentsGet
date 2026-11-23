"""Compile and install Assignment Overview for the current Mac."""
from argparse import ArgumentParser
from hashlib import file_digest
from pathlib import Path
import os
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile
from zipfile import ZipFile


SOURCE = Path(__file__).resolve().parents[1]
APP_ID = "local.spassignments.desktop"
APP_NAME = "Assignment Overview"
LEGACY_APP_NAME = "作业速览"
WIDGET_BUNDLE = Path("Contents/PlugIns/TimetableWidget.appex")
WIDGET_BINARY = WIDGET_BUNDLE / "Contents/MacOS/TimetableWidget"
BACKEND_FILES = (
    "desktop_bridge.py", "school_tasks.py", "school_keychain.py", "school_timetable.py", "school_grades.py",
    "task_records.py", "task_report.py", "report_template.html",
)
MODEL_FILES = (
    "README.md", "metadata.json", "sentencepiece.model",
    "model/config.json", "model/shared_vocabulary.json", "model/model.bin",
)
MODELS = {
    "en-zh": "433e7c4f034d87fbe2353161e05f18646d7999452f801a4e1f0378522b9850ab",
    "zh-en": "62e7af5a3a48b530e47b7b3e5c78c2de79073ecd815750d2bf3ab35b4a67da2d",
}


def run(*args, **kwargs):
    subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def install_model(folder, archive):
    direction = folder.name
    package = f"translate-{direction.replace('-', '_')}-1_9"
    print(f"Downloading the {direction} translation model…", flush=True)
    run("/usr/bin/curl", "--fail", "--location", "--silent", "--show-error", "--retry", 2,
        "--max-time", 240, f"https://argos-net.com/v1/{package}.argosmodel", "-o", archive)
    with archive.open("rb") as handle:
        if file_digest(handle, "sha256").hexdigest() != MODELS[direction]:
            raise ValueError("Translation model checksum failed; installation stopped.")
    with ZipFile(archive) as model:
        for name in MODEL_FILES:
            target = folder / name
            target.parent.mkdir(parents=True, exist_ok=True)
            with model.open(f"{package}/" + name) as before, target.open("wb") as after:
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


def build_widget(contents, cache, architecture):
    source = SOURCE / "TimetableWidget"
    bundle = contents / "PlugIns/TimetableWidget.appex"
    executable = bundle / "Contents/MacOS/TimetableWidget"
    executable.parent.mkdir(parents=True)
    info = plistlib.loads((source / "Info.plist").read_bytes())
    app = plistlib.loads((contents / "Info.plist").read_bytes())
    for key in ("CFBundleShortVersionString", "CFBundleVersion"):
        info[key] = app[key]
    (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    for localization in source.glob("*.lproj"):
        shutil.copytree(localization, bundle / "Contents/Resources" / localization.name)
    # Keep the Swift widget bundle linked while Foundation serves the XPC requests.
    run("/usr/bin/xcrun", "swiftc", "-O", "-swift-version", "5", "-parse-as-library",
        "-application-extension", "-target", f"{architecture}-apple-macosx14.0",
        "-framework", "Foundation", "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain",
        "-Xlinker", "-u", "-Xlinker", "_main",
        "-module-cache-path", cache, SOURCE / "Desktop/AssignmentData.swift", SOURCE / "Desktop/GPAData.swift",
        SOURCE / "Desktop/DeskTheme.swift", SOURCE / "Desktop/WidgetSnapshot.swift",
        SOURCE / "Desktop/Timetable.swift", source / "TimetableWidget.swift", "-o", executable)
    # Finder metadata copied from a desktop checkout is not permitted on signed extensions.
    run("/usr/bin/xattr", "-cr", bundle)
    run("/usr/bin/codesign", "--force", "--sign", "-", "--entitlements",
        source / "TimetableWidget.entitlements", bundle)


def build_app(stage, runtime, architecture):
    bundle = stage / f"{APP_NAME}.app"
    contents = bundle / "Contents"
    native = contents / "MacOS"
    resources = contents / "Resources"
    native.mkdir(parents=True)
    resources.mkdir()
    shutil.copyfile(SOURCE / "Desktop/Info.plist", contents / "Info.plist")
    shutil.copyfile(SOURCE / "Desktop/AppIcon.icns", resources / "AppIcon.icns")
    for name in ("BookOtter.png", "ClassicIcon.icns", "OtterTransparentIcon.icns", "CreatureTransparentIcon.icns",
                 "OtterTransparentIconSource.png", "CreatureTransparentIconSource.png"):
        shutil.copyfile(SOURCE / "Desktop" / name, resources / name)
    for localization in (SOURCE / "Desktop").glob("*.lproj"):
        shutil.copytree(localization, resources / localization.name)
    backend = resources / "Backend"
    backend.mkdir()
    for name in BACKEND_FILES:
        shutil.copyfile(SOURCE / "backend" / name, backend / name)
    shutil.copyfile(SOURCE / "scripts/THIRD_PARTY.md", resources / "Third-Party Components.md")
    for direction in MODELS:
        install_model(resources / "Models" / direction, stage / f"{direction}.zip")
    (resources / "Python").mkdir()
    install_runtime(runtime, resources / "Python" / architecture)

    print("Building the macOS app…", flush=True)
    cache = stage / "SwiftModules"
    sources = sorted((SOURCE / "Desktop").glob("*.swift"))
    run("/usr/bin/xcrun", "swiftc", "-O", "-swift-version", "5", "-parse-as-library",
        "-target", f"{architecture}-apple-macosx14.0", "-module-cache-path", cache,
        *sources, "-o", native / "AssignmentDesktop")
    build_widget(contents, cache, architecture)
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


def stop_retired_widget(previous, destination):
    retired = previous / WIDGET_BINARY
    if not retired.is_file():
        return
    # WidgetKit may keep the old executable mapped after the bundle was replaced.
    mapped = subprocess.run(["/usr/sbin/lsof", "-a", "-d", "txt", "-t", str(retired)],
                            capture_output=True, text=True)
    valid_paths = {retired.resolve(), (destination / WIDGET_BINARY).resolve()}
    for pid in mapped.stdout.splitlines():
        if not pid.isdecimal():
            continue
        process = subprocess.run(["/bin/ps", "-p", pid, "-o", "comm="], capture_output=True, text=True)
        executable = process.stdout.strip()
        if not executable or Path(executable).resolve() not in valid_paths:
            continue
        try:
            os.kill(int(pid), signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            pass


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
    stop_retired_widget(previous, destination)
    widget = destination / WIDGET_BUNDLE
    if widget.is_dir():
        # Register the new containing app before asking PlugInKit to discover its widgets.
        registrar = Path("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")
        if registrar.is_file():
            subprocess.run([str(registrar), "-f", str(destination)], capture_output=True)
        registration = subprocess.run(["/usr/bin/pluginkit", "-a", str(widget)], capture_output=True, text=True)
        if registration.returncode:
            print("Widget registration will be retried by macOS when the app opens.", file=sys.stderr)


def main():
    parser = ArgumentParser(description=__doc__)
    parser.add_argument("runtime", type=Path)
    parser.add_argument("architecture", choices=("arm64", "x86_64"))
    parser.add_argument("--app-dir", type=Path, default=Path.home() / "Applications")
    parser.add_argument("--no-open", action="store_true")
    args = parser.parse_args()
    apps = args.app_dir.expanduser().resolve()
    destination = apps / f"{LEGACY_APP_NAME}.app"
    english = apps / f"{APP_NAME}.app"
    if not destination.exists() and english.exists():
        destination = english
    apps.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".sp-install-", dir=apps) as stage:
        stage = Path(stage)
        bundle = build_app(stage, args.runtime.resolve(), args.architecture)
        install_app(bundle, destination, stage)
    print(f"Installation complete. {destination}", flush=True)
    if not args.no_open:
        run("/usr/bin/open", destination)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit(f"Installation failed. {error}")
