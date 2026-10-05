module crig;
import std::math;

fn bool AppState.copy_animation_keys_at(&self, AnimRef ref, float[] times)
{
	AnimTemplate* clip = self.key_clip(ref);
	if (!clip || times.len == 0) return false;
	RigView? opened = self.open_rig(mem);
	if (catch opened) return false;
	RigView view = opened;
	defer view.free(mem);
	String[] source_names = self.names_for(&view, ref);
	usz count;
	foreach (frame : clip.keyframes) foreach (time : times)
		if (math::abs(frame.time - time) < ANIM_SAME_TIME) { count++; break; }
	if (count == 0) return false;
	AnimKeyframe[] frames = alloc::new_array(mem, AnimKeyframe, (sz)count);
	usz write;
	foreach (frame : clip.keyframes)
	{
		bool wanted;
		foreach (time : times) if (math::abs(frame.time - time) < ANIM_SAME_TIME) { wanted = true; break; }
		if (wanted) frames[write++] = keyframe_copy(mem, frame);
	}
	AnimTemplate copied = clip_with_frames(mem, *clip, frames, clip.duration);
	bool accepted;
	defer if (!accepted) copied.free(mem);
	foreach (&frame : copied.keyframes) foreach (&dot : frame.dots)
	{
		// A copied key must carry the curve the source actually used. INHERIT is
		// relative to a clip and could resolve differently in the destination.
		if (dot.keys_rotation()) dot.rotation_interpolation = dot.interpolation(true, clip.blend);
		if (dot.keys_translation()) dot.translation_interpolation = dot.interpolation(false, clip.blend);
		sz joint = array::index_of(source_names, dot.joint_name) ?? -1;
		if (joint < 0) { self.@notice("Some joints in these keys don't match this rig, so they can't be copied."); return false; }
		dot.joint_name.free(mem);
		dot.joint_name = view.names[joint].copy(mem);
	}
	self.anim_key_clipboard.free(mem);
	self.anim_key_clipboard = copied;
	self.anim_key_clipboard_sparse = false;
	accepted = true;
	return true;
}

fn bool AppState.copy_animation_key(&self, AnimRef ref, float time)
{
	AnimTemplate* clip = self.key_clip(ref);
	sz index = self.key_near(ref, time, ANIM_SAME_TIME);
	if (!clip || index < 0) { self.@notice("Click a key to copy it."); return false; }
	float[1] times = { clip.keyframes[index].time };
	if (!self.copy_animation_keys_at(ref, times[..])) return false;
	self.@notice("Key copied. Choose another time and paste.");
	return true;
}

fn bool AppState.copy_selected_animation_keys(&self, AnimRef ref)
{
	if (self.anim_key_selection_ref.same(ref) && self.anim_channel_key_selection.len() > 0)
	{
		return self.copy_selected_animation_channels(ref);
	}
	if (!self.anim_key_selection_ref.same(ref) || self.anim_key_selection.len() == 0)
	{ self.@notice("Select keys to copy."); return false; }
	if (!self.copy_animation_keys_at(ref, self.anim_key_selection.array_view())) return false;
	self.@notice("%d keys copied.", self.anim_key_clipboard.keyframes.len);
	return true;
}

fn bool AppState.copy_selected_animation_channels(&self, AnimRef ref)
{
	AnimTemplate* clip = self.key_clip(ref);
	if (!clip || self.anim_channel_key_selection.len() == 0) return false;
	RigView? opened = self.open_rig(mem);
	if (catch opened) return false;
	RigView view = opened;
	defer view.free(mem);
	String[] source_names = self.names_for(&view, ref);
	AnimTemplate copied = self.clip_channels(*clip, true);
	// A copied key must carry the curve the source actually used. INHERIT is
	// relative to a clip and could resolve differently in the destination.
	foreach (&frame : copied.keyframes) foreach (&dot : frame.dots)
	{
		if (dot.keys_rotation()) dot.rotation_interpolation = dot.interpolation(true, clip.blend);
		if (dot.keys_translation()) dot.translation_interpolation = dot.interpolation(false, clip.blend);
	}
	bool accepted;
	defer if (!accepted) copied.free(mem);
	foreach (&frame : copied.keyframes) foreach (&dot : frame.dots)
	{
		sz joint = array::index_of(source_names, dot.joint_name) ?? -1;
		if (joint < 0) { self.@notice("Some joints in these keys don't match this rig, so they can't be copied."); return false; }
		dot.joint_name.free(mem);
		dot.joint_name = view.names[joint].copy(mem);
	}
	self.anim_key_clipboard.free(mem);
	self.anim_key_clipboard = copied;
	self.anim_key_clipboard_sparse = true;
	accepted = true;
	self.@notice("%d channel keys copied.", self.anim_channel_key_selection.len());
	return true;
}

fn bool AppState.paste_animation_keys_count(&self, AnimRef ref, float time, usz count)
{
	AnimTemplate* clip = self.key_clip(ref);
	if (!clip || self.anim_key_clipboard.keyframes.len == 0 || count == 0)
	{ self.@notice("Copy keys first."); return false; }
	if (self.pose_edit_pending) return false;
	count = math::min(count, (usz)self.anim_key_clipboard.keyframes.len);
	float offset = time - self.anim_key_clipboard.keyframes[0].time;
	for (usz i = 0; i < count; i++)
	{
		float destination = self.anim_key_clipboard.keyframes[i].time + offset;
		if (!(destination >= 0.0f && destination <= clip.duration))
		{ self.@notice("The copied keys do not fit inside this animation."); return false; }
		for (usz earlier = 0; earlier < i; earlier++)
		{
			float other = self.anim_key_clipboard.keyframes[earlier].time + offset;
			if (math::abs(destination - other) < ANIM_SAME_TIME)
			{ self.@notice("Two copied keys would land at the same time."); return false; }
			sz occupied = self.key_near(ref, destination, ANIM_SAME_TIME);
			sz other_occupied = self.key_near(ref, other, ANIM_SAME_TIME);
			if (occupied >= 0 && occupied == other_occupied)
			{ self.@notice("Two copied keys would merge into the same key."); return false; }
		}
	}
	RigView? opened = self.open_rig(mem);
	if (catch opened) return false;
	RigView view = opened;
	defer view.free(mem);
	String[] target_names = self.names_for(&view, ref);
	for (usz f = 0; f < count; f++) foreach (dot : self.anim_key_clipboard.keyframes[f].dots)
	{
		bool found;
		foreach (usz j, name : view.names) if (name == dot.joint_name)
		{ found = true; break; }
		if (!found) { self.@notice("The copied poses belong to a different rig; their joints must match."); return false; }
	}
	AnimTemplate built = clip_copy(mem, *clip);
	for (usz f = 0; f < count; f++)
	{
		AnimKeyframe pasted = keyframe_copy(mem, self.anim_key_clipboard.keyframes[f]);
		pasted.time += offset;
		foreach (&dot : pasted.dots) foreach (usz i, name : view.names)
		{
			if (name != dot.joint_name) continue;
			dot.joint_name.free(mem);
			dot.joint_name = target_names[i].copy(mem);
			break;
		}
		AnimTemplate next = clip_with_key(mem, built, pasted);
		built.free(mem);
		built = next;
	}
	self.prepare_timeline_navigation();
	AnimRef landed = self.land_key_edit(ref, built);
	if (!landed.valid()) return false;
	if (self.anim_key_clipboard_sparse)
	{
		self.restart_key_selection(landed);
		for (usz i; i < count; i++) foreach (dot : self.anim_key_clipboard.keyframes[i].dots)
		{
			float landed_time = self.anim_key_clipboard.keyframes[i].time + offset;
			String target_joint = dot.joint_name;
			foreach (usz j, name : view.names) if (name == dot.joint_name)
			{ target_joint = target_names[j]; break; }
			if (dot.keys_rotation()) self.select_channel(landed_time, target_joint, ROTATION);
			if (dot.keys_translation()) self.select_channel(landed_time, target_joint, TRANSLATION);
		}
	}
	else
	{
		self.restart_key_selection(landed);
		for (usz i = 0; i < count; i++) self.select_time(self.anim_key_clipboard.keyframes[i].time + offset);
	}
	self.settle_key_selection();
	self.editing = landed;
	self.edit_time = time;
	self.show_edited();
	return true;
}

fn bool AppState.paste_animation_key(&self, AnimRef ref, float time)
{
	bool pasted = self.paste_animation_keys_count(ref, time, 1);
	if (pasted) self.@notice("Pasted the copied keys at %.2fs. Undo restores the previous keys.", time);
	return pasted;
}

fn bool AppState.paste_animation_keys(&self, AnimRef ref, float time)
{
	bool pasted = self.paste_animation_keys_count(ref, time, self.anim_key_clipboard.keyframes.len);
	if (pasted) self.@notice("Pasted %d keys. Undo restores the previous keys.", self.anim_key_clipboard.keyframes.len);
	return pasted;
}
