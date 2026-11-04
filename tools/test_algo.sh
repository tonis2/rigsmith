#!/bin/sh
# Runs the algorithm tests with no editor, GPU or window: only the lower layers
# and test/algo are compiled. Arguments go to c3c, such as --test-filter name.
cd "$(dirname "$0")/.." || exit 1

libs="--libdir libs/three/lib --lib gltf --lib collision --lib image"
lower=$(find src/rig src/gltf src/core src/anim -name '*.c3')
tests=$(find test/algo -name '*.c3')

# shellcheck disable=SC2086
exec c3c compile-test --test-noleak --test-quiet --output-dir build/algo --build-dir build/algo "$@" $libs $lower $tests
