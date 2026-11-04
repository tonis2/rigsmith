<*
 A body built around a skeleton, for a pack to be looked at with.

 	`rig::TriMesh body = crig::dummy_body(mem, &skeleton, radii[..]);`
 	`defer body.free(mem);`

 Not a modelled character, and not trying to be. What the template view has to
 show is which lump of the body each bone is carrying, so that a user can see
 where the dots are meant to sit before placing their own. A limb thick enough
 to read at pane size is the whole requirement.

 A tapered prism per bone, a small octahedron at each leaf, and — where the
 caller asks for one — a sphere at the joint, all welded into one soup. The parts
 overlap and nothing unions them: the binder works per vertex and the mesh pass
 does not cull, so interior faces cost a few triangles and change nothing about
 what is drawn or how it is weighted.

 The spheres are what separate a diagram from a figure. Three of the packs here
 are looked at to see which lump of the body a bone carries and want none; the
 humanoid is looked at as a body, and without them every joint shows the pinch
 where two tubes meet.

 Written for the offline pack builder and moved in when `build_body` and
 `save_pack`'s body argument arrived: a pack that carries no body cannot serve as
 a body plan, and making that reachable over the wire is what took the last
 reason to run `make-anims` away. `tools/make_anims.c3` still calls it, from here.
*>
module crig;

import rig;
import std::math;
import std::math::vector;
import std::collections::list;



alias BodyVec3List = List{Vec3};
alias BodyUintList = List{uint};

// Below this a bone has no direction to build a prism along, and the ring would
// come out as a disc of coincident points.
const float BODY_MIN_BONE = 1.0e-5f;

<*
 Build a body around `skeleton`.

 Normals are emitted rather than left to be computed, so the mesh arrives with
 `has_normals()` true and the render pass does not have to smooth it — a smoothed
 normal across the seam where two prisms meet would round off the one edge that
 says a joint is there.

 The caller owns the mesh.

 @param radii : `One radius per joint, as a fraction of the rig's height. Short arrays repeat their last entry.`
 @param sides : `Faces around each bone. Eight reads as round at pane size and costs nothing.`
 @param balls : `A sphere at the joint itself, as a fraction of height; zero, or a short array, gets none. What hides the seam where two bones meet at an angle.`
 @param ball_back : `How far from the joint back towards its parent each ball sits, 0 at the joint and 1 at the parent. For the one case where the mass a bone carries is not centred on either end of it — a skull, which hangs between the jaw and the crown.`
 @require sides >= 3 : `A prism needs three sides to enclose anything.`
*>
fn rig::TriMesh dummy_body(
	Allocator allocator,
	rig::Skeleton* skeleton,
	float[] radii,
	usz sides = 8,
	float[] balls = {},
	float[] ball_back = {})
{
	BodyVec3List positions;
	BodyVec3List normals;
	BodyUintList indices;
	positions.init(allocator);
	normals.init(allocator);
	indices.init(allocator);

	float height = skeleton.height();
	if (height <= 0.0f) height = 1.0f;

	usz joints = skeleton.len();
	for (usz j = 0; j < joints; j++)
	{
		float radius = radius_of(radii, j) * height;

		int parent = skeleton.parents[j];
		if (parent >= 0 && (usz)parent < joints)
		{
			add_prism(
				&positions, &normals, &indices,
				skeleton.joints[(usz)parent], skeleton.joints[j],
				radius_of(radii, (usz)parent) * height, radius,
				sides
			);
		}

		// A leaf is where a chain stops, and a bone that simply ends there reads
		// as an amputation — a head is a leaf, and so is every wrist and ankle.
		if (is_leaf(skeleton, j)) add_octahedron(&positions, &normals, &indices, skeleton.joints[j], radius);

		// The ball, if this joint was given one. Placed after the bone rather than
		// instead of it: the two overlap, nothing unions them, and the interior
		// faces cost a few triangles and change nothing about what is drawn.
		if (j < balls.len && balls[j] > 0.0f)
		{
			Vec3 middle = skeleton.joints[j];
			float back = j < ball_back.len ? ball_back[j] : 0.0f;
			if (back > 0.0f && parent >= 0 && (usz)parent < joints)
			{
				middle = middle + (skeleton.joints[(usz)parent] - middle) * back;
			}
			add_sphere(&positions, &normals, &indices, middle, balls[j] * height, sides);
		}
	}

	rig::TriMesh mesh = {
		.positions = positions.to_array(allocator),
		.normals = normals.to_array(allocator),
		.indices = indices.to_array(allocator),
	};
	positions.free();
	normals.free();
	indices.free();
	return mesh;
}

// The last entry stands in for everything past the end, so a table can say
// "thick down to here, thin after" without listing every joint.
fn float radius_of(float[] radii, usz joint) @local
{
	if (radii.len == 0) return 0.04f;
	return joint < radii.len ? radii[joint] : radii[radii.len - 1];
}

fn bool is_leaf(rig::Skeleton* skeleton, usz joint) @local
{
	usz joints = skeleton.len();
	for (usz j = 0; j < joints; j++)
	{
		if (skeleton.parents[j] == (int)joint) return false;
	}
	return true;
}

// A closed tapered prism from `a` to `b`: a ring at each end, quads between
// them, and a fan closing each ring. Closed rather than a bare tube because an
// open end reads as a hole in the body from any angle that can see into it.
fn void add_prism(
	BodyVec3List* positions,
	BodyVec3List* normals,
	BodyUintList* indices,
	Vec3 a,
	Vec3 b,
	float ra,
	float rb,
	usz sides) @local
{
	Vec3 along = b - a;
	float length = along.length();
	if (length < BODY_MIN_BONE) return;
	Vec3 axis = along / length;

	// Any vector not parallel to the bone will do; the ring's rotation about it
	// is arbitrary and invisible.
	Vec3 aside = math::abs(axis.y) < 0.9f ? (Vec3){ 0, 1, 0 } : (Vec3){ 1, 0, 0 };
	Vec3 u = aside.cross(axis).normalize();
	Vec3 v = axis.cross(u);

	uint base = (uint)positions.len();
	for (usz i = 0; i < sides; i++)
	{
		float angle = (float)math::TAU * (float)i / (float)sides;
		Vec3 out = u * math::cos(angle) + v * math::sin(angle);

		positions.push(a + out * ra);
		normals.push(out);
		positions.push(b + out * rb);
		normals.push(out);
	}

	for (usz i = 0; i < sides; i++)
	{
		uint here = base + (uint)(i * 2);
		uint next = base + (uint)(((i + 1) % sides) * 2);

		indices.push(here);
		indices.push(next);
		indices.push(here + 1);

		indices.push(next);
		indices.push(next + 1);
		indices.push(here + 1);
	}

	add_cap(positions, normals, indices, a, u, v, ra, -axis, sides);
	add_cap(positions, normals, indices, b, u, v, rb, axis, sides);
}

// A fan closing one end of a prism. Its own vertices rather than the ring's,
// because the cap faces along the bone and the ring faces away from it.
fn void add_cap(
	BodyVec3List* positions,
	BodyVec3List* normals,
	BodyUintList* indices,
	Vec3 center,
	Vec3 u,
	Vec3 v,
	float radius,
	Vec3 facing,
	usz sides) @local
{
	uint middle = (uint)positions.len();
	positions.push(center);
	normals.push(facing);

	for (usz i = 0; i < sides; i++)
	{
		float angle = (float)math::TAU * (float)i / (float)sides;
		positions.push(center + (u * math::cos(angle) + v * math::sin(angle)) * radius);
		normals.push(facing);
	}

	for (usz i = 0; i < sides; i++)
	{
		indices.push(middle);
		indices.push(middle + 1 + (uint)i);
		indices.push(middle + 1 + (uint)((i + 1) % sides));
	}
}

// A sphere at a joint, as rings of latitude joined by quads and closed with a
// fan at each pole.
//
// `sides` is read as the count around the equator and half of it as the count
// from pole to pole, so one number keeps the quads roughly square and a caller
// that wanted a smoother body gets one everywhere at once.
fn void add_sphere(
	BodyVec3List* positions,
	BodyVec3List* normals,
	BodyUintList* indices,
	Vec3 center,
	float radius,
	usz sides) @local
{
	usz stacks = sides / 2 < 2 ? 2 : sides / 2;

	// The poles are their own vertices rather than a degenerate ring: a ring of
	// coincident points has no normal worth having, and the fan below wants one
	// vertex to turn around anyway.
	uint north = (uint)positions.len();
	positions.push(center + (Vec3){ 0, radius, 0 });
	normals.push({ 0, 1, 0 });

	uint rings = (uint)positions.len();
	for (usz row = 1; row < stacks; row++)
	{
		float polar = (float)math::PI * (float)row / (float)stacks;
		float y = math::cos(polar);
		float ring = math::sin(polar);

		for (usz i = 0; i < sides; i++)
		{
			float angle = (float)math::TAU * (float)i / (float)sides;
			Vec3 out = { ring * math::cos(angle), y, ring * math::sin(angle) };
			positions.push(center + out * radius);
			normals.push(out);
		}
	}

	uint south = (uint)positions.len();
	positions.push(center - (Vec3){ 0, radius, 0 });
	normals.push({ 0, -1, 0 });

	for (usz i = 0; i < sides; i++)
	{
		uint here = rings + (uint)i;
		uint next = rings + (uint)((i + 1) % sides);

		indices.push(north);
		indices.push(next);
		indices.push(here);

		indices.push(south);
		indices.push(here + (uint)((stacks - 2) * sides));
		indices.push(next + (uint)((stacks - 2) * sides));
	}

	for (usz row = 0; row + 2 < stacks; row++)
	{
		uint top = rings + (uint)(row * sides);
		uint bottom = top + (uint)sides;

		for (usz i = 0; i < sides; i++)
		{
			uint step = (uint)((i + 1) % sides);

			indices.push(top + (uint)i);
			indices.push(top + step);
			indices.push(bottom + (uint)i);

			indices.push(top + step);
			indices.push(bottom + step);
			indices.push(bottom + (uint)i);
		}
	}
}

// Eight triangles around a point. Enough to read as a knob at the end of a
// chain, and small enough that a rig's worth of them costs nothing.
fn void add_octahedron(
	BodyVec3List* positions,
	BodyVec3List* normals,
	BodyUintList* indices,
	Vec3 center,
	float radius) @local
{
	Vec3[6] corners = {
		{ radius, 0, 0 }, { -radius, 0, 0 },
		{ 0, radius, 0 }, { 0, -radius, 0 },
		{ 0, 0, radius }, { 0, 0, -radius },
	};

	uint base = (uint)positions.len();
	foreach (corner : corners)
	{
		positions.push(center + corner);
		normals.push(corner.normalize());
	}

	uint[24] faces = {
		0, 2, 4, 2, 1, 4, 1, 3, 4, 3, 0, 4,
		2, 0, 5, 1, 2, 5, 3, 1, 5, 0, 3, 5,
	};
	foreach (index : faces) indices.push(base + index);
}
