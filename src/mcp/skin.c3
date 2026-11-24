<*
 The skin's half of measure_clip's answer: where the clip stretches an edge of
 the mesh past tolerance (`AppState.clip_skin_faults`), and what mends each.
*>
module crig;

import std::math;

fn String skin_joint_name(RigView* view, int joint) @private
	=> joint >= 0 && (usz)joint < view.names.len ? view.names[(usz)joint] : "";

// A small piece riding the body — a knot, a buckle, a tusk — whose answer is to
// pin it to one joint.
fn bool skin_small_shell(AppState* app, SkinStretch found) @private
	=> skin_small_piece(found.shell_vertices, app.geometry.positions.len);

<*
 `,"skin":{…}`: every region stretched past tolerance, worst first, or none.
*>
fn void append_skin_faults(DString* out, AppState* app, RigView* view, SkinStretch[] skin)
{
	float height = view.skeleton.height();
	if (height <= 0.0f) height = 1.0f;
	out.appendf(`,"skin":{"measured":%s,"tolerance":%s,"faults":[`, app.has_mesh() ? "true" : "false",
		(JsonFloat)SKIN_STRETCH_TOLERANCE);
	usz kept = math::min((usz)skin.len, (usz)SKIN_FAULTS_MOST);
	foreach (usz i, found : skin[:kept])
	{
		if (i > 0) out.append_char(',');
		out.appendf(`{"shell":%d,"shell_vertices":%d,"between":["`, found.shell, found.shell_vertices);
		json_escape_into(out, skin_joint_name(view, found.joint_a));
		out.append_string(`","`);
		json_escape_into(out, skin_joint_name(view, found.joint_b));
		out.appendf(`"],"stretch":%s,"growth":%s,"phase":%s,"at":%s,"vertices":[%d,%d]`,
			(JsonFloat)found.stretch, (JsonFloat)(found.growth / height), (JsonFloat)found.phase,
			(JsonVec3)found.at, found.a, found.b);
		String owner = skin_joint_name(view, found.owner);
		if (owner.len > 0)
		{
			out.append_string(`,"held_most_by":"`);
			json_escape_into(out, owner);
			out.append_char('"');
		}
		out.append_char('}');
	}
	out.append_char(']');
	if (skin.len > kept) out.appendf(`,"faults_omitted":%d`, skin.len - kept);
	out.append_string(`,"note":"an edge of the mesh pulled past tolerance times its rest length while the clip plays, between the two joints that hold most of each end: a piece split between joints that move apart (a knot, a belt end), or cloth weighted to two limbs (a skirt down its middle). growth is a fraction of rig height, at is the edge at rest, in model space."}`);
}

<*
 One fix per stretched shell, after the clip's own: a small piece is pinned to
 the joint holding most of it; a large one is painted.
*>
fn void append_skin_fix_rows(DString* out, usz* written, AppState* app, RigView* view, SkinStretch[] skin)
{
	usz kept = math::min((usz)skin.len, (usz)SKIN_FAULTS_MOST);
	foreach (usz i, found : skin[:kept])
	{
		// One row per shell: its worst region speaks for it.
		bool seen = false;
		for (usz k = 0; k < i; k++) if (skin[k].shell == found.shell) seen = true;
		if (seen) continue;
		// The joint both ends hang from: what the torn piece should ride.
		String rider = skin_joint_name(view, skeleton_common_ancestor(&view.skeleton, found.joint_a, found.joint_b));
		if (rider.len == 0) rider = skin_joint_name(view, found.owner);
		bool pinned = app.doc.attachment_of((uint)found.shell) != 0;
		if (skin_small_shell(app, found) && rider.len > 0 && !pinned)
		{
			fix_open(out, written, "skin_stretch", "edit_rig");
			out.appendf(`{"ops":[{"op":"attach","shell":%d,"joint":"`, found.shell);
			json_escape_into(out, rider);
			out.append_string(`"}]},"why":"a small separate piece is pulled between joints that move apart, so it stretches; pinned to the joint they both hang from, it rides that joint rigidly"}`);
			continue;
		}
		fix_open(out, written, "skin_stretch", "paint_weights");
		out.append_string(`{"dot":"`);
		json_escape_into(out, rider.len > 0 ? rider : skin_joint_name(view, found.joint_a));
		out.appendf(`","weight":1,"vertices":[%d,%d]},"why":"the skin between `, found.a, found.b);
		json_escape_into(out, skin_joint_name(view, found.joint_a));
		out.append_string(` and `);
		json_escape_into(out, skin_joint_name(view, found.joint_b));
		out.append_string(` tears apart as they move; give the region to one joint, or blend it across the two, with paint_weights over the vertices there — these two are the edge's ends, a start and not the whole region"}`);
	}
}
