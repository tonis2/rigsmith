<*
 The session file: everything needed to reopen a rig next time (B7).

 `<mesh-stem>.rigsmith.json`, beside the mesh — the same rule the export follows,
 because crig is started with a path and everything it produces belongs where
 the question came from. One object:

     { "version": 19, "mesh": "goat.glb", "root": 3, "next_id": 17,
       "auto_connect": true, "sym_x": 0.42, "plan": "biped",
       "sharpness": 2.5, "skin_from_file": true,
       "dots": [{"id": 1, "position": [x, y, z], "reach": 0.4}, ...],
       "edges": [[a, b], ...],
       "attachments": [[shell, dot_id], ...],
       "paint": [[vertex, dot_id, factor], ...],
       "pins": [[vertex, dot_id, share], ...],
       "secondary": [{"root": 3, "tip": 5, "preset": "tail",
                      "flexibility": 0.4, "damping": 0.7, "gravity": 1,
                      "collide": true}, ...],
       "colliders": [{"id": 5, "radius": 0.12}, ...],
       "collision_exclusions": [[a, b], ...],
       "allow_intersections": true, "collision_clearance": 0.005,
       "animations": [{"file": "anims/biped.glb", "clip": "Walk"}, ...] }

 The settings and `next_id` are stored on purpose. `RigDocument` declared them
 in B5 so this file would not change shape when they started being used, and
 keeping `next_id` is what keeps ids stable across a load — ids are handed out
 once and never reused, and reusing one a deleted dot had would resurrect
 exactly the confusion the scheme exists to prevent. `mesh` is informational:
 the file is found from the mesh's path, so loading never reads it back.

 **Where the rig ends up.** `AppState.save_session` writes this file beside
 whichever model the save produced, and `adopt_source_rig` reads it first on the
 way back in. It used to go into the model's own `extras` as well; that copy is
 gone, because the paint layer is one entry per (vertex, dot) pair and a painted
 humanoid was putting megabytes of it into the file the user ships — readable by
 nothing but crig, and byte-identical to what was already sitting beside it.

 A sidecar beside a `.glb` therefore means *crig saved this model*, which is also
 what raises `AppState.saves_in_place` on an open: the document lives here, so a
 model that has one is a model crig owns and may write again in place.

 The writer is hand-rolled — the vocabulary is seven keys and two lists — while
 the reader goes through `std::encoding::json`, because parsing is the
 direction that can fail in someone else's hands. Loading validates everything
 it adopts: a version that is present and known, ids unique and non-zero, edges
 naming dots that exist, the root resolving to a placed dot. A file that fails
 any of it is not a session, and is refused without touching the open rig.

 Lives in `core/` rather than `app/` for the usual reason: no cui, so the
 round trip is assertable with no window — which is what `ui-test` does.
*>
module crig;

import std::collections::object;
import std::collections::list;

import std::encoding::json;
import std::io;
import libc;
import std::math;
import std::math::vector;
import gltf_edit;

// The JSON string and number writers every crig writer uses — the session, the pack
// `extras` and every MCP answer. They are `gltf_edit`'s, the lowest layer that
// writes JSON, and not the MCP library's: crig's own formats should not change
// when the wire protocol does.
//
// The body of a JSON string, quotes left to the caller.
alias json_escape_into = gltf_edit::escape_json_body;
// A complete JSON string literal, quotes included.
alias append_json_string = gltf_edit::escape_json_string;
// Numbers the same way: `%s` with one of these writes the shortest text that
// reads back as the same float, and `null` for one that is not finite.
alias JsonFloat = gltf_edit::JsonFloat;
alias JsonVec3 = gltf_edit::JsonVec3;
alias JsonQuat = gltf_edit::JsonQuat;

faultdef SESSION_IO, SESSION_SHAPE;

struct ProjectSession
{
	RigDocument doc;
	AnimTemplate[] authored;
	bool model_transform_in_mesh;
}

fn void ProjectSession.free(&self, Allocator allocator)
{
	self.doc.free();
	free_animations(allocator, self.authored);
	*self = {};
}

// Bumped when the file's meaning changes; a reader refuses what it does not
// understand rather than silently rigging half of it.
//
// 6 added `skin_from_file`. That is a bump and not merely a new optional key
// because a reader that ignores it does not lose a label — it binds the mesh
// with crig's own binder over a rig whose weights were painted somewhere else,
// and shows a deformation nobody authored.
//
// 7 added the pose: `rot` and `move` per dot. Both are optional and a version 6
// file simply has neither, so the bump is for the other direction — a version 7
// file read by a version 6 binary would come back as a rig with the pose
// silently dropped, and the work that went into it gone with no error anywhere.
//
// 8 added `paint`, and the bump is for that same direction and a sharper reason.
// A version 8 file read by a version 7 binary comes back as a rig that binds
// *differently* — every hand correction gone, so the mesh deforms the way the
// binder alone says it should, which is exactly the state the corrections were
// made to get out of. Nothing on screen would say anything was lost.
//
// 9 added `physics` and `colliders` — which bones the simulation owns and what
// they are pushed out of. Same direction and same sharpness: a version 9 file
// read by a version 8 binary comes back as a rig whose tail no longer moves,
// with nothing anywhere saying it used to.
//
// 10 added `animations`: which of the library's clips are bound to this
// character. The bump is the same direction again — a version 10 file read by a
// version 9 binary comes back as a character with no animations, and since the
// bound set is also what an export ships, the next export would write a rigged
// model with nothing on it and no error to say why.
//
// 11 added `sharpness`: the power this model's weights are raised to. Written
// only when it is set, so most files still have no such key — and the bump is
// the same direction as the four above it. A version 11 file read by a version
// 10 binary binds every boundary back at the binder's own blend, which on the
// hard-surface model the setting exists for is the mush it was turned up to get
// rid of, with nothing on screen to say a number was dropped.
//
// 12 added `pins`: the vertices handed to a dot outright. Same direction again,
// and the loudest of them — a pin is a *stated* share rather than a correction
// riding on the binder, so a version 12 file read by a version 11 binary comes
// back with every hand-drawn region blended again. Written only when there is
// one, so a rig that has never used the lasso still has no such key.
//
// 13 added `rotation_limits`: the editable per-axis constraint table and its
// bone-local frame choice. It is omitted for an unconstrained rig, and old
// files therefore read as entirely free. The bump prevents an older binary
// from opening constrained work and silently saving it back without limits.
//
// 14 added `collision_exclusions`: the region pairs the self-collision check
// is told to leave alone, as dot-id pairs like `edges`. Omitted when there are
// none, so a rig that never needed one writes what it always did. Same
// direction as 13: a version 14 file read by a version 13 binary would come
// back with the cape colliding with the arm again, and save that back.
//
// 15 added `allow_intersections` and `collision_clearance`: whether the
// self-collision check is off for this rig, and the clearance it measures
// against. Both are omitted at their defaults — blocking on, the built-in
// clearance — so a rig that never touched either writes what it always did.
// A version 15 file read by a version 14 binary would bring the check back on
// over a rig its author had turned it off for, and save that back.
//
// 16 replaced `physics` with `secondary`: one record per chain — root, tip,
// preset and shared behaviour — where there was one per dynamic bone. The old
// key is still read and migrated (`secondary_chains_from_bones`), never
// written. Same direction as every bump above: a version 16 file read by a
// version 15 binary would find no `physics` at all and come back with every
// tail the animation's, and save that back.
//
// 17 dropped `swing` and `thickness` from a chain: where a chain may turn is
// its joints' `rotation_limits` now, and how fat it is comes off its own skin.
// A version 16 file's two values are read and let go — a cone was a bound on
// the simulation alone and the table is the rig's; a thickness typed by hand
// is replaced by one measured. The bump is for the reader: a version 17 file
// is a version 16 file with two keys missing, which a version 16 binary would
// read as a chain of zero thickness that collides with nothing.
//
// 18 moved the joints' rotation limits out of the session and into the model:
// Save writes them into the .glb as the KHR constraint joints Export writes,
// and an open reads them back off the model, so the file a library fits from
// and the file crig reopens are one file with one set of tables. The key is
// still read — a session from before, or one written for a model that could
// not take a skin in place (see `session_text`'s `limits`), carries the
// tables the model does not — but a version 18 file ordinarily has none, which
// a version 17 binary would read as a rig with every joint free.
//
// 19 added the complete character's non-destructive placement. Older sessions
// open at the identity transform; older readers must not silently drop a model
// move or rotation when saving the project again.
//
// 20 added animation layers to authored clips (`authored_clips[i].layers`). They
// are optional and live in the sidecar only — a glb carries the flattened
// channels and no layer data — so a version 19 file reads as a clip with none.
const uint SESSION_VERSION = 20;

<*
 Where a mesh's session lives: beside it, with `.rigsmith.json` for the extension.

 The stem is cut at the last dot of the *last path segment*, the same rule as
 `rigged_path` (core/rigging.c3), so a directory with a dot in its name does
 not swallow the file name.

 The caller owns the returned string.
*>
fn String session_path(Allocator allocator, String mesh_path)
{
	// `path_stem` (core/rigging.c3) is the one place that rule lives. It matters
	// that every file crig puts beside a model agrees on it — the session here,
	// the rigged copy there, the play script in app/play.c3 — or a mesh in a
	// directory with a dot in its name gets its sidecar somewhere else.
	return string::format(allocator, "%s.rigsmith.json", mesh_path[:path_stem(mesh_path)]);
}

<*
 Writes the project to an exclusively-created sibling temporary, closes the
 complete file, then atomically renames it over the session. A write failure
 therefore leaves the previous valid sidecar in place.
*>
fn void? write_session(
	String path,
	RigDocument* doc,
	String mesh_path,
	AnimTemplate[] clips = {},
	bool limits = false,
	bool model_transform_in_mesh = false)
{
	String body = session_text(mem, doc, mesh_path, clips, limits, model_transform_in_mesh);
	defer body.free(mem);

	String temporary;
	File file;
	bool opened = false;
	for (uint attempt = 0; attempt < 100; attempt++)
	{
		temporary = string::format(mem, "%s.tmp.%d", path, attempt);
		File? candidate = io::file::open(temporary, "wx");
		if (try File made = candidate)
		{
			file = made;
			opened = true;
			break;
		}
		temporary.free(mem);
		temporary = "";
	}
	if (!opened) return SESSION_IO~;
	defer temporary.free(mem);

	sz? written = file.write(body);
	if (catch written)
	{
		(void)file.close();
		(void)io::file::delete(temporary);
		return SESSION_IO~;
	}

	// A short write is a full disk, not a success. What it leaves behind parses
	// as far as it got, so the next load would come back as a smaller rig than
	// the one that was saved — the one failure mode worth a second line here.
	if (written != (sz)body.len)
	{
		(void)file.close();
		(void)io::file::delete(temporary);
		return SESSION_IO~;
	}
	if (catch file.close())
	{
		(void)io::file::delete(temporary);
		return SESSION_IO~;
	}
	if (libc::rename(temporary.zstr_tcopy(), path.zstr_tcopy()) != 0)
	{
		(void)io::file::delete(temporary);
		return SESSION_IO~;
	}
}

<*
 The document as the JSON text a session is.

 Split out from the file write so the text can be built without a file to put it
 in — which is what every round-trip check does, and what makes the format
 assertable with no disk behind it.

 Numbers go through `JsonFloat` and its vector forms: the shortest text that
 reads back as the same float32, which never needs more than nine digits.

 The caller owns the returned string.

 @param mesh_path : `Recorded under "mesh" for a reader's benefit; nothing reads it back.`
 @param limits : `Write the joints' rotation limits too. Off for a model that carries them itself, which is every model Save could write into; on for one it could not, so the tables are not lost with the skin.`
*>
fn String session_text(
	Allocator allocator,
	RigDocument* doc,
	String mesh_path,
	AnimTemplate[] clips = {},
	bool limits = false,
	bool model_transform_in_mesh = false)
{
	DString text = dstring::new(allocator);
	defer text.free();

	// Every string here goes through `append_json_string`, which is not
	// decoration: a dot's name is whatever the user typed, a mesh is whatever the
	// filesystem allows, and on this platform both include the quote and the
	// backslash. One of those written raw ends the string early and the rest of
	// the file stops being JSON — so the session does not fail to load a name, it
	// fails to load at all.
	text.appendf("{\n  \"version\": %d,\n  \"mesh\": ", SESSION_VERSION)!!;
	append_json_string(&text, base_name(mesh_path));
	text.append_string(",\n");

	text.appendf("  \"root\": %d,\n  \"next_id\": %d,\n", doc.root_id, doc.next_id)!!;
	text.appendf("  \"auto_connect\": %s,\n  \"sym_x\": %s,\n", doc.auto_connect, (JsonFloat)doc.sym_x)!!;

	if (!doc.model_transform.is_identity())
	{
		Quaternionf rotation = doc.model_transform.orientation();
		text.appendf("  \"model_transform\": {\"location\":%s,\"rotation\":%s},\n",
			(JsonVec3)doc.model_transform.location, (JsonQuat)rotation)!!;
	}
	if (model_transform_in_mesh) text.append_string("  \"model_transform_in_mesh\": true,\n");

	// Only when there is one. A hand-built rig declares no body plan, and an
	// empty string in the file would read as a plan named "" on the way back.
	if (doc.plan.len > 0)
	{
		text.append_string(`  "plan": `);
		append_json_string(&text, doc.plan);
		text.append_string(",\n");
	}

	// Only when this model asked for one, on the same terms as the plan above: a
	// zero is the unset state and a 1 is what unset is read as, so writing either
	// would put a key in every session for a setting nobody touched.
	if (doc.sharpness > 0.0f && doc.sharpness != 1.0f)
	{
		text.appendf("  \"sharpness\": %s,\n", (JsonFloat)doc.sharpness)!!;
	}

	// Only when set, for the plain reason: false is what every rig crig builds
	// is, and a key saying so in every session would be noise. The weights
	// themselves are not written — they are megabytes, and they are still sitting
	// in the mesh's own file, which is where the load reads them from again.
	if (doc.skin_from_file)
	{
		text.append_string("  \"skin_from_file\": true,\n");
	}

	text.append_string(`  "dots": [`);
	foreach (i, dot : doc.dots.array_view())
	{
		if (i > 0) text.append_char(',');
		text.appendf("{\"id\":%d", dot.id)!!;
		if (dot.name.len > 0)
		{
			text.append_string(`,"name":`);
			append_json_string(&text, dot.name);
		}
		text.appendf(",\"position\":%s", (JsonVec3)dot.position)!!;
		// Only when limited. An unlimited reach is what a dot has until someone
		// says otherwise, and writing the zero would put the word in every entry
		// of every rig that has never used it.
		if (dot.reach > 0.0f) text.appendf(",\"reach\":%s", (JsonFloat)dot.reach)!!;

		text.append_char('}');
	}

	// Two appends, and not one raw string: backticks do not process escapes, so
	// a `\n` written inside them lands in the file as a backslash and an n —
	// which is not whitespace to a JSON parser, and the whole file stops being
	// readable at the one character that was meant to be invisible.
	text.append_string("],\n");
	text.append_string(`  "edges": [`);
	foreach (i, edge : doc.edges.array_view())
	{
		if (i > 0) text.append_char(',');
		text.appendf("[%d,%d]", edge.a, edge.b)!!;
	}

	// Attachments naming a dot that no longer exists are dropped here rather
	// than when the dot goes: until the session is written a deletion is still
	// one Ctrl+Z from coming back, and the entry has to be waiting for it.
	text.append_string("],\n");
	text.append_string(`  "attachments": [`);
	usz pinned = 0;
	foreach (entry : doc.attachments.array_view())
	{
		if (entry.dot_id == 0 || !doc.find(entry.dot_id)) continue;
		if (pinned > 0) text.append_char(',');
		text.appendf("[%d,%d]", entry.shell, entry.dot_id)!!;
		pinned++;
	}

	// The hand corrections, on the same terms as the attachments above: dropped
	// here when the dot they name is gone, not when it went, because until the
	// file is written a deletion is still one Ctrl+Z from coming back.
	//
	// Written flat rather than grouped by dot. A stroke is thousands of these and
	// the grouped form would save a few bytes per dab while making the reader
	// carry a second shape; `%.9g` round-trips a float exactly, which matters more
	// here than anywhere else in the file — a correction read back a hair off is a
	// deformation nobody authored.
	text.append_string("],\n");
	text.append_string(`  "paint": [`);
	usz dabs = 0;
	foreach (dab : doc.paint.array_view())
	{
		if (dab.dot_id == 0 || !doc.find(dab.dot_id)) continue;
		if (dabs > 0) text.append_char(',');
		text.appendf("[%d,%d,%s]", dab.vertex, dab.dot_id, (JsonFloat)dab.factor)!!;
		dabs++;
	}

	text.append_char(']');

	// The pins, on the paint's terms exactly — flat triples, `%.9g` so a share
	// round-trips a float exactly, and an entry naming a dot that has gone
	// dropped here rather than when the dot went, because until the file is
	// written a deletion is still one Ctrl+Z from coming back.
	//
	// **Omitted entirely when there is none**, unlike the four lists above and
	// like the physics below: this key arrived in version 12, so every earlier
	// file simply has none, and writing `"pins": []` onto every session crig has
	// ever saved would be a line of noise for a layer most rigs never use.
	usz stated = 0;
	foreach (pin : doc.pins.array_view())
	{
		if (pin.dot_id == 0 || !doc.find(pin.dot_id)) continue;
		text.append_string(stated == 0 ? ",\n  \"pins\": [" : ",");
		text.appendf("[%d,%d,%s]", pin.vertex, pin.dot_id, (JsonFloat)pin.share)!!;
		stated++;
	}
	if (stated > 0) text.append_char(']');

	// The chains, on the same terms as the paint and the attachments above:
	// keyed by a dot, and dropped here when the dot they name is gone rather than
	// when it went, because until the file is written a deletion is still one
	// Ctrl+Z from coming back. A chain whose tip is gone is kept — the record is
	// the root's, and the boundary already reads a missing tip as a run of
	// nothing — so undoing the tip's deletion brings the run back whole.
	//
	// **Omitted entirely when there is none**, unlike the four lists above, which
	// are always written even when empty. Those are the shape of a session and a
	// reader may lean on them; this arrived in version 16 (as `physics` in 9) and
	// every earlier file simply has no such key, so writing `"secondary": []` on
	// every rig that has never used it would be a line of noise in every session
	// crig has ever saved.
	//
	// One object per chain rather than a flat array: seven values, and seven
	// positional values is a format nobody can read back without counting.
	usz chains = 0;
	foreach (chain : doc.secondary.array_view())
	{
		if (chain.root == 0 || !doc.find(chain.root)) continue;
		text.append_string(chains == 0 ? ",\n  \"secondary\": [" : ",");
		text.appendf(`{"root":%d,"tip":%d,"preset":"%s","flexibility":%s,"damping":%s,"gravity":%s,"collide":%s}`,
			chain.root, chain.tip, chain.preset.label(), (JsonFloat)chain.flexibility, (JsonFloat)chain.damping,
			(JsonFloat)chain.gravity, chain.collide ? "true" : "false")!!;
		chains++;
	}
	if (chains > 0) text.append_char(']');

	usz capsules = 0;
	foreach (entry : doc.colliders.array_view())
	{
		if (entry.dot_id == 0 || !doc.find(entry.dot_id)) continue;
		text.append_string(capsules == 0 ? ",\n  \"colliders\": [" : ",");
		text.appendf(`{"id":%d,"radius":%s}`, entry.dot_id, (JsonFloat)entry.radius)!!;
		capsules++;
	}
	if (capsules > 0) text.append_char(']');

	// Joint constraints live in the model since version 18, so they are written
	// here only on request — for a model that could not take them. Sparse when
	// they are: most joints on most imported rigs are free and need no object
	// saying so. Like physics, stale entries are retained in memory for undo and
	// dropped at the save boundary. A stale primary-child choice is omitted while
	// the axis limits themselves survive; a deleted child cannot define a frame
	// after reopen.
	usz limited = 0;
	foreach (entry : doc.rotation_limits.array_view())
	{
		if (!limits) break;
		if (entry.dot_id == 0 || !doc.find(entry.dot_id)) continue;
		text.append_string(limited == 0 ? ",\n  \"rotation_limits\": [" : ",");
		text.appendf(`{"id":%d,"active":%s,"axes":[`, entry.dot_id, entry.constrained)!!;
		foreach (usz a, axis : entry.axes)
		{
			if (a > 0) text.append_char(',');
			text.appendf(`{"allow":%s,"minimum":%s,"maximum":%s,"locked":%s}`,
				axis.allowed, (JsonFloat)axis.minimum, (JsonFloat)axis.maximum, (JsonFloat)axis.locked)!!;
		}
		text.append_char(']');
		if (entry.primary_child != 0 && doc.find(entry.primary_child))
		{
			text.appendf(`,"primary_child":%d`, entry.primary_child)!!;
		}
		if (entry.has_saved_frame)
		{
			text.appendf(`,"frame":%s`, (JsonQuat)entry.saved_frame)!!;
		}
		text.append_char('}');
		limited++;
	}
	if (limited > 0) text.append_char(']');

	// Dot-id pairs like the edges, and filtered like the layers above: an
	// exclusion whose dot is gone waited in memory for an undo that never came.
	usz excluded = 0;
	foreach (entry : doc.collision_exclusions.array_view())
	{
		if (!doc.find(entry.a) || !doc.find(entry.b)) continue;
		text.append_string(excluded == 0 ? ",\n  \"collision_exclusions\": [" : ",");
		text.appendf("[%d,%d]", entry.a, entry.b)!!;
		excluded++;
	}
	if (excluded > 0) text.append_char(']');

	// Both only when set, on `sharpness`'s terms: the default is the absent key.
	if (doc.allow_intersections) text.append_string(",\n  \"allow_intersections\": true");
	if (doc.collision_clearance > 0.0f)
	{
		text.appendf(",\n  \"collision_clearance\": %s", (JsonFloat)doc.collision_clearance)!!;
	}

	// The clips bound to this character, in the order the user put them in — so
	// the key is written whole rather than per-entry-filtered like the two above.
	// Nothing here is checked against the document: a bound clip names a file and
	// a clip inside it, and whether either still exists is a question for the
	// library at load time, not for the writer. An entry that has gone stale is
	// worth keeping and showing as missing; dropping it here would lose the only
	// record that the user ever chose it.
	//
	// An authored clip carries an empty `file` and is written as one. It cannot be
	// resolved on a later run — there is no file to look in — and the panel says
	// so rather than the writer pretending it was never bound.
	if (doc.animations.len() > 0)
	{
		text.append_string(",\n  \"animations\": [");
		foreach (usz i, bound : doc.animations.array_view())
		{
			if (i > 0) text.append_char(',');
			text.append_string(`{"file":`);
			append_json_string(&text, bound.file);
			text.append_string(`,"clip":`);
			append_json_string(&text, bound.clip);
			text.append_char('}');
		}
		text.append_char(']');
	}

	if (doc.joint_maps.len > 0)
	{
		text.append_string(",\n  \"joint_maps\": [");
		foreach (usz i, map : doc.joint_maps)
		{
			if (i > 0) text.append_char(',');
			text.append_string(`{"file":`);
			append_json_string(&text, map.file);
			text.append_string(`,"source":`);
			append_json_string(&text, map.source);
			text.append_string(`,"joint":`);
			append_json_string(&text, map.joint);
			text.append_char('}');
		}
		text.append_char(']');
	}

	if (clips.len > 0)
	{
		text.append_string(",\n  \"authored_clips\": [");
		foreach (usz c, clip : clips)
		{
			if (c > 0) text.append_char(',');
			text.append_string(`{"name":`);
			append_json_string(&text, clip.name);
			text.appendf(`,"duration":%s,"loop":%s,"blend":"%s"`,
				(JsonFloat)clip.duration, clip.loop, clip.blend == SMOOTH ? "smooth" : "linear")!!;
			if (clip.ground.solves() || clip.ground.floor_set)
			{
				text.append_string(`,"ground":{`);
				if (clip.ground.floor_set) text.appendf(`"floor":%s,`, (JsonFloat)clip.ground.floor)!!;
				text.append_string(`"feet":[`);
				foreach (usz f, foot : clip.ground.feet)
				{
					if (f > 0) text.append_char(',');
					text.append_string(`{"joint":`); append_json_string(&text, foot.joint);
					text.appendf(`,"down":%s,"up":%s`, (JsonFloat)foot.down, (JsonFloat)foot.up)!!;
					text.append_string(foot.off_floor ? `,"off_floor":true}` : "}");
				}
				text.append_string("]}");
			}
			text.append_string(`,"keys":[`);
			foreach (usz k, key : clip.keyframes)
			{
				if (k > 0) text.append_char(',');
				text.appendf(`{"time":%s,"dots":[`, (JsonFloat)key.time)!!;
				append_key_dots(&text, key.dots);
				text.append_string("]}");
			}
			text.append_string("]");
			if (clip.layers.len > 0)
			{
				text.append_string(`,"layers":[`);
				foreach (usz l, &layer : clip.layers)
				{
					if (l > 0) text.append_char(',');
					text.append_char('{');
					append_layer_fields(&text, layer);
					if (!layer.procedural())
					{
						text.append_string(`,"keys":[`);
						foreach (usz k, key : layer.keyframes)
						{
							if (k > 0) text.append_char(',');
							text.appendf(`{"time":%s,"dots":[`, (JsonFloat)key.time)!!;
							append_key_dots(&text, key.dots);
							text.append_string("]}");
						}
						text.append_char(']');
					}
					text.append_char('}');
				}
				text.append_char(']');
			}
			text.append_char('}');
		}
		text.append_char(']');
	}

	if (doc.poses.len > 0)
	{
		text.append_string(",\n  \"poses\": [");
		foreach (usz i, pose : doc.poses)
		{
			if (i > 0) text.append_char(',');
			text.append_string(`{"name":`);
			append_json_string(&text, pose.name);
			text.append_string(`,"dots":[`);
			append_key_dots(&text, pose.dots);
			text.append_string("]}");
		}
		text.append_char(']');
	}

	text.append_string("\n}\n");
	return text.copy_str(allocator);
}

// One key's entries as JSON objects, comma separated; shared by clips and poses.
fn void append_key_dots(DString* text, AnimKeyDot[] dots) @private
{
	foreach (usz d, dot : dots)
	{
		if (d > 0) text.append_char(',');
		text.append_string(`{"joint":`); append_json_string(text, dot.joint_name);
		text.appendf(`,"channels":"%s"`, dot.channels == ROTATION
			? "rotation" : (dot.channels == TRANSLATION ? "translation" : "both"))!!;
		text.appendf(`,"axis":%s,"angle":%s,"move":%s,"bone":%s`,
			(JsonVec3)dot.axis, (JsonFloat)dot.angle,
			(JsonVec3)dot.move, (JsonVec3)dot.bone)!!;
		if (dot.rotation_interpolation != INHERIT)
		{
			text.appendf(`,"rotation_interpolation":"%s"`, dot.rotation_interpolation.serialized())!!;
		}
		if (dot.translation_interpolation != INHERIT)
		{
			text.appendf(`,"translation_interpolation":"%s"`, dot.translation_interpolation.serialized())!!;
		}
		if (dot.keys_rotation()) append_ease_field(text, "rotation_ease", dot.rotation_ease);
		if (dot.keys_translation()) append_ease_field(text, "translation_ease", dot.translation_ease);
		text.append_char('}');
	}
}

<*
 Reads a session back into a fresh document.

 Settings that are absent take the editor's defaults, so a file written before
 a setting existed still loads: chaining on, and `sym_x` from the caller — the
 app passes the mesh's own bounds centre, which is what a fresh document would
 have guessed. A `mirror` flag from a session written while placing mirrored as
 it went is read as nothing, which is what it now is.

 @param fallback_sym_x : `Used when the file names no symmetry plane.`
 @return? SESSION_IO : `The file could not be read.`
 @return? SESSION_SHAPE : `It parsed, but it is not a session crig wrote.`
*>
fn RigDocument? read_session(Allocator allocator, String path, float fallback_sym_x = 0.0f)
{
	char[]? content = io::file::load(allocator, path);
	if (catch content) return SESSION_IO~;
	defer alloc::free(allocator, content);

	return parse_session(allocator, (String)content, fallback_sym_x);
}

<* Read the optional authored animation payload without changing the document reader. *>
fn AnimTemplate[]? read_session_clips(Allocator allocator, String path)
{
	char[]? content = io::file::load(allocator, path);
	if (catch content) return SESSION_IO~;
	defer alloc::free(allocator, content);
	return parse_session_clips(allocator, (String)content);
}

<* Read document and authored clips from one immutable snapshot of the sidecar. *>
fn ProjectSession? read_project_session(Allocator allocator, String path, float fallback_sym_x = 0.0f)
{
	char[]? content = io::file::load(allocator, path);
	if (catch content) return SESSION_IO~;
	defer alloc::free(allocator, content);
	// One parse for all three readers: the std JSON reader is the slow part of
	// opening a project, and each of them used to take its own.
	Object*? parsed = json::parse(allocator, (String)content);
	if (catch parsed) return SESSION_SHAPE~;
	defer parsed.free();
	RigDocument? doc = session_document(allocator, parsed, fallback_sym_x);
	if (catch doc) return SESSION_SHAPE~;
	AnimTemplate[]? clips = session_clips(allocator, parsed);
	if (catch clips)
	{
		doc.free();
		return SESSION_SHAPE~;
	}
	bool? placed = session_transform_in_mesh(parsed);
	if (catch placed)
	{
		doc.free();
		free_animations(allocator, clips);
		return SESSION_SHAPE~;
	}
	return { .doc = doc, .authored = clips, .model_transform_in_mesh = placed };
}

fn bool? session_transform_in_mesh(Object* parsed) @private
{
	if (try bool placed = parsed.get_bool("model_transform_in_mesh")) return placed;
	if (try Object* ignored = parsed.get("model_transform_in_mesh")) return SESSION_SHAPE~;
	return false;
}

fn Vec3? session_vec3(Object* value) @private
{
	if (!is_list(value) || value.get_len() != 3) return SESSION_SHAPE~;
	Vec3 out = {
		(float)value.get_float_at(0)!,
		(float)value.get_float_at(1)!,
		(float)value.get_float_at(2)!,
	};
	if (!math::is_finite(out.x) || !math::is_finite(out.y) || !math::is_finite(out.z)) return SESSION_SHAPE~;
	return out;
}

// Four numbers [x, y, z, w], read as they were written. Whether they make a
// usable rotation is the caller's question.
fn Quaternionf? session_quat(Object* value) @private
{
	if (!is_list(value) || value.get_len() != 4) return SESSION_SHAPE~;
	return { .v = {
		(float)value.get_float_at(0)!,
		(float)value.get_float_at(1)!,
		(float)value.get_float_at(2)!,
		(float)value.get_float_at(3)!,
	} };
}

fn AnimTemplate[]? parse_session_clips(Allocator allocator, String text)
{
	Object*? parsed = json::parse(allocator, text);
	if (catch parsed) return SESSION_SHAPE~;
	defer parsed.free();
	return session_clips(allocator, parsed);
}

fn AnimTemplate[]? session_clips(Allocator allocator, Object* parsed) @private
{
	Object*? payload = parsed.get("authored_clips");
	if (catch payload) return (AnimTemplate[]){};
	if (!is_list(payload)) return SESSION_SHAPE~;

	AnimTemplateList clips;
	clips.init(allocator);
	bool complete = false;
	defer if (!complete)
	{
		foreach (&clip : clips.array_view()) clip.free(allocator);
		clips.free();
	};
	for (sz c = 0; c < payload.get_len(); c++)
	{
		AnimTemplate clip = parse_session_clip(allocator, payload.get_at(c))!;
		foreach (prior : clips.array_view()) if (prior.name == clip.name)
		{
			clip.free(allocator);
			return SESSION_SHAPE~;
		}
		clips.push(clip);
	}
	AnimTemplate[] out = clips.to_array(allocator);
	clips.free();
	complete = true;
	return out;
}

fn AnimTemplate? parse_session_clip(Allocator allocator, Object* entry) @private
{
	AnimTemplate clip = { .owned = true };
	bool complete = false;
	defer if (!complete) clip.free(allocator);
	String name = entry.get_string("name")!;
	double duration = entry.get_float("duration")!;
	bool loop = entry.get_bool("loop")!;
	String blend = entry.get_string("blend") ?? "linear";
	Object* keys = entry.get("keys")!;
	float clip_duration = (float)duration;
	if (name.len == 0 || clip_duration <= 0.0f || !math::is_finite(clip_duration)
		|| !is_list(keys) || keys.get_len() == 0
		|| (blend != "linear" && blend != "smooth")) return SESSION_SHAPE~;
	clip.name = name.copy(allocator);
	clip.duration = clip_duration;
	clip.loop = loop;
	clip.blend = blend == "smooth" ? SMOOTH : LINEAR;
	clip.keyframes = alloc::new_array(allocator, AnimKeyframe, keys.get_len());
	if (try Object* ground = entry.get("ground"))
	{
		if (try double floor = ground.get_float("floor"))
		{
			float ground_floor = (float)floor;
			if (!math::is_finite(ground_floor)) return SESSION_SHAPE~;
			clip.ground.floor = ground_floor;
			clip.ground.floor_set = true;
		}
		Object* feet = ground.get("feet")!;
		if (!is_list(feet)) return SESSION_SHAPE~;
		clip.ground.feet = alloc::new_array(allocator, AnimFoot, feet.get_len());
		for (sz f = 0; f < feet.get_len(); f++)
		{
			Object* foot = feet.get_at(f);
			String joint = foot.get_string("joint")!;
			double down = foot.get_float("down")!;
			double up = foot.get_float("up")!;
			float down_f = (float)down;
			float up_f = (float)up;
			if (joint.len == 0 || !math::is_finite(down_f) || !math::is_finite(up_f)) return SESSION_SHAPE~;
			clip.ground.feet[f] = { .joint = joint.copy(allocator),
				.down = down_f, .up = up_f, .off_floor = foot.get_bool("off_floor") ?? false };
		}
	}
	float previous = -1.0f;
	bool explicit_channels = false;
	for (sz k = 0; k < keys.get_len(); k++)
	{
		Object* key = keys.get_at(k);
		Object* dots = key.get("dots")!;
		float time = (float)key.get_float("time")!;
		if (!is_list(dots) || !math::is_finite(time) || time < 0.0f || time <= previous || time > clip.duration) return SESSION_SHAPE~;
		previous = time;
		clip.keyframes[k].time = time;
		clip.keyframes[k].dots = alloc::new_array(allocator, AnimKeyDot, dots.get_len());
		for (sz d = 0; d < dots.get_len(); d++)
		{
			Object* dot = dots.get_at(d);
			String joint = dot.get_string("joint")!;
			for (sz p = 0; p < d; p++) if (clip.keyframes[k].dots[p].joint_name == joint) return SESSION_SHAPE~;
			clip.keyframes[k].dots[d] = session_key_dot(allocator, dot, &explicit_channels)!;
		}
	}
	if (!explicit_channels)
	{
		foreach (&frame : clip.keyframes)
		{
			AnimDotList expanded;
			expanded.init(allocator);
			foreach (dot : frame.dots) expanded.push(dot);
			foreach (source : clip.keyframes) foreach (candidate : source.dots)
			{
				bool present = false;
				foreach (held : expanded.array_view()) if (held.joint_name == candidate.joint_name)
				{
					present = true;
					break;
				}
				if (!present) expanded.push({ .joint_name = candidate.joint_name.copy(allocator), .channels = BOTH });
			}
			if (frame.dots.len > 0) alloc::free(allocator, frame.dots);
			frame.dots = expanded.to_array(allocator);
			expanded.free();
		}
	}
	if (try Object* layers = entry.get("layers"))
	{
		if (!layers.is_null())
		{
			if (!is_list(layers)) return SESSION_SHAPE~;
			clip.layers = alloc::new_array(allocator, AnimLayer, layers.get_len());
			for (sz l = 0; l < layers.get_len(); l++)
			{
				clip.layers[(usz)l] = session_layer(allocator, layers.get_at(l))!;
			}
		}
	}
	clip.compile_tracks(allocator);
	complete = true;
	return clip;
}

// One layer of a clip. Its keys, when it has any, are read like the clip's own.
fn AnimLayer? session_layer(Allocator allocator, Object* entry) @private
{
	AnimLayer layer = anim_layer_defaults("");
	bool complete = false;
	defer if (!complete) layer.free(allocator);
	if (!read_layer_fields(entry, allocator, &layer, null)) return SESSION_SHAPE~;
	if (layer.kind == KEYED)
	{
		Object* keys = entry.get("keys")!;
		if (!is_list(keys)) return SESSION_SHAPE~;
		layer.keyframes = alloc::new_array(allocator, AnimKeyframe, keys.get_len());
		float previous = -1.0f;
		bool explicit_channels = false;
		for (sz k = 0; k < keys.get_len(); k++)
		{
			Object* key = keys.get_at(k);
			Object* dots = key.get("dots")!;
			float time = (float)key.get_float("time")!;
			if (!is_list(dots) || !math::is_finite(time) || time < 0.0f || time <= previous) return SESSION_SHAPE~;
			previous = time;
			layer.keyframes[(usz)k].time = time;
			layer.keyframes[(usz)k].dots = alloc::new_array(allocator, AnimKeyDot, dots.get_len());
			for (sz d = 0; d < dots.get_len(); d++)
			{
				Object* dot = dots.get_at(d);
				String joint = dot.get_string("joint")!;
				for (sz p = 0; p < d; p++) if (layer.keyframes[(usz)k].dots[(usz)p].joint_name == joint) return SESSION_SHAPE~;
				layer.keyframes[(usz)k].dots[(usz)d] = session_key_dot(allocator, dot, &explicit_channels)!;
			}
		}
	}
	complete = true;
	return layer;
}

// One key entry; the joint name is copied. `explicit_channels` is raised when
// the entry states its channels.
fn AnimKeyDot? session_key_dot(Allocator allocator, Object* dot, bool* explicit_channels) @private
{
	String joint = dot.get_string("joint")!;
	if (joint.len == 0) return SESSION_SHAPE~;
	String channels = "both";
	Object*? channel_field = dot.get("channels");
	if (try Object* ignored = channel_field)
	{
		String? stated = dot.get_string("channels");
		if (catch stated) return SESSION_SHAPE~;
		channels = stated;
		*explicit_channels = true;
	}
	if (channels != "both" && channels != "rotation" && channels != "translation") return SESSION_SHAPE~;
	float angle = (float)dot.get_float("angle")!;
	if (!math::is_finite(angle)) return SESSION_SHAPE~;
	Vec3 axis = session_vec3(dot.get("axis")!)!;
	Vec3 move = session_vec3(dot.get("move")!)!;
	Vec3 bone = session_vec3(dot.get("bone")!)!;
	AnimInterpolation rotation_interpolation;
	AnimInterpolation translation_interpolation;
	if (try String value = dot.get_string("rotation_interpolation"))
	{
		if (!parse_anim_interpolation(value, &rotation_interpolation)) return SESSION_SHAPE~;
	}
	if (try String value = dot.get_string("translation_interpolation"))
	{
		if (!parse_anim_interpolation(value, &translation_interpolation)) return SESSION_SHAPE~;
	}
	if (channels == "translation" && rotation_interpolation != INHERIT) return SESSION_SHAPE~;
	if (channels == "rotation" && translation_interpolation != INHERIT) return SESSION_SHAPE~;
	AnimEase rotation_ease;
	AnimEase translation_ease;
	if (!read_ease_field(dot, "rotation_ease", &rotation_ease)) return SESSION_SHAPE~;
	if (!read_ease_field(dot, "translation_ease", &translation_ease)) return SESSION_SHAPE~;
	if (channels == "translation") rotation_ease = {};
	if (channels == "rotation") translation_ease = {};
	return { .joint_name = joint.copy(allocator),
		.axis = axis, .angle = angle, .move = move, .bone = bone,
		.rotation_interpolation = rotation_interpolation,
		.translation_interpolation = translation_interpolation,
		.rotation_ease = rotation_ease,
		.translation_ease = translation_ease,
		.channels = channels == "rotation" ? ROTATION
			: (channels == "translation" ? TRANSLATION : BOTH) };
}

<*
 A session read out of text rather than out of a file.

 The half of `read_session` that does the work, split out for the same reason
 `session_text` is: a `.glb` carries this exact object in its `extras`, and it has
 to be read by the same reader that reads the sidecar or the two formats drift.

 @param text : `The session object's JSON. Borrowed.`
 @param fallback_sym_x : `Used when the text names no symmetry plane.`
 @return? SESSION_SHAPE : `It parsed, but it is not a session crig wrote.`
*>
fn RigDocument? parse_session(Allocator allocator, String text, float fallback_sym_x = 0.0f)
{
	Object*? parsed = json::parse(allocator, text);
	if (catch parsed) return SESSION_SHAPE~;
	defer parsed.free();
	return session_document(allocator, parsed, fallback_sym_x);
}

fn RigDocument? session_document(Allocator allocator, Object* parsed, float fallback_sym_x) @private
{
	// Required, not merely checked when present: the version is what makes this
	// a crig session rather than some other tool's JSON that happens to sit
	// beside the mesh under the same name. A reader that accepts a file with no
	// version accepts every file.
	double? version = parsed.get_float("version");
	if (catch version) return SESSION_SHAPE~;

	// Any version up to this one, because every field a later version added is
	// optional on the way in — a version 1 file simply names no joints, and its
	// dots come back unnamed. Refusing it would strand the sessions already
	// sitting beside people's meshes for the sake of a field they predate.
	if (version < 1 || version > SESSION_VERSION) return SESSION_SHAPE~;

	// Built here rather than inside the parse so a file that fails validation
	// halfway can be freed: the lists have already taken whatever was adopted
	// before the bad entry, and a fault carries no document back to free.
	RigDocument doc = {
		.auto_connect = true,
		.sym_x = fallback_sym_x,
	};
	doc.dots.init(allocator);
	doc.edges.init(allocator);
	doc.attachments.init(allocator);
	doc.paint.init(allocator);
	doc.pins.init(allocator);
	doc.secondary.init(allocator);
	doc.colliders.init(allocator);
	doc.rotation_limits.init(allocator);
	doc.collision_exclusions.init(allocator);
	doc.animations.init(allocator);

	if (catch parse_document(allocator, &doc, parsed))
	{
		doc.free();
		return SESSION_SHAPE~;
	}
	return doc;
}

<*
 Whether a parsed value can be walked as a list — and the reason it is not
 spelled `Object.is_array()`.

 `std::collections::object` only tags a container as a list once something has
 been pushed into it, so an **empty** JSON array parses as the "empty" object
 and `is_array()` answers false for it. Validating with that predicate refuses
 every rig that has no bones yet, which is every rig up to its second dot.
 `is_indexable()` is the one that means "safe to index", and `get_len()`
 requires exactly it; JSON null is turned away here rather than read as an
 empty list, because a key that says nothing is not a key that says "none".
*>
fn bool is_list(Object* value) @private => !value.is_null() && value.is_indexable();

<*
 The body of `read_session`, faulting freely so the caller does the mapping.

 Fills a document the caller has already initialised, and leaves it partly
 filled when it faults — which is why the caller owns freeing it.
*>
fn void? parse_document(Allocator allocator, RigDocument* doc, Object* parsed) @private
{
	if (try bool b = parsed.get_bool("auto_connect")) doc.auto_connect = b;
	if (try double x = parsed.get_float("sym_x")) doc.sym_x = (float)x;
	if (try Object* transformed = parsed.get("model_transform"))
	{
		if (!transformed.is_keyable()) return SESSION_SHAPE~;
		doc.model_transform.location = session_vec3(transformed.get("location")!)!;
		doc.model_transform.rotation = session_quat(transformed.get("rotation")!)!;
		if (!doc.model_transform.valid()
			|| doc.model_transform.rotation.v.dot(doc.model_transform.rotation.v) <= 1.0e-12f)
		{
			return SESSION_SHAPE~;
		}
		doc.model_transform.rotation = doc.model_transform.orientation();
	}
	// Optional, like every field added after version 1: a file written before
	// body plans were recorded simply declares none, and the library falls back
	// to matching on names the rig has in common with a clip.
	if (try String p = parsed.get_string("plan")) doc.set_plan(p);
	// Absent means the binder, which is what every rig built in crig uses and what
	// every session written before importing existed was bound with.
	if (try bool s = parsed.get_bool("skin_from_file")) doc.skin_from_file = s;
	// Version 11, and absent in every file the writer had nothing to say about —
	// which is read as unset, the binder's own blend. Through the setter rather
	// than assigned, so a hand-edited file naming a power outside the band the
	// arithmetic survives is clamped here instead of reaching the binder.
	if (try double g = parsed.get_float("sharpness")) doc.set_sharpness((float)g);

	Object* dots = parsed.get("dots")!;
	if (!is_list(dots)) return SESSION_SHAPE~;
	for (sz i = 0; i < dots.get_len(); i++)
	{
		Object* entry = dots.get_at(i);
		uint id = entry.get_uint("id")!;
		if (id == 0) return SESSION_SHAPE~;
		Vec3 position = session_vec3(entry.get("position")!)!;

		String name = "";
		if (try String n = entry.get_string("name")) name = n;

		// Absent in every session written before reaches existed, which reads as
		// the unlimited one those rigs were bound with.
		float reach = 0.0f;
		if (try double r = entry.get_float("reach")) reach = (float)r;

		// insert_dot refuses the duplicate and the null id, which is the
		// validation above said out loud; and it keeps next_id honest.
		if (!doc.insert_dot(id, position, name, reach)) return SESSION_SHAPE~;

	}

	// The stored counter wins over the derive — ids above the highest live dot
	// are already spent too — but never falls behind it.
	if (try uint n = parsed.get_uint("next_id"))
	{
		if (n > doc.next_id) doc.next_id = n;
	}

	Object* edges = parsed.get("edges")!;
	if (!is_list(edges)) return SESSION_SHAPE~;
	for (sz i = 0; i < edges.get_len(); i++)
	{
		Object* pair = edges.get_at(i);
		if (!is_list(pair) || pair.get_len() != 2) return SESSION_SHAPE~;
		uint a = pair.get_uint_at(0)!;
		uint b = pair.get_uint_at(1)!;
		// connect rejects self-loops, duplicates and ids that name nothing,
		// which between them is every way an edge can be wrong.
		if (!doc.connect(a, b)) return SESSION_SHAPE~;
	}

	// A root that names nothing falls to the first dot, the same guess
	// add_dot makes — a rootless document exports a skeleton no one asked for.
	uint root = 0;
	if (try uint r = parsed.get_uint("root")) root = r;
	doc.root_id = doc.find(root) != null ? root : (doc.dots.len() > 0 ? doc.dots[0].id : 0);

	// Optional, unlike dots and edges: every session written before shells
	// existed has none, and a rig with nothing pinned writes an empty list.
	if (try Object* pinned = parsed.get("attachments"))
	{
		if (!is_list(pinned)) return SESSION_SHAPE~;
		for (sz i = 0; i < pinned.get_len(); i++)
		{
			Object* pair = pinned.get_at(i);
			if (!is_list(pair) || pair.get_len() != 2) return SESSION_SHAPE~;
			// attach_shell refuses a dot that is not in the document, which is
			// the only way an attachment can name nothing on the way in.
			if (!doc.attach_shell(pair.get_uint_at(0)!, pair.get_uint_at(1)!)) return SESSION_SHAPE~;
		}
	}

	// Optional for the same reason, and refused on the same terms — a triple that
	// is not a triple, or a dot that is not in the document, means this is not a
	// session crig wrote.
	//
	// **Vertex indices are not checked against a mesh**, because there is no mesh
	// here: `core/` reads the document alone, and the file is found from the
	// mesh's path rather than carrying it. A dab past the end of whatever is
	// eventually loaded is dropped by `paint_columns` when the bind asks for it,
	// which is the same answer a stale attachment gets.
	if (try Object* painted = parsed.get("paint"))
	{
		if (!is_list(painted)) return SESSION_SHAPE~;
		for (sz i = 0; i < painted.get_len(); i++)
		{
			Object* dab = painted.get_at(i);
			if (!is_list(dab) || dab.get_len() != 3) return SESSION_SHAPE~;
			if (!doc.set_paint(
				dab.get_uint_at(0)!,
				dab.get_uint_at(1)!,
				(float)dab.get_float_at(2)!)) return SESSION_SHAPE~;
		}
	}

	// Version 12, and read on the paint's terms exactly: optional, since every
	// file written before the lasso existed has no such key, and a triple that is
	// not a triple or a dot that is not in the document means this is not a
	// session crig wrote.
	//
	// Vertex indices are not checked against a mesh here either — there is no
	// mesh in `core/` to check them against, and one past the end of whatever is
	// eventually loaded is dropped by `pin_columns` when the bind asks for it.
	if (try Object* stated = parsed.get("pins"))
	{
		if (!is_list(stated)) return SESSION_SHAPE~;
		for (sz i = 0; i < stated.get_len(); i++)
		{
			Object* pin = stated.get_at(i);
			if (!is_list(pin) || pin.get_len() != 3) return SESSION_SHAPE~;
			if (!doc.set_pin(
				pin.get_uint_at(0)!,
				pin.get_uint_at(1)!,
				(float)pin.get_float_at(2)!)) return SESSION_SHAPE~;
		}
	}

	// Version 16. Absent in every file written before it, which is either a rig
	// whose bones are all the animation's or one carrying the version 9 `physics`
	// key read below — so absence is read as none rather than refused, the rule
	// every optional key here follows.
	//
	// **A chain naming a root the file did not place is dropped, not refused.**
	// That is a softer rule than the paint and the attachments get, and
	// deliberately: a tail whose base joint this rig does not carry should cost
	// that tail rather than the whole session. An unknown preset costs only its
	// label. Every other malformation — a list that is not a list, an entry that
	// is not an object, a value out of its range — still says this is not a
	// session crig wrote. A version 16 entry's `swing` and `thickness` are not
	// read at all: see the version note.
	if (try Object* chains = parsed.get("secondary"))
	{
		if (!is_list(chains)) return SESSION_SHAPE~;
		for (sz i = 0; i < chains.get_len(); i++)
		{
			Object* entry = chains.get_at(i);
			if (!entry.is_keyable()) return SESSION_SHAPE~;
			uint anchor = entry.get_uint("root")!;
			SecondaryChain chain = {
				.root = anchor,
				.tip = entry.get_uint("tip") ?? anchor,
				.preset = secondary_preset_named(entry.get_string("preset") ?? "custom"),
				.flexibility = (float)(entry.get_float("flexibility") ?? 0.0),
				.damping = (float)(entry.get_float("damping") ?? 0.0),
				.gravity = (float)(entry.get_float("gravity") ?? 0.0),
				.collide = entry.get_bool("collide") ?? false,
			};
			if (!secondary_values_sane(chain)) return SESSION_SHAPE~;
			doc.set_secondary(chain);
		}
	}

	// Version 9 to 15: one entry per dynamic bone. Read into the old shape and
	// migrated against the skeleton these dots build, so a tail saved under the
	// old model reopens as the chain it was — `secondary_chains_from_bones` says
	// exactly how much of it survives. A file carrying both keys is not one crig
	// wrote, and the chains already placed win: a migrated run whose root is
	// already taken is left alone.
	if (try Object* dynamic = parsed.get("physics"))
	{
		if (!is_list(dynamic)) return SESSION_SHAPE~;

		JiggleSpec[] bones = alloc::new_array(allocator, JiggleSpec, dynamic.get_len());
		defer alloc::free(allocator, bones);
		for (sz i = 0; i < dynamic.get_len(); i++)
		{
			Object* entry = dynamic.get_at(i);
			if (!entry.is_keyable()) return SESSION_SHAPE~;
			bones[i] = {
				.dot_id = entry.get_uint("id")!,
				.params = {
					.stiffness = (float)(entry.get_float("stiffness") ?? 0.0),
					.damping = (float)(entry.get_float("damping") ?? 0.0),
					.gravity = (float)(entry.get_float("gravity") ?? 0.0),
					.radius = (float)(entry.get_float("radius") ?? 0.0),
				},
			};
		}

		SecondaryChain[] migrated = secondary_chains_from_bones(allocator, doc, bones);
		defer if (migrated.len > 0) alloc::free(allocator, migrated);
		foreach (chain : migrated)
		{
			if (doc.secondary_of(chain.root).present()) continue;
			doc.set_secondary(chain);
		}
	}

	if (try Object* capsules = parsed.get("colliders"))
	{
		if (!is_list(capsules)) return SESSION_SHAPE~;
		for (sz i = 0; i < capsules.get_len(); i++)
		{
			Object* entry = capsules.get_at(i);
			if (!entry.is_keyable()) return SESSION_SHAPE~;
			uint id = entry.get_uint("id")!;
			doc.set_collider(id, (float)(entry.get_float("radius") ?? 0.0));
		}
	}

	// Version 13, and ordinarily absent since 18, when the tables moved into the
	// model — a file that has them is from before, or was written beside a model
	// that could not take them, and either way they are what the rig has until
	// the model says otherwise (see `AppState.adopt_model_limits`). All three rows
	// are present in a written entry so the document round-trips the inactive
	// values too — turning an axis off and on later must restore what the user
	// entered, not defaults guessed on reload.
	if (try Object* limited = parsed.get("rotation_limits"))
	{
		if (!is_list(limited)) return SESSION_SHAPE~;
		for (sz i = 0; i < limited.get_len(); i++)
		{
			Object* entry = limited.get_at(i);
			if (!entry.is_keyable()) return SESSION_SHAPE~;

			uint id = entry.get_uint("id")!;
			foreach (held : doc.rotation_limits.array_view())
			{
				if (held.dot_id == id) return SESSION_SHAPE~;
			}

			JointRotationLimits settings = unconstrained_rotation(id);
			settings.constrained = entry.get_bool("active")!;

			Object* axes = entry.get("axes")!;
			if (!is_list(axes) || axes.get_len() != 3) return SESSION_SHAPE~;
			for (usz a = 0; a < 3; a++)
			{
				Object* axis = axes.get_at((sz)a);
				if (!axis.is_keyable()) return SESSION_SHAPE~;
				settings.axes[a] = {
					.allowed = axis.get_bool("allow")!,
					.minimum = (float)axis.get_float("minimum")!,
					.maximum = (float)axis.get_float("maximum")!,
					.locked = (float)axis.get_float("locked")!,
				};
			}

			if (try uint child = entry.get_uint("primary_child")) settings.primary_child = child;
			if (try Object* frame = entry.get("frame"))
			{
				settings.saved_frame = session_quat(frame)!;
				settings.has_saved_frame = true;
			}

			if (!doc.set_rotation_limits(id, settings)) return SESSION_SHAPE~;
		}
	}

	// Version 14. Absent means the default rules alone, which is every older
	// session. Validated on the edges' terms: `add_exclusion` refuses a pair
	// naming one dot twice, a dot that is not here, or one already listed.
	if (try Object* excluded = parsed.get("collision_exclusions"))
	{
		if (!is_list(excluded)) return SESSION_SHAPE~;
		for (sz i = 0; i < excluded.get_len(); i++)
		{
			Object* pair = excluded.get_at(i);
			if (!is_list(pair) || pair.get_len() != 2) return SESSION_SHAPE~;
			uint a = pair.get_uint_at(0)!;
			uint b = pair.get_uint_at(1)!;
			if (!doc.add_exclusion(a, b)) return SESSION_SHAPE~;
		}
	}

	// Version 15. Absent is the default either way; a clearance that is not a
	// sensible fraction of the model is a fault, not a value to clamp.
	if (try bool allowed = parsed.get_bool("allow_intersections")) doc.allow_intersections = allowed;
	if (try double clearance = parsed.get_float("collision_clearance"))
	{
		if (!math::is_finite(clearance) || clearance <= 0.0 || clearance > MAX_COLLISION_CLEARANCE) return SESSION_SHAPE~;
		doc.collision_clearance = (float)clearance;
	}

	// The bound clips, and the one list here that is *not* checked against the
	// document: a clip names a file and a name inside it, and neither is a dot.
	// Whether the file still exists is settled by the library when it is asked to
	// resolve one — see `AppState.resolve_bound` — and an entry it cannot find is
	// shown as missing rather than dropped, because the user chose it and losing
	// the record silently is the one outcome worth avoiding.
	//
	// A missing `file` is an authored clip, which is a real state and not a
	// malformed one. A missing or empty `clip` is malformed: there is nothing to
	// look up, so it is refused with the rest of the file.
	if (try Object* bound = parsed.get("animations"))
	{
		if (!is_list(bound)) return SESSION_SHAPE~;
		for (sz i = 0; i < bound.get_len(); i++)
		{
			Object* entry = bound.get_at(i);
			if (!entry.is_keyable()) return SESSION_SHAPE~;

			String name = entry.get_string("clip") ?? "";
			if (name.len == 0) return SESSION_SHAPE~;
			doc.bind_clip(entry.get_string("file") ?? "", name);
		}
	}

	if (try Object* maps = parsed.get("joint_maps"))
	{
		if (!is_list(maps)) return SESSION_SHAPE~;
		JointMap[] read = alloc::new_array(mem, JointMap, maps.get_len());
		usz count = 0;
		for (sz i = 0; i < maps.get_len(); i++)
		{
			Object* entry = maps.get_at(i);
			if (!entry.is_keyable()) continue;
			String source = entry.get_string("source") ?? "";
			if (source.len == 0) continue;
			read[count++] = { .file = (entry.get_string("file") ?? "").copy(mem), .source = source.copy(mem),
				.joint = (entry.get_string("joint") ?? "").copy(mem) };
		}
		if (count == 0) { alloc::free(mem, read); } else { doc.set_joint_maps(read[:count]); }
	}

	// The pose library. A malformed pose is skipped rather than failing the
	// whole project.
	if (try Object* poses = parsed.get("poses"))
	{
		if (!is_list(poses)) return SESSION_SHAPE~;
		List{SavedPose} read;
		read.init(mem);
		defer read.free();
		for (sz i = 0; i < poses.get_len(); i++)
		{
			Object* entry = poses.get_at(i);
			if (!entry.is_keyable()) continue;
			String name = entry.get_string("name") ?? "";
			Object*? listed = entry.get("dots");
			if (catch listed) continue;
			Object* pose_dots = listed;
			if (name.len == 0 || !is_list(pose_dots) || pose_dots.get_len() == 0) continue;
			AnimKeyframe held = { .dots = alloc::new_array(mem, AnimKeyDot, pose_dots.get_len()) };
			bool whole = true;
			bool explicit_channels;
			for (sz d = 0; d < pose_dots.get_len(); d++)
			{
				AnimKeyDot? dot = session_key_dot(mem, pose_dots.get_at(d), &explicit_channels);
				if (catch dot) { whole = false; break; }
				held.dots[d] = dot;
			}
			if (!whole) { held.free(mem); continue; }
			read.push({ .name = name.copy(mem), .dots = held.dots });
		}
		if (read.len() > 0) doc.set_poses(read.to_array(mem));
	}
}
