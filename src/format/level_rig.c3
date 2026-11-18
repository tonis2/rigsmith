<*
 A rigged character read out of a level file by its armature: its joints in the
 armature's own space, their rest, and the level's clips that drive them. Nothing
 of its mesh but the box it rests in.
*>
module crig;

import rig;
import gltf;
import std::math;
import std::collections::list;

faultdef LEVEL_RIG_NO_ARMATURE, LEVEL_RIG_NO_SKIN;

<* One rigged character of a level file, read by its armature. *>
struct LevelRig
{
	String armature; // owned
	// The armature's place in the file's world.
	Vec3 position;
	Quaternionf rotation;
	Vec3 scale;
	// Its skinned meshes' box at rest, in the armature's space.
	rig::Bounds bounds;
	// The joints in the armature's space, parents first, a name each (owned).
	rig::Skeleton skeleton;
	String[] names;
	// The skin's joints at rest in the skin's order, names owned; a joint with no joint above it is in the armature's space.
	JointRest[] rest;
	// The level's animations that drive these joints, by the names the file gives them.
	AnimTemplate[] clips;
}

fn void LevelRig.free(&self, Allocator allocator)
{
	if (self.armature.len > 0) self.armature.free(allocator);
	self.skeleton.free(allocator);
	foreach (n : self.names) if (n.len > 0) n.free(allocator);
	if (self.names.len > 0) alloc::free(allocator, self.names);
	free_joint_rests(allocator, self.rest);
	free_animations(allocator, self.clips);
	*self = {};
}

<* The node called `name`, or -1. *>
fn sz gltf_node_named(gltf::GltfStream* stream, String name)
{
	foreach (usz i, &n : stream.gltf.nodes) if (n.name == name) return (sz)i;
	return -1;
}

<*
 The skin a skinned mesh hanging off node `armature` uses, the first one found; -1 for none.

 @param [&inout] bounds : "Gets that skin's meshes' box, in their own space"
*>
fn int armature_skin(gltf::GltfStream* stream, uint armature, rig::Bounds* bounds)
{
	int skin = -1;
	bool boxed;
	foreach (&n : stream.gltf.nodes)
	{
		if (n.skin < 0 || n.mesh < 0 || n.parent == null || n.parent.index != armature) continue;
		if (skin >= 0 && n.skin != skin) continue;
		skin = n.skin;
		if ((usz)n.mesh >= (usz)stream.gltf.meshes.len()) continue;
		foreach (&p : stream.gltf.meshes[n.mesh].primitives)
		{
			sz? at = p.attributes.get("POSITION");
			if (catch at) continue;
			if (at < 0 || (usz)at >= (usz)stream.gltf.accessors.len()) continue;
			gltf::Accessor* a = &stream.gltf.accessors[at];
			Vec3 low = a.min.xyz;
			Vec3 high = a.max.xyz;
			*bounds = boxed ? (rig::Bounds){ math::min(bounds.min, low), math::max(bounds.max, high) } : (rig::Bounds){ low, high };
			boxed = true;
		}
	}
	return skin;
}

<*
 The names of a file's rigged characters: each node a skinned mesh hangs off, in the file's order.

 @return "The caller frees the array; the names are the stream's"
*>
fn String[] level_armatures(Allocator allocator, gltf::GltfStream* stream)
{
	List{String} found;
	found.init(allocator);
	defer found.free();
	foreach (&n : stream.gltf.nodes)
	{
		if (n.skin < 0 || n.mesh < 0 || n.parent == null) continue;
		String name = n.parent.name;
		bool seen;
		foreach (f : found) seen = seen || f == name;
		if (!seen && name.len > 0) found.push(name);
	}
	return found.len() > 0 ? found.to_array(allocator) : {};
}

<*
 Read the character whose armature is the node called `armature`: where it stands, its skin's
 joints in the armature's own space and at rest, and every animation of the file that drives
 them, read by the file's own names. Its clips keep the travel the file gives them.

 @param [&inout] stream
 @return? LEVEL_RIG_NO_ARMATURE : "The file has no node of that name"
 @return? LEVEL_RIG_NO_SKIN : "No skinned mesh hangs off it, or its joints would not read"
*>
fn LevelRig? read_level_rig(Allocator allocator, gltf::GltfStream* stream, String armature)
{
	sz node = gltf_node_named(stream, armature);
	if (node < 0) return LEVEL_RIG_NO_ARMATURE~;
	rig::Bounds bounds;
	int skin = armature_skin(stream, (uint)node, &bounds);
	if (skin < 0 || (usz)skin >= (usz)stream.gltf.skins.len()) return LEVEL_RIG_NO_SKIN~;

	usz count = (usz)stream.gltf.nodes.len();
	NodeTransform[] local = alloc::new_array(mem, NodeTransform, (sz)count);
	defer free(local);
	bool scaled;
	foreach (usz i, &n : stream.gltf.nodes) local[i] = node_rest(n, &scaled);
	NodeWorld[] world = file_world(mem, stream, local);
	defer free(world);
	NodeWorld placed = world[node];
	NodeWorld[] inside = alloc::new_array(mem, NodeWorld, (sz)count);
	defer free(inside);
	world_transforms(stream, local, inside, placed.inverse());

	AnimImportOptions own = { .skin = skin, .keep_source_names = true, .keep_root_travel = true,
		.armature_space = true, .armature = (uint)node };
	String[] names;
	usz[] joint_nodes;
	rig::Skeleton? read = read_rest_skeleton(allocator, stream, &names, 0, skin, own, &joint_nodes);
	if (catch read) return LEVEL_RIG_NO_SKIN~;
	defer if (joint_nodes.len > 0) alloc::free(allocator, joint_nodes);

	LevelRig out = {
		.armature = armature.copy(allocator),
		.position = placed.position,
		.rotation = placed.rotation,
		.scale = placed.scale,
		.bounds = bounds,
		.skeleton = read,
		.names = names,
	};

	List{uint} joints = stream.gltf.skins[skin].joints;
	out.rest = alloc::new_array(allocator, JointRest, (sz)joints.len());
	usz kept;
	foreach (jn : joints)
	{
		if ((usz)jn >= count) continue;
		gltf::Node* n = stream.gltf.nodes.get_ref((sz)jn);
		bool under_joint = n.parent != null && joints.contains(n.parent.index);
		NodeTransform at = local[jn];
		JointRest r = { .name = n.name.copy(allocator), .parent = under_joint ? n.parent.name.copy(allocator) : "".copy(allocator) };
		if (under_joint)
		{
			r.translation = at.translation;
			r.rotation = at.rotation;
			r.scale = at.scale;
		}
		else
		{
			r.translation = inside[jn].position;
			r.rotation = inside[jn].rotation;
			r.scale = inside[jn].scale;
		}
		out.rest[kept++] = r;
	}
	out.rest = out.rest[:kept];

	List{AnimTemplate} clips;
	clips.init(allocator);
	defer clips.free();
	foreach (usz i, anim : stream.gltf.animations)
	{
		if (is_rest_clip(stream, i) || !clip_drives_joints(anim, joint_nodes)) continue;
		AnimImportOptions take = own;
		take.index = (int)i;
		AnimTemplate? one = import_animation(allocator, stream, take);
		if (catch one) continue;
		clips.push(one);
	}
	if (clips.len() > 0) out.clips = clips.to_array(allocator);
	return out;
}
