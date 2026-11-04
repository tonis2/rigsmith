#!/bin/sh
# Runs the algorithm tests with no editor, GPU or window: only the lower layers
# and test/algo are compiled. Arguments go to c3c, such as --test-filter name.
cd "$(dirname "$0")/.." || exit 1

libs="--libdir libs/three/lib --lib gltf --lib collision --lib image"
lower=$(find src/model src/algo src/format -name '*.c3')
tests=$(find test/algo -name '*.c3')

# Leak checks cost time locally; CI always runs them.
leaks="--test-noleak"
[ -n "$CI" ] && leaks=""

# shellcheck disable=SC2086
exec c3c compile-test $leaks --test-quiet --output-dir build/algo --build-dir build/algo "$@" $libs $lower $tests
