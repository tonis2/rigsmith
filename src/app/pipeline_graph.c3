<*
 The Nodes pane's graphs (`ui/nodes_panel.c3` draws them with cui's NodeGraph):
 text to motion and video capture as nodes the user wires together. One graph
 per template, for every model, saved as `nodes/<template>.json` in the config
 folder in llm-runner's graph shape,

     { "nodes": [ { "id", "type", "params": { "name": "text" | { "from": "node.port" } }, "pos": [x, y] } ] }

 Model nodes hold the weights' paths; a path set on one is the config's too,
 so the next model node starts with it. Running a node runs the nodes upstream
 of it that are not done yet, then the node itself, one job at a time.
*>
module crig;

import std::collections::list;
import std::collections::object;
import std::encoding::json;
import std::io::file;
import std::io::path;
import std::math;
import cui;
import cui::widgets;
import gltf_edit;

faultdef CAPTURE_CLIP_TAKEN, CAPTURE_POSE_TAKEN, CAPTURE_BAD_POSES, NODE_NOTHING_TO_RUN, NODE_SOURCE_MISSING;

enum NodeKind : char
{
	KIMODO_TEXT,
	KIMODO_MODEL,
	DINO_BACKBONE,
	PROMPT,
	GUIDE,
	TEXT_TO_MOTION,
	FINDER_FILE,
	TRAIN,
	VIDEO,
	ANIMATE,
	NOTE,
	IMAGE,
	POSE,
}

// What a wire carries.
enum NodeLink : char
{
	ENCODER,
	MOTION_MODEL,
	BACKBONE,
	PROMPT_TEXT,
	POSES,
	FINDER,
	FOOTAGE,
	STILL,
}

struct NodeInput
{
	String name;
	NodeLink link;
	bool optional;
}

const usz NODE_KINDS = 13;
const usz NODE_PARAMS = 5;
const usz NODE_INPUTS = 4;
const float NODE_W = 230;
const float NOTE_W = 260;
const Color NOTE_HEADER = { 0.55, 0.45, 0.18, 1.0 };
const String[NODE_KINDS] NODE_TYPES = { "kimodo_text_encoder", "kimodo_model", "dinov3_backbone", "prompt", "guide_poses",
	"text_to_motion", "finder_file", "train_finder", "video", "animate", "note", "image", "image_to_pose" };
const String[NODE_KINDS] NODE_TITLES = { "Kimodo encoder", "Kimodo model", "DINOv3 backbone", "Prompt", "Guide poses",
	"Text to motion", "Finder file", "Train finder", "Video", "Animate", "Note", "Image", "Image to pose" };
const String[NODE_KINDS] NODE_CATEGORIES = { "Models", "Models", "Models", "Generate", "Generate", "Generate",
	"Capture", "Capture", "Capture", "Capture", "Notes", "Capture", "Capture" };
const String[NODE_KINDS] NODE_ID_BASES = { "text_encoder", "motion_model", "backbone", "prompt", "guide", "generate",
	"finder", "train", "video", "animate", "note", "image", "pose" };
// Each kind's settings by slot; "" = no setting there.
const String[NODE_PARAMS][NODE_KINDS] NODE_PARAM_NAMES = {
	{ "path", "tokenizer", "", "", "" },
	{ "path", "", "", "", "" },
	{ "path", "", "", "", "" },
	{ "text", "", "", "", "" },
	{ "clip", "", "", "", "" },
	{ "name", "seconds", "seed", "steps", "optimize" },
	{ "path", "", "", "", "" },
	{ "poses", "size", "folder", "", "" },
	{ "path", "", "", "", "" },
	{ "name", "mirror", "folder", "", "" },
	{ "text", "", "", "", "" },
	{ "path", "", "", "", "" },
	{ "name", "mirror", "folder", "", "" },
};
const NodeInput[NODE_INPUTS][NODE_KINDS] NODE_INPUT_TABLE = {
	{}, {}, {}, {}, {},
	{ { "text_encoder", ENCODER, false }, { "motion_model", MOTION_MODEL, false }, { "prompt", PROMPT_TEXT, false }, { "poses", POSES, true } },
	{},
	{ [0] = { "backbone", BACKBONE, false } },
	{},
	{ { "finder", FINDER, false }, { "video", FOOTAGE, false }, { "backbone", BACKBONE, false }, {} },
	{}, {},
	// Animate's order, so the same slots read the same things.
	{ { "finder", FINDER, false }, { "image", STILL, false }, { "backbone", BACKBONE, false }, {} },
};
const usz[NODE_KINDS] NODE_INPUT_COUNTS = { 0, 0, 0, 0, 0, 4, 0, 1, 0, 3, 0, 0, 3 };
const String[8] NODE_LINK_NAMES = { "text_encoder", "motion_model", "backbone", "prompt", "poses", "finder", "video", "image" };
const Color[8] NODE_LINK_COLORS = {
	{ 0.45, 0.85, 0.45, 1.0 }, { 0.95, 0.60, 0.20, 1.0 }, { 0.91, 0.32, 0.36, 1.0 }, { 0.85, 0.88, 0.95, 1.0 },
	{ 0.40, 0.90, 0.75, 1.0 }, { 0.30, 0.68, 0.95, 1.0 }, { 0.72, 0.50, 0.98, 1.0 }, { 0.95, 0.55, 0.80, 1.0 },
};
const String[3] NODE_OPTIMIZE_NAMES = { "off", "light", "strong" };

// What a kind makes, if anything.
fn bool node_output(NodeKind kind, NodeLink* link)
{
	switch (kind)
	{
		case KIMODO_TEXT: *link = ENCODER;
		case KIMODO_MODEL: *link = MOTION_MODEL;
		case DINO_BACKBONE: *link = BACKBONE;
		case PROMPT: *link = PROMPT_TEXT;
		case GUIDE: *link = POSES;
		case FINDER_FILE:
		case TRAIN: *link = FINDER;
		case VIDEO: *link = FOOTAGE;
		case IMAGE: *link = STILL;
		case TEXT_TO_MOTION:
		case POSE:
		case ANIMATE:
		case NOTE: return false;
	}
	return true;
}

fn usz node_inputs(NodeKind kind) => NODE_INPUT_COUNTS[kind.ordinal];

// The slot of a step's save folder; 0 for a kind without one.
fn usz node_folder_slot(NodeKind kind)
{
	switch (kind)
	{
		case TRAIN: return 2;
		default: return 0;
	}
}
fn NodeInput node_input(NodeKind kind, usz k) => NODE_INPUT_TABLE[kind.ordinal][k];

// The config key a model node's setting is kept under; "" for other settings.
fn String node_config_key(NodeKind kind, usz slot)
{
	switch (kind)
	{
		case KIMODO_TEXT: return slot == 0 ? "text_model" : slot == 1 ? "tokenizer" : "";
		case KIMODO_MODEL: return slot == 0 ? "model" : "";
		case DINO_BACKBONE: return slot == 0 ? "creature_model" : "";
		default: return "";
	}
}

// A new node's setting.
fn String node_default(NodeKind kind, usz slot)
{
	switch (kind)
	{
		case TEXT_TO_MOTION:
			switch (slot)
			{
				case 1: return "5";
				case 2: return "0";
				case 3: return "100";
				case 4: return "light";
			}
		case TRAIN: if (slot == 0) return "1500"; if (slot == 1) return "448";
		// Mirror: off for a video, where it costs a second look a frame.
		case ANIMATE: if (slot == 1) return "0";
		case POSE: if (slot == 1) return "1";
		default: break;
	}
	return "";
}

// Whether an Animate or Image to pose node also looks mirrored; unset is its default.
fn bool node_mirror_on(PipelineNode* n)
{
	String m = n.params[1].trim();
	return (m.len > 0 ? m : node_default(n.kind, 1)) != "0";
}

fn KeyReduction node_optimize(String text)
{
	foreach (i, name : NODE_OPTIMIZE_NAMES) if (text.trim() == name) return (KeyReduction)(int)i;
	return LIGHT;
}

struct PipelineNode
{
	NodeKind kind;
	String id; // owned
	Vec2 pos;
	String[NODE_PARAMS] params; // owned; "" = unset
	sz[NODE_INPUTS] input; // the node wired into each input, -1 = none
	bool selected;
}

fn void PipelineNode.free(&self)
{
	if (self.id.len > 0) self.id.free(mem);
	foreach (p : self.params) if (p.len > 0) p.free(mem);
	*self = { };
}

// One of the editor's ports: a node's input slot, or its output (-1).
struct NodePort
{
	usz node;
	sz input;
}

// One of the editor's wires, by the input it ends on.
struct NodeWire
{
	usz node;
	usz input;
}

struct PipelineGraph
{
	bool loaded;
	bool unframed; // fresh from its template: the pane frames it once
	String file; // owned: where it is saved; "" = nowhere
	List{PipelineNode} nodes;
	View2D view;
	uint version; // bumped by every change the pane rebuilds for
	// The picked wire, by the input it ends on; -1 = none.
	sz wire_node;
	usz wire_input;
	// The run: the nodes still to run, the one running, the one that failed
	// and why (owned), and the node a refusal is about.
	List{usz} queue;
	sz running;
	sz failed;
	String failure;
	sz blocker;
	// The editor's borrowed tables, remade by `rebuild_view`.
	List{GraphNode} shown_nodes;
	List{GraphPort} shown_ports;
	List{GraphWire} shown_wires;
	List{NodePort} port_of;
	List{NodeWire} wire_of;
}

fn void PipelineGraph.free(&self)
{
	foreach (&n : self.nodes) n.free();
	self.nodes.free();
	self.queue.free();
	self.shown_nodes.free();
	self.shown_ports.free();
	self.shown_wires.free();
	self.port_of.free();
	self.wire_of.free();
	if (self.file.len > 0) self.file.free(mem);
	if (self.failure.len > 0) self.failure.free(mem);
	*self = { };
}

// Empty, saved to `file`.
fn void PipelineGraph.reset(&self, String file)
{
	uint version = self.version;
	self.free();
	self.loaded = true;
	self.file = file.copy(mem);
	self.nodes.init(mem);
	self.queue.init(mem);
	self.shown_nodes.init(mem);
	self.shown_ports.init(mem);
	self.shown_wires.init(mem);
	self.port_of.init(mem);
	self.wire_of.init(mem);
	self.view = { .pan = { -20, -20 } };
	self.wire_node = self.running = self.failed = self.blocker = -1;
	self.version = version + 1;
}

// Template `t`'s graph, read from the config folder the first time.
fn PipelineGraph* AppState.pipeline_now(&self, usz t)
{
	PipelineGraph* g = &self.pipelines[t];
	if (g.loaded) return g;
	String file = self.config.directory.len > 0 ? string::tformat("%s/nodes/%s.json", self.config.directory, TEMPLATE_SLUGS[t]) : "";
	g.reset(file);
	bool read;
	if (file.len > 0)
	{
		if (try char[] text = file::load_temp(file)) read = @ok(g.read_json((String)text));
	}
	if (!read) self.load_template(t);
	return g;
}

// The open template's graph.
fn PipelineGraph* AppState.pipeline(&self) => self.pipeline_now(self.open_template);

fn void AppState.open_template_named(&self, usz t)
{
	if (t >= TEMPLATES || t == self.open_template) return;
	self.open_template = t;
	self.config.nodes_template = (int)t;
	self.config.save();
	self.pipeline_now(t).version++;
}

// Template `t`'s graph as the template has it, model nodes from the config.
fn void AppState.load_template(&self, usz t)
{
	PipelineGraph* g = &self.pipelines[t];
	g.reset(g.file.tcopy());
	(void)g.read_json(TEMPLATE_DOCS[t]);
	for (usz i = 0; i < g.count(); i++) self.fill_from_config(g, i);
	g.unframed = true;
}

// Put template `t`'s nodes back as they were; refused while it runs.
fn bool AppState.reset_template(&self, usz t)
{
	PipelineGraph* g = self.pipeline_now(t);
	if (g.busy()) return false;
	self.load_template(t);
	g.changed();
	return true;
}

// The graph with a run going, if any: one job runs at a time.
fn PipelineGraph*? AppState.running_pipeline(&self)
{
	foreach (&g : self.pipelines) if (g.loaded && g.busy()) return g;
	return NOT_FOUND~;
}

macro PipelineNode* PipelineGraph.at(&self, node) => self.nodes.get_ref((sz)node);
fn usz PipelineGraph.count(&self) => (usz)self.nodes.len();
fn NodePort[] PipelineGraph.ports(&self) => self.port_of.array_view();
fn NodeWire[] PipelineGraph.wires(&self) => self.wire_of.array_view();

fn sz PipelineGraph.find(&self, String id)
{
	foreach (i, &n : self.nodes) if (n.id == id) return (sz)i;
	return -1;
}

fn String PipelineGraph.fresh_id(&self, NodeKind kind)
{
	String base = NODE_ID_BASES[kind.ordinal];
	if (self.find(base) < 0) return base.tcopy();
	for (int i = 2; ; i++)
	{
		String id = string::tformat("%s%d", base, i);
		if (self.find(id) < 0) return id;
	}
}

// A node with its default settings; `id` "" = a fresh one.
fn usz PipelineGraph.add(&self, NodeKind kind, Vec2 pos, String id = "")
{
	PipelineNode n = { .kind = kind, .id = (id.len > 0 ? id : self.fresh_id(kind)).copy(mem), .pos = pos, .input = { -1, -1, -1, -1 } };
	foreach (usz slot, &p : n.params)
	{
		String value = node_default(kind, slot);
		if (value.len > 0) *p = value.copy(mem);
	}
	self.nodes.push(n);
	return self.count() - 1;
}

// A node from the menu: a model node starts with the config's paths.
fn usz AppState.add_node(&self, NodeKind kind, Vec2 pos)
{
	PipelineGraph* g = self.pipeline();
	usz node = g.add(kind, pos);
	self.fill_from_config(g, node);
	return node;
}

fn void AppState.fill_from_config(&self, PipelineGraph* g, usz node)
{
	PipelineNode* n = g.at(node);
	foreach (usz slot, &p : n.params)
	{
		String key = node_config_key(n.kind, slot);
		if (key.len == 0 || p.len > 0) continue;
		String held = *self.config.motion_generator.path_of(key);
		if (held.len > 0) *p = held.copy(mem);
	}
}

// A node and the wires into and out of it.
fn void PipelineGraph.remove(&self, usz node)
{
	self.at(node).free();
	self.nodes.remove_at((sz)node);
	foreach (&n : self.nodes)
	{
		foreach (&src : n.input)
		{
			if (*src == (sz)node)
			{
				*src = -1;
			}
			else if (*src > (sz)node)
			{
				(*src)--;
			}
		}
	}
	self.wire_node = -1;
}

// A copy of a node beside it, without its wires.
fn usz PipelineGraph.duplicate(&self, usz node)
{
	PipelineNode* n = self.at(node);
	usz copy = self.add(n.kind, n.pos + (Vec2) { 30, 30 });
	n = self.at(node);
	foreach (usz slot, p : n.params) self.set_param(copy, slot, p);
	return copy;
}

fn void PipelineGraph.set_param(&self, usz node, usz slot, String text)
{
	replace_owned(&self.at(node).params[slot], text);
}

// A setting as typed: a model node's path is the config's default too.
fn void AppState.set_node_param(&self, usz node, usz slot, String text)
{
	PipelineGraph* g = self.pipeline();
	g.set_param(node, slot, text);
	String key = node_config_key(g.at(node).kind, slot);
	if (key.len > 0) self.config.set_motion_path(key, text);
	g.save();
}

<*
 Wire `from`'s output into `to`'s input `input`, replacing what fed it. Only
 Train both takes and makes, and what it takes (a backbone) comes from a node
 that takes nothing, so a wire cannot close a loop.

 @return `False when the output is not what the input takes.`
*>
fn bool PipelineGraph.connect(&self, usz from, usz to, usz input)
{
	if (from == to || input >= node_inputs(self.at(to).kind)) return false;
	NodeLink made;
	if (!node_output(self.at(from).kind, &made) || made != node_input(self.at(to).kind, input).link) return false;
	self.at(to).input[input] = (sz)from;
	return true;
}

fn void PipelineGraph.disconnect(&self, usz node, usz input)
{
	self.at(node).input[input] = -1;
	if (self.wire_node == (sz)node && self.wire_input == input) self.wire_node = -1;
}

// A change the pane rebuilds for, saved.
fn void PipelineGraph.changed(&self)
{
	self.version++;
	self.save();
}

fn bool PipelineGraph.busy(&self) => self.running >= 0 || self.queue.len() > 0;

// ---------------------------------------------------------------------------
// nodes.json

// The graph as nodes.json says it. Owned.
fn String PipelineGraph.to_json(&self)
{
	DString out = dstring::new(mem);
	defer out.free();
	out.appendf("{\n  \"view\": { \"pan\": [%.1f, %.1f], \"zoom\": %.3f },\n  \"nodes\": [", self.view.pan.x, self.view.pan.y, self.view.zoom > 0 ? self.view.zoom : 1.0f);
	foreach (i, &n : self.nodes)
	{
		out.append_string(i == 0 ? "\n    { \"id\": " : ",\n    { \"id\": ");
		gltf_edit::escape_json_string(&out, n.id);
		out.appendf(", \"type\": \"%s\", \"pos\": [%.0f, %.0f], \"params\": {", NODE_TYPES[n.kind.ordinal], n.pos.x, n.pos.y);
		bool first = true;
		foreach (slot, name : NODE_PARAM_NAMES[n.kind.ordinal])
		{
			if (name.len == 0) continue;
			out.appendf("%s\"%s\": ", first ? " " : ", ", name);
			gltf_edit::escape_json_string(&out, n.params[slot]);
			first = false;
		}
		for (usz k = 0; k < node_inputs(n.kind); k++)
		{
			if (n.input[k] < 0) continue;
			PipelineNode* src = self.at(n.input[k]);
			NodeLink made;
			(void)node_output(src.kind, &made);
			out.appendf("%s\"%s\": { \"from\": ", first ? " " : ", ", node_input(n.kind, k).name);
			gltf_edit::escape_json_string(&out, string::tformat("%s.%s", src.id, NODE_LINK_NAMES[made.ordinal]));
			out.append_string(" }");
			first = false;
		}
		out.append_string(" } }");
	}
	out.append_string("\n  ]\n}\n");
	return out.copy_str(mem);
}

fn void PipelineGraph.save(&self)
{
	if (self.file.len == 0) return;
	if (try slash = self.file.rindex_of_char('/')) (void)path::mkdir(self.file[:(usz)slash], true);
	String text = self.to_json();
	defer text.free(mem);
	(void)file::save(self.file, text);
}

<*
 Read a document's nodes and wires into the graph, moved by `offset`. With
 `fresh` every node gets a new id (a template added beside what is there);
 otherwise a node whose id is taken is left out. Unknown types are left out,
 and wires from nodes that are not there. A setting the document leaves out
 is the kind's default.

 @return `The index of the first node read.`
*>
fn usz? PipelineGraph.read_json(&self, String text, Vec2 offset = { 0, 0 }, bool fresh = false)
{
	Object* parsed = json::parse(tmem, text)!;
	if (!fresh)
	{
		if (try Object* view = parsed.get("view"))
		{
			if (try Object* pan = view.get("pan")) self.view.pan = { (float)(pan.get_float_at(0) ?? 0), (float)(pan.get_float_at(1) ?? 0) };
			if (try double zoom = view.get_float("zoom")) self.view.zoom = (float)zoom;
		}
	}
	Object* nodes = parsed.get("nodes")!;
	if (!nodes.is_array()) return CAPTURE_NOT_STARTED~;
	usz first = self.count();
	// The document's ids of the nodes read, by index from `first`.
	List{String} named;
	named.init(tmem);
	for (sz i = 0; i < nodes.get_len(); i++)
	{
		Object* entry = nodes.get_at(i);
		String type = entry.get_string("type") ?? "";
		sz kind = -1;
		foreach (k, known : NODE_TYPES) if (known == type) kind = (sz)k;
		String id = entry.get_string("id") ?? "";
		if (kind < 0 || id.len == 0 || named.contains(id) || (!fresh && self.find(id) >= 0)) continue;
		Vec2 pos = { 40, 40 };
		if (try Object* at = entry.get("pos")) pos = { (float)(at.get_float_at(0) ?? 40), (float)(at.get_float_at(1) ?? 40) };
		usz node = self.add((NodeKind)(int)kind, pos + offset, fresh ? "" : id);
		named.push(id);
		if (try Object* params = entry.get("params"))
		{
			foreach (usz slot, name : NODE_PARAM_NAMES[kind])
			{
				if (name.len == 0) continue;
				if (try String value = params.get_string(name)) self.set_param(node, slot, value);
			}
		}
	}
	// The wires, once every node they name is in.
	for (sz i = 0; i < nodes.get_len(); i++)
	{
		Object* entry = nodes.get_at(i);
		sz to = named_index(&named, entry.get_string("id") ?? "");
		if (to < 0) continue;
		Object*? params = entry.get("params");
		if (catch params) continue;
		PipelineNode* n = self.at(first + (usz)to);
		for (usz k = 0; k < node_inputs(n.kind); k++)
		{
			Object*? wire = params.get(node_input(n.kind, k).name);
			if (catch wire) continue;
			String from = wire.get_string("from") ?? "";
			usz cut = from.len;
			if (try dot = from.rindex_of_char('.')) cut = (usz)dot;
			sz src = named_index(&named, from[:cut]);
			if (src >= 0) (void)self.connect(first + (usz)src, first + (usz)to, k);
		}
	}
	return first;
}

fn sz named_index(List{String}* named, String id) @local
{
	foreach (i, n : *named) if (n == id) return (sz)i;
	return -1;
}

// ---------------------------------------------------------------------------
// Templates: documents of the same shape, each opened on its own canvas.

const usz TEMPLATES = 5;
const String[TEMPLATES] TEMPLATE_NAMES = { "Text to motion", "Text to motion through guide poses",
	"Video capture: train a finder", "Video capture: from a finder file", "Pose from a picture" };
const String[TEMPLATES] TEMPLATE_SLUGS = { "text_to_motion", "guided", "train_finder", "finder_file", "pose_from_picture" };
const String[TEMPLATES] TEMPLATE_DOCS = {
	`{ "nodes": [
		{ "id": "note", "type": "note", "pos": [-300, 0], "params": { "text": "Set the Kimodo encoder and model once: they are kept for every template.\n\nWrite what the character does in Prompt, then Run Text to motion (or Ctrl+Return in the prompt). The clip lands in Animations." } },
		{ "id": "text_encoder", "type": "kimodo_text_encoder", "pos": [0, 0] },
		{ "id": "motion_model", "type": "kimodo_model", "pos": [0, 140] },
		{ "id": "prompt", "type": "prompt", "pos": [0, 260], "params": { "text": "A person walks forward and waves with the right hand." } },
		{ "id": "generate", "type": "text_to_motion", "pos": [300, 60], "params": { "text_encoder": { "from": "text_encoder.text_encoder" },
			"motion_model": { "from": "motion_model.motion_model" }, "prompt": { "from": "prompt.prompt" } } } ] }`,
	`{ "nodes": [
		{ "id": "note", "type": "note", "pos": [-300, 0], "params": { "text": "Like Text to motion, but the motion passes through the poses of a clip.\n\nKey the poses it has to hit in a clip on this character, pick it in Guide poses, then Run." } },
		{ "id": "text_encoder", "type": "kimodo_text_encoder", "pos": [0, 0] },
		{ "id": "motion_model", "type": "kimodo_model", "pos": [0, 140] },
		{ "id": "prompt", "type": "prompt", "pos": [0, 260], "params": { "text": "A person walks forward, then sits down." } },
		{ "id": "guide", "type": "guide_poses", "pos": [0, 410] },
		{ "id": "generate", "type": "text_to_motion", "pos": [300, 60], "params": { "text_encoder": { "from": "text_encoder.text_encoder" },
			"motion_model": { "from": "motion_model.motion_model" }, "prompt": { "from": "prompt.prompt" }, "poses": { "from": "guide.poses" } } } ] }`,
	`{ "nodes": [
		{ "id": "note", "type": "note", "pos": [-300, 0], "params": { "text": "1. Set the DINOv3 backbone, then Run Train finder once per character.\n2. In the 3D view's Pose tab, pick a saved pose and press Reference picture.\n3. Animate reference.png with a video model (Copy video prompt there).\n4. Choose the video, then Run Animate." } },
		{ "id": "backbone", "type": "dinov3_backbone", "pos": [0, 0] },
		{ "id": "train", "type": "train_finder", "pos": [0, 140], "params": { "backbone": { "from": "backbone.backbone" } } },
		{ "id": "video", "type": "video", "pos": [0, 330] },
		{ "id": "animate", "type": "animate", "pos": [300, 140], "params": { "finder": { "from": "train.finder" },
			"video": { "from": "video.video" }, "backbone": { "from": "backbone.backbone" } } } ] }`,
	`{ "nodes": [
		{ "id": "note", "type": "note", "pos": [-300, 0], "params": { "text": "1. Choose a finder trained before in Finder file.\n2. In the 3D view's Pose tab, pick a saved pose and press Reference picture.\n3. Animate reference.png with a video model (Copy video prompt there).\n4. Choose the video, then Run Animate." } },
		{ "id": "backbone", "type": "dinov3_backbone", "pos": [0, 0] },
		{ "id": "finder", "type": "finder_file", "pos": [0, 140] },
		{ "id": "video", "type": "video", "pos": [0, 300] },
		{ "id": "animate", "type": "animate", "pos": [300, 140], "params": { "finder": { "from": "finder.finder" },
			"video": { "from": "video.video" }, "backbone": { "from": "backbone.backbone" } } } ] }`,
	`{ "nodes": [
		{ "id": "note", "type": "note", "pos": [-300, 0], "params": { "text": "1. In the 3D view's Pose tab, pick a saved pose near the one you want and press Reference picture.\n2. Copy image prompt there, and give it to an image model with reference.png.\n3. Choose what it makes in Image.\n4. Run Image to pose: the pose lands in Poses." } },
		{ "id": "backbone", "type": "dinov3_backbone", "pos": [0, 0] },
		{ "id": "finder", "type": "finder_file", "pos": [0, 140] },
		{ "id": "image", "type": "image", "pos": [0, 300] },
		{ "id": "pose", "type": "image_to_pose", "pos": [300, 140], "params": { "finder": { "from": "finder.finder" },
			"image": { "from": "image.image" }, "backbone": { "from": "backbone.backbone" } } } ] }`,
};

// ---------------------------------------------------------------------------
// What each node makes, and where.

<*
 A step's own path: in its save folder when it has one, else in the capture
 folder, where the first of each kind keeps the folder's own names and a
 second goes under its id. Temporary.
*>
fn String AppState.capture_node_path(&self, PipelineNode* n, String own)
{
	usz slot = node_folder_slot(n.kind);
	String folder = slot > 0 ? n.params[slot].trim() : "";
	if (folder.len > 0) return string::tformat("%s/%s", folder, own);
	if (n.id == NODE_ID_BASES[n.kind.ordinal]) return self.capture_path(own);
	return self.capture_path(string::tformat("%s/%s", n.id, own));
}

// The finder a Finder file or Train node gives. Temporary.
fn String AppState.capture_node_finder(&self, PipelineNode* n)
{
	if (n.kind == FINDER_FILE) return n.params[0].trim();
	return self.capture_node_path(n, "finder.safetensors");
}

// The clip (or pose) an Animate node makes: its name, or its video's file name. Temporary.
fn String PipelineGraph.clip_name(&self, usz node)
{
	PipelineNode* n = self.at(node);
	if (n.params[0].trim().len > 0) return n.params[0].trim();
	sz video = n.input[1];
	return capture_clip_name(video >= 0 ? self.at(video).params[0].trim() : "");
}

// The setting `slot` of what feeds `node`'s input `k`; "" when unwired.
fn String PipelineGraph.fed(&self, usz node, usz k, usz slot = 0)
{
	sz src = self.at(node).input[k];
	return src < 0 ? "" : self.at(src).params[slot].trim();
}

// Whether a node's work is there already, so running past it skips it.
fn bool AppState.node_ready(&self, PipelineGraph* g, usz node)
{
	PipelineNode* n = g.at(node);
	String first = n.params[0].trim();
	switch (n.kind)
	{
		case KIMODO_TEXT:
			String tokenizer = n.params[1].trim();
			return first.len > 0 && file::exists(first) && (tokenizer.len == 0 || file::exists(tokenizer));
		case KIMODO_MODEL: return first.len > 0 && motion_checkpoint_gap(first).len == 0;
		case DINO_BACKBONE: return first.len > 0 && path::exists((Path)first);
		case PROMPT: return first.len > 0;
		case GUIDE: return first.len == 0 || self.has_bound_clip_named(first);
		case TEXT_TO_MOTION: return false;
		case FINDER_FILE:
		case TRAIN:
			String finder = self.capture_node_finder(n);
			return finder.len > 0 && file::exists(finder);
		case VIDEO: return first.len > 0 && path::exists((Path)first);
		case IMAGE: return first.len > 0 && file::is_file(first);
		case ANIMATE: return self.has_bound_clip_named(g.clip_name(node));
		case POSE: return self.saved_pose_named(g.clip_name(node)) >= 0;
		case NOTE: return true;
	}
}

// Whether a kind is a setting rather than a step: nothing runs for it.
fn bool node_is_source(NodeKind kind)
{
	switch (kind)
	{
		case TEXT_TO_MOTION:
		case TRAIN:
		case POSE:
		case ANIMATE: return false;
		default: return true;
	}
}

// ---------------------------------------------------------------------------
// Running.

<*
 Run `nodes`, each after the nodes upstream of it that are not ready yet.
 Refused with what is missing before anything starts; `blocker` names the
 node a refusal is about.
*>
fn void? AppState.run_nodes(&self, PipelineGraph* g, usz[] nodes)
{
	g.blocker = -1;
	if (self.capture_engine_busy() || @ok(self.running_pipeline())) return CAPTURE_BUSY~;
	List{usz} order;
	order.init(tmem);
	foreach (node : nodes) self.node_order(g, node, &order)!;
	if (order.len() == 0) return NODE_NOTHING_TO_RUN~;
	foreach (i : order)
	{
		g.blocker = (sz)i;
		PipelineNode* n = g.at(i);
		switch (n.kind)
		{
			case TEXT_TO_MOTION:
				if (self.doc.dots.len() == 0) return MOTION_NO_SKELETON~;
				if (!self.motion_gpu) return MOTION_NO_GPU~;
				if (self.llm_plugin_problem("kimodo").len > 0) return MOTION_NO_PLUGIN~;
			case TRAIN: self.capture_ready(g.fed(i, 0))!;
			case ANIMATE:
			case POSE: self.capture_ready(g.fed(i, 2))!;
			default: self.capture_ready("", false)!;
		}
	}
	g.blocker = -1;
	g.failed = -1;
	foreach (i : order) g.queue.push(i);
	g.version++;
	self.advance_pipeline();
}

fn void? AppState.run_node(&self, PipelineGraph* g, usz node) => self.run_nodes(g, (usz[]){ node });

<*
 The nodes running `node` takes, upstream first; ready ones are skipped, but
 never `node` itself. A setting that is not there refuses the run.
*>
fn void? AppState.node_order(&self, PipelineGraph* g, usz node, List{usz}* order)
{
	PipelineNode* n = g.at(node);
	if (node_is_source(n.kind))
	{
		if (self.node_ready(g, node)) return;
		g.blocker = (sz)node;
		return NODE_SOURCE_MISSING~;
	}
	for (usz k = 0; k < node_inputs(n.kind); k++)
	{
		sz src = n.input[k];
		if (src < 0)
		{
			if (node_input(n.kind, k).optional) continue;
			g.blocker = (sz)node;
			fault missing = node_unwired(n.kind, k);
			return missing~;
		}
		if (!self.node_ready(g, (usz)src)) self.node_order(g, (usz)src, order)!;
	}
	switch (n.kind)
	{
		case TRAIN:
			uint? poses = n.params[0].trim().to_uint();
			if (catch poses) return CAPTURE_BAD_POSES~;
			if (poses < 50 || poses > 20000) return CAPTURE_BAD_POSES~;
			uint? size = n.params[1].trim().to_uint();
			if (catch size) return CAPTURE_BAD_SIZE~;
			if (!capture_size_ok(size)) return CAPTURE_BAD_SIZE~;
		case ANIMATE:
			if (self.capture_reference_for("").len == 0) return CAPTURE_NO_REFERENCE~;
			if (self.has_bound_clip_named(g.clip_name(node))) return CAPTURE_CLIP_TAKEN~;
		case POSE:
			if (self.capture_reference_for("").len == 0) return CAPTURE_NO_REFERENCE~;
			if (self.saved_pose_named(g.clip_name(node)) >= 0) return CAPTURE_POSE_TAKEN~;
		case TEXT_TO_MOTION:
			MotionRequest request;
			self.node_request(g, node, &request)!;
		default:
			break;
	}
	if (!order.contains(node)) order.push(node);
}

// What an input left unwired refuses the run with.
fn fault node_unwired(NodeKind kind, usz k) @local
{
	switch (node_input(kind, k).link)
	{
		case ENCODER:
		case MOTION_MODEL: return MOTION_NO_GENERATOR;
		case PROMPT_TEXT: return MOTION_NO_PROMPT;
		case BACKBONE: return CAPTURE_NO_BACKBONE;
		case FINDER: return CAPTURE_NO_FINDER;
		case STILL: return CAPTURE_NO_IMAGE;
		default: return CAPTURE_NO_VIDEO;
	}
}

<*
 A Text to motion node's request, from its settings and what is wired in; the
 strings borrow the graph. Refused with what is wrong with a setting.
*>
fn void? AppState.node_request(&self, PipelineGraph* g, usz node, MotionRequest* out)
{
	PipelineNode* n = g.at(node);
	float? seconds = n.params[1].trim().to_float();
	if (catch seconds) return MOTION_BAD_SECONDS~;
	if (!(seconds >= MOTION_MIN_SECONDS && seconds <= MOTION_MAX_SECONDS)) return MOTION_BAD_SECONDS~;
	uint? seed = n.params[2].trim().to_uint();
	if (catch seed) return MOTION_BAD_SEED~;
	uint? steps = n.params[3].trim().to_uint();
	if (catch steps) return MOTION_BAD_STEPS~;
	if (steps < 1 || steps > MOTION_MAX_STEPS) return MOTION_BAD_STEPS~;
	// Unnamed is "Generated N"; a name the character holds is refused rather
	// than doubled, since clips are picked out by name.
	String name = n.params[0].trim();
	if (name.len == 0)
	{
		name = self.next_generated_name(tmem);
	}
	else if (self.has_bound_clip_named(name))
	{
		return MOTION_NAME_TAKEN~;
	}
	*out = { .prompt = g.fed(node, 2), .name = name, .seconds = seconds, .seed = seed, .steps = steps,
		.guide = g.fed(node, 3), .optimize = node_optimize(n.params[4]) };
}

fn void? AppState.start_node(&self, PipelineGraph* g, usz node)
{
	PipelineNode* n = g.at(node);
	switch (n.kind)
	{
		case TEXT_TO_MOTION:
			MotionRequest request;
			self.node_request(g, node, &request)!;
			KimodoModels models = { g.fed(node, 0), g.fed(node, 0, 1), g.fed(node, 1) };
			self.start_motion_generation(request, models)!;
			// The name went to this clip; the next run starts unnamed again.
			g.set_param(node, 0, "");
			g.save();
		case TRAIN:
			usz poses = n.params[0].trim().to_uint() ?? 1500;
			uint size = n.params[1].trim().to_uint() ?? CAPTURE_DEFAULT_SIZE;
			self.start_capture_training(poses, size, self.capture_node_path(n, "renders"), self.capture_node_finder(n), g.fed(node, 0))!;
		case ANIMATE:
		case POSE:
			String finder = self.capture_node_finder(g.at(n.input[0]));
			self.start_capture_animation(g.fed(node, 2), finder, "", g.fed(node, 1), g.clip_name(node), node_mirror_on(n), n.kind == POSE)!;
		default:
			return CAPTURE_NOT_STARTED~;
	}
}

fn void PipelineGraph.fail(&self, sz node, String why)
{
	self.failed = node;
	replace_owned(&self.failure, why);
	self.queue.clear();
}

<*
 A frame of the run: the step that ended read off its job, and the next one
 started once the jobs are free.
*>
fn void AppState.advance_pipeline(&self)
{
	PipelineGraph*? busy = self.running_pipeline();
	if (catch busy) return;
	PipelineGraph* g = busy;
	CaptureJob* job = &self.capture_job;
	if (g.running >= 0)
	{
		NodeKind kind = g.at(g.running).kind;
		if (kind == TEXT_TO_MOTION)
		{
			if (self.motion_job.running) return;
			if (self.motion_job.failed) g.fail(g.running, self.motion_job.last());
		}
		else
		{
			if (job.running || job.reference_pending) return;
			bool ok = !job.failed;
			if (!ok) g.fail(g.running, job.last());
		}
		g.running = -1;
		g.version++;
	}
	if (g.queue.len() == 0 || self.capture_engine_busy()) return;
	usz next = g.queue.pop_first()!!;
	g.running = (sz)next;
	g.version++;
	if (catch err = self.start_node(g, next))
	{
		String why = node_fault_text(err);
		self.@notice("%s could not start: %s", g.at(next).id, why);
		g.fail((sz)next, why);
		g.running = -1;
	}
}

// Stop whatever a graph is running; the queue goes too.
fn void AppState.stop_pipeline(&self)
{
	if (try g = self.running_pipeline())
	{
		if (g.running >= 0 && g.at(g.running).kind == TEXT_TO_MOTION)
		{
			self.stop_motion_generation();
			g.stop_run();
			return;
		}
	}
	self.stop_capture();
}

fn void AppState.stop_runs(&self)
{
	foreach (&g : self.pipelines) g.stop_run();
}

// Stop: the queue goes, and the step running is not marked failed.
fn void PipelineGraph.stop_run(&self)
{
	if (!self.loaded) return;
	self.queue.clear();
	if (self.running >= 0) self.version++;
	self.running = -1;
}

// Why a node will not run, as a phrase.
fn String node_fault_text(fault err)
{
	switch (err)
	{
		case MOTION_NO_GENERATOR:
		case MOTION_NO_PROMPT:
		case MOTION_NO_GPU:
		case MOTION_NO_PLUGIN:
		case MOTION_BUSY:
		case MOTION_NO_SKELETON:
		case MOTION_BAD_SECONDS:
		case MOTION_BAD_SEED:
		case MOTION_BAD_STEPS:
		case MOTION_NAME_TAKEN:
		case MOTION_GUIDE_MISSING:
		case MOTION_GUIDE_UNMATCHED:
		case MOTION_GUIDE_EMPTY:
		case MOTION_NOT_STARTED:
			return motion_fault_text(err);
		case NODE_NOTHING_TO_RUN: return "it is a setting: run a node it is wired into";
		case NODE_SOURCE_MISSING: return "a node it needs is not set, or its file is not there";
		default: return capture_fault_text(err);
	}
}

// ---------------------------------------------------------------------------
// The editor's tables

<*
 Remake the nodes, ports and wires the NodeGraph borrows: each node's input
 ports, then its output, and a wire per wired input.
*>
fn void PipelineGraph.rebuild_view(&self, AppState* app)
{
	self.shown_nodes.clear();
	self.shown_ports.clear();
	self.shown_wires.clear();
	self.port_of.clear();
	self.wire_of.clear();
	// Each node's output port, NO_PORT for one that makes nothing.
	List{usz} output;
	output.init(tmem);
	for (usz i = 0; i < self.count(); i++)
	{
		PipelineNode* n = self.at(i);
		bool note = n.kind == NOTE;
		self.shown_nodes.push({ .pos = n.pos, .width = note ? NOTE_W : NODE_W, .title = NODE_TITLES[n.kind.ordinal], .tag = n.id,
			.header = note ? NOTE_HEADER : (Color) { } });
		for (usz k = 0; k < node_inputs(n.kind); k++)
		{
			NodeInput input = node_input(n.kind, k);
			self.port_of.push({ i, (sz)k });
			self.shown_ports.push({ .node = i, .label = input.name, .color = NODE_LINK_COLORS[input.link.ordinal], .hollow = n.input[k] < 0 });
		}
		NodeLink made;
		if (!node_output(n.kind, &made))
		{
			output.push(NO_PORT);
			continue;
		}
		output.push((usz)self.shown_ports.len());
		self.port_of.push({ i, -1 });
		self.shown_ports.push({ .node = i, .output = true, .label = NODE_LINK_NAMES[made.ordinal], .color = NODE_LINK_COLORS[made.ordinal] });
	}
	for (usz to = 0; to < self.count(); to++)
	{
		PipelineNode* n = self.at(to);
		for (usz k = 0; k < node_inputs(n.kind); k++)
		{
			if (n.input[k] < 0) continue;
			self.wire_of.push({ to, k });
			self.shown_wires.push({ .from = output[n.input[k]], .to = self.port_index(to, (sz)k) });
		}
	}
	self.update_flags(app);
}

const usz NO_PORT = usz::max;

// The editor's port of a node's input (or its output, -1).
fn usz PipelineGraph.port_index(&self, usz node, sz input)
{
	foreach (usz i, p : self.ports()) if (p.node == node && p.input == input) return i;
	return NO_PORT;
}

// The states drawn on the cards and wires: selected, running, failed.
fn void PipelineGraph.update_flags(&self, AppState* app)
{
	if ((usz)self.shown_nodes.len() != self.count()) return;
	foreach (i, &n : self.nodes)
	{
		GraphNode* shown = &self.shown_nodes[i];
		shown.pos = n.pos;
		bool running = self.running == (sz)i;
		shown.flags = { .selected = n.selected, .running = running, .error = self.failed == (sz)i };
		float progress = n.kind == TEXT_TO_MOTION ? app.motion_job.progress() : app.capture_job.progress();
		shown.progress = running ? math::max(progress, 0.001f) : 0;
	}
	foreach (i, w : self.wire_of)
	{
		self.shown_wires[i].selected = self.wire_node == (sz)w.node && self.wire_input == w.input;
	}
}
