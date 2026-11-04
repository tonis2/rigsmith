<* Clip fields as JSON: the codecs the session, packs and MCP share. *>
module crig;

import std::math;
import std::math::quaternion;
import std::math::vector;
import std::collections::object;
import rig;
import std::sort;

<*
 A key entry's tangents as `,"field":{"mode":"free","in":[x,y,z],"out":[x,y,z]}`,
 or nothing for an Auto key — so a clip with none writes exactly what it wrote
 before. Only `FREE` and `BROKEN` write their rates; the other modes work them
 out from the keys.
*>
fn void append_tangent_field(DString* out, String field, AnimTangents tangents)
{
	if (!tangents.explicit()) return;
	out.appendf(`,"%s":{"mode":"%s"`, field, tangent_word(tangents.mode))!!;
	if (tangents.mode == FREE || tangents.mode == BROKEN)
	{
		out.appendf(`,"in":%s,"out":%s`, (JsonVec3)tangents.incoming, (JsonVec3)tangents.outgoing)!!;
	}
	out.append_char('}');
}

<*
 The layer's fields as members of a JSON object, each preceded by a comma —
 everything but the keyed content. Fields at their default are left out.
*>
fn void append_layer_fields(DString* out, AnimLayer* layer)
{
	out.append_string(`"name":`);
	append_json_string(out, layer.name);
	out.appendf(`,"kind":"%s","mode":"%s","weight":%s`, layer.kind.wire(), layer.mode.wire(),
		(JsonFloat)layer.weight)!!;
	if (layer.mute) out.append_string(`,"mute":true`);
	if (layer.solo) out.append_string(`,"solo":true`);
	if (layer.end > layer.start || layer.start > 0.0f)
	{
		out.appendf(`,"start":%s,"end":%s`, (JsonFloat)layer.start, (JsonFloat)layer.end)!!;
	}
	if (layer.fade_in > 0.0f) out.appendf(`,"fade_in":%s`, (JsonFloat)layer.fade_in)!!;
	if (layer.fade_out > 0.0f) out.appendf(`,"fade_out":%s`, (JsonFloat)layer.fade_out)!!;
	if (layer.mask.len > 0)
	{
		out.append_string(`,"mask":[`);
		foreach (usz i, entry : layer.mask)
		{
			if (i > 0) out.append_char(',');
			append_json_string(out, entry);
		}
		out.append_char(']');
	}
	if (layer.link.len > 0)
	{
		out.append_string(`,"link":`);
		append_json_string(out, layer.link);
	}
	if (layer.length > 0.0f) out.appendf(`,"length":%s`, (JsonFloat)layer.length)!!;
	if (layer.fit != STRETCH) out.appendf(`,"fit":"%s"`, layer.fit.wire())!!;
	out.appendf(`,"track":%d`, layer.track)!!;
	if (layer.offset != 0.0f) out.appendf(`,"offset":%s`, (JsonFloat)layer.offset)!!;
	if (layer.speed > 0.0f) out.appendf(`,"speed":%s`, (JsonFloat)layer.speed)!!;
	if (layer.source.len > 0)
	{
		out.append_string(`,"source":`);
		append_json_string(out, layer.source);
	}
	if (!layer.procedural()) return;
	out.append_string(`,"joint":`);
	append_json_string(out, layer.joint);
	if (layer.tip.len > 0)
	{
		out.append_string(`,"tip":`);
		append_json_string(out, layer.tip);
	}
	out.appendf(`,"axis":%s,"amplitude":%s`, (JsonVec3)layer.axis, (JsonFloat)layer.amplitude)!!;
	switch (layer.kind)
	{
		case WAVE:
			out.appendf(`,"cycles":%s,"lag":%s,"falloff":%s,"phase":%s`, (JsonFloat)layer.cycles,
				(JsonFloat)layer.lag, (JsonFloat)layer.falloff, (JsonFloat)layer.phase)!!;
		case NOISE:
			out.appendf(`,"cycles":%s,"seed":%d`, (JsonFloat)layer.cycles, layer.seed)!!;
		case PULSE:
			out.appendf(`,"at":%s,"width":%s`, (JsonFloat)layer.at, (JsonFloat)layer.width)!!;
		default: {}
	}
}

// A number field: untouched when absent, refused with a sentence when it is not
// a finite number. `detail` may be null, for a reader with nobody to tell.
fn bool layer_number(Object* obj, String key, float* into, DString* detail) @local
{
	Object* found = member(obj, key);
	if (found == null) return true;
	double? value = obj.get_float(key);
	if (catch value)
	{
		if (detail) detail.appendf(`layer "%s" must be a finite number`, key);
		return false;
	}
	if (!math::is_finite((float)value))
	{
		if (detail) detail.appendf(`layer "%s" must be a finite number`, key);
		return false;
	}
	*into = (float)value;
	return true;
}

fn bool layer_text(Object* obj, String key, Allocator allocator, String* into, DString* detail) @local
{
	Object* found = member(obj, key);
	if (found == null) return true;
	String? value = obj.get_string(key);
	if (catch value)
	{
		if (detail) detail.appendf(`layer "%s" must be a string`, key);
		return false;
	}
	if (into.len > 0) alloc::free(allocator, into.ptr);
	*into = value.len > 0 ? value.copy(allocator) : "";
	return true;
}

<*
 Read the layer fields `append_layer_fields` writes from a JSON object, on top
 of `layer` (which a caller seeds with `anim_layer_defaults`, or with the layer
 being replaced). Validates the values, not the joint names — that is the
 caller's, who knows the rig. Does not read keyed content.

 @param detail : `Filled with the refusal; may be null.`
 @return `False when a field is malformed or out of range.`
*>
fn bool read_layer_fields(Object* obj, Allocator allocator, AnimLayer* layer, DString* detail)
{
	if (obj == null || !obj.is_keyable())
	{
		if (detail) detail.append_string("a layer must be an object");
		return false;
	}
	if (!layer_text(obj, "name", allocator, &layer.name, detail)) return false;
	if (!layer_text(obj, "joint", allocator, &layer.joint, detail)) return false;
	if (!layer_text(obj, "tip", allocator, &layer.tip, detail)) return false;
	if (!layer_text(obj, "link", allocator, &layer.link, detail)) return false;
	if (!layer_text(obj, "source", allocator, &layer.source, detail)) return false;
	if (!layer_number(obj, "length", &layer.length, detail)) return false;
	if (!layer_number(obj, "offset", &layer.offset, detail)) return false;
	if (!layer_number(obj, "speed", &layer.speed, detail)) return false;
	if (!layer_number(obj, "weight", &layer.weight, detail)) return false;
	if (!layer_number(obj, "start", &layer.start, detail)) return false;
	if (!layer_number(obj, "end", &layer.end, detail)) return false;
	if (!layer_number(obj, "fade_in", &layer.fade_in, detail)) return false;
	if (!layer_number(obj, "fade_out", &layer.fade_out, detail)) return false;
	if (!layer_number(obj, "amplitude", &layer.amplitude, detail)) return false;
	if (!layer_number(obj, "cycles", &layer.cycles, detail)) return false;
	if (!layer_number(obj, "lag", &layer.lag, detail)) return false;
	if (!layer_number(obj, "falloff", &layer.falloff, detail)) return false;
	if (!layer_number(obj, "phase", &layer.phase, detail)) return false;
	if (!layer_number(obj, "at", &layer.at, detail)) return false;
	if (!layer_number(obj, "width", &layer.width, detail)) return false;

	if (member(obj, "seed") != null)
	{
		double? seed = obj.get_float("seed");
		if (catch seed)
		{
			if (detail) detail.append_string(`layer "seed" must be a whole number, zero or more`);
			return false;
		}
		if (seed < 0 || seed > 4.0e9)
		{
			if (detail) detail.append_string(`layer "seed" must be a whole number, zero or more`);
			return false;
		}
		layer.seed = (uint)seed;
	}
	if (member(obj, "track") != null)
	{
		double? track = obj.get_float("track");
		if (catch track)
		{
			if (detail) detail.append_string(`layer "track" must be a whole number, zero or more`);
			return false;
		}
		if (track < 0 || track > 1.0e6)
		{
			if (detail) detail.append_string(`layer "track" must be a whole number, zero or more`);
			return false;
		}
		layer.track = (uint)track;
	}
	if (member(obj, "mute") != null) layer.mute = obj.get_bool("mute") ?? false;
	if (member(obj, "solo") != null) layer.solo = obj.get_bool("solo") ?? false;

	if (member(obj, "axis") != null)
	{
		Vec3 axis;
		if (!as_vec3(member(obj, "axis"), &axis) || axis.length_sq() < 1.0e-12f
			|| !math::is_finite(axis.length_sq()))
		{
			if (detail) detail.append_string(`layer "axis" must be a non-zero [x,y,z], the local axis the generator turns about`);
			return false;
		}
		layer.axis = axis.normalize();
	}

	if (member(obj, "mode") != null)
	{
		String? mode = obj.get_string("mode");
		if (catch mode)
		{
			if (detail) detail.append_string(`layer "mode" must be "additive" or "override"`);
			return false;
		}
		if (mode != "additive" && mode != "override")
		{
			if (detail) detail.append_string(`layer "mode" must be "additive" or "override"`);
			return false;
		}
		layer.mode = mode == "override" ? OVERRIDE : ADDITIVE;
	}
	if (member(obj, "fit") != null)
	{
		String fit = obj.get_string("fit") ?? "";
		AnimLayerFit parsed;
		if (!parse_layer_fit(fit, &parsed))
		{
			if (detail) detail.append_string(`layer "fit" must be "stretch", "keep" or "repeat"`);
			return false;
		}
		layer.fit = parsed;
	}
	if (member(obj, "kind") != null)
	{
		String? kind = obj.get_string("kind");
		if (catch kind)
		{
			if (detail) detail.append_string(`layer "kind" must be "keyed", "wave", "noise" or "pulse"`);
			return false;
		}
		if (kind != "keyed" && kind != "wave" && kind != "noise" && kind != "pulse")
		{
			if (detail) detail.append_string(`layer "kind" must be "keyed", "wave", "noise" or "pulse"`);
			return false;
		}
		layer.kind = kind == "wave" ? WAVE : (kind == "noise" ? NOISE : (kind == "pulse" ? PULSE : KEYED));
	}

	if (member(obj, "mask") != null)
	{
		Object* mask = member(obj, "mask");
		if (!mask.is_array())
		{
			if (detail) detail.append_string(`layer "mask" must be an array of joint names; each includes the joints below it`);
			return false;
		}
		foreach (entry : layer.mask) if (entry.len > 0) alloc::free(allocator, entry.ptr);
		if (layer.mask.len > 0) alloc::free(allocator, layer.mask);
		layer.mask = alloc::new_array(allocator, String, (sz)mask.get_len());
		for (sz i = 0; i < mask.get_len(); i++)
		{
			String? entry = mask.get_string_at((usz)i);
			if (catch entry)
			{
				if (detail) detail.appendf(`layer "mask"[%d] must be a joint name`, i);
				return false;
			}
			if (entry.len == 0)
			{
				if (detail) detail.appendf(`layer "mask"[%d] must be a joint name`, i);
				return false;
			}
			layer.mask[(usz)i] = entry.copy(allocator);
		}
	}

	if (layer.name.len == 0)
	{
		if (detail) detail.append_string(`a layer needs a "name"`);
		return false;
	}
	if (layer.weight < 0.0f || layer.weight > 1.0f)
	{
		if (detail) detail.appendf(`layer "weight" is %.9g; it is 0 to 1`, layer.weight);
		return false;
	}
	if (layer.start < 0.0f || layer.fade_in < 0.0f || layer.fade_out < 0.0f || layer.cycles < 0.0f || layer.length < 0.0f
		|| layer.speed < 0.0f)
	{
		if (detail) detail.append_string(`layer "start", "fade_in", "fade_out", "cycles", "length" and "speed" cannot be negative`);
		return false;
	}
	if (layer.source.len > 0 && (layer.kind != KEYED || !(layer.length > 0.0f)))
	{
		if (detail) detail.append_string(`a layer with a "source" is a keyed piece on its own clock: it needs "kind":"keyed" and a "length"`);
		return false;
	}
	if (layer.procedural())
	{
		if (layer.joint.len == 0)
		{
			if (detail) detail.appendf(`a "%s" layer needs "joint": the joint its chain starts at`, layer.kind.wire());
			return false;
		}
		if (layer.kind == PULSE && !(layer.width > 0.0f))
		{
			if (detail) detail.append_string(`a "pulse" layer needs a "width" above zero, in seconds`);
			return false;
		}
	}
	return true;
}

<*
 The path as a JSON object's members, without the braces.
*>
fn void append_path_fields(DString* out, AnimPath* path)
{
	out.append_string(`"joint":`);
	append_json_string(out, path.joint);
	if (path.name.len > 0)
	{
		out.append_string(`,"name":`);
		append_json_string(out, path.name);
	}
	if (path.closed) out.append_string(`,"closed":true`);
	if (path.mute) out.append_string(`,"mute":true`);
	if (path.follow) out.append_string(`,"follow":true`);
	if (path.generated) out.append_string(`,"generated":true`);
	if (path.to > path.from) out.appendf(`,"from":%s,"to":%s`, (JsonFloat)path.from, (JsonFloat)path.to)!!;
	if (path.blend > 0.0f) out.appendf(`,"blend":%s`, (JsonFloat)path.blend)!!;
	out.append_string(`,"points":[`);
	foreach (usz i, point : path.points)
	{
		if (i > 0) out.append_char(',');
		out.appendf(`{"at":%s`, (JsonVec3)point.at)!!;
		if (point.sharp) out.append_string(`,"sharp":true`);
		out.append_char('}');
	}
	out.append_string(`],"slices":[`);
	foreach (usz i, slice : path.slices)
	{
		if (i > 0) out.append_char(',');
		out.appendf(`{"time":%s,"u":%s`, (JsonFloat)slice.time, (JsonFloat)slice.u)!!;
		if (slice.tag != NONE) out.appendf(`,"tag":"%s"`, slice.tag.wire())!!;
		out.append_char('}');
	}
	out.append_char(']');
}

<*
 Read a path from a JSON object, on top of `path` (a zero one, or the path being
 replaced: members left out keep their value). Validates the shape, not the
 joint name. Slices are put in time order.

 @param detail : `Filled with the refusal; may be null.`
*>
fn bool read_path_fields(Object* obj, Allocator allocator, AnimPath* path, DString* detail)
{
	if (obj == null || !obj.is_keyable())
	{
		if (detail) detail.append_string("a path must be an object");
		return false;
	}
	if (member(obj, "joint") != null)
	{
		String? joint = obj.get_string("joint");
		if (catch joint)
		{
			if (detail) detail.append_string(`path "joint" must be a joint name`);
			return false;
		}
		if (path.joint.len > 0) alloc::free(allocator, path.joint.ptr);
		path.joint = joint.len > 0 ? joint.copy(allocator) : "";
	}
	if (member(obj, "name") != null)
	{
		String name = obj.get_string("name") ?? "";
		if (path.name.len > 0) alloc::free(allocator, path.name.ptr);
		path.name = name.len > 0 ? name.copy(allocator) : "";
	}
	if (member(obj, "closed") != null) path.closed = obj.get_bool("closed") ?? false;
	if (member(obj, "mute") != null) path.mute = obj.get_bool("mute") ?? false;
	if (member(obj, "follow") != null) path.follow = obj.get_bool("follow") ?? false;
	if (member(obj, "generated") != null) path.generated = obj.get_bool("generated") ?? false;
	if (member(obj, "from") != null) path.from = (float)(obj.get_float("from") ?? 0.0);
	if (member(obj, "to") != null) path.to = (float)(obj.get_float("to") ?? 0.0);
	if (member(obj, "blend") != null) path.blend = math::max(0.0f, (float)(obj.get_float("blend") ?? 0.0));

	Object* points = member(obj, "points");
	if (points != null)
	{
		if (!points.is_array() || points.get_len() > (sz)PATH_POINTS_MOST)
		{
			if (detail) detail.appendf(`path "points" must be an array of up to %d {"at":[x,y,z]}`, PATH_POINTS_MOST);
			return false;
		}
		AnimPathPoint[] read = alloc::new_array(allocator, AnimPathPoint, (sz)points.get_len());
		for (sz i = 0; i < points.get_len(); i++)
		{
			Object* point = points.get_at((usz)i);
			Vec3 at;
			if (point == null || !point.is_keyable() || !as_vec3(member(point, "at"), &at) || !math::is_finite(at.length_sq()))
			{
				alloc::free(allocator, read);
				if (detail) detail.appendf(`path "points"[%d] needs "at": [x,y,z], a fraction of the rig's height`, i);
				return false;
			}
			read[(usz)i] = { .at = at, .sharp = point.get_bool("sharp") ?? false };
		}
		if (path.points.len > 0) alloc::free(allocator, path.points);
		path.points = read;
	}

	Object* slices = member(obj, "slices");
	if (slices != null)
	{
		if (!slices.is_array())
		{
			if (detail) detail.append_string(`path "slices" must be an array of {"time": s, "u": 0..1}`);
			return false;
		}
		AnimPathSlice[] read = alloc::new_array(allocator, AnimPathSlice, (sz)slices.get_len());
		for (sz i = 0; i < slices.get_len(); i++)
		{
			Object* slice = slices.get_at((usz)i);
			double? time = slice ? slice.get_float("time") : NOT_FOUND~;
			double? u = slice ? slice.get_float("u") : NOT_FOUND~;
			if (catch time, u)
			{
				alloc::free(allocator, read);
				if (detail) detail.appendf(`path "slices"[%d] needs "time" (seconds) and "u" (0..1 along the curve)`, i);
				return false;
			}
			String tag = slice.get_string("tag") ?? "";
			if (!math::is_finite((float)time) || !(u >= 0.0 && u <= 1.0) || (tag != "" && tag != "down" && tag != "up"))
			{
				alloc::free(allocator, read);
				if (detail) detail.appendf(`path "slices"[%d]: "time" must be a number, "u" 0 to 1 and "tag" "down" or "up"`, i);
				return false;
			}
			read[(usz)i] = { .time = (float)time, .u = (float)u, .tag = tag == "down" ? DOWN : tag == "up" ? UP : NONE };
		}
		if (path.slices.len > 0) alloc::free(allocator, path.slices);
		path.slices = read;
		path.sort_slices();
	}
	if (path.joint.len == 0)
	{
		if (detail) detail.append_string(`a path needs "joint": the joint that follows it`);
		return false;
	}
	return true;
}

fn void append_gait_preset(DString* out, AnimGaitPreset* preset)
{
	out.appendf(`{"gait":"%s","duty":%s,"stride":%s,"lift":%s,"samples":%d`, preset.kind.label(), (JsonFloat)preset.duty,
		(JsonFloat)preset.stride, (JsonFloat)preset.lift, preset.samples)!!;
	if (preset.drop_set) out.appendf(`,"drop":%s`, (JsonFloat)preset.drop)!!;
	if (preset.legs_only) out.append_string(`,"legs_only":true`);
	if (preset.arms_set)
	{
		out.appendf(`,"arms":[%s,%s,%s,%s]`, (JsonFloat)preset.arm_swing, (JsonFloat)preset.arm_elbow,
			(JsonFloat)preset.arm_elbow_swing, (JsonFloat)preset.arm_spread)!!;
	}
	out.append_string(`,"feet":[`);
	foreach (usz i, name : preset.feet)
	{
		if (i > 0) out.append_char(',');
		out.append_string(`{"joint":`);
		append_json_string(out, name);
		out.appendf(`,"offset":%s}`, (JsonFloat)(i < preset.offsets.len ? preset.offsets[i] : 0.0f))!!;
	}
	out.append_string("]}");
}

<*
 Read a preset `append_gait_preset` wrote. False on a malformed one, which then
 holds nothing.
*>
fn bool read_gait_preset(Object* obj, Allocator allocator, AnimGaitPreset* preset)
{
	*preset = {};
	if (obj == null || !obj.is_keyable()) return false;
	if (!parse_gait_kind(obj.get_string("gait") ?? "", &preset.kind)) return false;
	preset.duty = (float)(obj.get_float("duty") ?? 0.0);
	preset.stride = (float)(obj.get_float("stride") ?? 0.0);
	preset.lift = (float)(obj.get_float("lift") ?? 0.0);
	preset.samples = (usz)math::clamp(obj.get_float("samples") ?? (double)8, 8.0, 240.0);
	preset.legs_only = obj.get_bool("legs_only") ?? false;
	if (try double drop = obj.get_float("drop"))
	{
		preset.drop_set = true;
		preset.drop = (float)drop;
	}
	Object* arms = member(obj, "arms");
	if (arms != null && arms.is_array() && arms.get_len() == 4)
	{
		preset.arms_set = true;
		preset.arm_swing = (float)(arms.get_float_at(0) ?? 1.0);
		preset.arm_elbow = (float)(arms.get_float_at(1) ?? 1.0);
		preset.arm_elbow_swing = (float)(arms.get_float_at(2) ?? 1.0);
		preset.arm_spread = (float)(arms.get_float_at(3) ?? 1.0);
	}
	Object* feet = member(obj, "feet");
	if (feet == null || !feet.is_array() || feet.get_len() == 0 || (usz)feet.get_len() > GAIT_FEET_MAX) return false;
	preset.feet = alloc::new_array(allocator, String, feet.get_len());
	preset.offsets = alloc::new_array(allocator, float, feet.get_len());
	for (sz i = 0; i < feet.get_len(); i++)
	{
		Object* foot = feet.get_at((usz)i);
		String joint = foot ? foot.get_string("joint") ?? "" : "";
		if (joint.len == 0)
		{
			preset.free(allocator);
			return false;
		}
		preset.feet[(usz)i] = joint.copy(allocator);
		preset.offsets[(usz)i] = (float)(foot.get_float("offset") ?? 0.0);
	}
	preset.set = true;
	return true;
}
