<*
 patch_clip: change a few joints of a clip over a range, without rewriting it.

 The recommendation this answers (animation_plan.md, MCP3) is that lowering the
 hands should be a small arm edit, not a whole new clip. apply_clip writes a clip
 from nothing: to move one joint a person must send back every keyframe of every
 other joint unchanged, and one dropped track is a silent regression. So this is
 the additive counterpart — an offset composed onto the joints named, over the
 range named, and every other track, every other channel and the grounding left
 exactly as they were.

 ## What "additive" and "over a range" mean here

 An offset is composed onto the joint's *existing* value at each of its keys,
 rather than replacing it: a rotation turns the joint further from where the clip
 already had it, a move slides it further. The value it composes onto is read from
 the source clip (`entry_at`), so the offsets of one call are independent of each
 other and of the order they are applied in — the same reason `plant_feet`
 computes against the source.

 A range is a span of the cycle. Over the whole clip the offset is uniform: every
 key of the named joint is turned by the same amount. Over a sub-range it is a
 plateau — held at full offset from `start` to `end`, keyed at the range's two
 edges so the transition into it happens in the clip's own interpolation between
 the edge and the neighbouring key outside, and nothing beyond the range moves. A
 joint sparse within the range still gets the edit, because the edges are keyed
 whether or not the joint had a key there; a joint keyed inside the range keeps
 those keys, offset, so the plateau does not sag between them.

 ## Coordinate space

 `local` (the default) states the offset in the joint's parent frame — the frame
 the clip already stores the joint in, so it composes with no rig at all. `world`
 states it against the model's own axes whatever the chain above is doing, which
 is what "tilt the forearm down" means when the shoulder is already rolled; it
 needs the rig, to read where the parent points. It is the same `local`/`world`
 distinction a keyframe entry's `space` draws in apply_clip, and the `turning`
 doc topic explains the trap it exists for.

 ## It lands as one undo step

 Like apply_clip and plant_feet, the rewritten clip is authored in one commit, so
 a patch is one Ctrl+Z. What it does not do: resample a channel a joint does not
 key (a rotation-only patch never invents a translation key), retime, or touch the
 ground spec — those are apply_clip's and plant_feet's jobs.
*>
module crig;

import rig;
import std::collections::object;
import std::math;
import std::math::matrix;
import std::math::quaternion;

faultdef PATCH_REFUSED;

// The most joints one call offsets. A patch is meant to be a few tracks; a call
// that names a whole biped is almost certainly a clip apply_clip should write.
const usz PATCH_JOINTS_MOST @local = 64;

const String PATCH_CLIP_SCHEMA = `{"type":"object","properties":{
	"clip":{"type":"string","description":"The clip to patch. get_scene lists every pack and clip; get_clip reads one back in the shape apply_clip takes."},
	"range":{"type":"object","description":"The span of the cycle to offset over. Omit for the whole clip, where the offset is uniform. A sub-range holds the offset at full value from start to end and eases it in and out through the clip's own interpolation in the gaps just outside; nothing beyond the range moves.","properties":{
		"phase":{"type":"array","items":{"type":"number"},"description":"[start,end] as fractions of the cycle, 0 to 1, start before end. Phase, not seconds, so it survives retiming."},
		"time":{"type":"array","items":{"type":"number"},"description":"[start,end] in seconds, start before end, within the clip's duration."}
	}},
	"joints":{"type":"array","description":"The joints to offset, each an object. A joint keys a rotation offset, a move offset, or both.","items":{"type":"object","properties":{
		"name":{"type":"string","description":"The dot this offset turns. It must be one the clip's rig carries."},
		"rotation":{"description":"An additive turn composed onto the joint's existing rotation: a quaternion {\"x\",\"y\",\"z\",\"w\"}, an axis and angle {\"axis\":[x,y,z],\"angle\":radians}, or three euler radians [x,y,z] turned about the axes of the frame space names, X then Y then Z."},
		"move":{"type":"array","items":{"type":"number"},"description":"An additive slide [x,y,z] added to the joint's existing offset, as a fraction of rig height, not model units."},
		"space":{"type":"string","description":"\"local\" (the default) states the offset in the joint's parent frame, the frame the clip stores it in. \"world\" states it against the model's own axes whatever the joints above are doing, and needs the rig to convert. Same distinction as a keyframe entry's space in apply_clip."}
	},"required":["name"]}}
},"required":["clip","joints"]}`;

// One joint to offset, resolved against the clip's rig.
struct PatchJoint @local
{
	String name;
	sz joint;              // skeleton index, -1 until resolved; only read for world space
	bool has_rotation;
	Quaternionf rotation;  // the additive turn
	bool has_move;
	Vec3 move;             // the additive slide, fraction of height
	bool world;            // space: false = parent frame (local), true = model frame
	usz rot_keys;          // how many rotation keys this joint's patch touched
	usz move_keys;
}

<*
 patch_clip: compose an offset onto the named joints over the range, and land it.

 @return? PATCH_REFUSED : `The reason is in detail.`
*>
fn String? patch_clip_json(AppState* app, Object* args, DString* detail)
{
	if (!takes_object(args, detail, `patch_clip takes an object: {"clip": name, "range": {"phase":[a,b]} or {"time":[a,b]}, "joints": [{"name": dot, "rotation": ..., "move": [x,y,z], "space": "local"|"world"}]}`)) return PATCH_REFUSED~;

	String clip_name;
	if (!required_string(args, "clip", &clip_name, detail, `patch_clip needs "clip": the name of the clip to offset. get_scene lists every pack and clip.`)) return PATCH_REFUSED~;

	Object* joints_arg = member(args, "joints");
	if (joints_arg == null || !joints_arg.is_array() || joints_arg.get_len() == 0)
	{
		detail.append_string(`patch_clip needs "joints": a non-empty array of {"name": dot, "rotation": ..., "move": [x,y,z]}. An offset with neither a rotation nor a move changes nothing.`);
		return PATCH_REFUSED~;
	}

	AnimRef ref = resolve_named(app, clip_name, detail)!;
	AnimTemplate* src = app.clip(ref);
	if (src == null)
	{
		detail.append_string(`this clip could not be read back to offset.`);
		return PATCH_REFUSED~;
	}
	float duration = src.duration;
	if (duration <= 0.0f)
	{
		detail.append_string(`this clip has no duration, so it has no range to offset over.`);
		return PATCH_REFUSED~;
	}

	// The range, in seconds. Omitted is the whole clip.
	float start = 0.0f;
	float end = duration;
	if (!parse_range(member(args, "range"), duration, &start, &end, detail)) return PATCH_REFUSED~;
	bool whole = start <= ANIM_SAME_TIME && end >= duration - ANIM_SAME_TIME;

	// The joints, each with its offset and space. A world-space joint means the rig
	// has to be opened to read where its parent points.
	usz jcount = (usz)joints_arg.get_len();
	if (jcount > PATCH_JOINTS_MOST)
	{
		detail.appendf(`patch_clip offsets at most %d joints in one call; this names %d. A change that broad is a clip apply_clip should write.`, PATCH_JOINTS_MOST, jcount);
		return PATCH_REFUSED~;
	}
	PatchJoint[PATCH_JOINTS_MOST] joints;
	usz jn = 0;
	bool needs_rig = false;
	for (usz i = 0; i < jcount; i++)
	{
		Object* entry = joints_arg.get_at((sz)i);
		if (!entry.is_keyable())
		{
			detail.appendf(`joints[%d] must be an object: {"name": dot, "rotation": ..., "move": [x,y,z]}`, i);
			return PATCH_REFUSED~;
		}

		String? given = entry.get_string("name");
		if (catch given)
		{
			detail.appendf(`joints[%d] needs "name": the dot this offset turns`, i);
			return PATCH_REFUSED~;
		}
		String name = given;
		if (!app.has_dot_named(name))
		{
			detail.appendf(`joints[%d].name is "%s", which is not a dot on this rig`, i, name);
			append_addressable(detail, app, name);
			return PATCH_REFUSED~;
		}
		for (usz e = 0; e < jn; e++)
		{
			if (joints[e].name != name) continue;
			detail.appendf(`joints[%d] names "%s" again. Give a joint one offset: state the whole turn or slide once.`, i, name);
			return PATCH_REFUSED~;
		}

		PatchJoint pj = { .name = name, .joint = -1 };

		Object* rotation = member(entry, "rotation");
		if (rotation != null)
		{
			Vec3 axis;
			float angle;
			if (!rotation_from(rotation, &axis, &angle))
			{
				detail.appendf(
					`joints[%d].rotation must be a quaternion {"x","y","z","w"}, an axis and an angle {"axis":[x,y,z],"angle":radians}, or three euler radians [x,y,z]`,
					i);
				return PATCH_REFUSED~;
			}
			pj.has_rotation = true;
			pj.rotation = quaternion::from_axis_angle{float}(axis, angle);
		}

		Object* slide = member(entry, "move");
		if (slide != null)
		{
			if (!as_vec3(slide, &pj.move))
			{
				detail.appendf(`joints[%d].move must be [x,y,z] as a fraction of rig height, not model units`, i);
				return PATCH_REFUSED~;
			}
			pj.has_move = true;
		}

		if (!pj.has_rotation && !pj.has_move)
		{
			detail.appendf(`joints[%d] needs a "rotation" or a "move" to offset by. An entry with neither changes nothing.`, i);
			return PATCH_REFUSED~;
		}

		if (member(entry, "space") != null)
		{
			String? space = entry.get_string("space");
			if (catch space)
			{
				detail.appendf(`joints[%d].space must be the string "local" or "world"`, i);
				return PATCH_REFUSED~;
			}
			switch (space)
			{
				case "local": pj.world = false;
				case "world": pj.world = true;
				default:
					detail.appendf(
						`joints[%d].space is "%s". It is "local" — the joint's parent frame, the frame the clip stores it in, which is the default — or "world", the model's own axes whatever the joints above are doing.`,
						i, space);
					return PATCH_REFUSED~;
			}
		}
		if (pj.world) needs_rig = true;

		joints[jn++] = pj;
	}

	// World space reads where each named joint's parent points, so the rig is
	// opened once when any joint asks for it, and its hierarchy resolves the indices.
	RigView view = {};
	bool rig_open = false;
	defer if (rig_open) view.free(mem);
	if (needs_rig)
	{
		RigView? opened = app.open_rig(mem);
		if (catch opened)
		{
			detail.append_string(`a joint asked for "space":"world", which is measured against the rig's own hierarchy — and this document has no rig to measure against. Offset in "local" space, or fit a rig first.`);
			return PATCH_REFUSED~;
		}
		view = opened;
		rig_open = true;
		for (usz i = 0; i < jn; i++)
		{
			if (!joints[i].world) continue;
			joints[i].joint = view.joint_of(app.dot_named(joints[i].name).id);
		}
	}

	// Where a key is placed, so the offset lands as a plateau bounded by the range.
	// Over the whole clip, every key of the joint's channel; over a sub-range, the
	// joint's own keys inside it and the two edges — an edge keyed whether or not
	// the joint had one there, so a joint sparse in the range still gets the edit.
	AnimFloatList times;
	times.init(mem);
	defer times.free();
	if (!whole)
	{
		push_unique(&times, start);
		push_unique(&times, end);
	}
	for (usz i = 0; i < jn; i++)
	{
		PatchJoint* pj = &joints[i];
		if (pj.has_rotation) collect_channel_times(src, pj.name, true, start, end, whole, &times);
		if (pj.has_move) collect_channel_times(src, pj.name, false, start, end, whole, &times);
	}

	// The bake: at each key time, offset each joint whose channel belongs there, and
	// fold the resulting sparse keyframe into a growing copy of the clip. Every value
	// is read from the source, so folds are independent and their order does not
	// matter — clip_with_key merges each onto the key already at that instant.
	AnimTemplate current;
	bool have = false;
	usz folds = 0;
	foreach (t : times.array_view())
	{
		bool is_edge = !whole
			&& (math::abs(t - start) < ANIM_SAME_TIME || math::abs(t - end) < ANIM_SAME_TIME);

		AnimDotList dots;
		dots.init(mem);
		for (usz i = 0; i < jn; i++)
		{
			PatchJoint* pj = &joints[i];
			bool rot = pj.has_rotation && channel_keyed_here(src, pj.name, true, t, is_edge, whole, start);
			bool mov = pj.has_move && channel_keyed_here(src, pj.name, false, t, is_edge, whole, start);
			if (!rot && !mov) continue;

			AnimKeyDot base = src.entry_at(pj.name, t);
			AnimKeyDot out = {
				.joint_name = pj.name.copy(mem),
				.axis = base.axis,
				.angle = base.angle,
				.move = base.move,
				.bone = base.bone,
			};

			// The parent's world orientation, shared by both channels of a world
			// offset, read from the source clip up the hierarchy.
			Quaternionf parent_world = quaternion::IDENTITY;
			if (pj.world) parent_world = parent_world_at(src, &view, pj.joint, t);

			if (rot)
			{
				Quaternionf held = quaternion::from_axis_angle{float}(base.axis, base.angle);
				Quaternionf turned = pj.world
					? parent_world.invert().mul(pj.rotation).mul(parent_world).mul(held).normalize()
					: pj.rotation.mul(held).normalize();
				axis_angle_of(turned, &out.axis, &out.angle);
				out.rotation_interpolation = INHERIT;
				pj.rot_keys++;
			}
			if (mov)
			{
				Vec3 delta = pj.world ? parent_world.invert().rotate_vec3(pj.move) : pj.move;
				out.move = base.move + delta;
				out.translation_interpolation = INHERIT;
				pj.move_keys++;
			}
			out.channels = rot ? (mov ? BOTH : ROTATION) : TRANSLATION;
			dots.push(out);
		}

		if (dots.len() == 0)
		{
			dots.free();
			continue;
		}
		AnimKeyframe key = { .time = t, .dots = dots.to_array(mem) };
		dots.free();

		if (!have)
		{
			current = clip_with_key(mem, *src, key);
			have = true;
		}
		else
		{
			AnimTemplate next = clip_with_key(mem, current, key);
			current.free(mem);
			current = next;
		}
		folds++;
	}

	// Nothing was in range for any named joint: report it against the range and
	// leave the clip alone.
	if (!have)
	{
		return patch_report(app, clip_name, start, end, duration, whole, joints[:jn], 0, ref, false, false);
	}

	bool replaced;
	AnimRef landed = app.author_clip(current, &replaced);
	app.refresh_ui();
	return patch_report(app, clip_name, start, end, duration, whole, joints[:jn], folds, landed, replaced, true);
}

// The range argument as a pair of seconds. Omitted (null) leaves the whole-clip
// span the caller passed in. Phase and seconds are the two spellings; naming both,
// or a pair that is not increasing or is out of bounds, is refused by name.
fn bool parse_range(Object* range, float duration, float* start, float* end, DString* detail) @local
{
	if (range == null) return true;
	if (!range.is_keyable())
	{
		detail.append_string(`"range" must be an object: {"phase":[a,b]} as fractions 0 to 1, or {"time":[a,b]} in seconds. Omit it for the whole clip.`);
		return false;
	}

	Object* phase = member(range, "phase");
	Object* time = member(range, "time");
	if (phase != null && time != null)
	{
		detail.append_string(`"range" takes "phase" or "time", not both: phase is a fraction of the cycle and time is seconds. Give one.`);
		return false;
	}
	if (phase == null && time == null)
	{
		detail.append_string(`"range" needs "phase":[a,b] (fractions 0 to 1) or "time":[a,b] (seconds). Omit "range" for the whole clip.`);
		return false;
	}

	Object* pair = phase != null ? phase : time;
	if (!pair.is_array() || pair.get_len() != 2)
	{
		detail.append_string(phase != null
			? `"range".phase must be [start,end] as two fractions of the cycle, 0 to 1.`
			: `"range".time must be [start,end] as two times in seconds.`);
		return false;
	}
	double? a = pair.get_float_at(0);
	double? b = pair.get_float_at(1);
	if (catch a, b)
	{
		detail.append_string(`"range" bounds must be two numbers, start before end.`);
		return false;
	}

	if (phase != null)
	{
		if (a < 0 || b > 1 || a >= b)
		{
			detail.appendf(`"range".phase is [%.9g,%.9g]. It is [start,end] with 0 <= start < end <= 1.`, a, b);
			return false;
		}
		*start = (float)a * duration;
		*end = (float)b * duration;
		return true;
	}

	if (a < 0 || b > (double)duration || a >= b)
	{
		detail.appendf(`"range".time is [%.9g,%.9g] against a duration of %.9g. It is [start,end] with 0 <= start < end <= duration.`, a, b, duration);
		return false;
	}
	*start = (float)a;
	*end = (float)b;
	return true;
}

// Add the times where this joint keys this channel within the range: every one
// over the whole clip, the interior ones (edges are added separately) over a
// sub-range. A channel the joint never keys at all gets a key at `start`, so a
// whole-clip offset on an otherwise-unmoved joint is still expressed.
fn void collect_channel_times(AnimTemplate* src, String name, bool rotation,
	float start, float end, bool whole, AnimFloatList* into) @local
{
	foreach (frame : src.keyframes)
	{
		float t = frame.time;
		bool inside = whole
			? true
			: (t > start + ANIM_SAME_TIME && t < end - ANIM_SAME_TIME);
		if (!inside) continue;
		AnimKeyDot ignored;
		if (frame.channel_dot(name, rotation, &ignored)) push_unique(into, t);
	}
	if (whole && src.channel_count(name, rotation) == 0) push_unique(into, start);
}

// Whether this joint's channel should be keyed at this instant: an edge always,
// an instant the joint already keys the channel at, or — for a whole-clip offset
// on a channel the joint never keys — the single fallback key at `start`.
fn bool channel_keyed_here(AnimTemplate* src, String name, bool rotation,
	float t, bool is_edge, bool whole, float start) @local
{
	if (is_edge) return true;
	foreach (frame : src.keyframes)
	{
		if (math::abs(frame.time - t) >= ANIM_SAME_TIME) continue;
		AnimKeyDot ignored;
		return frame.channel_dot(name, rotation, &ignored);
	}
	// The fallback key an unkeyed channel got in collect_channel_times.
	return whole && math::abs(t - start) < ANIM_SAME_TIME && src.channel_count(name, rotation) == 0;
}

// A joint's parent's world orientation at `time`, read from the clip's own
// rotations up the hierarchy. The skeleton supplies the parent chain and the
// names; the turns are the clip's. Shared with apply_clip's world-space keys.
fn Quaternionf parent_world_at(AnimTemplate* clip, RigView* view, sz joint, float time)
{
	Quaternionf world = quaternion::IDENTITY;
	if (joint < 0) return world;
	int parent = view.skeleton.parents[joint];
	while (parent >= 0)
	{
		String name = (usz)parent < view.names.len ? view.names[(usz)parent] : "";
		Quaternionf local = clip.rotation_at(name, time);
		world = local.mul(world).normalize();
		parent = view.skeleton.parents[(usz)parent];
	}
	return world;
}

// A time added to the list only if no near-equal one is there, so the joints'
// key sets and the range edges union into one set of distinct instants.
fn void push_unique(AnimFloatList* list, float t) @local
{
	foreach (held : list.array_view()) if (math::abs(held - t) < ANIM_SAME_TIME) return;
	list.push(t);
}

// The answer: the range as both phase and seconds, per joint how many keys the
// offset touched, and where the clip landed. `landed`/`replaced` are read only
// when `did_land`.
fn String patch_report(AppState* app, String clip_name, float start, float end, float duration,
	bool whole, PatchJoint[] joints, usz keys, AnimRef landed, bool replaced, bool did_land) @local
{
	DString out = dstring::new(mem);
	defer out.free();

	out.append_string(`{"clip":"`);
	json_escape_into(&out, clip_name);
	out.appendf(`","range":{"time":[%s,%s],"phase":[%s,%s],"whole":%s}`,
		(JsonFloat)start, (JsonFloat)end,
		(JsonFloat)(duration > 0.0f ? start / duration : 0.0f),
		(JsonFloat)(duration > 0.0f ? end / duration : 0.0f),
		whole ? "true" : "false");

	out.append_string(`,"joints":[`);
	foreach (ji, pj : joints)
	{
		if (ji > 0) out.append_char(',');
		out.append_string(`{"joint":"`);
		json_escape_into(&out, pj.name);
		out.appendf(`","space":"%s","rotation_keys":%d,"move_keys":%d`,
			pj.world ? "world" : "local", pj.rot_keys, pj.move_keys);
		if (pj.rot_keys == 0 && pj.move_keys == 0)
		{
			out.append_string(`,"note":"no key of this joint fell in the range"`);
		}
		out.append_char('}');
	}
	out.appendf(`],"keys_written":%d`, keys);

	if (did_land)
	{
		String applied = applied_json(app, landed, replaced);
		defer alloc::free(mem, applied);
		out.append_string(`,"landed":`);
		out.append_string(applied);
	}
	else
	{
		out.append_string(`,"landed":null,"note":"nothing in the range was keyed by the named joints, so the clip is unchanged. Widen the range, or name a joint the clip drives."`);
	}
	out.append_char('}');
	return out.copy_str(mem);
}
