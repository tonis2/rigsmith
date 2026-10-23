<*
 The weight tools: show_weights, get_weights, paint_weights, pin_weights, fix_strays and
 get_shells.

 Weights are derived rather than authored — every rig edit rebinds from scratch —
 so nothing here owns any of it. What these do is *report* on the bind and state
 rows over it: paint_weights a share, pin_weights the blunt form, both the one
 layer of hand edits the brush writes too (the multipliers sessions from before
 carry still apply until reset). `AppState` does the arithmetic; this file is the
 selection language, the payloads, and the refusals.

 The pairing that repeats: `show_weights` puts a picture in front of a person and
 `get_weights` answers the caller, and neither is the other's precondition. The
 same shape as `play` against `get_pose`.
*>
module crig;

import rig;
import std::collections::object;
import std::math;
import std::collections::list;

faultdef WEIGHTS_BAD_ARGS;

<*
 show_weights: paint one of the weight views, for the person at the screen.

 Changes the selection when it is given a dot, because that is where the falloff
 view reads its joint from — the same state the F key acts on. Nothing else here
 touches the document.
*>
fn String? tool_show_weights(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;

	if (!takes_object(args, detail, `show_weights takes an object: {"mode": one of off, territory, falloff, "dot": a name from get_skeleton, "unused": true or false}`)) return WEIGHTS_BAD_ARGS~;

	// The Unused overlay sits beside the view rather than being one of them, so
	// a call that only flips it leaves the view as it is.
	bool? unused = args.get_bool("unused");
	String asked;
	if (try given = args.get_string("mode"))
	{
		asked = given;
	}
	else if (try unused)
	{
		if (unused != app.show_unused) app.toggle_unused();
		app.refresh_ui();
		return showing_json(app);
	}
	else
	{
		detail.append_string(`show_weights needs "mode": one of off, territory, falloff, or "unused" on its own. get_weights answers the same as numbers and needs no view to be on.`);
		return WEIGHTS_BAD_ARGS~;
	}

	TintMode mode;
	switch (asked)
	{
		case "off": mode = OFF;
		case "territory": mode = TERRITORY;
		case "falloff": mode = FALLOFF;
		default:
			detail.appendf(
				`"%s" is not a weight view. Use territory for which dot owns each vertex, falloff for one dot's share of each, or off.`,
				asked);
			return WEIGHTS_BAD_ARGS~;
	}

	if (try named = args.get_string("dot"))
	{
		app.selected = resolve_dot(app, named, detail)!;
	}
	else if (mode == FALLOFF && app.selected == 0)
	{
		detail.append_string(`the falloff view ramps from one dot and none is selected — pass "dot" with a name from get_skeleton.`);
		return WEIGHTS_BAD_ARGS~;
	}

	if (try unused) if (unused != app.show_unused) app.toggle_unused();
	app.show_tint(mode);
	app.refresh_ui();
	return showing_json(app);
}

<*
 What `show_weights` answers with: the view that is now on the screen, and what
 a person looking at it is seeing.

 The reading is spelled out because the caller is usually the one describing the
 picture to whoever is in front of it, and a colour named without its meaning is
 no more use over a wire than it is in a screenshot.
*>
fn String showing_json(AppState* app)
{
	DString out = dstring::new(mem);
	defer out.free();

	String mode;
	String painting;
	switch (app.tint_mode)
	{
		case TERRITORY:
			mode = "territory";
			painting = "one colour per dot: the dot each vertex belongs to more than any other. The boundary between two colours is the seam the mesh will bend at.";
		case FALLOFF:
			mode = "falloff";
			painting = "one dot's share of each vertex on a ramp: grey none, orange all of it.";
		default:
			mode = "off";
			painting = "the mesh in its own colour, with no weight view over it.";
	}

	Dot* selected = app.doc.find(app.selected);

	out.append_string(`{"showing":"`);
	out.append_string(mode);
	out.append_string(`","dot":`);
	if (app.tint_mode == FALLOFF && selected)
	{
		out.append_char('"');
		append_bone_name(&out, selected.id, selected.name);
		out.append_char('"');
	}
	else
	{
		out.append_string("null");
	}
	out.append_string(`,"painting":"`);
	json_escape_into(&out, painting);
	out.appendf(`","unused":%s`, app.show_unused ? "true" : "false");
	if (app.show_unused)
	{
		out.append_string(`,"unused_marks":"magenta over the view: vertices no dot holds. Nothing moves them, so posed or exported they follow the root."`);
	}
	out.append_char('}');

	return out.copy_str(mem);
}

<*
 get_weights: the same three views, as numbers.

 A read, and unconditional: it binds its own copy rather than reporting whatever
 the screen last painted, so it answers with no view on and cannot answer with a
 stale one. `vertices` adds those vertices' rows, and `strays` the islands of
 weight a pose pulls out of the body — what to read when a spike shows and
 nothing on screen says whose it is.
*>
fn String? tool_get_weights(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;

	uint dot = 0;
	uint[] rows = {};
	bool strays = false;
	if (args != null && args.is_keyable())
	{
		if (try named = args.get_string("dot")) dot = resolve_dot(app, named, detail)!;
		if (try Object* listed = args.get("vertices"))
		{
			if (!listed.is_indexable())
			{
				detail.append_string(`"vertices" is a list of vertex indices.`);
				return WEIGHTS_BAD_ARGS~;
			}
			usz count = app.geometry.positions.len;
			rows = alloc::new_array(mem, uint, listed.get_len());
			for (sz i = 0; i < listed.get_len(); i++)
			{
				double at = listed.get_float_at(i) ?? -1.0;
				if (at < 0.0 || at >= (double)count)
				{
					alloc::free(mem, rows);
					detail.appendf(`vertices[%d] is not a vertex of this mesh: it has %d, numbered from 0.`, i, count);
					return WEIGHTS_BAD_ARGS~;
				}
				rows[i] = (uint)at;
			}
		}
		strays = args.get_bool("strays") ?? false;
	}
	defer if (rows.len > 0) alloc::free(mem, rows);
	return weights_json(app, dot, detail, rows, strays);
}

<*
 What `get_weights` answers with: the ownership table, and a surveyed dot's hold
 on its neighbours.

 `owns` and `reaches` answer different questions and the gap between them is the
 point. A dot owns a vertex when no other dot holds it more strongly — that is
 the territory view, and every vertex is owned by exactly one dot. It reaches a
 vertex when it holds any usable share of it, so the reaches of two neighbours
 overlap, and the size of that overlap is how much they will fight over the mesh
 between them.

 `rows` is each vertex asked for, as the views show it: the joints holding it
 down to `AREA_LEAK_FLOOR`, and whose edit wrote its pins. `strays` is
 `AppState.stray_islands`, each with up to `STRAY_LISTED` of its vertices.

 @param dot : `The dot to survey, or 0 for the table alone.`
 @param rows : `Vertices whose rows to add, in range.`
 @param strays : `Add the stray islands.`
 @return? RIG_EMPTY : `No mesh or no rig; the reason is left in detail.`
*>
fn String? weights_json(AppState* app, uint dot, DString* detail, uint[] rows = {}, bool strays = false)
{
	WeightSurvey? surveyed = app.survey_weights(mem, dot);
	if (catch surveyed)
	{
		detail.append_string(
			"nothing here to weigh: a bind needs a mesh and at least one dot on it. get_scene says whether a model is loaded, get_skeleton what is placed on it.");
		return RIG_EMPTY~;
	}
	WeightSurvey survey = surveyed;
	defer survey.free(mem);

	DString out = dstring::new(mem);
	defer out.free();

	out.appendf(`{"vertices":%d,"unclaimed":%d,"unused":%d,"floor":%s,"dots":[`,
		survey.vertices, survey.unclaimed, survey.unused, (JsonFloat)SHOWN_FLOOR);

	foreach (i, stake : survey.stakes)
	{
		if (i > 0) out.append_char(',');
		out.append_string(`{"name":"`);
		append_bone_name(&out, stake.dot, stake.name);
		out.appendf(`","owns":%d,"reaches":%d}`, stake.owns, stake.reaches);
	}
	out.append_char(']');

	if (dot != 0)
	{
		JointStake surveyed_stake = { .dot = dot };
		foreach (stake : survey.stakes)
		{
			if (stake.dot == dot) surveyed_stake = stake;
		}

		out.append_string(`,"dot":"`);
		append_bone_name(&out, surveyed_stake.dot, surveyed_stake.name);
		out.appendf(`","owns":%d,"reaches":%d,"shared":[`,
			surveyed_stake.owns, surveyed_stake.reaches);

		foreach (i, share : survey.shared)
		{
			if (i > 0) out.append_char(',');
			out.append_string(`{"name":"`);
			append_bone_name(&out, share.dot, share.name);
			out.appendf(`","vertices":%d,"mean":%.4g,"peak":%.4g}`,
				share.vertices, share.mean, share.peak);
		}
		out.append_char(']');
	}

	if (rows.len > 0) vertex_rows_json(app, &out, rows);
	if (strays) strays_json(app, &out);

	out.append_char('}');
	return out.copy_str(mem);
}

// How many of a stray island's vertices `get_weights` lists.
const usz STRAY_LISTED = 32;

// The name a dot goes by in a reply, bone_<id> when it has none.
fn void append_dot_name(DString* out, AppState* app, uint id) @private
{
	Dot* dot = app.doc.find(id);
	append_bone_name(out, id, dot ? dot.name : "");
}

fn void vertex_rows_json(AppState* app, DString* out, uint[] rows) @private
{
	out.append_string(`,"rows":[`);
	RigView? opened = app.open_rig(mem);
	if (try view = opened)
	{
		defer view.free(mem);
		usz bones = view.len();
		usz count = app.geometry.positions.len;
		// The rows the views paint, through the one funnel.
		float[] shown = app.weights(mem, &view);
		defer if (shown.len > 0) alloc::free(mem, shown);
		float[] row = alloc::new_array(mem, float, (sz)bones);
		defer alloc::free(mem, row);
		uint[SKIN_INFLUENCES * 2] dots;
		float[SKIN_INFLUENCES * 2] shares;
		foreach (i, v : rows)
		{
			if (bones == 0 || shown.len < count * bones) break;
			if (i > 0) out.append_char(',');
			share_row(shown[(usz)v * bones:bones], row);
			usz held = strongest_shares(row, view.dot_ids, dots[..], shares[..]);
			out.appendf(`{"vertex":%d,"at":%s,"joints":[`, v, (JsonVec3)app.geometry.positions[v]);
			for (usz k = 0; k < held; k++)
			{
				if (k > 0) out.append_char(',');
				out.append_string(`{"name":"`);
				append_dot_name(out, app, dots[k]);
				// The joint's own weight beside its share: columns are not rescaled
				// around each other, so the two differ wherever a row does not sum to one.
				sz joint = view.joint_of(dots[k]);
				float weight = joint >= 0 ? shown[(usz)v * bones + (usz)joint] : 0.0f;
				out.appendf(`","share":%.4g,"weight":%.4g,"edited":%s}`, shares[k], weight,
					app.weights_held(dots[k]) ? "true" : "false");
			}
			out.append_string("]}");
		}
	}
	out.append_char(']');
}

fn void strays_json(AppState* app, DString* out) @private
{
	StrayIsland[] strays = app.stray_islands(mem);
	defer free_strays(mem, strays);
	out.append_string(`,"strays":[`);
	foreach (i, stray : strays)
	{
		if (i > 0) out.append_char(',');
		out.append_string(`{"joint":"`);
		append_dot_name(out, app, stray.dot);
		out.appendf(`","count":%d,"vertices":[`, stray.vertices.len);
		foreach (k, v : stray.vertices[:math::min((usz)stray.vertices.len, STRAY_LISTED)])
		{
			if (k > 0) out.append_char(',');
			out.appendf("%d", v);
		}
		out.appendf(`],"at":%s,"peak":%.3g,"gap":%.3g,"pull":%.3g,"around":[`, (JsonVec3)stray.centre, stray.peak, stray.gap, stray.pull);
		for (usz k = 0; k < stray.around_count; k++)
		{
			if (k > 0) out.append_char(',');
			out.append_char('"');
			append_dot_name(out, app, stray.around[k]);
			out.append_char('"');
		}
		out.append_string("]}");
	}
	out.append_char(']');
}

<*
 The one weight tool that writes.

 The selection is the survey's own vocabulary read backwards — see `PaintPick` —
 so the refusals here are about the *rig* rather than about the request wherever
 they can be: a vertex off this dot's limb cannot be painted onto it at all, and
 saying which and how many is the difference between a caller that moves the dot
 and one that tries the same call again.
*>
fn String? tool_paint_weights(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;

	if (!takes_object(args, detail, `paint_weights takes an object: {"dot": name, "weight": 0..1}`)) return WEIGHTS_BAD_ARGS~;

	String named;
	if (!required_string(args, "dot", &named, detail, `paint_weights needs "dot": whose weight is being set. `))
	{
		append_dot_names(detail, app);
		return WEIGHTS_BAD_ARGS~;
	}
	uint dot = resolve_dot(app, named, detail)!;

	if ((args.get_bool("reset") ?? false)) return released_json(app, dot, args.get_bool("all") ?? false);

	if (args.has_key("share"))
	{
		detail.append_string(`"share" is gone: a dot's weights are its own column now, and setting one never rescales another, so the share a vertex ends up with is this weight over the row's total. Pass "weight" instead.`);
		return WEIGHTS_BAD_ARGS~;
	}
	double? asked = args.get_float("weight");
	if (catch asked)
	{
		detail.appendf(`paint_weights needs "weight": how much of each vertex %s should hold, 0 to 1 — other dots keep what they hold. `, named);
		detail.append_string(`Use "reset": true to put the dot back on the automatic weights instead.`);
		return WEIGHTS_BAD_ARGS~;
	}
	if (asked < 0.0 || asked > 1.0)
	{
		detail.appendf(`"weight" is %s, and has to be between 0 and 1.`, asked);
		return WEIGHTS_BAD_ARGS~;
	}

	uint[] chosen = paint_selection(app, dot, args, detail)!;
	defer if (chosen.len > 0) alloc::free(mem, chosen);

	PaintResult did = app.paint_share(dot, chosen, (float)asked);
	app.undo_stack.commit();
	app.refresh_ui();

	return painted_json(app, named, (float)asked, chosen.len, did);
}

<*
 `reset` for either writing tool: the named dot back on the automatic weights,
 or with `all` every dot, as one undo step (`release_recorded`).
*>
fn String released_json(AppState* app, uint dot, bool all) @private
{
	usz released = 0;
	if (all)
	{
		released = app.release_all_recorded();
	}
	else
	{
		if (app.release_recorded(dot)) released = 1;
		app.undo_stack.commit();
	}
	app.refresh_ui();
	return string::format(mem, `{"reset":true,"released":%d,"means":"those dots follow the automatic weights again"}`, released);
}

<*
 The vertices a `paint_weights` call names, either explicitly or by predicate.

 The caller owns the result. Empty is a legitimate answer — a selection matching
 nothing is not an error, it is the rig saying the smear being aimed at is not
 there — so the emptiness is reported in the response rather than raised here.
*>
fn uint[]? paint_selection(AppState* app, uint dot, Object* args, DString* detail) @private
{
	if (try Object* listed = args.get("vertices"))
	{
		if (!listed.is_indexable())
		{
			detail.append_string(`"vertices" is a list of vertex indices, or leave it out and select with "owned_by" / "at_least".`);
			return WEIGHTS_BAD_ARGS~;
		}
		sz count = listed.get_len();
		if (count == 0) return {};

		uint[] explicit = alloc::new_array(mem, uint, count);
		for (sz i = 0; i < count; i++)
		{
			double at = listed.get_float_at(i) ?? -1.0;
			if (at < 0.0)
			{
				alloc::free(mem, explicit);
				detail.appendf(`vertices[%d] is not a vertex index. They are whole numbers from 0.`, i);
				return WEIGHTS_BAD_ARGS~;
			}
			explicit[i] = (uint)at;
		}
		return explicit;
	}

	PaintPick pick = { .at_least = 0.0f, .at_most = 1.0f };
	if (try named = args.get_string("owned_by")) pick.owner = resolve_dot(app, named, detail)!;
	if (try double floor = args.get_float("at_least")) pick.at_least = (float)floor;
	if (try double ceiling = args.get_float("at_most")) pick.at_most = (float)ceiling;

	return app.pick_vertices(mem, dot, pick);
}

<*
 What a paint call did, including what it could not do and why.
*>
fn String painted_json(AppState* app, String dot, float weight, usz asked, PaintResult did) @private
{
	DString out = dstring::new(mem);
	defer out.free();

	out.appendf(`{"dot":`)!!;
	append_json_string(&out, dot);
	out.appendf(`,"weight":%.6g,"selected":%d,"painted":%d`, weight, asked, did.changed)!!;

	// Only when there is something to say. A caller that got what it asked for
	// should not have to read two zeroes to find that out.
	if (did.blocked > 0) out.appendf(`,"blocked":%d,"blocked_means":"off this dot's limb, where it held nothing: pin_weights hands such vertices over"`, did.blocked)!!;
	if (did.emptied > 0)
	{
		out.appendf(`,"emptied":%d`, did.emptied)!!;
		out.append_string(`,"emptied_means":"no other dot holds those vertices, so they now hold nothing and follow the root: paint another dot onto them"`);
	}
	if (asked == 0)
	{
		out.append_string(`,"note":"nothing matched the selection: get_weights lists which dots actually share vertices with this one"`);
	}

	out.appendf(`,"painting":"this dot's own weights, held from now on: no other dot's changed, moving dots will not change these, and Reset on the Weights card or reset:true puts it back on the automatic weights"}`)!!;
	return out.copy_str(mem);
}

<*
 The other weight tool that writes: the lasso over the wire.

 `tool_paint_weights` in shape all the way through — same selection, same
 reset — and differing in what it writes: the weight outright, with no limb to
 stay on, so a prop held at arm's length can be given to the hand.
*>
fn String? tool_pin_weights(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;

	if (!takes_object(args, detail, `pin_weights takes an object: {"dot": name, "weight": 0..1}`)) return WEIGHTS_BAD_ARGS~;

	String named;
	if (!required_string(args, "dot", &named, detail, `pin_weights needs "dot": which dot the vertices are given to. `))
	{
		append_dot_names(detail, app);
		return WEIGHTS_BAD_ARGS~;
	}
	uint dot = resolve_dot(app, named, detail)!;

	if ((args.get_bool("reset") ?? false)) return released_json(app, dot, args.get_bool("all") ?? false);

	if (args.has_key("share") || args.has_key("exclusive"))
	{
		detail.append_string(`"share" and "exclusive" are gone: a dot's weights are its own column now, and setting one never takes a vertex off another dot. Pass "weight" — the share a vertex ends up with is that over the row's total.`);
		return WEIGHTS_BAD_ARGS~;
	}
	// A weight with no number on it is the full one, which is what the lasso
	// writes and what a caller saying "this belongs to that dot" means.
	double asked = args.get_float("weight") ?? 1.0;
	if (asked < 0.0 || asked > 1.0)
	{
		detail.appendf(`"weight" is %s, and has to be between 0 and 1.`, asked);
		return WEIGHTS_BAD_ARGS~;
	}

	uint[] chosen = paint_selection(app, dot, args, detail)!;
	defer if (chosen.len > 0) alloc::free(mem, chosen);

	usz changed = app.set_weight_vertices(chosen, dot, (float)asked);
	app.refresh_ui();

	return pinned_json(app, named, (float)asked, chosen.len, changed);
}

<*
 fix_strays: the Weights card's Fix strays over the wire. Each stray get_weights
 lists is taken off its dot — that dot's weight on the island goes to 0 and no
 other dot's changes (`AppState.fix_strays`) — as one undo step. Answers how
 many it found, how many vertices moved, how many were left holding nothing,
 and the strays left in get_weights' words.
*>
fn String? tool_fix_strays(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;
	StrayIsland[] strays = app.stray_islands(mem);
	defer free_strays(mem, strays);
	usz emptied = 0;
	usz fixed = app.fix_strays(strays, &emptied);
	app.refresh_ui();

	DString out = dstring::new(mem);
	defer out.free();
	out.appendf(`{"found":%d,"fixed":%d,"emptied":%d`, strays.len, fixed, emptied);
	strays_json(app, &out);
	out.append_char('}');
	return out.copy_str(mem);
}

<*
 What a pin call did, in `painted_json`'s voice: what was asked for, what was
 selected and what moved.
*>
fn String pinned_json(AppState* app, String dot, float weight, usz asked, usz changed) @private
{
	DString out = dstring::new(mem);
	defer out.free();

	out.appendf(`{"dot":`)!!;
	append_json_string(&out, dot);
	out.appendf(`,"weight":%.6g,"selected":%d,"pinned":%d`, weight, asked, changed)!!;

	if (asked == 0)
	{
		out.append_string(`,"note":"nothing matched the selection: get_weights lists which dots actually share vertices with this one"`);
	}

	out.appendf(`,"pinning":"this dot's own weight on those vertices, held from now on; other dots keep theirs, so where they hold the vertex too the two blend"}`)!!;
	return out.copy_str(mem);
}

const usz SHELL_LIST_DEFAULT @local = 40;

fn String? tool_get_shells(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;

	usz limit = SHELL_LIST_DEFAULT;
	if (args != null && args.is_keyable())
	{
		if (try double asked = args.get_float("limit"))
		{
			limit = asked > 0.0 ? (usz)asked : 0;
		}
	}
	return shells_json(app, limit);
}

<*
 The mesh's pieces, largest first, with whatever each one has been pinned to and
 whatever the binder decided for the rest.

 The rows themselves are `AppState.shell_rows` — the one list, in the one
 order, that anything listing the pieces reads (a Shells pane drew it until it
 went for now), because a piece two tools numbered or ranked differently is a
 piece nobody could talk about.

 @param limit : `How many rows to write. The tail of a shattered mesh is rivets, and a caller that wants them can ask.`
*>
fn String shells_json(AppState* app, usz limit)
{
	DString out = dstring::new(mem);
	defer out.free();

	usz count = app.shells.count;
	out.appendf(`{"pieces":%d,"vertices":%d,"shells":[`, count, app.geometry.positions.len);

	ShellRow[] rows = app.shell_rows(mem);
	defer if (rows.len > 0) alloc::free(mem, rows);

	// Empty when there are no pieces, and when `shells` was built from a mesh
	// that has since been replaced — see `shell_rows`.
	if (rows.len == 0)
	{
		out.append_string(`],"listed":0}`);
		return out.copy_str(mem);
	}

	// The binder's automatic choices are joint indices, and joint indices are
	// breadth-first output that shifts on every rig edit — so they are reported
	// only while `riders_stale` is down, resolved through a rig built now, which
	// that flag being down guarantees is the rig they were made against. A stale
	// guess would name a real bone that is not the one the binder chose, which is
	// worse than saying nothing.
	//
	// Refreshed here first, at the cost of a bind when the rig has moved since
	// the last one. This is the one reader left that wants them — the Shells
	// pane, which kept them fresh behind a debounce, is gone for now — and a
	// tool call that answered "not known" until something else happened to bind
	// would be answering a question with a shrug.
	app.refresh_shell_riders();
	RigView view;
	bool automatic = false;
	if (!app.riders_stale && app.shell_riders.len == count)
	{
		RigView? opened = app.open_rig(mem);
		if (try opened)
		{
			view = opened;
			automatic = true;
		}
	}
	defer if (automatic) view.free(mem);

	usz listed = limit < rows.len ? limit : rows.len;
	for (usz i = 0; i < listed; i++)
	{
		ShellRow row = rows[i];
		if (i > 0) out.append_char(',');

		out.appendf(`{"shell":%d,"vertices":%d,"centre":`, row.shell, row.vertices);
		append_vec3(&out, (row.low + row.high) * 0.5f);
		out.append_string(`,"size":`);
		append_vec3(&out, row.high - row.low);

		uint pinned = app.doc.attachment_of((uint)row.shell);
		Dot* rider = app.doc.find(pinned);
		out.append_string(`,"pinned":`);
		if (rider == null)
		{
			out.append_string("null");
		}
		else
		{
			out.append_char('"');
			append_bone_name(&out, rider.id, rider.name);
			out.append_char('"');
		}

		// Omitted entirely rather than written null: absent means "not known",
		// and a piece the falloff simply blends is the same absence.
		int decided = automatic ? app.shell_rider(row.shell) : -1;
		if (decided >= 0 && (usz)decided < view.names.len)
		{
			out.append_string(`,"auto":"`);
			append_bone_name(&out, view.dot_ids[(usz)decided], view.names[(usz)decided]);
			out.append_char('"');
		}
		out.append_char('}');
	}

	out.appendf(`],"listed":%d}`, listed);
	return out.copy_str(mem);
}
