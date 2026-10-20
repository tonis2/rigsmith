<*
 Align X/Y/Z on the pose: turning bones so the selected joints line up with the
 first-selected one on a world axis, in the animation being edited.

 	`app.align_pose_to_anchor(0); // onto the anchor's X, where Apply to reaches`

 The rig's Align (`align_selection_to_anchor`) moves joints on the model, which
 is the wrong edit while a clip is posed: the neck, head and head top of a rig
 built straight are already on one line at rest, and what leans is the pose.
 Here a joint reaches the line the way a posed joint can — its parent bone
 swings about the parent, the shortest way that puts the joint on the anchor's
 coordinate — so bone lengths hold and what is written is rotation keys.

 **Shallowest first.** The joints are swung in order of depth, each measured
 where the swings above it left it, so a chain picked from its base (neck,
 head, head top) comes out straight in one press. The anchor's coordinate is
 read once, before anything turns; a bone swung above the anchor carries the
 anchor off it, which is why the base of a chain is the one to pick first.

 **In the clip's own words.** An imported clip records its turns against the
 source rig's bones, and playback carries them onto this rig down the chain
 (`AnimTemplate.pose`). A key is rewritten on the bone it was recorded against
 so it plays exactly the turn wanted (`turn_key`), and what it plays is
 measured, not assumed.

 **The keys, not the holds.** What is lined up is the clip's own motion. A
 look-at on the head decides where the face points as the clip plays, which
 fights a straight head; pushing the keys against it would only bury turns in
 them for the day it is muted, so it is left to act and named in the notice.

 **Where it lands follows Apply to.** At the playhead the swung bones are keyed
 there; on Selected keys or Whole clip every key in reach is aligned from what
 the clip shows at it — the way to straighten a generated clip's head through
 every frame. Either is one undo step. A clip with layers lands at the playhead
 through the draft, as Mirror does, without the playback check.
*>
module crig;

import rig;
import std::math;
import std::math::quaternion;

<*
 How close a joint has to come to the line to count as on it, as a fraction of
 rig height: a tenth of a millimetre on a figure a metre tall. Float noise
 through a palette is far below it; a limit holding a bone short is far above.
*>
const float POSE_ALIGN_TOLERANCE = 1.0e-4f;

<*
 What lining up one pose did: whether any bone turned, and how many of the
 joints asked for ended on the line.
*>
struct PoseAlignment
{
	bool turned;
	usz lined;
	usz asked;
}

<*
 Line the selection up with the anchor on `component` in the animation being
 edited — the Align buttons while the header is on Pose. Says what it did.

 @param component : `0 for X, 1 for Y, 2 for Z.`
 @return `How many joints ended on the line, summed over the keys aligned; zero when none did.`
*>
fn usz AppState.align_pose_to_anchor(&self, int component)
{
	if (component < 0 || component > 2) return 0;
	String axis = component == 0 ? "X" : (component == 1 ? "Y" : "Z");
	if (!self.clip(self.editing))
	{
		self.@notice("pick an animation to align a pose in");
		return 0;
	}
	if (self.selected == 0 || self.also_selected.len() == 0)
	{
		self.@notice("select two or more joints to line them up on %s; the first one picked stays put", axis);
		return 0;
	}
	RigView? opened = self.open_rig(mem);
	if (catch opened) return 0;
	RigView view = opened;
	defer view.free(mem);

	sz anchor = view.joint_of(self.selected);
	usz[] order = self.align_order(&view);
	defer if (order.len > 0) alloc::free(mem, order);
	if (anchor < 0 || order.len == 0)
	{
		self.@notice("select two or more joints of this rig to line them up on %s", axis);
		return 0;
	}

	if (self.clip(self.editing).layers.len == 0) return self.align_onto_keys(&view, (usz)anchor, order, component);

	rig::Pose pose = self.pose_shown_at(&view, self.edit_time, self.pose_edit_active);
	defer pose.free(mem);
	bool[] turned = alloc::new_array(mem, bool, (sz)view.len());
	defer alloc::free(mem, turned);
	PoseAlignment done = align_pose(&self.doc, &view, &pose, (usz)anchor, order, component, turned);
	if (!done.turned)
	{
		self.@notice(done.lined == done.asked ? "the selected joints are already on the first one's %s here"
			: "the limits keep the selected joints off the first one's %s here", axis);
		return done.lined;
	}
	if (self.land_pose(&view, keyed_bones(&view, pose, turned, self.edit_time)) == 0) return 0;
	self.@notice("Lined up %d of %d joint%s on %s at %.2fs%s · Ctrl+Z undoes it", done.lined, done.asked,
		done.asked == 1 ? "" : "s", axis, self.edit_time, done.lined < done.asked ? "; the limits held the rest short" : "");
	return done.lined;
}

<*
 `align_pose_to_anchor` on a clip without layers: at the playhead, or at every
 key Apply to reaches, as one undo step.

 Every key is lined up from what the clip's keys play there, and only the
 bones that turn at a key are written there. A pose posed and not yet keyed is
 keyed first, as Auto-key would, so what is lined up is what is on screen; that
 keying joins the step.

 @return `How many joints ended on the line as played, summed over the keys; zero when none did.`
*>
fn usz AppState.align_onto_keys(&self, RigView* view, usz anchor, usz[] order, int component)
{
	String axis = component == 0 ? "X" : (component == 1 ? "Y" : "Z");
	// Before any keying here, which would fork a library clip and say so.
	bool forked = self.editing.pack != self.authored_pack;
	bool keyed_first = self.pose_edit_active && self.pose_edit_pending;
	if (keyed_first && !self.key_pose_edit(CHANGED)) return 0;

	AnimRef ref = self.editing;
	if (self.clip(ref) && self.clip(ref).lazy) (void)self.ensure_clip_imported(ref);
	AnimTemplate* clip = self.clip(ref);
	if (!clip) return 0;
	AnimFloatList times;
	times.init(tmem);
	self.reach_key_times(ref, self.edit_time, &times);
	bool at_playhead = times.len() == 0;
	if (at_playhead) times.push(self.edit_time);

	bool[] written = alloc::new_array(mem, bool, (sz)view.len());
	defer alloc::free(mem, written);
	AnimTemplate trial = clip_copy(mem, *clip);
	PoseAlignment total;
	usz held;
	bool fits = true;
	foreach (time : times)
	{
		PoseAlignment done = self.align_key(view, ref, &trial, time, anchor, order, component, written, &fits);
		if (!fits) break;
		total.turned |= done.turned;
		total.lined += done.lined;
		total.asked += done.asked;
		if (done.lined < done.asked) held++;
	}
	String aimed = self.hold_covers(view, anchor, order);
	String after = aimed.len > 0 ? string::tformat(" · a look-at on %s still turns it as it plays", aimed) : "";
	if (!fits || !total.turned)
	{
		trial.free(mem);
		if (!fits)
		{
			self.@notice("this animation cannot carry the aligned joints");
			return 0;
		}
		String where = at_playhead ? "here" : "at every key";
		if (total.lined == total.asked)
		{
			self.@notice("the selected joints are already on the first one's %s %s%s", axis, where, after);
		}
		else
		{
			self.@notice("the limits keep the selected joints off the first one's %s %s%s", axis, where, after);
		}
		return total.lined;
	}
	if (!self.land_onto_keys(view, ref, trial, written, keyed_first)) return 0;

	// A fork's notice says where the change went, which matters more.
	if (forked) return total.lined;
	String how = keyed_first ? "Keyed the pose and lined up" : "Lined up";
	if (at_playhead)
	{
		self.@notice("%s %d of %d joint%s on %s at %.2fs%s%s · Ctrl+Z undoes it", how, total.lined, total.asked,
			total.asked == 1 ? "" : "s", axis, self.edit_time,
			total.lined < total.asked ? "; the limits held the rest short" : "", after);
		return total.lined;
	}
	String reach = self.key_reach == WHOLE_CLIP ? string::tformat("all %d keys", times.len())
		: string::tformat("%d selected keys", times.len());
	String shortfall = held > 0 ? string::tformat("; at %d of them the limits held some short", held) : "";
	self.@notice("%s %d joint%s on %s across %s%s%s · Ctrl+Z undoes it", how, order.len, order.len == 1 ? "" : "s",
		axis, reach, shortfall, after);
	return total.lined;
}

<*
 How many times a key is rewritten and played back before what it plays is
 taken as the answer. One pass is exact for a joint the clip already keys; the
 others are for a joint keyed here for the first time, a root, or a limit.
*>
const int POSE_ALIGN_ROUNDS = 3;

<*
 Line `order` up with the anchor at `time` in `trial`, rewriting `trial` there,
 and say how it came out as the clip plays it.

 The pose to reach is worked out once, from what the clip plays now, and each
 turned bone's key is then rewritten to play it (`turn_key`), shallowest first
 and each from what the writes above it left. The lining up is of the clip's
 own keys: a look-at or a pin is laid over them as it plays, and may turn the
 joints off the line again (`hold_covers` says so).

 @param written : `Marked for every rig joint whose key was rewritten.`
 @param fits : `Cleared when a joint the clip cannot name had to turn; trial is then partly rewritten and only fit to free.`
*>
fn PoseAlignment AppState.align_key(&self, RigView* view, AnimRef ref, AnimTemplate* trial, float time,
	usz anchor, usz[] order, int component, bool[] written, bool* fits)
{
	PoseAlignment out = { .asked = order.len };
	rig::Pose start = self.evaluated_clip_pose(mem, view, *trial, ref, time, false);
	defer start.free(mem);
	out.lined = lined_on(view, start, anchor, order, component);
	if (out.lined == out.asked) return out;

	bool[] turned = alloc::new_array(mem, bool, (sz)view.len());
	defer alloc::free(mem, turned);
	rig::Pose wanted = start.copy(mem);
	defer wanted.free(mem);
	if (!align_pose(&self.doc, view, &wanted, anchor, order, component, turned).turned) return out;

	String[] names = self.names_for(view, ref);
	Vec3[] bones = view.skeleton.bone_directions(mem);
	defer if (bones.len > 0) alloc::free(mem, bones);
	float missed = math::FLOAT_MAX;
	for (int round = 0; round < POSE_ALIGN_ROUNDS; round++)
	{
		// Joints come parents first, so this is shallowest first.
		foreach (usz j, bool moved : turned)
		{
			if (!moved) continue;
			if (j >= names.len || names[j].len == 0 || j >= bones.len)
			{
				*fits = false;
				return out;
			}
			rig::Pose now = self.evaluated_clip_pose(mem, view, *trial, ref, time, false);
			Quaternionf change = now.rotations[j].invert().mul(wanted.rotations[j]).normalize();
			now.free(mem);
			if (turn_size(change) < 1.0e-6f) continue;
			turn_key(trial, names[j], bones[j], time, change);
			written[j] = true;
			out.turned = true;
		}
		rig::Pose played = self.evaluated_clip_pose(mem, view, *trial, ref, time, false);
		out.lined = lined_on(view, played, anchor, order, component);
		float miss;
		foreach (usz j, bool moved : turned)
		{
			if (moved) miss = math::max(miss, turn_size(played.rotations[j].invert().mul(wanted.rotations[j])));
		}
		played.free(mem);
		// A limit holding a bone short stops it changing; so do the rounds.
		if (out.lined == out.asked || miss < 1.0e-5f || miss >= missed) break;
		missed = miss;
	}
	return out;
}

// How far a rotation turns, in radians — near enough for small ones.
fn float turn_size(Quaternionf q) @local => 2.0f * ((Vec3){ q.v.x, q.v.y, q.v.z }).length();

<*
 Turn `name`'s key at `time` in `clip` so the joint plays turned by `change`
 in its parent's frame.

 Playback carries a joint's key onto this rig as `M · turn · carry⁻¹`, where
 `carry` takes the bone the clip recorded onto the rig's own and `M` comes from
 the joints above it alone (`AnimTemplate.pose`). So `turn · carry⁻¹ · change ·
 carry` plays turned by `change`, and the key keeps the bone it was recorded
 against — the clip stays one rig's motion, which `span_bone` relies on. The
 key is edited in place when there is one at `time` that turns the joint;
 otherwise the joint is keyed there, rotation only.
*>
fn void turn_key(AnimTemplate* clip, String name, Vec3 rig_bone, float time, Quaternionf change)
{
	Vec3 bone;
	Quaternionf turn = clip.rotation_and_bone_at(name, time, &bone);
	Quaternionf carry = bone_carry(bone, rig_bone);
	Vec3 axis;
	float angle;
	axis_angle_of(turn.mul(carry.invert()).mul(change).mul(carry).normalize(), &axis, &angle);
	foreach (&frame : clip.keyframes)
	{
		if (math::abs(frame.time - time) >= ANIM_SAME_TIME) continue;
		foreach (&dot : frame.dots)
		{
			if (dot.joint_name != name || !dot.keys_rotation()) continue;
			dot.axis = axis;
			dot.angle = angle;
			return;
		}
	}
	AnimKeyDot[] dots = alloc::new_array(mem, AnimKeyDot, 1);
	dots[0] = { .joint_name = name.copy(mem), .channels = ROTATION, .axis = axis, .angle = angle, .bone = bone };
	AnimTemplate keyed = clip_with_key(mem, *clip, { .time = time, .dots = dots });
	clip.free(mem);
	*clip = keyed;
}

<*
 The first look-at in the clip being edited that turns one of the joints in
 `order`, the anchor, or a bone above them, or "" — what to name when the line
 the keys hold is not the line on screen. An aim turns its joint and the
 parents its spread reaches; a muted one or one at no influence turns nothing.
*>
fn String AppState.hold_covers(&self, RigView* view, usz anchor, usz[] order)
{
	AnimTemplate* clip = self.clip(self.editing);
	if (!clip) return "";
	String[] names = self.names_for(view, self.editing);
	foreach (aim : clip.aims)
	{
		if (aim.mute || aim.influence <= 0.0f) continue;
		sz at = -1;
		foreach (usz j, name : names) if (name == aim.joint) { at = (sz)j; break; }
		for (usz step = 0; at >= 0 && step < aim.spread; step++)
		{
			if ((usz)at == anchor) return aim.joint;
			foreach (joint : order) if ((usz)at == joint || view.skeleton.parents[joint] == at) return aim.joint;
			at = view.skeleton.parents[(usz)at];
		}
	}
	return "";
}

<*
 The selected joints other than the anchor, as joint indices, shallowest first —
 the order `align_pose` swings them in. Ties keep the order they were picked.
 The caller frees it.
*>
fn usz[] AppState.align_order(&self, RigView* view)
{
	usz[] order = alloc::new_array(mem, usz, (sz)self.also_selected.len());
	usz count;
	foreach (id : self.also_selected.array_view())
	{
		sz joint = view.joint_of(id);
		if (joint >= 0 && id != self.selected) order[count++] = (usz)joint;
	}
	if (count == 0)
	{
		alloc::free(mem, order);
		return {};
	}
	order = order[:count];
	// Insertion sort by depth: a handful of joints, and stable.
	for (usz i = 1; i < order.len; i++)
	{
		usz held = order[i];
		usz depth = joint_depth(&view.skeleton, held);
		usz j = i;
		for (; j > 0 && joint_depth(&view.skeleton, order[j - 1]) > depth; j--) order[j] = order[j - 1];
		order[j] = held;
	}
	return order;
}

fn usz joint_depth(rig::Skeleton* skeleton, usz joint) @local
{
	usz depth;
	for (int at = skeleton.parents[joint]; at >= 0; at = skeleton.parents[(usz)at]) depth++;
	return depth;
}

<*
 Swing `pose` so each joint of `order` takes the anchor's coordinate on
 `component`, shallowest first, each through its parent bone's limits.
 `turned` is marked for every bone that moved; a root has no bone above it to
 swing and stays where it is.
*>
fn PoseAlignment align_pose(RigDocument* doc, RigView* view, rig::Pose* pose, usz anchor, usz[] order,
	int component, bool[] turned)
{
	PoseAlignment done = { .asked = order.len };
	Vec3[] at = alloc::new_array(mem, Vec3, (sz)view.len());
	defer alloc::free(mem, at);
	if (!posed_points(view, *pose, at)) return done;
	float target = at[anchor][component];

	foreach (joint : order)
	{
		int parent = view.skeleton.parents[joint];
		if (parent < 0) continue;
		Vec3 from = at[joint] - at[(usz)parent];
		Vec3 to = swung_onto(from, target - at[(usz)parent][component], component);
		if ((to - from).length_sq() < 1.0e-14f) continue;

		Quaternionf[]? read = pose.world_rotations(mem, &view.skeleton);
		if (catch read) break;
		Quaternionf[] world = read;
		int above = view.skeleton.parents[(usz)parent];
		Quaternionf over = above >= 0 ? world[(usz)above] : quaternion::IDENTITY;
		alloc::free(mem, world);

		// The swing is a world turn; in the parent's frame it is conjugated by the
		// world rotation above it, as `turn_joint` measures a sweep.
		Quaternionf swing = bone_carry(from, to);
		Quaternionf local = over.invert().mul(swing).mul(over).mul(pose.rotations[(usz)parent]).normalize();
		JointRotationLimits limits = doc.rotation_limits_of(view.dot_ids[(usz)parent]);
		local = constrain_joint_rotation(joint_limit_frame(&view.skeleton, view.dot_ids, limits), limits, local);
		if (1.0f - math::abs(local.v.dot(pose.rotations[(usz)parent].v)) < 1.0e-9f) continue;

		pose.rotations[(usz)parent] = local;
		turned[(usz)parent] = true;
		done.turned = true;
		if (!posed_points(view, *pose, at)) return done;
	}

	done.lined = lined_up(view, at, anchor, order, component);
	return done;
}

// How many of `order` sit on the anchor's coordinate on `component` in `pose`.
fn usz lined_on(RigView* view, rig::Pose pose, usz anchor, usz[] order, int component) @local
{
	Vec3[] at = alloc::new_array(mem, Vec3, (sz)view.len());
	defer alloc::free(mem, at);
	if (!posed_points(view, pose, at)) return 0;
	return lined_up(view, at, anchor, order, component);
}

fn usz lined_up(RigView* view, Vec3[] at, usz anchor, usz[] order, int component) @local
{
	float tolerance = POSE_ALIGN_TOLERANCE * view.skeleton.height();
	usz lined;
	foreach (joint : order)
	{
		if (math::abs(at[joint][component] - at[anchor][component]) <= tolerance) lined++;
	}
	return lined;
}

<*
 The bone `from` swung the shortest way about its root until its `component`
 is `along`, its length kept. Past the bone's reach it points straight along
 the axis, as near as it can come. A bone already on the axis has no shortest
 way and leans toward the next axis round.
*>
fn Vec3 swung_onto(Vec3 from, float along, int component)
{
	float length = from.length();
	if (length < 1.0e-9f) return from;
	along = math::clamp(along, -length, length);
	Vec3 across = from;
	across[component] = 0.0f;
	float spread = across.length();
	if (spread < 1.0e-6f * length)
	{
		across = {};
		across[(component + 1) % 3] = 1.0f;
		spread = 1.0f;
	}
	Vec3 to = across * (math::sqrt(math::max(length * length - along * along, 0.0f)) / spread);
	to[component] = along;
	return to;
}

// Where `pose` puts every joint, in model space, into `at`.
fn bool posed_points(RigView* view, rig::Pose pose, Vec3[] at) @local
{
	Matrix4f[]? built = rig::joint_palette(mem, &view.skeleton, pose);
	if (catch built) return false;
	Matrix4f[] palette = built;
	foreach (usz i, joint : view.skeleton.joints) at[i] = joint.transform(palette[i]);
	alloc::free(mem, palette);
	return true;
}

<*
 The bones `turned` marks, as rig-named entries at `time` — what `land_pose`
 and `entries_in_clip_words` take. The caller owns the result.
*>
fn AnimKeyframe keyed_bones(RigView* view, rig::Pose pose, bool[] turned, float time)
{
	Vec3[] bones = view.skeleton.bone_directions(mem);
	defer if (bones.len > 0) alloc::free(mem, bones);
	AnimKeyframe every = keyframe_of_pose(mem, pose, view.names, bones, view.skeleton.height(), time);

	AnimDotList kept;
	kept.init(mem);
	defer kept.free();
	foreach (dot : every.dots)
	{
		bool keep;
		foreach (usz j, name : view.names)
		{
			if (name != dot.joint_name) continue;
			keep = j < turned.len && turned[j];
			break;
		}
		if (keep) { kept.push(dot); }
		else if (dot.joint_name.len > 0) { alloc::free(mem, dot.joint_name.ptr); }
	}
	if (every.dots.len > 0) alloc::free(mem, every.dots);
	return { .time = time, .dots = kept.to_array(mem) };
}
