<*
 Making the model say what the rig says.

 	`app.write_rig_into_model();`

 `save_rig_beside` writes the rig **document** as `<stem>.crig.json` next to the
 model, which is what crig reads back and is enough for crig alone. This is the
 other half: the file's own nodes and its own `JOINTS_0` / `WEIGHTS_0` rewritten
 to be this rig, so that everything which is not crig — Blender, three.js, a
 viewer, the next tool along — sees the skeleton the user built rather than the
 one the file arrived with.

 The two are separate acts because they cost different amounts. The document is
 one small file written whole. This binds the mesh and rewrites the skin, and it
 is the reason **Save** can take a moment on a large character.

 The model is edited rather than rebuilt. `gltf_edit::reskin_glb` compacts the
 ordinary single-buffer data it can classify, appends the new skin payload, and
 edits the JSON around it, so the materials, textures, UVs and morph targets all
 come back untouched. **Export** writes through here too, into a copy, and falls
 back to the rebuilding writer (positions, normals, triangles) only when this
 cannot take the model.

 The clips are the one thing that cannot come back untouched. They are keyed
 against the skeleton this replaces, so the character's bound clips are
 re-authored against the new one instead — see `model_clips`. The file's own
 embedded clips are not read back: a clip the character does not bind is not
 written, so a character that binds none comes back with none rather than with
 channels that drive nothing.

 **It can refuse, and says why.** A model whose vertices sit under a node
 transform cannot be given a skin without moving, because glTF ignores a skinned
 node's transform; a file whose buffer lives beside it in a `.bin` has no binary
 chunk to rewrite. Both come back as a notice and leave the file alone, with the document
 still written beside it — so Save always saves, and only the model half is ever
 skipped.
*>
module crig;

import rig;
import gltf;
import gltf_edit;
import std::io;
import std::math::matrix;
import std::math::quaternion;
import std::math::vector;



<*
 What a joint node is called in the file when its dot has no name.

 The same spelling `rig::export_rigged_glb` uses, so a rig written by either
 route reads the same way in another tool. Naming it at all matters: the node is
 how an animation channel addresses a bone, and a nameless one cannot be
 addressed.
*>
fn String model_joint_name(Allocator allocator, String name, usz joint)
{
	if (name.len > 0) return name.copy(allocator);
	return string::format(allocator, "joint_%d", joint);
}

<*
 Write this rig's skeleton and skin into the mesh's own file.

 	`if (!app.write_rig_into_model(target)) { … the document still went in … }`

 @param path : `The .glb to rewrite. Save's own target, which is not always the file that was opened.`
 @param chosen : `The clips to write instead of the bound ones — Export's ticked list. Null writes the bound clips.`

 @return `False when the file could not take it; a notice has already said why.`
*>
fn bool AppState.write_rig_into_model(&self, String path, AnimTemplate[]* chosen = null,
	ExportMotion motion = {}, ExportMotionReport* report = null)
{
	if (path.len == 0 || !self.has_mesh()) return false;
	if (self.doc.dots.len() == 0) return false;

	// Walked and closed before anything is written: `reskin_glb` opens the same
	// path for itself, and holding a reader over a file being rewritten is a rule
	// worth keeping even where this platform allows it.
	rig::MeshParts parts;
	Matrix4f bind = matrix::IDENTITY4;
	if (!self.read_mesh_parts(path, &parts, &bind)) return false;
	defer parts.free(mem);

	// The one check that catches the two walks drifting apart — see the note on
	// `gltf_parts.c3`. Weights written against a vertex count that is not this
	// mesh's would land on whatever vertex happened to be at that row.
	if (parts.vertices != self.geometry.positions.len)
	{
		self.@notice("%s reads as %d vertices, this mesh has %d — the model was left alone",
			base_name(path), parts.vertices, self.geometry.positions.len);
		return false;
	}

	if (!parts.upright())
	{
		// The mesh sits under a node transform. glTF ignores a *skinned* node's
		// transform, so a naive skin would drop the mesh back to its node's local
		// origin the moment it gained one — unless that transform is folded into the
		// skin's bind matrix, which reproduces it exactly at rest (see
		// `gltf_edit::Reskin.bind`). crig already measured the rig against the baked,
		// placed positions, so the bind is just that placement. It works when one
		// transform placed the whole mesh and there is no existing skin whose own
		// bind this would overwrite; anything else still goes to Export.
		Matrix4f placement;
		if (parts.skin >= 0 || !parts.shared_placement(&placement) || placement.determinant() == 0.0f)
		{
			self.@notice("%s places its mesh with a node transform — export instead",
				base_name(path));
			return false;
		}
		bind = placement;
	}

	RigView? opened = self.open_rig(mem);
	if (catch opened) return false;
	RigView view = opened;
	defer view.free(mem);

	// A skin is one tree. A chain added and never connected — an antenna, a tail
	// placed on its own — is a second root, and the file would refuse it with no
	// word on which joint is loose, so it is named here instead.
	if (!one_skeleton(self, &view, path)) return false;

	float[] skin = self.bind_dense(mem, &view);
	defer alloc::free(mem, skin);

	usz bones = view.len();
	if (skin.len != self.geometry.positions.len * bones) return false;

	gltf_edit::ReskinJoint[] joints = alloc::new_array(mem, gltf_edit::ReskinJoint, (sz)bones);
	defer
	{
		foreach (joint : joints)
		{
			if (joint.name.len > 0) alloc::free(mem, joint.name.ptr);
		}
		alloc::free(mem, joints);
	}

	for (usz j = 0; j < bones; j++)
	{
		joints[j] = {
			.name = model_joint_name(mem, view.names[j], j),
			.parent = view.skeleton.parents[j],
			.position = view.skeleton.joints[j],
		};
	}

	gltf_edit::ReskinPart[] written = alloc::new_array(mem, gltf_edit::ReskinPart, (sz)parts.parts.len);
	defer alloc::free(mem, written);

	foreach (usz p, part : parts.parts)
	{
		written[p] = {
			.node = part.node,
			.mesh = part.mesh,
			.primitive = part.primitive,
			.base = part.base,
			.count = part.count,
		};
	}

	// Re-authored, not carried over: the reskin below re-roots the skeleton, which
	// leaves every channel the file already had naming a joint that has either come
	// off the scene or lost the rest rotation its keys were composed against. See
	// `gltf_edit::ReskinClip`. Read from the file about to be rewritten, so what is
	// preserved is what that file actually held.
	gltf_edit::ReskinClip[] clips = self.model_clips(&view, chosen, motion, report);
	defer free_reskin_clips(mem, clips);

	// The joints' limits go into the file as well, as the KHR joints an export
	// writes — so the model saved in place is the same body plan the exported
	// one is, and a fit from either adopts the same tables.
	gltf_edit::ReskinConstraint[] limits = self.model_constraints(mem, &view);
	defer if (limits.len > 0) alloc::free(mem, limits);

	if (catch fault error = gltf_edit::reskin_glb(mem, path, {
		.joints = joints,
		.parts = written,
		.weights = skin,
		.vertices = self.geometry.positions.len,
		.skin = parts.skin,
		.influences = SKIN_INFLUENCES,
		.bind = bind,
		.clips = clips,
		.constraints = limits,
		.plan = self.doc.plan,
		// Only once the model has been resized here: otherwise the file's own
		// positions are already the mesh's, and rewriting them would grow nothing
		// but the chance of drift.
		.positions = self.mesh_resized ? self.geometry.positions : (Vec3[]){},
	}))
	{
		self.@notice("could not write the rig into %s (%s)", base_name(path), error);
		return false;
	}

	// `skin_from_file` is deliberately **not** set here, though the file now does
	// hold this rig's weights. The flag means "these weights came from somewhere
	// crig cannot reproduce" — a shoulder somebody painted — and it is what stops
	// the binder overwriting them. Weights crig itself just derived are not that:
	// setting the flag would make the next reach the user sizes do nothing, since
	// `bind_dense` would keep handing back what the file says instead of binding
	// the rig again.
	io::printfn("wrote the rig into %s (%d joints, %d vertices)", path, bones, parts.vertices);
	return true;
}

<*
 The rig's exact rotation limits, as the in-place writer takes them.

 	`gltf_edit::ReskinConstraint[] limits = app.model_constraints(mem, &view);`

 One entry per joint with a table it can write — the frame derived the way the
 exporter derives it (`constraint_world_frame`), the axes as the editor holds
 them, and the intent, primary child and adjustment the provenance keeps so a
 fork's frame is rebuilt the same on another rig. Rows the exporter would skip
 are skipped here for the same reasons.

 The caller owns the array; the strings in it are borrowed constants.
*>
fn gltf_edit::ReskinConstraint[] AppState.model_constraints(&self, Allocator allocator, RigView* view)
{
	ConstraintRig constraints = constraint_rig_of(allocator, &self.doc, &view.skeleton, view.dot_ids);
	defer constraints.free(allocator);

	usz count = 0;
	foreach (row : constraints.joints) if (row.status == EXACT) count++;
	if (count == 0) return {};

	gltf_edit::ReskinConstraint[] out = alloc::new_array(allocator, gltf_edit::ReskinConstraint, (sz)count);
	usz written = 0;
	foreach (usz joint, row : constraints.joints)
	{
		if (row.status != EXACT || view.skeleton.parents[joint] < 0) continue;
		Quaternionf frame;
		if (!constraint_world_frame(&view.skeleton, joint, row, &frame)) continue;
		gltf_edit::ReskinConstraint* limit = &out[written++];
		*limit = {
			.joint = joint,
			.frame = frame,
			.intent = constraint_intent_name(row.frame_intent),
			.primary = row.primary_child,
			.adjustment = row.frame_adjustment,
		};
		foreach (usz axis, held : row.axes)
		{
			limit.axes[axis] = {
				.allowed = held.allowed,
				.minimum = held.minimum,
				.maximum = held.maximum,
				.locked = held.locked,
			};
		}
	}
	return out[:written];
}

<*
 The animations to bake into the model, re-authored against the rig about to be
 written into it.

 	`gltf_edit::ReskinClip[] clips = app.model_clips(&view);`
 	`defer free_reskin_clips(mem, clips);`

 **The character's bound clips are the whole list.** These are the animations the
 Animations pane lists — `doc.animations`, resolved to their templates — and Save
 writes exactly them into the file, so the `.glb` holds the animations the
 character has and nothing else, visible to the Asset view, to Blender, to the
 next tool along. Before, this read only the animations the file already carried,
 so a clip authored in crig and bound to the character lived in the `.crig.json`
 sidecar and never reached the model itself.

 A clip embedded in the file but not bound is **not** carried over: unbinding a
 clip and saving takes it out of the model, which is what "Remove from character"
 promises. The Animations pane is authoritative — a file's own extra clips are
 not silently re-added on save, so an import that arrived with clips the character
 does not want loses them the first time it is saved.

 A save rewrites the skeleton, and a clip keyed against the old one does not
 survive that — so each is round-tripped through its template and re-sampled
 against the new joints: a template holds a pose per joint *name* in world axes,
 the one description of a clip that does not depend on the hierarchy it came from.
 Read through the same body plans the rig was named through, or the names would
 not meet — the same join `import_rig_from_source` depends on.

 The current document's exact joint limits are evaluated into these curves too.
 A rewritten model is an ordinary glTF consumer boundary just like Export: it
 cannot be expected to run crig's constraint evaluator after sampling a key.

 **Empty is a real answer, and it clears the file's animations.** A character with
 no bound clips leaves the model with none, which is the honest state rather than
 channels driving detached nodes.

 The caller owns the result.
*>
fn gltf_edit::ReskinClip[] AppState.model_clips(&self, RigView* view, AnimTemplate[]* chosen = null,
	ExportMotion motion = {}, ExportMotionReport* report = null)
{
	// The character's bound clips, each resolved to its live template — the whole
	// list, so what the Animations pane shows is exactly what the file gets. The
	// file's own embedded clips are deliberately not read: a clip the character
	// does not bind is not written, so unbinding it and saving removes it.
	AnimTemplateList templates;
	templates.init(mem);
	defer templates.free();

	// Export hands over the clips it was asked to write instead.
	if (chosen)
	{
		foreach (clip : *chosen)
		{
			if (clip.name.len > 0 && !template_named(templates, clip.name)) templates.push(clip);
		}
	}
	for (sz i = 0; !chosen && i < (sz)self.doc.animations.len(); i++)
	{
		AnimRef ref = self.resolve_bound(i);
		if (!ref.valid()) continue;
		// A bound clip may still be a deferred stub — read its curves before it is
		// baked into the file, or the export would keep an empty animation.
		self.ensure_clip_imported(ref);
		AnimTemplate* bound = self.clip(ref);
		if (bound == null || bound.name.len == 0) continue;
		if (!template_named(templates, bound.name)) templates.push(*bound);
	}

	ConstraintRig constraints = constraint_rig_of(mem, &self.doc, &view.skeleton,
		view.dot_ids);
	defer constraints.free(mem);
	return reskin_clips(mem, &view.skeleton, view.names, templates.array_view(), constraints,
		motion, report);
}

// Whether a template of this name is already gathered — how the bound clips and
// the file's own are unioned without writing one twice.
fn bool template_named(AnimTemplateList list, String name) @local
{
	foreach (held : list.array_view()) if (held.name == name) return true;
	return false;
}

<*
 The source file's primitives, in the order the flattener took them.

 Split out so the stream closes before the caller writes: a `defer` inside
 `write_rig_into_model` would hold it open across `reskin_glb`.

 @param out : `Filled on success; the caller frees it.`
 @param bind : `Receives the file's own bind transform, which the rewrite has to preserve. Untouched on failure.`
 @return `False when the file will not open or holds nothing to skin.`
*>
fn bool AppState.read_mesh_parts(&self, String path, rig::MeshParts* out, Matrix4f* bind)
{
	gltf::GltfStream? opened = gltf::open(path, mem);
	if (catch opened) return false;
	gltf::GltfStream stream = opened;
	defer stream.close();

	rig::MeshParts? walked = rig::mesh_parts(mem, &stream);
	if (catch walked) return false;

	// Read here rather than in the walk, which promises to touch no buffer, and
	// only for a file that has a skin at all — the bind matrices live in the
	// binary chunk and an unskinned model has none to read.
	Matrix4f found = matrix::IDENTITY4;
	if (walked.skin >= 0)
	{
		if (catch stream.load_all_buffers()) return false;
		// And the half turn a figure facing −Z took on its way in
		// (`import_rig_from_source`), which the bind is what keeps: the file's
		// positions still face −Z, the rig written over them faces +Z.
		found = source_turn(&stream).mul(rig::skin_bind_matrix(&stream, walked.skin));
	}

	*out = walked;
	*bind = found;
	return true;
}

<*
 Whether the rig is one connected skeleton; if not, the notice names the first
 loose joint and the nearest joint of the main tree to connect it to.
*>
fn bool one_skeleton(AppState* app, RigView* view, String path) @private
{
	int[] parents = view.skeleton.parents;
	Vec3[] joints = view.skeleton.joints;

	// Each joint's root, and the root with the most joints under it is the body.
	usz count = parents.len;
	usz[] under = alloc::new_array(mem, usz, (sz)count);
	defer alloc::free(mem, under);
	usz roots = 0;
	for (usz j = 0; j < count; j++)
	{
		if (parents[j] < 0) roots++;
		under[root_of(parents, j)]++;
	}
	if (roots <= 1) return true;

	usz body = 0;
	for (usz j = 0; j < count; j++) if (under[j] > under[body]) body = j;

	usz loose = count;
	for (usz j = 0; j < count; j++)
	{
		if (parents[j] < 0 && j != body) { loose = j; break; }
	}
	if (loose == count) return true;

	sz nearest = -1;
	float best = float::max;
	for (usz j = 0; j < count; j++)
	{
		if (root_of(parents, j) != body) continue;
		float apart = (joints[j] - joints[loose]).length();
		if (apart >= best) continue;
		best = apart;
		nearest = (sz)j;
	}

	String name = view.names[loose].len > 0 ? view.names[loose] : "a joint";
	if (nearest >= 0)
	{
		String to = view.names[(usz)nearest].len > 0 ? view.names[(usz)nearest] : "the nearest joint";
		app.@notice("%s is not connected to the skeleton — connect it to %s", name, to);
	}
	else
	{
		app.@notice("%s is not connected to the skeleton — connect it to another joint", name);
	}
	return false;
}

fn usz root_of(int[] parents, usz joint) @private
{
	usz at = joint;
	for (usz guard = 0; guard <= parents.len && parents[at] >= 0; guard++) at = (usz)parents[at];
	return at;
}
