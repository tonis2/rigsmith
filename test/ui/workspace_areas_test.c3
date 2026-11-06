module crig_tests::ui;
import crig;
import libc;
import cui;
import cui::widgets;
import c3w;
import rig;
import gltf;
import collision;
import crig_tests::library;
import crig_tests::shared_app;
import std::core::test;
import std::io;
import std::math;

// ---------------------------------------------------------------------------
// The split-area workspace (cui's areas): per-pane tabs, splitting, closing
// and merging through the right-click context menu, the divider drag, and the
// Animations panel. The strip's tab math is re-derived here the way the widget
// derives it — measured labels with the pad floor — so every gesture aims at
// the same pixels a user would.

// The registered views, in the order `crig::area_views` holds them — the strip
// draws one tab per entry and `tab_center` measures its way along them, so a name
// here that is not the view's own aims every click after it at the wrong pixels.
const String[6] AREA_TAB_NAMES = { "3D View", "Assets", "Motion & Physics", "Animations", "Scene", "Generate" };

// Which tab is which, so a check that wants a pane on a view says so rather than
// counting.
const usz TAB_3D = 0;
const usz TAB_ASSETS = 1;
const usz TAB_PHYSICS = 2;
const usz TAB_ANIMATIONS = 3;
const usz TAB_SCENE = 4;

fn float tab_w(Fixture* fixture, String name)
{
	AreaStyle s = crig::AREA_STYLE;
	float text  = fixture.ui.text.measure(s.font, name, s.text_size).x;
	return math::max(text + 2 * s.pad_x, 2 * s.pad_x);
}

fn Vec2 tab_center(Fixture* fixture, Element* strip, usz index)
{
	float x = 0;
	for (usz i = 0; i < index; i++) x += tab_w(fixture, AREA_TAB_NAMES[i]);
	return strip.absolute + (Vec2) { x + tab_w(fixture, AREA_TAB_NAMES[index]) * 0.5f, TAB_H * 0.5f };
}

<*
 Right-click at `at` and click the named context-menu row — the one way panes
 split, close and merge.
*>
fn void pick_context(Fixture* fixture, Vec2 at, String label)
{
	fixture.right_click(at);
	Element*? row = fixture.ui.find_id(label);
	if (catch row)
	{
		test::@check(false, "SKIPPED — no context row to pick");
		return;
	}
	fixture.click(row.absolute + row.size * 0.5f);
}

fn usz count_viewports(Fixture* fixture)
{
	usz n = 0;
	fixture.ui.@each(Viewport ; v)
	{
		n++;
	};
	return n;
}

// The text field for setting `slot` on the card of node `id`.
fn Element*? node_field(Fixture* fixture, String id, usz slot)
{
	crig::PipelineGraph* g = fixture.app.pipeline();
	Element* graph = fixture.ui.find_id(crig::NODES_GRAPH_ID)!;
	foreach (card : graph.children)
	{
		if (!card.is_widget(NodeCard) || (sz)card.widget_as(NodeCard).node != g.find(id)) continue;
		return card.find_id(crig::NODE_FIELD_IDS[slot]);
	}
	return NOT_FOUND~;
}

// A card's chooser, with the pointer on it so its choice finds the card.
// A card's icon pressed, from over its card.
fn void node_press(Fixture* fixture, String button_id)
{
	Element* found = fixture.ui.find_id(button_id)!!;
	fixture.ui.hovered = found;
	found.widget_as(Button).on_click(fixture.ui);
}

// Whether the Animate card's mirror icon is drawn lit.
fn bool mirror_lit(Fixture* fixture)
{
	Element* found = fixture.ui.find_id(crig::NODE_MIRROR_ID)!!;
	return found.widget_as(Button).style.color == crig::ACCENT;
}

fn Select*? node_select(Fixture* fixture, String select_id)
{
	Element* found = fixture.ui.find_id(select_id)!;
	fixture.ui.hovered = found;
	return found.widget_as(Select);
}

<*
 Text to motion and video capture share the Nodes pane, a tab beside Assets
 under the Scene outliner. It opens on the Text to motion template; the bar on
 top picks another. What is typed on a card goes into its node and survives the
 pane rebuilding.
*>
fn void the_nodes_pane_is_open_and_keeps_what_is_typed() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	fixture.reset();
	crig::build_ui(fixture.ui, &fixture.app);
	fixture.ui.flush();
	// A tab away in the default workspace, beside Assets.
	test::@check(!@ok(fixture.ui.find_id(crig::NODES_PANEL_ID)), "the default workspace opened on Nodes");
	crig::show_pane_view(fixture.ui, crig::NODES_VIEW, SplitAxis.HORIZONTAL, 2.0f / 3.0f);
	fixture.feed(VIEWPORT_CENTER);
	fixture.ui.flush();
	test::@check(@ok(fixture.ui.find_id(crig::NODES_PANEL_ID)), "Nodes did not open");
	test::@check(crig::query_nodes(fixture.ui).checked, "the menu does not tick Nodes while it shows");
	Select* template = node_select(fixture, crig::NODES_TEMPLATE_ID)!!;
	test::@check(template.selected == 0 && template.options[0] == "Text to motion", "the bar does not open on Text to motion: row %d", template.selected);
	test::@check(@ok(fixture.ui.find_id("node-run-generate")) && !@ok(fixture.ui.find_id("node-run-train")), "only text to motion's nodes show");
	test::@check((node_field(fixture, "note", 0)!!).widget_as(TextField).value().contains("Prompt"), "the template's note is not on the canvas");

	crig::PipelineGraph* g = fixture.app.pipeline();
	Element*? prompt = node_field(fixture, "prompt", 0);
	if (catch prompt)
	{
		test::@check(false, "no prompt field on the Prompt card");
		return;
	}
	// The template's prompt goes first.
	prompt.widget_as(TextField).set_text(prompt, "");
	fixture.type_into(prompt, "a person waves");
	test::@check(g.at(g.find("prompt")).params[0] == "a person waves", "the prompt node reads '%s'", g.at(g.find("prompt")).params[0]);
	test::@check((node_field(fixture, "generate", 1)!!).widget_as(TextField).value() == "5"
		&& (node_field(fixture, "generate", 2)!!).widget_as(TextField).value() == "0", "the length and seed do not start at 5 and 0");
	crig::refresh_nodes_view(fixture.ui);
	fixture.ui.flush();
	test::@check((node_field(fixture, "prompt", 0)!!).widget_as(TextField).value() == "a person waves", "a rebuild lost the prompt");

	// Guide poses offer None and every bound clip, and a clip bound while the
	// pane is up joins the list.
	Select* guide = node_select(fixture, crig::NODE_GUIDE_ID)!!;
	test::@check(guide.options.len >= 1 && guide.options[0] == "None" && guide.selected == 0, "the guide chooser does not start on None");
	crig::AnimKeyframe[] frames = alloc::new_array(mem, crig::AnimKeyframe, 1);
	crig::AnimRef authored = fixture.app.author_clip({ .name = "Guide pose".copy(mem), .duration = 1.0f,
		.keyframes = frames, .owned = true });
	test::@check(authored.valid(), "the guide clip was not authored");
	fixture.feed(VIEWPORT_CENTER);
	fixture.ui.flush();
	guide = node_select(fixture, crig::NODE_GUIDE_ID)!!;
	usz row = guide.options.len - 1;
	test::@check(guide.options[row] == "Guide pose", "the new clip is not offered: %s", guide.options);
	guide.on_change(fixture.ui, row);
	test::@check(g.at(g.find("guide")).params[0] == "Guide pose", "the guide node's clip is '%s'", g.at(g.find("guide")).params[0]);

	// Optimize starts on Light, and a level picked is kept through a rebuild.
	Select* optimize = node_select(fixture, crig::NODE_OPTIMIZE_ID)!!;
	test::@check(optimize.options.len == 3 && optimize.selected == crig::KeyReduction.LIGHT.ordinal,
		"Optimize does not start on Light: row %d of %s", optimize.selected, optimize.options);
	optimize.on_change(fixture.ui, crig::KeyReduction.STRONG.ordinal);
	test::@check(g.at(g.find("generate")).params[4] == "strong", "the node's level is %s", g.at(g.find("generate")).params[4]);
	crig::refresh_nodes_view(fixture.ui);
	fixture.ui.flush();
	optimize = node_select(fixture, crig::NODE_OPTIMIZE_ID)!!;
	test::@check(optimize.selected == crig::KeyReduction.STRONG.ordinal, "a rebuild lost Strong: row %d", optimize.selected);

	// The bar opens the train template on its own canvas.
	template = node_select(fixture, crig::NODES_TEMPLATE_ID)!!;
	template.on_change(fixture.ui, 1);
	fixture.feed(VIEWPORT_CENTER);
	fixture.ui.flush();
	test::@check(fixture.app.open_template == 1 && fixture.app.config.nodes_template == 1, "the choice is not kept");
	foreach (run : (String[]){ "node-run-train", "node-run-animate" })
	{
		test::@check(@ok(fixture.ui.find_id(run)), "no %s on the train template", run);
	}
	test::@check(!@ok(fixture.ui.find_id("node-run-generate")), "text to motion's nodes still show");
	test::@check(!@ok(fixture.ui.find_id("node-run-reference")), "a Reference node is still in the template");
	g = fixture.app.pipeline();
	// Train starts at 1500 poses, and a video typed is the Video node's.
	test::@check((node_field(fixture, "train", 0)!!).widget_as(TextField).value() == "1500", "the training set does not start at 1500 poses");
	Select* size = node_select(fixture, crig::NODE_SIZE_ID)!!;
	test::@check(size.options.len == 6 && size.selected == 0 && size.options[0] == "448 px", "Size does not start on 448 px: row %d of %s", size.selected, size.options);
	size.on_change(fixture.ui, 2);
	test::@check(g.at(g.find("train")).params[1] == "640", "the train node's size is %s", g.at(g.find("train")).params[1]);
	crig::refresh_nodes_view(fixture.ui);
	fixture.ui.flush();
	test::@check((node_select(fixture, crig::NODE_SIZE_ID)!!).selected == 2, "a rebuild lost 640 px");
	test::@check(!@ok(fixture.ui.find_id("node-reference")), "Video has no Reference dropdown: its first frame finds it");
	fixture.type_into(node_field(fixture, "video", 0)!!, "/clips/wave.mp4");
	test::@check(g.at(g.find("video")).params[0] == "/clips/wave.mp4", "the video node's path reads '%s'", g.at(g.find("video")).params[0]);
	// Animate's mirror check starts on; a click turns it off, another back on.
	usz animate = (usz)g.find("animate");
	test::@check(g.at(animate).params[1] == "", "Animate's mirror check does not start unset (%s)", g.at(animate).params[1]);
	test::@check(mirror_lit(fixture), "the mirror icon is dark while the check is on");
	node_press(fixture, crig::NODE_MIRROR_ID);
	test::@check(g.at(animate).params[1] == "0", "a click did not turn the mirror check off (%s)", g.at(animate).params[1]);
	// The next frames redraw the icon by themselves.
	fixture.feed({ 0, 0 });
	fixture.feed({ 0, 0 });
	test::@check(!mirror_lit(fixture), "the mirror icon still shows on after a click turned it off");
	node_press(fixture, crig::NODE_MIRROR_ID);
	test::@check(g.at(animate).params[1] == "1", "a second click did not turn it back on (%s)", g.at(animate).params[1]);
	fixture.feed({ 0, 0 });
	fixture.feed({ 0, 0 });
	test::@check(mirror_lit(fixture), "the mirror icon still shows off after a click turned it on");

	// The source's switch makes it an Image: the wire stays and Animate's card follows.
	test::@check(@ok(node_field(fixture, "animate", 3)), "a video's Animate has no Frames");
	source_switch(fixture, 1);
	test::@check(g.find("video") < 0 && g.at(animate).input[1] == g.find("image"), "the switch did not make an Image on the same wire");
	test::@check(fixture.ui.find_id(crig::NODE_SOURCE_ID)!!.widget_as(Segmented).selected == 1, "the switch does not show Image");
	test::@check(!@ok(node_field(fixture, "animate", 3)), "Animate asks for a picture's Frames");
	// And back, with a run going: refused, and the switch shows what the node is.
	g.running = (sz)animate;
	source_switch(fixture, 0);
	test::@check(g.find("image") >= 0, "the source swapped during a run");
	test::@check(fixture.ui.find_id(crig::NODE_SOURCE_ID)!!.widget_as(Segmented).selected == 1, "the refused switch stayed on Video");
	g.running = -1;
	source_switch(fixture, 0);
	test::@check(g.find("video") >= 0 && @ok(node_field(fixture, "animate", 3)), "the switch did not go back to Video");

	// Browse on Video takes a folder of frames: Select on a folder picks it.
	String picked = "build/test_pick_frames";
	(void)path::mkdir(picked, true);
	defer (void)path::rmtree((Path)picked);
	test::@check(@ok(node_browse_press(fixture, "video", 0)), "no Browse on the Video card");
	fixture.ui.flush();
	test::@check(fixture.app.file_purpose == crig::FilePurpose.CAPTURE_VIDEO, "Video's Browse asks for %s", fixture.app.file_purpose);
	Element* path_field = fixture.ui.find_id(crig::FILE_PATH_ID)!!;
	path_field.widget_as(TextField).set_text(path_field, "build/test_pick_frames/");
	path_field.widget_as(TextField).on_submit(fixture.ui, "build/test_pick_frames/");
	fixture.ui.flush();
	test::@check(g.at(g.find("video")).params[0] == picked, "Select on a folder did not pick it: '%s'", g.at(g.find("video")).params[0]);
	// Browse on Reference file takes a reference's folder the same way.
	test::@check(@ok(node_browse_press(fixture, "reference", 0)), "no Browse on the Reference file card");
	fixture.ui.flush();
	test::@check(fixture.app.file_purpose == crig::FilePurpose.CAPTURE_REFERENCE, "Reference file's Browse asks for %s", fixture.app.file_purpose);
	path_field = fixture.ui.find_id(crig::FILE_PATH_ID)!!;
	path_field.widget_as(TextField).set_text(path_field, "build/test_pick_frames/");
	path_field.widget_as(TextField).on_submit(fixture.ui, "build/test_pick_frames/");
	fixture.ui.flush();
	test::@check(g.at(g.find("reference")).params[0] == picked, "Select on a folder did not pick it: '%s'", g.at(g.find("reference")).params[0]);
	// Animate writes no files: no save folder. Train's asks for a folder.
	test::@check(!@ok(node_browse_press(fixture, "animate", 2)), "Animate still has a save folder");
	test::@check(@ok(node_browse_press(fixture, "train", 2)), "no save folder Browse on Train");
	fixture.ui.flush();
	test::@check(fixture.app.file_purpose == crig::FilePurpose.CAPTURE_FOLDER, "Train's save folder asks for %s", fixture.app.file_purpose);
	close_the_chooser(fixture);
	fixture.type_into(node_field(fixture, "train", 2)!!, "/captures/zidane");
	test::@check(g.at(g.find("train")).params[2] == "/captures/zidane", "Train's save folder reads '%s'", g.at(g.find("train")).params[2]);
}

// Each template's note says how to use it, so all of it has to show without scrolling.
fn void every_templates_note_fits_its_card() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	fixture.reset();
	crig::build_ui(fixture.ui, &fixture.app);
	fixture.ui.flush();
	crig::show_pane_view(fixture.ui, crig::NODES_VIEW, SplitAxis.HORIZONTAL, 2.0f / 3.0f);
	fixture.feed(VIEWPORT_CENTER);
	fixture.ui.flush();
	for (usz t = 0; t < crig::TEMPLATES; t++)
	{
		fixture.app.open_template_named(t);
		fixture.feed(VIEWPORT_CENTER);
		fixture.feed(VIEWPORT_CENTER);
		fixture.ui.flush();
		Element* note = node_field(fixture, "note", 0)!!;
		float hidden = note.widget_as(TextField).clamp_scroll(note, 100000.0f);
		test::@check(hidden <= 0.0f, "%s's note hides %f px of its text", crig::TEMPLATE_NAMES[t], hidden);
	}
}

// Choose row `row` of the source card's Video | Image switch, and let the pane rebuild.
fn void source_switch(Fixture* fixture, usz row)
{
	Element* found = fixture.ui.find_id(crig::NODE_SOURCE_ID)!!;
	fixture.ui.hovered = found;
	found.widget_as(Segmented).on_change(fixture.ui, row);
	fixture.feed({ 0, 0 });
	fixture.feed({ 0, 0 });
}

// Press a card's Browse icon for `slot`.
fn void? node_browse_press(Fixture* fixture, String id, usz slot)
{
	crig::PipelineGraph* g = fixture.app.pipeline();
	Element* graph = fixture.ui.find_id(crig::NODES_GRAPH_ID)!;
	foreach (card : graph.children)
	{
		if (!card.is_widget(NodeCard) || (sz)card.widget_as(NodeCard).node != g.find(id)) continue;
		Element* found = card.find_id(string::tformat("node-browse-%d", slot))!;
		fixture.ui.hovered = found;
		found.widget_as(Button).on_click(fixture.ui);
		return;
	}
	return NOT_FOUND~;
}

// Text to motion's Name field: typed, it names the clip; left empty, the clip
// is "Generated N", the lowest number the character does not already have — and
// the field shows that name as its placeholder.
fn void the_generate_node_names_an_unnamed_clip_generated_n() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	fixture.reset();
	crig::build_ui(fixture.ui, &fixture.app);
	fixture.ui.flush();
	crig::show_pane_view(fixture.ui, crig::NODES_VIEW, SplitAxis.HORIZONTAL, 2.0f / 3.0f);
	fixture.feed(VIEWPORT_CENTER);
	fixture.ui.flush();

	crig::PipelineGraph* g = fixture.app.pipeline();
	Element* field = node_field(fixture, "generate", 0)!!;
	test::@check(field.widget_as(TextField).placeholder == "Generated 1",
		"an unnamed clip would be '%s'", field.widget_as(TextField).placeholder);
	fixture.type_into(field, "Big jump");
	test::@check(g.at(g.find("generate")).params[0] == "Big jump", "the node's name is '%s'", g.at(g.find("generate")).params[0]);

	// A clip already called "Generated 1" moves the default on to 2.
	crig::AnimKeyframe[] frames = alloc::new_array(mem, crig::AnimKeyframe, 1);
	crig::AnimRef taken = fixture.app.author_clip({ .name = "Generated 1".copy(mem), .duration = 1.0f,
		.keyframes = frames, .owned = true });
	test::@check(taken.valid(), "the clip was not authored");
	String next = fixture.app.next_generated_name(mem);
	defer next.free(mem);
	test::eq(next, "Generated 2");
	fixture.feed(VIEWPORT_CENTER);
	fixture.ui.flush();
	field = node_field(fixture, "generate", 0)!!;
	test::@check(field.widget_as(TextField).placeholder == "Generated 2",
		"the placeholder did not move on: '%s'", field.widget_as(TextField).placeholder);
	test::@check(field.widget_as(TextField).value() == "Big jump", "a rebuild lost the typed name");
}

<*
 The MCP port in Settings applies at once: a number is saved and asks main to
 rebind, 0 turns the server off, and anything else changes nothing. The line
 under the field says what the server is doing.
*>
fn void settings_port_rebinds_the_mcp_server() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	crig::open_settings_dialog(f.ui);
	f.ui.flush();

	crig::settings_port_submitted(f.ui, " 9123 ");
	test::@check(f.app.config.mcp_port == 9123, "the port reads %d", f.app.config.mcp_port);
	test::@check(f.app.mcp_restart_wanted, "a new port did not ask for a rebind");

	f.app.mcp_restart_wanted = false;
	crig::settings_port_submitted(f.ui, "eighty");
	crig::settings_port_submitted(f.ui, "70000");
	test::@check(f.app.config.mcp_port == 9123 && !f.app.mcp_restart_wanted, "a bad port was taken");

	crig::settings_port_submitted(f.ui, "0");
	test::@check(f.app.config.mcp_port == 0 && f.app.mcp_restart_wanted, "0 did not turn the server off");

	Element* field = f.ui.find_id(crig::SETTINGS_PORT_ID)!!;
	String said = crig::mcp_status_text(field);
	test::@check(said == "Off", "a closed server says '%s'", said);
	said.free(mem);

	f.app.mcp_serving_port = 9123;
	said = crig::mcp_status_text(field);
	test::@check(said == "Serving at http://127.0.0.1:9123/mcp", "a serving server says '%s'", said);
	said.free(mem);

	f.app.mcp_serving_port = 0;
	f.app.mcp_port_busy = true;
	f.app.config.mcp_port = 9123;
	said = crig::mcp_status_text(field);
	test::@check(said.starts_with("Port 9123 is in use"), "a refused bind says '%s'", said);
	said.free(mem);
}

<*
 Settings has an AI page for the llm folder the pipelines run from. The model
 files are not there: they are set on the Nodes pane's model nodes.
*>
fn void settings_ai_page_holds_the_plugins_only() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	crig::open_settings_dialog(f.ui);
	f.ui.flush();
	test::@check(f.in_tree(crig::SETTINGS_TABS_ID), "Settings has no tabs");
	test::@check(f.in_tree(crig::SETTINGS_PORT_ID), "Settings does not open on its General page");

	crig::open_ai_settings(f.ui);
	f.ui.flush();
	test::@check(!f.in_tree(crig::SETTINGS_PORT_ID), "the General page stayed up");
	test::@check(!f.in_tree("settings-motion-model") && !f.in_tree("settings-capture-backbone"), "model files are asked for on the AI page");
	test::@check(f.in_tree(crig::SETTINGS_PLUGINS_FOLDER_ID) && f.in_tree(crig::AI_PLUGINS_STATUS_ID), "no plugins folder");
	crig::set_motion_path(f.ui, "plugins", "  /nowhere/llm ");
	f.ui.flush();
	test::@check(f.app.config.motion_generator.plugins == "/nowhere/llm", "the folder reads '%s'", f.app.config.motion_generator.plugins);
	Element* folder = f.ui.find_id(crig::SETTINGS_PLUGINS_FOLDER_ID)!!;
	test::@check(folder.widget_as(TextField).value() == "/nowhere/llm", "the field reads '%s'", folder.widget_as(TextField).value());
}

<*
 The first Scene editor is the logical hierarchy crig can faithfully expose
 today: one flattened mesh and the rig derived from the document. Its rows are
 also the bridge into object-level selection for the transform tools.
*>
fn void scene_outliner_lists_and_selects_spatial_objects() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	fixture.reset();

	uint hips = fixture.doc().add_dot({ 0, -0.3f, 0 }, "hips");
	uint chest = fixture.doc().add_dot({ 0, 0.3f, 0 }, "chest");
	fixture.doc().connect(hips, chest);
	fixture.doc().bind_clip("walk.glb", "Walk");

	Element* strip = fixture.ui.find(AreaTabStrip)!!;
	fixture.click(tab_center(fixture, strip, TAB_SCENE));
	Element* outliner = fixture.ui.find_id(crig::SCENE_OUTLINER_ID)!!;
	test::@check(outliner.absolute.x >= crig::SCENE_OUTLINER_PAD
		&& outliner.absolute.y >= crig::BAR_H + TAB_H + crig::SCENE_OUTLINER_PAD,
		"the Outliner rows must be inset from the pane borders");
	Element* tree = outliner.children[0];
	TreeRow[] rows = tree.widget_as(Tree).rows;

	test::@check(rows.len == 6, "Scene should list Scene, Model, Mesh, Skeleton and two joints, not animations");
	test::@check(rows[0].label == "Scene" && rows[0].depth == 0, "Scene must be the root row");
	test::@check(rows[2].label == "Mesh" && rows[2].depth == 2, "Mesh must sit under the model");
	test::@check(rows[3].label == "Skeleton" && rows[3].depth == 2, "Skeleton must sit beside Mesh");
	test::@check(rows[4].label == "hips" && rows[4].depth == 3, "the rig root must sit under Skeleton");
	test::@check(rows[5].label == "chest" && rows[5].depth == 4, "children must follow the rig hierarchy");

	fixture.click(category_center(tree, 2));
	test::@check(fixture.app.selected == 0 && fixture.app.scene_selection == crig::SceneSelection.MESH,
		"selecting Mesh must choose the object target and clear joints");

	tree = fixture.ui.find_id(crig::SCENE_OUTLINER_ID)!!.children[0];
	fixture.click(category_center(tree, 4));
	test::@check(fixture.app.selected == hips && fixture.app.scene_selection == crig::SceneSelection.JOINT,
		"selecting a joint row must select the viewport joint");

	tree = fixture.ui.find_id(crig::SCENE_OUTLINER_ID)!!.children[0];
	fixture.shift_click(category_center(tree, 5));
	test::@check(fixture.app.selected == hips && fixture.app.is_selected(chest)
		&& fixture.app.selection_count() == 2,
		"shift-clicking a joint row must extend the joint selection");

	fixture.app.select(chest);
	fixture.app.refresh_ui();
	fixture.ui.flush();
	tree = fixture.ui.find_id(crig::SCENE_OUTLINER_ID)!!.children[0];
	test::@check(tree.widget_as(Tree).selected == 5,
		"a joint selection made outside the Outliner must update its highlight");

	fixture.click(category_center(tree, 3));
	test::@check(fixture.app.selected == 0 && fixture.app.scene_selection == crig::SceneSelection.SKELETON,
		"selecting Skeleton must replace the joint selection");

	tree = fixture.ui.find_id(crig::SCENE_OUTLINER_ID)!!.children[0];
	fixture.click(category_mark(tree, 4, 3));
	tree = fixture.ui.find_id(crig::SCENE_OUTLINER_ID)!!.children[0];
	test::@check(tree.widget_as(Tree).rows.len == 5,
		"closing a joint branch must hide its descendants");

	fixture.click(category_mark(tree, 3, 2));
	tree = fixture.ui.find_id(crig::SCENE_OUTLINER_ID)!!.children[0];
	test::@check(tree.widget_as(Tree).rows.len == 4,
		"closing Skeleton must hide the complete joint hierarchy");
}

<*
 The outliner reads like Blender's: every row carries its kind's icon, the
 model, mesh and skeleton carry an eye that hides them without selecting them,
 and every joint of a group is lit with the anchor as the active row.
*>
fn void scene_outliner_rows_carry_icons_eyes_and_the_whole_selection() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	fixture.reset();

	uint hips = fixture.doc().add_dot({ 0, -0.3f, 0 }, "hips");
	uint chest = fixture.doc().add_dot({ 0, 0.3f, 0 }, "chest");
	fixture.doc().connect(hips, chest);

	Element* strip = fixture.ui.find(AreaTabStrip)!!;
	fixture.click(tab_center(fixture, strip, TAB_SCENE));
	Element* tree = fixture.ui.find_id(crig::SCENE_OUTLINER_ID)!!.children[0];
	TreeRow[] rows = tree.widget_as(Tree).rows;
	test::@check(rows.len == 6, "expected six rows, got %d", rows.len);
	if (rows.len != 6) return;
	test::@check(rows[0].icon == crig::OUTLINER_ICON_SCENE && rows[1].icon == crig::OUTLINER_ICON_MODEL
		&& rows[2].icon == crig::OUTLINER_ICON_MESH && rows[3].icon == crig::OUTLINER_ICON_SKELETON
		&& rows[5].icon == crig::OUTLINER_ICON_JOINT, "a row is missing its kind's icon");
	test::@check(rows[1].toggles[0].shown && rows[2].toggles[0].shown && rows[3].toggles[0].shown
		&& !rows[0].toggles[0].shown && !rows[4].toggles[0].shown,
		"only the model, mesh and skeleton carry an eye");

	fixture.app.select(hips);
	fixture.app.refresh_ui();
	fixture.ui.flush();

	// The mesh's eye: hides the mesh, keeps the joint selection.
	TreeStyle style = crig::OUTLINER_STYLE;
	tree = fixture.ui.find_id(crig::SCENE_OUTLINER_ID)!!.children[0];
	Vec2 eye = tree.absolute + (Vec2) { tree.size.x - style.padding - style.toggle_width * 0.5f, 2.5f * style.row_height };
	fixture.click(eye);
	test::@check(!fixture.app.show_mesh, "the mesh's eye did not hide the mesh");
	test::@check(fixture.app.selected == hips, "the eye changed the selection");
	tree = fixture.ui.find_id(crig::SCENE_OUTLINER_ID)!!.children[0];
	test::@check(!tree.widget_as(Tree).rows[2].toggles[0].on, "the eye does not show the mesh as hidden");
	fixture.click(eye);
	test::@check(fixture.app.show_mesh, "a second click did not bring the mesh back");

	// The model's eye takes both halves away together.
	fixture.click(eye - (Vec2) { 0, style.row_height });
	test::@check(!fixture.app.show_mesh && !fixture.app.show_rig, "the model's eye must hide mesh and rig");
	fixture.click(eye - (Vec2) { 0, style.row_height });
	test::@check(fixture.app.show_mesh && fixture.app.show_rig, "the model's eye must bring both back");

	fixture.app.extend_selection(chest);
	fixture.app.refresh_ui();
	fixture.ui.flush();
	Tree* widget = fixture.ui.find_id(crig::SCENE_OUTLINER_ID)!!.children[0].widget_as(Tree);
	test::@check(widget.selected == 4, "the anchor must stay the active row");
	test::@check(widget.rows[4].highlighted && widget.rows[5].highlighted,
		"every joint in the selection must be lit");
}

<*
 Each joint row sits straight under its own parent: two fingers list as
 index_1, index_2, then thumb_1, thumb_2 — not every first segment and then every
 second one, which indented made index_2 look like thumb_1's child.
*>
fn void scene_outliner_lists_joints_under_their_own_parent() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	fixture.reset();

	uint hand = fixture.doc().add_dot({ 0, 0, 0 }, "hand");
	uint index_1 = fixture.doc().add_dot({ 0.1f, 0.1f, 0 }, "index_1");
	uint index_2 = fixture.doc().add_dot({ 0.2f, 0.2f, 0 }, "index_2");
	uint thumb_1 = fixture.doc().add_dot({ -0.1f, 0.1f, 0 }, "thumb_1");
	uint thumb_2 = fixture.doc().add_dot({ -0.2f, 0.2f, 0 }, "thumb_2");
	fixture.doc().connect(hand, index_1);
	fixture.doc().connect(index_1, index_2);
	fixture.doc().connect(hand, thumb_1);
	fixture.doc().connect(thumb_1, thumb_2);

	Element* strip = fixture.ui.find(AreaTabStrip)!!;
	fixture.click(tab_center(fixture, strip, TAB_SCENE));
	TreeRow[] rows = fixture.ui.find_id(crig::SCENE_OUTLINER_ID)!!.children[0].widget_as(Tree).rows;
	test::@check(rows.len == 9, "expected Scene, Model, Mesh, Skeleton and five joints, got %d rows", rows.len);
	if (rows.len != 9) return;

	String[5] names;
	usz[5] depths;
	for (usz i = 0; i < 5; i++)
	{
		names[i] = rows[4 + i].label;
		depths[i] = rows[4 + i].depth;
	}
	test::@check(names[0] == "hand" && depths[0] == 3, "the hand should head the joints");
	bool index_first = names[1] == "index_1";
	String first = index_first ? "index" : "thumb";
	String second = index_first ? "thumb" : "index";
	test::@check(names[1].starts_with(first) && depths[1] == 4
		&& names[2].starts_with(first) && depths[2] == 5
		&& names[3].starts_with(second) && depths[3] == 4
		&& names[4].starts_with(second) && depths[4] == 5,
		"joints are not listed under their own parent: %s(%d) %s(%d) %s(%d) %s(%d)",
		names[1], depths[1], names[2], depths[2], names[3], depths[3], names[4], depths[4]);
}

<*
 A right-click on an Outliner row selects what it names and raises the context
 menu for it: the Skeleton row offers moving the whole rig, which Move by… does
 exactly and as one undo; a joint row offers growing the selection to its
 children or to the whole skeleton.
*>
fn void scene_outliner_right_click_menu_moves_the_skeleton() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	fixture.reset();

	uint hips = fixture.app.add_recorded({ 0, -0.3f, 0 }, "hips");
	uint chest = fixture.app.add_recorded({ 0, 0.3f, 0 }, "chest");
	uint head = fixture.app.add_recorded({ 0, 0.6f, 0 }, "head");
	fixture.app.connect_recorded(hips, chest);
	fixture.app.connect_recorded(chest, head);
	fixture.app.undo_stack.commit();
	fixture.app.refresh_ui();

	Element* strip = fixture.ui.find(AreaTabStrip)!!;
	fixture.click(tab_center(fixture, strip, TAB_SCENE));
	Element* tree = fixture.ui.find_id(crig::SCENE_OUTLINER_ID)!!.children[0];
	test::@check(tree.widget_as(Tree).rows[3].label == "Skeleton", "row 3 should be the Skeleton");

	Element* ctx = fixture.ui.find_id(crig::VIEWPORT_CONTEXT_ID)!!;
	fixture.right_click(category_center(tree, 3));
	test::@check(ctx.widget_as(Dialog).open, "a right-click on the Skeleton row did not open the menu");
	test::@check(fixture.app.selected == 0 && fixture.app.scene_selection == crig::SceneSelection.SKELETON,
		"a right-click on the Skeleton row must select the skeleton");
	test::@check(@ok(fixture.ui.find_id("viewport-context-move-by"))
		&& @ok(fixture.ui.find_id("viewport-context-select-joints")),
		"the Skeleton menu must offer Move by… and Select all joints");

	crig::scene_context_move(fixture.ui);
	test::@check(!ctx.widget_as(Dialog).open, "Move did not close the menu");
	test::@check(fixture.app.transform_tool == crig::TransformTool.MOVE_TOOL,
		"Move must switch to the Move tool so the gizmo sits on the skeleton");

	test::@check(fixture.app.move_selection_by({ 0, 0, 0.5f }) == crig::MoveByResult.MOVED,
		"Move by did not move the skeleton");
	foreach (id : (uint[]) { hips, chest, head })
	{
		test::@check(math::abs(fixture.doc().find(id).position.z - 0.5f) < 1e-5f,
			"every joint must move forward by the offset");
	}
	test::@check(fixture.app.undo(), "undo did nothing");
	foreach (id : (uint[]) { hips, chest, head })
	{
		test::@check(math::abs(fixture.doc().find(id).position.z) < 1e-5f,
			"one undo must put the whole skeleton back");
	}

	fixture.app.refresh_ui();
	fixture.ui.flush();
	tree = fixture.ui.find_id(crig::SCENE_OUTLINER_ID)!!.children[0];
	fixture.right_click(category_center(tree, 5));
	test::@check(fixture.app.selected == chest, "a right-click on a joint row must select that joint");
	test::@check(@ok(fixture.ui.find_id("viewport-context-select-children")),
		"the joint menu must offer Select children");
	crig::scene_context_select_children(fixture.ui);
	test::@check(fixture.app.selected == chest && fixture.app.is_selected(head)
		&& !fixture.app.is_selected(hips) && fixture.app.selection_count() == 2,
		"Select children must select the joint and everything below it");

	crig::scene_context_select_skeleton(fixture.ui);
	test::@check(fixture.app.selected == 0 && fixture.app.scene_selection == crig::SceneSelection.SKELETON,
		"Select whole skeleton must pick the Skeleton object");
}

<*
 Switching tabs rebuilds the pane, which recycles every element in it — so the
 strip is re-found for the switch back, and `fixture.viewport` is re-resolved
 for whoever runs next.
*>
fn void tabs_swap_the_pane_content() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("a pane's tabs swap its content");
	fixture.reset();

	Element*? strip = fixture.ui.find(AreaTabStrip);
	if (catch strip)
	{
		test::@check(false, "SKIPPED — no tab strip in the tree");
		return;
	}

	fixture.click(tab_center(fixture, strip, 1));
	test::@check(fixture.in_tree("hud") == false, "the Assets tab takes the 3D view down");
	test::@check(fixture.in_tree(crig::ASSETS_GRID_ID), "and puts the asset grid up");

	if (try Element* s2 = fixture.ui.find(AreaTabStrip)) fixture.click(tab_center(fixture, s2, 0));
	bool viewport_back = false;
	if (try Element* v = fixture.ui.find(Viewport)) viewport_back = true;
	test::@check(viewport_back, "the 3D View tab brings the viewport back");

	fixture.viewport = fixture.ui.find(Viewport)!!;
}

<*
 Rig and View are on the window bar, beside File, Edit and Help: they stay when
 no pane shows a 3D View, the Rig items still act on the document, and View's
 camera items grey until a 3D View is back. Each 3D View pane keeps a header
 strip of its own for the tint switch.
*>
fn void rig_and_view_menus_live_on_the_window_bar() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("Rig and View live on the window bar");
	fixture.reset();

	Element*? rig = fixture.ui.find_id("Rig");
	if (catch rig)
	{
		test::@check(false, "SKIPPED — the Rig title is nowhere in the tree");
		return;
	}
	test::@check(rig.absolute.y < crig::BAR_H, "Rig sits on the window bar");
	test::@check(!crig::query_has_view(fixture.ui).disabled, "the camera items are live with a 3D View");

	Element*? strip = fixture.ui.find(AreaTabStrip);
	if (catch strip)
	{
		test::@check(false, "SKIPPED — no tab strip in the tree");
		return;
	}
	fixture.click(tab_center(fixture, strip, 1));
	test::@check(fixture.in_tree("Rig") && fixture.in_tree("View"),
		"the Rig and View menus stay with no 3D View showing");
	test::@check(!fixture.in_tree("tints"), "while the tint switch goes with the model");
	test::@check(crig::query_has_view(fixture.ui).disabled, "and the camera items grey with no 3D View");

	bool chain = fixture.app.doc.auto_connect;
	fixture.click(fixture.center_of("Rig")!!);
	Vec2? item = fixture.center_of("Auto-connect");
	if (catch item)
	{
		test::@check(false, "the Rig menu did not open with no 3D View");
		return;
	}
	fixture.click(item);
	test::@check(fixture.app.doc.auto_connect != chain, "a Rig item still acts with no 3D View");
	fixture.app.doc.auto_connect = chain;

	if (try Element* s2 = fixture.ui.find(AreaTabStrip)) fixture.click(tab_center(fixture, s2, 0));
	test::@check(fixture.in_tree("tints"), "the 3D View tab brings its header back");

	pick_context(fixture, VIEWPORT_CENTER, "Split Vertical");
	usz bars = 0;
	fixture.ui.@each_id("viewbar" ; b)
	{
		bars++;
	};
	test::@check(bars == 2, "a split gives each pane a header of its own");
	usz rigs = 0;
	fixture.ui.@each_id("Rig" ; title)
	{
		rigs++;
	};
	test::@check(rigs == 1, "and the Rig menu is not duplicated per pane (%d)", rigs);

	Element* right_view = null;
	fixture.ui.@each(Viewport ; v)
	{
		if (right_view == null || v.absolute.x > right_view.absolute.x) right_view = v;
	};
	pick_context(fixture, right_view.absolute + right_view.size * (Vec2){ 0.5f, 0.75f }, "Close");
	test::@check(count_viewports(fixture) == 1, "and the workspace folds back to one pane");
	fixture.viewport = fixture.ui.find(Viewport)!!;
}

<*
 Split viewports keep separate cameras. Activating one swaps its camera into the
 app-facing slot used by shortcuts and MCP without moving the other pane.
*>
fn void split_viewports_keep_independent_cameras() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("split viewports keep independent cameras");
	fixture.reset();

	pick_context(fixture, VIEWPORT_CENTER, "Split Vertical");
	if (count_viewports(fixture) != 2)
	{
		test::@check(false, "SKIPPED — the split did not produce a second pane");
		return;
	}

	Element* near_view = null;
	Element* far_view = null;
	fixture.ui.@each(Viewport ; v)
	{
		if (near_view == null || v.absolute.x < near_view.absolute.x)
		{
			far_view = near_view != null ? near_view : far_view;
			near_view = v;
		}
		else
		{
			far_view = v;
		}
	};

	if (far_view == null)
	{
		test::@check(false, "SKIPPED — the second pane has no viewport");
		return;
	}

	// Placed after the split, because the pane's context menu does not open over a
	// dot — and needed at all because the overlay paints nothing, and so watches
	// nothing, over an empty document. Both panes show the one document.
	Vec2 near_centre = near_view.absolute + near_view.size * 0.5f;
	fixture.click(near_centre);
	if (fixture.doc().dots.len() == 0)
	{
		test::@check(false, "SKIPPED — no dot to draw an overlay from");
		return;
	}

	Viewport* near_widget = near_view.widget_as(Viewport);
	Viewport* far_widget = far_view.widget_as(Viewport);
	float near_before = near_widget.view_camera(near_view).pitch;
	float far_before = far_widget.view_camera(far_view).pitch;

	fixture.ui.process_input(
		{
			.mouse = near_centre,
			.scroll = 8.0,
			.scroll_precise = true,
		},
		DT
	);
	float near_after = near_widget.view_camera(near_view).pitch;
	float far_after = far_widget.view_camera(far_view).pitch;
	test::@check(near_after != near_before, "orbiting the left pane moves its camera");
	test::@check(far_after == far_before, "and leaves the right pane's camera alone");
	fixture.ui.flush();

	Vec2 far_centre = far_view.absolute + far_view.size * 0.5f;
	fixture.scroll(far_centre, { 0, -8.0f }, true);
	test::@check(near_widget.view_camera(near_view).pitch == near_after,
		"orbiting the right pane leaves the left camera where it was");
	test::@check(far_widget.view_camera(far_view).pitch != far_after,
		"and moves the right camera independently");

	// Lower in the pane, clear of the dot that shows at its centre: a right-press
	// on a dot raises the joint menu now, so the pane menu is reached off it.
	pick_context(fixture, far_view.absolute + far_view.size * (Vec2){ 0.5f, 0.75f }, "Close");
	fixture.viewport = fixture.ui.find(Viewport)!!;
}

fn void split_viewport_transforms_latch_the_originating_camera() @test
{
	Fixture fixture;
	if (catch fault error = fixture.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer fixture.close();

	io::printn("a transform in split view keeps the camera and coordinates of the pane where it began");
	pick_context(&fixture, VIEWPORT_CENTER, "Split Vertical");
	if (count_viewports(&fixture) != 2)
	{
		test::@check(false, "SKIPPED — the split did not produce a second pane");
		return;
	}

	Element* left = null;
	Element* right = null;
	fixture.ui.@each(Viewport ; view)
	{
		if (!left || view.absolute.x < left.absolute.x)
		{
			right = left ? left : right;
			left = view;
		}
		else
		{
			right = view;
		}
	};
	if (!right)
	{
		test::@check(false, "SKIPPED — the second pane has no viewport");
		return;
	}

	crig::Viewport* left_widget = left.widget_as(crig::Viewport);
	crig::Viewport* right_widget = right.widget_as(crig::Viewport);
	left_widget.activate_camera(left);
	fixture.app.camera.yaw = 0.0f;
	fixture.app.camera.pitch = 0.0f;
	right_widget.activate_camera(right);
	fixture.app.camera.yaw = 90.0f;
	fixture.app.camera.pitch = 0.0f;

	fixture.app.select_scene(crig::SceneSelection.MODEL);
	fixture.app.refresh_ui();
	Vec2 left_center = left.absolute + left.size * 0.5f;
	fixture.feed(left_center);
	fixture.feed_key(Key.G);
	test::@check(fixture.app.transform_interaction.active
		&& fixture.app.transform_interaction.viewport == left_widget
		&& fixture.app.transform_interaction.camera.yaw == 0.0f,
		"G over the left pane did not latch that pane and its camera");
	fixture.feed(left_center + (Vec2){ 40, 0 });
	Vec3 left_delta = fixture.app.transform_interaction.raw_translation;
	fixture.feed(right.absolute + right.size * 0.5f);
	test::@check(fixture.app.transform_interaction.viewport == left_widget
		&& fixture.app.transform_interaction.camera.yaw == 0.0f,
		"crossing into the other pane changed the transform's source camera");
	fixture.feed_key(Key.ESCAPE);
	test::@check(fixture.app.doc.model_transform.is_identity(),
		"cancelling the left-pane preview did not restore the model");

	Vec2 right_center = right.absolute + right.size * 0.5f;
	fixture.feed(right_center);
	fixture.feed_key(Key.G);
	test::@check(fixture.app.transform_interaction.active
		&& fixture.app.transform_interaction.viewport == right_widget
		&& fixture.app.transform_interaction.camera.yaw == 90.0f,
		"G over the right pane did not latch its independent camera");
	fixture.feed(right_center + (Vec2){ 40, 0 });
	Vec3 right_delta = fixture.app.transform_interaction.raw_translation;
	test::@check(left_delta.length() > 1.0e-5f && right_delta.length() > 1.0e-5f
		&& (left_delta - right_delta).length() > 1.0e-4f,
		"the two camera orientations produced the same free-move plane");
	fixture.feed_key(Key.ESCAPE);

	pick_context(&fixture, right.absolute + right.size * (Vec2){ 0.5f, 0.75f }, "Close");
	fixture.viewport = fixture.ui.find(Viewport)!!;
}

<*
 The first cell showing an asset of this kind, or null.

 Found by walking the browser's own cells and asking each what it is drawing,
 rather than by computing a position from the grid's arithmetic. The cells are
 real elements — that is what the `Grid` is for — so their absolute positions are
 already settled by layout, and a copy of the wrapping rule here would drift the
 moment a cell changes size.

 @param name : `Also require this exact asset name; empty takes the first of the kind.`
*>
fn Element* asset_cell(Fixture* fixture, crig::AssetKind kind, String name = "")
{
	// No early exit: a bare `return` inside an `@each` body leaves the enclosing
	// function, not the iteration, so the first match is kept by a guard instead.
	Element* found = null;
	fixture.ui.@each(crig::AssetCell; cell)
	{
		if (!found)
		{
			crig::AssetEntry* entry = fixture.app.visible_asset(cell.widget_as(crig::AssetCell).row);
			if (entry && entry.kind == kind && (name.len == 0 || entry.name == name)) found = cell;
		}
	};
	return found;
}

// The middle of a cell, in window coordinates — where a click on it goes.
fn Vec2 cell_center(Element* cell) => cell.absolute + cell.size * 0.5f;

<*
 The middle of a sidebar row, in window coordinates.

 The row height comes off the style the widget actually uses, so a change to the
 theme moves these clicks with it rather than leaving them landing one row above
 where the check means.
*>
fn Vec2 category_center(Element* tree, usz row)
{
	TreeStyle style = tree.widget_as(Tree).style.resolved();
	return tree.absolute + (Vec2) {
		tree.size.x * 0.5f,
		((float)row + 0.5f) * style.row_height,
	};
}

<*
 Which sidebar row names this kind's heading, or past the end when there is none.

 Asked rather than counted: the rows are derived from what the scan found, so
 which position a kind sits at depends on what else the library holds.
*>
fn usz category_row(Fixture* fixture, crig::AssetKind kind)
{
	foreach (usz i, category : fixture.app.asset_categories)
	{
		if (!category.any_kind && category.kind == kind && category.depth == 1) return i;
	}
	return fixture.app.asset_categories.len;
}

<*
 The bug a second pack makes visible: two packs carrying a clip under the same
 name, where a playing highlight compared by name lights both cells.

 It needs a *second* pack, which is why it cannot be checked against the shipped
 library. The two are written out of the one on disk, so they differ in nothing
 but their names and both carry a clip called the same thing.
*>
fn void two_clips_with_one_name_do_not_both_light() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("one name in two packs lights one cell");
	fixture.reset();

	String folder = "build/ui-packs";
	if (catch path::mkdir(folder))
	{
		// Left from a previous run; the files below are overwritten.
	}

	// The body pack, not the first one: both fixtures are written out of this and
	// are applied as body plans below, so a source with no mesh would write two
	// packs that carry no rig to fit.
	int planned = fixture.app.plan_pack("biped");
	crig::AnimPack* source = planned < 0 ? null : fixture.app.pack((usz)planned);
	if (!source || source.clips.len == 0)
	{
		test::@check(false, "SKIPPED — no shipped pack to build fixtures from");
		return;
	}

	crig::AnimTemplate[1] clips = { source.clips[0] };

	bool wrote = true;
	if (catch crig::export_pack_glb(
		mem,
		"build/ui-packs/alpha.glb",
		&source.rest,
		source.joint_names,
		clips[..],
		source.mesh,
		{ .plan = "biped", .name = "Alpha" }
	)) wrote = false;
	if (catch crig::export_pack_glb(
		mem,
		"build/ui-packs/beta.glb",
		&source.rest,
		source.joint_names,
		clips[..],
		source.mesh,
		{ .plan = "biped", .name = "Beta" }
	)) wrote = false;
	if (!wrote)
	{
		test::@check(false, "SKIPPED — could not write the pack fixtures");
		return;
	}

	// Everything above borrowed from the library, and this frees it.
	fixture.app.load_packs(folder);

	test::@check(fixture.app.packs.len() == 2, "both packs load");

	test::@check(fixture.app.apply_plan_named("biped"), "a biped rig, so the clips are live");
	fixture.app.expanded_pack = 0;
	test::@check(fixture.app.start_animation_at(0), "playing the first pack's clip");
	test::@check(!crig::clip_flags(&fixture.app, { 1, 0 }).checked, "does not light the same-named clip in the other pack");
	test::@check(crig::clip_flags(&fixture.app, { 0, 0 }).checked, "only the one that is playing");

	// Switching what the list shows must not reach into the player.
	fixture.app.expanded_pack = 1;
	test::@check(fixture.app.animating, "and opening another pack's card does not stop it");

	fixture.app.stop_animation();
	fixture.app.load_packs(library::ready());
}

<*
 A skin cell places that file's rig, and goes through the asking to do it.

 What is checked here is the browser's half — that a click on a cell reaches
 `request_pack_rig` at all, and reaches it with the right pack. The rule about
 *when* that asks is `applying_a_rig_asks_before_replacing`, next to the code it
 belongs to; this asserts only that the cell is wired into it, by placing a rig
 and then watching a second cell stop at the question.
*>
fn void a_skin_cell_places_that_files_rig() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("a skin cell asks, then gives up its rig");
	fixture.reset();

	Element*? strip = fixture.ui.find(AreaTabStrip);
	if (catch strip)
	{
		test::@check(false, "SKIPPED — no tab strip in the tree");
		return;
	}
	fixture.click(tab_center(fixture, strip, 1));

	// The quadruped's, by the name its file gives it — every pack's skin is called
	// "rig", so the plan is what tells them apart, and the cell is found by asking
	// the entries rather than by counting positions in the grid.
	Element* skin = null;
	fixture.ui.@each(crig::AssetCell; cell)
	{
		if (!skin)
		{
			crig::AssetEntry* entry = fixture.app.visible_asset(cell.widget_as(crig::AssetCell).row);
			if (entry && entry.kind == crig::AssetKind.SKIN && entry.plan == "quadruped") skin = cell;
		}
	};
	if (!skin)
	{
		test::@check(false, "SKIPPED — no quadruped skin in the browser");
		return;
	}

	Element*? panel = fixture.ui.find_id(crig::CONFIRM_DIALOG_ID);
	if (catch panel)
	{
		test::@check(false, "SKIPPED — there is no confirm dialog in the tree");
		return;
	}
	ConfirmDialog* ask = panel.widget_as(ConfirmDialog);

	// Nothing to lose, so it lands straight away — see
	// `applying_a_rig_asks_before_replacing` for why an empty document is not
	// asked. What this says is that the cell reached the right pack.
	fixture.click(cell_center(skin));
	test::@check(fixture.doc().dots.len() == QUADRUPED_PACK_DOTS, "clicking a skin cell places that file's rig");
	test::@check(fixture.doc().plan == "quadruped", "under the plan its file declares");

	// One entry, like any other body plan — which is what makes trying one free.
	fixture.chord(VIEWPORT_CENTER, Key.LEFT_CTRL, Key.Z);
	test::@check(fixture.doc().dots.len() == 0, "and the whole plan is one Ctrl+Z");

	// With a rig placed, the same click stops at the question rather than
	// replacing it — which is what says the cell goes through `request_pack_rig`
	// and not straight to the fit.
	test::@check(fixture.app.apply_plan_named("biped"), "with a biped rig placed");
	sz placed = fixture.doc().dots.len();
	fixture.click(cell_center(skin));
	fixture.ui.flush();
	test::@check(ask.asking(panel), "a second skin cell raises the question instead of replacing");
	test::@check(fixture.doc().dots.len() == placed, "and nothing is replaced while it stands");

	panel.widget_as(ConfirmDialog).withdraw(panel);
	crig::answer_rig_dialog(fixture.ui, false);
	if (try Element* back = fixture.ui.find(AreaTabStrip)) fixture.click(tab_center(fixture, back, 0));
	fixture.viewport = fixture.ui.find(Viewport)!!;
}

<*
 A cell lights under the pointer, and puts it out when the pointer leaves.

 Leaving an element produces no MOVE inside it, so a highlight with nothing to
 clear it stays lit for as long as the pane is open — on a cell the user is no
 longer anywhere near. Asserted through the hover state rather than the pixels,
 because that flag is what the paint reads.
*>
fn void a_cell_lights_under_the_pointer() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("a cell lights under the pointer and goes out behind it");
	fixture.reset();

	Element*? strip = fixture.ui.find(AreaTabStrip);
	if (catch strip)
	{
		test::@check(false, "SKIPPED — no tab strip in the tree");
		return;
	}
	fixture.click(tab_center(fixture, strip, 1));

	Element* clip = asset_cell(fixture, crig::AssetKind.ANIMATION);
	if (!clip)
	{
		test::@check(false, "SKIPPED — the browser offered no clip to hover");
		return;
	}
	crig::AssetCell* cell = clip.widget_as(crig::AssetCell);

	fixture.feed(cell_center(clip));
	test::@check(cell.hovered, "a cell under the pointer is lit");

	// Off the browser entirely, rather than onto a neighbouring cell: what is being
	// checked is the path with no MOVE to clear the flag.
	fixture.feed({ 4.0, crig::WIN_H - 4.0 });
	test::@check(!cell.hovered, "and leaving the browser puts it out");

	if (try Element* back = fixture.ui.find(AreaTabStrip)) fixture.click(tab_center(fixture, back, 0));
	fixture.viewport = fixture.ui.find(Viewport)!!;
}

<*
 An empty library says so, and keeps the room to say it in.

 crig started from a directory with no assets finds nothing at all, and a pane
 that came up blank reads as a broken build rather than as an empty folder. The
 line needs a row's worth of height under it: sized to the padding alone it falls
 outside the box the Scroll clips to.

 The library is emptied *before* the view is built, because the height is decided
 in layout and nothing about a rescan marks a laid-out sheet stale.
*>
fn void an_empty_library_says_so() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("an empty library says so");
	fixture.reset();

	fixture.app.config.remove_library(0);
	fixture.app.config.add_library("build/no-such-asset-folder", "Missing");
	fixture.app.scan_libraries();
	test::@check(fixture.app.assets.entries.len == 0,
		"a folder that is not there is an empty library, not an error");
	test::@check(fixture.app.packs.len() == 0, "and no pack was read from it either");

	Element*? strip = fixture.ui.find(AreaTabStrip);
	if (catch strip)
	{
		test::@check(false, "SKIPPED — no tab strip in the tree");
		return;
	}
	fixture.click(tab_center(fixture, strip, 1));

	Element*? sheet = fixture.ui.find(crig::AssetSheet);
	if (catch sheet)
	{
		test::@check(false, "SKIPPED — the Assets view did not build");
		return;
	}
	test::@check(sheet.size.y >= crig::ASSET_CELL.y,
		"and the sheet holds a cell's height for the line that says so");

	// Put the fixture's library back, since the workspace is shared across checks.
	fixture.app.config.remove_library(0);
	fixture.app.config.add_library(library::ready(), "Checks");
	fixture.app.scan_libraries();
	if (try Element* back = fixture.ui.find(AreaTabStrip)) fixture.click(tab_center(fixture, back, 0));
	fixture.viewport = fixture.ui.find(Viewport)!!;
}

<*
 A clip cell greys against a rig that cannot carry it — and the + on it binds
 anyway.

 What is left of `asset_flags` for a clip now that nothing in the grid plays one.
 The greying is a **warning**: a rig declaring another body plan will not answer
 this clip's joints, and it is worth saying so before the clip goes on the
 character rather than after.

 The + is deliberately outside that rule, and that is the half worth asserting. A
 user builds the character's clip list while the rig is still being built, so a
 clip that does not fit *yet* has to be bindable — `AssetCell.on_mouse` puts the
 bind target ahead of the greying check for exactly that, and this is the check
 that would notice it slipping below it.
*>
fn void a_greyed_clip_cell_still_takes_a_binding() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("a greyed clip cell still takes a binding");
	fixture.reset();

	// A biped preset first: the walk targets joints by name, and a cell greys when
	// the rig cannot carry the clip.
	test::@check(fixture.app.apply_plan_named("biped"), "the biped body plan is on offer");
	fixture.ui.flush();

	Element*? strip = fixture.ui.find(AreaTabStrip);
	if (catch strip)
	{
		test::@check(false, "SKIPPED — no tab strip in the tree");
		return;
	}
	fixture.click(tab_center(fixture, strip, TAB_ASSETS));
	fixture.ui.flush();

	// A clip out of the biped's own file, so the rig placed above can carry it.
	usz row = fixture.app.visible_assets.len;
	fixture.ui.@each(crig::AssetCell; each)
	{
		if (row >= fixture.app.visible_assets.len)
		{
			usz at = each.widget_as(crig::AssetCell).row;
			crig::AssetEntry* entry = fixture.app.visible_asset(at);
			if (entry && entry.kind == crig::AssetKind.ANIMATION && entry.plan == "biped"
				&& !fixture.app.asset_flags(at).disabled)
			{
				row = at;
			}
		}
	};
	if (row >= fixture.app.visible_assets.len)
	{
		test::@check(false, "SKIPPED — the browser offered no clip this rig can carry");
		return;
	}

	// A rig that is placed but is somebody else's. Asserted on the flag rather than
	// on the paint, because the flag is what the paint and the click both read.
	fixture.doc().set_plan("quadruped");
	test::@check(fixture.app.asset_flags(row).disabled,
		"a clip of another body plan is offered as though this rig could carry it");

	int chosen = fixture.app.selected_asset;
	Element* cell = fixture.asset_cell_at(row);
	if (!cell)
	{
		test::@check(false, "SKIPPED — the cell went away");
		return;
	}
	fixture.click(cell.absolute + cell.size * 0.5f);
	fixture.ui.flush();
	test::@check(fixture.app.selected_asset == chosen, "a greyed cell answered a press on its body");
	test::@check(!fixture.app.animating, "and started an animation, which nothing in the grid may do");

	// The one target on it that is not governed by the greying.
	if (!fixture.bind_click(row))
	{
		test::@check(false, "SKIPPED — the cell went away between finding it and clicking it");
		return;
	}
	fixture.ui.flush();
	test::@check(fixture.doc().animations.len() == 1,
		"the + refused a clip this rig cannot carry — %d bound",
		fixture.doc().animations.len());
	test::@check(fixture.app.is_bound_entry(fixture.app.visible_asset(row)),
		"and the mark it draws does not agree that it bound");

	fixture.doc().free_animations();
	if (try Element* s2 = fixture.ui.find(AreaTabStrip)) fixture.click(tab_center(fixture, s2, TAB_3D));
	fixture.viewport = fixture.ui.find(Viewport)!!;
	fixture.reset();
}

<*
 A clip played on an empty document brings its own rig.

 The library is where a body plan comes from, so a first run with nothing placed
 would otherwise show a full library with every cell greyed and no cue that
 **Use this rig** is the way in. Playing a clip with nothing placed does both.

 It stops there: `apply_preset` adds rather than replaces, so the same clip over a
 rig already placed would leave two skeletons in one document. That half is
 asserted on the dot count rather than on the greying, because a rule that greyed
 correctly and fitted anyway would look right in every screenshot.

 Driven the way a user reaches it now — the + in the grid, then Play in the
 Animations pane — because the grid's own click stopped playing anything. Two
 panes and four presses for one claim is more machinery than a check likes, and it
 is the whole route: it also says a clip can be bound with **no rig at all**,
 which is the state this check starts in and the one binding used to be refused in.
*>
fn void a_clip_brings_its_own_rig() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("a clip clicked on an empty document fits the rig it needs");
	fixture.reset();
	if (fixture.app.pack_clip_count() == 0)
	{
		test::@check(false, "SKIPPED — no animation library");
		return;
	}

	Element*? strip = fixture.ui.find(AreaTabStrip);
	if (catch strip)
	{
		test::@check(false, "SKIPPED — no tab strip in the tree");
		return;
	}
	fixture.click(tab_center(fixture, strip, 1));

	// By plan rather than by taking the first cell: a clips-only file carries the
	// tag of the plan it was authored against, so which asset comes first is
	// decided by name, and only a file with a body has a rig for the click below
	// to place.
	int planned = fixture.app.plan_pack("biped");
	if (planned < 0)
	{
		test::@check(false, "SKIPPED — no pack in the library carries a body");
		return;
	}

	usz pack       = (usz)planned;
	AnimPack* open = fixture.app.pack(pack);
	if (!open)
	{
		test::@check(false, "SKIPPED — the pack went away");
		return;
	}

	Element* clip = null;
	fixture.ui.@each(crig::AssetCell; each)
	{
		if (!clip)
		{
			crig::AssetEntry* entry = fixture.app.visible_asset(each.widget_as(crig::AssetCell).row);
			if (entry && entry.kind == crig::AssetKind.ANIMATION && entry.plan == "biped") clip = each;
		}
	};
	if (!clip)
	{
		test::@check(false, "SKIPPED — no biped clip in the browser");
		return;
	}
	usz row = clip.widget_as(crig::AssetCell).row;

	// The name is read before the click, because which clip the cell stands for is
	// what the check below is about — its position in the pack is not the same
	// number as its position in the browser, which sorts across every file.
	String wanted = fixture.app.visible_asset(row).name;

	test::@check(fixture.doc().dots.len() == 0, "the document starts with nothing placed");
	test::@check(!fixture.app.asset_flags(row).disabled,
		"and its clips are offered rather than greyed against a rig that is not there");

	// Against the joints the plan *places*, not every joint the pack carries: a
	// pack's optional joints are vocabulary for the matcher and `fit_preset` leaves
	// them out, so a handed biped is a 59-joint file that places seventeen dots.
	usz plan_dots = 0;
	for (usz j = 0; j < open.rest.len(); j++)
	{
		if (j >= open.joint_optional.len || !open.joint_optional[j]) plan_dots++;
	}

	// Onto the character first, with nothing placed. The + is the only thing in the
	// grid that acts on a clip, and it does not ask what rig is standing there.
	if (!fixture.bind_click(row))
	{
		test::@check(false, "SKIPPED — the cell went away between finding it and clicking it");
		return;
	}
	fixture.ui.flush();
	test::@check(fixture.doc().animations.len() == 1,
		"a clip would not bind onto a document with no rig in it — %d bound",
		fixture.doc().animations.len());
	test::@check(fixture.doc().dots.len() == 0, "and binding placed a rig, which is Play's job and not the +'s");

	// Then Play, in the pane that owns playing.
	if (try Element* over = fixture.ui.find(AreaTabStrip)) fixture.click(tab_center(fixture, over, TAB_ANIMATIONS));
	fixture.ui.flush();

	Vec2? play = fixture.center_of(crig::ANIM_TRANSPORT_PLAY_ID);
	if (catch play)
	{
		test::@check(false, "SKIPPED — the Animations pane has no Play button");
		return;
	}
	fixture.click(play);
	fixture.ui.flush();

	test::@check(fixture.doc().dots.len() == (sz)plan_dots, "playing a clip places that pack's rig");
	test::@check(fixture.doc().plan == open.plan, "under the pack's own plan");
	test::@check(fixture.app.animating, "and starts playing");
	test::@check(fixture.app.current_ref.pack == (int)pack && fixture.app.current_anim.name == wanted,
		"the clip it plays is %s, the one that was bound, and out of that pack",
		fixture.app.current_anim.name);

	// The rig and the clip that came with it are one entry, like any other
	// body plan — which is what makes trying one free. Back on the 3D pane for it:
	// the chord is aimed at the middle of a pane, and the middle of the Animations
	// pane is its list.
	fixture.app.stop_animation();
	if (try Element* over = fixture.ui.find(AreaTabStrip)) fixture.click(tab_center(fixture, over, TAB_3D));
	fixture.viewport = fixture.ui.find(Viewport)!!;
	fixture.chord(VIEWPORT_CENTER, Key.LEFT_CTRL, Key.Z);
	test::@check(fixture.doc().dots.len() == 0, "and the rig it brought is one Ctrl+Z");

	// A second body plan onto a rig that is already placed is the case this
	// must not do: two skeletons in one document, neither of them what the user
	// asked for.
	test::@check(fixture.app.apply_plan_named("biped"), "with a biped rig placed");
	sz placed = fixture.doc().dots.len();
	usz other = (usz)fixture.app.packs.len();
	foreach (usz i, &entry : fixture.app.packs)
	{
		if (entry.plan != "biped" && entry.is_body_plan() && entry.clips.len > 0)
		{
			other = i;
			break;
		}
	}
	if (other >= (usz)fixture.app.packs.len())
	{
		io::printn("  (the stacking half needs a second body-plan pack — not in this library)");
	}
	else
	{
		test::@check(!fixture.app.play_clip({ (int)other, 0 }), "a clip from another pack refuses to play");
		test::@check(fixture.doc().dots.len() == placed, "and places no second skeleton over the first");
	}

	fixture.doc().free_animations();
	if (try Element* back = fixture.ui.find(AreaTabStrip)) fixture.click(tab_center(fixture, back, TAB_3D));
	fixture.viewport = fixture.ui.find(Viewport)!!;
}

<*
 The default workspace keeps the model, Scene Outliner, Assets and animation
 controls visible together. Generate remains available from the pane's tabs. Check
 both the split tree and actual widget bounds at the startup size and a larger window.
*>
fn void the_default_workspace_opens_four_panes() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	crig::build_ui(f.ui, &f.app);
	f.ui.flush();
	AreaNode* root = crig::area_layout.root;
	test::@check(!root.is_leaf() && root.axis == SplitAxis.VERTICAL,
		"the timeline must be below the upper panes");
	test::@check(root.second.is_leaf() && root.second.active == crig::ANIMATION_VIEW,
		"the bottom pane must show Animations");
	test::@check(!root.first.is_leaf() && root.first.axis == SplitAxis.HORIZONTAL,
		"the upper area must split left and right");
	AreaNode* column = root.first.second;
	test::@check(root.first.first.active == TAB_3D && !column.is_leaf() && column.axis == SplitAxis.VERTICAL,
		"the model must be left of a column of panes");
	test::@check(column.first.active == crig::SCENE_VIEW && column.second.active == crig::LIBRARY_VIEW,
		"the column must hold the Scene Outliner over Assets");
	foreach (size : (Vec2[]) { { crig::WIN_W, crig::WIN_H }, { 1920, 1080 } })
	{
		f.ui.resize(size);
		f.ui.flush();
		Element* model = f.ui.find(Viewport)!!;
		Element* outliner = f.ui.find_id(crig::SCENE_OUTLINER_ID)!!;
		Element* animation = f.ui.find_id(crig::ANIM_PANEL_ID)!!;
		Element* assets = f.ui.find_id(crig::ASSETS_GRID_ID)!!;
		test::@check(assets.absolute.x >= model.absolute.x + model.size.x
			&& assets.absolute.y > outliner.absolute.y,
			"Assets must sit right of the model, under the Scene Outliner");
		// The narrow column's strips give up padding, then shorten the long
		// names, rather than push the last tab — this pane's own — off the end.
		f.ui.@each(AreaTabStrip; strip)
		{
			if (strip.absolute.x < model.absolute.x + model.size.x) continue;
			AreaTabStrip* tabs = strip.widget_as(AreaTabStrip);
			int last = tabs.zone_at(strip, { strip.size.x - 2, strip.size.y * 0.5f });
			test::@check(last == (int)crig::NODES_VIEW + 1,
				"a %.0f px strip ends on tab %d, not on Nodes", strip.size.x, last - 1);
		};
		test::@check(model.size.x > size.x * 0.68f && model.size.x < size.x * 0.76f,
			"the model should occupy nearly three quarters of the width");
		test::@check(outliner.absolute.x >= model.absolute.x + model.size.x,
			"the Scene Outliner must sit to the right of the model");
		test::@check(animation.absolute.y >= model.absolute.y + model.size.y,
			"the animation panel must be below the model");
		test::@check(animation.size.x > size.x * 0.95f,
			"the animation panel must span the window");
		test::@check(model.size.y > size.y * 0.5f, "the model needs the larger height share");
	}
}

fn void split_and_close() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("splitting the workspace:");
	fixture.reset();

	pick_context(fixture, VIEWPORT_CENTER, "Split Vertical");
	test::@check(count_viewports(fixture) == 2, "Split Vertical makes two 3D views");

	Element* left  = null;
	Element* right = null;
	fixture.ui.@each(Viewport ; v)
	{
		if (left == null)
		{
			left = v;
		}
		else if (v.absolute.x < left.absolute.x)
		{
			right = left;
			left = v;
		}
		else
		{
			right = v;
		}
	};
	if (left == null || right == null)
	{
		test::@check(false, "SKIPPED — could not find both panes");
		return;
	}

	// Both panes route clicks through their own rect and projection: the same
	// world point is the view-center ray in each, so a dot placed through one
	// pane's center is picked right back up through the other's.
	sz before = fixture.doc().dots.len();
	fixture.click(left.absolute + left.size * 0.5f);
	test::@check(fixture.doc().dots.len() == before + 1, "a click in the left pane places a dot");
	uint placed = fixture.app.selected;

	fixture.app.selected = 0;
	fixture.click(right.absolute + right.size * 0.5f);
	test::@check(fixture.app.selected == placed, "the right pane picks that dot through its own projection");

	// The divider drag: a relayout, not a rebuild, so the pane handles stay live.
	Element*? handle = fixture.ui.find(AreaSplitter);
	if (catch handle)
	{
		test::@check(false, "SKIPPED — no splitter handle in the tree");
		return;
	}
	float left_before = left.size.x;
	Vec2 grab         = handle.absolute + handle.size * 0.5f;
	fixture.drag(grab, grab + (Vec2) { 100.0, 0.0 });
	test::@check(math::abs(left.size.x - (left_before + 100.0f)) < 1.0f, "dragging the divider grows the left pane");

	grab = handle.absolute + handle.size * 0.5f;
	fixture.drag(grab, (Vec2) { 10.0, grab.y });
	test::@check(math::abs(left.size.x - crig::AREA_STYLE.min_pane) < 1.0f, "and it stops at the minimum pane width");

	// Close the right pane from its own context menu; the left takes the
	// whole width. Lower in the pane, clear of the dot at its centre — a
	// right-press on a dot raises the joint menu now, so the pane menu is off it.
	pick_context(fixture, right.absolute + right.size * (Vec2){ 0.5f, 0.75f }, "Close");
	test::@check(count_viewports(fixture) == 1, "closing the right pane leaves one");
	test::@check(crig::area_layout.root.is_leaf(), "and the pane tree is a single leaf again");

	// The last pane cannot close: its row is greyed, the click changes nothing
	// and leaves the menu open the way a dead menu item leaves its dropdown.
	pick_context(fixture, VIEWPORT_CENTER + (Vec2){ 0.0f, 120.0f }, "Close");
	test::@check(count_viewports(fixture) == 1, "the last pane's Close is a no-op");
	fixture.click(SPOT_A); // dismiss the still-open menu

	fixture.viewport = fixture.ui.find(Viewport)!!;
}

<*
 The context menu: a right press in a pane offers the splits and close, one on
 a divider offers the merges — the same tree operations the strip's glyphs
 drive, reached without the trip to the strip. Merge directions name the pane
 that remains.
*>
fn void context_menu_splits_and_merges() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("the right-click menu splits panes and merges them back");
	fixture.reset();

	// The press that opens the menu must not fall through to the model.
	sz dots_before = fixture.doc().dots.len();
	fixture.right_click(VIEWPORT_CENTER);
	test::@check(fixture.doc().dots.len() == dots_before, "the right press places no dot");

	Element*? split_row = fixture.ui.find_id("Split Vertical");
	if (catch split_row)
	{
		test::@check(false, "SKIPPED — the context menu did not open");
		return;
	}
	fixture.click(split_row.absolute + split_row.size * 0.5f);
	test::@check(count_viewports(fixture) == 2, "Split Vertical makes two 3D views");

	// The divider's own right-click offers the merges instead.
	Element*? handle = fixture.ui.find(AreaSplitter);
	if (catch handle)
	{
		test::@check(false, "SKIPPED — no splitter handle in the tree");
		return;
	}
	fixture.right_click(handle.absolute + handle.size * 0.5f);
	Element*? merge_row = fixture.ui.find_id("Merge Left");
	if (catch merge_row)
	{
		test::@check(false, "SKIPPED — the divider menu did not open");
		return;
	}
	fixture.click(merge_row.absolute + merge_row.size * 0.5f);
	test::@check(count_viewports(fixture) == 1, "Merge Left folds the workspace back to one pane");
	test::@check(crig::area_layout.root.is_leaf(), "and the pane tree is a single leaf again");

	// Dismissing the menu swallows the click: nothing lands on the model, and
	// SPOT_A is a spot where a fallen-through press would have placed a dot.
	fixture.right_click(VIEWPORT_CENTER);
	dots_before = fixture.doc().dots.len();
	fixture.click(SPOT_A);
	test::@check(fixture.doc().dots.len() == dots_before, "the dismissing click places nothing");
	bool closed = true;
	if (try Element* row = fixture.ui.find_id("Split Vertical")) closed = false;
	test::@check(closed, "and the menu is gone");

	fixture.viewport = fixture.ui.find(Viewport)!!;
}

<*
 The focus rationale, restated for the strip: its widgets have no on_key, so a
 click on a tab resolves focus up to AppRoot and the keyboard keeps working —
 the same property check_shortcuts_survive_menu_clicks pins for the bar.
*>
fn void shortcuts_survive_tab_clicks() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("shortcuts survive the tab strip");
	fixture.reset();

	fixture.click(SPOT_B);
	sz placed = fixture.doc().dots.len();
	test::@check(placed > 0, "a dot to undo");

	Element*? strip = fixture.ui.find(AreaTabStrip);
	if (catch strip)
	{
		test::@check(false, "SKIPPED — no tab strip in the tree");
		return;
	}
	fixture.click(tab_center(fixture, strip, 1));
	if (try Element* s2 = fixture.ui.find(AreaTabStrip)) fixture.click(tab_center(fixture, s2, 0));

	fixture.chord(VIEWPORT_CENTER, Key.LEFT_CTRL, Key.Z);
	test::@check(fixture.doc().dots.len() == placed - 1, "ctrl+Z still lands after clicking tabs");

	fixture.viewport = fixture.ui.find(Viewport)!!;
}

<*
 The search box narrows the grid as the characters land, not on Return.

 A field that only reported on submit makes a search the user has to finish
 before anything happens, which is a different thing from a search box. Asserted
 on the cells actually built rather than on the filter, because the cells are
 what a person sees — a filter that narrowed while the grid kept its children
 would pass a check on the filter alone.
*>
fn void the_search_box_narrows_the_grid_as_it_is_typed() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("the search box narrows the grid while it is typed");
	fixture.reset();

	Element*? strip = fixture.ui.find(AreaTabStrip);
	if (catch strip)
	{
		test::@check(false, "SKIPPED — no tab strip in the tree");
		return;
	}
	fixture.click(tab_center(fixture, strip, 1));

	Element*? search = fixture.ui.find_id(crig::ASSETS_SEARCH_ID);
	if (catch search)
	{
		test::@check(false, "SKIPPED — the browser has no search box");
		return;
	}

	usz everything = count_cells(fixture);
	test::@check(everything > 0, "the browser came up empty");

	// One character at a time, with no Return anywhere: what is being checked is
	// that the grid moved before the field was submitted.
	fixture.type_into(search, "q");
	usz after_one = count_cells(fixture);
	test::@check(after_one < everything,
		"one typed character left %d of %d cells — the grid did not narrow", after_one, everything);

	fixture.type_into(search, "uad");
	usz after_four = count_cells(fixture);
	test::@check(after_four > 0, "searching for quad matched nothing at all");
	test::@check(after_four <= after_one, "and a longer search does not widen it");

	// Everything left is in that file, name or path — the browser must not keep a
	// cell that no longer matches what is in the box.
	fixture.ui.@each(crig::AssetCell; cell)
	{
		crig::AssetEntry* entry = fixture.app.visible_asset(cell.widget_as(crig::AssetCell).row);
		if (entry)
		{
			test::@check(entry.file.len >= 13 && entry.file[^13..] == "quadruped.glb",
				"%s survived a search for quad and came out of %s", entry.name, entry.file);
		}
	};

	// Cleared with Backspace rather than by setting the text, so the deletion path
	// reports too — a search that narrowed and never widened again would be worse
	// than one that did nothing.
	for (usz i = 0; i < 4; i++) fixture.tap(cell_or_center(search), Key.BACKSPACE);
	test::@check(count_cells(fixture) == everything,
		"clearing the box brings every cell back");

	if (try Element* back = fixture.ui.find(AreaTabStrip)) fixture.click(tab_center(fixture, back, 0));
	fixture.viewport = fixture.ui.find(Viewport)!!;
}

// How many cells the grid is currently showing.
fn usz count_cells(Fixture* fixture)
{
	usz found = 0;
	fixture.ui.@each(crig::AssetCell; cell) { found++; };
	return found;
}

// The middle of an element, for a key aimed at it.
fn Vec2 cell_or_center(Element* elem) => elem.absolute + elem.size * 0.5f;

<*
 The middle of a sidebar row's disclosure mark, in window coordinates.

 A different target from `category_center`: cui's Tree gives the mark the indent
 step immediately left of the label and toggles on a click there, selecting on a
 click anywhere else in the row. Aiming at the middle of the row would exercise
 selection and say nothing about collapsing.

 @param depth : `How deep the row sits — the mark's column follows the indent.`
*>
fn Vec2 category_mark(Element* tree, usz row, usz depth)
{
	TreeStyle style = tree.widget_as(Tree).style.resolved();
	float text_x = tree.widget_as(Tree).text_x(style, depth);
	return tree.absolute + (Vec2) {
		text_x - style.indent * 0.5f,
		((float)row + 0.5f) * style.row_height,
	};
}

<*
 Where in the frame's paint order the first rectangle of this colour inside `rect`
 was recorded, or -1 when there is none.

 The canvas is the display list the renderer consumes, in the order the painter
 filled it, so an index into it is a z position: of two things covering the same
 pixels, the one recorded later is the one the user sees. This is the only way to
 ask "is it on top" from a test — the elements' own rects say where things are and
 nothing about which won.

 @param corner : `Top-left of the window region to look in.`
 @param size : `Its extent. A drawing counts when its centre falls inside.`
*>
fn int painted_at(Fixture* fixture, Color color, Vec2 corner, Vec2 size)
{
	foreach (usz i, drawing : fixture.ui.canvas.drawings.array_view())
	{
		if (drawing.kind != DrawingKind.RECT) continue;
		if (drawing.color != (Vec4)color) continue;

		Vec2 at = drawing.corner + drawing.size * 0.5f;
		if (at.x < corner.x || at.x >= corner.x + size.x) continue;
		if (at.y < corner.y || at.y >= corner.y + size.y) continue;
		return (int)i;
	}
	return -1;
}

<*
 A category row narrows the grid to that kind, and "All" widens it again.

 The sidebar and the search are two narrowings a person expects to combine, so
 the search box is left alone by a category click — asserted here, because the
 obvious implementation of "narrow to this category" is to build a whole new
 filter and quietly drop the text out of the box.
*>
fn void a_category_narrows_the_grid_to_its_kind() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("a category row narrows the grid");
	fixture.reset();

	Element*? strip = fixture.ui.find(AreaTabStrip);
	if (catch strip)
	{
		test::@check(false, "SKIPPED — no tab strip in the tree");
		return;
	}
	fixture.click(tab_center(fixture, strip, 1));

	Element*? tree = fixture.ui.find_id(crig::ASSETS_TREE_ID);
	if (catch tree)
	{
		test::@check(false, "SKIPPED — the browser has no sidebar");
		return;
	}

	usz everything = count_cells(fixture);
	usz clips_row = category_row(fixture, crig::AssetKind.ANIMATION);
	if (clips_row >= fixture.app.asset_categories.len)
	{
		test::@check(false, "SKIPPED — no Animations row in the sidebar");
		return;
	}
	usz expected = fixture.app.asset_categories[clips_row].count;

	fixture.click(category_center(tree, clips_row));
	usz narrowed = count_cells(fixture);
	test::@check(narrowed == expected,
		"the Animations row counts %d and the grid drew %d", expected, narrowed);
	test::@check(narrowed < everything, "and that is fewer than the whole library");

	fixture.ui.@each(crig::AssetCell; cell)
	{
		crig::AssetEntry* entry = fixture.app.visible_asset(cell.widget_as(crig::AssetCell).row);
		if (entry) test::@check(entry.kind == crig::AssetKind.ANIMATION, "%s is not a clip", entry.name);
	};

	// Row 0 is All, which `categories` always emits first.
	fixture.click(category_center(tree, 0));
	test::@check(count_cells(fixture) == everything, "and All brings the rest back");

	if (try Element* back = fixture.ui.find(AreaTabStrip)) fixture.click(tab_center(fixture, back, 0));
	fixture.viewport = fixture.ui.find(Viewport)!!;
}

<*
 The rows the sidebar is actually drawing.

 Read off the widget rather than off `app.asset_categories`, which is the trap
 this whole area sets: the Tree *borrows* its rows, and the only thing that
 renews the borrow is the pane's own build. State that changes the categories
 without asking for that build leaves the app right and the screen wrong, which
 is a check on the app state passing while nothing on screen moves.

 Empty when the browser is not up.
*>
fn TreeRow[] sidebar_rows(Fixture* fixture)
{
	Element*? tree = fixture.ui.find_id(crig::ASSETS_TREE_ID);
	if (catch tree) return {};
	return tree.widget_as(Tree).rows;
}

// How many body-plan rows the sidebar is showing under a kind.
fn usz plan_rows_under(Fixture* fixture, crig::AssetKind kind)
{
	usz found = 0;
	foreach (category : fixture.app.asset_categories)
	{
		if (category.depth == 2 && category.kind == kind) found++;
	}
	return found;
}

// The first body-plan row under a kind, or past the end when it has none.
fn usz plan_row_under(Fixture* fixture, crig::AssetKind kind)
{
	foreach (usz i, category : fixture.app.asset_categories)
	{
		if (category.depth == 2 && category.kind == kind) return i;
	}
	return fixture.app.asset_categories.len;
}

<*
 The library chooser's list is drawn over the sidebar rather than under it.

 cui records an open `Select`'s popup in the Select's own slot in the paint
 order — its own doc comment says so — so a toolbar built before the content it
 covers is a list the sidebar is then painted straight over. The chooser sits
 directly above the category tree, which is the one thing its list has to be
 readable against.

 Asked of the display list because that is where the answer is. The elements'
 rects say the list and the sidebar occupy the same pixels; only the order the
 painter filled them in says which one the user sees.
*>
fn void the_library_chooser_opens_over_the_sidebar() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("the library chooser drops its list over the sidebar");
	fixture.reset();

	Element*? strip = fixture.ui.find(AreaTabStrip);
	if (catch strip)
	{
		test::@check(false, "SKIPPED — no tab strip in the tree");
		return;
	}
	fixture.click(tab_center(fixture, strip, 1));

	Element*? tree = fixture.ui.find_id(crig::ASSETS_TREE_ID);
	if (catch tree)
	{
		test::@check(false, "SKIPPED — the browser has no sidebar");
		return;
	}
	Element*? chooser = fixture.ui.find_id(crig::ASSETS_LIBRARY_ID);
	if (catch chooser)
	{
		test::@check(false, "SKIPPED — the browser has no library chooser");
		return;
	}

	// The browser opens on "All", so the sidebar has a filled selection rect
	// directly under the toolbar for the list to land on. Without something
	// painted there the comparison below would have nothing to compare against.
	int row = painted_at(fixture, crig::ACCENT, tree.absolute, tree.size);
	if (row < 0)
	{
		test::@check(false, "SKIPPED — the sidebar draws no selected row for the list to cover");
		return;
	}

	fixture.click(cell_or_center(chooser));

	// Re-resolved: opening the chooser rebuilds the subtree it sits in.
	Element*? opened = fixture.ui.find_id(crig::ASSETS_TREE_ID);
	if (catch opened)
	{
		test::@check(false, "the sidebar went away when the chooser opened");
		return;
	}

	int list = painted_at(fixture, crig::MENU_STYLE.panel_color, opened.absolute, opened.size);
	int covered = painted_at(fixture, crig::ACCENT, opened.absolute, opened.size);
	test::@check(list >= 0, "the chooser dropped no list over the sidebar at all");
	test::@check(covered >= 0, "the sidebar stopped drawing its selected row");
	test::@check(list > covered,
		"the list is recorded at %d and the sidebar row under it at %d — the sidebar wins", list, covered);

	// Shut before leaving. An open Select lays a window-wide catcher over
	// everything, so the tab click below would only close the list.
	if (try Element* head = fixture.ui.find_id(crig::ASSETS_LIBRARY_ID)) fixture.click(cell_or_center(head));

	if (try Element* back = fixture.ui.find(AreaTabStrip)) fixture.click(tab_center(fixture, back, 0));
	fixture.viewport = fixture.ui.find(Viewport)!!;
}

<*
 A category's disclosure mark closes it, and closing narrows nothing.

 Two gestures on one row: the mark opens and closes, the label narrows the grid.
 Both halves are asserted, because the obvious way to wire a collapse is through
 the same callback the selection uses — which makes a category impossible to
 close without also filtering by it.

 The last part is the state that has to be repaired rather than merely hidden: a
 plan row that is the current filter cannot simply vanish, or the grid keeps
 showing one body plan with no row on screen saying why.
*>
fn void a_category_closes_from_its_mark() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("a category closes from its disclosure mark");
	fixture.reset();

	Element*? strip = fixture.ui.find(AreaTabStrip);
	if (catch strip)
	{
		test::@check(false, "SKIPPED — no tab strip in the tree");
		return;
	}
	fixture.click(tab_center(fixture, strip, 1));

	Element*? tree = fixture.ui.find_id(crig::ASSETS_TREE_ID);
	if (catch tree)
	{
		test::@check(false, "SKIPPED — the browser has no sidebar");
		return;
	}

	usz clips_row = category_row(fixture, crig::AssetKind.ANIMATION);
	usz plans = plan_rows_under(fixture, crig::AssetKind.ANIMATION);
	usz skins = plan_rows_under(fixture, crig::AssetKind.SKIN);
	if (clips_row >= fixture.app.asset_categories.len || plans == 0 || skins == 0)
	{
		test::@check(false, "SKIPPED — the shipped library has no kind with plans under it");
		return;
	}

	usz rows = fixture.app.asset_categories.len;
	usz everything = count_cells(fixture);
	io::printfn("  Animations holds %d plan rows of %d in the sidebar", plans, rows);

	// Depth 1: a kind heading, one indent step in, and the mark sits in the step
	// left of its label.
	fixture.click(category_mark(tree, clips_row, 1));

	test::@check(fixture.app.kind_collapsed(crig::AssetKind.ANIMATION), "the mark did not close the kind");
	test::@check(plan_rows_under(fixture, crig::AssetKind.ANIMATION) == 0,
		"and its plan rows are still in the sidebar");
	test::@check(fixture.app.asset_categories.len == rows - plans,
		"the sidebar lost %d rows, not the %d under Animations",
		rows - fixture.app.asset_categories.len, plans);
	test::@check(plan_rows_under(fixture, crig::AssetKind.SKIN) == skins,
		"closing one kind took the plans out from under another");
	test::@check(category_row(fixture, crig::AssetKind.ANIMATION) < fixture.app.asset_categories.len,
		"and it closed the kind's own row along with them");

	// The half the app state cannot answer: the sidebar has to have been rebuilt,
	// or the rows it borrows are the ones from before the click.
	test::@check(sidebar_rows(fixture).len == rows - plans,
		"the app dropped the rows and the sidebar is still drawing %d of them",
		sidebar_rows(fixture).len);
	test::@check(!sidebar_rows(fixture)[clips_row].expanded,
		"and its mark still points down at rows that are not there");

	// A closed category is still a category. Nothing about the grid changed,
	// because the mark is not the label.
	test::@check(count_cells(fixture) == everything,
		"closing a category narrowed the grid to %d of %d cells", count_cells(fixture), everything);

	// Open it again from the same pixel: the mark is a switch, not a one-way door.
	Element* reopen = fixture.ui.find_id(crig::ASSETS_TREE_ID)!!;
	fixture.click(category_mark(reopen, clips_row, 1));
	test::@check(!fixture.app.kind_collapsed(crig::AssetKind.ANIMATION), "the mark would not open it again");
	test::@check(sidebar_rows(fixture).len == rows, "and the rows under it did not all come back");

	// Now narrow to a plan and close the kind over the top of it.
	Element* narrowing = fixture.ui.find_id(crig::ASSETS_TREE_ID)!!;
	usz plan = plan_row_under(fixture, crig::AssetKind.ANIMATION);
	fixture.click(category_center(narrowing, plan));
	if (fixture.app.asset_filter.any_plan)
	{
		test::@check(false, "clicking a plan row did not narrow to that plan");
		return;
	}

	Element* closing = fixture.ui.find_id(crig::ASSETS_TREE_ID)!!;
	fixture.click(category_mark(closing, category_row(fixture, crig::AssetKind.ANIMATION), 1));
	test::@check(fixture.app.asset_filter.any_plan,
		"the grid is still narrowed to \"%s\" with no row left to say so", fixture.app.asset_filter.plan);
	test::@check(crig::selected_category(&fixture.app) == category_row(fixture, crig::AssetKind.ANIMATION),
		"and the kind it widened to is not the row the sidebar lights");

	if (try Element* back = fixture.ui.find(AreaTabStrip)) fixture.click(tab_center(fixture, back, 0));
	fixture.viewport = fixture.ui.find(Viewport)!!;
}

<*
 A kind heading's label narrows on the first click and closes on the second.

 The whole row, not the indent step at its left edge. A disclosure mark is the
 conventional target and it is also fourteen pixels wide; the row is the width of
 the sidebar, and a second click on it had no meaning before this — the filter it
 would set is the one already set.

 Only a heading behaves this way. A plan row clicked twice is a plan row clicked
 twice, which is what the last part checks: it has nothing under it to close, and
 a rule written as "the selected row toggles" would leave the grid narrowed to a
 body plan while the sidebar folded something shut.
*>
fn void a_second_click_on_a_category_closes_it() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("clicking a chosen category again closes it");
	fixture.reset();

	Element*? strip = fixture.ui.find(AreaTabStrip);
	if (catch strip)
	{
		test::@check(false, "SKIPPED — no tab strip in the tree");
		return;
	}
	fixture.click(tab_center(fixture, strip, 1));

	Element*? tree = fixture.ui.find_id(crig::ASSETS_TREE_ID);
	if (catch tree)
	{
		test::@check(false, "SKIPPED — the browser has no sidebar");
		return;
	}

	usz clips_row = category_row(fixture, crig::AssetKind.ANIMATION);
	usz plans = plan_rows_under(fixture, crig::AssetKind.ANIMATION);
	if (clips_row >= fixture.app.asset_categories.len || plans == 0)
	{
		test::@check(false, "SKIPPED — the shipped library has no kind with plans under it");
		return;
	}
	usz rows = fixture.app.asset_categories.len;
	usz everything = count_cells(fixture);

	// First click: the middle of the row, nowhere near the mark. This narrows.
	fixture.click(category_center(tree, clips_row));
	test::@check(!fixture.app.kind_collapsed(crig::AssetKind.ANIMATION),
		"the first click on a category closed it instead of choosing it");
	test::@check(count_cells(fixture) < everything, "and it did not narrow the grid");
	test::@check(sidebar_rows(fixture).len == rows, "and it took rows out of the sidebar");

	// Second click, same pixel. The row is already the one narrowing the grid, so
	// now it folds.
	Element* again = fixture.ui.find_id(crig::ASSETS_TREE_ID)!!;
	usz narrowed = count_cells(fixture);
	fixture.click(category_center(again, clips_row));
	test::@check(fixture.app.kind_collapsed(crig::AssetKind.ANIMATION),
		"clicking the chosen category again did nothing");
	test::@check(sidebar_rows(fixture).len == rows - plans,
		"the sidebar is drawing %d rows, not the %d left after closing one kind",
		sidebar_rows(fixture).len, rows - plans);
	test::@check(count_cells(fixture) == narrowed,
		"and closing it changed what the grid is showing as well");

	// Third click opens it again: one target, one switch.
	Element* third = fixture.ui.find_id(crig::ASSETS_TREE_ID)!!;
	fixture.click(category_center(third, clips_row));
	test::@check(sidebar_rows(fixture).len == rows, "a third click did not open it back up");

	// A plan row has nothing under it, so clicking it twice must stay a click on
	// a plan row.
	Element* plans_tree = fixture.ui.find_id(crig::ASSETS_TREE_ID)!!;
	usz plan = plan_row_under(fixture, crig::AssetKind.ANIMATION);
	fixture.click(category_center(plans_tree, plan));
	Element* twice = fixture.ui.find_id(crig::ASSETS_TREE_ID)!!;
	fixture.click(category_center(twice, plan));
	test::@check(!fixture.app.asset_filter.any_plan, "a plan row clicked twice stopped narrowing to its plan");
	test::@check(sidebar_rows(fixture).len == rows, "and folded a category it does not head");

	if (try Element* back = fixture.ui.find(AreaTabStrip)) fixture.click(tab_center(fixture, back, 0));
	fixture.viewport = fixture.ui.find(Viewport)!!;
}

<*
 The settings panel opens from the menu, and a library added there reaches the
 browser without a restart.

 The second half is the point. A folder added in the settings that did not appear
 until crig was started again would read as not having been added at all, so the
 rescan is part of the action rather than something deferred to next time.
*>
fn void settings_adds_a_library_and_the_browser_sees_it() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("a library added in the settings reaches the browser");
	fixture.reset();

	Vec2? file_title = fixture.center_of("File");
	if (catch file_title)
	{
		test::@check(false, "SKIPPED — the File title is not on the bar");
		return;
	}
	fixture.click(file_title);

	Vec2? item = fixture.center_of("Settings");
	if (catch item)
	{
		test::@check(false, "SKIPPED — no Settings item in the File menu");
		return;
	}
	fixture.click(item);

	Dialog*? panel = fixture.ui.get_widget_id(crig::SETTINGS_DIALOG_ID, Dialog);
	if (catch panel)
	{
		test::@check(false, "SKIPPED — no settings dialog in the tree");
		return;
	}
	test::@check(panel.open, "File > Settings brings the panel up");
	test::@check(fixture.in_tree(crig::SETTINGS_LIBRARIES_ID), "with the library list in it");
	test::@check(fixture.app.library_rows.len == (usz)fixture.app.config.libraries.len(),
		"listing every configured library");

	// Added through the same call the file chooser makes, rather than by clicking
	// through the chooser: what is being checked is that the browser follows, and
	// walking a second dialog to get there would be checking the chooser instead.
	// A folder holding the same three packs, so the count doubles exactly and
	// nothing about the check depends on what else is on this machine.
	usz before = fixture.app.assets.entries.len;
	crig::add_asset_library(fixture.ui, library::ready_second());
	fixture.ui.flush();

	test::@check(fixture.app.config.libraries.len() == 2, "the folder is configured");
	test::@check(fixture.app.assets.entries.len == before * 2,
		"and rescanned at once — %d assets became %d", before, fixture.app.assets.entries.len);
	test::@check(fixture.app.library_rows.len == 2, "the panel's own list follows without reopening");
	test::@check(fixture.app.library_labels.len == 3,
		"and so does the browser's chooser, All libraries included");

	// And back out, so the workspace the other checks share is as it was.
	crig::settings_remove_library(fixture.ui);
	if (fixture.app.config.libraries.len() > 1)
	{
		// Nothing was selected, which is what the panel greys with a notice rather
		// than guessing at. Removed by index instead, since this is teardown.
		fixture.app.config.remove_library(1);
		fixture.app.scan_libraries();
	}
	test::@check(fixture.app.assets.entries.len == before, "removing it puts the library back as it was");

	panel.set_open(fixture.ui.find_id(crig::SETTINGS_DIALOG_ID)!!, false);
	fixture.ui.flush();
}

<*
 How big the interface is drawn: the keys walk it, the ends hold, and the panel
 follows.

 The setting exists because three lays cui out in the render target's *pixels*,
 which on a HiDPI output is twice as many as there are points — so a window that
 came up half-size is the state a user has to get out of, and every route out of
 it is checked here rather than only the one the panel offers. `ctrl+=` in
 particular: it is the route that works when the panel is too small to read.

 Nothing here asserts the layout moved, and that is deliberate. What `set_scale`
 does is the engine's to check, and there is no engine in a test — `hosted()` is
 false, `apply_ui_scale` returns without touching anything, and what is left is
 exactly crig's half: which number the keys land on and whether it is written
 down.
*>
fn void the_interface_scale_steps_and_holds_at_the_ends() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("stepping the interface size:");
	fixture.reset();

	test::@check(fixture.app.config.ui_scale == crig::DEFAULT_UI_SCALE,
		"it opens at the size the display asks for (%.2f)", fixture.app.config.ui_scale);

	// The stops rather than a fixed increment: the difference between 1.0 and 1.1
	// is worth a keystroke and the difference between 2.5 and 2.6 is not.
	crig::nudge_ui_scale(fixture.ui, 1);
	test::@check(fixture.app.config.ui_scale == 1.1f,
		"one step up is the next stop, not a fixed increment (%.2f)", fixture.app.config.ui_scale);

	crig::nudge_ui_scale(fixture.ui, -1);
	test::@check(fixture.app.config.ui_scale == crig::DEFAULT_UI_SCALE,
		"and one back down is where it started (%.2f)", fixture.app.config.ui_scale);

	// Far more presses than there are stops, which is what a held key is.
	for (usz i = 0; i < 40; i++) crig::nudge_ui_scale(fixture.ui, 1);
	test::@check(fixture.app.config.ui_scale == crig::MAX_UI_SCALE,
		"holding it up settles at the top (%.2f)", fixture.app.config.ui_scale);

	for (usz i = 0; i < 40; i++) crig::nudge_ui_scale(fixture.ui, -1);
	test::@check(fixture.app.config.ui_scale == crig::MIN_UI_SCALE,
		"and holding it down settles at the bottom (%.2f)", fixture.app.config.ui_scale);

	crig::nudge_ui_scale(fixture.ui, 0);
	test::@check(fixture.app.config.ui_scale == crig::DEFAULT_UI_SCALE,
		"reset comes back to the default from either end (%.2f)", fixture.app.config.ui_scale);

	// A value the slider can leave it on, which is not a stop: the next step up
	// has to be the stop above it rather than one it has already passed.
	crig::adopt_ui_scale(&fixture.app, 1.35f);
	crig::nudge_ui_scale(fixture.ui, 1);
	test::@check(fixture.app.config.ui_scale == 1.5f,
		"a step from between two stops goes to the one above (%.2f)", fixture.app.config.ui_scale);
	crig::nudge_ui_scale(fixture.ui, 0);

	// And through the keys the user actually presses, which is the half that
	// would break silently if the ctrl block stopped reaching them.
	crig::adopt_ui_scale(&fixture.app, crig::DEFAULT_UI_SCALE);
	fixture.chord(VIEWPORT_CENTER, Key.LEFT_CTRL, Key.EQUALS);
	test::@check(fixture.app.config.ui_scale == 1.1f,
		"ctrl+= draws it bigger (%.2f)", fixture.app.config.ui_scale);

	fixture.chord(VIEWPORT_CENTER, Key.LEFT_CTRL, Key.MINUS);
	test::@check(fixture.app.config.ui_scale == crig::DEFAULT_UI_SCALE,
		"ctrl+- draws it smaller (%.2f)", fixture.app.config.ui_scale);

	fixture.chord(VIEWPORT_CENTER, Key.LEFT_CTRL, Key.KP_ADD);
	fixture.chord(VIEWPORT_CENTER, Key.LEFT_CTRL, Key.KEY_0);
	test::@check(fixture.app.config.ui_scale == crig::DEFAULT_UI_SCALE,
		"and ctrl+0 puts it back (%.2f)", fixture.app.config.ui_scale);

	// Plain `=` is not the shortcut: it is free, and a setting changed twice a
	// year does not get to claim an unmodified key on a rigging tool.
	fixture.tap(VIEWPORT_CENTER, Key.EQUALS);
	test::@check(fixture.app.config.ui_scale == crig::DEFAULT_UI_SCALE,
		"the plain key is left alone (%.2f)", fixture.app.config.ui_scale);
}

<*
 The setting is on a slider in File > Settings, and the slider shows where the
 keys left it.

 The panel is built from `config.ui_scale` on every opening, so the check that
 matters is that a size chosen from the keyboard is what the slider comes up
 holding — a panel that opened at 1.00 whatever the interface was doing would be
 a control that fights the thing it is meant to show.
*>
fn void the_settings_panel_shows_the_interface_size() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("the interface size on the settings panel:");
	fixture.reset();

	crig::adopt_ui_scale(&fixture.app, 1.5f);

	Vec2? file_title = fixture.center_of("File");
	if (catch file_title)
	{
		test::@check(false, "SKIPPED — the File title is not on the bar");
		return;
	}
	fixture.click(file_title);

	Vec2? item = fixture.center_of("Settings");
	if (catch item)
	{
		test::@check(false, "SKIPPED — no Settings item in the File menu");
		return;
	}
	fixture.click(item);

	Slider*? slider = fixture.ui.get_widget_id(crig::SETTINGS_SCALE_ID, Slider);
	if (catch slider)
	{
		test::@check(false, "SKIPPED — no interface slider in the settings panel");
		return;
	}

	test::@check(slider.value == 1.5f, "the slider opens where the keys left it (%.2f)", slider.value);
	test::@check(slider.min == crig::MIN_UI_SCALE && slider.max == crig::MAX_UI_SCALE,
		"over the range the keys reach (%.2f to %.2f)", slider.min, slider.max);

	Slider*? overlay = fixture.ui.get_widget_id(crig::SETTINGS_RIG_OVERLAY_ID, Slider);
	if (catch overlay)
	{
		test::@check(false, "SKIPPED — no rig overlay slider in the settings panel");
		return;
	}
	test::@check(overlay.value == 100.0f && overlay.min == 10.0f && overlay.max == 100.0f,
		"the rig overlay offers its persistent 10–100%% range (%.0f, %.0f–%.0f)",
		overlay.value, overlay.min, overlay.max);
	crig::rig_overlay_strength_committed(fixture.ui, 35.0f);
	test::@check(math::abs(fixture.app.config.rig_overlay_strength - 0.35f) < 0.001f,
		"releasing the overlay slider adopts 35%% (%.3f)", fixture.app.config.rig_overlay_strength);
	crig::reset_rig_overlay_strength(fixture.ui);
	test::@check(fixture.app.config.rig_overlay_strength == crig::DEFAULT_RIG_OVERLAY_STRENGTH,
		"its Reset restores the restrained default");
	fixture.ui.flush();
	Slider*? overlay_after = fixture.ui.get_widget_id(crig::SETTINGS_RIG_OVERLAY_ID, Slider);
	if (try overlay_after)
	{
		test::@check(overlay_after.value == 100.0f,
			"the rebuilt panel shows Reset at 100%% (%.0f)", overlay_after.value);
	}
	else { test::@check(false, "the rig overlay slider survives its panel rebuild"); }

	// The track and the Reset button share a row, and the slider is given a fixed
	// width rather than left to fill it — so the one thing that can go wrong is
	// the button being pushed off the side of a panel that is not going to grow
	// for it. Measured rather than eyeballed, because it moves whenever either
	// the width or the label does.
	Element* row = fixture.ui.find_id(crig::SETTINGS_SCALE_ID)!!.parent;
	test::@check(row != null && row.size.x <= crig::SETTINGS_DIALOG_W,
		"the slider and Reset fit the panel (%.0f of %.0f)",
		row ? row.size.x : 0.0f, crig::SETTINGS_DIALOG_W);

	// Released on a new value: the commit is what takes it, so that a drag does
	// not re-lay out the panel under the pointer holding it.
	crig::ui_scale_committed(fixture.ui, 2.0f);
	test::@check(fixture.app.config.ui_scale == 2.0f,
		"and a release on the track is taken (%.2f)", fixture.app.config.ui_scale);

	crig::nudge_ui_scale(fixture.ui, 0);

	if (try Dialog* panel = fixture.ui.get_widget_id(crig::SETTINGS_DIALOG_ID, Dialog))
	{
		panel.set_open(fixture.ui.find_id(crig::SETTINGS_DIALOG_ID)!!, false);
		fixture.ui.flush();
	}
}
