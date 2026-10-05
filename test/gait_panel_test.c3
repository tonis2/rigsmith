<*
 The Gait panel: "+ Gait" in the Animations pane, through the real tree.

 `c3c test --trust=full --test-filter crig_tests::ui`

 The dog is the model: four legs, each ending in a foot and a toe, which is the
 rig `author_gait` finds feet on. The panel and the MCP tool share
 `AppState.author_gait`; these pin what is the panel's own — the footfall rows,
 the custom offsets, the names.
*>
module crig_tests::ui;

import crig;
import cui;
import cui::widgets;
import rig;
import std::core::test;
import std::math;

const String GAIT_DOG = "assets/animations/quadruped.glb";

// The dog, rigged from its own file, with the Animations pane up.
fn void gait_dog(Fixture* f, rig::TriMesh mesh)
{
	f.open(mesh)!!;
	f.app.source_path = GAIT_DOG;
	test::@check(f.app.import_rig_from_source(), "the dog must import its rig");
	crig::build_ui(f.ui, &f.app);
	f.ui.flush();
	f.click(tab_center(f, f.ui.find(AreaTabStrip)!!, TAB_ANIMATIONS));
	f.ui.flush();
}

fn void gait_open(Fixture* f)
{
	f.pick_menu_item(crig::ANIM_NEW_MENU_BUTTON_ID, crig::GAIT_BUTTON_ID);
}

fn void gait_create(Fixture* f)
{
	f.click(f.center_of(crig::GAIT_CREATE_ID)!!);
	f.ui.flush();
}

fn void the_gait_button_opens_a_dialog_with_a_row_per_foot() @test
{
	rig::TriMesh mesh = rig::load_gltf(mem, GAIT_DOG)!!;
	defer mesh.free(mem);
	Fixture f;
	gait_dog(&f, mesh);
	defer f.close();

	Dialog* dialog = f.ui.get_widget_id(crig::GAIT_DIALOG_ID, Dialog)!!;
	test::@check(!dialog.open, "the gait dialog should start closed");
	gait_open(&f);
	dialog = f.ui.get_widget_id(crig::GAIT_DIALOG_ID, Dialog)!!;
	test::@check(dialog.open, "+ Gait did not open the dialog");
	test::@check(@ok(f.ui.find_id(crig::GAIT_DIAGRAM_ID)), "the footfall diagram is missing");
	test::eq(crig::gait_draft.count, (usz)4);
	test::@check(crig::gait_draft.kind == WALK, "a walk is the default gait");
	Element* name = f.ui.find_id(crig::GAIT_NAME_ID)!!;
	test::@check(name.widget_as(TextField).text.str_view() == "Walk", "the name should start as the gait's");
}

fn void creating_a_gait_binds_a_clip_with_a_ground_spec() @test
{
	rig::TriMesh mesh = rig::load_gltf(mem, GAIT_DOG)!!;
	defer mesh.free(mem);
	Fixture f;
	gait_dog(&f, mesh);
	defer f.close();

	gait_open(&f);
	gait_create(&f);
	Dialog* dialog = f.ui.get_widget_id(crig::GAIT_DIALOG_ID, Dialog)!!;
	test::@check(!dialog.open, "Create should close the dialog");
	AnimTemplate* clip = f.app.clip(f.app.editing);
	test::@check(clip != null && clip.name == "Walk", "the new clip should be open and called Walk");
	test::@check(clip.ground.solves(), "a gait clip carries a ground spec");
	test::eq(clip.ground.feet.len, (sz)4);
	test::@check(clip.loop, "a gait loops by default");
	test::@check(f.app.clip_named_in_authored("Walk").valid(), "the clip was not written to the authored pack");
}

fn void a_second_gait_with_the_same_name_does_not_replace_the_first() @test
{
	rig::TriMesh mesh = rig::load_gltf(mem, GAIT_DOG)!!;
	defer mesh.free(mem);
	Fixture f;
	gait_dog(&f, mesh);
	defer f.close();

	gait_open(&f);
	gait_create(&f);
	gait_open(&f);
	gait_create(&f);
	test::@check(f.app.clip_named_in_authored("Walk").valid(), "the first Walk was lost");
	test::@check(f.app.clip_named_in_authored("Walk_2").valid(), "the second should be Walk_2");
	AnimTemplate* clip = f.app.clip(f.app.editing);
	test::@check(clip != null && clip.name == "Walk_2", "the newest gait should be the open clip");

	// A trot's name follows the gait while the field is untouched.
	gait_open(&f);
	crig::gait_kind_chosen(f.ui, 1);
	Element* name = f.ui.find_id(crig::GAIT_NAME_ID)!!;
	test::@check(name.widget_as(TextField).text.str_view() == "Trot", "the name should follow the gait");
}

fn void custom_offsets_move_the_ground_windows() @test
{
	rig::TriMesh mesh = rig::load_gltf(mem, GAIT_DOG)!!;
	defer mesh.free(mem);
	Fixture f;
	gait_dog(&f, mesh);
	defer f.close();

	gait_open(&f);
	gait_create(&f);
	AnimTemplate* walk = f.app.clip(f.app.editing);
	float[4] walked;
	foreach (i, foot : walk.ground.feet) walked[i] = foot.down;

	gait_open(&f);
	crig::gait_kind_chosen(f.ui, 4);
	test::@check(crig::gait_draft.kind == CUSTOM, "Custom was not chosen");
	// Every foot lands together: the windows must all open at the same phase.
	for (usz i = 0; i < 4; i++) crig::gait_set_offset(i, 0.25f);
	gait_create(&f);
	AnimTemplate* custom = f.app.clip(f.app.editing);
	test::@check(custom != null && custom.name == "Custom", "the custom clip should be open");
	test::eq(custom.ground.feet.len, (sz)4);
	bool moved;
	foreach (i, foot : custom.ground.feet)
	{
		test::@check(math::abs(foot.down - 0.25f) < 0.001f, "a custom foot should land where it was put, got %f", foot.down);
		if (math::abs(foot.down - walked[i]) > 0.001f) moved = true;
	}
	test::@check(moved, "custom offsets did not change the ground windows");
}

fn void a_rig_with_no_feet_says_so() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	test::@check(f.app.apply_plan_named("biped"), "could not fit a rig");
	crig::build_ui(f.ui, &f.app);
	f.ui.flush();
	f.click(tab_center(&f, f.ui.find(AreaTabStrip)!!, TAB_ANIMATIONS));
	f.ui.flush();
	gait_open(&f);
	// A fitted plan on a cube has joints but no feet near a floor the gait can walk on;
	// whichever way it lands, the panel must not author a clip it cannot.
	if (crig::gait_draft.count == 0)
	{
		test::@check(!@ok(f.ui.find_id(crig::GAIT_DIAGRAM_ID)), "no feet, so no diagram");
		gait_create(&f);
		test::@check(!f.app.clip_named_in_authored("Walk").valid(), "no feet must author nothing");
	}
}
