#!/usr/bin/env bash
#
# Build dist/Rigsmith-<version>-macos-arm64.dmg from build/rigsmith: a
# Rigsmith.app to drag into Applications.
#
#     c3c build rigsmith && packaging/package-macos.sh
#
# The bundle carries the Vulkan loader and KosmicKrisp driver beside the
# executable in Contents/MacOS, where vk/loader.c3 and vk/driver.c3 look for them
# (@executable_path), and the assets under Contents/Resources. KosmicKrisp is
# built for macOS 26, so that is the bundle's floor.
#
# Signed ad hoc only, not notarized: a downloaded copy is quarantined, and the
# first launch has to be right-click > Open (or `xattr -dr com.apple.quarantine`).
source "$(dirname "$0")/common.sh"

version="$(rigsmith_version)"
stage="dist/macos"
app="$stage/Rigsmith.app"
rm -rf "$stage"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

cp build/rigsmith "$app/Contents/MacOS/"
drivers="libs/three/lib/vulkan.c3l/macos-aarch64"
[ -f "$drivers/libvulkan_kosmickrisp.dylib" ] || {
	echo "::error::no Vulkan driver in $drivers — run libs/three/setup.sh driver" >&2
	exit 1; }
libs/three/packaging/stage-libs.sh "$drivers" "$app/Contents/MacOS"
stage_assets "$app/Contents/Resources"
cp LICENSE "$app/Contents/Resources/"

# The icon: every size iconutil wants, cut from the one PNG.
iconset="$stage/rigsmith.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
	sips -z $size $size packaging/rigsmith.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
	double=$((size * 2))
	[ $double -le 512 ] && sips -z $double $double packaging/rigsmith.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/rigsmith.icns"
rm -rf "$iconset"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>Rigsmith</string>
	<key>CFBundleDisplayName</key><string>Rigsmith</string>
	<key>CFBundleIdentifier</key><string>io.github.tonis2.rigsmith</string>
	<key>CFBundleExecutable</key><string>rigsmith</string>
	<key>CFBundleIconFile</key><string>rigsmith</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>${version%%[-+]*}</string>
	<key>CFBundleVersion</key><string>${version}</string>
	<key>LSMinimumSystemVersion</key><string>26.0</string>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Re-sign after the bundle is assembled: an arm64 binary must carry a valid
# signature to run at all, and adding the dylibs beside it changes the bundle.
codesign --force --deep --sign - "$app"

ln -s /Applications "$stage/Applications"
out="dist/Rigsmith-${version}-macos-arm64.dmg"
rm -f "$out"
hdiutil create -volname Rigsmith -srcfolder "$stage" -ov -format UDZO "$out" >/dev/null
echo "$out"
