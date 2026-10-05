<*
 save_pack: the authored clips, written into the library as a file.

 Publishes reusable clips into a library file and reads that file back. Project
 Save separately preserves the editable authored keys in the session sidecar;
 publishing leaves those copies, their bindings and their undo history intact.

 It takes no path. The caller names the pack and the file name is derived from it,
 because a tool that accepted a path would be a tool that could write anywhere —
 and the refusals are the interesting part of the file: a pack with no body can
 never be fitted as a body plan, and a plan whose optional list is wrong guesses
 forty knuckles onto a model that has none. Both are explained rather than
 rejected.

 **Clips are not required.** A pack carrying a body is a body plan whether or not
 anything has been animated on it, which is the case a fresh model rigged by hand
 with `edit_rig` is in — and demanding a clip first would mean authoring an
 animation for a figure nobody has animated yet just to get the plan written.
 The one save still refused is the one that would carry neither.
*>
module crig;

import rig;
import std::collections::object;

faultdef SAVE_REFUSED;

<*
 save_pack: the authored clips, written into the library as a pack file.

 The path is not an argument and will not become one. This surface is bound to
 loopback with no authentication, so a caller choosing where crig writes is a
 caller choosing any file on the machine — the name is turned into one file name
 inside the folder the library was read from, and every character that could
 steer it somewhere else is replaced.

 Refusals are checked here rather than left to `save_authored_pack`'s faults,
 because "a dot has no name" is only useful to a caller that is told which dot.
*>
fn String? tool_save_pack(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;

	if (!takes_object(args, detail, `save_pack takes an object: {"name": pack name, "plan": body-plan tag}`)) return SAVE_REFUSED~;

	String name;
	if (!required_string(args, "name", &name, detail, `save_pack needs "name": what the pack is called in the library. The file name is derived from it.`)) return SAVE_REFUSED~;

	PackBody body = NONE;
	if (member(args, "body") != null)
	{
		String? asked = args.get_string("body");
		if (catch asked)
		{
			detail.append_string(`save_pack's "body" must be the string "none", "dummy" or "mesh"`);
			return SAVE_REFUSED~;
		}
		switch (asked)
		{
			// Spelled out rather than left empty: an empty case falls through.
			case "none": body = NONE;
			case "dummy": body = DUMMY;
			case "mesh": body = MESH;
			default:
				detail.appendf(
					`save_pack's "body" is "%s". It is "none" — no body, the default, and a pack with none can be played but never fitted as a body plan — or "dummy", a stand-in built around this rig, or "mesh", the model that is loaded.`,
					asked);
				return SAVE_REFUSED~;
		}
	}
	if (body == MESH && !app.has_mesh())
	{
		detail.append_string(`"body":"mesh" writes the loaded model into the pack, and nothing is loaded. Open a model, or ask for "dummy" — a stand-in built around the rig itself.`);
		return SAVE_REFUSED~;
	}

	DString slug = dstring::new(mem);
	defer slug.free();
	if (!append_slug(&slug, name))
	{
		detail.appendf(`"%s" has no letter or digit in it, so there is no file name to derive from it.`, name);
		return SAVE_REFUSED~;
	}

	if (app.library_path.len == 0)
	{
		detail.append_string("the animation library has not been read, so there is no folder to save a pack into.");
		return SAVE_REFUSED~;
	}

	String file = string::format(mem, "%s.glb", slug.str_view());
	defer alloc::free(mem, file.ptr);
	String path = string::format(mem, "%s/%s", app.library_path, file);
	defer alloc::free(mem, path.ptr);

	// A body with no clips is a body plan and is written; what is refused is a
	// file that would hold neither — see `AppState.save_authored_pack`. The
	// refusal names both ways out, because a caller who has just rigged a model
	// by hand has done nothing wrong and only needs to say what the file carries.
	AnimPack* authored = app.authored();
	usz written = authored ? authored.clips.len : 0;
	if (written == 0 && body == NONE)
	{
		detail.append_string(`nothing has been authored and no body was asked for, so the file would hold neither a clip to play nor a body to fit. apply_clip writes a clip into the Authored pack; "body":"mesh" writes the loaded model, and "body":"dummy" a stand-in built around this rig — either one makes the rig you have placed a body plan in its own right.`);
		return SAVE_REFUSED~;
	}

	if (!append_unnamed_dots(detail, app))
	{
		return SAVE_REFUSED~;
	}

	// Saving into a pack that exists adds to it, so there is nothing to guard
	// against there — except a body. A save that writes none over one is not
	// merely losing a file: every untagged pack in the library is matched against
	// the ones that have a body, so it takes the reference rig those are read
	// through with it. Asking for a body is the way past this, and the refusal
	// says so rather than only saying no.
	AnimPack* standing = null;
	foreach (&held : app.packs)
	{
		if (held.path == path) standing = held;
	}
	if (standing && standing.is_body_plan() && body == NONE)
	{
		detail.appendf(`"%s" is the file behind the "%s" body plan, which other packs are matched against, and this would write no body over it — leaving the library without that plan. Ask for "body":"mesh" or "body":"dummy" to write one, or choose another name.`, file, standing.name);
		return SAVE_REFUSED~;
	}

	// An existing pack's own tag unless the caller says otherwise: a re-save that
	// quietly untagged a pack would change which rigs are offered its clips.
	String plan = standing ? standing.plan : app.doc.plan;
	if (try given_plan = args.get_string("plan")) plan = given_plan;

	// Borrowed on both branches — from the JSON document, which outlives the call,
	// or from the standing pack, which is only freed by the re-read `save_authored_pack`
	// does after the file is written. Only the array is ours.
	String[] optional = {};
	defer if (optional.len > 0) alloc::free(mem, optional);
	if (!read_optional(app, args, standing, &optional, detail)) return SAVE_REFUSED~;

	int? saved = app.save_authored_pack(file, name, plan, standing ? standing.tags : (String[]){}, body, optional);
	if (catch error = saved)
	{
		detail.appendf(`could not write %s: %s`, path, error);
		return SAVE_REFUSED~;
	}
	if (saved < 0)
	{
		detail.appendf(`%s was written, but re-reading the library found no pack there. The file is on disk and crig cannot see it as one.`, path);
		return SAVE_REFUSED~;
	}

	app.refresh_ui();
	return saved_json(app, saved, path, written, body);
}

<*
 What `save_pack` answers with: where the clips went, and what came back.

 `clips` is read off the reloaded pack rather than off what was handed to the
 writer, so it describes the file. A list shorter than `saved` is a clip that did
 not survive the round trip, which is the one failure this operation can have
 without erroring.

 @param written : `How many clips the authored pack held before the save — the pack itself is gone by the time this runs.`
*>
fn String saved_json(AppState* app, int index, String path, usz written, PackBody body)
{
	AnimPack* pack = app.pack((usz)index);

	DString out = dstring::new(mem);
	defer out.free();

	out.append_string(`{"pack":"`);
	json_escape_into(&out, pack.name);
	out.append_string(`","file":"`);
	json_escape_into(&out, path);
	out.append_string(`","plan":"`);
	json_escape_into(&out, pack.plan);
	out.append_string(`","saved":`);
	out.appendf("%d", written);
	out.append_string(`,"clips":[`);
	foreach (c, clip : pack.clips)
	{
		if (c > 0) out.append_char(',');
		out.append_char('"');
		json_escape_into(&out, clip.name);
		out.append_char('"');
	}
	out.append_string(`],"playing":`);
	out.append_string(app.animating ? "true" : "false");

	// Read back off the file rather than off the argument: what the pack turned
	// out to be is the answer, and a body that was asked for and did not survive
	// the round trip would otherwise be reported as present.
	out.append_string(`,"vertices":`);
	out.appendf("%d", pack.mesh.positions.len);
	out.append_string(`,"body_plan":`);
	out.append_string(pack.is_body_plan() ? "true" : "false");

	// Also off the file, and for the same reason: the count is how a caller sees
	// that a list it sent survived the write, and how one that sent none finds out
	// that every joint will be placed on every model this plan is fitted to.
	usz spare = 0;
	foreach (marked : pack.joint_optional)
	{
		if (marked) spare++;
	}
	out.append_string(`,"optional":`);
	out.appendf("%d", spare);

	// A pack that declares a plan and carries no body is legal and nearly always
	// a mistake — it will be offered to rigs of that plan and can never fit one.
	// Said here rather than refused, because a clip file written for a plan the
	// library already has a body for is the case where it is right.
	if (body == NONE && pack.plan.len > 0 && !pack.is_body_plan())
	{
		out.append_string(`,"note":"this pack declares a plan and carries no body, so it can be played on a rig of that plan but can never fit one. Save again with \"body\":\"dummy\" or \"body\":\"mesh\" to make it a plan in its own right."`);
	}
	out.append_char('}');

	return out.copy_str(mem);
}

// How much of a pack name reaches the file name. Long enough to stay legible,
// short enough that no filesystem argues about it.
const usz SLUG_LIMIT @local = 48;

<*
 A pack name reduced to something safe to use as a file name.

 Letters, digits, dashes and underscores survive; everything else becomes an
 underscore, which is what makes a name arriving over a socket unable to steer
 the write anywhere — a separator or a dot cannot reach the string this builds.
 Length is capped for the same reason a file name is: the caller names a pack,
 not a path.

 @return `False when nothing recognisable was left, which is not a file name.`
*>
fn bool append_slug(DString* out, String name) @local
{
	bool solid = false;
	foreach (char c : name)
	{
		if (out.len() >= (sz)SLUG_LIMIT) break;
		bool alnum = ascii::is_alnum(c);
		if (alnum) solid = true;
		out.append_char(alnum || c == '-' || c == '_' ? c : '_');
	}
	return solid;
}

<*
 Which joints the saved pack marks optional: the caller's list, or the one the
 pack being written over already carried.

 **Silence and an empty array mean different things here**, which is unusual
 enough in this surface to be worth stating. `save_pack` is additive — a second
 save into the same file keeps its clips, its tag and its tags — and a list that
 vanished because nobody mentioned it would quietly turn forty finger joints back
 into ones every fitted rig is given. So omitting the key carries the standing
 pack's list across, and `[]` is how a caller says it means none.

 Every name is checked against the live rig. A pack marks its own joints optional
 and nothing else can be there, so an unrecognised one is a misspelling that would
 otherwise be written into the file and only show up as a finger being placed on a
 model years later.

 The returned array is the caller's to free; the strings inside it are borrowed.

 @return `False when something was refused, with the reason left in detail.`
*>
fn bool read_optional(AppState* app, Object* args, AnimPack* standing, String[]* out, DString* detail) @local
{
	Object* listed = member(args, "optional");
	if (listed == null)
	{
		if (!standing) return true;

		usz spare = 0;
		foreach (marked : standing.joint_optional)
		{
			if (marked) spare++;
		}
		if (spare == 0) return true;

		String[] kept = alloc::new_array(mem, String, (sz)spare);
		usz next = 0;
		foreach (usz j, marked : standing.joint_optional)
		{
			if (marked && j < standing.joint_names.len) kept[next++] = standing.joint_names[j];
		}
		if (next == 0)
		{
			alloc::free(mem, kept);
			return true;
		}
		*out = kept[:next];
		return true;
	}

	// `[]` first, because it does not parse as an array. The stdlib's Object only
	// learns it is a list from the first element pushed into it, so an empty one
	// arrives as the same shapeless empty value `{}` does and `is_array` says no.
	// Both mean nothing is listed, which is precisely what an explicit empty list
	// says here, so both are taken rather than refused for their punctuation.
	if (listed.is_empty()) return true;

	if (!listed.is_array())
	{
		detail.append_string(`save_pack's "optional" is an array of dot names — the joints a plan fitted from this pack may leave unplaced, which is what fingers are. Pass [] to mark none.`);
		return false;
	}

	usz count = (usz)listed.get_len();
	if (count == 0) return true;

	String[] names = alloc::new_array(mem, String, (sz)count);
	for (usz i = 0; i < count; i++)
	{
		String? given = listed.get_string_at((sz)i);
		if (catch given)
		{
			alloc::free(mem, names);
			detail.appendf(`save_pack's "optional"[%d] is not a string. Every entry is a dot name, as get_skeleton reports it.`, i);
			return false;
		}
		if (!app.has_dot_named(given))
		{
			alloc::free(mem, names);
			detail.appendf(
				`"%s" is marked optional and this rig has no dot of that name, so it would be written into the pack addressing nothing. get_skeleton lists the names this rig carries; the list is spelled the way they are, not the way another rig spells them.`,
				given);
			return false;
		}
		names[i] = given;
	}
	*out = names;
	return true;
}

<*
 Whether every joint the pack would carry has a name, and the sentence when not.

 A pack keys its clips on joint names, so one blank name is a joint no clip can
 ever address and `export_pack_glb` refuses the whole file for it. Named here
 rather than left to that fault: a caller cannot see the rig, and "a dot has no
 name" without saying which is a refusal it can only answer by guessing.

 @return `False when the pack cannot be written, with the reason left in detail.`
*>
fn bool append_unnamed_dots(DString* detail, AppState* app) @local
{
	if (app.doc.dots.len() == 0)
	{
		detail.append_string("this document has no dots, so the pack would carry no skeleton for its clips to address.");
		return false;
	}

	usz blank = 0;
	foreach (dot : app.doc.dots.array_view())
	{
		if (dot.name.len == 0) blank++;
	}
	if (blank == 0) return true;

	detail.appendf("%d dot%s no name, and a pack addresses joints by name: ", blank, blank == 1 ? " has" : "s have");
	NameList list = { .out = detail, .total = blank };
	foreach (dot : app.doc.dots.array_view())
	{
		if (dot.name.len > 0) continue;
		if (!list.next()) break;
		detail.appendf("bone_%d", dot.id);
	}
	detail.append_string(". Name them, or delete the ones that are not joints, and save again.");
	return false;
}
