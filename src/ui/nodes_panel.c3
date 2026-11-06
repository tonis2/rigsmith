<*
 The Nodes pane: text to motion and video capture as graphs
 (`app/pipeline_graph.c3`) in cui's node editor, one per template, picked in
 the bar on top. Model nodes hold the weights, Prompt and Guide poses feed Text
 to motion; Finder file, Train finder and a Video or Image feed Animate. Reference
 file picks the reference it reads through (they are drawn from the Animations
 menu). Nodes are added from the menu (double-click, Space or Tab, or a wire
 dropped on nothing), wired by dragging, and run from their cards.

 One pipeline job runs at a time; the MCP tools share it.
*>
module crig;
import cui;
import cui::widgets;
import std::io;
import std::math;
import std::math::vector;
import std::io::file;
import std::io::path;
import std::os::process;
import std::core::string;
import std::collections::list;
import std::time::clock;

const String NODES_PANEL_ID = "nodes-panel";
const String NODES_GRAPH_ID = "nodes-graph";
const String NODES_MENU_ID = "nodes-menu";
const String NODES_TEMPLATE_ID = "nodes-template";
const String NODES_RESET_ID = "nodes-reset";
// A card's text field for each setting slot.
const String[NODE_PARAMS] NODE_FIELD_IDS = { "node-param-0", "node-param-1", "node-param-2", "node-param-3", "node-param-4" };
const String NODE_GUIDE_ID = "node-guide";
const String NODE_OPTIMIZE_ID = "node-optimize";
const String NODE_SIZE_ID = "node-size";
const String NODE_MIRROR_ID = "node-mirror";
const String NODE_SOURCE_ID = "node-source";
// The pose chooser's first row: the rig's rest pose rather than a clip.
// A card's body, inside its padding.
const float NODE_INNER = NODE_W - 16;
const float NODE_TEXT = 11;
const float NODE_PROMPT_H = 56;
const float NODES_BAR_H = 30;
// A note card's text field, roughly how many characters fit a line of it, a line's
// height and the field's padding top and bottom.
const float NOTE_INNER = NOTE_W - 16;
const usz NOTE_LINE_CHARS = 30;
const float NOTE_LINE_H = 19;
const float NOTE_PADDING = 12;

// By `KeyReduction` ordinal.
String[3] generate_optimize_levels = { "Off", "Light", "Strong" };
String[CAPTURE_SIZES.len] train_size_names = { "448 px", "512 px", "640 px", "768 px", "896 px", "1024 px" };
String[2] node_source_names = { "Video", "Image" };
// The bar's choices; a Select borrows its options, so not the const itself.
String[TEMPLATES] nodes_template_names = TEMPLATE_NAMES;

// Set by the routes that open the pane for typing (View › Nodes);
// the pane puts the caret in a prompt on its next update.
bool nodes_focus_prompt;

fn Element* build_nodes_view(Ui* ui)
{
	return @subtree(ui)
	{
		@node((NodesPanel) { }).with_id(NODES_PANEL_ID);
	};
}

// Every pane showing it: the workspace can be split so two do.
fn void refresh_nodes_view(Ui* ui)
{
	ui.@each_id(NODES_PANEL_ID; panel)
	{
		panel.request_build();
	};
}

<*
 Bring the Nodes pane on screen; with `prompt`, the caret in the first Prompt
 node's text.
*>
fn void open_nodes_panel(Ui* ui, bool prompt = false)
{
	show_pane_view(ui, NODES_VIEW, SplitAxis.HORIZONTAL, 2.0f / 3.0f);
	nodes_focus_prompt = prompt;
}

<*
 What decides the pane's shape: rebuilt when a control comes or goes, a step
 ends or the graph changes, never for a number.
*>
struct NodesSnapshot
{
	bool has_file;
	bool skeleton;
	bool generating;
	bool capturing;
	CaptureStage stage;
	uint finished;
	usz clips;
	sz bound;
	usz template;
	uint graph;
}

fn NodesSnapshot nodes_snapshot(AppState* app) @private
{
	usz clips;
	foreach (pack : app.packs) clips += pack.clips.len;
	return {
		.has_file = app.source_path.len > 0,
		.skeleton = app.doc.dots.len() > 0,
		.generating = app.motion_job.running,
		.capturing = app.capture_job.running,
		.stage = app.capture_job.stage,
		.finished = app.capture_job.finished,
		.clips = clips,
		.bound = app.doc.animations.len(),
		.template = app.open_template,
		.graph = app.pipeline().version,
	};
}

struct NodesPanel (Widget)
{
	NodesSnapshot shown;
	// The cards' status lines, which their labels point at until the next build.
	List{String} held;
}

fn String NodesPanel.hold(&self, String text)
{
	// On the heap by name: an uninitialised List would take temp memory.
	if (!self.held.allocator) self.held.init(mem);
	String kept = text.copy(mem);
	self.held.push(kept);
	return kept;
}

fn void NodesPanel.release(&self)
{
	foreach (text : self.held) text.free(mem);
	self.held.clear();
}

fn void NodesPanel.unmount(&self, Element* elem) @dynamic
{
	self.release();
	self.held.free();
}

fn Vec2 NodesPanel.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	if (elem.children.len() == 0) return constraints.constrain({ 0, 0 });
	elem.layout_child(0, cui::tight(constraints.max));
	elem.place_child(0, { 0, 0 });
	return constraints.max;
}

fn void NodesPanel.update(&self, Element* elem, float dt) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	NodesSnapshot now = nodes_snapshot(app);
	if (fields_differ(now, self.shown))
	{
		self.shown = now;
		elem.request_build();
		return;
	}
	PipelineGraph* g = app.pipeline();
	Element*? graph = elem.find_id(NODES_GRAPH_ID);
	if (catch graph) return;
	// A graph fresh from its template, framed once its cards are laid out.
	if (g.unframed && graph.size.x > 0)
	{
		g.unframed = false;
		graph.widget_as(NodeGraph).frame(graph);
	}
	if (nodes_focus_prompt)
	{
		nodes_focus_prompt = false;
		foreach (card : graph.children)
		{
			if (!card.is_widget(NodeCard) || g.at(card.widget_as(NodeCard).node).kind != PROMPT) continue;
			if (try Element* field = card.find_id(NODE_FIELD_IDS[0]))
			{
				field.widget_as(TextField).select_all(field);
				field.request_focus();
			}
			break;
		}
	}
	// The running card's bar.
	if (g.running < 0) return;
	g.update_flags(app);
	graph.widget_as(NodeGraph).repaint(graph);
}

fn Element* NodesPanel.build(&self, Element* elem) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	self.release();
	self.shown = nodes_snapshot(app);
	PipelineGraph* g = app.pipeline();
	g.rebuild_view(app);
	// What the cards cannot say: read when the pane is built, Settings rebuilds it.
	bool generates;
	bool captures;
	foreach (&n : g.nodes)
	{
		generates |= n.kind == TEXT_TO_MOTION;
		captures |= n.kind == TRAIN || n.kind == ANIMATE;
	}
	String kimodo = generates ? app.llm_plugin_problem("kimodo") : "";
	String creature = captures ? app.llm_plugin_problem("creature") : "";
	Element* body = @subtree(elem.ui)
	{
		@tree((NodesBody) { })
		{
		@tree((Stack) { })
		{
			@node((Rectangle) { .style = { .color = PANEL } });
			@tree((Anchored) { .h = START, .v = CENTER, .margin = { 8, 0 } })
			{
				@tree((Row) { .gap = 6, .cross_align = CENTER })
				{
					small_label("Template");
					@node((Select) { .options = nodes_template_names[..], .selected = app.open_template, .width = 250,
						.style = VIEW_MENU_STYLE, .on_change = &nodes_template_chosen }).with_id(NODES_TEMPLATE_ID);
					@card_icon(RESET_GLYPH, "Reset — put this template's nodes back as they were; model paths stay", &nodes_reset_clicked).with_id(NODES_RESET_ID);
				};
			};
		};
		@tree((Stack) { })
		{
			@tree((NodeGraph) {
				.nodes = g.shown_nodes.array_view(),
				.ports = g.shown_ports.array_view(),
				.wires = g.shown_wires.array_view(),
				.view = g.view,
				.on_select = &nodes_select,
				.on_box = &nodes_box,
				.on_move = &nodes_move,
				.can_connect = &nodes_can_connect,
				.on_connect = &nodes_connect,
				.on_disconnect = &nodes_disconnect,
				.on_wire_select = &nodes_wire_select,
				.on_wire_dropped = &nodes_wire_dropped,
				.on_context = &nodes_context,
				.on_command = &nodes_command,
				.on_add_request = &nodes_add_request,
				.on_view = &nodes_view_moved,
			})
			{
				for (usz i = 0; i < g.count(); i++)
				{
					@tree((NodeCard) { .node = i })
					{
						self.card_body(app, g, i);
					};
				}
			}.with_id(NODES_GRAPH_ID);
			if (g.count() == 0)
			{
				@tree((Anchored) { .h = CENTER, .v = CENTER })
				{
					@node((Label) { .text = "Add nodes from the list, or reset the template", .size = 14, .color = TEXT_DIM });
				};
			}
			@tree((Anchored) { .h = START, .v = START, .margin = { 10, 10 } })
			{
				@tree((Column) { .gap = 4, .size = { 360, 0 } })
				{
					if (!self.shown.skeleton)
					{
						self.note("This model has no skeleton yet. Rig it first: generated and captured clips are put on the rig.");
					}
					else if (captures && !self.shown.has_file)
					{
						self.note("Save the model as a .glb to capture: the capture's files go in a folder beside it.");
					}
					if (kimodo.len > 0) self.plugin_note("Kimodo", kimodo);
					if (creature.len > 0) self.plugin_note("creature", creature);
				};
			};
			@node((ContextMenu) { .items = nodes_menu_items[:nodes_menu_len], .searchable = true, .placeholder = "Add a node",
				.style = MENU_STYLE, .on_choose = &nodes_menu_chosen }).with_id(NODES_MENU_ID);
		};
		};
	};

	// The fields show their nodes' settings.
	Element* graph = body.find_id(NODES_GRAPH_ID)!!;
	foreach (card : graph.children)
	{
		if (!card.is_widget(NodeCard)) continue;
		PipelineNode* n = g.at(card.widget_as(NodeCard).node);
		foreach (slot, id : NODE_FIELD_IDS)
		{
			if (try Element* field = card.find_id(id)) field.widget_as(TextField).set_text(field, n.params[slot]);
		}
	}
	return body;
}

// The template bar on top, the canvas under it.
struct NodesBody (Widget)
{
	float bar; // px; 0 = NODES_BAR_H
}

fn Vec2 NodesBody.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	Vec2 max = constraints.max;
	if (elem.children.len() < 2) return max;
	float bar = self.bar > 0 ? self.bar : NODES_BAR_H;
	elem.layout_child(0, cui::tight({ max.x, bar }));
	elem.place_child(0, { 0, 0 });
	elem.layout_child(1, cui::tight({ max.x, math::max(max.y - bar, 0.0f) }));
	elem.place_child(1, { 0, bar });
	return max;
}

fn void nodes_template_chosen(Ui* ui, usz row) @private
{
	ui.inherit(AppState)!!.open_template_named(row);
	refresh_nodes_view(ui);
}

fn void nodes_reset_clicked(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	if (!app.reset_template(app.open_template)) app.@notice("Stop the run first: its nodes are running");
	refresh_nodes_view(ui);
}

fn void NodesPanel.note(&self, String text)
{
	@node((GenerateNote) { .text = self.hold(text), .size = 12, .color = ACCENT });
}

fn void NodesPanel.plugin_note(&self, String plugin, String why)
{
	@tree((Row) { .gap = 4, .cross_align = CENTER })
	{
		@card_icon(FOLDER_GLYPH, "Plugins — choose the llm folder, or link the plugin into it, in File › Settings › AI", &open_ai_settings);
		@node((GenerateNote) { .text = self.hold(string::tformat("The %s plugin cannot run: %s.", plugin, why)), .size = 12, .color = ACCENT });
	};
}

<*
 A card's body: its settings, its icons and one status line. Whatever is
 running shows Stop and the step's live status instead of its Run.
*>
fn void NodesPanel.card_body(&self, AppState* app, PipelineGraph* g, usz i)
{
	PipelineNode* n = g.at(i);
	bool running = g.running == (sz)i;
	bool ready = app.node_ready(g, i);
	@tree((Column) { .gap = 4 })
	{
		switch (n.kind)
		{
			case NOTE:
				@node((TextField) { .multiline = true, .width = NOTE_INNER, .height = note_height(n.params[0]), .style = TEXT_FIELD_STYLE,
					.placeholder = "a note", .on_change = &node_param0_changed }).with_id(NODE_FIELD_IDS[0]);
			case KIMODO_TEXT:
				path_field(0, "Llama-3-Kimodo-*.gguf", "Choose the text encoder — Kimodo's Llama .gguf; saved as the default for new nodes");
				path_field(1, "tokenizer.gguf, if not beside it", "Choose the tokenizer — only when it is not beside the text encoder");
				@node((LiveLabel) { .text_of = &node_status_text, .size = { NODE_INNER, 16 }, .text_size = NODE_TEXT, .color = TEXT_DIM });
			case KIMODO_MODEL:
				path_field(0, "Kimodo-* folder, .safetensors or .gguf", "Choose the motion model — NVIDIA's Kimodo folder as downloaded, or kimodo.cpp's .gguf; saved as the default");
				@node((LiveLabel) { .text_of = &node_status_text, .size = { NODE_INNER, 16 }, .text_size = NODE_TEXT, .color = TEXT_DIM });
			case DINO_BACKBONE:
				path_field(0, "SAM 3D Body's model.ckpt, or its folder", "Choose the backbone — SAM 3D Body's DINOv3 model.ckpt; saved as the default");
				@node((LiveLabel) { .text_of = &node_status_text, .size = { NODE_INNER, 16 }, .text_size = NODE_TEXT, .color = TEXT_DIM });
			case PROMPT:
				@node((TextField) { .multiline = true, .width = NODE_INNER, .height = NODE_PROMPT_H, .style = TEXT_FIELD_STYLE,
					.placeholder = "what the character does", .on_change = &node_param0_changed,
					.on_submit = &node_prompt_submitted }).with_id(NODE_FIELD_IDS[0]);
				@node((Label) { .text = "Ctrl+Return runs what it feeds", .size = NODE_TEXT, .color = TEXT_DIM });
			case GUIDE:
				@node((GuideChooser) { .node = i });
				self.status(n.params[0].trim().len > 0 && !ready ? "No clip by that name" : "", false);
			case TEXT_TO_MOTION:
				@tree((Row) { .gap = 4, .cross_align = CENTER })
				{
					@node((TextField) { .width = NODE_INNER - TOOL_CELL_W - 4, .style = TEXT_FIELD_STYLE, .placeholder = self.hold(app.next_generated_name(tmem)),
						.on_change = &node_param0_changed, .on_submit = &node_field_submitted }).with_id(NODE_FIELD_IDS[0]);
					self.run_icon(n.kind, running, "Generate — makes the clip and puts it on the character");
				};
				@tree((Row) { .gap = 4, .cross_align = CENTER })
				{
					small_label("Length");
					number_field(1, 34, &node_param1_changed);
					small_label("s");
					small_label("Steps");
					number_field(3, 40, &node_param3_changed);
				};
				@tree((Row) { .gap = 4, .cross_align = CENTER })
				{
					small_label("Seed");
					number_field(2, 52, &node_param2_changed);
					@card_icon(SEED_GLYPH, "New seed — another take on the same prompt", &node_new_seed_clicked);
					@node((Select) { .options = generate_optimize_levels[..], .selected = node_optimize(n.params[4]).ordinal,
						.width = 80, .style = VIEW_MENU_STYLE, .on_change = &node_optimize_chosen }).with_id(NODE_OPTIMIZE_ID);
				};
			case FINDER_FILE:
				path_field(0, "a .safetensors trained before", "Choose a finder — one trained before, for this character or one like it");
				String finder = app.capture_node_finder(n);
				String summary = finder_summary(finder);
				self.status(summary.len > 0 ? summary : finder.len == 0 ? "No finder chosen" : ready ? "A joint finder" : "Not there", ready);
			case TRAIN:
				@tree((Row) { .gap = 4, .cross_align = CENTER })
				{
					small_label("Poses");
					number_field(0, 48, &node_param0_changed);
					small_label("Size");
					@node((Select) { .options = train_size_names[..], .selected = train_size_row(n.params[1]),
						.width = 72, .style = VIEW_MENU_STYLE, .on_change = &node_size_chosen }).with_id(NODE_SIZE_ID);
					self.run_icon(n.kind, running, "Train — draws each pose from four cameras, then teaches the finder where its joints are, in five stages. The line below says how many pictures it uses and about how long it takes. Size — the pictures' side: bigger finds joints more precisely but trains slower (896 is about 4× 448). Changing it draws the set again.");
				};
				folder_field(2);
				if (!running)
				{
					self.status(ready ? finder_summary(app.capture_node_finder(n)) : "Not trained yet", ready);
					@node((LiveLabel) { .text_of = &node_status_text, .size = { NODE_INNER, 16 }, .text_size = NODE_TEXT, .color = TEXT_DIM });
				}
			case VIDEO:
			case IMAGE:
				@node((Segmented) { .options = node_source_names[..], .selected = n.kind == IMAGE ? 1 : 0, .on_change = &node_source_chosen,
					.style = SEGMENTED_STYLE }).with_id(NODE_SOURCE_ID);
				if (n.kind == VIDEO)
				{
					path_field(0, "the clip, or a folder of its frames", "Choose video — the .mp4 or .mov (H.264) the video model made from a reference picture, or a folder of its frames");
				}
				else
				{
					path_field(0, "reference.png in a new pose", "Choose picture — a reference picture moved into a new pose by an image model: the same two views, the same framing");
				}
				@node((LiveLabel) { .text_of = &node_status_text, .size = { NODE_INNER, 16 }, .text_size = NODE_TEXT, .color = TEXT_DIM });
			case REFERENCE:
				path_field(0, "empty: the closest saved reference", "Choose the reference — the one the video or picture was made from: its folder, reference.png or studio.json. Empty takes the saved reference that looks most like the first frame");
				@node((LiveLabel) { .text_of = &node_status_text, .size = { NODE_INNER, 16 }, .text_size = NODE_TEXT, .color = TEXT_DIM });
			case ANIMATE:
				bool pose = g.reads_still(i);
				@tree((Row) { .gap = 4, .cross_align = CENTER })
				{
					String named = string::tformat("%s name: %s", pose ? "pose" : "clip", g.clip_name(i));
					@node((TextField) { .width = NODE_INNER - 2 * (TOOL_CELL_W + 4), .style = TEXT_FIELD_STYLE, .placeholder = self.hold(named),
						.on_change = &node_param0_changed }).with_id(NODE_FIELD_IDS[0]);
					@card_icon(MIRROR_GLYPH, "Mirror check — also reads each frame mirrored, so left and right don't swap. Off is about a third faster, but a fast run can lose steps.",
						&node_mirror_clicked, g.mirror_on(i) ? LIT : PLAIN).with_id(NODE_MIRROR_ID);
					self.run_icon(n.kind, running, pose ? "Animate — finds the joints in the picture and saves the pose in Poses, read through the reference's layout"
						: "Animate — reads the video a frame at a time into a clip on the character, with the finder and the picture's layout; save the model to keep it");
				};
				if (!pose)
				{
					// Fewer frames for a quick test run; empty reads the whole video.
					@tree((Row) { .gap = 4, .cross_align = CENTER })
					{
						small_label("Frames");
						@node((TextField) { .width = 48, .style = TEXT_FIELD_STYLE, .placeholder = "all", .on_change = &node_param3_changed,
							.on_submit = &node_field_submitted }).with_id(NODE_FIELD_IDS[3]);
						small_label("from the start");
					};
				}
				if (!running && g.failed != (sz)i) self.status(ready ? (pose ? "In Poses" : "On the character") : "", ready);
		}
		if (running)
		{
			@node((LiveLabel) { .text_of = n.kind == TEXT_TO_MOTION ? &generate_status_text : &capture_status_text,
				.size = { NODE_INNER, 16 }, .text_size = NODE_TEXT, .color = TEXT_DIM });
			if (n.kind == TRAIN) @node((LiveLabel) { .text_of = &capture_count_text, .size = { NODE_INNER, 16 }, .text_size = NODE_TEXT, .color = TEXT_DIM });
		}
		else if (g.failed == (sz)i)
		{
			@node((GenerateNote) { .text = self.hold(g.failure), .size = NODE_TEXT, .color = DOT_LOCKED });
		}
	};
}

// A note's field: tall enough for its text, wrapped.
fn float note_height(String text) @private
{
	usz lines;
	foreach (para : text.tsplit("\n")) lines += math::max(para.len + NOTE_LINE_CHARS - 1, NOTE_LINE_CHARS) / NOTE_LINE_CHARS;
	return (float)math::max(lines, (usz)3) * NOTE_LINE_H + NOTE_PADDING;
}

fn void NodesPanel.status(&self, String text, bool lit)
{
	if (text.len == 0) return;
	@node((GenerateNote) { .text = self.hold(text), .size = NODE_TEXT, .color = lit ? TEXT : TEXT_DIM });
}

fn void NodesPanel.run_icon(&self, NodeKind kind, bool running, String tip)
{
	if (running)
	{
		String stop = kind == TRAIN ? "Stop — keeps the drawn pictures, and the body once it has trained; the rest starts over" : "Stop — throws away what it had made";
		@card_icon(STOP_GLYPH, stop, &node_stop_clicked).with_id("node-stop");
		return;
	}
	@card_icon(RUN_GLYPH, tip, &node_run_clicked, COMMIT).with_id(string::tformat("node-run-%s", NODE_ID_BASES[kind.ordinal]));
}

fn void small_label(String text) @private
{
	@node((Label) { .text = text, .size = NODE_TEXT, .color = TEXT_DIM });
}

fn void number_field(usz slot, float width, OnText changed) @private
{
	@node((TextField) { .width = width, .style = TEXT_FIELD_STYLE, .on_change = changed, .on_submit = &node_field_submitted }).with_id(NODE_FIELD_IDS[slot]);
}

const OnText[4] NODE_PARAM_CHANGED = { &node_param0_changed, &node_param1_changed, &node_param2_changed, &node_param3_changed };
const OnClick[4] NODE_BROWSE_CLICKED = { &node_browse0_clicked, &node_browse1_clicked, &node_browse2_clicked, &node_browse3_clicked };

// A path setting: its field and its Browse icon.
fn void path_field(usz slot, String placeholder, String tip) @private
{
	@tree((Row) { .gap = 4, .cross_align = CENTER })
	{
		@node((TextField) { .width = NODE_INNER - TOOL_CELL_W - 4, .style = TEXT_FIELD_STYLE, .placeholder = placeholder,
			.on_change = NODE_PARAM_CHANGED[slot] }).with_id(NODE_FIELD_IDS[slot]);
		@card_icon(BROWSE_GLYPH, tip, NODE_BROWSE_CLICKED[slot]).with_id(string::tformat("node-browse-%d", slot));
	};
}

// A step's save folder; empty is the capture folder beside the model.
fn void folder_field(usz slot) @private
{
	path_field(slot, "save folder: <model>.capture", "Save folder — where this step writes its files; empty is the capture folder beside the model");
}

<*
 The live line under a model or Video node's path: whether its file is there.
 Owned.
*>
fn String node_status_text(Element* elem) @private
{
	AppState* app = elem.inherit(AppState)!!;
	PipelineGraph* g = app.pipeline();
	sz node = card_above(elem);
	if (node < 0 || (usz)node >= g.count()) return "";
	PipelineNode* n = g.at(node);
	String first = n.params[0].trim();
	switch (n.kind)
	{
		case KIMODO_TEXT:
			if (first.len == 0) return "Choose the text encoder".copy(mem);
			if (!file::exists(first)) return "Not found".copy(mem);
			String tokenizer = n.params[1].trim();
			if (tokenizer.len > 0 && !file::exists(tokenizer)) return "Tokenizer not found".copy(mem);
			return (tokenizer.len > 0 ? "Found" : "Found · its tokenizer beside it").copy(mem);
		case KIMODO_MODEL:
			if (first.len == 0) return "Choose the motion model".copy(mem);
			String gap = motion_checkpoint_gap(first);
			return gap.len > 0 ? string::format(mem, "Not found: %s", base_name(gap)) : "Found".copy(mem);
		case DINO_BACKBONE:
			if (first.len == 0) return "Choose the backbone".copy(mem);
			return (path::exists((Path)first) ? "Found" : "Not found").copy(mem);
		case IMAGE:
			if (first.len == 0) return "Choose the picture".copy(mem);
			return (file::is_file(first) ? "A picture: makes a pose" : "Not there").copy(mem);
		case VIDEO:
			if (first.len > 0 && !path::exists((Path)first)) return "Not there".copy(mem);
			if (first.len > 0 && path::is_dir((Path)first)) return "A folder of frames".copy(mem);
			String lower = first.to_lower_tcopy();
			if (first.len > 0 && !lower.ends_with(".mp4") && !lower.ends_with(".mov") && !lower.ends_with(".m4v")) return "Not an .mp4 or .mov".copy(mem);
			return "H.264 .mp4 or .mov, read in Rigsmith".copy(mem);
		case TRAIN:
			uint? poses = first.to_uint();
			if (catch poses) return "";
			if (!capture_poses_ok(poses)) return "";
			return capture_train_summary(poses, n.params[1].trim().to_uint() ?? CAPTURE_DEFAULT_SIZE);
		case REFERENCE:
			if (first.len == 0) return "The closest saved reference".copy(mem);
			String folder = capture_reference_folder(first);
			return folder.len > 0 ? string::format(mem, "Found: %s", base_name(folder)) : "Not a reference: no studio.json".copy(mem);
		default:
			return "";
	}
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

fn sz node_card_clicked(Ui* ui) @private
{
	sz node = card_above(ui.hovered);
	if (node < 0) node = card_above(ui.focused);
	return node < (sz)ui.inherit(AppState)!!.pipeline().count() ? node : -1;
}

fn sz node_card_typed(Ui* ui) @private
{
	sz node = card_above(ui.focused);
	if (node < 0) node = card_above(ui.hovered);
	return node < (sz)ui.inherit(AppState)!!.pipeline().count() ? node : -1;
}

fn void node_param_typed(Ui* ui, usz slot, String text) @private
{
	sz node = node_card_typed(ui);
	if (node >= 0) ui.inherit(AppState)!!.set_node_param((usz)node, slot, text);
}

fn void node_param0_changed(Ui* ui, String text) @private => node_param_typed(ui, 0, text);
fn void node_param1_changed(Ui* ui, String text) @private => node_param_typed(ui, 1, text);
fn void node_param2_changed(Ui* ui, String text) @private => node_param_typed(ui, 2, text);
fn void node_param3_changed(Ui* ui, String text) @private => node_param_typed(ui, 3, text);

// Return in a Text to motion field runs it.
fn void node_field_submitted(Ui* ui, String text) @private
{
	AppState* app = ui.inherit(AppState)!!;
	sz node = node_card_typed(ui);
	if (node >= 0 && app.pipeline().at(node).kind == TEXT_TO_MOTION) node_run(app, (usz)node);
}

// Ctrl+Return in a prompt runs every Text to motion node it feeds.
fn void node_prompt_submitted(Ui* ui, String text) @private
{
	AppState* app = ui.inherit(AppState)!!;
	PipelineGraph* g = app.pipeline();
	sz prompt = node_card_typed(ui);
	if (prompt < 0) return;
	app.set_node_param((usz)prompt, 0, text);
	List{usz} fed;
	fed.init(tmem);
	foreach (usz i, &n : g.nodes) if (n.kind == TEXT_TO_MOTION && n.input[2] == prompt) fed.push(i);
	if (fed.len() == 0)
	{
		app.@notice("Wire the prompt into a Text to motion node to run it");
		return;
	}
	if (catch err = app.run_nodes(g, fed.array_view())) app.@notice("Could not run: %s", node_refusal(app, err));
}

fn void node_optimize_chosen(Ui* ui, usz row) @private
{
	sz node = node_card_clicked(ui);
	if (node < 0 || row >= NODE_OPTIMIZE_NAMES.len) return;
	ui.inherit(AppState)!!.set_node_param((usz)node, 4, NODE_OPTIMIZE_NAMES[row]);
}

// The Size row a Train node's setting is on; the default's for one off the list.
fn usz train_size_row(String text) @private
{
	uint size = text.trim().to_uint() ?? CAPTURE_DEFAULT_SIZE;
	foreach (row, s : CAPTURE_SIZES) if (s == size) return (usz)row;
	return 0;
}

fn void node_size_chosen(Ui* ui, usz row) @private
{
	sz node = node_card_clicked(ui);
	if (node < 0 || row >= CAPTURE_SIZES.len) return;
	ui.inherit(AppState)!!.set_node_param((usz)node, 1, string::tformat("%d", CAPTURE_SIZES[row]));
}

fn void node_mirror_clicked(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	sz node = node_card_clicked(ui);
	if (node < 0) return;
	app.set_node_param((usz)node, 1, app.pipeline().mirror_on((usz)node) ? "0" : "1");
	// The card rebuilds, so the icon shows the new state.
	app.pipeline().version++;
}

// The Video | Image switch on a source's card. A refusal rebuilds it too, so the
// switch goes back to what the node is.
fn void node_source_chosen(Ui* ui, usz row) @private
{
	AppState* app = ui.inherit(AppState)!!;
	PipelineGraph* g = app.pipeline();
	sz node = node_card_clicked(ui);
	if (node < 0 || (g.at(node).kind == IMAGE) == (row == 1)) return;
	if (!g.swap_source((usz)node)) app.@notice("Stop the run first: its nodes are running");
	g.changed();
}

fn void node_new_seed_clicked(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	sz node = node_card_clicked(ui);
	if (node < 0) return;
	ulong t = (ulong)clock::now();
	uint seed = (uint)((t * 6364136223846793005u + 1442695040888963407u) >> 33) % 100000u;
	app.set_node_param((usz)node, 2, string::tformat("%d", seed));
	app.pipeline().version++;
}

// ---------------------------------------------------------------------------
// The editor's gestures.

fn void nodes_select(Ui* ui, sz node, SelectMode mode) @private
{
	AppState* app = ui.inherit(AppState)!!;
	PipelineGraph* g = app.pipeline();
	if (mode == SelectMode.REPLACE)
	{
		foreach (&n : g.nodes) n.selected = false;
		g.wire_node = -1;
	}
	if (node >= 0) g.at(node).selected = mode == SelectMode.TOGGLE ? !g.at(node).selected : true;
	g.update_flags(app);
}

fn void nodes_box(Ui* ui, usz[] hit, SelectMode mode) @private
{
	AppState* app = ui.inherit(AppState)!!;
	PipelineGraph* g = app.pipeline();
	if (mode == SelectMode.REPLACE) foreach (&n : g.nodes) n.selected = false;
	foreach (i : hit) g.at(i).selected = mode == SelectMode.TOGGLE ? !g.at(i).selected : true;
	g.update_flags(app);
}

fn void nodes_move(Ui* ui, Vec2 delta, bool done) @private
{
	AppState* app = ui.inherit(AppState)!!;
	PipelineGraph* g = app.pipeline();
	foreach (&n : g.nodes)
	{
		if (!n.selected) continue;
		n.pos += delta;
		if (done) n.pos = { math::round(n.pos.x), math::round(n.pos.y) };
	}
	g.update_flags(app);
	if (done) g.save();
}

fn void nodes_view_moved(Ui* ui, View2D view) @private => ui.inherit(AppState)!!.pipeline().view = view;

fn bool nodes_can_connect(Ui* ui, usz from, usz to) @private
{
	PipelineGraph* g = ui.inherit(AppState)!!.pipeline();
	if (from >= g.ports().len || to >= g.ports().len) return false;
	NodePort a = g.ports()[from];
	NodePort b = g.ports()[to];
	if (a.input >= 0 || b.input < 0 || a.node == b.node) return false;
	NodeLink made;
	return node_output(g.at(a.node).kind, &made) && made == node_input(g.at(b.node).kind, (usz)b.input).link;
}

<*
 The wires changed but no card did: the editor's tables remade in place, so a
 wire being dragged off an input carries on.
*>
fn void nodes_wires_changed(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	PipelineGraph* g = app.pipeline();
	g.rebuild_view(app);
	g.save();
	Element*? graph = ui.find_id(NODES_GRAPH_ID);
	if (catch graph) return;
	NodeGraph* editor = graph.widget_as(NodeGraph);
	editor.nodes = g.shown_nodes.array_view();
	editor.ports = g.shown_ports.array_view();
	editor.wires = g.shown_wires.array_view();
	editor.refresh(graph);
}

fn void nodes_connect(Ui* ui, usz from, usz to) @private
{
	PipelineGraph* g = ui.inherit(AppState)!!.pipeline();
	usz node = g.ports()[to].node;
	if (!g.connect(g.ports()[from].node, node, (usz)g.ports()[to].input)) return;
	nodes_wires_changed(ui);
	// Animate's card shows what its source makes.
	if (g.at(node).kind == ANIMATE) g.version++;
}

fn void nodes_disconnect(Ui* ui, usz wire) @private
{
	PipelineGraph* g = ui.inherit(AppState)!!.pipeline();
	if (wire >= g.wires().len) return;
	g.disconnect(g.wires()[wire].node, g.wires()[wire].input);
	nodes_wires_changed(ui);
}

fn void nodes_wire_select(Ui* ui, usz wire, SelectMode mode) @private
{
	AppState* app = ui.inherit(AppState)!!;
	PipelineGraph* g = app.pipeline();
	if (wire >= g.wires().len) return;
	foreach (&n : g.nodes) n.selected = false;
	g.wire_node = (sz)g.wires()[wire].node;
	g.wire_input = g.wires()[wire].input;
	g.update_flags(app);
}

fn void nodes_command(Ui* ui, GraphCommand command) @private
{
	AppState* app = ui.inherit(AppState)!!;
	PipelineGraph* g = app.pipeline();
	switch (command)
	{
		case DELETE:
			nodes_delete_selection(ui);
		case DUPLICATE:
			nodes_duplicate_selection(ui);
		case SELECT_ALL:
			foreach (&n : g.nodes) n.selected = true;
			g.wire_node = -1;
			g.update_flags(app);
		default:
			break;
	}
}

fn void nodes_delete_selection(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	PipelineGraph* g = app.pipeline();
	if (g.wire_node >= 0)
	{
		g.disconnect((usz)g.wire_node, g.wire_input);
		nodes_wires_changed(ui);
		return;
	}
	bool picked;
	foreach (n : g.nodes) picked |= n.selected;
	if (!picked) return;
	if (g.busy())
	{
		app.@notice("Stop the run first: its nodes are running");
		return;
	}
	for (usz i = g.count(); i > 0; i--)
	{
		if (g.at(i - 1).selected) g.remove(i - 1);
	}
	g.failed = -1;
	g.changed();
}

fn void nodes_duplicate_selection(Ui* ui) @private
{
	PipelineGraph* g = ui.inherit(AppState)!!.pipeline();
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

enum NodesMenu : char
{
	ADD,
	NODE,
}

const String[3] NODE_ACTIONS = { "Run up to here", "Duplicate", "Delete" };
const usz NODES_MENU_MAX = NODE_KINDS;

NodesMenu nodes_menu;
ContextMenuItem[NODES_MENU_MAX] nodes_menu_items;
NodeKind[NODES_MENU_MAX] nodes_menu_kinds;
usz nodes_menu_len;
Vec2 nodes_menu_plane;
// The port a dropped wire hangs from, for the added node to take.
bool nodes_menu_wired;
usz nodes_menu_port;
// The node a node menu is for, and the node and setting a file chooser fills.
usz nodes_menu_node;
sz node_pick = -1;
usz node_pick_slot;

fn void open_nodes_menu(Ui* ui, Vec2 screen) @private
{
	Element*? menu = ui.find_id(NODES_MENU_ID);
	if (catch menu) return;
	ContextMenu* shown = menu.widget_as(ContextMenu);
	shown.items = nodes_menu_items[:nodes_menu_len];
	shown.searchable = nodes_menu == ADD;
	shown.open_at(menu, screen);
}

<*
 The add menu at a point: every kind, or with a wire dropped from
 `port`, the kinds that would take it.
*>
fn void open_nodes_add_menu(Ui* ui, Vec2 plane, Vec2 screen, sz port = -1) @private
{
	PipelineGraph* g = ui.inherit(AppState)!!.pipeline();
	nodes_menu = ADD;
	nodes_menu_plane = plane;
	nodes_menu_wired = port >= 0 && (usz)port < g.ports().len;
	nodes_menu_port = nodes_menu_wired ? (usz)port : 0;
	nodes_menu_len = 0;
	foreach (usz k, title : NODE_TITLES)
	{
		NodeKind kind = (NodeKind)(int)k;
		if (nodes_menu_wired && nodes_dropped_slot(g, kind) < 0) continue;
		nodes_menu_kinds[nodes_menu_len] = kind;
		nodes_menu_items[nodes_menu_len++] = { .label = title, .category = NODE_CATEGORIES[k] };
	}
	if (nodes_menu_len > 0) open_nodes_menu(ui, screen);
}

<*
 Where a node of `kind` takes the dropped wire: the input slot it goes into
 (or 0 for its output, when the wire hangs from an input); -1 = it cannot.
*>
fn sz nodes_dropped_slot(PipelineGraph* g, NodeKind kind) @private
{
	NodePort from = g.ports()[nodes_menu_port];
	NodeLink made;
	if (from.input >= 0)
	{
		return node_output(kind, &made) && made == node_input(g.at(from.node).kind, (usz)from.input).link ? 0 : -1;
	}
	if (!node_output(g.at(from.node).kind, &made)) return -1;
	for (usz k = 0; k < node_inputs(kind); k++) if (node_input(kind, k).link == made) return (sz)k;
	return -1;
}

fn void nodes_add_request(Ui* ui, Vec2 plane, Vec2 screen) @private => open_nodes_add_menu(ui, plane, screen);
fn void nodes_wire_dropped(Ui* ui, usz port, Vec2 plane, Vec2 screen) @private => open_nodes_add_menu(ui, plane, screen, (sz)port);

fn void nodes_context(Ui* ui, GraphTarget target, sz index, Vec2 plane, Vec2 screen) @private
{
	PipelineGraph* g = ui.inherit(AppState)!!.pipeline();
	switch (target)
	{
		case NODE:
			if (!g.at(index).selected) nodes_select(ui, index, REPLACE);
			nodes_menu = NODE;
			nodes_menu_node = (usz)index;
			nodes_menu_len = 0;
			foreach (action : NODE_ACTIONS) nodes_menu_items[nodes_menu_len++] = { .label = action };
			open_nodes_menu(ui, screen);
		case WIRE:
			nodes_wire_select(ui, (usz)index, REPLACE);
			nodes_delete_selection(ui);
		default:
			open_nodes_add_menu(ui, plane, screen);
	}
}

fn void nodes_menu_chosen(Ui* ui, usz index) @private
{
	AppState* app = ui.inherit(AppState)!!;
	PipelineGraph* g = app.pipeline();
	if (nodes_menu == NODE)
	{
		if (nodes_menu_node >= g.count()) return;
		switch (index)
		{
			case 0: node_run(app, nodes_menu_node);
			case 1: nodes_duplicate_selection(ui);
			case 2: nodes_delete_selection(ui);
		}
		return;
	}
	if (index >= nodes_menu_len) return;
	NodeKind kind = nodes_menu_kinds[index];
	sz slot = nodes_menu_wired ? nodes_dropped_slot(g, kind) : -1;
	usz added = app.add_node(kind, nodes_menu_plane);
	if (slot >= 0)
	{
		NodePort from = g.ports()[nodes_menu_port];
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

// Why a run was refused, naming the node it is about. Temporary.
fn String node_refusal(AppState* app, fault err) @private
{
	PipelineGraph* g = app.pipeline();
	String why = node_fault_text(err);
	if (g.blocker < 0 || (usz)g.blocker >= g.count()) return why;
	if (err == NODE_SOURCE_MISSING) return string::tformat("%s is not set, or its file is not there", g.at(g.blocker).id);
	return string::tformat("%s: %s", g.at(g.blocker).id, why);
}

fn void node_run(AppState* app, usz node) @private
{
	if (catch err = app.run_node(app.pipeline(), node)) app.@notice("Could not run %s: %s", app.pipeline().at(node).id, node_refusal(app, err));
}

fn void node_run_clicked(Ui* ui) @private
{
	sz node = node_card_clicked(ui);
	if (node >= 0) node_run(ui.inherit(AppState)!!, (usz)node);
}

fn void node_stop_clicked(Ui* ui) @private
{
	ui.inherit(AppState)!!.stop_pipeline();
	refresh_nodes_view(ui);
	refresh_animations_view(ui);
}

fn void node_browse(Ui* ui, usz slot) @private
{
	AppState* app = ui.inherit(AppState)!!;
	node_pick = node_card_clicked(ui);
	if (node_pick < 0) return;
	node_pick_slot = slot;
	PipelineNode* n = app.pipeline().at(node_pick);
	// Start in a folder that is set, or beside a file, since the other weights are usually next to it.
	String held = n.params[slot].trim();
	if (held.len > 1 && held[^1] == '/') held = held[:held.len - 1];
	// A reference with nothing chosen starts where the dialog saves them.
	if (n.kind == REFERENCE && held.len == 0) held = app.config.reference_folder.len > 0 ? app.config.reference_folder : app.capture_path("references");
	if (held.len > 0 && path::is_dir((Path)held))
	{
		app.remember_directory(held);
	}
	else if (try slash = held.rindex_of_char('/'))
	{
		String dir = held[:(usz)slash];
		if (path::is_dir((Path)dir)) app.remember_directory(dir);
	}
	open_file_dialog(ui, node_browse_purpose(n.kind, slot));
}

// What a node's Browse asks for: a file, a folder, or either.
fn FilePurpose node_browse_purpose(NodeKind kind, usz slot)
{
	if (slot > 0 && slot == node_folder_slot(kind)) return CAPTURE_FOLDER;
	switch (kind)
	{
		case KIMODO_MODEL:
		case DINO_BACKBONE: return MOTION_PATH;
		case VIDEO: return CAPTURE_VIDEO;
		case IMAGE: return CAPTURE_IMAGE;
		case FINDER_FILE: return CAPTURE_FINDER;
		case REFERENCE: return CAPTURE_REFERENCE;
		default: return MOTION_FILE;
	}
}

fn void node_browse0_clicked(Ui* ui) @private => node_browse(ui, 0);
fn void node_browse1_clicked(Ui* ui) @private => node_browse(ui, 1);
fn void node_browse2_clicked(Ui* ui) @private => node_browse(ui, 2);
fn void node_browse3_clicked(Ui* ui) @private => node_browse(ui, 3);

// A chosen file into the node and setting whose chooser it was.
fn void node_file_chosen(Ui* ui, String path)
{
	AppState* app = ui.inherit(AppState)!!;
	PipelineGraph* g = app.pipeline();
	if (node_pick < 0 || (usz)node_pick >= g.count()) return;
	app.set_node_param((usz)node_pick, node_pick_slot, path);
	g.changed();
	if (g.at(node_pick).kind == FINDER_FILE) app.@notice("Using the joint finder %s", base_name(path));
}

fn String capture_status_text(Element* elem) @private
{
	CaptureJob* job = &elem.inherit(AppState)!!.capture_job;
	if (!job.running) return "";
	switch (job.stage)
	{
		case RENDERING:
		case TRAINING: return job.train_stage_text();
		default: return job.last().len > 0 ? job.last().copy(mem) : "";
	}
}

// The second line of a training's status: how far, and how long is left. Owned.
fn String capture_count_text(Element* elem) @private
{
	CaptureJob* job = &elem.inherit(AppState)!!.capture_job;
	return job.running ? job.train_count_text() : "";
}

// ---------------------------------------------------------------------------
// Guide poses: None, or one of the character's clips.

<*
 A Guide poses node's clip dropdown. Owns its labels, as `AnimChooser` does,
 so a clip renamed or dropped cannot leave the Select pointing into freed
 strings.
*>
struct GuideChooser (Widget)
{
	usz node;
	String[] labels;
}

fn void GuideChooser.release(&self)
{
	foreach (label : self.labels) label.free(mem);
	if (self.labels.len > 0) alloc::free(mem, self.labels);
	self.labels = {};
}

fn void GuideChooser.unmount(&self, Element* elem) @dynamic => self.release();

fn Element* GuideChooser.build(&self, Element* elem) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	self.release();
	sz bound = app.doc.animations.len();
	self.labels = alloc::new_array(mem, String, bound + 1);
	self.labels[0] = "None".copy(mem);
	String chosen = app.pipeline().at(self.node).params[0];
	usz selected = 0;
	foreach (sz i, clip : app.doc.animations.array_view())
	{
		self.labels[i + 1] = clip.clip.copy(mem);
		if (clip.clip == chosen) selected = (usz)i + 1;
	}
	return @subtree(elem.ui)
	{
		@node((Select) { .options = self.labels, .selected = selected,
			.width = NODE_INNER, .style = VIEW_MENU_STYLE, .searchable = self.labels.len > ANIM_CHOOSER_SEARCH_MIN,
			.on_change = &node_guide_chosen }).with_id(NODE_GUIDE_ID);
	};
}

fn Vec2 GuideChooser.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	Vec2 own = elem.layout_child(0, constraints);
	elem.place_child(0, { 0, 0 });
	return own;
}

fn void node_guide_chosen(Ui* ui, usz row) @private
{
	AppState* app = ui.inherit(AppState)!!;
	sz node = node_card_clicked(ui);
	if (node < 0) return;
	String name = row == 0 || (sz)row > app.doc.animations.len() ? "" : app.doc.animations[(sz)row - 1].clip;
	app.set_node_param((usz)node, 0, name);
	app.pipeline().version++;
}
