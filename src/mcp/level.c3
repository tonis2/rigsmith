<* The level over the wire: open_level, close_level, get_level and ground_at. *>
module crig;

import std::collections::object;
import std::math;

faultdef LEVEL_REFUSED;

fn void add_level_tools(ToolTable* table, AppState* app)
{
	table.add_tool({
		.name = "open_level",
		.description = "Open a level .glb behind the characters, as a backdrop with its own materials and lights: it is never selected, edited, saved with the characters or undone, and the floor grid goes while it is open. It is read over the next frames; get_level says how far it has got. frame points the camera at the whole level once it is in. Answers get_level's report.",
		.input_schema = `{"type":"object","properties":{"path":{"type":"string"},"frame":{"type":"boolean"}},"required":["path"]}`,
		.handler = &tool_open_level,
		.user_data = app,
		.hidden = true,
	});
	table.add_tool({
		.name = "close_level",
		.description = "Take the level away; the characters stay as they are. Answers get_level's report.",
		.input_schema = `{"type":"object","properties":{}}`,
		.handler = &tool_close_level,
		.user_data = app,
		.hidden = true,
	});
	table.add_tool({
		.name = "get_level",
		.description = "The open level: its path, state (none, waiting, reading, placing or shown), progress from 0 to 1, how many nodes, colliders and lights it brought, its bounds in metres, the seconds the read and the placing took, and whether the 3D view draws its colliders. colliders sets that view on or off.",
		.input_schema = `{"type":"object","properties":{"colliders":{"type":"boolean"}}}`,
		.handler = &tool_get_level,
		.user_data = app,
		.hidden = true,
	});
	table.add_tool({
		.name = "ground_at",
		.description = "The ground under a point of the open level: a ray straight down from 0.5 m above at [x,y,z], against the level's colliders only (plants and the characters never count), or under a pixel of the 3D view with screen [x,y] in the full-size screenshot's pixels. Answers hit, point, normal and the collider's name.",
		.input_schema = `{"type":"object","properties":{"at":{"type":"array","items":{"type":"number"}},"screen":{"type":"array","items":{"type":"number"}}}}`,
		.handler = &tool_ground_at,
		.user_data = app,
		.hidden = true,
	});
}

fn String level_phase_name(LevelPhase phase) @local
{
	switch (phase)
	{
		case NONE: return "none";
		case WAITING: return "waiting";
		case READING: return "reading";
		case PLACING: return "placing";
		case SHOWN: return "shown";
	}
}

<*
 The level as get_level reports it. The caller owns the result.

 @param [&in] app
*>
fn String level_json(AppState* app)
{
	LevelReport report = level_report();
	DString out = dstring::new(mem);
	defer out.free();
	out.append_string(`{"path":`);
	append_json_string(&out, app.level_path);
	// Headless, a level is remembered and never read.
	String state = app.has_level() && !hosted() ? "waiting" : level_phase_name(report.phase);
	out.appendf(`,"state":"%s","progress":%s,"nodes":%d,"colliders":%d,"lights":%d`,
		state, (JsonFloat)report.progress, report.nodes, report.colliders, report.lights)!!;
	if (report.boxed)
	{
		out.appendf(`,"bounds":{"min":%s,"max":%s}`, (JsonVec3)report.box.min, (JsonVec3)report.box.max)!!;
	}
	out.appendf(`,"read_seconds":%s,"place_seconds":%s,"colliders_shown":%s}`,
		(JsonFloat)((float)report.read_ms / 1000.0f), (JsonFloat)((float)report.place_ms / 1000.0f),
		app.show_colliders ? "true" : "false")!!;
	return out.copy_str(mem);
}

fn String? tool_open_level(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;
	if (!takes_object(args, detail, `open_level takes {"path": "forest.glb", "frame": true}`)) return LEVEL_REFUSED~;
	String path;
	if (!required_string(args, "path", &path, detail, "open_level needs the level's path")) return LEVEL_REFUSED~;
	bool frame = args.get_bool("frame") ?? false;
	if (!app.open_level(path, frame))
	{
		detail.append_string(app.notice());
		return LEVEL_REFUSED~;
	}
	app.refresh_ui();
	return level_json(app);
}

fn String? tool_close_level(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;
	app.close_level();
	app.refresh_ui();
	return level_json(app);
}

fn String? tool_get_level(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;
	if (args != null && args.is_keyable() && member(args, "colliders") != null)
	{
		bool? shown = args.get_bool("colliders");
		if (catch shown)
		{
			detail.append_string(`"colliders" must be true or false: whether the 3D view draws the level's colliders`);
			return LEVEL_REFUSED~;
		}
		app.show_colliders = shown;
		app.refresh_ui();
	}
	return level_json(app);
}

fn String? tool_ground_at(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;
	if (!takes_object(args, detail, `ground_at takes {"at": [x,y,z]} or {"screen": [x,y]}`)) return LEVEL_REFUSED~;
	if (!level_shown())
	{
		detail.append_string("there is no level in yet — open_level, then wait for get_level to say shown");
		return LEVEL_REFUSED~;
	}
	GroundHit hit;
	Vec3 at;
	Object* screen = member(args, "screen");
	if (as_vec3(member(args, "at"), &at))
	{
		hit = ground_below(at);
	}
	else if (screen != null && screen.is_array() && screen.get_len() == 2)
	{
		double? x = screen.get_float_at(0);
		double? y = screen.get_float_at(1);
		if (catch x, y)
		{
			detail.append_string(`"screen" is [x,y] in the full-size screenshot's pixels`);
			return LEVEL_REFUSED~;
		}
		hit = ground_under_pixel((float)x, (float)y);
	}
	else
	{
		detail.append_string(`ground_at needs "at": [x,y,z] in metres, or "screen": [x,y] in the full-size screenshot's pixels`);
		return LEVEL_REFUSED~;
	}
	if (!hit.hit) return `{"hit":false}`.copy(mem);
	DString out = dstring::new(mem);
	defer out.free();
	out.appendf(`{"hit":true,"point":%s,"normal":%s,"collider":`, (JsonVec3)hit.point, (JsonVec3)hit.normal)!!;
	append_json_string(&out, level_node_name(hit.node));
	out.append_char('}');
	return out.copy_str(mem);
}
