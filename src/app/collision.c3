<*
 The self-collision service's seam: the policy over the deformed surface, the
 one setting both read, and the blocking a pose write goes through (C3).

 `core/posed_occlusion.c3` finds the pairs and `core/collision_policy.c3`
 decides which count; what is here is how the editor holds the two together.
 Both are rebuilt with the skin binding in `rebind_skin`, so a rig edit that
 renumbers the joints renumbers them under the policy as well, and both are
 released with it.

 ## The switch

 All of it is behind `CrigConfig.self_collision`, off by default: with it off
 no policy is built, no write is checked, and nothing below is shown — not
 the per-rig control, not the status line, not the dialog. It is turned on in
 Settings by someone who wants it, and `set_self_collision` is the one door,
 so the policy comes up or goes with the setting rather than at the next
 rebind. What the rig's session holds about it — *Prevent intersections*,
 the clearance, the exclusions — is kept either way and means something
 again the moment it is on.


*>
module crig;

import rig;
import collision;
import std::math;
import std::math::quaternion;
import std::collections::list;
import std::time;

<*
 What counts as touching, as a fraction of the picker's bounds diagonal.

 A small visible clearance rather than exact contact, scaled from the mesh so
 a model in millimetres and one in metres are held off by the same visible
 gap: half a percent of the diagonal is about a centimetre on a standing
 human. The Advanced section will let a rig override it; until then this is
 the one number.
*>
const float COLLISION_CLEARANCE = 0.005f;

// The most a rig may ask for: a tenth of the diagonal is a clearance wider
// than a limb, past which the check stops meaning contact.
const float MAX_COLLISION_CLEARANCE = 0.1f;

// The clearance this rig measures against, as a fraction of the diagonal.
fn float AppState.collision_clearance_fraction(&self) => self.doc.collision_clearance > 0.0f
	? self.doc.collision_clearance
	: COLLISION_CLEARANCE;

fn float AppState.collision_clearance(&self) => self.picker.scale * self.collision_clearance_fraction();

<*
 How finely a blocked move is bisected between the last clear rotation and
 the request. Eight halvings put the joint within 1/256 of the requested
 sweep from the surface — a third of a degree on a quarter turn — for eight
 regional refits. Three is what a mesh over budget gets: an eighth of the
 sweep, coarse but still a stop rather than a pass.

 That is the most a search costs, not what every search costs: the halvings
 stop once the interval left is under `COLLISION_SEARCH_RESOLUTION`. A
 pointer moves a joint a degree or two between frames, and bisecting that
 to the full depth would put the joint within a thousandth of a degree of
 the surface — six tests to learn nothing the clearance does not already
 hide. A quarter of a degree is a few millimetres at a limb's length, under
 the clearance on any figure, and three halvings of a pointer step reach it.
*>
const usz COLLISION_SEARCH_STEPS = 8;
const usz COLLISION_SEARCH_STEPS_REDUCED = 3;
const float COLLISION_SEARCH_RESOLUTION = (float)(0.25 * math::PI / 180);

<*
 Seconds one checked write may take before the check is cut back. Only a
 blocked write costs more than one test — a clear one is a refit and a
 measurement — so this is the frame a hand pressed against the body may
 take, not the frame a free one does: a tenth of a second is a stutter
 while pushing, where the joint is visibly stopped anyway, and a mesh that
 needs longer than that for its bisection is what the reduced check is
 for. A single test over this is a mesh the check cannot follow at all.
*>
const float COLLISION_TIME_BUDGET = 0.1f;

<*
 How far inside the clearance a gesture's start has to be before the
 gesture is left unchecked. A blocked gesture leaves its joint just clear
 of the surface, and the pose the next one begins from is that one keyed
 and sampled back — the same rotation to within rounding, which is enough
 to put a gap that was a hair over the clearance a hair under it. Read at
 face value that would suspend every second gesture against the body, and
 the joint would pass through on the one that pushes. So a start counts
 as in contact only when it is well inside: a crossing, or a pose that
 came from a clip or an unchecked gesture with the skin actually folded.
*>
const float COLLISION_SUSPEND_FRACTION = 0.5f;

<*
 How much of the check a mesh is getting. `REDUCED` bisects coarsely and
 skips the careful IK pass; `PAUSED` checks nothing until the control is
 toggled or the skin rebound.
*>
enum CollisionMode : char
{
	FULL,
	REDUCED,
	PAUSED,
}

fn String CollisionMode.label(self)
{
	switch (self)
	{
		case FULL: return "full";
		case REDUCED: return "reduced";
		case PAUSED: return "paused";
	}
}

fn float AppState.collision_budget_seconds(&self) => self.collision_budget > 0.0f
	? self.collision_budget
	: COLLISION_TIME_BUDGET;

// The most anyone may ask for: past twelve halvings a float cannot tell the
// candidates apart.
const usz MAX_COLLISION_SEARCH_STEPS = 12;

// The depth the Advanced dialog set, or the default.
fn usz AppState.collision_search_steps_setting(&self) => self.collision_search_steps_override > 0
	? self.collision_search_steps_override
	: COLLISION_SEARCH_STEPS;

fn bool AppState.set_collision_search_steps(&self, int steps)
{
	if (steps < 1 || (usz)steps > MAX_COLLISION_SEARCH_STEPS) return false;
	self.collision_search_steps_override = (usz)steps;
	return true;
}

// The depth a write bisects at: the setting, or the reduced depth when the
// mesh is over budget and the setting is deeper than that.
fn usz AppState.collision_search_steps(&self)
{
	usz set = self.collision_search_steps_setting();
	return self.collision_mode == REDUCED ? math::min(set, COLLISION_SEARCH_STEPS_REDUCED) : set;
}

<*
 The halvings a blocked move of `angle` radians is bisected by: the depth
 the mode allows, or as many as bring the interval under the resolution,
 and never fewer than one.
*>
fn usz AppState.collision_search_depth(&self, float angle)
{
	usz most = self.collision_search_steps();
	usz steps = 0;
	float interval = angle;
	while (steps < most && interval > COLLISION_SEARCH_RESOLUTION)
	{
		interval *= 0.5f;
		steps++;
	}
	return math::max(steps, (usz)1);
}

// The angle one rotation turns through to become another.
fn float rotation_angle_between(Quaternionf from, Quaternionf to)
{
	float cosine = math::abs(from.v.dot(to.v));
	return 2.0f * (float)math::acos(math::min(cosine, 1.0f));
}

<*
 One contact the narrow phase found: which pair, where, and how close.
*>
struct CollisionContact
{
	bool hit;
	DeformedTrianglePair pair;
	TriangleGap gap;
}

<*
 What one blocked write met — the readout's, the tests' and C5's account of
 the check.
*>
struct CollisionBlock
{
	// A check ran: blocking is on, a policy is built, and the gesture did not
	// begin in contact.
	bool tested;
	// The request was cut short. `fraction` says how much of it was accepted;
	// zero is a joint that stayed where it was.
	bool blocked;
	float fraction;
	// Narrow-phase passes this write cost.
	usz tests;
	// The nearest contact that stopped it, for drawing.
	CollisionContact contact;
	// A pull: how far the grabbed joint still is from the target once the
	// solve stopped, and whether that is more than the solver's tolerance —
	// the target is out of reach, the mesh in the way or not.
	float residual;
	bool unreached;
	// What the write cost, and what the last narrow phase sorted its pairs
	// into — the diagnostics the Advanced section shows.
	float seconds;
	CollisionPairCounts counts;
	// The mode the write ran under.
	CollisionMode mode;
	// The pose stamp the contact was drawn against: the ring shows while the
	// displayed pose is still this one, and goes with the first scrub, step of
	// history or new gesture that replaces it.
	uint shown_at;
}

<*
 Whether a pose write is checked at all: the system is switched on, blocking
 is on for this rig, not paused for this mesh, and the binding has a policy
 to check it against.
*>
fn bool AppState.collision_blocking_active(&self) => self.config.self_collision
	&& !self.doc.allow_intersections
	&& self.collision_mode != PAUSED
	&& self.collision_policy.ready && self.skin_joints > 0;

<*
 The switch for the whole system, kept in the config. On, and the policy is
 built over whatever skin is bound; off, and it is released along with the
 last check's account, so nothing is left to draw or report.
*>
fn void AppState.set_self_collision(&self, bool on)
{
	if (self.config.self_collision == on) return;
	self.config.self_collision = on;
	self.config.save();
	self.rebuild_collision_policy();
}

<*
 The one normal control: on blocks, off lets joints pass through the body.
 Toggling either way retries a paused check — the reason for the toggle is
 usually that the mesh gave up, and the user asking again is the retry.
*>
fn void AppState.set_prevent_intersections(&self, bool prevent)
{
	self.doc.allow_intersections = !prevent;
	self.collision_mode = FULL;
	self.last_block = {};
}

<*
 Sets the clearance as a fraction of the diagonal and rebuilds the policy
 over it — the rest contacts depend on it — when a policy is up.

 @return `False when the fraction is not a usable one; nothing changes then.`
*>
fn bool AppState.set_collision_clearance(&self, float fraction)
{
	if (!math::is_finite(fraction) || fraction <= 0.0f || fraction > MAX_COLLISION_CLEARANCE) return false;
	self.doc.collision_clearance = fraction;
	self.rebuild_collision_policy();
	return true;
}

<*
 The policy again over the surface that stands, for a clearance or a binding
 that changed under it. Nothing when no skin is bound — `rebind_skin` builds
 it with the surface then — and nothing when the system is off.
*>
fn void AppState.rebuild_collision_policy(&self)
{
	self.collision_policy.free();
	self.collision_mode = FULL;
	self.last_block = {};
	if (!self.config.self_collision) return;
	if (!self.deformed_surface.root || self.skin_joints == 0) return;
	RigView? opened = self.open_rig(mem);
	if (catch opened) return;
	RigView view = opened;
	defer view.free(mem);
	if (view.len() != (usz)self.skin_joints) return;
	self.collision_policy = build_collision_policy(&self.deformed_surface,
		view.skeleton.parents, view.dot_ids, self.collision_clearance(), &self.doc,
		self.adjacency_for().class_of, self.skin);
}

<*
 Reads what the last write cost against the budget and sets the mode the
 next one runs under. Called after every checked write. A write that was
 not tested says nothing about the mesh and changes nothing.
*>
fn void AppState.judge_collision_cost(&self)
{
	CollisionBlock* block = &self.last_block;
	block.mode = self.collision_mode;
	if (!block.tested || block.tests == 0) return;
	float budget = self.collision_budget_seconds();
	float per_test = block.seconds / (float)block.tests;
	// Said once, when it happens: the modes line keeps saying it afterwards,
	// but the moment the check gives ground is the moment to know why.
	if (per_test > budget && self.collision_mode != PAUSED)
	{
		self.collision_mode = PAUSED;
		self.@notice("live collision blocking paused: %.0f ms per test on this mesh — toggle Prevent intersections to retry",
			per_test * 1000.0f);
	}
	else if (per_test <= budget && block.seconds > budget && self.collision_mode == FULL)
	{
		self.collision_mode = REDUCED;
		self.@notice("live collision blocking reduced: the last move took %.0f ms on this mesh", block.seconds * 1000.0f);
	}
}

<*
 The joints on either side of a contact, by the dot names the rig gives
 them — "LeftHand" and "Spine1" — or "" for a triangle no joint weights.
*>
fn String AppState.contact_region_name(&self, uint triangle)
{
	uint region = self.deformed_surface.region_for_triangle(triangle);
	usz joint = (usz)region;
	if (joint >= self.collision_policy.dot_ids.len) return "";
	Dot* dot = self.doc.find(self.collision_policy.dot_ids[joint]);
	return dot ? dot.name : "";
}

<*
 The joints `joint` carries, in the skeleton's order — itself and every
 descendant. What a turn moves, and so what a refit and a broad phase are
 asked about.

 The caller owns the result.
*>
fn uint[] subtree_joints(Allocator allocator, rig::Skeleton* skeleton, usz joint)
{
	usz count = skeleton.len();
	if (joint >= count) return {};
	// One sweep: joints are ordered parents-before-children, so a parent's
	// answer is known by the time its child asks.
	bool[] inside = mem::new_array(bool, (sz)count);
	defer mem::free(inside);
	List{uint} moving;
	moving.init(allocator);
	defer moving.free();
	for (usz j = joint; j < count; j++)
	{
		int parent = skeleton.parents[j];
		inside[j] = j == joint || (parent >= 0 && (usz)parent < j && inside[(usz)parent]);
		if (inside[j]) moving.push((uint)j);
	}
	return moving.to_array(allocator);
}

<*
 Whether a move of `carried` as one piece is a move of every joint the skin
 is bound to — the root turned, or a chain whose one pivot is the root. No
 pair of triangles changes its distance under it, so there is nothing to
 test; see the file comment.
*>
fn bool AppState.moves_whole_skin(&self, uint[] carried) => self.skin_joints > 0 && carried.len >= (usz)self.skin_joints;

<*
 Refit the surface for `pose`, whole or for `moving` alone, and return the
 stamp the palette was skinned under.

 Ungrounded on purpose; see the file comment. Zero when the binding could not
 be posed, which the caller reads as "nothing to test".

 @param moving : `The joints whose palette rows changed since the last refit; empty refits everything.`
 @param palette : `Receives the palette, which the caller frees and measures contacts against.`
*>
fn uint AppState.refit_collision_surface(&self, RigView* view, rig::Pose pose, uint[] moving, Matrix4f[]* palette)
{
	Matrix4f[]? skinned = rig::joint_palette(mem, &view.skeleton, pose);
	if (catch skinned) return 0;
	uint generation = self.next_pose_generation();
	if (moving.len == 0)
	{
		self.deformed_surface.refit_all(self.skin, skinned, generation);
	}
	else
	{
		self.deformed_surface.refit_joints(moving, self.skin, skinned, generation);
	}
	*palette = skinned;
	return generation;
}

<*
 The nearest contact among the policy's candidates for `moving`, at the
 surface as `palette` and `generation` last refitted it — or, with `first`,
 the first one found. Within the clearance counts as a contact.

 A rejected candidate pose is usually well inside the body, where hundreds
 of pairs cross, and a search that wants only to know it is rejected has no
 reason to measure them all: the first contact answers, and the search's
 next candidate is a different pose anyway. The nearest is for the one
 question that is about depth — whether a gesture begins inside the
 clearance by enough to be suspended — and it is asked once per gesture.
*>
fn CollisionContact AppState.nearest_collision_contact(
	&self,
	uint[] moving,
	Matrix4f[] palette,
	uint generation,
	CollisionPairCounts* counts = null,
	uint[] rigid = {},
	bool first = false)
{
	CollisionContact nearest;
	DeformedTrianglePair[] candidates = self.collision_candidates(mem, moving, counts, rigid);
	defer if (candidates.len > 0) alloc::free(mem, candidates);
	float clearance = self.collision_policy.clearance;
	foreach (pair : candidates)
	{
		collision::TriangleVerts one = self.deformed_surface.deformed_triangle(pair.a, self.skin, palette, generation);
		collision::TriangleVerts other = self.deformed_surface.deformed_triangle(pair.b, self.skin, palette, generation);
		// The planes first: most candidates are boxes that overlap around
		// triangles that do not, and the exact distance is fifteen tests.
		if (triangles_apart_by_plane(one, other, clearance)) continue;
		TriangleGap gap = triangle_gap(one, other);
		if (gap.distance > clearance) continue;
		if (nearest.hit && gap.distance >= nearest.gap.distance) continue;
		nearest = { .hit = true, .pair = pair, .gap = gap };
		if (first) break;
	}
	return nearest;
}

<*
 Skin `pose`, refitting `moving`, and say whether those joints' triangles are
 clear of the rest of the skin. The surface is left at `pose`.
*>
fn bool AppState.pose_clear(&self, RigView* view, rig::Pose pose, uint[] moving, CollisionContact* contact, uint[] rigid = {})
{
	Matrix4f[] palette;
	uint generation = self.refit_collision_surface(view, pose, moving, &palette);
	if (generation == 0) return true;
	defer alloc::free(mem, palette);
	*contact = self.nearest_collision_contact(moving, palette, generation, &self.last_block.counts, rigid, first: true);
	return !contact.hit;
}

<*
 `pose_clear` with `joint` set to `rotation` first; `pose` is left holding it,
 and the caller decides what to keep.
*>
fn bool AppState.pose_is_clear(
	&self,
	RigView* view,
	rig::Pose* pose,
	usz joint,
	Quaternionf rotation,
	uint[] moving,
	CollisionContact* contact)
{
	pose.rotations[joint] = rotation;
	return self.pose_clear(view, *pose, moving, contact);
}

<*
 Leave the surface at `pose` for `moving` — what a blocked search owes after
 its last candidate was a rejected one, so that the next regional refit finds
 every other row exact.
*>
fn void AppState.settle_collision_surface(&self, RigView* view, rig::Pose pose, uint[] moving)
{
	Matrix4f[] palette;
	if (self.refit_collision_surface(view, pose, moving, &palette) != 0) alloc::free(mem, palette);
}

<*
 Opens a gesture's collision check: the surface is refitted whole for the
 draft as it stands, and the gesture is suspended if that draft is already in
 contact among the pairs the gesture could change — those around `joint`'s
 subtree, less the ones `rigid_joint`'s subtree carries as one.

 Called where a gesture begins, before any request arrives. Cheap to call
 when blocking is off — it then only resets the report.

 @param rigid_joint : `The joint whose subtree the gesture moves as one piece: the joint itself for a turn, a chain's deepest pivot for a pull.`
*>
fn void AppState.begin_collision_gesture(&self, RigView* view, usz joint, usz rigid_joint = usz::max)
{
	self.last_block = {};
	self.collision_suspended = false;
	if (!self.collision_blocking_active() || joint >= view.len()) return;
	if (rigid_joint >= view.len()) rigid_joint = joint;

	rig::Pose pose = self.draft_pose(mem, view);
	defer pose.free(mem);
	uint[] moving = subtree_joints(mem, &view.skeleton, joint);
	defer if (moving.len > 0) alloc::free(mem, moving);
	uint[] rigid = subtree_joints(mem, &view.skeleton, rigid_joint);
	defer if (rigid.len > 0) alloc::free(mem, rigid);

	Matrix4f[] palette;
	uint generation = self.refit_collision_surface(view, pose, {}, &palette);
	if (generation == 0) return;
	defer alloc::free(mem, palette);
	CollisionContact already = self.nearest_collision_contact(moving, palette, generation, null, rigid);
	self.collision_suspended = already.hit
		&& already.gap.distance < self.collision_policy.clearance * COLLISION_SUSPEND_FRACTION;
	self.last_block.tests = 1;
	self.last_block.contact = already;
}

<*
 The rotation `joint` may take on the way to `requested`: the request itself
 when the subtree stays clear, else the largest clear fraction of the way
 there from the rotation `pose` holds.

 `pose` comes back holding the answer, so the caller writes it as it always
 did. Every candidate goes through the joint's limits first, since the slerp
 between two permitted rotations need not stay permitted.

 @param report : `Filled with what the check did; last_block is the usual receiver.`
*>
fn Quaternionf AppState.blocked_joint_rotation(
	&self,
	RigView* view,
	rig::Pose* pose,
	usz joint,
	Quaternionf requested,
	JointLimitFrame frame,
	JointRotationLimits limits,
	CollisionBlock* report)
{
	*report = { .fraction = 1.0f, .mode = self.collision_mode };
	if (!self.collision_blocking_active() || self.collision_suspended || joint >= pose.rotations.len)
	{
		pose.rotations[joint] = requested;
		return requested;
	}
	report.tested = true;
	Clock clock = clock::now();
	defer report.seconds += (float)clock.mark().to_sec();

	Quaternionf accepted = pose.rotations[joint];
	uint[] moving = subtree_joints(mem, &view.skeleton, joint);
	defer if (moving.len > 0) alloc::free(mem, moving);
	if (self.moves_whole_skin(moving))
	{
		pose.rotations[joint] = requested;
		return requested;
	}

	CollisionContact contact;
	report.tests++;
	if (self.pose_is_clear(view, pose, joint, requested, moving, &contact)) return requested;
	report.blocked = true;
	report.contact = contact;

	// Pinned: a joint already at the surface, pushed further in. The search's
	// own smallest step is blocked too, and every halving would only learn
	// that; asked first, it costs one test — the common case while the
	// pointer keeps pushing — and a step that is clear seeds the search.
	usz steps = self.collision_search_depth(rotation_angle_between(accepted, requested));
	float low = 1.0f / (float)(1 << steps);
	Quaternionf landed = constrain_joint_rotation(frame, limits, accepted.slerp(requested, low).normalize());
	report.tests++;
	bool settled = self.pose_is_clear(view, pose, joint, landed, moving, &contact);
	if (!settled)
	{
		if (contact.gap.distance < report.contact.gap.distance) report.contact = contact;
		report.fraction = 0.0f;
		pose.rotations[joint] = accepted;
		self.settle_collision_surface(view, *pose, moving);
		return accepted;
	}

	// Bisect between the smallest step, clear, and the request, which is
	// not. `low` is always a tested clear fraction; the contact kept is the
	// nearest one that stopped the search.
	low = @bisect_clear(report, &contact, low, steps, &settled; float middle)
	{
		Quaternionf candidate = constrain_joint_rotation(frame, limits,
			accepted.slerp(requested, middle).normalize());
		settled = self.pose_is_clear(view, pose, joint, candidate, moving, &contact);
		if (settled) landed = candidate;
	};
	report.fraction = low;
	pose.rotations[joint] = landed;
	if (!settled) self.settle_collision_surface(view, *pose, moving);
	return landed;
}

<*
 Bisect between `low`, a fraction already tested clear, and 1, which is not.
 The body tries the pose at `middle` and writes whether it was clear into
 `*settled`, and the contact it met into `*contact`; the nearest contact that
 stopped the search is kept on the report.

 @return `The largest fraction found clear.`
*>
macro float @bisect_clear(CollisionBlock* report, CollisionContact* contact, float low, usz steps, bool* settled; @probe(float middle))
{
	float high = 1.0f;
	for (usz step = 0; step < steps; step++)
	{
		float middle = (low + high) * 0.5f;
		report.tests++;
		@probe(middle);
		if (*settled)
		{
			low = middle;
		}
		else
		{
			high = middle;
			if (!report.contact.hit || contact.gap.distance < report.contact.gap.distance) report.contact = *contact;
		}
	}
	return low;
}

<*
 How far the tip of a chain has to be able to move for the chain not to
 count as pinned, in clearances. A solve toward a target inside the body
 answers with a pose far inside it, and the smallest fraction of that the
 depth would resolve moves the tip a fraction of a millimetre: clear more
 often than not, and then the whole search runs to land it there. A tip
 that cannot advance half a clearance is at the surface already, which is
 what pinned means, and half a clearance is under what the eye can see.
*>
const float PINNED_TIP_TRAVEL = 0.5f;

<*
 Cut one chain solve to the largest fraction the mesh allows.

 `pose` arrives holding the solve's answer for `joints` and `before` what
 each of them held when the solve began; `moving` is the anchor's subtree
 and `rigid` the deepest pivot's, the one part of it the solve carries as
 one. Clear, and the solve stands. In contact, the chain is slerped back
 toward `before` as one — every joint by the same fraction, each through its
 own limits — and `pose` comes back holding the landed fraction, the surface
 settled on it.

 @param reach : `The anchor-to-tip length of the chain, for sizing the pinned probe by the tip's travel; zero sizes it by the depth alone.`
 @return `True when the solve was accepted whole.`
*>
fn bool AppState.blocked_chain_pass(
	&self,
	RigView* view,
	rig::Pose* pose,
	usz[] joints,
	Quaternionf[] before,
	uint[] moving,
	uint[] rigid,
	CollisionBlock* report,
	float reach = 0.0f)
{
	if (!self.collision_blocking_active() || self.collision_suspended) return true;
	report.tested = true;
	report.mode = self.collision_mode;
	if (self.moves_whole_skin(rigid.len > 0 ? rigid : moving)) return true;
	Clock clock = clock::now();
	defer report.seconds += (float)clock.mark().to_sec();

	CollisionContact contact;
	report.tests++;
	if (self.pose_clear(view, *pose, moving, &contact, rigid)) return true;
	report.blocked = true;
	report.contact = contact;

	Quaternionf[IK_MAX_CHAIN + 1] after;
	foreach (usz i, joint : joints) after[i] = pose.rotations[joint];

	// The smallest step first, as `blocked_joint_rotation` asks it: a chain
	// pinned against the body answers in one more test. The sweep the depth
	// is read from is the widest any pivot turns through; the step itself is
	// the larger of the depth's and the one that moves the tip half a
	// clearance, so a solve far into the body is not searched for the
	// hair's breadth of it that is clear.
	float sweep = 0.0f;
	foreach (usz i, joint : joints) sweep = math::max(sweep, rotation_angle_between(before[i], after[i]));
	usz steps = self.collision_search_depth(sweep);
	float low = 1.0f / (float)(1 << steps);
	float travel = sweep * reach;
	if (travel > 0.0f)
	{
		low = math::clamp(self.collision_policy.clearance * PINNED_TIP_TRAVEL / travel, low, 0.5f);
	}
	self.slerp_chain(view, pose, joints, before[:joints.len], after[:joints.len], low);
	report.tests++;
	bool settled = self.pose_clear(view, *pose, moving, &contact, rigid);
	if (!settled)
	{
		if (contact.gap.distance < report.contact.gap.distance) report.contact = contact;
		low = 0.0f;
	}
	else
	{
		// Bisect between the smallest step, clear, and the answer, which is
		// not; `low` is always a tested clear fraction.
		low = @bisect_clear(report, &contact, low, steps, &settled; float middle)
		{
			self.slerp_chain(view, pose, joints, before[:joints.len], after[:joints.len], middle);
			settled = self.pose_clear(view, *pose, moving, &contact, rigid);
		};
	}
	report.fraction = low;

	// The last candidate tested is not necessarily the one that stands.
	self.slerp_chain(view, pose, joints, before[:joints.len], after[:joints.len], low);
	if (!settled) self.settle_collision_surface(view, *pose, moving);
	return false;
}

<*
 Cut a whole-body solve to the largest fraction the mesh allows.

 	`app.blocked_body_pass(&view, &pose, before, root, held_rotation, held_offset, &app.last_block, &last);`

 `pose` arrives holding the solve's answer and `before` the pose the solve began
 from — the pose the gesture began with. A body solve moves the root, and the root
 carries every triangle alike, so it changes no distance between two of them: the
 test is made with the root held where the gesture found it (`held_rotation`,
 `held_offset`), and what is moving is every joint whose own turn changed and
 everything below it. Clear, and the solve stands. In contact, the whole answer —
 the root's slide and turn with it — is slerped back toward `before` as one, to the
 largest clear fraction, the way `blocked_chain_pass` cuts a chain: a cut is a
 share of the way from where the gesture began.

 The surface is refitted for the joints that moved, so it has to be right for all
 the others. Held there for every test of a gesture, it agrees with every row a
 test does not touch — as long as that row is where the surface last left it.
 Solved from the start each move, a joint that has come back to the start is
 where `before` has it and not where the last move's test left the surface; so
 `surface`, the last answer, adds the joints it turned to those that move.

 @param surface : `The pose the last move left the surface at, or null when that was the start.`
 @return `True when the solve was accepted whole.`
*>
fn bool AppState.blocked_body_pass(
	&self,
	RigView* view,
	rig::Pose* pose,
	rig::Pose before,
	usz root,
	Quaternionf held_rotation,
	Vec3 held_offset,
	CollisionBlock* report,
	rig::Pose* surface = null)
{
	if (!self.collision_blocking_active() || self.collision_suspended) return true;
	usz n = view.len();
	bool[] inside = mem::new_array(bool, (sz)n);
	defer mem::free(inside);
	float sweep = 0.0f;
	bool turned = false;
	for (usz j = 0; j < n; j++)
	{
		int parent = view.skeleton.parents[j];
		bool bent = parent >= 0 && pose.rotations[j].v != before.rotations[j].v;
		if (bent)
		{
			turned = true;
			sweep = math::max(sweep, rotation_angle_between(before.rotations[j], pose.rotations[j]));
		}
		// A joint the last move turned is still turned in the surface, whether or not
		// this answer has it back where it began.
		bool left = parent >= 0 && surface && surface.rotations[j].v != before.rotations[j].v;
		if (left) turned = true;
		inside[j] = bent || left || (parent >= 0 && inside[(usz)parent]);
	}
	if (!turned) return true;
	List{uint} listed;
	listed.init(mem);
	defer listed.free();
	for (usz j = 0; j < n; j++) if (inside[j]) listed.push((uint)j);
	uint[] moving = listed.array_view();
	if (self.moves_whole_skin(moving)) return true;

	report.tested = true;
	report.mode = self.collision_mode;
	Clock clock = clock::now();
	defer report.seconds += (float)clock.mark().to_sec();

	rig::Pose after = pose.copy(mem);
	defer after.free(mem);
	rig::Pose test = pose.copy(mem);
	defer test.free(mem);
	CollisionContact contact;
	self.blend_body(view, &test, before, after, 1.0f, root, held_rotation, held_offset, true);
	report.tests++;
	if (self.pose_clear(view, test, moving, &contact)) return true;
	report.blocked = true;
	report.contact = contact;

	usz steps = self.collision_search_depth(sweep);
	float low = 1.0f / (float)(1 << steps);
	self.blend_body(view, &test, before, after, low, root, held_rotation, held_offset, true);
	report.tests++;
	bool settled = self.pose_clear(view, test, moving, &contact);
	if (!settled)
	{
		if (contact.gap.distance < report.contact.gap.distance) report.contact = contact;
		low = 0.0f;
	}
	else
	{
		low = @bisect_clear(report, &contact, low, steps, &settled; float middle)
		{
			self.blend_body(view, &test, before, after, middle, root, held_rotation, held_offset, true);
			settled = self.pose_clear(view, test, moving, &contact);
		};
	}
	report.fraction = low;
	self.blend_body(view, pose, before, after, low, root, held_rotation, held_offset, false);
	if (!settled)
	{
		self.blend_body(view, &test, before, after, low, root, held_rotation, held_offset, true);
		self.settle_collision_surface(view, test, moving);
	}
	return false;
}

<*
 `out` set `fraction` of the way from `before` to `after`: every turn slerped and
 put back through its joint's limits, the root's slide carried the same share.
 With `hold_root`, the root instead stands where the gesture found it — the frame
 `blocked_body_pass` tests in.
*>
fn void AppState.blend_body(
	&self,
	RigView* view,
	rig::Pose* out,
	rig::Pose before,
	rig::Pose after,
	float fraction,
	usz root,
	Quaternionf held_rotation,
	Vec3 held_offset,
	bool hold_root)
{
	foreach (usz j, was : before.rotations)
	{
		if (fraction <= 0.0f || was.v == after.rotations[j].v)
		{
			out.rotations[j] = fraction <= 0.0f ? was : after.rotations[j];
		}
		else
		{
			JointRotationLimits limits = self.doc.rotation_limits_of(view.dot_ids[j]);
			JointLimitFrame frame = joint_limit_frame(&view.skeleton, view.dot_ids, limits);
			out.rotations[j] = constrain_joint_rotation(frame, limits, was.slerp(after.rotations[j], fraction).normalize());
		}
		out.offsets[j] = before.offsets[j] + (after.offsets[j] - before.offsets[j]) * math::max(fraction, 0.0f);
	}
	if (hold_root && root < out.rotations.len)
	{
		out.rotations[root] = held_rotation;
		out.offsets[root] = held_offset;
	}
}

<*
 Every joint of a chain slerped the same `fraction` of the way from what it
 held to a pass's answer, each through its own limits; zero puts back what
 was held.
*>
fn void AppState.slerp_chain(
	&self,
	RigView* view,
	rig::Pose* pose,
	usz[] joints,
	Quaternionf[] before,
	Quaternionf[] after,
	float fraction)
{
	foreach (usz i, joint : joints)
	{
		if (fraction <= 0.0f)
		{
			pose.rotations[joint] = before[i];
			continue;
		}
		uint dot = view.dot_ids[joint];
		JointRotationLimits limits = self.doc.rotation_limits_of(dot);
		JointLimitFrame frame = joint_limit_frame(&view.skeleton, view.dot_ids, limits);
		pose.rotations[joint] = constrain_joint_rotation(frame, limits,
			before[i].slerp(after[i], fraction).normalize());
	}
}

<*
 A rotation typed into the Joint card, as far as the mesh lets it go.

 One-shot, so the gesture the check assumes is opened and closed here: a
 whole refit for the draft as it stands, the request, and the answer. A draft
 already in contact around the joint is not blocked, on the rule every
 gesture follows.

 @return `The rotation to write — the request, or where it stopped.`
*>
fn Quaternionf AppState.numeric_joint_rotation(
	&self,
	RigView* view,
	uint id,
	Quaternionf requested,
	JointLimitFrame frame,
	JointRotationLimits limits)
{
	sz joint = view.joint_of(id);
	if (joint < 0) return requested;
	self.begin_collision_gesture(view, (usz)joint);
	rig::Pose pose = self.draft_pose(mem, view);
	defer pose.free(mem);
	Quaternionf landed = self.blocked_joint_rotation(view, &pose, (usz)joint, requested, frame, limits, &self.last_block);
	self.judge_collision_cost();
	return landed;
}

<*
 The broad-phase pairs a joint edit can bring together that the policy allows
 the narrow phase to test — less the pairs the edit carries rigidly as one.

 Asked of the surface as it was last refitted: a gesture refits the joints it
 moved before asking, since it alone knows which palette rows changed. With
 no bound skin, or before any refit, there is nothing to ask and the answer is
 empty with every count at zero.

 @param moving_joints : `Joint indices in the binding's order — the subtree a gesture turns.`
 @param counts : `Filled with what the pass kept and dropped, when given.`
 @param rigid_joints : `The joints the gesture carries as one, when fewer than the moving ones — a chain solve's deepest pivot and below.`
 @return `Owned by the caller through the allocator.`
*>
fn DeformedTrianglePair[] AppState.collision_candidates(
	&self,
	Allocator allocator,
	uint[] moving_joints,
	CollisionPairCounts* counts = null,
	uint[] rigid_joints = {})
{
	if (counts) *counts = {};
	if (!self.collision_policy.ready || !self.deformed_surface.surface_ready) return {};

	// With the binding, so pairs the move carries rigidly together are never
	// measured: a turn of the shoulder cannot bring one finger against another.
	// A chain solve names the narrower set its deepest pivot carries. And
	// with the policy's table of regions that may meet, so the pairs a
	// region's triangles make with each other and with the crease beside
	// them — most of what a query finds — are pruned as subtrees rather than
	// enumerated for the filter to drop one by one.
	DeformedTrianglePair[] raw = self.deformed_surface.broad_phase_pairs_for_joints(
		mem, moving_joints, self.collision_policy.clearance, self.skin, rigid_joints, self.collision_policy.may_meet());
	defer if (raw.len > 0) alloc::free(mem, raw);
	return self.collision_policy.filter(allocator, &self.deformed_surface, raw, counts);
}

<*
 Excludes two joints' regions from the self-collision check, or puts them back
 under it, as one undo step.

 The exceptional control the ordinary workflow never shows — see
 `CollisionExclusion`. Reaching the asked-for state is success: excluding a
 pair already excluded changes nothing and records nothing.

 @return `True if the document changed.`
*>
fn bool AppState.set_collision_exclusion(&self, uint a, uint b, bool excluded)
{
	if (!self.exclude_recorded(a, b, excluded)) return false;
	self.undo_stack.commit();
	return true;
}
