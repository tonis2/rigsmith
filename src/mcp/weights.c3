<*
 The weight tools: show_weights, get_weights, paint_weights, pin_weights and
 get_shells.

 Weights are derived rather than authored — every rig edit rebinds from scratch —
 so nothing here owns any of it. What these five do is *report* on the bind and
 put two layers on top of it: corrections, which are multipliers over whatever the
 binder currently says and therefore survive moving a dot, and pins, which state a
 share outright and do not. `AppState` does the arithmetic; this file is the
 selection language, the payloads, and the refusals.

 The pairing that repeats: `show_weights` puts a picture in front of a person and
 `get_weights` answers the caller, and neither is the other's precondition. The
 same shape as `play` against `get_pose`.
*>
module crig;

import rig;
import std::collections::object;
import std::math;

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

	if (!takes_object(args, detail, `show_weights takes an object: {"mode": one of off, territory, falloff, "dot": a name from get_skeleton}`)) return WEIGHTS_BAD_ARGS~;
	String asked;
	if (!required_string(args, "mode", &asked, detail, `show_weights needs "mode": one of off, territory, falloff. get_weights answers the same as numbers and needs no view to be on.`)) return WEIGHTS_BAD_ARGS~;

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
	out.append_string(`"}`);

	return out.copy_str(mem);
}

<*
 get_weights: the same three views, as numbers.

 A read, and unconditional: it binds its own copy rather than reporting whatever
 the screen last painted, so it answers with no view on and cannot answer with a
 stale one.
*>
fn String? tool_get_weights(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;

	uint dot = 0;
	if (args != null && args.is_keyable())
	{
		if (try named = args.get_string("dot")) dot = resolve_dot(app, named, detail)!;
	}
	return weights_json(app, dot, detail);
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

 @param dot : `The dot to survey, or 0 for the table alone.`
 @return? RIG_EMPTY : `No mesh or no rig; the reason is left in detail.`
*>
fn String? weights_json(AppState* app, uint dot, DString* detail)
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

	out.appendf(`{"vertices":%d,"unclaimed":%d,"floor":%s,"dots":[`,
		survey.vertices, survey.unclaimed, (JsonFloat)BLEND_FLOOR);

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

	out.append_char('}');
	return out.copy_str(mem);
}

<*
 The one weight tool that writes.

 The selection is the survey's own vocabulary read backwards — see `PaintPick` —
 so the refusals here are about the *rig* rather than about the request wherever
 they can be: a vertex the binder gives this dot nothing on cannot be painted
 onto it at all, and saying which and how many is the difference between a
 caller that moves the dot and one that tries the same call again.
*>
fn String? tool_paint_weights(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;

	if (!takes_object(args, detail, `paint_weights takes an object: {"dot": name, "share": 0..1}`)) return WEIGHTS_BAD_ARGS~;

	String named;
	if (!required_string(args, "dot", &named, detail, `paint_weights needs "dot": whose share is being set. `))
	{
		append_dot_names(detail, app);
		return WEIGHTS_BAD_ARGS~;
	}
	uint dot = resolve_dot(app, named, detail)!;

	if ((args.get_bool("reset") ?? false))
	{
		usz cleared = app.clear_paint();
		app.refresh_ui();
		return string::format(mem, `{"reset":true,"cleared":%d}`, cleared);
	}

	double? asked = args.get_float("share");
	if (catch asked)
	{
		detail.appendf(`paint_weights needs "share": what fraction of each vertex %s should end up holding, 0 to 1. `, named);
		detail.append_string(`Use "reset": true to take every correction off instead.`);
		return WEIGHTS_BAD_ARGS~;
	}
	if (asked < 0.0 || asked > 1.0)
	{
		detail.appendf(`"share" is %s, and a share is a fraction of one vertex — it has to be between 0 and 1.`, asked);
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
fn String painted_json(AppState* app, String dot, float share, usz asked, PaintResult did) @private
{
	DString out = dstring::new(mem);
	defer out.free();

	out.appendf(`{"dot":`)!!;
	append_json_string(&out, dot);
	out.appendf(`,"share":%.6g,"selected":%d,"painted":%d`, share, asked, did.changed)!!;

	// Only when there is something to say. A caller that got what it asked for
	// should not have to read two zeroes to find that out.
	if (did.unreachable > 0)
	{
		out.appendf(`,"unreachable":%d`, did.unreachable)!!;
		out.append_string(`,"unreachable_means":"the binder gives this dot no weight at all on those vertices, so no correction reaches them — the dot has to move closer or its reach has to widen"`);
	}
	if (did.alone > 0)
	{
		out.appendf(`,"alone":%d`, did.alone)!!;
		out.append_string(`,"alone_means":"no other dot holds those vertices, so there is no share to take — they are already wholly this dot's"`);
	}
	if (asked == 0)
	{
		out.append_string(`,"note":"nothing matched the selection: get_weights lists which dots actually share vertices with this one"`);
	}

	out.appendf(`,"painting":"corrections ride over the binder, so moving a dot re-derives the mesh underneath them"}`)!!;
	return out.copy_str(mem);
}

<*
 The other weight tool that writes, and the one that can state a value.

 `tool_paint_weights` in shape all the way through — same selection, same
 refusals — because the two differ in what they write rather than in how they
 are asked. Where they part is the reset: this one takes the pins off and leaves
 the corrections, since the layers are independent and a caller clearing one
 rarely means both.
*>
fn String? tool_pin_weights(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;

	if (!takes_object(args, detail, `pin_weights takes an object: {"dot": name, "share": 0..1}`)) return WEIGHTS_BAD_ARGS~;

	String named;
	if (!required_string(args, "dot", &named, detail, `pin_weights needs "dot": which dot the vertices are handed to. `))
	{
		append_dot_names(detail, app);
		return WEIGHTS_BAD_ARGS~;
	}
	uint dot = resolve_dot(app, named, detail)!;

	if ((args.get_bool("reset") ?? false))
	{
		usz cleared = app.clear_pins();
		app.refresh_ui();
		return string::format(mem, `{"reset":true,"cleared":%d}`, cleared);
	}

	// Unlike a share, which has no default worth guessing: a pin with no number
	// on it is the rigid one, which is what the lasso writes and what a caller
	// saying "this belongs to that dot" means.
	double asked = args.get_float("share") ?? 1.0;
	if (asked < 0.0 || asked > 1.0)
	{
		detail.appendf(`"share" is %s, and a share is a fraction of one vertex — it has to be between 0 and 1.`, asked);
		return WEIGHTS_BAD_ARGS~;
	}

	bool exclusive = args.get_bool("exclusive") ?? true;

	uint[] chosen = paint_selection(app, dot, args, detail)!;
	defer if (chosen.len > 0) alloc::free(mem, chosen);

	usz changed = app.pin_vertices(chosen, dot, (float)asked, exclusive);
	app.undo_stack.commit();
	app.refresh_ui();

	return pinned_json(app, named, (float)asked, chosen.len, changed);
}

<*
 What a pin call did. `painted_json`'s voice, minus its two diagnoses.

 Neither of those has a reading here. "Unreachable" is a statement about a
 multiplier, and a pin does not multiply; "alone" is about there being no share
 to take, and a pin takes the whole vertex by saying so. What is left is what
 was asked for, what was selected and what moved.
*>
fn String pinned_json(AppState* app, String dot, float share, usz asked, usz changed) @private
{
	DString out = dstring::new(mem);
	defer out.free();

	out.appendf(`{"dot":`)!!;
	append_json_string(&out, dot);
	out.appendf(`,"share":%.6g,"selected":%d,"pinned":%d`, share, asked, changed)!!;

	if (asked == 0)
	{
		out.append_string(`,"note":"nothing matched the selection: get_weights lists which dots actually share vertices with this one"`);
	}

	out.appendf(`,"pinning":"a pin states the share and is applied after the corrections, so it is the last word on a vertex — and it does not move when the dot does"}`)!!;
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
