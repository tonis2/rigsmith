<*
 Fast, geometry-free checks for editing individual sparse animation channels.
*>
module crig_tests::animation_channel_edit;

import crig;
import std::core::test;
import std::io::file;
import std::math;
import std::math::quaternion;

const float EPSILON = 1.0e-5f;

fn AnimKeyDot channel_dot(float value, AnimChannels channels)
{
	return {
		.joint_name = "hip".copy(mem),
		.axis = { 0, 1, 0 },
		.angle = value,
		.move = { value, 0, 0 },
		.channels = channels,
	};
}

fn AnimTemplate channel_clip(String name, float duration, float[] times,
	AnimChannels[] channels)
{
	AnimKeyframe[] keys = alloc::new_array(mem, AnimKeyframe, (sz)times.len);
	foreach (usz i, &key : keys)
	{
		AnimKeyDot[] dots = alloc::new_array(mem, AnimKeyDot, 1);
		dots[0] = channel_dot(times[i], channels[i]);
		*key = { .time = times[i], .dots = dots };
	}
	return { .name = name.copy(mem), .duration = duration, .keyframes = keys, .owned = true };
}

fn sz frame_at(AnimTemplate* clip, float time)
{
	foreach (usz i, frame : clip.keyframes)
		if (math::abs(frame.time - time) < EPSILON) return (sz)i;
	return -1;
}

fn AnimChannels channels_at(AnimTemplate* clip, float time)
{
	sz frame = frame_at(clip, time);
	if (frame < 0 || clip.keyframes[(usz)frame].dots.len == 0) return BOTH;
	return clip.keyframes[(usz)frame].dots[0].channels;
}

struct ChannelFixture { AppState app; }

fn void ChannelFixture.open(&self)
{
	self.app = crig::new_app({});
	self.app.doc.root_id = self.app.doc.add_dot({}, "hip");
}

fn AnimRef ChannelFixture.add(&self, String name, float duration, float[] times,
	AnimChannels[] channels)
{
	AnimRef ref = self.app.put_authored_clip(channel_clip(name, duration, times, channels));
	(void)self.app.bind_ref(ref);
	self.app.undo_stack.commit();
	self.app.undo_stack.clear();
	self.app.editing = ref;
	return ref;
}

fn void ChannelFixture.close(&self) => self.app.free();

fn void channel_move_merges_independent_tracks_and_rejects_overlap_atomically() @test
{
	ChannelFixture f;
	f.open();
	defer f.close();
	AnimRef clip = f.add("move channels", 1.0f, ((float[3]){ 0.2f, 0.4f, 0.6f })[..],
		((AnimChannels[3]){ ROTATION, TRANSLATION, ROTATION })[..]);

	test::@check(f.app.select_animation_channel_key(clip, 0.2f, "hip", ROTATION),
		"rotation channel could not be selected");
	sz history = f.app.undo_stack.cursor;
	test::@check(f.app.move_selected_animation_keys(clip, 0.2f),
		"rotation could not move onto an independently keyed translation");
	AnimTemplate* moved = f.app.clip(f.app.editing);
	test::@check(frame_at(moved, 0.2f) < 0 && channels_at(moved, 0.4f) == BOTH,
		"independent same-time channels did not merge into one sparse dot");
	test::@check(math::abs(moved.entry_at("hip", 0.4f).angle - 0.2f) < EPSILON
		&& math::abs(moved.entry_at("hip", 0.4f).move.x - 0.4f) < EPSILON,
		"merge changed the moved rotation or preserved translation");
	test::@check(f.app.undo_stack.cursor == history + 1, "channel move was not one edit");

	clip = f.app.editing;
	test::@check(f.app.select_animation_channel_key(clip, 0.4f, "hip", ROTATION),
		"moved rotation was not selectable");
	history = f.app.undo_stack.cursor;
	test::@check(!f.app.move_selected_animation_keys(clip, 0.2f),
		"move onto an occupied rotation channel was accepted");
	test::@check(channels_at(f.app.clip(clip), 0.4f) == BOTH
		&& channels_at(f.app.clip(clip), 0.6f) == ROTATION
		&& f.app.undo_stack.cursor == history,
		"rejected overlap partially changed sparse keys or history");
}

fn void channel_group_move_refuses_two_keys_aliasing_one_destination_frame() @test
{
	ChannelFixture f;
	f.open();
	defer f.close();
	AnimRef clip = f.add("close channel move", 2.0f,
		((float[3]){ 0.2f, 0.2006f, 1.0003f })[..],
		((AnimChannels[3]){ ROTATION, ROTATION, TRANSLATION })[..]);
	(void)f.app.select_animation_channel_key(clip, 0.2f, "hip", ROTATION);
	(void)f.app.select_animation_channel_key(clip, 0.2006f, "hip", ROTATION, additive: true);
	test::@check(f.app.animation_channel_key_selection_count(clip) == 2,
		"close rotation keys did not remain independently selected");
	sz history = f.app.undo_stack.cursor;
	test::@check(!f.app.move_selected_animation_keys(clip, 0.8f),
		"two selected rotations were aliased through one nearby destination frame");
	test::@check(frame_at(f.app.clip(clip), 0.2f) >= 0
		&& frame_at(f.app.clip(clip), 0.2006f) >= 0
		&& frame_at(f.app.clip(clip), 1.0003f) >= 0
		&& channels_at(f.app.clip(clip), 1.0003f) == TRANSLATION
		&& f.app.undo_stack.cursor == history,
		"ambiguous group move lost a key, changed the occupied frame, or wrote history");

	test::@check(f.app.move_selected_animation_keys(clip, 0.0f)
		&& f.app.undo_stack.cursor == history,
		"zero channel movement changed history or was treated as an error");
	test::@check(!f.app.move_selected_animation_keys(clip, -0.3f)
		&& frame_at(f.app.clip(clip), 0.2f) >= 0 && f.app.undo_stack.cursor == history,
		"out-of-bounds channel movement partially changed keys or history");
	f.app.pose_edit_pending = true;
	test::@check(!f.app.move_selected_animation_keys(clip, 0.1f)
		&& frame_at(f.app.clip(clip), 0.2f) >= 0 && f.app.undo_stack.cursor == history,
		"a pending pose draft did not guard channel movement atomically");
}

fn void channel_delete_preserves_the_other_channel_and_undo_restores_it() @test
{
	ChannelFixture f;
	f.open();
	defer f.close();
	AnimRef clip = f.add("delete channel", 1.0f, ((float[2]){ 0.2f, 0.8f })[..],
		((AnimChannels[2]){ BOTH, ROTATION })[..]);
	test::@check(f.app.select_animation_channel_key(clip, 0.2f, "hip", TRANSLATION),
		"translation channel could not be selected");
	sz history = f.app.undo_stack.cursor;
	test::@check(f.app.delete_selected_animation_keys(clip), "channel delete failed");
	test::@check(channels_at(f.app.clip(f.app.editing), 0.2f) == ROTATION
		&& frame_at(f.app.clip(f.app.editing), 0.8f) >= 0,
		"channel delete removed its sibling or an unrelated key");
	test::@check(f.app.undo_stack.cursor == history + 1 && f.app.undo(),
		"channel delete was not one undoable edit");
	test::@check(channels_at(f.app.clip(f.app.editing), 0.2f) == BOTH,
		"undo did not restore the deleted sparse channel");
}

fn void channel_copy_paste_replaces_only_incoming_channels_and_undoes_once() @test
{
	ChannelFixture f;
	f.open();
	defer f.close();
	AnimRef source = f.add("channel source", 2.0f, ((float[2]){ 0.2f, 0.4f })[..],
		((AnimChannels[2]){ BOTH, TRANSLATION })[..]);
	f.app.clip(source).keyframes[0].dots[0].rotation_interpolation = HOLD;
	f.app.clip(source).keyframes[1].dots[0].translation_interpolation = AUTO;
	(void)f.app.select_animation_channel_key(source, 0.2f, "hip", ROTATION);
	(void)f.app.select_animation_channel_key(source, 0.4f, "hip", TRANSLATION, additive: true);
	test::@check(f.app.animation_channel_key_selection_count(source) == 2
		&& f.app.copy_selected_animation_keys(source), "sparse channel copy failed");

	AnimRef target = f.add("channel target", 2.0f, ((float[1]){ 1.0f })[..],
		((AnimChannels[1]){ BOTH })[..]);
	f.app.clip(target).keyframes[0].dots[0].translation_interpolation = HOLD;
	sz history = f.app.undo_stack.cursor;
	test::@check(f.app.paste_animation_keys(target, 1.0f), "sparse channel paste failed");
	AnimTemplate* pasted = f.app.clip(f.app.editing);
	test::@check(channels_at(pasted, 1.0f) == BOTH && channels_at(pasted, 1.2f) == TRANSLATION,
		"paste expanded or lost copied channels instead of merging independently");
	test::@check(math::abs(pasted.entry_at("hip", 1.0f).angle - 0.2f) < EPSILON
		&& math::abs(pasted.entry_at("hip", 1.0f).move.x - 1.0f) < EPSILON,
		"incoming rotation did not replace rotation while preserving translation");
	test::@check(pasted.keyframes[(usz)frame_at(pasted, 1.0f)].dots[0].rotation_interpolation == HOLD
		&& pasted.keyframes[(usz)frame_at(pasted, 1.0f)].dots[0].translation_interpolation == HOLD
		&& pasted.keyframes[(usz)frame_at(pasted, 1.2f)].dots[0].translation_interpolation == AUTO,
		"paste lost an incoming segment mode or replaced its sibling channel's mode");
	test::@check(f.app.undo_stack.cursor == history + 1, "channel paste was not one edit");

	test::@check(f.app.undo(), "channel paste did not undo");
	test::@check(f.app.select_animation_channel_key(source, 0.2f, "hip", TRANSLATION)
		&& f.app.copy_selected_animation_keys(source), "replacement clipboard setup failed");
	history = f.app.undo_stack.cursor;
	test::@check(f.app.paste_animation_keys(target, 1.0f),
		"paste could not replace an occupied same channel");
	AnimRef replaced = f.app.editing;
	test::@check(channels_at(f.app.clip(replaced), 1.0f) == BOTH
		&& math::abs(f.app.clip(replaced).entry_at("hip", 1.0f).angle - 1.0f) < EPSILON
		&& math::abs(f.app.clip(replaced).entry_at("hip", 1.0f).move.x - 0.2f) < EPSILON
		&& f.app.undo_stack.cursor == history + 1,
		"same-channel paste did not replace translation and preserve rotation in one edit");
	test::@check(f.app.undo()
		&& math::abs(f.app.clip(target).entry_at("hip", 1.0f).angle - 1.0f) < EPSILON
		&& math::abs(f.app.clip(target).entry_at("hip", 1.0f).move.x - 1.0f) < EPSILON,
		"undo did not restore both destination channels");
}

fn void copying_both_channels_normalizes_one_dot_and_pastes_both_once() @test
{
	ChannelFixture f;
	f.open();
	defer f.close();
	AnimRef source = f.add("both channel source", 2.0f, ((float[1]){ 0.2f })[..],
		((AnimChannels[1]){ BOTH })[..]);
	(void)f.app.select_animation_channel_key(source, 0.2f, "hip", ROTATION);
	(void)f.app.select_animation_channel_key(source, 0.2f, "hip", TRANSLATION, additive: true);
	test::@check(f.app.copy_selected_animation_keys(source), "paired channel copy failed");
	test::@check(f.app.anim_key_clipboard.keyframes.len == 1
		&& f.app.anim_key_clipboard.keyframes[0].dots.len == 1
		&& f.app.anim_key_clipboard.keyframes[0].dots[0].channels == BOTH,
		"paired selection duplicated the joint or lost a channel in the clipboard");

	AnimRef target = f.add("both channel target", 2.0f, ((float[1]){ 1.0f })[..],
		((AnimChannels[1]){ BOTH })[..]);
	test::@check(f.app.paste_animation_keys(target, 1.0f),
		"paired channels could not replace an occupied joint");
	AnimRef replaced = f.app.editing;
	sz occupied = frame_at(f.app.clip(replaced), 1.0f);
	test::@check(occupied >= 0 && f.app.clip(replaced).keyframes[(usz)occupied].dots.len == 1
		&& f.app.clip(replaced).keyframes[(usz)occupied].dots[0].channels == BOTH
		&& math::abs(f.app.clip(replaced).entry_at("hip", 1.0f).angle - 0.2f) < EPSILON
		&& math::abs(f.app.clip(replaced).entry_at("hip", 1.0f).move.x - 0.2f) < EPSILON,
		"occupied paste did not replace both values through one normalized dot");

	test::@check(f.app.paste_animation_keys(replaced, 1.5f),
		"paired channels could not paste at a fresh time");
	AnimRef fresh = f.app.editing;
	sz inserted = frame_at(f.app.clip(fresh), 1.5f);
	test::@check(inserted >= 0 && f.app.clip(fresh).keyframes[(usz)inserted].dots.len == 1
		&& f.app.clip(fresh).keyframes[(usz)inserted].dots[0].channels == BOTH,
		"fresh paste duplicated the same joint instead of storing one BOTH dot");
	test::@check(f.app.animation_channel_key_selected(fresh, 1.5f, "hip", ROTATION)
		&& f.app.animation_channel_key_selected(fresh, 1.5f, "hip", TRANSLATION),
		"fresh paired paste did not select both resulting channel keys");
}

fn void sparse_channel_edit_survives_session_round_trip() @test
{
	const String SESSION = "build/animation-channel-edit-session.rigsmith.json";
	defer (void)file::delete(SESSION);
	ChannelFixture f;
	f.open();
	defer f.close();
	AnimRef clip = f.add("persist channels", 1.0f, ((float[2]){ 0.2f, 0.7f })[..],
		((AnimChannels[2]){ BOTH, ROTATION })[..]);
	(void)f.app.select_animation_channel_key(clip, 0.2f, "hip", TRANSLATION);
	test::@check(f.app.move_selected_animation_keys(clip, 0.2f), "fixture channel move failed");

	AnimPack* authored = f.app.authored();
	test::@check(authored != null, "no authored pack after channel edit");
	if (!authored) return;
	if (catch crig::write_session(SESSION, &f.app.doc, "fixture.glb", authored.clips))
	{
		test::@check(false, "could not persist channel edit");
		return;
	}
	ProjectSession? reading = crig::read_project_session(mem, SESSION);
	if (catch reading) { test::@check(false, "could not reload channel edit"); return; }
	ProjectSession loaded = reading;
	defer loaded.free(mem);
	test::@check(loaded.authored.len == 1
		&& channels_at(&loaded.authored[0], 0.2f) == ROTATION
		&& channels_at(&loaded.authored[0], 0.4f) == TRANSLATION
		&& channels_at(&loaded.authored[0], 0.7f) == ROTATION,
		"session round trip lost the independently moved sparse channel");
}

fn void library_channel_edit_forks_without_touching_the_source() @test
{
	ChannelFixture f;
	f.open();
	defer f.close();
	AnimTemplate[] clips = alloc::new_array(mem, AnimTemplate, 1);
	clips[0] = channel_clip("borrowed channels", 1.0f, ((float[2]){ 0.2f, 0.7f })[..],
		((AnimChannels[2]){ BOTH, ROTATION })[..]);
	AnimRef borrowed = { (int)f.app.adopt_pack({
		.name = "channel library".copy(mem), .clips = clips, .owned = true,
	}), 0 };
	(void)f.app.select_animation_channel_key(borrowed, 0.2f, "hip", TRANSLATION);
	test::@check(f.app.delete_selected_animation_keys(borrowed), "library channel edit failed");
	test::@check(channels_at(f.app.clip(borrowed), 0.2f) == BOTH,
		"library source was changed in place");
	test::@check(f.app.editing.valid() && !f.app.editing.same(borrowed)
		&& f.app.editing.pack == f.app.authored_pack
		&& channels_at(f.app.clip(f.app.editing), 0.2f) == ROTATION,
		"channel edit did not land in an authored fork");
	test::@check(f.app.undo() && channels_at(f.app.clip(borrowed), 0.2f) == BOTH,
		"fork undo disturbed the library source");
}

fn void selected_channel_keying_saves_only_that_channel_and_keeps_the_other_draft() @test
{
	ChannelFixture f;
	f.open();
	defer f.close();
	AnimRef clip = f.add("selected channel key", 1.0f, ((float[2]){ 0.0f, 1.0f })[..],
		((AnimChannels[2]){ BOTH, BOTH })[..]);
	f.app.edit_time = 0.5f;
	test::@check(f.app.pose_from_clip(clip, f.app.edit_time), "could not open the pose draft");
	Quaternionf turn = quaternion::from_axis_angle{float}((Vec3){ 0, 1, 0 }, 0.45f);
	test::@check(f.app.set_working_pose(f.app.doc.root_id, turn, { 0.25f, 0, 0 }),
		"could not change both channels in the draft");
	f.app.pose_edit_pending = true;
	test::@check(f.app.select_animation_channel_key(clip, 0.0f, "hip", ROTATION),
		"could not scope Selected to the explicit rotation lane");
	test::@check(f.app.key_pose_edit(SELECTED), "selected rotation could not be keyed");
	AnimTemplate* keyed = f.app.clip(f.app.editing);
	sz inserted = frame_at(keyed, 0.5f);
	test::@check(inserted >= 0 && keyed.keyframes[(usz)inserted].dots.len == 1
		&& keyed.keyframes[(usz)inserted].dots[0].channels == ROTATION,
		"Selected expanded a rotation-only timeline selection to both channels");
	test::@check(f.app.pose_edit_active && f.app.pose_edit_pending
		&& math::abs(f.app.working_pose(f.app.doc.root_id).offset.x - 0.25f) < EPSILON,
		"saving rotation discarded the same joint's unkeyed translation draft");
}
