<*
 Held props: a placeholder sword, wand or staff riding a hand.

 A prop is the document's (`HeldProp`): its grip offset and turn are in the hand's
 frame, so it follows whatever pose the hand is in. Nothing here poses the body;
 a two-hand grip is a pin held relative to the prop hand (`AnimPin.relative_to`).
*>
module crig;

import rig;
import std::math;
import std::math::vector;
import std::math::quaternion;
import std::collections::list;

// Default lengths, as fractions of the rig's height.
const float PROP_SWORD_LENGTH = 0.45f;
const float PROP_WAND_LENGTH = 0.18f;
const float PROP_STAFF_LENGTH = 1.0f;
// The shortest and longest a prop may be, as fractions of the rig's height.
const float PROP_MIN_LENGTH = 0.05f;
const float PROP_MAX_LENGTH = 2.0f;
// How far past the wrist a leaf hand's grip sits, as a fraction of the rig's height.
const float PROP_LEAF_GRIP = 0.03f;
// How thin a sword's blade is against its width.
const float PROP_BLADE_FLAT = 0.22f;

fn float PropKind.default_length(self)
{
	switch (self)
	{
		case SWORD: return PROP_SWORD_LENGTH;
		case WAND: return PROP_WAND_LENGTH;
		case STAFF: return PROP_STAFF_LENGTH;
	}
}

// Where a prop is and how it is turned, in model space.
struct PropFrame
{
	Vec3 at;
	Quaternionf turn;
}

<*
 The prop's frame in model space: the hand from `palette`, or the rest pose when
 the palette does not fit the skeleton.

 @param [&in] skeleton : "The rig the palette was built for"
 @require joint < skeleton.len() : "No such joint"
*>
fn PropFrame prop_frame(rig::Skeleton* skeleton, Matrix4f[] palette, usz joint, HeldProp prop)
{
	float height = skeleton.height();
	Vec3 hand = skeleton.joints[joint];
	Quaternionf spun = quaternion::IDENTITY;
	if (palette.len == skeleton.len())
	{
		hand = hand.transform(palette[joint]);
		spun = rig::quat_from_matrix(palette[joint]);
	}
	return { .at = hand + spun.rotate_vec3(prop.offset * height), .turn = spun.mul(prop.turn).normalize() };
}

<*
 Where a new prop of `kind` sits in the hand at `joint`: in the palm, between the
 wrist and its longest child, with its tip toward the way the figure faces, kept
 square to the hand. A hand that already points forward holds it up instead.

 @param [&in] skeleton : "The rig at rest"
 @require joint < skeleton.len() : "No such joint"
*>
fn HeldProp default_prop(rig::Skeleton* skeleton, String[] names, usz joint, uint dot_id, PropKind kind)
{
	HeldProp prop = { .dot_id = dot_id, .kind = kind, .length = kind.default_length(), .turn = quaternion::IDENTITY };
	float height = skeleton.height();
	if (!(height > 0.0f)) return prop;

	Vec3 wrist = skeleton.joints[joint];
	Vec3 palm = wrist;
	Vec3 along = { 0, -1, 0 };
	sz child = longest_child(skeleton, joint);
	int parent = skeleton.parents[joint];
	if (child >= 0 && (skeleton.joints[(usz)child] - wrist).length_sq() > 1.0e-12f)
	{
		Vec3 reach = skeleton.joints[(usz)child] - wrist;
		along = reach.normalize();
		palm = wrist + reach * 0.5f;
	}
	else if (parent >= 0 && (wrist - skeleton.joints[(usz)parent]).length_sq() > 1.0e-12f)
	{
		along = (wrist - skeleton.joints[(usz)parent]).normalize();
		palm = wrist + along * (PROP_LEAF_GRIP * height);
	}
	prop.offset = (palm - wrist) / height;

	Vec3 facing = { 0, 0, 1 };
	if (!rig_facing(skeleton, names, &facing)) facing = { 0, 0, 1 };
	Vec3 tip = facing - along * facing.dot(along);
	if (tip.length_sq() < 0.04f)
	{
		Vec3 up = { 0, 1, 0 };
		tip = up - along * up.dot(along);
		Vec3 across;
		if (tip.length_sq() < 0.04f && child >= 0 && knuckle_line(skeleton, (usz)child, &across)) tip = across;
	}
	if (tip.length_sq() < 1.0e-8f) return prop;
	Vec3 y = tip.normalize();
	// The blade's edges run along the hand, as they do in a closed fist.
	Vec3 x = along - y * along.dot(y);
	if (x.length_sq() < 1.0e-8f) x = math::abs(y.x) < 0.9f ? (Vec3){ 1, 0, 0 } : (Vec3){ 0, 0, 1 };
	x = (x - y * x.dot(y)).normalize();
	prop.turn = rig::quat_from_basis(x, y, x.cross(y));
	return prop;
}

<*
 Which joints are hands: each named arm's wrist (`rig_arms`), and a joint that is
 not a foot or a digit and carries digits or is called hand or wrist. When the
 arms are named, the second kind counts only inside an arm, so a head with ears
 is not a hand.

 @param [&in] skeleton : "The rig at rest"
 @return "One flag per joint, owned by the caller"
*>
fn bool[] rig_arm_wrists(Allocator allocator, rig::Skeleton* skeleton, String[] names)
{
	usz count = skeleton.len();
	bool[] hands = alloc::new_array(allocator, bool, (sz)count);
	if (count == 0) return hands;
	@pool()
	{
		GaitArm[8] found;
		usz arms = rig_arms(skeleton, names, found[..]);
		bool[] digit = skeleton.digits(tmem);
		GroundFloor level = floor_of_solve(skeleton, {}, 0.0f, false);
		usz[] digit_children = alloc::new_array(tmem, usz, (sz)count);
		foreach (usz j, parent : skeleton.parents)
		{
			if (parent >= 0 && (usz)parent < count && digit[j]) digit_children[(usz)parent]++;
		}

		bool[] candidate = alloc::new_array(tmem, bool, (sz)count);
		for (usz j = 0; j < count; j++)
		{
			if (digit[j] || level.rests_low(skeleton, j)) continue;
			String name = j < names.len ? names[j] : "";
			if (digit_children[j] < 2 && !name_has(name, "hand") && !name_has(name, "wrist")) continue;
			if (arms > 0)
			{
				bool in_arm = false;
				foreach (arm : found[:arms]) if (joint_under(skeleton, (usz)arm.shoulder, j)) in_arm = true;
				if (!in_arm) continue;
			}
			candidate[j] = true;
			hands[j] = true;
		}
		// A named arm's wrist, unless a hand was already found at it or below it.
		foreach (arm : found[:arms])
		{
			usz wrist = (usz)arm.wrist;
			bool below = false;
			for (usz j = 0; j < count; j++) if (candidate[j] && joint_under(skeleton, wrist, j)) below = true;
			if (!below) hands[wrist] = true;
		}
	};
	return hands;
}

// One held prop as an export writes its socket: under `joint`, `offset` model
// units from it in its rest frame, turned by `turn`.
struct PropSocket
{
	usz joint;
	Vec3 offset;
	Quaternionf turn;
}

<*
 The document's held props as export sockets, in joint order. A prop on a dot
 the skeleton lacks is left out.

 @param [&in] doc : "The rig"
 @param [&in] skeleton : "Built from the document"
 @param dot_ids : "One per joint, as build_skeleton gives them"
 @return "The sockets, owned by the caller"
*>
fn PropSocket[] prop_sockets(Allocator allocator, RigDocument* doc, rig::Skeleton* skeleton, uint[] dot_ids)
{
	float height = skeleton.height();
	List{PropSocket} out;
	out.init(allocator);
	defer out.free();
	foreach (usz j, id : dot_ids)
	{
		if (j >= skeleton.len()) break;
		HeldProp prop = doc.prop_of(id);
		if (!prop.held()) continue;
		out.push({ .joint = j, .offset = prop.offset * height, .turn = prop.turn.normalize() });
	}
	return out.len() > 0 ? out.to_array(allocator) : (PropSocket[]){};
}

// A prop's mesh: grip at the origin, +Y toward the tip, one colour per vertex.
struct PropShape
{
	rig::TriMesh mesh;
	Vec4[] colours;
}

fn void PropShape.free(&self, Allocator allocator)
{
	self.mesh.free(allocator);
	if (self.colours.len > 0) alloc::free(allocator, self.colours);
	*self = {};
}

const Vec4 PROP_DARK_WOOD = { 0.32f, 0.20f, 0.11f, 1.0f };
const Vec4 PROP_WOOD = { 0.50f, 0.33f, 0.18f, 1.0f };
const Vec4 PROP_PALE_WOOD = { 0.74f, 0.58f, 0.38f, 1.0f };
const Vec4 PROP_TIP = { 0.88f, 0.80f, 0.60f, 1.0f };

<*
 The placeholder mesh for `kind`, `length` model units from end to end.

 @require length > 0.0f : "A prop needs a length"
 @return "The shape, owned by the caller"
*>
fn PropShape prop_shape(Allocator allocator, PropKind kind, float length)
{
	BodyVec3List positions;
	BodyVec3List normals;
	BodyUintList indices;
	List{Vec4} colours;
	positions.init(allocator);
	normals.init(allocator);
	indices.init(allocator);
	colours.init(allocator);
	defer
	{
		positions.free();
		normals.free();
		indices.free();
		colours.free();
	}
	float l = length;
	switch (kind)
	{
		case SWORD:
			add_prism(&positions, &normals, &indices, { 0, -0.1f * l, 0 }, { 0, 0.1f * l, 0 }, 0.018f * l, 0.018f * l, 8);
			prop_paint(&positions, &colours, PROP_DARK_WOOD);
			add_sphere(&positions, &normals, &indices, { 0, -0.12f * l, 0 }, 0.03f * l, 8);
			prop_paint(&positions, &colours, PROP_WOOD);
			add_prism(&positions, &normals, &indices, { -0.11f * l, 0.11f * l, 0 }, { 0.11f * l, 0.11f * l, 0 }, 0.02f * l, 0.02f * l, 4);
			prop_paint(&positions, &colours, PROP_WOOD);
			sz blade = positions.len();
			add_prism(&positions, &normals, &indices, { 0, 0.12f * l, 0 }, { 0, 0.75f * l, 0 }, 0.045f * l, 0.038f * l, 4);
			add_prism(&positions, &normals, &indices, { 0, 0.75f * l, 0 }, { 0, 0.85f * l, 0 }, 0.038f * l, 0.002f * l, 4);
			prop_flatten(&positions, &normals, blade);
			prop_paint(&positions, &colours, PROP_PALE_WOOD);
		case WAND:
			add_prism(&positions, &normals, &indices, { 0, -0.15f * l, 0 }, { 0, 0.15f * l, 0 }, 0.042f * l, 0.04f * l, 8);
			prop_paint(&positions, &colours, PROP_DARK_WOOD);
			add_prism(&positions, &normals, &indices, { 0, 0.15f * l, 0 }, { 0, 0.8f * l, 0 }, 0.032f * l, 0.016f * l, 8);
			prop_paint(&positions, &colours, PROP_WOOD);
			add_sphere(&positions, &normals, &indices, { 0, 0.82f * l, 0 }, 0.03f * l, 8);
			prop_paint(&positions, &colours, PROP_TIP);
		case STAFF:
			add_prism(&positions, &normals, &indices, { 0, -0.35f * l, 0 }, { 0, 0.6f * l, 0 }, 0.016f * l, 0.016f * l, 8);
			prop_paint(&positions, &colours, PROP_WOOD);
			add_sphere(&positions, &normals, &indices, { 0, 0.62f * l, 0 }, 0.04f * l, 8);
			prop_paint(&positions, &colours, PROP_DARK_WOOD);
	}
	return {
		.mesh = {
			.positions = positions.to_array(allocator),
			.normals = normals.to_array(allocator),
			.indices = indices.to_array(allocator),
		},
		.colours = colours.to_array(allocator),
	};
}

// The vertices added since the last paint take `colour`.
fn void prop_paint(BodyVec3List* positions, List{Vec4}* colours, Vec4 colour) @local
{
	while (colours.len() < positions.len()) colours.push(colour);
}

// The vertices from `first` on pressed thin along Z, the way a blade is flat.
fn void prop_flatten(BodyVec3List* positions, BodyVec3List* normals, sz first) @local
{
	for (sz i = first; i < positions.len(); i++)
	{
		Vec3* p = positions.get_ref(i);
		p.z *= PROP_BLADE_FLAT;
		Vec3* n = normals.get_ref(i);
		Vec3 pressed = { n.x, n.y, n.z / PROP_BLADE_FLAT };
		*n = pressed.normalize();
	}
}
