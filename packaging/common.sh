# Sourced by the package-*.sh scripts. Run from the repository root, after
# `c3c build rigsmith`.

set -euo pipefail

# The version from a v* tag, or a dev stamp for a hand-run build.
rigsmith_version() {
	local ref="${GITHUB_REF_NAME:-$(git describe --tags --exact-match 2>/dev/null || true)}"
	case "$ref" in
		v*) echo "${ref#v}" ;;
		*)  echo "0.0.0-dev+$(git rev-parse --short HEAD)" ;;
	esac
}

# Copy what the app reads at runtime into <dir>/assets. The executable finds it
# there through `locate_bundle` (src/main.c3), whatever directory it is run from.
stage_assets() {
	local dest="$1/assets"
	mkdir -p "$dest/animations"
	cp assets/DejaVuSans.ttf assets/DejaVuSans-LICENSE "$dest/"
	cp assets/animations/*.glb "$dest/animations/"
	local f
	for f in "$dest"/animations/*.glb; do
		if head -c 40 "$f" | grep -q 'git-lfs'; then
			echo "::error::$f is a Git LFS pointer, not a model — check out with LFS" >&2
			exit 1
		fi
	done
}
