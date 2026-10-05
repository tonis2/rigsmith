<*
 The app's side of secondary-motion chains: the questions about a chain that
 need the skeleton to answer, asked over an opened `RigView`.

 `core/secondary.c3` holds the record and the document's list and knows only
 dot ids. Everything here resolves those ids against a build — which joints a
 chain owns, where a chain started at a dot would end, whether a record the
 user is about to write can be simulated — and says so in a sentence when it
 cannot, so the panel and the MCP tool refuse the same shapes for the same
 reasons and neither has to know the resolver's rules.

 Nothing here writes the document except `adopt_bones_recorded`, which is the
 migration for the two places the old per-bone form still arrives from — a
 KHR file and a body-plan pack — and lands, recorded, inside whatever undo
 group the import already opened.
*>
module crig;

import rig;
import std::math;

<*
 The joints a chain owns in this build, root first: `secondary_run` with the
 dot ids resolved. Zero when the chain does not resolve here.

 @param out : `Room for the run. The view's joint count is always enough.`
*>
fn usz AppState.secondary_run_of(&self, RigView* view, SecondaryChain chain, usz[] out)
{
	sz root = view.joint_of(chain.root);
	sz tip = view.joint_of(chain.tip);
	if (root < 0 || tip < 0) return 0;
	return secondary_run(&view.skeleton, (usz)root, (usz)tip, out);
}

<*
 Where a chain rooted at this dot would end: the far end of the unbranched run
 below it, or the dot itself at a fork. See `secondary_infer_tip`.

 @return `The tip's dot id, or 0 when the root is not a joint of this build.`
*>
fn uint AppState.infer_secondary_tip(&self, RigView* view, uint root)
{
	sz joint = view.joint_of(root);
	if (joint < 0) return 0;
	usz tip = secondary_infer_tip(&view.skeleton, (usz)joint);
	return tip < view.dot_ids.len ? view.dot_ids[tip] : 0;
}

<*
 Why this record could not be simulated, or "" when it could.

 	`String problem = app.secondary_problem(&view, chain);`
 	`if (problem.len > 0) { app.@notice("%s", problem); return; }`

 The four shapes `jiggle_specs_from_document` would skip, said out loud before
 they are written, plus the values a file would refuse:

 - the root is not a joint of this rig, or is the skeleton's own root — there
   is no animated point above it for the chain to hang from;
 - the tip is not a joint, or does not descend from the root;
 - the run passes through a joint another chain already owns. One bone, one
   chain: a run that overlapped would have the nearer chain keep the joint and
   this one silently lose it;
 - a value outside its range — see `secondary_values_sane`.

 The sentence is a literal, so nothing is owned by the caller.
*>
fn String AppState.secondary_problem(&self, RigView* view, SecondaryChain chain)
{
	if (!secondary_values_sane(chain))
	{
		return "flexibility and damping run 0 to 1, gravity to ±10, the swing to 180° and the thickness cannot be negative";
	}

	sz root = view.joint_of(chain.root);
	if (root < 0) return "the chain's root is not a joint of this rig";
	if (view.skeleton.parents[root] < 0)
	{
		return "the root cannot start a chain — there is nothing above it to hinge from";
	}

	uint tip_id = chain.tip != 0 ? chain.tip : chain.root;
	sz tip = view.joint_of(tip_id);
	if (tip < 0) return "the chain's tip is not a joint of this rig";

	usz[] run = alloc::new_array(mem, usz, (sz)view.len());
	defer alloc::free(mem, run);
	usz length = secondary_run(&view.skeleton, (usz)root, (usz)tip, run);
	if (length == 0) return "the tip has to be below the root — a chain runs down one line of bones";

	usz[] other = alloc::new_array(mem, usz, (sz)view.len());
	defer alloc::free(mem, other);
	foreach (held : self.doc.secondary.array_view())
	{
		if (held.root == chain.root) continue;
		usz taken = self.secondary_run_of(view, held, other);
		for (usz i = 0; i < length; i++)
		{
			for (usz k = 0; k < taken; k++)
			{
				if (run[i] == other[k]) return "that run crosses a chain that is already there — clear it first, or root this one below it";
			}
		}
	}

	return "";
}

<*
 Whether some chain owns this dot's bone.

 Asked per dot per frame by the overlay, which is why it is a lookup into a
 list rebuilt only when the rig or the chains change rather than a walk of the
 skeleton per ask. The list is the runs of every chain that resolves, so a
 stale record marks nothing — the same reading the solver gives it.
*>
fn bool AppState.is_dynamic(&self, uint id) => self.secondary_root_of(id) != 0;

<*
 The root of the chain whose run this dot sits in, or 0 when none does.

 A root's chain is its own; a tip's or a middle joint's is the chain above it.
 What lets the panel show the tail's behaviour whichever bone of the tail was
 clicked. Same cache as `is_dynamic`, same terms.
*>
fn uint AppState.secondary_root_of(&self, uint id)
{
	if (id == 0) return 0;
	self.refresh_dynamic_dots();
	foreach (usz i, held : self.dynamic_dots)
	{
		if (held == id) return self.dynamic_dot_roots[i];
	}
	return 0;
}

// Rebuilds `dynamic_dots` when the rig or the chains have moved since it was
// last built. A document with no chains, which is most of them, costs the two
// comparisons and nothing else.
fn void AppState.refresh_dynamic_dots(&self)
{
	if (self.dynamic_dots_built && self.dynamic_dots_rig == self.rig_generation
		&& self.dynamic_dots_sim == self.secondary_generation) return;

	if (self.dynamic_dots.len > 0) alloc::free(mem, self.dynamic_dots);
	if (self.dynamic_dot_roots.len > 0) alloc::free(mem, self.dynamic_dot_roots);
	self.dynamic_dots = {};
	self.dynamic_dot_roots = {};
	self.dynamic_dots_built = true;
	self.dynamic_dots_rig = self.rig_generation;
	self.dynamic_dots_sim = self.secondary_generation;

	if (self.doc.secondary.len() == 0) return;

	RigView? opened = self.open_rig(mem);
	if (catch opened) return;
	RigView view = opened;
	defer view.free(mem);

	JiggleChainSpec[] chains;
	JiggleColliderSpec[] colliders;
	jiggle_specs_from_document(mem, &self.doc, &view.skeleton, view.dot_ids, &chains, &colliders);
	defer free_jiggle_specs(mem, chains, colliders);

	usz count = 0;
	foreach (chain : chains) count += chain.joints.len;
	if (count == 0) return;

	self.dynamic_dots = alloc::new_array(mem, uint, (sz)count);
	self.dynamic_dot_roots = alloc::new_array(mem, uint, (sz)count);
	usz at = 0;
	foreach (chain : chains)
	{
		uint root = view.dot_ids[chain.joints[0]];
		foreach (joint : chain.joints)
		{
			self.dynamic_dots[at] = view.dot_ids[joint];
			self.dynamic_dot_roots[at] = root;
			at++;
		}
	}
}

<*
 Lands the old per-bone form on the document as chains, one recorded edit per
 chain, leaving the group open.

 	`usz landed = app.adopt_bones_recorded(bones);`

 The migration the two importers share: a KHR file and a body-plan pack both
 still speak in bones, and `secondary_chains_from_bones` says which runs those
 bones make against the skeleton these dots build. A run whose root already
 carries a chain is left alone rather than overwritten — the document's own
 setup outranks a file's — and a run that crosses one is skipped, since a chain
 that would silently lose its joints is worse than a bone that stays the
 animation's.

 @return `How many chains landed.`
*>
fn usz AppState.adopt_bones_recorded(&self, JiggleSpec[] bones)
{
	SecondaryChain[] chains = secondary_chains_from_bones(mem, &self.doc, bones);
	if (chains.len == 0) return 0;
	defer alloc::free(mem, chains);

	RigView? opened = self.open_rig(mem);
	if (catch opened) return 0;
	RigView view = opened;
	defer view.free(mem);

	usz landed = 0;
	foreach (chain : chains)
	{
		if (self.doc.secondary_of(chain.root).present()) continue;
		if (self.secondary_problem(&view, chain).len > 0) continue;
		if (self.set_secondary_recorded(chain)) landed++;
	}
	return landed;
}
