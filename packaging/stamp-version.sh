#!/usr/bin/env bash
#
# Write the release's version into src/version.c3, so the Help menu and
# `rigsmith --help` name it. Run it before the build, and don't commit the
# result:
#
#     packaging/stamp-version.sh && c3c build rigsmith
#
# Prints the version it wrote.
source "$(dirname "$0")/common.sh"

version="$(rigsmith_version)"
file=src/version.c3
line="const String VERSION = \"${version}\";"
# -i.bak rather than -i: BSD sed on the macOS runner needs the suffix. No $
# anchor and no grep -x: a Windows checkout may end the line with \r.
sed -i.bak "s/^const String VERSION = \".*\";/${line}/" "$file"
rm -f "$file.bak"
grep -qF "$line" "$file" || {
	echo "::error::could not stamp the version into $file" >&2
	exit 1; }
echo "$version"
