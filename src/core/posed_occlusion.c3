<*
 Occlusion queries against the mesh the GPU is currently skinning.

 `DeformedCollisionSurface` is one posed mesh cache with two workloads. The rig
 overlay asks only a few dozen rays, so its conservative node bounds and posed
 vertices stay lazy. Collision prevention asks which triangles a joint edit can
 bring together, so the same mirrored tree also carries exact triangle bounds
 which can refit only affected leaves and their ancestors.

 The bound is conservative without being the whole rest box through every
 joint. For each BVH node it records one rest-space box per joint, containing
 only vertices in that node which that joint influences. Transforming those
 boxes by the palette and taking their union contains every linearly blended
 vertex: a weighted average lies inside the axis-aligned box containing all of
 its contributing points. False-positive nodes can be visited, but no posed
 triangle can be skipped.

 Conservative node bounds and lazily skinned vertices are stamped with the
 caller's pose generation. All rig dots, bones and labels in one paint share
 the work, while a new evaluated pose invalidates it by changing one integer.
 The exact side uses static joint-to-triangle and topology tables, so a gesture
 reskins and refits its own region without a per-step mesh-sized allocation.
 The broad phase walks the tree against itself rather than once per moving
 triangle, with the moving and rigidly carried counts of each node pushed up
 from the region's leaves, so what a move carries whole is pruned as a
 subtree and what it cannot touch is never descended.
*>
module crig;

import gltf;
import collision;
import std::math;
import std::math::matrix;
import std::collections::list;
import std::sort;


struct PosedInfluenceBound @local
{
	uint joint;
	collision::Aabb3 rest;
}

struct DeformedSurfaceNode @local
{
	collision::TriBVHNode* source;
	DeformedSurfaceNode* parent;
	DeformedSurfaceNode* left;
	DeformedSurfaceNode* right;
	PosedInfluenceBound[] influences;

	// A cache for the palette generation named below it.
	collision::Aabb3 posed;
	uint posed_generation;

	// The exact bound of the currently refitted triangle surface. Unlike
	// `posed`, this is not conservative: collision broad phase consumes it.
	collision::Aabb3 surface_bound;
	bool surface_dirty;

	// How many triangles the node holds, and — for the broad-phase query
	// whose stamp `count_stamp` names — how many of them that query moves and
	// how many of those it carries rigidly. Pushed up from the moving
	// triangles' leaves by `note_query_triangle`, so the pair walk can drop a
	// subtree nothing moves in, or one the move carries whole, at its root.
	uint triangle_count;
	uint count_stamp;
	uint moving_count;
	uint rigid_count;

	// The distinct skin regions of the triangles under the node, ascending;
	// what lets a policy's table of regions that may meet prune a pair of
	// subtrees before either is descended. See `assign_node_regions`.
	uint[] regions;
}

struct DeformedRefitStats
{
	usz vertices;
	usz triangles;
	usz nodes;
	bool full;
}

struct DeformedTrianglePair
{
	uint a;
	uint b;
}

<*
 The posed topology and acceleration companion to a `Picker`.

 `source` nodes and their vertex/triangle arrays remain owned by the picker.
 Everything else here is owned and released by `free`.
*>
struct DeformedCollisionSurface
{
	DeformedSurfaceNode* root;
	float scale;
	usz vertices;
	usz triangles;
	uint joints;
	uint slots;

	// Static topology and skin regions. The offsets are CSR tables: the values
	// for item i are entries[offsets[i] : offsets[i + 1] - offsets[i]].
	uint[] joint_triangle_offsets;
	uint[] joint_triangles;
	uint[] vertex_regions;
	uint[] triangle_regions;

	// Exact posed geometry used by collision. A triangle points back to the
	// mirrored leaf that contains it so a regional refit only dirties its path.
	collision::Aabb3[] triangle_bounds;
	DeformedSurfaceNode*[] triangle_leaves;
	uint[] triangle_marks;
	uint[] vertex_marks;
	uint[] query_marks;
	// Stamped with the query stamp for a moving triangle every corner of which
	// is weighted only to moving joints — one that the move carries rigidly.
	uint[] rigid_marks;
	uint mark_stamp;
	uint query_stamp;
	uint surface_generation;
	bool surface_ready;

	// Allocated once and filled only for vertices whose leaves a ray reaches.
	Vec3[] posed_vertices;
	uint[] vertex_generations;
}

fn void add_influence_point(List{PosedInfluenceBound}* out, uint joint, Vec3 point) @local
{
	foreach (&entry : out.array_view())
	{
		if (entry.joint != joint) continue;
		entry.rest.expand_by_point(point);
		return;
	}
	out.push({ .joint = joint, .rest = { .min = point, .max = point } });
}

fn void add_influence_box(List{PosedInfluenceBound}* out, PosedInfluenceBound incoming) @local
{
	foreach (&entry : out.array_view())
	{
		if (entry.joint != incoming.joint) continue;
		entry.rest.expand_by_aabb(incoming.rest);
		return;
	}
	out.push(incoming);
}

fn usz source_triangle_count(collision::TriBVHNode* node) @local
{
	if (!node) return 0;
	if (node.is_leaf()) return (usz)node.count;
	return source_triangle_count(node.left) + source_triangle_count(node.right);
}

fn void assign_triangle_leaves(DeformedSurfaceNode* node, DeformedSurfaceNode*[] leaves) @local
{
	if (!node) return;
	if (node.source.is_leaf())
	{
		for (sz i = 0; i < node.source.count; i++)
		{
			usz triangle = (usz)node.source.sorted_indices[node.source.start + i];
			if (triangle < leaves.len) leaves[triangle] = node;
		}
		return;
	}
	assign_triangle_leaves(node.left, leaves);
	assign_triangle_leaves(node.right, leaves);
}

fn void prefix_offsets(uint[] offsets) @local
{
	uint total = 0;
	for (usz i = 0; i + 1 < offsets.len; i++)
	{
		uint count = offsets[i];
		offsets[i] = total;
		total += count;
	}
	if (offsets.len > 0) offsets[offsets.len - 1] = total;
}

fn void build_joint_maps(DeformedCollisionSurface* out, gltf::SkinBinding binding) @local
{
	out.joint_triangle_offsets = alloc::new_array(mem, uint, (sz)out.joints + 1);
	uint[] marks = alloc::new_array(mem, uint, (sz)out.joints);
	defer alloc::free(mem, marks);
	for (usz triangle = 0; triangle < out.triangles; triangle++)
	{
		uint stamp = (uint)triangle + 1;
		collision::Triangle indices = out.root.source.triangles[triangle];
		uint[3] corners = { indices.x, indices.y, indices.z };
		foreach (corner : corners)
		{
			if ((usz)corner >= out.vertices) continue;
			usz base = (usz)corner * (usz)binding.slots;
			for (uint slot = 0; slot < binding.slots; slot++)
			{
				if (binding.weights[base + slot] <= 0.0f) continue;
				uint joint = (uint)binding.joints[base + slot];
				if (joint >= out.joints || marks[joint] == stamp) continue;
				marks[joint] = stamp;
				out.joint_triangle_offsets[joint]++;
			}
		}
	}
	prefix_offsets(out.joint_triangle_offsets);
	uint triangle_entries = out.joint_triangle_offsets[out.joints];
	out.joint_triangles = alloc::new_array(mem, uint, (sz)triangle_entries);
	uint[] cursors = alloc::new_array(mem, uint, (sz)out.joints);
	defer alloc::free(mem, cursors);
	for (uint joint = 0; joint < out.joints; joint++) cursors[joint] = out.joint_triangle_offsets[joint];
	marks[..] = 0;
	for (usz triangle = 0; triangle < out.triangles; triangle++)
	{
		uint stamp = (uint)triangle + 1;
		collision::Triangle indices = out.root.source.triangles[triangle];
		uint[3] corners = { indices.x, indices.y, indices.z };
		foreach (corner : corners)
		{
			if ((usz)corner >= out.vertices) continue;
			usz base = (usz)corner * (usz)binding.slots;
			for (uint slot = 0; slot < binding.slots; slot++)
			{
				if (binding.weights[base + slot] <= 0.0f) continue;
				uint joint = (uint)binding.joints[base + slot];
				if (joint >= out.joints || marks[joint] == stamp) continue;
				marks[joint] = stamp;
				out.joint_triangles[cursors[joint]++] = (uint)triangle;
			}
		}
	}
}

fn void build_regions(DeformedCollisionSurface* out, gltf::SkinBinding binding) @local
{
	out.vertex_regions = alloc::new_array(mem, uint, (sz)out.vertices);
	for (usz vertex = 0; vertex < out.vertices; vertex++)
	{
		uint region = uint::max;
		float strongest = 0.0f;
		usz base = vertex * (usz)binding.slots;
		for (uint slot = 0; slot < binding.slots; slot++)
		{
			float weight = binding.weights[base + slot];
			uint joint = (uint)binding.joints[base + slot];
			if (joint >= out.joints || weight <= strongest) continue;
			region = joint;
			strongest = weight;
		}
		out.vertex_regions[vertex] = region;
	}

	out.triangle_regions = alloc::new_array(mem, uint, (sz)out.triangles);
	float[] totals = alloc::new_array(mem, float, (sz)out.joints);
	uint[] marks = alloc::new_array(mem, uint, (sz)out.joints);
	defer alloc::free(mem, totals);
	defer alloc::free(mem, marks);
	for (usz triangle = 0; triangle < out.triangles; triangle++)
	{
		uint stamp = (uint)triangle + 1;
		uint region = uint::max;
		float strongest = 0.0f;
		collision::Triangle indices = out.root.source.triangles[triangle];
		uint[3] corners = { indices.x, indices.y, indices.z };
		foreach (corner : corners)
		{
			if ((usz)corner >= out.vertices) continue;
			usz base = (usz)corner * (usz)binding.slots;
			for (uint slot = 0; slot < binding.slots; slot++)
			{
				float weight = binding.weights[base + slot];
				uint joint = (uint)binding.joints[base + slot];
				if (joint >= out.joints || weight <= 0.0f) continue;
				if (marks[joint] != stamp)
				{
					marks[joint] = stamp;
					totals[joint] = weight;
				}
				else
				{
					totals[joint] += weight;
				}
				if (totals[joint] > strongest)
				{
					region = joint;
					strongest = totals[joint];
				}
			}
		}
		out.triangle_regions[triangle] = region;
	}
}

fn uint shared_triangle_vertices(DeformedCollisionSurface* out, usz triangle, uint candidate) @local
{
	collision::Triangle a = out.root.source.triangles[triangle];
	collision::Triangle b = out.root.source.triangles[candidate];
	uint[3] ac = { a.x, a.y, a.z };
	uint[3] bc = { b.x, b.y, b.z };
	uint shared = 0;
	foreach (av : ac) foreach (bv : bc) if (av == bv) { shared++; break; }
	return shared;
}

fn DeformedSurfaceNode* build_posed_node(
	collision::TriBVHNode* source,
	gltf::SkinBinding binding,
	uint joint_count,
	DeformedSurfaceNode* parent = null) @local
{
	DeformedSurfaceNode* node = mem::new(DeformedSurfaceNode, { .source = source, .parent = parent });
	List{PosedInfluenceBound} influences;
	influences.init(mem);
	defer influences.free();

	if (source.is_leaf())
	{
		node.triangle_count = (uint)source.count;
		for (sz i = 0; i < source.count; i++)
		{
			sz triangle_index = source.sorted_indices[source.start + i];
			collision::Triangle triangle = source.triangles[triangle_index];
			uint[3] corners = { triangle.x, triangle.y, triangle.z };

			foreach (corner : corners)
			{
				usz vertex = (usz)corner;
				if (vertex >= binding.vertices) continue;
				usz base = vertex * (usz)binding.slots;
				for (uint slot = 0; slot < binding.slots; slot++)
				{
					if (binding.weights[base + slot] <= 0.0f) continue;
					uint joint = (uint)binding.joints[base + slot];
					if (joint >= joint_count) continue;
					add_influence_point(&influences, joint, source.vertices[corner]);
				}
			}
		}
	}
	else
	{
		if (source.left)
		{
			node.left = build_posed_node(source.left, binding, joint_count, node);
			foreach (influence : node.left.influences) add_influence_box(&influences, influence);
			node.triangle_count += node.left.triangle_count;
		}
		if (source.right)
		{
			node.right = build_posed_node(source.right, binding, joint_count, node);
			foreach (influence : node.right.influences) add_influence_box(&influences, influence);
			node.triangle_count += node.right.triangle_count;
		}
	}

	node.influences = influences.to_array(mem);
	node.surface_bound = source.aabb;
	return node;
}

<*
 Build the static acceleration data for one picker/binding pair.

 An empty or inconsistent pair deliberately returns an empty occluder. The
 viewport can then use its ordinary rest picker; a damaged preview should lose
 a depth cue, not take the editor down.

 @param picker : `Borrowed for the lifetime of the result.`
 @param binding : `Borrowed only while building; queries receive the current binding again.`
*>
fn DeformedCollisionSurface build_deformed_collision_surface(Picker* picker, gltf::SkinBinding binding, uint joints)
{
	usz needed = binding.vertices * (usz)binding.slots;
	usz triangles = picker.bvh ? source_triangle_count(picker.bvh) : 0;
	if (!picker.bvh || joints == 0 || binding.vertices == 0 || binding.slots == 0
		|| binding.joints.len < needed || binding.weights.len < needed
		|| triangles == 0 || triangles >= (usz)uint::max)
	{
		return {};
	}

	DeformedCollisionSurface out = {
		.root = build_posed_node(picker.bvh, binding, joints),
		.scale = picker.scale,
		.vertices = binding.vertices,
		.triangles = triangles,
		.joints = joints,
		.slots = binding.slots,
		.posed_vertices = alloc::new_array(mem, Vec3, (sz)binding.vertices),
		.vertex_generations = alloc::new_array(mem, uint, (sz)binding.vertices),
		.triangle_bounds = alloc::new_array(mem, collision::Aabb3, (sz)triangles),
		.triangle_leaves = alloc::new_array(mem, DeformedSurfaceNode*, (sz)triangles),
		.triangle_marks = alloc::new_array(mem, uint, (sz)triangles),
		.vertex_marks = alloc::new_array(mem, uint, (sz)binding.vertices),
		.query_marks = alloc::new_array(mem, uint, (sz)triangles),
		.rigid_marks = alloc::new_array(mem, uint, (sz)triangles),
	};
	assign_triangle_leaves(out.root, out.triangle_leaves);
	build_joint_maps(&out, binding);
	build_regions(&out, binding);
	assign_node_regions(&out, out.root);
	return out;
}

<*
 The regions under every node, merged upward from the leaves. A triangle no
 joint weights contributes `uint::max`, which the table read against these
 treats as a region that may meet anything.
*>
fn void assign_node_regions(DeformedCollisionSurface* owner, DeformedSurfaceNode* node) @local
{
	List{uint} merged;
	merged.init(mem);
	defer merged.free();
	if (node.source.is_leaf())
	{
		for (sz i = 0; i < node.source.count; i++)
		{
			usz triangle = (usz)node.source.sorted_indices[node.source.start + i];
			if (triangle < owner.triangles) merged.push(owner.triangle_regions[triangle]);
		}
	}
	else
	{
		if (node.left)
		{
			assign_node_regions(owner, node.left);
			foreach (region : node.left.regions) merged.push(region);
		}
		if (node.right)
		{
			assign_node_regions(owner, node.right);
			foreach (region : node.right.regions) merged.push(region);
		}
	}
	if (merged.len() == 0) return;
	uint[] sorted = merged.array_view();
	sort::quicksort(sorted);
	usz kept = 0;
	foreach (usz i, region : sorted)
	{
		if (i > 0 && region == sorted[kept - 1]) continue;
		sorted[kept++] = region;
	}
	node.regions = alloc::new_array(mem, uint, (sz)kept);
	node.regions[:kept] = sorted[:kept];
}

fn void DeformedSurfaceNode.free(&self)
{
	if (self.left)
	{
		self.left.free();
		mem::free(self.left);
	}
	if (self.right)
	{
		self.right.free();
		mem::free(self.right);
	}
	if (self.influences.len > 0) alloc::free(mem, self.influences);
	if (self.regions.len > 0) alloc::free(mem, self.regions);
	*self = {};
}

fn void DeformedCollisionSurface.free(&self)
{
	if (self.root)
	{
		self.root.free();
		mem::free(self.root);
	}
	if (self.posed_vertices.len > 0) alloc::free(mem, self.posed_vertices);
	if (self.vertex_generations.len > 0) alloc::free(mem, self.vertex_generations);
	if (self.joint_triangle_offsets.len > 0) alloc::free(mem, self.joint_triangle_offsets);
	if (self.joint_triangles.len > 0) alloc::free(mem, self.joint_triangles);
	if (self.vertex_regions.len > 0) alloc::free(mem, self.vertex_regions);
	if (self.triangle_regions.len > 0) alloc::free(mem, self.triangle_regions);
	if (self.triangle_bounds.len > 0) alloc::free(mem, self.triangle_bounds);
	if (self.triangle_leaves.len > 0) alloc::free(mem, self.triangle_leaves);
	if (self.triangle_marks.len > 0) alloc::free(mem, self.triangle_marks);
	if (self.vertex_marks.len > 0) alloc::free(mem, self.vertex_marks);
	if (self.query_marks.len > 0) alloc::free(mem, self.query_marks);
	if (self.rigid_marks.len > 0) alloc::free(mem, self.rigid_marks);
	*self = {};
}

fn bool DeformedCollisionSurface.matches(&self, gltf::SkinBinding binding, Matrix4f[] palette, uint generation)
{
	usz needed = binding.vertices * (usz)binding.slots;
	return self.root != null && generation != 0
		&& binding.vertices == self.vertices && binding.slots == self.slots
		&& binding.joints.len >= needed && binding.weights.len >= needed
		&& palette.len >= (usz)self.joints;
}

fn uint[] DeformedCollisionSurface.triangles_for_joint(&self, uint joint)
{
	if (joint >= self.joints) return {};
	uint begin = self.joint_triangle_offsets[joint];
	return self.joint_triangles[(usz)begin : (usz)(self.joint_triangle_offsets[joint + 1] - begin)];
}

fn uint DeformedCollisionSurface.region_for_vertex(&self, uint vertex)
{
	return (usz)vertex < self.vertices ? self.vertex_regions[vertex] : uint::max;
}

fn uint DeformedCollisionSurface.region_for_triangle(&self, uint triangle)
{
	return (usz)triangle < self.triangles ? self.triangle_regions[triangle] : uint::max;
}

fn bool DeformedCollisionSurface.triangles_share_vertex(&self, uint a, uint b)
{
	if ((usz)a >= self.triangles || (usz)b >= self.triangles) return false;
	return shared_triangle_vertices(self, (usz)a, b) > 0;
}

fn uint DeformedCollisionSurface.next_mark(&self)
{
	self.mark_stamp++;
	if (self.mark_stamp != 0) return self.mark_stamp;
	self.triangle_marks[..] = 0;
	self.vertex_marks[..] = 0;
	self.mark_stamp = 1;
	return 1;
}

fn void reset_count_stamps(DeformedSurfaceNode* node) @local
{
	if (!node) return;
	node.count_stamp = 0;
	reset_count_stamps(node.left);
	reset_count_stamps(node.right);
}

fn uint DeformedCollisionSurface.next_query_mark(&self)
{
	self.query_stamp++;
	if (self.query_stamp != 0) return self.query_stamp;
	self.query_marks[..] = 0;
	self.rigid_marks[..] = 0;
	reset_count_stamps(self.root);
	self.query_stamp = 1;
	return 1;
}

fn collision::Aabb3 DeformedSurfaceNode.posed_bound(&self, Matrix4f[] palette, uint generation)
{
	if (self.posed_generation == generation) return self.posed;

	collision::Aabb3 bound = collision::NEW_AABB3;
	bool expanded = false;
	foreach (influence : self.influences)
	{
		bound.expand_by_aabb(influence.rest.transform_matrix(palette[influence.joint]));
		expanded = true;
	}
	// A valid binding gives every vertex an influence. Staying conservative in
	// the face of malformed input is still cheap, and makes a missing row a
	// visible rest-pose mismatch rather than an invisible branch of the mesh.
	self.posed = expanded ? bound : self.source.aabb;
	self.posed_generation = generation;
	return self.posed;
}

fn Vec3 DeformedCollisionSurface.posed_vertex(
	&self,
	usz vertex,
	gltf::SkinBinding binding,
	Matrix4f[] palette,
	uint generation)
{
	if (self.vertex_generations[vertex] == generation) return self.posed_vertices[vertex];

	Vec3 rest = self.root.source.vertices[vertex];
	Vec3 moved = { 0, 0, 0 };
	usz base = vertex * (usz)binding.slots;
	for (uint slot = 0; slot < binding.slots; slot++)
	{
		float weight = binding.weights[base + slot];
		if (weight == 0.0f) continue;
		uint joint = (uint)binding.joints[base + slot];
		if (joint >= palette.len) continue;
		moved += rest.transform(palette[joint]) * weight;
	}

	self.posed_vertices[vertex] = moved;
	self.vertex_generations[vertex] = generation;
	return moved;
}

fn collision::TriangleVerts DeformedCollisionSurface.deformed_triangle(
	&self,
	uint triangle,
	gltf::SkinBinding binding,
	Matrix4f[] palette,
	uint generation)
{
	if ((usz)triangle >= self.triangles || !self.matches(binding, palette, generation)) return {};
	collision::Triangle indices = self.root.source.triangles[triangle];
	return {
		self.posed_vertex((usz)indices.x, binding, palette, generation),
		self.posed_vertex((usz)indices.y, binding, palette, generation),
		self.posed_vertex((usz)indices.z, binding, palette, generation),
	};
}

fn collision::Aabb3 triangle_bound(collision::TriangleVerts triangle) @local
{
	collision::Aabb3 bound = collision::NEW_AABB3;
	bound.expand_by_point(triangle[0]);
	bound.expand_by_point(triangle[1]);
	bound.expand_by_point(triangle[2]);
	return bound;
}

fn void mark_surface_path_dirty(DeformedSurfaceNode* node) @local
{
	while (node)
	{
		if (node.surface_dirty) return;
		node.surface_dirty = true;
		node = node.parent;
	}
}

<*
 Rebuild the posed bounds under `node` from the triangle bounds. With
 `only_dirty` it skips every subtree not marked by mark_surface_path_dirty.
*>
fn collision::Aabb3 refit_surface(
	DeformedSurfaceNode* node,
	collision::Aabb3[] triangle_bounds,
	usz* visited,
	bool only_dirty) @local
{
	if (only_dirty && !node.surface_dirty) return node.surface_bound;
	(*visited)++;
	collision::Aabb3 bound = collision::NEW_AABB3;
	if (node.source.is_leaf())
	{
		for (sz i = 0; i < node.source.count; i++)
		{
			usz triangle = (usz)node.source.sorted_indices[node.source.start + i];
			bound.expand_by_aabb(triangle_bounds[triangle]);
		}
	}
	else
	{
		if (node.left) bound.expand_by_aabb(refit_surface(node.left, triangle_bounds, visited, only_dirty));
		if (node.right) bound.expand_by_aabb(refit_surface(node.right, triangle_bounds, visited, only_dirty));
	}
	node.surface_bound = bound;
	node.surface_dirty = false;
	return bound;
}

fn DeformedRefitStats DeformedCollisionSurface.refit_all(
	&self,
	gltf::SkinBinding binding,
	Matrix4f[] palette,
	uint generation)
{
	DeformedRefitStats stats = { .full = true };
	if (!self.matches(binding, palette, generation)) return stats;
	uint stamp = self.next_mark();
	for (usz triangle = 0; triangle < self.triangles; triangle++)
	{
		collision::Triangle indices = self.root.source.triangles[triangle];
		uint[3] corners = { indices.x, indices.y, indices.z };
		foreach (corner : corners)
		{
			if ((usz)corner >= self.vertices || self.vertex_marks[corner] == stamp) continue;
			self.vertex_marks[corner] = stamp;
			stats.vertices++;
		}
		self.triangle_bounds[triangle] = triangle_bound(
			self.deformed_triangle((uint)triangle, binding, palette, generation));
		stats.triangles++;
	}
	refit_surface(self.root, self.triangle_bounds, &stats.nodes, false);
	self.surface_generation = generation;
	self.surface_ready = true;
	return stats;
}

<*
 Refit only triangles whose skin weights mention one of `changed_joints`.

 The caller supplies every palette row changed since the preceding refit. A
 first call automatically becomes a full refit, so consumers never query a
 mixture of rest and posed triangle bounds.
*>
fn DeformedRefitStats DeformedCollisionSurface.refit_joints(
	&self,
	uint[] changed_joints,
	gltf::SkinBinding binding,
	Matrix4f[] palette,
	uint generation)
{
	if (!self.matches(binding, palette, generation)) return {};
	if (!self.surface_ready) return self.refit_all(binding, palette, generation);

	DeformedRefitStats stats;
	uint stamp = self.next_mark();
	foreach (joint : changed_joints)
	{
		if (joint >= self.joints) continue;
		foreach (triangle : self.triangles_for_joint(joint))
		{
			if (self.triangle_marks[triangle] == stamp) continue;
			self.triangle_marks[triangle] = stamp;
			collision::Triangle indices = self.root.source.triangles[triangle];
			uint[3] corners = { indices.x, indices.y, indices.z };
			foreach (corner : corners)
			{
				if ((usz)corner >= self.vertices || self.vertex_marks[corner] == stamp) continue;
				self.vertex_marks[corner] = stamp;
				stats.vertices++;
			}
			self.triangle_bounds[triangle] = triangle_bound(
				self.deformed_triangle(triangle, binding, palette, generation));
			mark_surface_path_dirty(self.triangle_leaves[triangle]);
			stats.triangles++;
		}
	}
	if (self.root.surface_dirty) refit_surface(self.root, self.triangle_bounds, &stats.nodes, true);
	self.surface_generation = generation;
	return stats;
}

fn collision::Aabb3 expanded_bound(collision::Aabb3 bound, float clearance) @local
{
	if (clearance <= 0.0f) return bound;
	Vec3 margin = { clearance, clearance, clearance };
	bound.min -= margin;
	bound.max += margin;
	return bound;
}

<*
 Count one moving triangle under every node on its leaf's path to the root,
 for the query `stamp` names. A node's counts are read only under that
 stamp; the first triangle to reach a node under a new stamp restarts them.
*>
fn void note_query_triangle(DeformedSurfaceNode* node, uint stamp, bool rigid) @local
{
	while (node)
	{
		if (node.count_stamp != stamp)
		{
			node.count_stamp = stamp;
			node.moving_count = 0;
			node.rigid_count = 0;
		}
		node.moving_count++;
		if (rigid) node.rigid_count++;
		node = node.parent;
	}
}

fn uint DeformedSurfaceNode.moving_under(&self, uint stamp) => self.count_stamp == stamp ? self.moving_count : 0;

// Every triangle under the node is one the query carries rigidly.
fn bool DeformedSurfaceNode.carried_whole(&self, uint stamp) => self.count_stamp == stamp
	&& self.triangle_count > 0 && self.rigid_count == self.triangle_count;

fn float DeformedSurfaceNode.surface_extent(&self) => (self.surface_bound.max - self.surface_bound.min).length_sq();

<*
 Whether `may_meet` — a joints-by-joints table of the region pairs a
 policy wants measured — lets any triangle of `a` meet any of `b`. Read only
 where the two region lists are short: near the leaves, where the pairs are,
 rather than at the root, where the table would be read whole for nothing.
 A region past the table, including the `uint::max` of an unweighted
 triangle, may meet anything.
*>
fn bool nodes_may_meet(DeformedSurfaceNode* a, DeformedSurfaceNode* b, bool[] may_meet, uint joints) @local
{
	if (a.regions.len * b.regions.len > MAY_MEET_NODE_PAIRS) return true;
	foreach (ra : a.regions)
	{
		if (ra >= joints) return true;
		foreach (rb : b.regions)
		{
			if (rb >= joints || may_meet[(usz)ra * (usz)joints + (usz)rb]) return true;
		}
	}
	return false;
}

const usz MAY_MEET_NODE_PAIRS @local = 64;

fn bool regions_may_meet(uint ra, uint rb, bool[] may_meet, uint joints) @local
{
	if (may_meet.len == 0 || ra >= joints || rb >= joints) return true;
	return may_meet[(usz)ra * (usz)joints + (usz)rb];
}

<*
 The pairs between two leaves — or within one, when `a` and `b` are the same
 leaf — that the query has to measure: at least one triangle moving, not both
 carried rigidly, bounds within the clearance of each other.
*>
fn void collect_leaf_pairs(
	DeformedCollisionSurface* owner,
	DeformedSurfaceNode* a,
	DeformedSurfaceNode* b,
	float clearance,
	uint stamp,
	bool skip_rigid,
	bool[] may_meet,
	List{DeformedTrianglePair}* pairs) @local
{
	for (sz i = 0; i < a.source.count; i++)
	{
		uint triangle = (uint)a.source.sorted_indices[a.source.start + i];
		bool moving = owner.query_marks[triangle] == stamp;
		bool rigid = skip_rigid && moving && owner.rigid_marks[triangle] == stamp;
		uint region = owner.triangle_regions[triangle];
		collision::Aabb3 query = expanded_bound(owner.triangle_bounds[triangle], clearance);
		for (sz j = a == b ? i + 1 : 0; j < b.source.count; j++)
		{
			uint other = (uint)b.source.sorted_indices[b.source.start + j];
			bool other_moving = owner.query_marks[other] == stamp;
			if (!moving && !other_moving) continue;
			if (rigid && other_moving && owner.rigid_marks[other] == stamp) continue;
			if (!regions_may_meet(region, owner.triangle_regions[other], may_meet, owner.joints)) continue;
			if (!owner.triangle_bounds[other].collides(query)) continue;
			pairs.push({ .a = math::min(triangle, other), .b = math::max(triangle, other) });
		}
	}
}

<*
 The pair walk: every unordered pair of triangles under `a` and `b` that the
 query has to measure, found by descending the two subtrees together.

 Called on the root against itself. A subtree nothing moves in is dropped
 whole, as is a pair of subtrees the move carries rigidly — an arm during a
 turn of the spine, or the whole body during a turn of the root — and two
 subtrees further apart than the clearance. What remains is descended on the
 larger side, and a subtree against itself into its two halves and the pair
 of them, which is what visits each pair of leaves exactly once.
*>
fn void collect_node_pairs(
	DeformedCollisionSurface* owner,
	DeformedSurfaceNode* a,
	DeformedSurfaceNode* b,
	float clearance,
	uint stamp,
	bool skip_rigid,
	bool[] may_meet,
	List{DeformedTrianglePair}* pairs) @local
{
	if (a.moving_under(stamp) == 0 && b.moving_under(stamp) == 0) return;
	if (skip_rigid && a.carried_whole(stamp) && b.carried_whole(stamp)) return;
	if (a != b && !expanded_bound(a.surface_bound, clearance).collides(b.surface_bound)) return;
	if (may_meet.len > 0 && !nodes_may_meet(a, b, may_meet, owner.joints)) return;
	bool leaf_a = a.source.is_leaf();
	bool leaf_b = b.source.is_leaf();
	if (leaf_a && leaf_b)
	{
		collect_leaf_pairs(owner, a, b, clearance, stamp, skip_rigid, may_meet, pairs);
		return;
	}
	if (a == b)
	{
		if (a.left) collect_node_pairs(owner, a.left, a.left, clearance, stamp, skip_rigid, may_meet, pairs);
		if (a.right) collect_node_pairs(owner, a.right, a.right, clearance, stamp, skip_rigid, may_meet, pairs);
		if (a.left && a.right) collect_node_pairs(owner, a.left, a.right, clearance, stamp, skip_rigid, may_meet, pairs);
		return;
	}
	if (leaf_b || (!leaf_a && a.surface_extent() >= b.surface_extent()))
	{
		if (a.left) collect_node_pairs(owner, a.left, b, clearance, stamp, skip_rigid, may_meet, pairs);
		if (a.right) collect_node_pairs(owner, a.right, b, clearance, stamp, skip_rigid, may_meet, pairs);
		return;
	}
	if (b.left) collect_node_pairs(owner, a, b.left, clearance, stamp, skip_rigid, may_meet, pairs);
	if (b.right) collect_node_pairs(owner, a, b.right, clearance, stamp, skip_rigid, may_meet, pairs);
}

<*
 Whether every corner of `triangle` is weighted only to joints marked in
 `in_moving` — so a move of those joints carries it as one rigid piece.
*>
fn bool triangle_rigid_to(DeformedCollisionSurface* owner, gltf::SkinBinding binding, uint triangle, bool[] in_moving) @local
{
	collision::Triangle indices = owner.root.source.triangles[triangle];
	uint[3] corners = { indices.x, indices.y, indices.z };
	foreach (corner : corners)
	{
		if ((usz)corner >= owner.vertices) return false;
		usz base = (usz)corner * (usz)binding.slots;
		for (uint slot = 0; slot < binding.slots; slot++)
		{
			if (binding.weights[base + slot] <= 0.0f) continue;
			uint joint = (uint)binding.joints[base + slot];
			if (joint >= in_moving.len || !in_moving[joint]) return false;
		}
	}
	return true;
}

<*
 Return unfiltered broad-phase pairs for regions influenced by `moving_joints`.

 Adjacency, rest-contact and clothing policy deliberately remain visible in
 this raw result. `core/collision_policy.c3` owns those exclusions; hiding them
 here would make the policy impossible to test independently from acceleration
 correctness.

 The one pair this can leave out is not policy but arithmetic. Two triangles
 weighted only to joints that a move carries as one rigid piece — every
 vertex of both takes the same transform — cannot change their distance, so
 testing them says nothing about the move. Given `binding`, such pairs are
 dropped; a triangle blended across the boundary of that set is not rigid
 and keeps every pair it is in. Without a binding every pair is returned.

 Which joints move as one is the caller's to say. For a turn of one joint it
 is the whole moving set; for a chain solve, where every pivot turns by its
 own step, it is only the deepest pivot's subtree, and `rigid_joints` names
 it. Empty means the moving set itself.

 The other thing this can leave out is what a policy has already decided.
 Given `may_meet` — a joints-by-joints table, true where two regions' pairs
 are worth measuring — a pair of subtrees whose regions can never meet is
 dropped before either is descended, and a pair of triangles whose regions
 cannot is never emitted. The table is the policy's to build and its rules
 stay its own; what it saves here is enumerating and then classifying the
 thousands of pairs a region's own triangles make with each other and with
 the crease beside them, which is most of what a query finds. Without the
 table every pair comes back, as the policy's checks want.

 @param binding : `The skin, to tell a rigidly carried triangle from a blended one; empty keeps every moving pair.`
 @param rigid_joints : `The joints the move carries as one, when fewer than all of the moving ones.`
 @param may_meet : `Which region pairs to keep, as a joints-by-joints table of joints squared entries; empty keeps every pair.`
*>
fn DeformedTrianglePair[] DeformedCollisionSurface.broad_phase_pairs_for_joints(
	&self,
	Allocator allocator,
	uint[] moving_joints,
	float clearance = 0.0f,
	gltf::SkinBinding binding = {},
	uint[] rigid_joints = {},
	bool[] may_meet = {})
{
	if (!self.surface_ready || !self.root) return {};
	if (may_meet.len != (usz)self.joints * (usz)self.joints) may_meet = {};
	uint stamp = self.next_query_mark();
	bool skip_rigid = binding.slots > 0 && binding.vertices == self.vertices
		&& binding.joints.len >= self.vertices * (usz)binding.slots
		&& binding.weights.len >= self.vertices * (usz)binding.slots;
	bool[] in_moving;
	if (skip_rigid)
	{
		in_moving = alloc::new_array(mem, bool, (sz)self.joints);
		foreach (joint : rigid_joints.len > 0 ? rigid_joints : moving_joints) if (joint < self.joints) in_moving[joint] = true;
	}
	defer if (in_moving.len > 0) alloc::free(mem, in_moving);

	foreach (joint : moving_joints)
	{
		if (joint >= self.joints) continue;
		foreach (triangle : self.triangles_for_joint(joint))
		{
			if (self.query_marks[triangle] == stamp) continue;
			self.query_marks[triangle] = stamp;
			bool rigid = skip_rigid && triangle_rigid_to(self, binding, triangle, in_moving);
			if (rigid) self.rigid_marks[triangle] = stamp;
			note_query_triangle(self.triangle_leaves[triangle], stamp, rigid);
		}
	}

	List{DeformedTrianglePair} pairs;
	pairs.init(allocator);
	defer pairs.free();
	collect_node_pairs(self, self.root, self.root, clearance, stamp, skip_rigid, may_meet, &pairs);
	return pairs.to_array(allocator);
}

<*
 One triangle's three vertex indices, as the index buffer names them.
*>
fn uint[3] DeformedCollisionSurface.triangle_corners(&self, uint triangle)
{
	if (!self.root || (usz)triangle >= self.triangles) return {};
	collision::Triangle indices = self.root.source.triangles[triangle];
	return { indices.x, indices.y, indices.z };
}

<*
 One triangle's corners as the mesh was authored — the picker's own vertices,
 which no palette has touched.
*>
fn collision::TriangleVerts DeformedCollisionSurface.rest_triangle(&self, uint triangle)
{
	if (!self.root || (usz)triangle >= self.triangles) return {};
	collision::Triangle indices = self.root.source.triangles[triangle];
	return {
		self.root.source.vertices[indices.x],
		self.root.source.vertices[indices.y],
		self.root.source.vertices[indices.z],
	};
}

fn void collect_rest_pairs(
	DeformedCollisionSurface* owner,
	collision::TriBVHNode* node,
	uint triangle,
	collision::Aabb3 query,
	collision::Aabb3[] rest_bounds,
	List{DeformedTrianglePair}* pairs) @local
{
	if (!node.aabb.collides(query)) return;
	if (node.is_leaf())
	{
		for (sz i = 0; i < node.count; i++)
		{
			uint other = (uint)node.sorted_indices[node.start + i];
			if (other <= triangle || !rest_bounds[other].collides(query)) continue;
			if (shared_triangle_vertices(owner, (usz)triangle, other) > 0) continue;
			pairs.push({ .a = triangle, .b = other });
		}
		return;
	}
	if (node.left) collect_rest_pairs(owner, node.left, triangle, query, rest_bounds, pairs);
	if (node.right) collect_rest_pairs(owner, node.right, triangle, query, rest_bounds, pairs);
}

<*
 Every pair of triangles whose rest-pose bounds, grown by `clearance`, meet,
 each once with `a < b` — the broad phase over the mesh as it was authored.

 The picker's own BVH answers this, so no palette and no refit is involved.
 Pairs that share a vertex are left out: two such triangles are at distance
 zero in every pose the mesh can take, which is a fact the topology tables
 already state rather than a contact this could tell anyone about. Everything
 else is here whatever region it lies in; the policy decides what is a contact.
*>
fn DeformedTrianglePair[] DeformedCollisionSurface.rest_pairs(&self, Allocator allocator, float clearance)
{
	if (!self.root || self.triangles == 0) return {};
	collision::Aabb3[] rest_bounds = alloc::new_array(mem, collision::Aabb3, (sz)self.triangles);
	defer alloc::free(mem, rest_bounds);
	for (usz triangle = 0; triangle < self.triangles; triangle++)
	{
		rest_bounds[triangle] = triangle_bound(self.rest_triangle((uint)triangle));
	}

	List{DeformedTrianglePair} pairs;
	pairs.init(allocator);
	defer pairs.free();
	for (usz triangle = 0; triangle < self.triangles; triangle++)
	{
		collision::Aabb3 query = expanded_bound(rest_bounds[triangle], clearance);
		collect_rest_pairs(self, self.root.source, (uint)triangle, query, rest_bounds, &pairs);
	}
	return pairs.to_array(allocator);
}

fn collision::HitInfo posed_ray_intersects(
	DeformedCollisionSurface* owner,
	DeformedSurfaceNode* node,
	collision::Ray ray,
	gltf::SkinBinding binding,
	Matrix4f[] palette,
	uint generation) @local
{
	collision::HitInfo missed;
	if (!node.posed_bound(palette, generation).intersect_ray(ray).collided) return missed;

	if (node.source.is_leaf())
	{
		collision::HitInfo nearest;
		float closest = float::max;
		for (sz i = 0; i < node.source.count; i++)
		{
			sz triangle_index = node.source.sorted_indices[node.source.start + i];
			collision::Triangle indices = node.source.triangles[triangle_index];
			collision::TriangleVerts triangle = {
				owner.posed_vertex((usz)indices.x, binding, palette, generation),
				owner.posed_vertex((usz)indices.y, binding, palette, generation),
				owner.posed_vertex((usz)indices.z, binding, palette, generation),
			};
			collision::HitInfo hit = triangle.intersect_ray(ray);
			if (!hit.collided || hit.depth >= closest) continue;
			closest = hit.depth;
			nearest = hit;
			nearest.triangle = triangle;
		}
		return nearest;
	}

	collision::HitInfo left;
	collision::HitInfo right;
	if (node.left) left = posed_ray_intersects(owner, node.left, ray, binding, palette, generation);
	if (node.right) right = posed_ray_intersects(owner, node.right, ray, binding, palette, generation);
	if (left.collided && right.collided) return left.depth < right.depth ? left : right;
	return left.collided ? left : right;
}

fn collision::HitInfo DeformedCollisionSurface.ray_intersects(
	&self,
	collision::Ray ray,
	gltf::SkinBinding binding,
	Matrix4f[] palette,
	uint generation)
{
	if (!self.matches(binding, palette, generation)) return {};
	return posed_ray_intersects(self, self.root, ray, binding, palette, generation);
}

<*
 Whether something nearer hides a point *on* the posed skin.

 `Picker.hidden_surface` against the mesh the GPU is showing: one cast, and the
 first hit either is the point itself — in sight, give or take the float error
 in a ray aimed at it — or a nearer piece of the body in front of it. The brush
 asks this of every vertex under its circle while a clip is parked, which is
 what lets a stroke land on the limb the user is looking at rather than on the
 rest-pose vertex that happens to project there.

 @param point : `A posed vertex. For a point inside the body, ask occluded instead.`
*>
fn bool DeformedCollisionSurface.hidden_surface(
	&self,
	Vec3 eye,
	Vec3 point,
	gltf::SkinBinding binding,
	Matrix4f[] palette,
	uint generation)
{
	collision::Ray ray;
	collision::HitInfo entry;
	float distance;
	return surface_before(self, eye, point, binding, palette, generation, &ray, &entry, &distance);
}

<*
 Whether the posed skin crosses the sight line from `eye` before `point`.
 Leaves the ray, the first crossing and the distance to `point` for occluded's
 second look.
*>
fn bool surface_before(
	DeformedCollisionSurface* self,
	Vec3 eye,
	Vec3 point,
	gltf::SkinBinding binding,
	Matrix4f[] palette,
	uint generation,
	collision::Ray* ray,
	collision::HitInfo* entry,
	float* distance) @local
{
	if (!self.matches(binding, palette, generation)) return false;

	Vec3 delta = point - eye;
	*distance = delta.length();
	if (*distance <= self.scale * SURFACE_EPSILON) return false;

	*ray = { .origin = eye, .direction = delta / *distance };
	*entry = self.ray_intersects(*ray, binding, palette, generation);
	return entry.collided && entry.depth < *distance - self.scale * SURFACE_EPSILON;
}

<*
 Whether the posed body sits wholly between `eye` and an interior rig point.

 The two-surface rule is the same one `Picker.occluded` documents: the first
 surface puts the ray inside the body; a second before the joint proves it came
 back out, so some other part of the body is in front of the control.
*>
fn bool DeformedCollisionSurface.occluded(
	&self,
	Vec3 eye,
	Vec3 point,
	gltf::SkinBinding binding,
	Matrix4f[] palette,
	uint generation)
{
	collision::Ray ray;
	collision::HitInfo entry;
	float distance;
	if (!surface_before(self, eye, point, binding, palette, generation, &ray, &entry, &distance)) return false;

	float step = self.scale * SURFACE_EPSILON;
	collision::Ray onward = {
		.origin = eye + ray.direction * (entry.depth + step),
		.direction = ray.direction,
	};
	collision::HitInfo exit = self.ray_intersects(onward, binding, palette, generation);
	return exit.collided && entry.depth + step + exit.depth < distance - step;
}

// ---------------------------------------------------------------------------
// Proximity: what secondary motion asks of the surface

<*
 The nearest point of the posed skin to a point in space, when it is within
 reach.

 `hit` false leaves the rest zeroed. `normal` is the way out: from the
 nearest point toward the point asked about, which at an edge or a corner of
 the skin is the direction that actually separates the two — a face's own
 normal there would shove a point beside the edge along the face instead of
 off it. A point that has slipped just inside the skin has no such direction,
 so it is given the face's own, from its winding — outward on a mesh wound
 the way glTF asks — and told which way out is rather than pushed deeper.
*>
struct SurfaceContact
{
	bool hit;
	Vec3 point;
	Vec3 normal;
	float distance;
	uint triangle;
}

// Squared distance from a point to a box, zero inside it.
fn float box_distance_sq(collision::Aabb3 box, Vec3 point) @local
{
	Vec3 gap = {
		math::max(box.min.x - point.x, math::max(0.0f, point.x - box.max.x)),
		math::max(box.min.y - point.y, math::max(0.0f, point.y - box.max.y)),
		math::max(box.min.z - point.z, math::max(0.0f, point.z - box.max.z)),
	};
	return gap.dot(gap);
}

fn void posed_nearest_within(
	DeformedCollisionSurface* owner,
	DeformedSurfaceNode* node,
	Vec3 point,
	bool[] skip,
	gltf::SkinBinding binding,
	Matrix4f[] palette,
	uint generation,
	SurfaceContact* best) @local
{
	// The reach shrinks as contacts are found, so the bound is the best so far.
	float limit = best.distance * best.distance;
	if (box_distance_sq(node.posed_bound(palette, generation), point) >= limit) return;

	if (node.source.is_leaf())
	{
		for (sz i = 0; i < node.source.count; i++)
		{
			usz triangle = (usz)node.source.sorted_indices[node.source.start + i];
			if (triangle < skip.len && skip[triangle]) continue;
			collision::Triangle indices = node.source.triangles[triangle];
			Vec3 a = owner.posed_vertex((usz)indices.x, binding, palette, generation);
			Vec3 b = owner.posed_vertex((usz)indices.y, binding, palette, generation);
			Vec3 c = owner.posed_vertex((usz)indices.z, binding, palette, generation);
			Vec3 on = collision::closest_point_on_triangle(point, a, b, c);
			float gap_sq = (point - on).length_sq();
			if (gap_sq >= best.distance * best.distance) continue;
			Vec3 face = (b - a).cross(c - a);
			float area = face.length();
			if (area <= 0.0f) continue;
			face = face / area;
			float gap = math::sqrt(gap_sq);
			Vec3 away = point - on;
			bool outside = gap > SURFACE_EPSILON * owner.scale && away.dot(face) > 0.0f;
			*best = {
				.hit = true,
				.point = on,
				.normal = outside ? away / gap : face,
				.distance = gap,
				.triangle = (uint)triangle,
			};
		}
		return;
	}

	// The nearer child first: whatever it finds tightens the reach the other
	// is tested against.
	DeformedSurfaceNode* first = node.left;
	DeformedSurfaceNode* second = node.right;
	if (first && second
		&& box_distance_sq(second.posed_bound(palette, generation), point)
			< box_distance_sq(first.posed_bound(palette, generation), point))
	{
		first = node.right;
		second = node.left;
	}
	if (first) posed_nearest_within(owner, first, point, skip, binding, palette, generation, best);
	if (second) posed_nearest_within(owner, second, point, skip, binding, palette, generation, best);
}

<*
 The nearest point of the skin, posed by `palette`, within `radius` of
 `point` — or no hit when nothing is that close.

 	`SurfaceContact near = surface.nearest_within(p, reach, skip, skin, palette, generation);`

 The lazy side of the cache, like a ray: conservative node bounds and only
 the vertices of the leaves the search reaches are posed, and both are kept
 for the generation, so a chain of points asked about one after another
 poses the skin around it once. Nothing is refitted, which is what makes it
 cheap enough to ask per particle per substep.

 @param skip : `One flag per triangle; a flagged triangle is not the surface. Empty skips nothing. What lets a tail's own skin be left out of what the tail is pushed off.`
*>
fn SurfaceContact DeformedCollisionSurface.nearest_within(
	&self,
	Vec3 point,
	float radius,
	bool[] skip,
	gltf::SkinBinding binding,
	Matrix4f[] palette,
	uint generation)
{
	SurfaceContact best = { .distance = radius };
	if (radius <= 0.0f || !self.matches(binding, palette, generation)) return best;
	posed_nearest_within(self, self.root, point, skip, binding, palette, generation, &best);
	return best;
}

<*
 How far, on average, the skin a joint owns stands off its bone at rest: the
 mean distance of the vertices whose strongest weight is this joint's from
 the line through `head` and `tail`. Zero for a joint that owns no vertex.

 What a chain's particles take for their own radius when nobody types one:
 the tail's skin is excluded from what the tail collides with, so its axis
 has to be held off the body by the tail's own girth, and the girth is here
 in the weights already. The mean rather than the widest, because a tail is
 a run of round-ish sections and the widest of them is a fin or a tuft; the
 line rather than the segment, because the skin a bone owns runs past its
 ends — the cap of a tail, the base of a braid — and that skin stands off
 the bone by the same girth as the rest, not by its distance to the end.
*>
fn float DeformedCollisionSurface.joint_thickness(&self, uint joint, Vec3 head, Vec3 tail)
{
	if (!self.root || joint >= self.joints) return 0.0f;
	Vec3 axis = tail - head;
	float axis_sq = axis.length_sq();
	float total = 0.0f;
	usz owned = 0;
	foreach (usz vertex, region : self.vertex_regions)
	{
		if (region != joint || vertex >= self.vertices) continue;
		Vec3 at = self.root.source.vertices[vertex];
		Vec3 on = head;
		if (axis_sq > 0.0f) on = head + axis * ((at - head).dot(axis) / axis_sq);
		total += (at - on).length();
		owned++;
	}
	return owned > 0 ? total / (float)owned : 0.0f;
}
