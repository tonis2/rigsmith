<*
 Hand-made joint matches for a library pack: the Joint mapping dialog's data.

 The automatic match (`measure_reach`) leaves some of a clip's joints with no
 joint on this rig, or pairs one wrongly. The user picks a rig joint for each,
 and the choice is stored per pack file in the document (`RigDocument.joint_maps`),
 saved in the sidecar and laid over the automatic match by `apply_joint_maps`.
*>
module crig;

import std::collections::list;

struct MappingRow
{
	String source; // owned
	usz chosen; // index into the draft's options; 0 = (none)
	usz current; // what the rig answers with now
}

struct MappingDraft
{
	int pack;
	String file; // owned
	String[] options; // owned; [0] is "(none)", then this rig's named joints
	MappingRow[] rows;
	bool all;
}

fn void MappingDraft.free(&self)
{
	self.file.free(mem);
	foreach (option : self.options) option.free(mem);
	if (self.options.len > 0) alloc::free(mem, self.options);
	foreach (row : self.rows) row.source.free(mem);
	if (self.rows.len > 0) alloc::free(mem, self.rows);
	*self = { .pack = -1 };
}

<*
 Whether the clip comes from a library pack with a skeleton to match against.
 The project's own clips are keyed in this rig's names and need no mapping.
*>
fn bool AppState.clip_mappable(&self, AnimRef ref)
{
	if (!ref.valid() || ref.pack == self.authored_pack) return false;
	AnimPack* pack = self.pack((usz)ref.pack);
	return pack && pack.joint_names.len > 0 && pack.rest.len() == pack.joint_names.len;
}

<*
 Which of the pack's joints the clip keys, as flags parallel to its joint names.
 Empty for a clip that is not read yet.
*>
fn bool[] AppState.keyed_pack_joints(&self, Allocator allocator, AnimRef ref)
{
	AnimTemplate* clip = self.clip(ref);
	AnimPack* pack = self.pack((usz)ref.pack);
	if (!clip || !pack || clip.lazy) return {};
	bool[] keyed = alloc::new_array(allocator, bool, pack.joint_names.len);
	foreach (frame : clip.keyframes) foreach (dot : frame.dots)
	{
		sz b = pack_joint_index(pack, dot.joint_name);
		if (b >= 0) keyed[(usz)b] = true;
	}
	return keyed;
}

<*
 How many joints the clip keys that no joint of this rig plays.
*>
fn usz AppState.unmatched_joints(&self, AnimRef ref)
{
	if (!self.clip_mappable(ref)) return 0;
	PackReach* reach = self.pack_reach((usz)ref.pack);
	if (!reach || reach.taken.len == 0) return 0;
	bool[] keyed = self.keyed_pack_joints(tmem, ref);
	usz missing = 0;
	foreach (usz b, flag : keyed) if (flag && b < reach.taken.len && !reach.taken[b]) missing++;
	return missing;
}

<*
 Fill the dialog's rows for the clip: the keyed joints no rig joint plays and the
 ones already matched by hand, or with `all` every joint the clip keys. Each row
 starts on what the rig plays now, or for an unplayed joint on a rig joint whose
 name reads the same (`hip_L`, `LeftHip`, `mixamorig:LeftHip`).
*>
fn bool AppState.open_mapping_draft(&self, AnimRef ref, bool all)
{
	self.mapping_draft.free();
	if (!self.clip_mappable(ref) || !self.ensure_clip_imported(ref)) return false;
	AnimPack* pack = self.pack((usz)ref.pack);
	PackReach* reach = self.pack_reach((usz)ref.pack);
	if (!pack || !reach || reach.taken.len != pack.joint_names.len) return false;

	RigView? opened = self.open_rig(mem);
	if (catch opened) return false;
	RigView view = opened;
	defer view.free(mem);

	StringList options;
	options.init(mem);
	defer options.free();
	options.push("(none)".copy(mem));
	foreach (name : view.names) if (name.len > 0) options.push(name.copy(mem));

	bool[] keyed = self.keyed_pack_joints(tmem, ref);
	List{MappingRow} rows;
	rows.init(mem);
	defer rows.free();
	foreach (usz b, source : pack.joint_names)
	{
		if (b >= keyed.len || !keyed[b]) continue;
		bool by_hand = false;
		foreach (map : self.doc.joint_maps) if (map.names_pack(pack.path) && map.source == source) by_hand = true;
		if (!all && reach.taken[b] && !by_hand) continue;

		usz current = 0;
		foreach (usz j, held : reach.names)
		{
			if (held != source || j >= view.names.len) continue;
			current = option_index(options.array_view(), view.names[j]);
			break;
		}
		usz chosen = current;
		if (chosen == 0 && !by_hand) chosen = option_index(options.array_view(), similar_joint(source, view.names, reach, pack));
		rows.push({ .source = source.copy(mem), .chosen = chosen, .current = current });
	}

	self.mapping_draft = {
		.pack = ref.pack,
		.file = pack.path.copy(mem),
		.options = options.to_array(mem),
		.rows = rows.to_array(mem),
		.all = all,
	};
	return true;
}

fn usz option_index(String[] options, String name) @local
{
	if (name.len == 0) return 0;
	foreach (usz i, option : options) if (i > 0 && option == name) return i;
	return 0;
}

<*
 A rig joint whose name reads like `source` once case, separators, a namespace
 and the side word are set aside — and that plays no pack joint yet. Empty when
 none does.
*>
fn String similar_joint(String source, String[] names, PackReach* reach, AnimPack* pack) @local
{
	char side;
	String wanted = joint_name_key(source, &side);
	if (wanted.len == 0) return "";
	foreach (usz j, name : names)
	{
		if (name.len == 0) continue;
		if (j < reach.names.len && pack_joint_index(pack, reach.names[j]) >= 0) continue;
		char other;
		if (joint_name_key(name, &other) == wanted && other == side) return name;
	}
	return "";
}

<*
 A joint name reduced to its words, lowercase and run together, with the side
 (`l`, `r` or 0) taken out: `mixamorig:LeftUpLeg` and `up_leg_L` both read
 "upleg" on the left. In tmem.
*>
fn String joint_name_key(String name, char* side) @local
{
	*side = 0;
	if (try sz colon = name.rindex_of_char(':')) name = name[colon + 1..];
	DString body = dstring::temp();
	DString word = dstring::temp();
	for (usz i = 0; i <= name.len; i++)
	{
		char c = i < name.len ? name[i] : ' ';
		bool letter = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9');
		bool upper = c >= 'A' && c <= 'Z';
		bool previous_lower = i > 0 && name[i - 1] >= 'a' && name[i - 1] <= 'z';
		if (!letter || (upper && previous_lower))
		{
			String done = word.str_view();
			if (done == "l" || done == "left") { *side = 'l'; }
			else if (done == "r" || done == "right") { *side = 'r'; }
			else { body.append(done); }
			word.clear();
			if (!letter) continue;
		}
		word.append_char(upper ? c + ('a' - 'A') : c);
	}
	return body.str_view();
}

<*
 Store the dialog's choices for its pack as one undo step. A row is kept when it
 differs from what the rig plays, or when it was already a hand match.
*>
fn bool AppState.apply_mapping_draft(&self, usz[] chosen)
{
	MappingDraft* draft = &self.mapping_draft;
	if (draft.file.len == 0) return false;
	List{JointMap} rows;
	rows.init(tmem);
	foreach (usz i, row : draft.rows)
	{
		usz pick = i < chosen.len ? chosen[i] : row.chosen;
		if (pick >= draft.options.len) pick = 0;
		bool by_hand = false;
		foreach (map : self.doc.joint_maps) if (map.names_pack(draft.file) && map.source == row.source) by_hand = true;
		if (pick == row.current && !by_hand) continue;
		rows.push({ .file = draft.file, .source = row.source, .joint = pick == 0 ? "" : draft.options[pick] });
	}
	return self.map_pack_joints(draft.file, rows.array_view());
}

<*
 Replace the hand matches of one pack file's joints named in `rows`, or with
 `reset` all of that file's. One undo step; false when nothing changes.

 @param rows : `Borrowed; copied in.`
*>
fn bool AppState.map_pack_joints(&self, String file, JointMap[] rows, bool reset = false)
{
	List{JointMap} next;
	next.init(tmem);
	foreach (map : self.doc.joint_maps)
	{
		bool replaced = reset && map.names_pack(file);
		foreach (row : rows) if (map.names_pack(file) && map.source == row.source) replaced = true;
		if (!replaced) next.push(map);
	}
	foreach (row : rows) next.push({ .file = file, .source = row.source, .joint = row.joint });
	if (joint_maps_equal(next.array_view(), self.doc.joint_maps)) return false;

	JointMap[] before = copy_joint_maps(mem, self.doc.joint_maps);
	JointMap[] after = copy_joint_maps(mem, next.array_view());
	self.doc.set_joint_maps(copy_joint_maps(mem, after));
	self.undo_stack.record_joint_maps(before, after);
	self.undo_stack.commit();
	self.reach_stale = true;
	return true;
}

fn bool joint_maps_equal(JointMap[] a, JointMap[] b) @local
{
	if (a.len != b.len) return false;
	foreach (usz i, map : a)
	{
		if (map.file != b[i].file || map.source != b[i].source || map.joint != b[i].joint) return false;
	}
	return true;
}
