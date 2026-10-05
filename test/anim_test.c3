<*
 Posing and skinning, offline and with no GPU.

     `c3c test --trust=full --test-filter crig_tests::anim`

 Answers the question the tint views cannot: given the dots someone placed, does
 the mesh actually deform when a joint turns, and does it deform *only* where it
 should. A colour map shows which joint owns a vertex; this shows what happens
 when that joint moves, which is the thing a rig is for.

 The fixture is a two-legged stick figure built in code — a pelvis, a hip and a
 foot down each side. Small enough to reason about by hand, and shaped like the
 failure that matters: two limbs side by side, which is exactly where
 straight-line binding bleeds one into the other. `the_still_leg_mostly_stays_put`
 measures that bleed as a number, so a better binder has something to beat.

 The last two run the load-bearing claims again at a real vertex count, against
 a mesh in the repo rather than one named on a command line.
*>
module crig_tests::anim;

import crig;
import rig;
import gltf;
import std::core::test;
import std::io;
import std::math;
import std::math::vector;
import std::math::matrix;
import std::math::quaternion;



// How far apart the legs stand, and how many points sample each one.
const float LEG_X = 0.3f;
const usz LEG_SAMPLES = 12;

// Rest must be reproduced to float precision, not merely closely: every joint's
// transform cancels its own inverse bind exactly, so anything above rounding
// means the two frames disagree.
const float REST_EPSILON = 1.0e-5f;

<*
 A real mesh with a real vertex count, kept in the repo so the checks that need
 one run everywhere rather than only where someone has a model to hand.

 Relative, so the run has to start from the crig directory — the same assumption
 the font path makes.
*>
const String REAL_MESH = "assets/animations/humanoid.glb";

<*
 Pelvis, hip and foot down each side — five joints, parents before children.

 A real rig arrives from `build_skeleton`'s BFS; this one is written out so the
 test depends on the pose math alone and not on the graph walk that feeds it.
*>
fn rig::Skeleton biped_skeleton(Allocator allocator)
{
	Vec3[] joints = alloc::new_array(allocator, Vec3, 5);
	int[] parents = alloc::new_array(allocator, int, 5);

	joints[0] = { 0, 0, 0 };           parents[0] = -1;   // pelvis, the root
	joints[1] = { -LEG_X, 0, 0 };      parents[1] = 0;    // hip, left
	joints[2] = { -LEG_X, -1.0f, 0 };  parents[2] = 1;    // foot, left
	joints[3] = { LEG_X, 0, 0 };       parents[3] = 0;    // hip, right
	joints[4] = { LEG_X, -1.0f, 0 };   parents[4] = 3;    // foot, right

	return { .joints = joints, .parents = parents };
}

// Joint and vertex names, so the checks below read as anatomy rather than as
// indices. Vertices run left leg, then right leg, then the body.
const usz HIP_L = 1;
const usz FOOT_L = 2;
const usz LEFT_FIRST = 0;
const usz RIGHT_FIRST = LEG_SAMPLES;
const usz BODY_FIRST = LEG_SAMPLES * 2;
// The lowest sample on the left leg, sitting on the foot joint itself.
const usz LEFT_TIP = LEG_SAMPLES - 1;

<*
 Points down both legs and a short column up the middle for a body.

 Samples start at the hip and end on the foot, so the last one of each leg sits
 exactly on the joint — a vertex with a single influence, which is what makes an
 exact prediction possible further down.
*>
fn Vec3[] biped_positions(Allocator allocator)
{
	usz body = 4;
	Vec3[] positions = alloc::new_array(allocator, Vec3, (sz)(LEG_SAMPLES * 2 + body));

	for (usz i = 0; i < LEG_SAMPLES; i++)
	{
		float t = (float)i / (float)(LEG_SAMPLES - 1);
		positions[LEFT_FIRST + i] = { -LEG_X, -t, 0 };
		positions[RIGHT_FIRST + i] = { LEG_X, -t, 0 };
	}

	for (usz i = 0; i < body; i++)
	{
		positions[BODY_FIRST + i] = { 0, (float)(i + 1) * 0.25f, 0 };
	}

	return positions;
}

<*
 The stick figure, its rest positions and the binding between them.

 Every check below starts from one of these rather than from the one above it,
 so a binder change moves them together and a pose change moves them apart.
*>
struct Biped
{
	rig::Skeleton skeleton;
	Vec3[] rest;
	gltf::SkinBinding binding;
}

<*
 Build the stick figure and bind it.

 Allocates from `mem`; the caller frees it with `Biped.free`.
*>
fn Biped biped()
{
	rig::Skeleton skeleton = biped_skeleton(mem);
	Vec3[] rest = biped_positions(mem);
	return { skeleton, rest, rig::bind_skin(mem, rest, &skeleton)!! };
}

fn void Biped.free(&self)
{
	self.binding.free(mem);
	alloc::free(mem, self.rest);
	self.skeleton.free(mem);
}

// Largest distance any vertex in `range` travelled between the two arrays.
fn float max_travel(Vec3[] rest, Vec3[] posed, usz first, usz count)
{
	float worst = 0.0f;
	for (usz i = first; i < first + count; i++)
	{
		float moved = (posed[i] - rest[i]).length();
		if (moved > worst) worst = moved;
	}
	return worst;
}

// The index of the first vertex that is NaN or infinite, or -1 if none is.
fn sz first_broken(Vec3[] points)
{
	foreach (index, point : points)
	{
		if (!math::is_finite(point.x) || !math::is_finite(point.y) || !math::is_finite(point.z))
		{
			return (sz)index;
		}
	}
	return -1;
}

fn bool is_identity(Matrix4f value, float epsilon)
{
	Matrix4f identity = matrix::IDENTITY4;
	for (usz i = 0; i < 16; i++)
	{
		if (math::abs(value.m[i] - identity.m[i]) > epsilon) return false;
	}
	return true;
}

<*
 Skin `positions` with `pose` and hand back the result, along with the binding
 so a caller can look at the weights that produced it.
*>
fn Vec3[] posed_positions(
	Allocator allocator,
	Vec3[] positions,
	rig::Skeleton* skeleton,
	rig::Pose pose,
	gltf::SkinBinding binding)
{
	Matrix4f[] palette = rig::joint_palette(allocator, skeleton, pose)!!;
	defer alloc::free(allocator, palette);

	Vec3[] out = alloc::new_array(allocator, Vec3, (sz)positions.len);
	rig::skin_positions(out, positions, binding, palette)!!;
	return out;
}

<*
 A vertex's influences are a share of it, so they add to the whole of it.

 Weights that sum to anything else scale the vertex by that sum the moment
 anything moves — the mesh inflates or collapses rather than bending.
*>
fn void every_influence_sums_to_one() @test
{
	Biped fixture = biped();
	defer fixture.free();

	for (usz v = 0; v < fixture.binding.vertices; v++)
	{
		float sum = 0.0f;
		for (usz s = 0; s < (usz)fixture.binding.slots; s++)
		{
			sum += fixture.binding.weights[v * fixture.binding.slots + s];
		}
		test::@check(math::abs(sum - 1.0f) <= 1.0e-3f, "vertex %d's influences sum to %.6f", v, sum);
	}
}

<*
 The rest pose's palette is the identity at every joint.

 The cheapest possible statement that the pose frames and the bind frames agree:
 if they did not, a rig would deform the moment it was loaded.
*>
fn void the_rest_palette_is_the_identity() @test
{
	Biped fixture = biped();
	defer fixture.free();

	rig::Pose rest_pose = rig::rest_pose(mem, fixture.skeleton.len());
	defer rest_pose.free(mem);

	Matrix4f[] palette = rig::joint_palette(mem, &fixture.skeleton, rest_pose)!!;
	defer alloc::free(mem, palette);

	foreach (joint, entry : palette)
	{
		test::@check(is_identity(entry, REST_EPSILON), "joint %d's rest transform is not the identity", joint);
	}
}

// And the same claim from the other side: whatever the palette holds, the
// vertices have to come out where they were modelled.
fn void the_rest_pose_leaves_every_vertex_alone() @test
{
	Biped fixture = biped();
	defer fixture.free();

	rig::Pose rest_pose = rig::rest_pose(mem, fixture.skeleton.len());
	defer rest_pose.free(mem);

	Vec3[] unmoved = posed_positions(mem, fixture.rest, &fixture.skeleton, rest_pose, fixture.binding);
	defer alloc::free(mem, unmoved);

	float travelled = max_travel(fixture.rest, unmoved, 0, fixture.rest.len);
	test::@check(travelled < REST_EPSILON, "the rest pose moved a vertex by %.7f", travelled);
}

<*
 Turning the root rotates the whole mesh rigidly about it.

 Every joint hangs off the root, so all of them inherit the same rotation and
 the palette collapses to one transform. That makes this check blind to the
 binder: it fails only if the frames themselves are wrong, which is what makes
 it the first one to read when something looks bent.
*>
fn void turning_the_root_is_a_rigid_motion() @test
{
	Biped fixture = biped();
	defer fixture.free();

	rig::Pose root_turn = rig::rest_pose(mem, fixture.skeleton.len());
	defer root_turn.free(mem);
	root_turn.turn(0, { 0, 0, 1 }, (float)math::PI * 0.5f);

	Vec3[] swung = posed_positions(mem, fixture.rest, &fixture.skeleton, root_turn, fixture.binding);
	defer alloc::free(mem, swung);

	for (usz i = 0; i < fixture.rest.len; i++)
	{
		// A quarter turn about +Z through the origin, which is where the root is.
		Vec3 expected = { -fixture.rest[i].y, fixture.rest[i].x, fixture.rest[i].z };
		float off = (swung[i] - expected).length();
		test::@check(off <= 1.0e-4f, "vertex %d landed %.5f from where a rigid quarter turn puts it", i, off);
	}
}

<*
 Sliding the root carries every vertex by exactly that offset.

 The translation half of a pose, asked the same way as the rotation half:
 everything hangs off the root, so every vertex has to arrive at exactly the
 offset and nothing may stretch. A pose that folded the offset in at the wrong
 end of the composition would move the mesh by some rotated version of it
 instead, which no amount of eyeballing a preview reliably catches.
*>
fn void sliding_the_root_is_a_rigid_motion() @test
{
	Biped fixture = biped();
	defer fixture.free();

	Vec3 slide = { 0.3f, -0.2f, 0.1f };
	rig::Pose root_slide = rig::rest_pose(mem, fixture.skeleton.len());
	defer root_slide.free(mem);
	root_slide.move(0, slide);

	Vec3[] slid = posed_positions(mem, fixture.rest, &fixture.skeleton, root_slide, fixture.binding);
	defer alloc::free(mem, slid);

	for (usz i = 0; i < fixture.rest.len; i++)
	{
		float off = (slid[i] - (fixture.rest[i] + slide)).length();
		test::@check(off <= 1.0e-4f, "vertex %d landed %.5f from the offset it was slid by", i, off);
	}
}

<*
 Sliding a hip takes the leg under it along, and mostly leaves the other alone.

 The same claim the hip rotation makes, which is what says the offset is
 composed into the chain rather than applied to the palette afterwards.
*>
fn void sliding_a_hip_carries_only_its_own_leg() @test
{
	Biped fixture = biped();
	defer fixture.free();

	rig::Pose hip_slide = rig::rest_pose(mem, fixture.skeleton.len());
	defer hip_slide.free(mem);
	hip_slide.move(HIP_L, { 0, -0.5f, 0 });

	Vec3[] dropped = posed_positions(mem, fixture.rest, &fixture.skeleton, hip_slide, fixture.binding);
	defer alloc::free(mem, dropped);

	sz broken = first_broken(dropped);
	test::@check(broken < 0, "vertex %d slid to NaN or infinity", broken);

	float moved = max_travel(fixture.rest, dropped, LEFT_FIRST, LEG_SAMPLES);
	float still = max_travel(fixture.rest, dropped, RIGHT_FIRST, LEG_SAMPLES);
	test::@check(moved > 0.25f, "the leg under the slid hip travelled only %.4f", moved);
	test::@check(still < moved * 0.25f, "the other leg travelled %.4f against the slid leg's %.4f", still, moved);
}

<*
 Turning a hip swings the leg under it, and the foot arrives by inheritance.

 The foot is a child of the hip and carries no rotation of its own, so where it
 lands is a claim about composition down the chain. The tip sits on the foot
 joint with essentially all its weight there, so the landing point is
 predictable rather than merely plausible: a pivot at the hip sends it to +X.
*>
fn void turning_a_hip_swings_its_leg_from_the_hip() @test
{
	Biped fixture = biped();
	defer fixture.free();

	rig::Pose hip_turn = rig::rest_pose(mem, fixture.skeleton.len());
	defer hip_turn.free(mem);
	hip_turn.turn(HIP_L, { 0, 0, 1 }, (float)math::PI * 0.5f);

	Vec3[] posed = posed_positions(mem, fixture.rest, &fixture.skeleton, hip_turn, fixture.binding);
	defer alloc::free(mem, posed);

	sz broken = first_broken(posed);
	test::@check(broken < 0, "posed vertex %d is NaN or infinite", broken);

	float swung = max_travel(fixture.rest, posed, LEFT_FIRST, LEG_SAMPLES);
	test::@check(swung > 0.5f, "turning a hip swung its leg only %.4f", swung);

	Vec3 tip = posed[LEFT_FIRST + LEFT_TIP];
	Vec3 expected = { -LEG_X + 1.0f, 0, 0 };
	test::@check((tip - expected).length() < 0.02f,
		"the foot tip landed at (%.4f, %.4f, %.4f), not (%.4f, %.4f, %.4f)",
		tip.x, tip.y, tip.z, expected.x, expected.y, expected.z);
}

<*
 The leg that was not posed mostly stays put — the bleed, as a number.

 The other leg is not attached to the joint that moved, so ideally it does not
 move at all. It does, a little, because `bind_geometric` measures straight-line
 distance and the gap between two limbs is short. This is PLAN.md §3's bleed,
 and the figure a better binder has to beat: the message prints it either way a
 failure is read.
*>
fn void the_still_leg_mostly_stays_put() @test
{
	Biped fixture = biped();
	defer fixture.free();

	rig::Pose hip_turn = rig::rest_pose(mem, fixture.skeleton.len());
	defer hip_turn.free(mem);
	hip_turn.turn(HIP_L, { 0, 0, 1 }, (float)math::PI * 0.5f);

	Vec3[] posed = posed_positions(mem, fixture.rest, &fixture.skeleton, hip_turn, fixture.binding);
	defer alloc::free(mem, posed);

	float swung = max_travel(fixture.rest, posed, LEFT_FIRST, LEG_SAMPLES);
	float bled = max_travel(fixture.rest, posed, RIGHT_FIRST, LEG_SAMPLES);
	test::@check(bled < swung * 0.25f, "the still leg travelled %.4f against the swung leg's %.4f (%.1f%%)",
		bled, swung, swung > 0.0f ? bled / swung * 100.0f : 0.0f);
}

<*
 A chain down the longest axis of `REAL_MESH`, standing in for placed dots.

 Crude, but the pose math does not care how the joints were chosen, and a mesh
 with thousands of vertices exercises the parts a twenty-point fixture cannot.
 The caller frees the mesh, the skeleton and the binding.
*>
fn void? load_real_mesh(rig::TriMesh* mesh, rig::Skeleton* skeleton, gltf::SkinBinding* binding)
{
	*mesh = rig::load_gltf(mem, REAL_MESH)!;

	rig::Bounds bounds = mesh.bounds();
	Vec3 extent = bounds.extent();

	// Longest axis, so the chain runs along the body of whatever was handed in.
	usz axis = 0;
	if (extent.y > extent[axis]) axis = 1;
	if (extent.z > extent[axis]) axis = 2;

	usz count = 4;
	Vec3[] joints = alloc::new_array(mem, Vec3, (sz)count);
	int[] parents = alloc::new_array(mem, int, (sz)count);
	for (usz i = 0; i < count; i++)
	{
		float t = (float)i / (float)(count - 1);
		Vec3 joint = bounds.center();
		joint[axis] = bounds.min[axis] + extent[axis] * t;
		joints[i] = joint;
		parents[i] = i == 0 ? -1 : (int)(i - 1);
	}

	*skeleton = { .joints = joints, .parents = parents };
	*binding = rig::bind_skin(mem, mesh.positions, skeleton)!;
}

// The rest claim again, at a real vertex count: thousands of vertices, each
// with up to four influences, all of which have to cancel exactly.
fn void a_real_mesh_rests_where_it_was_modelled() @test
{
	rig::TriMesh mesh;
	rig::Skeleton skeleton;
	gltf::SkinBinding binding;
	if (catch fault error = load_real_mesh(&mesh, &skeleton, &binding))
	{
		test::@check(false, "could not load %s (%s) — run from the crig directory", REAL_MESH, error);
		return;
	}
	defer { binding.free(mem); skeleton.free(mem); mesh.free(mem); }

	rig::Pose rest_pose = rig::rest_pose(mem, skeleton.len());
	defer rest_pose.free(mem);

	Vec3[] unmoved = posed_positions(mem, mesh.positions, &skeleton, rest_pose, binding);
	defer alloc::free(mem, unmoved);

	float travelled = max_travel(mesh.positions, unmoved, 0, mesh.positions.len);
	test::@check(travelled < REST_EPSILON, "the rest pose moved a real mesh's vertex by %.7f", travelled);
}

// And that bending it does something finite. A binder that divides by a zero
// weight somewhere in a real mesh shows up here and nowhere in the stick figure.
fn void a_real_mesh_bends_without_coming_apart() @test
{
	rig::TriMesh mesh;
	rig::Skeleton skeleton;
	gltf::SkinBinding binding;
	if (catch fault error = load_real_mesh(&mesh, &skeleton, &binding))
	{
		test::@check(false, "could not load %s (%s) — run from the crig directory", REAL_MESH, error);
		return;
	}
	defer { binding.free(mem); skeleton.free(mem); mesh.free(mem); }

	rig::Pose bend = rig::rest_pose(mem, skeleton.len());
	defer bend.free(mem);
	bend.turn(skeleton.len() - 1, { 0, 0, 1 }, (float)math::PI * 0.25f);

	Vec3[] posed = posed_positions(mem, mesh.positions, &skeleton, bend, binding);
	defer alloc::free(mem, posed);

	sz broken = first_broken(posed);
	test::@check(broken < 0, "posed vertex %d of a real mesh is NaN or infinite", broken);

	float travelled = max_travel(mesh.positions, posed, 0, mesh.positions.len);
	test::@check(travelled > 0.0f, "bending the last joint of a real mesh moved nothing");
}

// ---------------------------------------------------------------------------
// What a clip does between its keyframes, and where it puts the feet.
//
// The fixture above is the rig for all of these: a pelvis with a rigid leg down
// each side, so a hip turned by θ puts its foot at `-cos θ` and the arithmetic
// stays checkable by hand. Nothing here binds a mesh — a ground solve is about
// where the joints land, and skinning follows them.

const String[] BIPED_NAMES = { "pelvis", "hip_L", "foot_L", "hip_R", "foot_R" };

// Angles a curve is fitted through. Uneven on purpose: equally spaced values
// hide a tangent that divides by key index instead of by elapsed time.
const float[] SWING = { 0.0f, 0.5f, 0.2f, -0.4f };

<*
 A clip turning one joint about X through `angles`, one key per equal division
 of `duration`, plus the closing key when `closed` asks for one.

 Static-ish: the arrays come from `mem` and `owned` stays false, so
 `AnimTemplate.free` leaves them alone and the caller frees with `free_swing`.
*>
fn AnimTemplate swing_clip(String joint, float[] angles, float duration, bool loop, AnimBlend blend, bool closed)
{
	usz keys = angles.len + (closed ? 1 : 0);
	AnimKeyframe[] frames = alloc::new_array(mem, AnimKeyframe, (sz)keys);

	for (usz k = 0; k < keys; k++)
	{
		AnimKeyDot[] dots = alloc::new_array(mem, AnimKeyDot, 1);
		dots[0] = { .joint_name = joint, .axis = { 1, 0, 0 }, .angle = angles[k % (usz)angles.len] };
		frames[k] = { .time = duration * (float)k / (float)angles.len, .dots = dots };
	}

	return { .name = "Swing", .duration = duration, .keyframes = frames, .loop = loop, .blend = blend };
}

fn void free_swing(AnimTemplate clip)
{
	foreach (frame : clip.keyframes) alloc::free(mem, frame.dots);
	alloc::free(mem, clip.keyframes);
}

// The angle a pose turned a joint through about X, signed.
fn float turned_about_x(rig::Pose pose, usz joint)
{
	Quaternionf turn = pose.rotations[joint];
	return 2.0f * math::atan2(turn.v.x, turn.v.w);
}

// A cubic through its control points has to *hit* them, or every writer that
// samples a clip at its own key times writes something the player never plays.
fn void a_smooth_curve_passes_through_its_keys() @test
{
	rig::Skeleton skeleton = biped_skeleton(mem);
	defer skeleton.free(mem);

	AnimTemplate clip = swing_clip("hip_L", SWING, 1.0f, true, SMOOTH, false);
	defer free_swing(clip);

	foreach (usz k, frame : clip.keyframes)
	{
		rig::Pose pose = clip.pose(mem, &skeleton, BIPED_NAMES, frame.time);
		defer pose.free(mem);

		float landed = turned_about_x(pose, HIP_L);
		test::@check(math::abs(landed - SWING[k]) < 1.0e-4f,
			"key %d asks for %.5f and the curve lands on %.5f", k, SWING[k], landed);
	}
}

<*
 A looping cycle's tangents have to reach across the wrap.

 Measured as the rate of turn either side of the loop point against the rate
 either side of an ordinary key: a curve whose ends are clamped instead of
 wrapped flattens at the seam, so the figure hitches once per cycle. Nothing
 else in the suite catches it — every keyframe is still hit exactly.
*>
fn void a_looping_smooth_cycle_has_no_kink() @test
{
	rig::Skeleton skeleton = biped_skeleton(mem);
	defer skeleton.free(mem);

	AnimTemplate clip = swing_clip("hip_L", SWING, 1.0f, true, SMOOTH, false);
	defer free_swing(clip);

	float step = 1.0e-3f;
	float before = (sampled_swing(clip, &skeleton, 1.0f) - sampled_swing(clip, &skeleton, 1.0f - step)) / step;
	float after = (sampled_swing(clip, &skeleton, step) - sampled_swing(clip, &skeleton, 0.0f)) / step;

	test::@check(math::abs(before - after) < 0.05f,
		"the cycle turns at %.4f rad/s into the loop point and %.4f rad/s out of it", before, after);
}

// The other convention: nine keys where the ninth restates the first at
// `duration`. It closes the same loop, so it must fit the same curve.
fn void a_restated_opening_pose_closes_the_loop() @test
{
	rig::Skeleton skeleton = biped_skeleton(mem);
	defer skeleton.free(mem);

	AnimTemplate open = swing_clip("hip_L", SWING, 1.0f, true, SMOOTH, false);
	AnimTemplate closed = swing_clip("hip_L", SWING, 1.0f, true, SMOOTH, true);
	defer { free_swing(open); free_swing(closed); }

	for (usz i = 0; i <= 20; i++)
	{
		float t = (float)i / 20.0f;
		float a = sampled_swing(open, &skeleton, t);
		float b = sampled_swing(closed, &skeleton, t);
		test::@check(math::abs(a - b) < 1.0e-4f,
			"at %.3f the open cycle turns %.5f and the closed one %.5f", t, a, b);
	}
}

fn float sampled_swing(AnimTemplate clip, rig::Skeleton* skeleton, float t)
{
	rig::Pose pose = clip.pose(mem, skeleton, BIPED_NAMES, t);
	defer pose.free(mem);
	return turned_about_x(pose, HIP_L);
}

// ---------------------------------------------------------------------------
// The ground solve.

<*
 The same two-legged figure with legs of a chosen length.

 The whole point of solving contact rather than authoring it is that the answer
 depends on the rig, so the checks below need two rigs that disagree about how
 far it is to the floor.
*>
fn rig::Skeleton legged_skeleton(Allocator allocator, float leg)
{
	Vec3[] joints = alloc::new_array(allocator, Vec3, 5);
	int[] parents = alloc::new_array(allocator, int, 5);

	joints[0] = { 0, 0, 0 };          parents[0] = -1;
	joints[1] = { -LEG_X, 0, 0 };     parents[1] = 0;
	joints[2] = { -LEG_X, -leg, 0 };  parents[2] = 1;
	joints[3] = { LEG_X, 0, 0 };      parents[3] = 0;
	joints[4] = { LEG_X, -leg, 0 };   parents[4] = 3;

	return { .joints = joints, .parents = parents };
}

// Where a pose put one joint, in world space — a palette entry applied to the
// joint's own rest position, the same arithmetic the solve reads.
fn Vec3 landed_at(rig::Skeleton* skeleton, rig::Pose pose, usz joint)
{
	Matrix4f[] palette = rig::joint_palette(mem, skeleton, pose)!!;
	defer alloc::free(mem, palette);

	Vec3 rest = skeleton.joints[joint];
	float[<4>] moved = palette[joint].apply({ rest.x, rest.y, rest.z, 1.0f });
	return { moved.x, moved.y, moved.z };
}

// A still clip holding each hip at a fixed angle, with a ground spec.
fn AnimTemplate stance_clip(float left, float right, AnimGround ground)
{
	AnimKeyframe[] frames = alloc::new_array(mem, AnimKeyframe, 1);
	AnimKeyDot[] dots = alloc::new_array(mem, AnimKeyDot, 2);
	dots[0] = { .joint_name = "hip_L", .axis = { 1, 0, 0 }, .angle = left };
	dots[1] = { .joint_name = "hip_R", .axis = { 1, 0, 0 }, .angle = right };
	frames[0] = { .time = 0.0f, .dots = dots };

	return { .name = "Stance", .duration = 1.0f, .keyframes = frames, .loop = true, .ground = ground };
}

<*
 The defect this whole mechanism exists for.

 One clip, two rigs whose legs differ by half again, and the stance foot has to
 reach the floor on both. A clip that stated its root height as a keyframe can
 only be right on one of them — which is what a run cycle solved on one mesh and
 replayed on another actually does: its feet sink by several percent of rig
 height, and the deeper the disagreement about leg length the worse it gets.
*>
fn void a_planted_foot_lands_on_the_floor() @test
{
	AnimFoot[] feet = alloc::new_array(mem, AnimFoot, 1);
	feet[0] = { .joint = "foot_L", .down = 0.0f, .up = 1.0f };
	defer alloc::free(mem, feet);

	AnimTemplate clip = stance_clip(0.8f, 0.0f, { .feet = feet });
	defer free_swing(clip);

	float[2] legs = { 1.0f, 1.6f };
	float[2] dropped;

	foreach (usz i, leg : legs)
	{
		rig::Skeleton skeleton = legged_skeleton(mem, leg);
		defer skeleton.free(mem);

		rig::Pose pose = clip.pose(mem, &skeleton, BIPED_NAMES, 0.0f);
		defer pose.free(mem);

		float floor = skeleton.joints[FOOT_L].y;
		float landed = landed_at(&skeleton, pose, FOOT_L).y;
		dropped[i] = pose.offsets[0].y;

		test::@check(math::abs(landed - floor) < 1.0e-5f,
			"on legs of %.1f the planted foot rests at %.5f and the floor is %.5f", leg, landed, floor);
	}

	// And the correction genuinely differed, so the check above is not passing
	// because the solve did nothing on either rig.
	test::@check(math::abs(dropped[0] - dropped[1]) > 1.0e-3f,
		"both rigs dropped the root by %.5f, so nothing rig-specific was solved", dropped[0]);
}

<*
 The second pass: whatever the plant does, no contact joint ends up under the
 floor.

 With the left foot planted at a steep angle the root is pulled down far enough
 to bury the right one, which is a swing foot scything through the ground — the
 failure the raise-only pass exists to stop. It pays for it by leaving the
 planted foot above the floor, which is the trade stated in anim_ground.c3.
*>
fn void nothing_ends_up_below_the_floor() @test
{
	AnimFoot[] feet = alloc::new_array(mem, AnimFoot, 2);
	feet[0] = { .joint = "foot_L", .down = 0.0f, .up = 1.0f };
	feet[1] = { .joint = "foot_R", .down = 0.5f, .up = 0.6f };
	defer alloc::free(mem, feet);

	AnimTemplate clip = stance_clip(0.8f, 0.0f, { .feet = feet });
	defer free_swing(clip);

	rig::Skeleton skeleton = legged_skeleton(mem, 1.0f);
	defer skeleton.free(mem);

	rig::Pose pose = clip.pose(mem, &skeleton, BIPED_NAMES, 0.0f);
	defer pose.free(mem);

	float floor = skeleton.joints[FOOT_L].y;
	foreach (joint : (usz[]){ FOOT_L, 4 })
	{
		float landed = landed_at(&skeleton, pose, joint).y;
		test::@check(landed >= floor - 1.0e-5f,
			"joint %d ended %.5f below the floor", joint, floor - landed);
	}
}

// An authored root slide adds to the solve rather than being overwritten by it,
// which is where a flight arc goes.
fn void an_authored_root_slide_survives_the_solve() @test
{
	AnimFoot[] feet = alloc::new_array(mem, AnimFoot, 1);
	feet[0] = { .joint = "foot_L", .down = 0.0f, .up = 1.0f };
	defer alloc::free(mem, feet);

	AnimKeyframe[] frames = alloc::new_array(mem, AnimKeyframe, 1);
	AnimKeyDot[] dots = alloc::new_array(mem, AnimKeyDot, 2);
	dots[0] = { .joint_name = "hip_L", .axis = { 1, 0, 0 }, .angle = 0.8f };
	dots[1] = { .joint_name = "pelvis", .move = { 0, 0.25f, 0 } };
	frames[0] = { .time = 0.0f, .dots = dots };
	AnimTemplate clip = {
		.name = "Hop", .duration = 1.0f, .keyframes = frames, .loop = true,
		.ground = { .feet = feet },
	};
	defer free_swing(clip);

	rig::Skeleton skeleton = legged_skeleton(mem, 1.0f);
	defer skeleton.free(mem);

	rig::Pose grounded = clip.pose(mem, &skeleton, BIPED_NAMES, 0.0f);
	rig::Pose raw = clip.pose(mem, &skeleton, BIPED_NAMES, 0.0f, grounded: false);
	defer { grounded.free(mem); raw.free(mem); }

	float lift = raw.offsets[0].y;
	test::@check(lift > 0.0f, "the authored slide did not reach the pose at all");
	test::@check(grounded.offsets[0].y < lift,
		"the solve left the root at %.5f, so it replaced the authored slide instead of correcting it",
		grounded.offsets[0].y);

	float floor = skeleton.joints[FOOT_L].y;
	float landed = landed_at(&skeleton, grounded, FOOT_L).y;
	test::@check(math::abs(landed - floor) < 1.0e-5f,
		"with an authored slide the planted foot rests at %.5f and the floor is %.5f", landed, floor);
}

<*
 What a pack file has to carry, and what it must not.

 The keys go out as authored and the settings go out beside them, so the clip
 that comes back smooths and solves for itself. Writing the *solved* result
 instead would bake the authoring rig's leg length into the library — and the
 file would still load, still play, and still be wrong on every other figure,
 which is why this is asserted rather than eyeballed.
*>
fn void a_saved_pack_keeps_its_blend_and_ground() @test
{
	AnimFoot[] feet = alloc::new_array(mem, AnimFoot, 1);
	feet[0] = { .joint = "foot_L", .down = 0.0f, .up = 0.4f };
	defer alloc::free(mem, feet);

	AnimTemplate clip = swing_clip("hip_L", SWING, 1.0f, true, SMOOTH, false);
	clip.name = "Stride";
	clip.ground = { .feet = feet };
	defer free_swing(clip);

	rig::Skeleton source = legged_skeleton(mem, 1.0f);
	defer source.free(mem);

	String path = "build/anim-ground/pack.glb";
	if (catch path::mkdir((Path)"build/anim-ground")) {}
	AnimTemplate[1] written = { clip };
	if (catch fault error = crig::export_pack_glb(mem, path, &source, BIPED_NAMES, written[..], {}, {}))
	{
		test::@check(false, "could not write the pack (%s)", error);
		return;
	}

	AnimPack? read = crig::read_pack(mem, path);
	if (catch read)
	{
		test::@check(false, "could not read the pack back");
		return;
	}
	AnimPack pack = read;
	defer pack.free(mem);

	test::@check(pack.clips.len == 1, "the pack came back with %d clips", pack.clips.len);
	if (pack.clips.len != 1) return;
	AnimTemplate back = pack.clips[0];

	test::@check(back.blend == SMOOTH, "the clip came back linear");
	test::@check(back.ground.feet.len == 1, "the clip came back with %d contact joints", back.ground.feet.len);
	if (back.ground.feet.len != 1) return;
	test::@check(back.ground.feet[0].joint == "foot_L",
		"the contact joint came back as \"%s\"", back.ground.feet[0].joint);
	test::@check(math::abs(back.ground.feet[0].up - 0.4f) < 1.0e-4f,
		"the contact window came back ending at %.4f", back.ground.feet[0].up);

	// The keys are the ones that were authored, not a denser sampling of the
	// curve they describe: a pack that baked them could never be re-solved.
	test::@check(back.keyframes.len == clip.keyframes.len,
		"%d keyframes went out and %d came back", clip.keyframes.len, back.keyframes.len);

	// The closing span too. This clip's last key is at 0.75 of a cycle one second
	// long, and the quarter left is the wrap back to key 0 — a span glTF records
	// nowhere, because a sampler is as long as its last sample. Lose it and the
	// cycle comes back a keyframe short, which retimes every contact window and
	// collapses the wrap tangent onto the last key.
	test::@check(math::abs(back.duration - clip.duration) < 1.0e-4f,
		"a cycle %.4f long came back %.4f long", clip.duration, back.duration);

	// And the whole point of it: the same file, on a rig it was never authored
	// against, still puts the planted foot on that rig's floor.
	rig::Skeleton other = legged_skeleton(mem, 1.6f);
	defer other.free(mem);

	rig::Pose pose = back.pose(mem, &other, pack.joint_names, 0.1f);
	defer pose.free(mem);

	float floor = other.joints[FOOT_L].y;
	float landed = landed_at(&other, pose, FOOT_L).y;
	test::@check(math::abs(landed - floor) < 1.0e-4f,
		"replayed on longer legs the planted foot rests at %.5f and the floor is %.5f", landed, floor);
}

// ---------------------------------------------------------------------------
// Filling in the other side, and measuring the result.

// Not along an axis of the reflection, so a sign rule that flips the wrong two
// components fails rather than coinciding with the right answer.
fn Vec3 tilted() => ((Vec3){ 1, 2, 3 }).normalize();

// A clip driving one side only, which is what an author writes.
fn AnimTemplate one_sided_clip(float duration)
{
	AnimKeyframe[] frames = alloc::new_array(mem, AnimKeyframe, (sz)SWING.len);
	foreach (usz k, angle : SWING)
	{
		AnimKeyDot[] dots = alloc::new_array(mem, AnimKeyDot, 1);
		dots[0] = { .joint_name = "hip_L", .axis = tilted(), .angle = angle, .move = { 0.1f, 0.2f, 0.3f } };
		frames[k] = { .time = duration * (float)k / (float)SWING.len, .dots = dots };
	}
	return { .name = "One", .duration = duration, .keyframes = frames, .loop = true };
}

<*
 An entry's turn as a rotation vector — the axis scaled by the angle.

 Compared instead of the axis and the angle separately, because those are not
 unique: a quaternion converts back as a non-negative angle about whichever
 direction that needs, so the same turn is stored as `+0.4` about `a` or `+0.4`
 about `-a` depending on which side of zero it came from. The rotation vector is
 the same either way, and it is what the sign rules are actually a claim about.
*>
fn Vec3 rotation_vector(AnimKeyDot dot) => dot.axis.normalize() * dot.angle;

// The entry a keyframe holds for a joint, or a zeroed one when it holds none.
fn AnimKeyDot entry_in(AnimKeyframe frame, String joint)
{
	foreach (dot : frame.dots)
	{
		if (dot.joint_name == joint) return dot;
	}
	return {};
}

<*
 The three sign rules, as an assertion.

 An axis keeps the component a displacement flips and flips the two it keeps,
 because an axis is a pseudo-vector. Getting that backwards produces a clip that
 plays, looks nearly right, and has one leg rotating the wrong way — which reads
 as bad animation rather than as a bug.
*>
fn void a_mirrored_clip_reflects_the_side_it_fills() @test
{
	AnimTemplate source = one_sided_clip(1.0f);
	defer free_swing(source);

	AnimTemplate both = crig::mirror_template(mem, source, "Both", 0.0f);
	defer both.free(mem);

	// Key 1, not key 0: at an angle of zero the axis is arbitrary and every sign
	// rule agrees with every other.
	AnimKeyDot filled = entry_in(both.keyframes[1], "hip_R");
	test::@check(filled.joint_name == "hip_R", "the mirror filled in no hip_R at all");

	Vec3 authored = tilted() * SWING[1];
	Vec3 want = { authored.x, -authored.y, -authored.z };
	Vec3 got = rotation_vector(filled);
	test::@check((got - want).length() < 1.0e-4f,
		"the reflected turn came out (%.4f, %.4f, %.4f) against (%.4f, %.4f, %.4f)",
		got.x, got.y, got.z, want.x, want.y, want.z);

	test::@check(math::abs(filled.move.x + 0.1f) < 1.0e-5f
		&& math::abs(filled.move.y - 0.2f) < 1.0e-5f
		&& math::abs(filled.move.z - 0.3f) < 1.0e-5f,
		"the reflected slide came out (%.4f, %.4f, %.4f)", filled.move.x, filled.move.y, filled.move.z);

	// And what the author wrote is left exactly as written.
	AnimKeyDot kept = entry_in(both.keyframes[1], "hip_L");
	test::@check(math::abs(kept.angle - SWING[1]) < 1.0e-6f
		&& math::abs(kept.move.x - 0.1f) < 1.0e-6f,
		"the mirror disturbed the side that was authored");
}

// Half a cycle, on a cycle keyed in quarters, lands on a key — so the filled
// side is the authored one two keys along, not a resampling of it.
fn void a_mirrored_side_lags_by_the_phase_asked_for() @test
{
	AnimTemplate source = one_sided_clip(1.0f);
	defer free_swing(source);

	AnimTemplate both = crig::mirror_template(mem, source, "Both", 0.5f);
	defer both.free(mem);

	foreach (usz k, frame : both.keyframes)
	{
		usz from = (k + SWING.len - SWING.len / 2) % (usz)SWING.len;
		Vec3 authored = tilted() * SWING[from];
		Vec3 want = { authored.x, -authored.y, -authored.z };
		Vec3 got = rotation_vector(entry_in(frame, "hip_R"));
		test::@check((got - want).length() < 1.0e-4f,
			"key %d's mirrored side turns (%.4f, %.4f, %.4f); key %d of the source asks for (%.4f, %.4f, %.4f)",
			k, got.x, got.y, got.z, from, want.x, want.y, want.z);
	}
}

// A gait's contact windows have to be mirrored too, or the solve drops the
// figure onto the one foot the author happened to write.
fn void a_mirrored_clip_plants_both_feet() @test
{
	AnimFoot[] feet = alloc::new_array(mem, AnimFoot, 1);
	feet[0] = { .joint = "foot_L", .down = 0.0f, .up = 0.4f };
	defer alloc::free(mem, feet);

	AnimTemplate source = one_sided_clip(1.0f);
	source.ground = { .feet = feet };
	defer free_swing(source);

	AnimTemplate both = crig::mirror_template(mem, source, "Both", 0.5f);
	defer both.free(mem);

	test::@check(both.ground.feet.len == 2, "the mirrored clip plants %d feet", both.ground.feet.len);
	if (both.ground.feet.len != 2) return;
	test::@check(both.ground.feet[1].joint == "foot_R",
		"the second contact joint came out as \"%s\"", both.ground.feet[1].joint);
	test::@check(math::abs(both.ground.feet[1].down - 0.5f) < 1.0e-5f,
		"the mirrored foot goes down at %.4f rather than half a cycle later", both.ground.feet[1].down);
}

<*
 A pose flipped: sided joints trade places, a centre joint reflects where it
 is, a side the rig lacks is dropped and counted, and the channel masks ride
 along — the contract `keyframe_flipped` states, checked without a rig.
*>
fn void a_flipped_pose_swaps_sides_and_reflects_the_middle() @test
{
	AnimKeyDot[] dots = alloc::new_array(mem, AnimKeyDot, 4);
	dots[0] = { .joint_name = "hip_L".copy(mem), .axis = { 0.6f, 0.8f, 0 }, .angle = 0.5f,
		.move = { 0.1f, 0.2f, 0.3f }, .bone = { 0.3f, -0.9f, 0.1f } };
	dots[1] = { .joint_name = "hip_R".copy(mem), .axis = { 0, 0, 1 }, .angle = 0.25f, .channels = ROTATION };
	dots[2] = { .joint_name = "spine".copy(mem), .axis = { 0, 0, 1 }, .angle = 0.3f, .move = { 0.05f, 0, 0 } };
	dots[3] = { .joint_name = "tail_L".copy(mem), .axis = { 1, 0, 0 }, .angle = 0.1f };
	AnimKeyframe pose = { .time = 0.75f, .dots = dots };
	defer pose.free(mem);

	String[4] rig = { "hip_L", "hip_R", "spine", "head" };
	usz unmatched;
	AnimKeyframe flipped = crig::keyframe_flipped(mem, pose, rig[..], &unmatched);
	defer flipped.free(mem);

	test::@check(flipped.time == 0.75f, "the flip moved the pose to %.2f s", flipped.time);
	test::@check(flipped.dots.len == 3, "%d entries came back; hip_L, hip_R and spine were wanted", flipped.dots.len);
	test::@check(unmatched == 1, "tail_L has no twin on this rig and should be the one dropped, not %d", unmatched);
	test::@check(!flipped.names("tail_L") && !flipped.names("tail_R"), "a twin the rig lacks was invented");

	// hip_R takes hip_L's entry reflected: axis (x, -y, -z), move and bone (-x, y, z).
	AnimKeyDot right = entry_in(flipped, "hip_R");
	test::@check(right.joint_name == "hip_R" && right.channels == BOTH, "hip_L's entry did not land on hip_R whole");
	test::@check((right.axis - (Vec3){ 0.6f, -0.8f, 0 }).length() < 1.0e-6f && right.angle == 0.5f,
		"the turn was not reflected: axis (%.2f, %.2f, %.2f)", right.axis.x, right.axis.y, right.axis.z);
	test::@check((right.move - (Vec3){ -0.1f, 0.2f, 0.3f }).length() < 1.0e-6f, "the slide was not reflected");
	test::@check((right.bone - (Vec3){ -0.3f, -0.9f, 0.1f }).length() < 1.0e-6f, "the bone was not reflected");

	// hip_L takes hip_R's, rotation only — the mask is the entry's, not the twin's.
	AnimKeyDot left = entry_in(flipped, "hip_L");
	test::@check(left.channels == ROTATION && (left.axis - (Vec3){ 0, 0, -1 }).length() < 1.0e-6f
		&& left.angle == 0.25f, "hip_R's rotation-only entry did not swap onto hip_L as written");

	// The spine has no twin, so it is reflected where it stands.
	AnimKeyDot spine = entry_in(flipped, "spine");
	test::@check((spine.axis - (Vec3){ 0, 0, -1 }).length() < 1.0e-6f && spine.move.x == -0.05f,
		"the centre joint was not reflected in place");

	// With no rig to check against, every twin is welcome.
	AnimKeyframe unchecked = crig::keyframe_flipped(mem, pose);
	defer unchecked.free(mem);
	test::@check(unchecked.dots.len == 4 && unchecked.names("tail_R"), "without a rig the dropped twin should come through");

	// And the source is left as it was.
	test::@check(pose.dots[0].joint_name == "hip_L" && pose.dots[0].axis.y == 0.8f, "the flip disturbed its source");
}

<*
 The measurements a screenshot cannot make.

 A foot pinned to the ground for the whole cycle by a clip that never moves it
 has to report no slide and no penetration; the stride is the two feet's own
 separation, which on this fixture is known exactly.
*>
fn void metrics_measure_a_still_stance() @test
{
	AnimFoot[] feet = alloc::new_array(mem, AnimFoot, 2);
	feet[0] = { .joint = "foot_L", .down = 0.0f, .up = 1.0f };
	feet[1] = { .joint = "foot_R", .down = 0.0f, .up = 1.0f };
	defer alloc::free(mem, feet);

	AnimTemplate clip = stance_clip(0.0f, 0.0f, { .feet = feet });
	defer free_swing(clip);

	rig::Skeleton skeleton = legged_skeleton(mem, 1.0f);
	defer skeleton.free(mem);

	ClipMetrics numbers = crig::clip_metrics(mem, &skeleton, BIPED_NAMES, clip, 16);
	defer numbers.free(mem);

	test::@check(numbers.floor_penetration < 1.0e-5f,
		"a still stance reports %.5f of penetration", numbers.floor_penetration);
	test::@check(numbers.foot_slide < 1.0e-5f,
		"a foot that never moves reports %.5f of slide", numbers.foot_slide);
	test::@check(numbers.root_bob < 1.0e-5f,
		"a still stance reports %.5f of bob", numbers.root_bob);

	float want = 2.0f * LEG_X / skeleton.height();
	test::@check(math::abs(numbers.stride - want) < 1.0e-4f,
		"the feet stand %.5f apart and the stride reads %.5f", want, numbers.stride);
}

// And that a foot dragged along the ground while it is meant to be planted
// shows up as slide — the number that separates walking from skating.
fn void metrics_catch_a_sliding_foot() @test
{
	// Both feet, and both down throughout: the solve only keeps the contact joints
	// a clip names out of the floor, while the metric measures every joint — so a
	// spec that mentions one foot of two reports the other one sinking, correctly.
	AnimFoot[] feet = alloc::new_array(mem, AnimFoot, 2);
	feet[0] = { .joint = "foot_L", .down = 0.0f, .up = 1.0f };
	feet[1] = { .joint = "foot_R", .down = 0.0f, .up = 1.0f };
	defer alloc::free(mem, feet);

	AnimTemplate clip = swing_clip("hip_L", SWING, 1.0f, true, SMOOTH, false);
	clip.ground = { .feet = feet };
	defer free_swing(clip);

	rig::Skeleton skeleton = legged_skeleton(mem, 1.0f);
	defer skeleton.free(mem);

	ClipMetrics numbers = crig::clip_metrics(mem, &skeleton, BIPED_NAMES, clip, 32);
	defer numbers.free(mem);

	test::@check(numbers.foot_slide > 0.05f,
		"a hip swinging through %.2f radians with the foot planted reports only %.5f of slide",
		SWING[1] - SWING[3], numbers.foot_slide);
	test::@check(numbers.floor_penetration < 1.0e-4f,
		"the solve left %.5f of penetration", numbers.floor_penetration);
}

// ---------------------------------------------------------------------------
// The chain an IK drag may turn, and the world rotations that convert into it.

<*
 The run above a foot is its own leg and stops at the pelvis.

 The pelvis carries both legs, so turning it to place one foot swings the other.
 That is the whole of the rule, and the stick figure is the smallest rig that
 states it: two joints down each side of one fork.
*>
fn void the_run_above_a_foot_is_its_own_leg() @test
{
	rig::Skeleton skeleton = biped_skeleton(mem);
	defer skeleton.free(mem);

	usz[8] run;
	usz count = skeleton.ancestor_run(FOOT_L, run[..]);

	test::@check(count == 1, "the run above the left foot holds %d joints, expected the hip alone", count);
	test::@check(run[0] == HIP_L, "it starts at joint %d rather than the left hip", run[0]);
}

<*
 A joint whose parent forks, and a root, both come back with nothing.

 Not an oversight and not an error: there is no joint above either that can move
 it without moving its siblings too, and the caller has to answer for that rather
 than be handed a chain that swings half the figure.
*>
fn void a_forked_parent_and_a_root_have_no_run() @test
{
	rig::Skeleton skeleton = biped_skeleton(mem);
	defer skeleton.free(mem);

	usz[8] run;
	test::@check(skeleton.ancestor_run(HIP_L, run[..]) == 0,
		"the hip found a run above it, but the pelvis carries both legs");
	test::@check(skeleton.ancestor_run(0, run[..]) == 0, "the root found a run above it");
}

<*
 `world_rotations` agrees with the rotation the palette carries.

 The two are the same quantity by two routes — quaternion products here, a 4x4
 composition and its rotation block there — and every conversion from a
 world-frame turn into a stored local one divides by this. If they ever
 disagreed, a pose edited from outside would land somewhere other than where the
 mesh went, and only the mesh would be visible.
*>
fn void world_rotations_agree_with_the_palette() @test
{
	rig::Skeleton skeleton = biped_skeleton(mem);
	defer skeleton.free(mem);

	rig::Pose pose = rig::rest_pose(mem, skeleton.len());
	defer pose.free(mem);

	// Two turns down one leg, about different axes, so a hip that composed in the
	// wrong order or dropped its parent shows up.
	pose.turn(HIP_L, { 0, 0, 1 }, 0.7f);
	pose.turn(FOOT_L, { 1, 0, 0 }, -0.4f);

	Quaternionf[] world = pose.world_rotations(mem, &skeleton)!!;
	defer alloc::free(mem, world);

	Matrix4f[] palette = rig::joint_palette(mem, &skeleton, pose)!!;
	defer alloc::free(mem, palette);

	// Compared by what the rotation does to a vector rather than component by
	// component: q and -q are the same rotation, and a check on the four numbers
	// would fail on a sign nothing can see.
	Vec3 probe = ((Vec3){ 0.3f, 0.5f, -0.8f }).normalize();

	for (usz j = 0; j < skeleton.len(); j++)
	{
		Matrix4f turn = world[j].to_matrix();
		Vec3 by_quaternion = { turn.m00 * probe.x + turn.m01 * probe.y + turn.m02 * probe.z,
			turn.m10 * probe.x + turn.m11 * probe.y + turn.m12 * probe.z,
			turn.m20 * probe.x + turn.m21 * probe.y + turn.m22 * probe.z };

		Matrix4f entry = palette[j];
		Vec3 by_palette = { entry.m00 * probe.x + entry.m01 * probe.y + entry.m02 * probe.z,
			entry.m10 * probe.x + entry.m11 * probe.y + entry.m12 * probe.z,
			entry.m20 * probe.x + entry.m21 * probe.y + entry.m22 * probe.z };

		test::@check((by_quaternion - by_palette).length() < 1.0e-5f,
			"joint %d: the quaternion sends the probe to %s and the palette to %s",
			j, by_quaternion, by_palette);
	}
}
