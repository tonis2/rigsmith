<*
 crig — a joint-based rigger, with three's engine underneath it.

 crig [model.glb] [options]

 --preset <name>       fit a body plan once the mesh is up: quadruped, biped, bird
 --mcp [port]          serve Rigsmith's tools on this port for this run (always on otherwise,
                       on the port in File > Settings — 8808 unless changed)
 --mcp-stdio [port]    relay stdin/stdout to a Rigsmith that is already serving
 --width <n>           the window's size in points
 --height <n>          the same, vertically
 --ui-scale <n>        how big the interface is drawn; remembered (default 1)
 --debug               validation layers and three's own @debug_log

 A path is optional and always was: the animation library, the body plans and
 every pane of the workspace are reachable without having decided on a file
 first. `--preset` needs one, and says so.

 ## Where the engine stops and crig starts

 three owns the window, the Vulkan device, the renderer, the JavaScript runtime
 and the MCP transport. crig owns the document, the workspace, the tools and the
 camera — and it owns `main`, which is the whole of the difference from the
 arrangement this replaces.

 crig was a `dynamic-lib` that `three --plugin` loaded. Everything above was the
 same, and it was reached through a table of function pointers between two
 images that had to agree on struct layout exactly: a `void*` where a `cui::Ui*`
 belonged, a rule about which libraries either side could link, a thunk between
 two spellings of a tool handler, and a `__c3_runtime_startup` that had to be
 called by hand or every `@dynamic` interface call in crig failed at run time.
 Now three's engine sources compile into this binary and every one of those is an
 ordinary call. See `engine/engine.c3` for the handle and
 `libs/three/src/app/boot.c3` for the seam.

 ## The loop is crig's

 Not three's `live`. That one is written for a game — it boots a script or an
 assets directory and its whole job is between the tick and the draw — and crig's
 per-frame work is a different list: service a pending open, push the document,
 the camera and the pane rect into the scene. Everything a window frame *is*
 still comes from `three::drive_window`, so there is one participant in the
 events, the pointer and the cursor rather than two.

 **Order matters twice in it.** `drive_window` runs three's own camera controls
 before `sync_scene` pushes crig's, so crig's camera is the one that lands — and
 three's are turned off besides, since crig's viewport widget owns the drag.
 `sync_scene` runs last so a mesh opened this iteration reaches the device in the
 same one rather than a frame later.
*>
module crig;

import three;
import cui;
import rig;
import mcp;
import c3w;
import std::io;
import std::time;

<*
 The document, the workspace and everything the tools edit.

 Static for the reason `engine/engine.c3` gives about the engine handle: one
 process, one document, and a pointer every file needs and no file owns.
*>
AppState app @local;

// The tree crig built into three's Ui. Kept so shutdown can take it back down
// before the Ui it was built into goes away.
cui::Element* workspace @local = null;

const int DEFAULT_MCP_PORT = 8808;

fn int main(String[] args)
{
	String mesh_path = "";
	String preset_name = "";
	int port = 0;
	bool relay_stdio = false;
	uint width = 1280;
	uint height = 720;
	bool size_given = false;
	// Zero means "the flag was not given", which is a different answer from any
	// scale it could name — the config's own setting stands in that case.
	float ui_scale = 0.0f;

	for (usz i = 1; i < args.len; i++)
	{
		String argument = args[i];
		switch (argument)
		{
			case "--help":
			case "-h":
				usage();
				return 0;
			case "--debug":
				three::debugging = true;
			case "--preset":
				if (i + 1 >= args.len)
				{
					io::eprintn("rigsmith: --preset needs a name: quadruped, biped or bird");
					return 1;
				}
				preset_name = args[++i];
			case "--width":
				if (i + 1 >= args.len) { io::eprintn("rigsmith: --width needs a number"); return 1; }
				width = args[++i].to_uint() ?? 1280;
				size_given = true;
			case "--height":
				if (i + 1 >= args.len) { io::eprintn("rigsmith: --height needs a number"); return 1; }
				height = args[++i].to_uint() ?? 720;
				size_given = true;
			case "--ui-scale":
				// Refused rather than clamped, unlike everything that reaches the
				// setting from inside the program: a number typed on a command line
				// is a claim about what was meant, and `--ui-scale 20` is a typo
				// worth saying so about instead of silently starting at 3.
				if (i + 1 >= args.len) { io::eprintn("rigsmith: --ui-scale needs a number"); return 1; }
				String asked = args[++i];
				float? given = asked.to_float();
				if (catch given)
				{
					io::eprintfn("rigsmith: --ui-scale wants a number, not '%s'", asked);
					return 1;
				}
				if (given < MIN_UI_SCALE || given > MAX_UI_SCALE)
				{
					io::eprintfn("rigsmith: --ui-scale is between %.2f and %.2f, not %.2f",
						MIN_UI_SCALE, MAX_UI_SCALE, given);
					return 1;
				}
				ui_scale = given;
			case "--mcp":
				// The port is optional, so a following argument is taken only when it
				// actually looks like one — otherwise `crig --mcp model.glb` would
				// swallow the path.
				port = DEFAULT_MCP_PORT;
				if (i + 1 < args.len)
				{
					if (try given = args[i + 1].to_int())
					{
						port = given;
						i++;
					}
				}
			case "--mcp-stdio":
				// The same optional port, and a port an earlier `--mcp` named is
				// kept, so the two flags compose in either order.
				relay_stdio = true;
				if (port == 0) port = DEFAULT_MCP_PORT;
				if (i + 1 < args.len)
				{
					if (try given = args[i + 1].to_int())
					{
						port = given;
						i++;
					}
				}
			default:
				if (argument.len > 0 && argument[0] == '-')
				{
					io::eprintfn("rigsmith: unknown option: %s", argument);
					return 1;
				}
				if (mesh_path.len == 0) mesh_path = argument;
		}
	}

	// The stdio end of a crig that is already serving, which is what `.mcp.json`
	// names: no window, no device, no document. It forwards each message to the
	// port and answers the handshake — `initialize`, `tools/list` — itself, out
	// of the same tool table, so a client that launched before the window was
	// up sees a server that is there and complaining rather than one that
	// failed to start. Nothing here dereferences the app the table is built
	// over, which is why a zeroed one will do. See mcp/relay.c3 in three.
	if (relay_stdio)
	{
		three::ToolHost catalog_host = { };
		mcp::Server catalog = three::new_mcp_server(&catalog_host);
		install_tools(&app, &catalog);
		mcp::relay("127.0.0.1", port, &catalog);
		return 0;
	}

	// Before the config, the font or the library is read: a packaged build is
	// started from anywhere, and its assets are beside the executable — under
	// Contents/Resources in a macOS .app, usr/share/rigsmith in an AppImage.
	locate_bundle();
	// And the library goes where a person can find it: ~/Documents/Rigsmith.
	install_user_library();

	// Before anything compiles a shader. crig has no `shaders/` of its own — the
	// mesh pass and its shaders went to three with the executable — so the working
	// directory's override is turned off rather than left to find whatever a
	// checkout happens to contain. `shader/load.c3` is the trap it avoids.
	three::choose_caches({ .cache_dir_set = true, .cache_dir = "" });

	// On the heap: at 65 KB the engine is over c3c's stack object limit, the
	// same reason three's own `run` allocates it.
	three::Engine* machine = mem::new(three::Engine);
	defer mem::free(machine);
	defer machine.close();
	if (catch err = machine.open(width, height))
	{
		io::eprintfn("rigsmith: could not bring the engine up: %s", err);
		return 1;
	}
	engine = machine;

	three::Renderer* renderer = &machine.renderer;
	c3w::Window* window = machine.viewer();
	window.set_title("Rigsmith");
	// Opens filling the screen, unless a size was asked for on the command line.
	if (!size_given) window.maximize();

	// Empty until a file is read, which is the state crig runs in when it was
	// started with no path.
	rig::TriMesh geometry = {};
	if (mesh_path.len > 0)
	{
		rig::TriMesh? loaded = rig::load_gltf(mem, mesh_path);
		if (catch error = loaded)
		{
			io::eprintfn("rigsmith: could not load %s: %s", mesh_path, error);
			return 1;
		}
		geometry = loaded;
	}

	app = new_app(geometry, mesh_path);
	// Handed over rather than loaded inside `new_app`, so an AppState built
	// anywhere else carries a config with no file behind it and cannot read or
	// write the settings of whoever started it.
	app.config = load_config();
	app.restore_ui_memory();
	// The flag is a setting, not an override for one run: it lands in the config
	// and is written back out at shutdown like a size picked in the panel would
	// be. That is the whole use for it — a window whose interface is too small to
	// find the panel in is exactly the situation the flag exists for, and having
	// to pass it again every time would not have fixed anything.
	if (ui_scale > 0.0f) app.config.ui_scale = ui_scale;

	if (mesh_path.len > 0)
	{
		app.adopt_source_rig();
		app.remember_project(mesh_path);
	}

	// Before the tree, so the Assets view opens on a read library.
	app.scan_libraries();

	if (!mount_ui(renderer)) return 1;

	if (preset_name.len > 0)
	{
		if (!app.has_mesh())
		{
			io::eprintn("rigsmith: --preset needs a mesh to fit the plan to");
			return 1;
		}
		if (!app.apply_plan_named(preset_name))
		{
			io::eprintfn("rigsmith: unknown body plan '%s'", preset_name);
			return 1;
		}
	}

	// three's, and the only JavaScript engine in the process. It is what makes
	// `run_script` answer — crig's own QuickJS host went with the executable and
	// is not coming back, because this one is already here.
	three::JsRuntime runtime;
	if (catch err = runtime.open(&renderer.pass, renderer))
	{
		io::eprintfn("rigsmith: could not start the script runtime: %s", err);
		return 1;
	}
	defer runtime.close();
	runtime.window = window;
	// three's orbit, pan and zoom off: crig's `Viewport` widget owns the drag and
	// `sync_views` pushes the result. Two writers of one camera is jitter.
	runtime.controls.enabled = false;

	// Addressed by pointer from every tool, so it must not move while the server
	// lives — hence a local of the function that owns the loop.
	three::ToolHost tool_host = { .runtime = &runtime, .renderer = renderer };
	mcp::Server server = three::new_mcp_server(&tool_host);
	// After three's three, so a name crig takes cannot shadow one the engine uses.
	install_tools(&app, &server);

	// The readback hook `render` and crig's own `screenshot` call through. It was
	// null in every run before this — `AppState.screenshot`'s doc explains why:
	// nothing but the executable ever had a renderer to draw with, and back when
	// crig was a plugin the executable was three's, not crig's. crig is the
	// executable now and the renderer is right here, so this is where the hook
	// finally lands. Addressed by pointer for the loop's lifetime, the same reason
	// `tool_host` is a local of this function.
	ScreenshotHook screenshot_hook = { .app = &app, .renderer = renderer };
	app.screenshot = &grab_frame;
	app.screenshot_ctx = &screenshot_hook;
	// Text to motion runs its kernels on the window's device (app/generate.c3).
	app.motion_gpu = renderer;

	// The `crig` object a run_script body drives crig's tools through — bound onto
	// three's runtime, because three owns the only JavaScript engine in the process
	// now. See src/mcp/script.c3. Independent of whether a server came up: a script
	// arriving by any path gets the same surface.
	install_crig_script(&runtime, &app);

	// On by default, from the config's port, because most runs are a double-click
	// and never see a command line; `--mcp <port>` overrides it for this run
	// without touching the config. Settings rebinds it live (`run_loop`).
	mcp::Listener listener;
	serve_mcp(&listener, window, port > 0 ? port : app.config.mcp_port);
	defer listener.stop();

	int code = run_loop(renderer, window, &runtime, &server, &listener);

	// The tree first: its elements belong to three's Ui, which outlives this call,
	// and every widget in it borrows something from `app`.
	renderer.ui.set_root(null);
	workspace = null;
	app.config.save();
	app.free();
	return code;
}

<*
 What `grab_frame` reads back through: the document to draw and the renderer that
 draws it.

 A struct so the hook carries both without a second global, and a local of `run`
 so its lifetime is the server's — `AppState.screenshot_ctx` holds a borrow.
*>
struct ScreenshotHook @local
{
	AppState* app;
	three::Renderer* renderer;
}

<*
 One frame of the document as a PNG at `path`. Installed as `AppState.screenshot`.

 `sync_scene` first, because the only callers — `render` photographing a clip at
 an instant, a contact sheet — have just parked a pose or aimed a camera the last
 drawn frame does not show yet, and this runs between frames where nothing else
 will push it. Then `Renderer.screenshot`, three's offscreen path: it records the
 scene and reads it back with no window, no surface and no present, which is what
 lets a headless or backgrounded crig answer `render` at all. False the way the
 `ScreenshotFn` alias asks — no frame drawn, so no file written — when the
 readback faults.
*>
fn bool grab_frame(void* ctx, String path) @local
{
	ScreenshotHook* hook = ctx;
	sync_scene(hook.app);
	if (catch hook.renderer.screenshot(path)) return false;
	return true;
}

fn void usage() @local
{
	io::printn("Rigsmith — a joint-based rigger");
	io::printn();
	io::printn("  rigsmith [model.glb] [options]");
	io::printn();
	io::printn("  --preset <name>       fit a body plan: quadruped, biped or bird");
	io::printn("  --mcp [port]          serve MCP on this port for this run (default: Settings' port, 8808)");
	io::printn("  --mcp-stdio [port]    relay stdin/stdout to a Rigsmith that is already serving");
	io::printn("  --width <n>           the window's size in points");
	io::printn("  --height <n>          the same, vertically");
	io::printn("  --ui-scale <n>        how big the interface is drawn, 0.5 to 3 — remembered");
	io::printn("  --debug               validation layers and three's own log");
}

<*
 Points `bundle_root` at the packaged assets when the working directory has none.
*>
fn void locate_bundle() @local => @pool()
{
	String? beside = three::executable_dir(tmem);
	if (catch beside) return;
	choose_bundle_root({
		beside,
		string::tformat("%s/../Resources", beside),
		string::tformat("%s/../share/rigsmith", beside),
	});
}

<*
 Builds crig's workspace into three's Ui and hands it over.

 The font goes into the same Ui three already put DejaVu into, so crig's is a
 second face rather than a replacement — three's overlay goes on drawing with
 font 0 and crig's widgets name their own. A missing file is not fatal: the tree
 still builds and still works, it just draws with whatever the engine loaded.
*>
fn bool mount_ui(three::Renderer* renderer) @local
{
	Ui* ui = renderer.ui.context(&renderer.gpu, &renderer.target);
	if (ui == null)
	{
		io::eprintn("rigsmith: three would not bring its interface layer up");
		return false;
	}

	if (catch ui.load_font(bundled(FONT_PATH)))
	{
		io::eprintfn("rigsmith: could not open %s — falling back to the engine's font", bundled(FONT_PATH));
	}

	// Before the tree rather than after it: `set_scale` re-lays out whatever is
	// mounted, and there is nothing cheaper than laying the workspace out once at
	// the size it is going to be shown at. `run_loop` keeps it there — see
	// `ui/ui_scale.c3` for why that is a per-frame question and not a startup one.
	apply_ui_scale(&app);

	workspace = build_ui_tree(ui, &app);
	renderer.ui.set_root(workspace);
	// After the mount rather than as part of the build: the tree has no Ui root
	// above it until it has been grafted, and focus walks upward.
	focus_workspace(ui);
	return true;
}

<*
 One window, until it closes.

 `three::drive_window` is everything a frame of window *is* — the events, the
 pointer, the interface, the cursor shape and the keyboard a script sees — so it
 is called once here rather than reimplemented. What this loop adds is crig's
 own list, and the ordering note in the file header is the whole of why it is
 where it is.
*>
fn int run_loop(
	three::Renderer* renderer,
	c3w::Window* window,
	three::JsRuntime* runtime,
	mcp::Server* server,
	mcp::Listener* listener
) @local
{
	three::InputTracker keyboard;
	c3w::CursorShape shown;
	three::Hover hover;

	Clock since_start = clock::now();
	long last_frame_ns = 0;
	// Whether the last iteration left nothing to do, which is what lets the window
	// sleep in the kernel between gestures. Read at the top of the next iteration,
	// the only place the question can be asked.
	bool quiet = false;

	while (true)
	{
		three::WindowFrame poll = three::drive_window(
			renderer,
			window,
			&runtime.controls,
			&keyboard,
			&shown,
			&hover,
			since_start,
			&last_frame_ns,
			quiet,
			&runtime.pointer
		);
		if (poll.closed) break;

		// A widget handler that asked for a new tree was held while cui was walking
		// the old one. This is the first moment it is not.
		runtime.flush_ui();

		// Settings changed the port. Between frames, like an open, so no request is
		// mid-answer when the old socket goes.
		if (app.mcp_restart_wanted)
		{
			app.mcp_restart_wanted = false;
			serve_mcp(listener, window, app.config.mcp_port);
		}

		// Answers nothing, cheaply, when nothing is listening.
		usz handled = listener.pump(server);
		if (runtime.quit_wanted) break;
		if (app.quit_requested) break;
		runtime.take_render_resize();

		long elapsed_ns = (long)since_start.to_now();
		runtime.tick((double)elapsed_ns / 1_000_000.0, poll.input);

		// File > Open model. Serviced between frames because it replaces the arrays
		// the picker and the scene are built from.
		if (app.pending_open.len > 0) service_open(&app);

		// A compare on all but the handful of frames where the display's density
		// actually changed under the window. `ui/ui_scale.c3` has the two cases
		// that makes this worth doing every iteration rather than once at startup.
		apply_ui_scale(&app);

		// Last, so a mesh opened this iteration reaches the device in the same one.
		sync_scene(&app);

		bool ui_idle = renderer.ui.idle();
		bool? presented = renderer.frame();
		if (catch err = presented)
		{
			io::eprintfn("rigsmith: the frame could not be presented: %s", err);
			return 1;
		}
		quiet = presented && !runtime.is_animating() && !runtime.is_simulating()
			&& !poll.camera_moved && handled == 0 && ui_idle;
	}
	return 0;
}

<*
 (Re)bind the MCP listener to `port`, or leave it closed for 0.

 A port that is taken is a notice rather than an exit: a second Rigsmith opened
 by double-click should still open, just without a server of its own. What came
 of it is left on the app for Settings to show.
*>
fn void serve_mcp(mcp::Listener* listener, c3w::Window* window, int port) @local
{
	listener.stop();
	app.mcp_serving_port = 0;
	app.mcp_port_busy = false;
	if (port <= 0) return;

	if (catch err = listener.start(port, wake: &three::wake_window, wake_ctx: window))
	{
		io::eprintfn("rigsmith: could not listen on %d: %s", port, err);
		app.mcp_port_busy = true;
		app.@notice("MCP: port %d is in use — another Rigsmith? Pick another in File › Settings", port);
		return;
	}
	app.mcp_serving_port = port;
	io::printfn("mcp: http://127.0.0.1:%d/mcp", port);
}

<*
 The mesh the interface asked for, into the document.

 A file that will not load leaves a notice and the model that was already there.
 Dropping a working rig because a second file was mistyped is the worse of the
 two outcomes.
*>
fn void service_open(AppState* self) @local
{
	String path = self.take_pending_open();
	defer path.free(mem);

	rig::TriMesh? loaded = rig::load_gltf(mem, path);
	if (catch error = loaded)
	{
		self.@notice("could not open %s: %s", base_name(path), error);
		self.refresh_ui();
		return;
	}

	self.load_mesh(loaded, path);
	// A model that loaded is a project whether or not the GPU takes it: the
	// document is real either way, and the recent list is how it is reached again.
	self.remember_project(path);
	self.refresh_ui();
}
