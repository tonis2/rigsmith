<* The guide poses a motion job sends, as JSON. *>
module crig;

import gltf_edit;
import rig;
import std::core::string;
import std::math::matrix;

// The rest pose of a guide's joints, opening the JSON.
fn void guide_write_rest(DString* out, rig::Skeleton* skeleton, String[] names, bool[] sent, float facing)
{
	out.append_string("{\n    \"rest\": {");
	bool first = true;
	foreach (usz i, rest : skeleton.joints)
	{
		if (!sent[i]) continue;
		out.appendf("%s\n      ", first ? "" : ",");
		gltf_edit::escape_json_string(out, names[i]);
		out.append_string(": ");
		append_json_point(out, turned_about_y(rest, facing));
		first = false;
	}
}

<*
 One keyed instant of a guide.

 @param lead : `Whether it is the first of the keys.`
 @param held : `The limbs it holds alone, or null for a whole pose.`
*>
fn void guide_write_key(DString* out, rig::Skeleton* skeleton, Matrix4f[] palette, String[] names, bool[] sent, float facing,
	int frame, bool lead, bool[4]* held)
{
	out.appendf("%s\n      { \"frame\": %d, \"joints\": {", lead ? "" : ",", frame);
	bool first = true;
	foreach (usz i, rest : skeleton.joints)
	{
		if (!sent[i]) continue;
		out.appendf("%s ", first ? "" : ",");
		gltf_edit::escape_json_string(out, names[i]);
		out.append_string(": ");
		append_json_point(out, turned_about_y(rest.transform(palette[i]), facing));
		first = false;
	}
	out.append_string(" }");
	if (held)
	{
		out.append_string(", \"effectors\": [");
		first = true;
		foreach (usz k, name : KIMODO_EFFECTORS)
		{
			if (!(*held)[k]) continue;
			out.appendf(`%s"%s"`, first ? "" : ", ", name);
			first = false;
		}
		out.append_string("]");
	}
	out.append_string(" }");
}
