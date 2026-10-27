<*
 `find_contacts` over MCP: Clip tools › Find contacts, made from a script.

 Every foot of the rig gets a window for each step it takes, read off the motion
 (`AppState.find_contacts`), in place of the windows the clip's feet had; off-floor
 contacts and the floor height stay. The answer lists the windows written and
 measure_clip's numbers for the clip as it now plays.
*>
module crig;

import std::collections::object;

faultdef CONTACTS_REFUSED;

const String FIND_CONTACTS_SCHEMA = `{"type":"object","properties":{
	"clip":{"type":"string","description":"The clip, or \"Pack/Clip\". Default: the clip open in the timeline."}
}}`;

fn String? tool_find_contacts(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;
	if (!takes_object(args, detail, `find_contacts takes an object: {"clip": name}`)) return CONTACTS_REFUSED~;

	AnimRef ref = app.editing;
	Object* named = member(args, "clip");
	if (named != null)
	{
		if (!named.is_string())
		{
			detail.append_string(`"clip" must be a clip's name, or "Pack/Clip".`);
			return CONTACTS_REFUSED~;
		}
		ref = resolve_named(app, named.s, detail)!;
	}
	if (!ref.valid() || !app.clip(ref))
	{
		detail.append_string(`no clip is open. Give "clip": the clip whose feet to find.`);
		return CONTACTS_REFUSED~;
	}
	if (!app.find_contacts(ref))
	{
		detail.append_string(`found no steps: no foot comes to rest near the lowest it reaches, or the rig has no feet near the floor.`);
		return CONTACTS_REFUSED~;
	}

	// A library clip is forked into the authored pack when it lands.
	AnimRef landed = app.editing.valid() ? app.editing : ref;
	AnimTemplate* clip = app.clip(landed);
	DString out = dstring::new(mem);
	defer out.free();
	out.append_string(`{"clip":`);
	append_json_string(&out, clip ? clip.name : "");
	if (clip)
	{
		out.append_string(`,"ground":`);
		append_ground_json(&out, clip.ground);
		append_metrics_member(&out, app, landed);
	}
	out.append_char('}');
	return out.copy_str(mem);
}
