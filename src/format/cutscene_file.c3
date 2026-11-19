<*
 The `CUSTOM_cutscene` file three.c3 plays, written as version 2 (version 1 plus
 `place` and the `turn` strip); the reader takes 1 and 2 so tests can check it.
*>
module crig;

import std::collections::list;
import std::collections::object;
import std::encoding::base64;
import std::encoding::json;
import std::io;
import std::io::file;
import std::math;
import gltf_edit;

const String CUTSCENE_EXTENSION = "CUSTOM_cutscene";
const int CUTSCENE_FORMAT_VERSION = 2;

<* The file is not there, or it is not glTF. *>
excuse CUTSCENE_UNREADABLE;
<* A glTF without the CUSTOM_cutscene extension. *>
excuse CUTSCENE_NOT_A_CUTSCENE;
<* A version other than 1 and 2. *>
excuse CUTSCENE_UNKNOWN_VERSION;
<* A field the format does not allow, or a cutscene the game would refuse. *>
excuse CUTSCENE_MALFORMED;
<* The file could not be written. *>
excuse CUTSCENE_WRITE_FAILED;

// glTF's float component type, and the only one a one-off's accessors use.
const int GLTF_FLOAT = 5126;

// Appends the reason to `why` when there is one, and hands back `kind` to return.
fn fault cut_refuse(fault kind, DString* why, String format, args...) @local
{
	if (why != null) why.appendf(format, ...args)!!;
	return kind;
}

<*
 The file a cutscene named `name` exports to, `<name>.cutscene.glb` or `.gltf`, as the addon names it.

 @return "The caller owns it"
*>
fn String cutscene_file_name(Allocator allocator, String name, bool binary = true)
{
	DString out = dstring::new(allocator);
	defer out.free();
	foreach (c : name)
	{
		bool kept = c >= 0x80 || c.is_alnum() || c == '-' || c == '_' || c == '.';
		out.append_char(kept ? c : '_');
	}
	out.append_string(binary ? ".cutscene.glb" : ".cutscene.gltf");
	return out.copy_str(allocator);
}

// A `.gltf` path is written as text; anything else as a `.glb`.
fn bool cut_text_path(String path) @local
{
	if (path.len < 5) return false;
	String tail = path[^5..];
	foreach (i, c : ".gltf")
	{
		char have = tail[i] >= 'A' && tail[i] <= 'Z' ? (char)(tail[i] + 32) : tail[i];
		if (have != c) return false;
	}
	return true;
}

<*
 Write `cutscene` to `path` through `save_safely`, a `.gltf` as text and anything else as a `.glb`.
 A strip's `animation` indexes `animations`, written as glTF animations on stub nodes.

 @param [in] cutscene
 @param [inout] why : "Gets the reason when it is refused; may be null"
 @param [in] animations : "The one-offs its strips play, baked"
 @require path.len > 0 : "A save needs a path"

 @return? CUTSCENE_MALFORMED, CUTSCENE_WRITE_FAILED
*>
fn void? write_cutscene_file(String path, Cutscene* cutscene, DString* why = null, CutAnimation[] animations = {})
{
	bool text_form = cut_text_path(path);
	char[] binary;
	String text = cutscene_gltf_text(mem, cutscene, why, animations, text_form ? null : &binary)!;
	defer text.free(mem);
	defer if (binary.len > 0) free(binary);
	char[] chunk;
	defer if (chunk.len > 0) free(chunk);
	if (binary.len > 0)
	{
		// The BIN chunk: its length, its type, and the buffer padded with zeros.
		usz padded = (binary.len + 3) & ~(usz)3;
		chunk = mem::new_array(char, (sz)padded + 8);
		bitorder::write((uint)padded, chunk[0:4], UIntLE);
		chunk[4:4] = "BIN\0"[..];
		chunk[8:binary.len] = binary[..];
	}
	GlbParts parts = { .json = (char[])text, .rest = chunk, .version = 2, .binary = !text_form };
	if (catch gltf_edit::write_glb(path, parts))
	{
		return cut_refuse(CUTSCENE_WRITE_FAILED, why, "'%s' could not be written", path)~;
	}
}

<*
 The cutscene as its file's glTF JSON, sorted and rounded as the addon writes it, with the paths a move walks
 and its one-offs as animations. Their buffer goes to `binary` for a `.glb`, or into the text as a data URI.

 @param [in] cutscene
 @param [inout] why : "Gets the reason when it is refused; may be null"
 @param [in] animations : "The one-offs its strips play, baked"
 @param [out] binary : "Gets the buffer's bytes for a .glb chunk, the caller's to free; null embeds them"

 @return "The caller owns it"
 @return? CUTSCENE_MALFORMED
*>
fn String? cutscene_gltf_text(Allocator allocator, Cutscene* cutscene, DString* why = null, CutAnimation[] animations = {},
	char[]* binary = null)
{
	cut_check_writable(cutscene, why, animations)!;

	// The paths a move walks, renumbered in their order in the cutscene.
	int[] slot = cutscene.paths.len > 0 ? mem::new_array(int, (sz)cutscene.paths.len) : {};
	defer if (slot.len > 0) free(slot);
	foreach (&slot_of : slot) *slot_of = -1;
	foreach (&actor : cutscene.actors)
	{
		foreach (&s : actor.strips) if (s.kind == MOVE) slot[s.path] = 0;
	}
	int written = 0;
	foreach (&slot_of : slot) if (*slot_of == 0) *slot_of = written++;

	DString out = dstring::new(allocator);
	defer out.free();
	out.append_string(`{"asset":{"version":"2.0","generator":"rigsmith"},`);
	out.append_string("\n\"extensionsUsed\":[");
	gltf_edit::escape_json_string(&out, CUTSCENE_EXTENSION);
	out.append_string("],\n\"extensions\":{");
	gltf_edit::escape_json_string(&out, CUTSCENE_EXTENSION);
	out.appendf(`:{"version":%d,"name":`, CUTSCENE_FORMAT_VERSION)!!;
	gltf_edit::escape_json_string(&out, cutscene.name);
	out.append_string(`,"duration":`);
	cut_write_number(&out, cutscene.duration);
	out.append_string(`,"fps":`);
	cut_write_number(&out, cutscene.fps);

	if (cutscene.actors.len > 0)
	{
		out.append_string(`,"actors":[`);
		foreach (usz i, &actor : cutscene.actors)
		{
			if (i > 0) out.append_char(',');
			cut_write_actor(&out, actor, i, slot);
		}
		out.append_string("]");
	}
	if (written > 0)
	{
		out.append_string(`,"paths":[`);
		int listed = 0;
		foreach (usz i, &path : cutscene.paths)
		{
			if (slot[i] < 0) continue;
			if (listed++ > 0) out.append_char(',');
			out.append_string("\n{\"name\":");
			gltf_edit::escape_json_string(&out, path.name);
			out.append_string(`,"length":`);
			cut_write_number(&out, path.length);
			out.append_string(`,"points":[`);
			foreach (usz k, point : path.points)
			{
				if (k > 0) out.append_char(',');
				cut_write_point(&out, point);
			}
			out.append_string("]}");
		}
		out.append_string("]");
	}
	out.append_string("}},");

	// The stub nodes exist only to carry names: an actor's, then one per bone its one-offs move, under it.
	out.append_string("\n\"scene\":0,\"scenes\":[{\"name\":");
	gltf_edit::escape_json_string(&out, cutscene.name);
	if (cutscene.actors.len > 0)
	{
		out.append_string(`,"nodes":[`);
		for (usz i = 0; i < cutscene.actors.len; i++) out.appendf(i == 0 ? "%d" : ",%d", i)!!;
		out.append_string("]");
	}
	out.append_string("}]");
	List{CutBoneStub} bones;
	bones.init(mem);
	defer bones.free();
	foreach (&a : animations)
	{
		foreach (&c : a.channels)
		{
			if (cut_bone_stub(bones.array_view(), a.actor, c.bone) < 0) bones.push({ a.actor, c.bone });
		}
	}
	if (cutscene.actors.len > 0)
	{
		out.append_string(",\n\"nodes\":[");
		foreach (usz i, &actor : cutscene.actors)
		{
			out.append_string(i == 0 ? "{\"name\":" : ",{\"name\":");
			gltf_edit::escape_json_string(&out, actor.row);
			if (actor.uid.len > 0)
			{
				out.append_string(`,"uid":`);
				gltf_edit::escape_json_string(&out, actor.uid);
			}
			bool listed = false;
			foreach (usz b, bone : bones)
			{
				if (bone.actor != i) continue;
				out.append_string(listed ? "," : `,"children":[`);
				out.appendf("%d", cutscene.actors.len + b)!!;
				listed = true;
			}
			if (listed) out.append_char(']');
			out.append_char('}');
		}
		foreach (bone : bones)
		{
			out.append_string(",{\"name\":");
			gltf_edit::escape_json_string(&out, bone.name);
			out.append_char('}');
		}
		out.append_string("]");
	}
	if (animations.len > 0) cut_write_animations(&out, cutscene, animations, bones.array_view(), binary);
	out.append_string("}\n");
	return out.copy_str(allocator);
}

// A bone's stub node: the actor it hangs under and the bone's name (borrowed).
struct CutBoneStub @local
{
	usz actor;
	String name;
}

fn sz cut_bone_stub(CutBoneStub[] bones, usz actor, String name) @local
{
	foreach (usz i, b : bones) if (b.actor == actor && b.name == name) return (sz)i;
	return -1;
}

<*
 The one-offs as glTF animations, each channel a LINEAR sampler over float accessors, one buffer view
 each, in one buffer: in the `.glb`'s chunk when `binary` is given, else as a data URI.
*>
fn void cut_write_animations(DString* out, Cutscene* cutscene, CutAnimation[] animations, CutBoneStub[] bones, char[]* binary) @local
{
	DString blob = dstring::new(mem);
	defer blob.free();
	DString views = dstring::new(mem);
	defer views.free();
	DString accessors = dstring::new(mem);
	defer accessors.free();
	usz accessor = 0;
	out.append_string(",\n\"animations\":[");
	foreach (usz i, &a : animations)
	{
		out.append_string(i == 0 ? "{\"name\":" : ",\n{\"name\":");
		gltf_edit::escape_json_string(out, a.name);
		out.append_string(`,"channels":[`);
		foreach (usz k, &c : a.channels)
		{
			usz node = cutscene.actors.len + (usz)cut_bone_stub(bones, a.actor, c.bone);
			String path = c.path == TRANSLATION ? "translation" : c.path == ROTATION ? "rotation" : "scale";
			out.appendf(`%s{"sampler":%d,"target":{"node":%d,"path":"%s"}}`, k == 0 ? "" : ",", k, node, path)!!;
		}
		out.append_string(`],"samplers":[`);
		foreach (usz k, &c : a.channels)
		{
			out.appendf(`%s{"input":%d,"output":%d,"interpolation":"LINEAR"}`, k == 0 ? "" : ",", accessor, accessor + 1)!!;
			float first = c.times[0];
			float last = c.times[^1];
			cut_append_view(&views, &blob, c.times);
			accessors.appendf(`%s{"bufferView":%d,"componentType":%d,"count":%d,"type":"SCALAR","min":[`,
				accessor == 0 ? "" : ",", accessor, GLTF_FLOAT, c.times.len)!!;
			gltf_edit::write_json_double(&accessors, (double)first);
			accessors.append_string(`],"max":[`);
			gltf_edit::write_json_double(&accessors, (double)last);
			accessors.append_string("]}");
			cut_append_view(&views, &blob, c.values);
			accessors.appendf(`,{"bufferView":%d,"componentType":%d,"count":%d,"type":"%s"}`,
				accessor + 1, GLTF_FLOAT, c.times.len, c.path == ROTATION ? "VEC4" : "VEC3")!!;
			accessor += 2;
		}
		out.append_string("]}");
	}
	out.append_string("]");
	out.append_string(",\n\"accessors\":[");
	out.append_string(accessors.str_view());
	out.append_string("],\n\"bufferViews\":[");
	out.append_string(views.str_view());
	out.appendf("],\n\"buffers\":[{\"byteLength\":%d", blob.len())!!;
	if (binary)
	{
		*binary = (char[])blob.str_view().copy(mem);
	}
	else
	{
		out.append_string(`,"uri":"data:application/octet-stream;base64,`);
		String encoded = base64::encode(mem, (char[])blob.str_view());
		defer encoded.free(mem);
		out.append_string(encoded);
		out.append_char('"');
	}
	out.append_string("}]");
}

// One buffer view over `values`, appended little-endian to the blob.
fn void cut_append_view(DString* views, DString* blob, float[] values) @local
{
	usz at = (usz)blob.len();
	char[4] bytes;
	foreach (v : values)
	{
		bitorder::write(bitcast(v, uint), bytes[..], UIntLE);
		blob.append_string((String)bytes[..]);
	}
	views.appendf(`%s{"buffer":0,"byteOffset":%d,"byteLength":%d}`, at == 0 ? "" : ",", at, values.len * 4)!!;
}

// What three.c3 would refuse to play, refused here so it is never written.
fn void? cut_check_writable(Cutscene* cutscene, DString* why, CutAnimation[] animations) @local
{
	foreach (usz i, &a : animations)
	{
		if (a.actor >= cutscene.actors.len)
		{
			return cut_refuse(CUTSCENE_MALFORMED, why, "animations[%d] '%s' plays on no actor", i, a.name)~;
		}
		if (a.channels.len == 0)
		{
			return cut_refuse(CUTSCENE_MALFORMED, why, "the one-off '%s' of %s keys nothing", a.name, cutscene.actors[a.actor].row)~;
		}
		foreach (&c : a.channels)
		{
			bool shaped = c.bone.len > 0 && c.times.len > 0 && c.values.len == c.times.len * c.width();
			for (usz k = 1; shaped && k < c.times.len; k++) shaped = c.times[k] > c.times[k - 1];
			foreach (v : c.values) shaped = shaped && math::is_finite(v);
			foreach (t : c.times) shaped = shaped && math::is_finite(t) && t >= 0.0f;
			if (!shaped)
			{
				return cut_refuse(CUTSCENE_MALFORMED, why, "the one-off '%s' has a bad channel on '%s'", a.name, c.bone)~;
			}
		}
	}
	foreach (usz i, &actor : cutscene.actors)
	{
		if (actor.row.len == 0)
		{
			return cut_refuse(CUTSCENE_MALFORMED, why, "actors[%d] has no row, which is how the game finds it", i)~;
		}
		int first = cutscene.actor_by_row(actor.row);
		if (first != (int)i)
		{
			return cut_refuse(CUTSCENE_MALFORMED, why, "actors[%d] and actors[%d] are both '%s'", first, i, actor.row)~;
		}
		foreach (usz k, &s : actor.strips)
		{
			switch (s.kind)
			{
				case MOVE:
					if (!(s.end > s.start))
					{
						return cut_refuse(CUTSCENE_MALFORMED, why, "actors[%d].strips[%d]: a move needs an end after its start", i, k)~;
					}
					if (s.path < 0 || s.path >= cutscene.paths.len)
					{
						return cut_refuse(CUTSCENE_MALFORMED, why, "actors[%d].strips[%d].path is %d, and the cutscene has %d paths",
							i, k, s.path, cutscene.paths.len)~;
					}
					if (cutscene.paths[s.path].points.len < 2)
					{
						return cut_refuse(CUTSCENE_MALFORMED, why, "actors[%d].strips[%d] walks '%s', which has under 2 points",
							i, k, cutscene.paths[s.path].name)~;
					}
				case TURN:
					if (!(s.end > s.start))
					{
						return cut_refuse(CUTSCENE_MALFORMED, why, "actors[%d].strips[%d]: a turn needs an end after its start", i, k)~;
					}
					if (s.target_row.len > 0 && cutscene.actor_by_row(s.target_row) < 0)
					{
						return cut_refuse(CUTSCENE_MALFORMED, why, "actors[%d].strips[%d].actor is '%s', and this cutscene has no actor of that row",
							i, k, s.target_row)~;
					}
				case PLAY:
					if (s.end < s.start)
					{
						return cut_refuse(CUTSCENE_MALFORMED, why, "actors[%d].strips[%d]: end is before start", i, k)~;
					}
			}
			if (s.kind == TURN) continue;
			if (s.one_off && s.animation < 0)
			{
				return cut_refuse(CUTSCENE_MALFORMED, why, "%s: the %s at %.2f s plays the one-off '%s', which this cutscene does not have",
					actor.row, s.kind == MOVE ? "move" : "play", s.start, s.clip)~;
			}
			if (s.animation < 0) continue;
			if (s.clip.len == 0)
			{
				return cut_refuse(CUTSCENE_MALFORMED, why, "actors[%d].strips[%d]: a one-off animation needs the clip name it plays as", i, k)~;
			}
			if (s.animation >= animations.len || animations[s.animation].actor != i)
			{
				return cut_refuse(CUTSCENE_MALFORMED, why, "actors[%d].strips[%d] plays the one-off '%s' as animation %d, which %s has none of",
					i, k, s.clip, s.animation, actor.row)~;
			}
		}
	}
}

fn void cut_write_actor(DString* out, CutActor* actor, usz node, int[] slot) @local
{
	out.append_string("\n{\"row\":");
	gltf_edit::escape_json_string(out, actor.row);
	if (actor.uid.len > 0)
	{
		out.append_string(`,"uid":`);
		gltf_edit::escape_json_string(out, actor.uid);
	}
	out.appendf(`,"node":%d`, node)!!;
	if (actor.no_level_node)
	{
		out.append_string(`,"place":{"position":`);
		cut_write_point(out, actor.home);
		out.appendf(`,"rotation":%s}`, (JsonQuat)actor.home_rotation)!!;
	}
	out.append_string(`,"strips":[`);

	// Sorted by start, strips that start together kept in order, as the player sorts them.
	usz[] order = actor.strips.len > 0 ? mem::new_array(usz, (sz)actor.strips.len) : {};
	defer if (order.len > 0) free(order);
	for (usz i = 0; i < order.len; i++)
	{
		usz k = i;
		while (k > 0 && actor.strips[order[k - 1]].start > actor.strips[i].start)
		{
			order[k] = order[k - 1];
			k--;
		}
		order[k] = i;
	}
	foreach (usz i, at : order)
	{
		if (i > 0) out.append_char(',');
		CutStrip* s = &actor.strips[at];
		cut_write_strip(out, s, s.kind == MOVE ? slot[s.path] : -1);
	}
	out.append_string("]}");
}

// `scene` adds what only the scene file keeps: a typed ground speed, a play's held speed, and which strips play one-offs.
fn void cut_write_strip(DString* out, CutStrip* s, int path, bool scene = false) @local
{
	switch (s.kind)
	{
		case MOVE: out.append_string("\n{\"type\":\"move\"");
		case TURN: out.append_string("\n{\"type\":\"turn\"");
		case PLAY: out.append_string("\n{\"type\":\"play\"");
	}
	out.append_string(`,"start":`);
	cut_write_number(out, s.start);
	out.append_string(`,"end":`);
	cut_write_number(out, s.end);
	switch (s.kind)
	{
		case MOVE:
			out.appendf(`,"path":%d,"ease":"%s","turn":%s`, path, cut_ease_name(s.ease), s.turn ? "true" : "false")!!;
			if (scene && s.ground_speed > 0.0f)
			{
				out.append_string(`,"ground_speed":`);
				cut_write_number(out, s.ground_speed);
			}
			cut_write_clip(out, s, scene);
		case PLAY:
			cut_write_clip(out, s, scene);
			if (scene && s.ground_speed > 0.0f)
			{
				out.append_string(`,"ground_speed":`);
				cut_write_number(out, s.ground_speed);
			}
			if (scene && s.speed_held) out.append_string(`,"speed_held":true`);
		case TURN:
			out.appendf(`,"ease":"%s"`, cut_ease_name(s.ease))!!;
			if (s.target_row.len > 0)
			{
				out.append_string(`,"actor":`);
				gltf_edit::escape_json_string(out, s.target_row);
			}
			else
			{
				out.append_string(`,"point":`);
				cut_write_point(out, s.target);
			}
	}
	out.append_char('}');
}

fn void cut_write_clip(DString* out, CutStrip* s, bool scene) @local
{
	if (s.clip.len == 0) return;
	out.append_string(`,"clip":`);
	gltf_edit::escape_json_string(out, s.clip);
	out.appendf(`,"loop":%s,"speed":`, s.loop ? "true" : "false")!!;
	cut_write_number(out, s.speed);
	out.append_string(`,"fade":`);
	cut_write_number(out, s.fade);
	if (math::abs(s.offset) > 1e-6f)
	{
		out.append_string(`,"offset":`);
		cut_write_number(out, s.offset);
	}
	if (scene && s.one_off) out.append_string(`,"one_off":true`);
	if (!scene && s.animation >= 0) out.appendf(`,"animation":%d`, s.animation)!!;
}

fn String cut_ease_name(CutEase ease) @local
{
	switch (ease)
	{
		case LINEAR: return "linear";
		case IN: return "in";
		case OUT: return "out";
		case INOUT: return "inout";
	}
}

// Rounded to four places as the addon rounds, and never -0.
fn void cut_write_number(DString* out, float value) @local
{
	double rounded = math::round((double)value * 10000.0) / 10000.0 + 0.0;
	gltf_edit::write_json_double(out, rounded);
}

fn void cut_write_point(DString* out, Vec3 point) @local
{
	out.append_char('[');
	cut_write_number(out, point.x);
	out.append_char(',');
	cut_write_number(out, point.y);
	out.append_char(',');
	cut_write_number(out, point.z);
	out.append_char(']');
}

<*
 The cutscene in the scene file's form, as `cutscene_from_json` reads it: a move's
 `path` is its index into this cutscene's paths, and each path keeps its knots.

 @param [&inout] out
 @param [in] cutscene
 @param points : "Write each path's samples too, not only those of a path with no knots"
 @param [in] links : "One per actor to name its character and level node, or none"
 @require links.len == 0 || links.len == cutscene.actors.len : "One link per actor"
*>
fn void append_cutscene_json(DString* out, Cutscene* cutscene, bool points = false, CutActorLink[] links = {})
{
	out.append_string(`{"name":`);
	gltf_edit::escape_json_string(out, cutscene.name);
	out.append_string(`,"duration":`);
	cut_write_number(out, cutscene.duration);
	out.append_string(`,"fps":`);
	cut_write_number(out, cutscene.fps);
	out.append_string(`,"actors":[`);
	foreach (usz i, &actor : cutscene.actors)
	{
		out.append_string(i == 0 ? `{"row":` : `,{"row":`);
		gltf_edit::escape_json_string(out, actor.row);
		if (actor.uid.len > 0)
		{
			out.append_string(`,"uid":`);
			gltf_edit::escape_json_string(out, actor.uid);
		}
		if (links.len > 0)
		{
			out.appendf(`,"character":%d,"level_node":`, links[i].character)!!;
			gltf_edit::escape_json_string(out, links[i].level_node);
		}
		out.append_string(`,"strips":[`);
		foreach (usz k, &s : actor.strips)
		{
			if (k > 0) out.append_char(',');
			cut_write_strip(out, s, s.path, scene: true);
		}
		out.append_string("]}");
	}
	out.append_string(`],"paths":[`);
	foreach (usz i, &path : cutscene.paths)
	{
		out.append_string(i == 0 ? `{"name":` : `,{"name":`);
		gltf_edit::escape_json_string(out, path.name);
		out.append_string(`,"length":`);
		cut_write_number(out, path.length);
		out.append_string(`,"knots":`);
		cut_write_points(out, path.knots);
		if (points || path.knots.len == 0)
		{
			out.append_string(`,"points":`);
			cut_write_points(out, path.points);
		}
		out.append_char('}');
	}
	out.append_string("]");
	if (cutscene.one_offs.len > 0)
	{
		out.append_string(`,"one_offs":[`);
		foreach (usz i, &one : cutscene.one_offs)
		{
			out.append_string(i == 0 ? `{"row":` : `,{"row":`);
			gltf_edit::escape_json_string(out, one.row);
			out.append_string(`,"clip":`);
			append_session_clip(out, one.clip);
			out.append_char('}');
		}
		out.append_string("]");
	}
	out.append_string("}");
}

fn void cut_write_points(DString* out, Vec3[] points) @local
{
	out.append_char('[');
	foreach (usz k, point : points)
	{
		if (k > 0) out.append_char(',');
		cut_write_point(out, point);
	}
	out.append_char(']');
}

<*
 Read a version 1 or 2 cutscene file, keeping a strip's `animation` index; with `animations`, the
 one-offs too, each channel named by its bone stub.

 @param [inout] why : "Gets the reason when it is refused; may be null"
 @param [out] animations : "Gets the file's animations, the caller's to free; null reads none"

 @return "The caller owns it; see Cutscene.free"
 @return? CUTSCENE_UNREADABLE, CUTSCENE_NOT_A_CUTSCENE, CUTSCENE_UNKNOWN_VERSION, CUTSCENE_MALFORMED
*>
fn Cutscene? read_cutscene_file(Allocator allocator, String path, DString* why = null, CutAnimation[]* animations = null)
{
	GlbParts? parts = gltf_edit::split_glb(mem, path);
	if (catch parts) return cut_refuse(CUTSCENE_UNREADABLE, why, "'%s' is not there or is not a glTF file", path)~;
	defer parts.free(mem);
	// A .glb's buffer is its BIN chunk, which follows the JSON chunk.
	char[] chunk;
	if (parts.rest.len >= 8 && parts.rest[4:4] == "BIN\0")
	{
		usz length = (usz)bitorder::read(parts.rest[0:4], UIntLE);
		if (length <= parts.rest.len - 8) chunk = parts.rest[8:length];
	}
	return parse_cutscene_text(allocator, (String)parts.json, why, animations, chunk, scene_folder(path));
}

struct CutReading @local
{
	long version;
	WalkPath[] paths;
	usz animations;
	DString* why;
	// The scene's own form: knots kept, and what the problems list names is read, not refused.
	bool lenient;
}

<*
 Read a cutscene file's glTF JSON, as `read_cutscene_file` does.

 @param [inout] why : "Gets the reason when it is refused; may be null"
 @param [out] animations : "Gets the file's animations, the caller's to free; null reads none"
 @param binary : "A .glb's buffer, for its animations"
 @param folder : "Where a buffer's relative uri is read from"

 @return "The caller owns it; see Cutscene.free"
 @return? CUTSCENE_UNREADABLE, CUTSCENE_NOT_A_CUTSCENE, CUTSCENE_UNKNOWN_VERSION, CUTSCENE_MALFORMED
*>
fn Cutscene? parse_cutscene_text(Allocator allocator, String text, DString* why = null, CutAnimation[]* animations = null,
	char[] binary = {}, String folder = ".")
{
	Object*? parsed = json::parse(mem, text);
	if (catch parsed) return cut_refuse(CUTSCENE_UNREADABLE, why, "not a glTF file: its JSON does not parse")~;
	defer parsed.free();
	Object* ext = member(member(parsed, "extensions"), CUTSCENE_EXTENSION);
	if (ext == null || !ext.is_map())
	{
		return cut_refuse(CUTSCENE_NOT_A_CUTSCENE, why, "this glTF has no %s extension, so it is not a cutscene", CUTSCENE_EXTENSION)~;
	}
	Object* version = member(ext, "version");
	double number = 0.0;
	if (version != null && (version.is_int() || version.is_float())) number = ext.get_float("version")!!;
	if (number != 1.0 && number != 2.0)
	{
		return cut_refuse(CUTSCENE_UNKNOWN_VERSION, why, "%s is version %s, and this reads versions 1 and 2",
			CUTSCENE_EXTENSION, version == null ? "missing" : string::tformat("%s", version))~;
	}

	Object* listed = member(parsed, "animations");
	CutReading reading = {
		.version = (long)number,
		.animations = listed != null && listed.is_array() ? (usz)listed.get_len() : 0,
		.why = why,
	};
	Cutscene cutscene = cut_read_body(allocator, ext, &reading)!;
	if (!animations) return cutscene;
	defer catch cutscene.free(allocator);
	*animations = cut_read_animations(allocator, parsed, ext, binary, folder, why)!;
	return cutscene;
}

<*
 The file's animations as baked one-offs: each channel's bone is its target stub's name, and the
 animation's actor the one whose stub node that bone hangs under.

 @return? CUTSCENE_MALFORMED
*>
fn CutAnimation[]? cut_read_animations(Allocator allocator, Object* doc, Object* ext, char[] binary, String folder, DString* why) @local
{
	Object* listed = member(doc, "animations");
	if (listed == null) return {};
	if (!listed.is_array()) return cut_refuse(CUTSCENE_MALFORMED, why, "animations is not an array")~;
	Object* nodes = member(doc, "nodes");
	usz node_count = nodes != null && nodes.is_array() ? (usz)nodes.get_len() : 0;
	// The buffer: the .glb's chunk, a data URI, or a file beside this one.
	char[] buffer = binary;
	char[] owned;
	defer if (owned.len > 0) alloc::free(mem, owned);
	Object* buffers = member(doc, "buffers");
	if (buffers != null && buffers.is_array() && buffers.get_len() > 0)
	{
		Object* uri = member(buffers.get_at(0), "uri");
		if (uri != null && uri.is_string() && uri.s.starts_with("data:"))
		{
			usz comma = (usz)(uri.s.index_of_char(',') ?? 0);
			owned = base64::decode(mem, uri.s[comma + 1..]) ?? (char[]){};
			buffer = owned;
		}
		else if (uri != null && uri.is_string())
		{
			owned = file::load(mem, string::tformat("%s/%s", folder, uri.s)) ?? (char[]){};
			buffer = owned;
		}
	}
	List{CutAnimation} out;
	out.init(allocator);
	defer catch
	{
		foreach (&a : out) a.free(allocator);
		out.free();
	}
	Object* actors = member(ext, "actors");
	for (usz i = 0; i < (usz)listed.get_len(); i++)
	{
		Object* raw = listed.get_at((sz)i);
		CutAnimation made = { .name = cut_read_string(allocator, raw, "name", "an animation", why)! };
		List{CutChannel} channels;
		channels.init(allocator);
		Object* list = member(raw, "channels");
		Object* samplers = member(raw, "samplers");
		bool shaped = list != null && list.is_array() && samplers != null && samplers.is_array();
		for (usz k = 0; shaped && k < (usz)list.get_len(); k++)
		{
			Object* channel = list.get_at((sz)k);
			Object* target = member(channel, "target");
			long sampler = channel.get_long("sampler") ?? -1;
			long node = target != null ? target.get_long("node") ?? -1 : -1;
			String path = target != null ? target.get_string("path") ?? "" : "";
			if (sampler < 0 || sampler >= samplers.get_len() || node < 0 || (usz)node >= node_count)
			{
				shaped = false;
				break;
			}
			CutChannel c;
			switch (path)
			{
				case "translation": c.path = TRANSLATION;
				case "rotation": c.path = ROTATION;
				case "scale": c.path = SCALE;
				default: continue;
			}
			Object* s = samplers.get_at((sz)sampler);
			c.times = cut_read_floats(allocator, doc, s.get_long("input") ?? -1, buffer, 1) ?? (float[]){};
			c.values = cut_read_floats(allocator, doc, s.get_long("output") ?? -1, buffer, c.width()) ?? (float[]){};
			c.bone = (nodes.get_at((sz)node).get_string("name") ?? "").copy(allocator);
			made.actor = cut_stub_actor(nodes, actors, (usz)node);
			if (c.times.len == 0 || c.values.len != c.times.len * c.width()) shaped = false;
			channels.push(c);
		}
		made.channels = channels.len() > 0 ? channels.to_array(allocator) : {};
		channels.free();
		if (!shaped)
		{
			made.free(allocator);
			return cut_refuse(CUTSCENE_MALFORMED, why, "animations[%d] has a channel the file cannot back", i)~;
		}
		out.push(made);
	}
	CutAnimation[] read = out.len() > 0 ? out.to_array(allocator) : {};
	out.free();
	return read;
}

// The actor whose stub node is `node` or a parent of it; the count of actors when none is.
fn usz cut_stub_actor(Object* nodes, Object* actors, usz node) @local
{
	usz count = actors != null && actors.is_array() ? (usz)actors.get_len() : 0;
	for (usz a = 0; a < count; a++)
	{
		long stub = actors.get_at((sz)a).get_long("node") ?? -1;
		if (stub < 0 || (usz)stub >= (usz)nodes.get_len()) continue;
		if ((usz)stub == node) return a;
		Object* children = member(nodes.get_at((sz)stub), "children");
		if (children == null || !children.is_array()) continue;
		for (usz k = 0; k < (usz)children.get_len(); k++)
		{
			if ((children.get_long_at((sz)k) ?? -1) == (long)node) return a;
		}
	}
	return count;
}

// An accessor's floats, `width` a element, when it is a tightly packed float accessor inside `buffer`.
fn float[]? cut_read_floats(Allocator allocator, Object* doc, long index, char[] buffer, usz width) @local
{
	Object* accessors = member(doc, "accessors");
	Object* views = member(doc, "bufferViews");
	if (index < 0 || accessors == null || views == null || index >= accessors.get_len()) return CUTSCENE_MALFORMED~;
	Object* accessor = accessors.get_at((sz)index);
	long view_index = accessor.get_long("bufferView") ?? -1;
	if ((accessor.get_long("componentType") ?? 0) != GLTF_FLOAT || view_index < 0 || view_index >= views.get_len()) return CUTSCENE_MALFORMED~;
	String type = accessor.get_string("type") ?? "";
	usz elements = type == "SCALAR" ? 1 : type == "VEC3" ? 3 : type == "VEC4" ? 4 : 0;
	if (elements != width) return CUTSCENE_MALFORMED~;
	Object* view = views.get_at((sz)view_index);
	usz count = (usz)(accessor.get_long("count") ?? 0);
	usz at = (usz)(view.get_long("byteOffset") ?? 0) + (usz)(accessor.get_long("byteOffset") ?? 0);
	usz stride = (usz)(view.get_long("byteStride") ?? 0);
	if ((stride != 0 && stride != width * 4) || at + count * width * 4 > buffer.len) return CUTSCENE_MALFORMED~;
	float[] out = alloc::new_array(allocator, float, (sz)(count * width));
	foreach (usz k, &v : out) *v = bitcast(bitorder::read(buffer[at + k * 4:4], UIntLE), float);
	return out;
}

<*
 A cutscene in the scene file's form: the extension's fields, with each path's
 `knots` (its points resampled from them) and, unlike the file, a move without a
 usable path or a turn toward a missing actor kept for the problems list.

 @param [in] raw : "The cutscene object"
 @param [inout] why : "Gets the reason when it is refused; may be null"

 @return "The caller owns it; see Cutscene.free"
 @return? CUTSCENE_MALFORMED
*>
fn Cutscene? cutscene_from_json(Allocator allocator, Object* raw, DString* why = null)
{
	if (raw == null || !raw.is_map()) return cut_refuse(CUTSCENE_MALFORMED, why, "a cutscene is an object")~;
	CutReading reading = { .version = CUTSCENE_FORMAT_VERSION, .why = why, .lenient = true };
	Cutscene cutscene = cut_read_body(allocator, raw, &reading)!;
	foreach (&path : cutscene.paths)
	{
		if (path.knots.len > 0) path.resample(allocator);
	}
	return cutscene;
}

fn Cutscene? cut_read_body(Allocator allocator, Object* ext, CutReading* reading) @local
{
	DString* why = reading.why;
	Cutscene cutscene = { .fps = CUT_DEFAULT_FPS };
	defer catch cutscene.free(allocator);
	cutscene.name = cut_read_string(allocator, ext, "name", "the cutscene", why)!;
	cutscene.fps = (float)cut_read_number(ext, "fps", CUT_DEFAULT_FPS, "the cutscene", why)!;

	Object* paths = member(ext, "paths");
	if (paths != null)
	{
		if (!paths.is_array()) return cut_refuse(CUTSCENE_MALFORMED, why, "paths is not an array")~;
		if (paths.get_len() > 0) cutscene.paths = alloc::new_array(allocator, WalkPath, paths.get_len());
		foreach (usz i, &path : cutscene.paths)
		{
			char[32] buffer;
			String where = string::bformat(&buffer, "paths[%d]", i);
			*path = cut_read_path(allocator, paths.get_at((sz)i), where, reading)!;
		}
	}
	reading.paths = cutscene.paths;

	Object* actors = member(ext, "actors");
	if (actors != null)
	{
		if (!actors.is_array()) return cut_refuse(CUTSCENE_MALFORMED, why, "actors is not an array")~;
		if (actors.get_len() > 0) cutscene.actors = alloc::new_array(allocator, CutActor, actors.get_len());
		foreach (usz i, &actor : cutscene.actors)
		{
			cut_read_actor(allocator, actors.get_at((sz)i), i, reading, actor)!;
		}
	}
	// A turn faces an actor of this cutscene, which the player checks as it loads.
	foreach (usz i, &actor : cutscene.actors)
	{
		foreach (usz k, &s : actor.strips)
		{
			if (reading.lenient || s.kind != TURN || s.target_row.len == 0 || cutscene.actor_by_row(s.target_row) >= 0) continue;
			return cut_refuse(CUTSCENE_MALFORMED, why, "actors[%d].strips[%d].actor is '%s', and this cutscene has no actor of that row",
				i, k, s.target_row)~;
		}
	}

	// The scene keeps its one-offs; the file's are animations, read apart.
	Object* one_offs = member(ext, "one_offs");
	if (reading.lenient && one_offs != null)
	{
		if (!one_offs.is_array()) return cut_refuse(CUTSCENE_MALFORMED, why, "one_offs is not an array")~;
		if (one_offs.get_len() > 0) cutscene.one_offs = alloc::new_array(allocator, CutOneOff, one_offs.get_len());
		foreach (usz i, &one : cutscene.one_offs)
		{
			Object* raw = one_offs.get_at((sz)i);
			Object* row = member(raw, "row");
			Object* clip = member(raw, "clip");
			if (row == null || !row.is_string() || row.s.len == 0 || clip == null || !clip.is_map())
			{
				return cut_refuse(CUTSCENE_MALFORMED, why, "one_offs[%d] is { row, clip }", i)~;
			}
			AnimTemplate? read = parse_session_clip(allocator, clip);
			if (catch read) return cut_refuse(CUTSCENE_MALFORMED, why, "one_offs[%d].clip is not a clip Rigsmith reads", i)~;
			*one = { .row = row.s.copy(allocator), .clip = read };
		}
	}

	// Without a duration the cutscene lasts until its last strip ends, as the player reads it.
	float last = 0.0f;
	foreach (&actor : cutscene.actors)
	{
		foreach (&s : actor.strips) last = math::max(last, s.end);
	}
	cutscene.duration = (float)cut_read_number(ext, "duration", last, "the cutscene", why)!;
	return cutscene;
}

// A string under `key`, empty when absent; refused when it is something else.
fn String? cut_read_string(Allocator allocator, Object* obj, String key, String where, DString* why) @local
{
	Object* value = member(obj, key);
	if (value == null) return "";
	if (!value.is_string()) return cut_refuse(CUTSCENE_MALFORMED, why, "%s.%s is not a string", where, key)~;
	return value.s.len > 0 ? value.s.copy(allocator) : "";
}

// A number under `key`, `fallback` when absent; refused when it is something else.
fn double? cut_read_number(Object* obj, String key, double fallback, String where, DString* why) @local
{
	Object* value = member(obj, key);
	if (value == null) return fallback;
	if (!value.is_int() && !value.is_float()) return cut_refuse(CUTSCENE_MALFORMED, why, "%s.%s is not a number", where, key)~;
	double number = obj.get_float(key)!!;
	if (!math::is_finite(number)) return cut_refuse(CUTSCENE_MALFORMED, why, "%s.%s is not a number", where, key)~;
	return number;
}

fn bool? cut_read_bool(Object* obj, String key, bool fallback, String where, DString* why) @local
{
	Object* value = member(obj, key);
	if (value == null) return fallback;
	if (!value.is_bool()) return cut_refuse(CUTSCENE_MALFORMED, why, "%s.%s is true or false", where, key)~;
	return value.b;
}

fn Vec3? cut_read_point(Object* value, String where, DString* why) @local
{
	Vec3 point;
	if (!as_vec3(value, &point)) return cut_refuse(CUTSCENE_MALFORMED, why, "%s wants [x, y, z]", where)~;
	return point;
}

fn CutEase? cut_read_ease(Object* raw, String where, DString* why) @local
{
	Object* value = member(raw, "ease");
	if (value == null) return INOUT;
	if (value.is_string())
	{
		switch (value.s)
		{
			case "linear": return LINEAR;
			case "in": return IN;
			case "out": return OUT;
			case "inout": return INOUT;
		}
	}
	return cut_refuse(CUTSCENE_MALFORMED, why, "%s.ease is one of linear, in, out, inout", where)~;
}

fn WalkPath? cut_read_path(Allocator allocator, Object* raw, String where, CutReading* reading) @local
{
	DString* why = reading.why;
	if (raw == null || !raw.is_map()) return cut_refuse(CUTSCENE_MALFORMED, why, "%s is not an object", where)~;
	WalkPath path;
	defer catch path.free(allocator);
	path.name = cut_read_string(allocator, raw, "name", where, why)!;
	if (reading.lenient) path.knots = cut_read_points(allocator, member(raw, "knots"), where, "knots", true, why)!;
	path.points = cut_read_points(allocator, member(raw, "points"), where, "points", reading.lenient, why)!;
	float measured = 0.0f;
	for (usz k = 1; k < path.points.len; k++) measured += (path.points[k] - path.points[k - 1]).length();
	path.length = (float)cut_read_number(raw, "length", measured, where, why)!;
	return path;
}

// An array of [x, y, z] under `key`; an absent one is empty when `optional`.
fn Vec3[]? cut_read_points(Allocator allocator, Object* points, String where, String key, bool optional, DString* why) @local
{
	if (points == null && optional) return {};
	if (points == null || !points.is_array()) return cut_refuse(CUTSCENE_MALFORMED, why, "%s.%s is an array of [x, y, z]", where, key)~;
	if (points.get_len() == 0) return {};
	Vec3[] out = alloc::new_array(allocator, Vec3, points.get_len());
	defer catch alloc::free(allocator, out);
	foreach (usz k, &point : out)
	{
		char[48] buffer;
		*point = cut_read_point(points.get_at((sz)k), string::bformat(&buffer, "%s.%s[%d]", where, key, k), why)!;
	}
	return out;
}

fn void? cut_read_actor(Allocator allocator, Object* raw, usz index, CutReading* reading, CutActor* actor) @local
{
	DString* why = reading.why;
	char[32] buffer;
	String where = string::bformat(&buffer, "actors[%d]", index);
	if (raw == null || !raw.is_map()) return cut_refuse(CUTSCENE_MALFORMED, why, "%s is not an object", where)~;
	Object* row = member(raw, "row");
	if (row == null || !row.is_string() || row.s.len == 0)
	{
		return cut_refuse(CUTSCENE_MALFORMED, why, "%s.row names the object to drive", where)~;
	}
	actor.row = row.s.copy(allocator);
	actor.uid = cut_read_string(allocator, raw, "uid", where, why)!;
	actor.home_rotation = quaternion::IDENTITY;

	Object* place = member(raw, "place");
	if (place != null)
	{
		if (reading.version < 2)
		{
			return cut_refuse(CUTSCENE_MALFORMED, why, "%s.place needs %s version 2, and the file says version 1", where, CUTSCENE_EXTENSION)~;
		}
		if (!place.is_map()) return cut_refuse(CUTSCENE_MALFORMED, why, "%s.place wants { position, rotation }", where)~;
		char[48] at;
		actor.home = cut_read_point(member(place, "position"), string::bformat(&at, "%s.place.position", where), why)!;
		Object* turn = member(place, "rotation");
		double[4] q;
		bool shaped = turn != null && turn.is_array() && turn.get_len() == 4;
		for (usz k = 0; shaped && k < 4; k++)
		{
			double? v = turn.get_float_at((sz)k);
			if (catch v)
			{
				shaped = false;
				break;
			}
			q[k] = v;
		}
		if (!shaped) return cut_refuse(CUTSCENE_MALFORMED, why, "%s.place.rotation wants a quaternion [x, y, z, w]", where)~;
		double length = math::sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]);
		if (length < 1e-6) return cut_refuse(CUTSCENE_MALFORMED, why, "%s.place.rotation is all zero, which is no rotation", where)~;
		actor.home_rotation = { .v = { (float)(q[0] / length), (float)(q[1] / length), (float)(q[2] / length), (float)(q[3] / length) } };
		actor.no_level_node = true;
	}

	Object* strips = member(raw, "strips");
	if (strips == null) return;
	if (!strips.is_array()) return cut_refuse(CUTSCENE_MALFORMED, why, "%s.strips is not an array", where)~;
	if (strips.get_len() > 0) actor.strips = alloc::new_array(allocator, CutStrip, strips.get_len());
	foreach (usz k, &strip : actor.strips)
	{
		char[48] at;
		*strip = cut_read_strip(allocator, strips.get_at((sz)k), string::bformat(&at, "%s.strips[%d]", where, k), reading)!;
	}
}

fn CutStrip? cut_read_strip(Allocator allocator, Object* raw, String where, CutReading* reading) @local
{
	DString* why = reading.why;
	if (raw == null || !raw.is_map()) return cut_refuse(CUTSCENE_MALFORMED, why, "%s is not an object", where)~;
	Object* type = member(raw, "type");
	CutStripKind kind;
	switch (type != null && type.is_string() ? type.s : "")
	{
		case "move": kind = MOVE;
		case "play": kind = PLAY;
		case "turn": kind = TURN;
		default:
			return cut_refuse(CUTSCENE_MALFORMED, why, "%s: type is 'move', 'play' or 'turn'", where)~;
	}
	if (kind == TURN && reading.version < 2)
	{
		return cut_refuse(CUTSCENE_MALFORMED, why, "%s.type 'turn' needs %s version 2, and the file says version 1", where, CUTSCENE_EXTENSION)~;
	}
	CutStrip s = cut_strip(kind, 0.0f, 0.0f);
	defer catch s.free(allocator);
	s.start = (float)cut_read_number(raw, "start", 0.0, where, why)!;
	// Every strip Rigsmith writes has an end; a play strip without one runs on in the player.
	if (member(raw, "end") == null) return cut_refuse(CUTSCENE_MALFORMED, why, "%s has no end", where)~;
	s.end = (float)cut_read_number(raw, "end", 0.0, where, why)!;

	if (kind == TURN)
	{
		if (member(raw, "clip") != null || member(raw, "animation") != null)
		{
			return cut_refuse(CUTSCENE_MALFORMED, why, "%s: a turn plays no clip", where)~;
		}
		if (!(s.end > s.start)) return cut_refuse(CUTSCENE_MALFORMED, why, "%s: a turn needs an end after its start", where)~;
		s.ease = cut_read_ease(raw, where, why)!;
		Object* point = member(raw, "point");
		Object* actor = member(raw, "actor");
		if ((point == null) == (actor == null))
		{
			return cut_refuse(CUTSCENE_MALFORMED, why, "%s: a turn faces a point: [x, y, z] or an actor: '<row>', %s",
				where, point == null ? "names neither" : "not both")~;
		}
		if (actor != null)
		{
			if (!actor.is_string() || actor.s.len == 0)
			{
				return cut_refuse(CUTSCENE_MALFORMED, why, "%s.actor is the row of the actor to face", where)~;
			}
			s.target_row = actor.s.copy(allocator);
			return s;
		}
		char[64] at;
		s.target = cut_read_point(point, string::bformat(&at, "%s.point", where), why)!;
		return s;
	}

	s.clip = cut_read_string(allocator, raw, "clip", where, why)!;
	s.loop = cut_read_bool(raw, "loop", kind == MOVE, where, why)!;
	s.speed = (float)cut_read_number(raw, "speed", 1.0, where, why)!;
	s.fade = (float)cut_read_number(raw, "fade", CUT_DEFAULT_FADE, where, why)!;
	s.offset = (float)cut_read_number(raw, "offset", 0.0, where, why)!;
	Object* animation = member(raw, "animation");
	if (animation != null)
	{
		long index = animation.is_int() ? (long)animation.i : -1;
		if (index < 0) return cut_refuse(CUTSCENE_MALFORMED, why, "%s.animation is the index of an animation in the file", where)~;
		if (s.clip.len == 0) return cut_refuse(CUTSCENE_MALFORMED, why, "%s: a one-off animation needs the clip name it plays as", where)~;
		if ((usz)index >= reading.animations)
		{
			return cut_refuse(CUTSCENE_MALFORMED, why, "%s.animation is %d, and the file has %d animations", where, index, reading.animations)~;
		}
		s.animation = (int)index;
		s.one_off = true;
	}
	// The scene's own form names a one-off by its clip, which the problems list checks.
	if (reading.lenient) s.one_off = cut_read_bool(raw, "one_off", false, where, why)!;

	if (kind == PLAY)
	{
		if (s.end < s.start) return cut_refuse(CUTSCENE_MALFORMED, why, "%s: end is before start", where)~;
		if (!reading.lenient) return s;
		float typed = (float)cut_read_number(raw, "ground_speed", 0.0, where, why)!;
		s.ground_speed = typed > 0.0f ? typed : 0.0f;
		s.speed_held = cut_read_bool(raw, "speed_held", false, where, why)!;
		return s;
	}
	if (!(s.end > s.start)) return cut_refuse(CUTSCENE_MALFORMED, why, "%s: a move needs an end after its start", where)~;
	Object* path = member(raw, "path");
	long index = path != null && path.is_int() ? (long)path.i : -1;
	if (reading.lenient)
	{
		// Kept as it is; the problems list says when there is nothing to walk.
		s.path = index < 0 || index > 0x7fff_ffff ? -1 : (int)index;
		s.ease = cut_read_ease(raw, where, why)!;
		s.turn = cut_read_bool(raw, "turn", true, where, why)!;
		float typed = (float)cut_read_number(raw, "ground_speed", 0.0, where, why)!;
		s.ground_speed = typed > 0.0f ? typed : 0.0f;
		return s;
	}
	if (index < 0 || (usz)index >= reading.paths.len)
	{
		usz count = reading.paths.len;
		return cut_refuse(CUTSCENE_MALFORMED, why, "%s.path is %s, and the file has %d path%s", where,
			path == null ? "missing" : string::tformat("%s", path), count, count == 1 ? "" : "s")~;
	}
	if (reading.paths[index].points.len < 2)
	{
		return cut_refuse(CUTSCENE_MALFORMED, why, "%s: a move needs a path of at least 2 points", where)~;
	}
	s.path = (int)index;
	s.ease = cut_read_ease(raw, where, why)!;
	s.turn = cut_read_bool(raw, "turn", true, where, why)!;
	return s;
}
