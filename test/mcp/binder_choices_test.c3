module crig_tests::mcp;
import crig;
import image;
import image::png;
import mcp;
import three;
import rig;
import crig_tests::library;
import crig_tests::shared_app;
import std::core::test;
import std::collections::object;
import std::encoding::base64;
import std::encoding::json;
import std::io;
import std::io::file;
import std::io::path;
import std::math;
import std::math::quaternion;

// ---------------------------------------------------------------------------
// The binder's own rigid choices, over the wire

<*
 The cube with a second solid beside it, and a dot inside that one.

 What the fixture has to produce is a piece the *binder* freezes rather than one
 the user pinned: `rig::rigid_shells` calls a reached piece one bone's outright
 when nearly all of it is nearest that bone, and a separate cube with a dot in
 the middle of it is exactly that. The main cube keeps its blend, because its
 corners are split between the three joints of the chain.
*>
Vec3[16] two_solid_positions = {
	{ -1, -1, -1 }, { 1, -1, -1 }, { 1, 1, -1 }, { -1, 1, -1 },
	{ -1, -1, 1 },  { 1, -1, 1 },  { 1, 1, 1 },  { -1, 1, 1 },

	{ 1.5, -0.5, -0.5 }, { 2.5, -0.5, -0.5 }, { 2.5, 0.5, -0.5 }, { 1.5, 0.5, -0.5 },
	{ 1.5, -0.5, 0.5 },  { 2.5, -0.5, 0.5 },  { 2.5, 0.5, 0.5 },  { 1.5, 0.5, 0.5 },
};

uint[72] two_solid_indices = {
	4, 5, 6, 4, 6, 7,      0, 3, 2, 0, 2, 1,
	1, 2, 6, 1, 6, 5,      0, 4, 7, 0, 7, 3,
	3, 7, 6, 3, 6, 2,      0, 1, 5, 0, 5, 4,

	12, 13, 14, 12, 14, 15,   8, 11, 10, 8, 10, 9,
	9, 10, 14, 9, 14, 13,     8, 12, 15, 8, 15, 11,
	11, 15, 14, 11, 14, 10,   8, 9, 13, 8, 13, 12,
};

fn void Fixture.open_two_solids(&self)
{
	self.app = crig::new_app(
		{ .positions = two_solid_positions[..], .indices = two_solid_indices[..] });

	uint hips = self.app.doc.add_dot({ 0, 1, 0 }, "hips");
	uint knee = self.app.doc.add_dot({ 0, 0.5, 0 }, "knee");
	uint foot = self.app.doc.add_dot({ 0, 0, 0 }, "foot");
	self.app.doc.connect(hips, knee);
	self.app.doc.connect(knee, foot);
	self.app.doc.add_dot({ 2.0, 0, 0 }, "prop");

	self.tools = crig::new_tool_table(&self.app);
	self.server = crig::serve_table(&self.tools, &self.app);
}

<*
 `get_shells` says which bone the binder froze a piece onto by itself.

 The field an agent needs to not pin a piece twice: a part that is already rigid
 looks exactly like a part that is not, and the only difference is a decision
 made inside a bind and until now thrown away. Never reported stale, because the
 answer is a joint index and joint indices are renumbered by every edit — a
 stale one names a real bone confidently and wrongly. So a rig that has moved
 since the last bind costs the tool a fresh one: the pane that used to keep the
 riders fresh behind a debounce is gone, and a tool call is the one reader left.
*>
fn void get_shells_names_the_binders_own_choice() @test
{
	Fixture fixture;
	fixture.open_two_solids();
	defer fixture.close();
	Fixture* f = &fixture;

	if (f.app.shells.count != 2)
	{
		test::@check(false, "SKIPPED — the fixture is %d pieces, not two", f.app.shells.count);
		return;
	}

	// The bind is what fills the riders, and nothing has asked for one yet.
	crig::RigView? opened = f.app.open_rig(mem);
	if (catch opened)
	{
		test::@check(false, "the fixture rig produced no skeleton");
		return;
	}
	crig::RigView view = opened;
	f.app.base_bind_for(&view);
	view.free(mem);

	Object*? listed = f.call_tool("get_shells", "{}");
	if (catch listed)
	{
		test::@check(false, "get_shells answers");
		return;
	}
	defer listed.free();

	Object*? shells = listed.get("shells");
	if (catch shells)
	{
		test::@check(false, "get_shells wrote no shells array");
		return;
	}

	usz decided = 0;
	for (sz i = 0; i < shells.get_len(); i++)
	{
		Object* row = shells.get_at(i);
		String named = row.get_string("auto") ?? "";
		if (named.len == 0) continue;
		decided++;
		test::@check(named == "prop",
			"a piece was reported as riding \"%s\" rather than the dot sitting inside it", named);
	}
	test::@check(decided == 1, "%d pieces carry an auto, where the fixture has one", decided);

	// And the moment the rig moves the old indices name whatever the next
	// breadth-first walk puts in their place — so the tool binds again rather
	// than reporting them, and the answer is the same dot, found afresh.
	f.app.mark_rig_stale();
	test::@check(f.app.riders_stale, "mark_rig_stale did not raise riders_stale");

	Object*? again = f.call_tool("get_shells", "{}");
	if (catch again)
	{
		test::@check(false, "get_shells answers after a rig edit");
		return;
	}
	defer again.free();
	test::@check(!f.app.riders_stale, "get_shells answered a moved rig without refreshing the riders");

	Object*? fresh = again.get("shells");
	if (catch fresh) return;

	usz refound = 0;
	for (sz i = 0; i < fresh.get_len(); i++)
	{
		String named = fresh.get_at(i).get_string("auto") ?? "";
		if (named.len == 0) continue;
		refound++;
		test::@check(named == "prop",
			"after the rig moved a piece was reported as riding \"%s\"", named);
	}
	test::@check(refound == 1, "%d pieces carry an auto after the rig moved, where the fixture has one", refound);
}

<*
 The pose library over MCP: two poses saved off a clip, then a clip written
 between them that starts and ends on those poses. Deleting one is undoable in
 the panel's own history.
*>
fn void poses_are_saved_and_tweened_over_mcp() @test
{
	Fixture fixture;
	fixture.open_authored();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? first = f.call_tool("save_pose", `{"name":"Start","clip":"Authored/as_axis","t":0}`);
	Object*? second = f.call_tool("save_pose", `{"name":"End","clip":"Authored/as_axis","t":0.5}`);
	if (catch first) { test::@check(false, "save_pose answers"); return; }
	if (catch second) { test::@check(false, "second save_pose answers"); return; }
	first.free();
	defer second.free();
	test::@check(f.app.doc.poses.len == 2, "both poses are in the project's library");
	test::@check((second.get("poses").get_len() ?? 0) == 2, "the answer lists them");

	Object*? scene = f.call_tool("get_scene", "{}");
	if (catch scene) { test::@check(false, "get_scene answers"); return; }
	defer scene.free();
	test::@check((scene.get("saved_poses").get_len() ?? 0) == 2, "get_scene names the saved poses");
	test::@check((scene.get("saved_poses").get_string_at(1) ?? "") == "End", "in the library's order");

	Object*? made = f.call_tool("tween_poses", `{"from":"Start","to":"End","name":"Between","duration":0.8}`);
	if (catch made) { test::@check(false, "tween_poses answers"); return; }
	defer made.free();
	Object*? clip = f.call_tool("get_clip", `{"clip":"Authored/Between"}`);
	if (catch clip) { test::@check(false, "the tweened clip can be read back"); return; }
	defer clip.free();
	test::@check((clip.get("keyframes").get_len() ?? 0) == 2, "two poses make two keys");
	test::@check(math::abs(clip.get("keyframes").get_at(1).get_float("time") ?? 0.0 - 0.8) < 1e-4, "the last pose lands at the duration");

	Object*? gone = f.call_tool("delete_pose", `{"pose":"Start"}`);
	if (catch gone) { test::@check(false, "delete_pose answers"); return; }
	gone.free();
	test::@check(f.app.doc.poses.len == 1, "the pose is gone");
	test::@check(f.app.saved_pose_named("Start") < 0, "by name");
}

<*
 A stroke drawn in Sketch becomes a mark the agent can read: normalised points,
 its ink, the camera; and it can be cleared.
*>
fn void a_sketch_is_read_back_as_data() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	f.app.begin_sketch();
	f.app.sketch_ink = crig::SketchInk.RED;
	// Inside a scope that closes, as an MCP or UI callback runs.
	@pool()
	{
		f.app.sketch_moved({ 100, 50 });
	};
	@pool()
	{
		f.app.sketch_moved({ 300, 250 });
	};
	Matrix4f vp = f.app.model_view_projection(&f.app.camera, 2.0f);
	uint id = f.app.sketch_commit(vp, { 400, 300 }, &f.app.camera);
	test::@check(id == 1, "the stroke is mark 1");

	Object*? got = f.call_tool("get_annotations", `{}`);
	if (catch got) { test::@check(false, "get_annotations answers"); return; }
	defer got.free();
	test::@check((got.get("annotations").get_len() ?? 0) == 1, "one mark");
	Object* mark = got.get("annotations").get_at(0)!!;
	test::@check((mark.get_string("meaning") ?? "") == "wrong", "red means wrong");
	test::@check((mark.get("points").get_len() ?? 0) == 2, "both points kept");
	Object* second = mark.get("points").get_at(1)!!;
	test::@check(math::abs(second.get_at(0).f - 0.75) < 1e-3, "in fractions of the viewport");

	Object*? cleared = f.call_tool("get_annotations", `{"clear":true}`);
	if (catch cleared) { test::@check(false, "clear answers"); return; }
	cleared.free();
	test::@check(f.app.annotations.len() == 0, "and they can be cleared");
}
