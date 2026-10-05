<*
 Body plans: a whole rig placed at once, and the ghosts that show where it
 wanted to put things.

 A plan is a named rest skeleton — from `core/presets.c3`'s built-in tables or
 from a pack in the library that declares one — fitted to the mesh's voxel grid
 by `core/presets.c3` and then placed as ordinary recorded dots. Nothing about
 the result remembers the pack afterwards except `doc.plan`, which is what
 decides which packs are offered next time.

 Placing is deliberately not automatic on selecting a pack: browsing what a pack
 holds is a read, and placing seventeen dots is an edit.

 The targets are the other half. `plan_targets` is where the fit *wanted* each
 named joint, kept after the placement so a dot dragged away from its plan can
 be shown next to where the plan put it — which is the only way to tell "this
 rig was adjusted" from "this rig was fitted to a different mesh".
*>
module crig;

import rig;
import std::math;



<*
 Drops a body plan into the document (M2).

 The dots arrive as ordinary recorded placements with one commit at the end, so
 nineteen dots and eighteen bones are one Ctrl+Z — which is what makes trying a
 preset free. Nothing else about them is special: they carry no template, no
 link back to the table they came from, and the next click cannot tell them from
 hand-placed ones.

 **Replaces whatever rig was there**, in the same undo group as the dots it
 places. Two rigs in one document is not a state anyone wants: the second
 chain hangs off nothing, exports as a second root, and every joint has a twin a
 millimetre away that the skin splits its weights between. Silently deleting
 placed work would be worse than either, so the asking happens above this — see
 `request_pack_rig`, which is the door every interactive path comes through.
 Undo brings the old rig back whole, since the clearing and the placing are one
 entry.

 The first dot of the table is the pelvis, and it becomes the document root by
 the ordinary rule that the first dot in an empty document does.

 @param physics : `The rig's jiggle setup, indexed against preset.dots. Only a pack-derived table can carry one, since AnimPack.preset is index-parallel to the pack's joints while a built-in table's mirror rows expand into two dots each.`
 @param constraints : `Reusable anatomical limits in the same source-joint order. Exact rows are matched onto the fitted dots by name and rebuilt in the target rest frame; foreign or unsupported rows are reported and left on the template.`
 @param source_rest : `The pack's own rest skeleton, index-parallel to preset.dots — the joints the constraint rows were written against. Empty for a built-in table, which falls back to the plan's proportions.`
*>
fn void AppState.apply_preset(
	&self,
	Preset preset,
	String plan = "",
	RigPhysics physics = {},
	ConstraintRig constraints = {},
	rig::Skeleton source_rest = {})
{
	bool reversed = false;
	FittedDot[] fitted = fit_preset(mem, preset, self.geometry.bounds(), &self.voxels, &reversed);
	if (fitted.len == 0)
	{
		self.@notice("the %s skeleton is empty", preset.name);
		return;
	}
	defer free_fitted(mem, fitted);

	// After the fit, not before: a preset that turns out to be empty must leave
	// the document exactly as it found it, and this is the first line that could
	// not be taken back by returning.
	usz replaced = self.clear_rig_recorded();

	// Every dot in the document is about to be a different dot. Ids are not
	// reused, so a handle held across this resolves to nothing rather than to the
	// wrong joint — but "invalidated by a body plan being fitted" is a better
	// answer than "that dot was removed", and it is the true one.

	uint[] ids = alloc::new_array(mem, uint, (sz)fitted.len);
	defer alloc::free(mem, ids);

	usz stranded = 0;
	foreach (usz i, dot : fitted)
	{
		ids[i] = self.add_recorded(dot.position, dot.name);
		if (dot.parent >= 0)
		{
			self.connect_recorded(ids[(usz)dot.parent], ids[i]);
		}
		if (!dot.landed) stranded++;
	}

	// Before the commit, so a plan that brings a tail with it is still one Ctrl+Z.
	if (physics.present()) self.adopt_preset_physics(physics, preset, fitted, ids);
	ConstraintApplyReport constraint_report = self.adopt_preset_constraints(
		constraints, preset, fitted, ids, reversed, source_rest);

	self.undo_stack.commit();
	self.doc.set_plan(plan);
	self.mark_rig_stale();
	self.select(ids[0]);
	self.refresh_ui();

	// Only what the user can act on follows the count: a fit that came out facing
	// -Z (the facing is measured and can be wrong), joints outside the mesh, the
	// rig it replaced, and limits that did not match.
	String facing = reversed ? " · facing -Z" : "";
	String outside = stranded > 0
		? string::tformat(" · %d joint%s outside the mesh", stranded, stranded == 1 ? " is" : "s are")
		: "";
	String swapped = replaced > 0 ? string::tformat(" · replaced %d joints", replaced) : "";
	usz constraints_skipped = constraint_report.skipped();
	String limits = "";
	if (constraint_report.present())
	{
		limits = constraints_skipped > 0
			? string::tformat(" · %d joint limit%s, %d didn't match", constraint_report.applied,
				constraint_report.applied == 1 ? "" : "s", constraints_skipped)
			: string::tformat(" · %d joint limit%s", constraint_report.applied, constraint_report.applied == 1 ? "" : "s");
	}
	self.@notice("Fitted the %s skeleton · %d joints%s%s%s%s",
		preset.name, fitted.len, facing, outside, swapped, limits);
	self.fit_reversed = reversed;
}

<*
 Apply the body plan a pack carries: its own rest skeleton, fitted to this mesh.

 The dots arrive as ordinary recorded placements under one undo entry, exactly
 as a hand-placed chain would — see `apply_preset`. Nothing about them
 remembers the pack afterwards except `doc.plan`, which is what decides
 which packs are offered next time.

 Deliberately not automatic on selecting a pack. Browsing what a pack holds is a
 read; placing seventeen dots is an edit, and a user clicking through a library
 to see what is in it must not have the rig rewritten under them each time.

 @return `False when there is no such pack, or it carries no body to measure against.`
*>
fn bool AppState.apply_pack_rig(&self, usz index)
{
	AnimPack* pack = self.pack(index);
	if (!pack) return false;
	if (!pack.is_body_plan())
	{
		self.@notice("%s carries no body to fit a rig from", pack.name);
		return false;
	}

	Preset derived = pack.preset(mem);
	defer free_preset(mem, derived);
	self.apply_preset(derived, pack.plan, pack.physics, pack.constraints, pack.rest);
	return true;
}

<*
 Put the body plan's joint limits back on the rig as it stands, without fitting
 it again — the joints stay where the user placed them; only the limit rows are
 rebuilt against their frames, by name, as one undo step.

 What a rig fitted before the limit transfer read the pack's real skeleton needs:
 its limits are on the wrong axes (a hip that swings sideways where it should
 swing forward) and a re-fit would throw the placement away. The facing is read
 off the rig itself, since a Turn around after the fit changed it: the source's
 left joints on the other side of X from this rig's means it is turned half round.

 @return `How many joints took a limit; -1 when the rig has no body plan with limits.`
*>
fn sz AppState.reapply_plan_limits(&self)
{
	int found = self.plan_pack(self.doc.plan);
	if (found < 0) return -1;
	AnimPack* pack = self.pack((usz)found);
	if (!pack || pack.constraints.joints.len == 0) return -1;

	Preset derived = pack.preset(mem);
	defer free_preset(mem, derived);

	usz count = (usz)self.doc.dots.len();
	FittedDot[] fitted = alloc::new_array(mem, FittedDot, (sz)count);
	defer alloc::free(mem, fitted);
	uint[] ids = alloc::new_array(mem, uint, (sz)count);
	defer alloc::free(mem, ids);
	foreach (usz i, dot : self.doc.dots.array_view())
	{
		fitted[i] = { .name = dot.name, .position = dot.position, .parent = -1, .landed = true };
		ids[i] = dot.id;
	}

	// Facing, from which side each rig keeps its left.
	float source_side = 0.0f;
	float target_side = 0.0f;
	foreach (usz j, name : pack.joint_names)
	{
		if (j >= pack.rest.len()) break;
		float sign = name.ends_with("_L") || name.ends_with("_l") ? 1.0f
			: (name.ends_with("_R") || name.ends_with("_r") ? -1.0f : 0.0f);
		if (sign == 0.0f) continue;
		source_side += sign * pack.rest.joints[j].x;
		foreach (dot : self.doc.dots.array_view())
		{
			if (dot.name == name) target_side += sign * dot.position.x;
		}
	}
	bool reversed = source_side * target_side < 0.0f;

	sz before = self.undo_stack.edits.len();
	ConstraintApplyReport report = self.adopt_preset_constraints(
		pack.constraints, derived, fitted, ids, reversed, pack.rest);
	if (self.undo_stack.edits.len() != before) self.undo_stack.commit();
	self.mark_rig_stale();
	return (sz)report.applied;
}

<*
 Carry a pack's exact anatomical limits onto the dots its plan just fitted.

 Names are the boundary. A fit may omit optional source rows, and the target's
 breadth-first joint order is allowed to differ from the file's, so neither
 source nor target indices are stable across this operation. A duplicate name
 is refused with the same caution as a missing one: choosing the first would
 make a constraint land differently after an unrelated topology edit.

 The frame is rebuilt from the target rest skeleton. An adjusted source frame
 contributes only its bone-relative quaternion (`base * adjustment`), never its
 absolute source-space rotation. Missing primary children and target topology
 that cannot define the requested frame are skipped rather than guessed.

 **The rows are read across the two derived frames, not copied.** A derived
 frame's two swing axes are whichever world cardinals the bone leans least
 along, so a thigh that is nearly vertical has its X along world x on one rig
 and along world z on another — and a fit that put the head toward −Z has
 turned the whole figure half way round, so the axis that folded a knee *back*
 on the source points the other way on the target. So each target swing axis
 takes the row of the source axis it lies along, with the source turned the
 same half turn first. Adjusted frames keep their adjustment as it is.

 Every accepted row goes through `set_rotation_limits_recorded`, and this
 function deliberately does not commit. `apply_preset` closes the group after
 this returns, so replacing the old rig, fitting the new one, adopting physics
 and adopting constraints remain one Ctrl+Z.

 @param reversed : `Whether the fit put the plan's head toward −Z, turning the source figure half way round about Y.`
 @param source_rest : `The pack's rest skeleton the rows were written against; see apply_preset.`
*>
fn ConstraintApplyReport AppState.adopt_preset_constraints(
	&self,
	ConstraintRig constraints,
	Preset preset,
	FittedDot[] fitted,
	uint[] ids,
	bool reversed = false,
	rig::Skeleton source_rest = {})
{
	ConstraintApplyReport report = {
		.unsupported = constraints.skipped + constraints.foreign.len,
	};
	if (constraints.joints.len == 0) return report;

	uint[] dot_ids;
	rig::Skeleton? built = build_skeleton(&self.doc, mem, &dot_ids);
	if (catch built)
	{
		foreach (source : constraints.joints)
		{
			if (source.status == EXACT)
			{
				report.invalid_frame++;
			}
			else if (source.status == UNSUPPORTED)
			{
				report.unsupported++;
			}
		}
		return report;
	}
	rig::Skeleton target = built;
	defer
	{
		target.free(mem);
		if (dot_ids.len > 0) alloc::free(mem, dot_ids);
	}

	// The source rig as the rows were written against it, for the frames the
	// rows are read across: the pack's own rest skeleton when there is one. The
	// plan's proportions are only a stand-in — a biped plan puts every joint at
	// mid-depth, so its thigh leans only sideways, and a near-vertical bone's frame
	// takes its X from whichever way the bone leans least: the flattened thigh's X
	// came out pointing forward where the real one's points across, and the hip's
	// forward swing landed on the sideways axis (a leg that could not sit). A
	// hand-written table has no pack, and is read as its proportions say.
	bool real = source_rest.len() == preset.dots.len && source_rest.len() > 0;
	rig::Skeleton origin = real ? source_rest : preset_skeleton(mem, preset);
	defer if (!real) origin.free(mem);

	foreach (usz source_joint, source : constraints.joints)
	{
		if (source.status == FREE) continue;
		if (source.status == UNSUPPORTED)
		{
			report.unsupported++;
			continue;
		}

		if (source_joint >= preset.dots.len)
		{
			report.missing_joint++;
			continue;
		}
		uint target_dot = unique_fitted_dot_id(
			preset.dots[source_joint].name, fitted, ids);
		if (target_dot == 0)
		{
			report.missing_joint++;
			continue;
		}

		uint primary_dot = 0;
		if (source.frame_intent.uses_primary_child())
		{
			if (source.primary_child < 0 || (usz)source.primary_child >= preset.dots.len)
			{
				report.missing_primary_child++;
				continue;
			}
			primary_dot = unique_fitted_dot_id(
				preset.dots[(usz)source.primary_child].name, fitted, ids);
			if (primary_dot == 0)
			{
				report.missing_primary_child++;
				continue;
			}
		}

		JointRotationLimits limits = unconstrained_rotation(target_dot);
		limits.constrained = true;
		limits.axes = source.axes;
		limits.primary_child = primary_dot;

		JointLimitFrame base = joint_limit_frame(&target, dot_ids, limits);
		if (!base.usable())
		{
			report.invalid_frame++;
			continue;
		}
		if (source.frame_intent.has_adjustment())
		{
			limits.has_saved_frame = true;
			limits.saved_frame = base.rotation.mul(source.frame_adjustment).normalize();
		}
		else if (source_joint < origin.len())
		{
			JointLimitFrame from = joint_limit_frame_by_index(&origin, source_joint,
				source.frame_intent.uses_primary_child() ? source.primary_child : -1);
			if (from.usable())
			{
				limits.axes = carried_axes(source.axes, from.rotation, base.rotation, reversed);
			}
		}

		if (self.set_rotation_limits_recorded(target_dot, limits))
		{
			report.applied++;
		}
		else
		{
			report.invalid_frame++;
		}
	}

	return report;
}

<*
 Carry a pack's physics onto the dots its plan just placed, by name.

 	`self.adopt_preset_physics(physics, preset, fitted, ids);`

 By name and not by index, because the fit is allowed to drop dots — an optional
 joint the table marks and this mesh has no place for — so the k-th fitted dot is
 not the k-th table row. Names are what everything downstream of a fit already
 joins on (`plan_target`, `dot_named`), and a joint a plan carries physics for
 always has one.

 The file speaks in bones and the document in chains, so the bones are gathered
 by dot and folded into chains by `adopt_bones_recorded` — a tail authored bone
 by bone under the old model lands as one Tail-shaped chain.

 **The radii are rescaled and the rest is not.** Flexibility, damping, gravity
 and the swing are ratios and angles: they mean the same thing on a mouse and on
 an elephant. A collider radius and a chain's thickness are model units, and
 this plan was authored against a different body — so they are scaled by how
 much bigger this one is, measured as the ratio of the two bounding boxes'
 diagonals. That is a guess, and it is a far better one than carrying a
 squirrel's belly onto a horse unchanged.

 Recorded, not committed: the caller's group is still open, so the tail arrives
 in the same Ctrl+Z as the dots it hangs off.

 @return `How many entries landed.`
*>
fn usz AppState.adopt_preset_physics(&self, RigPhysics physics, Preset preset, FittedDot[] fitted, uint[] ids)
{
	rig::Bounds box = self.geometry.bounds();
	float here = (box.max - box.min).length();
	float there = preset.extent.length();
	float scale = there > 1.0e-6f && here > 0.0f ? here / there : 1.0f;

	usz landed = 0;

	if (physics.joints.len > 0)
	{
		JiggleSpec[] bones = alloc::new_array(mem, JiggleSpec, (sz)physics.joints.len);
		defer alloc::free(mem, bones);
		usz gathered = 0;
		foreach (spec : physics.joints)
		{
			if (spec.joint >= preset.dots.len) continue;
			uint id = fitted_dot_id(preset.dots[spec.joint].name, fitted, ids);
			if (id == 0) continue;
			JiggleParams params = spec.params;
			params.radius *= scale;
			bones[gathered++] = { .dot_id = id, .params = params };
		}
		landed += self.adopt_bones_recorded(bones[:gathered]);
	}

	foreach (spec : physics.colliders)
	{
		if (spec.joint >= preset.dots.len) continue;
		uint id = fitted_dot_id(preset.dots[spec.joint].name, fitted, ids);
		if (id != 0 && self.set_collider_recorded(id, spec.radius * scale)) landed++;
	}

	return landed;
}

// Which dot a fitted table row became, or 0 for a row the fit did not place.
<*
 The plan's dots as a skeleton, in the space the pack measured them in.
*>
fn rig::Skeleton preset_skeleton(Allocator allocator, Preset preset) @local
{
	rig::Skeleton out = {
		.joints = alloc::new_array(allocator, Vec3, (sz)preset.dots.len),
		.parents = alloc::new_array(allocator, int, (sz)preset.dots.len),
	};
	bool measured = preset.extent.length_sq() > 0.0f;
	foreach (usz i, dot : preset.dots)
	{
		out.joints[i] = measured ? dot.at * preset.extent : dot.at;
		out.parents[i] = dot.parent;
	}
	return out;
}

<*
 A source row read against the target's derived frame.

 Each target swing axis takes the row of the source axis it lies along, with
 the sign of that alignment. A reversed fit is the source turned half way round
 about Y, so the source axes are turned with it before they are compared — a
 turn carries a rotation as it is, where a reflection would turn every row about.
 The twist axis is the bone on both sides.
*>
fn JointAxisLimit[3] carried_axes(JointAxisLimit[3] axes, Quaternionf from, Quaternionf to, bool reversed) @local
{
	Vec3 xs = from.rotate_vec3({ 1, 0, 0 });
	Vec3 zs = from.rotate_vec3({ 0, 0, 1 });
	if (reversed)
	{
		xs = { -xs.x, xs.y, -xs.z };
		zs = { -zs.x, zs.y, -zs.z };
	}
	JointAxisLimit[3] out;
	out[0] = carried_axis(to.rotate_vec3({ 1, 0, 0 }), xs, zs, axes[0], axes[2]);
	out[1] = axes[1];
	out[2] = carried_axis(to.rotate_vec3({ 0, 0, 1 }), xs, zs, axes[0], axes[2]);
	return out;
}

fn JointAxisLimit carried_axis(Vec3 axis, Vec3 xs, Vec3 zs, JointAxisLimit x_row, JointAxisLimit z_row) @local
{
	float along_x = axis.dot(xs);
	float along_z = axis.dot(zs);
	bool from_x = math::abs(along_x) >= math::abs(along_z);
	JointAxisLimit row = from_x ? x_row : z_row;
	// An axis that points the other way turns the row about.
	return (from_x ? along_x : along_z) < 0.0f ? turned_about(row) : row;
}

fn JointAxisLimit turned_about(JointAxisLimit row) @local => {
	.allowed = row.allowed,
	.minimum = -row.maximum,
	.maximum = -row.minimum,
	.locked = -row.locked,
};

fn uint fitted_dot_id(String name, FittedDot[] fitted, uint[] ids) @local
{
	if (name.len == 0) return 0;
	foreach (usz i, dot : fitted)
	{
		if (dot.name == name) return ids[i];
	}
	return 0;
}

// The unique fitted dot carrying `name`. Constraint transfer must not choose a
// first match when a malformed plan repeats a name: that would be an arbitrary
// anatomical edit. Physics predates this stricter boundary and keeps its own
// first-match helper above for compatibility.
fn uint unique_fitted_dot_id(String name, FittedDot[] fitted, uint[] ids) @local
{
	if (name.len == 0) return 0;
	uint found = 0;
	foreach (usz i, dot : fitted)
	{
		if (dot.name != name) continue;
		if (found != 0 || i >= ids.len) return 0;
		found = ids[i];
	}
	return found;
}

<*
 The pack carrying a body plan, however the user spelled its name.

 Matched case-insensitively against the pack's plan tag first, then its display
 name — the tag is what a command line would say, the name is what the library
 shows.

 An empty name matches nothing, rather than matching the first untagged pack in
 the library. That is not a nicety: an untagged clip file has an empty plan tag
 and so does a document with no plan applied, and without the guard the two
 would compare equal.

 Packs carrying no body are skipped, and the tag alone is not enough to identify
 one. A clips-only pack carries the tag of the plan it was authored against —
 `Mixamo` and anything `save_pack` writes for a biped are both tagged `biped` —
 so matching on the tag alone answers with whichever of them the library lists
 first, and the plan then fails to apply for want of a body to fit from.

 @return `Its index in the library, or -1 when no pack with a body carries that plan.`
*>
fn int AppState.plan_pack(&self, String name)
{
	if (name.len == 0) return -1;

	foreach (usz i, &pack : self.packs)
	{
		if (pack.is_body_plan() && name.compare_to_ignore_case(pack.plan) == 0) return (int)i;
	}
	foreach (usz i, &pack : self.packs)
	{
		if (pack.is_body_plan() && name.compare_to_ignore_case(pack.name) == 0) return (int)i;
	}
	return -1;
}

<*
 Apply the body plan a name picks out, however the user spelled it.

 @return `False when nothing matches, which is what the caller reports.`
*>
fn bool AppState.apply_plan_named(&self, String name)
{
	int index = self.plan_pack(name);
	if (index < 0) return false;
	return self.apply_pack_rig((usz)index);
}

<*
 Re-fit the document's body plan onto the mesh, replacing whatever was cached.

 Frees the previous fit, so every `FittedDot*` handed out by `plan_target`
 before this dangles afterwards.

 An empty result is an answer rather than a failure, and there are three ways to
 reach it: the document carries no plan, no pack in the library carries that
 plan, or the pack that does carries no body to fit from. All three mean the
 same thing to the caller — this rig has nothing to be measured against.
*>
fn void AppState.refit_plan_targets(&self)
{
	free_fitted(mem, self.plan_targets);
	self.plan_targets = {};
	self.plan_targets_stale = false;

	if (self.plan_fitted.len > 0) alloc::free(mem, self.plan_fitted.ptr);
	self.plan_fitted = self.doc.plan.len > 0 ? self.doc.plan.copy(mem) : "";

	int index = self.plan_pack(self.doc.plan);
	if (index < 0) return;

	AnimPack* pack = self.pack((usz)index);
	if (!pack || !pack.is_body_plan()) return;

	Preset derived = pack.preset(mem);
	defer free_preset(mem, derived);

	self.plan_targets = fit_preset(mem, derived, self.geometry.bounds(), &self.voxels);
}

<*
 Where the body plan wants the dot of this name, on this mesh.

 Re-fits first if the plan or the library has moved since the last call, which
 invalidates every pointer returned before it — so hold the result no longer
 than the paint or the readout that asked for it.

 A hand-placed dot is unnamed and has no target; so has a named dot whose plan
 does not carry that name, which is what a rig built from two different plans
 looks like.

 @return `The plan's dot of that name, or null when there is none.`
*>
fn FittedDot* AppState.plan_target(&self, String name)
{
	if (name.len == 0) return null;
	if (self.plan_targets_stale || self.plan_fitted != self.doc.plan)
	{
		self.refit_plan_targets();
	}

	foreach (&dot : self.plan_targets)
	{
		if (dot.name == name) return dot;
	}
	return null;
}

<*
 How far a dot may sit from its plan target before the offset is worth drawing,
 as a fraction of the mesh's diagonal.

 Below this the ring would overlap the dot it points at and the line joining
 them would have no direction to show: framed, the diagonal spans most of the
 viewport, so a hundredth of it is about the radius a dot is drawn at. A dot the
 fit already placed correctly must not grow decoration.
*>
const float PLAN_OFFSET_MIN = 0.01;

faultdef NO_PLAN_TARGET;

<*
 Where the body plan wants the selected dot, when that is somewhere it is not.

 The one question the overlay and the HUD both ask, so they answer it from here
 rather than each applying the threshold themselves — a ring drawn without a
 readout beside it, or the reverse, is worse than neither.

 @return `The target in model space, or NO_PLAN_TARGET when the dot has none or already sits on it.`
*>
fn Vec3? AppState.selected_plan_target(&self)
{
	if (self.selected == 0) return NO_PLAN_TARGET~;

	Dot* dot = self.doc.find(self.selected);
	if (!dot) return NO_PLAN_TARGET~;

	FittedDot* target = self.plan_target(dot.name);
	if (!target) return NO_PLAN_TARGET~;

	if ((target.position - dot.position).length() < self.picker.scale * PLAN_OFFSET_MIN)
	{
		return NO_PLAN_TARGET~;
	}
	return target.position;
}
