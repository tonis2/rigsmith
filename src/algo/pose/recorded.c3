<* The pure half of src/app/recorded.c3: no state, undo or notices. *>
module crig;

import rig;
import std::math;

<*
 The joint above this one, walking the bones out from the root; 0 for the root
 and for a joint the root cannot reach.
*>
fn uint parent_dot(RigDocument* doc, uint id)
{
	uint root = doc.root_id;
	if (root == 0 || root == id || !doc.find(root)) return 0;

	DotIdList frontier;
	frontier.init(mem);
	defer frontier.free();
	DotIdList parents;
	parents.init(mem);
	defer parents.free();
	frontier.push(root);
	parents.push(0);

	for (sz head = 0; head < frontier.len(); head++)
	{
		uint at = frontier[head];
		foreach (edge : doc.edges.array_view())
		{
			uint next = edge.a == at ? edge.b : (edge.b == at ? edge.a : 0);
			if (next == 0 || next == parents[head]) continue;
			bool seen = false;
			foreach (known : frontier.array_view())
			{
				if (known == next) { seen = true; break; }
			}
			if (seen) continue;
			if (next == id) return at;
			frontier.push(next);
			parents.push(at);
		}
	}
	return 0;
}

<*
 How long a joint's own bone is: the segment to its primary child.

 The primary child is the one its rotation limits name; otherwise the child that
 carries on most nearly straight from the bone arriving at the joint; at the root,
 with nothing arriving, the shortest. A leaf's own bone is the one arriving at it.
*>
fn float own_bone_length(RigDocument* doc, uint id)
{
	Dot* dot = doc.find(id);
	if (!dot) return 0.0f;

	uint parent = parent_dot(doc, id);
	Dot* above = parent != 0 ? doc.find(parent) : null;
	uint primary = doc.rotation_limits_of(id).primary_child;

	Vec3 arriving = above ? (dot.position - above.position) : (Vec3){};
	float arriving_length = arriving.length();

	float chosen = 0.0f;
	float straightest = -2.0f;
	foreach (edge : doc.edges.array_view())
	{
		uint other = edge.a == id ? edge.b : (edge.b == id ? edge.a : 0);
		if (other == 0 || other == parent) continue;
		Dot* child = doc.find(other);
		if (!child) continue;

		Vec3 bone = child.position - dot.position;
		float length = bone.length();
		if (length <= 0.0f) continue;
		if (other == primary) return length;

		if (arriving_length > 0.0f)
		{
			float straight = bone.dot(arriving) / (length * arriving_length);
			if (straight <= straightest) continue;
			straightest = straight;
			chosen = length;
		}
		else if (chosen == 0.0f || length < chosen)
		{
			chosen = length;
		}
	}
	return chosen > 0.0f ? chosen : arriving_length;
}

<*
 A reach to start a joint at, when a rig has some reaches and not others.

 Sized from the joint's **own bone** — the segment to its primary child — with a
 little over, so the far end of that bone is still held. Not the longest edge
 touching the joint: a hips or chest joint touches a long spine or thigh, and
 sizing from that gave them a reach over half the body.

 A joint with no bones falls back to a tenth of the model.
*>
fn float default_reach(RigDocument* doc, rig::TriMesh* geometry, uint id)
{
	if (!doc.find(id)) return 0.0f;

	float own = own_bone_length(doc, id);
	if (own > 0.0f) return own * 1.5f;

	rig::Bounds box = geometry.bounds();
	Vec3 span = box.max - box.min;
	float size = span.max();
	return size > 0.0f ? size * 0.1f : 0.0f;
}
