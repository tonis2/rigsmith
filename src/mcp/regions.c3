<*
 Vertices by where they are, on the wire: the region keys paint_weights and
 pin_weights narrow a selection with, and get_vertices, which hands a script the
 positions (`algo/geom/regions.c3`).
*>
module crig;

import rig;
import std::collections::object;
import std::math;

excuse VERTICES_REFUSED;

// The region keys, as they sit in every schema that takes them.
const String REGION_SCHEMA_KEYS = `"shell":{"type":"number","description":"Only this piece of the mesh, by the id get_shells reports."},"shells":{"type":"array","items":{"type":"number"},"description":"Only these pieces."},"box":{"type":"object","properties":{"min":{"type":"array","items":{"type":"number"}},"max":{"type":"array","items":{"type":"number"}}},"description":"Only vertices inside this box, in model units."},"height":{"type":"array","items":{"type":"number"},"description":"[from, to]: only vertices between these heights, in model units along Y — the skirt below the belt."},"side":{"type":"string","enum":["left","right","middle"],"description":"Only the figure's left (past the mirror plane toward +X), its right, or the vertices on the plane itself."}`;

const usz VERTICES_MOST = 20000;

const String GET_VERTICES_SCHEMA = `{"type":"object","properties":{` +++ REGION_SCHEMA_KEYS +++ `,"limit":{"type":"number","description":"How many to list at most. Default and most 20000."},"owners":{"type":"boolean","description":"Also give the joint holding most of each vertex. Costs a bind when the rig has moved."}}}`;

<*
 The region an object's keys describe. Absent keys leave it unnarrowed.

 @return `False, with detail saying why, when a key is there but malformed.`
*>
fn bool read_region(AppState* app, Object* args, VertexRegion* into, DString* detail)
{
	*into = { .plane = app.doc.sym_x };
	Object* one = member(args, "shell");
	Object* many = member(args, "shells");
	if (one && many)
	{
		detail.append_string(`give "shell" or "shells", not both.`);
		return false;
	}
	if (one)
	{
		long? shell = one.to_value(long, false);
		if (catch shell)
		{
			detail.append_string(`"shell" is a piece number, as get_shells reports them.`);
			return false;
		}
		into.shells[0] = (int)shell;
		into.shell_count = 1;
	}
	if (many)
	{
		if (!many.is_array() || many.get_len() == 0 || (usz)many.get_len() > REGION_SHELLS_MOST)
		{
			detail.appendf(`"shells" is a list of 1 to %d piece numbers.`, REGION_SHELLS_MOST);
			return false;
		}
		for (usz i = 0; i < (usz)many.get_len(); i++)
		{
			double? shell = many.get_float_at((sz)i);
			if (catch shell)
			{
				detail.append_string(`"shells" holds piece numbers only.`);
				return false;
			}
			into.shells[into.shell_count++] = (int)shell;
		}
	}
	Object* box = member(args, "box");
	if (box)
	{
		if (!as_vec3(member(box, "min"), &into.low) || !as_vec3(member(box, "max"), &into.high))
		{
			detail.append_string(`"box" is {"min": [x,y,z], "max": [x,y,z]}.`);
			return false;
		}
		into.boxed = true;
	}
	Object* height = member(args, "height");
	if (height)
	{
		double from = -1.0e30;
		double to = 1.0e30;
		bool read = height.is_array() && height.get_len() == 2;
		if (read)
		{
			if (try f = height.get_float_at(0)) { from = f; } else { read = false; }
			if (try t = height.get_float_at(1)) { to = t; } else { read = false; }
		}
		if (!read)
		{
			detail.append_string(`"height" is [from, to], two heights in model units.`);
			return false;
		}
		into.banded = true;
		into.from = (float)from;
		into.to = (float)to;
	}
	if (try side = args.get_string("side"))
	{
		switch (side)
		{
			case "left": into.side = LEFT;
			case "right": into.side = RIGHT;
			case "middle": into.side = MIDDLE;
			default:
				detail.appendf(`"side" is "left", "right" or "middle", not "%s".`, side);
				return false;
		}
		rig::Bounds bounds = app.geometry.bounds();
		into.middle = (bounds.max.x - bounds.min.x) * 0.005f;
	}
	return true;
}

<*
 `chosen` cut down to what the region holds. Takes the slice over and returns
 one the caller owns; unnarrowed, the same slice comes back.
*>
fn uint[] in_region(AppState* app, uint[] chosen, VertexRegion* region)
{
	if (!region.narrows() || chosen.len == 0) return chosen;
	int[] shell_of = app.shells.of.len == app.geometry.positions.len ? app.shells.of : (int[]){};
	usz kept = 0;
	foreach (v : chosen)
	{
		if (v >= app.geometry.positions.len) continue;
		if (region.holds(app.geometry.positions[v], shell_of.len > v ? shell_of[v] : 0)) chosen[kept++] = v;
	}
	if (kept == chosen.len) return chosen;
	if (kept == 0)
	{
		alloc::free(mem, chosen);
		return {};
	}
	uint[] out = alloc::new_array(mem, uint, (sz)kept);
	out[..] = chosen[:kept];
	alloc::free(mem, chosen);
	return out;
}

<*
 get_vertices: the vertices a region holds, with their positions and shells —
 and, asked for, the joint holding most of each. What a script reads the mesh
 through.
*>
fn String? get_vertices_tool(AppState* app, Object* args, DString* detail)
{
	if (!takes_object(args, detail, `get_vertices takes an object: {"shell": n, "box": {"min": [..], "max": [..]}, "height": [from, to], "side": "left"}`)) return VERTICES_REFUSED~;
	if (!app.has_mesh())
	{
		detail.append_string(`there is no mesh loaded.`);
		return VERTICES_REFUSED~;
	}
	VertexRegion region;
	if (!read_region(app, args, &region, detail)) return VERTICES_REFUSED~;
	usz limit = (usz)math::clamp(args.get_float("limit") ?? (double)VERTICES_MOST, 1.0, (double)VERTICES_MOST);
	int[] shell_of = app.shells.of.len == app.geometry.positions.len ? app.shells.of : (int[]){};
	uint[] found = region_vertices(mem, &region, app.geometry.positions, shell_of);
	defer if (found.len > 0) alloc::free(mem, found);
	usz listed = math::min((usz)found.len, limit);

	bool owners = args.get_bool("owners") ?? false;
	RigView view;
	float[] dense;
	bool weighed = false;
	if (owners)
	{
		if (try opened = app.open_rig(mem))
		{
			view = opened;
			dense = app.weights(mem, &view);
			weighed = dense.len == app.geometry.positions.len * view.len();
			if (!weighed)
			{
				if (dense.len > 0) alloc::free(mem, dense);
				view.free(mem);
			}
		}
	}
	defer
	{
		if (weighed)
		{
			alloc::free(mem, dense);
			view.free(mem);
		}
	}

	DString out = dstring::new(mem);
	defer out.free();
	out.appendf(`{"count":%d,"listed":%d,"indices":[`, found.len, listed);
	for (usz i = 0; i < listed; i++)
	{
		if (i > 0) out.append_char(',');
		out.appendf("%d", found[i]);
	}
	out.append_string(`],"positions":[`);
	for (usz i = 0; i < listed; i++)
	{
		if (i > 0) out.append_char(',');
		out.appendf("%s", (JsonVec3)app.geometry.positions[found[i]]);
	}
	out.append_string(`],"shells":[`);
	for (usz i = 0; i < listed; i++)
	{
		if (i > 0) out.append_char(',');
		out.appendf("%d", shell_of.len > found[i] ? shell_of[found[i]] : 0);
	}
	out.append_char(']');
	if (weighed)
	{
		usz bones = view.len();
		out.append_string(`,"owners":[`);
		for (usz i = 0; i < listed; i++)
		{
			if (i > 0) out.append_char(',');
			usz row = found[i] * bones;
			usz best = 0;
			for (usz j = 1; j < bones; j++) if (dense[row + j] > dense[row + best]) best = j;
			out.append_char('"');
			json_escape_into(&out, view.names[best]);
			out.append_char('"');
		}
		out.append_char(']');
	}
	out.append_string(`,"space":"model space; indices are the ones paint_weights, pin_weights and get_weights use"}`);
	return out.copy_str(mem);
}

const String BLEND_WEIGHTS_SCHEMA = `{"type":"object","properties":{` +++ REGION_SCHEMA_KEYS +++ `,
	"top":{"type":"string","description":"The joint the region hangs from, which takes it whole at the top: the hips for a skirt, the chest for a cape."},
	"sides":{"type":"array","items":{"type":"string"},"description":"The joints blended in toward the bottom and the sides — the thighs for a skirt. Each vertex takes the one on its side of the mirror plane. Leave out to give the region to top alone."},
	"share":{"type":"number","description":"What a side joint takes at the bottom, on the outside edge. Default 0.8."},
	"share_top":{"type":"number","description":"The same at the top. Default 0.24."},
	"middle":{"type":"number","description":"How much of that is left on the mirror plane, as a fraction: 0 keeps the middle on top alone. Default 0.15."},
	"keep":{"type":"array","items":{"type":"string"},"description":"Joints left as they are on the region. Every other joint holding some of it is taken off."}
},"required":["top"]}`;

fn bool read_dots(AppState* app, Object* args, String key, uint[] into, usz* count, DString* detail) @private
{
	*count = 0;
	Object* listed = member(args, key);
	if (!listed) return true;
	if (!listed.is_array() || (usz)listed.get_len() > into.len)
	{
		detail.appendf(`"%s" is a list of at most %d joint names.`, key, into.len);
		return false;
	}
	for (usz i = 0; i < (usz)listed.get_len(); i++)
	{
		String? name = listed.get_string_at((sz)i);
		if (catch name)
		{
			detail.appendf(`"%s" holds joint names only.`, key);
			return false;
		}
		uint? id = resolve_dot(app, name, detail);
		if (catch id) return false;
		into[(*count)++] = id;
	}
	return true;
}

fn void append_dot_list(DString* out, AppState* app, uint[] ids) @private
{
	out.append_char('[');
	foreach (usz i, id : ids)
	{
		if (i > 0) out.append_char(',');
		Dot* dot = app.doc.find(id);
		out.append_char('"');
		append_bone_name(out, id, dot ? dot.name : "");
		out.append_char('"');
	}
	out.append_char(']');
}

<*
 blend_weights: a region weighted as cloth (`AppState.blend_region_recorded`).
*>
fn String? blend_weights_tool(AppState* app, Object* args, DString* detail)
{
	if (!takes_object(args, detail, `blend_weights takes an object: {"shell": n, "height": [from, to], "top": "hips", "sides": ["thigh_L", "thigh_R"]}`)) return VERTICES_REFUSED~;
	String named;
	if (!required_string(args, "top", &named, detail, `blend_weights needs "top": the joint the region hangs from. `)) return VERTICES_REFUSED~;
	uint top = resolve_dot(app, named, detail)!;
	VertexRegion region;
	if (!read_region(app, args, &region, detail)) return VERTICES_REFUSED~;
	if (!region.narrows())
	{
		detail.append_string(`blend_weights needs a region — "shell", "box", "height" or "side" — or it would weight the whole body as cloth.`);
		return VERTICES_REFUSED~;
	}
	uint[8] sides;
	usz side_count;
	if (!read_dots(app, args, "sides", sides[..], &side_count, detail)) return VERTICES_REFUSED~;
	uint[BLEND_HELD_MOST] keep;
	usz keep_count;
	if (!read_dots(app, args, "keep", keep[..], &keep_count, detail)) return VERTICES_REFUSED~;
	BlendShape shape = SKIRT_BLEND;
	shape.share = (float)math::clamp(args.get_float("share") ?? (double)shape.share, 0.0, 1.0);
	shape.share_top = (float)math::clamp(args.get_float("share_top") ?? (double)shape.share_top, 0.0, 1.0);
	shape.middle = (float)math::clamp(args.get_float("middle") ?? (double)shape.middle, 0.0, 1.0);

	int[] shell_of = app.shells.of.len == app.geometry.positions.len ? app.shells.of : (int[]){};
	uint[] vertices = region_vertices(mem, &region, app.geometry.positions, shell_of);
	defer if (vertices.len > 0) alloc::free(mem, vertices);
	BlendResult did = app.blend_region_recorded(vertices, top, sides[:side_count], shape, keep[:keep_count]);
	app.refresh_ui();

	DString out = dstring::new(mem);
	defer out.free();
	out.appendf(`{"selected":%d,"changed":%d,"columns":%d,"top":"`, vertices.len, did.changed, did.written);
	json_escape_into(&out, named);
	out.append_string(`","sides":`);
	append_dot_list(&out, app, sides[:side_count]);
	out.append_string(`,"cleared":`);
	append_dot_list(&out, app, did.cleared[:did.cleared_count]);
	out.append_string(`,"held":`);
	append_dot_list(&out, app, did.held[:did.held_count]);
	if (vertices.len == 0) out.append_string(`,"note":"the region holds no vertices: get_vertices with the same keys shows what it selects"`);
	if (did.held_count > 0) out.append_string(`,"held_means":"these joints' weights are now held as written everywhere, not only on the region: moving them no longer re-weights them. paint_weights reset puts a joint back on the automatic weights."`);
	out.append_char('}');
	return out.copy_str(mem);
}
