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

 **What the weights are.** One funnel, `weights`: the automatic bind for every
 joint nobody has edited, and the stored column of every joint that has been
 (`Dot.held`). The Unused overlay, beside either view, marks the vertices the
 two leave holding nothing.
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
 colours, so a switch that only re-armed a stale rig would leave the territory
 and falloff views both showing whichever one was painted first.

 Immediately rather than after the debounce, for the same reason a keypress
 never waits: the delay exists to swallow a stream of edits, and this is one
 deliberate act.
*>
fn void AppState.toggle_tint(&self, TintMode mode)
{
	self.show_tint(self.tint_mode == mode ? OFF : mode);
}

<*
 Whether the mesh is recoloured at all: a weight view is up, or the Unused
 overlay is on. Every gate that used to ask "is a view on" asks this, since the
 overlay needs the same debounced recolour the views do.
*>
fn bool AppState.tinting(&self) => self.tint_mode != OFF || self.show_unused;

<*
 The Unused overlay on or off. Recoloured at once, like `show_tint`: the
 weights did not change, only what is painted from them.
*>
fn void AppState.toggle_unused(&self)
{
	self.show_unused = !self.show_unused;
	self.weights_stale = true;
	self.weights_due = 0.0f;
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
	if (!self.tinting()) return;

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
 `weights`.
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
	if (!self.tinting() || !self.weights_stale) return;

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
		|| (self.tinting() && self.weights_stale)
		|| self.edge_pending
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
 number. A caller that wants to keep or modify the array wants `weights`,
 which hands back a copy.

 @return `The base bind, or empty when there is no rig or no mesh to bind.`
*>
fn float[] AppState.base_bind_for(&self, RigView* view)
{
	usz wanted = self.geometry.positions.len * view.len();
	if (wanted == 0) return {};

	ulong key = self.bind_key(view);
	if (self.base_bind.len != wanted || self.base_key != key)
	{
		self.drop_base_bind();
		self.base_bind = self.bind_base(mem, view);
		self.base_key = key;
		if (self.base_bind.len != wanted) return {};
	}
	return self.base_bind;
}

<*
 The rig bound with these joints' grows and soft edges on it and nobody else's:
 what Grow, Shrink and Soft edge write a held joint's column from.

 	`float[] shaped = app.tool_bind_for(&view, { knee, twin });`

 A bind of its own because the live one (`base_bind_for`) reads no grow at all —
 a grown joint changes who owns a vertex, and with it every neighbour's window,
 so a grow in the live bind would move weights the user never touched. Here the
 change is read off only for the joints asked about. With none of them grown or
 softened it *is* the live bind, so a joint shrunk back to nothing gets exactly
 the column it would follow unheld.

 Cached on its own key, one bind at a time — a Grow drag asks for the same
 joint's again and again. **Borrowed**, on `base_bind_for`'s terms, and valid
 until the next tool bind or the next rig change.

 @param dots : `The joints whose grow and soft edge to bind with; ids not in the view are skipped.`
 @return `Vertices x joints in the view's order, rows summing to one; empty with nothing to bind.`
*>
fn float[] AppState.tool_bind_for(&self, RigView* view, uint[] dots)
{
	usz bones = view.len();
	usz wanted = self.geometry.positions.len * bones;
	if (wanted == 0) return {};

	float[] grows = alloc::new_array(mem, float, (sz)bones);
	defer alloc::free(mem, grows);
	float[] bands = alloc::new_array(mem, float, (sz)bones);
	defer alloc::free(mem, bands);
	bool shaped = false;
	ulong key = self.bind_key(view);
	foreach (id : dots)
	{
		sz j = view.joint_of(id);
		if (j < 0) continue;
		grows[(usz)j] = j < view.grows.len ? view.grows[(usz)j] : 0.0f;
		bands[(usz)j] = j < view.bands.len ? view.bands[(usz)j] : 0.0f;
		if (grows[(usz)j] != 0.0f || bands[(usz)j] > 0.0f) shaped = true;
		mix_key(&key, (ulong)id);
		mix_key(&key, (ulong)bitcast(grows[(usz)j], uint));
		mix_key(&key, (ulong)bitcast(bands[(usz)j], uint));
	}
	if (!shaped) return self.base_bind_for(view);
	if (self.tool_bind.len == wanted && self.tool_key == key) return self.tool_bind;

	self.drop_tool_bind();
	int[] riders = self.shells.count > 0 ? alloc::new_array(mem, int, (sz)self.shells.count) : (int[]){};
	defer if (riders.len > 0) alloc::free(mem, riders);
	float[] distances = alloc::new_array(mem, float, (sz)wanted);
	defer alloc::free(mem, distances);
	self.tool_bind = self.bind_binder(mem, view, grows, bands, riders, {}, distances);
	normalise_rows(self.tool_bind, bones);
	self.tool_key = key;
	if (self.tool_bind.len != wanted) return {};
	return self.tool_bind;
}

// Releases the cached tool bind. Safe on one never made.
fn void AppState.drop_tool_bind(&self)
{
	if (self.tool_bind.len > 0) alloc::free(mem, self.tool_bind);
	self.tool_bind = {};
}

<*
 A fingerprint of everything the base bind is made from: the joints, their
 tree, their reaches, which shells ride which joint, the model's sharpness and
 knuckle blend, and the mesh itself. Not
 the grows or soft edges, which the live bind does not read — see
 `tool_bind_for`.

 What makes the cache trustworthy rather than merely fast. `mark_rig_stale`
 drops it on every recorded edit, but a cache that is only as fresh as the last
 caller remembered to make it hands back the bind of a rig nobody has any more —
 a dot moved by a path that forgot, and every view, the skin and the file all
 describe the old one. Checked on every read; the cost is a pass over the
 joints, against a bind that costs a pass over the mesh through the voxel grid.
*>
fn ulong AppState.bind_key(&self, RigView* view)
{
	ulong hash = 0xcbf2_9ce4_8422_2325;
	mix_key(&hash, (ulong)(uptr)self.geometry.positions.ptr);
	mix_key(&hash, (ulong)self.geometry.positions.len);
	mix_key(&hash, (ulong)bitcast(self.doc.sharpness, uint));
	mix_key(&hash, (ulong)bitcast(self.doc.knuckle_blend, uint));
	foreach (b, joint : view.skeleton.joints)
	{
		mix_key(&hash, (ulong)bitcast(joint.x, uint));
		mix_key(&hash, (ulong)bitcast(joint.y, uint));
		mix_key(&hash, (ulong)bitcast(joint.z, uint));
		mix_key(&hash, (ulong)(uint)view.skeleton.parents[b]);
		mix_key(&hash, (ulong)view.dot_ids[b]);
	}
	foreach (reach : view.reaches) mix_key(&hash, (ulong)bitcast(reach, uint));
	foreach (rides : view.attachments) mix_key(&hash, (ulong)(uint)rides);
	return hash;
}

// One step of FNV-1a over a whole word, for `bind_key`.
fn void mix_key(ulong* hash, ulong value) @private
{
	*hash = (*hash ^ value) * 0x0000_0100_0000_01b3;
}

<*
 Which of the two binds a reader is asking for.

 There are exactly two, and every weight tool asks for one of them by name
 rather than assembling its own from the layers underneath. Before there was a
 name for each, five callers each built "the automatic weights" their own way —
 some with the paint multipliers on, some without — and two tools asked the same
 question got two answers.
*>
enum WeightLayer
{
	AUTOMATIC, // every joint as the binder places it now: what an unheld joint follows and Reset goes back to
	EDITED,    // held joints' own columns as stored, the rest automatic: what the views draw, the skin rides and the file holds
}

<*
 The weights, as one of the two binds every tool shares.

 	`float[] shown = app.weights(mem, &view);`
 	`float[] automatic = app.weights(mem, &view, AUTOMATIC);`

 **The funnel.** The views, the posed skin, the exporters, the survey, the
 brush, the Area tool, the stray fixer and MCP all read the weights through
 here, so none of them can disagree with what another shows. A copy of the
 cached live bind (`base_bind_for`), and for `EDITED` every held joint's column
 replaced by the one it stores (`Dot.held`).

 **Column by column, never row by row.** A held column is written as stored,
 whatever the automatic columns beside it hold, and they are not rescaled around
 it — so editing one joint moves no other joint's weight, and a vertex a held
 joint was taken off with nothing automatic on it is left holding nothing
 (unused; see `UNUSED_TOTAL`). Rows therefore need not sum to one; every
 consumer divides by the row's own total.

 The caller owns the returned array; the cache stays behind.

 @return `Vertices x joints in the view's order, or empty when there is no rig or no mesh to bind.`
*>
fn float[] AppState.weights(&self, Allocator allocator, RigView* view, WeightLayer layer = EDITED)
{
	usz bones = view.len();
	usz wanted = self.geometry.positions.len * bones;
	if (wanted == 0) return {};

	// A rig whose every joint is held shows nothing of the binder's, so the bind
	// is not worth making.
	bool all_held = layer == EDITED && view.all_held();
	float[] base = all_held ? (float[]){} : self.base_bind_for(view);
	if (!all_held && base.len == 0) return {};

	float[] out = alloc::new_array(allocator, float, (sz)wanted);
	if (!all_held) out[..] = base[..];
	if (layer == AUTOMATIC || view.held.len == 0) return out;

	for (usz v = 0; v < wanted; v += bones)
	{
		for (usz j = 0; j < bones; j++) if (view.held[j]) out[v + j] = 0.0f;
	}
	foreach (pin : view.pins) out[(usz)pin.vertex * bones + pin.joint] = pin.share;
	return out;
}

<*
 The bind's distances: the squared distance from each vertex to its nearest
 bone, and the joint each shell rode — what the unclaimed count reads.

 	`float[] nearest = app.bind_field(&view, &riders);`

 Filled by the same bind as the base when the binder made it. A rig wearing its
 file's weights has no bind of crig's underneath, so the distances are measured
 once here and kept until the rig changes — the question "how far is this vertex
 from every bone" has the same answer whoever painted the weights.

 Borrowed, like `base_bind_for`: valid until the next `mark_rig_stale`.

 @param riders : `Set to the riders of the same bind; may be empty.`
 @return `One per vertex, or empty when there is nothing to bind.`
*>
fn float[] AppState.bind_field(&self, RigView* view, int[]* riders)
{
	*riders = {};
	usz vertices = self.geometry.positions.len;
	if (vertices == 0 || view.len() == 0 || self.base_bind_for(view).len == 0) return {};

	if (self.field_nearest.len != vertices)
	{
		self.drop_field();
		self.field_nearest = alloc::new_array(mem, float, (sz)vertices);
		if (self.shells.count > 0) self.field_riders = alloc::new_array(mem, int, (sz)self.shells.count);
		float[] dense = rig::bind_geodesic(
			mem, &self.voxels, self.geometry.positions, view.skeleton.joints, view.skeleton.parents,
			&self.shells, view.attachments, self.field_riders, view.reaches, self.field_nearest, self.bind_eps());
		alloc::free(mem, dense);
	}
	*riders = self.field_riders;
	return self.field_nearest;
}

// Releases the cached distances. Safe on ones that were never filled.
fn void AppState.drop_field(&self)
{
	if (self.field_nearest.len > 0) alloc::free(mem, self.field_nearest);
	if (self.field_riders.len > 0) alloc::free(mem, self.field_riders);
	if (self.field_distances.len > 0) alloc::free(mem, self.field_distances);
	self.field_nearest = {};
	self.field_riders = {};
	self.field_distances = {};
}

// Releases the cached base bind and the distances that came with it. Safe to
// call on one that is already empty, which is what lets `mark_rig_stale` stay
// unconditional.
fn void AppState.drop_base_bind(&self)
{
	if (self.base_bind.len > 0) alloc::free(mem, self.base_bind);
	self.base_bind = {};
	self.drop_tool_bind();
	self.drop_field();
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
	// frame. Always the edited weights: the views show what the mesh wears, and
	// nothing else.
	float[] painted = self.weights(mem, &view, EDITED);
	defer if (painted.len > 0) alloc::free(mem, painted);

	switch (self.tint_mode)
	{
		case FALLOFF:
			// One joint's share, or none of anybody's when the selection was
			// cleared under the view: grey everywhere says "no joint chosen",
			// where falling back to joint 0 painted the root's weights under a
			// label naming nobody.
			sz found = view.joint_of(self.selected);
			if (found < 0)
			{
				self.falloff_held = 0;
				self.tints = alloc::new_array(mem, uint, (sz)self.geometry.positions.len);
				self.tints[..] = share_tint(0.0f);
				break;
			}
			self.tints = falloff_tints(mem, painted, self.geometry.positions.len, view.len(), (usz)found,
				SHOWN_FLOOR, &self.falloff_held);
		case TERRITORY:
			self.tints = vertex_tints(mem, painted, self.geometry.positions.len, view.len());
		case OFF:
			// The Unused overlay with no view under it: the plain mesh colour, so
			// the magenta is the only thing painted and says only one thing.
			self.tints = alloc::new_array(mem, uint, (sz)self.geometry.positions.len);
			self.tints[..] = rgb(MESH_COLOR.r, MESH_COLOR.g, MESH_COLOR.b);
	}
	self.overlay_area_tints(&view, painted);
	self.overlay_limb_tints(&view, painted);
	self.overlay_unused_tints(view.len(), painted);
	self.overlay_stray_tints();
}

<*
 Count the vertices no joint holds and, while the overlay is on, mark them in
 `UNUSED_MAGENTA` over whatever the view painted. Counted either way, so the
 card and `get_weights` can say how many there are without the overlay up.
*>
fn void AppState.overlay_unused_tints(&self, usz bones, float[] painted)
{
	usz count = self.geometry.positions.len;
	self.unused_count = 0;
	if (bones == 0 || painted.len != count * bones) return;
	bool marking = self.show_unused && self.tints.len == count;
	uint magenta = rgb(UNUSED_MAGENTA.x, UNUSED_MAGENTA.y, UNUSED_MAGENTA.z);
	for (usz v = 0; v < count; v++)
	{
		if (!unused_row(painted[v * bones:bones])) continue;
		self.unused_count++;
		if (marking) self.tints[v] = magenta;
	}
}

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
	usz reaches; // those, plus every other it holds at least SHOWN_FLOOR of
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
	usz unused;  // vertices no joint holds — see UNUSED_TOTAL
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

	// What the views paint and the skin rides, through the one funnel: the
	// survey describes the weights somebody is looking at, never a bind of its
	// own. The distances and the riders come from the same bind — see
	// `bind_field` — and keep the rigidly bound shells out of the unclaimed count.
	float[] dense = self.weights(mem, &view);
	defer if (dense.len > 0) alloc::free(mem, dense);
	if (dense.len != vertices * bones) return WEIGHTS_NO_RIG~;
	int[] riders;
	float[] nearest = self.bind_field(&view, &riders);

	usz unused = 0;
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
		if (sum <= UNUSED_TOTAL) unused++;
		if (sum <= 0.0f || owner < 0) continue;
		usz best = (usz)owner;
		stakes[best].owns++;

		// The owner always reaches what it owns. On a rig with enough joints the
		// strongest share of an evenly-spread vertex can sit under the floor, and a
		// dot reported as owning mass it does not reach describes nothing.
		for (usz b = 0; b < bones; b++)
		{
			if (b == best || dense[base + b] / sum >= SHOWN_FLOOR) stakes[b].reaches++;
		}

		if (focus < 0 || (usz)focus == best) continue;

		float share = dense[base + (usz)focus] / sum;
		if (share < SHOWN_FLOOR) continue;
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
		.unused = unused,
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


// How far from the rest of a joint's weight, as a fraction of the model's
// height, an island of it has to sit to be a stray rather than its own blend.
const float STRAY_GAP = 0.1f;

// How far a pose has to be able to pull an island off the mesh around it, as a
// fraction of the model's height, for it to be a stray — see `pull_apart`.
const float STRAY_PULL = 0.05f;

// The colour the Unused overlay marks a vertex no joint holds in — Blender's
// "missing" colour, which no territory hue, the falloff ramp nor stray red is.
const Vec3 UNUSED_MAGENTA = { 1.0, 0.0, 1.0 };

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
	float[] painted = self.weights(mem, &view);
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
 Take each stray's joint off the stray, as one undo step.

 A stray is an island of one joint's weight cut off from the rest of it, so
 the fix is that joint's alone: its weight on the island's vertices goes to 0
 and every other joint keeps what it holds there. The joint is held from then
 on (`replace_column`). A vertex nobody else held is left unused rather than
 handed to somebody — the Unused view shows it, and the brush or the lasso
 gives it to the joint it belongs to.

 @param emptied : `Filled with how many vertices were left holding nothing. Null to not ask.`
 @return `How many vertices changed; 0 when nothing did.`
*>
fn usz AppState.fix_strays(&self, StrayIsland[] strays, usz* emptied = null)
{
	if (emptied) *emptied = 0;
	usz count = self.geometry.positions.len;
	if (strays.len == 0 || count == 0) return 0;
	self.flush_edges();

	RigView? opened = self.open_rig(mem);
	if (catch opened) return 0;
	RigView view = opened;
	defer view.free(mem);
	usz bones = view.len();
	float[] painted = self.weights(mem, &view);
	defer if (painted.len > 0) alloc::free(mem, painted);
	if (bones == 0 || painted.len < count * bones) return 0;

	float[] column = alloc::new_array(mem, float, (sz)count);
	defer alloc::free(mem, column);
	usz changed = 0;
	foreach (usz i, stray : strays)
	{
		// One column per joint, however many of its islands were found: the first
		// stray naming a joint writes all of them.
		bool seen = false;
		for (usz k = 0; k < i; k++) if (strays[k].dot == stray.dot) seen = true;
		sz joint = view.joint_of(stray.dot);
		if (seen || joint < 0) continue;

		for (usz v = 0; v < count; v++) column[v] = painted[v * bones + (usz)joint];
		foreach (other : strays[i..])
		{
			if (other.dot != stray.dot) continue;
			foreach (v : other.vertices)
			{
				if ((usz)v >= count || column[v] == 0.0f) continue;
				column[v] = 0.0f;
				float total = 0.0f;
				for (usz b = 0; b < bones; b++) if ((sz)b != joint) total += painted[(usz)v * bones + b];
				if (emptied && total <= UNUSED_TOTAL) (*emptied)++;
			}
		}
		changed += self.replace_column(&view, stray.dot, column, commit: false);
	}
	if (changed == 0) return 0;
	self.undo_stack.commit();
	return changed;
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
	if (self.tinting())
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
	usz emptied = 0;
	usz fixed = self.fix_strays(self.strays, &emptied);
	usz left = self.find_strays();
	String unused = emptied > 0 ? string::tformat(" · %d left unused, View › Unused weights shows them", emptied) : "";
	if (fixed == 0)
	{
		self.@notice("nothing to change");
	}
	else if (left == 0)
	{
		self.@notice("fixed %d stray vertices%s", fixed, unused);
	}
	else
	{
		self.@notice("fixed %d stray vertices · %d %s left%s", fixed, left, left == 1 ? "stray" : "strays", unused);
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
