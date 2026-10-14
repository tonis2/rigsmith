<*
 A pose keyed with Apply to on Selected keys lands on every key picked in the
 sheet, and on Whole clip on every key of the clip (app/key_spread.c3). A
 one-joint rig, so the turn made at the playhead is the turn each key takes.
*>
module crig_tests::key_spread;

import crig;
import std::core::test;
import std::math;
import std::math::quaternion;

// Keys every quarter second, each turning "hip" by its own time about Y — far
// enough apart that no unselected key is inside the edge fade.
fn AnimTemplate spread_clip()
{
	float[5] times = { 0.0f, 0.25f, 0.5f, 0.75f, 1.0f };
	AnimKeyframe[] keys = alloc::new_array(mem, AnimKeyframe, 5);
	foreach (usz i, &key : keys)
	{
		AnimKeyDot[] dots = alloc::new_array(mem, AnimKeyDot, 1);
		dots[0] = { .joint_name = "hip".copy(mem), .axis = { 0, 1, 0 }, .angle = times[i], .channels = ROTATION };
		*key = { .time = times[i], .dots = dots };
	}
	return { .name = "spread".copy(mem), .duration = 1.0f, .keyframes = keys, .owned = true };
}

struct SpreadFixture { AppState app; }

fn AnimRef SpreadFixture.open(&self)
{
	self.app = crig::new_app({});
	self.app.doc.root_id = self.app.doc.add_dot({}, "hip");
	AnimRef ref = self.app.put_authored_clip(spread_clip());
	(void)self.app.bind_ref(ref);
	self.app.undo_stack.commit();
	self.app.undo_stack.clear();
	self.app.editing = ref;
	self.app.key_reach = SELECTED_KEYS;
	return ref;
}

fn void SpreadFixture.close(&self) => self.app.free();

// Open a draft at `time` and turn the hip a further `angle` about Y from there.
fn void SpreadFixture.turn_at(&self, float time, float angle)
{
	self.app.edit_time = time;
	test::@check(self.app.pose_from_clip(self.app.editing, time), "could not open the pose draft");
	PosedJoint was = self.app.working_pose(self.app.doc.root_id);
	Quaternionf turned = was.rotation.mul(quaternion::from_axis_angle{float}((Vec3){ 0, 1, 0 }, angle)).normalize();
	test::@check(self.app.set_working_pose(self.app.doc.root_id, turned, was.offset), "could not turn the hip");
	self.app.pose_edit_pending = true;
}

fn float hip_apart(AnimKeyframe[] frames, float time, float angle)
{
	foreach (frame : frames)
	{
		if (math::abs(frame.time - time) > 1.0e-4f) continue;
		foreach (dot : frame.dots)
		{
			if (dot.joint_name != "hip" || !dot.keys_rotation()) continue;
			Quaternionf got = quaternion::from_axis_angle{float}(dot.axis.normalize(), dot.angle);
			Quaternionf want = quaternion::from_axis_angle{float}((Vec3){ 0, 1, 0 }, angle);
			return 1.0f - math::abs(got.v.dot(want.v));
		}
	}
	return 1.0f;
}

fn void a_turn_at_one_selected_key_lands_on_all_of_them() @test
{
	SpreadFixture f;
	AnimRef clip = f.open();
	defer f.close();
	test::eq(f.app.select_animation_keys_between(clip, 0.25f, 0.75f), (usz)3);
	test::eq(f.app.spread_key_count(clip, 0.5f), (usz)3);

	f.turn_at(0.5f, 0.3f);
	sz before = f.app.undo_stack.cursor;
	test::@check(f.app.key_pose_edit(CHANGED), "the turn was not keyed");
	test::eq(f.app.undo_stack.cursor, before + 1);

	AnimKeyframe[] keys = f.app.clip(f.app.editing).keyframes;
	test::eq(keys.len, (sz)5);
	foreach (time : (float[3]){ 0.25f, 0.5f, 0.75f })
	{
		test::@check(hip_apart(keys, time, time + 0.3f) < 1.0e-6f, "the selected key at %f did not take the turn", time);
	}
	test::@check(hip_apart(keys, 0.0f, 0.0f) < 1.0e-6f && hip_apart(keys, 1.0f, 1.0f) < 1.0e-6f,
		"a key outside the selection moved");
	test::@check(!f.app.pose_edit_pending, "the keyed turn was left pending");

	// The selection stays for the next turn, which lands on the same keys.
	test::eq(f.app.animation_key_selection_count(f.app.editing), (usz)3);
	f.turn_at(0.25f, 0.2f);
	test::@check(f.app.key_pose_edit(CHANGED), "the second turn was not keyed");
	keys = f.app.clip(f.app.editing).keyframes;
	foreach (time : (float[3]){ 0.25f, 0.5f, 0.75f })
	{
		test::@check(hip_apart(keys, time, time + 0.5f) < 1.0e-5f, "the second turn missed the key at %f", time);
	}

	test::@check(f.app.undo() && f.app.undo(), "undo failed");
	keys = f.app.clip(f.app.editing).keyframes;
	foreach (time : (float[3]){ 0.25f, 0.5f, 0.75f })
	{
		test::@check(hip_apart(keys, time, time) < 1.0e-6f, "undo did not restore the key at %f", time);
	}
}

// A scrubbed playhead sits beside keys more often than on one; inside the picked
// span it is still an edit to that span, and it adds no key of its own.
fn void a_turn_between_selected_keys_lands_on_all_of_them() @test
{
	SpreadFixture f;
	AnimRef clip = f.open();
	defer f.close();
	test::eq(f.app.select_animation_keys_between(clip, 0.25f, 0.75f), (usz)3);
	test::eq(f.app.spread_key_count(clip, 0.6f), (usz)3);

	f.turn_at(0.6f, 0.3f);
	sz before = f.app.undo_stack.cursor;
	test::@check(f.app.key_pose_edit(CHANGED), "the turn was not keyed");
	test::eq(f.app.undo_stack.cursor, before + 1);
	AnimKeyframe[] keys = f.app.clip(f.app.editing).keyframes;
	test::eq(keys.len, (sz)5);
	foreach (time : (float[3]){ 0.25f, 0.5f, 0.75f })
	{
		test::@check(hip_apart(keys, time, time + 0.3f) < 1.0e-6f, "the selected key at %f did not take the turn", time);
	}
	test::@check(hip_apart(keys, 0.0f, 0.0f) < 1.0e-6f && hip_apart(keys, 1.0f, 1.0f) < 1.0e-6f,
		"a key outside the selection moved");
}

fn void off_the_selection_or_with_one_key_picked_only_the_playhead_is_keyed() @test
{
	SpreadFixture f;
	AnimRef clip = f.open();
	defer f.close();

	// The playhead is past the picked span: the selection is not where the edit is.
	test::eq(f.app.select_animation_keys_between(clip, 0.25f, 0.75f), (usz)3);
	test::eq(f.app.spread_key_count(clip, 0.9f), (usz)0);
	f.turn_at(0.9f, 0.3f);
	test::@check(f.app.key_pose_edit(CHANGED), "the turn was not keyed");
	AnimKeyframe[] keys = f.app.clip(f.app.editing).keyframes;
	test::eq(keys.len, (sz)6);
	test::@check(hip_apart(keys, 0.9f, 1.2f) < 1.0e-5f, "the playhead key is not the turned pose");
	test::@check(hip_apart(keys, 0.5f, 0.5f) < 1.0e-6f, "a selected key moved with the playhead off the selection");

	// One key picked is that key alone, as before.
	f.app.clear_animation_key_selection();
	test::@check(f.app.select_animation_key(f.app.editing, 0.25f), "could not pick the key");
	test::eq(f.app.spread_key_count(f.app.editing, 0.25f), (usz)0);
	f.turn_at(0.25f, 0.3f);
	test::@check(f.app.key_pose_edit(CHANGED), "the single turn was not keyed");
	keys = f.app.clip(f.app.editing).keyframes;
	test::@check(hip_apart(keys, 0.25f, 0.55f) < 1.0e-5f && hip_apart(keys, 0.5f, 0.5f) < 1.0e-6f,
		"one picked key keyed more than the playhead");
}

fn void with_a_keyed_layer_active_its_selected_keys_take_the_turn() @test
{
	SpreadFixture f;
	AnimRef clip = f.open();
	defer f.close();
	test::@check(f.app.add_clip_layer(clip, KEYED, ADDITIVE) >= 0, "no keyed layer");
	// Each turn is made over the layer as keyed so far, which holds its last key,
	// so the layer ends up at 0.1, 0.2 and 0.3.
	foreach (time : (float[3]){ 0.25f, 0.5f, 0.75f })
	{
		f.turn_at(time, 0.1f);
		test::@check(f.app.key_pose_edit(CHANGED), "could not key the layer at %f", time);
	}

	test::eq(f.app.select_animation_keys_between(f.app.editing, 0.25f, 0.75f), (usz)3);
	f.turn_at(0.5f, 0.2f);
	test::@check(f.app.key_pose_edit(CHANGED), "the turn was not keyed into the layer");
	AnimTemplate* now = f.app.clip(f.app.editing);
	foreach (time : (float[3]){ 0.25f, 0.5f, 0.75f })
	{
		test::@check(hip_apart(now.layers[0].keyframes, time, time * 0.4f + 0.2f) < 1.0e-5f, "the layer key at %f did not take the turn", time);
		test::@check(hip_apart(now.keyframes, time, time) < 1.0e-6f, "the base key at %f moved", time);
	}
}

fn void whole_clip_turns_every_key_without_a_selection() @test
{
	SpreadFixture f;
	AnimRef clip = f.open();
	defer f.close();
	f.app.key_reach = WHOLE_CLIP;
	test::eq(f.app.spread_key_count(clip, 0.0f), (usz)5);

	f.turn_at(0.0f, 0.3f);
	sz before = f.app.undo_stack.cursor;
	test::@check(f.app.key_pose_edit(CHANGED), "the turn was not keyed");
	test::eq(f.app.undo_stack.cursor, before + 1);
	AnimKeyframe[] keys = f.app.clip(f.app.editing).keyframes;
	test::eq(keys.len, (sz)5);
	foreach (time : (float[5]){ 0.0f, 0.25f, 0.5f, 0.75f, 1.0f })
	{
		test::@check(hip_apart(keys, time, time + 0.3f) < 1.0e-5f, "the key at %f did not take the turn", time);
	}
	test::@check(!f.app.pose_edit_pending, "the keyed turn was left pending");

	test::@check(f.app.undo(), "undo failed");
	keys = f.app.clip(f.app.editing).keyframes;
	foreach (time : (float[5]){ 0.0f, 0.25f, 0.5f, 0.75f, 1.0f })
	{
		test::@check(hip_apart(keys, time, time) < 1.0e-6f, "undo did not restore the key at %f", time);
	}
}

// Between keys, the turn made there still lands on the keys, and no key is added.
fn void whole_clip_from_between_keys_adds_no_key() @test
{
	SpreadFixture f;
	f.open();
	defer f.close();
	f.app.key_reach = WHOLE_CLIP;

	f.turn_at(0.6f, 0.3f);
	test::@check(f.app.key_pose_edit(CHANGED), "the turn was not keyed");
	AnimKeyframe[] keys = f.app.clip(f.app.editing).keyframes;
	test::eq(keys.len, (sz)5);
	foreach (time : (float[5]){ 0.0f, 0.25f, 0.5f, 0.75f, 1.0f })
	{
		test::@check(hip_apart(keys, time, time + 0.3f) < 1.0e-5f, "the key at %f did not take the turn", time);
	}
}

// This frame keys the playhead alone, keys picked or not; the count of those
// picked is still there for the dock to point at Selected keys.
fn void this_frame_keys_the_playhead_whatever_is_picked() @test
{
	SpreadFixture f;
	AnimRef clip = f.open();
	defer f.close();
	f.app.key_reach = FRAME;
	test::eq(f.app.select_animation_keys_between(clip, 0.25f, 0.75f), (usz)3);
	test::eq(f.app.spread_key_count(clip, 0.5f), (usz)0);
	test::eq(f.app.picked_keys_around(clip, 0.5f), (usz)3);

	f.turn_at(0.5f, 0.3f);
	test::@check(f.app.key_pose_edit(CHANGED), "the turn was not keyed");
	AnimKeyframe[] keys = f.app.clip(f.app.editing).keyframes;
	test::eq(keys.len, (sz)5);
	test::@check(hip_apart(keys, 0.5f, 0.8f) < 1.0e-5f, "the playhead key is not the turned pose");
	test::@check(hip_apart(keys, 0.25f, 0.25f) < 1.0e-6f && hip_apart(keys, 0.75f, 0.75f) < 1.0e-6f,
		"a picked key moved on This frame");
}

fn void selected_keys_with_nothing_picked_keys_the_playhead() @test
{
	SpreadFixture f;
	AnimRef clip = f.open();
	defer f.close();
	test::eq(f.app.spread_key_count(clip, 0.5f), (usz)0);

	f.turn_at(0.5f, 0.3f);
	test::@check(f.app.key_pose_edit(CHANGED), "the turn was not keyed");
	AnimKeyframe[] keys = f.app.clip(f.app.editing).keyframes;
	test::@check(hip_apart(keys, 0.5f, 0.8f) < 1.0e-5f, "the playhead key is not the turned pose");
	test::@check(hip_apart(keys, 0.25f, 0.25f) < 1.0e-6f, "another key moved with nothing picked");
}

fn void whole_clip_on_a_keyed_layer_turns_its_keys() @test
{
	SpreadFixture f;
	AnimRef clip = f.open();
	defer f.close();
	test::@check(f.app.add_clip_layer(clip, KEYED, ADDITIVE) >= 0, "no keyed layer");
	// Keyed one at a time first, so the layer holds 0.1, 0.2 and 0.3, after the
	// rest key it starts from at 0.
	f.app.key_reach = FRAME;
	foreach (time : (float[3]){ 0.25f, 0.5f, 0.75f })
	{
		f.turn_at(time, 0.1f);
		test::@check(f.app.key_pose_edit(CHANGED), "could not key the layer at %f", time);
	}

	f.app.key_reach = WHOLE_CLIP;
	test::eq(f.app.spread_key_count(f.app.editing, 0.5f), (usz)4);
	f.turn_at(0.5f, 0.2f);
	test::@check(f.app.key_pose_edit(CHANGED), "the turn was not keyed into the layer");
	AnimTemplate* now = f.app.clip(f.app.editing);
	test::eq(now.layers[0].keyframes.len, (sz)4);
	foreach (time : (float[4]){ 0.0f, 0.25f, 0.5f, 0.75f })
	{
		test::@check(hip_apart(now.layers[0].keyframes, time, time * 0.4f + 0.2f) < 1.0e-5f, "the layer key at %f did not take the turn", time);
		test::@check(hip_apart(now.keyframes, time, time) < 1.0e-6f, "the base key at %f moved", time);
	}
}
