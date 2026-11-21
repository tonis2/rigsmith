<*
 Held props over MCP: `set_prop` puts a placeholder sword, wand or staff in a
 hand, changes it, or takes it away. One call is one undo step.
*>
module crig;

import std::collections::object;
import std::math;
import std::math::quaternion;

excuse PROP_REFUSED;

const String SET_PROP_SCHEMA = `{"type":"object","properties":{
	"joint":{"type":"string","description":"The hand, by joint name: the prop rides it in every clip of this character."},
	"kind":{"type":"string","enum":["sword","wand","staff","none"],"description":"The placeholder to hold, or none to take the prop away."},
	"length":{"type":"number","description":"End to end, as a fraction of the rig's height (0.05 to 2). Default: the prop's own, or 0.45 for a sword, 0.18 a wand, 1.0 a staff."},
	"offset":{"type":"array","items":{"type":"number"},"description":"[x,y,z] where the grip sits from the joint, a fraction of the rig's height, in the joint's rest frame. Default: the palm."},
	"turn":{"type":"array","items":{"type":"number"},"description":"[x,y,z,w] the quaternion taking the prop's +Y (toward its tip) into the joint's rest frame. Default: the tip toward the way the figure faces."}
},"required":["joint","kind"]}`;

fn String? tool_set_prop(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;
	if (!takes_object(args, detail, `set_prop takes an object: {"joint": name, "kind": "sword"|"wand"|"staff"|"none", "length": share of height, "offset": [x,y,z], "turn": [x,y,z,w]}`)) return PROP_REFUSED~;
	String joint;
	String kind_name;
	if (!required_string(args, "joint", &joint, detail, `set_prop needs "joint": the hand's name. get_skeleton lists them.`)) return PROP_REFUSED~;
	if (!required_string(args, "kind", &kind_name, detail, `set_prop needs "kind": "sword", "wand", "staff" or "none".`)) return PROP_REFUSED~;
	Dot* dot = app.dot_named(joint);
	if (dot == null)
	{
		detail.appendf(`no joint is called "%s". get_skeleton lists them.`, joint);
		return PROP_REFUSED~;
	}
	uint id = dot.id;

	HeldProp prop = { .dot_id = id, .turn = quaternion::IDENTITY };
	if (kind_name != "none")
	{
		PropKind? kind = prop_kind_named(kind_name);
		if (catch kind)
		{
			detail.appendf(`"kind" is "sword", "wand", "staff" or "none", not "%s".`, kind_name);
			return PROP_REFUSED~;
		}
		HeldProp held = app.doc.prop_of(id);
		if (held.held() && held.kind == kind)
		{
			prop = held;
		}
		else
		{
			RigView? opened = app.open_rig(mem);
			if (catch opened)
			{
				detail.append_string("this document has no rig to hold a prop.");
				return PROP_REFUSED~;
			}
			RigView view = opened;
			defer view.free(mem);
			sz j = view.joint_of(id);
			if (j < 0)
			{
				detail.appendf(`"%s" is not part of a usable rig.`, joint);
				return PROP_REFUSED~;
			}
			prop = default_prop(&view.skeleton, view.names, (usz)j, id, kind);
		}
		if (member(args, "length") != null)
		{
			double length = args.get_float("length") ?? -1.0;
			if (!(length >= PROP_MIN_LENGTH && length <= PROP_MAX_LENGTH))
			{
				detail.appendf(`"length" is a share of the rig's height from %s to %s.`, (JsonFloat)PROP_MIN_LENGTH, (JsonFloat)PROP_MAX_LENGTH);
				return PROP_REFUSED~;
			}
			prop.length = (float)length;
		}
		Object* offset = member(args, "offset");
		if (offset != null && !as_vec3(offset, &prop.offset))
		{
			detail.append_string(`"offset" must be [x,y,z], a share of the rig's height.`);
			return PROP_REFUSED~;
		}
		Object* turn = member(args, "turn");
		if (turn != null)
		{
			Quaternionf given;
			if (!prop_quat(turn, &given) || given.v.length_sq() < 1.0e-12f)
			{
				detail.append_string(`"turn" must be [x,y,z,w], a rotation that is not zero.`);
				return PROP_REFUSED~;
			}
			prop.turn = given.normalize();
		}
	}
	(void)app.place_prop(prop);

	DString out = dstring::new(mem);
	defer out.free();
	HeldProp now = app.doc.prop_of(id);
	out.append_string(`{"joint":`);
	append_json_string(&out, dot.name);
	if (now.held())
	{
		out.appendf(`,"kind":"%s","length":%s,"offset":%s,"turn":%s,"socket":`, now.kind.label, (JsonFloat)now.length,
			(JsonVec3)now.offset, (JsonQuat)now.turn)!!;
		append_json_string(&out, string::tformat("%s.socket", dot.name));
	}
	else
	{
		out.append_string(`,"kind":"none"`);
	}
	out.appendf(`,"hand":%s}`, app.is_hand(id));
	return out.copy_str(mem);
}

// A turn as [x,y,z,w], the way the answer writes it, or {"x","y","z","w"}.
fn bool prop_quat(Object* obj, Quaternionf* into) @local
{
	if (obj == null || !obj.is_array()) return as_quat(obj, into);
	if (obj.get_len() != 4) return false;
	double? x = obj.get_float_at(0);
	double? y = obj.get_float_at(1);
	double? z = obj.get_float_at(2);
	double? w = obj.get_float_at(3);
	if (catch x, y, z, w) return false;
	*into = { .v = { (float)x, (float)y, (float)z, (float)w } };
	return true;
}

// The held props, in set_prop's shape, or nothing when no hand holds one.
fn void append_prop_list(DString* out, AppState* app) @private
{
	usz written = 0;
	foreach (prop : app.doc.props.array_view())
	{
		Dot* dot = app.doc.find(prop.dot_id);
		if (!prop.held() || !dot) continue;
		out.append_string(written == 0 ? `,"props":[{"joint":"` : `,{"joint":"`);
		append_bone_name(out, dot.id, dot.name);
		out.appendf(`","kind":"%s","length":%s,"offset":%s,"turn":%s}`, prop.kind.label, (JsonFloat)prop.length,
			(JsonVec3)prop.offset, (JsonQuat)prop.turn)!!;
		written++;
	}
	if (written > 0) out.append_char(']');
}
