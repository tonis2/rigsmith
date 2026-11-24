<*
 get_sections: where planes across the mesh cut it, as separate loops with their
 middles and extents. The measuring tool for placing joints from the mesh — the
 arm's line from slices across X, the neck at the narrowest slice, the legs as
 the loops below a skirt — without parsing the model outside Rigsmith.
*>
module crig;

import rig;
import std::collections::object;
import std::math;

excuse SECTIONS_REFUSED;

const usz SECTIONS_MOST = 256;
const usz SECTION_LOOPS_MOST = 32;

const String GET_SECTIONS_SCHEMA = `{"type":"object","properties":{
	"axis":{"type":"string","enum":["x","y","z"],"description":"The axis the planes are square to: y for horizontal slices (the neck, the waist, the legs), x for slices across the arms, z for slices front to back. Default y."},
	"at":{"type":"array","items":{"type":"number"},"description":"Where to cut, in model units along the axis. Or from, to and step instead."},
	"from":{"type":"number","description":"The first plane, in model units along the axis. Default the mesh's low end."},
	"to":{"type":"number","description":"The last plane. Default the mesh's high end."},
	"step":{"type":"number","description":"How far apart the planes are. Default a twentieth of the span."},
	"box":{"type":"object","properties":{"min":{"type":"array","items":{"type":"number"}},"max":{"type":"array","items":{"type":"number"}}},"description":"Only what lies inside this box, in model units: one hand, one leg."},
	"min_length":{"type":"number","description":"Leave out loops shorter than this, in model units: a fingernail, a stray sliver. Default 0."}
}}`;

fn String? get_sections_tool(AppState* app, Object* args, DString* detail)
{
	if (!takes_object(args, detail, `get_sections takes an object: {"axis": "y", "from": 0, "to": 1, "step": 0.05}`)) return SECTIONS_REFUSED~;
	if (!app.has_mesh())
	{
		detail.append_string(`there is no mesh loaded to cut.`);
		return SECTIONS_REFUSED~;
	}

	String named = args.get_string("axis") ?? "y";
	usz axis;
	switch (named)
	{
		case "x": axis = 0;
		case "y": axis = 1;
		case "z": axis = 2;
		default:
			detail.appendf(`"axis" is "x", "y" or "z", not "%s".`, named);
			return SECTIONS_REFUSED~;
	}

	rig::Bounds bounds = app.geometry.bounds();
	float[SECTIONS_MOST] planes;
	usz count = 0;
	Object* listed = member(args, "at");
	if (listed)
	{
		if (!listed.is_array() || listed.get_len() == 0 || (usz)listed.get_len() > SECTIONS_MOST)
		{
			detail.appendf(`"at" is a list of 1 to %d numbers.`, SECTIONS_MOST);
			return SECTIONS_REFUSED~;
		}
		for (usz i = 0; i < (usz)listed.get_len(); i++)
		{
			double? at = listed.get_float_at((sz)i);
			if (catch at)
			{
				detail.append_string(`"at" holds numbers only.`);
				return SECTIONS_REFUSED~;
			}
			planes[count++] = (float)at;
		}
	}
	else
	{
		float from = (float)(args.get_float("from") ?? (double)bounds.min[axis]);
		float to = (float)(args.get_float("to") ?? (double)bounds.max[axis]);
		float span = math::abs(to - from);
		float step = (float)(args.get_float("step") ?? (double)(span > 0.0f ? span / 20.0f : 1.0f));
		if (!math::is_finite(from) || !math::is_finite(to) || !math::is_finite(step) || step <= 0.0f)
		{
			detail.append_string(`"from", "to" and "step" are numbers, and the step is above zero.`);
			return SECTIONS_REFUSED~;
		}
		if (span / step + 1.0f > (float)SECTIONS_MOST)
		{
			detail.appendf(`that is %d planes; %d at most. Take a larger step or a shorter span.`,
				(int)(span / step) + 1, SECTIONS_MOST);
			return SECTIONS_REFUSED~;
		}
		float direction = to >= from ? 1.0f : -1.0f;
		for (usz i = 0; count < SECTIONS_MOST; i++)
		{
			float at = from + direction * step * (float)i;
			if ((to - at) * direction < -step * 1.0e-3f) break;
			planes[count++] = at;
		}
	}

	bool boxed = false;
	Vec3 low;
	Vec3 high;
	Object* box = member(args, "box");
	if (box)
	{
		if (!as_vec3(member(box, "min"), &low) || !as_vec3(member(box, "max"), &high))
		{
			detail.append_string(`"box" is {"min": [x,y,z], "max": [x,y,z]}.`);
			return SECTIONS_REFUSED~;
		}
		boxed = true;
	}
	float min_length = (float)(args.get_float("min_length") ?? 0.0);

	MeshSection[] sections = mesh_sections(mem, app.geometry, app.shells.of, axis, planes[:count], boxed, low, high);
	defer free_mesh_sections(mem, sections);

	DString out = dstring::new(mem);
	defer out.free();
	out.appendf(`{"axis":"%s","bounds":{"min":%s,"max":%s},"sections":[`, named,
		(JsonVec3)bounds.min, (JsonVec3)bounds.max);
	foreach (usz s, section : sections)
	{
		if (s > 0) out.append_char(',');
		out.appendf(`{"at":%s,"loops":[`, (JsonFloat)section.at);
		usz written = 0;
		usz skipped = 0;
		foreach (loop : section.loops)
		{
			if (loop.length < min_length) continue;
			if (written >= SECTION_LOOPS_MOST)
			{
				skipped++;
				continue;
			}
			if (written > 0) out.append_char(',');
			Vec3 size = loop.high - loop.low;
			size[axis] = 0.0f;
			out.appendf(`{"centre":%s,"min":%s,"max":%s,"size":%s,"length":%s,"shell":%d,"closed":%s}`,
				(JsonVec3)loop.centre, (JsonVec3)loop.low, (JsonVec3)loop.high, (JsonVec3)size,
				(JsonFloat)loop.length, loop.shell, loop.closed ? "true" : "false");
			written++;
		}
		out.append_char(']');
		if (skipped > 0) out.appendf(`,"loops_omitted":%d`, skipped);
		out.append_char('}');
	}
	out.append_string("]}");
	return out.copy_str(mem);
}
