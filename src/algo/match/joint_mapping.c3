<* The pure half of src/app/joint_mapping.c3: no state, undo or notices. *>
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

fn usz option_index(String[] options, String name)
{
	if (name.len == 0) return 0;
	foreach (usz i, option : options) if (i > 0 && option == name) return i;
	return 0;
}

<*
 A joint name reduced to its words, lowercase and run together, with the side
 (`l`, `r` or 0) taken out: `armature:LeftUpLeg` and `up_leg_L` both read
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

fn bool joint_maps_equal(JointMap[] a, JointMap[] b)
{
	if (a.len != b.len) return false;
	foreach (usz i, map : a)
	{
		if (map.file != b[i].file || map.source != b[i].source || map.joint != b[i].joint) return false;
	}
	return true;
}

<*
 A rig joint whose name reads like `source` once case, separators, a namespace
 and the side word are set aside — and that plays no pack joint yet. Empty when
 none does.
*>
fn String similar_joint(String source, String[] names, PackReach* reach, AnimPack* pack)
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
