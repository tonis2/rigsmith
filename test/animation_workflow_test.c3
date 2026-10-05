<*
 The animation editor's state boundary, without a window or pointer geometry.

     `c3c test --trust=full --test-filter crig_tests::animation_workflow`

 Mouse solving has its own UI checks. Here a direct pose write stands in for the
 middle of G/R, so these checks stay about the easily-regressed contract around
 it: sampling is transient, escape is silent, and only a kept key reaches undo.
*>
module crig_tests::animation_workflow;

import crig;
import rig;
import crig_tests::shared_app;
import std::core::test;
import std::io;
import std::math;
import std::math::quaternion;

struct Workflow
{
	crig::AppState app;
	AnimRef clip;
	uint joint;
	Quaternionf first;
	Quaternionf second;
}

fn void animation_key_clipboard_preserves_sparse_channels_and_undo() @test
{
	Workflow f;
	test::@check(f.open(), "fixture failed");
	defer f.app.free();
	AnimKeyDot source;
	foreach (dot : f.app.clip(f.clip).keyframes[0].dots)
	{
		if (dot.joint_name == "thigh_L") source = dot;
	}
	AnimKeyDot[] dots = alloc::new_array(mem, AnimKeyDot, 1);
	dots[0] = source;
	dots[0].joint_name = source.joint_name.copy(mem);
	dots[0].channels = ROTATION;
	f.clip = f.app.land_clip(f.clip, crig::clip_with_key(mem, *f.app.clip(f.clip), { .time = 0.25f, .dots = dots }));
	test::@check(f.app.copy_animation_key(f.clip, 0.25f), "copy failed");
	test::@check(!f.app.copy_animation_key(f.clip, 0.27f), "copy grabbed a nearby key");
	AnimRef target = f.app.new_clip("target", 1, from_rest: true);
	f.app.editing = target;
	test::@check(f.app.pose_from_clip(target, 0), "target pose would not open");
	test::@check(f.app.set_working_pose(f.joint, f.second, { 0, 0.25f, 0 }),
		"target pose did not change");
	f.app.pose_edit_pending = true;
	test::@check(f.app.key_pose_edit(), "target pose would not save");
	target = f.app.editing;
	AnimKeyDot before;
	foreach (dot : f.app.clip(target).keyframes[0].dots)
	{
		if (dot.joint_name == "thigh_L") before = dot;
	}
	f.app.undo_stack.clear();
	test::@check(f.app.paste_animation_key(target, 0), "paste failed");
	AnimKeyDot after;
	foreach (dot : f.app.clip(f.app.editing).keyframes[0].dots)
	{
		if (dot.joint_name == "thigh_L") after = dot;
	}
	test::@check(after.channels == BOTH && after.move == before.move && after.angle == source.angle,
		"paste overwrote an uncopied translation or lost rotation");
	test::@check(f.app.undo(), "paste was not undoable");
	foreach (dot : f.app.clip(f.app.editing).keyframes[0].dots)
	{
		if (dot.joint_name == "thigh_L")
		{
			test::@check(dot.angle == before.angle && dot.move == before.move, "undo did not restore destination");
		}
	}
	test::@check(f.app.redo(), "paste was not redoable");
	test::@check(f.app.paste_animation_key(f.app.editing, 0.75f), "clipboard did not survive undo/redo");
	AnimKeyframe pasted = f.app.clip(f.app.editing).keyframes[1];
	test::@check(pasted.time == 0.75f && pasted.dots.len == 1 && pasted.dots[0].channels == ROTATION,
		"paste expanded a sparse key into a full pose");
}

fn bool same_rotation(Quaternionf a, Quaternionf b)
{
	return 1.0f - math::abs(a.v.dot(b.v)) < 1.0e-3f;
}

fn bool same_palette(Matrix4f[] a, Matrix4f[] b)
{
	if (a.len != b.len) return false;
	foreach (usz j, matrix : a)
	{
		for (usz i = 0; i < 16; i++)
		{
			if (math::abs(matrix.m[i] - b[j].m[i]) > 1.0e-5f) return false;
		}
	}
	return true;
}

fn bool Workflow.open(&self)
{
	self.app = shared_app::open();
	// Most lifecycle checks below explicitly exercise automatic keying.
	test::@check(self.app.auto_key, "new users should have automatic pose keying enabled");
	// The shared setup carries a real coarse grid and an immutable snapshot of
	// the fixture library; mutable document and animation state are still fresh.
	if (!self.app.apply_plan_named("biped")) return false;

	foreach (dot : self.app.doc.dots.array_view())
	{
		if (dot.name == "thigh_L") { self.joint = dot.id; break; }
	}
	if (self.joint == 0) return false;

	self.first = quaternion::from_axis_angle{float}(((Vec3){ 1, 0, 0 }), 0.55f);
	self.second = quaternion::from_axis_angle{float}(((Vec3){ 1, 0, 0 }), -0.35f);
	self.clip = self.app.new_clip("workflow", 1.0f, from_rest: true);
	if (!self.clip.valid()) return false;
	self.app.editing = self.clip;
	if (!self.app.pose_from_clip(self.clip, 0.0f)) return false;
	if (!self.app.set_working_pose(self.joint, self.first, {})) return false;
	self.app.pose_edit_pending = true;
	if (!self.app.key_pose_edit()) return false;
	self.clip = self.app.editing;
	if (!self.app.pose_from_clip(self.clip, 0.5f)) return false;
	if (!self.app.set_working_pose(self.joint, self.second, {})) return false;
	self.app.pose_edit_pending = true;
	if (!self.app.key_pose_edit()) return false;
	self.clip = self.app.editing;
	if (!self.clip.valid()) return false;

	// The setup is not part of any assertion about editing history.
	self.app.stop_animation();
	self.app.undo_stack.clear();
	self.app.editing = self.clip;
	self.app.edit_time = 0.0f;
	self.app.selected = self.joint;
	return true;
}

fn void Workflow.close(&self) => self.app.free();

fn void scrubbing_is_history_free_and_does_not_open_a_draft() @test
{
	Workflow f;
	bool opened = f.open();
	defer f.close();
	if (!opened) { test::@check(false, "could not build the biped workflow fixture"); return; }
	io::printn("scrubbing changes the evaluated pose without opening a draft or history");

	sz cursor = f.app.undo_stack.cursor;
	test::@check(f.app.park_clip(f.clip, 0.0f), "the clip would not park");
	test::@check(f.app.scrub_to(0.5f), "the parked clip would not scrub");
	test::@check(f.app.undo_stack.cursor == cursor, "scrub moved the undo cursor");
	test::@check(!f.app.pose_edit_active, "scrubbing silently opened a pose edit");

	float held = f.app.anim_time;
	f.app.tick_animation(0.25f);
	test::@check(f.app.anim_time == held, "a parked clip advanced under tick");
}

fn void turn_begins_from_the_sampled_time() @test
{
	Workflow f;
	bool opened = f.open();
	defer f.close();
	if (!opened) { test::@check(false, "could not build the biped workflow fixture"); return; }
	io::printn("R on a parked clip samples the playhead without first pressing P");

	f.app.edit_time = 0.5f;
	test::@check(f.app.park_clip(f.clip, f.app.edit_time), "the clip would not park");
	sz cursor = f.app.undo_stack.cursor;
	test::@check(f.app.begin_turn(), "R did not begin on the parked animation");
	test::@check(f.app.pose_edit_active, "the sampled pose was not marked transient");
	test::@check(same_rotation(f.app.working_pose(f.joint).rotation, f.second),
		"R began from rest rather than the pose at 0.5 s");
	test::@check(f.app.undo_stack.cursor == cursor, "sampling created undo history");
	f.app.cancel_drag();
	f.app.discard_pose_edit();
}

fn void stopped_preview_still_opens_the_selected_animation_for_posing() @test
{
	Workflow f;
	bool opened = f.open();
	defer f.close();
	if (!opened) { test::@check(false, "could not build the biped workflow fixture"); return; }
	io::printn("G/R open the selected animation directly from the regular viewport");

	// `Workflow.open` deliberately leaves an editing clip selected while the
	// preview player is stopped — the state that used to make every posing entry
	// point inert after removing Pose mode.
	test::@check(!f.app.animating && f.app.editing.same(f.clip),
		"the fixture did not begin in the stopped regular view");
	f.app.edit_time = 0.5f;
	test::@check(f.app.animation_pose_ready(),
		"the selected animation was not poseable until playback was parked");
	test::@check(f.app.begin_turn(), "R would not open the selected animation");
	test::@check(f.app.pose_edit_active
		&& same_rotation(f.app.working_pose(f.joint).rotation, f.second),
		"R did not seed its draft from the selected animation's playhead");
	f.app.cancel_drag();
	f.app.discard_pose_edit();

	uint hips = 0;
	foreach (dot : f.app.doc.dots.array_view())
	{
		if (dot.name == "hips") { hips = dot.id; break; }
	}
	test::@check(hips != 0, "the fixture has no root joint for G");
	f.app.selected = hips;
	test::@check(f.app.begin_pose(), "G would not open the selected animation");
	test::@check(f.app.drag.verb == DragVerb.POSE && f.app.pose_edit_active,
		"G did not enter the shared animation draft");
	f.app.cancel_drag();
	f.app.discard_pose_edit();
}

fn void rest_dot_drag_preserves_a_manual_animation_draft() @test
{
	Workflow f;
	bool opened = f.open();
	defer f.close();
	if (!opened) { test::@check(false, "could not build the biped workflow fixture"); return; }
	io::printn("mouse placement keeps an unsaved animation draft posed while it edits the rig");

	f.app.edit_time = 0.5f;
	test::@check(f.app.pose_from_clip(f.clip, f.app.edit_time), "the manual draft would not open");
	test::@check(f.app.set_working_pose(f.joint, f.first, {}), "the manual draft would not change");
	f.app.pose_edit_pending = true;
	Quaternionf pending = f.app.working_pose(f.joint).rotation;

	Dot* dot = f.app.doc.find(f.joint);
	Vec3 before = dot.position;
	f.app.begin_drag(f.joint);
	// A rest move no longer drops the mesh out of the draft's pose: the draft stays
	// active and the posed display stays up, to be re-solved against the edited rig
	// rather than thrown away and replayed.
	test::@check(f.app.pose_edit_active && f.app.pose_palette.len > 0,
		"rest placement discarded the draft or dropped the pose it should keep");
	dot.position += { 0.01f, 0, 0 };
	f.app.end_drag();
	test::@check(f.app.pose_edit_active && f.app.pose_edit_pending,
		"rest placement closed the unsaved animation draft");
	test::@check(same_rotation(f.app.working_pose(f.joint).rotation, pending),
		"rest placement changed the pending animation rotation");
	test::@check(f.app.pose_palette.len > 0,
		"the pending animation was not redrawn against the edited rest rig");
	test::@check((f.app.doc.find(f.joint).position - before).length() > 0.005f,
		"the rest-rig edit itself did not land");
}

fn void timeline_drafts_start_from_the_limit_aware_sample() @test
{
	Workflow f;
	bool opened = f.open();
	defer f.close();
	if (!opened) { test::@check(false, "could not build the biped workflow fixture"); return; }
	io::printn("paused editing and playback evaluate the same joint limits");

	crig::JointRotationLimits limits = crig::unconstrained_rotation(f.joint);
	limits.constrained = true;
	foreach (&axis : limits.axes)
	{
		axis.allowed = false;
		axis.locked = 0.0f;
	}

	// The authored key at 0.5 s is `second`, and deliberately violates the new
	// all-axis lock. Opening a draft must copy what playback evaluates, not the
	// raw quaternion hidden behind the preview.
	f.app.edit_time = 0.5f;
	test::@check(f.app.park_clip(f.clip, f.app.edit_time), "the clip would not park");

	// The parked frame before the lock is the state undoing the lock returns to —
	// the key already carried through the joint's own plan limits. Comparing the
	// undo against the raw key only matches on a rig whose plan leaves this key
	// alone; captured here, it holds whatever the plan constrains.
	Matrix4f[] before_lock = alloc::new_array(mem, Matrix4f, f.app.pose_palette.len);
	defer alloc::free(mem, before_lock);
	foreach (usz bi, bm : f.app.pose_palette) before_lock[bi] = bm;

	test::@check(f.app.set_rotation_limits_recorded(f.joint, limits),
		"the timeline test limit was refused");
	f.app.undo_stack.commit();

	RigView view = f.app.open_rig(mem)!!;
	defer view.free(mem);
	rig::Pose raw = f.app.clip(f.clip).pose(mem, &view.skeleton,
		f.app.names_for(&view, f.clip), f.app.edit_time, false);
	defer raw.free(mem);
	sz at = view.joint_of(f.joint);
	test::@check(at >= 0 && same_rotation(raw.rotations[(usz)at], f.second),
		"limit-aware editing rewrote the source animation key");
	if (at < 0) return;

	rig::Pose evaluated = f.app.evaluated_clip_pose(mem, &view, *f.app.clip(f.clip),
		f.clip, f.app.edit_time);
	defer evaluated.free(mem);
	Matrix4f[] expected = rig::joint_palette(mem, &view.skeleton, evaluated)!!;
	defer alloc::free(mem, expected);
	test::@check(same_palette(f.app.pose_palette, expected),
		"tightening a limit did not refresh the parked playback frame");
	test::@check(f.app.undo() && same_palette(f.app.pose_palette, before_lock),
		"undoing a limit left the constrained parked frame on screen");
	test::@check(f.app.redo() && same_palette(f.app.pose_palette, expected),
		"redoing a limit did not restore the constrained parked frame");

	test::@check(f.app.pose_from_clip(f.clip, f.app.edit_time),
		"the constrained timeline sample would not open for editing");
	test::@check(same_rotation(f.app.working_pose(f.joint).rotation,
		quaternion::IDENTITY), "the draft bypassed the locked playback pose");
	f.app.discard_pose_edit();
}

fn void move_ik_uses_the_same_timeline_lifecycle() @test
{
	Workflow f;
	bool opened = f.open();
	defer f.close();
	if (!opened) { test::@check(false, "could not build the biped workflow fixture"); return; }
	io::printn("G/IK on a parked clip samples and auto-keys through the same draft");

	uint hips = 0;
	foreach (dot : f.app.doc.dots.array_view())
	{
		if (dot.name == "hips") { hips = dot.id; break; }
	}
	if (hips == 0) { test::@check(false, "the biped fixture has no hips"); return; }
	f.app.selected = hips;
	f.app.edit_time = 0.25f;
	f.app.park_clip(f.clip, f.app.edit_time);
	test::@check(f.app.begin_pose(), "G did not begin on the parked root");
	sz before = f.app.undo_stack.cursor;
	Vec3 target = f.app.drag.from + (Vec3){ 0.15f, 0.0f, 0.0f };
	(void)f.app.pose_toward(target);
	f.app.end_drag();
	test::@check(f.app.undo_stack.cursor == before + 1, "the G/IK gesture did not auto-key once");
	test::@check(!f.app.pose_edit_active, "the G/IK auto-key left its draft active");
}

fn void a_changed_timeline_gesture_auto_keys_once() @test
{
	Workflow f;
	bool opened = f.open();
	defer f.close();
	if (!opened) { test::@check(false, "could not build the biped workflow fixture"); return; }
	io::printn("one changed timeline gesture creates one keyed undo step");

	f.app.edit_time = 0.25f;
	test::@check(f.app.park_clip(f.clip, f.app.edit_time), "the clip would not park");
	test::@check(f.app.begin_turn(), "the turn would not begin");
	sz before = f.app.undo_stack.cursor;
	usz keys = f.app.clip(f.clip).keyframes.len;
	f.app.turn_joint({ 0, 0, 1 }, 0.8f);
	f.app.end_drag();

	test::@check(f.app.undo_stack.cursor == before + 1, "auto-key did not create exactly one undo step");
	test::@check(f.app.clip(f.app.editing).keyframes.len == keys + 1, "auto-key did not add one key");
	AnimKeyframe changed = f.app.clip(f.app.editing).keyframes[1];
	test::@check(changed.dots.len == 1 && changed.dots[0].channels == ROTATION,
		"a rotation gesture keyed unrelated joints or translations");
	test::@check(!f.app.pose_edit_active && !f.app.pose_edit_pending,
		"auto-key left a draft edit behind");
	test::@check(f.app.undo(), "the key was not undoable");
	test::@check(f.app.animating && f.app.anim_paused && f.app.anim_time == 0.25f,
		"undo started playback or moved the playhead");
	test::@check(f.app.clip(f.app.editing).keyframes.len == keys, "undo did not remove the auto-key");
	test::@check(f.app.redo(), "the auto-key was not redoable");
	test::@check(f.app.animating && f.app.anim_paused && f.app.anim_time == 0.25f,
		"redo started playback or moved the playhead");
	test::@check(f.app.clip(f.app.editing).keyframes.len == keys + 1, "redo did not restore the auto-key");
}

fn void a_noop_timeline_gesture_creates_no_key() @test
{
	Workflow f;
	bool opened = f.open();
	defer f.close();
	if (!opened) { test::@check(false, "could not build the biped workflow fixture"); return; }
	io::printn("a timeline gesture returned to its start creates no key");

	f.app.edit_time = 0.25f;
	f.app.park_clip(f.clip, f.app.edit_time);
	test::@check(f.app.begin_turn(), "the turn would not begin");
	sz before = f.app.undo_stack.cursor;
	usz keys = f.app.clip(f.clip).keyframes.len;
	f.app.turn_joint({ 0, 0, 1 }, 0.0f);
	f.app.end_drag();
	test::@check(f.app.undo_stack.cursor == before, "a no-op gesture created history");
	test::@check(f.app.clip(f.clip).keyframes.len == keys, "a no-op gesture created a key");
	f.app.discard_pose_edit();
}

fn void escape_restores_the_sample_and_commits_nothing() @test
{
	Workflow f;
	bool opened = f.open();
	defer f.close();
	if (!opened) { test::@check(false, "could not build the biped workflow fixture"); return; }
	io::printn("escape abandons a timeline gesture without a key or undo entry");

	f.app.edit_time = 0.5f;
	f.app.park_clip(f.clip, f.app.edit_time);
	test::@check(f.app.begin_turn(), "the turn would not begin");
	sz before = f.app.undo_stack.cursor;
	usz keys = f.app.clip(f.clip).keyframes.len;
	f.app.turn_joint({ 0, 1, 0 }, 1.0f);
	test::@check(f.app.cancel_drag(), "escape did not cancel the gesture");

	test::@check(f.app.undo_stack.cursor == before, "escape moved the undo cursor");
	test::@check(f.app.clip(f.clip).keyframes.len == keys, "escape changed the clip");
	test::@check(same_rotation(f.app.working_pose(f.joint).rotation, f.second),
		"escape did not restore the pose sampled at the playhead");
	f.app.discard_pose_edit();
}

fn void manual_key_keeps_a_draft_and_navigation_discards_it() @test
{
	Workflow f;
	bool opened = f.open();
	defer f.close();
	if (!opened) { test::@check(false, "could not build the biped workflow fixture"); return; }
	io::printn("auto-key off keeps a draft for Key, and navigation discards it");

	f.app.auto_key = false;
	f.app.edit_time = 0.25f;
	f.app.park_clip(f.clip, f.app.edit_time);
	test::@check(f.app.begin_turn(), "the turn would not begin");
	sz before = f.app.undo_stack.cursor;
	usz keys = f.app.clip(f.clip).keyframes.len;
	f.app.turn_joint({ 0, 0, 1 }, 0.7f);
	f.app.end_drag();
	test::@check(f.app.pose_edit_pending, "the changed pose was not kept as a draft");
	test::@check(f.app.undo_stack.cursor == before, "draft pose created undo history");
	test::@check(f.app.clip(f.clip).keyframes.len == keys, "draft pose changed the clip");

	test::@check(f.app.key_pose_edit(), "manual Key did not write the draft");
	AnimRef keyed = f.app.editing;
	test::@check(f.app.undo_stack.cursor == before + 1, "manual Key did not create one undo step");
	test::@check(f.app.clip(keyed).keyframes.len == keys + 1, "manual Key did not add one key");

	// Start another draft at an occupied time; leaving it must not replace that
	// key or add history, and must return to the parked animation sample.
	f.app.editing = keyed;
	f.app.edit_time = 0.5f;
	f.app.park_clip(keyed, f.app.edit_time);
	test::@check(f.app.begin_turn(), "the second turn would not begin");
	f.app.turn_joint({ 0, 1, 0 }, 0.9f);
	f.app.end_drag();
	sz settled = f.app.undo_stack.cursor;
	test::@check(f.app.prepare_timeline_navigation(), "navigation found no draft to discard");
	test::@check(f.app.undo_stack.cursor == settled, "discarding a draft changed history");
	test::@check(!f.app.pose_edit_active && !f.app.pose_edit_pending,
		"navigation left the discarded draft active");
}

fn void manual_key_on_a_parked_frame_keys_the_sample() @test
{
	Workflow f;
	bool opened = f.open();
	defer f.close();
	if (!opened) { test::@check(false, "could not build the biped workflow fixture"); return; }
	io::printn("Key on a parked frame records its sampled animation pose");

	f.app.edit_time = 0.25f;
	test::@check(f.app.pose_from_clip(f.clip, f.app.edit_time), "could not read the expected sample");
	Quaternionf expected = f.app.working_pose(f.joint).rotation;
	f.app.discard_pose_edit();

	test::@check(f.app.park_clip(f.clip, f.app.edit_time), "the clip would not park");
	AnimRef keyed = f.app.key_here(f.clip, f.app.edit_time);
	test::@check(keyed.valid(), "manual Key did not write the parked sample");

	AnimTemplate* clip = f.app.clip(keyed);
	AnimKeyframe* inserted = null;
	foreach (&key : clip.keyframes)
	{
		if (math::abs(key.time - f.app.edit_time) < 1.0e-5f) { inserted = key; break; }
	}
	test::@check(inserted != null, "manual Key did not land at the playhead");
	if (inserted)
	{
		test::@check(same_rotation(inserted.rotation_of("thigh_L"), expected),
			"manual Key did not record the parked frame");
	}
}

fn void editing_a_library_clip_forks_without_touching_the_source() @test
{
	Workflow f;
	bool opened = f.open();
	defer f.close();
	if (!opened) { test::@check(false, "could not build the biped workflow fixture"); return; }
	io::printn("the first edit of an imported clip forks it and remains playable");

	AnimRef source = crig::NO_ANIM;
	foreach (usz p, &pack : f.app.packs)
	{
		if ((int)p == f.app.authored_pack) continue;
		foreach (usz c, clip : pack.clips)
		{
			AnimRef candidate = { (int)p, (int)c };
			if (f.app.clip_applies(candidate)) { source = candidate; break; }
		}
		if (source.valid()) break;
	}
	if (!source.valid()) { test::@check(false, "no imported clip applies to the biped fixture"); return; }

	usz source_keys = f.app.clip(source).keyframes.len;
	float time = f.app.clip(source).keyframes[0].time;
	String source_name = f.app.clip(source).name.copy(mem);
	defer source_name.free(mem);
	// Occupy the imported name in the authored pack first. Forking must protect
	// that clip rather than replacing it, and bind the uniquely named result.
	AnimTemplate collision = crig::clip_retimed(mem, *f.app.clip(source), f.app.clip(source).duration);
	AnimRef occupied = f.app.put_authored_clip(collision);
	test::@check(occupied.valid(), "could not establish the authored name collision");
	test::@check(f.app.bind_ref(source), "the imported clip would not bind before editing");
	sz bound = f.app.doc.animations.len() - 1;
	f.app.editing = source;
	f.app.edit_time = time;
	f.app.selected = f.joint;
	f.app.undo_stack.clear();
	test::@check(f.app.park_clip(source, time), "the imported clip would not park");
	test::@check(f.app.begin_turn(), "the imported pose would not enter R");
	f.app.turn_joint({ 0, 0, 1 }, 0.35f);
	f.app.end_drag();

	AnimRef fork = f.app.editing;
	test::@check(fork.valid() && fork.pack == f.app.authored_pack,
		"the edit did not move to the authored pack");
	test::@check(f.app.clip(fork).name != source_name,
		"forking replaced an authored clip with the imported clip's name");
	test::@check(f.app.clip(occupied) != null && f.app.clip(occupied).name == source_name,
		"forking damaged the authored clip that already owned the name");
	test::@check(f.app.clip(source).keyframes.len == source_keys,
		"editing changed the imported source clip");
	test::@check(f.app.resolve_bound(bound).pack == fork.pack
		&& f.app.resolve_bound(bound).clip == fork.clip,
		"the binding did not follow the authored fork");
	test::@check(f.app.undo_stack.cursor > 0, "forking and keying created no undo history");
	test::@check(f.app.undo(), "the fork was not undoable");
	test::@check(!f.app.undo_stack.can_undo(), "forking and rebinding required more than one undo");
	test::@check(f.app.clip(source) != null && f.app.clip(source).keyframes.len == source_keys,
		"undo damaged the imported source");
	test::@check(f.app.resolve_bound(bound).pack == source.pack
		&& f.app.resolve_bound(bound).clip == source.clip,
		"undo did not restore the imported binding");
	test::@check(f.app.redo(), "the fork was not redoable");
	test::@check(f.app.clip(fork) != null, "redo did not restore the authored fork");
	test::@check(f.app.resolve_bound(bound).pack == fork.pack
		&& f.app.resolve_bound(bound).clip == fork.clip,
		"redo did not restore the authored binding");
	test::@check(f.app.park_clip(fork, time), "the redone fork no longer resolves its playback names");
}

fn void a_grounded_park_and_resume_use_the_same_palette() @test
{
	Workflow f;
	bool opened = f.open();
	defer f.close();
	if (!opened) { test::@check(false, "could not build the biped workflow fixture"); return; }
	io::printn("parking and resuming a grounded clip do not jump palettes");

	// Ground metadata is authored explicitly here: shipped packs are allowed to
	// contain only airborne clips, which should not weaken this player contract.
	AnimFoot[] feet = alloc::new_array(mem, AnimFoot, 1);
	feet[0] = {
		.joint = "ankle_L".copy(mem),
		.down = 0.0f,
		.up = 1.0f,
	};
	AnimRef grounded = f.clip;
	f.app.clip(grounded).ground = { .feet = feet, .floor = 0.2f, .floor_set = true };

	float time = f.app.clip(grounded).duration * 0.37f;
	test::@check(f.app.park_clip(grounded, time), "the grounded clip would not park");
	Matrix4f[] parked = (Matrix4f[])@clone_slice(f.app.pose_palette);
	defer if (parked.len > 0) alloc::free(mem, parked);
	// Prove the fixture exercises the solve, then compare newly evaluated
	// palettes. resume_clip alone only flips the clock and would prove nothing.
	RigView view = f.app.open_rig(mem)!!;
	defer view.free(mem);
	rig::Pose authored = f.app.clip(grounded).pose(mem, &view.skeleton,
		f.app.names_for(&view, grounded), time, false);
	defer authored.free(mem);
	Matrix4f[] ungrounded = rig::joint_palette(mem, &view.skeleton, authored)!!;
	defer alloc::free(mem, ungrounded);
	test::@check(!same_palette(parked, ungrounded), "the fixture's ground solve changed nothing");
	f.app.resume_clip();
	f.app.refresh_animation();
	test::@check(same_palette(parked, f.app.pose_palette),
		"resuming changed the grounded pose at the same playhead");
	f.app.park_clip(grounded, time);
	test::@check(f.app.begin_turn(), "R did not open the grounded frame");
	test::@check(same_palette(parked, f.app.pose_palette),
		"entering the pose draft changed the grounded palette");
	f.app.cancel_drag();
	test::@check(same_palette(parked, f.app.pose_palette),
		"canceling changed the grounded palette");
}

fn void library_reload_preserves_authored_editing_and_the_parked_pose() @test
{
	Workflow f;
	bool opened = f.open();
	defer f.close();
	if (!opened) { test::@check(false, "could not build the workflow fixture"); return; }
	test::@check(f.app.park_clip(f.clip, 0.375f), "the authored clip would not park");
	Matrix4f[] before = alloc::new_array(mem, Matrix4f, (sz)f.app.pose_palette.len);
	foreach (usz i, matrix : f.app.pose_palette) before[i] = matrix;
	defer alloc::free(mem, before);

	// Remove the library packs so the authored index really moves, then reload
	// the configured library. Neither operation may change the edited motion.
	f.app.load_packs("build/no-animation-library");
	test::@check(f.app.editing.same(f.app.clip_named_in_authored("workflow")),
		"reloading kept an old editing index instead of the authored identity");
	test::@check(f.app.animating && f.app.anim_paused
		&& f.app.current_ref.same(f.app.editing), "reload lost the parked authored preview");
	test::@check(f.app.edit_time == 0.375f && f.app.anim_time == 0.375f,
		"reload changed the playhead");
	test::@check(same_palette(before, f.app.pose_palette), "reload changed the sampled pose");

	f.app.scan_libraries();
	test::@check(f.app.editing.same(f.app.clip_named_in_authored("workflow"))
		&& f.app.current_ref.same(f.app.editing), "configured reload lost the clip identity");
	test::@check(f.app.anim_paused && f.app.edit_time == 0.375f
		&& same_palette(before, f.app.pose_palette), "configured reload changed the parked pose");
	test::@check(f.app.authored_dirty, "a library reload marked unsaved project keys clean");
}

fn void selected_keying_preserves_unchanged_channels_and_undoes_once() @test
{
	Workflow f;
	bool opened = f.open();
	defer f.close();
	if (!opened) { test::@check(false, "could not build workflow fixture"); return; }
	f.app.edit_time = 0.25f;
	f.app.park_clip(f.clip, f.app.edit_time);
	sz before = f.app.undo_stack.cursor;
	usz original_keys = f.app.clip(f.clip).keyframes.len;
	AnimRef keyed = f.app.key_here(f.clip, f.app.edit_time, SELECTED);
	test::@check(keyed.valid(), "unchanged selected key was refused");
	AnimKeyframe inserted = f.app.clip(keyed).keyframes[1];
	test::@check(inserted.dots.len == 1 && inserted.dots[0].channels == BOTH,
		"selected key did not record exactly the selected joint's two channels");
	test::@check(inserted.dots[0].move == (Vec3){}, "explicit zero translation was not preserved");
	test::@check(f.app.undo_stack.cursor == before + 1, "selected key did not form one undo step");
	f.app.undo();
	test::@check(f.app.clip(keyed).keyframes.len == original_keys, "undo left selected key behind");
	f.app.redo();
	test::@check(f.app.clip(keyed).keyframes[1].dots.len == 1, "redo did not preserve sparse key");
}

fn void selected_keying_keeps_other_unkeyed_pose_changes() @test
{
	Workflow f;
	bool opened = f.open();
	defer f.close();
	if (!opened) { test::@check(false, "could not build workflow fixture"); return; }
	f.app.edit_time = 0.25f;
	f.app.park_clip(f.clip, f.app.edit_time);
	f.app.pose_from_clip(f.clip, f.app.edit_time);
	uint other = 0;
	foreach (dot : f.app.doc.dots.array_view())
	{
		if (dot.name == "thigh_R") { other = dot.id; break; }
	}
	test::@check(other != 0, "fixture has no other leg");
	Quaternionf turn = quaternion::from_axis_angle{float}((Vec3){ 1, 0, 0 }, 0.4f);
	f.app.set_working_pose(other, turn, {});
	f.app.pose_edit_pending = true;
	test::@check(f.app.key_pose_edit(SELECTED), "selected key failed");
	test::@check(f.app.pose_edit_active && f.app.pose_edit_pending, "selected key discarded the other leg's unkeyed change");
	test::@check(same_rotation(f.app.working_pose(other).rotation, turn), "unselected draft changed");
	test::@check(f.app.key_pose_edit(CHANGED), "remaining change could not be keyed");
	test::@check(!f.app.pose_edit_active, "keying all remaining changes left a draft");
}
