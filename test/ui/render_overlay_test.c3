module crig_tests::ui;

import crig;
import cui;
import image;
import image::png;
import std::core::test;
import std::collections::object;
import std::encoding::json;
import std::math;

// What render's grab saw: whether the viewport was due a repaint, and the yaw.
struct RenderGrab @local
{
	Element* viewport;
	bool repainted;
	float yaw;
	crig::AppState* app;
}

fn bool overlay_grab(void* ctx, String path) @local
{
	RenderGrab* seen = ctx;
	seen.repainted = seen.viewport.dirty.paint;
	seen.yaw = seen.app.camera.yaw;
	char[8 * 8 * 4] pixels;
	image::Image picture = { .width = 8, .height = 8, .bit_depth = 8, .format = image::PixelFormat.RGBA, .pixels = pixels[..] };
	return @ok(png::save_file(&picture, path));
}

// The bones are painted from the camera, so a render that turns it has to repaint them.
fn void render_draws_the_bones_from_its_own_camera() @test
{
	Fixture fixture;
	if (catch fault error = fixture.open())
	{
		test::@check(false, "could not build the interface (%s)", error);
		return;
	}
	defer fixture.close();

	RenderGrab seen = { .viewport = fixture.viewport, .app = &fixture.app };
	fixture.app.screenshot = &overlay_grab;
	fixture.app.screenshot_ctx = &seen;
	fixture.viewport.dirty.paint = false;

	Object* args = json::parse(mem, `{"camera":{"yaw":70,"pitch":20}}`)!!;
	defer args.free();
	DString detail;
	defer detail.free();
	String? answer = crig::render_content(&fixture.app, args, &detail);
	if (catch answer)
	{
		test::@check(false, "render answers: %s", detail.str_view());
		return;
	}
	answer.free(mem);

	test::@check(math::abs(seen.yaw - 70.0f) < 0.001f, "the frame is taken from the render's camera");
	test::@check(seen.repainted, "and the viewport repaints for it, so the bones follow that camera");
}
