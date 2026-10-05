<*
 Giving a hand-placed rig the names a clip can address it by.

 A clip reaches a joint through its **name** — `clip_applies` asks
 `has_dot_named` for every joint the template keys — and a dot placed by
 clicking has none. So a rig that is geometrically perfect plays nothing until
 someone types seventeen names, each spelled exactly as some body plan spells
 it.

 Nothing here decides what a joint is called by looking at it. `match_shapes`
 (core/joint_match.c3) pairs two skeletons on where their joints sit and which
 hangs off which, reads no name on either side, and is already what carries a
 downloaded clip's joints onto a plan's vocabulary on import. This points the
 same function at the document's own dots and writes the answer back.

 What that buys is a guess, not a fact, and it is reported as one — the count
 matched against the plan's size is the number a user needs to see, because a
 rig that filled four dots of seventeen matched nothing useful and no single
 name says so.
*>
module crig;




<*
 What an auto-naming did.

 `matched` against `total` is the coverage — how much of the plan the rig turned
 out to have — and is the pair worth showing. Both count the plan's *required*
 joints only; `extra` is the optional ones that matched as well, which on a biped
 means the fingers. `renamed` is smaller whenever a dot already carried the name
 the plan wanted, which is the ordinary result of running this twice.

 `plan` is borrowed from the pack that won, so it lives exactly as long as the
 library does: read it, print it, do not keep it across a rescan.
*>
struct AutoNaming
{
	String plan;
	usz matched;
	usz total;
	usz extra;    // optional plan joints that matched too — the fingers
	usz renamed;
	usz unnamed;  // dots the plan had no joint for, and so left alone
}

<*
 Whether the match was good enough to have been acted on.
*>
fn bool AutoNaming.usable(&self) => self.total > 0 && self.matched * 3 >= self.total * 2;

<*
 Name the document's dots after whichever body plan the rig is shaped like.

 	`AutoNaming named = app.auto_name();`
 	`if (!named.usable()) { … nothing was written … }`

 **Writes nothing unless two thirds of the plan matched.** Below that the rig is
 not that shape — it is a rig that happened to stand upright — and naming it
 anyway would ungrey clips that then play wrong, which is worse than a library
 greyed out. The result says how close it got either way, so a near miss is
 something the caller can report rather than something it has to guess at.

 One undo entry for the whole naming, the way `apply_preset` places a plan as
 one. Dots the plan has no joint for keep whatever name they had: the plan has
 no opinion about them, and a hand-named finger is not something to erase.

 **The plan tag is not part of that entry.** `doc.plan` is set here and undo
 does not take it back — the same bargain `apply_preset` makes. Re-running this,
 or applying a plan, is what changes it again.

 Candidates are the library's body plans. A document that already declares one
 is matched against that alone: a rig whose shape the user has already stated is
 not a rig to re-guess, and re-guessing it could retag a half-built biped as a
 bird.

 @return `What matched and what was written. An empty document, or a library with no body plan, comes back with a zero total.`
*>
fn AutoNaming AppState.auto_name(&self)
{
	AutoNaming named = self.auto_name_recorded();
	self.undo_stack.commit();

	self.plan_targets_stale = true;
	self.refresh_ui();
	return named;
}

<*
 The naming, recorded but not committed — for a batch that closes its own group.

 The rig does not move, so nothing is rebound and nothing is marked stale here.
 What the caller still owes is the commit, `plan_targets_stale` and a refresh;
 `auto_name` is that caller for everything but the MCP batch, which has its own.

 @return `What matched, on the same terms as auto_name. Nothing was renamed unless the match was usable.`
*>
fn AutoNaming AppState.auto_name_recorded(&self)
{
	RigView? opened = self.open_rig(mem);
	if (catch opened) return {};
	RigView view = opened;
	defer view.free(mem);

	MatchShape source = {
		.at = view.skeleton.joints,
		.parent = view.skeleton.parents,
		// Empty: a document holds no clips, so there is nothing to say about how
		// far each joint ever turns. The matcher reads a missing `moved` as "this
		// side cannot tell you", not as "nothing moves".
		.moved = {},
	};

	// A document that declares a plan is matched against that pack alone, through
	// the same lookup the plan chooser uses — so "the biped plan" means the same
	// pack here as it does there, spelling and all. Declaring one the library
	// does not hold leaves nothing to match against, which is the honest answer.
	int declared = self.doc.plan.len > 0 ? self.plan_pack(self.doc.plan) : -1;
	if (self.doc.plan.len > 0 && declared < 0) return {};

	AnimPack* winner = null;
	JointMatch best = {};
	defer best.free(mem);

	foreach (usz i, &pack : self.packs)
	{
		if (!pack.is_body_plan()) continue;
		if (declared >= 0 && i != (usz)declared) continue;

		Preset plan = pack.preset(mem);
		defer free_preset(mem, plan);

		JointMatch tried = match_preset(mem, source, plan);
		if (best.total > 0 && !tried.better_than(best))
		{
			tried.free(mem);
			continue;
		}
		best.free(mem);
		best = tried;
		winner = pack;
	}

	if (!winner) return {};

	AutoNaming result = {
		.plan = winner.plan,
		.matched = best.matched,
		.extra = best.extra,
		.total = best.total,
	};
	foreach (int dot : best.dot)
	{
		if (dot < 0) result.unnamed++;
	}
	if (!result.usable()) return result;

	// The plan is re-derived rather than held from the loop above: `pack.preset`
	// allocates, and holding the winner's copy across every later candidate's
	// allocate-and-free would be the one leak in an otherwise scoped loop.
	Preset plan = winner.preset(mem);
	defer free_preset(mem, plan);

	// `rename_recorded` does not move a dot, so the view's joint order — which is
	// BFS output and shifts the moment structure changes — stays good for the
	// whole loop. Nothing structural belongs in here.
	foreach (usz joint, int dot : best.dot)
	{
		if (dot < 0 || (usz)dot >= plan.dots.len) continue;
		if (self.rename_recorded(view.dot_ids[joint], plan.dots[(usz)dot].name)) result.renamed++;
	}

	self.doc.set_plan(winner.plan);
	return result;
}
