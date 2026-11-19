<*
 What an imported .glb is: a character, a level or a cutscene file, decided from its JSON alone.
 The gltf library drops a file's top-level extensions, so the JSON is read here.
*>
module crig;

import std::collections::list;
import std::collections::object;
import std::encoding::json;
import gltf_edit;

enum GlbKind
{
	CHARACTER,
	LEVEL,
	CUTSCENE,
}

<* What the rule counted. *>
struct GlbCensus
{
	// Distinct named nodes a skinned mesh hangs off, as `level_armatures` counts them.
	usz armatures;
	// Colliders and triggers on nodes that are neither a skin joint nor below one.
	usz loose_colliders;
}

<* The file is not there, or its JSON does not read. *>
excuse GLB_UNREADABLE;

<*
 Read the JSON of the .glb or .gltf at `path` and decide what it is; the buffer is not read.

 @param [out] census : "Gets what was counted; may be null"

 @return? GLB_UNREADABLE
*>
fn GlbKind? glb_kind(String path, GlbCensus* census = null)
{
	char[]? text = gltf_edit::glb_json_chunk(mem, path);
	if (catch text) return GLB_UNREADABLE~;
	defer alloc::free(mem, text);
	Object*? doc = json::parse(mem, (String)text);
	if (catch doc) return GLB_UNREADABLE~;
	defer doc.free();
	if (!doc.is_map()) return GLB_UNREADABLE~;
	return glb_kind_of(doc, census);
}

<*
 The rule: a root CUSTOM_cutscene extension is a cutscene; a collider outside a rig or two
 rigged armatures is a level; anything else is a character.

 @param [in] doc : "The file's parsed glTF JSON"
 @param [out] census : "Gets what was counted; may be null"
*>
fn GlbKind glb_kind_of(Object* doc, GlbCensus* census = null)
{
	GlbCensus counted;
	Object* nodes = member(doc, "nodes");
	usz count = nodes != null && nodes.is_array() ? (usz)nodes.get_len() : 0;
	sz[] parent = count > 0 ? mem::new_array(sz, (sz)count) : {};
	defer if (parent.len > 0) free(parent);
	bool[] joint = count > 0 ? mem::new_array(bool, (sz)count) : {};
	defer if (joint.len > 0) free(joint);
	foreach (&p : parent) *p = -1;
	for (usz i = 0; i < count; i++)
	{
		Object* children = member(nodes.get_at((sz)i), "children");
		if (children == null || !children.is_array()) continue;
		for (sz c = 0; c < children.get_len(); c++)
		{
			int child = children.get_int_at(c) ?? -1;
			if (child >= 0 && (usz)child < count) parent[child] = (sz)i;
		}
	}
	Object* skins = member(doc, "skins");
	if (skins != null && skins.is_array())
	{
		for (sz s = 0; s < skins.get_len(); s++)
		{
			Object* joints = member(skins.get_at(s), "joints");
			if (joints == null || !joints.is_array()) continue;
			for (sz j = 0; j < joints.get_len(); j++)
			{
				int at = joints.get_int_at(j) ?? -1;
				if (at >= 0 && (usz)at < count) joint[at] = true;
			}
		}
	}

	List{String} armatures;
	armatures.init(mem);
	defer armatures.free();
	for (usz i = 0; i < count; i++)
	{
		Object* node = nodes.get_at((sz)i);
		if (glb_has_collider(node) && !glb_in_rig(parent, joint, i)) counted.loose_colliders++;
		if (!glb_has_index(node, "mesh") || !glb_has_index(node, "skin") || parent[i] < 0) continue;
		Object* name = member(nodes.get_at(parent[i]), "name");
		if (name == null || !name.is_string() || name.s.len == 0 || armatures.contains(name.s)) continue;
		armatures.push(name.s);
	}
	counted.armatures = (usz)armatures.len();
	if (census != null) *census = counted;

	Object* cutscene = member(member(doc, "extensions"), CUTSCENE_EXTENSION);
	if (cutscene != null && cutscene.is_map()) return CUTSCENE;
	return counted.loose_colliders > 0 || counted.armatures >= 2 ? LEVEL : CHARACTER;
}

// A skin joint, or below one; a broken parent loop counts as outside.
fn bool glb_in_rig(sz[] parent, bool[] joint, usz node) @local
{
	sz at = (sz)node;
	for (usz steps = 0; at >= 0 && steps <= parent.len; steps++)
	{
		if (joint[at]) return true;
		at = parent[at];
	}
	return false;
}

fn bool glb_has_collider(Object* node) @local
{
	Object* body = member(member(node, "extensions"), "KHR_physics_rigid_bodies");
	return member(body, "collider") != null || member(body, "trigger") != null;
}

// A non-negative index under `key`, as the gltf library reads `mesh` and `skin`.
fn bool glb_has_index(Object* node, String key) @local
{
	if (member(node, key) == null) return false;
	int? at = node.get_int(key);
	if (catch at) return false;
	return at >= 0;
}
