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
// measure_clip as a quality gate
//
// What the zidane clips shipped with and nothing reported: a leftover leg key a
// couple of milliseconds off a whole pose, a loop whose last frame jumps back to
// its first, a knee the limits hold straight. Each is now named, with the call
// that mends it, and a clip with none of them reads usable.

// A dense-ish bend in whole poses (hips and knee keyed at every key), with one
// partial key two milliseconds after the middle one that snaps the knee straight
// and back — the leftover correction key's shape.
const String POPPING_CLIP = `{"name":"popping","duration":1.0,"keyframes":[{"time":0,"joints":[{"name":"hips","move":[0,0,0]},{"name":"knee","rotation":{"axis":[1,0,0],"angle":0.2}}]},{"time":0.5,"joints":[{"name":"hips","move":[0,0,0]},{"name":"knee","rotation":{"axis":[1,0,0],"angle":0.7}}]},{"time":0.502,"joints":[{"name":"knee","rotation":{"axis":[1,0,0],"angle":0.0}}]},{"time":0.506,"joints":[{"name":"hips","move":[0,0,0]},{"name":"knee","rotation":{"axis":[1,0,0],"angle":0.7}}]},{"time":1.0,"joints":[{"name":"hips","move":[0,0,0]},{"name":"knee","rotation":{"axis":[1,0,0],"angle":0.2}}]}]}`;

<*
 A key that juts out of the motion for a few milliseconds is a pop on its joint,
 named to the key and marked partial, and the fix offered is remove_keys with it.
*>
fn void measure_clip_finds_a_partial_key_pop() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? authored = f.call_tool("apply_clip", POPPING_CLIP);
	if (catch authored) { test::@check(false, "the popping clip authors"); return; }
	defer authored.free();
	// apply_clip answers with the verdict itself.
	Object*? metrics = authored.get("metrics");
	if (catch metrics) { test::@check(false, "apply_clip answers with metrics"); return; }
	test::@check((metrics.get_string("verdict") ?? "") == "needs_work", "a popping clip reads usable");

	Object* pop = find_issue(metrics, "pop");
	test::@check(pop != null, "the snap is reported as a pop");
	if (pop == null) return;
	test::@check((pop.get_string("joint") ?? "") == "knee", "named to the knee");
	test::@check((pop.get_int("key") ?? -1) == 2, "and to the partial key, index 2");
	test::@check(pop.get_bool("partial") ?? false, "which is marked partial");

	bool offered = false;
	Object*? fixes = metrics.get("fixes");
	if (try fixes)
	{
		for (sz i = 0; i < fixes.get_len(); i++)
		{
			Object* fix = fixes.get_at(i);
			if ((fix.get_string("tool") ?? "") != "remove_keys") continue;
			Object*? keys = fix.get("args")!!.get("keys");
			offered = @ok(keys) && keys!!.get_len() == 1 && (keys!!.get_int_at(0) ?? -1) == 2;
		}
	}
	test::@check(offered, "the fix offered is remove_keys of key 2");

	// Taking the fix leaves the clip usable.
	Object*? removed = f.call_tool("remove_keys", `{"clip":"popping","partial":true}`);
	if (catch removed) { test::@check(false, "remove_keys answers"); return; }
	defer removed.free();
	test::@check((removed.get_int("keyframes") ?? 0) == 4, "one keyframe went");
	Object* after = removed.get("metrics")!!;
	test::@check(find_issue(after, "pop") == null, "the pop is gone");
	test::@check((after.get_string("verdict") ?? "") == "usable", "and the clip reads usable");
}

<*
 A loop whose last frame jumps back to its first is a pop at the seam — between
 the even samples, where no contact sheet and no seam check looked.
*>
fn void measure_clip_finds_a_seam_snap() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? authored = f.call_tool("apply_clip",
		`{"name":"snap","duration":1.0,"loop":true,"keyframes":[{"time":0,"joints":[{"name":"knee","rotation":{"axis":[1,0,0],"angle":0.0}}]},{"time":0.5,"joints":[{"name":"knee","rotation":{"axis":[1,0,0],"angle":0.6}}]},{"time":0.992,"joints":[{"name":"knee","rotation":{"axis":[1,0,0],"angle":0.6}}]}]}`);
	if (catch authored) { test::@check(false, "the snapping clip authors"); return; }
	authored.free();

	Object*? m = f.call_tool("measure_clip", `{"clip":"snap"}`);
	if (catch m) { test::@check(false, "measure_clip answers"); return; }
	defer m.free();
	Object* pop = find_issue(m, "pop");
	test::@check(pop != null, "the jump back to the start is reported");
	if (pop == null) return;
	test::@check((pop.get_string("joint") ?? "") == "knee", "named to the knee");
	double phase = pop.get_float("phase") ?? -1.0;
	test::@check(phase > 0.98 || phase < 0.02, "at the seam, not phase %f", phase);
	test::@check((m.get_string("verdict") ?? "") == "needs_work", "a snapping loop reads usable");
}

<*
 A clean clip reads usable, and says so in apply_clip's own answer.
*>
fn void a_clean_clip_reads_usable() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? authored = f.call_tool("apply_clip",
		`{"name":"calm","duration":1.0,"keyframes":[{"time":0,"joints":[{"name":"knee","rotation":{"x":0,"y":0,"z":0,"w":1}}]},{"time":1.0,"joints":[{"name":"knee","rotation":{"axis":[1,0,0],"angle":0.3}}]}]}`);
	if (catch authored) { test::@check(false, "the calm clip authors"); return; }
	defer authored.free();
	Object*? metrics = authored.get("metrics");
	if (catch metrics) { test::@check(false, "apply_clip answers with metrics"); return; }
	test::@check((metrics.get_string("verdict") ?? "") == "usable", "a clean clip reads needs_work");
	test::@check(metrics.get("fixes")!!.get_len() == 0, "and is offered no fix");
}

<*
 get_pose shows the pose as it plays — a knee the limits lock stays straight —
 and lists the joint the limits changed, with how much.
*>
fn void get_pose_shows_what_the_limits_hold() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	uint knee = f.app.dot_named("knee").id;
	crig::JointRotationLimits lim = crig::unconstrained_rotation(knee);
	lim.constrained = true;
	for (usz i = 0; i < 3; i++)
	{
		lim.axes[i].allowed = false;
		lim.axes[i].locked = 0.0f;
	}
	test::@check(f.app.doc.set_rotation_limits(knee, lim), "the knee's limit table is set");

	Object*? authored = f.call_tool("apply_clip",
		`{"name":"strain","duration":1.0,"keyframes":[{"time":0,"joints":[{"name":"knee","rotation":{"axis":[1,0,0],"angle":1.0}}]}]}`);
	if (catch authored) { test::@check(false, "the straining clip authors"); return; }
	authored.free();

	Object*? pose = f.call_tool("get_pose", `{"clip":"strain","t":0.5}`);
	if (catch pose) { test::@check(false, "get_pose answers"); return; }
	defer pose.free();

	// The foot hangs straight below the knee, where the lock holds it.
	Object* joints = pose.get("joints")!!;
	for (sz i = 0; i < joints.get_len(); i++)
	{
		Object* row = joints.get_at(i);
		if ((row.get_string("name") ?? "") != "foot") continue;
		Object* at = row.get("position")!!;
		test::@check(math::abs((float)(at.get_float_at(2) ?? 1.0)) < 1.0e-4f, "the foot swung forward through a locked knee");
	}

	Object*? limited = pose.get("limited");
	if (catch limited) { test::@check(false, "get_pose lists the joints the limits held"); return; }
	test::@check(limited.get_len() == 1, "one joint was held, not %d", limited.get_len());
	if (limited.get_len() != 1) return;
	test::@check((limited.get_at(0).get_string("name") ?? "") == "knee", "the knee");
	test::@check(math::abs((float)(limited.get_at(0).get_float("removed") ?? 0.0) - 1.0f) < 0.01f, "by the radian keyed");
}

<*
 An ease written with apply_clip comes back from get_clip, and changes how the
 segment is paced without changing where it goes.
*>
fn void an_ease_survives_a_get_clip_round_trip() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? authored = f.call_tool("apply_clip",
		`{"name":"eased","duration":1.0,"keyframes":[{"time":0,"joints":[{"name":"knee","rotation":{"axis":[1,0,0],"angle":0.0},"rotation_ease":"in_out"}]},{"time":1.0,"joints":[{"name":"knee","rotation":{"axis":[1,0,0],"angle":1.0}}]}]}`);
	if (catch authored) { test::@check(false, "the eased clip authors"); return; }
	authored.free();

	Object*? read = f.call_tool("get_clip", `{"clip":"eased"}`);
	if (catch read) { test::@check(false, "get_clip answers"); return; }
	defer read.free();
	Object* first = read.get("keyframes")!!.get_at(0).get("joints")!!.get_at(0);
	Object*? ease = first.get("rotation_ease");
	if (catch ease) { test::@check(false, "get_clip lost the ease"); return; }
	test::@check(ease.get_len() == 2 && (ease.get_float_at(0) ?? 0) == 1.0 && (ease.get_float_at(1) ?? 0) == 1.0,
		"the ease came back as something other than [1, 1]");

	// Eased in, a quarter of the way through the segment has covered less than a
	// quarter of the turn.
	crig::AnimTemplate* clip = f.app.clip(f.app.clip_named_in_authored("eased"));
	crig::RigView view = f.app.open_rig(mem)!!;
	defer view.free(mem);
	rig::Pose pose = clip.pose(mem, &view.skeleton, view.names, 0.25f, false);
	defer pose.free(mem);
	usz knee = 0;
	foreach (usz j, name : view.names) if (name == "knee") knee = j;
	float turned = 2.0f * math::acos(math::min(math::abs(pose.rotations[knee].v.w), 1.0f));
	test::@check(turned < 0.2f, "a quarter in, an eased segment has turned %.3f of 1 radian", turned);
}

<*
 A clip whose foot leaves the floor with its stance knee bent does not drop the
 body back up the instant it lifts: the floor solve's pull fades out through the
 flight rather than stopping.
*>
fn void the_floor_solve_eases_into_a_flight() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? authored = f.call_tool("apply_clip",
		`{"name":"hop","duration":1.0,"loop":true,"keyframes":[{"time":0,"joints":[{"name":"knee","rotation":{"axis":[1,0,0],"angle":0.6}}]}],"ground":{"feet":[{"joint":"foot","down":0.0,"up":0.5}]}}`);
	if (catch authored) { test::@check(false, "the hop authors"); return; }
	authored.free();

	Object*? m = f.call_tool("measure_clip", `{"clip":"hop"}`);
	if (catch m) { test::@check(false, "measure_clip answers"); return; }
	defer m.free();
	test::@check(find_issue(m, "root_pop") == null, "the body pops as the foot lifts");

	// Either side of the lift, a hair apart, the hips stand at the same height.
	crig::AnimTemplate* clip = f.app.clip(f.app.clip_named_in_authored("hop"));
	crig::RigView view = f.app.open_rig(mem)!!;
	defer view.free(mem);
	rig::Pose before = clip.pose(mem, &view.skeleton, view.names, 0.499f);
	defer before.free(mem);
	rig::Pose after = clip.pose(mem, &view.skeleton, view.names, 0.501f);
	defer after.free(mem);
	usz hips = 0;
	foreach (usz j, name : view.names) if (name == "hips") hips = j;
	test::@check(math::abs(before.offsets[hips].y - after.offsets[hips].y) < 0.005f,
		"the hips jump %.4f across the lift", math::abs(before.offsets[hips].y - after.offsets[hips].y));
}

<*
 A foot pinned further below the hip than the leg is long brings the body down
 to it, rather than hovering short of the pin.
*>
fn void a_pin_out_of_reach_lowers_the_hips() @test
{
	Vec3[3] joints = { { 0, 1, 0 }, { 0, 0.5f, 0.02f }, { 0, 0, 0 } };
	int[3] parents = { -1, 0, 1 };
	rig::Skeleton skeleton = { .joints = joints[..], .parents = parents[..] };
	String[3] names = { "hips", "knee", "foot" };
	rig::Pose pose = rig::rest_pose(mem, 3);
	defer pose.free(mem);

	crig::AnimPin[1] pins;
	pins[0] = crig::pin_defaults(mem, "foot", { 0, -0.2f, 0 }, 0.0f, 1.0f);
	defer pins[0].free(mem);
	crig::pin_pose(mem, &skeleton, names[..], pins[..], 0.5f, 1.0f, false, &pose, 1.0f);

	Matrix4f[] palette = rig::joint_palette(mem, &skeleton, pose)!!;
	defer alloc::free(mem, palette);
	Vec3 foot = joints[2].transform(palette[2]);
	test::@check(pose.offsets[0].y < -0.15f, "the hips stayed up (%.3f)", pose.offsets[0].y);
	test::@check((foot - (Vec3){ 0, -0.2f, 0 }).length() < 0.02f, "the foot is %.3f from its pin", (foot - (Vec3){ 0, -0.2f, 0 }).length());
}

const String KNEE_CLIP = `{"name":"striding","duration":1.0,"loop":true,"keyframes":[{"time":0,"joints":[{"name":"hips","move":[0,0.01,0]},{"name":"knee","rotation":{"axis":[1,0,0],"angle":0.2}},{"name":"foot","rotation":{"axis":[1,0,0],"angle":-0.1}}]},{"time":0.5,"joints":[{"name":"hips","move":[0,0,0]},{"name":"knee","rotation":{"axis":[1,0,0],"angle":0.7}},{"name":"foot","rotation":{"axis":[1,0,0],"angle":0.1}}]}]}`;

fn bool keys_joint_named(crig::AppState* app, String clip, String joint)
{
	AnimTemplate* found = app.clip(app.clip_named_in_authored(clip));
	if (!found) return false;
	foreach (&frame : found.keyframes) foreach (dot : frame.dots) if (dot.joint_name == joint) return true;
	return false;
}

<*
 remove_keys with joints takes every key of those joints and the joints below
 them, leaving the rest of the clip, as one undo step.

 Re-introduce: remove only the named joint, and the foot keeps its keys.
*>
fn void remove_keys_by_joint_takes_the_joints_below() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;
	Object*? authored = f.call_tool("apply_clip", KNEE_CLIP);
	if (catch authored) { test::@check(false, "the clip authors"); return; }
	defer authored.free();

	Object*? removed = f.call_tool("remove_keys", `{"clip":"striding","joints":["knee"]}`);
	if (catch removed) { test::@check(false, "remove_keys answers"); return; }
	defer removed.free();
	test::@check((removed.get_string("done") ?? "") == "joint keys removed", "remove_keys did not take the joints");
	test::@check(!keys_joint_named(&f.app, "striding", "knee") && !keys_joint_named(&f.app, "striding", "foot"),
		"the knee or the foot below it still has keys");
	test::@check(keys_joint_named(&f.app, "striding", "hips"), "the hips lost their keys");
	test::@check(f.app.undo() && keys_joint_named(&f.app, "striding", "foot"), "one undo did not bring the keys back");

	// A joint the rig does not have is refused, and the clip is left as it is.
	Object*? stranger = f.call_tool("remove_keys", `{"clip":"striding","joints":["elbow"]}`);
	if (try stranger) stranger.free();
	test::@check(keys_joint_named(&f.app, "striding", "knee"), "a refused call changed the clip");
}

<*
 set_layer over the wire: extract lifts the knee and foot into a layer of their
 own, share links it into a second clip with a fit of its own, an edit in the
 first reaches the second, and unlink parts them.

 Re-introduce: share without a link, and the rename does not reach the second clip.
*>
fn void set_layer_extracts_shares_and_unlinks() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;
	Object*? first = f.call_tool("apply_clip", KNEE_CLIP);
	if (catch first) { test::@check(false, "the clip authors"); return; }
	defer first.free();
	Object*? second = f.call_tool("apply_clip",
		`{"name":"other","duration":2.0,"keyframes":[{"time":0,"joints":[{"name":"hips","move":[0,0,0]}]}]}`);
	if (catch second) { test::@check(false, "the second clip authors"); return; }
	defer second.free();

	Object*? lifted = f.call_tool("set_layer", `{"clip":"striding","op":"extract","joints":["knee"]}`);
	if (catch lifted) { test::@check(false, "extract answers"); return; }
	defer lifted.free();
	AnimTemplate* striding = f.app.clip(f.app.clip_named_in_authored("striding"));
	test::@check(striding.layers.len == 1 && striding.layers[0].mode == OVERRIDE && striding.layers[0].name == "knee motion",
		"the knee did not become a layer");
	test::@check(!keys_joint_named(&f.app, "striding", "foot"), "the foot below the knee stayed in the base");

	Object*? shared = f.call_tool("set_layer", `{"clip":"striding","op":"share","index":0,"clips":["other"],"fit":"keep"}`);
	if (catch shared) { test::@check(false, "share answers"); return; }
	defer shared.free();
	test::@check((shared.get_int("holders") ?? 0) == 2, "the layer is not held by both clips");
	AnimTemplate* other = f.app.clip(f.app.clip_named_in_authored("other"));
	test::@check(other.layers.len == 1 && other.layers[0].fit == KEEP && other.layers[0].length == 1.0f,
		"the second clip's copy lacks its fit or the layer's length");

	Object*? renamed = f.call_tool("set_layer", `{"clip":"striding","op":"replace","index":0,"layer":{"name":"leg"}}`);
	if (catch renamed) { test::@check(false, "replace answers"); return; }
	defer renamed.free();
	other = f.app.clip(f.app.clip_named_in_authored("other"));
	test::@check(other.layers[0].name == "leg" && other.layers[0].fit == KEEP, "the rename did not reach the shared copy");

	Object*? parted = f.call_tool("set_layer", `{"clip":"other","op":"unlink","name":"leg"}`);
	if (catch parted) { test::@check(false, "unlink answers"); return; }
	defer parted.free();
	other = f.app.clip(f.app.clip_named_in_authored("other"));
	test::@check(other.layers[0].link.len == 0, "unlink left the copy shared");
}

<*
 get_weights with vertices reads each one's row as the views show it — the dots
 holding it, strongest first, with their own weights and whether those are
 edited — and with strays
 says what is cut off from its dot, an empty list on a cube with none. A vertex
 the mesh does not have is refused with a sentence.
*>
fn void get_weights_reads_vertex_rows() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	// The knee on vertex 0, and every other dot taken off it, so the row is the
	// knee's alone.
	f.call_tool("pin_weights", `{"dot":"knee","vertices":[0]}`)!!.free();
	uint[1] zero = { 0 };
	foreach (dot : f.app.doc.dots.array_view()) if (dot.name != "knee") f.app.set_weight_vertices(zero[..], dot.id, 0.0f);
	Object*? weights = f.call_tool("get_weights", `{"vertices":[0],"strays":true}`);
	if (catch weights)
	{
		test::@check(false, "get_weights takes vertices and strays");
		return;
	}
	defer weights.free();

	Object* rows = weights.get("rows")!!;
	test::@check(rows.get_len() == 1, "%d rows for one vertex", rows.get_len());
	Object* row = rows.get_at(0);
	test::@check((row.get_int("vertex") ?? -1) == 0, "the row is not vertex 0's");
	Object* joints = row.get("joints")!!;
	test::@check(joints.get_len() == 1 && joints.get_at(0).get_string("name")!! == "knee",
		"the pinned vertex is not read as the knee's alone");
	test::@check(math::abs(joints.get_at(0).get_float("share")!! - 1.0) < 1.0e-3, "the knee's share is not the whole vertex");
	test::@check(joints.get_at(0).get_float("weight")!! == 1.0 && (joints.get_at(0).get_bool("edited") ?? false),
		"the row does not say the knee's own weight is full and edited");
	test::@check(weights.get("strays")!!.get_len() == 0, "the cube has strays");

	test::@check(f.refuses_tool("get_weights", `{"vertices":[99]}`, "not a vertex of this mesh"),
		"a vertex past the end is named back");
}

<*
 fix_strays answers what it found and changed, and the strays left, in
 get_weights' words — on the cube, none of either.

 Re-introduce: leave `fix_strays` out of `install_tools`.
*>
fn void fix_strays_answers_what_it_did() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? fixed = f.call_tool("fix_strays", `{}`);
	if (catch fixed)
	{
		test::@check(false, "fix_strays answers");
		return;
	}
	defer fixed.free();
	test::@check((fixed.get_int("found") ?? -1) == 0, "the cube has strays");
	test::@check((fixed.get_int("fixed") ?? -1) == 0, "fix_strays changed vertices on a clean cube");
	test::@check(fixed.get("strays")!!.get_len() == 0, "fix_strays lists strays left on a clean cube");
}

<*
 get_weights lists tears and fix_tears answers what it found and changed, and
 the tears left — on the welded cube, none of either.

 Re-introduce: leave `fix_tears` out of `install_tools`.
*>
fn void fix_tears_answers_what_it_did() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? found = f.call_tool("get_weights", `{"tears":true}`);
	if (catch found)
	{
		test::@check(false, "get_weights takes tears");
		return;
	}
	defer found.free();
	test::@check((found.get_int("tear_count") ?? -1) == 0 && found.get("tears")!!.get_len() == 0, "the cube has tears");

	Object*? fixed = f.call_tool("fix_tears", `{}`);
	if (catch fixed)
	{
		test::@check(false, "fix_tears answers");
		return;
	}
	defer fixed.free();
	test::@check((fixed.get_int("found") ?? -1) == 0, "the cube has tears");
	test::@check((fixed.get_int("fixed") ?? -1) == 0, "fix_tears changed vertices on a clean cube");
	test::@check((fixed.get_int("tear_count") ?? -1) == 0, "fix_tears lists tears left on a clean cube");
}
