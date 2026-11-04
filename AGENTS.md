# Making cui widgets

Try to make re-usable widgets to cui library, instead of new widget that directly paints columns/text.
For example instead or making Grid widget from fresh in crig, make Grid widget in cui and use it as build method with @subtree, seen in cui.c3l/test/composite.c3

# UI widgets in crig

Use AppState* app = ui.inherit(AppState)!!; instead of passing AppState to widget struct where possible.

# Testing
run c3c test --test-noleak mostly when developing,
c3c test --test-filter <suite>
Only run c3c test full leak checks when told directly.


The tests should only use .glb files in the assets folder, no fixtures

Algorithm tests go in test/algo and need no editor. Run a suite with c3c test --test-filter <suite>; CI runs them all through tools/test_algo.sh.

# Layers

Dependencies point one way: `src/model` and `src/algo`, then `src/format`, then `src/app`, then `src/ui` and `src/mcp`. tools/check_layers.sh compiles each layer without the ones above it, and the pre-commit hook runs it.

- `src/model`: data, such as RigDocument and AnimPack.
- `src/algo`: algorithms by topic. No AppState, UI, GPU, files or notices: take inputs, return results, and let app record them.
- `src/format`: reading and writing files and JSON.
- `src/app`: state, undo and commands, as thin methods that call algo.

Install the hook once with:

    echo 'tools/pre-commit.sh || exit 1' >> .git/hooks/pre-commit

# Fixing a bug

1. Find the rule in rules/. If there isn't one, add it.
2. Write a test that fails first, at the level of the algorithm.
3. Look for every other door to the same behaviour, and make them share one function.
4. Name the rule and the case in the commit message, not "Fixes".

If a fix needs a test in test/rules changed, that is a rule changing: stop and ask the owner. Don't rewrite or delete a test just to get to green.

# Naming

Don't use third-party product or rig names in code, comments or test data. Write "a downloaded rig", and `armature:LeftHand` for a prefixed joint name.

# Build and run

When c3c build gives warnings on build time, fix those too

rigsmith is an executable again and links three's engine sources:

    c3c build rigsmith
    ./build/rigsmith model.glb --mcp


**three is a git submodule at `libs/three`, and it sits in `libs/` beside llm.c3l.**
rigsmith compiles three's sources into its binary and resolves every library — cui,
gltf, collision, mcp, quickjs, vk, shady — from `libs/three/lib`, so both name
one copy by construction. A cui or engine change is made inside the submodule,
committed and pushed there, and then the pin is moved here.                                # here, after a repack

After a fresh clone:

    git submodule update --init --recursive
    libs/three/setup.sh          # fetches the macOS Vulkan driver

If you open a new rigsmith instance, close the old ones before, and run rigsmith instance on port 8088 (the default one)    