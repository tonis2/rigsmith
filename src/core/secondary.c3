<*
 Secondary motion as a behavior on a chain: one record per tail, braid, ear or
 accessory, rather than five unexplained numbers repeated on every dot.

 The record says **where the chain is** — a root dot and a tip dot, the run
 between them being whatever the skeleton says it is when the chain is expanded
 — and **how it behaves**, in words a person has an opinion about: a preset, a
 flexibility, a damping, a gravity and whether it collides with the character.
 The solver still runs on `JiggleParams` per joint, and KHR still writes a
 rigid body per bone; those are produced at the boundary that needs them
 (`SecondaryChain.solver_params`, `jiggle_specs_from_document`,
 `rig_physics_of`) and never stored.

 **Keyed by the root dot's id.** One chain per root, and a chain whose tip is no
 longer under its root — the rig was edited between — resolves to nothing at
 the boundary rather than to a guess, on the terms every dot-keyed list in the
 document follows: stale entries wait for undo, and the session writer is where
 they are finally dropped.

 **The old model is read, never written.** Files before session version 16 and
 every KHR_physics_rigid_bodies file carry the per-bone form, and
 `secondary_chains_from_bones` turns those into chains: a run of dynamic bones
 becomes one chain carrying its root bone's numbers. What a run cannot express
 in the new form — a stiffness gradient down a tail, a stiffness of exactly
 zero — reduces to the nearest chain; the shape and the feel of a shipped setup
 survive, its per-bone gradient does not.

 Lives in `core/` with the document it extends: no cui, no window, so a round
 trip and a migration are assertable headless.
*>
module crig;

import rig;
import std::collections::list;
import std::math;

alias SecondaryChainList = List{SecondaryChain};

<*
 Where a chain's editable numbers start from. Presets initialize values a user
 then edits; they are not solver modes, and nothing downstream reads them.

 `CUSTOM` is what a migrated setup arrives as — it was tuned by hand under the
 old model and no preset describes it — and what the UI may show once a preset's
 numbers have been dragged away from.
*>
enum SecondaryPreset : char
{
	HAIR,
	TAIL,
	EAR,
	SOFT,
	CUSTOM,
}

<*
 The preset's name as a file and a tool spell it: lower case, stable, and the
 same in both directions through `secondary_preset_named`.
*>
fn String SecondaryPreset.label(self)
{
	switch (self)
	{
		case HAIR: return "hair";
		case TAIL: return "tail";
		case EAR: return "ear";
		case SOFT: return "soft";
		case CUSTOM: return "custom";
	}
}

<*
 The preset a file or a tool named, or `CUSTOM` for a spelling nobody here
 knows — a preset is a starting point, and an unknown one costs the label rather
 than the chain.

 @param known : `Set when the label was one of the five; a caller that has to refuse a typo reads this, one that is loading a file does not.`
*>
fn SecondaryPreset secondary_preset_named(String label, bool* known = null)
{
	if (known) *known = true;
	switch (label)
	{
		case "hair": return HAIR;
		case "tail": return TAIL;
		case "ear": return EAR;
		case "soft": return SOFT;
		case "custom": return CUSTOM;
		default:
			if (known) *known = false;
			return CUSTOM;
	}
}

<*
 The stiffness a flexibility of 0 resolves to: the spring that halves its
 remaining gap to the animated pose every 1/120 s substep, which on screen is a
 bone welded to the clip. See `JiggleParams` for why the units are thousands.
*>
const float SECONDARY_STIFFEST = 14400.0f;

<*
 The stiffness a flexibility of 1 resolves to: a spring barely distinguishable
 from none, a rope rather than a stick. Not zero, because zero removes the
 constraint outright and a chain that follows nothing but gravity is not
 secondary motion — it is a thing that has fallen off.
*>
const float SECONDARY_LOOSEST = 100.0f;

<*
 One chain: where it hangs and how it moves.

 `root` is the dot whose joint is pinned — its position stays the animation's,
 its rotation is simulated — and `tip` is the last dot the chain owns. The run
 between them is resolved against the skeleton when the chain is expanded, so
 a dot inserted between the two joins the chain without the record changing.
 A tip equal to the root is a one-bone chain.

 The four behaviour values are stated in user terms and turned into solver terms
 by `solver_params`:

     flexibility  0..1. How far the chain lags behind the pose the clip keys:
                  0 follows it exactly, 1 hangs off it like a rope. Logarithmic
                  underneath — the useful stretch of stiffness is a ratio, not
                  a difference — see `secondary_stiffness`.
     damping      0..1. How much of its speed the chain sheds each second:
                  0 rings for ever, 1 is a dead stop. Stated as the share lost
                  rather than the share kept, which is how a slider labelled
                  Damping reads.
     gravity      A multiplier on standard gravity. 1 is earth, 0 a chain that
                  only chases the animation, negative a balloon.
     collide      Whether the chain is pushed out of the character: its
                  deformed skin, with the chain's own triangles left out, and
                  any collider capsules the rig still carries. How fat the
                  chain is comes from its own skin — `joint_thickness` — and
                  where it may swing from its joints' rotation limits, so
                  neither is a number here.

 That is the whole record. Nothing about how far a bone may turn or how thick
 it is: the first is the Joint card's rotation limits, which FK, IK, playback
 and the simulation all read, and the second is measured off the weights.
*>
struct SecondaryChain
{
	uint root;
	uint tip;
	SecondaryPreset preset;
	float flexibility;
	float damping;
	float gravity;
	bool collide;
}

<*
 Whether this record names a chain at all. The zero record — no root — is what
 `RigDocument.secondary_of` answers for a dot that carries none, and what an
 undo entry stores as "there was nothing here".
*>
fn bool SecondaryChain.present(self) => self.root != 0;

<*
 Whether two records say the same thing, bit for bit: the question a setter asks
 to know if it is a change, not a question about how alike two chains look.
*>
fn bool SecondaryChain.same(self, SecondaryChain other) => self.root == other.root
	&& self.tip == other.tip && self.preset == other.preset
	&& self.flexibility == other.flexibility && self.damping == other.damping
	&& self.gravity == other.gravity && self.collide == other.collide;

<*
 What a preset starts a chain at, on a record that keeps its root and tip.

 Tail is the old model's documented defaults, near enough — a stiffness just
 under 2000, three tenths of the speed kept per second, earth gravity — so a
 chain made with no preset named moves the way a bone made dynamic always has. Hair is looser and
 collides; an ear is stiff, half-weighted and free of the body; a soft accessory
 is in between and collides with nothing. `CUSTOM` changes nothing but the label.
*>
fn SecondaryChain SecondaryChain.with_preset(self, SecondaryPreset preset)
{
	SecondaryChain out = self;
	out.preset = preset;
	switch (preset)
	{
		case HAIR:
			out.flexibility = 0.55f;
			out.damping = 0.6f;
			out.gravity = 1.0f;
			out.collide = true;
		case TAIL:
			out.flexibility = 0.4f;
			out.damping = 0.7f;
			out.gravity = 1.0f;
			out.collide = true;
		case EAR:
			out.flexibility = 0.3f;
			out.damping = 0.75f;
			out.gravity = 0.5f;
			out.collide = false;
		case SOFT:
			out.flexibility = 0.5f;
			out.damping = 0.5f;
			out.gravity = 1.0f;
			out.collide = false;
		case CUSTOM:
			break;
	}
	return out;
}

<*
 Whether the four preset-owned values are still the ones the record's preset
 would set: what lets a panel say "Hair" over an untouched chain and "Hair,
 edited" over one whose sliders have moved. `CUSTOM` is never "edited".
*>
fn bool SecondaryChain.on_preset(self)
{
	if (self.preset == CUSTOM) return true;
	SecondaryChain fresh = self.with_preset(self.preset);
	return fresh.flexibility == self.flexibility && fresh.damping == self.damping
		&& fresh.gravity == self.gravity && fresh.collide == self.collide;
}

<*
 The spring rate a flexibility resolves to, on a log scale between
 `SECONDARY_STIFFEST` and `SECONDARY_LOOSEST`.

 Logarithmic because the solver takes the reciprocal: what a bone does between
 a stiffness of 100 and 2000 is most of what a bone can do, and a linear track
 would spend three quarters of itself on the stretch above 8000 where one number
 is not visibly different from the next. Half way along is about 1200, which is
 a soft, heavy follow.
*>
fn float secondary_stiffness(float flexibility)
{
	float share = math::clamp(flexibility, 0.0f, 1.0f);
	return SECONDARY_STIFFEST * math::pow(SECONDARY_LOOSEST / SECONDARY_STIFFEST, share);
}

<*
 The inverse of `secondary_stiffness`, for a setup arriving from the old model
 or from a file: the flexibility that resolves to this stiffness, clamped to the
 range a chain can express. Zero or less — the spring removed outright — reads
 as fully flexible, the nearest thing a chain has to no spring at all.
*>
fn float secondary_flexibility(float stiffness)
{
	if (!(stiffness > 0.0f)) return 1.0f;
	float share = math::ln(SECONDARY_STIFFEST / stiffness) / math::ln(SECONDARY_STIFFEST / SECONDARY_LOOSEST);
	return math::clamp(share, 0.0f, 1.0f);
}

<*
 The solver's per-bone reading of this chain: the same numbers for every bone
 in the run, which is what "shared behaviour values" means.

 The radius comes out as zero — a point. What a bone is held off the skin by
 is its own girth, which the record does not know and the skin does:
 `AppState.rebuild_jiggle` fills the radii in from `joint_thickness` for a
 chain that collides. A chain that does not collide keeps the point, and the
 capsules and the surface are skipped for it separately — see
 `JiggleChainSpec.ignores_colliders`.
*>
fn JiggleParams SecondaryChain.solver_params(self)
{
	return {
		.stiffness = secondary_stiffness(self.flexibility),
		.damping = 1.0f - math::clamp(self.damping, 0.0f, 1.0f),
		.gravity = self.gravity,
		.radius = 0.0f,
	};
}

<*
 A chain's behaviour read back out of the old model's numbers: the migration's
 other half, and the inverse of `solver_params` as far as the two forms allow.

 Damping is exact, gravity is copied, and the stiffness lands on the
 flexibility that resolves nearest to it. A per-bone radius is not carried —
 the chain's thickness is measured off its skin now — and the chain is
 labelled `CUSTOM`, because it was tuned by hand and no preset claims it.
*>
fn SecondaryChain secondary_from_params(uint root, uint tip, JiggleParams params)
{
	return {
		.root = root,
		.tip = tip,
		.preset = CUSTOM,
		.flexibility = secondary_flexibility(params.stiffness),
		.damping = 1.0f - math::clamp(params.damping, 0.0f, 1.0f),
		.gravity = params.gravity,
		.collide = true,
	};
}

<*
 As far from earth as a gravity multiplier is worth taking. Ten g is already
 past anything secondary motion reads as, and the bound is what turns a caller
 who meant model units per second squared into a refusal rather than a chain
 that snaps flat against the body.
*>
const float SECONDARY_GRAVITY_LIMIT = 10.0f;

<*
 Whether every number on this record is one a chain can mean: finite, the two
 shares inside 0..1 and gravity inside its bound. The one check a file reader
 and a tool share, so a session and an MCP call refuse the same values.
*>
fn bool secondary_values_sane(SecondaryChain chain)
{
	if (!math::is_finite(chain.flexibility) || chain.flexibility < 0.0f || chain.flexibility > 1.0f) return false;
	if (!math::is_finite(chain.damping) || chain.damping < 0.0f || chain.damping > 1.0f) return false;
	if (!math::is_finite(chain.gravity) || math::abs(chain.gravity) > SECONDARY_GRAVITY_LIMIT) return false;
	return true;
}

// ---------------------------------------------------------------------------
// The document's list

<*
 Writes a chain onto its root, replacing whatever that root carried.

 A record with no root is refused — `clear_secondary` is how a chain is taken
 off — and the tip is not checked against the rig here: the document has no
 skeleton, and a tip that is not under its root is a stale record the boundary
 skips, exactly like a pin on a deleted dot. `AppState.secondary_problem` is
 where a caller that can see the skeleton is told what is wrong before writing.

 @return `True if this changed anything.`
*>
fn bool RigDocument.set_secondary(&self, SecondaryChain chain)
{
	if (chain.root == 0 || !self.find(chain.root)) return false;
	if (chain.tip == 0) chain.tip = chain.root;

	foreach (sz i, held : self.secondary.array_view())
	{
		if (held.root != chain.root) continue;
		if (held.same(chain)) return false;
		*self.secondary.get_ref(i) = chain;
		return true;
	}

	self.secondary.push(chain);
	return true;
}

<*
 Takes the chain off this root, if it carries one.

 @return `True if this changed anything.`
*>
fn bool RigDocument.clear_secondary(&self, uint root)
{
	foreach (sz i, held : self.secondary.array_view())
	{
		if (held.root != root) continue;
		self.secondary.remove_at(i);
		return true;
	}
	return false;
}

<*
 The chain rooted at this dot, or the zero record where there is none — for a
 dot that does not exist too, since a selection outlives the dot it named.
*>
fn SecondaryChain RigDocument.secondary_of(&self, uint root)
{
	foreach (held : self.secondary.array_view())
	{
		if (held.root == root) return held;
	}
	return {};
}

<*
 Puts a root into exactly this state: the chain given, or none when the record
 is the zero one. The one call undo needs, since an edit's "before" is either.
*>
fn bool RigDocument.assign_secondary(&self, uint root, SecondaryChain chain)
{
	if (!chain.present()) return self.clear_secondary(root);
	chain.root = root;
	return self.set_secondary(chain);
}

// ---------------------------------------------------------------------------
// Runs

<*
 The joints a chain owns, root first, or nothing when the tip is not under the
 root.

 	`usz length = secondary_run(&skeleton, root_joint, tip_joint, run);`

 Walked from the tip upward, because a skeleton stores parents and not
 children, then reversed into the order the solver wants. A tip equal to the
 root is a run of one. `out` needs room for the whole ancestry in the worst
 case — a skeleton's joint count is always enough.

 @return `How many joints were written, or 0 when the tip does not descend from the root or either index is not a joint.`
*>
fn usz secondary_run(rig::Skeleton* skeleton, usz root, usz tip, usz[] out)
{
	usz joints = skeleton.len();
	if (root >= joints || tip >= joints || out.len == 0) return 0;

	usz length = 0;
	usz walk = tip;
	while (true)
	{
		if (length >= out.len) return 0;
		out[length++] = walk;
		if (walk == root) break;
		int parent = skeleton.parents[walk];
		if (parent < 0) return 0;
		walk = (usz)parent;
	}

	usz low = 0;
	usz high = length - 1;
	while (low < high)
	{
		usz swap = out[low];
		out[low] = out[high];
		out[high] = swap;
		low++;
		high--;
	}
	return length;
}

<*
 Where a chain rooted here would naturally end: down through every joint with
 exactly one child, stopping at the first fork and at the tip.

 What "choosing the root may infer the tip" means on a simple run. At a fork the
 answer is the fork itself — the user picks a branch from there — rather than a
 guess at which branch was meant.
*>
fn usz secondary_infer_tip(rig::Skeleton* skeleton, usz root)
{
	usz joints = skeleton.len();
	usz walk = root;
	while (walk < joints)
	{
		usz children = 0;
		usz heir = joints;
		for (usz c = 0; c < joints; c++)
		{
			int parent = skeleton.parents[c];
			if (parent < 0 || (usz)parent != walk) continue;
			children++;
			heir = c;
		}
		if (children != 1) break;
		walk = heir;
	}
	return walk;
}

// ---------------------------------------------------------------------------
// Migration

<*
 Turns the old per-bone model into chains against this document's own skeleton.

 	`SecondaryChain[] chains = secondary_chains_from_bones(mem, &doc, bones);`

 The grouping is the one the old resolver used, so a setup keeps its shape: a
 run of dynamic bones, each the sole dynamic child of the one before, is one
 chain; a fork is one chain per branch with the shared parent a chain of its
 own; a dynamic bone on the skeleton's root is dropped, since there is no
 animated point above it to hang from. Each chain carries its root bone's
 numbers, read through `secondary_from_params`.

 Entries naming dots the document does not hold are skipped. The document is
 not written — the caller records what comes back, so a migration lands in the
 same undo group as whatever brought the bones in. Empty when nothing resolves;
 the caller frees a non-empty result.
*>
fn SecondaryChain[] secondary_chains_from_bones(Allocator allocator, RigDocument* doc, JiggleSpec[] bones)
{
	if (bones.len == 0) return {};

	uint[] dot_ids;
	rig::Skeleton? built = build_skeleton(doc, allocator, &dot_ids);
	if (catch built) return {};
	rig::Skeleton skeleton = built;
	defer
	{
		skeleton.free(allocator);
		alloc::free(allocator, dot_ids);
	}

	usz joints = skeleton.len();
	JiggleParams[] params = alloc::new_array(allocator, JiggleParams, (sz)joints);
	defer alloc::free(allocator, params);
	bool[] dynamic = alloc::new_array(allocator, bool, (sz)joints);
	defer alloc::free(allocator, dynamic);

	usz count = 0;
	foreach (bone : bones)
	{
		if (bone.params.inert()) continue;
		foreach (usz j, id : dot_ids)
		{
			if (id != bone.dot_id || dynamic[j]) continue;
			dynamic[j] = true;
			params[j] = bone.params;
			count++;
			break;
		}
	}
	if (count == 0) return {};

	// How many dynamic children each dynamic joint has: a run continues only
	// through a joint with exactly one.
	usz[] followers = alloc::new_array(allocator, usz, (sz)joints);
	defer alloc::free(allocator, followers);
	for (usz j = 0; j < joints; j++)
	{
		if (!dynamic[j]) continue;
		int parent = skeleton.parents[j];
		if (parent < 0 || (usz)parent >= joints) { dynamic[j] = false; continue; }
		if (dynamic[(usz)parent]) followers[(usz)parent]++;
	}

	SecondaryChainList runs;
	runs.init(allocator);
	defer runs.free();

	for (usz j = 0; j < joints; j++)
	{
		if (!dynamic[j]) continue;
		int parent = skeleton.parents[j];
		bool rooted = parent < 0 || !dynamic[(usz)parent] || followers[(usz)parent] > 1;
		if (!rooted) continue;

		usz walk = j;
		while (followers[walk] == 1)
		{
			usz next = joints;
			for (usz c = walk + 1; c < joints; c++)
			{
				int above = skeleton.parents[c];
				if (dynamic[c] && above >= 0 && (usz)above == walk) { next = c; break; }
			}
			if (next >= joints) break;
			walk = next;
		}

		runs.push(secondary_from_params(dot_ids[j], dot_ids[walk], params[j]));
	}

	return runs.len() > 0 ? runs.to_array(allocator) : (SecondaryChain[]){};
}
