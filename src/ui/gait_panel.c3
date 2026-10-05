<*
 The Gait panel: "+ Gait" in the Animations pane. Pick a gait, see when each foot
 is on the floor, and write the cycle onto the character.

 The work is `AppState.author_gait` (app/gait_author.c3), the same path the MCP
 `author_gait` tool takes; this is the dialog in front of it.

 The footfall diagram is one row per foot found on the rig (`gait_find_feet`): a
 bar across the cycle from the foot's offset for `duty` of it — stance, wrapping
 through the loop point. The named gaits fill the offsets in; Custom makes every
 row draggable, which is the one thing the named gaits cannot say.

 **The draft lives here, not on the AppState.** `Dialog.body` is rebuilt on every
 opening, so the answers are gathered when the dialog opens and live only as long
 as it is up; the diagram reads them directly so a drag or a new gait repaints it
 without rebuilding the form around a focused field.
*>
module crig;

import cui;
import cui::widgets;
import rig;
import std::math;
import std::core::string;

const String GAIT_DIALOG_ID = "gait-dialog";
const String GAIT_BUTTON_ID = "anim-gait";
const String GAIT_NAME_ID = "gait-name";
const String GAIT_KIND_ID = "gait-kind";
const String GAIT_DURATION_ID = "gait-duration";
const String GAIT_LOOP_ID = "gait-loop";
const String GAIT_DUTY_ID = "gait-duty";
const String GAIT_STRIDE_ID = "gait-stride";
const String GAIT_LIFT_ID = "gait-lift";
const String GAIT_SAMPLES_ID = "gait-samples";
const String GAIT_DIAGRAM_ID = "gait-diagram";
const String GAIT_CREATE_ID = "gait-create";
// One number field per foot row, in the Advanced section.
String[8] gait_offset_ids = {
	"gait-offset-0", "gait-offset-1", "gait-offset-2", "gait-offset-3",
	"gait-offset-4", "gait-offset-5", "gait-offset-6", "gait-offset-7",
};

const float GAIT_W = 360.0f;
const float GAIT_GAP = 8.0f;
const float GAIT_TEXT = 13.0f;
const float GAIT_ROW_H = 20.0f;
const float GAIT_LABEL_W = 92.0f;
const float GAIT_VALUE_W = 40.0f;
const float GAIT_AXIS_H = 16.0f;
// A dragged offset lands on a fortieth of the cycle: the default key spacing.
const float GAIT_SNAP = 1.0f / 40.0f;
const usz GAIT_NAME_CHARS = 40;

String[5] gait_kind_options = { "Walk", "Trot", "Pace", "Gallop", "Custom" };
GaitKind[5] gait_kinds = { WALK, TROT, PACE, GALLOP, CUSTOM };

const DisclosureStyle GAIT_SECTION_STYLE = {
	.background = PANEL,
	.header = BTN,
	.header_hover = BTN_HOVER,
	.border = PANEL_BORDER,
	.text = TEXT,
	.mark = TEXT_DIM,
	.radius = R8,
	.header_height = 28.0f,
	.text_size = 13.0f,
	.padding = 10.0f,
	.gap = 6.0f,
	.border_width = 1.0f,
};

struct GaitRow
{
	char[GAIT_NAME_CHARS] text;
	usz len;
	usz joint;
	float offset;
	// What the chosen gait laid down, so a typed offset is told from an untouched one.
	float preset;
	// The offset the field was last given, so a typed one is told from a stale one.
	float synced;
}

<*
 Everything the open dialog is asking about. `leg` is the average leg height the
 stride placeholder is read off; `duty` is the typed advanced duty, or zero while
 it is left to the gait.
*>
struct GaitDraft
{
	GaitKind kind;
	usz count;
	GaitRow[GAIT_FEET_MAX] rows;
	float leg;
	float duty;
	// The name the field was last given for itself, so changing the gait renames
	// it only while the person has not typed their own.
	char[GAIT_NAME_CHARS] suggested;
	usz suggested_len;
}

GaitDraft gait_draft;

// Placeholders are borrowed by their fields, so they are kept where they outlive a call.
char[16][3] gait_hints;
usz[3] gait_hint_lens;

fn String gait_kind_title(GaitKind kind) => gait_kind_options[(usz)kind];

fn String GaitRow.name(&self) => (String)self.text[:self.len];

<*
 Open the panel: find the feet, lay out the named gait's offsets, and raise the
 dialog. Refuses, with a notice, on a document with no rig.
*>
fn void open_gait_panel(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (app.doc.dots.len() == 0)
	{
		app.@notice("Add a skeleton before creating a gait.");
		return;
	}
	gait_draft = { .kind = WALK };
	RigView? opened = app.open_rig(mem);
	if (try view = opened)
	{
		defer view.free(mem);
		usz[GAIT_FEET_MAX] joints;
		usz count = gait_find_feet(&view.skeleton, view.names, joints[:GAIT_FEET_MAX]);
		gait_draft.count = count;
		for (usz i = 0; i < count; i++)
		{
			String name = view.names[joints[i]];
			usz len = math::min((usz)name.len, GAIT_NAME_CHARS);
			gait_draft.rows[i].text[:len] = name[:len];
			gait_draft.rows[i].len = len;
			gait_draft.rows[i].joint = joints[i];
		}
		gait_draft.leg = gait_leg_height(&view.skeleton, joints[:count]);
		gait_apply_kind(&view.skeleton, WALK);
	}
	set_dialog_open(ui, GAIT_DIALOG_ID, true);
}

fn void anim_gait_clicked(Ui* ui) @private => open_gait_panel(ui);

// The named gait's offsets into the rows. Custom keeps whatever the rows hold.
fn void gait_apply_kind(rig::Skeleton* skeleton, GaitKind kind) @private
{
	gait_draft.kind = kind;
	if (kind == CUSTOM || gait_draft.count == 0) return;
	usz[GAIT_FEET_MAX] joints;
	float[GAIT_FEET_MAX] offsets;
	for (usz i = 0; i < gait_draft.count; i++) joints[i] = gait_draft.rows[i].joint;
	gait_offsets(skeleton, kind, joints[:gait_draft.count], offsets[:gait_draft.count]);
	for (usz i = 0; i < gait_draft.count; i++)
	{
		gait_draft.rows[i].offset = offsets[i];
		gait_draft.rows[i].preset = offsets[i];
	}
}

fn String gait_offset_text(float offset) => string::tformat("%.2f", offset);

// The offset fields follow the rows: after a new gait or a drag on the diagram.
fn void gait_sync_offset_fields(Ui* ui) @private
{
	for (usz i = 0; i < gait_draft.count; i++)
	{
		if (try Element* field = ui.find_id(gait_offset_ids[i]))
		{
			field.widget_as(TextField).set_text(field, gait_offset_text(gait_draft.rows[i].offset));
			gait_draft.rows[i].synced = gait_draft.rows[i].offset;
		}
	}
}

<*
 Each foot's landing phase as the fields hold it, into `offsets`. Returns false
 when a field is not a phase in [0, 1]; `changed` says whether any differs from
 what the gait laid down.
*>
fn bool gait_read_offsets(Ui* ui, float[] offsets, bool* changed) @private
{
	*changed = false;
	for (usz i = 0; i < gait_draft.count; i++)
	{
		GaitRow* row = &gait_draft.rows[i];
		offsets[i] = row.offset;
		String text = field_text(ui, gait_offset_ids[i]);
		if (text.len == 0) continue;
		float? parsed = text.to_float();
		if (catch parsed) return false;
		if (!(parsed >= 0.0f && parsed <= 1.0f)) return false;
		if (text != gait_offset_text(row.synced)) offsets[i] = parsed;
		if (offsets[i] != row.preset && gait_offset_text(offsets[i]) != gait_offset_text(row.preset)) *changed = true;
	}
	return true;
}

// Set one row's offset, as a drag or a test does: a phase in [0, 1), snapped.
fn void gait_set_offset(usz row, float phase)
{
	if (row >= gait_draft.count) return;
	float snapped = math::round(phase / GAIT_SNAP) * GAIT_SNAP;
	snapped -= math::floor(snapped);
	gait_draft.rows[row].offset = snapped;
}

fn float gait_shown_duty() @private
{
	return gait_draft.duty > 0.0f ? gait_draft.duty : gait_default_duty(gait_draft.kind, gait_draft.count);
}

fn String gait_suggested_name(GaitKind kind) @private => gait_kind_title(kind);

fn Element* build_gait_body(Ui* ui)
{
	GaitKind kind = gait_draft.kind;
	float leg = gait_draft.leg;
	String stride_hint = string::tformat("%.3g", gait_default_stride(kind) * leg);
	String lift_hint = string::tformat("%.2g", gait_default_lift(kind));
	String duty_hint = string::tformat("%.2g", gait_default_duty(kind, gait_draft.count));
	gait_store_hint(0, stride_hint);
	gait_store_hint(1, lift_hint);
	gait_store_hint(2, duty_hint);

	Element* body = @subtree(ui)
	{
		@tree((Column) { .size = { GAIT_W, 0 }, .gap = GAIT_GAP })
		{
			@node((Label) { .text = "Name", .size = GAIT_TEXT, .color = TEXT_DIM });
			@node((TextField) { .width = GAIT_W, .style = TEXT_FIELD_STYLE }).with_id(GAIT_NAME_ID);
			@node((Segmented) {
				.options = gait_kind_options[..],
				.selected = (sz)kind,
				.on_change = &gait_kind_chosen,
				.style = SEGMENTED_STYLE,
			}).with_id(GAIT_KIND_ID);
			@tree((Row) { .gap = GAIT_GAP, .cross_align = CENTER })
			{
				@node((Label) { .text = "Duration (s)", .size = GAIT_TEXT, .color = TEXT_DIM });
				@node((TextField) { .width = 70, .style = TEXT_FIELD_STYLE }).with_id(GAIT_DURATION_ID);
				@node((Checkbox) { .label = "Loop", .checked = true, .style = CHECKBOX_STYLE }).with_id(GAIT_LOOP_ID);
			};

			if (gait_draft.count == 0)
			{
				@node((Label) { .text = "No feet found. Legs are found from left/right limbs (thigh_L / thigh_R ...) that end in a foot and a toe near the floor. Name the joints that way, or fit a biped or quadruped plan.",
					.size = 12, .color = TEXT_DIM });
			}
			else
			{
				@node((Label) { .text = "Footfalls: drag a bar to set when that foot lands (Custom); each bar is the foot on the floor.",
					.size = 12, .color = TEXT_DIM });
				@node((GaitDiagram) { }).with_id(GAIT_DIAGRAM_ID);
			}

			@tree((Disclosure) { .label = "Advanced", .expanded = false, .width = GAIT_W,
				.style = GAIT_SECTION_STYLE })
			{
				@tree((Column) { .size = { GAIT_W - 20.0f, 0 }, .gap = 6.0f })
				{
					@tree((Row) { .gap = GAIT_GAP, .cross_align = CENTER })
					{
						@node((Label) { .text = "Duty", .size = GAIT_TEXT, .color = TEXT_DIM });
						@node((TextField) { .width = 60, .placeholder = gait_hint_text(2), .style = TEXT_FIELD_STYLE,
							.on_change = &gait_duty_changed }).with_id(GAIT_DUTY_ID);
						@node((Label) { .text = "Samples", .size = GAIT_TEXT, .color = TEXT_DIM });
						@node((TextField) { .width = 60, .placeholder = "40", .style = TEXT_FIELD_STYLE }).with_id(GAIT_SAMPLES_ID);
					};
					@tree((Row) { .gap = GAIT_GAP, .cross_align = CENTER })
					{
						@node((Label) { .text = "Stride", .size = GAIT_TEXT, .color = TEXT_DIM });
						@node((TextField) { .width = 60, .placeholder = gait_hint_text(0), .style = TEXT_FIELD_STYLE }).with_id(GAIT_STRIDE_ID);
						@node((Label) { .text = "Lift", .size = GAIT_TEXT, .color = TEXT_DIM });
						@node((TextField) { .width = 60, .placeholder = gait_hint_text(1), .style = TEXT_FIELD_STYLE }).with_id(GAIT_LIFT_ID);
					};
					if (gait_draft.count > 0)
					{
						@node((Label) { .text = "Foot offsets (phase of the cycle each foot lands, 0 to 1)", .size = 12, .color = TEXT_DIM });
						for (usz i = 0; i < gait_draft.count; i++)
						{
							@tree((Row) { .gap = GAIT_GAP, .cross_align = CENTER })
							{
								@node((Label) { .text = gait_draft.rows[i].name(), .size = GAIT_TEXT, .color = TEXT_DIM });
								@node((TextField) { .width = 60, .style = TEXT_FIELD_STYLE }).with_id(gait_offset_ids[i]);
							};
						}
					}
					@node((Label) { .text = "Stride in model units, lift as a fraction of the leg, duty as a fraction of the cycle. Empty takes the gait's own.",
						.size = 12, .color = TEXT_DIM });
				};
			};

			@tree((Row) { .gap = GAIT_GAP })
			{
				@node(accent_button("Create", &gait_create_confirmed)).with_id(GAIT_CREATE_ID);
				@node(panel_button("Cancel", &gait_cancelled)).with_id("gait-cancel");
			};
		};
	};

	String suggestion = gait_suggested_name(kind);
	focus_field(body, GAIT_NAME_ID, suggestion);
	gait_draft.suggested_len = math::min((usz)suggestion.len, GAIT_NAME_CHARS);
	gait_draft.suggested[:gait_draft.suggested_len] = suggestion[:gait_draft.suggested_len];
	Element* duration = body.find_id(GAIT_DURATION_ID)!!;
	duration.widget_as(TextField).set_text(duration, "1");
	for (usz i = 0; i < gait_draft.count; i++)
	{
		Element* field = body.find_id(gait_offset_ids[i])!!;
		field.widget_as(TextField).set_text(field, gait_offset_text(gait_draft.rows[i].offset));
		gait_draft.rows[i].synced = gait_draft.rows[i].offset;
	}
	return body;
}

fn void gait_store_hint(usz slot, String text) @private
{
	usz len = math::min((usz)text.len, (usz)15);
	gait_hints[slot][:len] = text[:len];
	gait_hint_lens[slot] = len;
}

fn String gait_hint_text(usz slot) @private => (String)gait_hints[slot][:gait_hint_lens[slot]];

fn void gait_cancelled(Ui* ui) => set_dialog_open(ui, GAIT_DIALOG_ID, false);

fn void gait_kind_chosen(Ui* ui, usz row)
{
	AppState* app = ui.inherit(AppState)!!;
	GaitKind kind = gait_kinds[math::min(row, (usz)4)];
	RigView? opened = app.open_rig(mem);
	if (try view = opened)
	{
		defer view.free(mem);
		gait_apply_kind(&view.skeleton, kind);
	}
	else
	{
		gait_draft.kind = kind;
	}

	// The name follows the gait until the person writes their own.
	if (try Element* field = ui.find_id(GAIT_NAME_ID))
	{
		String shown = field_text(ui, GAIT_NAME_ID);
		if (shown.len == 0 || shown == (String)gait_draft.suggested[:gait_draft.suggested_len])
		{
			String next = gait_suggested_name(kind);
			field.widget_as(TextField).set_text(field, next);
			gait_draft.suggested_len = math::min((usz)next.len, GAIT_NAME_CHARS);
			gait_draft.suggested[:gait_draft.suggested_len] = next[:gait_draft.suggested_len];
		}
	}
	// The placeholders in Advanced are the gait's own.
	gait_store_hint(0, string::tformat("%.3g", gait_default_stride(kind) * gait_draft.leg));
	gait_store_hint(1, string::tformat("%.2g", gait_default_lift(kind)));
	gait_store_hint(2, string::tformat("%.2g", gait_default_duty(kind, gait_draft.count)));
	String[3] ids = { GAIT_STRIDE_ID, GAIT_LIFT_ID, GAIT_DUTY_ID };
	foreach (i, id : ids)
	{
		if (try Element* field = ui.find_id(id))
		{
			field.widget_as(TextField).placeholder = gait_hint_text((usz)i);
			field.request_paint();
		}
	}
	gait_sync_offset_fields(ui);
	gait_repaint(ui);
}

fn void gait_duty_changed(Ui* ui, String text)
{
	float? parsed = text.trim().to_float();
	gait_draft.duty = 0.0f;
	if (try value = parsed)
	{
		if (value >= 0.1f && value <= 0.9f) gait_draft.duty = value;
	}
	gait_repaint(ui);
}

fn void gait_repaint(Ui* ui)
{
	if (try Element* diagram = ui.find_id(GAIT_DIAGRAM_ID)) diagram.request_paint();
}

// A number from a field: `fallback` when it is empty, and false when it is not one.
fn bool gait_field_number(Ui* ui, String id, float fallback, float* into) @private
{
	String text = field_text(ui, id);
	if (text.len == 0)
	{
		*into = fallback;
		return true;
	}
	float? parsed = text.to_float();
	if (catch parsed) return false;
	if (!math::is_finite(parsed)) return false;
	*into = parsed;
	return true;
}

fn void gait_create_confirmed(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (gait_draft.count == 0)
	{
		app.@notice("No feet to walk on. Name the legs _L/_R with a foot and toe, or fit a plan first.");
		return;
	}

	GaitSpec spec = { .kind = gait_draft.kind, .loop = true, .samples = GAIT_SAMPLES_DEFAULT };
	if (!gait_field_number(ui, GAIT_DURATION_ID, 1.0f, &spec.duration) || !(spec.duration > 0.0f && spec.duration <= 600.0f))
	{
		app.@notice("Enter a duration in seconds, for example 1.");
		return;
	}
	if (try Element* loop = ui.find_id(GAIT_LOOP_ID)) spec.loop = loop.widget_as(Checkbox).checked;

	float duty;
	float stride;
	float lift;
	float samples;
	if (!gait_field_number(ui, GAIT_DUTY_ID, 0.0f, &duty) || (duty != 0.0f && (duty < 0.1f || duty > 0.9f)))
	{
		app.@notice("Duty is the share of the cycle a foot is down, 0.1 to 0.9.");
		return;
	}
	if (!gait_field_number(ui, GAIT_STRIDE_ID, 0.0f, &stride) || stride < 0.0f)
	{
		app.@notice("Stride is a length in model units, more than zero.");
		return;
	}
	if (!gait_field_number(ui, GAIT_LIFT_ID, 0.0f, &lift) || lift < 0.0f || lift > 1.0f)
	{
		app.@notice("Lift is a fraction of the leg's height, more than zero and at most one.");
		return;
	}
	if (!gait_field_number(ui, GAIT_SAMPLES_ID, (float)GAIT_SAMPLES_DEFAULT, &samples) || samples < 8.0f || samples > (float)GAIT_SAMPLES_MOST)
	{
		app.@notice("Samples is a whole number of keys per cycle, 8 to %d.", GAIT_SAMPLES_MOST);
		return;
	}
	spec.duty = duty;
	spec.stride = stride;
	spec.samples = (usz)samples;

	String typed = field_text(ui, GAIT_NAME_ID);
	String wanted = typed.len > 0 ? typed : gait_suggested_name(gait_draft.kind);
	// Never the clip already called that: a second Walk is Walk_2, as New clip makes it.
	String name = app.unused_clip_name(mem, wanted);
	defer name.free(mem);

	// A named gait finds its own feet; Custom, or a typed foot offset, says where each one lands.
	float[GAIT_FEET_MAX] landing;
	bool offsets_typed;
	if (!gait_read_offsets(ui, landing[:GAIT_FEET_MAX], &offsets_typed))
	{
		app.@notice("A foot offset is a phase of the cycle, 0 to 1.");
		return;
	}
	GaitFootRequest[GAIT_FEET_MAX] named;
	usz named_count;
	if (gait_draft.kind == CUSTOM || offsets_typed)
	{
		for (usz i = 0; i < gait_draft.count; i++)
		{
			named[i] = { .joint = gait_draft.rows[i].name(), .has_offset = true, .offset = landing[i] };
		}
		named_count = gait_draft.count;
	}

	DString detail = dstring::new(mem);
	defer detail.free();
	GaitAuthored? authored = app.author_gait(name, spec, (double)lift, named[:named_count], &detail);
	if (catch authored)
	{
		app.@notice("Gait: %s", detail.str_view());
		return;
	}
	GaitAuthored result = authored;
	defer result.free(mem);

	app.show_edited();
	gait_cancelled(ui);
	AnimTemplate* stored = app.clip(result.landed);
	app.@notice("%s: %.2f units/s, slide %.4f — play it in place or use it as root motion",
		stored ? stored.name : name, result.report.speed, app.clip_foot_slide(result.landed));
}

// ---- the footfall diagram ---------------------------------------------------

struct GaitDiagram (Widget)
{
	sz dragging;
	bool armed;
}

fn float GaitDiagram.track_w(&self, Element* elem) => math::max(elem.size.x - GAIT_LABEL_W - GAIT_VALUE_W, 1.0f);

fn Vec2 GaitDiagram.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	return constraints.constrain({ GAIT_W, (float)gait_draft.count * GAIT_ROW_H + GAIT_AXIS_H });
}

fn void GaitDiagram.paint(&self, Element* elem, Painter* painter) @dynamic
{
	float x0 = GAIT_LABEL_W;
	float w = self.track_w(elem);
	float duty = gait_shown_duty();
	bool custom = gait_draft.kind == CUSTOM;
	for (usz i = 0; i < gait_draft.count; i++)
	{
		GaitRow* row = &gait_draft.rows[i];
		float y = (float)i * GAIT_ROW_H;
		painter.text({ 0, y + 2.0f }, row.name(), { .size = GAIT_TEXT, .color = TEXT });
		painter.rect({ x0, y + 3.0f }, { w, GAIT_ROW_H - 6.0f }, { .color = BTN, .border_radius = { 3, 3, 3, 3 } });

		float start = row.offset;
		float end = start + duty;
		Color ink = custom ? ACCENT : CONTACT_BAR;
		float first = math::min(end, 1.0f);
		painter.rect({ x0 + start * w, y + 3.0f }, { math::max((first - start) * w, 1.0f), GAIT_ROW_H - 6.0f },
			{ .color = ink, .border_radius = { 3, 3, 3, 3 } });
		// Stance wraps through the loop point: the rest starts at the left edge.
		if (end > 1.0f)
		{
			painter.rect({ x0, y + 3.0f }, { math::max((end - 1.0f) * w, 1.0f), GAIT_ROW_H - 6.0f },
				{ .color = ink, .border_radius = { 3, 3, 3, 3 } });
		}
		painter.text({ x0 + w + 6.0f, y + 2.0f }, string::tformat("%.2f", row.offset), { .size = 12.0f, .color = TEXT_DIM });
	}
	float axis = (float)gait_draft.count * GAIT_ROW_H;
	for (usz t = 0; t <= 4; t++)
	{
		float x = x0 + w * (float)t * 0.25f;
		painter.line({ x, 0 }, { x, axis }, 1.0f, { PANEL_BORDER.r, PANEL_BORDER.g, PANEL_BORDER.b, 0.6f });
		painter.text({ x - 6.0f, axis + 1.0f }, string::tformat("%.2g", (float)t * 0.25f), { .size = 11.0f, .color = TEXT_DIM });
	}
}

fn void GaitDiagram.on_hover(&self, Element* elem, bool entered) @dynamic
{
	if (gait_draft.kind == CUSTOM && entered) elem.set_cursor(Cursor.RESIZE_H);
}

<*
 Custom only: a press on a row takes that foot's landing at the pointer, a drag
 keeps taking it, the release ends it. The other gaits are a pattern, not a thing
 to drag, so they decline the press.
*>
fn bool GaitDiagram.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	if (gait_draft.kind != CUSTOM) return false;
	float phase = math::clamp((event.pos.x - GAIT_LABEL_W) / self.track_w(elem), 0.0f, 1.0f);
	switch (event.kind)
	{
		case PRESS:
			if (event.button != MouseButton.LEFT || event.pos.y < 0.0f) return false;
			usz row = (usz)(event.pos.y / GAIT_ROW_H);
			if (row >= gait_draft.count) return false;
			self.dragging = (sz)row;
			self.armed = true;
			gait_set_offset(row, phase);
			gait_sync_offset_fields(elem.ui);
			elem.request_paint();
			return true;
		case MOVE:
			if (!self.armed) return false;
			gait_set_offset((usz)self.dragging, phase);
			gait_sync_offset_fields(elem.ui);
			elem.request_paint();
			return true;
		case RELEASE:
			if (!self.armed) return false;
			self.armed = false;
			return true;
		default:
			return false;
	}
}
