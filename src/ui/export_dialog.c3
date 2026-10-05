<*
 Choosing what goes into an exported .glb: the rig, which clips, and where it is
 written.

 	File > Export .glb  (Ctrl+E)

 **There is no picker here any more, and that is the point.** This panel used to
 hold a second grid of every animation in every library, with its own search and
 its own ticks — so the set of clips a character had came into existence inside
 the export dialog and died with the next `load_mesh`. "Which animations does my
 character have" was a question with no answer except during an export.

 The answer is now the character's own: clips are bound in the Assets pane, live
 in the document, survive a restart, and are listed in the Animations view. This
 panel *reports* that set and writes it. What is left to decide here is genuinely
 about the export and nothing else — whether the model goes with the clips, and
 where the file lands.

 **The answers live on the AppState, not in this subtree.** `Dialog.body` is
 rebuilt on every opening and released on every close, so anything that has to
 survive closing the panel to fetch a destination belongs on `export_with_rig` —
 the same rule the workspace's views follow.

 A bound clip whose file has gone missing is counted and named in the summary
 rather than silently skipped: the writer takes what it can find, and the line
 above the button is where the user finds out that it found eleven of twelve.
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

// The path field, sized so Browse fits beside it on one row rather than being
// pushed onto its own.
const float EXPORT_FIELD_W = 440.0;

const String EXPORT_DIALOG_ID = "export-dialog";
const String EXPORT_PATH_ID = "export-path";
const String EXPORT_SUMMARY_ID = "export-summary";
const String EXPORT_CONFIRM_ID = "export-confirm";

const float EXPORT_TEXT_SIZE = 13.0;

// A template rig is a complete export; animations are optional.
const String EXPORT_NONE_BOUND =
	"No animations on this character — export the rig alone (animations are optional)";

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
			// What is going in, as a sentence rather than as a grid to work
			// through. The set was chosen elsewhere and this is the receipt.
			@node((ExportSummary) { }).with_id(EXPORT_SUMMARY_ID);

			@node((Checkbox) {
				.label = "Export rig — the model with its skeleton. Off writes the clips alone.",
				.checked = app.export_with_rig,
				.on_change = &export_rig_toggled,
				.style = CHECKBOX_STYLE,
			});

			// Root motion and key reduction are chosen in the Animations panel, where
			// the viewport shows them; this panel only writes what they say.
			@node((Label) { .text = "Write to", .size = EXPORT_TEXT_SIZE, .color = TEXT_DIM });

			@tree((Row) { .gap = EXPORT_GAP })
			{
				@node((TextField) {
					.placeholder = "path",
					.style = TEXT_FIELD_STYLE,
					.width = EXPORT_FIELD_W,
				}).with_id(EXPORT_PATH_ID);

				@node(panel_button("Browse", &export_browse));
			};

			// A tree rather than the one-line form, so the confirming button can
			// carry an id: it is the only control here that writes a file, and a
			// check driving the panel has to be able to find it.
			@tree((Row) { .gap = EXPORT_GAP, .main_align = END })
			{
				@node(panel_button("Cancel", &export_cancelled));
				@node(accent_button("Export", &export_confirmed)).with_id(EXPORT_CONFIRM_ID);
			};
		};
	};

	// Through the subtree, not the Ui: `Dialog.build` has not attached any of
	// this yet, so the tree-wide lookup cannot see it.
	//
	// The derived path is what everyone who does not care where it goes gets;
	// Browse and typing are for everyone else.
	//
	// With no source path there is nothing to derive from, and the field is left
	// on its placeholder rather than on an empty string that looks like an
	// answer. Not `?:` with a literal either: freeing one is freeing static data.
	if (app.source_path.len > 0)
	{
		if (try Element* field = body.find_id(EXPORT_PATH_ID))
		{
			String derived = rigged_path(mem, app.source_path);
			defer derived.free(mem);
			field.widget_as(TextField).set_text(field, derived);
		}
	}

	return body;
}

<*
 The one line that replaced the picker: what this export is about to write.

 A widget rather than a `Label` because the sentence is formatted from the
 document and has to be owned by something — a `Label` borrows its text for the
 life of the element, and a temporary would be released before the panel painted.

 Resolving every binding is what `bound_counts` does, and it is the reason this
 is built on open rather than measured on every paint: it can read files off
 disk. The panel is modal, so nothing can change the answer while it is up.
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

	// Every branch writes into the scratch, including the literal one: paint reads
	// the buffer back, so a branch that only pointed at static text would paint
	// whatever the last format left there.
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
		// The gap said out loud. A silent skip here would write a model missing
		// clips the user believes are on it, and the export reports success.
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
		// Amber when something is missing: the count is the news, and a dim line
		// saying eleven of twelve reads the same as one saying twelve.
		.color = total > 0 && found < total ? ACCENT : TEXT_DIM,
	});
}

<*
 Open the export panel.

 Nothing to prepare any more: the set being exported is the document's, and the
 summary resolves it during layout. There used to be a row list rebuilt here,
 borrowed from the asset index and the packs.
*>
fn void open_export_dialog(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	// Do not carry a previous animation-only export into a template document:
	// without bindings the rig is the only meaningful thing to write.
	if (app.doc.animations.len() == 0) app.export_with_rig = true;
	set_dialog_open(ui, EXPORT_DIALOG_ID, true);
}

<*
 Put a chosen destination into the panel's field.

 What the file browser calls back into when it was opened from **Browse** — the
 export panel stays up behind the chooser, so the field is still in the tree.
*>
fn void set_export_path(Ui* ui, String path)
{
	if (try Element* field = ui.find_id(EXPORT_PATH_ID))
	{
		field.widget_as(TextField).set_text(field, path);
	}
}

fn void export_rig_toggled(Ui* ui, bool checked) @private
{
	ui.inherit(AppState)!!.export_with_rig = checked;
}

fn void export_browse(Ui* ui) @private
{
	open_file_dialog(ui, FilePurpose.EXPORT_TARGET);
}

fn void export_cancelled(Ui* ui) @private
{
	set_dialog_open(ui, EXPORT_DIALOG_ID, false);
}

<*
 Write the file: the rig if it is ticked, and whichever clips are.

 The destination is copied before the panel closes — the field is inside the
 subtree that closing releases, and the string is a view into its buffer.
*>
fn void export_confirmed(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;

	String typed = field_text(ui, EXPORT_PATH_ID);

	String destination = typed.copy(mem);
	defer destination.free(mem);

	AnimTemplate[] clips = app.bound_templates(mem);
	defer if (clips.len > 0) alloc::free(mem, clips);

	bool with_rig = app.export_with_rig;

	set_dialog_open(ui, EXPORT_DIALOG_ID, false);

	if (with_rig)
	{
		app.export_rig(destination, clips);
	}
	else
	{
		app.export_clips_only(destination, clips);
	}
	app.refresh_ui();
}
