<*
 The app's side of secondary-motion chains: the questions about a chain that
 need the skeleton to answer, asked over an opened `RigView`.

 `algo/sim/secondary.c3` holds the record and the document's list and knows only
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

fn usz AppState.secondary_run_of(&self, RigView* view, SecondaryChain chain, usz[] out) => secondary_run_of(view, chain, out);

fn uint AppState.infer_secondary_tip(&self, RigView* view, uint root) => infer_secondary_tip(view, root);

fn String AppState.secondary_problem(&self, RigView* view, SecondaryChain chain) => secondary_problem(&self.doc, view, chain);

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
