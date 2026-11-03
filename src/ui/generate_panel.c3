<*
 What text to motion still needs from the interface, now its settings are the
 Nodes pane's (`ui/nodes_panel.c3`): the frame-by-frame hook that lands a clip
 and loads it in the Animations pane, the running line, and a wrapping note.
*>
module crig;
import cui;
import cui::widgets;
import std::math;
import std::math::vector;
import std::core::string;
import std::time::clock;
import std::io;

fn void replace_owned(String* held, String text) @private
{
	if (held.len > 0) alloc::free(mem, held.ptr);
	// Empty holds nothing, so the `len > 0` frees never skip an allocation.
	*held = text.len > 0 ? text.copy(mem) : "";
}

fn String motion_fault_text(fault err)
{
	switch (err)
	{
		case MOTION_NO_GENERATOR: return "wire in a Kimodo text encoder and motion model, their files chosen";
		case MOTION_NO_PLUGIN: return "the kimodo plugin is not in the plugins folder — link it in File › Settings › AI › Plugins";
		case MOTION_NO_GPU: return "there is no GPU to run it on";
		case MOTION_BUSY: return "a generation is already running";
		case MOTION_NO_PROMPT: return "the prompt is empty";
		case MOTION_GUIDE_MISSING: return "the character has no clip by the name the guide poses name";
		case MOTION_GUIDE_UNMATCHED: return "this rig does not match Kimodo's human skeleton, so its poses cannot guide it";
		case MOTION_GUIDE_EMPTY: return "the guide clip has no key inside the length being generated";
		case MOTION_NO_SKELETON: return "add a skeleton first: a generated clip is put on the rig";
		case MOTION_BAD_SECONDS: return string::tformat("the length is %d to %d seconds", (int)MOTION_MIN_SECONDS, (int)MOTION_MAX_SECONDS);
		case MOTION_BAD_SEED: return "the seed is a whole number, for example 0";
		case MOTION_BAD_STEPS: return string::tformat("steps is a whole number from 1 to %d", MOTION_MAX_STEPS);
		case MOTION_NAME_TAKEN: return "the character already has a clip by that name — give this one another";
		default: return "the pipeline would not start";
	}
}

<*
 The line under the progress bar. The text encoder and the weight upload come
 before the first diffusion step, a few seconds with nothing to count.
*>
fn String generate_status_text(Element* elem) @private
{
	MotionJob* job = &elem.inherit(AppState)!!.motion_job;
	if (!job.running) return "";
	if (job.step == 0) return "Loading Kimodo and reading the prompt…".copy(mem);
	return string::format(mem, "Step %d of %d · %d%%", job.step, job.steps, (int)(job.progress() * 100.0f));
}

<*
 A frame's worth of the running job, and the landing: the clip a finished job
 bound is loaded in the Animations pane, to be played from there.
*>
fn void tick_generation(Ui* ui, AppState* app)
{
	bool was = app.motion_job.running;
	app.tick_motion_job();
	AnimRef landed;
	if (app.take_generated_clip(&landed))
	{
		foreach (sz i, bound : app.doc.animations.array_view())
		{
			if (!app.resolve_bound(i).same(landed)) continue;
			app.anim_selected = (usz)i;
			anim_edit_selected(ui);
			break;
		}
	}
	if (was != app.motion_job.running) refresh_animations_view(ui);

	// A video capture step, and the clip it lands (`app/capture.c3`).
	bool capturing = app.capture_job.running;
	app.tick_capture();
	if (app.take_captured_clip(&landed))
	{
		foreach (sz i, bound : app.doc.animations.array_view())
		{
			if (!app.resolve_bound(i).same(landed)) continue;
			app.anim_selected = (usz)i;
			anim_edit_selected(ui);
			break;
		}
	}
	if (capturing != app.capture_job.running) refresh_animations_view(ui);
}

// ---------------------------------------------------------------------------
// Two small widgets the pane needs and cui does not have.

const usz NOTE_MAX_LINES = 24;

<*
 A paragraph that wraps at words to the width it is offered — Label does not
 wrap, and a narrow pane cannot hold a sentence on one line. `text` is borrowed.
*>
struct GenerateNote (Widget)
{
	String text;
	float size;
	Color color;
	usz[NOTE_MAX_LINES] starts;
	usz[NOTE_MAX_LINES] lengths;
	usz lines;
}

fn Vec2 GenerateNote.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	float width = constraints.max.x;
	String text = self.text;
	self.lines = 0;
	usz start = 0;
	while (start < text.len && self.lines < NOTE_MAX_LINES)
	{
		while (start < text.len && text[start] == ' ') start++;
		if (start >= text.len) break;
		// Grow the line a word at a time until the next word would not fit.
		usz end = start;
		usz fits = start;
		while (end < text.len)
		{
			usz next = end;
			while (next < text.len && text[next] == ' ') next++;
			while (next < text.len && text[next] != ' ') next++;
			if (fits > start && elem.ui.text.measure(0, text[start:next - start], self.size).x > width) break;
			end = next;
			fits = next;
		}
		self.starts[self.lines] = start;
		self.lengths[self.lines] = fits - start;
		self.lines++;
		start = fits;
	}
	return constraints.constrain({ width, (float)self.lines * self.size * 1.35f });
}

fn void GenerateNote.paint(&self, Element* elem, Painter* painter) @dynamic
{
	for (usz i = 0; i < self.lines; i++)
	{
		painter.text({ 0, (float)i * self.size * 1.35f }, self.text[self.starts[i]:self.lengths[i]],
			{ .size = self.size, .color = self.color });
	}
}
