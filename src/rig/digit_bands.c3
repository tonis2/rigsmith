<*
 Finger weights by where a vertex sits *along* a finger, not by how near it is to
 each of the finger's bones.

 A finger segment is about as long as the finger is thick, so a distance falloff
 cannot tell one segment from the next: a vertex on top of a knuckle is as near
 the bone beyond it as the bone it sits on, and the palm behind a knuckle is
 nearer that finger's first bone than the wrist's, which runs down the middle of
 the hand. A finer voxel grid does not help either — the gaps between fingers are
 a few millimetres on a figure a metre tall, a thousand times the cells to see.

 So a digit chain (`Skeleton.digits`) is cut by planes instead. Each joint of the
 chain stands at a knuckle, and the plane through it halves the bend there: past
 the plane is the joint's own segment, before it the segment above. The knuckle
 blend sets how far either side of a plane the two joints share a vertex, as a
 share of the shorter segment meeting there — 0 is a hard switch at the joint, 1
 a segment that is all ramp. Everything before the first knuckle is the fork's,
 the wrist's, so the palm moves with the hand and not with the fingers.

     `rig::band_digits(mem, dense, positions, &skeleton, blend: 0.5f);`

 The binder still decides *whether* a vertex is the hand's: a row the digits hold
 almost nothing of is left exactly as it was, and the bands only move the share
 the fork and its digits already held between them (`DigitBands.band_row`). What
 the planes decide is *which joint along the finger* it is.
*>
module rig;

import std::math;
import std::math::vector;

<*
 How much of a row a fork's digits must hold before the bands take it over:
 nothing below the lower bar, all of it above the upper, a smooth step between.

 The lower bar is what keeps the rest of the body bit-for-bit as the binder made
 it — `isolate_chains` leaves every row a leak of every finger, and a row of the
 forearm holding a hundred-thousandth of one must not be touched. The upper is a
 twentieth: a row where the fingers hold that much is a row of the hand.
*>
const float DIGIT_GATE_LOW = 0.005f;
const float DIGIT_GATE_HIGH = 0.05f;

<*
 How much of a row's hand share the chosen finger must already hold before the
 bands may take weight *from* the fork and give it to the finger.

 Giving back is always allowed: the palm behind a knuckle is the fork's whatever
 the binder thought. Taking is not, because the planes run on through anything
 beyond them — a skull past an ear's first knuckle, the skin round a wrist past a
 thumb whose first joint sits on it — and handing those to the digit outright
 would move a head with an ear. Where the binder already gives the finger a real
 share, the planes are trusted; where it gives it almost none, the fork keeps
 what it held.
*>
const float DIGIT_TRUST_LOW = 0.15f;
const float DIGIT_TRUST_HIGH = 0.4f;

// One chain of digits: the fork it hangs from, and where its joints start in the
// per-joint arrays of `DigitBands`. Its polyline has `count + 2` points from
// `points_at`: the fork, the chain's joints, and the leaf's tail.
struct DigitChain
{
	usz fork;
	usz first;
	usz count;
	usz points_at;
}

// A fork with digits, and where its chains start in `DigitBands.chains`.
struct DigitFork
{
	usz joint;
	usz first;
	usz count;
}

<*
 The knuckle planes of every digit chain of a skeleton, built once per bind.

 Per chain joint: the skeleton joint, the plane's normal (the joint's position
 is its point), and `spans`, half the shorter of the two segments meeting there
 — the ramp's half-width at a blend of 1.
*>
struct DigitBands
{
	DigitFork[] forks;
	DigitChain[] chains;
	usz[] joints;
	Vec3[] normals;
	float[] spans;
	Vec3[] points;
	bool[] digit;
}

<*
 The bands for a skeleton's digits, or empty ones when it has none.

 The caller owns the result and frees it with `DigitBands.free`.
*>
fn DigitBands digit_bands(Allocator allocator, Skeleton* skeleton)
{
	usz count = skeleton.joints.len;
	if (count == 0) return {};

	bool[] digit = skeleton.digits(allocator);
	usz chains = 0;
	usz members = 0;
	for (usz j = 0; j < count; j++)
	{
		if (!digit[j]) continue;
		members++;
		if (chain_starts(skeleton, digit, j)) chains++;
	}
	if (chains == 0)
	{
		alloc::free(allocator, digit);
		return {};
	}

	Vec3[] tails = skeleton.tails(allocator);
	defer alloc::free(allocator, tails);

	// The only child of each chain joint, to walk down it.
	usz[] below = alloc::new_array(allocator, usz, (sz)count);
	defer alloc::free(allocator, below);
	foreach (usz j, parent : skeleton.parents)
	{
		if (parent >= 0 && (usz)parent < count) below[(usz)parent] = j;
	}

	usz forks = 0;
	for (usz f = 0; f < count; f++) if (fork_has_chains(skeleton, digit, f)) forks++;

	DigitBands bands = {
		.forks = alloc::new_array(allocator, DigitFork, (sz)forks),
		.chains = alloc::new_array(allocator, DigitChain, (sz)chains),
		.joints = alloc::new_array(allocator, usz, (sz)members),
		.normals = alloc::new_array(allocator, Vec3, (sz)members),
		.spans = alloc::new_array(allocator, float, (sz)members),
		.points = alloc::new_array(allocator, Vec3, (sz)(members + 2 * chains)),
		.digit = digit,
	};

	// Fork by fork, so a fork's chains sit together; chains in joint order.
	usz at_fork = 0;
	usz at_chain = 0;
	usz at_joint = 0;
	usz at_point = 0;
	for (usz f = 0; f < count; f++)
	{
		if (!fork_has_chains(skeleton, digit, f)) continue;
		bands.forks[at_fork++] = { .joint = f, .first = at_chain };
		for (usz start = 0; start < count; start++)
		{
			if (skeleton.parents[start] != (int)f || !chain_starts(skeleton, digit, start)) continue;

			DigitChain chain = { .fork = f, .first = at_joint, .points_at = at_point };
			bands.points[at_point++] = skeleton.joints[f];
			usz walk = start;
			while (true)
			{
				bands.joints[at_joint + chain.count] = walk;
				bands.points[at_point++] = skeleton.joints[walk];
				chain.count++;
				if (!has_digit_child(skeleton, digit, walk)) break;
				walk = below[walk];
			}
			bands.points[at_point++] = tails[walk];
			at_joint += chain.count;

			// The plane at each knuckle halves the bend between the segment
			// arriving and the one leaving; a straight finger's planes are square
			// to it.
			Vec3[] line = bands.points[chain.points_at : chain.count + 2];
			for (usz k = 0; k < chain.count; k++)
			{
				Vec3 arriving = line[k + 1] - line[k];
				Vec3 leaving = line[k + 2] - line[k + 1];
				float in = arriving.length();
				float out = leaving.length();
				Vec3 normal = {};
				if (in > 0.0f) normal += arriving / in;
				if (out > 0.0f) normal += leaving / out;
				float size = normal.length();
				bands.normals[chain.first + k] = size > 0.0f ? normal / size : (Vec3){ 0, 1, 0 };
				bands.spans[chain.first + k] = 0.5f * math::min(in, out);
			}
			bands.chains[at_chain++] = chain;
			bands.forks[at_fork - 1].count++;
		}
	}
	return bands;
}

fn void DigitBands.free(&self, Allocator allocator)
{
	if (self.forks.len > 0) alloc::free(allocator, self.forks);
	if (self.chains.len > 0) alloc::free(allocator, self.chains);
	if (self.joints.len > 0) alloc::free(allocator, self.joints);
	if (self.normals.len > 0) alloc::free(allocator, self.normals);
	if (self.spans.len > 0) alloc::free(allocator, self.spans);
	if (self.points.len > 0) alloc::free(allocator, self.points);
	if (self.digit.len > 0) alloc::free(allocator, self.digit);
	*self = {};
}

// Whether the bands decide `joint`'s weights: a digit, or a fork a chain hangs from.
fn bool DigitBands.shapes(&self, usz joint)
{
	if (joint < self.digit.len && self.digit[joint]) return true;
	foreach (fork : self.forks) if (fork.joint == joint) return true;
	return false;
}

// A digit whose parent is not one: the first joint of a chain, under its fork.
fn bool chain_starts(Skeleton* skeleton, bool[] digit, usz joint) @private
{
	int parent = skeleton.parents[joint];
	return digit[joint] && parent >= 0 && (usz)parent < digit.len && !digit[(usz)parent];
}

fn bool fork_has_chains(Skeleton* skeleton, bool[] digit, usz fork) @private
{
	foreach (usz j, parent : skeleton.parents)
	{
		if (parent == (int)fork && chain_starts(skeleton, digit, j)) return true;
	}
	return false;
}

fn bool has_digit_child(Skeleton* skeleton, bool[] digit, usz joint) @private
{
	foreach (usz j, parent : skeleton.parents)
	{
		if (parent == (int)joint && digit[j]) return true;
	}
	return false;
}

<*
 The chain of `fork` whose line runs nearest `p` — fork to first knuckle, down
 the joints, out to the leaf's tail — as an index into `chains`.

 Straight-line and hard, like `isolate_chains`: a vertex belongs to one finger,
 and the seam between two runs where their lines are equally far.
*>
fn usz DigitBands.nearest_chain(&self, DigitFork fork, Vec3 p)
{
	usz best = fork.first;
	float nearest = FURTHER_THAN_ANY_MESH;
	for (usz c = fork.first; c < fork.first + fork.count; c++)
	{
		DigitChain chain = self.chains[c];
		Vec3[] line = self.points[chain.points_at : chain.count + 2];
		for (usz s = 0; s + 1 < line.len; s++)
		{
			float d2 = segment_distance_sq(p, line[s], line[s + 1]);
			if (d2 >= nearest) continue;
			nearest = d2;
			best = c;
		}
	}
	return best;
}

<*
 How much of `p` each joint along `chain` holds, its fork first: `out[0]` is the
 fork's and `out[1 + k]` the chain's k-th joint's, summing to one.

 Each knuckle's plane steps from the joint above to the joint below — smoothly
 over `blend` of the knuckle's span either side, or outright at a blend of 0 —
 and the steps multiply down the chain, so a vertex past every plane is the
 leaf's and one before the first is the fork's. Neighbouring ramps never meet on
 the finger while `blend` is at most 1, so a knuckle is shared by its two joints
 and no third.

 @param out : `At least the chain's joint count plus one.`
*>
fn void DigitBands.weights(&self, usz chain_index, Vec3 p, float blend, float[] out)
{
	DigitChain chain = self.chains[chain_index];
	Vec3[] line = self.points[chain.points_at : chain.count + 2];
	float past = 1.0f;
	for (usz k = 0; k < chain.count; k++)
	{
		usz slot = chain.first + k;
		float side = (p - line[k + 1]).dot(self.normals[slot]);
		float half = blend * self.spans[slot];
		float step;
		if (half > 0.0f)
		{
			float t = math::clamp((side + half) / (2.0f * half), 0.0f, 1.0f);
			step = t * t * (3.0f - 2.0f * t);
		}
		else
		{
			step = side >= 0.0f ? 1.0f : 0.0f;
		}
		out[k] = past * (1.0f - step);
		past *= step;
	}
	out[chain.count] = past;
}

fn float smooth_between(float low, float high, float x) @private
{
	float t = math::clamp((x - low) / (high - low), 0.0f, 1.0f);
	return t * t * (3.0f - 2.0f * t);
}

<*
 Re-blend one row of a bind along the fingers of every fork whose digits hold a
 share of it. The rest of the row — an elbow's share at the wrist crease — is
 kept as it was.

 For each such fork: the hand's share of the row, the fork's plus all its
 digits', is handed out again by the planes of the finger the vertex is nearest
 (`weights`). Only as much is taken *from* the fork as the binder already trusted
 that finger with (`DIGIT_TRUST_LOW`), and the result is blended in by how much
 of the row the digits hold (`DIGIT_GATE_LOW`). A digit the planes give nothing
 keeps `SIBLING_LEAK` of what it held, as `isolate_chains` leaves another
 finger, so a brush can still paint it back — and in proportion rather than at
 one level, so the leaks keep the binder's order and the cut to the strongest
 four never has a tie to break differently from one pass to the next.

 A row it re-blends comes back as shares summing to one; a row it leaves alone
 is left exactly as it was.

 @return `Whether the row was changed.`
*>
fn bool DigitBands.band_row(&self, float[] row, Vec3 p, float blend)
{
	if (self.forks.len == 0) return false;
	float sum = 0.0f;
	foreach (weight : row) sum += weight;
	if (!(sum > 0.0f)) return false;

	bool changed = false;
	float[64] along;
	foreach (fork : self.forks)
	{
		float digits = 0.0f;
		for (usz c = fork.first; c < fork.first + fork.count; c++)
		{
			DigitChain chain = self.chains[c];
			for (usz k = 0; k < chain.count; k++) digits += row[self.joints[chain.first + k]];
		}
		float gate = smooth_between(DIGIT_GATE_LOW, DIGIT_GATE_HIGH, digits / sum);
		if (gate <= 0.0f) continue;

		if (!changed)
		{
			foreach (&weight : row) *weight /= sum;
			digits /= sum;
			sum = 1.0f;
			changed = true;
		}

		usz chosen = self.nearest_chain(fork, p);
		DigitChain chain = self.chains[chosen];
		if (chain.count + 1 > along.len) continue;
		self.weights(chosen, p, blend, along[..]);

		float hand = row[fork.joint] + digits;
		float finger = 0.0f;
		for (usz k = 0; k < chain.count; k++) finger += row[self.joints[chain.first + k]];

		// The fork's new share: what the planes give it, unless that is less than
		// it held and the binder never trusted this finger with the difference.
		float held = row[fork.joint];
		float given = hand * along[0];
		if (given < held)
		{
			float trust = smooth_between(DIGIT_TRUST_LOW, DIGIT_TRUST_HIGH, hand > 0.0f ? finger / hand : 0.0f);
			given = held - (held - given) * trust;
		}
		float rest = hand - given;
		float spread = 1.0f - along[0];

		row[fork.joint] += (given - row[fork.joint]) * gate;
		for (usz c = fork.first; c < fork.first + fork.count; c++)
		{
			DigitChain other = self.chains[c];
			for (usz k = 0; k < other.count; k++)
			{
				// What the planes give nothing keeps a leak of what it held, in
				// proportion, so two joints never tie at a leak the binder told apart.
				usz joint = self.joints[other.first + k];
				float want = row[joint] * SIBLING_LEAK;
				if (c == chosen && spread > 0.0f) want = math::max(rest * along[1 + k] / spread, want);
				row[joint] += (want - row[joint]) * gate;
			}
		}
	}
	return changed;
}

<*
 Re-blend every row of a bind along its fingers (`DigitBands.band_row`).

 A vertex on a shell bound rigidly to one joint — an attachment, or a piece that
 is one bone's outright (`rigid_shells`) — is left alone: it moves as one piece,
 and banding it would bend it.

 @param dense : `[vertices, bones], rewritten in place.`
 @param blend : `The knuckle blend, 0 to 1 — see DigitBands.weights.`
 @param shell_of : `The shell of each vertex, or empty when the mesh has none to tell apart.`
 @param riders : `The joint each shell rides rigidly, or -1; empty when none do.`
*>
fn void band_digits(
	Allocator allocator,
	float[] dense,
	Vec3[] positions,
	Skeleton* skeleton,
	float blend,
	int[] shell_of = {},
	int[] riders = {})
{
	usz bones = skeleton.joints.len;
	if (bones == 0 || dense.len != positions.len * bones) return;
	DigitBands bands = digit_bands(allocator, skeleton);
	defer bands.free(allocator);
	if (bands.forks.len == 0) return;

	foreach (usz v, p : positions)
	{
		if (rides_rigidly(shell_of, riders, v)) continue;
		bands.band_row(dense[v * bones : bones], p, blend);
	}
}

<*
 Whether vertex `v` sits on a shell bound rigidly to one joint.
*>
fn bool rides_rigidly(int[] shell_of, int[] riders, usz v)
{
	if (v >= shell_of.len) return false;
	int shell = shell_of[v];
	return shell >= 0 && (usz)shell < riders.len && riders[(usz)shell] >= 0;
}
