<*
 The rig being edited: dots and the edges between them.

 A dot IS a joint — there is no template underneath, which is the whole reason
 crig can rig a goat and AccuRig cannot. The skeleton is derived from this on
 export (B6) rather than stored, so there is exactly one source of truth and no
 way for the two to disagree.

 Everything is addressed by `id`, never by index. Ids are handed out once and
 never reused, so a deletion cannot silently turn a held reference into a
 different dot — a stale id reads as "gone", which is what the selection and
 the undo stack (B5) both want from it. Id 0 is the null id.

 Positions are model space, the same space the mesh arrives in. M1 never
 normalizes, so there is no transform to remember.
*>
module crig;

import std::collections::list;


import std::math;
import std::math::quaternion;

alias DotList = List{Dot};
alias EdgeList = List{Edge};
alias AttachList = List{ShellAttachment};
alias PaintList = List{PaintDab};
alias PinList = List{VertexPin};
alias JiggleColliderList = List{JiggleCollider};
alias BoundList = List{BoundClip};
alias JointRotationLimitList = List{JointRotationLimits};
alias CollisionExclusionList = List{CollisionExclusion};

struct ProjectTransform
{
	Vec3 location;
	Quaternionf rotation;
}

fn Quaternionf ProjectTransform.orientation(self)
{
	return self.rotation.v.dot(self.rotation.v) > 1.0e-12f
		? self.rotation.normalize()
		: (Quaternionf)quaternion::IDENTITY;
}

fn bool ProjectTransform.valid(self)
{
	float[<4>] q = self.rotation.v;
	return math::is_finite(self.location.x) && math::is_finite(self.location.y)
		&& math::is_finite(self.location.z)
		&& math::is_finite(q.x) && math::is_finite(q.y)
		&& math::is_finite(q.z) && math::is_finite(q.w);
}

fn bool ProjectTransform.same(self, ProjectTransform other)
{
	return self.location == other.location
		&& self.orientation().v == other.orientation().v;
}

fn bool ProjectTransform.is_identity(self)
{
	Quaternionf identity = quaternion::IDENTITY;
	return self.location == (Vec3){}
		&& self.orientation().v == identity.v;
}

fn Vec3 ProjectTransform.point(self, Vec3 local)
{
	return self.location + self.orientation().rotate_vec3(local);
}

fn Vec3 ProjectTransform.inverse_point(self, Vec3 world)
{
	return self.orientation().invert().rotate_vec3(world - self.location);
}

fn Vec3 ProjectTransform.direction(self, Vec3 local)
{
	return self.orientation().rotate_vec3(local);
}

fn Vec3 ProjectTransform.inverse_direction(self, Vec3 world)
{
	return self.orientation().invert().rotate_vec3(world);
}

struct Dot
{
	uint id;
	Vec3 position;
	String name; // empty when unnamed (hand-placed dots); owned by the document

	<*
	 How far this dot's influence carries, in model units. Zero means no limit,
	 which is what every dot is until someone says otherwise.

	 The binder's falloff has no end of its own — `1 / (d^2 + eps)` is small far
	 away but never zero, and only the four-influence cut stops a dot pulling on
	 the whole mesh. That is how a dot buried between two others comes to own
	 almost nothing and still drag a third of the model about. A reach is the
	 answer to that, and the reason it is stored per dot rather than derived is
	 that the right distance is a fact about the character: how far a shoulder
	 should carry into a chest is not written anywhere in the geometry.
	*>
	float reach;
}

<*
 Undirected: `{a,b}` and `{b,a}` are the same edge, and the ops keep only one of
 them. Direction appears at export, when the BFS from the root turns edges into
 parent/child.
*>
struct Edge
{
	uint a, b;
}

<*
 A loose piece of the mesh pinned to a dot: the sword rides the spine, the hat
 rides the head.

 The binder decides this by itself for a piece nothing reaches — see
 `rig::rigid_shells` — and gets it right often enough to be the default and
 wrong often enough to need overriding. Which bone a prop hangs off is a fact
 about the character, not about the geometry: a sword across a back is nearest
 to a shoulder and strapped to the torso, and nothing in the mesh says so.

 **Keyed by dot id, never by joint index**, the same rule the paint layer will
 follow: joint indices are BFS output and shift the moment a dot is added,
 deleted or re-rooted, while ids are handed out once and never reused. The shell
 is an index into `rig::MeshShells`, which is derived from the mesh and is stable
 for as long as the mesh is.
*>
struct ShellAttachment
{
	uint shell;
	uint dot_id;
}

<*
 One vertex's correction to one dot's hold on it.

 **A multiplier, not a weight.** The binder returns `1 / (d² + ε)` —
 unnormalised, spanning orders of magnitude, and only ever read through
 `sparsify_weights`, which renormalises. So absolute scale is already meaningless
 and an *additive* correction would mean something quite different where the base
 is `1e-4` than where it is `1e2`. A multiplier means the same thing either side
 of the normalisation, which is the only kind of correction that survives the
 binder being changed underneath it.

 That is also what keeps the dots the source of truth. `final = base × paint`
 with `base` whatever the binder currently produces, so a dragged dot re-derives
 underneath a correction riding on top and no stroke has to be redone.

 **Keyed by dot id, never by joint index.** Indices are BFS output and shift the
 moment a dot is added or re-rooted; ids are handed out once and never reused.
 `RigView.paint` is where they become indices, for the one bind that asked.

 Absent is `1`, so the ordinary vertex costs nothing to store — a dense layer
 would be 24 MB on a 200k-vertex scan at 30 joints, 99% of it the number one.
*>
struct PaintDab
{
	uint vertex;
	uint dot_id;
	float factor;
}

<*
 A `PaintDab` with its dot id resolved to a joint index, for one bind.

 The document keys paint by dot id and a bind is indexed by joint, so somebody
 has to cross between them. Doing it once per bind rather than once per dab is
 what keeps a big stroke from going quadratic, and `RigView` — which exists to
 hold exactly the things that share a build's joint order — is where it happens.

 Not stored anywhere. A joint index is only meaningful for the build that
 produced it; see `RigView` on why mixing one build's order with another's is
 silent rather than loud.
*>
struct PaintColumn
{
	uint vertex;
	usz joint;
	float factor;
}

<*
 One vertex handed to one dot outright, or to a stated fraction of it.

 **A share, not a multiplier, and that is the whole difference from `PaintDab`.**
 A dab scales whatever the binder currently says, so it cannot lift a weight the
 binder left at zero — no finite multiplier reaches a share from nothing, which
 is exactly the leak a region tool is drawn to fix ("the wrong bone got none of
 this"). A pin states the answer instead: `pin_over` writes the column and
 rescales the rest of the row around it, so a vertex the flood never reached can
 still be given to the dot the user can see it belongs to.

 **Absolute, and it does not track the dot.** Move the dot afterwards and the
 pin says the same thing it said before, where a dab would re-derive underneath.
 That is the price of being able to state a value at all, and it is also what
 makes the smooth and harden ops possible — they bake a computed share, and a
 baked share that drifted with the rig would be a different answer every rebind.
	A pin is therefore work the user owns, like an animation key, rather than a correction
 riding on work the binder owns.

 `share` is 0 to 1 and is a share of the *vertex*, the same number every weight
 view and `sparsify_weights` normalise to. **Zero removes the entry** — the
 analog of paint's factor of 1 — so "is anything pinned" stays a length test and
 unpinning leaves nothing behind.

 **Keyed by dot id, never by joint index**, the rule every list in this file
 follows, and **keyed to the mesh** besides: a vertex index means nothing once a
 different model is loaded, or once the same one is re-exported with its
 vertices reordered. That caveat is inherited from the paint layer and is not
 fixed here.
*>
struct VertexPin
{
	uint vertex;
	uint dot_id;
	float share;
}

<*
 A `VertexPin` with its dot id resolved to a joint index, for one bind.

 `PaintColumn`'s sibling in every respect — see there for why the crossing
 happens once per bind rather than once per pin, and why none of these is ever
 stored.

 **Grouped by vertex**, which `PaintColumn` need not be: `pin_over` rewrites a
 whole row around the pins on it, so every pin on one vertex has to be in hand at
 once. `AppState.pin_columns` is what guarantees the grouping.
*>
struct PinColumn
{
	uint vertex;
	usz joint;
	float share;
}

<*
 One dab either side of a stroke, for the ledger.

 A stroke is thousands of these and one undo step, so `PAINT_STROKE` names a
 *range* of them rather than carrying any inline — `Edit.id` is where the range
 starts and `Edit.other` is how long it is.

 Both sides are stored rather than just the new one, because a stroke over
 already-painted mesh has a previous value per vertex that nothing else
 remembers. Recomputing it from the binder would give the base, not the
 correction that was there.
*>
struct PaintChange
{
	uint vertex;
	uint dot_id;
	float before;
	float after;
}

<*
 Whether these are the same four numbers, bit for bit.

 Spelled out because C3 gives a struct no `==` of its own, and exact rather than
 near: this asks whether two bones were given the same numbers, which is a
 question about what somebody wrote and not about how close two wobbles look.
*>
fn bool JiggleParams.same(self, JiggleParams other) => self.stiffness == other.stiffness
	&& self.damping == other.damping && self.gravity == other.gravity
	&& self.radius == other.radius;

<*
 Whether these params say nothing at all — the "this bone is the animation's"
 value, which the old per-dot model stored as absence and the migration skips.
*>
fn bool JiggleParams.inert(self) => self.same({});

<*
 One bone under the old per-dot model: the shape files before session version
 16 and every KHR_physics_rigid_bodies file still speak, and the input
 `secondary_chains_from_bones` turns into `SecondaryChain` records.

 The five numbers are `JiggleParams`, defined next to the solver in
 `anim/jiggle.c3` rather than here, because their units are the solver's and a
 second definition would be a second chance to disagree about what `stiffness`
 means. What this adds is only *which dot* carries them. Never stored on the
 document any more — see `RigDocument.secondary`.
*>
struct JiggleSpec
{
	uint dot_id;
	JiggleParams params;
}

<*
 One capsule the dynamic bones are pushed out of: the dot's own bone, from its
 joint to its tail, swept by `radius`.

 The bone rather than a free-standing shape, so a collider follows the animation
 for nothing — see `JiggleColliderSpec`, which is this with the dot id already
 resolved to a joint. A radius of zero is no collider at all and removes the
 entry.
*>
struct JiggleCollider
{
	uint dot_id;
	float radius;
}

<*
 Two skin regions the collision service is told never to test against each
 other, by the dots whose joints dominate them.

 The exceptional case the rules in `core/collision_policy.c3` cannot know
 about: a cape that is meant to hang through the arm it is skinned beside, a
 prop that lives inside the hand. Unordered, like an `Edge`, and the same two
 ids either way round name one exclusion. A pair naming the same dot twice is
 refused — a region never collides with itself under the ordinary rules, so
 there would be nothing for it to say.
*>
struct CollisionExclusion
{
	uint a, b;
}

struct RigDocument
{
	DotList dots;
	EdgeList edges;
	uint next_id;
	uint root_id; // 0 = empty document

	<*
	 Which dot each pinned shell rides. Absent means the binder decides.

	 Entries whose dot id no longer resolves are kept rather than swept: undo
	 restores a deleted dot under its old id, so the attachment comes back with
	 it for free. The session writer drops them on the way out, which is the
	 point where "deleted" has become permanent.
	*>
	AttachList attachments;

	<*
	 Hand corrections to the bind, sparse. Absent is 1 — no correction.

	 Stale entries wait rather than being swept, for the same reason the two
	 lists above keep theirs: undo restores a deleted dot under its old id and
	 the paint on it should come back too. The session writer drops them on the
	 way out, which is where "deleted" has become permanent.

	 **Keyed to the mesh as well as to the rig.** A vertex index means nothing
	 once a different model is loaded, and nothing here checks that — what makes
	 it safe is where it is stored, since the session file is already per-mesh.
	*>
	PaintList paint;

	<*
	 Vertices handed to a dot outright, sparse. Absent is "the layers below
	 decide" — see `VertexPin` for what one means and why it is not a correction.

	 **Applied last of everything**, after the binder, the sharpness and the
	 paint, so nothing downstream can clobber a fact the user stated. That order
	 is `pin_over`'s contract rather than this field's, but it is the reason the
	 layer is separate from `paint` instead of being a second kind of dab.

	 Stale entries wait rather than being swept, and vertex indices are keyed to
	 the mesh — both exactly as the paint layer above has them, and for the same
	 reasons.
	*>
	PinList pins;

	<*
	 The secondary-motion chains: which runs of bones the physics owns, and how
	 each run behaves. Absent is a bone the animation states outright.

	 Sparse and keyed by the root dot's id, the third such list in this struct,
	 and stale entries wait here rather than being swept for the same reason the
	 two above do: undo restores a deleted dot under its old id, and the tail
	 should come back wobbling. `jiggle_specs_from_document` skips whatever no
	 longer resolves — a root that is gone, a tip no longer under it — and the
	 session writer drops them on the way out, the point where "deleted" has
	 become permanent. The record itself is `core/secondary.c3`'s.
	*>
	SecondaryChainList secondary;

	<*
	 The capsules those chains are pushed out of, on exactly the same terms.

	 Separate from `secondary` rather than a flag on it because the two are
	 independent: a belly is a collider and never dynamic, a braid is dynamic and
	 collides with nothing, and a tail can be both.
	*>
	JiggleColliderList colliders;

	<*
	 Bone-local rotation limits, keyed by the dot whose joint they constrain.

	 Sparse for the same reason the chains are sparse: a rig with no
	 authored constraints stores nothing, and an entry for a deleted dot waits so
	 undo can bring it back with the dot. The session writer is where stale
	 entries are eventually dropped.

	 The values themselves live in `core/joint_limits.c3`, beside the frame math
	 that gives their X/Y/Z labels a stable meaning.
	*>
	JointRotationLimitList rotation_limits;

	<*
	 Region pairs the self-collision check is told to leave alone, keyed by dot
	 ids on each side — see `CollisionExclusion`.

	 Sparse for the reason the limits above are: a rig authored without any
	 stores nothing, and the default rules cover the common cases without an
	 entry. An exclusion naming a deleted dot waits here so undo can bring the
	 dot back still excluded; the session writer drops it once the deletion is
	 permanent. Not swept by `remove_dot`, unlike an edge, for exactly that
	 reason.
	*>
	CollisionExclusionList collision_exclusions;

	<*
	 Whether a pose gesture may drive the skin through itself.

	 Off is the default and the zero value, which is why the field is spelled
	 this way round: a fresh rig blocks. The character's choice rather than the
	 session's viewing state — an authoring constraint over its own surface —
	 so it is saved with the rig and not carried by the undo stack, on
	 `auto_connect`'s terms. *Prevent intersections* in the Animations pane is
	 what flips it; see `app/collision.c3`.
	*>
	bool allow_intersections;

	<*
	 How close counts as touching, as a fraction of the model's bounds
	 diagonal — the clearance every collision check is measured against. Zero
	 is unset and reads as `COLLISION_CLEARANCE`, the same convention
	 `sharpness` uses for the same reason: a zero-initialised document and
	 every session written before the field existed must mean the default.
	*>
	float collision_clearance;

	// B5 settings. Declared now so the operations that will read them have
	// somewhere to look, and so a session file written in B7 does not change
	// shape when they start being used.
	bool auto_connect;
	float sym_x;

	// A non-destructive placement of the complete character. Geometry, joints,
	// weights and authored motion remain in model space beneath it.
	ProjectTransform model_transform;

	<*
	 How crisp this model's blends are: the power every binder weight is raised
	 to before anything reads it. See `sharpen_weights`.

	 **Zero means unset and is read as 1**, the binder's own blend. That is not a
	 clamp for tidiness — a zero-initialised document is what every rig starts as
	 and what every session written before this field existed comes back as, and
	 reading that zero literally would flatten every weight to 1 and hand the
	 mesh to whichever joint the tie-break picked.

	 One number for the whole model rather than per dot. The thing it corrects is
	 a property of the *mesh* — a body assembled from solid pieces wants narrow
	 seams everywhere, an organic one wants none of this — so a per-dot version
	 would be forty copies of one decision.
	*>
	float sharpness;

	<*
	 Which body plan this rig was started from — an animation pack's plan tag.

	 Empty for a hand-built rig, and for every session written before this field
	 existed. Advisory, and deliberately so: nothing is derived from it except
	 which packs the library offers, and a rig that declares nothing is still
	 matched the older way, on names it has in common with a clip.

	 Not carried by the undo stack. Undoing a preset leaves the tag behind on an
	 empty document, which reads correctly for the wrong reason — every clip
	 greys out because no dot is named, not because the tag was cleared — and
	 applying any plan re-stamps it. Making it an `EditKind` would cost an enum
	 value, a second string on `Edit` and two branches in the ledger for a state
	 whose only wrong answer is invisible.
	*>
	String plan; // owned

	<*
	 Whether this rig's weights came out of the mesh's file rather than from
	 crig's binder — see `app/import_rig.c3`.

	 A record of where the rig came from, not a cache of what it holds: the weights
	 themselves live on `AppState` and are re-read from the file on every open, so
	 this is what tells the load to go looking for them.

	 It survives a rig edit on purpose, and is never cleared. Moving a dot does not
	 repaint anybody's weights, and dropping an imported binding because a joint
	 was nudged would throw away the thing the import was for. What decides per
	 bind is whether the columns still cover the rig — `AppState.imported_dense` —
	 so a flag left true over a rig the file can no longer describe costs a failed
	 lookup and nothing else.
	*>
	bool skin_from_file;

	<*
	 The clips the user has bound to this character, in the order they chose.

	 The working set: which of the library's animations belong to *this* rig, kept
	 so that it survives a restart and so that an export ships exactly it. Before
	 this existed the only such set was `AppState.export_clips`, which came into
	 being inside the export panel and died with the next `load_mesh` — so the
	 answer to "which animations does my character have" existed only during the
	 few seconds somebody was exporting.

	 **Named, not indexed.** An `AnimRef` is a pair of positions into
	 `AppState.packs`, and `load_packs` re-reads the whole library — so a reference
	 stored between runs would come back pointing at whatever landed in that slot.
	 A file path and a clip name are what the library can be searched for, which is
	 what `AppState.resolve_bound` does.

	 Not carried by the undo stack, on `plan`'s reasoning: binding is a choice
	 about the project rather than an edit to the rig, it is visible in a panel
	 that lists it, and unbinding is one click away.
	*>
	BoundList animations;

	<*
	 Library joints matched to this rig by hand, where the automatic match missed
	 or guessed wrong. Owned; replaced whole by `set_joint_maps`.
	*>
	JointMap[] joint_maps;

	// The pose library: named poses kept with the project. Owned; replaced whole
	// by `set_poses`.
	SavedPose[] poses;
}

<*
 One hand-made match: `source`, a joint of the library pack read from `file`,
 is played on this rig's joint `joint`. An empty `joint` means the source joint
 drives nothing. All three strings are owned.
*>
struct JointMap
{
	String file;
	String source;
	String joint;
}

// A path names a pack by path, or by file name when the library moved.
fn bool JointMap.names_pack(self, String path)
	=> self.file == path || base_name(self.file) == base_name(path);

fn JointMap[] copy_joint_maps(Allocator allocator, JointMap[] maps)
{
	if (maps.len == 0) return {};
	JointMap[] out = alloc::new_array(allocator, JointMap, maps.len);
	foreach (usz i, map : maps)
	{
		out[i] = { .file = map.file.copy(allocator), .source = map.source.copy(allocator),
			.joint = map.joint.copy(allocator) };
	}
	return out;
}

fn void free_joint_maps(Allocator allocator, JointMap[] maps)
{
	foreach (map : maps)
	{
		map.file.free(allocator);
		map.source.free(allocator);
		map.joint.free(allocator);
	}
	if (maps.len > 0) alloc::free(allocator, maps);
}

// Takes ownership of `maps`.
fn void RigDocument.set_joint_maps(&self, JointMap[] maps)
{
	free_joint_maps(mem, self.joint_maps);
	self.joint_maps = maps;
}

<*
 A named pose in the library: per-joint entries keyed by rig joint name, so it
 applies to any clip, and to another character named the same way. `name` and
 the entries' names are owned.
*>
struct SavedPose
{
	String name;
	AnimKeyDot[] dots;
}

fn SavedPose[] copy_saved_poses(Allocator allocator, SavedPose[] poses)
{
	if (poses.len == 0) return {};
	SavedPose[] out = alloc::new_array(allocator, SavedPose, poses.len);
	foreach (usz i, pose : poses)
	{
		out[i] = { .name = pose.name.copy(allocator),
			.dots = keyframe_copy(allocator, { .dots = pose.dots }).dots };
	}
	return out;
}

fn void SavedPose.free(&self, Allocator allocator)
{
	self.name.free(allocator);
	AnimKeyframe held = { .dots = self.dots };
	held.free(allocator);
	*self = {};
}

fn void free_saved_poses(Allocator allocator, SavedPose[] poses)
{
	foreach (&pose : poses) pose.free(allocator);
	if (poses.len > 0) alloc::free(allocator, poses);
}

// Takes ownership of `poses`.
fn void RigDocument.set_poses(&self, SavedPose[] poses)
{
	free_saved_poses(mem, self.poses);
	self.poses = poses;
}

<*
 One clip bound to this character: which file it lives in, and what it is called
 there.

 Both strings are owned by the document. `file` is the library `.glb` the clip
 was found in and is **empty for the authored pack**, which has no file — an
 authored clip that has not been saved into a pack cannot be resolved on a later
 run, and that is the honest answer rather than a dangling path.
*>
struct BoundClip
{
	String file; // owned; empty = the in-memory authored pack
	String clip; // owned
}

<*
 Bind a clip to this character, or report that it already was.

 Order is the user's, so this appends rather than sorting: the list is what the
 Animations panel shows and what an export walks, and both read better in the
 order somebody chose than in any order the program could pick.

 @return `False when this exact clip is already bound; nothing is added twice.`
*>
fn bool RigDocument.bind_clip(&self, String file, String clip)
{
	if (clip.len == 0) return false;
	if (self.bound_index(file, clip) >= 0) return false;

	self.animations.push({
		.file = file.len > 0 ? file.copy(mem) : "",
		.clip = clip.copy(mem),
	});
	return true;
}

<*
 Where a clip sits in the bound list, or -1.

 By file *and* name, because two packs may hold a clip of the same name and
 binding one must not report the other as already there.
*>
fn sz RigDocument.bound_index(&self, String file, String clip)
{
	foreach (sz i, bound : self.animations.array_view())
	{
		if (bound.file == file && bound.clip == clip) return i;
	}
	return -1;
}

<*
 Drop the bound clip at `index`, releasing the strings it owned.

 @return `False when there is no such entry.`
*>
fn bool RigDocument.unbind_at(&self, sz index)
{
	if (index < 0 || index >= self.animations.len()) return false;

	BoundClip* going = self.animations.get_ref(index);
	if (going.file.len > 0) alloc::free(mem, going.file.ptr);
	if (going.clip.len > 0) alloc::free(mem, going.clip.ptr);
	self.animations.remove_at(index);
	return true;
}

<*
 Move a bound clip to another position, carrying the entry with it.

 The panel's reorder. A no-op for an index that does not move or does not exist,
 rather than a refusal: this is a drag landing where it started.
*>
fn bool RigDocument.reorder_bound(&self, sz from, sz to)
{
	sz count = self.animations.len();
	if (from < 0 || from >= count || to < 0 || to >= count || from == to) return false;

	BoundClip moving = self.animations[from];
	self.animations.remove_at(from);
	self.animations.insert_at(to, moving);
	return true;
}

fn void RigDocument.free_animations(&self)
{
	foreach (bound : self.animations.array_view())
	{
		if (bound.file.len > 0) alloc::free(mem, bound.file.ptr);
		if (bound.clip.len > 0) alloc::free(mem, bound.clip.ptr);
	}
	self.animations.clear();
}

<*
 Record which body plan this rig came from, replacing whatever was there.
*>
fn void RigDocument.set_plan(&self, String plan)
{
	if (self.plan.len > 0) alloc::free(mem, self.plan.ptr);
	self.plan = plan.len > 0 ? plan.copy(mem) : "";
}

fn void RigDocument.free(&self)
{
	foreach (&dot : self.dots.array_view())
	{
		if (dot.name.len > 0) alloc::free(mem, dot.name.ptr);
	}
	self.dots.free();
	self.edges.free();
	self.attachments.free();
	self.paint.free();
	self.pins.free();
	self.secondary.free();
	self.colliders.free();
	self.rotation_limits.free();
	self.collision_exclusions.free();
	self.free_animations();
	self.animations.free();
	free_joint_maps(mem, self.joint_maps);
	free_saved_poses(mem, self.poses);
	if (self.plan.len > 0) alloc::free(mem, self.plan.ptr);
	*self = { };
}

<*
 The dot a shell is pinned to, or 0 when the binder is left to decide.
*>
fn uint RigDocument.attachment_of(&self, uint shell)
{
	foreach (entry : self.attachments.array_view())
	{
		if (entry.shell == shell) return entry.dot_id;
	}
	return 0;
}

<*
 Pins a shell to a dot, or unpins it.

 A dot that does not exist is refused, so an attachment always names something
 at the moment it is made — an id can stop resolving later, when the dot is
 deleted, and that is the case the entry is deliberately kept for.

 @param dot_id : `The dot the shell should ride; 0 hands it back to the binder.`
 @return `True if this changed anything.`
*>
fn bool RigDocument.attach_shell(&self, uint shell, uint dot_id)
{
	if (dot_id != 0 && !self.find(dot_id)) return false;

	foreach (sz i, entry : self.attachments.array_view())
	{
		if (entry.shell != shell) continue;
		if (entry.dot_id == dot_id) return false;

		if (dot_id == 0)
		{
			self.attachments.remove_at(i);
		}
		else
		{
			self.attachments.get_ref(i).dot_id = dot_id;
		}
		return true;
	}

	if (dot_id == 0) return false;
	self.attachments.push({ .shell = shell, .dot_id = dot_id });
	return true;
}

<*
 Adds a dot. The first one in an empty document becomes the root, because a
 skeleton needs one and the first dot the user places is the only defensible
 guess; B5 lets them move it.

 @param position : `Model space.`
 @return `The new dot's id, never 0.`
*>
fn uint RigDocument.add_dot(&self, Vec3 position, String name = "")
{
	// Pre-increment, so a zero-initialised document hands out 1 first and 0
	// stays available as the null id.
	self.next_id++;
	String owned = (String)@clone_slice((char[])name);
	self.dots.push({ .id = self.next_id, .position = position, .name = owned });
	if (self.root_id == 0) self.root_id = self.next_id;
	return self.next_id;
}

<*
 @param id : `The dot to look up; 0 finds nothing.`
 @return `A pointer into the dot list, or null. Invalidated by any add or remove.`
*>
fn Dot* RigDocument.find(&self, uint id)
{
	if (id == 0) return null;
	foreach (&dot : self.dots.array_view()) if (dot.id == id) return dot;
	return null;
}

<*
 @return `True if the dot existed and moved.`
*>
fn bool RigDocument.move_dot(&self, uint id, Vec3 position)
{
	Dot* dot = self.find(id);
	if (!dot) return false;
	dot.position = position;
	return true;
}

<*
 Renames a dot, freeing whatever name it carried.

 A name is what a clip addresses a joint by — see `AnimTemplate` — so this is
 what makes a hand-placed dot animatable at all, and what corrects one a body
 plan named after the wrong side.

 Names are not checked for uniqueness here. Two dots of the same name is a rig
 that no clip can address unambiguously, and it is worth being able to reach that
 state through one edit while a rename is half done rather than being refused
 halfway through a swap.

 @param name : `Copied; empty un-names the dot, which is the hand-placed state.`
 @return `True if the dot existed.`
*>
fn bool RigDocument.rename_dot(&self, uint id, String name)
{
	Dot* dot = self.find(id);
	if (!dot) return false;

	if (dot.name.len > 0) alloc::free(mem, dot.name.ptr);
	dot.name = (String)@clone_slice((char[])name);
	return true;
}

<*
 Sets how far a dot's influence carries.

 Nothing is refused: a reach shorter than the dot's own bone leaves part of that
 bone unweighted, and a reach wide enough to cross the body puts it back where it
 started. Both are states a user can want on the way to a third one, and the
 weight views are what show them — see `Dot.reach`.

 @param reach : `Model units. Zero, or anything below it, is no limit.`
 @return `True if the dot existed.`
*>
fn bool RigDocument.set_reach(&self, uint id, float reach)
{
	Dot* dot = self.find(id);
	if (!dot) return false;
	dot.reach = reach > 0.0f ? reach : 0.0f;
	return true;
}

<*
 The narrowest and the widest blend the binder will be asked for.

 Not taste: the binder's scores span the 1e-6..1e6 range, and a power outside
 this band takes the ends of that range past what a float can hold — a row whose
 every entry has underflowed to zero is a vertex with no joint at all. Within it
 the arithmetic is safe on any bind crig produces, so the clamp is the whole
 validation and nothing downstream has to check again.
*>
const float SHARPNESS_MIN = 0.25;
const float SHARPNESS_MAX = 4.0;

<*
 Sets how crisp this model's blends are — see `RigDocument.sharpness`.

 Clamped rather than refused, on `set_reach`'s reasoning: a number outside the
 band is a user reaching past what the arithmetic can carry, not a different
 intention, and the weight views are what show them where they ended up.

 @param value : `The power. Anything at or below 0 stores 0, which is the unset state and is read as 1 — so "back to the binder's own blend" has a way to be said.`
 @return `True if anything changed.`
*>
fn bool RigDocument.set_sharpness(&self, float value)
{
	float want = value <= 0.0f
		? 0.0f
		: math::clamp(value, SHARPNESS_MIN, SHARPNESS_MAX);

	if (self.sharpness == want) return false;
	self.sharpness = want;
	return true;
}

<*
 The plane the mirror reflects across — the model-space X a left dot and its
 right twin sit even distances either side of.

 Set from the mesh's bounding-box centre by default, which is only the body's
 midline when the mesh is symmetric about it: a tail, an off-centre export or a
 hand-built skeleton on no mesh at all leaves that centre somewhere the rig is
 not. The mirror does not trust it blindly — it reads the midline off the rig's
 centre joints (`AppState.symmetry_plane`) and reflects across that when the two
 disagree — but this stays the settable fallback for a rig with no centre joint
 to derive one from.

 @return `False when nothing changed, or the value is not a finite number.`
*>
fn bool RigDocument.set_sym_x(&self, float x)
{
	if (!math::is_finite(x)) return false;
	if (math::abs(self.sym_x - x) < 1.0e-6f) return false;
	self.sym_x = x;
	return true;
}

<*
 Sets one vertex's correction to one dot's hold on it.

	 Absent means no correction. A factor of exactly 1 removes the entry rather than storing
 it, so "is anything painted" stays a length test and a stroke that puts a vertex
 back where the binder had it leaves nothing behind.

 Nothing is refused and nothing is clamped. A factor of 0 is a vertex this dot
 does not hold at all, and a large one is a vertex it holds far more of than the
 binder thought; both are things to want, and `sparsify_weights` normalising
 afterwards is what keeps either from meaning something absolute.

 @param vertex : `Index into the mesh this document was painted against.`
 @param factor : `Multiplier on the binder's weight. 1 is no correction. Negative is clamped to 0 — a weight below zero is not a lesser hold, it is a vertex pushed the wrong way.`
 @return `True if anything changed.`
*>
fn bool RigDocument.set_paint(&self, uint vertex, uint dot_id, float factor)
{
	if (dot_id == 0 || !self.find(dot_id)) return false;

	float held = factor > 0.0f ? factor : 0.0f;
	bool clean = held == 1.0f;

	foreach (sz i, dab : self.paint.array_view())
	{
		if (dab.vertex != vertex || dab.dot_id != dot_id) continue;
		if (dab.factor == held) return false;

		if (clean)
		{
			self.paint.remove_at(i);
		}
		else
		{
			self.paint.get_ref(i).factor = held;
		}
		return true;
	}

	if (clean) return false;
	self.paint.push({ .vertex = vertex, .dot_id = dot_id, .factor = held });
	return true;
}

<*
 What this vertex's correction to this dot is, or 1 where there is none.
*>
fn float RigDocument.paint_of(&self, uint vertex, uint dot_id)
{
	foreach (dab : self.paint.array_view())
	{
		if (dab.vertex == vertex && dab.dot_id == dot_id) return dab.factor;
	}
	return 1.0f;
}

<*
 Hands one vertex to one dot outright, or takes the hand-over back.

 The pin layer's primitive, and `set_paint`'s sibling — but what it stores is a
 *share* rather than a multiplier, so unlike a dab it can lift a vertex the
 binder gave this dot nothing of. See `VertexPin`, which states the bargain that
 buys: a pin is absolute and does not move with the dot.

 **A share of exactly 0 removes the entry**, the analog of paint's factor of 1,
 so "is anything pinned" stays a length test and unpinning a region leaves
 nothing behind. Anything outside 0 to 1 is clamped rather than refused: a share
 is a fraction of one vertex, and there is no reading of 1.4 that is not simply
 "all of it".

 A dot that does not exist is refused, so a pin always names something at the
 moment it is made — the `attach_shell` rule. An id can stop resolving later,
 when the dot is deleted, and that is the case the entry is kept for.

 **One at a time only.** A lasso is thousands of these and every call is a scan
 of the list, so a loop over this function is quadratic in the region — see
 `AppState.pin_dabs`, which is the bulk form and the only one any tool uses.

 @param vertex : `Index into the mesh this document was pinned against.`
 @param share : `0 to 1, the fraction of the vertex this dot ends up holding. 0 removes the pin.`
 @return `True if anything changed.`
*>
fn bool RigDocument.set_pin(&self, uint vertex, uint dot_id, float share)
{
	if (dot_id == 0 || !self.find(dot_id)) return false;

	float held = share;
	held = math::clamp(held, 0.0f, 1.0f);
	bool clean = held == 0.0f;

	foreach (sz i, pin : self.pins.array_view())
	{
		if (pin.vertex != vertex || pin.dot_id != dot_id) continue;
		if (pin.share == held) return false;

		if (clean)
		{
			self.pins.remove_at(i);
		}
		else
		{
			self.pins.get_ref(i).share = held;
		}
		return true;
	}

	if (clean) return false;
	self.pins.push({ .vertex = vertex, .dot_id = dot_id, .share = held });
	return true;
}

<*
 What this vertex is pinned to this dot at, or 0 where it is not pinned to it.

 **A single-read diagnostic, never a bulk path.** Every call walks the whole
 layer, so asking it once per vertex of a region is the quadratic this file's
 sparse storage would otherwise be free of. `AppState.pin_dabs` builds a
 per-vertex index once and answers the same question in one pass; anything
 touching more than a handful of vertices wants that.
*>
fn float RigDocument.pin_of(&self, uint vertex, uint dot_id)
{
	foreach (pin : self.pins.array_view())
	{
		if (pin.vertex == vertex && pin.dot_id == dot_id) return pin.share;
	}
	return 0.0f;
}

<*
 Sizes this dot's collider capsule, or removes it.

 @param radius : `Model units, swept around the dot's own bone. Zero, or anything below it, is no collider.`
 @return `True if this changed anything.`
*>
fn bool RigDocument.set_collider(&self, uint dot_id, float radius)
{
	if (dot_id == 0 || !self.find(dot_id)) return false;

	float held = radius > 0.0f ? radius : 0.0f;

	foreach (sz i, entry : self.colliders.array_view())
	{
		if (entry.dot_id != dot_id) continue;
		if (entry.radius == held) return false;

		if (held == 0.0f)
		{
			self.colliders.remove_at(i);
		}
		else
		{
			self.colliders.get_ref(i).radius = held;
		}
		return true;
	}

	if (held == 0.0f) return false;
	self.colliders.push({ .dot_id = dot_id, .radius = held });
	return true;
}

<*
 How fat this dot's collider is, or zero where it has none.
*>
fn float RigDocument.collider_of(&self, uint dot_id)
{
	foreach (entry : self.colliders.array_view())
	{
		if (entry.dot_id == dot_id) return entry.radius;
	}
	return 0.0f;
}

<*
 Removes a dot and every edge that touched it.

 Deleting the root hands the role to whatever dot is left rather than leaving
 the document rootless: an empty root would make the next export produce a
 skeleton the user never asked for. It is a guess, and B5's "set root" is the
 correction.

 @return `True if the dot existed.`
*>
fn bool RigDocument.remove_dot(&self, uint id)
{
	sz index = -1;
	foreach (i, dot : self.dots.array_view())
	{
		if (dot.id == id)
		{
			index = (sz)i;
			break;
		}
	}
	if (index < 0) return false;

	if (self.dots[(usz)index].name.len > 0) alloc::free(mem, self.dots[(usz)index].name.ptr);
	self.dots.remove_at(index);

	// Backwards: remove_at shifts everything after the hole down.
	for (sz e = self.edges.len() - 1; e >= 0; e--)
	{
		Edge edge = self.edges[e];
		if (edge.a == id || edge.b == id) self.edges.remove_at(e);
	}

	if (self.root_id == id) self.root_id = self.dots.len() > 0 ? self.dots[0].id : 0;
	return true;
}

<*
 Puts a dot back with the id it had.

 Undo needs this and `add_dot` cannot do it: `add_dot` mints a fresh id, while
 every edit recorded after the one being undone still names the old one. So the
 id has to survive the round trip or the rest of the stack stops referring to
 anything.

 Appends rather than restoring the dot's original index. List order only decides
 paint order, and the root is restored explicitly by whoever recorded the
 deletion rather than being inferred from position.

 @return `False if that id is already present, or is the null id.`
*>
fn bool RigDocument.insert_dot(&self, uint id, Vec3 position, String name = "", float reach = 0.0f)
{
	if (id == 0 || self.find(id)) return false;
	String owned = (String)@clone_slice((char[])name);
	self.dots.push({ .id = id, .position = position, .name = owned, .reach = reach });

	// A restored id can be above the counter when the edits either side of it
	// were undone too; letting it fall behind would hand the same id out twice.
	if (id > self.next_id) self.next_id = id;
	if (self.root_id == 0) self.root_id = id;
	return true;
}

<*
 Where the unordered pair {a, b} sits in a list of `.a`/`.b` entries — the
 edges or the collision exclusions — or -1.
*>
macro sz pair_index(list, uint a, uint b) @private
{
	foreach (sz i, entry : list.array_view())
	{
		if ((entry.a == a && entry.b == b) || (entry.a == b && entry.b == a)) return i;
	}
	return -1;
}

<*
 Add the pair {a, b} to `list` unless it names one dot twice, a missing dot,
 or is already there.
*>
macro bool add_pair(RigDocument* doc, list, uint a, uint b) @private
{
	if (a == b || a == 0 || b == 0) return false;
	if (!doc.find(a) || !doc.find(b)) return false;
	if (pair_index(list, a, b) >= 0) return false;
	list.push({ .a = a, .b = b });
	return true;
}

// Remove the pair {a, b} from `list`; false when it was not there.
macro bool remove_pair(list, uint a, uint b) @private
{
	sz at = pair_index(list, a, b);
	if (at < 0) return false;
	list.remove_at(at);
	return true;
}

fn bool RigDocument.has_edge(&self, uint a, uint b) => pair_index(&self.edges, a, b) >= 0;

<*
 @return `True if the edge was added; false if it already existed, was a self-loop, or named a missing dot.`
*>
fn bool RigDocument.connect(&self, uint a, uint b) => add_pair(self, &self.edges, a, b);

<*
 @return `True if the edge existed.`
*>
fn bool RigDocument.disconnect(&self, uint a, uint b) => remove_pair(&self.edges, a, b);

fn bool RigDocument.has_exclusion(&self, uint a, uint b) => pair_index(&self.collision_exclusions, a, b) >= 0;

<*
 Tells the collision service never to test the regions of these two dots
 against each other.

 @return `True if the exclusion was added; false if it already existed, named one dot twice, or named a missing dot.`
*>
fn bool RigDocument.add_exclusion(&self, uint a, uint b) => add_pair(self, &self.collision_exclusions, a, b);

<*
 @return `True if the exclusion existed.`
*>
fn bool RigDocument.remove_exclusion(&self, uint a, uint b) => remove_pair(&self.collision_exclusions, a, b);

// ---------------------------------------------------------------------------
// Undo (B5)

<*
 One reversible operation. The stack that holds these lands in B5, but the
 shape is here now: every op below already has to decide what it would record,
 and discovering that later means writing each one twice.
*>
enum EditKind
{
	ADD_DOT,
	DELETE_DOT,
	MOVE_DOT,
	RENAME_DOT,
	SET_REACH,
	SET_SHARPNESS,
	ADD_EDGE,
	DELETE_EDGE,
	SET_ROOT,
	ATTACH_SHELL,
	SET_SECONDARY,
	SET_COLLIDER,
	SET_ROTATION_LIMITS,
	ADD_EXCLUSION,
	DELETE_EXCLUSION,
	SET_SYM_X,
	SET_MODEL_TRANSFORM,

	// The whole model resized about its origin: the mesh, which the document does
	// not hold, and every length in the document with it. Replays at the app level
	// for the mesh's sake — see `AppState.scale_model_by` — though it has no payload
	// slot, so `carries_payload` stays false for it.
	SCALE_MODEL,

	// The three that carry a payload too big to sit in an `Edit`, and so replay
	// through `AppState.apply_one` rather than through `RigDocument.apply_edit` —
	// the stores hang off the undo stack, which the document cannot see. See
	// `carries_payload`.
	REPLACE_CLIP,
	REBIND_CLIP,
	PAINT_STROKE,
	PIN_STROKE,
	SET_JOINT_MAPS,
	SET_POSES,
}

<*
 Whether this kind keeps its payload in a store on the undo stack rather than
 inline.

 Two consequences, and they are the reason this is a predicate rather than two
 comparisons written out wherever they are needed. Such an edit **replays at the
 app level** — `RigDocument.apply_edit` cannot reach the stack, so both switches
 there refuse these — and it **owns slots that have to be released** with it, in
 `drop_last`.

 `Edit.id` names the payload either way: one slot for `REPLACE_CLIP` or
 `SET_ROTATION_LIMITS`, the start of a range of `Edit.other` of them for the two
 stroke kinds.
*>
fn bool EditKind.carries_payload(self) => self == REPLACE_CLIP || self == REBIND_CLIP || self == PAINT_STROKE
	|| self == PIN_STROKE || self == SET_ROTATION_LIMITS || self == SET_JOINT_MAPS
	|| self == SET_POSES;

<*
 Whether this kind of edit carries owned strings.

 Asked rather than spelled out, because the answer is needed in three places in
 `core/editing.c3` — `free`, `clear` and the tail `record` discards — and a kind
 that learns to carry a name while one of them still tests for the old two leaks
 silently, with nothing to see at the call site.

 `REPLACE_CLIP` carries the clip's name, which is the one thing its payload slot
 cannot supply: undoing a *create* finds the pack holding the clip and the slot
 holding nothing, and something still has to say which clip to take out.
*>
fn bool EditKind.carries_names(self) => self == ADD_DOT || self == DELETE_DOT
	|| self == RENAME_DOT || self == REPLACE_CLIP;

struct Edit
{
	EditKind kind;
	// The dot, or the edge's or exclusion's first endpoint, or ATTACH_SHELL's new dot — and for
	// REPLACE_CLIP, an index into `UndoStack.clips` rather than anything about a
	// dot at all. A payload too big to sit inline gets a slot and is named from
	// here; see `UndoStack`.
	uint id;
	uint other; // the edge's or exclusion's second endpoint, the previous root, or ATTACH_SHELL's previous dot
	uint shell; // ATTACH_SHELL: which piece of the mesh
	Vec3 before; // MOVE_DOT / DELETE_DOT: where it was
	Vec3 after; // MOVE_DOT / ADD_DOT: where it is
	String name; // the dot's name for ADD_DOT / DELETE_DOT / RENAME_DOT; owned by the Edit
	String prior_name; // RENAME_DOT: the name it carried before; owned by the Edit

	// SET_REACH both ways, and DELETE_DOT's `reach_before` so a dot comes back
	// carrying the reach it was deleted with rather than an unlimited one.
	float reach_before;
	float reach_after;

	// SET_SHARPNESS either side. Its own pair rather than the reach's, by the rule
	// the collider radius below is held to: a blend sharpness is not a distance,
	// and a second kind reading `reach_before` would give that field a meaning that
	// depends on `kind`. This one names no dot at all — `id` is unused for it,
	// since the setting is the model's rather than any joint's.
	float sharp_before;
	float sharp_after;

	// SET_SYM_X either side — the mirror plane, the model's rather than any dot's,
	// so `id` is unused for it, the same as SET_SHARPNESS. Its own pair rather than
	// the sharpness's, by the rule that struct keeps: a plane is not a blend power,
	// and a second kind reading `sharp_before` would give that field a meaning that
	// depends on `kind`.
	float sym_before;
	float sym_after;

	ProjectTransform transform_before;
	ProjectTransform transform_after;

	// SET_SECONDARY either side, and SET_COLLIDER's radius either side. Inline
	// like the reach above rather than folded into it: a chain record does not
	// fit in a `Vec3` pair, and a collider radius is not a reach — reusing
	// `reach_before` for it would give that field a second reading that depends on
	// the kind, which is the thing this struct has so far managed to avoid.
	//
	// Neither kind carries a name or a payload slot, so `carries_names` and
	// `carries_payload` are both false for them and `drop_last` has nothing to
	// release. **A deleted dot keeps both entries** — the `PaintDab` precedent,
	// see the note on `RigView.paint` — so undoing a delete brings the dot back
	// still wobbling, and every consumer skips entries whose dot is gone. For
	// SET_SECONDARY `id` is the chain's root, and a zero record on either side is
	// "no chain here".
	SecondaryChain secondary_before;
	SecondaryChain secondary_after;
	float collider_before;
	float collider_after;

	// SCALE_MODEL: the factor applied going forward; undo applies its reciprocal.
	// Its own field by the rule above: a factor is not a distance or a power.
	float scale;

	// True when this edit undoes together with the one after it. A mirrored
	// placement is two dots the user thinks of as one action, so one Ctrl+Z has
	// to remove both.
	bool chained;
}
