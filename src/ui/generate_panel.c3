<*
 The Generate pane: a prompt in, a generated clip on the character out. The work
 is `app/generate.c3`; this is the pane it is driven from, and the frame-by-frame
 hook that loads the clip in the Animations pane once it lands.

 A workspace view of its own rather than a dialog behind a button, so it is
 found by its tab and so a run's progress stays on screen while the rest of the
 window is used. The default workspace opens it under the Scene outliner.

 While a job runs the pane shows its progress and a Stop rather than a second
 Generate — there is one GPU and one job at a time. The MCP `generate_motion`
 tool drives the same job, so an agent's run shows here too.

 "Poses from" picks one of the character's clips as the guide: its keyed poses
 are ones the generated motion passes through (see `app/generate.c3`). A guide
 is an ordinary clip, made in the Animations pane — a few keys, no loop.
*>
module crig;
import cui;
import cui::widgets;
import std::math;
import std::math::vector;
import std::core::string;
import std::time::clock;
import std::io;

const String GENERATE_PANEL_ID = "generate-panel";
const String GENERATE_NAME_ID = "generate-name";
const String GENERATE_PROMPT_ID = "generate-prompt";
const String GENERATE_SECONDS_ID = "generate-seconds";
const String GENERATE_SEED_ID = "generate-seed";
const String GENERATE_STEPS_ID = "generate-steps";
const String GENERATE_GO_ID = "generate-go";
const String GENERATE_STOP_ID = "generate-stop";
const String GENERATE_GUIDE_ID = "generate-guide";
const float GENERATE_PROMPT_H = 64.0f;
const String GENERATE_PLACEHOLDER = "A person walks forward and waves with the right hand.";

// Set by the routes that open the pane for typing (the Animations pane's
// "+ Generate", the View menu); the pane puts the caret in the prompt on its next
// update, once it is in the tree.
bool generate_focus_pending;

fn Element* build_generate_view(Ui* ui)
{
	return @subtree(ui)
	{
		@tree((Scroll) { })
		{
			@tree((Padding) { .insets = widgets::insets_all(ANIM_PAD) })
			{
				@node((GeneratePanel) { }).with_id(GENERATE_PANEL_ID);
			};
		};
	};
}

// Every pane showing it, not the first: the workspace can be split so two do.
fn void refresh_generate_view(Ui* ui)
{
	ui.@each_id(GENERATE_PANEL_ID; panel)
	{
		panel.request_build();
	};
}

<*
 Bring the Generate pane on screen and put the caret in its prompt: a pane
 already showing it, or a spare one switched to it, or the 3D view split.
*>
fn void open_generate_panel(Ui* ui)
{
	show_pane_view(ui, GENERATE_VIEW, SplitAxis.HORIZONTAL, 2.0f / 3.0f);
	generate_focus_pending = true;
}

fn void anim_generate_clicked(Ui* ui) @private => open_generate_panel(ui);

fn bool generator_configured(AppState* app)
{
	MotionGenerator* g = &app.config.motion_generator;
	return g.text_model.len > 0 && g.model.len > 0;
}

<*
 What decides the pane's shape — the AnimSnapshot discipline: rebuild when the
 set of controls changes, never for a number, so the progress bar and the status
 line follow the job on their own.
*>
struct GenerateSnapshot
{
	bool configured;
	bool skeleton;
	bool running;
	bool failed;
	// The chooser lists the bound clips, so binding or dropping one rebuilds it.
	sz clips;
}

fn GenerateSnapshot generate_snapshot(AppState* app) @private
{
	return {
		.configured = generator_configured(app),
		.skeleton = app.doc.dots.len() > 0,
		.running = app.motion_job.running,
		.failed = app.motion_job.failed && !app.motion_job.running,
		.clips = app.doc.animations.len(),
	};
}

fn bool GenerateSnapshot.differs(self, GenerateSnapshot other)
{
	return self.configured != other.configured
		|| self.skeleton != other.skeleton
		|| self.running != other.running
		|| self.failed != other.failed
		|| self.clips != other.clips;
}

struct GeneratePanel (Widget)
{
	GenerateSnapshot shown;
	// The Name field's placeholder — the name an unnamed clip gets. Held here, not
	// in temp memory, because the field keeps pointing at it between builds.
	char[48] default_name;
}

fn Vec2 GeneratePanel.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	if (elem.children.len() == 0) return constraints.constrain({ 0, 0 });
	float width = constraints.max.x;
	Vec2 inner = elem.layout_child(0, cui::loose({ width, constraints.max.y }));
	elem.place_child(0, { 0, 0 });
	return constraints.constrain({ width, inner.y });
}

fn void GeneratePanel.update(&self, Element* elem, float dt) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	if (generate_focus_pending)
	{
		if (try Element* field = elem.find_id(GENERATE_PROMPT_ID))
		{
			generate_focus_pending = false;
			field.widget_as(TextField).select_all(field);
			field.request_focus();
		}
	}
	GenerateSnapshot now = generate_snapshot(app);
	if (!now.differs(self.shown)) return;
	self.shown = now;
	elem.request_build();
}

fn Element* GeneratePanel.build(&self, Element* elem) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	self.shown = generate_snapshot(app);
	MotionDraft* draft = &app.motion_draft;
	if (draft.seconds.len == 0) draft.seconds = "5".copy(mem);
	if (draft.seed.len == 0) draft.seed = "0".copy(mem);
	if (draft.steps.len == 0) draft.steps = string::format(mem, "%d", MOTION_DEFAULT_STEPS);

	MotionJob* job = &app.motion_job;

	Element* body = @subtree(elem.ui)
	{
		@tree((Column) { .gap = ANIM_GAP })
		{
			@node((Label) { .text = "Text to motion", .size = 16, .color = TEXT });
			if (!self.shown.configured)
			{
				@node((GenerateNote) { .text = "Text to motion needs the Kimodo weights. In File › Settings › AI, choose the text model (.gguf) and the motion model (a .gguf, or NVIDIA's Kimodo folder as downloaded).",
					.size = ANIM_TEXT_SIZE, .color = ACCENT });
				@node(accent_button("Open AI settings", &open_ai_settings)).with_id("generate-open-settings");
			}
			else
			{
				if (!self.shown.skeleton)
				{
					@node((GenerateNote) { .text = "This model has no skeleton yet. Rig it first; a generated clip is put on the rig.",
						.size = ANIM_TEXT_SIZE, .color = ACCENT });
				}
				String unnamed = (String)io::bprintf(self.default_name[..], "%s", app.next_generated_name(tmem)) ?? GENERATED_NAME_PREFIX;
				@tree((Wrap) { .gap_x = ANIM_GAP, .gap_y = 4, .cross_align = CENTER })
				{
					@node((Label) { .text = "Name", .size = ANIM_TEXT_SIZE, .color = TEXT_DIM });
					@node((TextField) { .width = 190, .style = TEXT_FIELD_STYLE, .placeholder = unnamed,
						.on_change = &generate_name_changed, .on_submit = &generate_field_submitted }).with_id(GENERATE_NAME_ID);
				};
				@node((Label) { .text = "Prompt", .size = ANIM_TEXT_SIZE, .color = TEXT_DIM });
				@node((TextField) { .multiline = true, .height = GENERATE_PROMPT_H, .style = TEXT_FIELD_STYLE,
					.placeholder = GENERATE_PLACEHOLDER, .on_change = &generate_prompt_changed,
					.on_submit = &generate_prompt_submitted }).with_id(GENERATE_PROMPT_ID);
				@tree((Wrap) { .gap_x = ANIM_GAP, .gap_y = 4, .cross_align = CENTER })
				{
					@node((Label) { .text = "Seconds", .size = ANIM_TEXT_SIZE, .color = TEXT_DIM });
					@node((TextField) { .width = 44, .style = TEXT_FIELD_STYLE, .on_change = &generate_seconds_changed,
						.on_submit = &generate_field_submitted }).with_id(GENERATE_SECONDS_ID);
					@node((Label) { .text = "Seed", .size = ANIM_TEXT_SIZE, .color = TEXT_DIM });
					@node((TextField) { .width = 64, .style = TEXT_FIELD_STYLE, .on_change = &generate_seed_changed,
						.on_submit = &generate_field_submitted }).with_id(GENERATE_SEED_ID);
					@node(panel_button("New", &generate_random_seed_clicked)).with_id("generate-random-seed");
					@node((Label) { .text = "Steps", .size = ANIM_TEXT_SIZE, .color = TEXT_DIM });
					@node((TextField) { .width = 48, .style = TEXT_FIELD_STYLE, .on_change = &generate_steps_changed,
						.on_submit = &generate_field_submitted }).with_id(GENERATE_STEPS_ID);
				};
				@tree((Wrap) { .gap_x = ANIM_GAP, .gap_y = 4, .cross_align = CENTER })
				{
					@node((Label) { .text = "Poses from", .size = ANIM_TEXT_SIZE, .color = TEXT_DIM });
					@node((GenerateGuideChooser) { });
				};
				if (self.shown.running)
				{
					@tree((Wrap) { .gap_x = ANIM_GAP, .gap_y = 4, .cross_align = CENTER })
					{
						@node(panel_button("Stop", &generate_stop_clicked)).with_id(GENERATE_STOP_ID);
						@node((Label) { .text = string::tformat("Generating \"%s\"", job.name), .size = ANIM_TEXT_SIZE, .color = TEXT });
					};
					@node((GenerateProgress) { });
					@node((LiveLabel) { .text_of = &generate_status_text, .size = { 0, TREE_STYLE.row_height },
						.text_size = 12, .color = TEXT_DIM });
				}
				else
				{
					@tree((Wrap) { .gap_x = ANIM_GAP, .gap_y = 4, .cross_align = CENTER })
					{
						@node(accent_button("Generate", &generate_confirmed)).with_id(GENERATE_GO_ID);
						@node((Label) { .text = "Ctrl+Return in the prompt", .size = 12, .color = TEXT_DIM });
					};
					if (self.shown.failed)
					{
						@node((GenerateNote) { .text = job.last(), .size = 12, .color = DOT_LOCKED });
					}
				}
				@node((GenerateNote) { .text = "Example prompt: \"walks forward, then sits down\". Another seed is another take on the same prompt; fewer steps is faster and rougher.",
					.size = 12, .color = TEXT_DIM });
				@node((GenerateNote) { .text = "Poses from loads clips/poses, to let Kimodo use them as reference steps, for its animation generation.",
					.size = 12, .color = TEXT_DIM });
			}
		};
	};

	foreach (pair : (String[2][]){ { GENERATE_NAME_ID, draft.name }, { GENERATE_PROMPT_ID, draft.prompt }, { GENERATE_SECONDS_ID, draft.seconds },
		{ GENERATE_SEED_ID, draft.seed }, { GENERATE_STEPS_ID, draft.steps } })
	{
		if (try Element* field = body.find_id(pair[0])) field.widget_as(TextField).set_text(field, pair[1]);
	}
	return body;
}

// ---------------------------------------------------------------------------
// The fields, kept in the draft as they are typed.

fn void replace_owned(String* held, String text) @private
{
	if (held.len > 0) alloc::free(mem, held.ptr);
	// Empty holds nothing, so the `len > 0` frees never skip an allocation.
	*held = text.len > 0 ? text.copy(mem) : "";
}

fn void generate_name_changed(Ui* ui, String text) @private => replace_owned(&ui.inherit(AppState)!!.motion_draft.name, text);
fn void generate_prompt_changed(Ui* ui, String text) @private => replace_owned(&ui.inherit(AppState)!!.motion_draft.prompt, text);
fn void generate_seconds_changed(Ui* ui, String text) @private => replace_owned(&ui.inherit(AppState)!!.motion_draft.seconds, text);
fn void generate_seed_changed(Ui* ui, String text) @private => replace_owned(&ui.inherit(AppState)!!.motion_draft.seed, text);
fn void generate_steps_changed(Ui* ui, String text) @private => replace_owned(&ui.inherit(AppState)!!.motion_draft.steps, text);

fn void generate_prompt_submitted(Ui* ui, String text) @private
{
	generate_prompt_changed(ui, text);
	generate_confirmed(ui);
}

fn void generate_field_submitted(Ui* ui, String text) @private => generate_confirmed(ui);

// Sets the field in place: a change of seed is not a change of the pane's shape.
fn void set_generate_field(Ui* ui, String id, String* held, String text) @private
{
	replace_owned(held, text);
	ui.@each_id(id; field)
	{
		field.widget_as(TextField).set_text(field, text);
	};
}

fn void generate_random_seed_clicked(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	ulong t = (ulong)clock::now();
	uint seed = (uint)((t * 6364136223846793005u + 1442695040888963407u) >> 33) % 100000u;
	set_generate_field(ui, GENERATE_SEED_ID, &app.motion_draft.seed, string::tformat("%d", seed));
}

// ---------------------------------------------------------------------------
// Generating and stopping.

<*
 The request the draft describes, or false with a notice saying what is wrong
 with it. `prompt` borrows the draft.
*>
fn bool generate_request(AppState* app, MotionRequest* out) @private
{
	MotionDraft* draft = &app.motion_draft;
	String prompt = draft.prompt.trim();
	if (prompt.len == 0) { app.@notice("Describe the motion to generate."); return false; }
	float? seconds = draft.seconds.trim().to_float();
	if (catch seconds) { app.@notice("Enter a length in seconds, for example 5."); return false; }
	if (!(seconds >= MOTION_MIN_SECONDS && seconds <= MOTION_MAX_SECONDS))
	{
		app.@notice("Length must be between %d and %d seconds.", (int)MOTION_MIN_SECONDS, (int)MOTION_MAX_SECONDS);
		return false;
	}
	uint? seed = draft.seed.trim().to_uint();
	if (catch seed) { app.@notice("The seed is a whole number, for example 0."); return false; }
	uint? steps = draft.steps.trim().to_uint();
	if (catch steps) { app.@notice("Steps is a whole number, for example 100."); return false; }
	if (steps < 1 || steps > MOTION_MAX_STEPS)
	{
		app.@notice("Steps must be between 1 and %d.", MOTION_MAX_STEPS);
		return false;
	}
	// Unnamed is "Generated N"; a name the character already holds is refused
	// rather than doubled, since clips are picked out by name.
	String name = draft.name.trim();
	if (name.len == 0)
	{
		name = app.next_generated_name(tmem);
	}
	else if (app.has_bound_clip_named(name))
	{
		app.@notice("The character already has a clip called \"%s\" — pick another name.", name);
		return false;
	}
	*out = { .prompt = prompt, .name = name, .seconds = seconds, .seed = seed, .steps = steps, .guide = draft.guide };
	return true;
}

fn void generate_confirmed(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	if (app.motion_job.running) { app.@notice("\"%s\" is still generating.", app.motion_job.name); return; }
	if (app.doc.dots.len() == 0) { app.@notice("Add a skeleton before generating an animation."); return; }
	MotionRequest request;
	if (!generate_request(app, &request)) return;
	if (catch err = app.start_motion_generation(request))
	{
		app.@notice("Could not start generating: %s", motion_fault_text(err));
		return;
	}
	// The name went to this clip; the next one starts unnamed again.
	set_generate_field(ui, GENERATE_NAME_ID, &app.motion_draft.name, "");
	refresh_generate_view(ui);
	refresh_animations_view(ui);
}

fn void generate_stop_clicked(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	app.stop_motion_generation();
	refresh_generate_view(ui);
	refresh_animations_view(ui);
}

fn String motion_fault_text(fault err)
{
	switch (err)
	{
		case MOTION_NO_GENERATOR: return "choose the Kimodo model files in File › Settings › AI";
		case MOTION_NO_GPU: return "there is no GPU to run it on";
		case MOTION_BUSY: return "a generation is already running";
		case MOTION_NO_PROMPT: return "the prompt is empty";
		case MOTION_GUIDE_MISSING: return "the character has no clip by the name chosen under Poses from";
		case MOTION_GUIDE_UNMATCHED: return "this rig does not match Kimodo's human skeleton, so its poses cannot guide it";
		case MOTION_GUIDE_EMPTY: return "the Poses from clip has no key inside the length being generated";
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
	if (!job.running) return "".copy(mem);
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
}

// ---------------------------------------------------------------------------
// "Poses from": None, or one of the character's clips.

<*
 The guide dropdown. Owns its labels, as `AnimChooser` does, so a clip renamed
 or dropped cannot leave the Select pointing into freed strings.
*>
struct GenerateGuideChooser (Widget)
{
	String[] labels;
}

fn void GenerateGuideChooser.release(&self)
{
	foreach (label : self.labels) label.free(mem);
	if (self.labels.len > 0) alloc::free(mem, self.labels);
	self.labels = {};
}

fn void GenerateGuideChooser.unmount(&self, Element* elem) @dynamic => self.release();

fn Element* GenerateGuideChooser.build(&self, Element* elem) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	self.release();
	sz bound = app.doc.animations.len();
	self.labels = alloc::new_array(mem, String, bound + 1);
	self.labels[0] = "None".copy(mem);
	usz selected = 0;
	foreach (sz i, clip : app.doc.animations.array_view())
	{
		self.labels[i + 1] = clip.clip.copy(mem);
		if (clip.clip == app.motion_draft.guide) selected = (usz)i + 1;
	}
	// The clip it named has gone: back to None, so what is shown is what is sent.
	if (selected == 0 && app.motion_draft.guide.len > 0) replace_owned(&app.motion_draft.guide, "");
	return @subtree(elem.ui)
	{
		@node((Select) { .options = self.labels, .selected = selected,
			.width = 190, .style = VIEW_MENU_STYLE, .searchable = self.labels.len > ANIM_CHOOSER_SEARCH_MIN,
			.on_change = &generate_guide_chosen }).with_id(GENERATE_GUIDE_ID);
	};
}

fn Vec2 GenerateGuideChooser.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	Vec2 own = elem.layout_child(0, constraints);
	elem.place_child(0, { 0, 0 });
	return own;
}

fn void generate_guide_chosen(Ui* ui, usz row) @private
{
	AppState* app = ui.inherit(AppState)!!;
	String name = row == 0 || (sz)row > app.doc.animations.len() ? "" : app.doc.animations[(sz)row - 1].clip;
	replace_owned(&app.motion_draft.guide, name);
}

// ---------------------------------------------------------------------------
// Two small widgets the pane needs and cui does not have.

<*
 The running job's progress as a bar, full width. Repaints itself as the step
 count moves; never rebuilds.
*>
struct GenerateProgress (Widget)
{
	float shown;
}

fn Vec2 GenerateProgress.layout(&self, Element* elem, Constraints constraints) @dynamic
	=> constraints.constrain({ constraints.max.x, 6 });

fn void GenerateProgress.update(&self, Element* elem, float dt) @dynamic
{
	float now = elem.inherit(AppState)!!.motion_job.progress();
	if (now == self.shown) return;
	self.shown = now;
	elem.request_paint();
}

fn void GenerateProgress.paint(&self, Element* elem, Painter* painter) @dynamic
{
	float radius = elem.size.y * 0.5f;
	painter.rect({ 0, 0 }, elem.size, { .color = BTN, .border_radius = { radius, radius, radius, radius } });
	float fill = elem.size.x * math::clamp(self.shown, 0.0f, 1.0f);
	if (fill < 1.0f) return;
	painter.rect({ 0, 0 }, { fill, elem.size.y }, { .color = ACCENT, .border_radius = { radius, radius, radius, radius } });
}

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
