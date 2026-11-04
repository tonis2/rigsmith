<* A rig's physics as a glTF file states it. *>
module crig;

import rig;
import gltf;
import std::math;
import std::math::vector;
import std::math::quaternion;
import std::core::string;
import std::collections::list;

<*
 One dynamic bone, keyed by joint index rather than by dot id.

 `JiggleSpec` with the crossing already made: the per-bone form the extension
 speaks, which a chain is expanded into on the way out and folded back from on
 the way in. Nothing in a file has ever heard of a dot, and a writer that took
 dot ids plus the map every time would be doing the resolve once per entry
 instead of once.
*>
struct JiggleJoint
{
	usz joint;
	JiggleParams params;
}

<*
 A rig's physics in joint order: what goes into a file and what comes back out
 of one.

 `colliders` is `JiggleColliderSpec`, the same joint-plus-radius pair
 `build_jiggle_sim` takes, so the read side of a `.glb` and the sim builder speak
 the same type and nothing has to translate between them.

 `skipped` is only ever filled by the read: how many physics objects in the file
 described something crig has no place for — a box collider, a body on a node
 that is not a bone. Worth counting rather than hiding, because a foreign file
 that comes back with half its setup is a different claim from one that comes
 back whole.
*>
struct RigPhysics
{
	JiggleJoint[] joints;
	JiggleColliderSpec[] colliders;
	usz skipped;
}

fn void RigPhysics.free(&self, Allocator allocator)
{
	if (self.joints.len > 0) alloc::free(allocator, self.joints);
	if (self.colliders.len > 0) alloc::free(allocator, self.colliders);
	*self = {};
}
