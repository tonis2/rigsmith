// A held prop saves as one empty socket node under its hand, and saving again
// reuses that node rather than adding a second.
module crig_tests::held_prop_save;

import crig;
import gltf_edit;
import rig;
import std::core::test;
import std::io::file;

const String PROP_COPY = "build/held-prop-humanoid.glb";

// The node named `name`, or -1, and how many carry it.
fn sz node_named(String[] nodes, String name, usz* count) @local
{
	String wanted = string::tformat(`"%s"`, name);
	sz found = -1;
	*count = 0;
	foreach (usz i, node : nodes)
	{
		if (gltf_edit::read_gltf_member(node, {{ .key = "name" }}) != wanted) continue;
		if (found < 0) found = (sz)i;
		(*count)++;
	}
	return found;
}

fn bool has_child(String node, usz child) @local
{
	String listed = gltf_edit::read_gltf_member(node, {{ .key = "children" }});
	if (listed.len == 0) return false;
	String[] items = gltf_edit::json_array_items(mem, listed)!!;
	defer alloc::free(mem, items);
	foreach (item : items) if ((item.trim().to_int() ?? -1) == (int)child) return true;
	return false;
}

// The file's nodes, and whether exactly one socket hangs under wrist_R.
fn usz saved_socket(usz* nodes_out) @local
{
	gltf_edit::GlbParts parts = gltf_edit::split_glb(mem, PROP_COPY)!!;
	defer parts.free(mem);
	String nodes_text = gltf_edit::read_gltf_member((String)parts.json, {{ .key = "nodes" }});
	String[] nodes = gltf_edit::json_array_items(mem, nodes_text)!!;
	defer alloc::free(mem, nodes);
	*nodes_out = nodes.len;
	usz sockets;
	usz hands;
	sz socket = node_named(nodes, "wrist_R.socket", &sockets);
	sz hand = node_named(nodes, "wrist_R", &hands);
	if (socket < 0 || hand < 0) return 0;
	test::@check(has_child(nodes[(usz)hand], (usz)socket), "the socket is not a child of wrist_R");
	test::@check(gltf_edit::read_gltf_member(nodes[(usz)socket], {{ .key = "mesh" }}).len == 0, "the socket carries a mesh");
	return sockets;
}

fn void a_second_save_keeps_one_socket() @test
{
	char[] original = file::load(mem, "assets/animations/humanoid.glb")!!;
	defer alloc::free(mem, original);
	file::save(PROP_COPY, original)!!;
	defer (void)file::delete(PROP_COPY);

	rig::TriMesh mesh = rig::load_gltf(mem, PROP_COPY)!!;
	defer mesh.free(mem);
	crig::AppState app = crig::new_app(mesh, PROP_COPY);
	defer app.free();
	test::@check(app.import_rig_from_source(), "the humanoid rig must import");

	uint wrist;
	foreach (dot : app.doc.dots.array_view()) if (dot.name == "wrist_R") wrist = dot.id;
	test::@check(wrist != 0, "the humanoid has no wrist_R");
	test::@check(app.is_hand(wrist), "wrist_R is not a hand");
	test::@check(app.hold_prop(wrist, crig::PropKind.SWORD), "the sword was not put in the hand");

	test::@check(app.write_rig_into_model(PROP_COPY), "the first save failed: %s", app.notice());
	usz first_nodes;
	test::@check(saved_socket(&first_nodes) == 1, "the first save did not write one socket");

	test::@check(app.write_rig_into_model(PROP_COPY), "the second save failed: %s", app.notice());
	usz second_nodes;
	test::@check(saved_socket(&second_nodes) == 1, "the second save did not keep one socket");
	test::@check(second_nodes == first_nodes, "the second save has %d nodes, the first %d", second_nodes, first_nodes);
}
