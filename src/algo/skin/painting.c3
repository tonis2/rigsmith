<* The pure half of src/app/painting.c3: no state, undo or notices. *>
module crig;

import rig;
import std::math;
import std::math::vector;
import std::collections::list;

<*
 The brush's radius in screen pixels when it is first opened, and the range a
 scroll can take it through.

 The default is twice `PICK_RADIUS`, which is the size of a dot's hit circle —
 so the first stroke covers visibly more than a click would, which is what tells
 a user this is a brush and not a picker. The floor is a few pixels, below which
 a stroke lands on nothing and reads as a broken mode; the ceiling is a quarter
 of a window, past which the brush is a fill and the falloff view cannot show
 what changed.
*>
const float BRUSH_RADIUS_DEFAULT = 24.0;

const float BRUSH_RADIUS_MIN = 4.0;

const float BRUSH_RADIUS_MAX = 220.0;

// How much one scroll notch changes the radius, as a fraction of it. Relative
// rather than absolute so the small end is adjustable in single pixels while the
// large end still moves in one gesture.
const float BRUSH_RADIUS_STEP = 0.12;

<*
 The most one stroke can carry a vertex — the strip's Strength slider, as a
 fraction of the way to the target.

 **Full by default.** A drag at 1 puts the joint on, or takes it off, everywhere
 the core of the circle passes, which is what a hand sliding over a part
 expects; a lower setting is for blending, where a stroke carries only that much
 and the values in between are reached a pass at a time.

 **Not a flow rate.** A flow makes the result depend on how long the pointer
 lingered, so the same gesture twice gives two answers. This is spent once per
 stroke however slowly it is drawn — dwelling buys nothing — and it is *lifting
 the button and going again* that carries further. At a third, a centred pass
 lands on about a third, two on three fifths, and four on four fifths.
*>
const float BRUSH_STRENGTH_DEFAULT = 1.0;

const float BRUSH_STRENGTH_MIN = 0.05;

const float BRUSH_STRENGTH_MAX = 1.0;

<*
 How much of the radius paints at the full strength. The rest fades to nothing
 at the ring, so the circle on screen is what a stroke paints and its edge still
 leaves no step.
*>
const float BRUSH_CORE = 0.5;

<*
 How hard the brush hits at a point in its circle, 1 inside `BRUSH_CORE` and
 fading to 0 at the ring along `(1 - u²)²` — the curve `reach_bias` uses, smooth
 at both ends so a stroke leaves no visible step where the core or the circle
 stopped.

 @param closeness : `1 - d²/r²: 1 at the centre, 0 at the ring.`
*>
fn float brush_falloff(float closeness)
{
	float t = math::sqrt(math::clamp(1.0f - closeness, 0.0f, 1.0f));
	if (t <= BRUSH_CORE) return 1.0f;
	float u = (t - BRUSH_CORE) / (1.0f - BRUSH_CORE);
	float fade = 1.0f - u * u;
	return fade * fade;
}

<*
 What a share request did, counted by what it could not do.

 A brush can ignore this; an agent cannot. "340 vertices asked for, 12 of them
 off the limb" is the difference between an edit that worked and one that looked
 like it did — and the two refusals below are not user error, they are the rig
 saying something about itself.
*>
struct PaintResult
{
	usz changed;   // vertices whose weight actually moved
	usz blocked;   // off the joint's limb, where it held nothing: not given any of it
	usz emptied;   // left holding nothing: the joint was taken off and no other holds them
}

<*
 One place the brush lands: a vertex inside the circle, or a face's point
 nearest the centre. `shares` is how much of the pull each corner takes; a
 vertex is its own only corner.
*>
struct BrushTouch @private
{
	Vec3 point;
	float closeness; // 1 - d²/r² on screen: 1 at the centre, 0 at the ring
	uint[3] corners;
	float[3] shares;
}

<*
 The point of a screen triangle nearest `at`, and its barycentric weights: `at`
 itself when inside, otherwise the nearest point of the nearest edge. A triangle
 seen edge-on has no inside and is only its edges.
*>
fn Vec2 nearest_on_triangle(Vec2 at, Vec2[3] corner, float[3]* weight) @private
{
	Vec2 ab = corner[1] - corner[0];
	Vec2 ac = corner[2] - corner[0];
	float area = ab.x * ac.y - ab.y * ac.x;
	if (math::abs(area) > 1.0e-6f)
	{
		Vec2 b = corner[1] - at;
		Vec2 c = corner[2] - at;
		Vec2 a = corner[0] - at;
		float wa = (b.x * c.y - b.y * c.x) / area;
		float wb = (c.x * a.y - c.y * a.x) / area;
		float wc = 1.0f - wa - wb;
		if (wa >= 0.0f && wb >= 0.0f && wc >= 0.0f)
		{
			*weight = { wa, wb, wc };
			return at;
		}
	}

	Vec2 nearest = corner[0];
	float best = float::max;
	for (usz e = 0; e < 3; e++)
	{
		usz f = (e + 1) % 3;
		Vec2 edge = corner[f] - corner[e];
		Vec2 out = at - corner[e];
		float length = edge.x * edge.x + edge.y * edge.y;
		float t = length > 0.0f ? math::clamp((out.x * edge.x + out.y * edge.y) / length, 0.0f, 1.0f) : 0.0f;
		Vec2 on = corner[e] + edge * t;
		Vec2 gap = on - at;
		float span = gap.x * gap.x + gap.y * gap.y;
		if (span >= best) continue;
		best = span;
		nearest = on;
		*weight = { 0.0f, 0.0f, 0.0f };
		(*weight)[e] = 1.0f - t;
		(*weight)[f] = t;
	}
	return nearest;
}

<*
 A row's strongest joints, strongest first, as dot ids: those holding anything
 and at least `floor`, as many as `dots` has room for. Takes them out of `row`
 as it goes.

 @param shares : `Filled alongside; at least as long as dots.`
 @return `How many were written.`
*>
fn usz strongest_shares(float[] row, uint[] dot_ids, uint[] dots, float[] shares, float floor = AREA_LEAK_FLOOR)
{
	usz kept = 0;
	while (kept < dots.len)
	{
		sz strongest = -1;
		foreach (b, share : row)
		{
			if (share <= 0.0f || share < floor) continue;
			if (strongest < 0 || share > row[(usz)strongest]) strongest = (sz)b;
		}
		if (strongest < 0) break;
		dots[kept] = dot_ids[(usz)strongest];
		shares[kept] = row[(usz)strongest];
		row[(usz)strongest] = 0.0f;
		kept++;
	}
	return kept;
}

<*
 One row as shares of its vertex: `row` filled with `weights / sum(weights)`,
 or zeros for a row that holds nothing.
*>
fn void share_row(float[] weights, float[] row)
{
	float sum = 0.0f;
	foreach (weight : weights) sum += weight;
	foreach (b, weight : weights) row[b] = sum > 0.0f ? weight / sum : 0.0f;
}

// How far past the circle's own radius, in the model, a vertex may sit from the
// point under the cursor and still be the surface being painted.
const float BRUSH_DEPTH_SLACK = 1.25f;

<*
 Which vertices a correction should touch, said the way the survey says it.

 `owner` and the two bounds are the fields of a `BlendShare` row turned around:
 the survey reports "`knee` reaches 340 vertices owned by `hip`, mean 0.31, peak
 0.62", and this is that sentence with a target on the end. A caller reading the
 survey therefore already has the vocabulary to act on it, which is the whole
 reason the selector is shaped like the diagnosis rather than like a brush.

 Both bounds are on the *painted* share as it stands now, so a request narrows
 what is already there rather than what the binder alone would have said.
*>
struct PaintPick
{
	uint owner;     // the dot that must hold these vertices most; 0 for any
	float at_least; // the painted dot's current share, inclusive
	float at_most;
}

<*
 The joints whose part of the body `joint` may be painted onto: itself, its
 parent, the parent's other children, and everything below it — and for a digit
 (`Skeleton.digits`) the whole hand: the joint the fingers hang from and every
 digit under it.

 	`bool[] family = limb_family(mem, &view.skeleton, joint);`

 A vertex is on the joint's limb when these hold at least `LIMB_FLOOR` of its
 automatic row (`on_limb`). A finger's limb is its hand, a shin's its leg; the
 hips' is the whole body below them, which is what keeps a skirt the thighs hold
 paintable onto the hips. Everything below the joint, not only its children, so
 a With children part — a finger from its knuckle out, a whole arm — is the
 joint's limb by construction. The whole hand for a digit because a finger's
 parts are cut by the knuckle planes, not by the weights: a file can give a
 vertex the bands put on this finger wholly to the next finger's middle joint.

 The limit is on giving weight to a vertex the joint does not hold: taking a
 joint off is allowed anywhere, which is how a stroke that landed on the wrong
 limb is undone, and a vertex it already holds — a head piece's rim an earlier
 Apply gave the head — can be given more. It stops a stroke over a pose from
 painting the boot a hand hangs beside, and a part grown from the wrong place
 from handing it over on Apply. Not limited: a Whole piece or UV islands part,
 named from the menu (`area_names_pieces`), and Lasso pin — drawing around
 vertices is how any of them, a prop held at arm's length, is handed to a joint
 on purpose.

 The caller owns the result, one flag per joint.
*>
fn bool[] limb_family(Allocator allocator, rig::Skeleton* skeleton, usz joint)
{
	usz n = skeleton.len();
	bool[] family = alloc::new_array(allocator, bool, (sz)n);
	if (joint >= n) return family;
	int parent = skeleton.parents[joint];
	for (usz j = 0; j < n; j++)
	{
		if (j == joint || (parent >= 0 && ((int)j == parent || skeleton.parents[j] == parent)))
		{
			family[j] = true;
			continue;
		}
		for (int up = skeleton.parents[j]; up >= 0; up = skeleton.parents[(usz)up])
		{
			if (up != (int)joint) continue;
			family[j] = true;
			break;
		}
	}

	bool[] digit = skeleton.digits(mem);
	defer alloc::free(mem, digit);
	if (!digit[joint]) return family;
	usz fork = joint;
	while (digit[fork] && skeleton.parents[fork] >= 0) fork = (usz)skeleton.parents[fork];
	family[fork] = true;
	for (usz j = 0; j < n; j++)
	{
		if (!digit[j]) continue;
		for (int up = skeleton.parents[j]; up >= 0; up = skeleton.parents[(usz)up])
		{
			if (up != (int)fork) continue;
			family[j] = true;
			break;
		}
	}
	return family;
}

<*
 Whether an automatic row is on the limb `family` names: the family holds at
 least `LIMB_FLOOR` of it. A row with no weight at all is on every limb, since
 nothing there says whose it is.
*>
fn bool on_limb(float[] automatic, bool[] family)
{
	float sum = 0.0f;
	float held = 0.0f;
	foreach (b, weight : automatic)
	{
		sum += weight;
		if (b < family.len && family[b]) held += weight;
	}
	return sum <= 0.0f || held >= LIMB_FLOOR * sum;
}

// The colour of mesh the selected joint cannot be painted onto: darker than the
// falloff ramp's grey, so "none of this joint's" and "off its limb" read apart.
const Vec3 LIMB_OFF_GREY = { 0.12, 0.12, 0.13 };

fn uint off_limb_tint() => rgb(LIMB_OFF_GREY.x, LIMB_OFF_GREY.y, LIMB_OFF_GREY.z);
