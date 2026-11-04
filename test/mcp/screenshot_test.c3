module crig_tests::mcp;
import crig;
import image;
import image::png;
import mcp;
import three;
import rig;
import crig_tests::library;
import crig_tests::shared_app;
import std::core::test;
import std::collections::object;
import std::encoding::base64;
import std::encoding::json;
import std::io;
import std::io::file;
import std::io::path;
import std::math;
import std::math::quaternion;

// ---------------------------------------------------------------------------
// screenshot
//
// The only tool whose answer is not text, so the only one whose wrapping is
// worth a check of its own: an image block reaches a client as JSON with a
// base64 `data` member, and the escaped-into-text treatment every other tool
// gets would deliver the characters of that JSON instead.
//
// The renderer is stood in for. `AppState.screenshot` is a hook precisely so
// that something with no GPU can fill it, and a 4x2 PNG exercises every step
// from the grab through the decode to the base64 on the wire.

// A 4x2 checker, written where a renderer would have written its frame. `ctx`
// is a bool the check reads back, since "was the hook called at all" is not
// answerable from the response alone.
fn bool fake_grab(void* ctx, String path)
{
	char[4 * 2 * 4] pixels;
	foreach (i, &channel : pixels) *channel = (i / 4) % 2 == 0 ? 0 : 255;

	image::Image picture = {
		.width = 4,
		.height = 2,
		.bit_depth = 8,
		.format = image::PixelFormat.RGBA,
		.pixels = pixels[..],
	};
	if (catch png::save_file(&picture, path)) return false;

	*(bool*)ctx = true;
	return true;
}

// A hook that reports failure without writing anything — a window on its way
// closed, which is not the same as having no window at all.
fn bool refusing_grab(void* ctx, String path) => false;

// A window-sized stand-in for the render checks: big enough that the tiling has
// real rows to move and the sheet's size is arithmetic rather than a floor. The
// 4x2 checker above is right for screenshot, where the picture's size is the
// whole assertion, and too small here.
fn bool wide_grab(void* ctx, String path)
{
	char[64 * 40 * 4] pixels;
	foreach (i, &channel : pixels) *channel = (char)(i % 251);

	image::Image picture = {
		.width = 64,
		.height = 40,
		.bit_depth = 8,
		.format = image::PixelFormat.RGBA,
		.pixels = pixels[..],
	};
	if (catch png::save_file(&picture, path)) return false;

	*(int*)ctx = *(int*)ctx + 1;
	return true;
}

fn bool? screenshot_body(Object* root, String* mime, String* data, String* caption)
{
	Object* content = root.get("result")!.get("content")!;
	if (content.get_len() != 2) return false;

	Object* picture = content.get_at(0);
	if (picture.get_string("type")! != "image") return false;
	*mime = picture.get_string("mimeType")!;
	*data = picture.get_string("data")!;

	Object* text = content.get_at(1);
	if (text.get_string("type")! != "text") return false;
	*caption = text.get_string("text")!;
	return true;
}

fn void screenshot_answers_with_a_picture() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	bool grabbed = false;
	f.app.screenshot = &fake_grab;
	f.app.screenshot_ctx = &grabbed;

	Object*? root = f.request(`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"screenshot","arguments":{}}}`);
	if (catch root)
	{
		test::@check(false, "screenshot answers");
		return;
	}
	defer root.free();

	String mime;
	String data;
	String caption;
	if (!(screenshot_body(root, &mime, &data, &caption) ?? false))
	{
		test::@check(false, "screenshot answers with an image block and a caption");
		return;
	}

	test::@check(grabbed, "screenshot draws a frame rather than reusing one");
	test::@check(mime == "image/png", "and declares it a PNG");
	test::@check(caption == "4 x 2 pixels", "and says how big the picture is");

	// The base64 is the file, not a description of it: decoded, it starts with
	// the PNG signature. A tool that answered with an escaped JSON document
	// would pass every check above and fail this one.
	char[]? decoded = base64::decode(mem, (char[])data);
	if (catch decoded)
	{
		test::@check(false, "the image data is base64");
		return;
	}
	defer alloc::free(mem, decoded);
	char[8] signature = { 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a };
	test::@check(decoded.len > 8 && decoded[:8] == signature[..], "and decodes to a PNG");
}

fn void screenshot_says_when_there_is_nothing_to_photograph() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	// No hook: an AppState built by anything but `main`, which is every check and
	// every headless run.
	Object*? root = f.request(`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"screenshot","arguments":{}}}`);
	if (catch root)
	{
		test::@check(false, "screenshot answers with no window");
		return;
	}
	defer root.free();
	test::@check(error_code_is(root, -32603) && error_message_contains(root, "no window"),
		"a crig with no window says so rather than answering with a blank picture");

	f.app.screenshot = &refusing_grab;
	Object*? refused = f.request(`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"screenshot","arguments":{}}}`);
	if (catch refused)
	{
		test::@check(false, "screenshot answers a refused grab");
		return;
	}
	defer refused.free();
	test::@check(error_code_is(refused, -32603) && error_message_contains(refused, "no frame was drawn"),
		"and a frame that did not happen is an error, not an empty image block");
}
