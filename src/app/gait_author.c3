<*
 Authoring a gait cycle onto the character: the one path the MCP `author_gait`
 tool and the Animations pane's Gait panel both take.

 The caller says which gait, how long, and optionally which feet (by joint name)
 and where each lands; this finds the rest, draws the clip with `algo/motion/gait.c3`,
 and lands it in the authored pack as one undo step, bound and opened, exactly as
 `author_clip` does for every other writer. Why a request was refused is written
 into `detail`, in words a caller can show as they are.
*>
module crig;

import rig;
import std::math;
import std::math::quaternion;

faultdef GAIT_REFUSED, GAIT_BAD_FOOT;

// One foot as the caller names it. `offset` is honoured only when `has_offset`;
// otherwise the gait's own pattern places the foot.
struct GaitFootRequest
{
	String joint;
	bool has_offset;
	float offset;
}

<*
 Write the clip.

 @param name : `The clip's name; a clip of that name in the authored pack is replaced, so a caller that must not do that makes it unique first (unused_clip_name).`
 @param spec : `Kind, duration, loop and samples are taken as given; zero duty, stride and lift take the gait's defaults.`
 @param lift_fraction : `When above zero, lift as a fraction of the leg's height, overriding spec.lift.`
 @param feet : `Named feet, or empty to have them found.`
 @return? GAIT_REFUSED : `The reason is in detail.`
*>
fn GaitAuthored? AppState.author_gait(
	&self,
	String name,
	GaitSpec spec,
	double lift_fraction,
	GaitFootRequest[] feet,
	DString* detail
)
{
	RigView? opened = self.open_rig(mem);
	if (catch opened)
	{
		detail.append_string(
			`this document has no dots, so there are no legs to walk on. apply_plan fits a rig; get_scene reports what is loaded.`
		);
		return GAIT_REFUSED~;
	}
	RigView view = opened;
	defer view.free(mem);

	usz[GAIT_FEET_MAX] joints;
	bool[GAIT_FEET_MAX] offsets_given;
	float[GAIT_FEET_MAX] given_offset;
	usz count;
	if (feet.len > 0)
	{
		if (feet.len > GAIT_FEET_MAX)
		{
			detail.appendf(`"feet" has %d entries and %d is the most one gait drives.`, feet.len, GAIT_FEET_MAX);
			return GAIT_REFUSED~;
		}
		foreach (i, entry : feet)
		{
			if (!self.has_dot_named(entry.joint))
			{
				detail.appendf(
					`feet[%d].joint is "%s", which is not a dot on this rig. get_skeleton lists every joint by name.`,
					i,
					entry.joint
				);
				return GAIT_REFUSED~;
			}
			sz at = view.joint_of(self.dot_named(entry.joint).id);
			if (at < 0)
			{
				detail.appendf(`feet[%d].joint is "%s", which is not part of the rig's skeleton.`, i, entry.joint);
				return GAIT_REFUSED~;
			}
			joints[count] = (usz)at;
			if (entry.has_offset)
			{
				if (entry.offset < 0.0f || entry.offset > 1.0f)
				{
					detail.appendf(`feet[%d].offset is %.9g. It is a phase of the cycle, 0 to 1.`, i, entry.offset);
					return GAIT_REFUSED~;
				}
				offsets_given[count] = true;
				given_offset[count] = entry.offset;
			}
			else if (spec.kind == CUSTOM)
			{
				detail.appendf(
					`feet[%d] needs "offset" for gait custom: the phase of the cycle the foot lands at, 0 to 1.`,
					i
				);
				return GAIT_REFUSED~;
			}
			count++;
		}
	}
	else
	{
		if (spec.kind == CUSTOM)
		{
			detail.append_string(
				`gait custom needs "feet": every foot's joint and offset, since there is no pattern to read them from.`
			);
			return GAIT_REFUSED~;
		}
		count = gait_find_feet(&view.skeleton, view.names, joints[:GAIT_FEET_MAX]);
		if (count == 0)
		{
			detail.append_string(
				`no feet found: a foot is the lowest joint of a left/right pair of limbs that end in a toe, two or more bones below a fork. Name them in "feet".`
			);
			return GAIT_REFUSED~;
		}
	}

	float[GAIT_FEET_MAX] offsets;
	gait_offsets(&view.skeleton, spec.kind, joints[:count], offsets[:count]);
	GaitFoot[GAIT_FEET_MAX] driven;
	for (usz i = 0; i < count; i++)
	{
		driven[i] = { .joint = joints[i], .offset = offsets_given[i] ? given_offset[i] : offsets[i] };
	}

	if (lift_fraction > 0.0) spec.lift = (float)lift_fraction * gait_leg_height(&view.skeleton, joints[:count]);

	GaitAuthored out  = { .kind = spec.kind, .rig_height = view.skeleton.height() };
	DocClamp limits = { .limits = &self.doc, .skeleton = &view.skeleton, .dot_ids = view.dot_ids };
	AnimTemplate? made = gait_clip(
		mem,
		&view.skeleton,
		view.names,
		name,
		spec,
		driven[:count],
		&out.report,
		&doc_clamp,
		&limits
	);
	if (catch problem = made)
	{
		if (problem == GAIT_BAD_LEG)
		{
			detail.append_string(
				`a foot has no leg this can bend: it needs two or more named bones between it and the first fork above. get_skeleton shows the rig's joints and parents.`
			);
		}
		else
		{
			detail.append_string(`there are no feet to walk on.`);
		}
		return GAIT_REFUSED~;
	}
	AnimTemplate clip = made;
	self.hold_keys_inside_limits(&view, &clip);

	// The cycle this one replaces, when there is one.
	AnimTemplate* before = null;
	AnimPack* authored = self.authored();
	if (authored) foreach (&held : authored.clips) if (held.name == name) { before = held; break; }

	// The body above the legs as a layer of its own, which mutes, fades and
	// weighs apart from the walk: every keyed joint but the legs and the root.
	float height = view.skeleton.height();
	usz root = 0;
	while (view.skeleton.parents[root] >= 0) root = (usz)view.skeleton.parents[root];
	bool body_layered = false;
	if (!spec.legs_only && count == 2)
	{
		bool[] leg = alloc::new_array(mem, bool, (sz)view.len());
		defer alloc::free(mem, leg);
		leg[root] = true;
		for (usz i = 0; i < count; i++)
		{
			GaitLeg each;
			if (gait_leg_of(&view.skeleton, joints[i], &each)) for (usz j = 0; j <= each.bones; j++) leg[each.joints[j]] = true;
		}
		StringList body;
		body.init(mem);
		defer body.free();
		foreach (usz j, joint_name : view.names)
		{
			if (leg[j] || joint_name.len == 0 || clip.channel_count(joint_name, true) + clip.channel_count(joint_name, false) == 0) continue;
			body.push(joint_name);
		}
		if (body.len() > 0)
		{
			if (try layered = clip_with_joints_layered(mem, clip, body.array_view(), {}, GAIT_BODY_LAYER))
			{
				clip.free(mem);
				clip = layered;
				body_layered = true;
			}
		}
	}

	// Rewriting a cycle keeps what was laid over it, as apply_clip does: a layer
	// or a look-at is an edit of its own, and re-running the gait to change the
	// stride should not quietly take it away. The body layer and the feet's paths
	// are the cycle's and are written again; a foot's path edited by hand is the
	// person's and stays.
	if (before && !spec.drop_layers)
	{
		usz kept;
		foreach (&layer : before.layers) if (!body_layered || layer.name != GAIT_BODY_LAYER) kept++;
		AnimLayer[] next = alloc::new_array(mem, AnimLayer, (sz)(clip.layers.len + kept));
		foreach (usz i, layer : clip.layers) next[i] = layer;
		usz write = clip.layers.len;
		foreach (&layer : before.layers) if (!body_layered || layer.name != GAIT_BODY_LAYER) next[write++] = layer.copy(mem);
		if (clip.layers.len > 0) alloc::free(mem, clip.layers);
		clip.layers = next;
		clip.aims = aims_copy(mem, before.aims);
		clip.aim_targets = aim_targets_copy(mem, before.aim_targets);
		out.kept_layers = kept;
	}
	AnimPath[] stepped = gait_foot_paths(mem, &view.skeleton, view.names, spec, driven[:count], out.report);
	{
		usz hand;
		if (before) foreach (&path : before.paths) if (!path.generated) hand++;
		AnimPath[] next = alloc::new_array(mem, AnimPath, (sz)(hand + stepped.len));
		usz write;
		if (before) foreach (&path : before.paths) if (!path.generated) next[write++] = path.copy(mem);
		foreach (&path : stepped)
		{
			bool edited;
			for (usz k = 0; k < write; k++) if (next[k].joint == path.joint) edited = true;
			if (edited) { path.free(mem); continue; }
			// A generated path keeps its switches through a re-run.
			if (before)
			{
				foreach (&old : before.paths)
				{
					if (!old.generated || old.joint != path.joint) continue;
					path.follow = old.follow;
					path.mute = old.mute;
				}
			}
			next[write++] = *path;
		}
		if (stepped.len > 0) alloc::free(mem, stepped);
		clip.paths = next[:write];
		out.paths = write;
	}
	// What it was written from, for the viewport to write it again.
	if (height > 0.0f)
	{
		clip.gait = {
			.set = true,
			.kind = spec.kind,
			.duty = out.report.duty,
			.stride = out.report.stride / height,
			.lift = out.report.lift / height,
			.drop_set = spec.drop_set,
			.drop = spec.drop / height,
			.legs_only = spec.legs_only,
			.arms_set = spec.arms_set,
			.arm_swing = spec.arm_swing,
			.arm_elbow = spec.arm_elbow,
			.arm_elbow_swing = spec.arm_elbow_swing,
			.arm_spread = spec.arm_spread,
			.samples = spec.samples,
			.feet = alloc::new_array(mem, String, (sz)count),
			.offsets = alloc::new_array(mem, float, (sz)count),
		};
		for (usz i = 0; i < count; i++)
		{
			clip.gait.feet[i] = view.names[joints[i]].copy(mem);
			clip.gait.offsets[i] = driven[i].offset;
		}
	}

	out.landed = self.author_clip(clip, &out.replaced);

	out.count = count;
	for (usz i = 0; i < count; i++)
	{
		out.joints[i] = joints[i];
		out.offsets[i] = driven[i].offset;
		out.names[i] = view.names[joints[i]].copy(mem);
	}

	// The legs were solved for where each foot should be, not for what the rig's
	// joints allow, and holding the keys inside the limits moves a foot the limits
	// refused — an ankle that will not flex as far as the stance asks lets the toe
	// skate. Pins hold each foot on its stance path with a solve that knows the
	// limits, so a cycle that measures as sliding is pinned before it is handed back.
	out.slide_before = self.clip_foot_slide(out.landed);
	// The feet's paths hold them already; pins would hold the same feet twice.
	if (!spec.no_pins && (spec.always_pin || (out.paths == 0 && out.slide_before > ISSUE_SLIDE_TOLERANCE)))
	{
		String[GAIT_FEET_MAX] feet_named;
		for (usz i = 0; i < count; i++) feet_named[i] = out.names[i];
		DString why = dstring::new(mem);
		defer why.free();
		// The treadmill's speed and direction are read off the stance feet, as
		// pin_feet's travel "auto" does. The reports are on the temporary
		// allocator; only whether it held is kept.
		if (try self.pin_clip_feet(
			out.landed,
			feet_named[:count],
			{ },
			true,
			FOOT_PIN_BLEND,
			true,
			{ },
			&why,
			travel_auto: true
		))
		{
			// Kept only if they hold the feet better than the keys alone: a foot
			// the leg cannot reach is not reached by pinning it either, and a pin
			// blending out of a window it could not hold adds a slide of its own.
			out.pinned = spec.always_pin || self.clip_foot_slide(out.landed) < out.slide_before;
			if (!out.pinned) self.undo();
		}
	}
	self.refresh_ui();
	return out;
}

<*
 The worst a foot slides off the floor while it should be planted, as a fraction
 of the rig's height — `measure_clip`'s foot_slide for a landed clip, or zero when
 there is no rig or no ground spec to measure against.
*>
fn float AppState.clip_foot_slide(&self, AnimRef ref)
{
	AnimTemplate* clip = self.clip(ref);
	if (!clip) return 0.0f;
	RigView? opened = self.open_rig(mem);
	if (catch opened) return 0.0f;
	RigView view = opened;
	defer view.free(mem);
	ClipMetrics numbers = clip_metrics(mem, &view.skeleton, view.names, *clip, 32, &self.doc, view.dot_ids);
	defer numbers.free(mem);
	return numbers.foot_slide;
}

fn void AppState.hold_keys_inside_limits(&self, RigView* view, AnimTemplate* clip) => hold_keys_inside_limits(&self.doc, view, clip);

// ---------------------------------------------------------------------------
// Writing a gait again

<*
 Write the gait clip `ref` again from its preset, `changed` in place of it: a
 longer stride dragged in the viewport, another gait picked on the Path strip, a
 foot's landing moved on the sheet. Its name, length and loop stay; layers laid
 over it and paths edited by hand stay; the body layer and the generated paths
 are written again. One undo step.

 @return `Where the clip is now, or NO_ANIM when it could not be written (the reason in a notice).`
*>
fn AnimRef AppState.rerun_gait(&self, AnimRef ref, AnimGaitPreset* changed)
{
	AnimTemplate* clip = self.clip(ref);
	if (!clip || !changed.set || changed.feet.len == 0) return NO_ANIM;
	RigView? opened = self.open_rig(mem);
	if (catch opened) return NO_ANIM;
	float height = opened.skeleton.height();
	opened.free(mem);
	if (!(height > 0.0f)) return NO_ANIM;

	GaitSpec spec = {
		.kind = changed.kind,
		.duty = changed.duty,
		.stride = changed.stride * height,
		.lift = changed.lift * height,
		.duration = clip.duration,
		.loop = clip.loop,
		.samples = changed.samples >= 8 ? changed.samples : GAIT_SAMPLES_DEFAULT,
		.legs_only = changed.legs_only,
		.drop_set = changed.drop_set,
		.drop = changed.drop * height,
		.arms_set = changed.arms_set,
		.arm_swing = changed.arm_swing,
		.arm_elbow = changed.arm_elbow,
		.arm_elbow_swing = changed.arm_elbow_swing,
		.arm_spread = changed.arm_spread,
		.no_pins = true,
	};
	GaitFootRequest[GAIT_FEET_MAX] feet;
	usz count = math::min((usz)changed.feet.len, GAIT_FEET_MAX);
	for (usz i = 0; i < count; i++)
	{
		feet[i] = { .joint = changed.feet[i], .has_offset = i < changed.offsets.len,
			.offset = i < changed.offsets.len ? changed.offsets[i] - math::floor(changed.offsets[i]) : 0.0f };
	}
	String name = clip.name.copy(mem);
	defer name.free(mem);
	DString why = dstring::new(mem);
	defer why.free();
	GaitAuthored? written = self.author_gait(name, spec, 0.0, feet[:count], &why);
	if (catch written)
	{
		self.@notice("the gait could not be written again: %s", why.str_view());
		return NO_ANIM;
	}
	written.free(mem);
	return written.landed;
}

<*
 The preset of the gait clip `ref`, a copy to change and hand to `rerun_gait`;
 one that is not set when the clip was not written by a gait.
*>
fn AnimGaitPreset AppState.gait_preset_of(&self, AnimRef ref)
{
	AnimTemplate* clip = self.clip(ref);
	return clip ? clip.gait.copy(mem) : (AnimGaitPreset){};
}

<*
 The edited gait clip written again as another gait, each foot landing where
 that gait puts it.
*>
fn bool AppState.regait(&self, GaitKind kind)
{
	AnimGaitPreset preset = self.gait_preset_of(self.editing);
	defer preset.free(mem);
	if (!preset.set) return false;
	RigView? opened = self.open_rig(mem);
	if (catch opened) return false;
	RigView view = opened;
	defer view.free(mem);
	usz[GAIT_FEET_MAX] joints;
	usz count;
	foreach (name : preset.feet)
	{
		sz at = array::index_of(view.names, name) ?? -1;
		if (at < 0 || count >= GAIT_FEET_MAX) return false;
		joints[count++] = (usz)at;
	}
	float[GAIT_FEET_MAX] offsets;
	gait_offsets(&view.skeleton, kind, joints[:count], offsets[:count]);
	for (usz i = 0; i < count && i < preset.offsets.len; i++) preset.offsets[i] = offsets[i];
	preset.kind = kind;
	// A new gait takes its own duty and lift; a stride the person set is kept.
	preset.duty = 0.0f;
	preset.lift = 0.0f;
	return self.rerun_gait(self.editing, &preset).valid();
}

<*
 A walk cycle, made new: the feet found on the rig, a second's cycle, under the
 first name "Walk" not already taken. It opens for editing with the Path tool,
 where its feet's paths are dragged.
*>
fn AnimRef AppState.new_walk_cycle(&self)
{
	String name = self.unused_clip_name(mem, "Walk");
	defer name.free(mem);
	DString why = dstring::new(mem);
	defer why.free();
	GaitSpec spec = { .kind = WALK, .duration = 1.0f, .loop = true, .samples = GAIT_SAMPLES_DEFAULT };
	GaitAuthored? written = self.author_gait(name, spec, 0.0, {}, &why);
	if (catch written)
	{
		self.@notice("%s", why.str_view());
		return NO_ANIM;
	}
	written.free(mem);
	return written.landed;
}
