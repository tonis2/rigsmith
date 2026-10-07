<*
 Reading a glTF animation back out as an AnimTemplate.

 A .glb that carries a walk carries it as node channels: a curve per joint per
 property, in each bone's own local frame. A crig template is the same motion
 said differently — one rotation per named joint per keyframe, about a world
 axis through the joint. This turns the first into the second.

 	`AnimTemplate walk = crig::import_gltf_animation(mem, "walk.glb")!;`
 	`defer walk.free(mem);`

 **The conversion is exact.** Setting crig's joint palette equal to glTF's and
 solving gives, for a joint whose parent joint is `p`:

 	rotation = delta(p)^-1 * delta(j)          delta(j) = posed(j) * rest(j)^-1
 	offset   = delta(p)^-1 * (P(j) - P(p)) - (p(j) - p(p))

 where `posed`/`rest` are world orientations and `P`/`p` world positions. Every
 term comes from evaluating the file twice — once at rest, once at the sample
 time — so nothing here depends on how the exporter chose to orient its bones.
 That cancellation is the point: two tools that disagree about which way a
 femur's local X points produce the same template out of the same walk.

 **Names are the join.** A template keys on joint names, and applying one looks
 up the dots by name, so an imported walk plays on any rig that uses the source's
 names. Nothing has to match in count or order — a name the target lacks is a
 joint that stays at rest, a joint the template never mentions likewise. What it
 does assume is that the target hangs its joints off the same parents; a rig that
 puts the knee under the hips rather than under the thigh will compose the angles
 differently.

 A rig from an outside tool agrees with crig about neither, which would leave
 every downloaded clip naming joints no crig rig has. `core/joint_match.c3` is
 the answer, and it reads no names at all: a source rig shaped like a body plan
 has its joints carried onto that plan's dot names, and the links the plan has no
 dot for are folded out of the joint list here — before `collect_joints`, so
 their children reparent onto the nearest survivor and their motion composes into
 it rather than being dropped.

 **What does not survive.** A Pose carries a rotation and an offset per joint and
 nothing else, so scale channels are counted and dropped, and morph weights are
 ignored. Sampling is exact at the source's own keyframes for the linear curves
 that make up almost every exported clip; step curves are approximated and spline
 curves are sampled. The report says which of these happened.
*>
module crig;

import rig;
import gltf;
import std::math;
import std::math::vector;
import std::math::matrix;
import std::math::quaternion;
import std::collections::list;
import std::sort;
import std::io;
import std::io::path;
import std::core::string;



<*
 Raised when the file carries no animations at all.
*>
faultdef ANIM_NO_ANIMATIONS;

<*
 Raised when the requested animation index or name is not in the file.
*>
faultdef ANIM_NOT_FOUND;

<*
 Raised when nothing in the file can be used as a named joint.
*>
faultdef ANIM_NO_JOINTS;

<*
 Raised when the animation has no keys, or all of them at one instant.
*>
faultdef ANIM_NO_KEYFRAMES;

<*
 Raised when the clip moves a joint on a rig with no vertical extent, leaving
 nothing to measure the offset against. A flat rig that only turns things is
 fine, since it never needs the unit.
*>
faultdef ANIM_NO_HEIGHT;

<*
 Raised when a sampler stores its times or values as something other than
 floats. Legal in glTF for other channels, not for these.
*>
faultdef ANIM_SAMPLER_UNSUPPORTED;

alias AnimFloatList = List{float};
alias AnimDotList = List{AnimKeyDot};
alias AnimKeyframeList = List{AnimKeyframe};
alias AnimTemplateList = List{AnimTemplate};

// Times closer together than this are one key. Source clips are authored in
// seconds at video frame rates, so anything this close is the same instant
// arriving twice through two channels.
const float ANIM_TIME_EPSILON @local = 1.0e-6f;

// Rotations smaller than this, and offsets smaller than this as a fraction of
// rig height, are rest. Small enough to keep any motion an eye could catch,
// large enough to drop the joints an exporter writes out unchanged.
//
// Not file-local, unlike its neighbours: `anim/bake.c3` emits the same shape of
// clip from a simulation instead of from a file, and a bake that culled at a
// different threshold from an import would produce a clip that is denser or
// sparser for no reason a reader could find.
const float ANIM_REST_EPSILON = 1.0e-4f;

// How many samples to take across each source interval when the source's own
// keys stop describing the result — a spline's tangents, or a fold composing
// two curves the source interpolates apart from each other. Four keeps the
// shape without inflating a clip much.
const uint ANIM_SUBDIVIDE_SLICES @local = 4;

// Where in an interval a stepped value gives way to the next one, as a fraction
// from the far end. The player only knows how to slide between keyframes, so a
// hold is a long flat run and a short ramp rather than a true jump.
const float ANIM_STEP_EDGE @local = 0.02f;

<*
 Which animation to take and what to do with it.

 The zero value takes the first animation in the file, keyed to the first skin,
 with the clip's travel removed.
*>
struct AnimImportOptions
{
	int index;             // which animation, in file order
	String name;           // take the animation with this name instead; "" uses index
	int skin;              // which skin names the joints, in file order
	bool keep_root_travel; // leave the root where the clip carried it
	uint subdivide;        // samples per source interval; 0 chooses by curve type
	float epsilon;         // threshold for motion introduced by folded transforms; declared source channels always remain tracks; 0 chooses

	// The body plans this file's rig may be matched onto, by the shape of the two
	// skeletons — see core/joint_match.c3. Empty leaves the file's own joint names
	// alone, and so does `keep_source_names`, which is what a caller wants when it
	// is the names themselves being examined.
	Preset[] plans;
	bool keep_source_names;

	<*
	 Keep a joint the matched plan has no dot for, under its own name, instead of
	 folding it away.

	 A clip wants the fold: a plan dot's motion has to include whatever the links
	 below it were doing, and a joint the plan cannot name is a joint the clip
	 cannot key. A *rig* wants the opposite. Every joint of an imported skeleton is
	 a column of the file's weights, and one folded out here is a column with
	 nowhere to land — which is the whole reason `import_rig_from_source` used to
	 pass no plans at all.

	 With this set the two readers agree about names without disagreeing about
	 joints: the ones the plan covers take its words, so a clip named on that plan
	 finds them, and the rest keep the file's spelling and their weights.
	*>
	bool keep_unmatched;
}

<*
 What the import had to leave behind or approximate.

 Worth showing a user: an animation that arrives with `scale_channels` set is one
 that will look subtly wrong however good the rest of the conversion is, and
 that is not something they can work out from watching it.
*>
struct AnimImportReport
{
	usz joints;         // joints the template names
	usz keyframes;
	usz unnamed_joints; // skipped, since a template keys on names
	usz scale_channels; // dropped, since a Pose has no scale
	bool stepped;       // the source held values between keys; approximated
	bool cubic;         // the source used spline tangents; sampled
	bool scaled_rest;   // a joint rests scaled, so its world axes are approximate
	float height;       // the source rig's height, the unit `move` is in
	Vec3 root_travel;   // how far the clip carried the root, start to end
	bool travel_removed;

	// What matching the rig onto a body plan did, if it was matched at all.
	// `folded` counts the links the plan has no dot for, whose motion composed
	// into their children rather than being lost — see core/joint_match.c3.
	String plan_matched;  // the plan's name; "" when the file's own names were kept

	// The same plan's body-plan tag — `biped` where `plan_matched` is `Biped`.
	// Two fields because the two are read by different sorts of caller: one is
	// shown to a person and the other is compared against what a pack declares,
	// and `AppState.pack_matches` is a string equality that a display name loses.
	String plan_tag;
	usz matched_joints;
	usz folded_joints;
	bool folded_animated; // a fold cost the clip its exactness between keys; subdivided
}

// A node's own transform, relative to its parent.
struct NodeTransform
{
	Quaternionf rotation;
	Vec3 translation;
	Vec3 scale;
}

// A node's transform in world terms. Rotation is kept apart from the matrix it
// implies because the whole conversion is written in world orientations, and
// chaining quaternions keeps them normalized where extracting them from a
// product of matrices would not.
struct NodeWorld
{
	Quaternionf rotation;
	Vec3 position;
	Vec3 scale;
}

<*
 Open a .gltf or .glb, take one animation out of it, and close it again.

 The returned template owns everything it points at, including its joint names,
 so it outlives the file it came from.

 @param report : `Filled in with what was approximated or dropped, if given.`
 @return? ANIM_NO_ANIMATIONS : `The file carries no animations.`
 @return? ANIM_NOT_FOUND : `No animation matches the options.`
 @return? ANIM_NO_JOINTS : `Nothing in the file can serve as a named joint.`
 @return? ANIM_NO_KEYFRAMES : `The animation has no keys, or all of them at one instant.`
 @return? ANIM_NO_HEIGHT : `The clip moves a joint on a rig with no height to measure it against.`
 @return? ANIM_SAMPLER_UNSUPPORTED : `A sampler stores its times or values as something other than floats.`
*>
fn AnimTemplate? import_gltf_animation(
	Allocator allocator,
	String path,
	AnimImportOptions options = {},
	AnimImportReport* report = null)
{
	gltf::GltfStream stream = gltf::open(path, allocator)!;
	defer stream.close();

	return import_animation(allocator, &stream, options, report);
}

<*
 Take one animation out of an already-open stream.

 Loads the buffers that animation needs; the caller does not have to have loaded
 anything.

 @param report : `Filled in with what was approximated or dropped, if given.`
 @return? ANIM_NO_ANIMATIONS : `The file carries no animations.`
 @return? ANIM_NOT_FOUND : `No animation matches the options.`
 @return? ANIM_NO_JOINTS : `Nothing in the file can serve as a named joint.`
 @return? ANIM_NO_KEYFRAMES : `The animation has no keys, or all of them at one instant.`
 @return? ANIM_NO_HEIGHT : `The clip moves a joint on a rig with no height to measure it against.`
 @return? ANIM_SAMPLER_UNSUPPORTED : `A sampler stores its times or values as something other than floats.`
*>
fn AnimTemplate? import_animation(
	Allocator allocator,
	gltf::GltfStream* stream,
	AnimImportOptions options = {},
	AnimImportReport* report = null)
{
	usz available = (usz)stream.gltf.animations.len();
	if (available == 0) return ANIM_NO_ANIMATIONS~;

	usz pick = available;
	if (options.name.len > 0)
	{
		for (usz i = 0; i < available; i++)
		{
			if (stream.gltf.animations[(sz)i].name == options.name)
			{
				pick = i;
				break;
			}
		}
	}
	else if (options.index >= 0 && (usz)options.index < available)
	{
		pick = (usz)options.index;
	}
	if (pick >= available) return ANIM_NOT_FOUND~;

	stream.load_animation_buffers((uint)pick)!;
	gltf::Animation anim = stream.gltf.animations[(sz)pick];

	AnimImportReport tally = {};

	// --- rest ---------------------------------------------------------------

	usz nodes = (usz)stream.gltf.nodes.len();
	if (nodes == 0) return ANIM_NO_JOINTS~;

	NodeTransform[] rest_local = alloc::new_array(allocator, NodeTransform, (sz)nodes);
	NodeWorld[] rest_world = alloc::new_array(allocator, NodeWorld, (sz)nodes);
	NodeTransform[] posed_local = alloc::new_array(allocator, NodeTransform, (sz)nodes);
	NodeWorld[] posed_world = alloc::new_array(allocator, NodeWorld, (sz)nodes);
	defer
	{
		alloc::free(allocator, rest_local);
		alloc::free(allocator, rest_world);
		alloc::free(allocator, posed_local);
		alloc::free(allocator, posed_world);
	}

	for (usz i = 0; i < nodes; i++)
	{
		rest_local[i] = node_rest(stream.gltf.nodes.get_ref((sz)i), &tally.scaled_rest);
	}
	// Once for the rest and every sample alike, so every pose is read through the
	// same turn.
	NodeWorld origin = source_origin(stream);
	world_transforms(stream, rest_local, rest_world, origin);

	// --- joints -------------------------------------------------------------

	usz[] joint_node = alloc::new_array(allocator, usz, (sz)nodes);
	int[] joint_parent = alloc::new_array(allocator, int, (sz)nodes);
	bool[] wanted = alloc::new_array(allocator, bool, (sz)nodes);
	defer
	{
		alloc::free(allocator, joint_node);
		alloc::free(allocator, joint_parent);
		alloc::free(allocator, wanted);
	}

	mark_joints(stream, anim, options, wanted, &tally.unnamed_joints);

	// What each node answers to on the target plan, and which nodes are still
	// joints once the plan's missing links have been folded out. Between marking
	// and collecting because collecting is what reparents a folded joint's
	// children onto the nearest survivor, which is what composes the fold rather
	// than dropping it. See core/joint_alias.c3.
	String[] node_label = alloc::new_array(allocator, String, (sz)nodes);
	defer alloc::free(allocator, node_label);
	apply_joint_map(allocator, stream, anim, rest_world, options, wanted, node_label, &tally);

	usz joints = 0;
	for (usz i = 0; i < nodes; i++)
	{
		if (stream.gltf.nodes.get_ref((sz)i).parent == null)
		{
			collect_joints(stream, (uint)i, -1, wanted, joint_node, joint_parent, &joints);
		}
	}
	if (joints == 0) return ANIM_NO_JOINTS~;

	// The source rig as a skeleton, so the height and the bone directions come
	// from the same code the player uses on the target rig. Two definitions of
	// "which way does this bone point" would retarget against each other.
	rig::Skeleton source = {
		.joints = alloc::new_array(allocator, Vec3, (sz)joints),
		.parents = alloc::new_array(allocator, int, (sz)joints),
	};
	defer source.free(allocator);
	float epsilon = options.epsilon > 0.0f ? options.epsilon : ANIM_REST_EPSILON;
	for (usz j = 0; j < joints; j++)
	{
		source.joints[j] = rest_world[joint_node[j]].position;
		source.parents[j] = joint_parent[j];
	}

	// Height is only ever the unit an offset is measured in, so a rig that has
	// none is refused further down and only if the clip turns out to have offsets
	// to store. Plenty of rigs are flat — a set of wheels turning on one axle is
	// a whole animation — and refusing those outright would be refusing them for
	// a field they never use.
	float height = source.height();
	tally.height = height;

	Vec3[] bones = source.bone_directions(allocator);
	defer alloc::free(allocator, bones);

	// --- when to sample -----------------------------------------------------

	AnimFloatList sampled;
	sampled.init(allocator);
	defer sampled.free();
	sample_times(stream, anim, options, allocator, &sampled, &tally)!;

	usz samples = (usz)sampled.len();
	if (samples < 2) return ANIM_NO_KEYFRAMES~;

	float start = sampled[0];
	float duration = sampled[(sz)(samples - 1)] - start;
	if (duration <= 0.0f) return ANIM_NO_KEYFRAMES~;

	// --- convert ------------------------------------------------------------

	// Held whole rather than emitted frame by frame, because stripping the
	// clip's travel is a decision about the root across every sample at once.
	Quaternionf[] turns = alloc::new_array(allocator, Quaternionf, (sz)(joints * samples));
	Quaternionf[] deltas = alloc::new_array(allocator, Quaternionf, (sz)joints);
	defer alloc::free(allocator, deltas);
	Vec3[] slides = alloc::new_array(allocator, Vec3, (sz)(joints * samples));
	bool[] rotation_track = alloc::new_array(allocator, bool, (sz)joints);
	bool[] translation_track = alloc::new_array(allocator, bool, (sz)joints);
	AnimInterpolation[] rotation_interpolation = alloc::new_array(allocator, AnimInterpolation, (sz)joints);
	AnimInterpolation[] translation_interpolation = alloc::new_array(allocator, AnimInterpolation, (sz)joints);
	defer
	{
		alloc::free(allocator, turns);
		alloc::free(allocator, slides);
		alloc::free(allocator, rotation_track);
		alloc::free(allocator, translation_track);
		alloc::free(allocator, rotation_interpolation);
		alloc::free(allocator, translation_interpolation);
	}
	foreach (channel : anim.channels)
	{
		if (channel.target.path != gltf::AnimationProperty.ROTATION
			&& channel.target.path != gltf::AnimationProperty.TRANSLATION) continue;
		for (usz j = 0; j < joints; j++)
		{
			if (joint_node[j] != channel.target.node) continue;
			if (channel.target.path == gltf::AnimationProperty.ROTATION)
			{
				rotation_track[j] = true;
				if (!tally.folded_animated
					&& anim.samplers[channel.sampler].interpolation == gltf::Interpolation.STEP)
				{
					rotation_interpolation[j] = HOLD;
				}
			}
			else
			{
				translation_track[j] = true;
				if (!tally.folded_animated
					&& anim.samplers[channel.sampler].interpolation == gltf::Interpolation.STEP)
				{
					translation_interpolation[j] = HOLD;
				}
			}
			break;
		}
	}

	for (usz s = 0; s < samples; s++)
	{
		posed_local[:nodes] = rest_local[:nodes];
		apply_channels(stream, anim, sampled[(sz)s], posed_local, &tally.scale_channels);
		world_transforms(stream, posed_local, posed_world, origin);

		for (usz j = 0; j < joints; j++)
		{
			usz node = joint_node[j];
			deltas[j] = posed_world[node].rotation.mul(rest_world[node].rotation.invert()).normalize();
		}
		for (usz j = 0; j < joints; j++)
		{
			deltas[j] = body_turn(j, deltas[j], joint_parent[:joints], joint_node[:joints],
				rest_world, posed_world, height > 0.0f ? height : 1.0f);
		}

		for (usz j = 0; j < joints; j++)
		{
			usz node = joint_node[j];
			Quaternionf delta = deltas[j];

			// A root joint answers to nothing above it, which is exactly what the
			// palette assumes: it hangs off the origin with no parent transform.
			Quaternionf parent_delta = quaternion::IDENTITY;
			Vec3 parent_posed = { 0, 0, 0 };
			Vec3 parent_rest = { 0, 0, 0 };
			if (joint_parent[j] >= 0)
			{
				usz parent = (usz)joint_parent[j];
				usz parent_node = joint_node[parent];
				// Still the parent's world delta: joints are ordered
				// parents-before-children, so this was written earlier in this same
				// pass and the pass below has not rewritten it yet.
				parent_delta = turns[s * joints + parent];
				parent_posed = posed_world[parent_node].position;
				parent_rest = rest_world[parent_node].position;
			}

			Quaternionf inverse_parent = parent_delta.invert();
			turns[s * joints + j] = delta;
			slides[s * joints + j] =
				inverse_parent.rotate_vec3(posed_world[node].position - parent_posed)
				- (rest_world[node].position - parent_rest);
		}

		// Second pass over the same sample: the entries above store each joint's
		// world delta, which is what a child needs from its parent. Turning them
		// into the parent-relative rotations a Pose holds can only happen once
		// every parent in the frame has been written.
		for (usz j = joints; j > 0; j--)
		{
			usz index = j - 1;
			if (joint_parent[index] < 0) continue;
			Quaternionf parent_delta = turns[s * joints + (usz)joint_parent[index]];
			turns[s * joints + index] = parent_delta.invert().mul(turns[s * joints + index]).normalize();
		}
	}

	// A flat rig can carry a clip that turns things, but not one that moves them:
	// there is no length in it to say how far "a fiftieth of the rig" is. Asked
	// now, when the offsets are known, rather than guessed at from the rig alone.
	if (height <= 0.0f)
	{
		foreach (slide : slides)
		{
			if (slide.length() > 0.0f) return ANIM_NO_HEIGHT~;
		}
		height = 1.0f;
	}
	for (usz j = 0; j < joints; j++)
	{
		for (usz s = 0; s < samples; s++)
		{
			Vec4 turn = shortest_turn(turns[s * joints + j]).to_axis_angle();
			if (turn.w >= epsilon) rotation_track[j] = true;
			if (slides[s * joints + j].length() >= epsilon * height) translation_track[j] = true;
		}
	}

	tally.root_travel = root_travel(slides, joint_parent, joints, samples);

	// Measured against the rig rather than against zero: every clip drifts a
	// little, and taking a millimetre off a two-metre figure would only add
	// noise to a walk that was already authored in place.
	if (!options.keep_root_travel && tally.root_travel.length() > height * 1.0e-4f)
	{
		strip_root_travel(slides, joint_parent, joints, samples, sampled, tally.root_travel);
		tally.travel_removed = true;
	}

	// --- emit ---------------------------------------------------------------

	AnimKeyframe[] keyframes = alloc::new_array(allocator, AnimKeyframe, (sz)samples);

	for (usz s = 0; s < samples; s++)
	{
		AnimDotList dots;
		dots.init(allocator);

		for (usz j = 0; j < joints; j++)
		{
			// Axis in xyz, angle in w, and never a negative angle: acos answers
			// within half a circle and `shortest_turn` keeps the scalar part in the
			// half that maps there.
			Vec4 turn = shortest_turn(turns[s * joints + j]).to_axis_angle();
			Vec3 move = slides[s * joints + j] / height;

			if (!rotation_track[j] && !translation_track[j]) continue;

			dots.push({
				.joint_name = node_label[joint_node[j]].copy(allocator),
				.axis = turn.xyz,
				.angle = turn.w,
				.move = move,
				.bone = bones[j],
				.rotation_interpolation = rotation_interpolation[j],
				.translation_interpolation = translation_interpolation[j],
				.channels = rotation_track[j] && translation_track[j]
					? BOTH : (rotation_track[j] ? ROTATION : TRANSLATION),
			});
		}

		keyframes[s] = { .time = sampled[(sz)s] - start, .dots = dots.to_array(allocator) };
		dots.free();
	}

	tally.joints = joints;
	tally.keyframes = samples;
	if (report) *report = tally;

	String label = clip_label(allocator, stream, anim, pick);
	AnimTemplate imported = {
		.name = label,
		.duration = duration,
		.keyframes = keyframes,
		.loop = true,
		.owned = true,
	};
	imported.compile_tracks(allocator);
	return imported;
}

<*
 How many animations a file carries, without taking any of them.

 For a chooser: opening a file is cheap, and knowing there are three walks in it
 before committing to one is the difference between a list and a guess.
*>
fn usz gltf_animation_count(gltf::GltfStream* stream) => (usz)stream.gltf.animations.len();

<*
 What a clip is called, from the glTF alone — no retarget needed.

 Its own name when the file gave it one, and otherwise the name the asset index
 invents for this very clip — see `unnamed_asset_name`, which the two share for
 exactly this reason. Kept in one place so a lazily-stubbed pack and a fully
 imported one name the same clip identically, which is what lets a binding stored
 against the stub resolve once the clip is read.
*>
fn String clip_label(Allocator allocator, gltf::GltfStream* stream, gltf::Animation anim, usz pick)
{
	if (anim.name.trim().len > 0) return anim.name.trim().copy(allocator);
	String stem = stem_of(allocator, stream.source_path);
	defer alloc::free(allocator, stem.ptr);
	return unnamed_asset_name(allocator, stem, pick);
}

<*
 The file's rest hierarchy as a skeleton, and a name for each joint.

 The same walk `import_animation` does before it looks at a single curve: the
 skin's joint list when the file has one, the animated nodes and their ancestors
 when it does not, unnamed nodes dropped, and the result emitted
 parents-before-children — the order a Skeleton and the palette both require.

 Here so that a caller can have the joints without converting a clip, and so
 there is one answer to "which nodes are the bones of this file" rather than two
 that can drift apart.

 	`String[] names;`
 	`rig::Skeleton rest = crig::read_rest_skeleton(mem, &stream, &names)!;`
 	`defer rest.free(mem);`

 The caller owns the skeleton and every name in the array.

 The names come back carried onto a body plan when the file's rig is one crig
 recognises, on the same terms `import_animation` carries a clip's — so a pack's
 skeleton and its clips cannot come back naming the same joint two ways. Pass
 `options.keep_source_names` to see the file's own spelling instead.

 `joint_nodes` answers "which node was this joint", which is what a caller needs to
 line these joints up against anything else read out of the same file — the skin
 weights above all, whose columns are addressed by node and by nothing else. It
 is not derivable afterwards: joints are dropped here for being unnamed or for
 belonging to no dot of the matched plan, so the two orders share no index.

 @param names : `Receives one name per joint, in joint order. Untouched on failure.`
 @param joint_nodes : `Receives the source node index per joint, if given. Owned by the caller; untouched on failure.`
 @param animation : `Which animation names the joints, used only when the file has no skin.`
 @param skin : `Which skin names them when it has one.`
 @param options : `Only the alias fields are read; the rest belong to a clip.`
 @param report : `Receives what the naming did, if given. Its plan_matched is the only account of which plan these words came from. Untouched on failure.`
 @return? ANIM_NO_JOINTS : `Nothing in the file can serve as a named joint.`
*>
fn rig::Skeleton? read_rest_skeleton(
	Allocator allocator,
	gltf::GltfStream* stream,
	String[]* names,
	int animation = 0,
	int skin = 0,
	AnimImportOptions options = {},
	usz[]* joint_nodes = null,
	AnimImportReport* report = null)
{
	usz nodes = (usz)stream.gltf.nodes.len();
	if (nodes == 0) return ANIM_NO_JOINTS~;

	// With no skin the joints are whatever an animation moves, so there has to
	// be an animation to read them off.
	usz available = (usz)stream.gltf.animations.len();
	usz skins = (usz)stream.gltf.skins.len();
	if (skins == 0 && available == 0) return ANIM_NO_JOINTS~;

	gltf::Animation anim = {};
	if (skins == 0)
	{
		usz pick = animation >= 0 && (usz)animation < available ? (usz)animation : 0;
		anim = stream.gltf.animations[(sz)pick];
	}

	NodeTransform[] local = alloc::new_array(allocator, NodeTransform, (sz)nodes);
	NodeWorld[] world = alloc::new_array(allocator, NodeWorld, (sz)nodes);
	usz[] joint_node = alloc::new_array(allocator, usz, (sz)nodes);
	int[] joint_parent = alloc::new_array(allocator, int, (sz)nodes);
	bool[] wanted = alloc::new_array(allocator, bool, (sz)nodes);
	defer
	{
		alloc::free(allocator, local);
		alloc::free(allocator, world);
		alloc::free(allocator, joint_node);
		alloc::free(allocator, joint_parent);
		alloc::free(allocator, wanted);
	}

	bool scaled;
	for (usz i = 0; i < nodes; i++)
	{
		local[i] = node_rest(stream.gltf.nodes.get_ref((sz)i), &scaled);
	}
	world_transforms(stream, local, world, source_origin(stream));

	AnimImportReport tally = {};
	mark_joints(stream, anim, { .skin = skin }, wanted, &tally.unnamed_joints);

	String[] node_label = alloc::new_array(allocator, String, (sz)nodes);
	defer alloc::free(allocator, node_label);
	apply_joint_map(allocator, stream, anim, world, options, wanted, node_label, &tally);

	usz joints = 0;
	for (usz i = 0; i < nodes; i++)
	{
		if (stream.gltf.nodes.get_ref((sz)i).parent == null)
		{
			collect_joints(stream, (uint)i, -1, wanted, joint_node, joint_parent, &joints);
		}
	}
	if (joints == 0) return ANIM_NO_JOINTS~;

	rig::Skeleton rest = {
		.joints = alloc::new_array(allocator, Vec3, (sz)joints),
		.parents = alloc::new_array(allocator, int, (sz)joints),
	};
	String[] labels = alloc::new_array(allocator, String, (sz)joints);
	usz[] sources = joint_nodes ? alloc::new_array(allocator, usz, (sz)joints) : (usz[]){};
	for (usz j = 0; j < joints; j++)
	{
		rest.joints[j] = world[joint_node[j]].position;
		rest.parents[j] = joint_parent[j];
		labels[j] = node_label[joint_node[j]].copy(allocator);
		if (joint_nodes) sources[j] = joint_node[j];
	}

	*names = labels;
	if (joint_nodes) *joint_nodes = sources;
	// Last, so a caller reading it knows the skeleton came back — everything above
	// can still fail, and a report handed out beside a fault would be describing a
	// naming that was thrown away.
	if (report) *report = tally;
	return rest;
}

<*
 Free an owned array of templates and every template in it.
*>
fn void free_animations(Allocator allocator, AnimTemplate[] templates)
{
	foreach (&template : templates) template.free(allocator);
	if (templates.len > 0) alloc::free(allocator, templates);
}

// Not what keeps junk out of the library — a file that gets this far and is not
// glTF fails to open, and the loop skips it either way. What this saves is
// handing a README or a stray PNG to the JSON parser, which answers by printing
// its complaint, so a user with anything else in the folder would meet a wall of
// parser noise every time crig started.
//
// An extension test rather than a mask on `ls`, which would need two passes for
// the two spellings and would not lowercase either of them.
fn bool is_gltf_name(String name) @local
{
	if (name.len < 5) return false;
	String tail = name[^5..];
	if (tail == ".gltf" || tail == ".GLTF") return true;
	return name[^4..] == ".glb" || name[^4..] == ".GLB";
}

<*
 The full path of every glTF file directly inside `directory`, in the order the
 filesystem lists them. A missing or unreadable folder is an empty list, not an
 error: a library folder that is not there is an ordinary thing.

 Free with `free_paths`.
*>
fn String[] gltf_files_in(Allocator allocator, String directory)
{
	// Asked before listing, not after: `path::ls` initialises its list and then
	// walks, and hands back only the fault when the walk fails — so the list it
	// already made is lost.
	if (!path::is_dir((Path)directory)) return {};

	PathList? entries = path::ls(allocator, (Path)directory, no_dirs: true);
	if (catch entries) return {};
	// Each entry carries its own copy of the name; the List's own free releases
	// the array holding them and not the names themselves.
	defer
	{
		foreach (entry : entries) entry.free(allocator);
		entries.free();
	}

	List{String} files;
	files.init(allocator);
	foreach (entry : entries)
	{
		String name = (String)entry;
		if (is_gltf_name(name)) files.push(string::format(allocator, "%s/%s", directory, name));
	}
	String[] result = files.len() > 0 ? files.to_array(allocator) : {};
	files.free();
	return result;
}

fn void free_paths(Allocator allocator, String[] paths)
{
	foreach (path : paths) alloc::free(allocator, path.ptr);
	if (paths.len > 0) alloc::free(allocator, paths);
}

// ---------------------------------------------------------------------------
// Reading the file's rest hierarchy.

// glTF writes a node's transform either as a matrix or as a translation,
// rotation and scale, never as both. The parser fills in defaults for whichever
// form is absent, so a matrix that is not the identity is the only signal left
// that the file chose that one.
fn NodeTransform node_rest(gltf::Node* node, bool* scaled) @local
{
	if (!is_identity_matrix(node.matrix)) return decompose(node.matrix, scaled);

	if (!is_uniform(node.scale)) *scaled = true;
	return {
		.rotation = node.rotation.normalize(),
		.translation = node.translation,
		.scale = node.scale,
	};
}

fn bool is_identity_matrix(Matrix4f m) @local
{
	Matrix4f identity = matrix::IDENTITY4;
	for (usz i = 0; i < 16; i++)
	{
		if (m.m[i] != identity.m[i]) return false;
	}
	return true;
}

// Whether the three axes are scaled by the same amount. A uniform scale leaves
// world directions alone, which is all this conversion needs from it; an
// unequal one bends them, and no world-axis rotation can say that.
fn bool is_uniform(Vec3 scale) @local
{
	return math::abs(scale.x - scale.y) < 1.0e-5f && math::abs(scale.x - scale.z) < 1.0e-5f;
}

// Pull a rotation, a translation and a scale back out of a node matrix. The
// columns are the transformed axes, so their lengths are the scale and their
// normalized selves are the rotation.
fn NodeTransform decompose(Matrix4f m, bool* scaled) @local
{
	Vec3 x = { m.m[0], m.m[1], m.m[2] };
	Vec3 y = { m.m[4], m.m[5], m.m[6] };
	Vec3 z = { m.m[8], m.m[9], m.m[10] };

	Vec3 scale = { x.length(), y.length(), z.length() };
	// A mirroring matrix has no rotation that says so: the sign goes onto X, as
	// `three::decompose` does, or the basis below is left-handed and the
	// quaternion read from it is nonsense. A mirror is not a uniform scale.
	if (x.dot(y.cross(z)) < 0) scale.x = -scale.x;
	if (!is_uniform(scale)) *scaled = true;

	x = math::abs(scale.x) > 1.0e-9f ? x / scale.x : (Vec3){ 1, 0, 0 };
	y = scale.y > 1.0e-9f ? y / scale.y : (Vec3){ 0, 1, 0 };
	z = scale.z > 1.0e-9f ? z / scale.z : (Vec3){ 0, 0, 1 };

	return {
		// Normalised first, just above: the axes have to be orthonormal for this,
		// and a node matrix is free to carry scale.
		.rotation = rig::quat_from_basis(x, y, z),
		.translation = { m.m[12], m.m[13], m.m[14] },
		.scale = scale,
	};
}

// Every node's transform in world terms, walked down from each root. Nodes
// outside any scene are walked too: a skeleton left out of the default scene is
// still the skeleton the channels are aimed at.
fn void world_transforms(gltf::GltfStream* stream, NodeTransform[] local, NodeWorld[] out, NodeWorld origin) @local
{
	usz nodes = (usz)stream.gltf.nodes.len();
	for (usz i = 0; i < nodes; i++)
	{
		if (stream.gltf.nodes.get_ref((sz)i).parent == null) place_node(stream, (uint)i, origin, local, out);
	}
}

const NodeWorld NODE_ORIGIN @local = { .rotation = quaternion::IDENTITY, .position = { 0, 0, 0 }, .scale = { 1, 1, 1 } };

<*
 Where a file's figure is stood before anything is read out of it: turned half
 way round about Y when it faces −Z, and left where it is otherwise.

 	`NodeWorld origin = crig::source_origin(&stream);`

 **crig reads every figure as facing +Z, its left side on +X.** A plan is
 written that way, the shape matcher tells a left limb from a right one by the
 sign of x (`same_side`), and a clip's motion is a world-space turn carried
 onto the target's bones. A source standing the other way round breaks all
 three at once: its left arm is matched to the target's right, and a stride
 that carries its foot toward its own front carries the target's foot toward
 the target's back — the character moonwalks, or, with the sides crossed as
 well, tears itself apart. Turning the file's world before anything is read
 from it fixes all three in one place, and because the skeleton, every sampled
 pose and the root's travel are all read through the same turn, the clip is
 exactly the same motion, merely stood facing the way crig expects.

 How it faces is read off its names, the only thing about a bare skeleton that
 says which side is its left — see `faces_back`.
*>
fn NodeWorld source_origin(gltf::GltfStream* stream)
{
	NodeWorld origin = NODE_ORIGIN;
	if (faces_back(stream)) origin.rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, (float)math::PI);
	return origin;
}

<*
 `source_origin`'s turn as a matrix, for what is read or written outside the
 node walk: the identity for a figure facing +Z, half way round about Y for one
 facing −Z.

 A model's mesh has to stand where its skeleton was read standing. The rig comes
 out of `read_rest_skeleton` through the turn, so the mesh it was skinned to is
 turned by the same matrix as it arrives (`import_rig_from_source`), and the
 writer folds the same matrix into the skin's bind (`read_mesh_parts`). The
 file's own positions stay as they are, the way an up-axis conversion's do.
*>
fn Matrix4f source_turn(gltf::GltfStream* stream)
{
	Matrix4f turn = matrix::IDENTITY4;
	if (!faces_back(stream)) return turn;
	turn.m[0] = -1.0f;
	turn.m[10] = -1.0f;
	return turn;
}

<*
 Whether a file's figure faces −Z: its joints named for the left side sit on −X.

 The same reading `reapply_plan_limits` takes of a rig: a name says which side
 a joint is on (`name_side` — `L_upper_arm`, `thigh_l`, `LeftHand`), and a
 figure facing +Z keeps its left on +X. Its left side's middle clearly on −X
 of its right's is a figure turned half round. Sides that part along Z are a
 figure stood sideways — the quadruped faces −X — and it is left as it stands,
 as is a file whose joints name no side, or whose sides disagree about it. So is one naming fewer than two joints on each side: a limb is
 several joints, and a lone `n_l` beside a lone `n_r` is two letters of an
 alphabet, not a left and a right.

 Reads the first skin's joints, or every named node for a file with no skin.
 Never for a file marked as standing as authored (`PACK_KEY_FACING`).
*>
fn bool faces_back(gltf::GltfStream* stream)
{
	usz nodes = (usz)stream.gltf.nodes.len();
	if (nodes == 0) return false;
	if (as_written(stream)) return false;

	NodeTransform[] local = alloc::new_array(tmem, NodeTransform, (sz)nodes);
	NodeWorld[] world = alloc::new_array(tmem, NodeWorld, (sz)nodes);
	bool[] joint = alloc::new_array(tmem, bool, (sz)nodes);

	bool scaled;
	for (usz i = 0; i < nodes; i++) local[i] = node_rest(stream.gltf.nodes.get_ref((sz)i), &scaled);
	world_transforms(stream, local, world, NODE_ORIGIN);

	if (stream.gltf.skins.len() > 0)
	{
		foreach (index : stream.gltf.skins[0].joints) if (index < nodes) joint[index] = true;
	}
	else
	{
		joint[:nodes] = true;
	}

	Vec3 left;
	Vec3 right;
	float widest = 0.0f;
	usz lefts = 0;
	usz rights = 0;
	for (usz i = 0; i < nodes; i++)
	{
		if (!joint[i]) continue;
		char side = name_side(stream.gltf.nodes.get_ref((sz)i).name);
		if (side == 0) continue;
		Vec3 at = world[i].position;
		widest = math::max(widest, math::max(math::abs(at.x), math::abs(at.z)));
		if (side == 'L' || side == 'l')
		{
			left += at;
			lefts++;
		}
		else
		{
			right += at;
			rights++;
		}
	}
	if (lefts < 2 || rights < 2) return false;
	// From the right side's middle to the left's. Facing +Z that points along
	// +X, facing −Z along −X — and for a figure stood sideways, like the
	// quadruped that faces −X, it points along Z, and the figure is neither:
	// its hind legs a hand's width out of line must not read as turned round.
	// So the sides have to part mostly along X (within about 27°), and by more
	// than a hundredth of the widest joint, well clear of a symmetric rig's
	// noise.
	Vec3 across = left / (float)lefts - right / (float)rights;
	return across.x < -widest * 0.01f && across.x * across.x > 4.0f * across.z * across.z;
}

fn void place_node(
	gltf::GltfStream* stream,
	uint index,
	NodeWorld parent,
	NodeTransform[] local,
	NodeWorld[] out) @local
{
	NodeTransform frame = local[index];
	NodeWorld here = {
		.rotation = parent.rotation.mul(frame.rotation).normalize(),
		.position = parent.position + parent.rotation.rotate_vec3(parent.scale * frame.translation),
		.scale = parent.scale * frame.scale,
	};
	out[index] = here;

	gltf::Node* node = stream.gltf.nodes.get_ref((sz)index);
	foreach (child : node.children) place_node(stream, child, here, local, out);
}

// ---------------------------------------------------------------------------
// Choosing the joints.

// A skin's joint list is the file saying which nodes are bones, and it is the
// answer whenever there is one. Without a skin — a clip exported on its own —
// the animated nodes and everything above them is the best guess available.
//
// A joint has to be named, because a template is looked up by name. An unnamed
// one is left out of the skeleton entirely rather than kept as a silent link in
// the chain: its motion then folds into its named descendants, which is what a
// target rig built from the names alone will expect.
fn void mark_joints(
	gltf::GltfStream* stream,
	gltf::Animation anim,
	AnimImportOptions options,
	bool[] wanted,
	usz* unnamed) @local
{
	usz skins = (usz)stream.gltf.skins.len();
	if (skins > 0)
	{
		usz which = options.skin >= 0 && (usz)options.skin < skins ? (usz)options.skin : 0;
		foreach (joint : stream.gltf.skins[(sz)which].joints)
		{
			if (joint < wanted.len) wanted[joint] = true;
		}
	}
	else
	{
		foreach (channel : anim.channels)
		{
			if (channel.target.path == gltf::AnimationProperty.POINTER) continue;
			if (channel.target.node >= wanted.len) continue;

			gltf::Node* node = stream.gltf.nodes.get_ref((sz)channel.target.node);
			while (node != null)
			{
				wanted[node.index] = true;
				node = node.parent;
			}
		}
	}

	for (usz i = 0; i < wanted.len; i++)
	{
		if (!wanted[i]) continue;
		if (stream.gltf.nodes.get_ref((sz)i).name.len > 0) continue;
		wanted[i] = false;
		(*unnamed)++;
	}
}

<*
 Which of these body plans a file's rig is shaped like, or -1 for none of them.

 	`int which = crig::match_stream(mem, &stream, plans);`

 For a caller reading several things out of one file: deciding once and handing
 the answer to each read keeps a pack whose clips move different subsets of the
 rig from coming back named on two different plans, and its skeleton on a third.
 A caller taking a single clip does not need this — `import_animation` matches
 for itself when handed plans and no answer.

 Loads each animation's buffers to measure which joints the clips turn — the
 matcher keeps plan dots off joints that are keyed flat, and cannot without
 reading the keys.

 @param animation : `Which animation names the joints, used only when the file has no skin.`
 @param skin : `Which skin names them when it has one.`
*>
fn int match_stream(
	Allocator allocator,
	gltf::GltfStream* stream,
	Preset[] plans,
	int animation = 0,
	int skin = 0)
{
	usz nodes = (usz)stream.gltf.nodes.len();
	if (nodes == 0 || plans.len == 0) return -1;

	usz available = (usz)stream.gltf.animations.len();
	usz skins = (usz)stream.gltf.skins.len();
	if (skins == 0 && available == 0) return -1;

	gltf::Animation anim = {};
	if (skins == 0)
	{
		usz pick = animation >= 0 && (usz)animation < available ? (usz)animation : 0;
		anim = stream.gltf.animations[(sz)pick];
	}

	NodeTransform[] local = alloc::new_array(allocator, NodeTransform, (sz)nodes);
	NodeWorld[] world = alloc::new_array(allocator, NodeWorld, (sz)nodes);
	bool[] wanted = alloc::new_array(allocator, bool, (sz)nodes);
	defer
	{
		alloc::free(allocator, local);
		alloc::free(allocator, world);
		alloc::free(allocator, wanted);
	}

	bool scaled;
	for (usz i = 0; i < nodes; i++)
	{
		local[i] = node_rest(stream.gltf.nodes.get_ref((sz)i), &scaled);
	}
	world_transforms(stream, local, world, source_origin(stream));

	usz unnamed;
	mark_joints(stream, anim, { .skin = skin }, wanted, &unnamed);

	JointMatch found = best_plan(allocator, stream, world, wanted, plans);
	defer found.free(allocator);
	return found.usable() ? (int)found.plan : -1;
}

// Carry the marked joints onto a body plan's dot names, and fold out the links
// the plan has no dot for by unmarking them — `collect_joints` runs next and is
// what reparents their children onto the nearest survivor.
//
// `label` comes back holding a name for every node, whether or not it is a
// joint, so a caller can index it by node the way `joint_node` points. The
// names are borrowed: a plan's belong to whoever built the plan and the rest are
// the stream's own, so both have to be copied to outlive this read.
fn void apply_joint_map(
	Allocator allocator,
	gltf::GltfStream* stream,
	gltf::Animation anim,
	NodeWorld[] rest_world,
	AnimImportOptions options,
	bool[] wanted,
	String[] label,
	AnimImportReport* tally) @local
{
	usz nodes = wanted.len;
	for (usz i = 0; i < nodes; i++)
	{
		label[i] = stream.gltf.nodes.get_ref((sz)i).name;
	}

	if (options.keep_source_names || options.plans.len == 0) return;

	JointMatch found = best_plan(allocator, stream, rest_world, wanted, options.plans);
	defer found.free(allocator);
	if (!found.usable()) return;

	Preset plan = options.plans[found.plan];

	bool[] folded = alloc::new_array(allocator, bool, (sz)nodes);
	defer alloc::free(allocator, folded);

	bool[] branch = extra_branches(allocator, stream, rest_world, wanted, found);
	defer alloc::free(allocator, branch);

	// `found.dot` is one entry per joint in the order `collect_joints` emits, and
	// `found.node` is the node each of those joints was — the two are how a
	// per-joint answer is written back into the per-node arrays this works on.
	foreach (usz j, dot : found.dot)
	{
		usz node = found.node[j];
		if (dot < 0)
		{
			// Left alone under the name set above, which is the node's own — see
			// `keep_unmatched`. It stays a joint, so nothing reparents onto it and
			// nothing counts as folded.
			if (options.keep_unmatched || branch[node]) continue;

			wanted[node] = false;
			folded[node] = true;
			tally.folded_joints++;
			continue;
		}

		label[node] = plan.dots[(usz)dot].name;
		tally.matched_joints++;
	}

	tally.plan_matched = plan.name;
	tally.plan_tag = plan.plan;
	if (tally.folded_joints > 0)
	{
		tally.folded_animated = fold_costs_exactness(allocator, stream, anim, wanted, folded);
	}
}

// How far each node's rotation channels ever leave its rest orientation, in
// radians, across every animation in the file. Zero for a node no channel
// names, and — the case this exists for — for one keyed flat: twist stubs,
// end markers and clavicles a tool exported but never moved all measure zero,
// and the matcher uses that to keep body-plan dots off them.
//
// The whole file rather than one clip, so every clip in a pack matches the
// same way: a rig whose fingers curl only in one clip must not come back with
// its wrist on a different joint for that clip alone.
//
// Loads each animation's buffers, skipping any that will not load. Empty when
// the file has no animations at all, which charges no penalty anywhere.
fn float[] node_motion(Allocator allocator, gltf::GltfStream* stream) @local
{
	usz nodes = (usz)stream.gltf.nodes.len();
	usz clips = (usz)stream.gltf.animations.len();
	if (nodes == 0 || clips == 0) return {};

	float[] out = alloc::new_array(allocator, float, (sz)nodes);

	bool scaled;
	for (usz a = 0; a < clips; a++)
	{
		if (catch stream.load_animation_buffers((uint)a)) continue;
		gltf::Animation anim = stream.gltf.animations[(sz)a];

		foreach (channel : anim.channels)
		{
			if (channel.target.path != gltf::AnimationProperty.ROTATION) continue;
			uint node = channel.target.node;
			if (node >= nodes) continue;

			Quaternionf rest = node_rest(stream.gltf.nodes.get_ref((sz)node), &scaled).rotation;
			gltf::AnimationSampler sampler = anim.samplers[channel.sampler];
			gltf::Accessor input = stream.gltf.accessors[sampler.input];
			gltf::Accessor output = stream.gltf.accessors[sampler.output];
			bool cubic = sampler.interpolation == gltf::Interpolation.CUBICSPLINE;

			usz keys = (usz)input.count;
			for (usz k = 0; k < keys; k++)
			{
				Quaternionf q = ((Quaternionf){ .v = key_value(stream, output, k, cubic) }).normalize();
				out[node] = math::max(out[node], rotation_angle_between(q, rest));
			}
		}
	}
	return out;
}

// The plan the marked joints fit best, matched on shape and on which joints
// the file's clips actually turn — see MatchShape.moved.
//
// The marked set is collected into a skeleton here rather than reusing the
// caller's, because the caller's collection happens *after* this has folded —
// that ordering is what makes a folded joint's rotation compose into its
// children instead of vanishing, and it means the joint list does not exist yet
// at the point the decision has to be made.
//
// The returned match carries `node` alongside `dot`, so the caller can put a
// per-joint answer back into the per-node arrays it holds.
fn JointMatch best_plan(
	Allocator allocator,
	gltf::GltfStream* stream,
	NodeWorld[] rest_world,
	bool[] wanted,
	Preset[] plans) @local
{
	usz nodes = wanted.len;
	usz[] joint_node = alloc::new_array(allocator, usz, (sz)nodes);
	int[] joint_parent = alloc::new_array(allocator, int, (sz)nodes);
	defer
	{
		alloc::free(allocator, joint_node);
		alloc::free(allocator, joint_parent);
	}

	usz joints = 0;
	for (usz i = 0; i < nodes; i++)
	{
		if (stream.gltf.nodes.get_ref((sz)i).parent == null)
		{
			collect_joints(stream, (uint)i, -1, wanted, joint_node, joint_parent, &joints);
		}
	}
	if (joints == 0) return {};

	Vec3[] at = alloc::new_array(allocator, Vec3, (sz)joints);
	defer alloc::free(allocator, at);
	for (usz j = 0; j < joints; j++) at[j] = rest_world[joint_node[j]].position;

	float[] motion = node_motion(allocator, stream);
	float[] moved = {};
	if (motion.len > 0)
	{
		moved = alloc::new_array(allocator, float, (sz)joints);
		for (usz j = 0; j < joints; j++) moved[j] = motion[joint_node[j]];
	}
	defer
	{
		if (motion.len > 0) alloc::free(allocator, motion);
		if (moved.len > 0) alloc::free(allocator, moved);
	}

	MatchShape source = { .at = at[:joints], .parent = joint_parent[:joints], .moved = moved };

	JointMatch best = {};
	foreach (usz p, plan : plans)
	{
		JointMatch tried = match_preset(allocator, source, plan);
		tried.plan = p;
		if (best.dot.len > 0 && !tried.better_than(best))
		{
			alloc::free(allocator, tried.dot);
			continue;
		}
		if (best.dot.len > 0) alloc::free(allocator, best.dot);
		best = tried;
	}

	if (best.dot.len == 0) return {};

	// The node behind each joint, so the caller can write the answer back.
	best.node = alloc::new_array(allocator, usz, (sz)joints);
	best.node[:joints] = joint_node[:joints];
	return best;
}

<*
 Which unmatched joints belong to a limb the plan does not have — a tail, an
 ear, a cape — and are kept under their own names instead of folded away.

 A fold exists for the links *between* plan dots: a second spine segment has to
 compose into the chest, or the chest misses a turn the clip made. A branch
 with no plan dot anywhere below it composes into nothing. Folded, it simply
 vanishes, and with it the whole of its motion — a character's tail keyed in
 every clip of the file plays on no rig, however well that rig's own tail is
 built. Kept, it is a few more joints in the pack, which a rig with a tail
 pairs with by shape (`measure_reach`) and a rig without one ignores.

 Only a branch of at least two joints reaching `ANIM_BRANCH_MIN` of the figure
 counts. The ones below that are end markers — a bone past the hand, a tip
 above the head — which a rig has no use for, and which some files key for
 props held in the hand.

 @return `One flag per node, true for a joint to keep. Owned by the caller.`
*>
fn bool[] extra_branches(
	Allocator allocator,
	gltf::GltfStream* stream,
	NodeWorld[] rest_world,
	bool[] wanted,
	JointMatch found) @local
{
	usz nodes = wanted.len;
	bool[] keep = alloc::new_array(allocator, bool, (sz)nodes);
	bool[] candidate = alloc::new_array(tmem, bool, (sz)nodes);
	bool[] above = alloc::new_array(tmem, bool, (sz)nodes);

	float low = 1.0e30f;
	float high = -1.0e30f;
	foreach (usz j, dot : found.dot)
	{
		usz node = found.node[j];
		float y = rest_world[node].position.y;
		low = math::min(low, y);
		high = math::max(high, y);
		if (dot < 0) continue;
		gltf::Node* up = stream.gltf.nodes.get_ref((sz)node).parent;
		while (up != null)
		{
			above[up.index] = true;
			up = up.parent;
		}
	}
	float height = high - low;
	if (height <= 0.0f) return keep;

	foreach (usz j, dot : found.dot)
	{
		usz node = found.node[j];
		if (dot < 0 && !above[node]) candidate[node] = true;
	}

	foreach (usz j, dot : found.dot)
	{
		usz node = found.node[j];
		if (!candidate[node]) continue;
		// The branch's first joint: the nearest joint above it is not in the branch.
		gltf::Node* up = stream.gltf.nodes.get_ref((sz)node).parent;
		while (up != null && !wanted[up.index]) up = up.parent;
		if (up == null || candidate[up.index]) continue;

		usz count = 0;
		float reach = branch_reach(stream, rest_world, wanted, candidate, node, &count);
		if (count < 2 || reach < height * ANIM_BRANCH_MIN) continue;
		mark_branch(stream, wanted, candidate, keep, node);
	}
	return keep;
}

// How far a branch reaches from its first joint, down its longest run, and how
// many joints it has.
fn float branch_reach(gltf::GltfStream* stream, NodeWorld[] rest_world, bool[] wanted, bool[] candidate, usz node, usz* count) @local
{
	(*count)++;
	float longest = 0.0f;
	foreach (child : stream.gltf.nodes.get_ref((sz)node).children)
	{
		if (child >= wanted.len || !wanted[child] || !candidate[child]) continue;
		float step = (rest_world[child].position - rest_world[node].position).length();
		longest = math::max(longest, step + branch_reach(stream, rest_world, wanted, candidate, child, count));
	}
	return longest;
}

fn void mark_branch(gltf::GltfStream* stream, bool[] wanted, bool[] candidate, bool[] keep, usz node) @local
{
	keep[node] = true;
	foreach (child : stream.gltf.nodes.get_ref((sz)node).children)
	{
		if (child < wanted.len && wanted[child] && candidate[child]) mark_branch(stream, wanted, candidate, keep, child);
	}
}

// How far a limb the plan has no dot for has to reach, as a fraction of the
// figure's height, to be kept rather than folded: a tenth. A tail or an ear
// reaches well past it; a bone marking the end of a hand does not.
const float ANIM_BRANCH_MIN @local = 0.1f;

// Whether folding cost this clip its exactness between the source's keys, which
// is what `sample_times` subdivides to win back.
//
// Sampling at the source's own keys is exact because the player slides between
// keyframes the way glTF slides between keys — but only while the two are
// sliding the same quantity. A fold hands one crig joint the product of two
// source rotations, and the product of two slerps is not the slerp of the
// product: the result lands on the source at every key and bows away from it in
// between.
//
// True only when both ends of that product move. A folded joint that holds
// still contributes a constant, and a kept joint under a folded one that holds
// still has nothing to compose with; either way one slerp is all that is left
// and it is exact again.
fn bool fold_costs_exactness(
	Allocator allocator,
	gltf::GltfStream* stream,
	gltf::Animation anim,
	bool[] wanted,
	bool[] folded) @local
{
	usz nodes = wanted.len;
	bool[] animated = alloc::new_array(allocator, bool, (sz)nodes);
	defer alloc::free(allocator, animated);

	foreach (channel : anim.channels)
	{
		if (channel.target.path == gltf::AnimationProperty.POINTER) continue;
		if (channel.target.node < nodes) animated[channel.target.node] = true;
	}

	for (usz i = 0; i < nodes; i++)
	{
		if (!folded[i] || !animated[i]) continue;
		if (subtree_moves_a_joint(stream, (uint)i, wanted, animated)) return true;
	}
	return false;
}

// Whether anything below this node survived aliasing and is itself animated —
// which is what a folded joint's rotation would have to compose with.
fn bool subtree_moves_a_joint(
	gltf::GltfStream* stream,
	uint index,
	bool[] wanted,
	bool[] animated) @local
{
	foreach (child : stream.gltf.nodes[index].children)
	{
		if (wanted[child] && animated[child]) return true;
		if (subtree_moves_a_joint(stream, child, wanted, animated)) return true;
	}
	return false;
}


// Emits joints parents-before-children, which is the order a Skeleton and the
// palette both require, and records each one's nearest joint ancestor.
fn void collect_joints(
	gltf::GltfStream* stream,
	uint index,
	int enclosing,
	bool[] wanted,
	usz[] joint_node,
	int[] joint_parent,
	usz* joints) @local
{
	int here = enclosing;
	if (wanted[index])
	{
		here = (int)*joints;
		joint_node[*joints] = index;
		joint_parent[*joints] = enclosing;
		(*joints)++;
	}

	foreach (child : stream.gltf.nodes[index].children)
	{
		collect_joints(stream, child, here, wanted, joint_node, joint_parent, joints);
	}
}

// ---------------------------------------------------------------------------
// Choosing when to sample.

// The source's own key times, which makes the conversion exact rather than
// merely close: a linear channel sampled at its own keys reproduces the whole
// curve, because the player slides between keyframes the same way glTF slides
// between keys. Resampling at a fixed rate would blur every key it missed.
//
// A spline needs points between the keys to keep its shape. STEP survives as
// per-channel HOLD metadata unless animated joints were folded into their
// children; that composition is no longer one source curve, so only that case
// keeps the old just-before-the-key approximation.
fn void? sample_times(
	gltf::GltfStream* stream,
	gltf::Animation anim,
	AnimImportOptions options,
	Allocator allocator,
	AnimFloatList* out,
	AnimImportReport* tally) @local
{
	AnimFloatList gathered;
	gathered.init(allocator);
	defer gathered.free();

	foreach (channel : anim.channels)
	{
		if (channel.target.path == gltf::AnimationProperty.POINTER) continue;

		gltf::AnimationSampler sampler = anim.samplers[channel.sampler];
		if (sampler.interpolation == gltf::Interpolation.STEP) tally.stepped = true;
		if (sampler.interpolation == gltf::Interpolation.CUBICSPLINE) tally.cubic = true;

		gltf::Accessor input = stream.gltf.accessors[sampler.input];
		if (input.data_type != gltf::DataType.FLOAT) return ANIM_SAMPLER_UNSUPPORTED~;

		for (usz k = 0; k < (usz)input.count; k++)
		{
			gathered.push(stream.@cast_buffer(input, (sz)k, float));
		}
	}
	if (gathered.len() == 0) return ANIM_NO_KEYFRAMES~;

	float[] sorted = gathered.to_array(allocator);
	defer alloc::free(allocator, sorted);
	quicksort(sorted);

	AnimFloatList keys;
	keys.init(allocator);
	defer keys.free();
	foreach (time : sorted)
	{
		if (keys.len() > 0 && time - keys[keys.len() - 1] <= ANIM_TIME_EPSILON) continue;
		keys.push(time);
	}

	uint slices = options.subdivide > 0
		? options.subdivide
		: (tally.cubic || tally.folded_animated ? ANIM_SUBDIVIDE_SLICES : 1);

	out.push(keys[0]);
	for (usz k = 1; k < (usz)keys.len(); k++)
	{
		float from = keys[(sz)(k - 1)];
		float to = keys[(sz)k];

		if (tally.stepped && tally.folded_animated) out.push(to - (to - from) * ANIM_STEP_EDGE);
		for (uint s = 1; s < slices; s++) out.push(from + (to - from) * ((float)s / (float)slices));

		out.push(to);
	}
}

// ---------------------------------------------------------------------------
// Reading the curves.

fn void apply_channels(
	gltf::GltfStream* stream,
	gltf::Animation anim,
	float time,
	NodeTransform[] local,
	usz* scale_channels) @local
{
	foreach (channel : anim.channels)
	{
		if (channel.target.path == gltf::AnimationProperty.POINTER) continue;

		uint node = channel.target.node;
		if (node >= local.len) continue;

		gltf::AnimationSampler sampler = anim.samplers[channel.sampler];

		switch (channel.target.path)
		{
			case TRANSLATION:
				local[node].translation = sample_at(stream, sampler, time, false).xyz;
			case ROTATION:
				local[node].rotation = ((Quaternionf){ .v = sample_at(stream, sampler, time, true) }).normalize();
			case SCALE:
				// Counted rather than applied. A Pose has a rotation and an offset
				// per joint and nowhere to put a scale, and quietly ignoring one
				// would leave a squashed walk looking merely wrong.
				(*scale_channels)++;
			default:
				break;
		}
	}
}

<*
 One sampler's value at `time`, clamped to its own ends.

 @param rotation : `True to blend as an orientation, which is a slerp rather than a line.`
*>
fn Vec4 sample_at(gltf::GltfStream* stream, gltf::AnimationSampler sampler, float time, bool rotation) @local
{
	gltf::Accessor input = stream.gltf.accessors[sampler.input];
	gltf::Accessor output = stream.gltf.accessors[sampler.output];

	usz keys = (usz)input.count;
	if (keys == 0) return { 0, 0, 0, 0 };

	bool cubic = sampler.interpolation == gltf::Interpolation.CUBICSPLINE;

	if (keys == 1 || time <= stream.@cast_buffer(input, 0, float)) return key_value(stream, output, 0, cubic);
	if (time >= stream.@cast_buffer(input, (sz)(keys - 1), float))
	{
		return key_value(stream, output, keys - 1, cubic);
	}

	// Binary search the bracket rather than walk it: glTF input times are strictly
	// increasing, and this is called for every channel at every sample, so an
	// O(keys) walk per call is what made importing a long clip — and a whole
	// file's worth of them on the first bind — cost what it did. `upper` is the
	// first key at or after `time`; the two edges above guarantee it lands in
	// range.
	usz lo = 1;
	usz hi = keys - 1;
	while (lo < hi)
	{
		usz mid = (lo + hi) / 2;
		if (stream.@cast_buffer(input, (sz)mid, float) < time) { lo = mid + 1; } else { hi = mid; }
	}
	usz upper = lo;
	usz lower = upper - 1;

	float from = stream.@cast_buffer(input, (sz)lower, float);
	float to = stream.@cast_buffer(input, (sz)upper, float);
	float span = to - from;
	float blend = span > 0.0f ? (time - from) / span : 0.0f;

	// A held value is the last key at or before the time asked for, so landing
	// exactly on a key takes that key's value rather than the one before it.
	if (sampler.interpolation == gltf::Interpolation.STEP)
	{
		return key_value(stream, output, blend >= 1.0f ? upper : lower, cubic);
	}

	Vec4 a = key_value(stream, output, lower, cubic);
	Vec4 b = key_value(stream, output, upper, cubic);

	if (cubic)
	{
		// Each spline key stores three values — in-tangent, value, out-tangent —
		// and the tangents are per second, so the interval scales them.
		Vec4 leaving = read_value(stream, output, lower * 3 + 2);
		Vec4 arriving = read_value(stream, output, upper * 3);

		float t2 = blend * blend;
		float t3 = t2 * blend;
		float h00 = 2.0f * t3 - 3.0f * t2 + 1.0f;
		float h10 = t3 - 2.0f * t2 + blend;
		float h01 = -2.0f * t3 + 3.0f * t2;
		float h11 = t3 - t2;

		return a * h00 + leaving * (span * h10) + b * h01 + arriving * (span * h11);
	}

	if (rotation)
	{
		Quaternionf blended = ((Quaternionf){ .v = a }).slerp((Quaternionf){ .v = b }, blend);
		return blended.v;
	}
	return a + (b - a) * blend;
}

fn Vec4 key_value(gltf::GltfStream* stream, gltf::Accessor output, usz key, bool cubic) @local
{
	return read_value(stream, output, cubic ? key * 3 + 1 : key);
}

// Read by declared width rather than always as four floats: a VEC3 accessor's
// last element has no fourth float behind it, and reading one would run off the
// end of the buffer view.
fn Vec4 read_value(gltf::GltfStream* stream, gltf::Accessor output, usz index) @local
{
	switch (output.type)
	{
		case gltf::AccessorType.VEC4:
			return stream.@cast_buffer(output, (sz)index, Vec4);
		case gltf::AccessorType.VEC3:
			Vec3 value = stream.@cast_buffer(output, (sz)index, Vec3);
			return { value.x, value.y, value.z, 0 };
		case gltf::AccessorType.SCALAR:
			return { stream.@cast_buffer(output, (sz)index, float), 0, 0, 0 };
		default:
			return { 0, 0, 0, 0 };
	}
}

// ---------------------------------------------------------------------------
// Turning the result into template entries.

<*
 The same rotation written with a non-negative scalar part.

 A quaternion and its negation turn a body to the same place, and
 `to_axis_angle` decomposes whichever of the two it is handed: a negative scalar
 part comes back as a turn between a half circle and a whole one, going the long
 way round. The emit loop drops a dot whose angle is under the rest epsilon, so
 a joint that barely moved has to read as barely moved rather than as very
 nearly a full revolution.

 The turns this is called on come out of `mul` and `invert` chains, which carry
 the sign of whatever the file stored; nothing upstream picks a hemisphere.
*>
// How badly a joint's own turn may misplace its children, as a fraction of how
// far they sit from it, before the turn is fitted to where they went instead.
// A joint's own turn places its direct children exactly, so anything above
// noise means the children are placed by something else — see `body_turn`.
const float ANIM_BODY_MISFIT @local = 0.1f;

<*
 The turn a joint takes on as the clip's, given where its children went.

 A joint's world turn is what the clip says about it, and on nearly every rig
 it is also what carries its children: they hang off it, so where they go is
 exactly where its turn puts them. Not on every rig. A game rig may stack its
 root, its waist and its pelvis on one point and key the root half way round
 while the bones under it key half way back — harmless on that rig, where the
 stacked bones do not move when the root spins, and the whole of the motion on
 a rig whose spine and thighs sit a little way off its hips: the upper body is
 swung below the hips and the legs cross. The clip never meant the hips to turn.

 So the turn is checked against the children it has to carry. Where it puts
 them where the clip put them, it stands — which is every joint on an ordinary
 rig, to rounding. Where it does not, and at least two children off the joint
 in different directions say how it did turn, the best fit to where those
 children went takes its place. Its children's own turns are read against it,
 so they still end up exactly where the clip put them.

 @param rest_world : `Every node at rest.`
 @param posed_world : `Every node at this sample.`
 @param height : `The source rig's height, what "a child off the joint" is measured against.`
*>
fn Quaternionf body_turn(
	usz joint,
	Quaternionf delta,
	int[] joint_parent,
	usz[] joint_node,
	NodeWorld[] rest_world,
	NodeWorld[] posed_world,
	float height) @local
{
	Vec3[8] from;
	Vec3[8] to;
	usz count = 0;
	Vec3 rest_at = rest_world[joint_node[joint]].position;
	Vec3 posed_at = posed_world[joint_node[joint]].position;
	foreach (usz c, parent : joint_parent)
	{
		if (parent != (int)joint || count == from.len) continue;
		Vec3 offset = rest_world[joint_node[c]].position - rest_at;
		if (offset.length() < height * 1.0e-3f) continue;
		from[count] = offset;
		to[count] = posed_world[joint_node[c]].position - posed_at;
		count++;
	}
	if (count < 2) return delta;

	// Two children along one line say nothing about a turn about that line.
	bool spread = false;
	for (usz a = 0; a < count && !spread; a++)
	{
		for (usz b = a + 1; b < count; b++)
		{
			if (from[a].normalize().cross(from[b].normalize()).length() > 0.2f) { spread = true; break; }
		}
	}
	if (!spread) return delta;

	float own = turn_misfit(from[:count], to[:count], delta);
	if (own <= ANIM_BODY_MISFIT) return delta;

	Quaternionf fitted = fit_turn(from[:count], to[:count]);
	return turn_misfit(from[:count], to[:count], fitted) < own * 0.5f ? fitted : delta;
}

// How far a turn puts each offset from where it went, squared and summed, as a
// fraction of the offsets' own squared lengths.
fn float turn_misfit(Vec3[] from, Vec3[] to, Quaternionf turn) @local
{
	float miss = 0.0f;
	float scale = 0.0f;
	foreach (usz i, a : from)
	{
		Vec3 gap = to[i] - turn.rotate_vec3(a);
		miss += gap.dot(gap);
		scale += a.dot(a);
	}
	return scale > 0.0f ? miss / scale : 0.0f;
}

<*
 The rotation that best carries each `from` onto its `to`, in the least-squares
 sense — Horn's closed form, the eigenvector of the largest eigenvalue of a 4×4
 symmetric matrix, found by power iteration on it shifted positive.
*>
fn Quaternionf fit_turn(Vec3[] from, Vec3[] to) @local
{
	float sxx, sxy, sxz, syx, syy, syz, szx, szy, szz;
	float bound = 0.0f;
	foreach (usz i, a : from)
	{
		Vec3 b = to[i];
		sxx += a.x * b.x; sxy += a.x * b.y; sxz += a.x * b.z;
		syx += a.y * b.x; syy += a.y * b.y; syz += a.y * b.z;
		szx += a.z * b.x; szy += a.z * b.y; szz += a.z * b.z;
		bound += a.length() * b.length();
	}
	// Rows in w, x, y, z order.
	float[4][4] n = {
		{ sxx + syy + szz, syz - szy, szx - sxz, sxy - syx },
		{ syz - szy, sxx - syy - szz, sxy + syx, szx + sxz },
		{ szx - sxz, sxy + syx, -sxx + syy - szz, syz + szy },
		{ sxy - syx, szx + sxz, syz + szy, -sxx - syy + szz },
	};
	for (usz i = 0; i < 4; i++) n[i][i] += bound;

	float[4] q = { 1.0f, 0.1f, 0.2f, 0.3f };
	for (usz step = 0; step < 100; step++)
	{
		float[4] next;
		float length = 0.0f;
		for (usz r = 0; r < 4; r++)
		{
			next[r] = n[r][0] * q[0] + n[r][1] * q[1] + n[r][2] * q[2] + n[r][3] * q[3];
			length += next[r] * next[r];
		}
		length = math::sqrt(length);
		if (length <= 0.0f) return quaternion::IDENTITY;
		for (usz r = 0; r < 4; r++) q[r] = next[r] / length;
	}
	return ((Quaternionf){ .v = { q[1], q[2], q[3], q[0] } }).normalize();
}

macro Quaternionf shortest_turn(Quaternionf turn) @local => turn.v.w < 0.0f ? -turn : turn;

// How far the clip carried the root from first sample to last. The first root,
// where a file has several: they would each have to be measured separately, and
// a rig with two skeletons in it is not what this is for.
fn Vec3 root_travel(Vec3[] slides, int[] joint_parent, usz joints, usz samples) @local
{
	for (usz j = 0; j < joints; j++)
	{
		if (joint_parent[j] >= 0) continue;
		return slides[(samples - 1) * joints + j] - slides[j];
	}
	return { 0, 0, 0 };
}

// Take the walk off the treadmill: subtract the travel in proportion to how far
// through the clip each sample is, so the root ends where it started and the
// sway around that line survives.
//
// A clip that was authored in place has no travel to remove and is untouched.
fn void strip_root_travel(
	Vec3[] slides,
	int[] joint_parent,
	usz joints,
	usz samples,
	AnimFloatList times,
	Vec3 travel) @local
{
	float start = times[0];
	float span = times[(sz)(samples - 1)] - start;
	if (span <= 0.0f) return;

	usz root = joints;
	for (usz j = 0; j < joints; j++)
	{
		if (joint_parent[j] < 0)
		{
			root = j;
			break;
		}
	}
	if (root >= joints) return;

	for (usz s = 0; s < samples; s++)
	{
		float through = (times[(sz)s] - start) / span;
		slides[s * joints + root] -= travel * through;
	}
}
