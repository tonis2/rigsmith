<* What a pack holds: clips, their rig and their tags. Reading and writing is src/format/pack.c3. *>
module crig;

import rig;
import gltf;
import std::sort;
import std::math::vector;
import std::math;
import std::collections::list;
import std::collections::object;
import std::encoding::json;
import std::core::string;
import std::math::matrix;
import std::math::quaternion;

alias AnimPackList = List{AnimPack};

alias StringList = List{String};

alias PresetList = List{Preset};

<*
 Which clip, said in a way that survives the library being reloaded around it.

 A pack and an index rather than a pointer or a name. A pointer into the library
 dies with the next reload, and names are not unique — one pack per body plan
 means there is a "Walk" in most of them, so anything comparing by name lights
 every one of them at once.

 `pack < 0` is "none", which is `NO_ANIM`.
*>
struct AnimRef
{
	int pack;
	int clip;
}

<*
 What a pack says about itself, on the way out.

 The write side of the root `extras` `read_pack` reads. Every field is optional:
 a meta with nothing in it writes no extras at all, which is the untagged pack —
 a legitimate thing to produce, and what `export_animations_glb` produces.
*>
struct AnimPackMeta
{
	String plan; // the body-plan tag a rig has to declare to be offered these clips
	String name; // display name; the reader falls back to the file stem without one
	String[] tags; // written as one comma-separated string
	uint version; // 0 writes PACK_VERSION

	// Joints a rig fitted to this plan does not have to carry — see
	// `PresetDot.optional`. Written as one comma-separated string like the tags,
	// and by name rather than by index so a pack that gains a joint does not
	// silently re-point them.
	String[] optional;
}

<*
 One animation pack, read off disk.

 `rest` and `joint_names` are the file's own skeleton, read the same way
 `import_animation` reads it, so the bone directions a clip was retargeted
 against and the ones a body plan would be derived from are the same numbers.

 `mesh` may be empty: a pack without a body still carries clips, and is still
 matched to a rig, but it cannot serve as a body plan — there is no box to
 measure its joints against. See `AnimPack.preset`.
*>
struct AnimPack
{
	String name; // display name; the file stem when the pack does not say
	String plan; // the body-plan tag, lowercased; "" = an untagged clip file
	String[] tags; // lowercased, in the order the file listed them
	String path; // where it was read from — a notice names it, a reload re-reads it
	uint version;

	AnimTemplate[] clips; // every animation in the file that converted

	rig::Skeleton rest; // parents precede children
	String[] joint_names; // one per joint, parallel to `rest.joints`

	// One flag per joint, parallel to the two above: whether the plan this pack
	// declares treats that joint as optional. Empty when the file said nothing,
	// which is the same as none — see `PACK_KEY_OPTIONAL`.
	bool[] joint_optional;

	<*
	 Which of this pack's bones the simulation owns, and the capsules they collide
	 with — read out of the file's KHR_physics_rigid_bodies, in the same joint
	 order as everything above.

	 Empty for every file that carries none, which is the same as saying "the animation
	 states every bone". Carried onto the document only when the pack's rig is
	 adopted — see `AppState.apply_preset` — because until then this is a library
	 entry and not the rig being edited.
	*>
	RigPhysics physics;

	<*
	 Reusable anatomical joint limits in this pack's joint order. This is kept
	 separate from `physics`: a constrained knee is stateless rig intent, while a
	 dynamic tail is secondary motion. P2/P3 populate this through the dedicated
	 KHR constraint writer/reader; an empty table is a pack with no constraints.
	*>
	ConstraintRig constraints;

	rig::TriMesh mesh; // the dummy body; `positions.len == 0` when there is none

	bool owned;

	// The parsed file, kept open when the pack was loaded with its clips deferred
	// (see `read_pack` `defer_clips`) so retargeting one on demand does not re-open
	// and re-parse the whole glb. `plan_match` is the body plan that read the
	// stubs, remembered so the on-demand import names joints the same way; -1 for
	// none. Closed by `AnimPack.free`.
	gltf::GltfStream stream;
	bool stream_held;
	int plan_match;
}

<*
 What reading a pack had to leave behind.

 Worth showing rather than keeping: a pack that comes back with `mesh_missing`
 carries clips but cannot be a body plan, and that is not something a user could
 work out from the file name.
*>
struct AnimPackReport
{
	usz clips_found; // animations in the file
	usz clips_read; // ones that converted
	usz joints;
	usz vertices;
	bool tagged; // carried a plan
	bool too_new; // declared a version this reader does not speak
	bool mesh_missing;

	// The body plan the file's rig turned out to be shaped like, if any, and
	// whether the plan below was inferred from that rather than read off the
	// file. Both worth showing: a pack that only matches a rig because crig
	// worked out what shape it was is a different claim from one that says so.
	String plan_matched;
	bool plan_inferred;

	usz constraints_read;
	usz constraints_foreign;
	usz constraint_cones;
	usz constraint_drives;
	usz constraint_graphs;
	usz constraints_skipped;
}

alias AnimDotList = List{AnimKeyDot};

<*
 Whether two references name the same clip in the same pack.
*>
fn bool AnimRef.same(self, AnimRef other) => self.pack == other.pack && self.clip == other.clip;

<*
 Whether this reference names anything at all.
*>
fn bool AnimRef.valid(self) => self.pack >= 0 && self.clip >= 0;

<*
 Release a pack and everything it owns. Safe on a pack that was never read.
*>
fn void AnimPack.free(&self, Allocator allocator)
{
	if (!self.owned) return;

	if (self.stream_held) { self.stream.close(); self.stream_held = false; }

	foreach (&clip : self.clips) clip.free(allocator);
	if (self.clips.len > 0) alloc::free(allocator, self.clips);

	foreach (name : self.joint_names) alloc::free(allocator, name.ptr);
	if (self.joint_names.len > 0) alloc::free(allocator, self.joint_names);
	if (self.joint_optional.len > 0) alloc::free(allocator, self.joint_optional);
	self.physics.free(allocator);
	self.constraints.free(allocator);

	foreach (tag : self.tags) alloc::free(allocator, tag.ptr);
	if (self.tags.len > 0) alloc::free(allocator, self.tags);

	self.rest.free(allocator);
	self.mesh.free(allocator);

	if (self.name.len > 0) alloc::free(allocator, self.name.ptr);
	if (self.plan.len > 0) alloc::free(allocator, self.plan.ptr);
	if (self.path.len > 0) alloc::free(allocator, self.path.ptr);

	*self = {};
}

<*
 Whether the pack can stand in for a body plan.

 It needs both a plan tag to be known by and a body to be measured against —
 see `AnimPack.preset` for why the body is not optional here even though a pack
 without one is still a perfectly good pack.
*>
fn bool AnimPack.is_body_plan(&self) => self.plan.len > 0 && self.mesh.positions.len > 0;

<*
 The pack's rest skeleton as a body plan, in the frame `fit_preset` reads:
 0 to 1 per axis, x across, y up, z head-ward.

 	`Preset plan = pack.preset(mem);`
 	`defer free_preset(mem, plan);`

 **Normalized against the body's bounds, not the skeleton's.** The tables in
 algo/match/presets.c3 are fractions of a *model's* box — a wrist at 0.86 across is
 0.86 of the figure's width — while the skeleton's own x extent is exactly wrist
 to wrist, which would put those wrists at 0 and 1 and hang them off the sides
 of every mesh the plan was fitted to. That is what makes the body load-bearing
 rather than decorative, and why a pack without one is not a body plan.

 `mirror` is false on every dot. `_L` and `_R` are separate joints in the file
 already, so letting `fit_preset` expand them would emit `wrist_L_L`.

 An axis the body has no extent on collapses to the middle rather than dividing
 by zero — a flat plan is a legitimate rig, and a set of wheels on one axle is a
 whole animation.

 The caller owns the table and its names; free it with `free_preset`.

 @require self.mesh.positions.len > 0 : `A pack with no body has no box to normalize against.`
*>
fn Preset AnimPack.preset(&self, Allocator allocator) => self.preset_in(allocator, self.mesh.bounds());

<*
 The same table, for a caller that only means to **match** against it.

 	`Preset plan = pack.match_plan(mem);`
 	`defer free_preset(mem, plan);`

 One difference, and it is why this is not just `preset` with the requirement
 dropped: a pack with no body is normalized against its own joints rather than
 refused. That would be wrong for a fit, for exactly the reason `preset` gives —
 a skeleton's x extent is wrist to wrist, so the wrists land at 0 and 1 and hang
 off the sides of the mesh. It is harmless for a match, because the matcher
 re-normalizes both sides against their own joint boxes before comparing them
 and `Preset.extent` is carried along to undo the per-axis divide either way.

 What it buys is the packs that are clips and nothing else — somebody's folder
 of downloaded animations, which have no mesh to measure and every reason to be
 retargeted onto the rig that is open. See `measure_reach`.
*>
fn Preset AnimPack.match_plan(&self, Allocator allocator)
{
	if (self.mesh.positions.len > 0) return self.preset(allocator);

	rig::Bounds box = { .min = { 0, 0, 0 }, .max = { 0, 0, 0 } };
	foreach (usz j, joint : self.rest.joints)
	{
		if (j == 0) { box = { .min = joint, .max = joint }; continue; }
		box.min = math::min(box.min, joint);
		box.max = math::max(box.max, joint);
	}
	return self.preset_in(allocator, box);
}

// The body of both of the above: the rest skeleton as fractions of `box`. Which
// box is the whole of the difference between them, and is the caller's to decide.
fn Preset AnimPack.preset_in(&self, Allocator allocator, rig::Bounds box)
{
	Vec3 extent = box.max - box.min;

	usz joints = self.rest.len();
	PresetDot[] dots = alloc::new_array(allocator, PresetDot, (sz)joints);

	for (usz j = 0; j < joints; j++)
	{
		Vec3 at = self.rest.joints[j] - box.min;
		dots[j] = {
			.name = self.joint_names[j].copy(allocator),
			.at = {
				extent.x > PACK_FLAT ? at.x / extent.x : 0.5f,
				extent.y > PACK_FLAT ? at.y / extent.y : 0.5f,
				extent.z > PACK_FLAT ? at.z / extent.z : 0.5f,
			},
			.parent = self.rest.parents[j],
			.mirror = false,
			.optional = j < self.joint_optional.len && self.joint_optional[j],
		};
	}

	// The box the fractions above are of, carried so the matcher can undo the
	// per-axis divide — see `Preset.extent`.
	return { .name = self.name, .plan = self.plan, .dots = dots, .extent = extent };
}

<*
 Whether this pack carries a tag, compared as the reader stored it.
*>
fn bool AnimPack.has_tag(&self, String tag)
{
	foreach (own : self.tags)
	{
		if (own == tag) return true;
	}
	return false;
}

alias AnimKeyframeList = List{AnimKeyframe};

// An axis narrower than this has no extent worth dividing by.
const float PACK_FLAT @local = 1.0e-6f;

alias AnimFloatList = List{float};

<*
 Release a table `AnimPack.preset` returned. Not for the tables in
 algo/match/presets.c3, whose names are string literals.
*>
fn void free_preset(Allocator allocator, Preset preset)
{
	foreach (dot : preset.dots)
	{
		if (dot.name.len > 0) alloc::free(allocator, dot.name.ptr);
	}
	if (preset.dots.len > 0) alloc::free(allocator, preset.dots);
}
