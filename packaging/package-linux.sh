#!/usr/bin/env bash
#
# Build dist/Rigsmith-<version>-x86_64.AppImage from build/rigsmith.
#
#     c3c build rigsmith && packaging/package-linux.sh
#
# Nothing but the executable and its assets goes in: Vulkan, X11 and Wayland are
# all dlopened from the system at runtime, the same as an unpackaged build.
source "$(dirname "$0")/common.sh"

version="$(rigsmith_version)"
appdir="dist/Rigsmith.AppDir"
rm -rf "$appdir"
mkdir -p "$appdir/usr/bin" "$appdir/usr/share/rigsmith"

cp build/rigsmith "$appdir/usr/bin/"
strip "$appdir/usr/bin/rigsmith" || true
stage_assets "$appdir/usr/share/rigsmith"
cp LICENSE "$appdir/usr/share/rigsmith/"

ln -s usr/bin/rigsmith "$appdir/AppRun"
cp packaging/rigsmith.png "$appdir/rigsmith.png"
ln -s rigsmith.png "$appdir/.DirIcon"
cat > "$appdir/rigsmith.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Rigsmith
Comment=Rig and animate glTF models
Exec=rigsmith %f
Icon=rigsmith
Categories=Graphics;3DGraphics;
MimeType=model/gltf-binary;
Terminal=false
DESKTOP

tool="${APPIMAGETOOL:-dist/appimagetool}"
if [ ! -x "$tool" ]; then
	curl -fsSL -o "$tool" https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage
	chmod +x "$tool"
fi

out="dist/Rigsmith-${version}-x86_64.AppImage"
# Extract-and-run: CI runners have no FUSE to mount the tool itself.
ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 "$tool" --no-appstream "$appdir" "$out"
echo "$out"
