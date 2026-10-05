#!/usr/bin/env bash
#
# Build dist/Rigsmith-<version>-windows-x64.zip from build/rigsmith.exe: a
# portable folder — unzip anywhere and run rigsmith.exe, nothing to install.
#
#     c3c build rigsmith && packaging/package-windows.sh
source "$(dirname "$0")/common.sh"

version="$(rigsmith_version)"
name="Rigsmith-${version}-windows-x64"
out="dist/$name"
rm -rf "$out"
mkdir -p "$out"

cp build/rigsmith.exe "$out/"
stage_assets "$out"
cp LICENSE "$out/LICENSE.txt"

cd dist
rm -f "$name.zip"
if command -v zip >/dev/null 2>&1; then
	zip -qr "$name.zip" "$name"
else
	# Git Bash on Windows has no zip, and its tar is GNU tar, which cannot write one.
	powershell -NoProfile -Command "Compress-Archive -Path '$name' -DestinationPath '$name.zip'"
fi
echo "dist/$name.zip"
