<*
 Reading parsed JSON that may not have the shape it should.

 Shared by the session reader, the clip codecs and the MCP tools. A missing or
 wrong-shaped value is an answer here, never a contract failure.
*>
module crig;

import std::collections::object;
import std::math::quaternion;
import std::math::vector;

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

// Whether `key` was sent as an explicit null, which `member` reads the same as
// absent. A tool that keeps a field when it is left out clears it on a null.
fn bool stated_null(Object* obj, String key)
{
	if (obj == null || !obj.is_keyable()) return false;
	Object*? found = obj.get(key);
	if (catch found) return false;
	return found.is_null();
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
