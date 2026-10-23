<*
 Playing a pack's clips on a rig that does not share its words.

 	`PackReach reach = measure_reach(mem, pack, &view.skeleton, view.names);`
 	`rig::Pose pose = clip.pose(mem, &view.skeleton, reach.names, time);`

 A clip drives a joint by **naming** it: `AnimTemplate.pose` asks whether a
 keyframe names each joint of the rig and leaves the ones it does not at rest.
 That single string comparison is the whole of retargeting, and it is also the
 whole of the problem — a library holds packs tagged `biped` in more than one
 spelling, a downloaded one saying `mixamorig:Hips` where the shipped humanoid
 says `hips`. A rig named by one of them takes nothing from the others, and the
 clip does not fail loudly: it plays, and the character stands still.

 So the names are translated rather than the clips retimed. `measure_reach` asks
 the shape matcher which joint of the pack each joint of the rig *is* — the same
 name-free question `auto_name` asks, see core/joint_match.c3 — and hands back
 this rig's joints spelled in that pack's words. Feed that to `pose` in place of
 the rig's own names and every clip in the pack plays, with nothing in the pose
 arithmetic changed or even aware.

 **The rig's own spelling wins wherever the pack shares it.** A rig already named
 in the pack's words is being read exactly, and a shape match is a guess however
 good; letting it overrule an exact name would move a joint the clip meant for
 its neighbour. The match only fills in what the names do not already answer.

 **What it cannot carry, it counts.** A pack that names sixty-five joints played
 on a rig with nineteen leaves forty-six of them with nowhere to go, and that is
 not a failure worth refusing — it is a walk without fingers, which is what the
 user asked for. `reach_gaps` is how it gets said out loud: not a list of
 forty-six joint names, but the two places the rig stops, `hand_L` and `hand_R`.
*>
module crig;

import rig;
import std::collections::list;
import std::math;



<*
 What one pack's clips can reach on one rig.

 `names` is the retarget itself: one entry per rig joint, in the pack's words
 where the pack has one and the rig's own where it has not. Parallel to the
 skeleton it was measured against, so it goes stale the moment the joint order
 does — see `AppState.pack_reach`, which is what keeps it fresh.

 `taken` is the same answer read from the other side: one entry per *pack* joint,
 true when some rig joint answers to it. It is what `reach_gaps` reduces, and it
 is not derivable from `names` without searching the pack for every entry.
*>
struct PackReach
{
	String[] names;
	bool[] taken;

	usz answered; // rig joints the pack has a word for
	usz joints;   // rig joints in total

	<*
	 Whether the two skeletons relate at all — `JointMatch.usable`, the two-thirds
	 rule, asked of the pack's required joints.

	 The line between "this clip will do something partial" and "this clip is for
	 a different animal". Everything above the line is offered and reported on;
	 everything below it is greyed, because a bird's clip on a biped is not a
	 walk missing its fingers.
	*>
	bool usable;
}

fn void PackReach.free(&self, Allocator allocator)
{
	foreach (name : self.names)
	{
		if (name.len > 0) alloc::free(allocator, name.ptr);
	}
	if (self.names.len > 0) alloc::free(allocator, self.names);
	if (self.taken.len > 0) alloc::free(allocator, self.taken);
	*self = {};
}

<*
 Whether some joint of the rig answers to this name once translated.

 A linear scan, which is what every other name lookup over a rig here is: the
 array is tens of entries and the map that would replace it would have to be
 rebuilt whenever the rig is.
*>
fn bool PackReach.answers(&self, String name)
{
	if (name.len == 0) return false;
	foreach (held : self.names)
	{
		if (held == name) return true;
	}
	return false;
}

<*
 Work out how a pack's clips fall on a rig.

 	`PackReach reach = measure_reach(mem, pack, &view.skeleton, view.names);`
 	`defer reach.free(mem);`

 Costs one shape match — a few milliseconds on a sixty-five joint rig against a
 sixty-five dot pack, and a quarter of one on the small plans. That is cheap
 enough to redo when the rig changes and far too dear to redo when a cell is
 painted, which is the split `AppState.pack_reach` exists to keep.

 @param skeleton : `The open rig. An empty one comes back unusable rather than as a fault: a document with no dots is an ordinary state, and the caller has its own answer for it.`
 @param names : `The rig's own joint names, in the same order. Borrowed.`
 @return `Owned by the caller.`
*>
fn PackReach measure_reach(
	Allocator allocator,
	AnimPack* pack,
	rig::Skeleton* skeleton,
	String[] names)
{
	usz joints = skeleton.len();
	usz bones = pack.rest.len();
	if (joints == 0) return {};

	// **A pack with no rest skeleton has no shape to be matched by**, and the
	// authored pack is exactly that: clips written against the rig in this
	// document, by `apply_clip` over MCP or out of the editor, with no skeleton
	// beside them because they never came from a file. Their joint names *are* this
	// rig's, so the rig answers to its own words and the shape gate does not apply
	// — which is the whole of what `clip_applies` asked before any of this existed.
	if (bones == 0 || bones != pack.joint_names.len)
	{
		PackReach spoken = {
			.names = alloc::new_array(allocator, String, (sz)joints),
			.joints = joints,
			.usable = true,
		};
		foreach (usz j, name : names)
		{
			if (j >= joints) break;
			if (name.len == 0) continue;
			spoken.names[j] = name.copy(allocator);
			spoken.answered++;
		}
		return spoken;
	}

	// `moved` is left empty on both sides for the reason `auto_name_recorded`
	// leaves it empty: a document holds no clips, so there is nothing to say about
	// how far each joint ever turns, and the matcher reads a missing `moved` as
	// "cannot tell you" rather than as "nothing moves".
	MatchShape rig = { .at = skeleton.joints, .parent = skeleton.parents };
	MatchShape bone = { .at = pack.rest.joints, .parent = pack.rest.parents };

	// **Matched both ways round, because the matcher is directional.** It lays the
	// plan's chains along the source's, so it needs a source at least as detailed
	// as the plan: a sixty-five joint mixamorig rig fits the seventeen-joint biped
	// plan exactly, and the same two the other way round matches the hips and
	// gives up — there is no source joint for `Spine1`, for a toe tip, or for the
	// crown of a head. Neither direction is the right one in general. The rig is
	// sometimes the finer skeleton and sometimes the coarser, and which it is
	// changes per pack, so both are asked and the one that relates more of this
	// rig is kept.
	int[] onto_plan = alloc::new_array(allocator, int, (sz)joints);
	int[] onto_rig = alloc::new_array(allocator, int, (sz)joints);
	defer
	{
		alloc::free(allocator, onto_plan);
		alloc::free(allocator, onto_rig);
	}

	Preset plan = pack.match_plan(allocator);
	defer free_preset(allocator, plan);

	JointMatch forward = match_preset(allocator, rig, plan);
	defer forward.free(allocator);
	foreach (usz j, int dot : forward.dot)
	{
		if (j < joints) onto_plan[j] = dot >= 0 && (usz)dot < bones ? dot : -1;
	}

	// The other way: the pack's own joints as the source, the rig as the plan. The
	// answer comes back per *pack* joint and is turned around here, which is all
	// the difference amounts to — a pairing has no direction once it is made.
	onto_rig[:joints] = -1;

	JointMatch backward = match_shapes(allocator, bone, rig);
	defer backward.free(allocator);
	foreach (usz b, int joint : backward.dot)
	{
		if (b >= bones || joint < 0 || (usz)joint >= joints) continue;
		if (onto_rig[(usz)joint] < 0) onto_rig[(usz)joint] = (int)b;
	}

	PackReach kept = fill_reach(allocator, pack, names, joints, onto_plan, forward.usable());
	PackReach other = fill_reach(allocator, pack, names, joints, onto_rig, backward.usable());

	// More of the rig spoken for wins, and a usable match beats an unusable one
	// whatever it covers — the flag is the two-thirds rule, which is a statement
	// about whether the skeletons relate at all rather than about this count.
	bool swap = other.usable != kept.usable
		? other.usable
		: other.answered > kept.answered;

	if (swap)
	{
		kept.free(allocator);
		kept = other;
	}
	else
	{
		other.free(allocator);
	}
	pair_branches(allocator, &kept, pack, skeleton);
	return kept;
}

<*
 Give a limb the plan does not have — a tail, an ear, a cape — the pack's limb
 that hangs off the same joint and points the same way.

 The body plan is what lets two rigs agree about a body, and it has no word for
 a tail: the importer keeps a source's tail under the file's own names (see
 `extra_branches`), and a rig's tail is whatever its builder called it, most
 often nothing at all. The whole-skeleton shape match does not reliably find
 them either — a tail is a thin thing whose shape varies more between two
 characters than anything the plan covers, and one curled a little to the side
 is on the wrong side of the midline to be paired with a straight one.

 So the pairing is local, and asks only what a limb certainly has: the joint it
 hangs off, answered already, and the way it points. A chain of rig joints no
 clip addresses, hanging off a joint the pack answers, is paired with a chain of
 pack joints nothing on the rig answers hanging off that same joint — the one
 that points most nearly the same way, as long as the two point into the same
 half of space (`BRANCH_MIN_AGREEMENT`). Only that loose: a tail modelled hanging
 down and to the side and one held straight out behind are eighty degrees apart
 at rest and still the same tail, and the clip's motion is carried relative to
 each rig's rest either way. Along the chains, joints
 pair in order by how far along each one they sit; a rig chain longer than the
 pack's leaves its last joints to follow the ones above.
*>
fn void pair_branches(Allocator allocator, PackReach* reach, AnimPack* pack, rig::Skeleton* skeleton) @private
{
	usz joints = skeleton.len();
	usz bones = pack.rest.len();
	if (reach.names.len != joints || reach.taken.len != bones) return;

	// Which pack joint each rig joint answers to, by name; -1 for none.
	int[] answer = alloc::new_array(allocator, int, (sz)joints);
	defer alloc::free(allocator, answer);
	for (usz j = 0; j < joints; j++) answer[j] = (int)pack_joint_index(pack, reach.names[j]);

	for (usz start = 0; start < joints; start++)
	{
		int up = skeleton.parents[start];
		if (up < 0 || answer[start] >= 0 || answer[(usz)up] < 0) continue;

		usz[] rig_chain = unanswered_chain(allocator, skeleton.parents, start, answer);
		defer alloc::free(allocator, rig_chain);
		if (rig_chain.len == 0) continue;
		Vec3 rig_from = skeleton.joints[(usz)up];
		Vec3 rig_way = skeleton.joints[rig_chain[^1]] - skeleton.joints[rig_chain[0]];
		if (rig_chain.len == 1) rig_way = skeleton.joints[rig_chain[0]] - rig_from;

		// The pack's limbs off the joint the rig's hangs from.
		usz hub = (usz)answer[(usz)up];
		float best = BRANCH_MIN_AGREEMENT;
		usz[] chosen = {};
		defer if (chosen.len > 0) alloc::free(allocator, chosen);
		for (usz b = 0; b < bones; b++)
		{
			if (pack.rest.parents[b] != (int)hub || reach.taken[b]) continue;
			usz[] pack_chain = untaken_chain(allocator, pack.rest.parents, b, reach.taken);
			if (pack_chain.len == 0) { alloc::free(allocator, pack_chain); continue; }
			Vec3 pack_way = pack.rest.joints[pack_chain[^1]] - pack.rest.joints[pack_chain[0]];
			if (pack_chain.len == 1) pack_way = pack.rest.joints[pack_chain[0]] - pack.rest.joints[hub];
			float agree = rig_way.length() > 0.0f && pack_way.length() > 0.0f
				? rig_way.normalize().dot(pack_way.normalize()) : -1.0f;
			if (agree <= best)
			{
				alloc::free(allocator, pack_chain);
				continue;
			}
			best = agree;
			if (chosen.len > 0) alloc::free(allocator, chosen);
			chosen = pack_chain;
		}
		if (chosen.len == 0) continue;

		float[] rig_along = chain_fractions(allocator, skeleton.joints, rig_chain);
		float[] pack_along = chain_fractions(allocator, pack.rest.joints, chosen);
		defer
		{
			alloc::free(allocator, rig_along);
			alloc::free(allocator, pack_along);
		}

		// In order down both chains, each rig joint to the nearest pack joint not
		// above the one the joint before it took.
		usz next = 0;
		foreach (usz i, joint : rig_chain)
		{
			if (next >= chosen.len) break;
			usz pick = next;
			for (usz k = next + 1; k < chosen.len; k++)
			{
				// Leave enough pack joints for the rig joints still to come.
				if (chosen.len - k < rig_chain.len - i && k > pick) break;
				if (math::abs(pack_along[k] - rig_along[i]) < math::abs(pack_along[pick] - rig_along[i])) pick = k;
			}
			usz bone = chosen[pick];
			if (reach.names[joint].len > 0) alloc::free(allocator, reach.names[joint].ptr);
			reach.names[joint] = pack.joint_names[bone].copy(allocator);
			reach.taken[bone] = true;
			answer[joint] = (int)bone;
			reach.answered++;
			next = pick + 1;
		}
	}
}

// How nearly a rig's limb and a pack's have to point the same way, root to tip,
// to be the same limb: anywhere in the same half of space. The legs, the arms
// and the head are answered by the plan before this is asked, so what is left
// to pair is a limb the plan lacks, and a tail pointing back is not an antenna
// pointing forward.
const float BRANCH_MIN_AGREEMENT @private = 0.0f;

// From `start` down through the only child that no clip addresses, while there
// is exactly one.
fn usz[] unanswered_chain(Allocator allocator, int[] parents, usz start, int[] answer) @private
{
	List{usz} chain;
	chain.init(allocator);
	usz at = start;
	while (true)
	{
		chain.push(at);
		usz only = 0;
		usz count = 0;
		foreach (usz c, parent : parents)
		{
			if (parent != (int)at) continue;
			count++;
			only = c;
		}
		if (count != 1 || answer[only] >= 0) break;
		at = only;
	}
	usz[] out = chain.to_array(allocator);
	chain.free();
	return out;
}

// The same, down the pack's joints no rig joint answers to yet.
fn usz[] untaken_chain(Allocator allocator, int[] parents, usz start, bool[] taken) @private
{
	List{usz} chain;
	chain.init(allocator);
	usz at = start;
	while (true)
	{
		chain.push(at);
		usz only = 0;
		usz count = 0;
		foreach (usz c, parent : parents)
		{
			if (parent != (int)at) continue;
			count++;
			only = c;
		}
		if (count != 1 || taken[only]) break;
		at = only;
	}
	usz[] out = chain.to_array(allocator);
	chain.free();
	return out;
}

// How far along a chain each joint sits, from its first joint, as a fraction of
// the whole. A chain of one sits at zero.
fn float[] chain_fractions(Allocator allocator, Vec3[] at, usz[] chain) @private
{
	float[] out = alloc::new_array(allocator, float, (sz)chain.len);
	float total = 0.0f;
	for (usz i = 1; i < chain.len; i++)
	{
		total += (at[chain[i]] - at[chain[i - 1]]).length();
		out[i] = total;
	}
	if (total > 0.0f) foreach (&f : out) *f /= total;
	return out;
}

// One candidate answer: the exact names, then whatever the given pairing adds.
//
// @param onto_plan : `The pack joint each rig joint pairs with, or -1. Not owned.`
fn PackReach fill_reach(
	Allocator allocator,
	AnimPack* pack,
	String[] names,
	usz joints,
	int[] onto_plan,
	bool usable) @private
{
	usz bones = pack.rest.len();
	PackReach reach = {
		.names = alloc::new_array(allocator, String, (sz)joints),
		.taken = alloc::new_array(allocator, bool, (sz)bones),
		.joints = joints,
		.usable = usable,
	};

	// The exact names first, and all of them before any pairing is read. A rig
	// joint whose own name is one this pack uses is answering exactly, and the
	// pass below must not then hand that same word to a second joint — two joints
	// answering to one channel would drive both off the same curve.
	usz exact = 0;
	foreach (usz j, name : names)
	{
		if (j >= joints) break;
		if (name.len == 0) continue;

		foreach (usz b, spelled : pack.joint_names)
		{
			if (spelled != name || reach.taken[b]) continue;
			reach.names[j] = name.copy(allocator);
			reach.taken[b] = true;
			reach.answered++;
			exact++;
			break;
		}
	}

	// **Names that already agree need no shape to confirm them**, and they have to
	// be allowed to say so on their own: a pack written against this very rig — an
	// authored one just saved to disk — can be a straight chain with no branch for
	// the matcher to anchor on, so the shape question comes back "no relation"
	// about two skeletons that are the same skeleton. Two thirds, the same
	// fraction `JointMatch.usable` asks for and against the same denominator.
	if (exact * 3 >= bones * 2) reach.usable = true;

	// Then the pairing, into whatever is still blank.
	for (usz j = 0; j < joints; j++)
	{
		if (reach.names[j].len > 0) continue;

		int b = onto_plan[j];
		if (b < 0 || (usz)b >= bones || reach.taken[(usz)b]) continue;

		reach.names[j] = pack.joint_names[(usz)b].copy(allocator);
		reach.taken[(usz)b] = true;
		reach.answered++;
	}

	// And the rig's own word for whatever is left, so the array stays parallel to
	// the skeleton and a joint the pack has never heard of still reads back as
	// itself rather than as a blank.
	foreach (usz j, name : names)
	{
		if (j >= joints || reach.names[j].len > 0) continue;
		if (name.len > 0) reach.names[j] = name.copy(allocator);
	}

	return reach;
}

<*
 Lay the hand-made matches for this pack over the automatic ones.

 A source joint mapped to a rig joint takes that joint over, and whatever the
 joint answered to before lets go; one mapped to nothing drives nothing. A pack
 with any hand match counts as related, since the user said how it fits.

 @param names : `The rig's own joint names, parallel to reach.names. Borrowed.`
*>
fn void apply_joint_maps(Allocator allocator, PackReach* reach, AnimPack* pack, String[] names, JointMap[] maps)
{
	usz bones = pack.joint_names.len;
	if (bones == 0 || reach.taken.len != bones || reach.names.len == 0) return;
	bool mapped = false;
	foreach (map : maps)
	{
		if (!map.names_pack(pack.path)) continue;
		sz source = pack_joint_index(pack, map.source);
		if (source < 0) continue;
		mapped = true;

		// Whoever answers to the source now lets go of it.
		foreach (usz j, &held : reach.names)
		{
			if (*held != map.source) continue;
			if (held.len > 0) alloc::free(allocator, held.ptr);
			String own = j < names.len ? names[j] : "";
			*held = own.len > 0 && pack_joint_index(pack, own) < 0 ? own.copy(allocator) : (String){};
		}
		reach.taken[(usz)source] = false;
		if (map.joint.len == 0) continue;

		foreach (usz j, own : names)
		{
			if (own != map.joint || j >= reach.names.len) continue;
			sz before = pack_joint_index(pack, reach.names[j]);
			if (before >= 0) reach.taken[(usz)before] = false;
			if (reach.names[j].len > 0) alloc::free(allocator, reach.names[j].ptr);
			reach.names[j] = map.source.copy(allocator);
			reach.taken[(usz)source] = true;
			break;
		}
	}
	if (!mapped) return;
	reach.usable = true;
	reach.answered = 0;
	foreach (held : reach.names) if (pack_joint_index(pack, held) >= 0) reach.answered++;
}

// Where a name sits among the pack's joints, or -1.
fn sz pack_joint_index(AnimPack* pack, String name)
{
	if (name.len == 0) return -1;
	foreach (usz b, spelled : pack.joint_names) if (spelled == name) return (sz)b;
	return -1;
}

<*
 Where a clip runs off the end of a rig, in the two ways it can.

 `stops` are joints the rig **has**, with clip motion below them and no rig
 below them to carry it — the hand on a character with no fingers. `missing` are
 whole branches the rig has not got at all, reported at the shallowest joint of
 each. The two want different words, which is why they are not one list: "nothing
 below hand_L" and "no tail" are both true and neither says the other.
*>
struct ReachGaps
{
	String[] stops;
	String[] missing;
}

fn void ReachGaps.free(&self, Allocator allocator)
{
	free_gaps(allocator, self.stops);
	free_gaps(allocator, self.missing);
	*self = {};
}

fn bool ReachGaps.present(&self) => self.stops.len > 0 || self.missing.len > 0;

<*
 Where this clip runs off the end of the rig, said in as few names as possible.

 	`ReachGaps gaps = reach_gaps(mem, pack, &reach, clip);`
 	`defer gaps.free(mem);`

 A clip keying sixty-five joints on a rig with nineteen is short by forty-six,
 and reciting forty-six names tells nobody anything. What is worth saying is
 where the rig *stops*: the joints it does have, under which the clip has motion
 and the rig has nothing. On a Mixamo dance played on a fingerless character that
 is two entries, `hand_L` and `hand_R`, and it reads as "the fingers will not
 move" without either of us having parsed a name to work it out.

 Structural rather than lexical on purpose, which is the same rule
 core/joint_match.c3 keeps: a joint is a hand because five chains hang off it,
 not because it is spelled like one.

 **A chain the rig carries more coarsely is not a gap.** A pack with three spine
 segments played on a rig with two loses one of them, and the spine still bends;
 saying so beside a genuinely absent hand would bury the one that matters. So a
 joint with no pairing is reported only when nothing below it is paired either —
 when the clip's motion there reaches the rig at no depth at all.

 A joint the clip never keys is not reported however absent: a walk that ignores
 the fingers is not short of them.

 @return `Owned by the caller. Empty both ways when the clip reaches everything it keys.`
*>
fn ReachGaps reach_gaps(Allocator allocator, AnimPack* pack, PackReach* reach, AnimTemplate* clip)
{
	usz bones = pack.rest.len();
	if (bones == 0 || reach.taken.len != bones || !clip) return {};

	// Which of the pack's joints this clip actually drives. A clip that leaves a
	// joint alone is not missing it.
	bool[] keyed = alloc::new_array(allocator, bool, (sz)bones);
	defer alloc::free(allocator, keyed);

	foreach (kf : clip.keyframes)
	{
		foreach (kd : kf.dots)
		{
			foreach (usz b, spelled : pack.joint_names)
			{
				if (spelled == kd.joint_name) { keyed[b] = true; break; }
			}
		}
	}

	// Two questions asked of every subtree, both about what lies *strictly* below
	// a joint: is any of it on the rig, and does the clip drive any of it. Walked
	// backwards over the parents-before-children order a rest skeleton is stored
	// in, so a joint's whole subtree has reported by the time the joint is read.
	bool[] rig_below = alloc::new_array(allocator, bool, (sz)bones);
	bool[] clip_below = alloc::new_array(allocator, bool, (sz)bones);
	defer
	{
		alloc::free(allocator, rig_below);
		alloc::free(allocator, clip_below);
	}

	for (usz b = bones; b > 0; b--)
	{
		usz j = b - 1;
		int parent = pack.rest.parents[j];
		if (parent < 0) continue;

		if (reach.taken[j] || rig_below[j]) rig_below[(usz)parent] = true;
		if (keyed[j] || clip_below[j]) clip_below[(usz)parent] = true;
	}

	StringList stops;
	StringList missing;
	stops.init(allocator);
	missing.init(allocator);

	for (usz j = 0; j < bones; j++)
	{
		// A joint the rig has, with clip motion under it and no rig under it: the
		// sentence "nothing below here", which subsumes every absent joint in the
		// subtree at once. This is the hand, on a rig with no fingers.
		if (reach.taken[j])
		{
			if (clip_below[j] && !rig_below[j]) stops.push(pack.joint_names[j].copy(allocator));
			continue;
		}

		// A joint with no pairing but a paired one below it: the chain reaches
		// through, one segment coarser. Not a gap — see the note above.
		if (rig_below[j]) continue;

		// Dead from here down, so report it — but only the shallowest of a run,
		// and only where the clip has motion to lose.
		if (!keyed[j] && !clip_below[j]) continue;

		int parent = pack.rest.parents[j];
		if (parent >= 0)
		{
			// Already said, one level up: either as another dead branch, or as the
			// "nothing below" that named this joint's parent.
			if (!reach.taken[(usz)parent] && !rig_below[(usz)parent]) continue;
			if (reach.taken[(usz)parent] && !rig_below[(usz)parent]) continue;
		}

		missing.push(pack.joint_names[j].copy(allocator));
	}

	ReachGaps out = { .stops = stops.to_array(allocator), .missing = missing.to_array(allocator) };
	stops.free();
	missing.free();
	return out;
}

<*
 How many of the rig's joints this clip will actually move.

 The number worth showing beside a gap, and not `PackReach.answered` — that is
 how much of the rig the *pack* has a word for, which is the same for every clip
 in it. A wave and a walk out of one pack reach very different amounts of a rig,
 and the one being played is the one to report.
*>
fn usz reach_drives(PackReach* reach, AnimTemplate* clip)
{
	if (!clip) return 0;

	usz driven = 0;
	foreach (name : reach.names)
	{
		if (name.len == 0) continue;
		foreach (kf : clip.keyframes)
		{
			if (kf.names(name)) { driven++; break; }
		}
	}
	return driven;
}

<*
 A few names as a phrase — "hand_L, hand_R and 3 more".

 	`String said = name_list(mem, stops, 3);`

 @param limit : `How many to spell out before the rest become a count. Zero spells out all of them.`
 @return `Owned by the caller. Empty for an empty list, and a literal is never returned, so it is always safe to free.`
*>
fn String name_list(Allocator allocator, String[] names, usz limit = 0)
{
	if (names.len == 0) return "";

	usz shown = limit == 0 || limit > names.len ? names.len : limit;

	DString out;
	out.init(allocator);
	for (usz i = 0; i < shown; i++)
	{
		if (i > 0) out.append(i + 1 == shown && shown == names.len ? " and " : ", ");
		out.append(names[i]);
	}
	if (shown < names.len) out.appendf(" and %d more", names.len - shown);
	return out.copy_str(allocator);
}

<*
 Release what `reach_gaps` returned.
*>
fn void free_gaps(Allocator allocator, String[] gaps)
{
	foreach (name : gaps)
	{
		if (name.len > 0) alloc::free(allocator, name.ptr);
	}
	if (gaps.len > 0) alloc::free(allocator, gaps);
}

// ---------------------------------------------------------------------------
// Respelling a clip

<*
 The words a joint name written in `from` becomes in `to`: `to[j]` for every
 joint j that `from` calls by it, once each. A name `from` does not hold stays as
 it is — a pack joint the rig has nothing for, or a name already in `to`'s words,
 as a layer put on a library clip from an authored one is. A joint `to` has no
 word for (an unnamed dot) cannot be written at all; `unreached` is raised.
*>
fn void words_for(String name, String[] from, String[] to, StringList* out, bool* unreached) @local
{
	out.clear();
	bool held = false;
	foreach (usz j, word : from)
	{
		if (word != name) continue;
		held = true;
		String spelt = j < to.len ? to[j] : "";
		if (spelt.len == 0) { *unreached = true; continue; }
		bool seen = false;
		foreach (already : out.array_view()) if (already == spelt) { seen = true; break; }
		if (!seen) out.push(spelt);
	}
	if (!held && name.len > 0) out.push(name);
}

// The entries of one key respelt: one per word each joint becomes.
fn AnimKeyframe keyframe_in_words(Allocator allocator, AnimKeyframe frame, String[] from, String[] to,
	StringList* words, usz* dropped) @local
{
	AnimDotList dots;
	dots.init(allocator);
	foreach (dot : frame.dots)
	{
		bool unreached;
		words_for(dot.joint_name, from, to, words, &unreached);
		if (words.len() == 0 && unreached) (*dropped)++;
		foreach (word : words.array_view())
		{
			AnimKeyDot copy = dot;
			copy.joint_name = word.copy(allocator);
			dots.push(copy);
		}
	}
	AnimKeyframe out = { .time = frame.time, .dots = dots.to_array(allocator) };
	dots.free();
	return out;
}

// Keys respelt, a key left saying nothing dropped — unless all of them would
// be, where the first is kept empty, since a clip has to have a key.
fn AnimKeyframe[] keyframes_in_words(Allocator allocator, AnimKeyframe[] frames, String[] from, String[] to,
	StringList* words, usz* dropped) @local
{
	AnimKeyframe[] out = alloc::new_array(allocator, AnimKeyframe, (sz)frames.len);
	usz count;
	foreach (frame : frames)
	{
		AnimKeyframe spelt = keyframe_in_words(allocator, frame, from, to, words, dropped);
		if (spelt.dots.len == 0 && (count > 0 || frames.len > 1))
		{
			spelt.free(allocator);
			continue;
		}
		out[count++] = spelt;
	}
	if (count == 0 && frames.len > 0) out[count++] = { .time = frames[0].time, .dots = {} };
	if (count == 0)
	{
		if (out.len > 0) alloc::free(allocator, out);
		return {};
	}
	return out[:count];
}

// One name replaced by its first word in `to`, or emptied when it has none.
fn void name_in_words(Allocator allocator, String* name, String[] from, String[] to, StringList* words) @local
{
	if (name.len == 0) return;
	bool unreached;
	words_for(*name, from, to, words, &unreached);
	String spelt = words.len() > 0 ? words.array_view()[0].copy(allocator) : "";
	alloc::free(allocator, name.ptr);
	*name = spelt;
}

<*
 The clip with every joint it names spelt in other words: a name that `from`
 gives joint j becomes `to[j]`. What a clip from a library file needs when it is
 copied into the authored pack, which speaks the rig's own words — `from` is the
 pack's word for each rig joint (`AppState.names_for`), `to` the rig's.

 A name `from` gives several joints (the rig's own word for a joint the pack has
 not got can be the word the pack gives another) is written once for each, so
 the copy drives every joint the original did. A name `from` does not hold is
 kept as it is, so a name already in `to`'s words passes through. Keys, ground contacts, look-at
 locks, pins and layers (their keys, masks and chains) are all respelt; times,
 values and the bones keys were recorded against are untouched, so the copy is
 carried onto the rig exactly as the original was.

 @param dropped : `Counts the entries whose joint the rig has no word for — an unnamed dot — and which the copy therefore cannot hold.`
*>
fn AnimTemplate clip_in_words(Allocator allocator, AnimTemplate source, String[] from, String[] to, usz* dropped = null)
{
	usz lost;
	StringList words;
	words.init(allocator);
	defer words.free();

	AnimTemplate out = clip_with_frames(allocator, source,
		keyframes_in_words(allocator, source.keyframes, from, to, &words, &lost), source.duration);

	foreach (&foot : out.ground.feet) name_in_words(allocator, &foot.joint, from, to, &words);
	foreach (&aim : out.aims) name_in_words(allocator, &aim.joint, from, to, &words);
	foreach (&pin : out.pins) name_in_words(allocator, &pin.joint, from, to, &words);
	foreach (&path : out.paths) name_in_words(allocator, &path.joint, from, to, &words);
	foreach (usz i, &layer : out.layers)
	{
		name_in_words(allocator, &layer.joint, from, to, &words);
		name_in_words(allocator, &layer.tip, from, to, &words);
		StringList mask;
		mask.init(allocator);
		defer mask.free();
		foreach (entry : layer.mask)
		{
			bool unreached;
			words_for(entry, from, to, &words, &unreached);
			foreach (word : words.array_view()) mask.push(word.copy(allocator));
			if (entry.len > 0) alloc::free(allocator, entry.ptr);
		}
		if (layer.mask.len > 0) alloc::free(allocator, layer.mask);
		layer.mask = mask.to_array(allocator);
		AnimKeyframe[] keys = keyframes_in_words(allocator, layer.keyframes, from, to, &words, &lost);
		foreach (&frame : layer.keyframes) frame.free(allocator);
		if (layer.keyframes.len > 0) alloc::free(allocator, layer.keyframes);
		layer.keyframes = keys;
	}
	// A contact, lock or pin on a joint the rig cannot address goes with it.
	out.ground.feet = feet_named(allocator, out.ground.feet);
	out.aims = aims_named(allocator, out.aims);
	out.pins = pins_named(allocator, out.pins);
	out.paths = anim_paths_named(allocator, out.paths);
	if (dropped) *dropped = lost;
	return out;
}

// The contacts, locks and pins that still name a joint, in place. An array left
// empty is released, since their owners free only one with a length.
fn AnimFoot[] feet_named(Allocator allocator, AnimFoot[] feet) @local
{
	usz kept;
	foreach (foot : feet) if (foot.joint.len > 0) feet[kept++] = foot;
	if (kept > 0 || feet.len == 0) return feet[:kept];
	alloc::free(allocator, feet);
	return {};
}

fn AnimAim[] aims_named(Allocator allocator, AnimAim[] aims) @local
{
	usz kept;
	foreach (&aim : aims)
	{
		if (aim.joint.len > 0) { aims[kept++] = *aim; continue; }
		aim.free(allocator);
	}
	if (kept > 0 || aims.len == 0) return aims[:kept];
	alloc::free(allocator, aims);
	return {};
}

fn AnimPin[] pins_named(Allocator allocator, AnimPin[] pins) @local
{
	usz kept;
	foreach (&pin : pins)
	{
		if (pin.joint.len > 0) { pins[kept++] = *pin; continue; }
		pin.free(allocator);
	}
	if (kept > 0 || pins.len == 0) return pins[:kept];
	alloc::free(allocator, pins);
	return {};
}
