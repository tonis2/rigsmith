<*
 author_gait: a walking, trotting or galloping cycle, written from the rig's legs.

 The layer above `solve_targets` and `pin_feet` for the commonest thing an
 animator asks of a character: make it walk. The caller names a gait (or gives each
 foot its own place in the cycle) and a duration; `anim/gait.c3` draws every foot's
 path — stance back along the floor at a constant speed, swing forward through an
 arc — and solves each leg onto it with the same two-bone-and-distal-tilt rule
 `solve_targets` uses for a three-bone run. The clip lands in the authored pack as
 ordinary, editable keys in one undo step, with a ground spec naming when each foot
 is down, so the root height is the floor solve's rather than a number authored for
 one skeleton.

 What comes back is the landed clip, the `measure_clip` numbers for it, and the
 treadmill speed: the figure does not travel, its stance foot runs backward, so
 `ground_speed` is what a caller moving the character through the world should
 move it at.
*>
module crig;

import rig;
import std::collections::object;
import std::math;

const String AUTHOR_GAIT_SCHEMA = `{"type":"object","properties":{
	"name":{"type":"string","description":"The clip's name in the authored pack; a clip of that name is replaced."},
	"duration":{"type":"number","description":"Seconds for one cycle. Default 1.","default":1},
	"loop":{"type":"boolean","description":"Whether the clip loops. Default true; a looping cycle keys no closing frame, since it is the opening one.","default":true},
	"gait":{"type":"string","enum":["walk","trot","pace","gallop","custom"],"description":"walk is the lateral sequence (left hind, left fore, right hind, right fore) with each foot down 62% of the cycle; trot lands the diagonal pairs together, 45%; pace the lateral pairs, 45%; gallop the rotary order, 35%. A two-legged figure alternates its feet half a cycle apart whichever is named (a walk is down 60%). custom takes every foot's offset from feet. Default walk."},
	"duty":{"type":"number","description":"How long each foot is on the floor, as a fraction of the cycle, 0.1 to 0.9. Default by gait."},
	"stride":{"type":"number","description":"How far the stance foot slides back, in model units — with duty and duration, the treadmill speed. Default about 0.6 of the leg's height for a walk, more for faster gaits."},
	"lift":{"type":"number","description":"How high the swinging foot clears the floor, as a fraction of the leg's height. Default 0.12 for a walk, more for faster gaits."},
	"feet":{"type":"array","description":"The feet to drive, each a joint and, optionally, where in the cycle it lands (0 to 1). Omit to find them: each left/right pair of limbs near the floor that ends in a toe. A foot is the lowest joint whose child is a toe — the one the floor meets — and its leg is the run of two to four bones up to the first fork. offset is required for gait custom; otherwise it overrides the gait's own.","items":{"type":"object","properties":{
		"joint":{"type":"string","description":"The foot joint, by the name get_skeleton reports."},
		"offset":{"type":"number","description":"Phase of the cycle the foot lands at, 0 to 1."}
	},"required":["joint"]}},
	"samples":{"type":"number","description":"Keys per cycle. Default 40, between 8 and 240."},
	"pin_feet":{"description":"Pin each foot to its stance path after the cycle is written: \"auto\" (the default) pins only when the cycle measures as sliding — the rig's joint limits refusing part of a solved stance, an ankle that will not flex as far as the stride asks — true always, false never. The answer's pinned says which happened.","anyOf":[{"type":"boolean"},{"type":"string","enum":["auto"]}]},
	"pelvis_drop":{"type":"number","description":"How far the hips sit below standing height, in model units, in place of the smallest drop that keeps every leg short of straight (the answer's pelvis_drop). Smaller for straighter legs, larger for a crouch; at most 0.6 of the leg's height. While a foot is down the floor solve still plants it, so this is a statement about how the legs bend."},
	"arms":{"type":"object","description":"For an upright two-legged figure with upper_body on: multipliers on the arms' default motion, each 1 when left out, 0 to 4.","properties":{
		"swing":{"type":"number","description":"How far the arms swing forward and back."},
		"elbow":{"type":"number","description":"How bent the elbows are."},
		"elbow_swing":{"type":"number","description":"How much more the elbow bends as the arm comes forward."},
		"spread":{"type":"number","description":"How far the arms hang out from the body."}
	}},
	"keep_layers":{"type":"boolean","description":"When a clip of this name already exists, keep its layers and look-ats over the new cycle, as apply_clip does. Default true; false starts the clip clean. Its pins are always written again, since they were for the old footfalls."},
	"upper_body":{"type":"boolean","description":"For an upright two-legged figure, key the rest of a walking body as well: the pelvis bobbing into each footfall and turning with the leading leg, the chest turning against it, the arms lowered and swinging opposite the legs with the elbows bent, the head held level. Amplitudes scale with stride; a run (trot) swings harder and bends the elbows. false keys the legs only, for a figure whose upper body another clip or layer drives. Default true."}
},"required":["name"]}`;

<*
 author_gait: write the clip, and answer with what it is and how it measures.

 @return? GAIT_REFUSED : `The reason is in detail.`
*>
fn String? author_gait_json(AppState* app, Object* args, DString* detail)
{
	if (!takes_object(args, detail, `author_gait takes an object: {"name": clip name, "duration": seconds, "gait": "walk"|"trot"|"pace"|"gallop"|"custom", "feet": [{"joint": name, "offset": phase}]}`)) return GAIT_REFUSED~;

	String clip_name;
	if (!required_string(args, "name", &clip_name, detail, `author_gait needs "name": what to call the clip.`)) return GAIT_REFUSED~;

	GaitSpec spec = { .kind = WALK, .duration = 1.0f, .loop = true, .samples = GAIT_SAMPLES_DEFAULT };
	if (try given = args.get_string("gait"))
	{
		if (!parse_gait_kind(given, &spec.kind))
		{
			detail.appendf(`"gait" is "%s". It is walk, trot, pace, gallop or custom.`, given);
			return GAIT_REFUSED~;
		}
	}
	if (try given = args.get_float("duration"))
	{
		if (!(given > 0.0) || given > 600.0)
		{
			detail.appendf(`"duration" is %.9g. It is seconds for one cycle, more than zero.`, given);
			return GAIT_REFUSED~;
		}
		spec.duration = (float)given;
	}
	if (try given = args.get_bool("loop")) spec.loop = given;
	if (try given = args.get_float("duty"))
	{
		if (given < 0.1 || given > 0.9)
		{
			detail.appendf(`"duty" is %.9g. It is the share of the cycle a foot is down, 0.1 to 0.9.`, given);
			return GAIT_REFUSED~;
		}
		spec.duty = (float)given;
	}
	if (try given = args.get_float("stride"))
	{
		if (!(given > 0.0))
		{
			detail.appendf(`"stride" is %.9g. It is model units, more than zero.`, given);
			return GAIT_REFUSED~;
		}
		spec.stride = (float)given;
	}
	double lift_fraction = 0.0;
	if (try given = args.get_float("lift"))
	{
		if (!(given > 0.0) || given > 1.0)
		{
			detail.appendf(`"lift" is %.9g. It is a fraction of the leg's height, more than zero and at most one.`, given);
			return GAIT_REFUSED~;
		}
		lift_fraction = given;
	}
	if (try given = args.get_float("samples"))
	{
		if (given < 8 || given > (double)GAIT_SAMPLES_MOST)
		{
			detail.appendf(`"samples" is %.9g. It is a whole number of keys per cycle, 8 to %d.`, given, GAIT_SAMPLES_MOST);
			return GAIT_REFUSED~;
		}
		spec.samples = (usz)given;
	}
	spec.legs_only = !(args.get_bool("upper_body") ?? true);
	spec.drop_layers = !(args.get_bool("keep_layers") ?? true);
	if (try given = args.get_float("pelvis_drop"))
	{
		if (given < 0.0 || given > 1000.0)
		{
			detail.appendf(`"pelvis_drop" is %.9g. It is model units the hips sit below standing, zero or more.`, given);
			return GAIT_REFUSED~;
		}
		spec.drop_set = true;
		spec.drop = (float)given;
	}
	Object* arms = member(args, "arms");
	if (arms != null)
	{
		if (!arms.is_keyable())
		{
			detail.append_string(`"arms" must be an object: {"swing": n, "elbow": n, "elbow_swing": n, "spread": n}, each a multiplier on the default.`);
			return GAIT_REFUSED~;
		}
		String[4] keys = { "swing", "elbow", "elbow_swing", "spread" };
		float[4] amounts = { 1.0f, 1.0f, 1.0f, 1.0f };
		foreach (usz k, key : keys)
		{
			if (try given = arms.get_float(key))
			{
				if (given < 0.0 || given > 4.0)
				{
					detail.appendf(`"arms".%s is %.9g. It is a multiplier on the default, 0 to 4.`, key, given);
					return GAIT_REFUSED~;
				}
				amounts[k] = (float)given;
			}
		}
		spec.arms_set = true;
		spec.arm_swing = amounts[0];
		spec.arm_elbow = amounts[1];
		spec.arm_elbow_swing = amounts[2];
		spec.arm_spread = amounts[3];
	}
	Object* pinning = member(args, "pin_feet");
	if (pinning != null)
	{
		if (pinning.is_bool())
		{
			spec.always_pin = pinning.b;
			spec.no_pins = !pinning.b;
		}
		else if (!pinning.is_string() || pinning.s != "auto")
		{
			detail.append_string(`"pin_feet" is true, false or "auto".`);
			return GAIT_REFUSED~;
		}
	}

	// The feet: as named, else found.
	GaitFootRequest[GAIT_FEET_MAX] named;
	usz named_count;
	Object* listed = member(args, "feet");
	if (listed != null)
	{
		if (!listed.is_array() || listed.get_len() == 0)
		{
			detail.append_string(`"feet" must be a non-empty array of {"joint": name, "offset": phase}. Leave it out to have the feet found.`);
			return GAIT_REFUSED~;
		}
		if ((usz)listed.get_len() > GAIT_FEET_MAX)
		{
			detail.appendf(`"feet" has %d entries and %d is the most one gait drives.`, listed.get_len(), GAIT_FEET_MAX);
			return GAIT_REFUSED~;
		}
		for (sz i = 0; i < listed.get_len(); i++)
		{
			Object* entry = listed.get_at(i);
			String? joint = entry.is_keyable() ? entry.get_string("joint") : GAIT_BAD_FOOT~;
			if (catch joint)
			{
				detail.appendf(`feet[%d] needs "joint": the foot's name.`, i);
				return GAIT_REFUSED~;
			}
			named[named_count] = { .joint = joint };
			if (try offset = entry.get_float("offset"))
			{
				named[named_count].has_offset = true;
				named[named_count].offset = (float)offset;
			}
			named_count++;
		}
	}

	GaitAuthored? authored = app.author_gait(clip_name, spec, lift_fraction, named[:named_count], detail);
	if (catch authored) return GAIT_REFUSED~;
	GaitAuthored result = authored;
	defer result.free(mem);
	AnimRef landed = result.landed;
	bool replaced = result.replaced;
	GaitReport report = result.report;
	usz count = result.count;
	bool authored_pinned = result.pinned;
	float slide_before = result.slide_before;

	// The authored pack's own name, so a clip of the same name in a file pack
	// cannot make the lookup ambiguous.
	AnimTemplate* stored = app.clip(landed);
	AnimPack* pack = app.pack((usz)landed.pack);
	String qualified = string::format(mem, "%s/%s", pack.name, stored.name);
	defer qualified.free(mem);
	String metrics = metrics_json(app, qualified, 0, detail)!;
	defer metrics.free(mem);
	String applied = applied_json(app, landed, replaced, measured: false);
	defer applied.free(mem);

	DString out = dstring::new(mem);
	defer out.free();
	out.append_string(`{"clip":"`);
	json_escape_into(&out, stored.name);
	out.appendf(`","gait":"%s","feet":[`, spec.kind.label());
	for (usz i = 0; i < count; i++)
	{
		if (i > 0) out.append_char(',');
		out.append_string(`{"joint":"`);
		json_escape_into(&out, result.names[i]);
		out.appendf(`","offset":%s}`, (JsonFloat)result.offsets[i]);
	}
	float height = result.rig_height;
	out.appendf(`],"duty":%s,"stride":%s,"lift":%s,"leg_height":%s,"pelvis_drop":%s,"floor":%s`,
		(JsonFloat)report.duty, (JsonFloat)report.stride, (JsonFloat)report.lift,
		(JsonFloat)report.leg_height, (JsonFloat)report.drop, (JsonFloat)report.floor);
	out.appendf(`,"ground_speed":%s,"ground_speed_rig_heights":%s,"keys":%d`,
		(JsonFloat)report.speed, (JsonFloat)(height > 0.0f ? report.speed / height : report.speed), report.keys);
	out.append_string(`,"travel":[0,0,`);
	out.appendf(`%s]`, (JsonFloat)report.speed);
	out.append_string(`,"note":"ground_speed is the treadmill the figure stands on, in model units per second: the stance foot runs backward at it, so move the character forward by it. travel is the same as a pin_feet argument."`);
	out.appendf(`,"pinned":%s,"slide_before_pins":%s`, authored_pinned ? "true" : "false", (JsonFloat)slide_before);
	if (result.kept_layers > 0) out.appendf(`,"kept_layers":%d`, result.kept_layers);
	out.append_string(`,"landed":`);
	out.append_string(applied);
	out.append_string(`,"metrics":`);
	out.append_string(metrics);
	out.append_char('}');
	return out.copy_str(mem);
}

fn String? tool_author_gait(Object* args, void* user_data, DString* detail)
	=> author_gait_json((AppState*)user_data, args, detail);
