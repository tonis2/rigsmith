<* The active cutscene's walk paths as lines in the 3D view, while a Cutscene pane or the preview is up. Read-only. *>
module crig;

import three;
import std::math;

const float[4] CUT_PATH_INK = { 0.98f, 0.82f, 0.30f, 1.0f };
// How wide a knot's cross is drawn, in metres.
const float CUT_KNOT_MARK = 0.08f;
// The line is drawn this far over the ground it lies on, so the ground does not hide it.
const float CUT_PATH_DRAW_LIFT = 0.04f;

struct CutPathDraw @local
{
	three::NodeId node;
	uint revision;
	usz active;
	uint serial;
	bool built;
}

CutPathDraw cut_path_draw @local = { .node = three::NO_NODE };

<* The stage was replaced: the line node went with it. *>
fn void cut_paths_lost_stage()
{
	cut_path_draw.node = three::NO_NODE;
	cut_path_draw.built = false;
}

fn void drop_cut_path_node() @local
{
	if (cut_path_draw.node.is_set() && stage_scene() != null) stage_scene().remove(cut_path_draw.node);
	cut_path_draw.node = three::NO_NODE;
}

<*
 The lines, rebuilt when the cutscene changes. Called from `sync_scene`.

 @param [&inout] app
*>
fn void sync_cutscene_paths(AppState* app)
{
	Cutscene* cutscene = app.cutscene();
	bool wanted = cutscene != null && cutscene.paths.len > 0 && (app.cut_preview || app.cut_panes > 0);
	if (!wanted)
	{
		if (cut_path_draw.node.is_set())
		{
			drop_cut_path_node();
			sweep_assets();
		}
		cut_path_draw.built = false;
		return;
	}
	if (!cut_path_draw.built || cut_path_draw.revision != app.cut_revision || cut_path_draw.active != app.cut_active)
	{
		build_cut_paths(cutscene);
		cut_path_draw.built = true;
		cut_path_draw.revision = app.cut_revision;
		cut_path_draw.active = app.cut_active;
	}
	if (cut_path_draw.node.is_set()) stage_scene().set_visible(cut_path_draw.node, stage_pane_shown());
}

fn void build_cut_paths(Cutscene* cutscene) @local
{
	bool had = cut_path_draw.node.is_set();
	drop_cut_path_node();
	three::GeometryBuilder shape;
	shape.init();
	defer shape.free();
	foreach (&walk : cutscene.paths)
	{
		for (usz k = 0; k + 1 < walk.points.len; k++)
		{
			uint base = (uint)shape.positions.len();
			shape.positions.push(walk.points[k] + (Vec3){ 0, CUT_PATH_DRAW_LIFT, 0 });
			shape.positions.push(walk.points[k + 1] + (Vec3){ 0, CUT_PATH_DRAW_LIFT, 0 });
			shape.indices.push(base);
			shape.indices.push(base + 1);
		}
		// A small cross on the ground at each knot.
		foreach (at : walk.knots)
		{
			Vec3 knot = at + (Vec3){ 0, CUT_PATH_DRAW_LIFT, 0 };
			uint base = (uint)shape.positions.len();
			shape.positions.push(knot - (Vec3){ CUT_KNOT_MARK, 0, 0 });
			shape.positions.push(knot + (Vec3){ CUT_KNOT_MARK, 0, 0 });
			shape.positions.push(knot - (Vec3){ 0, 0, CUT_KNOT_MARK });
			shape.positions.push(knot + (Vec3){ 0, 0, CUT_KNOT_MARK });
			foreach (v : (uint[]){ 0, 1, 2, 3 }) shape.indices.push(base + v);
		}
	}
	if (shape.indices.len() >= 2)
	{
		cut_path_draw.serial++;
		String key = string::tformat("crig:cut-paths:%d", cut_path_draw.serial);
		if (try made = stage_pass().assets.upload_built(&stage_renderer().gpu, key, key, &shape, true))
		{
			three::NodeId node = stage_scene().add_mesh(made, 0, stage_scene().root, "crig:cut-paths");
			if (node.is_set())
			{
				stage_scene().set_material(node, three::LINE_MATERIAL);
				stage_scene().set_color(node, CUT_PATH_INK);
				cut_path_draw.node = node;
			}
		}
	}
	if (had || cut_path_draw.node.is_set()) sweep_assets();
}
