<*
 Gaits as paths in the UI: "⋯ › New walk cycle" in the Animations pane and the
 Path strip's gait row, through the real tree.

 `c3c test --trust=full --test-filter crig_tests::ui::gait_strip`

 The dog is the model: four legs, each ending in a foot and a toe, which is the
 rig `author_gait` finds feet on. A walk cycle lays one path per foot, and the
 gait is written again — one undo step — from the strip, from a foot path's
 stance end dragged in the viewport, or from a foot's landing slice moved on the
 sheet.
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

// The 3D view in the pane, where the Path strip is.
fn void gait_show_view(Fixture* f)
{
	f.click(tab_center(f, f.ui.find(AreaTabStrip)!!, TAB_3D));
	f.feed({ 0, 0 });
	f.ui.flush();
}

fn void gait_new_walk(Fixture* f)
{
	f.pick_menu_item(crig::ANIM_MORE_ID, crig::ANIM_NEW_WALK_ID);
	f.feed({ 0, 0 });
	f.ui.flush();
}

fn void gait_strip_a_walk_cycle_lays_a_path_per_foot() @test
{
	rig::TriMesh mesh = rig::load_gltf(mem, GAIT_DOG)!!;
	defer mesh.free(mem);
	Fixture f;
	gait_dog(&f, mesh);
	defer f.close();

	gait_new_walk(&f);
	AnimTemplate* clip = f.app.clip(f.app.editing);
	test::@check(clip != null && clip.name == "Walk", "the new clip should be open and called Walk");
	test::@check(clip.ground.solves() && clip.ground.feet.len == 4, "a walk cycle carries the feet's ground windows");
	test::@check(clip.loop && clip.gait.set && clip.gait.kind == WALK, "a walk cycle loops and keeps its gait");
	test::eq(clip.paths.len, (sz)4);
	foreach (&path : clip.paths)
	{
		usz down;
		usz up;
		foreach (slice : path.slices)
		{
			if (slice.tag == DOWN) down++;
			if (slice.tag == UP) up++;
		}
		test::@check(path.generated && path.closed && down == 1 && up == 1, "%s's path is not a closed step with one landing and one lift", path.joint);
	}
	test::@check(f.app.path_tool, "the Path tool did not come on: %s", f.app.notice());
	gait_show_view(&f);
	test::@check(f.in_tree(crig::PATH_DRAW_ID) && f.in_tree(crig::PATH_GAIT_KIND_ID), "the Path strip did not come up with the gait row");
	f.click(tab_center(&f, f.ui.find(AreaTabStrip)!!, TAB_ANIMATIONS));
	f.ui.flush();

	// A second is a second clip, under the next free name.
	gait_new_walk(&f);
	test::@check(f.app.clip_named_in_authored("Walk").valid(), "the first Walk was lost");
	test::@check(f.app.clip(f.app.editing).name == "Walk_2", "the second should be Walk_2");
}

fn void gait_strip_another_gait_writes_the_clip_again_in_one_step() @test
{
	rig::TriMesh mesh = rig::load_gltf(mem, GAIT_DOG)!!;
	defer mesh.free(mem);
	Fixture f;
	gait_dog(&f, mesh);
	defer f.close();
	gait_new_walk(&f);
	float[4] walked;
	foreach (i, foot : f.app.clip(f.app.editing).ground.feet) walked[i] = foot.down;
	sz history = f.app.undo_stack.cursor;

	gait_show_view(&f);
	click_segment(&f, crig::PATH_GAIT_KIND_ID, 1);
	AnimTemplate* trot = f.app.clip(f.app.editing);
	test::@check(trot.name == "Walk" && trot.gait.kind == TROT, "the strip did not write the clip again as a trot");
	bool moved;
	foreach (i, foot : trot.ground.feet) if (math::abs(foot.down - walked[i]) > 0.001f) moved = true;
	test::@check(moved, "the trot lands its feet where the walk did");
	test::eq(f.app.undo_stack.cursor, history + 1);
	test::@check(f.app.undo() && f.app.clip(f.app.editing).gait.kind == WALK, "one undo did not bring the walk back");
}

fn void gait_strip_a_landing_moved_on_the_sheet_moves_that_foot() @test
{
	rig::TriMesh mesh = rig::load_gltf(mem, GAIT_DOG)!!;
	defer mesh.free(mem);
	Fixture f;
	gait_dog(&f, mesh);
	defer f.close();
	gait_new_walk(&f);
	AnimTemplate* clip = f.app.clip(f.app.editing);
	usz down_slice;
	foreach (usz s, slice : clip.paths[0].slices) if (slice.tag == DOWN) down_slice = s;
	String joint = clip.paths[0].joint.copy(mem);
	defer joint.free(mem);

	test::@check(f.app.retime_path_slice(0, down_slice, 0.3f), "the landing would not move");
	clip = f.app.clip(f.app.editing);
	bool landed;
	foreach (foot : clip.ground.feet) if (foot.joint == joint && math::abs(foot.down - 0.3f) < 0.001f) landed = true;
	test::@check(landed, "the foot's ground window did not follow its landing");
	bool still_generated;
	foreach (&path : clip.paths) if (path.joint == joint) still_generated = path.generated;
	test::@check(still_generated, "moving a gait foot's landing made its path the person's");
}

fn void gait_strip_a_stride_dragged_wider_writes_every_foot_again() @test
{
	rig::TriMesh mesh = rig::load_gltf(mem, GAIT_DOG)!!;
	defer mesh.free(mem);
	Fixture f;
	gait_dog(&f, mesh);
	defer f.close();
	gait_new_walk(&f);
	float stride = f.app.clip(f.app.editing).gait.stride;
	// The stance's front end of the first foot's path, dragged further forward.
	f.app.path_selected = 0;
	test::@check(f.app.begin_path_drag(0, 0, false), "the stance end would not take a drag");
	Vec3 front = f.app.path_drag_at();
	f.app.path_point_toward(front + (Vec3){ 0, 0, stride * f.app.path_height * 0.5f });
	f.app.end_drag();
	AnimTemplate* clip = f.app.clip(f.app.editing);
	test::@check(clip.gait.stride > stride * 1.2f, "the stride did not grow: %s, was %s", clip.gait.stride, stride);
	foreach (&path : clip.paths) test::@check(path.generated, "a foot's path stopped being the gait's");
}

fn void gait_strip_a_rig_with_no_feet_says_so() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	test::@check(f.app.apply_plan_named("biped"), "could not fit a rig");
	crig::build_ui(f.ui, &f.app);
	f.ui.flush();
	f.click(tab_center(&f, f.ui.find(AreaTabStrip)!!, TAB_ANIMATIONS));
	f.ui.flush();
	sz clips = f.app.doc.animations.len();
	gait_new_walk(&f);
	// A fitted plan on a cube may have no feet near a floor; whichever way it
	// lands, a walk is written only on feet.
	if (f.app.doc.animations.len() == clips)
	{
		test::@check(f.app.notice().len > 0, "no feet, and nothing said");
	}
	else
	{
		test::@check(f.app.clip(f.app.editing).paths.len > 0, "a walk with feet laid no paths");
	}
}
