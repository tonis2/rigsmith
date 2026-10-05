<*
 The `screenshot` tool's payload: a PNG of the window as MCP image content.

 The one tool whose answer is a picture rather than a number, and the only
 reason `ToolDef.raw_content` exists — an image block carries base64 in a
 `data` member, which is not something a text block can hold.

 It is the counterpart to `get_pose` and `get_weights` in the same way
 `show_weights` is to `get_weights`: those say what the document contains, this
 says what it looks like. Layout, occlusion, a panel that opened over the
 viewport, a gizmo drawn at the wrong depth — every question a person answers by
 glancing at the screen is one no amount of JSON reaches.

 Held apart from server.c3 because it is the only tool that decodes an image and
 the only one that writes to a temporary file, and neither belongs in the
 registry — the same split `clip.c3` already makes for apply_clip.
*>
module crig;

import image;
import image::png;

import std::encoding::base64;
import std::io;
import std::io::file;
import std::io::path;
import std::math;

faultdef SCREENSHOT_UNAVAILABLE, SCREENSHOT_FAILED, SCREENSHOT_UNREADABLE;

<*
 The longest edge the answer is allowed to have, in pixels.

 A client resamples a large image down to about this before a model ever sees
 it, so anything above it is bytes on the wire for pixels that are thrown away —
 and a retina window is 2560 across, four times the data of a picture that reads
 exactly the same. Below it nothing is resized at all.
*>
const uint SHOT_MAX_EDGE @local = 1568;

// Where the frame lands on its way from the renderer to base64. One fixed name,
// overwritten and then deleted every call, so a run that dies mid-grab leaves
// one stale file rather than a growing pile.
const String SHOT_FILE @local = "rigsmith-mcp-shot.png";

<*
 A PNG of crig's window, as the MCP content array for one tools/call.

 Two blocks: the image, and a line of text naming its pixel size and what it was
 scaled from if it was scaled at all. That ratio is the one thing a picture
 cannot say about itself, and without it a distance measured off the image is
 not a distance on the screen.

 Draws a frame, so it must be called between frames; see
 `AppState.grab_screenshot`. The result is allocated from `mem` and freed by the
 caller. The temporary file is deleted before returning, on every path out.

 Faults when there is no window to photograph, when the frame could not be
 drawn, or when what was written back is not a PNG this can read; `detail`
 carries which of the three, since an agent's next move differs in each case.
*>
fn String? screenshot_content(AppState* app, DString* detail)
{
	if (!app.screenshot)
	{
		detail.append_string("no window to photograph — this crig is running headless, "
			"or its surface refused the transfer a screenshot is read back through");
		return SCREENSHOT_UNAVAILABLE~;
	}

	String shot_path = temp_shot_path();
	defer shot_path.free(mem);
	// Registered before the grab rather than after it: a frame that failed
	// halfway still leaves a file, and the next call would read that one and
	// answer with a window from minutes ago.
	defer (void)file::delete(shot_path);

	if (!app.grab_screenshot(shot_path))
	{
		detail.append_string("no frame was drawn — the window is closing, or the "
			"surface refused the transfer a screenshot is read back through");
		return SCREENSHOT_FAILED~;
	}

	image::Image? grabbed = png::load_file(shot_path, mem);
	if (catch fault error = grabbed)
	{
		detail.appendf("the frame was written but could not be read back: %s", error);
		return SCREENSHOT_UNREADABLE~;
	}
	image::Image shot = grabbed;
	defer shot.free();

	uint window_width = shot.width;
	uint window_height = shot.height;

	// Down to something a client keeps, and only ever down: enlarging a small
	// window would cost bytes for pixels that were never rendered.
	uint edge = math::max(shot.width, shot.height);
	if (edge > SHOT_MAX_EDGE)
	{
		// Rounded up, so neither side can land on zero however thin the window is.
		uint width = (uint)(((ulong)shot.width * SHOT_MAX_EDGE + edge - 1) / edge);
		uint height = (uint)(((ulong)shot.height * SHOT_MAX_EDGE + edge - 1) / edge);
		image::Image smaller = shot.resize(width, height, mem);
		shot.free();
		shot = smaller;
	}

	char[]? encoded = png::save_bytes(&shot, mem);
	if (catch fault error = encoded)
	{
		detail.appendf("the frame could not be re-encoded: %s", error);
		return SCREENSHOT_UNREADABLE~;
	}
	char[] bytes = encoded;
	defer alloc::free(mem, bytes);

	String data = base64::encode(mem, bytes);
	defer data.free(mem);

	DString out = dstring::new(mem);
	defer out.free();
	out.append_string(`[{"type":"image","mimeType":"image/png","data":"`);
	// No escaping: base64's alphabet is letters, digits, + / and =, none of
	// which JSON quotes.
	out.append_string(data);
	out.appendf(`"},{"type":"text","text":"%d x %d pixels`, shot.width, shot.height);
	if (shot.width != window_width)
	{
		out.appendf(`, scaled down from a %d x %d window`, window_width, window_height);
	}
	out.append_string(`"}]`);
	return out.copy_str(mem);
}

// The temporary file's full path, allocated from `mem`. Falls back to the
// working directory when the platform will not name a temp directory, which is
// somewhere to write rather than a good place for it.
fn String temp_shot_path() @local
{
	Path? directory = path::temp_directory(mem);
	if (catch directory) return SHOT_FILE.copy(mem);
	defer directory.free(mem);
	return string::format(mem, "%s/%s", (String)directory, SHOT_FILE);
}
