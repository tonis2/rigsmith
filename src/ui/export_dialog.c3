<*
 The Export panel: what goes in the file (the character, all characters or a
 cutscene), a line saying what that is, and where it is written.

 	File > Export .glb…  (Ctrl+E)

 The answers live on the AppState (`export_what`, `export_with_rig`), since the
 body is released whenever the panel closes, Browse included.
*>
module crig;

import cui;
import cui::widgets;
import std::io;
import std::math;
import std::math::vector;
import std::core::string;

const float EXPORT_DIALOG_W = 560.0;
const float EXPORT_GAP = 10.0;

// The path field, sized so Browse fits beside it on one row.
const float EXPORT_FIELD_W = 440.0;
const float EXPORT_PICK_W = 260.0;

const String EXPORT_DIALOG_ID = "export-dialog";
const String EXPORT_WHAT_ID = "export-what";
const String EXPORT_CHOICE_ID = "export-choice";
const String EXPORT_CUTSCENE_ID = "export-cutscene";
const String EXPORT_LINE_ID = "export-line";
const String EXPORT_PATH_ID = "export-path";
const String EXPORT_BROWSE_ID = "export-browse";
const String EXPORT_SUMMARY_ID = "export-summary";
const String EXPORT_CONFIRM_ID = "export-confirm";

const float EXPORT_TEXT_SIZE = 13.0;

// A template rig is a complete export; animations are optional.
const String EXPORT_NONE_BOUND =
	"No animations on this character — export the rig alone (animations are optional)";

// In ExportWhat's order.
String[3] export_what_options = { "Character", "All characters", "Cutscene" };

<*
 Build the export panel as a detached subtree — the shape `Dialog.body` takes.
*>
fn Element* build_export_dialog_body(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;

	Element* body = @subtree(ui)
	{
		@tree((Column) { .size = { EXPORT_DIALOG_W, 0 }, .gap = EXPORT_GAP })
		{
			@tree(widgets::tip("What goes in the file: the character in focus, every character, or a cutscene for the game"))
			{
				@node((Segmented) { .options = export_what_options[..], .selected = (sz)app.export_what.ordinal,
					.on_change = &export_what_chosen, .style = SEGMENTED_STYLE }).with_id(EXPORT_WHAT_ID);
			};

			@node((ExportChoice) { }).with_id(EXPORT_CHOICE_ID);

			@node((Label) { .text = "Write to", .size = EXPORT_TEXT_SIZE, .color = TEXT_DIM });

			@tree((Row) { .gap = EXPORT_GAP })
			{
				@node((TextField) {
					.placeholder = "path",
					.style = TEXT_FIELD_STYLE,
					.width = EXPORT_FIELD_W,
				}).with_id(EXPORT_PATH_ID);

				@node(panel_button("Browse", &export_browse)).with_id(EXPORT_BROWSE_ID);
			};

			// A tree rather than the one-line form, so the confirming button can carry an id.
			@tree((Row) { .gap = EXPORT_GAP, .main_align = END })
			{
				@node(panel_button("Cancel", &export_cancelled));
				@node(accent_button("Export", &export_confirmed)).with_id(EXPORT_CONFIRM_ID);
			};
		};
	};

	// Through the subtree: `Dialog.build` has not attached it yet. With nothing to
	// name the file from, the field keeps its placeholder.
	String suggested = export_default_path(app, app.export_what);
	if (suggested.len > 0)
	{
		if (try Element* field = body.find_id(EXPORT_PATH_ID))
		{
			field.widget_as(TextField).set_text(field, suggested);
		}
	}

	return body;
}

// What decides the choice's body; compared each frame.
struct ExportShape
{
	ExportWhat what;
	usz cutscenes;
	usz active;
	uint revision;
}

fn ExportShape export_shape(AppState* app) @private
{
	return { .what = app.export_what, .cutscenes = (usz)app.cutscenes.len(), .active = app.cut_active, .revision = app.cut_revision };
}

<* The part of the panel under the choice, rebuilt when the choice or the cutscene changes. *>
struct ExportChoice (Widget)
{
	ExportShape shown;
	String[] names; // the cutscene picker's options, owned
	char[192] line; // the summary, held for its label to borrow
}

fn void ExportChoice.release(&self)
{
	free_names(mem, self.names);
	self.names = {};
}

fn void ExportChoice.unmount(&self, Element* elem) @dynamic => self.release();

fn void ExportChoice.update(&self, Element* elem, float dt) @dynamic
{
	ExportShape now = export_shape(elem.inherit(AppState)!!);
	if (!fields_differ(now, self.shown)) return;
	elem.request_build();
}

fn Vec2 ExportChoice.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	if (elem.children.len() == 0) return constraints.constrain({ 0, 0 });
	float width = math::min(EXPORT_DIALOG_W, constraints.max.x);
	Vec2 inner = elem.layout_child(0, cui::loose({ width, constraints.max.y }));
	elem.place_child(0, { 0, 0 });
	return constraints.constrain({ width, inner.y });
}

fn Element* ExportChoice.build(&self, Element* elem) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	self.shown = export_shape(app);
	self.release();
	String line;
	bool warn;
	switch (app.export_what)
	{
		case CHARACTER:
			break;
		case ALL_CHARACTERS:
			usz models;
			usz rigged;
			app.export_cast_counts(&models, &rigged);
			line = string::bformat(self.line[..], "%d character%s · %d rigged", models, models == 1 ? "" : "s", rigged);
			// Amber when one is left out: the scene export skips a character with no rig.
			warn = rigged < models;
		case CUTSCENE:
			if (Cutscene* cutscene = app.cutscene())
			{
				String[] problems = app.cutscene_problem_texts(mem);
				defer free_names(mem, problems);
				usz actors = cutscene.actors.len;
				String noted = problems.len == 0 ? "" : string::tformat(" · %d problem%s", problems.len, problems.len == 1 ? "" : "s");
				line = string::bformat(self.line[..], "%s · %d actor%s · %.1f s%s", cutscene.name, actors,
					actors == 1 ? "" : "s", cutscene.duration, noted);
				warn = problems.len > 0;
			}
			if (app.cutscenes.len() > 1)
			{
				self.names = alloc::new_array(mem, String, app.cutscenes.len());
				foreach (usz i, &c : app.cutscenes) self.names[i] = c.name.copy(mem);
			}
	}

	return @subtree(elem.ui)
	{
		@tree((Column) { .gap = EXPORT_GAP })
		{
			if (app.export_what == CHARACTER)
			{
				// What is going in, as a sentence: the clips were chosen in the Assets pane.
				@node((ExportSummary) { }).with_id(EXPORT_SUMMARY_ID);
				@node((Checkbox) {
					.label = "Export rig — the model with its skeleton. Off writes the clips alone.",
					.checked = app.export_with_rig,
					.on_change = &export_rig_toggled,
					.style = CHECKBOX_STYLE,
				});
			}
			else
			{
				if (self.names.len > 0)
				{
					@tree(widgets::tip("Which cutscene to write"))
					{
						@node((Select) { .options = self.names, .selected = app.cut_active, .width = EXPORT_PICK_W,
							.style = VIEW_MENU_STYLE, .on_change = &export_cutscene_chosen }).with_id(EXPORT_CUTSCENE_ID);
					};
				}
				@node((Label) { .text = line, .size = EXPORT_TEXT_SIZE, .color = warn ? ACCENT : TEXT_DIM }).with_id(EXPORT_LINE_ID);
			}
		};
	};
}

<*
 The one line that replaced the picker: what this export is about to write.

 A widget rather than a `Label` because the sentence is formatted from the
 document and has to be owned by something. Built on open rather than measured
 on every paint, since `bound_counts` can read files off disk.
*>
struct ExportSummary (Widget)
{
	Vec2 measured;
	char[192] scratch;
	usz len;
}

fn Vec2 ExportSummary.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;

	usz total;
	usz found;
	app.bound_counts(&total, &found);

	// Every branch writes into the scratch, since paint reads the buffer back.
	String line;
	if (total == 0)
	{
		line = string::bformat(self.scratch[..], "%s", EXPORT_NONE_BOUND);
	}
	else if (found == total)
	{
		line = string::bformat(self.scratch[..], "%d animation%s on this character",
			total, total == 1 ? "" : "s");
	}
	else
	{
		// Said out loud: a silent skip would write a model missing clips the user believes are on it.
		line = string::bformat(self.scratch[..],
			"%d of %d animations found — %d missing from your libraries",
			found, total, total - found);
	}
	self.len = line.len;

	self.measured = elem.ui.text.measure(0, line, EXPORT_TEXT_SIZE);
	return constraints.constrain(self.measured);
}

fn void ExportSummary.paint(&self, Element* elem, Painter* painter) @dynamic
{
	if (self.len == 0) return;

	usz total;
	usz found;
	elem.inherit(AppState)!!.bound_counts(&total, &found);

	painter.text({ 0, 0 }, (String)self.scratch[:self.len], {
		.size = EXPORT_TEXT_SIZE,
		// Amber when something is missing: the count is the news.
		.color = total > 0 && found < total ? ACCENT : TEXT_DIM,
	});
}

<* Open the export panel on the choice that fits the scene: see `default_export_what`. *>
fn void open_export_dialog(Ui* ui)
{
	open_export_for(ui, ui.inherit(AppState)!!.default_export_what());
}

<* Open the export panel on `what`, or on the default when `what` does not apply. *>
fn void open_export_for(Ui* ui, ExportWhat what)
{
	AppState* app = ui.inherit(AppState)!!;
	// Without bindings the rig is the only meaningful thing to write.
	if (app.doc.animations.len() == 0) app.export_with_rig = true;
	app.export_what = app.export_refusal(what).len == 0 ? what : app.default_export_what();
	set_dialog_open(ui, EXPORT_DIALOG_ID, true);
}

<*
 Put a chosen destination into the panel's field: Browse's answer, and the
 suggestion on every switch.
*>
fn void set_export_path(Ui* ui, String path)
{
	if (try Element* field = ui.find_id(EXPORT_PATH_ID))
	{
		field.widget_as(TextField).set_text(field, path);
	}
}

// A choice that does not apply says why and lights the one in force again.
fn void export_what_chosen(Ui* ui, usz index) @private
{
	AppState* app = ui.inherit(AppState)!!;
	if (index >= export_what_options.len) return;
	ExportWhat what = ExportWhat::from_ordinal(index);
	String refused = app.export_refusal(what);
	if (refused.len > 0)
	{
		app.@notice("%s", refused);
		if (try Element* strip = ui.find_id(EXPORT_WHAT_ID))
		{
			strip.widget_as(Segmented).selected = (sz)app.export_what.ordinal;
			strip.request_paint();
		}
		app.refresh_ui();
		return;
	}
	app.export_what = what;
	set_export_path(ui, export_default_path(app, what));
	app.refresh_ui();
}

fn void export_cutscene_chosen(Ui* ui, usz index) @private
{
	AppState* app = ui.inherit(AppState)!!;
	(void)app.select_cutscene(index);
	set_export_path(ui, export_default_path(app, CUTSCENE));
	app.refresh_ui();
}

fn void export_rig_toggled(Ui* ui, bool checked) @private
{
	ui.inherit(AppState)!!.export_with_rig = checked;
}

fn void export_browse(Ui* ui) @private
{
	open_file_dialog(ui, FilePurpose.EXPORT_TARGET);
}

// The chooser's title for Browse, naming what is written.
fn String export_target_title(ExportWhat what)
{
	switch (what)
	{
		case CHARACTER: return "Export the character to";
		case ALL_CHARACTERS: return "Export all characters to";
		case CUTSCENE: return "Export the cutscene to";
	}
}

fn void export_cancelled(Ui* ui) @private
{
	set_dialog_open(ui, EXPORT_DIALOG_ID, false);
}

<*
 Write the file `export_what` names. The destination is copied before the panel
 closes, since the field is inside the subtree that closing releases.
*>
fn void export_confirmed(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	ExportWhat what = app.export_what;

	String typed = field_text(ui, EXPORT_PATH_ID);
	// The character's export derives a path from its file; the others need one.
	if (what != CHARACTER && typed.len == 0)
	{
		app.@notice("type where to write it, or Browse");
		app.refresh_ui();
		return;
	}

	String destination = export_file_name(what, typed).copy(mem);
	defer destination.free(mem);

	set_dialog_open(ui, EXPORT_DIALOG_ID, false);

	switch (what)
	{
		case CHARACTER:
			AnimTemplate[] clips = app.bound_templates(mem);
			defer if (clips.len > 0) alloc::free(mem, clips);
			if (app.export_with_rig)
			{
				app.export_rig(destination, clips);
			}
			else
			{
				app.export_clips_only(destination, clips);
			}
		case ALL_CHARACTERS:
			(void)app.export_scene(destination);
		case CUTSCENE:
			(void)app.export_cutscene(destination);
	}
	app.refresh_ui();
}
