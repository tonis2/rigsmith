<*
 Curve clean-up: five tools that tidy the channels a clip keys, each one undo
 step, each acting on the same set of channel keys.

 **Fix flips** (Euler filter): a rotation key stores a quaternion, so the same
 orientation can be written two ways (`q` and `-q`). A channel whose neighbours
 sit on opposite sides of that pair reads as a swing the long way round to
 anything that blends the components, and as a jump in the file. Each key is
 rewritten onto the side its predecessor is on. The orientation at every key is
 unchanged. The Curves sheet's Euler angles are not stored: they are unwrapped
 from the quaternions sample to sample (`euler_of`), so a wrapped angle cannot
 survive in the data and the sign is all there is to fix.

 **Smooth**: a 1-2-1 pass over the key values of each channel. A position is
 averaged directly, a rotation moves a quarter of the way toward each
 neighbour along the shortest arc. The first and last key of a run stay.

 **Simplify**: drops the keys the straight line between their neighbours
 reproduces within Optimize's Light tolerance, by `curve_keys`. A key stays
 when either segment next to it is not a plain straight one (held or smooth
 segments, an ease), so the curve's shape between the kept keys is unchanged.

 **Flatten**: gives the selected keys the `FLAT` tangent mode, so the curve
 levels out through each of them. The values are untouched.

 **Match loop seam**: the last key of each channel takes the first key's value,
 so a cycle meets itself.

 Which channels: see `AppState.cleanup_picks`. The transforms below are plain
 functions over `AnimChannelKey` lists so they need no open app.
*>
module crig;

import std::math;
import std::math::vector;
import std::math::quaternion;
import std::collections::list;

// ---------------------------------------------------------------------------
// The transforms

// ---------------------------------------------------------------------------
// On the app

<*
 The channel keys a clean-up acts on, one rule, as `animation_selection_uses_ease`
 reads a selection:

 - Channel keys picked in the sheet: exactly those.
 - Else keys picked as whole poses: every channel keyed in those columns.
 - Else nothing picked: every key, over the whole clip, of the channels of the
   joints selected in the viewport (the ones Curves draws).

 Borrows the joint names from the clip and lives in the temp allocator.
*>
fn AnimChannelKey[] AppState.cleanup_picks(&self, AnimRef ref)
{
	AnimTemplate* clip = self.key_clip(ref);
	List{AnimChannelKey} picks;
	picks.init(tmem);
	if (!clip) return {};
	bool here = self.anim_key_selection_ref.same(ref);
	bool channels = here && self.anim_channel_key_selection.len() > 0;
	bool columns = here && !channels && self.anim_key_selection.len() > 0;
	List{String} joints;
	joints.init(tmem);
	if (!channels && !columns)
	{
		if (try view = self.open_rig(mem))
		{
			defer view.free(mem);
			String[] words = self.names_for(&view, ref);
			foreach (usz i, name : words)
			{
				if (i < view.dot_ids.len && name.len > 0 && self.is_selected(view.dot_ids[i])) joints.push(name.tcopy());
			}
		}
	}
	foreach (frame : clip.keyframes) foreach (dot : frame.dots)
	{
		for (int c = 0; c < 2; c++)
		{
			bool rotation = c == 0;
			if (rotation ? !dot.keys_rotation() : !dot.keys_translation()) continue;
			AnimChannels channel = rotation ? ROTATION : TRANSLATION;
			bool picked;
			if (channels)
			{
				picked = self.channel_selection_contains(frame.time, dot.joint_name, channel);
			}
			else if (columns)
			{
				picked = self.animation_key_selected(ref, frame.time);
			}
			else
			{
				foreach (joint : joints) if (joint == dot.joint_name) { picked = true; break; }
			}
			if (picked) picks.push({ .time = frame.time, .joint = dot.joint_name, .channel = channel });
		}
	}
	return picks.to_array(tmem);
}

<*
 Run one clean-up on the clip being edited and land it as one undo step.

 @return `False with a notice when it refused or found nothing to change.`
*>
fn bool AppState.curve_cleanup(&self, AnimRef ref, CurveCleanup op)
{
	if (!self.ensure_clip_imported(ref)) return false;
	AnimTemplate* clip = self.key_clip(ref);
	if (!clip)
	{
		self.@notice("Pick an animation to edit first.");
		return false;
	}
	if (self.procedural_layer_of(ref))
	{
		self.@notice("This layer is a generator with no keys: edit its parameters instead.");
		return false;
	}
	if (self.pose_edit_pending) return false;
	@pool()
	{
		AnimChannelKey[] picks = self.cleanup_picks(ref);
		if (picks.len == 0)
		{
			self.@notice("Select keys in the sheet, or joints in the viewport, to clean up their curves.");
			return false;
		}
		usz changed;
		AnimTemplate cleaned = clip_curve_cleaned(mem, *clip, picks, op, &changed);
		if (changed == 0)
		{
			cleaned.free(mem);
			switch (op)
			{
				case EULER_FILTER: self.@notice("No flips to fix: every selected rotation key already follows its neighbour.");
				case SMOOTH: self.@notice("Nothing to smooth: it needs three picked keys in a row on a channel.");
				case SIMPLIFY: self.@notice("No keys to lose: the selected curves are already as simple as they get.");
				case FLATTEN: self.@notice("The selected keys are already flat.");
				case LOOP_SEAM: self.@notice("Nothing to match: the selected channels already end where they start.");
			}
			return false;
		}
		bool landed;
		if (op == SIMPLIFY)
		{
			// Whole keys may be gone, so the picked times may name nothing now.
			AnimRef next = self.land_key_edit(ref, cleaned);
			landed = next.valid();
			if (landed)
			{
				self.clear_animation_key_selection();
				self.editing = next;
			}
		}
		else
		{
			landed = self.land_keeping_selection(ref, cleaned, true);
		}
		if (!landed) return false;
		switch (op)
		{
			case EULER_FILTER: self.@notice("Fixed %d flipped keys · Ctrl+Z undoes it", changed);
			case SMOOTH: self.@notice("Smoothed %d keys · Ctrl+Z undoes it", changed);
			case SIMPLIFY: self.@notice("Removed %d keys the curves do not need · Ctrl+Z undoes it", changed);
			case FLATTEN: self.@notice("Flattened %d keys · Ctrl+Z undoes it", changed);
			case LOOP_SEAM: self.@notice("Matched the seam on %d channels · Ctrl+Z undoes it", changed);
		}
		return true;
	};
}

fn bool AppState.euler_filter_selection(&self, AnimRef ref) => self.curve_cleanup(ref, EULER_FILTER);
fn bool AppState.smooth_selection(&self, AnimRef ref) => self.curve_cleanup(ref, SMOOTH);
fn bool AppState.simplify_selection(&self, AnimRef ref) => self.curve_cleanup(ref, SIMPLIFY);
fn bool AppState.flatten_selection(&self, AnimRef ref) => self.curve_cleanup(ref, FLATTEN);
fn bool AppState.match_loop_seam_selection(&self, AnimRef ref) => self.curve_cleanup(ref, LOOP_SEAM);
