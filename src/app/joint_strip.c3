<*
 Taking chosen joints out of a clip: **Remove joint animation** drops their keys,
 **Move joints to layer** lifts them into a layer of their own.

 	`app.remove_joint_animation(app.editing);   // the tail holds its rest pose`
 	`app.move_joints_to_layer(app.editing);     // the tail plays from layer "tail_1 motion"`

 Both act on the viewport selection the way a layer mask does: each selected
 joint **and everything below it**, so picking the first tail joint takes the
 whole tail. Both are one undo step, through the same doors every key edit uses.

 Remove follows the key editors' rule about where it writes: the base keys, or
 the active keyed layer's when one is chosen in the layer strip. Move always
 lifts from the base, and puts the new layer at the bottom of the stack so the
 pose stays exactly what it was (anim/keying.c3 `clip_with_joints_layered`).
*>
module crig;

import rig;

<*
 The joints the selection covers in this clip's vocabulary: every selected dot
 and every joint below one, in rig order. Unnamed joints are left out, since no
 clip can address them.

 @param roots : `When given, receives the covered joints whose parent is not covered — what a layer mask lists. The caller frees it and its names.`
 @param covered : `When given, receives one flag per rig joint. The caller frees it.`
 @param picked : `One flag per rig joint to start from instead of the viewport selection — the joints an MCP call names.`
 @return `Owned by the caller, names and all.`
*>
fn String[] AppState.covered_joint_names(&self, Allocator allocator, RigView* view, AnimRef ref,
	String[]* roots = null, bool[]* covered = null, bool[] picked = {})
{
	String[] names = self.names_for(view, ref);
	usz count = view.len();
	bool[] under = alloc::new_array(allocator, bool, (sz)count);
	// Whether a named joint at or above this one is covered: a mask entry already
	// takes this joint with it.
	bool[] named_above = alloc::new_array(mem, bool, (sz)count);
	defer alloc::free(mem, named_above);
	StringList out;
	out.init(mem);
	defer out.free();
	StringList tops;
	tops.init(mem);
	defer tops.free();
	for (usz j = 0; j < count; j++)
	{
		int parent = view.skeleton.parents[j];
		bool chosen = picked.len > 0 ? j < picked.len && picked[j]
			: j < view.dot_ids.len && self.is_selected(view.dot_ids[j]);
		under[j] = chosen || (parent >= 0 && under[(usz)parent]);
		String name = j < names.len ? names[j] : "";
		bool inherited = parent >= 0 && named_above[(usz)parent];
		named_above[j] = under[j] && (inherited || name.len > 0);
		if (!under[j] || name.len == 0) continue;
		out.push(name);
		if (!inherited) tops.push(name);
	}
	if (roots)
	{
		*roots = alloc::new_array(allocator, String, (sz)tops.len());
		foreach (usz i, name : tops.array_view()) (*roots)[i] = name.copy(allocator);
	}
	if (covered) { *covered = under; } else { alloc::free(allocator, under); }
	String[] joints = alloc::new_array(allocator, String, (sz)out.len());
	foreach (usz i, name : out.array_view()) joints[i] = name.copy(allocator);
	return joints;
}

fn void free_names(Allocator allocator, String[] names)
{
	foreach (name : names) if (name.len > 0) alloc::free(allocator, name.ptr);
	if (names.len > 0) alloc::free(allocator, names);
}

<*
 "tail_1", "tail_1 and the 11 joints below it", "tail_1, ear_L and the 4 joints
 below them": the covered joints said the short way, for a notice or a question.
 Temp-allocated.
*>
fn String covered_joints_phrase(String[] roots, usz count)
{
	if (roots.len == 0) return "";
	DString text = dstring::temp();
	text.append(roots[0]);
	if (roots.len > 1) text.appendf(roots.len == 2 ? " and %s" : ", %s", roots[1]);
	if (roots.len > 2) text.appendf(" and %d more", roots.len - 2);
	usz below = count > roots.len ? count - roots.len : 0;
	if (below > 0)
	{
		text.appendf(" and the %d joint%s below %s", below, below == 1 ? "" : "s", roots.len == 1 ? "it" : "them");
	}
	return text.str_view();
}

<*
 What the joints this clip covers are called, for the Remove question: the
 phrase and the count, or zero with a notice when nothing is selected.
*>
fn usz AppState.covered_joints_summary(&self, AnimRef ref, String* phrase)
{
	*phrase = "";
	RigView? opened = self.open_rig(mem);
	if (catch opened) return 0;
	RigView view = opened;
	defer view.free(mem);
	String[] roots;
	String[] joints = self.covered_joint_names(mem, &view, ref, &roots);
	defer
	{
		free_names(mem, joints);
		free_names(mem, roots);
	}
	*phrase = covered_joints_phrase(roots, joints.len);
	return joints.len;
}

// The clip, or the layer of it, that Remove writes to — for the question and
// the notice. Temp-allocated.
fn String AppState.key_target_label(&self, AnimRef ref)
{
	AnimTemplate* clip = self.clip(ref);
	if (!clip) return "";
	AnimLayer* layer = self.keyed_layer_of(ref);
	return layer ? string::tformat("layer \"%s\" of %s", layer.name, clip.name) : clip.name.tcopy();
}

<*
 Drop every key of the selected joints and the joints below them, from the base
 keys or, with a keyed layer active, from that layer.

 Says when something will still move them: another layer of the clip, or a
 secondary-motion chain, which swings a tail at playback whatever its keys say.

 @return `False when nothing was removed; a notice says why.`
*>
fn bool AppState.remove_joint_animation(&self, AnimRef ref)
{
	if (!self.ensure_clip_imported(ref)) return false;
	AnimTemplate* clip = self.key_clip(ref);
	if (!clip) return false;
	RigView? opened = self.open_rig(mem);
	if (catch opened)
	{
		self.@notice("there is no rig to pick joints on");
		return false;
	}
	RigView view = opened;
	defer view.free(mem);
	String[] roots;
	bool[] covered;
	String[] joints = self.covered_joint_names(mem, &view, ref, &roots, &covered);
	defer
	{
		free_names(mem, joints);
		free_names(mem, roots);
		alloc::free(mem, covered);
	}
	String label = self.key_target_label(ref);
	if (joints.len == 0)
	{
		self.@notice("select a joint first: it and every joint below it lose their keys");
		return false;
	}
	String phrase = covered_joints_phrase(roots, joints.len);
	AnimTemplate? stripped = clip_without_joints(mem, *clip, joints);
	if (catch why = stripped)
	{
		if (why == STRIP_NOTHING_KEYED)
		{
			self.@notice("%s has no keys on %s", label, phrase);
		}
		else
		{
			self.@notice(self.keyed_layer_of(ref)
				? "%s is everything %s keys — delete the layer instead"
				: "%s is everything %s animates — remove the animation itself instead", phrase, label);
		}
		return false;
	}

	// Asked before landing: the stack and the chains are the clip's and the rig's
	// as they are now.
	String still = "";
	AnimTemplate* whole = self.clip(ref);
	if (whole && !self.keyed_layer_of(ref))
	{
		String[] names = self.names_for(&view, ref);
		foreach (&layer : whole.layers)
		{
			if (!layer.drives_any(mem, &view.skeleton, names, covered)) continue;
			still = string::tformat(" · layer \"%s\" still moves them", layer.name);
			break;
		}
	}
	foreach (chain : self.doc.secondary.array_view())
	{
		sz root = array::index_of(view.dot_ids, chain.root) ?? -1;
		sz tip = array::index_of(view.dot_ids, chain.tip) ?? -1;
		if ((root >= 0 && covered[(usz)root]) || (tip >= 0 && covered[(usz)tip]))
		{
			still = string::tformat("%s · secondary motion still swings them at playback", still);
			break;
		}
	}

	AnimRef landed = self.land_key_edit(ref, stripped);
	if (!landed.valid()) return false;
	self.editing = landed;
	self.@notice("removed the animation of %s from %s; they hold their rest pose%s · Ctrl+Z brings it back",
		phrase, label, still);
	return true;
}

<*
 Lift the keys of the selected joints, and the joints below them, out of the
 clip's base into a new keyed override layer, which becomes the active one. The
 clip looks exactly as it did; the motion can now be muted, weighed, edited or
 deleted on its own.

 @param picked : `One flag per rig joint to start from instead of the selection, as covered_joint_names takes.`
 @param name : `The new layer's name; empty names it after the first joint, "<joint> motion".`
 @return `The new layer's index (0, the bottom of the stack), or -1 when nothing moved; a notice says why.`
*>
fn sz AppState.move_joints_to_layer(&self, AnimRef ref, bool[] picked = {}, String name = "")
{
	if (!self.ensure_clip_imported(ref)) return -1;
	AnimTemplate* clip = self.clip(ref);
	if (!clip) return -1;
	RigView? opened = self.open_rig(mem);
	if (catch opened)
	{
		self.@notice("there is no rig to pick joints on");
		return -1;
	}
	RigView view = opened;
	defer view.free(mem);
	String[] roots;
	String[] joints = self.covered_joint_names(mem, &view, ref, &roots, picked: picked);
	defer
	{
		free_names(mem, joints);
		free_names(mem, roots);
	}
	if (joints.len == 0)
	{
		self.@notice("select a joint first: it and every joint below it move to the layer");
		return -1;
	}
	String phrase = covered_joints_phrase(roots, joints.len);
	String called = self.unused_layer_name(clip, name.len > 0 ? name : string::tformat("%s motion", roots[0]));
	defer called.free(mem);
	AnimTemplate? built = clip_with_joints_layered(mem, *clip, joints, roots, called);
	if (catch why = built)
	{
		if (why == STRIP_NOTHING_KEYED)
		{
			self.@notice("%s has no keys on %s to move", clip.name, phrase);
		}
		else
		{
			self.@notice("%s is everything %s animates, so there is nothing to lift it off", phrase, clip.name);
		}
		return -1;
	}
	AnimRef landed = self.land_layered(ref, built);
	if (!landed.valid()) return -1;
	self.set_active_layer(landed, 0);
	self.@notice("%s now plays from layer \"%s\" — mute or delete it to still them · Ctrl+Z undoes the move",
		phrase, called);
	return 0;
}
