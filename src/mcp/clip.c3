<*
 apply_clip: the JSON an agent sends, turned into a template the library holds.

 The wire format is the agent's rather than the file's. A rotation arrives as a
 quaternion, as an axis and an angle, or as three euler radians, and all three
 carry exactly into the single axis and angle an `AnimKeyDot` stores — which is
 why a clip written here can hold a compound turn that could not have been typed
 into one by hand.

 Everything refused here is refused with a sentence naming the value and saying
 what would have been taken instead. That is the point of the file as much as
 the parsing is: an agent cannot see the rig, so a rejection that does not say
 which joint or which keyframe costs it a whole turn to guess at.

 Nothing here reaches into the library. `parse_clip` allocates a template and
 hands it over; `AppState.put_authored_clip` is what takes ownership.
*>
module crig;

import rig;
import std::collections::object;

import std::math;
import std::math::quaternion;

// Every refusal in this file. Declared here rather than beside the registry,
// because every one of them is raised by the parsing below and by nothing else.
faultdef CLIP_INVALID;

<*
 Read apply_clip's argument object as a template.

 	`AnimTemplate clip = parse_clip(app, args, &detail)!;`

 The result is allocated from `mem` with `owned` set, so the caller must either
 hand it to `AppState.put_authored_clip` or free it. Nothing is allocated on the
 fault path.

 Every joint name is checked against the document, and an unknown one is
 refused rather than dropped: a clip that quietly loses the joint it was
 supposed to turn plays, moves nothing, and gives an agent nothing to go on.
 Keyframe times must increase, because `AnimTemplate.pose` reads them in order.

 @param detail : `Filled with what was wrong and what would have been accepted, when this faults.`
 @param fallback_duration : `What a clip with no length of its own (one key at time zero, no "duration") is given instead of a refusal. A layer's keys are read through here and have none of their own.`
 @return? CLIP_INVALID : `Not a clip this rig can play. The reason is in detail.`
*>
fn AnimTemplate? parse_clip(AppState* app, Object* args, DString* detail, float fallback_duration = 0.0f)
{
	if (!takes_object(args, detail, `apply_clip takes an object: {"name": string, "keyframes": [{"time": seconds, "joints": [{"name": dot, "rotation": ..., "move": [x,y,z]}]}], "duration": seconds, "loop": bool}`)) return CLIP_INVALID~;

	String name;
	if (!required_string(args, "name", &name, detail, `apply_clip needs "name": a string, and the handle every later call uses for this clip. A clip of that name in the authored pack is replaced.`)) return CLIP_INVALID~;
	if (name.len == 0)
	{
		detail.append_string(`"name" is empty. A clip is addressed by name, so it needs one that is not.`);
		return CLIP_INVALID~;
	}

	Object* frames = member(args, "keyframes");
	if (frames == null || !frames.is_array() || frames.get_len() == 0)
	{
		detail.append_string(`apply_clip needs "keyframes": a non-empty array, each {"time": seconds, "joints": [...]}. An empty joints array adds no channel keys; use explicit identity rotation or zero move to key rest.`);
		return CLIP_INVALID~;
	}
	usz count = (usz)frames.get_len();

	AnimTemplate clip = {
		.name = name.copy(mem),
		.keyframes = alloc::new_array(mem, AnimKeyframe, (sz)count),
		.owned = true,
	};

	// Every path out below this line is a fault, and each one leaves the template
	// part-built. A zeroed keyframe holds no dots and a zeroed dot holds no name,
	// which is exactly what `AnimTemplate.free` walks past.
	bool complete = false;
	defer
	{
		if (!complete) clip.free(mem);
	}

	// Opened only if an entry asks for world space, and then only once. Building
	// the view walks the whole document, and most clips never need it — a turn
	// against the parent is a statement about two joints, not about the rig.
	RigView view = {};
	bool rig_open = false;
	bool[][] world_flags = alloc::new_array(mem, bool[], (sz)count);
	defer
	{
		if (rig_open) view.free(mem);
		foreach (flags : world_flags) if (flags.len > 0) alloc::free(mem, flags);
		alloc::free(mem, world_flags);
	}

	float last = 0;
	for (usz f = 0; f < count; f++)
	{
		Object* frame = frames.get_at((sz)f);
		if (!frame.is_keyable())
		{
			detail.appendf(`keyframes[%d] must be an object: {"time": seconds, "joints": [...]}`, f);
			return CLIP_INVALID~;
		}

		// A time that is missing, null or not a number and one that is negative are
		// the same refusal, since the sentence below answers both.
		double time = frame.get_float("time") ?? -1.0;
		if (time < 0)
		{
			detail.appendf(`keyframes[%d] needs "time": seconds from the start of the clip, zero or more`, f);
			return CLIP_INVALID~;
		}
		if (f > 0 && (float)time <= last)
		{
			detail.appendf(
				"keyframes[%d].time is %.9g, which is not later than keyframes[%d].time (%.9g). A clip is sampled between the pair of keyframes the clock falls in, so they have to be given in increasing time order.",
				f, time, f - 1, last);
			return CLIP_INVALID~;
		}
		last = (float)time;
		clip.keyframes[f].time = last;

		Object* joints = member(frame, "joints");
		if (joints == null) continue;
		if (!joints.is_indexable())
		{
			detail.appendf(`keyframes[%d].joints must be an array of {"name": dot, "rotation": ..., "move": [x,y,z]}`, f);
			return CLIP_INVALID~;
		}

		usz entries = joints.is_array() ? (usz)joints.get_len() : 0;
		if (entries == 0) continue;

		clip.keyframes[f].dots = alloc::new_array(mem, AnimKeyDot, (sz)entries);

		// Which entries stated an orientation against the model's own axes rather
		// than a turn against the parent. Kept beside the dots rather than on them:
		// it is a fact about how this call was written, and nothing past
		// `to_parent_frame` below has any use for it.
		bool[] in_world = alloc::new_array(mem, bool, (sz)entries);
		world_flags[f] = in_world;

		for (usz d = 0; d < entries; d++)
		{
			Object* entry = joints.get_at((sz)d);
			if (!entry.is_keyable())
			{
				detail.appendf(`keyframes[%d].joints[%d] must be an object with a "name"`, f, d);
				return CLIP_INVALID~;
			}

			String? given_joint = entry.get_string("name");
			if (catch given_joint)
			{
				detail.appendf(`keyframes[%d].joints[%d] needs "name": the dot this entry turns`, f, d);
				return CLIP_INVALID~;
			}
			String joint = given_joint;

			if (!app.has_dot_named(joint))
			{
				detail.appendf(`keyframes[%d].joints[%d].name is "%s", which is not a dot on this rig`, f, d, joint);
				append_addressable(detail, app, joint);
				return CLIP_INVALID~;
			}
			for (usz e = 0; e < d; e++)
			{
				if (clip.keyframes[f].dots[e].joint_name != joint) continue;
				detail.appendf(
					`keyframes[%d] names "%s" twice, at joints[%d] and joints[%d]. One instant gives a joint one rotation and one slide; two entries have no defined order.`,
					f, joint, e, d);
				return CLIP_INVALID~;
			}

			Vec3 axis;
			float angle;
			if (!rotation_from(member(entry, "rotation"), &axis, &angle))
			{
				detail.appendf(
					`keyframes[%d].joints[%d].rotation must be a quaternion {"x","y","z","w"}, an axis and an angle {"axis":[x,y,z],"angle":radians}, or three euler radians [x,y,z] turned about the world axes in X, then Y, then Z order. Leave it out for no rotation.`,
					f, d);
				return CLIP_INVALID~;
			}

			Vec3 move = {};
			Object* slide = member(entry, "move");
			bool has_rotation = member(entry, "rotation") != null;
			if (!has_rotation && slide == null)
			{
				detail.appendf(`keyframes[%d].joints[%d] needs rotation or move; write identity/zero explicitly to key rest.`, f, d);
				return CLIP_INVALID~;
			}
			if (slide != null && !as_vec3(slide, &move))
			{
				detail.appendf(
					`keyframes[%d].joints[%d].move must be [x,y,z] as a fraction of rig height, not in model units — see get_api_docs`,
					f, d);
				return CLIP_INVALID~;
			}

			AnimInterpolation rotation_interpolation;
			AnimInterpolation translation_interpolation;
			Object* rotation_mode = member(entry, "rotation_interpolation");
			if (rotation_mode != null)
			{
				String? value = entry.get_string("rotation_interpolation");
				if (catch value)
				{
					detail.appendf(`keyframes[%d].joints[%d].rotation_interpolation must be "hold", "linear" or "auto", and needs a rotation key in the same entry.`, f, d);
					return CLIP_INVALID~;
				}
				if (!has_rotation || !parse_anim_interpolation(value, &rotation_interpolation))
				{
					detail.appendf(`keyframes[%d].joints[%d].rotation_interpolation must be "hold", "linear" or "auto", and needs a rotation key in the same entry.`, f, d);
					return CLIP_INVALID~;
				}
			}
			Object* translation_mode = member(entry, "translation_interpolation");
			if (translation_mode != null)
			{
				String? value = entry.get_string("translation_interpolation");
				if (catch value)
				{
					detail.appendf(`keyframes[%d].joints[%d].translation_interpolation must be "hold", "linear" or "auto", and needs a move key in the same entry.`, f, d);
					return CLIP_INVALID~;
				}
				if (slide == null || !parse_anim_interpolation(value, &translation_interpolation))
				{
					detail.appendf(`keyframes[%d].joints[%d].translation_interpolation must be "hold", "linear" or "auto", and needs a move key in the same entry.`, f, d);
					return CLIP_INVALID~;
				}
			}

			if (member(entry, "space") != null)
			{
				String? space = entry.get_string("space");
				if (catch space)
				{
					detail.appendf(`keyframes[%d].joints[%d].space must be the string "local" or "world"`, f, d);
					return CLIP_INVALID~;
				}
				switch (space)
				{
					// Spelled out rather than left empty: an empty case falls
					// through to the next, which would read "local" as world.
					case "local": in_world[d] = false;
					case "world": in_world[d] = true;
					default:
						detail.appendf(
							`keyframes[%d].joints[%d].space is "%s". It is "local" — measured against the parent as this clip has it posed, which is the default — or "world", the joint's orientation against the model's own axes whatever the joints above it are doing.`,
							f, d, space);
						return CLIP_INVALID~;
				}
			}

			// `bone` defaults to zero, which means "do not retarget": a clip
			// authored here was written against the rig it is about to play on, so
			// there is no other rig's bone direction to carry its motion off — see
			// `AnimKeyDot.bone`.
			//
			// It can be given, and `get_clip` gives it. Without that a clip read
			// out and written back would come home with its retargeting stripped —
			// silently, and on exactly the clips that need it, since an imported
			// clip is the one carrying somebody else's bone directions. A
			// round trip that quietly changes what a clip means is worse than one
			// that refuses.
			Vec3 bone = {};
			Object* carried = member(entry, "bone");
			if (carried != null && !as_vec3(carried, &bone))
			{
				detail.appendf(
					`keyframes[%d].joints[%d].bone must be [x,y,z] — the direction this joint's bone pointed on the rig the clip was authored against. Leave it out unless you are writing back a clip get_clip gave you.`,
					f, d);
				return CLIP_INVALID~;
			}

			clip.keyframes[f].dots[d] = {
				.joint_name = joint.copy(mem),
				.axis = axis,
				.angle = angle,
				.move = move,
				.bone = bone,
				.channels = has_rotation ? (slide != null ? BOTH : ROTATION) : TRANSLATION,
				.rotation_interpolation = rotation_interpolation,
				.translation_interpolation = translation_interpolation,
			};
		}

		// A world entry is an absolute statement and the format holds turns against
		// the parent, so it has to be converted — and only here, once the keyframe
		// is whole, because a joint's world orientation is not knowable until every
		// entry above it in the chain has been read.
		usz absolute = 0;
		foreach (flag : in_world)
		{
			if (flag) absolute++;
		}
		if (absolute > 0)
		{
			if (!rig_open)
			{
				RigView? opened = app.open_rig(mem);
				if (catch opened)
				{
					detail.append_string(`a joint asked for "space":"world", which is measured against the rig's own hierarchy — and this document has no rig to measure against.`);
					return CLIP_INVALID~;
				}
				view = opened;
				rig_open = true;
			}
		}
	}

	double duration = last;
	// Asked through `member` first, because absent and null both mean "as long as
	// the keyframes" while a string there is a mistake worth naming.
	if (member(args, "duration") != null)
	{
		double? given = args.get_float("duration");
		if (catch given)
		{
			detail.append_string(`"duration" must be a number: how long the clip runs, in seconds`);
			return CLIP_INVALID~;
		}
		duration = given;
	}
	if (duration <= 0 && fallback_duration > 0.0f) duration = fallback_duration;
	if (duration <= 0)
	{
		detail.appendf(
			`duration comes out as %.9g. A clip with no length has no instant to show and the player stops on one — give a "duration", or a last keyframe later than zero.`,
			duration);
		return CLIP_INVALID~;
	}
	if ((float)duration < last)
	{
		detail.appendf(
			"duration is %.9g but the last keyframe is at %.9g, which the clock never reaches. Lengthen the clip or drop the keyframe.",
			duration, last);
		return CLIP_INVALID~;
	}
	clip.duration = (float)duration;

	if (try loop = args.get_bool("loop")) clip.loop = loop;

	if (member(args, "blend") != null)
	{
		String? blend = args.get_string("blend");
		if (catch blend)
		{
			detail.append_string(`"blend" must be "linear" or "smooth"`);
			return CLIP_INVALID~;
		}
		switch (blend)
		{
			case "linear": clip.blend = LINEAR;
			case "smooth": clip.blend = SMOOTH;
			default:
				detail.appendf(
					`"blend" is "%s". It is "linear" — straight between the keyframes, the default — or "smooth", a cubic through them that wraps through the loop point on a looping clip.`,
					blend);
				return CLIP_INVALID~;
		}
	}

	if (!parse_ground(app, member(args, "ground"), &clip.ground, detail)) return CLIP_INVALID~;
	if (rig_open) sparse_to_parent_frame(&view, &clip, world_flags);
	if (!apply_root_pivots(app, args, &clip, detail)) return CLIP_INVALID~;

	// Last, so the mirrored side is filled from the finished clip — its ground
	// windows included.
	Object* mirror = member(args, "mirror");
	if (mirror != null)
	{
		if (!mirror.is_keyable())
		{
			detail.append_string(`"mirror" must be an object: {"phase": how much of the cycle the other side lags by, 0 to 1}. Leave it out to write both sides yourself.`);
			return CLIP_INVALID~;
		}
		double phase = mirror.get_float("phase") ?? 0.5;
		if (phase < 0 || phase > 1)
		{
			detail.appendf(
				`"mirror".phase is %.9g. It is a fraction of the cycle, 0 to 1; half is a walk or a run.`, phase);
			return CLIP_INVALID~;
		}

		AnimTemplate both = mirror_template(mem, clip, name, (float)phase);
		clip.free(mem);
		clip = both;
	}

	// Layers are the clip's, not the keys': stated, they replace the stack (an
	// empty list clears it); left out, the clip of this name already in the
	// authored pack keeps its own, so rewriting the base keys does not quietly
	// drop an adjustment laid over them.
	Object* layers = member(args, "layers");
	if (layers != null)
	{
		if (!parse_layers(app, layers, clip.duration, &clip.layers, detail)) return CLIP_INVALID~;
	}
	// The look-at targets are not stated here (`set_aim` owns them), so rewriting
	// the keys of a clip keeps the ones the clip of this name already has.
	AnimPack* authored = app.authored();
	if (authored) foreach (held : authored.clips)
	{
		if (held.name != name) continue;
		if (layers == null) clip.layers = layers_copy(mem, held.layers);
		free_aims(mem, clip.aims);
		clip.aims = aims_copy(mem, held.aims);
		free_aim_targets(mem, clip.aim_targets);
		clip.aim_targets = aim_targets_copy(mem, held.aim_targets);
		free_pins(mem, clip.pins);
		clip.pins = pins_copy(mem, held.pins);
		break;
	}

	complete = true;
	return clip;
}

<*
 apply_clip's `ground`, as the spec a clip stores.

 A foot naming no dot on this rig is refused rather than dropped, for the reason
 an unknown joint name in a keyframe is: a clip that quietly loses the foot it
 was supposed to plant plays, sinks, and gives an agent nothing to go on.

 @param into : `Filled on success, left alone otherwise. Allocated from mem, so the template that carries it must be owned.`
 @return `False when the spec was refused, with the reason in detail.`
*>
fn bool parse_ground(AppState* app, Object* ground, AnimGround* into, DString* detail) @local
{
	if (ground == null) return true;
	if (!ground.is_keyable())
	{
		detail.append_string(`"ground" must be an object: {"feet": [{"joint": dot, "down": phase, "up": phase}], "floor": model-space height}`);
		return false;
	}

	Object* feet = member(ground, "feet");
	if (feet == null || !feet.is_array() || feet.get_len() == 0)
	{
		detail.append_string(`"ground" needs "feet": a non-empty array of {"joint": dot, "down": phase, "up": phase}. Without one there is nothing to stand the figure on.`);
		return false;
	}

	usz count = (usz)feet.get_len();
	AnimFoot[] planted = alloc::new_array(mem, AnimFoot, (sz)count);
	bool complete = false;
	defer
	{
		if (!complete)
		{
			AnimGround scratch = { .feet = planted };
			scratch.free(mem);
		}
	}

	for (usz f = 0; f < count; f++)
	{
		Object* entry = feet.get_at((sz)f);
		if (!entry.is_keyable())
		{
			detail.appendf(`ground.feet[%d] must be an object: {"joint": dot, "down": phase, "up": phase}`, f);
			return false;
		}

		String? joint = entry.get_string("joint");
		if (catch joint)
		{
			detail.appendf(`ground.feet[%d] needs "joint": the dot that touches the floor`, f);
			return false;
		}
		if (!app.has_dot_named(joint))
		{
			detail.appendf(`ground.feet[%d].joint is "%s", which is not a dot on this rig`, f, joint);
			append_addressable(detail, app, joint);
			return false;
		}

		double down = entry.get_float("down") ?? 0.0;
		double up = entry.get_float("up") ?? 1.0;
		if (down < 0 || down > 1 || up < 0 || up > 1)
		{
			detail.appendf(
				`ground.feet[%d] is down from %.9g to %.9g. Both are cycle phase — a fraction of the duration, 0 to 1 — not seconds. A window whose end is at or below its start wraps through the loop point, which is what one foot of a gait always does.`,
				f, down, up);
			return false;
		}

		planted[f] = { .joint = joint.copy(mem), .down = (float)down, .up = (float)up };
	}

	*into = { .feet = planted };
	if (try double floor = ground.get_float("floor"))
	{
		into.floor = (float)floor;
		into.floor_set = true;
	}

	complete = true;
	return true;
}

<*
 What apply_clip answers with: where the clip landed, and what it can do there.

 `applies` is the answer to the question an agent asks next — whether the clip
 would actually move this rig — and it can be false on a clip that parsed, since
 a document with no dots accepts nothing to address.
*>
fn String applied_json(AppState* app, AnimRef ref, bool replaced)
{
	AnimTemplate* clip = app.clip(ref);
	AnimPack* pack = app.pack((usz)ref.pack);

	DString out = dstring::new(mem);
	defer out.free();

	out.append_string(`{"clip":"`);
	json_escape_into(&out, clip.name);
	out.append_string(`","qualified":"`);
	json_escape_into(&out, pack.name);
	out.append_char('/');
	json_escape_into(&out, clip.name);
	out.append_string(`","pack":"`);
	json_escape_into(&out, pack.name);
	out.appendf(`","ref":[%d,%d],"replaced":`, ref.pack, ref.clip);
	out.append_string(replaced ? "true" : "false");
	out.appendf(`,"duration":%s,"loop":`, (JsonFloat)clip.duration);
	out.append_string(clip.loop ? "true" : "false");
	out.append_string(`,"keyframes":`);
	out.appendf("%d", clip.keyframes.len);

	out.append_string(`,"joints":[`);
	usz written = 0;
	foreach (f, frame : clip.keyframes)
	{
		foreach (d, dot : frame.dots)
		{
			if (named_earlier(clip, f, d, dot.joint_name)) continue;
			if (written > 0) out.append_char(',');
			out.append_char('"');
			json_escape_into(&out, dot.joint_name);
			out.append_char('"');
			written++;
		}
	}
	out.append_string(`],"applies":`);
	out.append_string(app.clip_applies(ref) ? "true" : "false");
	out.append_string(`,"playing":`);
	out.append_string(app.animating && app.current_ref.same(ref) ? "true" : "false");
	out.append_char('}');

	return out.copy_str(mem);
}

<*
 An entry's `"pivot": joint`, for the root: turn about that joint, not the root.

 The root turns about its own point, so turning a whole figure about a shoulder,
 a foot or the head means working out the slide that makes it so. Here the root
 entry names the joint it should turn about, and the root's move is adjusted so
 that joint stays where it was — where the keyframe, without this turn, puts it.

 Runs on the finished clip, at each keyframe that asks, by sampling the pose the
 keyframe gives (its parent chain as the rest of the entries posed it, the root's
 move included) and reading how far the turn carried the pivot: with `d` the
 root-to-pivot vector in that pose and `R` the root's turn, the pivot sat at
 `R⁻¹d` from the root before the turn, so the root slides by `R⁻¹d - d`.

 `pivot` belongs to the root only, since every other joint's turn is against a
 parent that is itself moving; anything else is refused.

 @param args : `apply_clip's argument object, read again for the entries that carry a pivot.`
 @return `False when a pivot was refused, with the reason in detail.`
*>
fn bool apply_root_pivots(AppState* app, Object* args, AnimTemplate* clip, DString* detail) @local
{
	Object* frames = member(args, "keyframes");
	if (frames == null || !frames.is_array()) return true;

	RigView view = {};
	bool rig_open = false;
	defer if (rig_open) view.free(mem);

	for (usz f = 0; f < (usz)frames.get_len() && f < clip.keyframes.len; f++)
	{
		Object* joints = member(frames.get_at((sz)f), "joints");
		if (joints == null || !joints.is_array()) continue;
		for (usz d = 0; d < (usz)joints.get_len(); d++)
		{
			Object* entry = joints.get_at((sz)d);
			if (!entry.is_keyable() || member(entry, "pivot") == null) continue;

			String? named = entry.get_string("pivot");
			if (catch named)
			{
				detail.appendf(`keyframes[%d].joints[%d].pivot must be a joint name: the dot the root turns about`, f, d);
				return false;
			}
			String pivot = named;
			String joint = entry.get_string("name") ?? "";

			if (!rig_open)
			{
				RigView? opened = app.open_rig(mem);
				if (catch opened)
				{
					detail.append_string(`a joint asked for a "pivot", which is read against the rig's own joints — and this document has no rig.`);
					return false;
				}
				view = opened;
				rig_open = true;
			}

			usz root = 0;
			while (view.skeleton.parents[root] >= 0) root = (usz)view.skeleton.parents[root];
			if (root >= view.names.len || view.names[root] != joint)
			{
				detail.appendf(`keyframes[%d].joints[%d].pivot is only for the root joint (here "%s"); "%s" turns against a parent that is itself moving, so there is no fixed point to turn it about.`,
					f, d, root < view.names.len ? view.names[root] : "", joint);
				return false;
			}

			usz at = view.names.len;
			foreach (j, name : view.names) if (name == pivot && name.len > 0) at = (usz)j;
			if (at >= view.names.len)
			{
				detail.appendf(`keyframes[%d].joints[%d].pivot is "%s", which is not a joint on this rig`, f, d, pivot);
				append_addressable(detail, app, pivot);
				return false;
			}
			usz keyed = entry_turning(&clip.keyframes[f], joint);
			if (at == root || keyed >= clip.keyframes[f].dots.len || !clip.keyframes[f].dots[keyed].keys_rotation()) continue;

			rig::Pose pose = clip.pose(mem, &view.skeleton, view.names, clip.keyframes[f].time, false);
			defer pose.free(mem);
			Matrix4f[]? built = rig::joint_palette(mem, &view.skeleton, pose);
			if (catch built) continue;
			defer alloc::free(mem, built);

			Vec3 from_root = view.skeleton.joints[at].transform(built[at])
				- view.skeleton.joints[root].transform(built[root]);
			Vec3 before_turn = pose.rotations[root].invert().rotate_vec3(from_root);
			Vec3 slide = before_turn - from_root;

			AnimKeyDot* dot = &clip.keyframes[f].dots[keyed];
			float height = view.skeleton.height();
			if (height <= 0.0f) continue;
			if (dot.keys_translation())
			{
				dot.move += slide / height;
			}
			else
			{
				dot.move = slide / height;
				dot.channels = BOTH;
			}
		}
	}
	return true;
}

// ---------------------------------------------------------------------------
// World space

<*
 Rewrite this keyframe's world-space entries as the parent-relative turns a
 template stores.

 **Why the wire needs this at all.** `AnimTemplate.pose` composes
 `authored[j] = authored[parent] · turn`, so an entry's axis is read in whatever
 frame the joints above it have been turned into — the model's own axes only
 while none of them is turned. On a rig that rests in a T-pose and animates with
 the arms down, that makes an elbow's hinge depend on how far the shoulder has
 already rolled, which is not an arithmetic a caller who cannot see the rig can
 be asked to do. So a caller may state where the joint points instead, and this
 is where that becomes what the format holds.

 Two passes, both root-first, which `RigView.skeleton` guarantees:

 1. Every joint's world orientation under this keyframe — a world entry taken at
    its word, a local one carried through its parent, and a joint this keyframe
    does not name given its parent's exactly. That last is not an approximation:
    `pose` gives an undriven joint `authored[j] = from_parent` too, so the two
    agree by construction, and it is what lets a caller leave forty finger
    joints unwritten.
 2. Each world entry turned back into the turn that reproduces it,
    `R = Rw_parent⁻¹ · Rw`.

 `move` travels with the rotation, since `joint_palette` applies an offset in the
 parent's world frame as well. On a root the two frames are the same and this
 changes nothing, which is where a slide is usually written anyway.

 A local entry is left exactly as it arrived. Mixing the two inside one keyframe
 is well defined and useful: the shoulder absolutely, the elbow as a hinge off it.
*>
fn void sparse_to_parent_frame(RigView* view, AnimTemplate* clip, bool[][] in_world) @local
{
	// All keys of each ancestor are converted before descendants. An ancestor
	// absent at this frame still contributes its sampled sparse track, including
	// keys later in the clip and across the wrap interval.
	for (usz j = 0; j < view.skeleton.len(); j++)
	{
		foreach (usz f, frame : clip.keyframes)
		{
			usz at = entry_turning(&frame, j < view.names.len ? view.names[j] : "");
			if (at >= frame.dots.len || !in_world[f][at]) continue;
			Quaternionf back = parent_world_at(clip, view, (sz)j, frame.time).invert();
			AnimKeyDot* dot = &clip.keyframes[f].dots[at];
			if (dot.keys_rotation())
			{
				Quaternionf desired = quaternion::from_axis_angle{float}(dot.axis, dot.angle);
				axis_angle_of(back.mul(desired).normalize(), &dot.axis, &dot.angle);
			}
			if (dot.keys_translation()) dot.move = back.rotate_vec3(dot.move);
		}
	}
}

// Which entry of this keyframe turns `name`, or `dots.len` when none does.
// Names are unique within a keyframe — `parse_clip` refuses a repeat — so the
// first match is the only one.
fn usz entry_turning(AnimKeyframe* frame, String name) @local
{
	if (name.len == 0) return frame.dots.len;
	foreach (d, dot : frame.dots)
	{
		if (dot.joint_name == name) return (usz)d;
	}
	return frame.dots.len;
}

// ---------------------------------------------------------------------------

<*
 One entry's rotation, in whichever of the three forms it arrived, as the axis
 and angle a template stores.

 Told apart by shape: a three-element array is euler radians, an object with an
 `axis` is an axis and an angle, and any other object is a quaternion. Euler is
 turned about the world axes in X, then Y, then Z order.

 A quaternion is normalized on the way through, and one with a negative scalar
 part is negated first — the same turn written the short way round, so a small
 correction reads as a small angle rather than as very nearly a full revolution.

 A null value is identity, which is rest: an entry that only slides names no
 rotation at all.

 @return `False when the value is none of the three, or carries no direction.`
*>
fn bool rotation_from(Object* value, Vec3* axis, float* angle)
{
	*axis = { 0, 1, 0 };
	*angle = 0;
	if (value == null) return true;

	Vec3 euler;
	if (as_vec3(value, &euler))
	{
		return axis_angle_of(quaternion::from_euler{float}(euler.x, euler.y, euler.z), axis, angle);
	}
	if (!value.is_keyable()) return false;

	Object* named_axis = member(value, "axis");
	if (named_axis != null)
	{
		Vec3 direction;
		if (!as_vec3(named_axis, &direction)) return false;
		double? turn = value.get_float("angle");
		if (catch turn) return false;
		if (direction.length_sq() < 1.0e-12f) return false;
		*axis = direction.normalize();
		*angle = (float)turn;
		return true;
	}

	Quaternionf turn;
	if (!as_quat(value, &turn)) return false;
	return axis_angle_of(turn, axis, angle);
}

<*
 What the rejected joint name could have been.

 The document's dots rather than the clip's other joints: a clip addresses the
 rig, and the usual reason a name misses is that it was spelled the way some
 other rig spells it.
*>
fn void append_addressable(DString* out, AppState* app, String tried)
{
	// get_skeleton answers for an unnamed dot with bone_<id> so that it can be
	// talked about at all, but a template matches the name a dot carries and an
	// unnamed dot carries none. Copying that address straight back is the one
	// wrong turn the read surface actively invites.
	if (tried.len > 5 && tried[:5] == "bone_")
	{
		out.append_string(". A dot with no name of its own is shown as bone_<id> so it can be referred to, but a clip matches on the name a dot carries — name the dot before animating it");
	}

	usz named = 0;
	foreach (dot : app.doc.dots.array_view())
	{
		if (dot.name.len > 0) named++;
	}
	if (named == 0)
	{
		out.append_string(". No dot on this rig is named, so no clip can address one. A body plan names them; get_skeleton lists what is placed.");
		return;
	}

	out.append_string(". Named dots: ");
	NameList list = { .out = out, .total = named };
	foreach (dot : app.doc.dots.array_view())
	{
		if (dot.name.len == 0) continue;
		if (!list.next()) break;
		out.append_string(dot.name);
	}
}

// Whether an earlier entry already named this joint — how a walk over every
// keyframe lists the dots a clip moves once each rather than once per key.
fn bool named_earlier(AnimTemplate* clip, sz frame, sz dot, String name)
{
	foreach (f, held : clip.keyframes)
	{
		if (f > frame) return false;
		foreach (d, entry : held.dots)
		{
			if (f == frame && d >= dot) return false;
			if (entry.joint_name == name) return true;
		}
	}
	return false;
}

// ---------------------------------------------------------------------------
// Reading a clip back out

<*
 A clip's stored keyframes, in exactly the shape `apply_clip` takes.

 	`get_clip({"clip": "Walk"})  ->  {"name": …, "keyframes": [ … ]}`

 The read half of clip authoring, and the gap it closes: `get_pose` *samples* a
 clip and `measure_clip` measures one, so before this an agent could see what a
 clip does at an instant and never see the keys it is made of. That made every
 clip an agent had not itself written unreadable — including, once the timeline
 shipped, every clip a *person* had keyed by hand.

 **The output is the input.** What comes out here can be handed straight back to
 `apply_clip` and produce the same clip, which is what makes "read it, change one
 key, write it back" a thing an agent can do without reconstructing the rest from
 a sample. Rotations come out as `{"axis":[x,y,z],"angle":r}` because that is
 what an `AnimKeyDot` actually stores — a quaternion would be equally lossless
 and would hide the form the dopesheet is editing.

 `bone` rides along for the same reason, and `apply_clip` learned to read it so
 that it can: an imported clip carries the bone directions of the rig it was
 authored against, and a round trip that dropped them would silently turn off
 retargeting on exactly the clips that need it.

 The caller owns the returned string.
*>
fn String? clip_json(AppState* app, String name, DString* detail)
{
	AnimRef ref = resolve_named(app, name, detail)!;
	AnimTemplate* clip = app.clip(ref);
	if (!clip)
	{
		detail.appendf(`"%s" resolved to no clip. get_scene lists every pack and clip.`, name);
		return CLIP_INVALID~;
	}

	AnimPack* pack = app.pack((usz)ref.pack);

	DString out = dstring::new(mem);
	defer out.free();

	out.append_string(`{"name":`);
	append_json_string(&out, clip.name);
	if (pack)
	{
		out.append_string(`,"pack":`);
		append_json_string(&out, pack.name);
	}
	out.appendf(`,"duration":%s,"loop":%s,"blend":"%s"`,
		(JsonFloat)clip.duration, clip.loop, clip.blend == AnimBlend.SMOOTH ? "smooth" : "linear")!!;

	// Whether this clip can be written back. The authored pack is the only one
	// crig writes, so a clip out of a library file comes with the news that
	// `apply_clip` will fork it rather than change the file — which is the same
	// rule the timeline follows and the same sentence it prints.
	out.appendf(`,"editable":%s`, ref.pack == app.authored_pack)!!;

	out.append_string(`,"keyframes":`);
	append_keyframes_json(&out, clip.keyframes);
	if (clip.layers.len > 0)
	{
		out.append_string(`,"layers":`);
		append_layers_json(&out, clip.layers);
	}
	if (clip.aims.len > 0 || clip.aim_targets.len > 0)
	{
		out.append_string(`,"aims":`);
		append_aims_json(&out, clip.aims, clip.aim_targets);
	}
	if (clip.pins.len > 0)
	{
		out.append_string(`,"pins":[`);
		foreach (usz i, &pin : clip.pins)
		{
			if (i > 0) out.append_char(',');
			out.append_string(`{"joint":`);
			append_json_string(&out, pin.joint);
			out.appendf(`,"position":%s,"rotation":%s,"at":`, pin.position ? "true" : "false", pin.rotation ? "true" : "false")!!;
			append_vec3(&out, pin.at);
			out.appendf(`,"orient":%s,"from":%s,"to":%s,"blend":%s,"mute":%s}`, (JsonQuat)pin.orient,
				(JsonFloat)pin.from, (JsonFloat)pin.to, (JsonFloat)pin.blend, pin.mute ? "true" : "false")!!;
		}
		out.append_char(']');
	}
	out.append_char('}');

	return out.copy_str(mem);
}

<*
 A list of keyframes in apply_clip's own shape, `[{"time":…,"joints":[…]}]` —
 what `get_clip` writes for a clip's keys and for a keyed layer's.
*>
fn void append_keyframes_json(DString* out, AnimKeyframe[] frames)
{
	out.append_char('[');
	foreach (usz f, frame : frames)
	{
		if (f > 0) out.append_char(',');
		out.appendf(`{"time":%s,"joints":[`, (JsonFloat)frame.time)!!;

		foreach (usz d, dot : frame.dots)
		{
			if (d > 0) out.append_char(',');
			out.append_string(`{"name":`);
			append_json_string(out, dot.joint_name);
			if (dot.channels != TRANSLATION)
			{
				out.appendf(`,"rotation":{"axis":%s,"angle":%s}`,
					(JsonVec3)dot.axis, (JsonFloat)dot.angle)!!;
				if (dot.rotation_interpolation != INHERIT)
				{
					out.appendf(`,"rotation_interpolation":"%s"`, dot.rotation_interpolation.serialized())!!;
				}
			}

			// Both are omitted when they say nothing, so a clip that only turns
			// joints reads as one — the entries an agent has to look at are the
			// ones that are there.
			if (dot.channels != ROTATION)
			{
				out.appendf(`,"move":%s`, (JsonVec3)dot.move)!!;
				if (dot.translation_interpolation != INHERIT)
				{
					out.appendf(`,"translation_interpolation":"%s"`, dot.translation_interpolation.serialized())!!;
				}
			}
			if (dot.bone.length() > 0.0f)
			{
				out.appendf(`,"bone":%s`, (JsonVec3)dot.bone)!!;
			}
			out.append_char('}');
		}
		out.append_string(`]}`);
	}
	out.append_char(']');
}
