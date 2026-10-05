<*
 Taking work back, and putting it somewhere it survives the process.

 Three things that look unrelated and are not: undo, the rig export and the
 session file are the whole answer to "what happens to what I did". Undo keeps
 it for the length of a run, the session keeps it across runs, and the export is
 how it leaves crig for something else.

 `undo` and `redo` walk `core/editing.c3`'s cursor through a *group* — every
 edit chained to the one before it, which is why one Ctrl+Z takes back a whole
 mirrored placement rather than one of its four primitives. Both end by dropping
 ids that no longer name a dot, because either direction can remove the dot the
 user is pointing at.

 The session's format and its validation are `core/session.c3`; what is here is
 the pair of user-facing commands over it. Same for the export: the writers are
 `anim/export.c3` and `rig/weights.c3`, and `export_rig` is the operation —
 which binds, optionally prunes, and says what it did in the status line.
*>
module crig;

import rig;
import std::io;
import std::math;



// ---------------------------------------------------------------------------
// Undo / redo

<*
 One edit forwards, sent wherever that kind of edit lives.

 The mirror of `RigDocument.apply_edit`, and the reason there are two: almost
 every kind is the document's, but clips hang off `AppState`, so `REPLACE_CLIP`
 has to be replayed here instead. The `default` keeps that a one-line exception
 rather than a second full copy of the mapping — and the `unreachable` waiting in
 `core/editing.c3` is what catches a kind added there and forgotten here.
*>
fn void AppState.apply_one(&self, Edit edit)
{
	switch (edit.kind)
	{
		case REPLACE_CLIP: self.swap_clip_edit(edit);
		case REBIND_CLIP: self.apply_binding_edit(edit, true);
		case PAINT_STROKE: self.replay_stroke(edit, forwards: true);
		case PIN_STROKE: self.replay_pin_stroke(edit, forwards: true);
		case SET_ROTATION_LIMITS: self.replay_rotation_limits(edit, forwards: true);
		case SET_JOINT_MAPS: self.replay_joint_maps(edit, forwards: true);
		case SET_POSES: self.replay_poses(edit, forwards: true);
		case SCALE_MODEL: self.apply_model_scale(edit.scale);
		default: self.doc.apply_edit(edit);
	}
}

<*
 One edit backwards. See `apply_one`.

 `REPLACE_CLIP` is its own inverse — the slot holds whichever side of the swap is
 not in the pack, and both directions are the same exchange — so the two cases
 call the same thing. Written as a pair anyway, so this file mirrors
 `core/editing.c3`'s pair and a reader who finds one goes looking for the other.
*>
fn void AppState.revert_one(&self, Edit edit)
{
	switch (edit.kind)
	{
		case REPLACE_CLIP: self.swap_clip_edit(edit);
		case REBIND_CLIP: self.apply_binding_edit(edit, false);
		case PAINT_STROKE: self.replay_stroke(edit, forwards: false);
		case PIN_STROKE: self.replay_pin_stroke(edit, forwards: false);
		case SET_ROTATION_LIMITS: self.replay_rotation_limits(edit, forwards: false);
		case SET_JOINT_MAPS: self.replay_joint_maps(edit, forwards: false);
		case SET_POSES: self.replay_poses(edit, forwards: false);
		case SCALE_MODEL: self.apply_model_scale(1.0f / edit.scale);
		default: self.doc.revert_edit(edit);
	}
}

fn void AppState.replay_joint_maps(&self, Edit edit, bool forwards)
{
	JointMapSwap swap = self.undo_stack.joint_maps[(usz)edit.id];
	self.doc.set_joint_maps(copy_joint_maps(mem, forwards ? swap.after : swap.before));
	self.reach_stale = true;
}

fn void AppState.replay_poses(&self, Edit edit, bool forwards)
{
	PoseSwap swap = self.undo_stack.poses[(usz)edit.id];
	self.doc.set_poses(copy_saved_poses(mem, forwards ? swap.after : swap.before));
	if (self.pose_library_row >= self.doc.poses.len) self.pose_library_row = self.doc.poses.len > 0 ? self.doc.poses.len - 1 : 0;
}

<*
 Replays one complete joint-limit table from the history's payload store.
*>
fn void AppState.replay_rotation_limits(&self, Edit edit, bool forwards)
{
	RotationLimitSwap swap = self.undo_stack.rotation_limits[(usz)edit.id];
	JointRotationLimits value = forwards ? swap.after : swap.before;
	self.doc.set_rotation_limits(value.dot_id, value);
}

<*
 Puts a stroke's dabs back on the document, one side or the other.

 Unlike a clip swap this is *not* self-inverse — a dab has a before and an after
 and they are different numbers — so the direction is a parameter rather than
 something the payload can work out for itself.

 The changes are replayed in the order they were recorded going forwards and in
 reverse going back. It makes no difference today, since a stroke never writes
 the same `(vertex, dot)` twice, but the reverse order is what stays correct if
 one ever does.

 @param forwards : `True to lay the stroke down, false to take it back off.`
*>
fn void AppState.replay_stroke(&self, Edit edit, bool forwards)
{
	sz count = (sz)edit.other;
	for (sz i = 0; i < count; i++)
	{
		sz at = (sz)edit.id + (forwards ? i : count - 1 - i);
		PaintChange change = self.undo_stack.strokes[(sz)at];
		self.doc.set_paint(change.vertex, change.dot_id, forwards ? change.after : change.before);
	}
}

<*
 Puts a lasso's pins back on the document, one side or the other.

 `replay_stroke` for the other layer, with one difference that is not cosmetic:
 it goes through `write_pins` rather than through `set_pin` per change. A stroke
 is thousands of dabs and so is a region, but `set_pin` is a scan of the whole
 layer, so a per-change replay would make Ctrl+Z quadratic in exactly the
 gesture the layer exists for — a lasso of twenty thousand vertices would take
 back in seconds what it laid down in one pass.

 Reversed going back, the same as a stroke. It makes no difference today, since
 one gesture never writes the same `(vertex, dot)` twice, and the reverse order
 is what stays correct if one ever does.

 @param forwards : `True to lay the region down, false to take it back off.`
*>
fn void AppState.replay_pin_stroke(&self, Edit edit, bool forwards)
{
	sz count = (sz)edit.other;
	if (count <= 0) return;

	VertexPin[] batch = alloc::new_array(mem, VertexPin, count);
	defer alloc::free(mem, batch);

	for (sz i = 0; i < count; i++)
	{
		sz at = (sz)edit.id + (forwards ? i : count - 1 - i);
		PaintChange change = self.undo_stack.pins[at];
		batch[i] = {
			.vertex = change.vertex,
			.dot_id = change.dot_id,
			.share = forwards ? change.after : change.before,
		};
	}

	self.write_pins(batch, {});
}

<*
 Exchange the parked clip for the one in the pack, either direction.

 Both halves of `REPLACE_CLIP`. What comes out of the pack goes straight back
 into the slot the one going in came from, so the stack holds exactly one
 template per edit at every moment and nothing is copied or freed on the way.
*>
fn void AppState.swap_clip_edit(&self, Edit edit)
{
	AnimTemplate parked = self.undo_stack.clips[(usz)edit.id];
	AnimTemplate came_back = self.swap_authored_clip(edit.name, parked);
	*self.undo_stack.clips.get_ref((sz)edit.id) = came_back;
}

fn void AppState.apply_binding_edit(&self, Edit edit, bool forwards)
{
	BindingSwap* swap = self.undo_stack.bindings.get_ref((sz)edit.id);
	// Row labels borrow the binding strings this is about to swap out.
	defer self.refresh_bound_rows();
	if (swap.moves)
	{
		sz from = forwards ? (sz)swap.index : (sz)swap.to;
		sz to = forwards ? (sz)swap.to : (sz)swap.index;
		if (self.doc.reorder_bound(from, to)) self.anim_selected = (usz)to;
		return;
	}
	BoundClip expected = forwards ? swap.before : swap.after;
	BoundClip desired = forwards ? swap.after : swap.before;
	sz row = expected.clip.len > 0 ? self.doc.bound_index(expected.file, expected.clip) : -1;
	AnimRef before = row < self.doc.animations.len() ? self.resolve_bound(row) : NO_ANIM;
	bool watches = self.animating && self.current_ref.same(before);
	bool paused = self.anim_paused;
	float time = watches ? self.anim_time : self.edit_time;
	sz desired_at = desired.clip.len > 0 ? self.doc.bound_index(desired.file, desired.clip) : -1;
	if (row >= 0)
	{
		BoundClip outgoing = self.doc.swap_bound((uint)row,
			desired.clip.len > 0 && desired_at < 0
				? owned_binding(desired.file, desired.clip)
				: (BoundClip){});
		if (outgoing.file.len > 0) alloc::free(mem, outgoing.file.ptr);
		if (outgoing.clip.len > 0) alloc::free(mem, outgoing.clip.ptr);
	}
	else if (desired.clip.len > 0 && desired_at < 0)
	{
		self.doc.insert_owned_bound((sz)swap.index, owned_binding(desired.file, desired.clip));
	}
	sz after_row = desired.clip.len > 0 ? self.doc.bound_index(desired.file, desired.clip) : -1;
	AnimRef after = after_row >= 0 ? self.resolve_bound(after_row) : NO_ANIM;
	if (swap.browse)
	{
		// A hand binding moves only the list; the clip being edited is let go
		// only when it is the row that just went away.
		if (!after.valid()) self.let_go_of_clip(before);
		return;
	}
	// Binding swaps are recorded only for the clip an authoring operation lands.
	// Following the row in both directions also restores the editing context when
	// redo recreates a newly-authored clip from an otherwise invalid reference.
	self.editing = after;
	if (watches && after.valid())
	{
		if (self.start_animation_ref(after))
		{
			self.anim_time = math::clamp(time, 0.0f, self.current_anim.duration);
			self.edit_time = self.anim_time;
			self.anim_paused = paused;
			self.refresh_animation();
		}
	}
	self.refresh_timeline_tracks(after);
}

fn bool AppState.undo(&self)
{
	bool had_draft = self.prepare_timeline_navigation();
	if (!self.undo_stack.can_undo()) return false;
	self.clear_animation_key_selection();

	sz i = self.undo_stack.cursor - 1;
	self.revert_one(self.undo_stack.edits[i]);
	while (i > 0 && self.undo_stack.edits[i - 1].chained)
	{
		i--;
		self.revert_one(self.undo_stack.edits[i]);
	}

	self.undo_stack.cursor = i;
	self.stepped_history(had_draft);
	return true;
}

fn bool AppState.redo(&self)
{
	bool had_draft = self.prepare_timeline_navigation();
	if (!self.undo_stack.can_redo()) return false;
	self.clear_animation_key_selection();

	sz i = self.undo_stack.cursor;
	self.apply_one(self.undo_stack.edits[i]);
	while (self.undo_stack.edits[i].chained && i + 1 < self.undo_stack.edits.len())
	{
		i++;
		self.apply_one(self.undo_stack.edits[i]);
	}

	self.undo_stack.cursor = i + 1;
	self.stepped_history(had_draft);
	return true;
}

<*
 What undo and redo both do once the cursor has moved.

 @param had_draft : `Whether a timeline draft was open before the step; it is parked again at the same time.`
*>
fn void AppState.stepped_history(&self, bool had_draft)
{
	// A step of history moves the document without recording anything.
	self.undo_stack.revision++;
	// A step of history can restore a dot under an id something else is now
	// holding, or take away the one it was pointing at. Neither is a state a
	// handle taken before the step can be trusted in.
	self.forget_stale_ids();
	self.mark_rig_stale();
	// The document has moved; the palette on screen has not. `mark_rig_stale`
	// covers the weights and says nothing about the pose, so a pose taken back
	// would keep bending the mesh until something else happened to rebuild it.
	//
	// A pose edit does not really need the rebind above — it moves no rest
	// position, so the weights are unchanged — but a step cannot tell what kind of
	// edit it just applied without inspecting the group, and one wasted bind on
	// a keypress is cheaper than that branch.
	self.refresh_pose_display();
	if (had_draft && self.editing.valid())
	{
		self.refresh_timeline_tracks(self.editing);
		(void)self.park_clip(self.editing, self.edit_time);
	}
}

<*
 Binds the mesh to the rig the dots describe and writes it out as a .glb.

 Everything here is derived: `core/rigging.c3` walks the document into a
 skeleton, the binder weights the vertices against it, and the file is
 written from those two. Nothing about the export is stored between runs, so
 there is no state that can be stale relative to what is on screen.

 Pruning is on, and it is a safety net rather than a correction: every dot was
 placed on purpose, so a joint holding no skin usually means a dot that ended up
 outside the mesh. Dropping it silently would be wrong in an editor — hence the
 count in the notice, which is the user's cue to go and look for it.

 Failures land on the panel rather than being returned. This is invoked from a
 button and from nowhere else, and a `void?` would only be unwrapped into the
 same message one line further up.

 **Clips need names.** A clip addresses a joint by name, so a file carrying
 animations needs one on every dot; an unnamed dot means the export falls back to
 writing the rig alone and says so. A rig fitted from a body plan is named
 throughout, which is the case this is for.

 @param destination : `Where to write. Empty derives the _rigged.glb name beside the source mesh, which is what File > Export rigged .glb does.`
 @param clips : `Animations to write into the same file. Empty writes the rig alone.`
*>
fn void AppState.export_rig(&self, String destination = "", AnimTemplate[] clips = {}, ExportMotion motion = {})
{
	if (!self.has_mesh())
	{
		self.@notice("no model loaded — there is nothing to rig");
		return;
	}
	if (self.doc.dots.len() == 0)
	{
		self.@notice("nothing to export — place some joints first");
		return;
	}
	if (destination.len == 0 && self.source_path.len == 0)
	{
		self.@notice("no mesh path to export beside");
		return;
	}

	RigView? opened = self.open_rig(mem);
	if (catch fault error = opened)
	{
		self.@notice("could not build a skeleton: %s", error);
		return;
	}
	RigView view = opened;
	defer view.free(mem);

	float[] skin = self.bind_dense(mem, &view);
	defer alloc::free(mem, skin);

	// **Nothing is pruned.** An export writes its `<stem>.crig.json` beside it, so
	// the pair is a document and not only an asset — and the two halves have to
	// name the same joints. A dot the export dropped is a dot the sidecar still
	// carries, and reopening the pair would find a document describing a skeleton
	// the model does not have. A joint holding no skin costs a node and four bytes
	// of inverse bind matrix in whatever reads the file next; a dot that vanishes
	// on a round trip costs the user the work of placing it.
	//
	// Still counted, because it is worth knowing: a joint no vertex rides almost
	// always means a dot that ended up outside the mesh.
	usz idle = joints_holding_no_skin(skin, self.geometry.positions.len, view.len());

	rig::Skeleton skeleton = view.skeleton;
	String[] names = view.names;

	// A chosen destination as given, or the derived one beside the mesh. Copied
	// either way so there is one thing to free.
	String path = destination.len > 0
		? destination.copy(mem)
		: rigged_path(mem, self.source_path);
	defer path.free(mem);

	// The mesh node's name comes from the source, not the destination: it names
	// what was rigged, and a user who exported to `try2.glb` did not rename their
	// model.
	String name = self.source_path.len > 0 ? base_name(self.source_path) : "Mesh";

	// A clip finds its joint by name, so one blank name is one joint no clip can
	// reach. Said out loud rather than written into the file: an export that
	// quietly dropped the animations would look like a writer bug.
	usz unnamed = 0;
	foreach (joint_name : names)
	{
		if (joint_name.len == 0) unnamed++;
	}
	bool animated = clips.len > 0 && unnamed == 0;
	if (clips.len > 0 && unnamed > 0)
	{
		self.@notice("%d joints have no name — writing the rig without the clips", unnamed);
	}

	// Both physical boundaries are resolved out of the document against this
	// build's joint order. `RigPhysics` remains secondary motion;
	// `ConstraintRig` is the independent anatomical table written through KHR.
	float[] radii = self.jiggle_radii(&view);
	defer if (radii.len > 0) alloc::free(mem, radii);
	RigPhysics physics = rig_physics_of(mem, &self.doc, &view.skeleton, view.dot_ids, radii);
	defer physics.free(mem);
	ConstraintRig constraints = constraint_rig_of(mem, &self.doc, &skeleton, view.dot_ids);
	defer constraints.free(mem);

	if (constraints.unsupported() > 0)
	{
		self.@notice("%d joint limits can't be exported exactly and will be skipped",
			constraints.unsupported());
	}
	if (unnamed > 0 && constraints.present())
	{
		self.@notice("joint limits need named joints — writing the rig without them");
	}

	// The crig writer also accepts an empty clip list. Use it whenever there is a
	// physics graph to preserve, so exporting a constraint-only template does not
	// require attaching a dummy animation. The plain rig writer stays the compact
	// path for an ordinary unanimated model.
	bool carries_physics = unnamed == 0 && (physics.present() || constraints.present());
	bool placed_model = !self.doc.model_transform.is_identity();
	String[] export_names = names;
	String[] generated_names;
	if (placed_model && unnamed > 0)
	{
		generated_names = alloc::new_array(mem, String, (sz)names.len);
		foreach (usz joint, joint_name : names)
		{
			generated_names[joint] = joint_name.len > 0
				? joint_name.copy(mem)
				: string::format(mem, "joint_%d", joint);
		}
		export_names = generated_names;
	}
	defer
	{
		foreach (generated : generated_names) generated.free(mem);
		if (generated_names.len > 0) alloc::free(mem, generated_names);
	}
	// The model itself, carried whole: the source copied to the destination and
	// the rig written into the copy the way Save writes it, so UVs, materials and
	// textures survive. Not for a model the user placed or one with secondary
	// motion — only the rebuilding writer below can say either — and not for a
	// source that will not take a skin in place; those fall through to it.
	AnimTemplate[] written_clips = animated ? clips : (AnimTemplate[]){};
	ExportMotionReport shaped = {};
	bool whole = !placed_model && !physics.present()
		&& self.export_whole_model(path, written_clips, motion, &shaped);

	PhysicalBodyWriteReport physical_bodies = {};
	if (whole)
	{
		// Written above.
	}
	else if (animated || carries_physics || placed_model)
	{
		if (catch fault error = export_rigged_animated_glb(
			mem, path, self.geometry, &skeleton, export_names, skin,
			animated ? clips : (AnimTemplate[]){}, name, SKIN_INFLUENCES,
			carries_physics ? physics : (RigPhysics){},
			carries_physics ? constraints : (ConstraintRig){},
			&physical_bodies, self.doc.model_transform, motion, &shaped))
		{
			self.@notice("could not write %s: %s", base_name(path), error);
			return;
		}
	}
	else if (catch fault error = rig::export_rigged_glb(
		mem, path, self.geometry, &skeleton, name, skin, names, SKIN_INFLUENCES))
	{
		self.@notice("could not write %s: %s", base_name(path), error);
		return;
	}

	// The file's own metadata, onto the file that now holds its skeleton. After the
	// write and not part of it — see `AppState.stamp_asset_metadata` for why the
	// writers are left alone. A failure costs a browser category and the clips'
	// blend settings, not the rig, so it is reported and the export still counts.
	if (!self.stamp_asset_metadata(path, animated ? clips : (AnimTemplate[]){}, clips_replaced: true))
	{
		self.@notice("wrote %s, but its metadata could not be stamped on", base_name(path));
	}

	// And the document beside it. This is the half glTF has no word for — reaches,
	// pins, the mirror plane, the paint — and without it the export reopens as
	// whatever its nodes say rather than as the rig that was exported. It is also
	// what makes `retarget_source` below true on the *next* run rather than only
	// on this one, since a sidecar beside a model is what raises `saves_in_place`.
	if (!self.save_rig_beside(path, model_transform_in_mesh: placed_model,
		stamped_clips: animated ? clips : (AnimTemplate[]){}, clips_replaced: true))
	{
		self.@notice("wrote %s, but its rig document could not be written beside it", base_name(path));
	}

	// Also on stdout with the full path: the panel has room for a file name and
	// the terminal is where someone runs `blender` on the answer.
	io::printfn("wrote %s (%d joints, %d clips, %d holding no skin)",
		path, skeleton.joints.len, animated ? clips.len : 0, idle);
	if (physical_bodies.requested > 0)
	{
		io::printfn("physical rig: %d/%d target hulls, %d vertices, %d triangles, %.2f KiB raw geometry",
			physical_bodies.written, physical_bodies.requested,
			physical_bodies.hull_vertices, physical_bodies.hull_triangles,
				(float)physical_bodies.payload_bytes / 1024.0f);
		if (physical_bodies.preserved_jiggle > 0)
		{
			io::printfn("physical rig: preserved %d existing secondary-motion bodies",
				physical_bodies.preserved_jiggle);
		}
	}

	// A whole copy is now where this rig lives, so Ctrl+S writes it rather than
	// making a copy of the model it was exported from. A rebuilt file is not
	// followed: it holds positions, normals and triangles only, and a later save
	// into it would keep working on a model that has lost its UVs and materials.
	if (whole)
	{
		self.retarget_source(path, placed_model);
		// The export wrote the resized positions, and it is the file followed now.
		self.mesh_resized = false;
	}
	String lossy = whole ? "" : " · no UVs/materials, so Ctrl+S keeps saving the original";

	// One line, four optional halves. The clip count is only worth printing when
	// there are clips, and the idle count only when there is one — a line that
	// always ends in "0 idle" is a line nobody reads. The physical bodies get a
	// half of their own rather than a line of their own: every constrained joint
	// asks for one, so on a rig fitted from the shipped humanoid the line saying
	// some were skipped would replace the one saying what was written.
	String bodies = "";
	if (physical_bodies.skipped > 0)
	{
		bodies = string::tformat(" · physical bodies: %d of %d, %d lacked usable weighted geometry",
			physical_bodies.written, physical_bodies.requested, physical_bodies.skipped);
	}
	else if (physical_bodies.preserved_jiggle > 0)
	{
		bodies = string::tformat(" · kept %d existing secondary-motion bodies",
			physical_bodies.preserved_jiggle);
	}
	if (animated)
	{
		self.@notice("wrote %s · %d joints, %d clips%s%s%s%s", base_name(path),
			skeleton.joints.len, clips.len, export_motion_words(motion, shaped),
			idle == 0 ? "" : " · some joints hold no skin", bodies, lossy);
	}
	else if (idle == 0)
	{
		self.@notice("wrote %s · %d joints%s%s", base_name(path), skeleton.joints.len, bodies, lossy);
	}
	else
	{
		self.@notice("wrote %s · %d joints, %d holding no skin%s%s", base_name(path),
			skeleton.joints.len, idle, bodies, lossy);
	}
}

<*
 Export by copying the opened model and writing the rig into the copy.

 The same writer Save uses, so what the model carried beyond its skin — UVs,
 materials, textures, morph targets — comes out the other side.

 @param clips : `The clips to write into it; empty writes none.`
 @return `False when there is no source file, or it would not take the skin; the caller writes the rebuilt file instead.`
*>
fn bool AppState.export_whole_model(&self, String path, AnimTemplate[] clips, ExportMotion motion = {},
	ExportMotionReport* report = null)
{
	if (self.source_path.len == 0 || !io::file::is_file(self.source_path)) return false;
	if (path != self.source_path && !copy_file(self.source_path, path)) return false;
	return self.write_rig_into_model(path, &clips, motion, report);
}

<*
 The notice's half about root motion and key reduction, or "" when neither ran.
*>
fn String export_motion_words(ExportMotion motion, ExportMotionReport report)
{
	String root = "";
	if (motion.root.mode == IN_PLACE && report.moved > 0)
	{
		root = string::tformat(" · %d in place", report.moved);
	}
	else if (motion.root.mode == ON_ROOT && report.moved > 0)
	{
		root = string::tformat(" · %d with travel on the root joint", report.moved);
	}
	if (motion.root.mode == ON_ROOT && report.no_root > 0)
	{
		root = string::tformat("%s · no root joint under the hips, travel left as authored", root);
	}
	String keys = "";
	if (motion.reduce != OFF && report.keys_before > 0)
	{
		keys = string::tformat(" · %d of %d keys written", report.keys_after, report.keys_before);
	}
	return string::tformat("%s%s", root, keys);
}

<*
 How many joints hold essentially none of the mesh.

 Each vertex is worth one unit however its row is scaled — the geodesic binder
 hands back unnormalised weights and the file's own arrive summing to one — so
 the row is normalised as it is read and a joint's share is measured against the
 whole. The threshold is `skinless_joints`': under one vertex's worth, so a small
 part on a dense mesh still counts as held.

 A measure rather than a simulation: the prune removes the weakest joint and
 measures again, since dropping one lifts its neighbour clear. This takes one pass
 and can therefore name a joint the prune would have kept. That is the right trade
 for a line in a notice, and the wrong one for deciding what to delete — which is
 why nothing is deleted.
*>
fn usz joints_holding_no_skin(float[] skin, usz vertices, usz joints)
{
	bool[] idle = skinless_joints(mem, skin, vertices, joints);
	defer alloc::free(mem, idle);
	usz count = 0;
	foreach (none : idle)
	{
		if (none) count++;
	}
	return count;
}

<*
 Writes the ticked clips and the skeleton they play on, and no model.

 What **Export rig** unticked produces: an animation pack rather than a rigged
 asset. The skeleton still goes in, because a clip addresses joints by name and
 a file carrying no joints is a file nothing can be played against — the rig is
 what is left out is the mesh and its skin, not the bones.

 No bind and no prune, which is the whole difference from `export_rig`: both
 exist to decide which joints hold skin, and there is no skin here. A joint that
 no clip touches is written anyway, because it is part of the skeleton the clips
 were authored against.

 @param destination : `Where to write. Empty derives the _rigged.glb name beside the source mesh.`
 @param clips : `Animations to write. Empty is refused — there would be nothing in the file.`
*>
fn void AppState.export_clips_only(&self, String destination, AnimTemplate[] clips, ExportMotion motion = {})
{
	if (clips.len == 0)
	{
		self.@notice("nothing to write — tick some animations, or turn Export rig back on");
		return;
	}
	if (self.doc.dots.len() == 0)
	{
		self.@notice("nothing to export — place some joints first");
		return;
	}
	if (destination.len == 0 && self.source_path.len == 0)
	{
		self.@notice("no mesh path to export beside");
		return;
	}

	RigView? opened = self.open_rig(mem);
	if (catch fault error = opened)
	{
		self.@notice("could not build a skeleton: %s", error);
		return;
	}
	RigView view = opened;
	defer view.free(mem);

	usz unnamed = 0;
	foreach (joint_name : view.names)
	{
		if (joint_name.len == 0) unnamed++;
	}
	if (unnamed > 0)
	{
		self.@notice("%d joints have no name — a clip cannot address them", unnamed);
		return;
	}

	String path = destination.len > 0
		? destination.copy(mem)
		: rigged_path(mem, self.source_path);
	defer path.free(mem);

	// Clips alone keep their authored keys, so root motion rewrites copies of them
	// and key reduction (a bake-time step) does not apply.
	AnimTemplate[] written = clips;
	ExportMotionReport shaped = {};
	if (motion.root.active())
	{
		written = alloc::new_array(mem, AnimTemplate, (sz)clips.len);
		foreach (usz i, clip : clips)
		{
			AnimTemplate moved;
			switch (clip_root_moved(mem, clip, &view.skeleton, view.names, motion.root, &moved))
			{
				case MOVED:
					written[i] = moved;
					shaped.moved++;
					continue;
				case NO_ROOT_JOINT: shaped.no_root++;
				default: shaped.no_travel++;
			}
			written[i] = clip_copy(mem, clip);
		}
	}
	defer if (motion.root.active())
	{
		foreach (&clip : written) clip.free(mem);
		alloc::free(mem, written);
	}

	if (catch fault error = export_animations_glb(mem, path, &view.skeleton, view.names, written))
	{
		self.@notice("could not write %s: %s", base_name(path), error);
		return;
	}

	io::printfn("wrote %s (%d joints, %d clips, no model)", path, view.skeleton.joints.len, clips.len);
	self.@notice("wrote %s · %d clips, no model%s%s", base_name(path), clips.len,
		export_motion_words({ .root = motion.root }, shaped),
		motion.reduce != OFF ? " · keys kept as authored (reduction applies to the model export)" : "");
}

// ---------------------------------------------------------------------------
// The session file (B7): the rig as it was when it was saved. The format and
// the validation are `core/session.c3`; these are the user-facing operations
// over it — saving from File > Save session and Ctrl+S, loading on the open that
// finds a session sitting beside the model.

<*
 Save: the rig into a model, and that model into agreement with the rig.

 	`Ctrl+S`

 Two writes, and the point of the pair is that the two files say one thing.
 `write_rig_into_model` rewrites the model's nodes and skin, so a viewer, a game
 engine or Blender opening the `.glb` sees the skeleton the user built.
 `save_rig_beside` writes `<stem>.crig.json` next to it, so crig reopening it
 sees the rest — dot ids, reaches, pins, the mirror plane, the pose, the paint.

 The document is **beside** the model rather than inside its `extras`, which is
 where it used to go as well. The paint layer alone is one entry per (vertex,
 dot) pair, so a painted humanoid was putting megabytes into the file the user
 ships, readable by nothing but crig and duplicating a sidecar that already held
 the identical bytes.

 **Never the file the user opened, until crig has made one of its own.** A model
 somebody else authored is copied to `<stem>_copy.glb` and the copy is what gets
 written, so a first save cannot cost anybody their source asset. From then on
 the copy *is* the document — `retarget_source` moves onto it, the HUD names it,
 and the next save writes it in place rather than making a copy of a copy. An
 export does the same thing with the file it wrote, which is the other way to end
 up owning one.

 So the file that changes on a Ctrl+S is: the one exported, else the one saved
 before, else a fresh copy beside the original.

 The sidecar is the destination rather than a fallback, and it is what a later
 open reads first — its existence beside a model is also what raises
 `saves_in_place` on that open. See `core/session.c3` and `adopt_source_rig`.
*>
fn void AppState.save_session(&self)
{
	if (self.source_path.len == 0)
	{
		self.@notice("no mesh path to save beside");
		return;
	}

	// Where this save is allowed to write. `saves_in_place` is the whole question:
	// crig writes over a file it produced and copies one it did not.
	String target = self.saves_in_place
		? self.source_path.copy(mem)
		: copy_path(mem, self.source_path);
	defer target.free(mem);

	bool copied = false;
	if (!self.saves_in_place && !io::file::is_file(target))
	{
		// A byte copy first, and only then the two writes. Both of them *edit* a
		// model — they grow its buffer and repoint its JSON — so there has to be a
		// model there to edit, and it has to be this one: the materials, the
		// textures and the UVs the rig is going onto are the original's.
		if (!copy_file(self.source_path, target))
		{
			self.@notice("could not write %s — saving beside the mesh instead", base_name(target));
			self.save_beside_mesh();
			return;
		}
		copied = true;
	}

	// Two halves, in this order, and the order is the point. The model is rewritten
	// first — its nodes and its skin become this rig, so anything that is not crig
	// sees what the user built. Then the document goes beside it, which is what
	// crig itself reads back.
	//
	// The model half is allowed to fail on its own. A `.gltf` with its buffer in a
	// sidecar `.bin`, or a mesh placed by a node transform, cannot take a skin
	// written in place — and neither is a reason to lose the rig, so the document
	// is still written and the notice says which happened.
	// The joints' limits ride in the model with the skin; a model that would
	// not take the skin gets them in the document instead, so they survive.
	self.notice_length = 0;
	bool into_model = self.write_rig_into_model(target);
	// Why the model was refused, said again in the closing notice that would
	// otherwise replace it.
	char[160] refused;
	String reason = into_model ? "" : (String)io::bprintf(refused[..], "%s", self.notice()) ?? "";

	// A resized model whose file would not take the new positions keeps nothing:
	// the document alone would reopen as joints the new size inside a mesh the old.
	if (!into_model && self.mesh_resized)
	{
		if (copied) (void)file::delete(target);
		self.@notice("not saved: %s would not take the resized mesh (%s) · export it instead",
			base_name(target), reason);
		return;
	}
	// The bound clips' own settings go with the save: the blend, loop and ground
	// glTF has no channel for ride in `extras.clips`, and stamping none removed them.
	AnimTemplate[] bound = self.bound_templates(mem);
	defer alloc::free(mem, bound);
	bool beside = self.save_rig_beside(target, limits: !into_model,
		model_transform_in_mesh: self.source_has_model_transform,
		stamped_clips: into_model ? bound : (AnimTemplate[]){}, clips_replaced: into_model);

	if (beside)
	{
		self.authored_dirty = false;
		String named = base_name(target).copy(mem);
		defer named.free(mem);

		// Before the notice, because the notice names the file this document now
		// belongs to and that is what `retarget_source` makes true.
		self.retarget_source(target, self.source_has_model_transform);
		// The file the document now follows holds the resized positions.
		self.mesh_resized = false;

		// The model just gained this character's animations; if it sits in a
		// library, the browser is re-read so they appear without a restart. Only
		// when the model itself was written — a save that fell back to the sidecar
		// put nothing new in any .glb the browser reads.
		if (into_model) self.reindex_saved_model(target);
		// The "Current file" group follows the model wherever the save put it — a copy
		// aside retargets `source_path` — and reflects a clip a delete-then-save removed.
		self.reindex_current_model();
		self.mark_saved();

		if (!into_model && reason.len > 0)
		{
			self.@notice("not saved into %s: %s", named, reason);
			return;
		}
		self.@notice(into_model
			? (copied ? "saved into %s · a copy; your original is untouched" : "saved into %s · rig and skin")
			: "saved beside %s · the model would not take the skin", named);
		return;
	}

	// The document did not land. If a copy was made for it, it is a duplicate of
	// the original with nothing added — worse than nothing, since it would be
	// adopted on the next open as a model with no rig in it.
	if (copied) (void)file::delete(target);
	self.save_beside_mesh();
}

<*
 The document as `<mesh-stem>.crig.json`, beside the mesh crig opened.

 The last resort, and the difference from `save_rig_beside` is *which* file it
 writes next to: that one goes beside the model this save produced, this one
 beside the model that was opened. Reached when there is no produced model to sit
 beside — an empty rig, or a copy that could not be made. See `save_session`.
*>
fn void AppState.save_beside_mesh(&self)
{
	// Beside a mesh the old size, a resized rig's document would reopen wrong.
	if (self.mesh_resized)
	{
		self.@notice("not saved: the resized mesh could not be written · export it instead");
		return;
	}

	String path = session_path(mem, self.source_path);
	defer path.free(mem);

	AnimTemplate[] clips = self.kept_authored_clips(mem);
	defer if (clips.len > 0) alloc::free(mem, clips);
	// With the limits: no model was written for them to live in.
	if (catch fault error = write_session(path, &self.doc, self.source_path, clips,
		limits: true, model_transform_in_mesh: self.source_has_model_transform))
	{
		self.@notice("could not save %s: %s", base_name(path), error);
		return;
	}

	// After the write, not before: the recent list is a list of projects that
	// exist, and one whose session could not be written is not yet one.
	self.remember_project(self.source_path);
	self.authored_dirty = false;
	self.mark_saved();

	io::printfn("saved %s (%d joints, %d bones)", path, self.doc.dots.len(), self.doc.edges.len());

	self.@notice(self.doc.dots.len() == 0
		? "saved %s · an empty rig writes nothing into the model"
		: "saved %s · beside the mesh you opened", base_name(path));
}

fn void AppState.restore_local_export_geometry(&self, ProjectTransform placement)
{
	if (self.geometry.positions.len == 0 || placement.is_identity()) return;

	Vec3[] positions = alloc::new_array(mem, Vec3, (sz)self.geometry.positions.len);
	foreach (usz i, position : self.geometry.positions)
	{
		positions[i] = placement.inverse_point(position);
	}
	Vec3[] normals;
	if (self.geometry.normals.len > 0)
	{
		normals = alloc::new_array(mem, Vec3, (sz)self.geometry.normals.len);
		foreach (usz i, normal : self.geometry.normals)
		{
			Vec3 local = placement.inverse_direction(normal);
			normals[i] = local.length_sq() > 1.0e-12f ? local.normalize() : local;
		}
	}
	uint[] indices = alloc::new_array(mem, uint, (sz)self.geometry.indices.len);
	foreach (usz i, index : self.geometry.indices) indices[i] = index;

	self.replace_geometry({
		.positions = positions,
		.normals = normals,
		.indices = indices,
	});
}

<*
 Reads the session back in, replacing the document wholesale.

 The undo stack is cleared rather than kept: its edits replay against the
 document they were recorded from, and after a load the ids they name may mean
 other dots entirely. Undo across a load is not a smaller history, it is a
 wrong one. The selection goes with it, for the same reason.
*>
fn void AppState.load_session(&self)
{
	if (self.source_path.len == 0)
	{
		self.@notice("no mesh path to load beside");
		return;
	}

	String path = session_path(mem, self.source_path);
	defer path.free(mem);

	// The mesh's own middle stands in when the file names no symmetry plane,
	// the same guess `new_app` makes for a fresh document.
	ProjectSession? loaded = read_project_session(mem, path, self.geometry.bounds().center().x);
	if (catch fault error = loaded)
	{
		if (error == SESSION_IO)
		{
			self.@notice("no saved project at %s", base_name(path));
		}
		else
		{
			self.@notice("%s is not a crig project file", base_name(path));
		}
		return;
	}
	if (loaded.model_transform_in_mesh && !self.source_has_model_transform)
	{
		self.restore_local_export_geometry(loaded.doc.model_transform);
	}
	// The running palette and pose draft belong to the document being replaced.
	// Close them while its rig and authored pack are still valid.
	LibraryRefs refs = self.remember_library_refs();
	defer refs.free();
	refs.playing = false;
	self.stop_animation();
	self.stop_deformed_display();
	self.free_timeline_tracks();
	self.editing = NO_ANIM;
	self.doc.free();
	self.doc = loaded.doc;
	self.replace_authored_clips(loaded.authored);
	self.authored_dirty = false;
	self.source_has_model_transform = loaded.model_transform_in_mesh;

	self.undo_stack.clear();
	self.select(0);

	self.mark_rig_stale();
	self.restore_library_refs(&refs);
	self.refresh_ui();
	// stderr rather than stdout: an MCP server built out of these sources may
	// have JSON-RPC on stdout, where one stray line is a parse error at the far
	// end. A terminal shows both streams, so the full path is still readable.
	io::eprintfn("loaded %s (%d joints, %d bones)", path, self.doc.dots.len(), self.doc.edges.len());
	self.@notice("loaded %s · %d joints, %d bones", base_name(path), self.doc.dots.len(), self.doc.edges.len());
}
