<*
 The weight views: which dot owns which part of the mesh, and how strongly.

 Two colourings of the same bind, kept apart because they answer two different
 questions — territory ("which dot wins this vertex") and falloff ("how much of
 it does *this* dot hold"). At most one is on at a time. The palettes themselves
 are `core/rigging.c3`; what is here is when to rebuild them and what to do with
 the result.

 **Rebinding is debounced, and that is the whole design.** A bind is a pass over
 every vertex against every bone, so doing it on each frame of a drag would make
 the drag unusable. `mark_rig_stale` sets a timer instead, `tick_weights` counts
 it down, and the recolour happens once the rig has been still for
 `WEIGHT_DEBOUNCE`. `ticking` is what tells the on-demand loop to keep asking
 for frames while that countdown runs — an idle editor asks for none.

 `survey_weights` is the same numbers without the colours, for the HUD and for
 `get_weights` over MCP. It exists because a picture cannot be asserted on and
 cannot be read by an agent.
*>
module crig;

import rig;
import std::math::vector;
import std::collections::list;



<*
 How long the rig has to sit still before the weights are rebound.

 Long enough that a drag does not rebind on every mouse move, short enough that
 letting go of a dot and looking at the result feels like one action rather than
 two.
*>
const float WEIGHT_DEBOUNCE = 0.15;

<*
 Turns the weight preview on or off (Rig menu > Weight preview; W is the Area tool).

 Switching on fires the rebind immediately rather than after the debounce:
 the delay exists to swallow a *stream* of edits, and a keypress is not one.
*>
fn void AppState.toggle_weights(&self) => self.toggle_tint(TERRITORY);

<*
 Turns the falloff view on or off (F): the selected dot's weight over the
 whole mesh on one ramp.

 Entering needs a selection, because the view is meaningless without a joint
 to show — say so rather than silently painting joint 0's falloff, which is
 not the joint the user is thinking about.
*>
fn void AppState.toggle_falloff(&self)
{
	if (self.tint_mode != FALLOFF && self.selected == 0)
	{
		self.@notice("select a joint first — falloff shows one joint");
		return;
	}
	self.toggle_tint(FALLOFF);
}


<*
 Switches a view on, or off if it is the one already showing.

 Turning a view on always recomputes, even when the rig has not changed a bit.
 `weights_stale` is a statement about the *rig*, and what changed here is the
 question being asked of it — the tint buffer still holds the previous view's
 colours, so a switch that only re-armed a stale rig would leave W, F and U all
 showing whichever one was painted first.

 Immediately rather than after the debounce, for the same reason a keypress
 never waits: the delay exists to swallow a stream of edits, and this is one
 deliberate act.
*>
fn void AppState.toggle_tint(&self, TintMode mode)
{
	self.show_tint(self.tint_mode == mode ? OFF : mode);
}

<*
 Show the view named, rather than toggling it.

 What `toggle_tint` does after it has worked out which view the key meant. A
 caller that was told which view to show wants that one whether or not it is
 already on, and toggling would turn it off in exactly the case where the caller
 and the screen already agreed.
*>
fn void AppState.show_tint(&self, TintMode mode)
{
	self.tint_mode = mode;
	if (mode == OFF) return;

	self.weights_stale = true;
	self.weights_due = 0.0f;
}

<*
 Notes that a hand correction changed, which is *not* the rig changing.

 **No debounce, and that is the whole point.** `WEIGHT_DEBOUNCE` exists to
 swallow a stream of rig edits, each of which needs a full geodesic bind. A
 stroke is also a stream, but it moves no dot — so the bind underneath is the
 one that was already there, and the only thing to redo is a multiply and a
 recolour. Waiting 0.15 s for that would be waiting for nothing, and since every
 mouse move restarts the timer the picture would not arrive until the hand
 stopped: the brush would look like it had jammed.

 The cached base is what makes the immediate answer affordable — see
 `painted_bind`.
*>
fn void AppState.mark_paint_stale(&self)
{
	self.weights_stale = true;
	self.weights_due = 0.0f;
	self.skin_stale = true;
	self.skin_due = 0.0f;
}

<*
 Notes that the rig changed under the preview. Cheap and unconditional — the
 work it defers is the expensive part.
*>
fn void AppState.mark_rig_stale(&self)
{
	self.weights_stale = true;
	self.weights_due = WEIGHT_DEBOUNCE;

	// The rig moved, so the bind underneath every view is worthless. Dropped here
	// rather than recomputed: the next thing that wants it will say so.
	self.drop_base_bind();

	// And with it the binder's rigid choices, which are joint *indices* — the
	// skeleton is numbered breadth-first, so a dot added or removed renames every
	// bone after it and a stale index resolves to the wrong one rather than to
	// none. The generation moves so a watcher can tell one edit from a stream of
	// them; see `AppState.refresh_shell_riders` for who is waiting.
	self.riders_stale = true;
	self.rig_generation = next_generation();

	// The skin, on the same timer as the tints — see `tick_skin`. A running
	// clip rebinds on its next tick regardless, since the player asks for the
	// skin every frame; the timer is for the body that is parked, which is the
	// one the user edits under for as long as they like.
	self.skin_stale = true;
	self.skin_due = WEIGHT_DEBOUNCE;

	// And what each pack's clips can reach, which is a question about the shape of
	// the rig and so is answered wrongly the moment a joint moves. No debounce for
	// the same reason the skin has none, and it is cheap besides: the whole shipped
	// library measures in about seven milliseconds. See `AppState.pack_reach`.
	self.reach_stale = true;

	// And the jiggle sim, for the same reason one step further out: it holds the
	// rest positions and the bone lengths the chains were built from, and a dot
	// that moved leaves both describing a rig nobody has. Every write to the
	// document that moves a joint comes through here — including an undo step,
	// which never reaches the recorded setters — so this is the one place that
	// covers all of them. Rebuilt lazily, on the next frame of playback that
	// wants one; see `app/sim.c3`.
	self.jiggle_reset();
}

<*
 The debounce, one frame's worth. Driven from `AppRoot.update`, which is where
 cui already hands out dt.

 Nothing happens while no tint view is on: the tints stay stale and the timer
 stays wherever it stopped, so switching a view on later still rebinds rather
 than showing a picture of a rig that has since been edited.
*>
fn void AppState.tick_weights(&self, float dt)
{
	if (self.tint_mode == OFF || !self.weights_stale) return;

	self.weights_due -= dt;
	if (self.weights_due > 0.0f) return;

	self.rebind_tints();
}

<*
 The posed body's half of the debounce: a rig edit under a parked clip or a
 pose draft reaches the skin once the hand has been still.

 The clip's clock is stopped, so nothing else would rebind — a paused player
 skips its tick and a draft never has one — and a reach set over MCP, a dot drag
 or the sharpness keys would leave the body on screen skinned by the rig it no
 longer has until the playhead happened to move. Debounced for the tints'
 reason: every one of those is a rig change, and a geodesic bind per mouse
 move would jam the drag. What lands here immediately, through `mark_paint_stale`,
 is a stroke, whose bind is a cached multiply.

 Nothing while a clip runs: `tick_animation` rebinds through
 `refresh_animation` on the frame after the edit, which is sooner than this.
*>
fn void AppState.tick_skin(&self, float dt)
{
	if (!self.skin_stale || !self.skinned()) return;
	if (self.animating && !self.anim_paused) return;

	self.skin_due -= dt;
	if (self.skin_due > 0.0f) return;

	self.refresh_pose_display();
}

<*
 Whether anything here is waiting on a frame rather than on the user.

 The render loop sleeps as soon as nothing has scheduled a frame, and every
 timer on this struct is advanced by the `dt` `AppRoot.update` hands it — which
 only arrives when a frame runs. A timer that does not ask for its next frame
 therefore stops: the weight debounce never expires, an animation freezes
 mid-stride and holds whatever pose it was on when the mouse went still. So
 `AppRoot.update` asks on their behalf while this is true.

 The camera snap is deliberately not in here. `OrbitCamera.advance` already
 reports that it moved and the repaint that follows schedules the next frame
 through cui's own invalidation — one mechanism per timer, and that one has it.

 @return `True while some timer still has somewhere to get to.`
*>
fn bool AppState.ticking(&self)
{
	// The debounce only counts down while a view is on to show the result — the
	// same condition `tick_weights` returns on, and asking for frames it would
	// spend on an early return is how an idle loop stops being idle.
	// A notice fades on a timer of its own, and the frames that age it are the
	// only ones there will be: the last thing the user did is usually also the
	// last thing that happens for a while, so a loop that slept here would leave
	// the result on screen until the next click.
	// The weight brush is the one *mode* that keeps the loop awake, rather than a
	// timer with somewhere to get to. Two reasons, and the second is why the
	// repaint on pointer move is not enough on its own: the circle is drawn where
	// the pointer is, so it has to be redrawn as the pointer moves; and a stroke
	// asks for its result immediately, which is only immediate if a frame is
	// coming. A mode the user opened deliberately and closes when done is the
	// right place to spend frames — an idle editor still asks for none, because
	// this is false the moment the brush is shut.
	// And a posed body waiting on `tick_skin`: a pose draft keeps no clock of
	// its own, so the frames that run its countdown have to be asked for here.
	// A paused clip is not ticking: its clock is stopped and a scrub or a pose
	// edit repaints through `refresh_ui`, so asking for frames here would redraw
	// the same still picture — occlusion rays and all — sixty times a second.
	return self.brushing
		|| (self.animating && !self.anim_paused)
		|| self.notice_length > 0
		|| (self.tint_mode != OFF && self.weights_stale)
		|| (self.skin_stale && self.skinned())
		// A text-to-motion job is polled a frame at a time; see `tick_motion_job`.
		|| self.motion_job.running;
}

<*
 The bind with no hand corrections on it, built if the cache does not hold it.

 	`float[] base = app.base_bind_for(&view);`

 **The base is cached and the corrections are not.** A bind is a pass over every
 vertex against every bone through the voxel grid — tens of milliseconds — while
 applying the paint is one multiply per dab and copying the result is a memcpy.
 Since a stroke changes only the corrections, keeping the base means the view can
 be redrawn on every mouse move instead of once the hand stops, and a solver that
 works against the base — `paint_share` — can run a whole stroke on one bind.

 The cache is dropped by `mark_rig_stale`, which is what every edit that moves a
 dot, a reach or an attachment already calls. It is also dropped when the joint
 count no longer matches, which catches the one case that changes the bind's
 shape without going through there.

 **Borrowed, not owned.** What comes back *is* the cache, valid exactly until the
 next `mark_rig_stale`. A caller may read it, must not free it, and must not hold
 it across anything that could edit the rig — which is the one way this can go
 wrong, and it goes wrong as a read of freed memory rather than as a wrong
 number. A caller that wants to keep or modify the array wants `painted_bind`,
 which hands back a copy.

 @return `The base bind, or empty when there is no rig or no mesh to bind.`
*>
fn float[] AppState.base_bind_for(&self, RigView* view)
{
	usz wanted = self.geometry.positions.len * view.len();
	if (wanted == 0) return {};

	if (self.base_bind.len != wanted)
	{
		self.drop_base_bind();
		self.base_bind = self.bind_dense(mem, view, painted: false);
		if (self.base_bind.len != wanted) return {};
	}
	return self.base_bind;
}

<*
 The current bind with the hand corrections on it, ready to colour.

 	`float[] painted = app.painted_bind(mem, &view);`

 A copy of `base_bind_for` with the paint applied over it — the corrections have
 to go somewhere, and painting them into the cache would leave the next caller
 solving against a base that already carries them.

 The caller owns the returned array; the cache stays behind.
*>
fn float[] AppState.painted_bind(&self, Allocator allocator, RigView* view)
{
	float[] base = self.base_bind_for(view);
	if (base.len == 0) return {};

	float[] out = alloc::new_array(allocator, float, (sz)base.len);
	foreach (usz i, weight : base) out[i] = weight;
	paint_over(out, view.len(), view.paint);

	// Last, over the corrections, which is the pin layer's whole contract — see
	// `pin_over`. No sharpening above it: the base already carries γ, so this
	// copy inherits it, and raising a stated share to a power would be the binder
	// arguing with the user.
	pin_over(out, view.len(), view.pins);
	return out;
}

// Releases the cached base bind. Safe to call on one that is already empty,
// which is what lets `mark_rig_stale` stay unconditional.
fn void AppState.drop_base_bind(&self)
{
	if (self.base_bind.len > 0) alloc::free(mem, self.base_bind);
	self.base_bind = {};
}

<*
 Rebinds the mesh and recolours every vertex for the active view.

 The generation always moves, including when there is nothing to show. An empty
 document leaves `tints` empty, and the pass reads that as "stop tinting" — so
 undoing the last dot takes the colours off the model instead of leaving the
 previous rig painted on it.
*>
fn void AppState.rebind_tints(&self)
{
	self.weights_stale = false;
	self.weights_due = 0.0f;
	self.tint_generation = next_generation();

	if (self.tints.len > 0)
	{
		alloc::free(mem, self.tints);
		self.tints = {};
	}

	RigView? opened = self.open_rig(mem);
	if (catch opened) return;
	RigView view = opened;
	defer view.free(mem);

	// Bound once here rather than twice inside the colourings below, so a stroke
	// pays for one copy of a cached matrix instead of a fresh geodesic bind per
	// frame.
	float[] painted = self.painted_bind(mem, &view);
	defer if (painted.len > 0) alloc::free(mem, painted);

	switch (self.tint_mode)
	{
		case FALLOFF:
			// The selection is always a joint — unreachable dots are appended
			// as roots — but guard anyway: joint 0 beats a crash over a view.
			sz found = view.joint_of(self.selected);
			usz joint = found >= 0 ? (usz)found : 0;
			self.tints = falloff_tints(
				mem, self.geometry.positions, &view.skeleton, joint, &self.voxels, &self.shells,
				view.attachments, view.reaches, BLEND_FLOOR, &self.falloff_held, view.paint, painted);
		default:
			self.tints = vertex_tints(
				mem, self.geometry.positions, &view.skeleton, &self.voxels, &self.shells,
				view.attachments, view.reaches, view.paint, painted);
	}
	self.overlay_area_tints(&view, painted);
	self.overlay_limb_tints(&view, painted);
	self.overlay_stray_tints();
}

<*
 The share below which a joint's hold on a vertex is not worth reporting.

 Nothing the binder or the exporter applies — both keep whatever survives
 `sparsify_weights`, however small. It exists because geodesic weights are
 non-zero almost everywhere, so counting from zero would report every joint as
 reaching the whole mesh and say nothing at all.
*>
const float BLEND_FLOOR = 0.05f;

<*
 One joint's share of the mesh, the number behind the TERRITORY view.

 `name` is borrowed from the document and dies with the next edit that renames
 or removes the dot. Copy it if it has to outlive the survey.
*>
struct JointStake
{
	uint dot;
	String name;
	usz owns;    // vertices this joint holds more strongly than any other
	usz reaches; // those, plus every other it holds at least BLEND_FLOOR of
}

<*
 How far one joint reaches into another's, which is what a tear is made of.

 A vertex counted here is owned by `dot` and pulled on by the joint being
 surveyed, so the two disagree about where it goes. Where that straddles a
 boundary the mesh has — an arm meeting a torso — it is the smear.
*>
struct BlendShare
{
	uint dot;     // the joint that owns these vertices
	String name;  // borrowed, like JointStake.name
	usz vertices;
	float mean;   // the surveyed joint's mean share of them
	float peak;
}

<*
 What the weight views show, as numbers rather than colours.

 `stakes` is one entry per joint in BFS order — the order `get_skeleton`
 reports. `shared` is empty unless a dot was surveyed.
*>
struct WeightSurvey
{
	usz vertices;
	usz unclaimed;
	JointStake[] stakes;
	BlendShare[] shared;
}

fn void WeightSurvey.free(&self, Allocator allocator)
{
	if (self.stakes.len > 0) alloc::free(allocator, self.stakes);
	if (self.shared.len > 0) alloc::free(allocator, self.shared);
	*self = {};
}

<*
 Read the bind as numbers: who owns what, who reaches into whose, what nothing
 owns.

 The same dense matrix `rebind_tints` paints from, and deliberately so — an
 answer that disagreed with the picture on screen would be worse than no answer.
 It follows that this reports the binder's raw weights and not the file's:
 `sparsify_weights` keeps only a vertex's four strongest afterwards, so `owns`
 is what TERRITORY draws either way, while a `reaches` entry ranking fifth or
 lower on its vertex is one the export will drop.

 Rebinds from scratch on every call — the cost of `rebind_tints`, without its
 debounce — so this is a diagnostic to ask a question with, not something to
 call per frame.

 The caller owns the result and frees it with `WeightSurvey.free`.

 @param dot : `Dot id to survey against its neighbours; 0 surveys none and leaves the shared list empty.`
 @return? WEIGHTS_NO_RIG : `No mesh, or no rig to bind it to.`
 @return? WEIGHTS_NO_SUCH_DOT : `A dot id that is not in this rig.`
*>
fn WeightSurvey? AppState.survey_weights(&self, Allocator allocator, uint dot = 0)
{
	usz vertices = self.geometry.positions.len;
	if (vertices == 0) return WEIGHTS_NO_RIG~;

	RigView? opened = self.open_rig(mem);
	if (catch opened) return WEIGHTS_NO_RIG~;
	RigView view = opened;
	defer view.free(mem);

	usz bones = view.len();
	if (bones == 0) return WEIGHTS_NO_RIG~;

	sz focus = view.joint_of(dot);
	if (dot != 0 && focus < 0) return WEIGHTS_NO_SUCH_DOT~;

	// Filled by the bind with the shells it pinned rigidly, which is what keeps
	// them out of the unclaimed count — see `unclaimed_mask`. An output of this
	// one bind rather than part of the view, like `nearest` below.
	int[] riders = alloc::new_array(mem, int, (sz)self.shells.count);
	defer if (riders.len > 0) alloc::free(mem, riders);

	float[] nearest = alloc::new_array(mem, float, (sz)self.geometry.positions.len);
	defer if (nearest.len > 0) alloc::free(mem, nearest);

	float[] dense = rig::bind_geodesic(
		mem, &self.voxels, self.geometry.positions, view.skeleton.joints, view.skeleton.parents,
		&self.shells, view.attachments, riders, view.reaches, nearest, self.bind_eps());
	defer alloc::free(mem, dense);

	// The second funnel: this binds for itself rather than through `bind_dense`,
	// because it needs the riders and the distances that only come out of the bind
	// itself — so the softness and the shaping have to be repeated here or the
	// numbers this reports describe a bind nobody is looking at.
	self.shape_bind(dense, &view, riders);
	paint_over(dense, bones, view.paint);
	pin_over(dense, bones, view.pins);

	// A rig that adopted its file's weights deforms with those, not with this bind:
	// the bind above is then only wanted for the riders and distances that come out
	// of it. Count over what the views paint and the skin rides — `painted_bind` —
	// so this describes the weights somebody is looking at. It used to rebind
	// regardless and ignore the file's, which is how it could report a leak the
	// view did not show.
	if (self.doc.skin_from_file)
	{
		float[] shown = self.painted_bind(mem, &view);
		if (shown.len == dense.len)
		{
			alloc::free(mem, dense);
			dense = shown;
		}
		else if (shown.len > 0)
		{
			alloc::free(mem, shown);
		}
	}

	JointStake[] stakes = alloc::new_array(allocator, JointStake, (sz)bones);
	for (usz j = 0; j < bones; j++)
	{
		stakes[j] = { .dot = view.dot_ids[j], .name = view.names[j] };
	}

	// Per owning joint, what the surveyed one still holds of its vertices.
	usz[] taken = alloc::new_array(mem, usz, (sz)bones);
	float[] taken_sum = alloc::new_array(mem, float, (sz)bones);
	float[] taken_peak = alloc::new_array(mem, float, (sz)bones);

	defer {
		alloc::free(mem, taken);
		alloc::free(mem, taken_sum);
		alloc::free(mem, taken_peak);
	}

	for (usz v = 0; v < vertices; v++)
	{
		usz base = v * bones;

		// Shares, not raw weights: the raw output spans orders of magnitude and a
		// floor over it would mean something different at every vertex. This is the
		// normalisation `falloff_tints` paints and `sparsify_weights` writes.
		float sum;
		sz owner = row_owner(dense[base:bones], &sum);
		if (sum <= 0.0f || owner < 0) continue;
		usz best = (usz)owner;
		stakes[best].owns++;

		// The owner always reaches what it owns. On a rig with enough joints the
		// strongest share of an evenly-spread vertex can sit under the floor, and a
		// dot reported as owning mass it does not reach describes nothing.
		for (usz b = 0; b < bones; b++)
		{
			if (b == best || dense[base + b] / sum >= BLEND_FLOOR) stakes[b].reaches++;
		}

		if (focus < 0 || (usz)focus == best) continue;

		float share = dense[base + (usz)focus] / sum;
		if (share < BLEND_FLOOR) continue;
		taken[best]++;
		taken_sum[best] += share;
		if (share > taken_peak[best]) taken_peak[best] = share;
	}

	bool[] stray = unclaimed_mask(mem, nearest, vertices, &self.shells, riders, view.pins);
	defer alloc::free(mem, stray);
	usz unclaimed = 0;
	foreach (flag : stray)
	{
		if (flag) unclaimed++;
	}

	usz neighbours = 0;
	for (usz b = 0; b < bones; b++)
	{
		if (taken[b] > 0) neighbours++;
	}

	BlendShare[] shared = neighbours > 0
		? alloc::new_array(allocator, BlendShare, (sz)neighbours)
		: (BlendShare[]){};
	usz at = 0;
	for (usz b = 0; b < bones; b++)
	{
		if (taken[b] == 0) continue;
		shared[at++] = {
			.dot = stakes[b].dot,
			.name = stakes[b].name,
			.vertices = taken[b],
			.mean = taken_sum[b] / (float)taken[b],
			.peak = taken_peak[b],
		};
	}

	// Worst first, so a caller reading only the head of the list reads the
	// boundary most likely to tear. Selection sort over one entry per joint.
	for (usz i = 0; i + 1 < shared.len; i++)
	{
		usz top = i;
		for (usz j = i + 1; j < shared.len; j++)
		{
			if (shared[j].vertices > shared[top].vertices) top = j;
		}
		if (top != i)
		{
			BlendShare swap = shared[i];
			shared[i] = shared[top];
			shared[top] = swap;
		}
	}

	return {
		.vertices = vertices,
		.unclaimed = unclaimed,
		.stakes = stakes,
		.shared = shared,
	};
}

<*
 The joint holding the most of one vertex's weight row, or -1 when nothing in
 the row is above zero. Ties go to the lower index. `sum` gets the row's total
 and `held` how many joints carry a share, for the callers that normalise.
*>
fn sz row_owner(float[] row, float* sum = null, usz* held = null)
{
	float total = 0.0f;
	float strongest = 0.0f;
	usz carrying = 0;
	sz best = -1;
	foreach (b, weight : row)
	{
		total += weight;
		if (weight <= 0.0f) continue;
		carrying++;
		if (weight > strongest)
		{
			strongest = weight;
			best = (sz)b;
		}
	}
	if (sum) *sum = total;
	if (held) *held = carrying;
	return best;
}

// A joint holds a vertex, for the stray survey, at this share or more.
const float STRAY_SHARE = 0.25f;

// How far from the rest of a joint's weight, as a fraction of the model's
// height, an island of it has to sit to be a stray rather than its own blend.
const float STRAY_GAP = 0.1f;

// How far a pose has to be able to pull an island off the mesh around it, as a
// fraction of the model's height, for it to be a stray — see `pull_apart`.
const float STRAY_PULL = 0.05f;

// The colour a stray is marked in while the Weights card lists it.
const Vec3 STRAY_RED = { 0.95, 0.1, 0.2 };

<*
 A patch of mesh a joint holds that is cut off from the rest of what it holds,
 and far from it — three vertices of a tail root given wholly to a knee, which
 the knee pulls out of the body as a spike. See `stray_islands`.
*>
struct StrayIsland
{
	uint dot;
	uint[] vertices;              // owned
	Vec3 centre;                  // at rest
	float peak;                   // the joint's largest share in it
	float gap;                    // nearest rest distance to the joint's own region, over the model's height
	float pull;                   // how far a pose can pull it off the mesh around it, over the model's height
	uint[SKIN_INFLUENCES] around; // the joints holding the mesh around it, strongest first
	usz around_count;
}

fn void free_strays(Allocator allocator, StrayIsland[] strays)
{
	foreach (stray : strays) if (stray.vertices.len > 0) alloc::free(allocator, stray.vertices);
	if (strays.len > 0) alloc::free(allocator, strays);
}

<*
 How far a pose can pull a point held by `row` away from the same point held
 by `other`: per joint, what its whole limb holds of the one less the other,
 times the point's distance from the joint — what turning that joint alone
 moves the two apart by, per radian. The most of any joint.

 @param limb : `Scratch, one per joint.`
*>
fn float pull_apart(rig::Skeleton* skeleton, float[] row, float[] other, Vec3 point, float[] limb)
{
	limb[..] = 0.0f;
	foreach (k, weight : row)
	{
		float apart = weight - other[k];
		if (apart == 0.0f) continue;
		for (int j = (int)k; j >= 0; j = skeleton.parents[(usz)j]) limb[(usz)j] += apart;
	}
	float most = 0.0f;
	foreach (j, apart : limb) most = math::max(most, math::abs(apart) * (point - skeleton.joints[j]).length());
	return most;
}

<*
 Every stray in the bind as shown, the ones a pose pulls furthest first.

 Per joint, the mesh it holds at least `STRAY_SHARE` of, split into connected
 islands over the welded surface. The largest is its region; a smaller island
 is a stray when the mesh around it is someone else's — not a whole piece of
 its own — it sits at least `STRAY_GAP` of the model's height from the region
 at rest, and a pose can pull it at least `STRAY_PULL` off the mesh around it
 (`pull_apart`). A joint's blend into its neighbours stays beside its region,
 and a blotch the mesh around moves with is no spike, so what this finds is
 what a pose pulls out of the body.

 The caller owns the result and frees it with `free_strays`.
*>
fn StrayIsland[] AppState.stray_islands(&self, Allocator allocator)
{
	usz count = self.geometry.positions.len;
	rig::MeshAdjacency* around = self.adjacency_for();
	float height = self.model_height();
	if (count == 0 || around.vertices() != count || !around.usable() || height <= 0.0f) return {};

	RigView? opened = self.open_rig(mem);
	if (catch opened) return {};
	RigView view = opened;
	defer view.free(mem);
	usz bones = view.len();
	float[] painted = self.painted_bind(mem, &view);
	defer if (painted.len > 0) alloc::free(mem, painted);
	if (bones == 0 || painted.len < count * bones) return {};

	// One row per weld, as shares, and where it is at rest.
	usz classes = around.classes();
	float[] share = alloc::new_array(mem, float, (sz)(classes * bones));
	defer alloc::free(mem, share);
	Vec3[] point = alloc::new_array(mem, Vec3, (sz)classes);
	defer alloc::free(mem, point);
	for (usz c = 0; c < classes; c++)
	{
		usz v = (usz)around.first[c];
		point[c] = self.geometry.positions[v];
		float sum = 0.0f;
		for (usz b = 0; b < bones; b++) sum += painted[v * bones + b];
		if (sum <= 0.0f) continue;
		for (usz b = 0; b < bones; b++) share[c * bones + b] = painted[v * bones + b] / sum;
	}

	int[] island = alloc::new_array(mem, int, (sz)classes);
	defer alloc::free(mem, island);
	float[] fill = alloc::new_array(mem, float, (sz)bones);
	defer alloc::free(mem, fill);
	float[] beside = alloc::new_array(mem, float, (sz)bones);
	defer alloc::free(mem, beside);
	float[] limb = alloc::new_array(mem, float, (sz)bones);
	defer alloc::free(mem, limb);
	List{uint} flood;
	flood.init(mem);
	defer flood.free();
	List{uint} region;
	region.init(mem);
	defer region.free();
	List{StrayIsland} found;
	found.init(mem);
	defer found.free();
	float[SKIN_INFLUENCES] beside_shares;

	for (usz b = 0; b < bones; b++)
	{
		// The joint's islands, and which is the largest.
		island[..] = -1;
		int islands = 0;
		int largest = -1;
		usz largest_size = 0;
		for (usz c = 0; c < classes; c++)
		{
			if (island[c] >= 0 || share[c * bones + b] < STRAY_SHARE) continue;
			flood.clear();
			flood.push((uint)c);
			island[c] = islands;
			for (sz next = 0; next < flood.len(); next++)
			{
				foreach (n : around.around(flood[next]))
				{
					if (island[n] >= 0 || share[(usz)n * bones + b] < STRAY_SHARE) continue;
					island[n] = islands;
					flood.push(n);
				}
			}
			if ((usz)flood.len() > largest_size)
			{
				largest_size = (usz)flood.len();
				largest = islands;
			}
			islands++;
		}
		if (islands < 2) continue;

		region.clear();
		for (usz c = 0; c < classes; c++) if (island[c] == largest) region.push((uint)c);

		for (int k = 0; k < islands; k++)
		{
			if (k == largest) continue;
			bool bordered = false;
			float nearest = float::max;
			float peak = 0.0f;
			Vec3 middle = {};
			usz members = 0;
			fill[..] = 0.0f;
			for (usz c = 0; c < classes; c++)
			{
				if (island[c] != k) continue;
				members++;
				middle += point[c];
				peak = math::max(peak, share[c * bones + b]);
				foreach (n : around.around(c))
				{
					if (island[n] == k) continue;
					if (share[(usz)n * bones + b] < AREA_LEAK_FLOOR) bordered = true;
					for (usz j = 0; j < bones; j++) fill[j] += share[(usz)n * bones + j];
				}
				foreach (r : region) nearest = math::min(nearest, (point[r] - point[c]).length());
			}
			if (!bordered || nearest < STRAY_GAP * height) continue;

			// The mesh around it, as one row: what the island moves with once fixed.
			float total = 0.0f;
			foreach (weight : fill) total += weight;
			if (total <= 0.0f) continue;
			foreach (&weight : fill) *weight /= total;
			float pull = 0.0f;
			for (usz c = 0; c < classes; c++)
			{
				if (island[c] == k) pull = math::max(pull, pull_apart(&view.skeleton, share[c * bones:bones], fill, point[c], limb));
			}
			if (pull < STRAY_PULL * height) continue;

			StrayIsland stray = { .dot = view.dot_ids[b], .centre = middle / (float)members, .peak = peak,
				.gap = nearest / height, .pull = pull / height };
			beside[..] = fill[..];
			beside[b] = 0.0f;
			stray.around_count = strongest_shares(beside, view.dot_ids, stray.around[..], beside_shares[..], 0.0f);
			usz held = 0;
			for (usz v = 0; v < count; v++) if (island[around.class_of[v]] == k) held++;
			stray.vertices = alloc::new_array(allocator, uint, (sz)held);
			held = 0;
			for (usz v = 0; v < count; v++) if (island[around.class_of[v]] == k) stray.vertices[held++] = (uint)v;
			found.push(stray);
		}
	}

	StrayIsland[] strays = alloc::new_array(allocator, StrayIsland, found.len());
	foreach (i, stray : found) strays[i] = stray;
	for (usz i = 0; i + 1 < strays.len; i++)
	{
		usz top = i;
		for (usz j = i + 1; j < strays.len; j++) if (strays[j].pull > strays[top].pull) top = j;
		if (top == i) continue;
		StrayIsland swap = strays[i];
		strays[i] = strays[top];
		strays[top] = swap;
	}
	return strays;
}

<*
 Put strays back where they belong, as one undo step.

 A stray is nearly always an edit's leftover — a joint taken off a row and the
 rest handed to a sliver of another — so its vertices go back to the automatic
 weights: their pins go, and they follow the rig again. Where the automatic row
 holds the stray's joint itself, the binder made the stray and that would put it
 back; those take the rows of the surface around the strays instead, averaged
 ring by ring inward, stated as pins and the stray's joint's work
 (`VertexPin.by`).

 @return `How many vertices it restated; 0 when nothing changed.`
*>
fn usz AppState.fix_strays(&self, StrayIsland[] strays)
{
	usz count = self.geometry.positions.len;
	rig::MeshAdjacency* around = self.adjacency_for();
	if (strays.len == 0 || count == 0 || around.vertices() != count || !around.usable()) return 0;

	RigView? opened = self.open_rig(mem);
	if (catch opened) return 0;
	RigView view = opened;
	defer view.free(mem);
	usz bones = view.len();
	float[] painted = self.painted_bind(mem, &view);
	defer if (painted.len > 0) alloc::free(mem, painted);
	if (bones == 0 || painted.len < count * bones) return 0;

	// The automatic row: the base with the multiplier paint, and no pins.
	float[] base = self.base_bind_for(&view);
	if (base.len < count * bones) return 0;
	float[] automatic = alloc::new_array(mem, float, (sz)(count * bones));
	defer alloc::free(mem, automatic);
	automatic[..] = base[:count * bones];
	paint_over(automatic, bones, view.paint);

	// Whose stray each weld is, 0 for none: the first island to name it. And
	// whether the automatic row holds one of the joints that name it.
	usz classes = around.classes();
	uint[] owner = alloc::new_array(mem, uint, (sz)classes);
	defer alloc::free(mem, owner);
	bool[] binder_made = alloc::new_array(mem, bool, (sz)classes);
	defer alloc::free(mem, binder_made);
	foreach (stray : strays)
	{
		sz joint = view.joint_of(stray.dot);
		foreach (v : stray.vertices)
		{
			if ((usz)v >= count) continue;
			uint c = around.class_of[v];
			if (owner[c] == 0) owner[c] = stray.dot;
			usz at = (usz)around.first[c] * bones;
			float sum = 0.0f;
			for (usz b = 0; b < bones; b++) sum += automatic[at + b];
			if (joint >= 0 && sum > 0.0f && automatic[at + (usz)joint] >= STRAY_SHARE * sum) binder_made[c] = true;
		}
	}

	// Every weld's row as shares: as shown off the strays, automatic on the ones
	// that go back to it, and the rest filled in below.
	float[] fill = alloc::new_array(mem, float, (sz)(classes * bones));
	defer alloc::free(mem, fill);
	bool[] known = alloc::new_array(mem, bool, (sz)classes);
	defer alloc::free(mem, known);
	bool[] back = alloc::new_array(mem, bool, (sz)classes);
	defer alloc::free(mem, back);
	List{uint} ring;
	ring.init(mem);
	defer ring.free();
	for (usz c = 0; c < classes; c++)
	{
		usz at = (usz)around.first[c] * bones;
		float[] from = owner[c] != 0 ? automatic : painted;
		float sum = 0.0f;
		for (usz b = 0; b < bones; b++) sum += from[at + b];
		if (sum > 0.0f) for (usz b = 0; b < bones; b++) fill[c * bones + b] = from[at + b] / sum;
		if (owner[c] != 0)
		{
			back[c] = sum > 0.0f && !binder_made[c];
			if (!back[c])
			{
				fill[c * bones:bones] = 0.0f;
				ring.push((uint)c);
				continue;
			}
		}
		known[c] = sum > 0.0f;
	}

	// A ring is the strays touching something known; each reads only what was
	// known before it, so the order inside a ring does not matter.
	List{uint} filled;
	filled.init(mem);
	defer filled.free();
	while (ring.len() > 0)
	{
		filled.clear();
		foreach (c : ring)
		{
			float[] row = fill[(usz)c * bones:bones];
			usz rows = 0;
			foreach (n : around.around(c))
			{
				if (!known[n]) continue;
				for (usz b = 0; b < bones; b++) row[b] += fill[(usz)n * bones + b];
				rows++;
			}
			if (rows == 0) continue;
			foreach (&weight : row) *weight /= (float)rows;
			filled.push(c);
		}
		if (filled.len() == 0) break;
		foreach (c : filled) known[c] = true;
		sz kept = 0;
		foreach (c : ring) if (!known[c]) ring[kept++] = c;
		while (ring.len() > kept) ring.pop()!!;
	}

	PinDraft draft;
	defer draft.free();
	draft.init(count);
	uint[SKIN_INFLUENCES] dots;
	float[SKIN_INFLUENCES] shares;
	usz stated = 0;
	for (usz v = 0; v < count; v++)
	{
		uint c = around.class_of[v];
		if (owner[c] == 0 || !known[c]) continue;
		if (back[c])
		{
			draft.state((uint)v, {}, {});
			stated++;
			continue;
		}
		usz kept = top_row(fill[(usz)c * bones:bones], view.dot_ids, -1, dots[..], shares[..]);
		if (kept == 0) continue;
		draft.state((uint)v, dots[:kept], shares[:kept], owner[c]);
		stated++;
	}
	if (stated == 0 || self.lay_draft(&draft) == 0) return 0;
	if (self.skinned()) self.refresh_pose_display();
	return stated;
}

<*
 Survey the bind for strays (`stray_islands`) and keep what it found for the
 Weights card, which lists them and marks them on the mesh until the next edit.

 @return `How many strays there are.`
*>
fn usz AppState.find_strays(&self)
{
	self.drop_strays();
	self.strays = self.stray_islands(mem);
	self.strays_checked = true;
	self.strays_revision = self.undo_stack.revision;
	self.strays_generation = next_generation();
	if (self.tint_mode != OFF)
	{
		self.weights_stale = true;
		self.weights_due = 0.0f;
	}
	return self.strays.len;
}

fn void AppState.drop_strays(&self)
{
	free_strays(mem, self.strays);
	self.strays = {};
	self.strays_checked = false;
}

// Whether the last survey still describes the bind: nothing has been edited since.
fn bool AppState.strays_current(&self) => self.strays_checked && self.strays_revision == self.undo_stack.revision;

// How many vertices the last survey's strays hold together.
fn usz AppState.stray_vertices(&self)
{
	usz held = 0;
	foreach (stray : self.strays) held += stray.vertices.len;
	return held;
}

<*
 Fix every stray the last survey found (`fix_strays`), then survey again so the
 card says what is left.

 @return `How many vertices were restated.`
*>
fn usz AppState.fix_found_strays(&self)
{
	if (!self.strays_current() || self.strays.len == 0)
	{
		self.@notice("find strays first");
		return 0;
	}
	usz fixed = self.fix_strays(self.strays);
	usz left = self.find_strays();
	if (fixed == 0)
	{
		self.@notice("nothing to change — the strays are the automatic weights'");
	}
	else if (left == 0)
	{
		self.@notice("fixed %d stray vertices", fixed);
	}
	else
	{
		self.@notice("fixed %d stray vertices · %d %s left", fixed, left, left == 1 ? "stray" : "strays");
	}
	return fixed;
}

<*
 While the Weights card lists strays, mark their vertices in `STRAY_RED` on
 whichever view is up, so the few vertices of a spike can be found on the body.
*>
fn void AppState.overlay_stray_tints(&self)
{
	usz count = self.geometry.positions.len;
	if (!self.strays_current() || self.tints.len != count) return;
	uint red = rgb(STRAY_RED.x, STRAY_RED.y, STRAY_RED.z);
	foreach (stray : self.strays)
	{
		foreach (v : stray.vertices) if ((usz)v < count) self.tints[v] = red;
	}
}
