<*
 The three layer-editing gaps: keying the base under a layer stack, the Curves
 view following the active layer, and mirroring a clip's layers.

     `c3c test --trust=full --test-noleak --test-filter crig_tests::ui::layer_edit_gaps`
*>
module crig_tests::ui;

import crig;
import rig;
import std::core::test;
import std::math;
import std::math::vector;
import std::math::quaternion;

fn AnimRef gap_workspace(Fixture* f)
{
	test::@check(f.app.apply_plan_named("biped"), "could not fit rig");
	AnimRef clip = f.app.new_clip("Gaps", 4);
	clip = f.app.key_here(clip, 1);
	f.app.editing = f.app.key_here(clip, 2);
	f.app.show_edited();
	return f.app.editing;
}

fn float gap_between(Quaternionf a, Quaternionf b)
{
	return 2.0f * math::acos(math::min(1.0f, math::abs(a.v.dot(b.v))));
}

fn String gap_root_name(Fixture* f)
{
	RigView view = f.app.open_rig(mem)!!;
	defer view.free(mem);
	foreach (usz j, id : view.dot_ids) if (id == f.app.doc.root_id) return view.names[j].copy(mem);
	return "";
}

// The keyed dot for `joint` at `time` in the frames, or an empty dot.
fn AnimKeyDot gap_dot_at(AnimKeyframe[] frames, float time, String joint)
{
	foreach (frame : frames) foreach (dot : frame.dots)
	{
		if (math::abs(frame.time - time) < 1.0e-4f && dot.joint_name == joint && dot.keys_rotation()) return dot;
	}
	return {};
}

// ---------------------------------------------------------------------------
// 1. Keying the base with layers above it

fn void gap_base_keying_takes_an_additive_wave_back_out() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	AnimRef clip = gap_workspace(&f);
	test::@check(f.app.add_clip_layer(clip, WAVE, ADDITIVE) >= 0, "no wave layer");
	f.app.set_active_layer(f.app.editing, -1);
	AnimTemplate* wavy = f.app.clip(f.app.editing);
	String root = gap_root_name(&f);
	defer root.free(mem);
	test::@check(wavy.layers[0].joint == root, "the wave is not on the root (%s)", wavy.layers[0].joint);

	// Mid-cycle, where the wave is well away from zero.
	float time = 0.7f;
	f.app.edit_time = time;
	test::@check(f.app.pose_from_clip(f.app.editing, time), "could not open a pose draft");
	Quaternionf seen = f.app.working_pose(f.app.doc.root_id).rotation;
	Quaternionf wanted = seen.mul(quaternion::from_axis_angle{float}((Vec3){ 0, 0, 1 }, 0.3f)).normalize();
	test::@check(f.app.set_working_pose(f.app.doc.root_id, wanted, {}), "could not pose the root");
	wanted = f.app.working_pose(f.app.doc.root_id).rotation;
	f.app.pose_edit_pending = true;
	test::@check(f.app.key_pose_edit(ALL), "keying the base failed");

	AnimTemplate* keyed = f.app.clip(f.app.editing);
	test::eq(keyed.layers.len, (sz)1);
	// The base key is the wanted pose minus the wave, so it is not the wanted pose.
	AnimKeyDot stored = gap_dot_at(keyed.keyframes, time, root);
	test::@check(stored.joint_name.len > 0, "no base key for the root at %.2fs", time);
	Quaternionf base = quaternion::from_axis_angle{float}(stored.axis, stored.angle);
	test::@check(gap_between(base, wanted) > 0.05f, "the wave was baked into the base key");
	// And the stack on top brings the screen to the wanted pose.
	RigView view = f.app.open_rig(mem)!!;
	defer view.free(mem);
	rig::Pose played = f.app.evaluated_clip_pose(mem, &view, *keyed, f.app.editing, time, false);
	defer played.free(mem);
	foreach (usz j, id : view.dot_ids) if (id == f.app.doc.root_id)
	{
		test::@check(gap_between(played.rotations[j], wanted) < 2.0e-3f, "the stack plays %f rad off the wanted pose",
			gap_between(played.rotations[j], wanted));
	}
}

fn void gap_base_keying_leaves_an_overridden_joint_alone() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	AnimRef clip = gap_workspace(&f);
	test::@check(f.app.add_clip_layer(clip, KEYED, OVERRIDE) >= 0, "no override layer");
	f.app.set_active_layer(f.app.editing, -1);
	String root = gap_root_name(&f);
	defer root.free(mem);

	float time = 0.7f;
	f.app.edit_time = time;
	test::@check(f.app.pose_from_clip(f.app.editing, time), "could not open a pose draft");
	test::@check(f.app.set_working_pose(f.app.doc.root_id, quaternion::from_axis_angle{float}((Vec3){ 0, 0, 1 }, 0.4f), {}),
		"could not pose the root");
	f.app.pose_edit_pending = true;
	test::@check(f.app.key_pose_edit(ALL), "keying the base failed");

	// The override covers the root at full weight: nothing of the base shows, so
	// no root rotation key was written at 0.7 s.
	AnimTemplate* keyed = f.app.clip(f.app.editing);
	test::@check(gap_dot_at(keyed.keyframes, time, root).joint_name.len == 0, "an overridden joint was keyed into the base");
	test::@check(gap_dot_at(keyed.keyframes, 1.0f, root).joint_name.len > 0, "the existing base keys were lost");
}

// ---------------------------------------------------------------------------
// 2. The Curves view follows the active layer

fn void gap_curves_show_and_edit_the_active_keyed_layer() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	AnimRef clip = gap_workspace(&f);
	String root = gap_root_name(&f);
	defer root.free(mem);
	f.app.select(f.app.doc.root_id);
	test::@check(f.app.add_clip_layer(clip, KEYED, ADDITIVE) >= 0, "no keyed layer");

	float turn = 0.4f;
	f.app.edit_time = 1.0f;
	test::@check(f.app.pose_from_clip(f.app.editing, 1.0f), "could not open a pose draft");
	test::@check(f.app.set_working_pose(f.app.doc.root_id, quaternion::from_axis_angle{float}((Vec3){ 0, 1, 0 }, turn), {}),
		"could not pose the root");
	f.app.pose_edit_pending = true;
	test::@check(f.app.key_pose_edit(ALL), "keying into the layer failed");
	f.app.discard_pose_edit();

	AnimTemplate* now = f.app.clip(f.app.editing);
	AnimKeyDot base_before = gap_dot_at(now.keyframes, 1.0f, root);
	float deg = 180.0f / (float)math::PI;

	Graph graph = f.app.build_graph(f.app.editing, false);
	defer graph.free();
	test::@check(!graph.procedural, "a keyed layer is flagged procedural");
	GraphKey* picked = null;
	foreach (&key : graph.keys)
	{
		if (graph.curves[key.curve].axis == 1 && math::abs(key.time - 1.0f) < 1.0e-4f) picked = key;
	}
	test::@check(picked != null, "the layer's key at 1 s is not on the graph");
	if (!picked) return;
	test::@check(math::abs(picked.value - turn * deg) < 0.1f, "the curve reads %f, not the layer's %f", picked.value, turn * deg);

	// Dragging the point edits the layer's key.
	test::@check(f.app.set_graph_key_value(f.app.editing, graph.curves[picked.curve].joint, true, 1.0f, picked.shown, 1, 10.0f),
		"the drag was refused");
	AnimTemplate* edited = f.app.clip(f.app.editing);
	AnimKeyDot layer_dot = gap_dot_at(edited.layers[0].keyframes, 1.0f, root);
	Quaternionf layer_turn = quaternion::from_axis_angle{float}(layer_dot.axis, layer_dot.angle);
	test::@check(gap_between(layer_turn, quaternion::from_axis_angle{float}((Vec3){ 0, 1, 0 }, 10.0f / deg)) < 1.0e-3f,
		"the layer's key did not move to 10 degrees");
	AnimKeyDot base_after = gap_dot_at(edited.keyframes, 1.0f, root);
	test::@check(base_after.angle == base_before.angle && base_after.axis == base_before.axis, "the drag changed the base key");
	test::@check(f.app.undo(), "undo failed");
	AnimKeyDot restored = gap_dot_at(f.app.clip(f.app.editing).layers[0].keyframes, 1.0f, root);
	test::@check(math::abs(restored.angle - turn) < 1.0e-3f, "undo did not restore the layer's key");
}

fn void gap_a_procedural_layer_has_no_editable_curves() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	AnimRef clip = gap_workspace(&f);
	f.app.select(f.app.doc.root_id);
	test::@check(f.app.add_clip_layer(clip, PULSE, ADDITIVE) >= 0, "no pulse layer");

	Graph graph = f.app.build_graph(f.app.editing, false);
	defer graph.free();
	test::@check(graph.procedural, "a pulse layer is not flagged procedural");
	test::@check(graph.curves.len == 0 && graph.keys.len == 0, "a generator layer drew editable points");
	test::@check(f.app.procedural_layer_of(f.app.editing) != null, "the query does not see the pulse");
	test::@check(!f.app.set_graph_key_value(f.app.editing, "x", true, 1.0f, {}, 0, 5.0f), "a curve edit reached the base under a generator");

	// Back on the base, the graph is the base's again.
	f.app.set_active_layer(f.app.editing, -1);
	Graph base = f.app.build_graph(f.app.editing, false);
	defer base.free();
	test::@check(!base.procedural && base.curves.len > 0, "the base graph did not come back");
}

// ---------------------------------------------------------------------------
// 3. Mirroring a clip mirrors its layers

String[4] gap_names @local = { "root", "tail", "ear_L", "ear_R" };
Vec3[4] gap_joints @local = { { 0, 1, 0 }, { 0, 1, -0.3f }, { 0.2f, 1.3f, 0 }, { -0.2f, 1.3f, 0 } };
int[4] gap_parents @local = { -1, 0, 0, 0 };

fn rig::Pose gap_pose(AnimTemplate* clip, float time)
{
	rig::Skeleton skeleton = { .joints = gap_joints[..], .parents = gap_parents[..] };
	return clip.pose(mem, &skeleton, gap_names[..], time, false);
}

// A rotation reflected across the X-normal plane: (x, y, z, w) -> (x, -y, -z, w).
fn Quaternionf gap_reflected(Quaternionf q) => { .v = { q.v.x, -q.v.y, -q.v.z, q.v.w } };

fn AnimTemplate gap_layered_clip()
{
	AnimKeyDot[] dots = alloc::new_array(mem, AnimKeyDot, 1);
	dots[0] = { .joint_name = "root".copy(mem), .axis = { 0, 1, 0 }, .angle = 0.0f, .channels = ROTATION };
	AnimKeyframe[] keys = alloc::new_array(mem, AnimKeyframe, 1);
	keys[0] = { .time = 0.0f, .dots = dots };
	AnimTemplate clip = { .name = "src".copy(mem), .duration = 2.0f, .loop = true, .owned = true, .keyframes = keys };

	AnimLayer tail = crig::anim_layer_defaults("Tail".copy(mem));
	tail.kind = WAVE;
	tail.joint = "tail".copy(mem);
	tail.axis = { 0, 1, 0 };
	tail.amplitude = 0.5f;
	tail.cycles = 1.0f;

	AnimLayer ear = crig::anim_layer_defaults("Ear".copy(mem));
	ear.kind = PULSE;
	ear.joint = "ear_L".copy(mem);
	ear.mask = alloc::new_array(mem, String, 1);
	ear.mask[0] = "ear_L".copy(mem);
	ear.axis = { 0, 1, 1 };
	ear.amplitude = 0.6f;
	ear.at = 0.8f;
	ear.width = 0.3f;

	AnimKeyDot[] ear_dots = alloc::new_array(mem, AnimKeyDot, 1);
	ear_dots[0] = { .joint_name = "ear_L".copy(mem), .axis = { 0, 1, 0 }, .angle = 0.4f, .channels = ROTATION };
	AnimLayer keyed = crig::anim_layer_defaults("Keyed".copy(mem));
	keyed.keyframes = alloc::new_array(mem, AnimKeyframe, 1);
	keyed.keyframes[0] = { .time = 0.0f, .dots = ear_dots };

	clip.layers = alloc::new_array(mem, AnimLayer, 3);
	clip.layers[0] = tail;
	clip.layers[1] = ear;
	clip.layers[2] = keyed;
	return clip;
}

fn void gap_mirroring_a_clip_mirrors_its_layers() @test
{
	AnimTemplate src = gap_layered_clip();
	defer src.free(mem);
	AnimTemplate mirrored = crig::mirror_template(mem, src, "mirrored", 0.5f);
	defer mirrored.free(mem);

	test::eq(mirrored.layers.len, (sz)3);
	test::@check(mirrored.layers[0].joint == "tail" && mirrored.layers[0].axis.y == -1.0f, "the tail wave did not flip its axis");
	test::@check(mirrored.layers[1].joint == "ear_R" && mirrored.layers[1].mask.len == 1 && mirrored.layers[1].mask[0] == "ear_R",
		"the pulse and its mask did not move to ear_R (%s)", mirrored.layers[1].joint);
	test::@check(mirrored.layers[1].axis.y == -1.0f && mirrored.layers[1].axis.z == -1.0f, "the pulse axis was not reflected");
	test::@check(mirrored.layers[2].keyframes[0].dots[0].joint_name == "ear_R", "the keyed layer's ear_L key did not move to ear_R");

	// The mirrored clip plays the reflection of the source, sided joints swapped.
	foreach (float time : { 0.0f, 0.4f, 0.8f, 1.3f, 1.9f })
	{
		rig::Pose a = gap_pose(&src, time);
		defer a.free(mem);
		rig::Pose b = gap_pose(&mirrored, time);
		defer b.free(mem);
		test::@check(gap_between(b.rotations[1], gap_reflected(a.rotations[1])) < 1.0e-3f, "tail is not reflected at %.1fs", time);
		test::@check(gap_between(b.rotations[3], gap_reflected(a.rotations[2])) < 1.0e-3f, "ear_R is not ear_L reflected at %.1fs", time);
		test::@check(gap_between(b.rotations[2], gap_reflected(a.rotations[3])) < 1.0e-3f, "ear_L is not ear_R reflected at %.1fs", time);
	}
	test::@check(src.layers[1].joint == "ear_L", "mirroring changed the source");
}

// Paste mirrored with a keyed layer active writes the twin into that layer.
fn void gap_paste_mirrored_follows_the_active_layer() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	AnimRef clip = gap_workspace(&f);
	test::@check(f.app.add_clip_layer(clip, KEYED, ADDITIVE) >= 0, "no keyed layer");
	sz layer_keys = f.app.clip(f.app.editing).layers[0].keyframes.len;
	sz base_keys = f.app.clip(f.app.editing).keyframes.len;
	AnimKeyDot[] dots = alloc::new_array(mem, AnimKeyDot, 1);
	dots[0] = { .joint_name = "thigh_L".copy(mem), .axis = { 0, 0, 1 }, .angle = 0.5f, .channels = ROTATION };
	f.app.anim_pose_clipboard.free(mem);
	f.app.anim_pose_clipboard = { .time = 0.0f, .dots = dots };
	f.app.edit_time = 1.0f;
	test::@check(f.app.paste_pose(true), "the mirrored paste was refused");

	AnimTemplate* now = f.app.clip(f.app.editing);
	test::eq(now.keyframes.len, base_keys);
	test::eq(now.layers[0].keyframes.len, layer_keys + 1);
	AnimKeyDot twin = gap_dot_at(now.layers[0].keyframes, 1.0f, "thigh_R");
	test::@check(twin.joint_name.len > 0, "thigh_R was not keyed into the layer");
	test::@check(math::abs(twin.angle - 0.5f) < 1.0e-3f && twin.axis.z < -0.99f, "the twin is not the reflected turn");
	test::@check(gap_dot_at(now.keyframes, 1.0f, "thigh_R").angle < 1.0e-6f, "the base was written");
}
