<*
 Changing what a glTF file says about itself, without rewriting what is in it.

 Renaming an animation, or tagging a file with the body plan its clips are for,
 means changing a handful of string values in the document's JSON. Everything
 else in that JSON — accessor bounds, node transforms, buffer views — has to
 come back out exactly as it went in, and a .glb's binary chunk must not be
 touched at all.

 	`JsonStep[3] where = { { .key = "animations" }, { .at = 0 }, { .key = "name" } };`
 	`JsonEdit[1] edits = { { .path = where[..], .value = "Walk" } };`
 	`gltf_edit::patch_gltf(mem, "walk.glb", edits[..])!;`

 **Nothing here is parsed and printed back.** A round trip through
 `std::collections::object` writes floats with `%g`, which rounds an accessor's
 min/max and a node's transform to six significant digits, and writes strings
 with no escaping at all. Either one silently corrupts a model. What this does
 instead is scan the raw text for the byte span of the one value being changed
 and splice the new bytes over it: every byte outside that span is copied
 through untouched, so a file that is patched twice differs from the original
 only where it was asked to.

 Both container forms are handled, told apart by the magic rather than by the
 extension. A `.gltf` is JSON from its first byte. A `.glb` is a header and a
 run of chunks, of which only the JSON one is rewritten — every later chunk is
 copied byte for byte, and the header's total length is recomputed around them.

 Three things in one file on purpose: the container split, the text splice, and
 the two writers that build the values going in. None of them is a feature of
 glTF, and none is interesting on its own — together they are one operation, and a
 reader who never needs to edit a file never needs to open this. If the standard
 library's JSON printer ever escapes its strings, keeps a float's digits and tells
 an empty array from an empty object, most of the scanning below can be deleted
 and this becomes a page.

 This lived in `gltf.c3l` and does not any more. Reading a glTF is a job with one
 shape and a library's worth of readers; editing one in place is a job with as
 many shapes as there are things to edit, and the file kept growing a case for
 each of crig's. It sits here now, in a module of its own, so that the library
 stays the thing anybody could use and this stays the thing only a rigging tool
 wants. Nothing here reaches back into `gltf` — the container constants below are
 the spec's, and a second copy of four magic numbers is cheaper than a dependency.
*>
module gltf_edit;

import std::collections::list;



import std::io;
import std::io::file;
import std::math;
import std::math::vector;
import std::math::quaternion;

<*
 Raised when the text does not parse far enough to reach the value asked for —
 an unterminated string, a member with no colon after it, a chunk that is not
 JSON at all.
*>
faultdef GLTF_PATCH_MALFORMED;

<*
 Raised when the path names something the document does not have and cannot be
 given: an array element past the end, or a member of a value that is not an
 object. A **missing member** is not this — the last step of a path is created
 when it is not there, and an object on the way to it is created empty.
*>
faultdef GLTF_PATCH_NO_SUCH_PATH;

<*
 One step down into a document: an object member by name, or an array element
 by position.

 An empty `key` selects by `at` instead. Nothing addresses a member called "",
 so the two cannot be confused.
*>
struct JsonStep
{
	String key;
	usz at;
}

<*
 One string value to write, and where it sits.

 The path is read from the document root and **must end on a key** — this
 writes named members, and an array of bare strings is not a shape glTF
 metadata takes.

 An empty `value` removes the member rather than writing an empty one, so a
 plan that is cleared leaves a file with no `plan` key rather than one that says
 nothing. Removing a member that is not there is not an error.
*>
struct JsonEdit
{
	JsonStep[] path;
	String value;
}

// Where a member sits: the opening quote of its name, its value, and the byte
// after that value. Replacing a value wants the last two; removing the member
// wants all three, plus whichever comma is beside it.
struct JsonMember
{
	usz key_start;
	usz value_start;
	usz value_end;
}

<*
 glTF's slot for whatever the authoring tool wanted to say about the file as a
 whole, and the object crig's own keys sit in — see `PACK_KEY_PLAN`.

 Named here rather than at each use because a caller assembling a path spells it
 once per key, and this is the one step of that path that is not the key itself.
*>
const String GLTF_EXTRAS = "extras";

<*
 Rewrite a glTF file's metadata where it lies.

 The file is read whole, patched in memory and written back over itself, so a
 failure part-way through leaves the original in place — nothing is truncated
 before the replacement exists.

 @param path : `The .glb or .gltf to change.`
 @param edits : `Applied in order; a later one sees what an earlier one wrote.`
 @return? GLTF_PATCH_MALFORMED : `The JSON could not be scanned as far as the path.`
 @return? GLTF_PATCH_NO_SUCH_PATH : `The path names an element the document does not have.`
*>
fn void? patch_gltf(Allocator allocator, String path, JsonEdit[] edits)
{
	// Both container forms through one door: `split_glb` decides which it is by
	// the magic rather than the extension, and a .gltf comes back as its whole
	// text with nothing after it.
	return patch_glb(allocator, path, edits);
}

<*
 Every edit applied to one JSON document.

 The text side of `patch_gltf`, split out because it is the whole of the logic
 and needs no file: a check can hand it a document and read the answer back.

 @param text : `The document. Not modified.`
 @return `A new document; the caller owns it.`
*>
fn String? patch_gltf_text(Allocator allocator, String text, JsonEdit[] edits)
{
	String working = text.copy(allocator);
	bool kept = false;
	defer if (!kept) alloc::free(allocator, working.ptr);

	foreach (edit : edits)
	{
		String next = apply_edit(allocator, working, edit)!;
		alloc::free(allocator, working.ptr);
		working = next;
	}

	kept = true;
	return working;
}

// ---------------------------------------------------------------------------
// One edit

<*
 One value written, as a new document.

 Recursive, and bounded by the path: each pass writes in at most one missing
 object and starts again on the result, so no byte offset has to survive a
 splice. A path is three steps at the outside, so the depth is too.
*>
fn String? apply_edit(Allocator allocator, String text, JsonEdit edit) @local
{
	if (edit.path.len == 0 || edit.path[^1].key.len == 0) return GLTF_PATCH_NO_SUCH_PATH~;

	// An object on the way that is not there yet — the root `extras` of a file
	// whose author never wrote one. Written in empty, then the whole edit is run
	// again against the grown text.
	for (usz s = 0; s + 1 < edit.path.len; s++)
	{
		if (edit.path[s].key.len == 0) continue;
		if (try walk_to(text, edit.path[:s + 1])) continue;

		String grown = insert_member(allocator, text, edit.path[:s], edit.path[s].key, "{}")!;
		defer alloc::free(allocator, grown.ptr);
		return apply_edit(allocator, grown, edit);
	}

	usz parent = walk_to(text, edit.path[:edit.path.len - 1])!;

	JsonMember? found = find_member(text, parent, edit.path[^1].key);
	if (catch fault why = found)
	{
		if (why == GLTF_PATCH_MALFORMED) return GLTF_PATCH_MALFORMED~;

		// Not there: nothing to remove, or a member to write in.
		if (edit.value.len == 0) return text.copy(allocator);

		String literal = quoted(allocator, edit.value);
		defer alloc::free(allocator, literal.ptr);
		return insert_member(allocator, text, edit.path[:edit.path.len - 1], edit.path[^1].key, literal);
	}

	if (edit.value.len == 0) return remove_member(allocator, text, parent, found);

	DString out = dstring::new(allocator);
	defer out.free();
	out.append_string(text[:found.value_start]);
	escape_json_string(&out, edit.value);
	out.append_string(text[found.value_end..]);
	return out.copy_str(allocator);
}

<*
 `value` as a JSON string literal, quotes and escapes included.

 A temporary for `insert_member`, which takes its value as raw JSON so that it
 can also write an empty object.
*>
fn String quoted(Allocator allocator, String value) @private
{
	DString out = dstring::new(allocator);
	defer out.free();
	escape_json_string(&out, value);
	return out.copy_str(allocator);
}

<*
 A member written into the object at `parent_path`, as a new document.

 At the front of the object rather than the back: the front is one byte past a
 brace this has already found, and the back would mean scanning for the matching
 one and then working out whether the last member has a trailing comma.

 @param raw : `The value as it should appear in the file — already quoted if it is a string.`
*>
fn String? insert_member(
	Allocator allocator,
	String text,
	JsonStep[] parent_path,
	String key,
	String raw) @local
{
	usz object_at = walk_to(text, parent_path)!;
	if (object_at >= text.len || text[object_at] != '{') return GLTF_PATCH_NO_SUCH_PATH~;

	usz first = skip_json_space(text, object_at + 1);
	bool empty = first < text.len && text[first] == '}';

	DString out = dstring::new(allocator);
	defer out.free();
	out.append_string(text[:object_at + 1]);
	escape_json_string(&out, key);
	out.append_char(':');
	out.append_string(raw);
	if (!empty) out.append_char(',');
	out.append_string(text[object_at + 1..]);
	return out.copy_str(allocator);
}

<*
 A member cut out, as a new document.

 The comma goes with it. Which one depends on where the member sits: a member
 with anything after it takes the comma that follows, and the last member of an
 object takes the one before it — leaving either behind writes a document that
 will not parse.
*>
fn String? remove_member(
	Allocator allocator,
	String text,
	usz object_at,
	JsonMember member) @local
{
	usz cut_from = member.key_start;
	usz cut_to = member.value_end;

	usz after = skip_json_space(text, cut_to);
	if (after < text.len && text[after] == ',')
	{
		cut_to = after + 1;
	}
	else
	{
		// Scanned back rather than remembered: the member was found by a forward
		// walk that does not keep where it came from.
		usz back = cut_from;
		while (back > object_at + 1 && is_json_space(text[back - 1])) back--;
		if (back > object_at + 1 && text[back - 1] == ',') cut_from = back - 1;
	}

	DString out = dstring::new(allocator);
	defer out.free();
	out.append_string(text[:cut_from]);
	out.append_string(text[cut_to..]);
	return out.copy_str(allocator);
}

// ---------------------------------------------------------------------------
// Scanning

<*
 Where the value at `path` begins.

 An empty path is the document itself, which is what makes a one-step edit find
 the root object without a special case.
*>
fn usz? walk_to(String text, JsonStep[] path) @local
{
	usz at = skip_json_space(text, 0);
	foreach (step : path)
	{
		if (step.key.len > 0)
		{
			JsonMember found = find_member(text, at, step.key)!;
			at = found.value_start;
			continue;
		}
		at = find_element(text, at, step.at)!;
	}
	return at;
}

<*
 One member of the object beginning at `object_at`.

 Member names are compared as the bytes between their quotes, with no escapes
 decoded. Every name glTF defines is a plain identifier, so this is exact for
 them and simply fails to match an escaped name — which is the safe direction:
 a miss writes a second member, and a false hit would overwrite the wrong one.

 @return? GLTF_PATCH_NO_SUCH_PATH : `The object has no such member, or this is not an object.`
 @return? GLTF_PATCH_MALFORMED : `The object could not be scanned to its end.`
*>
fn JsonMember? find_member(String text, usz object_at, String key) @local
{
	if (object_at >= text.len || text[object_at] != '{') return GLTF_PATCH_NO_SUCH_PATH~;

	usz i = skip_json_space(text, object_at + 1);
	while (i < text.len)
	{
		if (text[i] == '}') return GLTF_PATCH_NO_SUCH_PATH~;

		usz key_start = i;
		usz key_end = end_of_json_string(text, i)!;

		i = skip_json_space(text, key_end);
		if (i >= text.len || text[i] != ':') return GLTF_PATCH_MALFORMED~;
		i = skip_json_space(text, i + 1);

		usz value_start = i;
		usz value_end = end_of_json_value(text, i)!;
		if (text[key_start + 1 : key_end - key_start - 2] == key)
		{
			return { .key_start = key_start, .value_start = value_start, .value_end = value_end };
		}

		i = skip_json_space(text, value_end);
		if (i >= text.len) return GLTF_PATCH_MALFORMED~;
		if (text[i] == '}') return GLTF_PATCH_NO_SUCH_PATH~;
		if (text[i] != ',') return GLTF_PATCH_MALFORMED~;
		i = skip_json_space(text, i + 1);
	}
	return GLTF_PATCH_MALFORMED~;
}

<*
 Where element `which` of the array beginning at `array_at` starts.

 @return? GLTF_PATCH_NO_SUCH_PATH : `The array is shorter than that, or this is not an array.`
 @return? GLTF_PATCH_MALFORMED : `The array could not be scanned as far as that element.`
*>
fn usz? find_element(String text, usz array_at, usz which) @local
{
	if (array_at >= text.len || text[array_at] != '[') return GLTF_PATCH_NO_SUCH_PATH~;

	usz i = skip_json_space(text, array_at + 1);
	for (usz seen = 0; i < text.len; seen++)
	{
		if (text[i] == ']') return GLTF_PATCH_NO_SUCH_PATH~;
		if (seen == which) return i;

		i = skip_json_space(text, end_of_json_value(text, i)!);
		if (i >= text.len) return GLTF_PATCH_MALFORMED~;
		if (text[i] == ']') return GLTF_PATCH_NO_SUCH_PATH~;
		if (text[i] != ',') return GLTF_PATCH_MALFORMED~;
		i = skip_json_space(text, i + 1);
	}
	return GLTF_PATCH_MALFORMED~;
}

<*
 One past the value beginning at `at`, whatever kind of value it is.
*>
fn usz? end_of_json_value(String text, usz at) @local
{
	if (at >= text.len) return GLTF_PATCH_MALFORMED~;

	switch (text[at])
	{
		case '"':
			return end_of_json_string(text, at);
		case '{':
		case '[':
			return end_of_json_nest(text, at);
		default:
			// A number or one of the three bare words. It runs to the first byte
			// that can only belong to what comes after it, which is why there is no
			// need to know which of the four this is.
			for (usz i = at; i < text.len; i++)
			{
				if (!ends_json_token(text[i])) continue;
				if (i == at) return GLTF_PATCH_MALFORMED~;
				return i;
			}
			return GLTF_PATCH_MALFORMED~;
	}
}

<*
 One past the string beginning at `at`, which must be its opening quote.
*>
fn usz? end_of_json_string(String text, usz at) @local
{
	if (at >= text.len || text[at] != '"') return GLTF_PATCH_MALFORMED~;

	for (usz i = at + 1; i < text.len; i++)
	{
		// A backslash takes the next byte with it whatever that byte is, which is
		// all this needs to know: an escape is never a closing quote, and the six
		// forms differ only in what they mean.
		if (text[i] == '\\')
		{
			i++;
			continue;
		}
		if (text[i] == '"') return i + 1;
	}
	return GLTF_PATCH_MALFORMED~;
}

<*
 One past the object or array beginning at `at`.

 Strings are skipped whole rather than counted through, so a brace inside a name
 does not close the object around it.
*>
fn usz? end_of_json_nest(String text, usz at) @local
{
	usz depth = 0;
	usz i = at;
	while (i < text.len)
	{
		char c = text[i];
		if (c == '"')
		{
			i = end_of_json_string(text, i)!;
			continue;
		}
		if (c == '{' || c == '[') depth++;
		if (c == '}' || c == ']')
		{
			depth--;
			if (depth == 0) return i + 1;
		}
		i++;
	}
	return GLTF_PATCH_MALFORMED~;
}

fn bool is_json_space(char c) @local => c == ' ' || c == '\t' || c == '\n' || c == '\r';

// What a number or a bare word can be followed by, and nothing a number or a
// bare word can contain.
fn bool ends_json_token(char c) @local
{
	return c == ',' || c == '}' || c == ']' || is_json_space(c);
}

fn usz skip_json_space(String text, usz at) @local
{
	while (at < text.len && is_json_space(text[at])) at++;
	return at;
}

// ---------------------------------------------------------------------------
// Whole files
//
// The three calls a caller reaches for, over a path rather than over text.

<*
 A .glb rewritten with a patched JSON chunk.

 The container work is `split_glb`'s: it hands back the JSON text with its padding
 trimmed and every later chunk as one opaque run, so all that happens here is a
 splice between the two. The binary buffer, and any extension chunk after it, are
 bytes this function never looks at.
*>
fn void? patch_glb(Allocator allocator, String path, JsonEdit[] edits) @local
{
	GlbParts parts = split_glb(allocator, path)!;
	defer parts.free(allocator);

	String patched = patch_gltf_text(allocator, (String)parts.json, edits)!;

	// Handed over rather than aliased: the old text goes now and the new text is
	// the part set's, so `parts.free` is the only release either needs.
	alloc::free(allocator, parts.json);
	parts.json = (char[])patched;

	return write_glb(path, parts);
}

<*
 Set one member of a file's root `extras`, in place, changing nothing else.

 	`gltf_edit::patch_extra(mem, "character.glb", "mytool", `{"version":1}`)!;`

 The shorthand for what every tool stamping its own metadata onto somebody else's
 asset wants, and the reason it is a named function rather than a path spelled out
 at each call: `extras` is a shared room. Blender writes custom properties there,
 exporters leave notes, and a tool that replaces the whole object to add one key
 deletes theirs without saying so. This writes one member and leaves the rest.

 The value is stored as a JSON **string**, which is what `GltfStream` keeps —
 its extras map is string-valued and drops anything else — so a structured payload
 goes in as its own JSON text and comes back out of `stream.gltf.extras` ready to
 be parsed.

 @param key : `The member name inside extras. Use your tool's own so it cannot collide.`
 @param value : `Stored as a string. Pass JSON text to carry a structure.`
*>
fn void? patch_extra(Allocator allocator, String path, String key, String value)
{
	JsonStep[2] where = { { .key = GLTF_EXTRAS }, { .key = key } };
	JsonEdit[1] edits = { { .path = where[..], .value = value } };
	return patch_gltf(allocator, path, edits[..]);
}

<*
 Set one member to text written exactly as given.

 	`String grown = gltf_edit::patch_raw(mem, text, where[..], `[1,2,3]`)!;`

 The other half of `patch_gltf_text`, which writes strings and only strings —
 quoted, escaped, and no use at all for a number, an array or an object. This
 writes the bytes it is handed, so a caller assembling glTF's own vocabulary
 (accessors, node lists, buffer lengths) can put them where they go.

 **Nothing checks that `raw` is JSON.** It is spliced in whole, so a caller that
 hands over something malformed writes a malformed document — which is the price
 of not going through a printer that would round the floats.

 The path must end on a key, like every other edit here. A member that is not
 there is written in; one that is, is replaced.

 @param raw : `The value exactly as it should appear in the file.`
 @return `A new document; the caller owns it.`
*>
fn String? patch_raw(Allocator allocator, String text, JsonStep[] path, String raw)
{
	if (path.len == 0 || path[^1].key.len == 0) return GLTF_PATCH_NO_SUCH_PATH~;
	if (raw.len == 0) return GLTF_PATCH_NO_SUCH_PATH~;

	// The same growing pass `apply_edit` makes, and for the same case: a member
	// whose enclosing object the file never wrote.
	for (usz s = 0; s + 1 < path.len; s++)
	{
		if (path[s].key.len == 0) continue;
		if (try walk_to(text, path[:s + 1])) continue;

		String grown = insert_member(allocator, text, path[:s], path[s].key, "{}")!;
		defer alloc::free(allocator, grown.ptr);
		return patch_raw(allocator, grown, path, raw);
	}

	usz parent = walk_to(text, path[:path.len - 1])!;

	JsonMember? found = find_member(text, parent, path[^1].key);
	if (catch fault why = found)
	{
		if (why == GLTF_PATCH_MALFORMED) return GLTF_PATCH_MALFORMED~;
		return insert_member(allocator, text, path[:path.len - 1], path[^1].key, raw);
	}

	DString out = dstring::new(allocator);
	defer out.free();
	out.append_string(text[:found.value_start]);
	out.append_string(raw);
	out.append_string(text[found.value_end..]);
	return out.copy_str(allocator);
}

<*
 Replace the whole value at a path with text written exactly as given.

 	`String grown = gltf_edit::patch_raw_value(mem, text, where[..], `{"joints":[0,1]}`)!;`

 The one edit `patch_raw` cannot make: its path has to end on a key, because it
 may have to *write* the member in, and there is no such thing as writing in an
 array element that is not there. This replaces a value that already exists,
 which lets a path end on an index — `skins[0]`, `meshes[2].primitives[0]`.

 @param raw : `The value exactly as it should appear in the file.`
 @return? GLTF_PATCH_NO_SUCH_PATH : `The path names nothing.`
*>
fn String? patch_raw_value(Allocator allocator, String text, JsonStep[] path, String raw)
{
	if (path.len == 0 || raw.len == 0) return GLTF_PATCH_NO_SUCH_PATH~;

	usz at = walk_to(text, path)!;
	usz to = end_of_json_value(text, at)!;

	DString out = dstring::new(allocator);
	defer out.free();
	out.append_string(text[:at]);
	out.append_string(raw);
	out.append_string(text[to..]);
	return out.copy_str(allocator);
}

<*
 A JSON array's elements, each as the text it is written as.

 	`String[] nodes = gltf_edit::json_array_items(mem, array_text)!;`

 What a caller rewriting one entry of a long array needs: every other entry has
 to go back exactly as it came, and the only way to promise that is to copy its
 bytes rather than to re-print a parse of them.

 The items are **borrowed** from `array_text` — the array holding them is the
 caller's to free, the strings in it are not.

 @param array_text : `A JSON array, from its opening bracket to its closing one.`
 @return? GLTF_PATCH_MALFORMED : `It is not an array, or it does not close.`
*>
fn String[]? json_array_items(Allocator allocator, String array_text)
{
	usz at = skip_json_space(array_text, 0);
	if (at >= array_text.len || array_text[at] != '[') return GLTF_PATCH_MALFORMED~;

	List{String} items;
	items.init(allocator);
	// `to_array` copies rather than hands over its storage, so the list has to go
	// whichever way this returns.
	defer items.free();

	at++;
	while (true)
	{
		at = skip_json_space(array_text, at);
		if (at >= array_text.len) return GLTF_PATCH_MALFORMED~;
		if (array_text[at] == ']') break;

		usz from = at;
		usz to;
		switch (array_text[at])
		{
			case '{':
			case '[':
				to = end_of_json_nest(array_text, at)!;
			case '"':
				to = end_of_json_string(array_text, at)!;
			default:
				// A number, or one of the three bare words. It runs to whatever
				// ends a token, which is the same rule the value scanner uses.
				to = at;
				while (to < array_text.len && !ends_json_token(array_text[to])) to++;
				if (to == from) return GLTF_PATCH_MALFORMED~;
		}

		items.push(array_text[from : to - from]);

		at = skip_json_space(array_text, to);
		if (at < array_text.len && array_text[at] == ',') at++;
	}

	return items.to_array(allocator);
}

<*
 Read one member's raw text back out of a document.

 	`String mine = gltf_edit::read_gltf_member(text, where[..]);`

 The text as it is stored, not a parsed value: a caller that wrote an object gets
 that object's source and parses it however it likes, and one that wrote a string
 gets it with its quotes on. Nothing is unescaped, because the caller is what
 escaped it.

 @return `The value's text, borrowed from the document; empty when the path finds nothing.`
*>
fn String read_gltf_member(String text, JsonStep[] path)
{
	if (path.len == 0 || path[^1].key.len == 0) return "";

	usz? parent = walk_to(text, path[:path.len - 1]);
	if (catch parent) return "";

	JsonMember? found = find_member(text, parent, path[^1].key);
	if (catch found) return "";

	return text[found.value_start : found.value_end - found.value_start];
}

// ---------------------------------------------------------------------------
// The .glb container
//
// A file taken apart far enough to edit its JSON and no further. Everything past
// the JSON chunk is one opaque run, which is exactly why it survives: nothing
// here interprets it, so nothing here can perturb it.

// The four words the specification fixes: the file's magic, and the type tag on
// each of its two chunks. `gltf.c3l`'s writer has its own copies and keeps them
// private to itself; these are the same numbers read from the same spec, not a
// fork of anything. `@private` rather than `@local` so `reskin.c3` — which grows
// the BIN chunk — can name its tag without exporting it to the app.
const uint GLB_MAGIC      @private = 0x46546C67; // "glTF"
const uint GLB_CHUNK_JSON @private = 0x4E4F534A; // "JSON"
const uint GLB_CHUNK_BIN  @private = 0x004E4942; // "BIN\0"

<*
 Raised when a file begins with the glTF magic but is too short to hold the
 chunks its header claims.
*>
faultdef GLB_TRUNCATED;

<*
 Raised when the rewritten file could not be opened, written or closed.

 Distinct from `gltf::WRITE_FAILED`, which is the writer's: that one means a file
 could not be built, this one means an existing file could not be replaced.
*>
faultdef GLB_WRITE_FAILED;

<*
 Raised when a binary glTF's first chunk is not the JSON one. The specification
 requires it, and a file that breaks the rule cannot be edited by a reader that
 has no idea what it is holding instead.
*>
faultdef GLB_NO_JSON_CHUNK;

<*
 A glTF taken apart far enough to edit its JSON, and no further.

 `rest` is everything past the JSON chunk — the `BIN` chunk's header and payload,
 and whatever else follows — kept as one opaque run so that putting the file back
 together cannot perturb it. Nothing here interprets it, which is exactly why it
 survives.

 `version` is the container's, echoed back on write. It is not the asset version
 in the JSON.
*>
struct GlbParts
{
	char[] json;
	char[] rest;
	uint version;
	bool binary;
}

<*
 Release what `split_glb` allocated.

 A caller that replaced `json` with text of its own owns that text and must free
 it itself — this releases whatever the field points at now, which is why the
 replacement has to be handed over rather than aliased.
*>
fn void GlbParts.free(&self, Allocator allocator)
{
	if (self.json.len > 0) alloc::free(allocator, self.json);
	if (self.rest.len > 0) alloc::free(allocator, self.rest);
	*self = {};
}

<*
 Split a .glb or .gltf into its JSON text and everything after it.

 	`GlbParts parts = gltf_edit::split_glb(mem, "character.glb")!;`
 	`defer parts.free(mem);`

 The file is decided by its magic, not by its extension: a `.gltf` that is really
 a .glb is read as one, and a `.glb` that is really text is read as text. Text
 comes back whole in `json` with an empty `rest`.

 The JSON chunk's padding is trimmed. The container pads it to a multiple of four
 with spaces, which are whitespace to any JSON reader, but a caller splicing text
 wants the value it will write back to be the value it was given.

 The caller owns both arrays.

 @return? GLB_TRUNCATED : `The header claims chunks the file does not contain.`
 @return? GLB_NO_JSON_CHUNK : `A binary glTF whose first chunk is not JSON.`
*>
fn GlbParts? split_glb(Allocator allocator, String path)
{
	char[] bytes = file::load(allocator, path)!;
	defer catch alloc::free(allocator, bytes);

	if (bytes.len < 12 || read_u32(bytes, 0) != GLB_MAGIC)
	{
		// Not a container. Plain glTF is JSON and nothing else, so the whole file
		// is the part a caller wants to edit.
		return { .json = bytes, .rest = {}, .version = 2, .binary = false };
	}

	uint version = read_u32(bytes, 4);

	// The header's own length field is not trusted over the file's actual size:
	// an exporter that wrote it wrong should not make this read past the end, and
	// a file with bytes past the declared length keeps them in `rest`.
	if (bytes.len < 20) return GLB_TRUNCATED~;

	usz chunk_length = (usz)read_u32(bytes, 12);
	uint chunk_type = read_u32(bytes, 16);
	if (chunk_type != GLB_CHUNK_JSON) return GLB_NO_JSON_CHUNK~;

	usz json_start = 20;
	if (json_start + chunk_length > bytes.len) return GLB_TRUNCATED~;

	usz json_end = json_start + chunk_length;
	// Trailing pad, which the container writes as spaces. Trimmed rather than
	// carried, so a caller reading `json` as text sees what the exporter wrote.
	while (json_end > json_start && bytes[json_end - 1] == ' ') json_end--;

	usz after = json_start + chunk_length;

	GlbParts out = {
		.json = (char[])alloc::clone_slice(allocator, bytes[json_start:json_end - json_start]),
		.rest = after < bytes.len
			? (char[])alloc::clone_slice(allocator, bytes[after:bytes.len - after])
			: (char[]){},
		.version = version,
		.binary = true,
	};

	alloc::free(allocator, bytes);
	return out;
}

<*
 Write the parts back out as one file.

 	`gltf_edit::write_glb("character.glb", parts)!;`

 The JSON chunk is re-padded to the four-byte boundary the container requires and
 its length recomputed; `rest` is copied through untouched, so the binary buffer
 comes out bit-identical to the one that went in. A non-binary part set is written
 as its text alone.

 **Overwrites.** Writing over the file `split_glb` read is the ordinary use and is
 safe in the sense that matters — nothing is streamed, the whole output is built
 in memory and written in one call, so a failure partway cannot leave a half file
 where a whole one was. It is still a write to somebody's asset, and whether to do
 it in place or beside is the caller's decision, not this one's.

 @return? GLB_WRITE_FAILED : `The file could not be opened, written or closed.`
*>
fn void? write_glb(String path, GlbParts parts)
{
	if (!parts.binary)
	{
		if (catch file::save(path, parts.json)) return GLB_WRITE_FAILED~;
		return;
	}

	usz padded = (parts.json.len + 3) & ~(usz)3;
	usz total = 12 + 8 + padded + parts.rest.len;

	char[] out = mem::new_array(char, (sz)total);
	defer free(out);

	write_u32(out, 0, GLB_MAGIC);
	write_u32(out, 4, parts.version != 0 ? parts.version : 2);
	write_u32(out, 8, (uint)total);
	write_u32(out, 12, (uint)padded);
	write_u32(out, 16, GLB_CHUNK_JSON);

	out[20:parts.json.len] = parts.json[..];
	// Spaces, not zeros: the JSON chunk's pad has to stay whitespace so the text
	// still parses when a reader hands the padded run straight to a parser.
	for (usz i = parts.json.len; i < padded; i++) out[20 + i] = ' ';

	if (parts.rest.len > 0)
	{
		out[20 + padded : parts.rest.len] = parts.rest[..];
	}

	if (catch file::save(path, out)) return GLB_WRITE_FAILED~;
}

// glTF is little-endian throughout: the GLB header, the chunk headers and every
// accessor. Shared with reskin.c3, which writes the blob these headers describe.
fn uint read_u32(char[] bytes, usz at) @private => bitorder::read(bytes[at:4], UIntLE);
fn void write_u32(char[] bytes, usz at, uint value) @private => bitorder::write(value, bytes[at:4], UIntLE);

// ---------------------------------------------------------------------------
// Writing the values that go in
//
// The small half, and the half that is easy to get wrong without noticing. A
// string written as `"%s"` breaks the file the first time a material is called
// `Glass "front"`; a float written with `%g` keeps six digits and moves the
// model. Neither shows up until somebody else opens it.

<*
 Append `text` as a quoted, escaped JSON string.

 	`gltf_edit::escape_json_string(&out, node.name);`

 The two-character escapes for the ones JSON names, `\uXXXX` for the remaining
 control characters, and everything else through unchanged — which is what carries
 UTF-8: a multi-byte sequence is bytes above 0x7F and none of them is special, so
 passing them through is both correct and the only way to keep the original
 encoding.

 The forward slash is left alone. Escaping it is legal and pointless, and a file
 full of `\/` is a file somebody will ask about.
*>
fn void escape_json_string(DString* out, String text)
{
	out.append_char('"');
	escape_json_body(out, text);
	out.append_char('"');
}

<*
 The same, without the surrounding quotes — for a caller assembling a string out
 of several pieces.
*>
fn void escape_json_body(DString* out, String text)
{
	foreach (c : text)
	{
		switch (c)
		{
			case '"': out.append_string(`\"`);
			case '\\': out.append_string(`\\`);
			case '\b': out.append_string(`\b`);
			case '\f': out.append_string(`\f`);
			case '\n': out.append_string(`\n`);
			case '\r': out.append_string(`\r`);
			case '\t': out.append_string(`\t`);
			default:
				if (c < 0x20)
				{
					out.appendf(`\u%04x`, (uint)c)!!;
					continue;
				}
				out.append_char(c);
		}
	}
}

<*
 Append a number that reads back as the same double.

 	`gltf_edit::write_json_double(&out, node.translation.x);`

 Seventeen significant digits always round-trip a binary64, and most values need
 far fewer, so the shortest of fifteen, sixteen and seventeen that survives being
 parsed again is the one written. That keeps `0.5` spelled `0.5` rather than
 `0.50000000000000000`, while never letting a value drift.

 Infinities and NaN are written as `null`, which is the only thing JSON has for
 them: the alternative is text no parser accepts, and a file that will not load is
 worse than a value that arrives absent.
*>
fn void write_json_double(DString* out, double value)
{
	if (!math::is_finite(value))
	{
		out.append_string("null");
		return;
	}

	@stack_mem(64; Allocator scratch)
	{
		for (int digits = 15; digits <= 17; digits++)
		{
			String printed = string::format(scratch, "%.*g", digits, value);
			double? back = printed.to_double();
			if (try back && back == value)
			{
				out.append_string(printed);
				return;
			}
		}
		out.append_string(string::format(scratch, "%.17g", value));
	};
}

<*
 Append a number that reads back as the same float.

 	`gltf_edit::write_json_float(&out, joint.reach);`

 The same search as `write_json_double`, over the range a binary32 needs: nine
 significant digits always round-trip one, and most need six or seven.

 Worth having as its own function rather than widening to double and calling
 that. A float is a double the moment it is passed, and the shortest text that
 round-trips *the double* is not the shortest that round-trips the float it came
 from — `0.12267040f` widens to a double needing seventeen digits, and comes back
 out spelled `0.12267039716243744`. Every one of those extra digits is a
 restatement of where the binary32 ran out, written into a file for a reader that
 will narrow it back to the same float regardless.
*>
fn void write_json_float(DString* out, float value) => out.appendf("%s", (JsonFloat)value);

<*
 A float that prints, through `%s`, as the shortest text reading back as the
 same float, or `null` when it is not finite. JSON has no NaN.

 	`out.appendf(`"reach":%s`, (JsonFloat)joint.reach);`
*>
typedef JsonFloat (Printable) = float;

// `[x,y,z]`, each written as a JsonFloat.
typedef JsonVec3 (Printable) = Vec3;

// `[x,y,z,w]`, each written as a JsonFloat.
typedef JsonQuat (Printable) = Quaternionf;

fn sz? JsonFloat.to_format(&self, Formatter* formatter) @dynamic
{
	float value = (float)*self;
	if (!math::is_finite(value)) return formatter.print("null");
	char[32] buffer;
	for (int digits = 6; digits <= 9; digits++)
	{
		String printed = string::bformat(&buffer, "%.*g", digits, (double)value);
		float? back = printed.to_float();
		if (try back && back == value) return formatter.print(printed);
	}
	return formatter.printf("%.9g", (double)value);
}

fn sz? JsonVec3.to_format(&self, Formatter* formatter) @dynamic
{
	Vec3 v = (Vec3)*self;
	return formatter.printf("[%s,%s,%s]", (JsonFloat)v.x, (JsonFloat)v.y, (JsonFloat)v.z);
}

fn sz? JsonQuat.to_format(&self, Formatter* formatter) @dynamic
{
	Quaternionf q = (Quaternionf)*self;
	return formatter.printf("[%s,%s,%s,%s]",
		(JsonFloat)q.v.x, (JsonFloat)q.v.y, (JsonFloat)q.v.z, (JsonFloat)q.v.w);
}
