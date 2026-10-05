<*
 Reading a tool's arguments, and listing names in a refusal.

 The stdlib's accessors carry contracts — get_float wants a keyable, get_at an
 indexable — and a contract that fails is an assert, not a fault. Every field
 on this surface arrives from the wire, so each accessor is reached only once
 the shape it reads from has been checked: `member` for a key on something that
 may not be a map at all, `is_array` before an indexed read.

 The readers answer with a bool and write the refusal into `detail`, so each
 tool keeps its own fault and its own sentence: the words are the part a caller
 reads, and they differ per tool.
*>
module crig;

import std::collections::object;
import std::math::quaternion;
import std::math::vector;

// How many names a refusal lists before it says how many are left. Long enough
// for a whole pack, short enough that the sentence stays readable.
const usz NAME_LIST_LIMIT @private = 24;

// Whether the arguments are an object at all; otherwise `usage` is the refusal.
fn bool takes_object(Object* args, DString* detail, String usage)
{
	if (args != null && args.is_keyable()) return true;
	detail.append_string(usage);
	return false;
}

// A string field the tool cannot do without; `why` is the refusal when it is
// missing or not a string. `args` has been through `takes_object`.
fn bool required_string(Object* args, String key, String* into, DString* detail, String why)
{
	String? given = args.get_string(key);
	// A clip is `name` in apply_clip and `clip` everywhere else, so either
	// spelling reaches either tool.
	if (catch given)
	{
		if (key == "clip" || key == "name") given = args.get_string(key == "clip" ? "name" : "clip");
	}
	if (catch given)
	{
		detail.append_string(why);
		return false;
	}
	*into = given;
	return true;
}

// The value under `key`, or null when there is none, when the parent is not an
// object, or when the value is JSON null. An absent field and an explicit null
// mean the same thing to every caller here.
fn Object* member(Object* obj, String key)
{
	if (obj == null || !obj.is_keyable()) return null;
	Object*? found = obj.get(key);
	if (catch found) return null;
	return found.is_null() ? null : found;
}

// A three-number array as a vector. False for anything else, which is how the
// rotation forms are told apart.
fn bool as_vec3(Object* obj, Vec3* into)
{
	if (obj == null || !obj.is_array() || obj.get_len() != 3) return false;

	double? x = obj.get_float_at(0);
	double? y = obj.get_float_at(1);
	double? z = obj.get_float_at(2);
	if (catch x, y, z) return false;

	*into = { (float)x, (float)y, (float)z };
	return true;
}

// A quaternion written as {"x","y","z","w"}, taken as given — not normalised.
fn bool as_quat(Object* obj, Quaternionf* into)
{
	if (obj == null || !obj.is_keyable()) return false;

	double? x = obj.get_float("x");
	double? y = obj.get_float("y");
	double? z = obj.get_float("z");
	double? w = obj.get_float("w");
	if (catch x, y, z, w) return false;

	*into = { .v = { (float)x, (float)y, (float)z, (float)w } };
	return true;
}

<*
 A comma-separated list of names that stops at NAME_LIST_LIMIT and says how
 many were left out — or only that there were more, when `total` is left 0
 because counting would cost a second walk.

 	NameList list = { .out = out, .total = total };
 	foreach (...) { if (!list.next()) break; out.append_string(name); }
*>
struct NameList
{
	DString* out;
	usz total;
	usz shown;
}

<*
 Make room for the next name: false once the list is full, after writing
 ", and N more" the first time.
*>
fn bool NameList.next(&self)
{
	if (self.shown > NAME_LIST_LIMIT) return false;
	if (self.shown == NAME_LIST_LIMIT)
	{
		if (self.total > self.shown)
		{
			self.out.appendf(", and %d more", self.total - self.shown);
		}
		else
		{
			self.out.append_string(", and more");
		}
		self.shown++;
		return false;
	}
	if (self.shown > 0) self.out.append_string(", ");
	self.shown++;
	return true;
}
