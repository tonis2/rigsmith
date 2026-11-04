<*
 render_studio's layout: the figure inside both views, the floor on its row,
 the front view looking at the face and the side view at the right flank with
 the head to the right, and the far-off perspective cameras landing every
 point where an orthographic camera would.

 A fit that takes the cameras as known (llm-runner's creature plugin) projects
 by the layout alone; if the picture's cameras put a joint elsewhere, the fit
 bends the rig to make up the difference.

     `c3c test --trust=full --test-noleak --test-filter crig_tests::render_studio`
*>
module crig_tests::render_studio;

import crig;
import std::core::test;
import std::math;

// A figure 1.8 tall, arms held out to 0.8 either side, facing +Z.
Vec3[*] figure @local = {
	{ 0, 1.0f, 0 }, { 0, 1.5f, 0.02f }, { 0, 1.7f, 0.05f },
	{ 0.8f, 1.45f, 0 }, { -0.8f, 1.45f, 0 },
	{ 0.12f, 0.05f, 0.1f }, { -0.12f, 0.05f, -0.1f },
};

fn crig::StudioAsk default_ask() @local
{
	return { .out = "studio", .width = 1280, .height = 720, .ground_row = 630, .fill = 0.8f };
}

fn void the_figure_stands_on_the_floor_row_inside_both_views() @test
{
	crig::StudioAsk ask = default_ask();
	crig::StudioLayout layout = crig::studio_layout(&figure, 1.8f, 0.0f, 0.0f, &ask);
	test::@check(layout.views[0].width + layout.views[1].width == 1280 && layout.views[1].x == layout.views[0].width,
		"the views share the picture side by side");
	test::@check(layout.views[0].width % 2 == 0, "the split is even");
	test::@check(layout.units_per_pixel >= 1.8f / (0.8f * 630.0f) - 1.0e-6f, "the figure is no taller than fill asks");
	for (usz v = 0; v < 2; v++)
	{
		crig::StudioView view = layout.views[v];
		float[<2>] floor = layout.pixel(v, layout.centre);
		test::@check(math::abs(floor.x - ((float)view.x + (float)view.width * 0.5f)) < 1.0e-3f && math::abs(floor.y - 630.0f) < 1.0e-3f,
			"the centre on the floor lands mid-view on the floor row (view %d: %s, %s)", v, floor.x, floor.y);
		foreach (p : figure)
		{
			float[<2>] at = layout.pixel(v, p);
			test::@check(at.x > (float)view.x && at.x < (float)(view.x + view.width) && at.y > 0.0f && at.y < 630.0f,
				"every joint is inside view %d (%s, %s)", v, at.x, at.y);
		}
		float top = layout.pixel(v, { 0, 1.8f, 0 }).y;
		test::@check(top > 0.0f && top >= 630.0f - 0.8f * 630.0f - 1.0f, "the head's top is in the picture (%s)", top);
	}
}

fn void the_front_view_faces_the_figure_and_the_side_view_has_the_head_to_the_right() @test
{
	crig::StudioAsk ask = default_ask();
	crig::StudioLayout layout = crig::studio_layout(&figure, 1.8f, 0.0f, 0.0f, &ask);
	// Facing +Z, the figure's left is +X: facing the camera, it is on the right.
	test::@check(layout.pixel(0, { 0.5f, 1, 0 }).x > layout.pixel(0, { -0.5f, 1, 0 }).x,
		"the figure's left hand is on the front view's right, as it faces the viewer");
	test::@check(layout.pixel(1, { 0, 1, 0.5f }).x > layout.pixel(1, { 0, 1, -0.5f }).x,
		"from its right side, what is ahead of the figure is to the right");
	test::@check(math::abs(layout.pixel(1, { 0.5f, 1, 0 }).x - layout.pixel(1, { -0.5f, 1, 0 }).x) < 1.0e-3f,
		"the side view does not see across the figure");
	test::@check(math::abs(layout.pixel(0, { 0, 1.2f, 0.4f }).y - layout.pixel(1, { 0.3f, 1.2f, -0.2f }).y) < 1.0e-3f,
		"a height is the same row in both views");
}

fn void a_turned_figure_is_filmed_the_same() @test
{
	crig::StudioAsk ask = default_ask();
	crig::StudioLayout layout = crig::studio_layout(&figure, 1.8f, 0.0f, 0.0f, &ask);
	// The same figure facing world yaw 90 (+X): each point turned a quarter about +Y.
	Vec3[figure.len] turned;
	foreach (usz i, p : figure) turned[i] = { p.z, p.y, -p.x };
	crig::StudioLayout turned_layout = crig::studio_layout(&turned, 1.8f, 0.0f, 90.0f, &ask);
	test::@check(turned_layout.views[0].width == layout.views[0].width, "the split does not care which way the figure faces");
	for (usz v = 0; v < 2; v++)
	{
		foreach (usz i, p : figure)
		{
			float[<2>] a = layout.pixel(v, p);
			float[<2>] b = turned_layout.pixel(v, turned[i]);
			test::@check((a - b).length() < 1.0e-2f, "view %d, joint %d: %s, %s against %s, %s", v, i, a.x, a.y, b.x, b.y);
		}
	}
}

fn void the_far_cameras_land_points_where_orthographic_ones_would() @test
{
	crig::StudioAsk ask = default_ask();
	crig::StudioLayout layout = crig::studio_layout(&figure, 1.8f, 0.0f, 0.0f, &ask);
	float radius = 1.0f;
	Vec3[*] probes = { { 0, 0, 0 }, { 0.8f, 1.45f, 0.3f }, { -0.8f, 1.45f, -0.3f }, { 0.2f, 1.8f, 0.5f }, { -0.3f, 0.0f, -0.5f } };
	for (usz v = 0; v < 2; v++)
	{
		crig::OrbitCamera camera = layout.camera(v, radius);
		Matrix4f projection = camera.view_projection((float)layout.views[v].width / (float)layout.height);
		foreach (p : probes)
		{
			float[<2>] shown = layout.projected(v, projection, p);
			float[<2>] ortho = layout.pixel(v, p);
			test::@check((shown - ortho).length() < 0.5f, "view %d: the camera put a point at %s, %s, orthographic at %s, %s",
				v, shown.x, shown.y, ortho.x, ortho.y);
		}
	}
}

fn void a_given_front_width_is_kept_and_a_wide_figure_is_shrunk_to_fit() @test
{
	crig::StudioAsk ask = default_ask();
	ask.front_width = 400;
	crig::StudioLayout layout = crig::studio_layout(&figure, 1.8f, 0.0f, 0.0f, &ask);
	test::@check(layout.views[0].width == 400 && layout.views[1].width == 880, "the front view is as wide as asked");
	foreach (p : figure)
	{
		float[<2>] at = layout.pixel(0, p);
		test::@check(at.x > 0.0f && at.x < 400.0f, "the arms still fit the narrower front view (%s)", at.x);
	}

	// Arms twelve wide: the scale gives way rather than the arms leaving the picture.
	Vec3[*] wide = { { 6, 1.4f, 0 }, { -6, 1.4f, 0 }, { 0, 0, 0 }, { 0, 1.8f, 0 } };
	crig::StudioAsk free = default_ask();
	crig::StudioLayout shrunk = crig::studio_layout(&wide, 1.8f, 0.0f, 0.0f, &free);
	test::@check(shrunk.units_per_pixel > 1.8f / (0.8f * 630.0f), "the scale is coarser than fill alone asks");
	foreach (p : wide)
	{
		float[<2>] at = shrunk.pixel(0, p);
		test::@check(at.x > 0.0f && at.x < (float)shrunk.views[0].width, "a hand at %s stays in the front view (%s)", p.x, at.x);
	}
}
