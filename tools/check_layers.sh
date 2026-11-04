#!/bin/sh
# Fails when a layer reaches upward. Each layer is compiled without the ones above
# it, so a reference to anything up there does not resolve. Takes about a second.
cd "$(dirname "$0")/.." || exit 1

libs="--libdir libs/three/lib --lib gltf --lib collision --lib image"
pure=$(find src/model src/algo -name '*.c3')
files=$(find src/format -name '*.c3')

# shellcheck disable=SC2086
c3c -C compile-only --no-obj $libs $pure || {
	echo "check_layers: model or algo depends on something above it" >&2
	exit 1
}

# shellcheck disable=SC2086
c3c -C compile-only --no-obj $libs $pure $files || {
	echo "check_layers: format depends on something above it" >&2
	exit 1
}

# algo takes inputs and returns results: files belong to format.
if grep -rnE 'import std::io|file::|path::' src/model src/algo; then
	echo "check_layers: model or algo touches files" >&2
	exit 1
fi

# Third-party rig names stay out of the code: see Naming in AGENTS.md.
if grep -rIil 'mixamo' src test tools --exclude=check_layers.sh; then
	echo "check_layers: third-party rig name in the files above" >&2
	exit 1
fi
