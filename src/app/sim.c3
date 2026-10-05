<*
 The document's dynamic bones, running on top of whatever clip is playing.

 `anim/jiggle.c3` is the solver and knows nothing about a document, a window or
 a frame; `player.c3` turns a clip into a pose. This is the seam between them,
 and the whole of it is an order that is not negotiable:

     sample   the clip says where every joint would be with no physics at all
     aim      a palette over *that* pose is what the chains are pulled toward
     advance  as many 1/120 s substeps as this frame paid for
     write    the simulated rotations land back on the same pose
     skin     `refresh_animation` builds the palette the renderer sees from it

 The palette built here is thrown away, because it describes the pose before
 physics touched it. Two palettes per frame of playback, both one matrix per
 joint — the cost of the whole feature is set by the rig's size, and the frame
 was already walking it.

 **The sim is rebuilt rather than repaired.** A chain is a soft body plus the
 constraint indices into it, assembled once; a dot appearing halfway down a tail
 changes which run every joint below it belongs to, and there is no edit of the
 existing body that means the same thing as building it again. So everything
 that changes what the physics *is* — the setters in `recorded.c3`, a step of
 history, a skeleton that is no longer the shape the sim was built against —
 raises a flag, and the flag is spent here, on a frame that had to open the rig
 anyway.

 **A rebuild is also the reset.** A fresh sim is unprimed, so its first substep
 puts every particle exactly where the animation says its joint is, standing
 still — which is precisely what a seek, a clip change or a stop needs, and why
 there is one reset here rather than two.

 **The character is what the chains are held off.** The sim's `JiggleSurface`
 is answered here from the skin the player is deforming — the same
 `DeformedCollisionSurface` the overlay's occlusion and the self-collision
 check read — with every triangle a chain itself drives left out, since those
 go where the chain goes. Each chain's particles are as fat as the skin around
 their bone is, measured off the weights (`joint_thickness`), plus the
 collision clearance: nothing about it is typed. A rig with no mesh bound has
 no surface and its chains collide with whatever capsules it carries, as they
 always did.
*>
module crig;

import rig;
import std::math;
import std::math::matrix;



<*
 Advance the dynamic bones one frame and fold them into the pose the clip
 sampled.

 	`self.tick_jiggle(&view, &pose, dt);`

 Called from `refresh_animation` between the sample and the palette, the one
 place that holds a skeleton, a pose and a frame's worth of time at once.

 **A zero `dt` runs no substeps and still writes**, which is what every caller
 that is not the clock wants: a paused player, a seek, a rig edit that refreshed
 the picture. The tail holds where it settled rather than snapping back onto the
 keyed pose the moment nothing is advancing it.

 **It asks for no frames of its own.** `AppState.ticking` is unchanged, because
 this only ever runs under `refresh_animation` while a clip is playing, and the
 player is already what keeps the loop awake.

 @param view : `The rig the pose was sampled against. Its skeleton is what the sim is built from, and its dot ids are how the document's chains are found.`
 @param pose : `The animated pose, adjusted in place. Rotations only — offsets are left exactly as the clip and the ground solve wrote them.`
 @param dt : `Seconds of real time since the last frame. Zero holds the settled tail without advancing it.`
*>
fn void AppState.tick_jiggle(&self, RigView* view, rig::Pose* pose, float dt)
{
	if (!self.sim_enabled) return;

	if (self.sim_stale || !self.jiggle_sim.matches(&view.skeleton)) self.rebuild_jiggle(view);

	// The ordinary case, on the rigs nobody has made a single bone dynamic on:
	// one comparison per frame, and no palette built to hand a solver with
	// nothing to solve.
	if (!self.jiggle_sim.solves()) return;

	Matrix4f[]? aimed = rig::joint_palette(mem, &view.skeleton, *pose);
	if (catch aimed) return;
	Matrix4f[] targets = aimed;
	defer alloc::free(mem, targets);

	self.jiggle_sim.advance(targets, dt);
	self.release_jiggle_surface();

	// A refusal here is the pose and the skeleton disagreeing about their own
	// shape, which is a sim that went stale between the rebuild above and now.
	// Dropped the way a palette that would not build is dropped — this frame
	// shows the animation unmodified — and flagged, so the next one starts over
	// rather than asking again every frame.
	if (catch self.jiggle_sim.write_pose(mem, &view.skeleton, pose)) self.sim_stale = true;
}

<*
 State that whatever the tail was doing a moment ago is not history this run may
 use.

 A cut, in the editing sense. The particles carry a velocity and a lag of their
 own, and both are answers to a question the previous frame asked; after a seek,
 a clip change, or a change to the physics itself they are answers to the wrong
 question, and a chain released from them whips rather than swings.

 One bool, spent on the next frame of playback — the rebuild it asks for is also
 the prime, so no caller has to know which of the two it wanted, and a reset on
 a document with no dynamic bones costs a comparison and nothing else.
*>
fn void AppState.jiggle_reset(&self)
{
	self.sim_stale = true;
	// And the overlay's answer to "which dots are dynamic", which is a reading of
	// the same chains; see `AppState.is_dynamic`.
	self.secondary_generation++;
}

// Throws the sim away and builds the one this document currently describes.
//
// Both halves are unconditional: the flag is cleared before the build rather
// than after it, so a document the resolver finds nothing dynamic in is asked
// once instead of on every frame of the clip.
fn void AppState.rebuild_jiggle(&self, RigView* view)
{
	self.jiggle_sim.free(mem);
	self.sim_stale = false;

	JiggleChainSpec[] chains;
	JiggleColliderSpec[] colliders;
	jiggle_specs_from_document(mem, &self.doc, &view.skeleton, view.dot_ids, &chains, &colliders);
	defer free_jiggle_specs(mem, chains, colliders);

	// The resolver only ever hands back runs it walked out of this very
	// skeleton, so a refusal is not a thing this call can provoke — and were it
	// ever to, no sim is a viewport without jiggle rather than a frame that
	// stops.
	JiggleSim? built = self.build_dressed_sim(view, chains, colliders);
	if (catch built) return;
	self.jiggle_sim = built;
}

<*
 A sim over these runs with the character's skin as its surface: the radii
 measured, the chains' own triangles set aside, the probe wired up.

 	`JiggleSim sim = app.build_dressed_sim(&view, chains, colliders)!;`

 What `rebuild_jiggle` builds the viewport's from and what a bake builds its
 private one from, so the two collide with the same skin at the same
 thickness — a bake that hit less than the viewport did would write a tail
 through the body that never went through it on screen.

 Without a skin bound to this very rig — no mesh, or a binding older than the
 skeleton — the runs are built as they came: point particles, no surface,
 the capsules alone.

 @return? JIGGLE_EMPTY_CHAIN, JIGGLE_PARAM_MISMATCH, JIGGLE_UNKNOWN_JOINT, JIGGLE_BROKEN_CHAIN : `As build_jiggle_sim.`
*>
fn JiggleSim? AppState.build_dressed_sim(&self, RigView* view, JiggleChainSpec[] chains, JiggleColliderSpec[] colliders)
{
	bool skinned = self.deformed_surface.root != null && self.skin_joints > 0
		&& (usz)self.skin_joints == view.len() && self.skin.vertices == self.deformed_surface.vertices;
	if (skinned) self.dress_jiggle_chains(view, chains);

	JiggleSim sim = build_jiggle_sim(mem, &view.skeleton, chains, colliders)!;
	if (skinned && sim.solves())
	{
		sim.surface = { .context = self, .aim = &jiggle_surface_aim, .probe = &jiggle_surface_probe };
	}
	return sim;
}

// Measure each colliding chain's particles off the skin and mark every
// triangle any chain drives as not the surface.
//
// A particle sits where a bone starts, which is also where the bone above it
// ends, so it takes the fatter of the two; a bone with no skin of its own —
// a joint nothing is weighted to — takes its neighbour's rather than
// reading as a point. The clearance the self-collision check keeps is added
// on top, so a chain stands off the body by the same gap a posed hand does.
fn void AppState.dress_jiggle_chains(&self, RigView* view, JiggleChainSpec[] chains)
{
	if (self.jiggle_skip.len > 0) alloc::free(mem, self.jiggle_skip);
	self.jiggle_skip = alloc::new_array(mem, bool, (sz)self.deformed_surface.triangles);

	Vec3[] tails = view.skeleton.tails(mem);
	defer alloc::free(mem, tails);
	float clearance = self.collision_clearance();

	foreach (&chain : chains)
	{
		foreach (joint : chain.joints)
		{
			foreach (triangle : self.deformed_surface.triangles_for_joint((uint)joint))
			{
				if ((usz)triangle < self.jiggle_skip.len) self.jiggle_skip[triangle] = true;
			}
		}
		if (chain.ignores_colliders) continue;

		float above = 0.0f;
		foreach (usz i, joint : chain.joints)
		{
			float own = self.deformed_surface.joint_thickness((uint)joint, view.skeleton.joints[joint], tails[joint]);
			if (own <= 0.0f) own = above;
			chain.params[i].radius = math::max(own, above) + clearance;
			above = own;
		}
	}
}

<*
 Every joint's thickness as the skin measures it, in this build's joint order,
 for a file that carries a sphere per dynamic bone (`rig_physics_of`).

 	`float[] radii = app.jiggle_radii(&view);`
 	`defer if (radii.len > 0) alloc::free(mem, radii);`

 Empty when no skin is bound to this rig, which is a file whose bones are
 points. The same measurement the sim's particles take, less the clearance:
 a runtime keeps its own.
*>
fn float[] AppState.jiggle_radii(&self, RigView* view)
{
	if (self.deformed_surface.root == null || self.skin_joints == 0
		|| (usz)self.skin_joints != view.len()) return {};

	Vec3[] tails = view.skeleton.tails(mem);
	defer alloc::free(mem, tails);

	float[] radii = alloc::new_array(mem, float, (sz)view.len());
	foreach (usz joint, head : view.skeleton.joints)
	{
		radii[joint] = self.deformed_surface.joint_thickness((uint)joint, head, tails[joint]);
	}
	return radii;
}

// The step's palette, borrowed until `release_jiggle_surface`, under a stamp
// of its own so the vertices it poses are never handed to another palette.
fn void jiggle_surface_aim(void* context, Matrix4f[] palette)
{
	AppState* app = (AppState*)context;
	app.jiggle_palette = palette;
	app.jiggle_generation = app.next_pose_generation();
}

// The nearest point of the skin within the particle's reach, the chains' own
// triangles left out.
fn bool jiggle_surface_probe(void* context, Vec3 point, float radius, JiggleContact* out)
{
	AppState* app = (AppState*)context;
	if (app.jiggle_palette.len == 0) return false;
	SurfaceContact near = app.deformed_surface.nearest_within(point, radius, app.jiggle_skip,
		app.skin, app.jiggle_palette, app.jiggle_generation);
	if (!near.hit) return false;
	*out = { .point = near.point, .normal = near.normal };
	return true;
}

<*
 Let go of the palette the last step borrowed, and take a fresh stamp for
 whatever is skinned next: the display's palette is stamped by whatever
 `pose_generation` stands at when it is set, and the sim's must not be it.
 After every run of the sim — a frame, a bake — before anything else is posed.
*>
fn void AppState.release_jiggle_surface(&self)
{
	if (self.jiggle_palette.len == 0) return;
	self.jiggle_palette = {};
	self.next_pose_generation();
}
