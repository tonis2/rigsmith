<* The cutscenes over the wire: get_cutscenes, get_cutscene, set_cutscene, select_cutscene, set_cutscene_time, add_actor and export_cutscene. *>
module crig;

import std::collections::object;
import std::io;
import std::io::file;
import std::math;

faultdef CUTSCENE_REFUSED;

fn void add_cutscene_tools(ToolTable* table, AppState* app)
{
	table.add_tool({
		.name = "get_cutscenes",
		.description = "The scene's cutscenes (index, name, duration, fps and how many actors, strips and paths each has), which one is active, the preview's state and time, the scene's actors (each character with a row: its index, file name, row, level node, scale, and lift: how far the level node's origin stands over its copy's feet), the open level's rigged characters (name, position, facing in degrees, height, the height its feet stand at, and the character standing in for it or -1), and how many cutscene steps undo and redo hold.",
		.input_schema = `{"type":"object","properties":{}}`,
		.handler = &tool_get_cutscenes,
		.user_data = app,
		.hidden = true,
	});
	table.add_tool({
		.name = "get_cutscene",
		.description = "One cutscene whole, the active one unless index says: the CUSTOM_cutscene extension's shape (name, duration, fps, actors with row and strips, paths with name, length and points) plus each path's knots, each actor's character (its index in get_scene, -1 for none) and level_node, and one_offs: [{row, clip}], the clips made for this cutscene alone, each clip in the session file's form (name, duration, loop, blend, keys [{time, dots [{joint, axis, angle, move, bone, channels}]}], pins). A strip with one_off true plays its actor's one-off named clip. A move's path is its index into these paths. A play carries ground_speed (m/s) when one was typed and speed_held true when its speed is held. problems lists what would be refused or look wrong. set_cutscene takes the same shape back.",
		.input_schema = `{"type":"object","properties":{"index":{"type":"integer"}}}`,
		.handler = &tool_get_cutscene,
		.user_data = app,
		.hidden = true,
	});
	table.add_tool({
		.name = "set_cutscene",
		.description = "Write a cutscene as one undo step of the cutscene history (undo with history \"cutscene\"). cutscene is get_cutscene's shape: it replaces the one at index (default the active one), or with new true is added; a path's points are sampled from its knots when it has any and dropped onto the open level's ground, and its length is that dropped line's; a move or play takes ground_speed (m/s, scene only), and a play speed_held (scene only: Rigsmith does not refit a held walk to its move's pace); every speed is taken as given, none refitted; character and level_node are read-only. Without cutscene, new true adds an empty one (name optional) holding every actor, and delete true deletes the one at index. The cutscene written becomes the active one. Answers get_cutscene's report, or get_cutscenes' after a delete.",
		.input_schema = `{"type":"object","properties":{"index":{"type":"integer"},"cutscene":{"type":"object"},"new":{"type":"boolean"},"name":{"type":"string"},"delete":{"type":"boolean"}}}`,
		.handler = &tool_set_cutscene,
		.user_data = app,
		.hidden = true,
	});
	table.add_tool({
		.name = "select_cutscene",
		.description = "Make a cutscene the active one, by index or name: the one the Animations dock shows, the preview poses and export_cutscene writes. Not an undo step. Answers get_cutscenes' report.",
		.input_schema = `{"type":"object","properties":{"index":{"type":"integer"},"name":{"type":"string"}}}`,
		.handler = &tool_select_cutscene,
		.user_data = app,
		.hidden = true,
	});
	table.add_tool({
		.name = "set_cutscene_time",
		.description = "The active cutscene's transport. preview true stands every actor where the cutscene has it and plays the clip it plays then, found by name among its character's clips (a one-off among the cutscene's); false puts every character back as it was. t moves the playhead (seconds, inside the duration); play true plays from there in the window (and turns the preview on), false pauses. one_off {actor: row, strip: index} edits the one-off that strip plays with the character's own tools: its character is the focus, its clip the one open in the timeline (pose_joint, set_pins, the key tools and undo work on it), standing where the cutscene has it, the others posed at the cutscene time its playhead stands for, and t then moves that playhead; one_off false goes back, the edit one cutscene undo step. Answers the time and each actor's pose at it: position, facing in degrees, the strip playing, its clip, the clip time before and after a loop wraps it, whether it holds, and whether its character has that clip; and the one-off being edited, if any.",
		.input_schema = `{"type":"object","properties":{"t":{"type":"number"},"play":{"type":"boolean"},"preview":{"type":"boolean"},"one_off":{"description":"{actor: row, strip: index} to edit, false to go back","anyOf":[{"type":"object","properties":{"actor":{"type":"string"},"strip":{"type":"integer"}},"required":["actor","strip"]},{"type":"boolean"}]}}}`,
		.handler = &tool_set_cutscene_time,
		.user_data = app,
		.hidden = true,
	});
	table.add_tool({
		.name = "add_actor",
		.description = "Make a character an actor of the scene: a row is how the game finds it, unique in the scene. With path, the character file is loaded (or found when already in) with row (default a safe name from the file), standing at at [x,y,z] when given, dropped onto the level's ground under it when ground is true. With level_node alone, that rigged character of the open level is read from the level file itself by its armature: its joints, and the level's animations that drive them by the file's names, as its clips; it stands where the level puts the node at the node's scale, has no mesh or file of its own, and the level's own copy is drawn posed by it. It is read-only outside one-off editing (an edit on it is taken back and refused) and is never saved; several can be read from one level. With level_node and path, the file stands in for that rigged character instead (replacing one read from the level, keeping its row): at its place and facing with its feet where the copy's are, scaled to its height, its row the node's name; the level's own copy is hidden until the actor is removed. With neither, the character being edited (or the one character names) becomes an actor, or gets row as its new row, renamed in every cutscene; ground true drops it as its own undo step. Adds the actor to the active cutscene; the row is one cutscene undo step. Answers get_cutscenes' report.",
		.input_schema = `{"type":"object","properties":{"path":{"type":"string"},"level_node":{"type":"string"},"row":{"type":"string"},"at":{"type":"array","items":{"type":"number"}},"ground":{"type":"boolean"}}}`,
		.handler = &tool_add_actor,
		.user_data = app,
		.hidden = true,
	});
	table.add_tool({
		.name = "export_cutscene",
		.description = "Write the active cutscene (or the one at index, which becomes active) as a CUSTOM_cutscene .cutscene.glb, or .gltf text by the extension: paths sampled every 0.25 m from their knots and dropped onto the ground, lifted for an actor standing in for a level node by how far that node's origin stands over its feet, a place written only for actors with no level node. What the game would refuse is refused with the reason, and nothing is written.",
		.input_schema = `{"type":"object","properties":{"path":{"type":"string"},"index":{"type":"integer"}},"required":["path"]}`,
		.handler = &tool_export_cutscene,
		.user_data = app,
		.hidden = true,
	});
}

// The index a call names, the active cutscene's without one.
fn bool cut_index_of(AppState* app, Object* args, usz* out, DString* detail) @local
{
	*out = app.cut_active;
	if (member(args, "index") != null)
	{
		long? given = args.get_long("index");
		if (catch given)
		{
			detail.append_string(`"index" is a cutscene's position in get_cutscenes`);
			return false;
		}
		if (given < 0 || (usz)given >= (usz)app.cutscenes.len())
		{
			detail.appendf("index %d names no cutscene; the scene has %d", given, app.cutscenes.len())!!;
			return false;
		}
		*out = (usz)given;
		return true;
	}
	if (app.cutscenes.len() == 0)
	{
		detail.append_string(`the scene has no cutscene yet: set_cutscene {"new": true} adds one`);
		return false;
	}
	return true;
}

fn double cut_facing_degrees(Quaternionf rotation) @local => math::round(cut_heading_of(rotation) * 1800.0 / math::PI) / 10.0 + 0.0;

<* get_cutscenes' report. The caller owns it. *>
fn String cutscenes_json(AppState* app)
{
	DString out = dstring::new(mem);
	defer out.free();
	out.append_string(`{"cutscenes":[`);
	foreach (usz i, &c : app.cutscenes)
	{
		usz strips;
		foreach (&a : c.actors) strips += a.strips.len;
		if (i > 0) out.append_char(',');
		out.appendf(`{"index":%d,"name":`, i)!!;
		append_json_string(&out, c.name);
		out.appendf(`,"duration":%s,"fps":%s,"actors":%d,"strips":%d,"paths":%d}`,
			(JsonFloat)c.duration, (JsonFloat)c.fps, c.actors.len, strips, c.paths.len)!!;
	}
	out.appendf(`],"active":%d,"preview":%s,"playing":%s,"time":%s,"actors":[`,
		app.cutscenes.len() > 0 ? (sz)app.cut_active : -1, app.cut_preview, app.cut_playing, (JsonFloat)app.cut_time)!!;
	bool first = true;
	for (usz i = 0; i < app.character_count(); i++)
	{
		Character* c = app.character(i);
		if (c.actor_row.len == 0) continue;
		out.append_string(first ? "" : ",");
		first = false;
		out.appendf(`{"character":%d,"name":`, i)!!;
		append_json_string(&out, c.label());
		out.append_string(`,"row":`);
		append_json_string(&out, c.actor_row);
		out.append_string(`,"level_node":`);
		append_json_string(&out, c.level_node);
		out.appendf(`,"read_from":"%s"`, character_source(c))!!;
		out.appendf(`,"scale":%s,"lift":%s}`, (JsonFloat)(c.stage_scale > 0.0f ? c.stage_scale : 1.0f), (JsonFloat)c.stage_lift)!!;
	}
	out.append_string(`],"level_characters":[`);
	@pool()
	{
		foreach (usz k, lc : level_characters(tmem))
		{
			if (k > 0) out.append_char(',');
			out.append_string(`{"name":`);
			append_json_string(&out, lc.name);
			out.appendf(`,"position":%s,"facing":%s,"height":%s,"feet":%s,"taken_by":%d}`, (JsonVec3)lc.position,
				(JsonFloat)(float)cut_facing_degrees(lc.rotation), (JsonFloat)lc.height, (JsonFloat)lc.floor,
				app.level_node_character(lc.name))!!;
		}
	};
	out.appendf(`],"history":{"undo":%d,"redo":%d}}`, app.cut_history.undo.len(), app.cut_history.redo.len())!!;
	return out.copy_str(mem);
}

<* get_cutscene's report for cutscene `i`. The caller owns it. *>
fn String cutscene_report_json(AppState* app, usz i)
{
	// A one-off being edited is reported as it is now.
	app.sync_one_off_now();
	DString out = dstring::new(mem);
	defer out.free();
	Cutscene* cutscene = app.cutscenes.get_ref((sz)i);
	out.appendf(`{"index":%d,"active":%s,"cutscene":`, i, i == app.cut_active)!!;
	@pool()
	{
		append_cutscene_json(&out, cutscene, points: true, links: app.cut_links(cutscene, tmem));
	};
	out.append_string(`,"problems":[`);
	// Problems are the active cutscene's; another is picked for the length of the count.
	usz was = app.cut_active;
	app.cut_active = i;
	String[] problems = app.cutscene_problem_texts(mem);
	app.cut_active = was;
	defer free_names(mem, problems);
	foreach (usz k, text : problems)
	{
		if (k > 0) out.append_char(',');
		append_json_string(&out, text);
	}
	out.append_string("]}");
	return out.copy_str(mem);
}

fn String? tool_get_cutscenes(Object* args, void* user_data, DString* detail) @private
{
	return cutscenes_json((AppState*)user_data);
}

fn String? tool_get_cutscene(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;
	usz i;
	if (!cut_index_of(app, args, &i, detail)) return CUTSCENE_REFUSED~;
	return cutscene_report_json(app, i);
}

fn String? tool_set_cutscene(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;
	if (!takes_object(args, detail, `set_cutscene takes {"cutscene": {...}} or {"new": true} or {"index": 0, "delete": true}`)) return CUTSCENE_REFUSED~;
	bool fresh = args.get_bool("new") ?? false;
	bool gone = args.get_bool("delete") ?? false;
	Object* given = member(args, "cutscene");
	if (gone)
	{
		usz i;
		if (given != null || fresh)
		{
			detail.append_string(`delete takes only the index of the cutscene to delete`);
			return CUTSCENE_REFUSED~;
		}
		if (!cut_index_of(app, args, &i, detail)) return CUTSCENE_REFUSED~;
		(void)app.delete_cutscene(i);
		app.refresh_ui();
		return cutscenes_json(app);
	}
	if (given == null)
	{
		if (!fresh)
		{
			detail.append_string(`set_cutscene needs "cutscene" (get_cutscene's shape), or "new": true for an empty one`);
			return CUTSCENE_REFUSED~;
		}
		String name = args.get_string("name") ?? "";
		usz made = app.add_cutscene(name);
		app.refresh_ui();
		return cutscene_report_json(app, made);
	}
	usz i = (usz)app.cutscenes.len();
	if (!fresh && !cut_index_of(app, args, &i, detail)) return CUTSCENE_REFUSED~;
	DString why = dstring::new(mem);
	defer why.free();
	Cutscene? read = cutscene_from_json(mem, given, &why);
	if (catch read)
	{
		detail.appendf("the cutscene was not taken: %s", why.str_view())!!;
		return CUTSCENE_REFUSED~;
	}
	Cutscene taken = read;
	if (taken.name.len == 0) taken.name = app.cutscenes.len() > 0 && i < (usz)app.cutscenes.len()
		? app.cutscenes.get_ref((sz)i).name.copy(mem) : CUT_DEFAULT_NAME.copy(mem);
	if (!(taken.duration > 0.0f)) taken.duration = CUT_NEW_DURATION;
	if (!(taken.fps > 0.0f)) taken.fps = CUT_DEFAULT_FPS;
	app.replace_cutscene(i, taken);
	app.refresh_ui();
	return cutscene_report_json(app, i);
}

fn String? tool_select_cutscene(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;
	if (!takes_object(args, detail, `select_cutscene takes {"index": 0} or {"name": "Intro"}`)) return CUTSCENE_REFUSED~;
	usz i;
	if (try String name = args.get_string("name"))
	{
		sz found = -1;
		foreach (usz k, &c : app.cutscenes) if (c.name == name) found = (sz)k;
		if (found < 0)
		{
			detail.appendf("no cutscene is called '%s'", name)!!;
			return CUTSCENE_REFUSED~;
		}
		i = (usz)found;
	}
	else if (member(args, "index") == null || !cut_index_of(app, args, &i, detail))
	{
		if (detail.len() == 0) detail.append_string(`select_cutscene needs "index" or "name"`);
		return CUTSCENE_REFUSED~;
	}
	(void)app.select_cutscene(i);
	app.refresh_ui();
	return cutscenes_json(app);
}

fn String? tool_set_cutscene_time(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;
	if (!takes_object(args, detail, `set_cutscene_time takes {"t": 1.5, "preview": true, "play": false}`)) return CUTSCENE_REFUSED~;
	Cutscene* cutscene = app.cutscene();
	if (!cutscene)
	{
		detail.append_string(`the scene has no cutscene yet: set_cutscene {"new": true} adds one`);
		return CUTSCENE_REFUSED~;
	}
	if (member(args, "preview") != null)
	{
		bool? on = args.get_bool("preview");
		if (catch on)
		{
			detail.append_string(`"preview" is true or false`);
			return CUTSCENE_REFUSED~;
		}
		if (!app.set_cutscene_preview(on))
		{
			detail.append_string(app.notice());
			return CUTSCENE_REFUSED~;
		}
	}
	Object* one_off = member(args, "one_off");
	if (one_off != null)
	{
		if (one_off.is_bool() && !one_off.b)
		{
			(void)app.back_to_cutscene();
		}
		else
		{
			String row = one_off.is_map() ? one_off.get_string("actor") ?? "" : "";
			long k = one_off.is_map() ? one_off.get_long("strip") ?? -1 : -1;
			int actor = app.cutscene().actor_by_row(row);
			if (actor < 0 || k < 0 || (usz)k >= app.cutscene().actors[actor].strips.len)
			{
				detail.append_string(`"one_off" is {"actor": "<row>", "strip": index} naming a strip that plays a one-off, or false`);
				return CUTSCENE_REFUSED~;
			}
			if (!app.edit_cut_one_off((usz)actor, (usz)k))
			{
				detail.append_string(app.notice());
				return CUTSCENE_REFUSED~;
			}
		}
	}
	if (member(args, "t") != null)
	{
		double? t = args.get_float("t");
		if (catch t)
		{
			detail.append_string(`"t" is seconds from the cutscene's start`);
			return CUTSCENE_REFUSED~;
		}
		if (t < 0.0 || t > (double)cutscene.duration + 1e-6)
		{
			detail.appendf(`"t" is %.9g, and the cutscene runs from 0 to %.9g`, t, cutscene.duration)!!;
			return CUTSCENE_REFUSED~;
		}
		app.show_cutscene_at((float)t);
	}
	if (member(args, "play") != null)
	{
		bool? play = args.get_bool("play");
		if (catch play)
		{
			detail.append_string(`"play" is true or false`);
			return CUTSCENE_REFUSED~;
		}
		(void)app.play_cutscene(play);
	}
	app.refresh_ui();
	return cutscene_poses_json(app);
}

<* The active cutscene's time and every actor's pose at it. The caller owns it. *>
fn String cutscene_poses_json(AppState* app)
{
	Cutscene* cutscene = app.cutscene();
	DString out = dstring::new(mem);
	defer out.free();
	out.appendf(`{"time":%s,"duration":%s,"preview":%s,"playing":%s`,
		(JsonFloat)app.cut_time, (JsonFloat)cutscene.duration, app.cut_preview, app.cut_playing)!!;
	if (app.one_off_open())
	{
		out.append_string(`,"one_off":{"actor":`);
		append_json_string(&out, app.one_off.row);
		out.append_string(`,"clip":`);
		append_json_string(&out, app.one_off.name);
		out.appendf(`,"character":%d,"clip_time":%s}`, app.character_by_id(app.one_off.character), (JsonFloat)app.edit_time)!!;
	}
	out.append_string(`,"actors":[`);
	app.refresh_cut_homes(cutscene);
	@pool()
	{
		CutCurve[] curves = cutscene_curves(tmem, cutscene);
		foreach (usz k, &actor : cutscene.actors)
		{
			CutActorPose pose = cutscene_actor_shown(cutscene, curves, k, app.cut_time);
			if (k > 0) out.append_char(',');
			out.append_string(`{"row":`);
			append_json_string(&out, actor.row);
			sz who = app.actor_character(actor.row);
			out.appendf(`,"character":%d,"position":%s,"facing":%s,"strip":%d`, who, (JsonVec3)pose.position,
				(JsonFloat)(float)cut_facing_degrees(pose.rotation), pose.strip)!!;
			if (pose.strip >= 0)
			{
				CutStrip* s = &actor.strips[pose.strip];
				out.append_string(`,"clip":`);
				append_json_string(&out, s.clip);
				out.appendf(`,"clip_time":%s,"holding":%s`, (JsonFloat)pose.clip_time, pose.holding)!!;
				AnimRef ref = NO_ANIM;
				float length = -1.0f;
				CutOneOff* one = cutscene.one_off_of(k, s);
				if (one)
				{
					length = one.clip.duration;
				}
				else if (who >= 0 && !s.one_off)
				{
					app.@as_character((usz)who)
					{
						if (AnimTemplate* clip = app.bound_clip_named(s.clip, &ref)) length = clip.duration;
					};
				}
				out.appendf(`,"clip_found":%s`, length >= 0.0f)!!;
				if (length >= 0.0f) out.appendf(`,"clip_local":%s`, (JsonFloat)cut_clip_local(pose.clip_time, length, s.loop))!!;
			}
			out.append_char('}');
		}
	};
	out.append_string("]}");
	return out.copy_str(mem);
}

fn String? tool_add_actor(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;
	if (!takes_object(args, detail, `add_actor takes {"path": "hero.glb", "row": "hero"}, {"level_node": "guard_armature"} or {"level_node": "guard_armature", "path": "guard.glb"}`)) return CUTSCENE_REFUSED~;
	String row = args.get_string("row") ?? "";
	bool ground = args.get_bool("ground") ?? false;
	Vec3 at;
	bool placed = as_vec3(member(args, "at"), &at);
	if (member(args, "at") != null && !placed)
	{
		detail.append_string(`"at" is [x,y,z] in metres`);
		return CUTSCENE_REFUSED~;
	}
	String path = args.get_string("path") ?? "";
	String node = args.get_string("level_node") ?? "";
	if (path.len > 0 && !file::is_file(path))
	{
		detail.appendf("there is no file at %s", path)!!;
		return CUTSCENE_REFUSED~;
	}
	if (node.len > 0)
	{
		if (!app.take_level_actor(node, path, row))
		{
			detail.append_string(app.notice());
			return CUTSCENE_REFUSED~;
		}
	}
	else if (path.len > 0)
	{
		if (!app.add_actor_from_file(path, row, placed ? &at : null, ground))
		{
			detail.append_string(app.notice());
			return CUTSCENE_REFUSED~;
		}
	}
	else
	{
		if (placed)
		{
			detail.append_string(`"at" places a character loaded from "path"; move one already in the scene with the move tools`);
			return CUTSCENE_REFUSED~;
		}
		if (!app.make_actor(app.active, row))
		{
			detail.append_string(app.notice());
			return CUTSCENE_REFUSED~;
		}
		if (ground && !app.drop_actor_to_ground(app.active))
		{
			detail.append_string("there is no level ground under it — open_level, and wait for get_level to say shown");
			return CUTSCENE_REFUSED~;
		}
	}
	app.refresh_ui();
	return cutscenes_json(app);
}

fn String? tool_export_cutscene(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;
	if (!takes_object(args, detail, `export_cutscene takes {"path": "intro.cutscene.glb"}`)) return CUTSCENE_REFUSED~;
	String path;
	if (!required_string(args, "path", &path, detail, "export_cutscene needs where to write the file")) return CUTSCENE_REFUSED~;
	usz i;
	if (!cut_index_of(app, args, &i, detail)) return CUTSCENE_REFUSED~;
	(void)app.select_cutscene(i);
	DString why = dstring::new(mem);
	defer why.free();
	if (!app.export_cutscene(path, &why))
	{
		detail.appendf("not written: %s", why.str_view())!!;
		return CUTSCENE_REFUSED~;
	}
	Cutscene* cutscene = app.cutscene();
	DString out = dstring::new(mem);
	defer out.free();
	out.append_string(`{"written":`);
	append_json_string(&out, path);
	out.appendf(`,"name":`)!!;
	append_json_string(&out, cutscene.name);
	out.appendf(`,"actors":%d,"duration":%s}`, cutscene.actors.len, (JsonFloat)cutscene.duration)!!;
	return out.copy_str(mem);
}
