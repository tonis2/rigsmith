<* The pure steps behind the brush, the lasso, the graph, the dopesheet and the guide. *>
module crig_tests::view_cores;

import crig;
import rig;
import std::collections::list;
import std::core::string;
import std::core::test;
import std::math;
import std::math::matrix;
import std::math::vector;

// Four points on a plane through the view, in a row, with two faces joining them.
Vec3[4] row_shown = { { -0.5f, 0, 0.5f }, { -0.25f, 0, 0.5f }, { 0.25f, 0, 0.5f }, { 0.5f, 0, 0.5f } };
uint[6] row_faces = { 0, 1, 2, 1, 2, 3 };

fn bool nothing_hidden(void* ctx, Vec3 eye, Vec3 point) @local => false;
fn bool the_right_half_hidden(void* ctx, Vec3 eye, Vec3 point) @local => point.x > 0.0f;

// Pixels in a 100 by 100 window: world -1..1 maps straight across it.
fn crig::ScreenProbe row_probe(crig::HiddenTest hidden = &nothing_hidden, bool xray = false) @local
{
	return {
		.shown = row_shown[..],
		.indices = row_faces[..],
		.view_projection = matrix::IDENTITY4 { float },
		.viewport = { 100, 100 },
		.xray = xray,
		.hidden = hidden,
	};
}

fn void a_brush_takes_what_is_under_it_with_a_soft_edge() @test
{
	crig::ScreenProbe probe = row_probe();
	uint[4] vertices;
	float[4] strength;
	usz taken = crig::brush_vertices(&probe, vertices[..], strength[..], { 25, 50 }, 8.0f, 1.0f);
	test::@check(taken == 1 && vertices[0] == 0, "took %d", taken);
	test::@check(strength[0] > 0.9f, "the middle of the brush is soft: %f", strength[0]);
}

fn void a_brush_scales_by_its_own_strength() @test
{
	crig::ScreenProbe probe = row_probe();
	uint[4] vertices;
	float[4] strength;
	crig::brush_vertices(&probe, vertices[..], strength[..], { 25, 50 }, 8.0f, 0.5f);
	test::@check(strength[0] <= 0.5f && strength[0] > 0.4f, "gave %f", strength[0]);
}

fn void a_brush_skips_a_hidden_vertex_unless_it_reaches_through() @test
{
	uint[4] vertices;
	float[4] strength;
	crig::ScreenProbe probe = row_probe(&the_right_half_hidden);
	test::@check(crig::brush_vertices(&probe, vertices[..], strength[..], { 75, 50 }, 8.0f, 1.0f) == 0, "took a hidden vertex");
	probe.xray = true;
	test::@check(crig::brush_vertices(&probe, vertices[..], strength[..], { 75, 50 }, 8.0f, 1.0f) == 1, "x-ray didn't reach it");
}

fn void a_lasso_holds_what_projects_inside_it() @test
{
	crig::ScreenProbe probe = row_probe();
	Vec2[4] left = { { 0, 40 }, { 45, 40 }, { 45, 60 }, { 0, 60 } };
	bool[4] within;
	test::@check(crig::lasso_within(&probe, left[..], within[..]) == 2, "the count");
	test::@check(within[0] && within[1] && !within[2] && !within[3], "the flags");
}

fn void a_lasso_walks_from_what_it_sees_and_stays_inside_the_outline() @test
{
	rig::TriMesh mesh = { .positions = row_shown[..], .indices = row_faces[..] };
	rig::MeshAdjacency around = rig::build_adjacency(mem, mesh);
	defer around.free(mem);
	crig::ScreenProbe probe = row_probe(&the_right_half_hidden);
	bool[4] within = { false, true, true, false };
	uint[4] out;
	usz kept = crig::lasso_region(&probe, &around, within[..], out[..]);
	// Vertex 2 is hidden but joined to 1, which can be seen.
	test::@check(kept == 2 && out[0] == 1 && out[1] == 2, "kept %d", kept);
}

fn void a_lasso_with_nothing_to_walk_keeps_what_it_sees() @test
{
	rig::MeshAdjacency around;
	crig::ScreenProbe probe = row_probe(&the_right_half_hidden);
	bool[4] within = { false, true, true, false };
	uint[4] out;
	usz kept = crig::lasso_region(&probe, &around, within[..], out[..]);
	test::@check(kept == 1 && out[0] == 1, "kept %d", kept);
}

// ---- graph and dopesheet

fn crig::AnimTemplate two_joint_clip() @local
{
	crig::AnimKeyframe[] keys = alloc::new_array(mem, crig::AnimKeyframe, 2);
	foreach (usz i, &key : keys)
	{
		crig::AnimKeyDot[] dots = alloc::new_array(mem, crig::AnimKeyDot, i == 0 ? 2 : 1);
		dots[0] = { .joint_name = "hand".copy(mem), .axis = { 0, 1, 0 }, .angle = (float)i * 0.5f, .channels = ROTATION };
		if (i == 0) dots[1] = { .joint_name = "arm".copy(mem), .move = { 1, 0, 0 }, .channels = TRANSLATION };
		*key = { .time = (float)i, .dots = dots };
	}
	return { .name = "two".copy(mem), .duration = 1.0f, .keyframes = keys, .owned = true };
}

fn bool only_y_shown(void* ctx, uint id, bool rotation, int axis) @local => axis != 1;
fn bool all_shown(void* ctx, uint id, bool rotation, int axis) @local => false;
fn bool the_first_key(void* ctx, float at, String name, crig::AnimChannels channel) @local => at == 0.0f;

fn void a_graph_draws_only_the_axes_on_show() @test
{
	crig::AnimTemplate clip = two_joint_clip();
	defer clip.free(mem);
	String[1] names = { "hand" };
	uint[1] ids = { 7 };
	crig::GraphAsk ask = { .clip = &clip, .names = names[..], .ids = ids[..], .primary = "hand",
		.axis_hidden = &only_y_shown, .key_selected = &the_first_key };
	crig::Graph graph = { .unit = 1.0f };
	defer graph.free();
	crig::graph_fill(&graph, &ask);

	test::@check(graph.channels.len == 1 && graph.channels[0].rotation && graph.channels[0].primary, "the channel");
	test::@check(graph.curves.len == 1 && graph.curves[0].axis == 1, "%d curves", graph.curves.len);
	test::@check(graph.keys.len == 2, "%d keys", graph.keys.len);
	test::@check(graph.keys[0].selected && !graph.keys[1].selected, "the selection");
	test::@check(!graph.mixed, "one kind of curve is not mixed");
}

fn void rotation_and_position_together_are_scaled_to_share_a_plot() @test
{
	crig::AnimTemplate clip = two_joint_clip();
	defer clip.free(mem);
	String[2] names = { "hand", "arm" };
	uint[2] ids = { 7, 8 };
	crig::GraphAsk ask = { .clip = &clip, .names = names[..], .ids = ids[..], .primary = "hand",
		.axis_hidden = &all_shown, .key_selected = &the_first_key };
	crig::Graph graph = { .unit = 1.0f };
	defer graph.free();
	crig::graph_fill(&graph, &ask);
	test::@check(graph.mixed, "not mixed");
	foreach (curve : graph.curves) test::@check(curve.half > 0.0f, "a curve kept no range");
}

fn void dopesheet_rows_read_as_the_rigs_tree_with_strangers_last() @test
{
	crig::AnimTemplate clip = two_joint_clip();
	defer clip.free(mem);
	StringList named;
	named.init(mem);
	defer named.free();
	crig::clip_joint_names(&named, &clip);
	test::@check(named.len() == 2 && named[0] == "hand" && named[1] == "arm", "first seen");

	// root, then arm and hand under it; the clip names no root.
	Vec3[3] joints = { { 0, 0, 0 }, { 0, 1, 0 }, { 0, 2, 0 } };
	int[3] parents = { -1, 0, 1 };
	String[3] words = { "root", "arm", "wrist" };
	rig::Skeleton skeleton = { .joints = joints[..], .parents = parents[..] };
	StringList sorted;
	sorted.init(mem);
	defer sorted.free();
	List{uint} depths;
	depths.init(mem);
	defer depths.free();
	crig::joints_in_rig_order(&sorted, &depths, &skeleton, words[..], named.array_view());
	test::@check(sorted.len() == 2 && sorted[0] == "arm" && sorted[1] == "hand", "the order");
	test::@check(depths[0] == 1 && depths[1] == 0, "a joint the rig lacks has no depth");
}

fn void a_dopesheet_row_holds_each_channels_times() @test
{
	crig::AnimTemplate clip = two_joint_clip();
	defer clip.free(mem);
	String[2] order = { "arm", "hand" };
	uint[1] depths = { 3 };
	crig::TimelineTrack[] tracks = crig::timeline_tracks_of(mem, &clip, order[..], depths[..]);
	defer
	{
		foreach (track : tracks)
		{
			if (track.times.len > 0) alloc::free(mem, track.times);
			if (track.rotation_times.len > 0) alloc::free(mem, track.rotation_times);
			if (track.translation_times.len > 0) alloc::free(mem, track.translation_times);
		}
		alloc::free(mem, tracks);
	}
	test::@check(tracks[0].joint == "arm" && tracks[0].depth == 3 && tracks[1].depth == 0, "the depths");
	test::@check(tracks[0].translation_times.len == 1 && tracks[0].rotation_times.len == 0, "arm's channels");
	test::@check(tracks[1].rotation_times.len == 2 && tracks[1].times.len == 2, "hand's channels");
}

// ---- motion guide

fn void a_guide_sends_each_pack_joint_once() @test
{
	String[2] spelled = { "Hips", "Head" };
	crig::AnimPack pack = { .joint_names = spelled[..] };
	String[4] names = { "Hips", "Head", "Head", "Tail" };
	crig::PackReach reach = { .names = names[..] };
	bool[4] sent;
	test::@check(crig::guide_sent_joints(&pack, &reach, sent[..]) == 2, "the count");
	test::@check(sent[0] && sent[1] && !sent[2] && !sent[3], "the flags");
}

fn void a_guides_json_lists_the_sent_joints_and_any_limbs_held() @test
{
	Vec3[2] joints = { { 0, 1, 0 }, { 0, 2, 0 } };
	int[2] parents = { -1, 0 };
	rig::Skeleton skeleton = { .joints = joints[..], .parents = parents[..] };
	String[2] names = { "Hips", "Head" };
	bool[2] sent = { true, false };

	DString out = dstring::new(mem);
	defer out.free();
	crig::guide_write_rest(&out, &skeleton, names[..], sent[..], 0.0f);
	test::@check(out.str_view().contains(`"Hips"`) && !out.str_view().contains(`"Head"`), "%s", out.str_view());

	rig::Pose pose = rig::rest_pose(mem, 2);
	defer pose.free(mem);
	Matrix4f[] palette = rig::joint_palette(mem, &skeleton, pose)!!;
	defer alloc::free(mem, palette);
	bool[4] held = { true, false, false, false };
	DString key = dstring::new(mem);
	defer key.free();
	crig::guide_write_key(&key, &skeleton, palette, names[..], sent[..], 0.0f, 12, true, &held);
	test::@check(key.str_view().contains(`"frame": 12`), "%s", key.str_view());
	test::@check(key.str_view().contains(`"effectors": ["LeftHand"]`), "%s", key.str_view());
	DString whole = dstring::new(mem);
	defer whole.free();
	crig::guide_write_key(&whole, &skeleton, palette, names[..], sent[..], 0.0f, 12, false, null);
	test::@check(!whole.str_view().contains("effectors") && whole.str_view().starts_with(","), "%s", whole.str_view());
}

// ---- gait

fn void a_rewritten_cycle_keeps_paths_edited_by_hand() @test
{
	crig::AnimTemplate before;
	crig::AnimPath[2] old = {
		{ .joint = "foot_L".copy(mem), .name = "By hand".copy(mem) },
		{ .joint = "foot_R".copy(mem), .name = "Step".copy(mem), .generated = true, .mute = true },
	};
	defer foreach (&path : old) path.free(mem);
	before.paths = old[..];
	crig::AnimPath[] stepped = alloc::new_array(mem, crig::AnimPath, 2);
	stepped[0] = { .joint = "foot_L".copy(mem), .name = "Step".copy(mem), .generated = true };
	stepped[1] = { .joint = "foot_R".copy(mem), .name = "Step".copy(mem), .generated = true };

	crig::AnimPath[] paths = crig::gait_paths_over(mem, &before, stepped);
	defer
	{
		foreach (&path : paths) path.free(mem);
		alloc::free(mem, paths.ptr);
	}
	test::@check(paths.len == 2, "%d paths", paths.len);
	test::@check(paths[0].joint == "foot_L" && !paths[0].generated, "the hand path was replaced");
	test::@check(paths[1].joint == "foot_R" && paths[1].generated && paths[1].mute, "the switch was lost");
}

fn void a_cycle_records_what_it_was_written_from_in_rig_heights() @test
{
	crig::AnimTemplate clip;
	String[2] names = { "foot_L", "foot_R" };
	usz[2] feet = { 0, 1 };
	crig::GaitFoot[2] driven = { { .joint = 0, .offset = 0.0f }, { .joint = 1, .offset = 0.5f } };
	crig::GaitReport report = { .duty = 0.6f, .stride = 2.0f, .lift = 0.5f };
	crig::gait_record(mem, &clip, { .kind = WALK }, report, 2.0f, names[..], feet[..], driven[..]);
	defer clip.gait.free(mem);
	test::@check(clip.gait.set && clip.gait.stride == 1.0f && clip.gait.lift == 0.25f, "the record");
	test::@check(clip.gait.feet[1] == "foot_R" && clip.gait.offsets[1] == 0.5f, "the feet");
}
