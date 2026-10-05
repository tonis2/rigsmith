<*
 plant_feet: bake a clip's stance feet still, so they stop skating.

 The recommendation this answers (animation_plan.md, MCP2) is that a foot's
 contact is more than a height: a planted foot holds its horizontal place while
 the pelvis moves over it, and a foot that slides sideways under a leg that looks
 planted is the difference between walking and skating — the very thing
 `measure_clip`'s `foot_slide` measures and a still frame hides.

 `ground_pose` already answers the vertical half — where the hips sit for the
 stance foot to reach the floor — by sliding the root's Y. It cannot answer the
 horizontal half, because holding a foot in place while the pelvis sways needs the
 *leg* to bend, not the root to move. So this bakes that bend: across each stance
 window it holds the foot's XZ with the same limit-aware IK a pinned foot is held
 by (`solve_limited_pose_chain`), and keys the corrected leg. The vertical stays
 with `ground_pose`, which a pure-Y root shift leaves the baked XZ untouched by.

 ## Travel is not separable from planting

 Whether a stance foot should stay world-fixed or creep backward is a fact about
 the clip, not the foot: a clip that travels through the world plants its foot on
 the ground and the body passes over it (world-fixed), while an in-place cycle
 authored on the spot has the same foot slide backward at the gait's speed, which
 is what a treadmill is. So `travel` names that speed — the velocity the in-place
 body is not actually moving at — and the plant creeps the target backward by it.
 Zero, the default, is a foot fixed in the world: right for a clip that travels,
 for a stationary action, and for the plain "this foot must not skate" case.

 ## It bakes, and it lands

 Unlike `solve_targets`, which answers and writes nothing, this is a whole-clip
 edit — every sampled instant of every stance window, keyed — so it lands in the
 authored pack as one undo step the way `apply_clip` does, and answers with the
 `foot_slide` it removed. What it does not do yet: heel/toe roll, a swing foot's
 clearance and landing, and a pelvis distinct from the locomotion root — a single
 root carries both here. Those are the rest of MCP2.
*>
module crig;

import rig;
import std::collections::object;
import std::math;
import std::math::matrix;
import std::math::quaternion;

faultdef PLANT_REFUSED;

const String PLANT_FEET_SCHEMA = `{"type":"object","properties":{
	"clip":{"type":"string","description":"The clip to plant, which must carry a ground spec — the feet and the phases each is down. apply_clip's ground argument sets one; measure_clip and get_scene report whether a clip has one."},
	"travel":{"type":"array","items":{"type":"number"},"description":"[x,y,z] the velocity in model units per second that an in-place body is not actually moving at, so a stance foot creeps backward by it — a treadmill walk's gait speed. Omit or [0,0,0] for a foot fixed in the world, which is right for a clip that travels through the world and for any plain no-skate plant."},
	"samples":{"type":"number","description":"How many instants across the clip to key each planted foot at. Default is about 48 a second, at least 24. More holds a foot tighter between keys at the cost of more keys."}
},"required":["clip"]}`;

<*
 plant_feet: hold every stance foot still across its window, and land the result.

 @return? PLANT_REFUSED : `The reason is in detail.`
*>
fn String? plant_feet_json(AppState* app, Object* args, DString* detail)
{
	if (!takes_object(args, detail, `plant_feet takes an object: {"clip": name, "travel": [x,y,z], "samples": n}`)) return PLANT_REFUSED~;

	String clip_name;
	if (!required_string(args, "clip", &clip_name, detail, `plant_feet needs "clip": the name of a clip with a ground spec. get_scene lists every pack and clip.`)) return PLANT_REFUSED~;

	AnimRef ref = resolve_named(app, clip_name, detail)!;
	AnimTemplate* src = app.clip(ref);
	if (src == null || !src.ground.solves())
	{
		detail.append_string(`this clip has no ground spec, so there are no stance feet to plant. Give apply_clip a "ground" argument — the feet and the phases each is down — first.`);
		return PLANT_REFUSED~;
	}

	float duration = src.duration;
	if (duration <= 0.0f)
	{
		detail.append_string(`this clip has no duration, so there is no cycle to plant a foot across.`);
		return PLANT_REFUSED~;
	}

	usz samples = plant_samples_for(duration);
	if (try given = args.get_float("samples"))
	{
		if (given < 2 || given > (double)PLANT_SAMPLES_MOST)
		{
			detail.appendf(`"samples" is %.9g. It is a whole number from 2 to %d.`, given, PLANT_SAMPLES_MOST);
			return PLANT_REFUSED~;
		}
		samples = (usz)given;
	}

	Vec3 travel = {};
	if (member(args, "travel") != null && !as_vec3(member(args, "travel"), &travel))
	{
		detail.append_string(`"travel" must be [x,y,z] in model units per second.`);
		return PLANT_REFUSED~;
	}

	RigView? opened = app.open_rig(mem);
	if (catch opened)
	{
		detail.append_string(`this document has no dots, so there is no leg to bend. apply_plan fits a rig; get_scene reports what is loaded.`);
		return PLANT_REFUSED~;
	}
	RigView view = opened;
	defer view.free(mem);

	PlantOutcome outcome;
	defer outcome.free();
	AnimTemplate planted;
	if (!app.plant_clip(&view, view.names, src, src.ground, travel, samples, &outcome, &planted))
	{
		return plant_report(app, clip_name, travel, outcome.feet[:outcome.foot_count], outcome.before, outcome.before, 0, ref, false, false);
	}

	bool replaced;
	AnimRef landed = app.author_clip(planted, &replaced);
	app.refresh_ui();

	return plant_report(app, clip_name, travel, outcome.feet[:outcome.foot_count], outcome.before, outcome.after,
		outcome.keys, landed, replaced, true);
}

// The answer: the slide removed, per-foot what was planted, and where the clip
// landed. `landed_ref`/`replaced` are read only when `did_land`.
fn String plant_report(AppState* app, String clip_name, Vec3 travel, FootPlant[] feet,
	ClipMetrics before, ClipMetrics after, usz keys, AnimRef landed_ref, bool replaced, bool did_land) @local
{
	DString out = dstring::new(mem);
	defer out.free();

	out.append_string(`{"clip":"`);
	json_escape_into(&out, clip_name);
	out.append_string(`","travel":`);
	append_vec3(&out, travel);
	out.append_string(`,"feet":[`);
	foreach (fi, fp : feet)
	{
		if (fi > 0) out.append_char(',');
		out.append_string(`{"joint":"`);
		json_escape_into(&out, fp.name);
		out.appendf(`","planted":%s,"corrections":%d`, fp.ok ? "true" : "false", fp.corrections);
		if (!fp.ok) out.append_string(`,"note":"no leg to bend — the foot is not a dot on this rig, or nothing above it forms an unbranched run"`);
		out.append_char('}');
	}
	out.appendf(`],"foot_slide":{"before":%.6g,"after":%.6g},"ground_speed":{"before":%.6g,"after":%.6g},"keys_added":%d`,
		before.foot_slide, after.foot_slide, before.ground_speed, after.ground_speed, keys);

	if (did_land)
	{
		String applied = applied_json(app, landed_ref, replaced);
		defer alloc::free(mem, applied);
		out.append_string(`,"landed":`);
		out.append_string(applied);
	}
	else
	{
		out.append_string(`,"landed":null,"note":"nothing was planted — the stance feet were already still, or no foot had a leg to bend. The clip is unchanged."`);
	}
	out.append_char('}');
	return out.copy_str(mem);
}
