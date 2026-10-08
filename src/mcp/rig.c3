<*
 edit_rig: the rig itself, over the wire.

 Everything else on this surface reads the rig or animates it. This is the half
 that was missing: `get_weights` could report that 5% of a mesh's vertices were
 unclaimed and nothing could fix it, so the answer was always "ask the person at
 the screen to re-fit it by hand". A clip cannot address an unnamed dot either,
 which made a hand-built rig unanimatable from here for want of one string.

 **One call is one undo group.** A repair is several primitives — place a dot,
 name it, hang it off its parent — and a user who does not like the result must
 be able to take the whole thing back with one Ctrl+Z, not seven. So the ops
 arrive as a list, they are applied through the same *recorded* primitives the
 viewport uses, and exactly one commit closes the group at the end. That is also
 what makes the batch atomic: an op that fails part-way through rolls the group
 back before refusing, so a refused call leaves the rig where it found it.

 Nothing here reaches past `AppState`. Every op is a method that already existed
 for the mouse to call, which is what keeps a rig edited from the wire and one
 edited by hand the same rig.
*>
module crig;

import rig;
import std::collections::object;
import std::math;
import std::math::quaternion;

faultdef RIG_REFUSED;

<*
 edit_rig's argument shape, as the client sees it.

 Held apart from the registration for the reason `APPLY_CLIP_SCHEMA` is: this is
 what a model reads before its first attempt rather than after its first
 rejection, so the descriptions are the documentation.
*>
const String EDIT_RIG_SCHEMA = `{"type":"object","properties":{
	"ops":{"type":"array","description":"Applied in order, as one undo step. An op that fails takes the whole call back with it.","items":{"type":"object","properties":{
		"op":{"type":"string","enum":["place","move","name","name_all","remove","connect","disconnect","root","reach","sharpness","attach","detach","limits","exclude","include","symmetry"],"description":"place: a new dot. move: an existing one. name: what clips address it by. name_all: name every dot at once, by matching the rig's shape against a body plan. remove: it and its bones. connect/disconnect: a bone between two dots. root: which joint the skeleton hangs from. reach: how far a dot's influence carries. sharpness: how crisp every blend is, for the whole model. attach/detach: make a piece of the mesh ride one dot rigidly, or stop. limits: edit the joint's bone-local rotation limits (x and z the swing across the bone, y the twist about it). exclude/include: tell the self-collision check never to test the skin regions of two joints against each other, or to test them again — for a cape meant to hang through the arm, not for an ordinary rig, whose adjacent regions and modelled contacts are already left alone. symmetry: set the plane the mirror reflects across, for a mesh whose bounding-box centre is not the body's midline."},
		"joint":{"type":"string","description":"Which dot, by the name get_skeleton reports; bone_<id> reaches an unnamed one. Used by move, name, remove, root, reach, attach and limits."},
		"name":{"type":"string","description":"The name to give a dot — place and name. Empty un-names it, which is the hand-placed state; only named dots can be animated."},
		"position":{"type":"array","description":"[x,y,z] in model space, the space get_skeleton reports positions in — not a fraction of anything. Used by place and move.","items":{"type":"number"}},
		"connect_to":{"type":"string","description":"place only: hang the new dot off this one, so it arrives with its bone already made."},
		"a":{"type":"string","description":"connect/disconnect: one end of the bone. exclude/include: one of the two joints."},
		"b":{"type":"string","description":"connect/disconnect: the other end. exclude/include: the other joint."},
		"reach":{"type":"number","description":"reach only: how far this dot's influence carries, in model units — the same units as position. 0 is no limit, which is what every dot has until asked otherwise. Use it when a dot pulls on mesh it should not: get_weights names the pairs that overlap, and a reach is how you end one without moving the joint off the anatomy."},
		"value":{"type":"number","description":"sharpness only: the power the binder's weights are raised to, 0.25 to 4, one number for the whole model. 1 is the binder's own blend; above it narrows every transition band at once, which is what a model assembled from solid pieces wants and what no per-dot setting can say. Names no joint."},
		"shell":{"type":"integer","description":"attach/detach: which piece of the mesh, by the id get_shells reports."},
		"active":{"type":"boolean","description":"limits only: whether persistent limits are evaluated. Supplying an axis row turns this on unless active is explicitly false."},
		"x":{"type":"object","description":"limits only: the swing across the bone about the joint's X, in radians (where the bone points).","properties":{"allow":{"type":"boolean"},"minimum":{"type":"number"},"maximum":{"type":"number"},"locked":{"type":"number"}}},
		"y":{"type":"object","description":"limits only: the twist about the bone (the joint's Y), in radians.","properties":{"allow":{"type":"boolean"},"minimum":{"type":"number"},"maximum":{"type":"number"},"locked":{"type":"number"}}},
		"z":{"type":"object","description":"limits only: the swing across the bone about the joint's Z, in radians (where the bone points).","properties":{"allow":{"type":"boolean"},"minimum":{"type":"number"},"maximum":{"type":"number"},"locked":{"type":"number"}}},
		"primary_child":{"type":"string","description":"limits only: for a branching joint, which direct child defines local +Y. Empty clears the choice."},
		"frame":{"type":"array","minItems":4,"maxItems":4,"items":{"type":"number"},"description":"limits only: an explicit rest/model-space local-axis quaternion [x,y,z,w], overriding topology."},
		"clear_frame":{"type":"boolean","description":"limits only: remove an explicit frame and derive axes from the bone again."},
		"reset":{"type":"boolean","description":"limits only: remove all limits and saved frame choices from this joint."},
		"plane":{"type":"number","description":"symmetry only: the model-space X the mirror reflects across (a left dot at plane+d, its right twin at plane-d). Give this or \"from\"."},
		"from":{"type":"string","enum":["skeleton","mesh"],"description":"symmetry only: derive the plane instead of naming it — \"skeleton\" reads it off the rig's centre joints (named joints with no left/right twin, which sit on it), \"mesh\" resets it to the model's bounding-box centre (the default a fresh rig gets)."}
	},"required":["op"]}},
	"snap":{"type":"boolean","description":"Pull placed and moved dots to the nearest point inside the mesh. Default true; false puts a dot exactly where it was asked for, including outside the mesh."}
},"required":["ops"]}`;

// Every `op` edit_rig answers to, for the refusals that list them. Keep it in
// step with the schema's enum and the switch in `apply_op`.
const String RIG_OPS = "place, move, name, name_all, remove, connect, disconnect, root, reach, sharpness, attach, detach, limits, exclude, include, symmetry";

<*
 Apply a batch of rig edits, or none of them.

 	`String answer = edit_rig(app, args, &detail)!;`

 @param detail : `Filled with what was wrong and what would have been accepted, when this faults.`
 @return? RIG_REFUSED : `Nothing was changed. The reason is in detail.`
*>
fn String? edit_rig(AppState* app, Object* args, DString* detail)
{
	if (!takes_object(args, detail,
		string::tformat(`edit_rig takes an object: {"ops": [{"op": …}], "snap": bool}, where op is one of %s`, RIG_OPS)))
	{
		return RIG_REFUSED~;
	}

	Object* ops = member(args, "ops");
	if (ops == null || !ops.is_array() || ops.get_len() == 0)
	{
		detail.append_string(`edit_rig needs "ops": a non-empty array. An empty batch would answer with the rig unchanged, which get_skeleton already does.`);
		return RIG_REFUSED~;
	}

	bool snap = args.get_bool("snap") ?? true;
	usz count = (usz)ops.get_len();

	// The cursor before anything is applied. A refusal walks back to it rather
	// than reverting op by op, so a partial batch cannot be left half-applied by
	// a rollback that itself gives up part-way.
	sz mark = app.undo_stack.cursor;
	usz done = 0;

	for (usz i = 0; i < count; i++)
	{
		if (!apply_op(app, ops.get_at((sz)i), i, snap, detail))
		{
			// Committed first: the group is still open, and `undo` walks a chain
			// back from a closed edit. Then back to where the batch started.
			app.undo_stack.commit();
			while (app.undo_stack.cursor > mark && app.undo()) {}
			app.mark_rig_stale();
			app.forget_stale_ids();
			app.refresh_ui();
			return RIG_REFUSED~;
		}
		done++;
	}

	app.undo_stack.commit();
	app.mark_rig_stale();
	app.forget_stale_ids();
	app.plan_targets_stale = true;
	app.refresh_ui();
	return rig_json(app, done);
}

<*
 One op, applied and recorded but not committed.

 @return `False when the op was refused, in which case detail names the op's index and what was wrong.`
*>
fn bool apply_op(AppState* app, Object* op, usz index, bool snap, DString* detail) @local
{
	if (!op.is_keyable())
	{
		detail.appendf(`ops[%d] must be an object with an "op"`, index);
		return false;
	}

	String? kind = op.get_string("op");
	if (catch kind)
	{
		detail.appendf(`ops[%d] needs "op": one of %s`, index, RIG_OPS);
		return false;
	}

	switch (kind)
	{
		case "place": return op_place(app, op, index, snap, detail);
		case "move": return op_move(app, op, index, snap, detail);
		case "name": return op_name(app, op, index, detail);
		case "name_all": return op_name_all(app, index, detail);
		case "remove": return op_remove(app, op, index, detail);
		case "connect": return op_bone(app, op, index, true, detail);
		case "disconnect": return op_bone(app, op, index, false, detail);
		case "root": return op_root(app, op, index, detail);
		case "reach": return op_reach(app, op, index, detail);
		case "sharpness": return op_sharpness(app, op, index, detail);
		case "attach": return op_pin(app, op, index, true, detail);
		case "detach": return op_pin(app, op, index, false, detail);
		case "limits": return op_limits(app, op, index, detail);
		case "exclude": return op_exclusion(app, op, index, true, detail);
		case "include": return op_exclusion(app, op, index, false, detail);
		case "symmetry": return op_symmetry(app, op, index, detail);
		default:
			detail.appendf(
				`ops[%d].op is "%s". It has to be one of %s.`,
				index, kind, RIG_OPS);
			return false;
	}
}

fn bool op_place(AppState* app, Object* op, usz index, bool snap, DString* detail) @local
{
	Vec3 at;
	if (!op_position(app, op, index, snap, &at, detail)) return false;

	String name = op.get_string("name") ?? "";
	uint id = app.add_recorded(at, name);

	Object* anchor = member(op, "connect_to");
	if (anchor != null)
	{
		String? named = op.get_string("connect_to");
		if (catch named)
		{
			detail.appendf(`ops[%d].connect_to must be a dot name`, index);
			return false;
		}
		uint to = op_dot(app, named, index, "connect_to", detail);
		if (to == 0) return false;
		app.connect_recorded(to, id);
	}

	app.select(id);
	return true;
}

fn bool op_move(AppState* app, Object* op, usz index, bool snap, DString* detail) @local
{
	uint id = op_joint(app, op, index, detail);
	if (id == 0) return false;

	Vec3 at;
	if (!op_position(app, op, index, snap, &at, detail)) return false;

	Dot* dot = app.doc.find(id);
	app.move_recorded(id, dot.position, at);
	return true;
}

fn bool op_name(AppState* app, Object* op, usz index, DString* detail) @local
{
	uint id = op_joint(app, op, index, detail);
	if (id == 0) return false;

	String? name = op.get_string("name");
	if (catch name)
	{
		detail.appendf(
			`ops[%d] needs "name": what clips will address this dot by. An empty string un-names it.`, index);
		return false;
	}

	// A no-op rather than a refusal: a batch that names a dot what it is already
	// called has got where it was going, and failing it would roll back the rest.
	app.rename_recorded(id, name);
	return true;
}

// A refusal rather than a quiet no-op when the rig does not fit a plan, which is
// the opposite of `op_name`'s rule and for the opposite reason: a dot already
// carrying the name asked for has arrived where the batch was going, while a rig
// that matched nothing has not, and an agent told "applied: 1" would go on to
// play clips on a rig that is still nameless.
fn bool op_name_all(AppState* app, usz index, DString* detail) @local
{
	AutoNaming named = app.auto_name_recorded();
	if (named.total == 0)
	{
		detail.appendf(
			`ops[%d] name_all found no body plan to match against. The rig is named after a plan carried by a pack in the library, and none of the configured libraries holds one with a body.`,
			index);
		return false;
	}
	if (!named.usable())
	{
		detail.appendf(
			`ops[%d] name_all: the rig fits only %d of the %s plan's %d joints, so nothing was renamed. Place the joints the plan is missing, or name the dots one at a time with "name".`,
			index, named.matched, named.plan, named.total);
		return false;
	}
	return true;
}

fn bool op_remove(AppState* app, Object* op, usz index, DString* detail) @local
{
	uint id = op_joint(app, op, index, detail);
	if (id == 0) return false;

	app.remove_recorded(id);
	return true;
}

fn bool op_bone(AppState* app, Object* op, usz index, bool joining, DString* detail) @local
{
	String verb = joining ? "connect" : "disconnect";

	String? first = op.get_string("a");
	String? second = op.get_string("b");
	if (catch first, second)
	{
		detail.appendf(`ops[%d] is a %s and needs "a" and "b": the two dots the bone runs between`, index, verb);
		return false;
	}

	uint a = op_dot(app, first, index, "a", detail);
	if (a == 0) return false;
	uint b = op_dot(app, second, index, "b", detail);
	if (b == 0) return false;

	if (a == b)
	{
		detail.appendf(`ops[%d] would %s "%s" to itself, which is not a bone`, index, verb, first);
		return false;
	}

	if (joining)
	{
		app.connect_recorded(a, b);
		return true;
	}
	app.disconnect_recorded(a, b);
	return true;
}

<*
 exclude/include: a collision exclusion between two joints' regions, on the
 bone op's terms — two names, and the pair either way round is the same one.
 Reaching the asked-for state is success, like rename and reach.
*>
fn bool op_exclusion(AppState* app, Object* op, usz index, bool excluding, DString* detail) @local
{
	String verb = excluding ? "exclude" : "include";

	String? first = op.get_string("a");
	String? second = op.get_string("b");
	if (catch first, second)
	{
		detail.appendf(`ops[%d] is an %s and needs "a" and "b": the two joints whose regions it concerns`, index, verb);
		return false;
	}

	uint a = op_dot(app, first, index, "a", detail);
	if (a == 0) return false;
	uint b = op_dot(app, second, index, "b", detail);
	if (b == 0) return false;

	if (a == b)
	{
		detail.appendf(`ops[%d] would %s "%s" against itself; a region never collides with itself under the ordinary rules`, index, verb, first);
		return false;
	}

	app.exclude_recorded(a, b, excluding);
	return true;
}

fn bool op_root(AppState* app, Object* op, usz index, DString* detail) @local
{
	uint id = op_joint(app, op, index, detail);
	if (id == 0) return false;

	// Already the root is not a failure, for the same reason a redundant rename
	// is not: the batch asked for a state, and the state holds.
	app.root_recorded(id);
	return true;
}

fn bool op_reach(AppState* app, Object* op, usz index, DString* detail) @local
{
	uint id = op_joint(app, op, index, detail);
	if (id == 0) return false;

	Object* asked = member(op, "reach");
	if (asked == null)
	{
		detail.appendf(
			`ops[%d] needs "reach": how far this dot's influence carries, in model units. 0 lifts the limit.`,
			index);
		return false;
	}

	// Read loosely, because the most useful value of all is written `0` and JSON
	// parses that as an integer — a strict read would refuse the one call that
	// lifts a limit.
	double? want = asked.to_value(double, false);
	if (catch want)
	{
		detail.appendf(`ops[%d].reach must be a number of model units; 0 lifts the limit.`, index);
		return false;
	}

	if (want < 0.0)
	{
		detail.appendf(`ops[%d].reach is %.4g. A distance cannot be negative; 0 is the way to lift the limit.`,
			index, want);
		return false;
	}

	// A reach that does not cover the dot's own bone leaves part of that bone
	// holding nothing, which reads on screen as a limb that tears where it should
	// bend. Reported rather than refused: it is a legitimate thing to pass
	// through on the way to a smaller rig, and the weight views are what show it.
	app.set_reach_recorded(id, (float)want);
	return true;
}

<*
 The one op that names no joint: how crisp this model's blends are.

 A property of the mesh rather than of any dot — see `RigDocument.sharpness` —
 so `joint` is not read and asking for one would be inventing a per-dot setting
 the binder does not have.
*>
fn bool op_sharpness(AppState* app, Object* op, usz index, DString* detail) @local
{
	Object* asked = member(op, "value");
	if (asked == null)
	{
		detail.appendf(
			`ops[%d] needs "value": the power the binder's weights are raised to, %.4g to %.4g. 1 is the binder's own blend and above it narrows every transition band, which is what a model assembled from solid pieces wants.`,
			index, SHARPNESS_MIN, SHARPNESS_MAX);
		return false;
	}

	// Loosely, for `op_reach`'s reason: the useful round numbers here — 1, 2, 3 —
	// are all written without a decimal point and JSON parses every one of them as
	// an integer.
	double? want = asked.to_value(double, false);
	if (catch want)
	{
		detail.appendf(`ops[%d].value must be a number between %.4g and %.4g.`,
			index, SHARPNESS_MIN, SHARPNESS_MAX);
		return false;
	}

	// Refused rather than clamped, unlike the document's own setter: a clamp is
	// the right answer to a wheel that ran past the end of its range, and the
	// wrong one to a caller that asked for 10 — which is a caller working from a
	// wrong idea of what the number means, and telling them so is the whole value
	// of the range being in the sentence.
	if (want < (double)SHARPNESS_MIN || want > (double)SHARPNESS_MAX)
	{
		detail.appendf(
			`ops[%d].value is %.4g. Blend sharpness runs from %.4g to %.4g — 1 is the binder's own blend, above it sharpens every boundary and below it softens them. Outside that band the weights stop being representable.`,
			index, want, SHARPNESS_MIN, SHARPNESS_MAX);
		return false;
	}

	// Already at that sharpness is not a failure, for the same reason a redundant
	// rename is not: the batch asked for a state, and the state holds.
	app.set_sharpness_recorded((float)want);
	return true;
}

<*
 Set the mirror plane — the model-space X the M-key mirror reflects across.

 The plane defaults to the mesh's bounding-box centre, which is only the body's
 midline when the mesh is symmetric about it. A tail, an off-centre export or a
 rig built on no mesh leaves it elsewhere, and mirroring across it lands every
 twin out of place — which is what this op is for.
*>
fn bool op_symmetry(AppState* app, Object* op, usz index, DString* detail) @local
{
	Object* asked_plane = member(op, "plane");
	Object* asked_from = member(op, "from");
	String? from = op.get_string("from");
	bool has_from = asked_from != null;

	if (asked_plane == null && !has_from)
	{
		detail.appendf(
			`ops[%d] is a symmetry op and needs "plane" (the model-space X to reflect across) or "from": "skeleton" to read the plane off the rig's named joints, or "mesh" to reset it to the model's bounding-box centre.`,
			index);
		return false;
	}
	if (asked_plane != null && has_from)
	{
		detail.appendf(`ops[%d] takes "plane" or "from", not both.`, index);
		return false;
	}

	float plane;
	if (asked_plane != null)
	{
		double? want = asked_plane.to_value(double, false);
		if (catch want)
		{
			detail.appendf(`ops[%d].plane must be a number — the model-space X the mirror reflects across.`, index);
			return false;
		}
		if (!math::is_finite((float)want))
		{
			detail.appendf(`ops[%d].plane must be a finite number.`, index);
			return false;
		}
		plane = (float)want;
	}
	else
	{
		if (catch from)
		{
			detail.appendf(`ops[%d].from must be "skeleton" or "mesh".`, index);
			return false;
		}
		switch (from)
		{
			case "skeleton":
				if (!app.symmetry_plane(&plane))
				{
					detail.appendf(
						`ops[%d].from is "skeleton", but the rig has no centre joint to read a plane from — a named joint with no left/right twin, like a spine or a head. Name one first, or give "plane".`,
						index);
					return false;
				}
			case "mesh":
				plane = app.geometry.bounds().center().x;
			default:
				detail.appendf(
					`ops[%d].from is "%s". It is "skeleton" — read the plane off the rig's named joints — or "mesh", the model's bounding-box centre.`,
					index, from);
				return false;
		}
	}

	// A no-op when the plane is already there is not a failure, the same as a
	// redundant sharpness: the batch asked for a state and the state holds.
	app.set_sym_x_recorded(plane);
	return true;
}

fn bool op_pin(AppState* app, Object* op, usz index, bool pinning, DString* detail) @local
{
	String verb = pinning ? "attach" : "detach";

	Object* asked = member(op, "shell");
	if (asked == null)
	{
		detail.appendf(`ops[%d] is a %s and needs "shell": which piece of the mesh, by the id get_shells reports`,
			index, verb);
		return false;
	}

	long? shell = asked.to_value(long, false);
	if (catch shell)
	{
		detail.appendf(`ops[%d].shell must be a piece number, as get_shells reports them`, index);
		return false;
	}

	if (shell < 0 || (usz)shell >= app.shells.count)
	{
		detail.appendf(`ops[%d].shell is %d and this mesh has %d pieces, numbered from 0. get_shells lists them.`,
			index, shell, app.shells.count);
		return false;
	}

	if (!pinning)
	{
		// Zero is the value "the binder decides", not a missing dot.
		app.attach_recorded((uint)shell, 0);
		return true;
	}

	uint id = op_joint(app, op, index, detail);
	if (id == 0) return false;

	app.attach_recorded((uint)shell, id);
	return true;
}

<*
 One complete persistent rotation-limit edit.

 Axis numbers are radians, matching every other angle on the MCP surface. Rows
 are partial updates over the current table; the UI can therefore change one
 field without reconstructing the other two axes. Supplying any row enables
 limits unless `active:false` says otherwise. `reset:true` is the concise way
 back to an entirely free joint.
*>
fn bool op_limits(AppState* app, Object* op, usz index, DString* detail) @local
{
	uint id = op_joint(app, op, index, detail);
	if (id == 0) return false;

	bool has_reset = member(op, "reset") != null;
	bool reset = false;
	if (has_reset)
	{
		bool? asked = op.get_bool("reset");
		if (catch asked)
		{
			detail.appendf(`ops[%d].reset must be true or false.`, index);
			return false;
		}
		reset = asked;
	}
	bool has_active = member(op, "active") != null;
	bool has_axis = member(op, "x") != null || member(op, "y") != null || member(op, "z") != null;
	bool has_child = member(op, "primary_child") != null;
	bool has_frame = member(op, "frame") != null;
	bool has_clear_frame = member(op, "clear_frame") != null;
	bool clear_frame = false;
	if (has_clear_frame)
	{
		bool? asked = op.get_bool("clear_frame");
		if (catch asked)
		{
			detail.appendf(`ops[%d].clear_frame must be true or false.`, index);
			return false;
		}
		clear_frame = asked;
	}
	if (!has_reset && !has_active && !has_axis && !has_child && !has_frame && !has_clear_frame)
	{
		detail.appendf(`ops[%d] limits was given nothing to change. Supply active, x/y/z, primary_child, frame, clear_frame, or reset.`, index);
		return false;
	}
	if (reset && (has_active || has_axis || has_child || has_frame || has_clear_frame))
	{
		detail.appendf(`ops[%d] reset removes the whole limit table, so it cannot be combined with limit fields.`, index);
		return false;
	}

	JointRotationLimits settings = reset
		? unconstrained_rotation(id)
		: app.doc.rotation_limits_of(id);
	if (!reset)
	{
		if (has_active)
		{
			bool? active = op.get_bool("active");
			if (catch active)
			{
				detail.appendf(`ops[%d].active must be true or false.`, index);
				return false;
			}
			settings.constrained = active;
		}
		else if (has_axis)
		{
			settings.constrained = true;
		}

		String[3] fields = { "x", "y", "z" };
		for (usz a = 0; a < 3; a++)
		{
			Object* row = member(op, fields[a]);
			if (row == null) continue;
			if (!read_limit_axis(row, &settings.axes[a], index, fields[a], detail)) return false;
		}

		if (has_child)
		{
			String? named = op.get_string("primary_child");
			if (catch named)
			{
				detail.appendf(`ops[%d].primary_child must be a joint name, or an empty string to derive the frame automatically.`, index);
				return false;
			}
			settings.primary_child = named.len == 0 ? 0 : op_dot(app, named, index, "primary_child", detail);
			if (named.len > 0 && settings.primary_child == 0) return false;
		}

		if (has_frame)
		{
			Object* frame = member(op, "frame");
			if (!read_limit_frame(frame, &settings.saved_frame))
			{
				detail.appendf(`ops[%d].frame must be a non-zero quaternion [x,y,z,w].`, index);
				return false;
			}
			settings.has_saved_frame = true;
		}
		if (clear_frame)
		{
			settings.has_saved_frame = false;
			settings.saved_frame = quaternion::IDENTITY;
		}

		// A persistent table whose axes have no stable frame is unusable. Refuse it
		// here with the same reason the inspector will show, rather than storing a
		// constraint the caller cannot act on.
		if (settings.constrained)
		{
			RigView? opened = app.open_rig(mem);
			if (catch opened)
			{
				detail.appendf(`ops[%d] cannot define joint-local axes because this rig has no skeleton.`, index);
				return false;
			}
			RigView view = opened;
			defer view.free(mem);
			JointLimitFrame frame = joint_limit_frame(&view.skeleton, view.dot_ids, settings);
			if (!frame.usable())
			{
				detail.appendf(`ops[%d] cannot enable limits: %s.`, index, frame.status.reason());
				return false;
			}
		}
	}

	// Reaching an already-requested state is success, like rename/reach in the
	// same batch. It records nothing, so an all-no-op batch remains history-free.
	app.set_rotation_limits_recorded(id, settings);
	return true;
}

fn bool read_limit_axis(Object* row, JointAxisLimit* into, usz index, String field, DString* detail) @local
{
	if (!row.is_keyable())
	{
		detail.appendf(`ops[%d].%s must be an object with allow and its range or locked angle.`, index, field);
		return false;
	}
	bool touched = false;
	if (member(row, "allow") != null)
	{
		bool? value = row.get_bool("allow");
		if (catch value)
		{
			detail.appendf(`ops[%d].%s.allow must be true or false.`, index, field);
			return false;
		}
		into.allowed = value;
		touched = true;
	}
	String[3] names = { "minimum", "maximum", "locked" };
	float*[3] targets = { &into.minimum, &into.maximum, &into.locked };
	for (usz n = 0; n < 3; n++)
	{
		Object* given = member(row, names[n]);
		if (given == null) continue;
		double? value = given.to_value(double, false);
		if (catch value)
		{
			detail.appendf(`ops[%d].%s.%s must be a finite angle in radians.`, index, field, names[n]);
			return false;
		}
		if (!math::is_finite(value))
		{
			detail.appendf(`ops[%d].%s.%s must be a finite angle in radians.`, index, field, names[n]);
			return false;
		}
		*targets[n] = (float)value;
		touched = true;
	}
	if (!touched)
	{
		detail.appendf(`ops[%d].%s was empty; supply allow, minimum, maximum, or locked.`, index, field);
		return false;
	}
	if (into.minimum > into.maximum)
	{
		detail.appendf(`ops[%d].%s minimum %.6g is above maximum %.6g.`, index, field, into.minimum, into.maximum);
		return false;
	}
	return true;
}

fn bool read_limit_frame(Object* value, Quaternionf* into) @local
{
	if (value == null || !value.is_array() || value.get_len() != 4) return false;
	double? x = value.get_float_at(0);
	double? y = value.get_float_at(1);
	double? z = value.get_float_at(2);
	double? w = value.get_float_at(3);
	if (catch x, y, z, w) return false;
	if (!math::is_finite(x) || !math::is_finite(y) || !math::is_finite(z) || !math::is_finite(w)) return false;
	Quaternionf frame = { .v = { (float)x, (float)y, (float)z, (float)w } };
	if (frame.v.dot(frame.v) <= 1.0e-12f) return false;
	*into = frame.normalize();
	return true;
}

// ---------------------------------------------------------------------------

// The dot an op's "joint" names, or 0 with the refusal written.
fn uint op_joint(AppState* app, Object* op, usz index, DString* detail) @local
{
	String? named = op.get_string("joint");
	if (catch named)
	{
		detail.appendf(`ops[%d] needs "joint": the dot it acts on, by the name get_skeleton reports`, index);
		return 0;
	}
	return op_dot(app, named, index, "joint", detail);
}

// One dot address resolved, with the op's index in the refusal. The resolution
// itself is `resolve_dot`'s — the same one the weight tools use, so `bone_<id>`
// means here what it means there.
fn uint op_dot(AppState* app, String named, usz index, String field, DString* detail) @local
{
	// Written into a scratch buffer so the op's index can go in front of it:
	// `resolve_dot` has the sentence, and which op it belongs to is the part a
	// batch needs and a single call does not.
	DString said = dstring::new(mem);
	defer said.free();

	uint? found = resolve_dot(app, named, &said);
	if (catch found)
	{
		detail.appendf("ops[%d].%s: ", index, field);
		detail.append_string(said.str_view());
		return 0;
	}
	return found;
}

<*
 An op's `position`, snapped into the mesh when asked for.

 Snapping is on by default because an agent cannot see the model: a coordinate
 worked out from `get_scene`'s bounds lands near the surface as often as inside
 it, and a dot outside the mesh binds nothing. `snap: false` is for a caller that
 has a position it means literally.
*>
fn bool op_position(AppState* app, Object* op, usz index, bool snap, Vec3* into, DString* detail) @local
{
	Object* given = member(op, "position");
	if (given == null || !as_vec3(given, into))
	{
		detail.appendf(
			`ops[%d] needs "position": [x,y,z] in model space, the space get_skeleton reports. get_scene gives the mesh's bounds.`,
			index);
		return false;
	}

	if (snap) *into = snapped_inside(&app.voxels.grid, *into);
	return true;
}

<*
 What the rig looks like after a batch — the counts a caller needs to see its
 own edit land, and nothing that costs a rebind to answer.

 `unclaimed` is deliberately absent: `survey_weights` re-binds the whole mesh on
 every call, which is far too much to spend after every dot moves. `weights_stale`
 says the answer would have changed and `get_weights` is where to ask for it.
*>
fn String rig_json(AppState* app, usz applied)
{
	DString out = dstring::new(mem);
	defer out.free();

	usz named = 0;
	foreach (dot : app.doc.dots.array_view())
	{
		if (dot.name.len > 0) named++;
	}

	out.appendf(`{"applied":%d,"dots":%d,"named":%d,"bones":%d`,
		applied, app.doc.dots.len(), named, app.doc.edges.len());

	Dot* root = app.doc.find(app.doc.root_id);
	out.append_string(`,"root":`);
	if (root)
	{
		out.append_char('"');
		append_bone_name(&out, root.id, root.name);
		out.append_char('"');
	}
	else
	{
		out.append_string("null");
	}

	out.append_string(`,"plan":"`);
	json_escape_into(&out, app.doc.plan);
	out.append_string(`","weights_stale":`);
	out.append_string(app.weights_stale ? "true" : "false");
	out.append_string(`,"can_undo":`);
	out.append_string(app.undo_stack.can_undo() ? "true" : "false");
	out.append_char('}');

	return out.copy_str(mem);
}

<*
 apply_plan: fit a body plan's own skeleton onto the loaded mesh.

 The one call that turns a mesh into something a clip can be written for, and the
 usual first thing an agent does. `AppState.apply_plan_named` is the same entry
 point the library card uses, so a rig fitted from here and one fitted by hand
 are the same rig — seventeen dots under one undo entry, named in the plan's
 words.
*>
fn String? apply_plan(AppState* app, Object* args, DString* detail)
{
	if (!takes_object(args, detail, `apply_plan takes an object: {"plan": name}. get_scene lists the packs, and the ones carrying a body are the ones that can fit a rig.`)) return RIG_REFUSED~;

	String named;
	if (!required_string(args, "plan", &named, detail, `apply_plan needs "plan": a body-plan tag or pack name — "biped", "quadruped", "bird". get_scene lists what the library holds.`)) return RIG_REFUSED~;

	if (!app.has_mesh())
	{
		detail.append_string(`there is no mesh loaded to fit a rig onto. A body plan is measured against the model's own bounding box, so there has to be a model.`);
		return RIG_REFUSED~;
	}

	if (!app.apply_plan_named(named))
	{
		detail.appendf(`no pack carrying a body answers to "%s"`, named);
		append_plan_names(detail, app);
		return RIG_REFUSED~;
	}

	app.plan_targets_stale = true;
	app.refresh_ui();
	return rig_json(app, 1);
}

// The plans that could have been asked for. Only packs carrying a body: a
// clips-only pack carries its plan's tag too, and naming one here would be
// advice that fails when taken.
fn void append_plan_names(DString* out, AppState* app) @local
{
	usz shown = 0;
	foreach (&pack : app.packs)
	{
		if (!pack.is_body_plan()) continue;
		out.append_string(shown == 0 ? ". Body plans in the library: " : ", ");
		out.append_string(pack.plan.len > 0 ? pack.plan : pack.name);
		shown++;
	}
	if (shown == 0)
	{
		out.append_string(". No pack in the library carries a body, so no plan can be fitted from one; the rig has to be built by hand with edit_rig.");
	}
}

<*
 undo / redo: step the rig's history, as the keyboard does.

 On the wire because an agent that has just made things worse should be able to
 put them back without asking the person at the screen to reach for Ctrl+Z — and
 because that is what makes the rest of this surface safe to hand out.

 One call is one step of the same history the viewport writes, so a step may take
 back an agent's batch or a user's own placement, whichever came last. That is
 the point of there being one history rather than two.
*>
fn String? step_history(AppState* app, Object* args, bool forward, DString* detail)
{
	usz steps = 1;
	if (args != null && args.is_keyable())
	{
		if (try double given = args.get_float("steps"))
		{
			if (given < 1)
			{
				detail.appendf(`"steps" is %.9g. A step is one edit taken back, so it starts at 1.`, given);
				return RIG_REFUSED~;
			}
			steps = (usz)given;
		}
	}

	usz moved = 0;
	for (usz i = 0; i < steps; i++)
	{
		if (!(forward ? app.redo() : app.undo())) break;
		moved++;
	}

	app.plan_targets_stale = true;
	app.refresh_ui();
	return rig_json(app, moved);
}

<*
 scale_model: resize the whole model, by a height or a factor.

 The same `AppState.scale_model_by` the Scale model dialog calls, so the step it
 records is the one the dialog records and one undo takes either back.
*>
fn String? scale_model_tool(AppState* app, Object* args, DString* detail)
{
	if (!takes_object(args, detail, `scale_model takes an object: {"height": units} or {"factor": n}.`)) return RIG_REFUSED~;

	double? height = args.get_float("height");
	double? factor = args.get_float("factor");
	if (try height && try factor)
	{
		detail.append_string(`give "height" or "factor", not both — they are two ways of saying one size.`);
		return RIG_REFUSED~;
	}

	float before = app.model_height();
	ScaleModelResult result;
	if (try height)
	{
		result = app.scale_model_to_height((float)height);
	}
	else if (try factor)
	{
		result = app.scale_model_by((float)factor);
	}
	else
	{
		detail.append_string(`scale_model needs "height" (how tall the model should stand) or "factor" (how much to grow it).`);
		return RIG_REFUSED~;
	}

	switch (result)
	{
		case SCALED:
		case UNCHANGED:
			break;
		case LOCKED:
			detail.append_string(`a pose edit is open; finish it first, the same as resizing by hand.`);
			return RIG_REFUSED~;
		case REFUSED:
			detail.appendf(`nothing to scale, or a size out of range: a factor is %.4g to %.4g, a height has to be above zero.`,
				SCALE_MODEL_MIN, SCALE_MODEL_MAX);
			return RIG_REFUSED~;
	}
	app.refresh_ui();

	DString out = dstring::new(mem);
	defer out.free();
	out.appendf(`{"scaled":%s,"height_before":%s,"height":%s,"unsaved":%s}`,
		result == SCALED ? "true" : "false", (JsonFloat)before, (JsonFloat)app.model_height(),
		app.mesh_resized ? "true" : "false");
	return out.copy_str(mem);
}
