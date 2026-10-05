<*
 Resizing the whole model: the mesh, the rig on it, and every length the
 document keeps, as one undo step.

 	`app.scale_model_to_height(1.8f);`

 What a mesh made at the wrong size needs — a generator's output arrives about
 one unit tall, and a character meant for an engine working in metres wants to
 stand 1.8. Moving the model (`move_selection_by`) only places it; a placement
 is written out as a node above the model, and a skeleton under a scaled parent
 is the wrong answer to "this character is 1.8 tall". So this one is baked:
 the vertices, the joints, the reaches and the collider radii all change size.

 **About the model's origin**, not its centre, so a figure standing on the floor
 at Y = 0 is still standing on it afterwards.

 What does not change, and why:

 - Clip and pose translations are fractions of rig height (`AnimKeyDot.move`),
   and rotations have no size, so every clip plays the same on the larger rig.
   The one model-space number a clip can hold, a ground spec's stated floor, is
   scaled with the authored clips that carry one.
 - Paint and pins are per vertex, and the vertices keep their order.
 - The model's placement (`doc.model_transform`) is where the model stands in
   the world, not how big it is.

 The file catches up on Save: `mesh_resized` makes `write_rig_into_model` write
 the vertex positions alongside the skin, and a save that cannot write into the
 model refuses to write the document either — a sidecar of scaled joints beside
 an unscaled mesh would reopen as a rig the wrong size for its body.
*>
module crig;

import rig;
import std::math;

enum ScaleModelResult : int
{
	SCALED,
	UNCHANGED,
	LOCKED,
	REFUSED,
}

// Below this a factor is a typo or a collapse, above it the same the other way.
// A thousandfold covers millimetres to metres, which is the widest honest change.
const float SCALE_MODEL_MIN = 0.001f;
const float SCALE_MODEL_MAX = 1000.0f;

<*
 How tall the model stands, in model units: the mesh's extent along Y, or the
 rig's when there is no mesh. Zero for an empty scene.
*>
fn float AppState.model_height(&self)
{
	if (self.geometry.positions.len > 0)
	{
		rig::Bounds box = self.geometry.bounds();
		return box.max.y - box.min.y;
	}
	if (self.doc.dots.len() == 0) return 0.0f;
	float low = math::FLOAT_MAX;
	float high = -math::FLOAT_MAX;
	foreach (dot : self.doc.dots.array_view())
	{
		low = math::min(low, dot.position.y);
		high = math::max(high, dot.position.y);
	}
	return high - low;
}

<*
 Resize the model by a factor, as one undo step.

 @return `SCALED, UNCHANGED for a factor of one, LOCKED while a pose edit or a drag is open, REFUSED for a factor that is not a size or a scene with nothing in it.`
*>
fn ScaleModelResult AppState.scale_model_by(&self, float factor)
{
	if (!math::is_finite(factor) || factor < SCALE_MODEL_MIN || factor > SCALE_MODEL_MAX) return REFUSED;
	if (!self.has_mesh() && self.doc.dots.len() == 0) return REFUSED;
	// An unfinished pose draft or drag is the user's, and would be resized out
	// from under them. Playback is not: the resize stops it, as a new body does.
	if (self.transform_transaction.active || self.pose_edit_active) return LOCKED;
	if (math::abs(factor - 1.0f) < 1.0e-6f) return UNCHANGED;

	self.apply_model_scale(factor);
	self.undo_stack.record({ .kind = SCALE_MODEL, .scale = factor });
	self.undo_stack.commit();
	return SCALED;
}

<*
 Resize the model so it stands `height` model units tall. See `scale_model_by`.
*>
fn ScaleModelResult AppState.scale_model_to_height(&self, float height)
{
	float now = self.model_height();
	if (now <= 1.0e-6f || !math::is_finite(height) || height <= 0.0f) return REFUSED;
	return self.scale_model_by(height / now);
}

<*
 The resize itself, recorded by nobody: `scale_model_by` records it, and undo
 and redo replay it here with the factor or its reciprocal.
*>
fn void AppState.apply_model_scale(&self, float factor)
{
	if (self.geometry.positions.len > 0)
	{
		Vec3[] positions = alloc::new_array(mem, Vec3, (sz)self.geometry.positions.len);
		foreach (usz i, p : self.geometry.positions) positions[i] = p * factor;
		Vec3[] normals;
		if (self.geometry.normals.len > 0)
		{
			normals = alloc::new_array(mem, Vec3, (sz)self.geometry.normals.len);
			normals[..] = self.geometry.normals[..];
		}
		uint[] indices = alloc::new_array(mem, uint, (sz)self.geometry.indices.len);
		indices[..] = self.geometry.indices[..];

		// `replace_geometry` is written for a body swapped under a rig, and treats
		// the file the rig came from as no longer this model's. A resize is the same
		// model: whether crig may save over it, and how it is placed, both stay.
		bool in_place = self.saves_in_place;
		bool placed = self.source_has_model_transform;
		self.replace_geometry({ .positions = positions, .normals = normals, .indices = indices });
		self.saves_in_place = in_place;
		self.source_has_model_transform = placed;
		self.mesh_resized = true;
	}

	foreach (&dot : self.doc.dots.array_view())
	{
		dot.position = dot.position * factor;
		dot.reach *= factor;
	}
	foreach (&collider : self.doc.colliders.array_view()) collider.radius *= factor;
	self.doc.sym_x *= factor;

	// A ground spec's stated floor is the one model-space number a clip holds.
	if (AnimPack* authored = self.authored())
	{
		foreach (&clip : authored.clips)
		{
			if (clip.ground.floor_set) clip.ground.floor *= factor;
		}
	}

	// The anchors are world points on the old size; held on, they would pull the
	// limbs back toward it.
	self.clear_position_locks();

	// The same view of a larger model.
	self.camera.target = self.camera.target * factor;
	self.camera.distance *= factor;
	self.camera.min_distance *= factor;
	self.camera.max_distance *= factor;
	self.camera.near_plane *= factor;
	self.camera.far_plane *= factor;

	self.plan_targets_stale = true;
	self.mark_rig_stale();
	self.refresh_pose_display();
}
