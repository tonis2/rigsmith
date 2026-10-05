<*
 get_annotations: the person's sketches over the viewport, read by the agent.

 See app/sketch.c3.
*>
module crig;

import std::collections::object;

faultdef ANNOTATION_REFUSED;

const String GET_ANNOTATIONS_SCHEMA = `{"type":"object","properties":{
	"clear":{"type":"boolean","description":"Delete every mark after reading them.","default":false},
	"delete":{"type":"number","description":"Delete the mark with this id instead of reading."}
}}`;

<*
 The person's sketches (the Sketch tool): each stroke as fractions of the viewport
 (0..1 from the top left), its ink (red wrong, green keep, blue note), the clip
 and time on screen, the camera it was drawn from and the joints it passes near.
 The marks are painted in the viewport, so `screenshot` shows them too.
*>
fn String? tool_get_annotations(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;
	if (args != null && args.is_keyable())
	{
		double gone = args.get_float("delete") ?? -1.0;
		if (gone >= 1)
		{
			if (!app.delete_annotation((uint)gone))
			{
				detail.appendf(`no sketch has id %.9g. get_annotations reports the ids.`, gone);
				return ANNOTATION_REFUSED~;
			}
			app.refresh_ui();
		}
	}
	bool clear = args != null && args.is_keyable() && (args.get_bool("clear") ?? false);

	DString out = dstring::new(mem);
	defer out.free();
	out.append_string(`{"annotations":[`);
	foreach (i, mark : app.annotations.array_view())
	{
		if (i > 0) out.append_char(',');
		out.appendf(`{"id":%d,"ink":"%s","meaning":"%s"`, mark.id, mark.ink.label(),
			mark.ink == SketchInk.RED ? "wrong" : mark.ink == SketchInk.GREEN ? "keep" : "note");
		if (mark.clip.len > 0)
		{
			out.append_string(`,"clip":`);
			append_json_string(&out, mark.clip);
			out.appendf(`,"time":%s`, (JsonFloat)mark.time)!!;
		}
		out.appendf(`,"camera":{"target":%s,"distance":%s,"yaw":%s,"pitch":%s}`,
			(JsonVec3)mark.target, (JsonFloat)mark.distance, (JsonFloat)mark.yaw, (JsonFloat)mark.pitch)!!;
		out.append_string(`,"joints":[`);
		foreach (j, name : mark.joints)
		{
			if (j > 0) out.append_char(',');
			append_json_string(&out, name);
		}
		out.append_string(`],"points":[`);
		foreach (k, point : mark.points)
		{
			if (k > 0) out.append_char(',');
			out.appendf(`[%.4f,%.4f]`, point.x, point.y);
		}
		out.append_string(`]}`);
	}
	out.append_string(`]}`);
	if (clear)
	{
		app.clear_annotations();
		app.refresh_ui();
	}
	return out.copy_str(mem);
}
