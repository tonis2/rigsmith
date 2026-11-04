#!/bin/sh
# Fails when a lower layer reaches up into app, ui or mcp. The layers are compiled
# alone, so a reference to anything above them does not resolve. Under a second.
cd "$(dirname "$0")/.." || exit 1

libs="--libdir libs/three/lib --lib gltf --lib collision --lib image"
lower=$(find src/rig src/gltf src/core src/anim -name '*.c3')

# shellcheck disable=SC2086
c3c -C compile-only --no-obj $libs $lower || {
	echo "check_layers: a lower layer depends on something above it" >&2
	exit 1
}
