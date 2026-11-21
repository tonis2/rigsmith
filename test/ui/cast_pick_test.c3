<*
 A click on a character in the 3D view picks it: by its bones when it has no
 mesh, the nearer of two, and in a cutscene its actor becomes the one pieces go to.

     `c3c test --test-filter cast_pick`
*>
module crig_tests::ui;
import crig;
import cui;
import cui::widgets;
import rig;
import std::core::test;
import std::math;
import std::math::matrix;
import std::math::quaternion;

// Half way up the bare rig's lower bone, out of reach of both its joints.
const Vec3 CAST_PICK_SHIN @local = { 0, 0.45f, 0 };

<*
 A rig with no mesh, as one read from a level: feet, hips and head up the y axis,
 standing at `at`. It is the focus after.
*>
fn usz cast_pick_bare_rig(Fixture* f, Vec3 at) @local
{
	usz i = f.app.add_character({}, "");
	uint feet = f.app.doc.add_dot({ 0, 0, 0 }, "feet");
	uint hips = f.app.doc.add_dot({ 0, 0.9f, 0 }, "hips");
	uint head = f.app.doc.add_dot({ 0, 1.8f, 0 }, "head");
	(void)f.app.doc.connect(feet, hips);
	(void)f.app.doc.connect(hips, head);
	f.app.level_read = true;
	f.app.doc.model_transform = { .location = at, .rotation = quaternion::IDENTITY };
	return i;
}

// Face-on from +z, the cube and everything up to x = 4 in frame.
fn OrbitCamera cast_pick_view() @local
{
	OrbitCamera camera = crig::framed({ .min = { -1, -1, -1 }, .max = { 4, 2, 1 } });
	camera.yaw = 0;
	camera.pitch = 0;
	return camera;
}

fn void cast_pick_aim(Fixture* f) @local
{
	f.app.camera = cast_pick_view();
	f.app.camera_reset_generation++;
	f.ui.flush();
	f.feed(f.ui.input.mouse);
}

// Where model point `p` of character `i` is drawn, in window pixels.
fn Vec2 cast_pick_pixel(Fixture* f, usz i, Vec3 p) @local
{
	Element* view = f.ui.find(Viewport)!!;
	Matrix4f vp = f.app.character(i).model_view_projection(&f.app.camera, view.size.x / view.size.y);
	return view.absolute + crig::project(vp, p, view.size)!!;
}

// The cube as the actor "hero" and a bare rig beside it as "guide", in a new cutscene; the guide is the focus.
fn usz cast_pick_actors(Fixture* f) @local
{
	test::@check(f.app.make_actor(f.app.active, "hero"), "the cube is no actor");
	usz guide = cast_pick_bare_rig(f, { 2.5f, -1, 0 });
	test::@check(f.app.make_actor(guide, "guide"), "the bare rig is no actor");
	(void)f.app.add_cutscene();
	return guide;
}

fn void cast_pick_the_nearer_of_two_characters_wins() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	usz cube = f.app.active;
	// Both shins on one sight line; the far rig comes first, so the first tried does not simply win.
	Vec3 eye = cast_pick_view().eye();
	Vec3 near_at = { 2.5f, -1, 0.5f };
	Vec3 far_shin = eye + (near_at + CAST_PICK_SHIN - eye) * 1.4f;
	usz far = cast_pick_bare_rig(&f, far_shin - CAST_PICK_SHIN);
	usz near = cast_pick_bare_rig(&f, near_at);
	test::@check(f.app.focus_character(cube), "the cube did not take the focus back");
	cast_pick_aim(&f);

	f.click(cast_pick_pixel(&f, near, CAST_PICK_SHIN));
	test::@check(f.app.active == near, "the click picked %d, not the nearer %d (the far one is %d)", f.app.active, near, far);
}

fn void cast_pick_an_actor_is_hit_where_it_stands_at_its_size() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	usz bare = cast_pick_bare_rig(&f, {});
	// An arm from the head toward +z: seen end-on unturned, side-on once turned.
	uint hand = f.app.doc.add_dot({ 0, 1.8f, 1.2f }, "hand");
	(void)f.app.doc.connect(f.app.doc.dots[2].id, hand);
	Character* c = f.app.character(bare);
	c.staged = true;
	c.staged_place = { .location = { 2.5f, -1, 0 }, .rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, (float)(math::PI / 2)) };
	c.stage_scale = 1.5f;

	OrbitCamera camera = cast_pick_view();
	Vec3 arm = { 0, 1.8f, 0.6f };
	Vec2 pixel = crig::project(c.model_view_projection(&camera, VIEWPORT.x / VIEWPORT.y), arm, VIEWPORT)!!;
	Vec3 direction = camera.ray_direction(pixel, VIEWPORT)!!;
	float? hit = c.body_hit(&camera, direction, true);
	float expected = (c.placement().point(arm * c.drawn_scale()) - camera.eye()).length();
	// Short of the arm's axis by its thickness, a little more for a ray that meets it aslant.
	float thick = crig::BONE_PICK_SHARE * 1.8f * c.drawn_scale();
	test::@check(@ok(hit) && (hit ?? 0.0f) < expected && (hit ?? 0.0f) > expected - thick * 1.5f,
		"the turned arm was hit at %f, not about %f", hit ?? -1.0f, expected);
}

fn void cast_pick_a_click_on_an_actor_in_a_cutscene_targets_it() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	usz guide = cast_pick_actors(&f);
	usz hero = guide == 0 ? 1 : 0;
	crig::show_pane_view(f.ui, crig::ANIMATION_VIEW, SplitAxis.VERTICAL, 0.5f);
	test::@check(f.app.show_cutscene(0), "the cutscene would not show");
	cast_pick_aim(&f);
	test::@check(f.app.cutscene_in_dock(), "the dock shows no cutscene");
	// A turn of the hero's, picked: what is added goes to the hero.
	test::@check(f.app.add_cut_turn(0, "guide") >= 0, "no turn");
	test::eq(f.app.cut_target_actor(), 0);
	sz dots = f.app.doc.dots.len();

	// The guide, the focus, read from the level: a click on its bone targets it and places nothing.
	f.click(cast_pick_pixel(&f, guide, CAST_PICK_SHIN));
	test::@check(f.app.active == guide && f.app.cut_target_actor() == 1 && f.app.cut_selected == 0,
		"the click left the focus %d and the target %d", f.app.active, f.app.cut_target_actor());
	test::eq(f.app.doc.dots.len(), dots);
	test::@check(!f.notice_text().contains("read from the level"), "the click said %s", f.notice_text());

	// The hero's body: the focus moves to it, and the target with it.
	f.click(cast_pick_pixel(&f, hero, {}));
	test::@check(f.app.active == hero && f.app.cut_target_actor() == 0,
		"the hero's body left the focus %d and the target %d", f.app.active, f.app.cut_target_actor());

	// A drag from the body still turns the view.
	float yaw = f.app.camera.yaw;
	Vec2 from = cast_pick_pixel(&f, hero, {});
	f.drag(from, from + (Vec2){ DRAG_PIXELS, 0 });
	test::@check(f.app.camera.yaw != yaw && f.app.active == hero && f.app.cut_target_actor() == 0, "the drag did not orbit");
}

fn void cast_pick_a_scene_row_retargets_the_cutscene() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	usz guide = cast_pick_actors(&f);
	usz hero = guide == 0 ? 1 : 0;
	// The guide's lane was pressed last.
	f.app.cut_lane_actor = 2;

	Element* strip = f.ui.find(AreaTabStrip)!!;
	f.click(tab_center(&f, strip, TAB_SCENE));
	Element* tree = f.ui.find_id(crig::SCENE_OUTLINER_ID)!!.children[0];
	// Scene, then the hero's row above the focus's.
	f.click(category_center(tree, 1));
	test::@check(f.app.active == hero && f.app.cut_lane_actor == 1 && f.app.cut_target_actor() == 0,
		"the row left the focus %d and the lane %d", f.app.active, f.app.cut_lane_actor);
}
