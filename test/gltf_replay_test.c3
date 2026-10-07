<*
 Does a rigged .glb move the way crig showed it moving?

     `c3c test --trust=full --test-filter crig_tests::gltf_replay`

 Every other check over the writer compares crig against crig: it exports a file,
 reads it back through `read_pack`, and poses it through `AnimTemplate.pose`. That
 answers "is the writer the inverse of the reader", which is worth knowing and is
 not the question a user has. Their question is whether the file plays the same in
 Blender, and crig's reader agreeing with crig's writer says nothing about that —
 a convention both halves get wrong the same way passes.

 So the file here is replayed by `replay_frame` below, which is written against
 the glTF specification and calls nothing in `crig` or `rig`: it samples the
 animation channels, composes the node hierarchy, multiplies each joint by its
 inverse bind matrix and blends the vertices by their four weights. That is what
 an importer does. If it disagrees with crig, one of them is wrong about the file,
 and the file is what gets shipped.

 **The fixture has reaches on it**, and that is deliberate — see
 `check_the_fixture_reaches_actually_bite`. A reach changes which joints a vertex
 rides, so a preview bound without them and a file written with them deform
 differently while looking equally plausible on screen. Without a reach in the
 fixture the interesting half of `bind_skin` is never exercised and the check
 passes on a rig that has nothing to disagree about.
*>
module crig_tests::gltf_replay;

import crig;
import rig;
import gltf;
import gltf_edit;
import crig_tests::shared_app;
import std::core::test;
import std::io;
import std::io::file;
import std::math;
import std::math::vector;
import std::math::matrix;
import std::math::quaternion;



const String FIXTURE = "build/gltf-replay.glb";

// Float32 through a file and back, blended over four influences and a chain of
// quaternions. Anything above this is a disagreement, not rounding.
const float EXACT = 5.0e-4f;

// Times each clip is sampled at, between and on the keys.
const usz SAMPLES = 17;

// ---------------------------------------------------------------------------
// The fixture
// ---------------------------------------------------------------------------

const String[7] JOINTS = {
	"hips", "spine", "head", "arm_L", "arm_R", "leg_L", "leg_R",
};

// Nothing axis-aligned and nothing symmetric about the depth: a frame error that
// only shows on a rig standing off the axes has to have somewhere to show.
const Vec3[7] REST = {
	{ 0.05f, 1.00f, 0.02f },
	{ 0.02f, 1.35f, 0.10f },
	{ 0.00f, 1.62f, 0.18f },
	{ 0.45f, 1.30f, 0.06f },
	{ -0.42f, 1.28f, 0.09f },
	{ 0.20f, 0.50f, -0.05f },
	{ -0.18f, 0.52f, -0.03f },
};

const int[7] PARENTS = { -1, 0, 1, 1, 1, 0, 0 };

// Short enough on the limbs to rank their far vertices below somebody else, zero
// on the spine so the fixture covers both branches of `reach_bias`.
const float[7] REACHES = { 0.0f, 0.0f, 0.30f, 0.25f, 0.25f, 0.35f, 0.35f };

fn rig::Skeleton fixture_skeleton()
{
	Vec3[] joints = alloc::new_array(mem, Vec3, 7);
	int[] parents = alloc::new_array(mem, int, 7);
	foreach (usz j, at : REST)
	{
		joints[j] = at;
		parents[j] = PARENTS[j];
	}
	return { .joints = joints, .parents = parents };
}

<*
 A closed box around the figure, subdivided so there are vertices at every
 distance from every bone.

 Closed because `build_voxels` needs an interior to flood, and subdivided because
 an eight-vertex box puts every vertex in a corner, where the nearest bone is the
 same one under any reach at all.
*>
fn rig::TriMesh fixture_body()
{
	const usz STEPS = 5;
	const usz SIDE = STEPS + 1;
	Vec3 low = { -0.60f, 0.20f, -0.35f };
	Vec3 high = { 0.60f, 1.90f, 0.45f };

	usz per_face = SIDE * SIDE;
	Vec3[] positions = alloc::new_array(mem, Vec3, (sz)(per_face * 6));
	uint[] indices = alloc::new_array(mem, uint, (sz)(STEPS * STEPS * 6 * 6));

	usz vertex = 0;
	usz index = 0;
	// Each face is a grid over two axes at a fixed value of the third. `flip`
	// keeps the winding outward on the three faces at the low end.
	for (usz axis = 0; axis < 3; axis++)
	{
		for (usz side = 0; side < 2; side++)
		{
			usz base = vertex;
			usz u = (axis + 1) % 3;
			usz v = (axis + 2) % 3;

			for (usz i = 0; i <= STEPS; i++)
			{
				for (usz k = 0; k <= STEPS; k++)
				{
					float[3] at;
					at[axis] = side == 0 ? low[axis] : high[axis];
					at[u] = low[u] + (high[u] - low[u]) * (float)i / (float)STEPS;
					at[v] = low[v] + (high[v] - low[v]) * (float)k / (float)STEPS;
					positions[vertex++] = { at[0], at[1], at[2] };
				}
			}

			bool flip = side == 0;
			for (usz i = 0; i < STEPS; i++)
			{
				for (usz k = 0; k < STEPS; k++)
				{
					uint a = (uint)(base + i * SIDE + k);
					uint b = (uint)(base + i * SIDE + k + 1);
					uint c = (uint)(base + (i + 1) * SIDE + k);
					uint d = (uint)(base + (i + 1) * SIDE + k + 1);

					if (flip)
					{
						indices[index++] = a; indices[index++] = c; indices[index++] = b;
						indices[index++] = b; indices[index++] = c; indices[index++] = d;
					}
					else
					{
						indices[index++] = a; indices[index++] = b; indices[index++] = c;
						indices[index++] = b; indices[index++] = d; indices[index++] = c;
					}
				}
			}
		}
	}

	return { .positions = positions, .indices = indices };
}

// One entry of a keyframe, spelled out so the tables below read as tables.
fn crig::AnimKeyDot turn(
	Allocator allocator,
	String joint,
	Vec3 axis,
	float angle,
	Vec3 move = { 0, 0, 0 }) @local
{
	return {
		.joint_name = joint.copy(allocator),
		.axis = axis,
		.angle = angle,
		.move = move,
	};
}

<*
 Two turns that do not share an axis and a slide on the root, so the check
 covers a rotation channel, a translation channel and the parent-relative frame
 all three are written in.

 **Allocated rather than declared const.** A `const` keyframe table has to point
 at a `const` table of dots, and slicing one const into another is not a constant
 expression: the dots are materialised on the stack of whatever function names
 them, and a template built in a helper comes back pointing into a frame that has
 already returned. The failure is a segfault deep in `AnimTemplate.pose`, several
 calls from anything that looks wrong.

 The template owns everything it points at; release it with `AnimTemplate.free`.
*>
fn crig::AnimTemplate fixture_clip(Allocator allocator)
{
	crig::AnimKeyDot[] rest = alloc::new_array(allocator, crig::AnimKeyDot, 2);
	rest[0] = turn(allocator, "arm_L", { 0, 0, 1 }, 0.0f);
	rest[1] = turn(allocator, "hips", { 0, 1, 0 }, 0.0f);

	crig::AnimKeyDot[] raised = alloc::new_array(allocator, crig::AnimKeyDot, 3);
	raised[0] = turn(allocator, "arm_L", { 0, 0, 1 }, -0.9f);
	raised[1] = turn(allocator, "head", { 0.30151f, 0.90453f, 0.30151f }, 0.6f);
	raised[2] = turn(allocator, "hips", { 0, 1, 0 }, 0.35f, { 0.0f, 0.05f, 0.03f });

	// Its own copy of the opening pose rather than the same slice twice: the two
	// keys are freed separately, and sharing one would free it twice.
	crig::AnimKeyDot[] closing = alloc::new_array(allocator, crig::AnimKeyDot, 2);
	closing[0] = turn(allocator, "arm_L", { 0, 0, 1 }, 0.0f);
	closing[1] = turn(allocator, "hips", { 0, 1, 0 }, 0.0f);

	crig::AnimKeyframe[] frames = alloc::new_array(allocator, crig::AnimKeyframe, 3);
	frames[0] = { .time = 0.0f, .dots = rest };
	frames[1] = { .time = 0.5f, .dots = raised };
	frames[2] = { .time = 1.0f, .dots = closing };

	return {
		.name = "wave".copy(allocator),
		.duration = 1.0f,
		.keyframes = frames,
		.loop = true,
		.owned = true,
	};
}

// Sparse tracks on deliberately unrelated, nonuniform global key times. The
// head key at 0.42 must not become an arm key, and the translation-only hips
// track must not acquire rotation samples from either neighbour.
fn crig::AnimTemplate sparse_fixture_clip(Allocator allocator)
{
	crig::AnimKeyframe[] frames = alloc::new_array(allocator, crig::AnimKeyframe, 5);
	crig::AnimKeyDot[] arm_open = alloc::new_array(allocator, crig::AnimKeyDot, 1);
	arm_open[0] = turn(allocator, "arm_L", { 0, 0, 1 }, 0.0f);
	arm_open[0].channels = ROTATION;
	crig::AnimKeyDot[] hips = alloc::new_array(allocator, crig::AnimKeyDot, 1);
	hips[0] = turn(allocator, "hips", {}, 0.0f, { 0.04f, 0.02f, -0.03f });
	hips[0].channels = TRANSLATION;
	crig::AnimKeyDot[] head = alloc::new_array(allocator, crig::AnimKeyDot, 1);
	head[0] = turn(allocator, "head", { 0, 1, 0 }, 0.55f);
	head[0].channels = ROTATION;
	crig::AnimKeyDot[] arm_high = alloc::new_array(allocator, crig::AnimKeyDot, 1);
	arm_high[0] = turn(allocator, "arm_L", { 0, 0, 1 }, -0.8f);
	arm_high[0].channels = ROTATION;
	crig::AnimKeyDot[] arm_close = alloc::new_array(allocator, crig::AnimKeyDot, 1);
	arm_close[0] = turn(allocator, "arm_L", { 0, 0, 1 }, 0.0f);
	arm_close[0].channels = ROTATION;
	frames[0] = { .time = 0.0f, .dots = arm_open };
	frames[1] = { .time = 0.17f, .dots = hips };
	frames[2] = { .time = 0.42f, .dots = head };
	frames[3] = { .time = 0.73f, .dots = arm_high };
	frames[4] = { .time = 1.0f, .dots = arm_close };
	return { .name = "sparse".copy(allocator), .duration = 1.0f,
		.keyframes = frames, .loop = false, .owned = true };
}

// A plain two-key linear turn which spends most of its duration pressed against
// either side of a narrow anatomical range. Exporting only the constrained end
// keys would turn those plateaus back into one long linear sweep, so this is the
// shape which proves constraint baking preserves the motion between keys too.
fn crig::AnimTemplate constrained_fixture_clip(
	Allocator allocator,
	rig::Skeleton* skeleton)
{
	crig::JointLimitFrame frame = crig::joint_limit_frame_by_index(skeleton, 1, 2);
	Vec3 axis = frame.axis(crig::JointRotationAxis.X);
	crig::AnimKeyDot[] low = alloc::new_array(allocator, crig::AnimKeyDot, 1);
	crig::AnimKeyDot[] high = alloc::new_array(allocator, crig::AnimKeyDot, 1);
	low[0] = turn(allocator, "spine", axis, -1.0f);
	high[0] = turn(allocator, "spine", axis, 1.0f);
	crig::AnimKeyframe[] frames = alloc::new_array(allocator, crig::AnimKeyframe, 2);
	frames[0] = { .time = 0.0f, .dots = low };
	frames[1] = { .time = 1.0f, .dots = high };
	return { .name = "limited".copy(allocator), .duration = 1.0f,
		.keyframes = frames, .loop = false, .owned = true };
}

fn crig::ConstraintRig fixture_constraints(rig::Skeleton* skeleton)
{
	crig::ConstraintRig out = {};
	out.joints = alloc::new_array(mem, crig::JointConstraint,
		(sz)skeleton.len());
	crig::JointRotationLimits defaults = crig::unconstrained_rotation(0);
	foreach (&joint : out.joints)
	{
		*joint = {
			.status = crig::JointConstraintStatus.FREE,
			.axes = defaults.axes,
			.primary_child = -1,
			.frame_adjustment = quaternion::IDENTITY,
			.frame_status = crig::JointLimitFrameStatus.READY,
		};
	}

	crig::JointConstraint* spine = &out.joints[1];
	spine.status = crig::JointConstraintStatus.EXACT;
	spine.frame_intent = crig::ConstraintFrameIntent.PRIMARY_CHILD;
	spine.primary_child = 2;
	spine.axes[0] = { .allowed = true, .minimum = -0.20f, .maximum = 0.25f };
	spine.axes[1] = { .allowed = false, .locked = 0.0f };
	spine.axes[2] = { .allowed = false, .locked = 0.0f };
	return out;
}

// ---------------------------------------------------------------------------
// A glTF player that knows nothing about crig
// ---------------------------------------------------------------------------

// Raised rather than asserted: a file the replay cannot read is a check that
// says so, not one that quietly compares nothing.
faultdef REPLAY_NO_SKIN, REPLAY_UNSUPPORTED, REPLAY_JOINT_OUT_OF_RANGE;

// Where every joint and every vertex of a file ends up at one instant.
struct ReplayFrame
{
	Vec3[] joints;   // one per entry of the skin's joint list, in file order
	Vec3[] vertices; // one per POSITION, deformed
}

fn void ReplayFrame.free(&self, Allocator allocator)
{
	if (self.joints.len > 0) alloc::free(allocator, self.joints);
	if (self.vertices.len > 0) alloc::free(allocator, self.vertices);
	*self = {};
}

// Column-major, the layout glTF stores a MAT4 in and the one Matrix4x4.apply
// reads — so an inverse bind matrix off the wire needs no transpose.
fn Matrix4f compose(Vec3 translation, Quaternionf rotation, Vec3 scale) @local
{
	float[<4>] q = rotation.v;
	float x = q[0];
	float y = q[1];
	float z = q[2];
	float w = q[3];

	float[3] c0 = { 1 - 2 * (y * y + z * z), 2 * (x * y + z * w), 2 * (x * z - y * w) };
	float[3] c1 = { 2 * (x * y - z * w), 1 - 2 * (x * x + z * z), 2 * (y * z + x * w) };
	float[3] c2 = { 2 * (x * z + y * w), 2 * (y * z - x * w), 1 - 2 * (x * x + y * y) };

	Matrix4f out;
	out.m = {
		c0[0] * scale.x, c0[1] * scale.x, c0[2] * scale.x, 0.0f,
		c1[0] * scale.y, c1[1] * scale.y, c1[2] * scale.y, 0.0f,
		c2[0] * scale.z, c2[1] * scale.z, c2[2] * scale.z, 0.0f,
		translation.x, translation.y, translation.z, 1.0f,
	};
	return out;
}

// The one sampler shape this writer emits. STEP and CUBICSPLINE would need their
// own arms; a file carrying one should fail here rather than be read as linear.
fn float sampler_fraction(float[] times, float at, usz* lower) @local
{
	if (times.len == 0) return 0.0f;
	if (at <= times[0])
	{
		*lower = 0;
		return 0.0f;
	}
	if (at >= times[times.len - 1])
	{
		*lower = times.len - 1;
		return 0.0f;
	}
	usz hi = 1;
	while (hi < times.len && times[hi] < at) hi++;
	*lower = hi - 1;
	float span = times[hi] - times[hi - 1];
	return span <= 0.0f ? 0.0f : (at - times[hi - 1]) / span;
}

<*
 Play `animation` at `time` the way the glTF specification says to.

 Nothing in here calls crig: the node transforms come off the wire, the channels
 are sampled and composed here, and the skinning is
 `world(joint) * inverseBind(joint)` blended by the vertex's own weights. That is
 the whole point — a replay sharing crig's posing code could not disagree with it.

 The caller owns the frame.
*>
fn ReplayFrame? replay_frame(
	Allocator allocator,
	gltf::GltfStream* stream,
	usz animation,
	float time)
{
	usz nodes = (usz)stream.gltf.nodes.len();
	Vec3[] translation = alloc::new_array(allocator, Vec3, (sz)nodes);
	Quaternionf[] rotation = alloc::new_array(allocator, Quaternionf, (sz)nodes);
	Vec3[] scale = alloc::new_array(allocator, Vec3, (sz)nodes);
	defer
	{
		alloc::free(allocator, translation);
		alloc::free(allocator, rotation);
		alloc::free(allocator, scale);
	}

	for (usz i = 0; i < nodes; i++)
	{
		gltf::Node* node = stream.gltf.nodes.get_ref((sz)i);
		translation[i] = node.translation;
		rotation[i] = node.rotation;
		scale[i] = node.scale;
	}

	// --- the channels -------------------------------------------------------

	gltf::Animation anim = stream.gltf.animations[(sz)animation];
	foreach (channel : anim.channels)
	{
		gltf::AnimationSampler sampler = anim.samplers[(sz)channel.sampler];
		if (sampler.interpolation != gltf::Interpolation.LINEAR) return REPLAY_UNSUPPORTED~;

		gltf::Accessor input = stream.gltf.accessors[sampler.input];
		usz keys = (usz)input.count;
		if (keys == 0) continue;

		float[] times = alloc::new_array(allocator, float, (sz)keys);
		defer alloc::free(allocator, times);
		for (usz k = 0; k < keys; k++) times[k] = stream.@cast_buffer(input, (sz)k, float);

		usz lower;
		float fraction = sampler_fraction(times, time, &lower);
		usz upper = lower + 1 < keys ? lower + 1 : lower;

		gltf::Accessor output = stream.gltf.accessors[sampler.output];
		usz node = (usz)channel.target.node;

		switch (channel.target.path)
		{
			case gltf::AnimationProperty.ROTATION:
				Quaternionf a = { .v = stream.@cast_buffer(output, (sz)lower, float[<4>]) };
				Quaternionf b = { .v = stream.@cast_buffer(output, (sz)upper, float[<4>]) };
				rotation[node] = replay_slerp(a, b, fraction);
			case gltf::AnimationProperty.TRANSLATION:
				Vec3 a = stream.@cast_buffer(output, (sz)lower, Vec3);
				Vec3 b = stream.@cast_buffer(output, (sz)upper, Vec3);
				translation[node] = a + (b - a) * fraction;
			case gltf::AnimationProperty.SCALE:
				Vec3 a = stream.@cast_buffer(output, (sz)lower, Vec3);
				Vec3 b = stream.@cast_buffer(output, (sz)upper, Vec3);
				scale[node] = a + (b - a) * fraction;
			default:
				break;
		}
	}

	// --- the hierarchy ------------------------------------------------------

	Matrix4f[] world = alloc::new_array(allocator, Matrix4f, (sz)nodes);
	defer alloc::free(allocator, world);

	bool[] placed = alloc::new_array(allocator, bool, (sz)nodes);
	defer alloc::free(allocator, placed);

	// Roots first, then anything whose parent is already placed. Iterative rather
	// than recursive: the depth is whatever the file says it is.
	for (usz pass = 0; pass < nodes; pass++)
	{
		bool progressed = false;
		for (usz i = 0; i < nodes; i++)
		{
			if (placed[i]) continue;
			gltf::Node* node = stream.gltf.nodes.get_ref((sz)i);
			Matrix4f local = compose(translation[i], rotation[i], scale[i]);

			if (node.parent == null)
			{
				world[i] = local;
			}
			else
			{
				usz parent = (usz)node.parent.index;
				if (!placed[parent]) continue;
				world[i] = world[parent].mul(local);
			}
			placed[i] = true;
			progressed = true;
		}
		if (!progressed) break;
	}

	// --- the skin -----------------------------------------------------------

	if (stream.gltf.skins.len() == 0) return REPLAY_NO_SKIN~;
	gltf::Skin skin = stream.gltf.skins[0];
	usz bones = (usz)skin.joints.len();

	gltf::Accessor inverse_bind = stream.gltf.accessors[skin.inverseBindAccessor];
	Matrix4f[] palette = alloc::new_array(allocator, Matrix4f, (sz)bones);
	defer alloc::free(allocator, palette);

	Vec3[] joint_at = alloc::new_array(allocator, Vec3, (sz)bones);
	for (usz k = 0; k < bones; k++)
	{
		usz node = (usz)skin.joints[(sz)k];
		Matrix4f ibm = stream.@cast_buffer(inverse_bind, (sz)k, Matrix4f);
		palette[k] = world[node].mul(ibm);

		float[<4>] origin = world[node].apply({ 0, 0, 0, 1 });
		joint_at[k] = { origin.x, origin.y, origin.z };
	}

	// The skinned primitive, found by asking which node carries the skin rather
	// than by assuming it is mesh zero.
	gltf::Primitive? skinned = find_skinned_primitive(stream);
	if (catch skinned) return REPLAY_NO_SKIN~;
	gltf::Primitive primitive = skinned;

	sz? position_index = primitive.attributes.get("POSITION");
	if (catch position_index) return REPLAY_NO_SKIN~;
	gltf::Accessor positions = stream.gltf.accessors[position_index];
	usz count = (usz)positions.count;

	Vec3[] deformed = alloc::new_array(allocator, Vec3, (sz)count);
	for (usz v = 0; v < count; v++) deformed[v] = { 0, 0, 0 };

	// Every JOINTS_n / WEIGHTS_n set the file carries, accumulated in turn — a
	// binding wider than four slots is written as several.
	for (usz set = 0; ; set++)
	{
		String joint_key = string::tformat("JOINTS_%d", set);
		String weight_key = string::tformat("WEIGHTS_%d", set);

		sz? joint_index = primitive.attributes.get(joint_key);
		sz? weight_index = primitive.attributes.get(weight_key);
		if (catch joint_index) break;
		if (catch weight_index) break;

		gltf::Accessor joint_slots = stream.gltf.accessors[joint_index];
		gltf::Accessor weight_slots = stream.gltf.accessors[weight_index];

		for (usz v = 0; v < count; v++)
		{
			Vec3 rest = stream.@cast_buffer(positions, (sz)v, Vec3);
			float[<4>] weights = stream.@cast_buffer(weight_slots, (sz)v, float[<4>]);

			uint[4] which;
			switch (joint_slots.data_type)
			{
				case gltf::DataType.CHAR:
					char[<4>] narrow = stream.@cast_buffer(joint_slots, (sz)v, char[<4>]);
					for (usz s = 0; s < 4; s++) which[s] = (uint)narrow[s];
				case gltf::DataType.USHORT:
					ushort[<4>] wide = stream.@cast_buffer(joint_slots, (sz)v, ushort[<4>]);
					for (usz s = 0; s < 4; s++) which[s] = (uint)wide[s];
				default:
					return REPLAY_UNSUPPORTED~;
			}

			for (usz s = 0; s < 4; s++)
			{
				float weight = weights[s];
				if (weight == 0.0f) continue;
				if ((usz)which[s] >= bones) return REPLAY_JOINT_OUT_OF_RANGE~;

				float[<4>] moved = palette[which[s]].apply({ rest.x, rest.y, rest.z, 1.0f });
				deformed[v] += (Vec3){ moved.x, moved.y, moved.z } * weight;
			}
		}
	}

	return { .joints = joint_at, .vertices = deformed };
}

// Local rather than the stdlib's, so the replay does not inherit whatever the
// posing code inherits.
fn Quaternionf replay_slerp(Quaternionf a, Quaternionf b, float t) @local
{
	float[<4>] p = a.v;
	float[<4>] q = b.v;

	float dot = p[0] * q[0] + p[1] * q[1] + p[2] * q[2] + p[3] * q[3];
	if (dot < 0.0f)
	{
		q = -q;
		dot = -dot;
	}

	float[<4>] out;
	if (dot > 0.9995f)
	{
		out = p + (q - p) * t;
	}
	else
	{
		float theta = math::acos(math::clamp(dot, -1.0f, 1.0f));
		float sin_theta = math::sin(theta);
		out = p * (math::sin(theta * (1.0f - t)) / sin_theta)
			+ q * (math::sin(theta * t) / sin_theta);
	}

	float length = math::sqrt(out[0] * out[0] + out[1] * out[1] + out[2] * out[2] + out[3] * out[3]);
	if (length > 0.0f) out = out / length;
	return { .v = out };
}

fn gltf::Primitive? find_skinned_primitive(gltf::GltfStream* stream) @local
{
	usz nodes = (usz)stream.gltf.nodes.len();
	for (usz i = 0; i < nodes; i++)
	{
		gltf::Node* node = stream.gltf.nodes.get_ref((sz)i);
		if (!node.has_skin() || !node.has_mesh()) continue;

		gltf::Mesh mesh = stream.gltf.meshes[(usz)node.mesh];
		foreach (primitive : mesh.primitives) return primitive;
	}
	return REPLAY_NO_SKIN~;
}

// ---------------------------------------------------------------------------
// The checks
// ---------------------------------------------------------------------------

<*
 Everything the writer is handed and everything the preview binds.

 Built once for the process and read by every check, never written: what a
 check needs to change — a clip, a constraint rig — it makes for itself. The
 bind is at production resolution, since two of the checks below are about
 what that bind contains, and at that resolution it costs a second; paid once
 it is a rounding error, paid per check it was most of the suite.

 Allocated on the real heap `shared_app` captured before the runner installed
 any check's tracking allocator, so the first check to ask for it is not
 charged with a leak.
*>
struct Bench
{
	rig::Skeleton skeleton;
	rig::TriMesh body;
	rig::MeshVoxels voxels;
	rig::MeshShells shells;
	float[] dense;              // the writer's matrix, reaches applied
	gltf::SkinBinding preview;  // what AppState.rebind_skin binds
}

Bench shared_bench @local;
bool shared_bench_ready @local;

fn Bench* setup()
{
	Bench* out = &shared_bench;
	if (shared_bench_ready) return out;

	shared_app::@on_real_heap()
	{
		out.skeleton = fixture_skeleton();
		out.body = fixture_body();
		out.voxels = rig::build_voxels(mem, out.body);
		out.shells = rig::build_shells(mem, out.body);

		// The two calls under test, written the way the app makes them:
		// AppState.write_rigged (app/history.c3) and AppState.rebind_skin (app/pose.c3).
		out.dense = rig::bind_geodesic(mem, &out.voxels, out.body.positions,
			out.skeleton.joints, out.skeleton.parents, &out.shells, {},
			reaches: REACHES[..]);
		out.preview = rig::bind_skin(mem, out.body.positions, &out.skeleton,
			&out.voxels, &out.shells, {}, reaches: REACHES[..])!!;
	};

	shared_bench_ready = true;
	return out;
}

// Deform through a sparse binding, the way rig::apply_skin and every glTF player
// do. Here rather than borrowed so the crig side of the comparison is spelled
// out beside the file side.
fn void skin_through(Vec3[] out, Vec3[] rest, gltf::SkinBinding binding, Matrix4f[] palette)
{
	foreach (usz v, at : rest)
	{
		Vec3 sum = { 0, 0, 0 };
		usz base = v * (usz)binding.slots;
		for (uint s = 0; s < binding.slots; s++)
		{
			float weight = binding.weights[base + s];
			if (weight == 0.0f) continue;
			float[<4>] moved = palette[binding.joints[base + s]].apply({ at.x, at.y, at.z, 1.0f });
			sum += (Vec3){ moved.x, moved.y, moved.z } * weight;
		}
		out[v] = sum;
	}
}

<*
 A rigged, animated .glb deforms its mesh where crig's own preview put it.

 The check the writer exists to pass. crig poses a joint as a rotation about its
 rest position in world axes on nodes carrying no rotation; the file holds
 bone-aligned nodes, converted channels and four weights a vertex. Both halves
 have to describe the same motion of the same surface, and only an outside reader
 can say whether they do.

 Joints and vertices are both compared because they fail separately: a frame error
 moves the joints, and a binding error leaves the joints exactly right and the
 surface hanging off them wrong.

 *Re-introduce:* drop `reaches` from either `bind_skin` in `setup` or the
 `bind_geodesic` beside it, and the vertices part.
*>
fn void a_rigged_file_deforms_where_crig_showed_it() @test
{
	check_rigged_replay(false, false);
}

fn void a_saved_and_reopened_animation_exports_the_original_motion() @test
{
	check_rigged_replay(true, false);
}

fn void sparse_nonuniform_tracks_replay_as_previewed() @test
{
	check_rigged_replay(false, true);
}

fn void stretched_sparse_motion_survives_save_and_game_export() @test
{
	check_rigged_replay(true, true, true);
}

fn void channel_edited_motion_survives_save_and_game_export() @test
{
	check_rigged_replay(true, true, channel_edit: true);
}

fn void held_segment_survives_save_and_game_export() @test
{
	check_rigged_replay(true, true, hold: true);
}

fn void automatic_segment_survives_save_and_game_export() @test
{
	check_rigged_replay(true, true, automatic: true);
}

// Eased segments (a linear one and a smooth one) reach the sidecar and the
// game file as the viewport plays them.
fn void eased_segments_survive_save_and_game_export() @test
{
	check_rigged_replay(true, true, eased: true);
	check_rigged_replay(true, true, automatic: true, eased: true);
}

// A cycle whose last key stops short of the end blends back to the first key
// over what is left; one whose end differs is eased back when Loop is turned on.
// Both wrap spans have to reach the file as they play in the viewport.
fn void a_loop_wrap_span_replays_as_previewed() @test
{
	check_rigged_replay(false, false, loop_case: 1);
	check_rigged_replay(false, false, loop_case: 2);
}

fn void joint_limited_game_export_replays_the_constrained_viewport() @test
{
	check_rigged_replay(false, false, constrained: true);
}

fn void joint_limited_model_reskin_bakes_the_constrained_viewport() @test
{
	Bench* bench = setup();
	crig::ConstraintRig constraints = fixture_constraints(&bench.skeleton);
	defer constraints.free(mem);
	crig::AnimTemplate clip = constrained_fixture_clip(mem, &bench.skeleton);
	defer clip.free(mem);
	crig::AnimTemplate[1] source = { clip };

	gltf_edit::ReskinClip[] written = crig::reskin_clips(mem, &bench.skeleton, JOINTS[..], source[..],
		constraints);
	defer crig::free_reskin_clips(mem, written);
	test::@check(written.len == 1 && written[0].times.len > clip.keyframes.len,
		"model reskin densifies a constrained animation");
	if (written.len != 1) return;

	int spine_curve = -1;
	foreach (usz curve, channel : written[0].curves)
	{
		if (channel.joint == 1 && channel.turns.len == written[0].times.len)
		{
			spine_curve = (int)curve;
			break;
		}
	}
	test::@check(spine_curve >= 0, "model reskin writes the constrained spine channel");
	if (spine_curve < 0) return;

	float worst = 0.0f;
	for (usz step = 0; step < 97; step++)
	{
		float time = (float)step / 96.0f;
		usz lower;
		float fraction = sampler_fraction(written[0].times, time, &lower);
		usz upper = lower + 1 < written[0].times.len ? lower + 1 : lower;
		Quaternionf replayed = replay_slerp(
			written[0].curves[(usz)spine_curve].turns[lower],
			written[0].curves[(usz)spine_curve].turns[upper], fraction);

		rig::Pose expected = clip.pose(mem, &bench.skeleton, JOINTS[..], time, false);
		crig::constrain_pose_to_constraint_rig(&bench.skeleton, constraints,
			&expected);
		float gap = 1.0f - math::abs(replayed.v.dot(expected.rotations[1].v));
		if (gap > worst) worst = gap;
		expected.free(mem);
	}
	test::@check(worst < 1.0e-6f,
		"model reskin's ordinary curve matches the constrained pose between keys");
	test::@check(clip.keyframes[0].dots[0].angle == -1.0f
		&& clip.keyframes[1].dots[0].angle == 1.0f,
		"model reskin leaves the editable source keys unchanged");
}

fn void check_rigged_replay(bool reopen, bool sparse, bool stretch = false,
	bool channel_edit = false, bool hold = false, bool automatic = false,
	bool constrained = false, int loop_case = 0, bool eased = false)
{
	Bench* bench = setup();

	crig::ConstraintRig constraints = constrained
		? fixture_constraints(&bench.skeleton)
		: {};
	defer constraints.free(mem);
	crig::AnimTemplate clip = constrained
		? constrained_fixture_clip(mem, &bench.skeleton)
		: (sparse ? sparse_fixture_clip(mem) : fixture_clip(mem));
	if (hold)
	{
		clip.keyframes[0].dots[0].rotation_interpolation = crig::AnimInterpolation.HOLD;
	}
	if (automatic)
	{
		clip.keyframes[0].dots[0].rotation_interpolation = crig::AnimInterpolation.AUTO;
	}
	if (eased)
	{
		clip.keyframes[0].dots[0].rotation_ease = { 1.0f, 1.0f };
		clip.keyframes[3].dots[0].rotation_ease = { 0.6f, 0.0f };
	}
	if (loop_case > 0)
	{
		// The closing key made a different pose, so the wrap has somewhere to go.
		clip.keyframes[2].dots[0].angle = -0.4f;
		clip.duration = loop_case == 1 ? 1.4f : 1.0f;
		clip.loop = loop_case == 1;
		if (loop_case == 2)
		{
			bool extended;
			crig::AnimTemplate looped = crig::clip_looped(mem, clip, &extended);
			test::@check(extended && looped.duration > 1.0f, "turning Loop on did not ease the differing end back");
			clip.free(mem);
			clip = looped;
		}
	}
	if (stretch)
	{
		crig::AnimTemplate retimed = crig::clip_retimed(mem, clip, clip.duration * 1.7f);
		clip.free(mem);
		clip = retimed;
	}
	if (channel_edit)
	{
		// Exercise the editor's real immutable replacement before the independent
		// glTF reader checks the saved/reopened animation against its preview.
		crig::AppState app = crig::new_app({});
		defer app.free();
		crig::AnimRef ref = app.put_authored_clip(crig::clip_copy(mem, clip));
		(void)app.bind_ref(ref);
		app.editing = ref;
		app.select_animation_channel_key(ref, 0.73f, "arm_L", ROTATION);
		test::@check(app.move_selected_animation_keys(ref, -0.13f),
			"could not move the arm rotation before export");
		clip.free(mem);
		clip = crig::clip_copy(mem, *app.clip(app.editing));
	}
	defer clip.free(mem);
	crig::AnimTemplate[1] library = { clip };
	crig::AnimTemplate[] exporting = library[..];
	crig::AnimTemplate[] restored = {};
	defer if (restored.len > 0) crig::free_animations(mem, restored);
	if (reopen)
	{
		// Export the saved keys, but compare against the original in-memory
		// motion using the independent glTF sampler below.
		String sidecar = "build/gltf-replay.rigsmith.json";
		defer (void)file::delete(sidecar);
		crig::RigDocument doc = {};
		if (catch crig::write_session(sidecar, &doc, FIXTURE, library[..]))
		{
			test::@check(false, "could not save authored animation for replay");
			return;
		}
		crig::AnimTemplate[]? read = crig::read_session_clips(mem, sidecar);
		if (catch read)
		{
			test::@check(false, "could not reopen authored animation for replay");
			return;
		}
		restored = read;
		test::@check(restored.len == 1, "the saved animation did not reopen");
		if (restored.len != 1) return;
		exporting = restored;
	}

	if (catch fault error = crig::export_rigged_animated_glb(
		mem, FIXTURE, bench.body, &bench.skeleton, JOINTS[..], bench.dense,
		exporting, "body", constraints: constraints))
	{
		test::@check(false, "SKIPPED — the writer refused the fixture");
		io::printfn("  %s", error);
		return;
	}

	gltf::GltfStream? opened = gltf::open(FIXTURE, mem);
	if (catch opened)
	{
		test::@check(false, "SKIPPED — the file it wrote could not be opened");
		return;
	}
	gltf::GltfStream stream = opened;
	defer stream.close();
	if (catch stream.load_all_buffers())
	{
		test::@check(false, "SKIPPED — the file's buffers could not be read");
		return;
	}
	if (constrained)
	{
		// The game file gains ordinary samples; the editable source does not.
		test::@check(clip.keyframes.len == 2
			&& clip.keyframes[0].dots[0].angle == -1.0f
			&& clip.keyframes[1].dots[0].angle == 1.0f,
			"constraint export keeps the authored keys unchanged");
		gltf::Animation written = stream.gltf.animations[0];
		// The longest sampler: a channel that holds still is written as one key.
		usz baked = 0;
		foreach (sampler : written.samplers)
		{
			baked = math::max(baked, (usz)stream.gltf.accessors[sampler.input].count);
		}
		test::@check(baked > clip.keyframes.len,
			"constraint export adds samples around limit boundaries");
	}

	usz vertices = bench.body.positions.len;
	Vec3[] here = alloc::new_array(mem, Vec3, (sz)vertices);
	defer alloc::free(mem, here);

	// The file names its joints in its own order; crig's is joint order. Matched
	// by name, because agreeing by accident of ordering is not agreeing.
	gltf::Skin skin = stream.gltf.skins[0];
	usz[] to_crig = alloc::new_array(mem, usz, (sz)skin.joints.len());
	defer alloc::free(mem, to_crig);
	for (usz k = 0; k < (usz)skin.joints.len(); k++)
	{
		String name = stream.gltf.nodes.get_ref((sz)skin.joints[(sz)k]).name;
		usz found = JOINTS.len;
		foreach (usz j, joint : JOINTS)
		{
			if (joint == name) found = j;
		}
		if (found == JOINTS.len)
		{
			test::@check(false, "every joint in the file is one crig named");
			return;
		}
		to_crig[k] = found;
	}

	float worst_joint = 0.0f;
	float worst_vertex = 0.0f;
	usz samples = constrained || eased ? 97 : SAMPLES;
	for (usz step = 0; step < samples; step++)
	{
		float time = clip.duration * (float)step / (float)(samples - 1);

		rig::Pose pose = clip.pose(mem, &bench.skeleton, JOINTS[..], time);
		defer pose.free(mem);
		if (constrained)
		{
			crig::constrain_pose_to_constraint_rig(&bench.skeleton, constraints,
				&pose);
		}
		Matrix4f[] palette = rig::joint_palette(mem, &bench.skeleton, pose)!!;
		defer alloc::free(mem, palette);

		skin_through(here, bench.body.positions, bench.preview, palette);

		ReplayFrame? played = replay_frame(mem, &stream, 0, time);
		if (catch fault error = played)
		{
			test::@check(false, "the written file can be replayed as glTF");
			io::printfn("  %s at t=%.3f", error, time);
			return;
		}
		ReplayFrame frame = played;
		defer frame.free(mem);

		foreach (usz k, at : frame.joints)
		{
			usz j = to_crig[k];
			float[<4>] moved = palette[j].apply(
				{ bench.skeleton.joints[j].x, bench.skeleton.joints[j].y,
				  bench.skeleton.joints[j].z, 1.0f });
			float gap = (at - (Vec3){ moved.x, moved.y, moved.z }).length();
			if (gap > worst_joint) worst_joint = gap;
		}

		foreach (usz v, at : frame.vertices)
		{
			float gap = (at - here[v]).length();
			if (gap > worst_vertex) worst_vertex = gap;
		}
	}

	io::printfn("  replayed as glTF: joints %.7f out, vertices %.7f out",
		worst_joint, worst_vertex);
	// Auto is baked at the editor's documented four subdivisions per authored
	// span. Its small between-sample fitting error is bounded separately from
	// the float-roundtrip tolerance used by exact Linear/Hold curves.
	float tolerance = automatic || constrained || eased ? 1.0e-3f : EXACT;
	test::@check(worst_joint < tolerance, "an outside reader puts the joints where crig does");
	test::@check(worst_vertex < tolerance, "and deforms the mesh where crig does");

	(void)file::delete(FIXTURE);
}

<*
 The preview binds the same skin the writer writes.

 `AppState.rebind_skin` and `AppState.write_rigged` bind separately — one wants a
 `SkinBinding` to draw with, the other a dense matrix to prune before writing —
 so the two call sites can drift apart in what they pass. They did: the preview
 bound without `reaches` while the writer bound with them, and the result was a
 viewport that deformed the mesh one way and a file that deformed it another.

 Stated over the bindings rather than over a picture, because that is where the
 divergence is: same joints, same weights, or the file is not what was shown.
*>
fn void the_preview_binds_what_the_writer_writes() @test
{
	Bench* bench = setup();

	usz bones = bench.skeleton.len();
	usz vertices = bench.body.positions.len;

	gltf::SkinBinding? written = gltf::sparsify_weights(mem, bench.dense, vertices, bones, 4);
	if (catch written)
	{
		test::@check(false, "SKIPPED — the writer's matrix would not sparsify");
		return;
	}
	gltf::SkinBinding writer = written;
	defer writer.free(mem);

	test::@check(writer.slots == bench.preview.slots, "both bindings hold the same slots");
	if (writer.slots != bench.preview.slots) return;

	usz differing = 0;
	float worst = 0.0f;
	for (usz v = 0; v < vertices; v++)
	{
		usz base = v * (usz)writer.slots;
		for (uint s = 0; s < writer.slots; s++)
		{
			float gap = math::abs(writer.weights[base + s] - bench.preview.weights[base + s]);
			if (writer.joints[base + s] != bench.preview.joints[base + s] || gap > EXACT)
			{
				differing++;
				break;
			}
			if (gap > worst) worst = gap;
		}
	}

	io::printfn("  %d of %d vertices bound differently, worst weight %.7f out",
		differing, vertices, worst);
	test::@check(differing == 0, "the preview and the writer bind every vertex the same");
}

<*
 The fixture's reaches change the binding they are given to.

 Guards the two checks above from passing on a rig with nothing to disagree
 about. A reach only matters where it is short enough to hand a vertex to a
 different joint; a fixture whose reaches are all longer than the model would
 bind identically with them and without, and the check that the preview and the
 writer agree would then be checking nothing.
*>
fn void check_the_fixture_reaches_actually_bite() @test
{
	Bench* bench = setup();

	gltf::SkinBinding? unlimited_bound = rig::bind_skin(
		mem, bench.body.positions, &bench.skeleton, &bench.voxels, &bench.shells);
	if (catch unlimited_bound)
	{
		test::@check(false, "SKIPPED — the unlimited bind failed");
		return;
	}
	gltf::SkinBinding unlimited = unlimited_bound;
	defer unlimited.free(mem);

	usz differing = 0;
	for (usz v = 0; v < bench.body.positions.len; v++)
	{
		usz base = v * (usz)unlimited.slots;
		for (uint s = 0; s < unlimited.slots; s++)
		{
			if (unlimited.joints[base + s] != bench.preview.joints[base + s]
				|| math::abs(unlimited.weights[base + s] - bench.preview.weights[base + s]) > 1.0e-3f)
			{
				differing++;
				break;
			}
		}
	}

	io::printfn("  reaches move %d of %d vertices", differing, bench.body.positions.len);
	test::@check(differing > 0, "the fixture's reaches change what it binds");
}

<*
 A constrained animation, exported and then re-saved, must not grow.

 The trap: `write_rig_into_model` re-authors the file's animation by baking it
 through the joint limits, and it reads the clip back *from the file it is
 rewriting*. A dense per-span seed would be re-subdivided on every save, so the
 keyframes multiplied ANIM_BAKE_STEPS-fold each time (9 -> 33 -> 129 -> ...) —
 and a rig's limits are file metadata that make it happen on every save, without
 end. The adaptive refine, seeded with the authored keys rather than a dense
 grid, is idempotent: a span already straight within tolerance gets no new
 sample, so baking a baked clip reproduces it.

 The witness is the keyframe count. The first bake densifies around the limit;
 baking what that produced back through the same limits keeps the count — it does
 not multiply it — while still holding more keys than the sparse source, so the
 constrained curve is not lost.
*>
fn void a_constrained_export_re_saves_without_growing() @test
{
	Bench* bench = setup();
	crig::ConstraintRig constraints = fixture_constraints(&bench.skeleton);
	defer constraints.free(mem);
	crig::AnimTemplate clip = constrained_fixture_clip(mem, &bench.skeleton);
	defer clip.free(mem);
	crig::AnimTemplate[1] source = { clip };

	// The first bake — the sparse authored keys sampled wherever the constrained
	// curve bends. This is what an export writes into the file.
	gltf_edit::ReskinClip[] first = crig::reskin_clips(mem, &bench.skeleton, JOINTS[..],
		source[..], constraints);
	defer crig::free_reskin_clips(mem, first);
	test::@check(first.len == 1 && first[0].times.len > clip.keyframes.len,
		"the constrained export should densify around the limit");
	if (first.len != 1) return;
	usz baked = first[0].times.len;

	// Put that baked clip into a real file, exactly as an export does, then read
	// its clip back the way a save reads its own.
	String path = "build/gltf-replay-resave.glb";
	defer (void)file::delete(path);
	defer (void)file::delete("build/gltf-replay-resave.rigsmith.json");
	if (catch crig::export_rigged_animated_glb(mem, path, bench.body, &bench.skeleton,
		JOINTS[..], bench.dense, source[..], "body", constraints: constraints))
	{
		test::@check(false, "the writer refused the constrained fixture");
		return;
	}
	crig::AnimPack read = crig::read_pack(mem, path)!!;
	defer read.free(mem);
	test::@check(read.clips.len == 1, "the exported file did not read back one clip");
	if (read.clips.len != 1) return;
	usz in_file = read.clips[0].keyframes.len;

	// The save's own re-bake: read the file's already-baked clip and bake it
	// again through the same limits. It must reproduce the count, not multiply it.
	gltf_edit::ReskinClip[] again = crig::reskin_clips(mem, &bench.skeleton, JOINTS[..],
		read.clips, constraints);
	defer crig::free_reskin_clips(mem, again);
	test::@check(again.len == 1, "re-baking the file's clip dropped it");
	if (again.len != 1) return;
	test::@check(again[0].times.len <= in_file,
		"re-baking multiplied the keyframes: %d in the file -> %d (must not grow)",
		in_file, again[0].times.len);
	test::@check(again[0].times.len > clip.keyframes.len,
		"re-baking collapsed the constrained curve below the source keys");
}
