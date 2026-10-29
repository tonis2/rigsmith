<*
 The Capture pane: the capture's graph (`app/capture_graph.c3`) in cui's node
 editor. Finder file and Train finder make a joint finder, Reference picture
 the picture a video model (MiniMax, Seedance) animates, Video names what it
 made; Animate reads one video with one finder into a clip. Nodes are added
 from the menu (double-click, Space or Tab, or a wire dropped on nothing),
 wired by dragging, and run from their cards.

 One pipeline job runs at a time, shared with the Generate pane.
*>
module crig;
import cui;
import cui::widgets;
import std::io;
import std::math;
import std::math::vector;
import std::io::file;
import std::os::process;
import std::core::string;
import std::collections::list;

const String CAPTURE_PANEL_ID = "capture-panel";
const String CAPTURE_GRAPH_ID = "capture-graph";
const String CAPTURE_MENU_ID = "capture-menu";
const String CAPTURE_FINDER_ID = "capture-finder";
const String CAPTURE_POSES_ID = "capture-poses";
const String CAPTURE_TIME_ID = "capture-time";
const String CAPTURE_ACTION_ID = "capture-action";
const String CAPTURE_VIDEO_ID = "capture-video";
const String CAPTURE_NAME_ID = "capture-name";
const String CAPTURE_POSE_ID = "capture-pose";
// The pose chooser's first row: the rig's rest pose rather than a clip.
const String CAPTURE_REST = "<rest>";
// A card's body, inside its padding.
const float CAPTURE_INNER = CAPTURE_NODE_W - 16;
const float CAPTURE_FIELD_TEXT = 11;

fn Element* build_capture_view(Ui* ui)
{
	return @subtree(ui)
	{
		@node((CapturePanel) { }).with_id(CAPTURE_PANEL_ID);
	};
}

fn void refresh_capture_view(Ui* ui)
{
	ui.@each_id(CAPTURE_PANEL_ID; panel)
	{
		panel.request_build();
	};
}

fn void open_capture_panel(Ui* ui) => show_pane_view(ui, CAPTURE_VIEW, SplitAxis.HORIZONTAL, 2.0f / 3.0f);

<*
 What decides the pane's shape: rebuilt when a control comes or goes, a step
 ends or the graph changes, never for a number.
*>
struct CaptureSnapshot
{
	bool has_file;
	bool configured;
	bool skeleton;
	bool running;
	CaptureStage stage;
	bool failed;
	uint finished;
	usz clips;
	uint graph;
}

fn CaptureSnapshot capture_snapshot(AppState* app) @private
{
	usz clips;
	foreach (pack : app.packs) clips += pack.clips.len;
	return {
		.has_file = app.source_path.len > 0,
		.configured = app.config.motion_generator.creature_model.len > 0,
		.skeleton = app.doc.dots.len() > 0 && app.has_mesh(),
		.running = app.capture_job.running,
		.stage = app.capture_job.stage,
		.failed = app.capture_job.failed && !app.capture_job.running,
		.finished = app.capture_job.finished,
		.clips = clips,
		.graph = app.capture_graph_now().version,
	};
}

fn bool CaptureSnapshot.differs(self, CaptureSnapshot other)
{
	return self.has_file != other.has_file || self.configured != other.configured || self.skeleton != other.skeleton
		|| self.running != other.running || self.stage != other.stage || self.failed != other.failed
		|| self.finished != other.finished || self.clips != other.clips || self.graph != other.graph;
}

struct CapturePanel (Widget)
{
	CaptureSnapshot shown;
	// The cards' status lines, which their labels point at until the next build.
	List{String} held;
}

fn String CapturePanel.hold(&self, String text)
{
	String kept = text.copy(mem);
	self.held.push(kept);
	return kept;
}

fn void CapturePanel.release(&self)
{
	foreach (text : self.held) text.free(mem);
	self.held.clear();
}

fn void CapturePanel.unmount(&self, Element* elem) @dynamic
{
	self.release();
	self.held.free();
}

fn Vec2 CapturePanel.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	if (elem.children.len() == 0) return constraints.constrain({ 0, 0 });
	elem.layout_child(0, cui::tight(constraints.max));
	elem.place_child(0, { 0, 0 });
	return constraints.max;
}

fn void CapturePanel.update(&self, Element* elem, float dt) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	CaptureSnapshot now = capture_snapshot(app);
	if (now.differs(self.shown))
	{
		self.shown = now;
		elem.request_build();
		return;
	}
	// The running card's bar.
	if (app.capture_graph.running < 0) return;
	app.capture_graph.update_flags(app);
	if (try Element* graph = elem.find_id(CAPTURE_GRAPH_ID)) graph.widget_as(NodeGraph).repaint(graph);
}

fn Element* CapturePanel.build(&self, Element* elem) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	self.release();
	self.shown = capture_snapshot(app);
	if (!self.shown.has_file || !self.shown.skeleton)
	{
		String why = !self.shown.has_file ? "Open or save the model as a .glb first: the capture's files go in a folder beside it."
			: "This model has no skinned skeleton yet. Rig it first; the clip is put on the rig.";
		return @subtree(elem.ui)
		{
			@tree((Padding) { .insets = widgets::insets_all(ANIM_PAD) })
			{
				@node((GenerateNote) { .text = why, .size = ANIM_TEXT_SIZE, .color = ACCENT });
			};
		};
	}

	CaptureGraph* g = app.capture_graph_now();
	g.rebuild_view(app);
	// Read when the pane is built, not each frame: Settings rebuilds it.
	String unfit = app.llm_plugin_problem("creature");
	Element* body = @subtree(elem.ui)
	{
		@tree((Stack) { })
		{
			@tree((NodeGraph) {
				.nodes = g.shown_nodes.array_view(),
				.ports = g.shown_ports.array_view(),
				.wires = g.shown_wires.array_view(),
				.view = g.view,
				.on_select = &capture_select,
				.on_box = &capture_box,
				.on_move = &capture_move,
				.can_connect = &capture_can_connect,
				.on_connect = &capture_connect,
				.on_disconnect = &capture_disconnect,
				.on_wire_select = &capture_wire_select,
				.on_wire_dropped = &capture_wire_dropped,
				.on_context = &capture_context,
				.on_command = &capture_command,
				.on_add_request = &capture_add_request,
				.on_view = &capture_view_moved,
			})
			{
				for (usz i = 0; i < g.count(); i++)
				{
					@tree((NodeCard) { .node = i })
					{
						self.card_body(app, g, i);
					};
				}
			}.with_id(CAPTURE_GRAPH_ID);
			if (!self.shown.configured || unfit.len > 0)
			{
				@tree((Anchored) { .h = START, .v = START, .margin = { 10, 10 } })
				{
					@tree((Column) { .gap = 4, .size = { 360, 0 } })
					{
						if (!self.shown.configured)
						{
							@node((GenerateNote) { .text = "Training and reading need the DINOv3 backbone: choose SAM 3D Body's model.ckpt in File › Settings › AI › Video capture.",
								.size = 12, .color = ACCENT });
							@node(accent_button("Open AI settings", &open_ai_settings)).with_id("capture-open-settings");
						}
						if (unfit.len > 0)
						{
							@node((GenerateNote) { .text = self.hold(string::tformat("The creature plugin cannot run: %s. Choose the plugins folder, or link creature into it, under File › Settings › AI › Plugins.", unfit)),
								.size = 12, .color = ACCENT });
							@node(accent_button("Plugins…", &open_ai_settings)).with_id("capture-open-plugins");
						}
					};
				};
			}
			@node((ContextMenu) { .items = capture_menu_items[:capture_menu_len], .searchable = true, .placeholder = "Add a node",
				.style = MENU_STYLE, .on_choose = &capture_menu_chosen }).with_id(CAPTURE_MENU_ID);
		};
	};

	// The fields show their nodes' settings.
	Element* graph = body.find_id(CAPTURE_GRAPH_ID)!!;
	foreach (card : graph.children)
	{
		if (!card.is_widget(NodeCard)) continue;
		CaptureNode* n = g.at(card.widget_as(NodeCard).node);
		foreach (pair : (String[2][]){ { CAPTURE_FINDER_ID, "0" }, { CAPTURE_POSES_ID, "0" }, { CAPTURE_TIME_ID, "1" },
			{ CAPTURE_ACTION_ID, "2" }, { CAPTURE_VIDEO_ID, "0" }, { CAPTURE_NAME_ID, "0" } })
		{
			if (try Element* field = card.find_id(pair[0])) field.widget_as(TextField).set_text(field, n.params[pair[1][0] - '0']);
		}
	}
	return body;
}

<*
 A card's body: its settings, its icons and one status line. Whatever is
 running shows Stop and the step's live status instead of its Run.
*>
fn void CapturePanel.card_body(&self, AppState* app, CaptureGraph* g, usz i)
{
	CaptureNode* n = g.at(i);
	bool running = g.running == (sz)i;
	bool ready = app.capture_node_ready(i);
	@tree((Column) { .gap = 4 })
	{
		switch (n.kind)
		{
			case FINDER_FILE:
				@tree((Row) { .gap = 4, .cross_align = CENTER })
				{
					@node((TextField) { .width = CAPTURE_INNER - TOOL_CELL_W - 4, .style = TEXT_FIELD_STYLE, .placeholder = "a .safetensors trained before",
						.on_change = &capture_param0_changed }).with_id(CAPTURE_FINDER_ID);
					@card_icon(BROWSE_GLYPH, "Choose a finder — one trained before, for this character or one like it", &capture_browse_finder_clicked);
				};
				String finder = app.capture_node_finder(n);
				String summary = finder_summary(finder);
				self.status(summary.len > 0 ? summary : finder.len == 0 ? "No finder chosen" : ready ? "A joint finder" : "Not there", ready);
			case TRAIN:
				@tree((Row) { .gap = 4, .cross_align = CENTER })
				{
					@node((Label) { .text = "Poses", .size = CAPTURE_FIELD_TEXT, .color = TEXT_DIM });
					@node((TextField) { .width = 60, .style = TEXT_FIELD_STYLE, .on_change = &capture_param0_changed }).with_id(CAPTURE_POSES_ID);
					self.run_icon(running, "Train — draws the character in this many poses from the front and both sides, then teaches the finder where its joints are: about half an hour. A stopped run carries on.", "capture-train");
				};
				if (!running) self.status(ready ? finder_summary(app.capture_node_finder(n)) : "Not trained yet", ready);
			case REFERENCE:
				@tree((Row) { .gap = 4, .cross_align = CENTER })
				{
					@node((CapturePoseChooser) { .node = i });
					@node((TextField) { .width = 36, .style = TEXT_FIELD_STYLE, .on_change = &capture_param1_changed }).with_id(CAPTURE_TIME_ID);
					@node((Label) { .text = "s", .size = CAPTURE_FIELD_TEXT, .color = TEXT_DIM });
				};
				@node((TextField) { .width = CAPTURE_INNER, .style = TEXT_FIELD_STYLE, .placeholder = "the action: waves with his left hand",
					.on_change = &capture_param2_changed }).with_id(CAPTURE_ACTION_ID);
				@tree((Row) { .gap = 4, .cross_align = CENTER })
				{
					self.run_icon(running, "Make reference — the pose from the front and its right side in one picture, for the video model to animate", "capture-reference");
					if (ready)
					{
						@card_icon(COPY_GLYPH, "Copy prompt — give the video model reference.png as the first frame and this prompt, the action filled in. Keep it standing in place.", &capture_copy_prompt_clicked).with_id("capture-copy-prompt");
						@card_icon(FOLDER_GLYPH, "Open folder — where reference.png is", &capture_open_folder_clicked).with_id("capture-open-folder");
					}
				};
				if (!running) self.status(ready ? "reference.png drawn" : "No picture yet", ready);
			case VIDEO:
				@tree((Row) { .gap = 4, .cross_align = CENTER })
				{
					@node((TextField) { .width = CAPTURE_INNER - TOOL_CELL_W - 4, .style = TEXT_FIELD_STYLE, .placeholder = "the clip, or a folder of its frames",
						.on_change = &capture_param0_changed }).with_id(CAPTURE_VIDEO_ID);
					@card_icon(BROWSE_GLYPH, "Choose video — the clip the video model made, or a folder of its frames", &capture_browse_video_clicked);
				};
				if (n.params[0].trim().len > 0 && !ready) self.status("Not there", false);
			case ANIMATE:
				@tree((Row) { .gap = 4, .cross_align = CENTER })
				{
					@node((TextField) { .width = CAPTURE_INNER - TOOL_CELL_W - 4, .style = TEXT_FIELD_STYLE, .placeholder = self.hold(g.clip_name(i)),
						.on_change = &capture_param0_changed }).with_id(CAPTURE_NAME_ID);
					self.run_icon(running, "Animate — reads the video into a clip on the character, with the finder and the picture's layout", "capture-animate");
				};
				if (!running && g.failed != (sz)i) self.status(ready ? "On the character" : "", ready);
		}
		if (running)
		{
			@node((LiveLabel) { .text_of = &capture_status_text, .size = { CAPTURE_INNER, 16 }, .text_size = CAPTURE_FIELD_TEXT, .color = TEXT_DIM });
		}
		else if (g.failed == (sz)i)
		{
			@node((GenerateNote) { .text = self.hold(app.capture_job.last()), .size = CAPTURE_FIELD_TEXT, .color = DOT_LOCKED });
		}
	};
}

fn void CapturePanel.status(&self, String text, bool lit)
{
	if (text.len == 0) return;
	@node((GenerateNote) { .text = self.hold(text), .size = CAPTURE_FIELD_TEXT, .color = lit ? TEXT : TEXT_DIM });
}

fn void CapturePanel.run_icon(&self, bool running, String tip, String id)
{
	if (running)
	{
		@card_icon(STOP_GLYPH, "Stop — a stopped training set carries on where it stopped", &capture_stop_clicked).with_id("capture-stop");
		return;
	}
	@card_icon(RUN_GLYPH, tip, &capture_run_clicked, COMMIT).with_id(id);
}

// ---------------------------------------------------------------------------
// Which card a control is on: the one under the pointer for a click, the one
// with the keyboard for typing.

fn sz card_above(Element* start) @private
{
	for (Element* e = start; e; e = e.parent)
	{
		if (e.is_widget(NodeCard)) return (sz)e.widget_as(NodeCard).node;
	}
	return -1;
}

fn sz capture_card_clicked(Ui* ui) @private
{
	sz node = card_above(ui.hovered);
	return node >= 0 ? node : card_above(ui.focused);
}

fn sz capture_card_typed(Ui* ui) @private
{
	sz node = card_above(ui.focused);
	return node >= 0 ? node : card_above(ui.hovered);
}

fn void capture_param_typed(Ui* ui, usz slot, String text) @private
{
	CaptureGraph* g = &ui.inherit(AppState)!!.capture_graph;
	sz node = capture_card_typed(ui);
	if (node < 0 || (usz)node >= g.count()) return;
	g.set_param((usz)node, slot, text);
	g.save();
}

fn void capture_param0_changed(Ui* ui, String text) @private => capture_param_typed(ui, 0, text);
fn void capture_param1_changed(Ui* ui, String text) @private => capture_param_typed(ui, 1, text);
fn void capture_param2_changed(Ui* ui, String text) @private => capture_param_typed(ui, 2, text);

// ---------------------------------------------------------------------------
// The editor's gestures.

fn void capture_select(Ui* ui, sz node, SelectMode mode) @private
{
	AppState* app = ui.inherit(AppState)!!;
	CaptureGraph* g = &app.capture_graph;
	if (mode == SelectMode.REPLACE)
	{
		foreach (&n : g.nodes) n.selected = false;
		g.wire_node = -1;
	}
	if (node >= 0) g.at(node).selected = mode == SelectMode.TOGGLE ? !g.at(node).selected : true;
	g.update_flags(app);
}

fn void capture_box(Ui* ui, usz[] hit, SelectMode mode) @private
{
	AppState* app = ui.inherit(AppState)!!;
	CaptureGraph* g = &app.capture_graph;
	if (mode == SelectMode.REPLACE) foreach (&n : g.nodes) n.selected = false;
	foreach (i : hit) g.at(i).selected = mode == SelectMode.TOGGLE ? !g.at(i).selected : true;
	g.update_flags(app);
}

fn void capture_move(Ui* ui, Vec2 delta, bool done) @private
{
	AppState* app = ui.inherit(AppState)!!;
	CaptureGraph* g = &app.capture_graph;
	foreach (&n : g.nodes)
	{
		if (!n.selected) continue;
		n.pos += delta;
		if (done) n.pos = { math::round(n.pos.x), math::round(n.pos.y) };
	}
	g.update_flags(app);
	if (done) g.save();
}

fn void capture_view_moved(Ui* ui, View2D view) @private => ui.inherit(AppState)!!.capture_graph.view = view;

fn bool capture_can_connect(Ui* ui, usz from, usz to) @private
{
	CaptureGraph* g = &ui.inherit(AppState)!!.capture_graph;
	if (from >= g.ports().len || to >= g.ports().len) return false;
	CapturePort a = g.ports()[from];
	CapturePort b = g.ports()[to];
	if (a.input >= 0 || b.input < 0 || a.node == b.node) return false;
	CaptureLink made;
	return capture_output(g.at(a.node).kind, &made) && made == CAPTURE_INPUT_LINKS[b.input];
}

<*
 The wires changed but no card did: the editor's tables remade in place, so a
 wire being dragged off an input carries on.
*>
fn void capture_wires_changed(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	CaptureGraph* g = &app.capture_graph;
	g.rebuild_view(app);
	g.save();
	Element*? graph = ui.find_id(CAPTURE_GRAPH_ID);
	if (catch graph) return;
	NodeGraph* editor = graph.widget_as(NodeGraph);
	editor.nodes = g.shown_nodes.array_view();
	editor.ports = g.shown_ports.array_view();
	editor.wires = g.shown_wires.array_view();
	editor.refresh(graph);
}

fn void capture_connect(Ui* ui, usz from, usz to) @private
{
	CaptureGraph* g = &ui.inherit(AppState)!!.capture_graph;
	if (!g.connect(g.ports()[from].node, g.ports()[to].node, (usz)g.ports()[to].input)) return;
	capture_wires_changed(ui);
}

fn void capture_disconnect(Ui* ui, usz wire) @private
{
	CaptureGraph* g = &ui.inherit(AppState)!!.capture_graph;
	if (wire >= g.wires().len) return;
	g.disconnect(g.wires()[wire].node, g.wires()[wire].input);
	capture_wires_changed(ui);
}

fn void capture_wire_select(Ui* ui, usz wire, SelectMode mode) @private
{
	AppState* app = ui.inherit(AppState)!!;
	CaptureGraph* g = &app.capture_graph;
	if (wire >= g.wires().len) return;
	foreach (&n : g.nodes) n.selected = false;
	g.wire_node = (sz)g.wires()[wire].node;
	g.wire_input = g.wires()[wire].input;
	g.update_flags(app);
}

fn void capture_command(Ui* ui, GraphCommand command) @private
{
	AppState* app = ui.inherit(AppState)!!;
	CaptureGraph* g = &app.capture_graph;
	switch (command)
	{
		case DELETE:
			capture_delete_selection(ui);
		case DUPLICATE:
			capture_duplicate_selection(ui);
		case SELECT_ALL:
			foreach (&n : g.nodes) n.selected = true;
			g.wire_node = -1;
			g.update_flags(app);
		default:
			break;
	}
}

fn void capture_delete_selection(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	CaptureGraph* g = &app.capture_graph;
	if (g.wire_node >= 0)
	{
		g.disconnect((usz)g.wire_node, g.wire_input);
		capture_wires_changed(ui);
		return;
	}
	bool picked;
	foreach (n : g.nodes) picked |= n.selected;
	if (!picked) return;
	if (g.busy())
	{
		app.@notice("Stop the capture first: its nodes are running");
		return;
	}
	for (usz i = g.count(); i > 0; i--)
	{
		if (g.at(i - 1).selected) g.remove(i - 1);
	}
	g.failed = -1;
	g.changed();
}

fn void capture_duplicate_selection(Ui* ui) @private
{
	CaptureGraph* g = &ui.inherit(AppState)!!.capture_graph;
	usz count = g.count();
	for (usz i = 0; i < count; i++)
	{
		if (!g.at(i).selected) continue;
		g.at(i).selected = false;
		usz copy = g.duplicate(i);
		g.at(copy).selected = true;
	}
	g.changed();
}

// ---------------------------------------------------------------------------
// The menus: nodes to add, and what a node can do.

enum CaptureMenu : char
{
	ADD,
	NODE,
}

const String[3] CAPTURE_NODE_ACTIONS = { "Run up to here", "Duplicate", "Delete" };

CaptureMenu capture_menu;
ContextMenuItem[5] capture_menu_items;
CaptureNodeKind[5] capture_menu_kinds;
usz capture_menu_len;
Vec2 capture_menu_plane;
// The port a dropped wire hangs from, for the added node to take.
bool capture_menu_wired;
usz capture_menu_port;
// The node a node menu is for, and the node a file chooser fills.
usz capture_menu_node;
sz capture_pick_node = -1;

fn void open_capture_menu(Ui* ui, Vec2 screen) @private
{
	Element*? menu = ui.find_id(CAPTURE_MENU_ID);
	if (catch menu) return;
	ContextMenu* shown = menu.widget_as(ContextMenu);
	shown.items = capture_menu_items[:capture_menu_len];
	shown.searchable = capture_menu == ADD;
	shown.open_at(menu, screen);
}

<*
 The add menu at a point: every kind, or with a wire dropped from `port`, the
 kinds that would take it.
*>
fn void open_capture_add_menu(Ui* ui, Vec2 plane, Vec2 screen, sz port = -1) @private
{
	CaptureGraph* g = &ui.inherit(AppState)!!.capture_graph;
	capture_menu = ADD;
	capture_menu_plane = plane;
	capture_menu_wired = port >= 0 && (usz)port < g.ports().len;
	capture_menu_port = capture_menu_wired ? (usz)port : 0;
	capture_menu_len = 0;
	foreach (k, title : CAPTURE_TITLES)
	{
		CaptureNodeKind kind = (CaptureNodeKind)(int)k;
		if (capture_menu_wired && capture_dropped_slot(g, kind) < 0) continue;
		capture_menu_kinds[capture_menu_len] = kind;
		capture_menu_items[capture_menu_len++] = { .label = title, .category = "Capture" };
	}
	if (capture_menu_len > 0) open_capture_menu(ui, screen);
}

<*
 Where a node of `kind` takes the dropped wire: the input slot it goes into
 (or 0 for its output, when the wire hangs from an input); -1 = it cannot.
*>
fn sz capture_dropped_slot(CaptureGraph* g, CaptureNodeKind kind) @private
{
	CapturePort from = g.ports()[capture_menu_port];
	CaptureLink made;
	if (from.input >= 0) return capture_output(kind, &made) && made == CAPTURE_INPUT_LINKS[from.input] ? 0 : -1;
	if (!capture_output(g.at(from.node).kind, &made)) return -1;
	for (usz k = 0; k < capture_inputs(kind); k++) if (CAPTURE_INPUT_LINKS[k] == made) return (sz)k;
	return -1;
}

fn void capture_add_request(Ui* ui, Vec2 plane, Vec2 screen) @private => open_capture_add_menu(ui, plane, screen);
fn void capture_wire_dropped(Ui* ui, usz port, Vec2 plane, Vec2 screen) @private => open_capture_add_menu(ui, plane, screen, (sz)port);

fn void capture_context(Ui* ui, GraphTarget target, sz index, Vec2 plane, Vec2 screen) @private
{
	CaptureGraph* g = &ui.inherit(AppState)!!.capture_graph;
	switch (target)
	{
		case NODE:
			if (!g.at(index).selected) capture_select(ui, index, REPLACE);
			capture_menu = NODE;
			capture_menu_node = (usz)index;
			capture_menu_len = 0;
			foreach (action : CAPTURE_NODE_ACTIONS) capture_menu_items[capture_menu_len++] = { .label = action };
			open_capture_menu(ui, screen);
		case WIRE:
			capture_wire_select(ui, (usz)index, REPLACE);
			capture_delete_selection(ui);
		default:
			open_capture_add_menu(ui, plane, screen);
	}
}

fn void capture_menu_chosen(Ui* ui, usz index) @private
{
	AppState* app = ui.inherit(AppState)!!;
	CaptureGraph* g = &app.capture_graph;
	if (capture_menu == NODE)
	{
		if (capture_menu_node >= g.count()) return;
		switch (index)
		{
			case 0: capture_run(app, capture_menu_node);
			case 1: capture_duplicate_selection(ui);
			case 2: capture_delete_selection(ui);
		}
		return;
	}
	if (index >= capture_menu_len) return;
	CaptureNodeKind kind = capture_menu_kinds[index];
	sz slot = capture_menu_wired ? capture_dropped_slot(g, kind) : -1;
	usz added = g.add(kind, capture_menu_plane);
	if (slot >= 0)
	{
		CapturePort from = g.ports()[capture_menu_port];
		if (from.input >= 0)
		{
			(void)g.connect(added, from.node, (usz)from.input);
		}
		else
		{
			(void)g.connect(from.node, added, (usz)slot);
		}
	}
	foreach (&n : g.nodes) n.selected = false;
	g.at(added).selected = true;
	g.changed();
}

// ---------------------------------------------------------------------------
// The cards' icons.

fn void capture_run(AppState* app, usz node) @private
{
	if (catch err = app.run_capture_node(node)) app.@notice("Could not run %s: %s", app.capture_graph.at(node).id, capture_fault_text(err));
}

fn void capture_run_clicked(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	sz node = capture_card_clicked(ui);
	if (node >= 0 && (usz)node < app.capture_graph.count()) capture_run(app, (usz)node);
}

fn void capture_stop_clicked(Ui* ui) @private
{
	ui.inherit(AppState)!!.stop_capture();
	refresh_capture_view(ui);
}

fn void capture_browse_finder_clicked(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	capture_pick_node = capture_card_clicked(ui);
	if (capture_pick_node < 0) return;
	String finder = app.capture_graph.at(capture_pick_node).params[0];
	if (try slash = finder.rindex_of_char('/')) app.remember_directory(finder[:(usz)slash]);
	open_file_dialog(ui, FilePurpose.CAPTURE_FINDER);
}

fn void capture_browse_video_clicked(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	capture_pick_node = capture_card_clicked(ui);
	if (capture_pick_node < 0) return;
	String video = app.capture_graph.at(capture_pick_node).params[0].trim();
	if (try slash = video.rindex_of_char('/')) app.remember_directory(video[:(usz)slash]);
	open_file_dialog(ui, FilePurpose.CAPTURE_VIDEO);
}

// A chosen file into the node whose chooser it was.
fn void capture_file_chosen(Ui* ui, CaptureNodeKind kind, String path) @private
{
	CaptureGraph* g = &ui.inherit(AppState)!!.capture_graph;
	if (capture_pick_node < 0 || (usz)capture_pick_node >= g.count() || g.at(capture_pick_node).kind != kind) return;
	g.set_param((usz)capture_pick_node, 0, path);
	g.changed();
}

fn void set_capture_video(Ui* ui, String video) => capture_file_chosen(ui, VIDEO, video);

fn void use_capture_finder_chosen(Ui* ui, String finder)
{
	capture_file_chosen(ui, FINDER_FILE, finder);
	ui.inherit(AppState)!!.@notice("Using the joint finder %s", base_name(finder));
}

fn void capture_copy_prompt_clicked(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	sz node = capture_card_clicked(ui);
	if (node < 0) return;
	String action = app.capture_graph.at(node).params[2];
	ui.clipboard_write(capture_prompt(action));
	app.@notice(action.trim().len > 0 ? "Prompt copied, with the action filled in" : "Prompt copied · fill in the action where it says <describe the movement here>");
}

fn void capture_open_folder_clicked(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	sz node = capture_card_clicked(ui);
	if (node < 0) return;
	String folder = app.capture_node_path(app.capture_graph.at(node), "studio");
	$if env::DARWIN:
		String opener = "open";
	$else
		String opener = "xdg-open";
	$endif
	Process? shown = process::spawn({ opener, folder });
	if (catch shown) { app.@notice("Could not open %s", folder); return; }
	(void)shown.destroy();
}

fn String capture_status_text(Element* elem) @private
{
	CaptureJob* job = &elem.inherit(AppState)!!.capture_job;
	if (!job.running) return "".copy(mem);
	switch (job.stage)
	{
		case RENDERING: return string::format(mem, "Pose %d of %d", job.step, job.steps);
		case EXTRACTING: return job.steps > 0 ? string::format(mem, "Frame %d of %d", job.step, job.steps) : string::format(mem, "%d frames", job.step);
		default: return job.last().copy(mem);
	}
}

// ---------------------------------------------------------------------------
// The reference picture's pose: the rest pose, or a clip that plays on the rig.

// The clips a pose can come from, in the chooser's order; row 0 is the rest pose.
macro @each_capture_pose(AppState* app; @body(String label, String clip))
{
	@body("Rest pose", CAPTURE_REST);
	foreach (usz p, &pack : app.packs)
	{
		foreach (usz c, &clip : pack.clips)
		{
			if (!app.clip_applies({ (int)p, (int)c })) continue;
			@body(string::tformat("%s / %s", pack.name, clip.name), string::tformat("%s/%s", pack.name, clip.name));
		}
	}
}

<*
 A Reference node's pose dropdown. Owns its labels. With nothing chosen yet it
 picks the first clip that sounds like standing (an idle), which starts a video
 best.
*>
struct CapturePoseChooser (Widget)
{
	usz node;
	String[] labels;
}

fn void CapturePoseChooser.release(&self)
{
	foreach (label : self.labels) label.free(mem);
	if (self.labels.len > 0) alloc::free(mem, self.labels);
	self.labels = {};
}

fn void CapturePoseChooser.unmount(&self, Element* elem) @dynamic => self.release();

fn Element* CapturePoseChooser.build(&self, Element* elem) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	CaptureGraph* g = &app.capture_graph;
	self.release();
	usz count;
	@each_capture_pose(app; String label, String clip) { count++; };
	self.labels = alloc::new_array(mem, String, (sz)count);
	String chosen = g.at(self.node).params[0];
	usz row;
	usz selected;
	usz idle;
	@each_capture_pose(app; String label, String clip)
	{
		self.labels[row] = label.copy(mem);
		String lower = clip.to_lower_tcopy();
		if (idle == 0 && row > 0 && (lower.contains("idle") || lower.contains("stand"))) idle = row;
		if (clip == chosen) selected = row;
		row++;
	};
	if (chosen.len == 0)
	{
		selected = idle;
		g.set_param(self.node, 0, capture_pose_clip(app, idle));
	}
	return @subtree(elem.ui)
	{
		@node((Select) { .options = self.labels, .selected = selected, .width = CAPTURE_INNER - 56, .style = VIEW_MENU_STYLE,
			.searchable = self.labels.len > ANIM_CHOOSER_SEARCH_MIN, .on_change = &capture_pose_chosen }).with_id(CAPTURE_POSE_ID);
	};
}

fn Vec2 CapturePoseChooser.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	Vec2 own = elem.layout_child(0, constraints);
	elem.place_child(0, { 0, 0 });
	return own;
}

// The clip of the chooser's row `row`. Temporary.
fn String capture_pose_clip(AppState* app, usz row) @private
{
	usz at;
	String found = CAPTURE_REST;
	@each_capture_pose(app; String label, String clip)
	{
		if (at++ == row) found = clip;
	};
	return found;
}

fn void capture_pose_chosen(Ui* ui, usz row) @private
{
	AppState* app = ui.inherit(AppState)!!;
	sz node = capture_card_clicked(ui);
	if (node < 0 || (usz)node >= app.capture_graph.count()) return;
	app.capture_graph.set_param((usz)node, 0, capture_pose_clip(app, row));
	app.capture_graph.save();
}
