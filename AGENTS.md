# Making cui widgets

Try to make re-usable widgets to cui library, instead of new widget that directly paints columns/text.
For example instead or making Grid widget from fresh in crig, make Grid widget in cui and use it as build method with @subtree, seen in cui.c3l/test/composite.c3

# UI widgets in crig

Use AppState* app = ui.inherit(AppState)!!; instead of passing AppState to widget struct where possible.

# Testing
run c3c test --test-noleak mostly when developing,
and then c3c test in the end when all features are in, so it detects memory leaks.
Running c3c test with full leak detection is slow and should not be done after every change, but when full plan is done.
Version managing of configs is not important in current crig state, cause there's no users yet


The tests should only use .glb files in the assets folder, no fixtures

# Build and run

rigsmith is an executable again and links three's engine sources:

    c3c build rigsmith
    ./build/rigsmith model.glb --mcp


**three is a git submodule at `libs/three`, and it sits in `libs/` beside llm.c3l.**
rigsmith compiles three's sources into its binary and resolves every library — cui,
gltf, collision, mcp, quickjs, vk, shady — from `libs/three/lib`, so both name
one copy by construction. A cui or engine change is made inside the submodule,
committed and pushed there, and then the pin is moved here.

After a fresh clone:

    git submodule update --init --recursive
    libs/three/setup.sh          # fetches the macOS Vulkan driver