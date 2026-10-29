<*
 The Capture pane's graph (`ui/capture_panel.c3` draws it with cui's
 NodeGraph): the capture's steps as nodes the user wires together, saved as
 `<model>.capture/graph.json` in llm-runner's graph shape,

     { "nodes": [ { "id", "type", "params": { "name": "text" | { "from": "node.port" } }, "pos": [x, y] } ] }

 Finder file, Train finder, Reference picture and Video make what Animate
 takes. Running a node runs the nodes upstream of it that are not done yet,
 then the node itself, one capture step at a time.
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

faultdef CAPTURE_CLIP_TAKEN, CAPTURE_BAD_POSES;

enum CaptureNodeKind : char
{
	FINDER_FILE,
	TRAIN,
	REFERENCE,
	VIDEO,
	ANIMATE,
}

// What a wire carries.
enum CaptureLink : char
{
	FINDER,
	PICTURE,
	FOOTAGE,
}

const usz CAPTURE_PARAMS = 3;
const usz CAPTURE_INPUTS = 3;
const float CAPTURE_NODE_W = 230;
const String[5] CAPTURE_TYPES = { "finder_file", "train_finder", "reference", "video", "animate" };
const String[5] CAPTURE_TITLES = { "Finder file", "Train finder", "Reference picture", "Video", "Animate" };
const String[5] CAPTURE_ID_BASES = { "finder", "train", "reference", "video", "animate" };
// Each kind's settings by slot; "" = no setting there.
const String[CAPTURE_PARAMS][5] CAPTURE_PARAM_NAMES = {
	{ "path", "", "" },
	{ "poses", "", "" },
	{ "pose", "time", "action" },
	{ "path", "", "" },
	{ "name", "", "" },
};
// Animate's inputs, in order.
const String[CAPTURE_INPUTS] CAPTURE_INPUT_NAMES = { "finder", "picture", "video" };
const CaptureLink[CAPTURE_INPUTS] CAPTURE_INPUT_LINKS = { FINDER, PICTURE, FOOTAGE };
const String[3] CAPTURE_LINK_NAMES = { "finder", "picture", "video" };
const Color[3] CAPTURE_LINK_COLORS = { DOT, LABEL, PHYSICS_BONE };

// What a kind makes, if anything.
fn bool capture_output(CaptureNodeKind kind, CaptureLink* link)
{
	switch (kind)
	{
		case FINDER_FILE:
		case TRAIN: *link = FINDER;
		case REFERENCE: *link = PICTURE;
		case VIDEO: *link = FOOTAGE;
		case ANIMATE: return false;
	}
	return true;
}

fn usz capture_inputs(CaptureNodeKind kind) => kind == ANIMATE ? CAPTURE_INPUTS : 0;

struct CaptureNode
{
	CaptureNodeKind kind;
	String id; // owned
	Vec2 pos;
	String[CAPTURE_PARAMS] params; // owned; "" = unset
	sz[CAPTURE_INPUTS] input; // the node wired into each input, -1 = none
	bool selected;
}

fn void CaptureNode.free(&self)
{
	if (self.id.len > 0) self.id.free(mem);
	foreach (p : self.params) if (p.len > 0) p.free(mem);
	*self = { };
}

// One of the editor's ports: a node's input slot, or its output (-1).
struct CapturePort
{
	usz node;
	sz input;
}

// One of the editor's wires, by the input it ends on.
struct CaptureWire
{
	usz node;
	usz input;
}

struct CaptureGraph
{
	bool loaded;
	String folder; // owned: the capture folder it belongs to
	List{CaptureNode} nodes;
	View2D view;
	uint version; // bumped by every change the pane rebuilds for
	// The picked wire, by the input it ends on; -1 = none.
	sz wire_node;
	usz wire_input;
	// The run: the nodes still to run, the one running, the one that failed.
	List{usz} queue;
	sz running;
	sz failed;
	// The editor's borrowed tables, remade by `rebuild_view`.
	List{GraphNode} shown_nodes;
	List{GraphPort} shown_ports;
	List{GraphWire} shown_wires;
	List{CapturePort} port_of;
	List{CaptureWire} wire_of;
}

fn void CaptureGraph.free(&self)
{
	foreach (&n : self.nodes) n.free();
	self.nodes.free();
	self.queue.free();
	self.shown_nodes.free();
	self.shown_ports.free();
	self.shown_wires.free();
	self.port_of.free();
	self.wire_of.free();
	if (self.folder.len > 0) self.folder.free(mem);
	*self = { };
}

// Empty, for the capture folder `folder`.
fn void CaptureGraph.reset(&self, String folder)
{
	uint version = self.version;
	self.free();
	self.loaded = true;
	self.folder = folder.copy(mem);
	self.nodes.init(mem);
	self.queue.init(mem);
	self.shown_nodes.init(mem);
	self.shown_ports.init(mem);
	self.shown_wires.init(mem);
	self.port_of.init(mem);
	self.wire_of.init(mem);
	self.view = { .pan = { -20, -20 } };
	self.wire_node = self.running = self.failed = -1;
	self.version = version + 1;
}

// The graph of the model's capture folder, read when the folder changes.
fn CaptureGraph* AppState.capture_graph_now(&self)
{
	CaptureGraph* g = &self.capture_graph;
	String folder = self.capture_folder();
	if (g.loaded && g.folder == folder) return g;
	g.reset(folder);
	bool read;
	if (folder.len > 0)
	{
		if (try char[] text = file::load_temp(self.capture_path("graph.json"))) read = @ok(g.read_json((String)text));
	}
	if (!read)
	{
		g.reset(folder);
		String chosen = self.capture_finder();
		g.default_graph(chosen == self.capture_path("finder.safetensors") ? "" : chosen);
	}
	return g;
}

<*
 A new capture's graph: the finder, the picture and the video into Animate.
 A finder chosen before (`chosen`) comes in as a Finder file node.
*>
fn void CaptureGraph.default_graph(&self, String chosen)
{
	usz finder = chosen.len > 0 ? self.add(FINDER_FILE, { 40, 40 }) : self.add(TRAIN, { 40, 40 });
	if (chosen.len > 0) self.set_param(finder, 0, chosen);
	usz reference = self.add(REFERENCE, { 40, 190 });
	usz video = self.add(VIDEO, { 40, 400 });
	usz animate = self.add(ANIMATE, { 360, 190 });
	(void)self.connect(finder, animate, 0);
	(void)self.connect(reference, animate, 1);
	(void)self.connect(video, animate, 2);
}

macro CaptureNode* CaptureGraph.at(&self, node) => self.nodes.get_ref((sz)node);
fn usz CaptureGraph.count(&self) => (usz)self.nodes.len();
fn CapturePort[] CaptureGraph.ports(&self) => self.port_of.array_view();
fn CaptureWire[] CaptureGraph.wires(&self) => self.wire_of.array_view();

fn sz CaptureGraph.find(&self, String id)
{
	foreach (i, &n : self.nodes) if (n.id == id) return (sz)i;
	return -1;
}

fn String CaptureGraph.fresh_id(&self, CaptureNodeKind kind)
{
	String base = CAPTURE_ID_BASES[kind.ordinal];
	if (self.find(base) < 0) return base.tcopy();
	for (int i = 2; ; i++)
	{
		String id = string::tformat("%s%d", base, i);
		if (self.find(id) < 0) return id;
	}
}

fn usz CaptureGraph.add(&self, CaptureNodeKind kind, Vec2 pos)
{
	CaptureNode n = { .kind = kind, .id = self.fresh_id(kind).copy(mem), .pos = pos, .input = { -1, -1, -1 } };
	if (kind == TRAIN) n.params[0] = string::format(mem, "%d", CAPTURE_DEFAULT_POSES);
	if (kind == REFERENCE) n.params[1] = "0".copy(mem);
	self.nodes.push(n);
	return self.count() - 1;
}

// A node and the wires into and out of it.
fn void CaptureGraph.remove(&self, usz node)
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
fn usz CaptureGraph.duplicate(&self, usz node)
{
	CaptureNode* n = self.at(node);
	usz copy = self.add(n.kind, n.pos + (Vec2) { 30, 30 });
	n = self.at(node);
	foreach (usz slot, p : n.params) self.set_param(copy, slot, p);
	return copy;
}

fn void CaptureGraph.set_param(&self, usz node, usz slot, String text)
{
	replace_owned(&self.at(node).params[slot], text);
}

<*
 Wire `from`'s output into `to`'s input `input`, replacing what fed it. Only
 Animate takes wires and it makes nothing, so a wire cannot close a loop.

 @return `False when the output is not what the input takes.`
*>
fn bool CaptureGraph.connect(&self, usz from, usz to, usz input)
{
	if (from == to || input >= capture_inputs(self.at(to).kind)) return false;
	CaptureLink made;
	if (!capture_output(self.at(from).kind, &made) || made != CAPTURE_INPUT_LINKS[input]) return false;
	self.at(to).input[input] = (sz)from;
	return true;
}

fn void CaptureGraph.disconnect(&self, usz node, usz input)
{
	self.at(node).input[input] = -1;
	if (self.wire_node == (sz)node && self.wire_input == input) self.wire_node = -1;
}

// A change the pane rebuilds for, saved.
fn void CaptureGraph.changed(&self)
{
	self.version++;
	self.save();
}

fn bool CaptureGraph.busy(&self) => self.running >= 0 || self.queue.len() > 0;

// ---------------------------------------------------------------------------
// graph.json

// The graph as graph.json says it. Owned.
fn String CaptureGraph.to_json(&self)
{
	DString out = dstring::new(mem);
	defer out.free();
	out.appendf("{\n  \"view\": { \"pan\": [%.1f, %.1f], \"zoom\": %.3f },\n  \"nodes\": [", self.view.pan.x, self.view.pan.y, self.view.zoom > 0 ? self.view.zoom : 1.0f);
	foreach (i, &n : self.nodes)
	{
		out.append_string(i == 0 ? "\n    { \"id\": " : ",\n    { \"id\": ");
		gltf_edit::escape_json_string(&out, n.id);
		out.appendf(", \"type\": \"%s\", \"pos\": [%.0f, %.0f], \"params\": {", CAPTURE_TYPES[n.kind.ordinal], n.pos.x, n.pos.y);
		bool first = true;
		foreach (slot, name : CAPTURE_PARAM_NAMES[n.kind.ordinal])
		{
			if (name.len == 0) continue;
			out.appendf("%s\"%s\": ", first ? " " : ", ", name);
			gltf_edit::escape_json_string(&out, n.params[slot]);
			first = false;
		}
		for (usz k = 0; k < capture_inputs(n.kind); k++)
		{
			if (n.input[k] < 0) continue;
			CaptureNode* src = self.at(n.input[k]);
			CaptureLink made;
			(void)capture_output(src.kind, &made);
			out.appendf("%s\"%s\": { \"from\": ", first ? " " : ", ", CAPTURE_INPUT_NAMES[k]);
			gltf_edit::escape_json_string(&out, string::tformat("%s.%s", src.id, CAPTURE_LINK_NAMES[made.ordinal]));
			out.append_string(" }");
			first = false;
		}
		out.append_string(" } }");
	}
	out.append_string("\n  ]\n}\n");
	return out.copy_str(mem);
}

fn void CaptureGraph.save(&self)
{
	if (self.folder.len == 0) return;
	(void)path::mkdir(self.folder, true);
	String text = self.to_json();
	defer text.free(mem);
	(void)file::save(string::tformat("%s/graph.json", self.folder), text);
}

<*
 Read graph.json's nodes and wires into an empty graph. Nodes of a type it
 does not know are left out, and wires from nodes that are not there.
*>
fn void? CaptureGraph.read_json(&self, String text)
{
	Object* parsed = json::parse(tmem, text)!;
	if (try Object* view = parsed.get("view"))
	{
		if (try Object* pan = view.get("pan")) self.view.pan = { (float)(pan.get_float_at(0) ?? 0), (float)(pan.get_float_at(1) ?? 0) };
		if (try double zoom = view.get_float("zoom")) self.view.zoom = (float)zoom;
	}
	Object* nodes = parsed.get("nodes")!;
	if (!nodes.is_array()) return CAPTURE_NOT_STARTED~;
	for (sz i = 0; i < nodes.get_len(); i++)
	{
		Object* entry = nodes.get_at(i);
		String type = entry.get_string("type") ?? "";
		sz kind = -1;
		foreach (k, known : CAPTURE_TYPES) if (known == type) kind = (sz)k;
		String id = entry.get_string("id") ?? "";
		if (kind < 0 || id.len == 0 || self.find(id) >= 0) continue;
		Vec2 pos = { 40, 40 };
		if (try Object* at = entry.get("pos")) pos = { (float)(at.get_float_at(0) ?? 40), (float)(at.get_float_at(1) ?? 40) };
		CaptureNode n = { .kind = (CaptureNodeKind)(int)kind, .id = id.copy(mem), .pos = pos, .input = { -1, -1, -1 } };
		if (try Object* params = entry.get("params"))
		{
			foreach (slot, name : CAPTURE_PARAM_NAMES[kind])
			{
				if (name.len == 0) continue;
				if (try String value = params.get_string(name)) if (value.len > 0) n.params[slot] = value.copy(mem);
			}
		}
		self.nodes.push(n);
	}
	// The wires, once every node they name is in.
	for (sz i = 0; i < nodes.get_len(); i++)
	{
		Object* entry = nodes.get_at(i);
		sz to = self.find(entry.get_string("id") ?? "");
		if (to < 0) continue;
		Object*? params = entry.get("params");
		if (catch params) continue;
		foreach (k, name : CAPTURE_INPUT_NAMES)
		{
			Object*? wire = params.get(name);
			if (catch wire) continue;
			String from = wire.get_string("from") ?? "";
			usz cut = from.len;
			if (try dot = from.rindex_of_char('.')) cut = (usz)dot;
			sz src = self.find(from[:cut]);
			if (src >= 0) (void)self.connect((usz)src, (usz)to, (usz)k);
		}
	}
}

// ---------------------------------------------------------------------------
// What each node makes, and where.

<*
 A Train or Reference node's own path in the capture folder: the first of each
 (`train`, `reference`) keeps the folder's own names, so a capture from before
 the graph carries on. Temporary.
*>
fn String AppState.capture_node_path(&self, CaptureNode* n, String own)
{
	if (n.id == CAPTURE_ID_BASES[n.kind.ordinal]) return self.capture_path(own);
	return self.capture_path(string::tformat("%s/%s", n.id, own));
}

// The finder a Finder file or Train node gives. Temporary.
fn String AppState.capture_node_finder(&self, CaptureNode* n)
{
	if (n.kind == FINDER_FILE) return n.params[0].trim();
	return self.capture_node_path(n, "finder.safetensors");
}

// The clip an Animate node makes: its name, or its video's file name. Temporary.
fn String CaptureGraph.clip_name(&self, usz node)
{
	CaptureNode* n = self.at(node);
	if (n.params[0].trim().len > 0) return n.params[0].trim();
	sz video = n.input[2];
	return capture_clip_name(video >= 0 ? self.at(video).params[0].trim() : "");
}

// Whether a node's work is there already, so running past it skips it.
fn bool AppState.capture_node_ready(&self, usz node)
{
	CaptureGraph* g = &self.capture_graph;
	CaptureNode* n = g.at(node);
	switch (n.kind)
	{
		case FINDER_FILE:
		case TRAIN:
			String finder = self.capture_node_finder(n);
			return finder.len > 0 && file::exists(finder);
		case REFERENCE: return file::exists(string::tformat("%s/studio.json", self.capture_node_path(n, "studio")));
		case VIDEO: return n.params[0].trim().len > 0 && path::exists((Path)n.params[0].trim());
		case ANIMATE: return self.has_bound_clip_named(g.clip_name(node));
	}
}

// ---------------------------------------------------------------------------
// Running.

<*
 Run `node`, after the nodes upstream of it that are not ready yet. Refused
 with what is missing before anything starts.
*>
fn void? AppState.run_capture_node(&self, usz node)
{
	CaptureGraph* g = &self.capture_graph;
	if (self.capture_engine_busy() || g.busy()) return CAPTURE_BUSY~;
	List{usz} order;
	order.init(tmem);
	self.capture_order(node, &order)!;
	bool engine;
	foreach (i : order) if (g.at(i).kind != REFERENCE) engine = true;
	self.capture_ready(engine)!;
	g.failed = -1;
	foreach (i : order) g.queue.push(i);
	g.version++;
	self.advance_capture_graph();
}

<*
 The nodes running `node` takes, upstream first; ready ones are skipped, but
 never `node` itself.
*>
fn void? AppState.capture_order(&self, usz node, List{usz}* order)
{
	CaptureGraph* g = &self.capture_graph;
	CaptureNode* n = g.at(node);
	switch (n.kind)
	{
		case FINDER_FILE: return CAPTURE_NO_FINDER~;
		case VIDEO: return CAPTURE_NO_VIDEO~;
		case TRAIN:
			uint? poses = n.params[0].trim().to_uint();
			if (catch poses) return CAPTURE_BAD_POSES~;
			if (poses < 50 || poses > 20000) return CAPTURE_BAD_POSES~;
		case ANIMATE:
			foreach (k, src : n.input)
			{
				if (src < 0)
				{
					fault missing = k == 0 ? CAPTURE_NO_FINDER : k == 1 ? CAPTURE_NO_REFERENCE : CAPTURE_NO_VIDEO;
					return missing~;
				}
				if (!self.capture_node_ready((usz)src)) self.capture_order((usz)src, order)!;
			}
			if (self.has_bound_clip_named(g.clip_name(node))) return CAPTURE_CLIP_TAKEN~;
		case REFERENCE:
			break;
	}
	if (!order.contains(node)) order.push(node);
}

fn void? AppState.start_capture_node(&self, usz node)
{
	CaptureGraph* g = &self.capture_graph;
	CaptureNode* n = g.at(node);
	switch (n.kind)
	{
		case TRAIN:
			usz poses = n.params[0].trim().to_uint() ?? (uint)CAPTURE_DEFAULT_POSES;
			self.start_capture_training(poses, self.capture_node_path(n, "renders"), self.capture_node_finder(n))!;
		case REFERENCE:
			float time = n.params[1].trim().to_float() ?? 0.0f;
			self.request_capture_reference(self.capture_node_path(n, "studio"), n.params[0], time)!;
		case ANIMATE:
			String finder = self.capture_node_finder(g.at(n.input[0]));
			String studio = self.capture_node_path(g.at(n.input[1]), "studio");
			self.start_capture_animation(finder, studio, g.at(n.input[2]).params[0], g.clip_name(node))!;
		default:
			return CAPTURE_NOT_STARTED~;
	}
}

<*
 A frame of the run: the step that ended read off the job, and the next one
 started once the job is free.
*>
fn void AppState.advance_capture_graph(&self)
{
	CaptureGraph* g = &self.capture_graph;
	if (!g.loaded) return;
	CaptureJob* job = &self.capture_job;
	if (g.running >= 0)
	{
		if (job.running || job.reference_pending) return;
		bool ok = g.at(g.running).kind == REFERENCE ? job.reference_ok : !job.failed;
		if (!ok)
		{
			g.failed = g.running;
			g.queue.clear();
		}
		g.running = -1;
		g.version++;
	}
	if (g.queue.len() == 0 || self.capture_engine_busy()) return;
	usz next = g.queue.pop_first()!!;
	g.running = (sz)next;
	g.version++;
	if (catch err = self.start_capture_node(next))
	{
		self.@notice("%s could not start: %s", g.at(next).id, capture_fault_text(err));
		g.failed = (sz)next;
		g.running = -1;
		g.queue.clear();
	}
}

// Stop: the queue goes, and the step running is not marked failed.
fn void CaptureGraph.stop_run(&self)
{
	if (!self.loaded) return;
	self.queue.clear();
	if (self.running >= 0) self.version++;
	self.running = -1;
}

// ---------------------------------------------------------------------------
// The editor's tables

<*
 Remake the nodes, ports and wires the NodeGraph borrows: each node's input
 ports, then its output, and a wire per wired input.
*>
fn void CaptureGraph.rebuild_view(&self, AppState* app)
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
		CaptureNode* n = self.at(i);
		self.shown_nodes.push({ .pos = n.pos, .width = CAPTURE_NODE_W, .title = CAPTURE_TITLES[n.kind.ordinal], .tag = n.id });
		for (usz k = 0; k < capture_inputs(n.kind); k++)
		{
			CaptureLink link = CAPTURE_INPUT_LINKS[k];
			self.port_of.push({ i, (sz)k });
			self.shown_ports.push({ .node = i, .label = CAPTURE_INPUT_NAMES[k], .color = CAPTURE_LINK_COLORS[link.ordinal], .hollow = n.input[k] < 0 });
		}
		CaptureLink made;
		if (!capture_output(n.kind, &made))
		{
			output.push(NO_PORT);
			continue;
		}
		output.push((usz)self.shown_ports.len());
		self.port_of.push({ i, -1 });
		self.shown_ports.push({ .node = i, .output = true, .label = CAPTURE_LINK_NAMES[made.ordinal], .color = CAPTURE_LINK_COLORS[made.ordinal] });
	}
	for (usz to = 0; to < self.count(); to++)
	{
		CaptureNode* n = self.at(to);
		for (usz k = 0; k < capture_inputs(n.kind); k++)
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
fn usz CaptureGraph.port_index(&self, usz node, sz input)
{
	foreach (usz i, p : self.ports()) if (p.node == node && p.input == input) return i;
	return NO_PORT;
}

// The states drawn on the cards and wires: selected, running, failed.
fn void CaptureGraph.update_flags(&self, AppState* app)
{
	if ((usz)self.shown_nodes.len() != self.count()) return;
	foreach (i, &n : self.nodes)
	{
		GraphNode* shown = &self.shown_nodes[i];
		shown.pos = n.pos;
		bool running = self.running == (sz)i;
		shown.flags = { .selected = n.selected, .running = running, .error = self.failed == (sz)i };
		shown.progress = running ? math::max(app.capture_job.progress(), 0.001f) : 0;
	}
	foreach (i, w : self.wire_of)
	{
		self.shown_wires[i].selected = self.wire_node == (sz)w.node && self.wire_input == w.input;
	}
}
