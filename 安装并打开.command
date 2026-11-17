#!/bin/zsh
set -euo pipefail

sp_source="${0:A:h}"
if [[ "$(/usr/bin/uname -s)" != "Darwin" ]]; then
  print -u2 '作业速览需要 macOS 14 或更新版本。'
  exit 1
fi
sp_version="$(/usr/bin/sw_vers -productVersion)"
if (( ${sp_version%%.*} < 14 )); then
  print -u2 '作业速览需要 macOS 14 或更新版本。'
  exit 1
fi
if ! /usr/bin/xcode-select -p >/dev/null 2>&1 || ! /usr/bin/xcrun --find swiftc >/dev/null 2>&1; then
  print '请安装 Apple 命令行工具，完成后重新运行此文件。'
  /usr/bin/xcode-select --install
  exit 1
fi

sp_arch="$(/usr/bin/uname -m)"
case "$sp_arch" in
  arm64)
    sp_machine=aarch64
    sp_sha=7a2384641584ab9984221fcb0fc9265df465922af71be71410529e2a9c3f0540
    ;;
  x86_64)
    sp_machine=x86_64
    sp_sha=d27d59a722db9f69926eb6d9564071247221f45a04da920ea7f3001c97e32f9b
    ;;
  *)
    print -u2 "不支持的 Mac 架构 $sp_arch"
    exit 1
    ;;
esac

sp_stage="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf -- "$sp_stage"' EXIT
sp_archive="$sp_stage/python.tar.gz"
print '正在下载 Python 运行环境…'
/usr/bin/curl --fail --location --silent --show-error --retry 2 --max-time 240 \
  "https://github.com/astral-sh/python-build-standalone/releases/download/20261110/cpython-3.13.18%2B20261110-$sp_machine-apple-darwin-install_only_stripped.tar.gz" \
  -o "$sp_archive"
printf '%s  %s\n' "$sp_sha" "$sp_archive" | /usr/bin/shasum -a 256 --check --status
/usr/bin/tar -xzf "$sp_archive" -C "$sp_stage"
"$sp_stage/python/bin/python3.13" -I -B "$sp_source/scripts/install_macos.py" \
  "$sp_stage/python" "$sp_arch" "$@"
