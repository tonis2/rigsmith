<*
 The engine, as crig sees it.

 crig used to own `main`, a window, a Vulkan device, a mesh pass, an MCP server
 with two transports and a QuickJS runtime. It owns `main` again — but not the
 other five: three does, and this is the one handle everything reaches them
 through.

 ## Why a module global rather than a field on AppState

 The same argument crig's CLAUDE.md already makes about `ui.inherit(AppState)`: a
 pointer that every file needs and no file owns is worse as a parameter on two
 hundred signatures than as a static that is set once before anything runs.
 `main` sets it before the first frame and nothing clears it while the process
 lives.

 Null until then, and null in a unit test — which links these sources without
 ever bringing a device up. `hosted()` is that question, and it is the reason
 several files can be checked with no window at all.

 ## What changed when the plugin went

 This was a `three_abi::HostApi*` — a table of function pointers into another
 image, because crig was a `.dylib` three loaded and the two could share no
 types. Now crig compiles three's engine sources into its own binary, so this is
 an ordinary pointer to an ordinary struct and every call below is a direct one.
 `three::Engine` is the seam; `libs/three/src/app/boot.c3` describes it.
*>
module crig;

import three;

<*
 The window, device and renderer crig is drawing with. Set once by `main`.
*>
three::Engine* engine = null;

// Whether crig has been given an engine yet. False in a unit test.
fn bool hosted() @inline => engine != null;

<*
 The world: meshes, the scene graph, the camera and the view rect.

 Null when there is no engine, which every caller checks with `hosted()` first
 rather than testing this — the two are the same question and one of them reads
 as the thing being asked.
*>
fn three::MeshPass* stage_pass() @inline => engine == null ? null : &engine.renderer.pass;

// The device, for the uploads and the sweeps that need a `Gpu*`.
fn three::Renderer* stage_renderer() @inline => engine == null ? null : &engine.renderer;
