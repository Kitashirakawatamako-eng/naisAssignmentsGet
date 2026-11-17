"""Compile and install 作业速览 for the current Mac."""
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
BACKEND_FILES = (
    "desktop_bridge.py", "school_tasks.py", "school_keychain.py", "school_timetable.py",
    "task_records.py", "task_report.py", "report_template.html",
)
MODEL_FILES = (
    "README.md", "metadata.json", "sentencepiece.model",
    "model/config.json", "model/shared_vocabulary.json", "model/model.bin",
)
MODEL_SHA256 = "433e7c4f034d87fbe2353161e05f18646d7999452f801a4e1f0378522b9850ab"


def run(*args, **kwargs):
    subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def install_model(folder, archive):
    print("正在下载英译中模型…", flush=True)
    run("/usr/bin/curl", "--fail", "--location", "--silent", "--show-error", "--retry", 2,
        "--max-time", 240, "https://argos-net.com/v1/translate-en_zh-1_9.argosmodel", "-o", archive)
    with archive.open("rb") as handle:
        if file_digest(handle, "sha256").hexdigest() != MODEL_SHA256:
            raise ValueError("英译中模型校验失败，安装已停止。")
    with ZipFile(archive) as model:
        for name in MODEL_FILES:
            target = folder / name
            target.parent.mkdir(parents=True, exist_ok=True)
            with model.open("translate-en_zh-1_9/" + name) as before, target.open("wb") as after:
                shutil.copyfileobj(before, after)


def install_runtime(source_runtime, runtime):
    shutil.copytree(source_runtime, runtime, symlinks=True)
    library = runtime / "lib/python3.13"
    packages = library / "site-packages"
    print("正在安装翻译依赖…", flush=True)
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
    bundle = stage / "作业速览.app"
    contents = bundle / "Contents"
    native = contents / "MacOS"
    resources = contents / "Resources"
    native.mkdir(parents=True)
    resources.mkdir()
    shutil.copyfile(SOURCE / "Desktop/Info.plist", contents / "Info.plist")
    backend = resources / "Backend"
    backend.mkdir()
    for name in BACKEND_FILES:
        shutil.copyfile(SOURCE / "backend" / name, backend / name)
    shutil.copyfile(SOURCE / "scripts/THIRD_PARTY.md", resources / "第三方组件.md")
    install_model(resources / "Models/en-zh", stage / "model.zip")
    (resources / "Python").mkdir()
    install_runtime(runtime, resources / "Python" / architecture)

    print("正在编译 Mac 应用…", flush=True)
    cache = stage / "SwiftModules"
    icon = SOURCE / "Desktop/draw_icon.swift"
    sources = sorted(path for path in (SOURCE / "Desktop").glob("*.swift") if path != icon)
    run("/usr/bin/xcrun", "swiftc", "-O", "-swift-version", "5", "-parse-as-library",
        "-target", f"{architecture}-apple-macosx14.0", "-module-cache-path", cache,
        *sources, "-o", native / "AssignmentDesktop")
    run("/usr/bin/xcrun", "swift", "-module-cache-path", cache, icon, resources / "AppIcon.icns")
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
        raise ValueError("「应用程序」已有同名替身，请移开后再安装。")
    previous = stage / "previous.app"
    if destination.exists():
        path = destination / "Contents/Info.plist"
        if not path.is_file() or plistlib.loads(path.read_bytes()).get("CFBundleIdentifier") != APP_ID:
            raise ValueError("「应用程序」已有其他同名应用，请移开后再安装。")
        try:
            quit_installed_app(destination, stage)
        except subprocess.CalledProcessError:
            raise ValueError("旧版仍在运行，请退出作业速览后重新安装。") from None
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
    destination = apps / "作业速览.app"
    apps.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".sp-install-", dir=apps) as stage:
        stage = Path(stage)
        bundle = build_app(stage, args.runtime.resolve(), args.architecture)
        install_app(bundle, destination, stage)
    print(f"安装完成。{destination}", flush=True)
    if not args.no_open:
        run("/usr/bin/open", destination)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit(f"安装失败。{error}")
