<*
 Names to things, and the sentence when a name does not name anything.

 Every tool addresses the document by name — a clip, a pack, a dot — and none of
 them holds an id a caller could have. So each one starts by looking a string up,
 and the interesting half of that is the failure: an agent handed CLIP_NOT_FOUND
 retries by guessing, and an agent handed the list of clips retries by reading.
 That is why `resolve_named` takes a `detail` and `resolve_clip` does not — the
 first is for a tool answering a caller, the second for code that has somewhere
 else to put the refusal.

 The rule that runs through all of it: **an ambiguous name is an error, not a
 pick.** Two packs holding a `walk` the library cannot tell apart means the caller
 has to say which, because whichever one sorted first is not an answer to the
 question that was asked. A bare name is ranked first though — see
 `best_bare_matches` — so only a tie at the best rank is ambiguous.
*>
module crig;

import rig;
import std::collections::object;
import std::math;

faultdef CLIP_NOT_FOUND, CLIP_AMBIGUOUS;

<*
 The clip `name` asks for, either as `"Pack/Clip"` or as a name to look for
 everywhere.

 A name carrying a `/` is read as pack-and-clip first, dividing at the **last**
 one — so a pack name may not hold a slash and a clip name may. That reading is
 tried before the library-wide search rather than instead of it, which is what
 keeps a clip genuinely called `"walk/run"` reachable while no pack is called
 `"walk"`.

 Unqualified, the matches are ranked (bound to the character, then Authored, then
 packs that apply to the rig) and a tie at the best rank is CLIP_AMBIGUOUS rather
 than a quiet pick: the caller should be told to qualify, not handed whichever
 pack sorted first.
*>
fn AnimRef? resolve_clip(AppState* app, String name)
{
	usz slash = last_slash(name);
	if (slash + 1 < name.len)
	{
		AnimRef? qualified = resolve_in_pack(app, name[:slash], name[slash + 1..]);
		// A resolved clip is about to be read or sampled by whichever tool asked
		// for it — read its curves now if the pack deferred them.
		if (try qualified) { app.ensure_clip_imported(qualified); return qualified; }
	}
	AnimRef? anywhere = resolve_in_pack(app, "", name);
	if (try anywhere) app.ensure_clip_imported(anywhere);
	return anywhere;
}

<*
 Where the pack name stops in a `"Pack/Clip"` argument, or `name.len` when there
 is no `/` to divide it — which also makes `slash + 1 < name.len` the test for
 "there is a clip name after it", with no separate empty case to carry.
*>
fn usz last_slash(String name) @local => (usz)(name.rindex_of_char('/') ?? name.len);

// The clip called `clip_name` in the pack called `pack_name`, or — when `pack_name`
// is empty — the best-ranked clip of that name anywhere, if one outranks the rest.
// Two packs may carry the same display name (two files whose extras agree), so a
// qualified lookup counts matches rather than taking the first; a bare one ranks
// them, see `best_bare_matches`.
fn AnimRef? resolve_in_pack(AppState* app, String pack_name, String clip_name) @local
{
	if (pack_name.len == 0)
	{
		AnimRef[] best = best_bare_matches(app, clip_name);
		if (best.len == 0) return CLIP_NOT_FOUND~;
		if (best.len > 1) return CLIP_AMBIGUOUS~;
		return best[0];
	}

	AnimRef found = NO_ANIM;
	foreach (p, pack : app.packs)
	{
		if (pack.name != pack_name) continue;
		foreach (c, clip : pack.clips)
		{
			if (clip.name != clip_name) continue;
			if (found.valid()) return CLIP_AMBIGUOUS~;
			found = { (int)p, (int)c };
		}
	}
	if (!found.valid()) return CLIP_NOT_FOUND~;
	return found;
}

<*
 The clips called `name`, across the whole library, narrowed to the best rank.

 A bare name that several packs hold ("Walk" in the humanoid pack, in the model's
 own file and in Authored) used to be an error. It is ranked now, best first:

 1. the clip **bound to the character** — the one the Animations pane lists,
 2. the **Authored** pack — what was written in this project,
 3. a pack whose clip **applies to the rig** (`clip_applies`),
 4. anything else.

 Only a tie at the best rank is still ambiguous, and the tied clips are what comes
 back, so the caller can say which packs to choose between. Empty when nothing has
 the name. The array is on the temp allocator.
*>
fn AnimRef[] best_bare_matches(AppState* app, String name) @local
{
	usz count = 0;
	foreach (pack : app.packs)
	{
		foreach (clip : pack.clips) if (clip.name == name) count++;
	}
	if (count == 0) return {};

	AnimRef[] hits = alloc::new_array(tmem, AnimRef, (sz)count);
	usz at = 0;
	foreach (p, pack : app.packs)
	{
		foreach (c, clip : pack.clips) if (clip.name == name) hits[at++] = { (int)p, (int)c };
	}
	if (count == 1) return hits;

	// Resolved before anything is ranked: resolving a binding may read a pack in
	// and reallocate the array the walk above stood on.
	usz bound_count = (usz)app.doc.animations.len();
	AnimRef[] bound = alloc::new_array(tmem, AnimRef, (sz)bound_count);
	for (usz i = 0; i < bound_count; i++) bound[i] = app.resolve_bound((sz)i);

	int[] ranks = alloc::new_array(tmem, int, (sz)count);
	int best_rank = 4;
	foreach (i, hit : hits)
	{
		int rank = 3;
		foreach (b : bound) if (b.valid() && b.pack == hit.pack && b.clip == hit.clip) rank = 0;
		if (rank == 3 && hit.pack == app.authored_pack) rank = 1;
		if (rank == 3 && app.clip_applies(hit)) rank = 2;
		ranks[i] = rank;
		best_rank = math::min(best_rank, rank);
	}

	usz kept = 0;
	foreach (i, hit : hits)
	{
		if (ranks[i] == best_rank) hits[kept++] = hit;
	}
	return hits[:kept];
}

<*
 `resolve_clip`, with the refusal spelled out for a caller that cannot see the
 library.

 A name that matches nothing lists the clips there are: the usual cause is a
 spelling, or a clip the caller believes it wrote and did not. A name that
 matches in more than one pack names those packs and says to qualify it.

 A name that was *already* qualified and still missed is the case worth care:
 the miss is in one half or the other, and a sentence that does not say which
 sends the caller to re-read the wrong list.

 @param detail : `Filled with the reason when this faults; untouched otherwise.`
 @return? CLIP_NOT_FOUND : `No clip in the library answers to this name.`
 @return? CLIP_AMBIGUOUS : `More than one does, and the name given does not tell them apart.`
*>
fn AnimRef? resolve_named(AppState* app, String name, DString* detail)
{
	AnimRef? found = resolve_clip(app, name);
	if (try found) return found;

	usz slash = last_slash(name);
	if (slash + 1 < name.len)
	{
		String pack_name = name[:slash];
		String clip_name = name[slash + 1..];

		usz named_packs = 0;
		usz holders = 0;
		foreach (pack : app.packs)
		{
			if (pack.name != pack_name) continue;
			named_packs++;
			foreach (clip : pack.clips)
			{
				if (clip.name == clip_name) holders++;
			}
		}

		if (named_packs == 0)
		{
			// Both readings named, because both were tried: a caller who meant to
			// qualify wants the pack list, and one whose clip really carries a
			// slash wants to know the whole string missed too.
			detail.appendf(`no pack is called "%s", and no clip is called "%s". The library holds packs: `, pack_name, name);
			append_pack_names(detail, app);
			return CLIP_NOT_FOUND~;
		}
		if (holders > 1)
		{
			detail.appendf(`%d packs are called "%s" and hold a clip called "%s" between them, so the pair names neither. Rename one of the files.`, named_packs, pack_name, clip_name);
			return CLIP_AMBIGUOUS~;
		}
		detail.appendf(`pack "%s" holds no clip called "%s". It holds: `, pack_name, clip_name);
		append_pack_clip_names(detail, app, pack_name);
		return CLIP_NOT_FOUND~;
	}

	usz total = 0;
	foreach (pack : app.packs) total += pack.clips.len;

	AnimRef[] tied = best_bare_matches(app, name);
	if (tied.len > 1)
	{
		detail.appendf(`%d clips are called "%s", in packs `, tied.len, name);
		foreach (i, tie : tied)
		{
			if (i > 0) detail.append_string(", ");
			detail.append_char('"');
			detail.append_string(app.packs[(usz)tie.pack].name);
			detail.append_char('"');
		}
		detail.append_string(`, and none outranks the others. A bare name prefers the clip bound to the character, then the Authored pack, then a pack that fits the rig; these tie, so ask for it as "Pack/Clip".`);
		return CLIP_AMBIGUOUS~;
	}

	if (total == 0)
	{
		detail.appendf(`no clip is called "%s", and the library is empty. apply_clip is how a clip gets into it.`, name);
		return CLIP_NOT_FOUND~;
	}

	detail.appendf(`no clip is called "%s". The library holds: `, name);
	append_clip_names(detail, app);
	return CLIP_NOT_FOUND~;
}

<*
 Why `play_clip` said no. It answers with a bool, and everything the caller can
 do next is in the reason.

 Asked in the order play_clip asks them, so the sentence names the first thing
 that stopped it rather than the last.
*>
fn void explain_refusal(DString* detail, AppState* app, AnimRef ref) @private
{
	AnimTemplate* template = app.clip(ref);
	AnimPack* pack = app.pack((usz)ref.pack);
	if (!template || !pack) return;

	if (app.doc.dots.len() == 0)
	{
		detail.appendf(`there is no rig to play "%s" on: this document has no dots, and pack "%s" carries none to fit one from. Place a rig first — a body plan does it in one step.`, template.name, pack.name);
		return;
	}

	if (!app.pack_matches((usz)ref.pack))
	{
		detail.appendf(`"%s" is in pack "%s", which is written for the "%s" body plan, and this rig declares "%s". A clip is only offered to the plan it was written for.`, template.name, pack.name, pack.plan, app.doc.plan);
		return;
	}

	if (!app.clip_applies(ref))
	{
		detail.appendf(`"%s" names no joint this rig has. It turns: `, template.name);
		append_clip_joints(detail, template);
		detail.append_string(". get_skeleton lists the dots that are placed and the names they carry.");
		return;
	}

	// Everything visible from here is in order, so the refusal came from inside
	// the player — a rig it could not build, or a mesh it could not skin. Both
	// leave a sentence in the notice the user is already looking at.
	detail.appendf(`crig would not start "%s": %s`, template.name, app.notice());
}

// Every clip in the library, for a refusal that has to say what could have been
// asked for instead.
fn void append_clip_names(DString* out, AppState* app) @local
{
	usz total = 0;
	foreach (pack : app.packs) total += pack.clips.len;

	NameList list = { .out = out, .total = total };
	foreach (pack : app.packs)
	{
		foreach (clip : pack.clips)
		{
			if (!list.next()) return;
			out.append_string(clip.name);
		}
	}
}

// Every pack in the library, for a refusal about the half of "Pack/Clip" that
// names a pack.
fn void append_pack_names(DString* out, AppState* app) @local
{
	NameList list = { .out = out, .total = (usz)app.packs.len() };
	foreach (pack : app.packs)
	{
		if (!list.next()) return;
		out.append_string(pack.name);
	}
	if (list.shown == 0) out.append_string("none at all");
}

// One named pack's clips. Every pack of that name, since two files may carry
// one — a caller told "it holds" wants what all of them hold.
fn void append_pack_clip_names(DString* out, AppState* app, String pack_name) @local
{
	NameList list = { .out = out };
	foreach (pack : app.packs)
	{
		if (pack.name != pack_name) continue;
		foreach (clip : pack.clips)
		{
			if (!list.next()) return;
			out.append_string(clip.name);
		}
	}
	if (list.shown == 0) out.append_string("no clips at all");
}

// The joints a clip turns, once each rather than once per keyframe.
fn void append_clip_joints(DString* out, AnimTemplate* clip) @private
{
	NameList list = { .out = out };
	foreach (f, frame : clip.keyframes)
	{
		foreach (d, dot : frame.dots)
		{
			if (named_earlier(clip, f, d, dot.joint_name)) continue;
			if (!list.next()) return;
			out.append_string(dot.joint_name);
		}
	}
	if (list.shown == 0) out.append_string("nothing at all");
}

<*
 The dot a weight tool was pointed at, by the name `get_skeleton` reports.

 `bone_<id>` is a valid address here, and that is not an oversight: a clip
 addresses a dot by the name it carries and an unnamed one carries none, but a
 survey reads the bind, and an unnamed dot is bound exactly like the rest.

 @return? WEIGHTS_BAD_ARGS : `Nothing answers to that name; detail lists what does.`
*>
fn uint? resolve_dot(AppState* app, String name, DString* detail)
{
	if (name.len > 5 && name[:5] == "bone_")
	{
		uint id = 0;
		bool digits = true;
		foreach (c : name[5..])
		{
			if (c < '0' || c > '9')
			{
				digits = false;
				break;
			}
			id = id * 10 + (uint)(c - '0');
		}
		if (digits && app.doc.find(id)) return id;
	}

	if (Dot* dot = app.dot_named(name)) return dot.id;

	detail.appendf(`no dot on this rig answers to "%s"`, name);
	append_dot_names(detail, app);
	return WEIGHTS_BAD_ARGS~;
}

<*
 Every dot that can be pointed at, for a refusal to end on.

 Unnamed dots included, as `bone_<id>`: they are addressable by the weight tools,
 so leaving them out would be advice that misses half the rig.
*>
fn void append_dot_names(DString* out, AppState* app)
{
	if (app.doc.dots.len() == 0)
	{
		out.append_string(". This rig has no dots at all — get_scene says whether a model is even loaded.");
		return;
	}

	out.append_string(". Dots: ");
	NameList list = { .out = out, .total = (usz)app.doc.dots.len() };
	foreach (dot : app.doc.dots.array_view())
	{
		if (!list.next()) break;
		append_bone_label(out, dot.id, dot.name);
	}
}
