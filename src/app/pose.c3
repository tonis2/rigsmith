<*
 The two halves of a posed mesh that nobody owns alone.

 Animation playback and timeline pose drafts deform the body the same way: a
 `pose_palette` of one matrix per joint, over a `skin` binding of per-vertex
 influences. `drop_palette` puts that back at rest and `rebind_skin` rebuilds
 the binding under it.

 The split between them is the split in cost. The palette is sized by the rig
 and is rebuilt every frame a mode runs; the binding is sized by the mesh and is
 rebuilt only when the rig has moved under it.
*>
module crig;

import rig;
import gltf;
import std::math;
import std::math::matrix;



<*
 Releases the palette and the posed overlay together.

 Dropping both is what puts the whole picture back at rest: the mesh is skinned
 only while there is a palette, and the rig is drawn away from its own dots only
 while there is an overlay. Freeing one and not the other leaves the two halves
 of the view disagreeing about whether anything is playing.
*>
fn void AppState.drop_palette(&self)
{
	if (self.pose_palette.len > 0) alloc::free(mem, self.pose_palette);
	self.pose_palette = {};
	self.next_pose_generation();

	if (self.posed_dots.len > 0) alloc::free(mem, self.posed_dots);
	self.posed_dots = {};

	free_aim_handles(self.posed_aims);
	self.posed_aims = {};
	if (self.posed_aim_links.len > 0) alloc::free(mem, self.posed_aim_links);
	self.posed_aim_links = {};
}

<*
 A fresh stamp for a palette nothing has been skinned against yet.

 One stamp invalidates every lazy posed bound and vertex, which is why every
 distinct palette needs one of its own: the collision check skins candidate
 poses through the same caches the overlay reads, and two palettes under one
 stamp would hand one's vertices to the other. Zero means "no posed
 generation" to the query, so it is skipped on the practically impossible
 wrap rather than making one frame look cached forever.
*>
fn uint AppState.next_pose_generation(&self)
{
	self.pose_generation = next_generation();
	return self.pose_generation;
}

<*
 Re-evaluate whichever kind of posed display currently owns the palette.

 A parked animation still has `animating` set: only its clock is paused. Limit
 edits and history steps use this door so a newly tightened range is visible on
 that same frame instead of waiting for playback to resume. A transient timeline
 draft takes precedence over the player for defensive callers that still have
 both flags during a state transition.
*>
fn void AppState.refresh_pose_display(&self)
{
	if (self.pose_edit_active)
	{
		self.refresh_posed();
		return;
	}
	if (self.animating)
	{
		self.refresh_animation();
		return;
	}
}

<*
 Rebinds the skin to the rig `view` describes, if it has moved since the last
 binding.

 Shared by timeline posing and the animation player: both deform the mesh
 through `pose_palette`, both need a binding that describes the rig as it is now, and a
 binding rebuilt in two places is one that can be rebuilt two different ways.

 Returns immediately when the rig has not moved, which is the common case — both
 callers reach this every frame while they run.

 @return `False when the mesh could not be bound — the caller has no skin to pose with.`
*>
fn bool AppState.rebind_skin(&self, RigView* view)
{
	if (!self.skin_stale && self.skin_generation > 0) return true;

	// Mid-stroke the old surface stays up — see `end_stroke`. It borrows the
	// picker and takes the binding at query time, so it can outlive the
	// binding it was built over; only its static tables and per-joint boxes
	// are a stroke behind, and they are rebuilt the moment the button lifts.
	// Keeping it is what makes a stroke over a parked clip cost a sparsify and
	// an upload per move rather than a mirrored tree and a policy as well.
	bool keep_surface = self.stroke_open && self.deformed_surface.root != null
		&& self.deformed_surface.vertices == self.geometry.positions.len
		&& self.deformed_surface.joints == (uint)view.len();
	// They were derived from this binding and borrow the current picker. Drop
	// them before either side can be replaced.
	if (!keep_surface)
	{
		self.collision_policy.free();
		self.deformed_surface.free();
	}
	self.skin.free(mem);
	// Cleared before the rebind can fail: `free` leaves its slices pointing at
	// released memory, and the next free of the same binding would be a second
	// one.
	self.skin = {};
	// With it, because a joint count left behind describes a binding that is no
	// longer there — and `engine/scene.c3` would size three's skin from it.
	self.skin_joints = 0;

	// Through `painted_bind` rather than the binder directly, because that is
	// where the file's own weights are chosen over crig's — and because
	// everything the binder reads has to arrive the same way here as it does in
	// `write_rigged`: the cached base is `bind_dense` unpainted, with the same
	// corrections and pins laid over it in the same order. A preview bound on
	// different terms from the export deforms the mesh one way on screen and
	// another way in the file it writes. The cache is what lets a brush stroke
	// over a posed mesh reskin on every move: the geodesic pass underneath
	// costs tens of milliseconds, the multiply over it a fraction of one, and
	// `mark_rig_stale` drops the cache whenever the base is worth redoing.
	float[] dense = self.painted_bind(mem, view);
	defer if (dense.len > 0) alloc::free(mem, dense);

	gltf::SkinBinding? bound = gltf::sparsify_weights(
		mem, dense, self.geometry.positions.len, view.len(), SKIN_INFLUENCES);
	if (catch bound) return false;

	self.skin = bound;
	self.skin_joints = (uint)view.len();
	if (keep_surface)
	{
		self.surface_stale = true;
	}
	else
	{
		self.deformed_surface = build_deformed_collision_surface(&self.picker, self.skin, self.skin_joints);
		// The surface serves the overlay's occlusion whatever the settings say;
		// the policy over it is the self-collision system's alone, and is built
		// only when that is switched on. With the mesh's welds, so a seam the
		// exporter split is one surface to the policy rather than a row of rest
		// contacts to measure and store, and with the binding, so the patches
		// its weights blend across are read as one skin rather than as regions
		// meeting.
		if (self.config.self_collision)
		{
			self.collision_policy = build_collision_policy(&self.deformed_surface,
				view.skeleton.parents, view.dot_ids, self.collision_clearance(), &self.doc,
				self.adjacency_for().class_of, self.skin);
		}
		// A new surface is a new measurement: whatever the old one could afford,
		// this one is checked in full until it says otherwise.
		self.collision_mode = FULL;
		self.surface_stale = false;
	}
	self.skin_stale = false;
	self.skin_generation = next_generation();
	return true;
}

<*
 Occlusion against whichever surface is actually on screen.

 A live palette uses the lazy exact posed query; at rest — or if a malformed
 binding prevented that accelerator from being built — the ordinary picker is
 still the correct surface and remains the safe fallback.
*>
fn bool AppState.mesh_occluded(&self, Vec3 eye, Vec3 point)
{
	if (self.pose_palette.len > 0
		&& self.deformed_surface.matches(self.skin, self.pose_palette, self.pose_generation))
	{
		return self.deformed_surface.occluded(
			eye, point, self.skin, self.pose_palette, self.pose_generation);
	}
	return self.picker.occluded(eye, point);
}

<*
 Whether the surface on screen is the posed one, and can answer for itself.

 The condition `mesh_occluded` tests, named once: a palette is up and the
 accelerator was built for a binding shaped like the current one. Everything
 that asks "where is this vertex right now" or "is this vertex in sight" reads
 the same answer, so the brush, the overlay and the pick test cannot disagree
 about which body is being looked at.
*>
fn bool AppState.posed_surface_shown(&self)
{
	return self.pose_palette.len > 0
		&& self.deformed_surface.matches(self.skin, self.pose_palette, self.pose_generation);
}

<*
 Where a vertex is drawn right now: skinned by the palette on screen, or at
 rest when there is none.

 The one place that answers it, so a tool aiming at the body the user sees —
 the brush under a parked clip — projects the same point the GPU did. Cached
 per vertex per pose generation by the surface, which is what makes asking it
 for every vertex under a circle on every mouse move affordable.
*>
fn Vec3 AppState.shown_position(&self, usz vertex)
{
	if (self.posed_surface_shown())
	{
		return self.deformed_surface.posed_vertex(vertex, self.skin, self.pose_palette, self.pose_generation);
	}
	return self.geometry.positions[vertex];
}

<*
 `Picker.hidden_surface` against whichever surface is actually on screen.

 The brush's front-faces-only test. `point` is a `shown_position`: the posed
 vertex when a palette is up, the rest one otherwise, so the cast is made
 against the same body the point was read from.
*>
fn bool AppState.mesh_hidden_surface(&self, Vec3 eye, Vec3 point)
{
	if (self.posed_surface_shown())
	{
		return self.deformed_surface.hidden_surface(
			eye, point, self.skin, self.pose_palette, self.pose_generation);
	}
	return self.picker.hidden_surface(eye, point);
}
