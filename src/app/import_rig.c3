<*
 Taking a rig that already exists in the file, instead of building one.

 crig's ordinary job is to put a skeleton on a mesh that has none. This is the
 other case: the mesh arrives already rigged and already weighted — from Blender,
 from Mixamo, from crig's own export — and the only thing wanted is animation.
 Re-deriving the rig would answer a question nobody asked and lose the answer
 that came with the file.

 So two things are read out of the .glb and used as they stand. The joints become
 dots at their exact world positions, with the file's own names and its own
 parent links; nothing is fitted, nothing is snapped to the voxel grid. And the
 file's `JOINTS_n` / `WEIGHTS_n` become the binding, so the shoulder somebody
 spent an afternoon painting is the shoulder that deforms on screen and the one
 that gets written back out.

 **The weights are keyed by joint name, not by index.** Joint indices are the
 output of `build_skeleton`'s walk and shift whenever a dot is added or the root
 moves; names survive all of it. That is also what lets an imported binding come
 back after a reopen: the session stores a flag, not seven megabytes of weights,
 and the columns are matched to the rig again from the file next to it.

 **It is all or nothing.** The imported columns are used only when they cover the
 rig exactly — same count, every joint named by exactly one column. Anything else
 falls back to `bind_geodesic` for the whole mesh. A rig bound partly from the
 file and partly from the binder would have a seam nobody could see and nobody
 could explain, which is worse than either half.

 That rule is also the way back, and the only one — nothing in the interface says
 "stop using these weights". Adding or deleting a dot means the painted columns
 no longer describe this rig, the cover fails, and crig binds the whole mesh
 itself from that edit onward — said once in a notice, and Ctrl+Z brings them
 back. Moving or renaming a dot does not: the columns follow the dot, not its
 name, and nobody repainted anything by dragging or renaming a joint.
*>
module crig;

import rig;
import gltf;
import gltf_edit;
import std::io;
import std::io::file;
import std::math;
import std::math::vector;



<*
 A binding read out of the mesh's own file, in the file's joint order.

 Dense, the shape `bind_geodesic` returns: one row per vertex, one column per
 joint. `names` is what the columns are addressed by — see the module note on why
 that is a name and not an index.

 Owned by the state that holds it. Empty `weights` means nothing was imported,
 which is the state every hand-built rig is in.
*>
struct ImportedSkin
{
	float[] weights;
	String[] names;
	usz vertices;
	usz columns;

	// The dot each column became, so a rename keeps the column. Empty until the
	// columns are matched to dots, and then the join is by name.
	uint[] dot_ids;
}

fn void ImportedSkin.free(&self, Allocator allocator)
{
	foreach (name : self.names)
	{
		if (name.len > 0) alloc::free(allocator, name.ptr);
	}
	if (self.names.len > 0) alloc::free(allocator, self.names);
	if (self.dot_ids.len > 0) alloc::free(allocator, self.dot_ids);
	if (self.weights.len > 0) alloc::free(allocator, self.weights);
	*self = {};
}

fn bool ImportedSkin.present(&self) => self.weights.len > 0 && self.columns > 0;

<*
 Tie each column to the dot of the same name, so later renames keep it.

 All or nothing, like the cover itself: a column whose name matches no dot, or
 more than one, leaves the join by name.
*>
fn void ImportedSkin.bind_to_dots(&self, RigDocument* doc)
{
	if (self.dot_ids.len > 0) alloc::free(mem, self.dot_ids);
	self.dot_ids = {};
	if (!self.present()) return;

	uint[] ids = alloc::new_array(mem, uint, (sz)self.columns);
	foreach (usz c, name : self.names)
	{
		usz found = 0;
		foreach (dot : doc.dots.array_view())
		{
			if (name.len == 0 || dot.name != name) continue;
			ids[c] = dot.id;
			found++;
		}
		if (found != 1)
		{
			alloc::free(mem, ids);
			return;
		}
	}
	self.dot_ids = ids;
}

<*
 Fill an empty `doc.plan` from the model's own `extras.plan`.

 A sidecar written before plans were recorded (or by hand) has no "plan", yet the
 glb may carry the tag — and the next Save hands `doc.plan` to `reskin_glb`, which
 REMOVES the member when the value is empty. Adopting it here keeps the tag alive.
 A plan the session already declared wins.
*>
fn void AppState.adopt_source_plan(&self)
{
	if (self.doc.plan.len > 0 || self.source_path.len == 0) return;
	gltf::GltfStream? opened = gltf::open(self.source_path, mem);
	if (catch opened) return;
	gltf::GltfStream stream = opened;
	defer stream.close();
	if (try String declared = stream.gltf.extras.get(PACK_KEY_PLAN))
	{
		String plan = declared.trim().to_lower_copy(mem);
		defer alloc::free(mem, plan.ptr);
		if (plan.len > 0) self.doc.set_plan(plan);
	}
}

<*
 Settle where this model's rig comes from, in the one order that is defensible.

 The session beside the mesh wins, and it is the only place a rig document is
 kept. crig used to stamp the whole document into the model's own `extras` as
 well; that is gone, because the document is mostly the **paint layer** — one
 entry per (vertex, dot) pair — and a properly painted humanoid put megabytes of
 crig's own JSON inside the file the user ships. The sidecar always held the same
 bytes, so nothing was lost by dropping the copy.

 Failing that, the file's own nodes, when it has a skin. A mesh that arrives
 already rigged from somewhere else has an answer in it, and an empty document
 over a model that already has a skeleton throws that answer away for nothing.

 Failing both, nothing: a bare mesh waiting to be rigged.

 Called from both places a model becomes the open one — `load_mesh` and the
 command line — because the order above is a decision and not two.
*>
fn void AppState.adopt_source_rig(&self)
{
	if (self.source_path.len == 0) return;

	// The loaded model's own clips become the "Current file" browser group, whichever
	// tier below adopts the rig — a defer so every exit path indexes them once.
	defer self.reindex_current_model();

	String session = session_path(mem, self.source_path);
	defer session.free(mem);

	if (io::file::is_file(session))
	{
		self.load_session();
		// The session stores that the weights came from the file, never the
		// weights themselves — see `reload_imported_skin`. The joints' limits
		// live in the model too, since session 18: what it carries replaces
		// whatever the session had.
		if (self.doc.skin_from_file) self.reload_imported_skin();
		(void)self.adopt_model_limits(recorded: false);
		self.adopt_source_plan();

		// A model with a sidecar beside it is a model crig has saved before, so
		// saving may write it again rather than copying it aside — see
		// `AppState.saves_in_place`. This is the only place the flag is raised on an
		// open, and the sidecar's existence is what raises it: the document lives
		// there, so a file that has one is a file crig owns.
		self.saves_in_place = true;
		return;
	}

	if (self.source_carries_rig())
	{
		self.import_rig_from_source();
		return;
	}

	// Tier three, and the only one that used to happen in silence. A mesh with no
	// skin lands here with an empty document, no notice and nothing on screen
	// saying what to do next — and the one route to a body plan was a cell in a
	// pane the user may not have open. The panel this raises is that route, said
	// out loud. See `AppRoot.update`, which is what turns the flag into a panel.
	self.wants_rig_prompt = self.has_mesh();
}

<*
 Whether the open mesh's file carries a rig to import.

 Cheap enough to ask on every open: the header of a .glb names its skins, and
 nothing here loads a buffer.
*>
fn bool AppState.source_carries_rig(&self)
{
	if (self.source_path.len == 0) return false;

	gltf::GltfStream? stream = gltf::open(self.source_path, mem);
	if (catch stream) return false;
	defer stream.close();

	return stream.gltf.skins.len() > 0;
}

<*
 Replace the document with the rig the mesh's own file carries, and take its
 weights with it.

 	`if (app.import_rig_from_source()) app.refresh_ui();`

 One undo entry for the whole thing, the same bargain `apply_preset` strikes:
 clearing whatever was there and placing what the file says are one Ctrl+Z, so
 trying an import costs nothing.

 The dots land where the file puts them — **no fit, no voxel snap**. That is the
 difference between this and taking a body plan out of the library, which
 normalizes a rig against one mesh's bounds and re-places it against another's.
 A plan is a shape being carried onto a stranger; this is the rig that was built
 for this mesh, and moving it a millimetre would be moving it away from where the
 weights expect it.

 The weights are separate and may fail on their own. When they do the rig still
 arrives and `bind_geodesic` binds it, which is exactly the state a rig imported
 before this existed would have been in.

 @return `False when there was nothing to import; the document is untouched.`
*>
fn bool AppState.import_rig_from_source(&self)
{
	if (self.source_path.len == 0 || !self.has_mesh()) return false;

	gltf::GltfStream? opened = gltf::open(self.source_path, mem);
	if (catch opened) return false;
	gltf::GltfStream stream = opened;
	defer stream.close();

	if (catch stream.load_all_buffers()) return false;

	// Matched onto a body plan for its names, and `keep_unmatched` so that nothing
	// is dropped for the naming: a joint the plan cannot name is still a column of
	// this file's weights, and folding it away would leave that column with nowhere
	// to go. So the joints the plan covers take its words and the rest keep the
	// file's own spelling.
	//
	// The names are the point. A clip out of this same file is read through these
	// very plans by `pack_for_file`, and a rig that kept the file's spelling could
	// never be played by one — the two readers would be naming one skeleton two
	// ways, and every clip in the library would grey out against it.
	String[] names;
	usz[] joint_nodes;
	AnimImportReport named;
	rig::Skeleton? read = read_rest_skeleton(
		mem, &stream, &names,
		options: { .plans = self.reference_plans, .keep_unmatched = true },
		joint_nodes: &joint_nodes,
		report: &named);
	if (catch read) return false;

	rig::Skeleton rest = read;
	defer
	{
		rest.free(mem);
		foreach (name : names)
		{
			if (name.len > 0) alloc::free(mem, name.ptr);
		}
		if (names.len > 0) alloc::free(mem, names);
		if (joint_nodes.len > 0) alloc::free(mem, joint_nodes);
	}

	usz joints = rest.len();
	if (joints == 0) return false;

	// Read before the document is touched, so a skin that will not convert costs
	// the rig nothing — and so the failure notice below can say which half failed.
	ImportedSkin taken = self.read_imported_skin(&stream, names, joint_nodes);

	usz replaced = self.clear_rig_recorded();

	uint[] ids = alloc::new_array(mem, uint, (sz)joints);
	defer alloc::free(mem, ids);

	usz bones = 0;
	for (usz j = 0; j < joints; j++)
	{
		ids[j] = self.add_recorded(rest.joints[j], names[j]);

		int parent = rest.parents[j];
		if (parent < 0) continue;
		// Safe to index: `read_rest_skeleton` emits parents before children, so a
		// parent's id is already in the array by the time its child reads it.
		self.connect_recorded(ids[(usz)parent], ids[j]);
		bones++;
	}

	// Whatever the naming above matched, and "" when it matched nothing. The tag
	// and the dot names have to be the same claim: the library greys a clip whose
	// pack declares a plan this document does not, and a rig wearing a plan's words
	// while declaring none would be offered clips it could take and refused them.
	//
	// "" is the honest answer for a rig that matched nothing — a plan is two thirds
	// coverage or it is not one at all, see `JointMatch.usable` — and it leaves the
	// dots under the file's own spelling, which is where this stood before any of
	// the plans existed.
	self.doc.set_plan(named.plan_tag);

	// Whatever the file says the physics does, onto the dots its joints just
	// became — no fit and no rescaling, for the reason the positions get none:
	// this is the rig that was built for this mesh. Inside the same undo group,
	// so trying an import still costs one Ctrl+Z.
	RigPhysics physics = read_rig_physics(mem, &stream, joint_nodes);
	defer physics.free(mem);
	usz dynamic = self.adopt_physics_recorded(physics, ids);

	// And its joints' limits, the same way: a model crig saved or exported
	// carries them as KHR constraint joints, and this is a model with no
	// document beside it to carry them any other way.
	usz limited = self.adopt_model_limits(recorded: true);

	// The file's own clips that reach this rig: the animations built for this mesh,
	// bound so opening it plays them at once rather than leaving them embedded and
	// invisible (and, since Save writes only bound clips, silently dropped). A clip
	// whose channels miss every imported joint is skipped. Inside this undo group,
	// so one Ctrl+Z takes the rig and its bindings together. `source_path` is the
	// file these joints came from, which is what a binding resolves against.
	usz bound_clips = 0;
	foreach (usz i, anim : stream.gltf.animations)
	{
		if (!clip_drives_joints(anim, joint_nodes)) continue;
		String label = clip_label(mem, &stream, anim, i);
		defer label.free(mem);
		if (self.bind_clip_recorded(self.source_path, label)) bound_clips++;
	}

	self.undo_stack.commit();

	self.imported_skin.free(mem);
	self.imported_skin = taken;
	if (taken.columns == joints)
	{
		self.imported_skin.dot_ids = alloc::new_array(mem, uint, (sz)joints);
		self.imported_skin.dot_ids[..] = ids[..];
	}
	self.fresh_imported_skin();

	// Whatever the file painted, because this path is only reached for a file that
	// carries no crig document — see `adopt_source_rig`. Its weights are the only
	// account of this mesh anyone has given, so they are the one to use.
	self.doc.skin_from_file = taken.present();

	self.mark_rig_stale();
	self.select(ids[0]);

	String limits = limited > 0 ? string::tformat(" · %d joint limits", limited) : "";
	String clips_note = bound_clips > 0
		? string::tformat(" · bound %d clip%s", bound_clips, bound_clips == 1 ? "" : "s")
		: "";
	if (taken.present())
	{
		self.@notice("imported %d joints, %d bones and the file's own weights%s%s%s%s",
			joints, bones,
			dynamic > 0 ? " · and its physics" : "", limits, clips_note,
			replaced > 0 ? " · replaced the rig that was here" : "");
	}
	else
	{
		self.@notice("imported %d joints and %d bones%s%s%s · the file's weights would not fit this mesh, binding them here",
			joints, bones, dynamic > 0 ? " and its physics" : "", limits, clips_note);
	}
	return true;
}

// Whether any of a clip's channels drives one of the imported joints. The test
// for auto-binding a file's own clip: the clip reaches this rig iff a channel
// targets a source node that just became a bone. Node indices, not names, so it
// is exact and reads no buffers — a clip built for a second skeleton or a prop
// in the same file misses every joint and is left unbound.
fn bool clip_drives_joints(gltf::Animation anim, usz[] joint_nodes) @local
{
	foreach (channel : anim.channels)
	{
		foreach (node : joint_nodes)
		{
			if ((usz)channel.target.node == node) return true;
		}
	}
	return false;
}

<*
 The joints' rotation limits the model carries, onto the document's dots.

 	`usz landed = app.adopt_model_limits(recorded: false);`

 A model crig saved or exported holds its limits as the KHR constraint joints
 `write_rig_constraints` and the in-place writer both produce, and since
 session 18 that is the only place they are kept. Read back as a pack and
 matched by the name each dot's joint is written under — `model_joint_name`,
 so an unnamed dot finds its `joint_<n>` — exactly as they were written: the
 axes as they are, a fork's named child as the dot it became, an adjusted
 frame as the same adjustment off this rig's own derived frame. No fit and no
 facing: this is the rig the rows were written against.

 **The model's tables replace the document's.** A session from before 18, or
 one written beside a model that could not take a skin, carries tables of its
 own; they stand only while the model says nothing.

 @param recorded : `Through the recorded setter, inside the caller's open undo group — the import's way; false writes the document directly, for an open, whose history starts empty.`
 @return `How many tables landed. Zero for a model with none, or none that could be read.`
*>
fn usz AppState.adopt_model_limits(&self, bool recorded)
{
	if (self.source_path.len == 0 || self.doc.dots.len() == 0) return 0;

	AnimPack? read = read_pack(mem, self.source_path);
	if (catch read) return 0;
	AnimPack pack = read;
	defer pack.free(mem);

	usz exact = 0;
	foreach (row : pack.constraints.joints) if (row.status == EXACT) exact++;
	if (exact == 0) return 0;

	RigView? opened = self.open_rig(mem);
	if (catch opened) return 0;
	RigView view = opened;
	defer view.free(mem);

	// The dot each of the model's joints is, by the name it was written under.
	// A name the rig carries twice is nobody's, as everywhere names are the join.
	int[] dot_joint = alloc::new_array(mem, int, (sz)pack.joint_names.len);
	defer alloc::free(mem, dot_joint);
	foreach (usz k, name : pack.joint_names)
	{
		dot_joint[k] = -1;
		usz seen = 0;
		for (usz j = 0; j < view.len(); j++)
		{
			String written = model_joint_name(mem, view.names[j], j);
			defer alloc::free(mem, written.ptr);
			if (written != name) continue;
			dot_joint[k] = (int)j;
			seen++;
		}
		if (seen > 1) dot_joint[k] = -1;
	}

	if (!recorded) self.doc.rotation_limits.clear();

	usz landed = 0;
	foreach (usz k, row : pack.constraints.joints)
	{
		if (row.status != EXACT || dot_joint[k] < 0) continue;
		uint dot = view.dot_ids[(usz)dot_joint[k]];

		JointRotationLimits limits = unconstrained_rotation(dot);
		limits.constrained = true;
		limits.axes = row.axes;
		if (row.frame_intent.uses_primary_child())
		{
			if (row.primary_child < 0 || (usz)row.primary_child >= dot_joint.len) continue;
			int child = dot_joint[(usz)row.primary_child];
			if (child < 0) continue;
			limits.primary_child = view.dot_ids[(usz)child];
		}
		if (row.frame_intent.has_adjustment())
		{
			JointLimitFrame base = joint_limit_frame(&view.skeleton, view.dot_ids, limits);
			if (!base.usable()) continue;
			limits.has_saved_frame = true;
			limits.saved_frame = base.rotation.mul(row.frame_adjustment).normalize();
		}

		bool taken = recorded
			? self.set_rotation_limits_recorded(dot, limits)
			: self.doc.set_rotation_limits(dot, limits);
		if (taken) landed++;
	}
	return landed;
}

<*
 Put a file's physics onto the open document, one recorded edit per chain and
 per capsule.

 	`usz landed = app.adopt_physics_recorded(wire, ids);`

 The last step of an import: the file spoke in joints, the caller has just turned
 those joints into dots, and this is where the two meet. The file's bones are
 folded into chains by `adopt_bones_recorded`, so a tail the file states bone by
 bone lands as the one chain it is. Recorded rather than written straight in,
 and **not committed**, so the physics lands inside whatever undo group the
 import already opened — one Ctrl+Z takes the whole file back, tail and all.

 @param joint_dots : `The dot each joint became. An entry naming a joint past its end is dropped, which is what a file describing more bones than were adopted comes to.`
 @return `How many entries landed.`
*>
fn usz AppState.adopt_physics_recorded(&self, RigPhysics physics, uint[] joint_dots)
{
	usz landed = 0;

	if (physics.joints.len > 0)
	{
		JiggleSpec[] bones = alloc::new_array(mem, JiggleSpec, (sz)physics.joints.len);
		defer alloc::free(mem, bones);
		usz gathered = 0;
		foreach (spec : physics.joints)
		{
			if (spec.joint >= joint_dots.len) continue;
			bones[gathered++] = { .dot_id = joint_dots[spec.joint], .params = spec.params };
		}
		landed += self.adopt_bones_recorded(bones[:gathered]);
	}
	foreach (spec : physics.colliders)
	{
		if (spec.joint >= joint_dots.len) continue;
		if (self.set_collider_recorded(joint_dots[spec.joint], spec.radius)) landed++;
	}

	return landed;
}

<*
 Re-read the weights for a rig that is already in the document, without touching
 the rig.

 What a reopened session needs: the dots came back out of `<stem>.rigsmith.json`,
 which stores the flag and not the seven megabytes, so the columns have to be
 found again in the file beside it. The names are the join, and if they no longer
 line up the flag is cleared rather than left claiming a binding that is not
 there.
*>
fn void AppState.reload_imported_skin(&self)
{
	self.imported_skin.free(mem);
	if (self.source_path.len == 0 || !self.has_mesh())
	{
		self.doc.skin_from_file = false;
		return;
	}

	gltf::GltfStream? opened = gltf::open(self.source_path, mem);
	if (catch opened)
	{
		self.doc.skin_from_file = false;
		return;
	}
	gltf::GltfStream stream = opened;
	defer stream.close();

	if (catch stream.load_all_buffers())
	{
		self.doc.skin_from_file = false;
		return;
	}

	// The same naming `import_rig_from_source` used, because the names are the join
	// this re-read depends on: read the file's own spelling here and the dots that
	// came back out of the session — wearing a plan's words — would match none of
	// it, and a binding that is really there would be dropped as missing.
	String[] names;
	usz[] joint_nodes;
	rig::Skeleton? read = read_rest_skeleton(
		mem, &stream, &names,
		options: { .plans = self.reference_plans, .keep_unmatched = true },
		joint_nodes: &joint_nodes);
	if (catch read)
	{
		self.doc.skin_from_file = false;
		return;
	}

	rig::Skeleton rest = read;
	defer
	{
		rest.free(mem);
		foreach (name : names)
		{
			if (name.len > 0) alloc::free(mem, name.ptr);
		}
		if (names.len > 0) alloc::free(mem, names);
		if (joint_nodes.len > 0) alloc::free(mem, joint_nodes);
	}

	self.imported_skin = self.read_imported_skin(&stream, names, joint_nodes);
	self.imported_skin.bind_to_dots(&self.doc);
	self.fresh_imported_skin();
	self.doc.skin_from_file = self.imported_skin.present();
	self.mark_rig_stale();
}

<*
 The file's skin, with its columns moved into the order of the joints
 `read_rest_skeleton` produced and its rows normalized.

 Two things can go wrong and both come back as an empty result rather than a
 fault, because both mean the same thing to every caller — bind this mesh the
 ordinary way:

 - the walk that read the weights and the walk that read the positions disagree
   about how many vertices this mesh has, which is the guard `SourceSkin`
   describes;
 - a column of the file's weights belongs to a node the skeleton read dropped,
   and that column carries weight. Losing it would thin the vertices it holds
   and leave the rest to be scaled back up by the normalize below, which reads
   on screen as a limb that has quietly gone slack.

 @param names : `One per joint, as read_rest_skeleton returned them; copied.`
 @param joint_nodes : `The source node per joint, from the same call.`
*>
fn ImportedSkin AppState.read_imported_skin(
	&self,
	gltf::GltfStream* stream,
	String[] names,
	usz[] joint_nodes)
{
	rig::SourceSkin? read = rig::skin_from_gltf(mem, stream);
	if (catch read) return {};

	rig::SourceSkin source = read;
	defer source.free(mem);

	usz joints = joint_nodes.len;
	if (joints == 0 || joints != names.len) return {};
	if (source.vertices != self.geometry.positions.len) return {};

	// Which joint each of the file's columns feeds, or -1 for one the skeleton
	// read did not keep.
	int[] destination = alloc::new_array(mem, int, (sz)source.columns);
	defer alloc::free(mem, destination);

	for (usz c = 0; c < source.columns; c++)
	{
		destination[c] = -1;
		for (usz j = 0; j < joints; j++)
		{
			if (joint_nodes[j] != (usz)source.nodes[c]) continue;
			destination[c] = (int)j;
			break;
		}
	}

	for (usz c = 0; c < source.columns; c++)
	{
		if (destination[c] >= 0) continue;
		for (usz v = 0; v < source.vertices; v++)
		{
			if (source.weights[v * source.columns + c] != 0.0f) return {};
		}
	}

	ImportedSkin out = {
		.weights = alloc::new_array(mem, float, (sz)(source.vertices * joints)),
		.names = alloc::new_array(mem, String, (sz)joints),
		.vertices = source.vertices,
		.columns = joints,
	};
	foreach (usz j, name : names) out.names[j] = name.copy(mem);

	for (usz v = 0; v < source.vertices; v++)
	{
		usz from = v * source.columns;
		usz to = v * joints;

		float sum = 0.0f;
		for (usz c = 0; c < source.columns; c++)
		{
			int j = destination[c];
			if (j < 0) continue;
			float weight = source.weights[from + c];
			out.weights[to + (usz)j] = weight;
			sum += weight;
		}

		// glTF asks for rows that sum to one and does not guarantee it: a file
		// written with quantized weights is a fraction out on most vertices, and
		// skinning a vertex with a row summing to 0.99 shrinks it toward the
		// origin by a hundredth of its distance from it.
		if (sum <= 0.0f || sum == 1.0f) continue;
		float scale = 1.0f / sum;
		for (usz j = 0; j < joints; j++) out.weights[to + j] *= scale;
	}

	return out;
}

<*
 How many joints a vertex may ride, in the preview and in every file crig
 writes.

 Named here beside `bind_dense` because the two have to agree: the preview
 sparsifies the dense matrix itself, the exporter sparsifies it again on the way
 into the file, and a preview keeping four influences where the file keeps two
 shows a shoulder that does not exist anywhere else. Four is glTF's own
 `JOINTS_0` width and what every engine handles without a second attribute set.
*>
const uint SKIN_INFLUENCES = 4;

<*
 The dense weight matrix for this rig: the file's, when it covers the rig, and
 the binder's otherwise.

 The one place either answer is chosen. Both the preview and the exporter come
 through here, which is the whole point — a preview bound one way and a file
 written the other is the defect this consolidation exists to prevent, and it is
 invisible until the file is opened somewhere else.

 The caller owns the returned array.

 @param view : `Whose joint order the columns come back in.`
 @param painted : `False for the base underneath the hand corrections. Only a caller solving for a correction wants this — everything that displays or writes weights wants what the user sees, which is the default.`
*>
fn float[] AppState.bind_dense(&self, Allocator allocator, RigView* view, bool painted = true)
{
	// Painted over on the way out whichever answer was chosen — a correction is a
	// correction to whatever is underneath it, and a rig whose weights came from a
	// file is exactly the case where somebody has something to fix.
	if (self.doc.skin_from_file)
	{
		float[] taken = self.imported_dense(allocator, view);
		if (taken.len == 0) self.warn_imported_skin_replaced();
		if (taken.len > 0)
		{
			self.imported_skin_covered = true;
			// Nothing was decided: these weights were painted somewhere else, so
			// no piece of this mesh rides a bone by crig's choosing. Blank rather
			// than left alone, or the pane would go on showing the reasons the
			// binder gave before the file was adopted.
			self.blank_shell_riders();
			self.riders_stale = false;
			// A file's weights are the file's, with one exception: a vertex may not
			// hold a share of a sibling chain (a finger of the next finger). Files
			// from other tools often blend them, and the mesh then shows a wedge
			// between two fingers whenever one bends. The binder's own rule, so
			// both branches answer alike; under the paint, like the binder's.
			rig::isolate_chains(allocator, taken, view.skeleton.parents);
			if (painted)
			{
				paint_over(taken, view.len(), view.paint);
				// Over imported weights too, unlike the sharpening below: what an
				// artist painted elsewhere is ground truth about the *blend*, and a
				// pin is the user saying this vertex is not part of any blend. The
				// one layer that overrules a file, and it does so having been asked.
				pin_over(taken, view.len(), view.pins);
			}
			return taken;
		}
	}

	// App-owned, and refilled here rather than by the caller: this is called with
	// whatever allocator the caller is building into — a temporary one, twice in a
	// frame — while the answer outlives all of them. See `blank_shell_riders`.
	int[] riders = self.blank_shell_riders();

	float[] bound = rig::bind_geodesic(allocator, &self.voxels, self.geometry.positions,
		view.skeleton.joints, view.skeleton.parents, &self.shells,
		view.attachments, riders, reaches: view.reaches);
	self.riders_stale = false;

	// The binder's own branch only. Imported columns are what an artist painted
	// somewhere else, and sharpening those would be crig overruling a bind it did
	// not make — the one thing the import exists to preserve.
	//
	// Before the paint and inside the *unpainted* answer too, so the cached base
	// carries it: a correction is a correction to what the user can see, and
	// `paint_share` solves against this base. Changing it is therefore a
	// `mark_rig_stale`, never a `mark_paint_stale`.
	sharpen_weights(bound, self.doc.sharpness);
	if (painted)
	{
		paint_over(bound, view.len(), view.paint);

		// After the corrections and outside the *unpainted* answer, which is the
		// mirror of the sharpening above: the cached base has to stay pin-free so
		// `paint_share` keeps solving against the weights a correction is a
		// correction *to*. A base that already carried the pins would report a
		// pinned vertex as needing no correction at all.
		pin_over(bound, view.len(), view.pins);
	}
	return bound;
}

// A freshly read imported skin has not covered anything or been warned about.
fn void AppState.fresh_imported_skin(&self)
{
	self.imported_skin_covered = false;
	self.imported_skin_warned = false;
}

<*
 Say once that the file's own weights have stopped covering the rig.

 Only after they have covered it: a session that reopens already past that
 point has nothing new to be told.
*>
fn void AppState.warn_imported_skin_replaced(&self)
{
	if (!self.imported_skin_covered || self.imported_skin_warned) return;
	self.imported_skin_warned = true;
	self.@notice("This replaces the model's own skin weights with crig's automatic weights · Ctrl+Z brings them back");
}

<*
 The imported columns in this view's joint order, or empty when they do not
 cover it exactly.

 Exactly, meaning a one-to-one match: as many columns as joints, every joint
 claimed by a column — by its dot once the columns are tied to dots, by name
 before — and no column claimed twice. A rig with a dot added since the import
 fails the count; a dot deleted and another added fails the lookup; two dots
 sharing a name fail the second claim. All three mean the same thing — these weights were
 painted for a different rig — and all three fall back to the binder.

 The caller owns the returned array.
*>
fn float[] AppState.imported_dense(&self, Allocator allocator, RigView* view)
{
	if (!self.imported_skin.present()) return {};

	usz joints = view.len();
	if (joints == 0 || joints != self.imported_skin.columns) return {};
	if (self.imported_skin.vertices != self.geometry.positions.len) return {};

	int[] column = alloc::new_array(allocator, int, (sz)joints);
	defer alloc::free(allocator, column);

	bool[] claimed = alloc::new_array(allocator, bool, (sz)joints);
	defer alloc::free(allocator, claimed);

	// By dot when the columns are tied to dots, so a renamed joint keeps its
	// column: a name has no effect on geometry.
	bool by_dot = self.imported_skin.dot_ids.len == self.imported_skin.columns;
	for (usz j = 0; j < joints; j++)
	{
		column[j] = -1;
		if (by_dot)
		{
			foreach (usz c, id : self.imported_skin.dot_ids)
			{
				if (claimed[c] || id != view.dot_ids[j]) continue;
				claimed[c] = true;
				column[j] = (int)c;
				break;
			}
			if (column[j] < 0) return {};
			continue;
		}
		String want = view.names[j];
		if (want.len == 0) return {};

		foreach (usz c, held : self.imported_skin.names)
		{
			if (claimed[c] || held != want) continue;
			claimed[c] = true;
			column[j] = (int)c;
			break;
		}
		if (column[j] < 0) return {};
	}

	usz vertices = self.imported_skin.vertices;
	float[] dense = alloc::new_array(allocator, float, (sz)(vertices * joints));
	for (usz v = 0; v < vertices; v++)
	{
		usz from = v * self.imported_skin.columns;
		usz to = v * joints;
		for (usz j = 0; j < joints; j++)
		{
			dense[to + j] = self.imported_skin.weights[from + (usz)column[j]];
		}
	}
	return dense;
}

// ---------------------------------------------------------------------------
// The file's own metadata: what a library reader needs, and nothing more
// ---------------------------------------------------------------------------

<*
 Stamp a written .glb with the two keys a library reader looks for.

 	`app.stamp_asset_metadata("goat_rigged.glb");`

 Stamped after the file is written rather than built into it, and that is not a
 shortcut. The rigged writers live in `rig/`, which knows about meshes and
 skeletons and must not learn what a crig document is; and the same call is what
 saves metadata back into a mesh the user brought from elsewhere, where there is
 no writer involved at all. One way in, whoever produced the file.

 **The rig document does not ride here.** It used to, under an extras key of its
 own, and the whole of it — including the paint layer, which is one entry per
 (vertex, dot) pair. That put megabytes into a file whose only reader for them
 was crig, duplicating a `<stem>.rigsmith.json` that already held the same bytes. The
 sidecar is the document's one home now; see `adopt_source_rig`.

 What is left is small and is genuinely about the *file* rather than about the
 editing session: `plan`, so a rigged character shows up in the asset browser
 under its body plan on the same terms every library pack does, and `clips`, so a
 smooth clip does not come back linear — the motion is in the channels, but what
 the channels *mean* has no glTF slot. Together they are tens of bytes.

 Nothing is re-encoded — see `gltf_edit::patch_extra`. The binary chunk is copied
 through byte for byte, so this is safe on a file crig did not write.

 @param clips_replaced : `The file's animations were just rewritten to exactly clips, so their settings are rewritten too — none then removes a stale member rather than keeping it.`
 @return `False when the file could not be read or written; the caller reports it.`
*>
fn bool AppState.stamp_asset_metadata(&self, String path, AnimTemplate[] clips = {}, bool clips_replaced = false)
{
	String clip_settings = clip_extras_text(mem, clips);
	// Guarded: clips with nothing to declare come back as "", a literal that must
	// not be freed.
	defer if (clip_settings.len > 0) clip_settings.free(mem);

	if (clip_settings.len == 0 && self.doc.plan.len == 0 && !clips_replaced) return true;

	// One read and one write for both, rather than one apiece: `patch_gltf` takes
	// a list, and a second pass over a three-megabyte file to add forty bytes is a
	// second pass for nothing.
	gltf_edit::JsonStep[2] clip_path = { { .key = gltf_edit::GLTF_EXTRAS }, { .key = PACK_KEY_CLIPS } };
	gltf_edit::JsonStep[2] plan_path = { { .key = gltf_edit::GLTF_EXTRAS }, { .key = PACK_KEY_PLAN } };

	gltf_edit::JsonEdit[2] edits = {
		{ .path = clip_path[..], .value = clip_settings },
		{ .path = plan_path[..], .value = self.doc.plan },
	};

	// No clips handed over is "nothing to say about them", not "they have no
	// settings": an empty value removes the member, so the clip edit is left out and
	// whatever the file already declares (the blend, loop and ground a previous save
	// or export wrote) stays. Only a call that names clips, or one whose file just
	// had its animations replaced, may rewrite the member — the latter so deleting
	// the last clip does not leave its settings (keys and all) behind in the file.
	usz skip = clips.len == 0 && !clips_replaced ? 1 : 0;
	if (catch gltf_edit::patch_gltf(mem, path, edits[skip..])) return false;
	return true;
}

<*
 The dot going by this name, or null.

 By name because that is what a file addresses joints by: a clip names a joint,
 and so does a glTF node. The first match wins; two dots sharing a name is a rig
 the exporter would already have refused to write clips for.
*>
fn Dot* AppState.dot_named(&self, String name)
{
	if (name.len == 0) return null;
	foreach (&dot : self.doc.dots.array_view())
	{
		if (dot.name == name) return dot;
	}
	return null;
}

<*
 Write this rig's document beside a model, as that model's `<stem>.rigsmith.json`.

 What **Save** does with the half of a rig glTF has no word for — see
 `AppState.save_session`. Making the *nodes* agree is `write_rig_into_model`, and
 the two are separate on purpose: this one is cheap enough to run on every
 Ctrl+S, and that one rewrites the skin.

 **Beside the file that was written, and nowhere else.** A save that produced
 `<stem>_copy.glb` writes `<stem>_copy.rigsmith.json`; the original's own sidecar, if
 it has one, is that file's account of itself and this save did not touch that
 file. This is also what `adopt_source_rig` reads back, and what tells a later
 open that crig owns the model — so writing it beside the wrong file would hand
 ownership to a model crig deliberately left alone.

 @param stamped_clips : `The clips whose blend, loop and ground settings go into the model's extras.clips. Empty leaves the member the file already has alone, unless clips_replaced.`
 @param clips_replaced : `The model's animations were just rewritten to exactly stamped_clips; see stamp_asset_metadata.`
 @param limits : `Write the joints' rotation limits into the document too. Off when the model beside it carries them — an export, or a save whose skin went in — and on when it could not take them, so a Ctrl+S that had to leave the model alone does not lose the tables with it.`
 @return `False when the document could not be written; the caller reports it.`
*>
fn bool AppState.save_rig_beside(
	&self,
	String path,
	bool limits = false,
	bool model_transform_in_mesh = false,
	AnimTemplate[] stamped_clips = {},
	bool clips_replaced = false)
{
	if (path.len == 0 || self.doc.dots.len() == 0) return false;

	String sidecar = session_path(mem, path);
	defer sidecar.free(mem);

	AnimTemplate[] clips = self.kept_authored_clips(mem);
	defer if (clips.len > 0) alloc::free(mem, clips);
	if (catch write_session(sidecar, &self.doc, path, clips, limits, model_transform_in_mesh)) return false;

	// Best effort, and deliberately not fatal: `plan` and `clips` are how a
	// library reader describes this file, and losing them costs a browser category
	// rather than the rig.
	(void)self.stamp_asset_metadata(path, stamped_clips, clips_replaced);

	self.remember_project(path);
	io::printfn("saved the rig beside %s (%d joints, %d bones)",
		path, self.doc.dots.len(), self.doc.edges.len());
	return true;
}
