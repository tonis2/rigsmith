<*
 Fast, geometry-free checks for grouped saved-key editing.

 The fixture has one named joint only so clipboard name mapping still exercises
 the real path without loading the humanoid asset or building a fitted rig.
*>
module crig_tests::animation_multikey;

import crig;
import std::core::test;
import std::io::file;
import std::math;

const float EPSILON = 1.0e-5f;

fn AnimKeyDot multikey_dot(float value, AnimChannels channels)
{
	return {
		.joint_name = "hip".copy(mem),
		.axis = { 0, 1, 0 },
		.angle = value,
		.move = { value, 0, 0 },
		.channels = channels,
	};
}

fn AnimTemplate multikey_clip(String name, float duration, float[] times, AnimChannels[] channels)
{
	AnimKeyframe[] keys = alloc::new_array(mem, AnimKeyframe, (sz)times.len);
	foreach (usz i, &key : keys)
	{
		AnimKeyDot[] dots = alloc::new_array(mem, AnimKeyDot, 1);
		dots[0] = multikey_dot(times[i], channels[i]);
		*key = { .time = times[i], .dots = dots };
	}
	return {
		.name = name.copy(mem),
		.duration = duration,
		.keyframes = keys,
		.owned = true,
	};
}

fn sz frame_at(AnimTemplate* clip, float time)
{
	foreach (usz i, key : clip.keyframes)
	{
		if (math::abs(key.time - time) < EPSILON) return (sz)i;
	}
	return -1;
}

struct MultiKeyFixture
{
	AppState app;
}

fn void MultiKeyFixture.open(&self)
{
	self.app = crig::new_app({});
	self.app.doc.root_id = self.app.doc.add_dot({}, "hip");
}

fn AnimRef MultiKeyFixture.add(&self, String name, float duration, float[] times,
	AnimChannels[] channels)
{
	AnimRef ref = self.app.put_authored_clip(multikey_clip(name, duration, times, channels));
	// `put_authored_clip` deliberately does not add this clip to the document's
	// export set. Bind fixture clips up front so the operation under test records
	// only its clip swap, rather than also repairing synthetic setup state.
	(void)self.app.bind_ref(ref);
	self.app.undo_stack.commit();
	self.app.undo_stack.clear();
	self.app.editing = ref;
	return ref;
}

fn void MultiKeyFixture.close(&self) => self.app.free();

fn void grouped_move_preserves_spacing_and_rejects_the_whole_invalid_edit() @test
{
	MultiKeyFixture f;
	f.open();
	defer f.close();
	AnimRef clip = f.add("move", 1.0f, ((float[3]){ 0.2f, 0.6f, 0.8f })[..],
		((AnimChannels[3]){ ROTATION, TRANSLATION, BOTH })[..]);

	f.app.select_animation_key(clip, 0.2f);
	f.app.select_animation_key(clip, 0.6f, additive: true);
	test::@check(f.app.animation_key_selection_count(clip) == 2,
		"additive selection did not keep both columns");
	sz history = f.app.undo_stack.cursor;
	test::@check(f.app.move_selected_animation_keys(clip, 0.1f), "valid grouped move was refused");
	test::@check(frame_at(f.app.clip(clip), 0.3f) >= 0 && frame_at(f.app.clip(clip), 0.7f) >= 0,
		"grouped move did not preserve both relative key times");
	AnimKeyDot moved_rotation = f.app.clip(clip).entry_at("hip", 0.3f);
	AnimKeyDot moved_translation = f.app.clip(clip).entry_at("hip", 0.7f);
	test::@check(math::abs(moved_rotation.angle - 0.2f) < EPSILON
		&& math::abs(moved_translation.move.x - 0.6f) < EPSILON,
		"grouped move left compiled track sampling at the old times");
	test::@check(f.app.animation_key_selected(clip, 0.3f)
		&& f.app.animation_key_selected(clip, 0.7f), "selection did not follow moved keys");
	test::@check(f.app.undo_stack.cursor == history + 1, "one grouped move was not one history edit");

	history = f.app.undo_stack.cursor;
	test::@check(!f.app.move_selected_animation_keys(clip, 0.1f),
		"move colliding with an unselected key was accepted");
	test::@check(frame_at(f.app.clip(clip), 0.3f) >= 0 && frame_at(f.app.clip(clip), 0.7f) >= 0
		&& frame_at(f.app.clip(clip), 0.8f) >= 0, "collision partially moved the group");
	test::@check(f.app.undo_stack.cursor == history, "rejected collision created history");

	test::@check(!f.app.move_selected_animation_keys(clip, -0.4f),
		"move taking one selected key before zero was accepted");
	test::@check(frame_at(f.app.clip(clip), 0.3f) >= 0 && frame_at(f.app.clip(clip), 0.7f) >= 0,
		"out-of-bounds move partially moved the group");
	test::@check(f.app.undo_stack.cursor == history, "rejected bounds move created history");
	(void)f.app.move_selected_animation_keys(clip, 0.0f);
	test::@check(f.app.undo_stack.cursor == history
		&& frame_at(f.app.clip(clip), 0.3f) >= 0 && frame_at(f.app.clip(clip), 0.7f) >= 0,
		"zero-distance move changed keys or created an edit");

	test::@check(f.app.undo(), "grouped move could not be undone");
	test::@check(frame_at(f.app.clip(clip), 0.2f) >= 0 && frame_at(f.app.clip(clip), 0.6f) >= 0
		&& frame_at(f.app.clip(clip), 0.3f) < 0, "undo did not restore all moved times");
}

fn void grouped_delete_is_atomic_and_undo_restores_sparse_keys() @test
{
	MultiKeyFixture f;
	f.open();
	defer f.close();
	AnimRef clip = f.add("delete", 1.0f, ((float[3]){ 0.1f, 0.4f, 0.9f })[..],
		((AnimChannels[3]){ ROTATION, TRANSLATION, BOTH })[..]);
	f.app.select_animation_key(clip, 0.1f);
	f.app.select_animation_key(clip, 0.9f, additive: true);
	sz history = f.app.undo_stack.cursor;

	test::@check(f.app.delete_selected_animation_keys(clip), "grouped delete failed");
	test::@check(f.app.clip(clip).keyframes.len == 1 && frame_at(f.app.clip(clip), 0.4f) >= 0,
		"grouped delete removed the wrong columns");
	test::@check(math::abs(f.app.clip(clip).entry_at("hip", 0.1f).move.x - 0.4f) < EPSILON,
		"grouped delete left sampling on a removed compiled-track entry");
	test::@check(f.app.undo_stack.cursor == history + 1, "grouped delete was not one history edit");
	test::@check(f.app.undo(), "grouped delete was not undoable");
	test::@check(f.app.clip(clip).keyframes.len == 3
		&& f.app.clip(clip).keyframes[(usz)frame_at(f.app.clip(clip), 0.1f)].dots[0].channels == ROTATION
		&& f.app.clip(clip).keyframes[(usz)frame_at(f.app.clip(clip), 0.9f)].dots[0].channels == BOTH,
		"undo did not restore the selected sparse frames");
}

fn void grouped_copy_paste_keeps_relative_timing_sparse_channels_and_one_undo() @test
{
	MultiKeyFixture f;
	f.open();
	defer f.close();
	AnimRef source = f.add("source", 2.0f, ((float[2]){ 0.2f, 0.6f })[..],
		((AnimChannels[2]){ ROTATION, TRANSLATION })[..]);
	f.app.select_animation_keys_between(source, 0.1f, 0.7f);
	test::@check(f.app.copy_selected_animation_keys(source), "grouped copy failed");

	AnimRef target = f.add("target", 2.0f, ((float[1]){ 1.0f })[..],
		((AnimChannels[1]){ TRANSLATION })[..]);
	sz history = f.app.undo_stack.cursor;
	test::@check(f.app.paste_animation_keys(target, 1.0f), "grouped paste failed");
	AnimTemplate* pasted = f.app.clip(target);
	sz first = frame_at(pasted, 1.0f);
	sz second = frame_at(pasted, 1.4f);
	test::@check(first >= 0 && second >= 0, "paste lost the copied keys' relative timing");
	test::@check(pasted.keyframes[(usz)first].dots.len == 1
		&& pasted.keyframes[(usz)first].dots[0].channels == BOTH,
		"paste collision did not merge complementary sparse channels");
	test::@check(pasted.keyframes[(usz)second].dots.len == 1
		&& pasted.keyframes[(usz)second].dots[0].channels == TRANSLATION,
		"paste expanded a sparse copied frame");
	test::@check(f.app.undo_stack.cursor == history + 1, "grouped paste was not one history edit");
	test::@check(f.app.undo(), "grouped paste was not undoable");
	test::@check(f.app.clip(target).keyframes.len == 1 && frame_at(f.app.clip(target), 1.4f) < 0
		&& f.app.clip(target).keyframes[0].dots[0].channels == TRANSLATION,
		"undo did not restore the target independently of the clipboard source");
	test::@check(f.app.clip(source).keyframes.len == 2
		&& f.app.clip(source).keyframes[0].dots[0].channels == ROTATION,
		"copy/paste or target undo mutated the source clip");

	history = f.app.undo_stack.cursor;
	test::@check(!f.app.paste_animation_keys(target, 1.8f),
		"paste whose last key exceeds the duration was accepted");
	test::@check(f.app.clip(target).keyframes.len == 1 && f.app.undo_stack.cursor == history,
		"rejected paste partially wrote keys or history");

	// The incoming keys are distinct by more than ANIM_SAME_TIME, but both are
	// within that tolerance of the occupied midpoint. Neither may silently win
	// ownership of the existing destination column.
	AnimRef close_source = f.add("close source", 1.0f,
		((float[2]){ 0.2f, 0.2006f })[..],
		((AnimChannels[2]){ ROTATION, TRANSLATION })[..]);
	f.app.select_animation_keys_between(close_source, 0.19f, 0.21f);
	test::@check(f.app.copy_selected_animation_keys(close_source), "close-key grouped copy failed");
	AnimRef close_target = f.add("close target", 2.0f, ((float[1]){ 1.0003f })[..],
		((AnimChannels[1]){ BOTH })[..]);
	history = f.app.undo_stack.cursor;
	test::@check(!f.app.paste_animation_keys(close_target, 1.0f),
		"two close incoming keys were both mapped onto one occupied destination");
	test::@check(f.app.clip(close_target).keyframes.len == 1
		&& math::abs(f.app.clip(close_target).keyframes[0].time - 1.0003f) < EPSILON
		&& f.app.undo_stack.cursor == history,
		"ambiguous close-key paste partially changed the target or history");
}

fn void editing_selected_library_keys_forks_and_leaves_the_library_untouched() @test
{
	MultiKeyFixture f;
	f.open();
	defer f.close();
	AnimTemplate[] clips = alloc::new_array(mem, AnimTemplate, 1);
	clips[0] = multikey_clip("borrowed", 1.0f, ((float[2]){ 0.2f, 0.5f })[..],
		((AnimChannels[2]){ ROTATION, TRANSLATION })[..]);
	AnimRef borrowed = { (int)f.app.adopt_pack({
		.name = "fixture library".copy(mem), .clips = clips, .owned = true,
	}), 0 };
	f.app.select_animation_key(borrowed, 0.2f);
	test::@check(f.app.move_selected_animation_keys(borrowed, 0.1f),
		"selected library key could not be edited through a fork");

	test::@check(frame_at(f.app.clip(borrowed), 0.2f) >= 0
		&& frame_at(f.app.clip(borrowed), 0.3f) < 0, "library source was modified in place");
	test::@check(f.app.editing.valid() && !f.app.editing.same(borrowed)
		&& f.app.editing.pack == f.app.authored_pack,
		"library edit did not land in the authored pack");
	test::@check(frame_at(f.app.clip(f.app.editing), 0.3f) >= 0,
		"the authored fork does not contain the grouped edit");
	test::@check(f.app.undo(), "library fork edit was not undoable");
	test::@check(frame_at(f.app.clip(borrowed), 0.2f) >= 0,
		"undo of the fork disturbed the library source");
}

fn void grouped_key_edits_survive_the_authored_session_round_trip() @test
{
	const String SESSION = "build/animation-multikey-session.rigsmith.json";
	defer (void)file::delete(SESSION);
	MultiKeyFixture f;
	f.open();
	defer f.close();
	AnimRef clip = f.add("persisted", 1.0f, ((float[3]){ 0.1f, 0.4f, 0.7f })[..],
		((AnimChannels[3]){ ROTATION, TRANSLATION, BOTH })[..]);
	f.app.select_animation_key(clip, 0.1f);
	f.app.select_animation_key(clip, 0.4f, additive: true);
	test::@check(f.app.move_selected_animation_keys(clip, 0.1f), "fixture move failed");
	f.app.select_animation_key(clip, 0.7f);
	test::@check(f.app.delete_selected_animation_keys(clip), "fixture delete failed");

	AnimPack* authored = f.app.authored();
	test::@check(authored != null, "grouped edits lost their authored pack");
	if (!authored) return;
	if (catch crig::write_session(SESSION, &f.app.doc, "fixture.glb", authored.clips))
	{
		test::@check(false, "could not persist grouped animation edits");
		return;
	}
	ProjectSession? reading = crig::read_project_session(mem, SESSION);
	if (catch reading)
	{
		test::@check(false, "could not reload grouped animation edits");
		return;
	}
	ProjectSession loaded = reading;
	defer loaded.free(mem);
	test::@check(loaded.authored.len == 1 && loaded.authored[0].keyframes.len == 2,
		"session round trip lost the grouped move/delete result");
	test::@check(frame_at(&loaded.authored[0], 0.2f) >= 0
		&& frame_at(&loaded.authored[0], 0.5f) >= 0
		&& frame_at(&loaded.authored[0], 0.7f) < 0,
		"session round trip restored pre-edit key times");
}

fn void grouped_edit_guards_and_selection_invalidation_are_atomic() @test
{
	MultiKeyFixture f;
	f.open();
	defer f.close();
	AnimRef clip = f.add("guards", 1.0f, ((float[2]){ 0.2f, 0.6f })[..],
		((AnimChannels[2]){ ROTATION, TRANSLATION })[..]);
	f.app.select_animation_keys_between(clip, 0.0f, 1.0f);
	sz history = f.app.undo_stack.cursor;
	test::@check(!f.app.delete_selected_animation_keys(clip),
		"deleting every key left an invalid empty clip");
	test::@check(f.app.clip(clip).keyframes.len == 2 && f.app.undo_stack.cursor == history,
		"refused delete-all partially changed the clip or history");
	test::@check(f.app.copy_selected_animation_keys(clip), "could not seed grouped clipboard");

	f.app.pose_edit_pending = true;
	test::@check(!f.app.move_selected_animation_keys(clip, 0.1f)
		&& !f.app.delete_selected_animation_keys(clip)
		&& !f.app.paste_animation_keys(clip, 0.3f),
		"a pending pose draft did not block every grouped timeline edit");
	test::@check(frame_at(f.app.clip(clip), 0.2f) >= 0 && frame_at(f.app.clip(clip), 0.6f) >= 0
		&& f.app.clip(clip).keyframes.len == 2 && f.app.undo_stack.cursor == history,
		"a draft-blocked grouped edit partially changed keys or history");
	f.app.pose_edit_pending = false;

	f.app.clear_animation_key_selection();
	f.app.select_animation_key(clip, 0.2f);
	test::@check(f.app.move_selected_animation_keys(clip, 0.1f), "selection invalidation move failed");
	test::@check(f.app.animation_key_selected(clip, 0.3f), "selection did not follow its move");
	test::@check(f.app.undo(), "selection invalidation move did not undo");
	test::@check(f.app.animation_key_selection_count(clip) == 0,
		"undo retained times into the replaced clip storage");

	f.app.select_animation_key(clip, 0.2f);
	AnimTemplate retimed = crig::clip_retimed(mem, *f.app.clip(clip), 1.5f);
	AnimRef replaced = f.app.land_clip(clip, retimed);
	test::@check(replaced.valid() && f.app.animation_key_selection_count(replaced) == 0,
		"whole-clip replacement retained stale key selection");
	f.app.select_animation_key(replaced, 0.3f);
	test::@check(f.app.delete_authored_clip("guards"), "fixture clip deletion failed");
	f.app.undo_stack.commit();
	test::@check(f.app.animation_key_selection_count(replaced) == 0,
		"clip deletion left a selection pointing into shifted clip indices");

	AnimTemplate[] library_clips = alloc::new_array(mem, AnimTemplate, 1);
	library_clips[0] = multikey_clip("no-op borrowed", 1.0f,
		((float[2]){ 0.25f, 0.75f })[..], ((AnimChannels[2]){ ROTATION, BOTH })[..]);
	AnimRef borrowed = { (int)f.app.adopt_pack({
		.name = "no-op fixture library".copy(mem), .clips = library_clips, .owned = true,
	}), 0 };
	usz authored_count = f.app.authored().clips.len;
	AnimRef editing_before = f.app.editing;
	history = f.app.undo_stack.cursor;
	f.app.select_animation_key(borrowed, 0.25f);
	(void)f.app.move_selected_animation_keys(borrowed, 0.0f);
	test::@check(f.app.authored().clips.len == authored_count
		&& f.app.editing.same(editing_before) && frame_at(f.app.clip(borrowed), 0.25f) >= 0
		&& f.app.undo_stack.cursor == history,
		"zero-distance library move forked, changed editing, or created history");
}
