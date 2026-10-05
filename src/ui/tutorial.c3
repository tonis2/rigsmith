<*
 The guided tour: a welcome dialog on the first run, then a card of text per
 step with the interface it is talking about lit up.

 Three small pieces, deliberately plain:

 - `TUTORIAL_STEPS`, a const table. A step is a title, a paragraph and up to two
   widget ids to highlight. Editing the tour is editing that table.
 - `TutorialOverlay`, a click-through widget covering the window. It dims
   everything except the highlighted rectangles and rings them, and it puts the
   card beside the first one. It looks the ids up with `Ui.find_id` on every
   frame that happens, so a resized window or a moved divider follows for free.
 - The card, an ordinary non-modal `Dialog` whose body is rebuilt on each step.

 **A step whose target is not on screen still works.** `find_id` only sees what
 is mounted — a closed menu, a pane tabbed away, a dialog that is shut — and a
 tour that crashed or froze over that would be worse than one that merely cannot
 point. The step then shows its card centred with nothing lit, and its text says
 where to look. Steps are written against widgets that are always mounted (menu
 titles, the viewport's tool column, the timeline) for the same reason.

 **Click-through on purpose.** The dim does not take the pointer, so a user can
 try the thing being pointed at before pressing Next.
*>
module crig;

import cui;
import cui::widgets;

import std::io;
import std::math;

const String TUTORIAL_DIALOG_ID = "tutorial-card";
const String TUTORIAL_OVERLAY_ID = "tutorial-overlay";
const String TUTORIAL_MODEL = "assets/animations/humanoid.glb";
const String WELCOME_DIALOG_ID = "welcome-dialog";

const float TUTORIAL_CARD_W = 340.0;
// Where the overlay assumes the card ends, to choose a side before the card has
// been laid out. The dialog clamps whatever it is given onto the screen, so an
// estimate that is a little off costs a few pixels, not a clipped card.
const float TUTORIAL_CARD_H = 190.0;
const float TUTORIAL_GAP = 12.0;
const float TUTORIAL_HOLE_PAD = 4.0;
const float TUTORIAL_TEXT_SIZE = 13.0;
const float TUTORIAL_TITLE_SIZE = 16.0;
const Color TUTORIAL_DIM = { 0.0, 0.0, 0.0, 0.50 };

struct TutorialStep
{
	String title;
	String body;
	// Widget ids to light; an empty string is unused.
	String[2] targets;
}

const TutorialStep[*] TUTORIAL_STEPS = {
	{
		.title = "The 3D view",
		.body = "Your model lives here. Drag to orbit, shift-drag or middle-drag to pan, and scroll to zoom. Click a joint dot to select it.",
		.targets = { "viewport", "" },
	},
	{
		.title = "Menus",
		.body = "File opens and saves models. Rig fits a body plan to a mesh and edits the skeleton. View switches panels on and off. Help has the full list of controls.",
		.targets = { "menubar", "" },
	},
	{
		.title = "Fit a skeleton",
		.body = "Open a mesh from File, then choose Rig > Apply body plan to fit a humanoid or quadruped skeleton to it in one step. It is a single undo.",
		.targets = { "Rig", "" },
	},
	{
		.title = "Tools",
		.body = "These tools edit the rig: bond joints into chains, lasso-select, mark the area a joint moves, paint weights. Hover one for what it does.",
		.targets = { "tools", "" },
	},
	{
		.title = "Joints or Pose",
		.body = "Joints is for building the rig: dragging a dot moves the joint. Pose is for posing it: dragging bends the body around the joint instead.",
		.targets = { "stage-switch", "" },
	},
	{
		.title = "How the model is drawn",
		.body = "Switch between wireframe, solid and textured here. The tints button next to it colours the mesh by bone weight.",
		.targets = { "shading", "tints" },
	},
	{
		.title = "Animation",
		.body = "Play, step and loop a clip here. Auto-key records a key whenever you pose a joint. Use the clip list to pick a clip, make a new one, or bind one from a library.",
		.targets = { "anim-transport-play", "anim-autokey" },
	},
	{
		.title = "Generate motion",
		.body = "The Generate panel writes a clip from a text prompt using Kimodo. Download its model files first and point Settings > AI at them. View > Generate motion opens it.",
		.targets = { "generate-panel", "" },
	},
	{
		.title = "That's the tour",
		.body = "Save writes the rig and its clips back into the .glb. Help > Tutorial plays this again, and Help > Controls lists every shortcut.",
		.targets = { "", "" },
	},
};

// ---------------------------------------------------------------------------
// Running it

fn void tutorial_start(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	app.tutorial_active = true;
	app.tutorial_step = 0;
	// The tool column and most of what the tour points at only exist with a
	// model open, so a tour begun on an empty view loads the shipped humanoid.
	if (!app.has_mesh() && file::is_file(TUTORIAL_MODEL)) app.request_open(TUTORIAL_MODEL);
	// Raised like the overlay, so that it paints after it: both are raised, and
	// raised elements keep tree order among themselves (the overlay comes first).
	// Left unraised, the dim lands on top of the card and greys its text.
	if (try Element* card = ui.find_id(TUTORIAL_DIALOG_ID)) card.raised = true;
	tutorial_refresh(ui);
	set_dialog_open(ui, TUTORIAL_DIALOG_ID, true);
	ui.request_frame();
}

fn void tutorial_end(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (!app.tutorial_active) return;
	app.tutorial_active = false;
	set_dialog_open(ui, TUTORIAL_DIALOG_ID, false);
	if (try Element* overlay = ui.find_id(TUTORIAL_OVERLAY_ID)) overlay.request_paint();
	ui.request_frame();
}

// The dialog's own close (the X, or Escape) is the same as Skip.
fn void tutorial_card_closed(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (!app.tutorial_active) return;
	app.tutorial_active = false;
	if (try Element* overlay = ui.find_id(TUTORIAL_OVERLAY_ID)) overlay.request_paint();
}

<*
 Moves one step, ending the tour past the last. Clamped at the first.
*>
fn void tutorial_go(Ui* ui, int delta)
{
	AppState* app = ui.inherit(AppState)!!;
	if (!app.tutorial_active) return;
	int next = (int)app.tutorial_step + delta;
	if (next < 0) next = 0;
	if (next >= (int)TUTORIAL_STEPS.len)
	{
		tutorial_end(ui);
		return;
	}
	app.tutorial_step = (usz)next;
	tutorial_refresh(ui);
}

fn void tutorial_next(Ui* ui) => tutorial_go(ui, 1);
fn void tutorial_back(Ui* ui) => tutorial_go(ui, -1);
fn void tutorial_skip(Ui* ui) => tutorial_end(ui);

// A new step: the card's text is rebuilt, and the overlay re-places it.
fn void tutorial_refresh(Ui* ui)
{
	if (try Element* card = ui.find_id(TUTORIAL_DIALOG_ID))
	{
		card.widget_as(Dialog).placed = false;
		card.request_build();
	}
	if (try Element* overlay = ui.find_id(TUTORIAL_OVERLAY_ID))
	{
		overlay.widget_as(TutorialOverlay).placed_for = (usz)-1;
		overlay.request_paint();
	}
	ui.request_frame();
}

// Help > Tutorial.
fn void menu_start_tutorial(Ui* ui)
{
	close_menus(ui);
	tutorial_start(ui);
}

// ---------------------------------------------------------------------------
// The card

char[24] tutorial_counter_buffer;

fn Element* build_tutorial_body(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	usz index = math::min(app.tutorial_step, (usz)TUTORIAL_STEPS.len - 1);
	TutorialStep step = TUTORIAL_STEPS[index];
	bool last = index + 1 == TUTORIAL_STEPS.len;

	String counter = (String)io::bprintf(tutorial_counter_buffer[..], "Step %d of %d", index + 1, TUTORIAL_STEPS.len) ?? "";

	return @subtree(ui)
	{
		@tree((Column) { .size = { TUTORIAL_CARD_W, 0 }, .gap = 8 })
		{
			@node((Label) { .text = counter, .size = TUTORIAL_TEXT_SIZE, .color = TEXT_DIM });
			@node((Label) { .text = step.title, .size = TUTORIAL_TITLE_SIZE, .color = TEXT });
			@node((Label) { .text = step.body, .size = TUTORIAL_TEXT_SIZE, .color = TEXT,
				.overflow = TextOverflow.WRAP });
			@tree((Row) { .gap = 8 })
			{
				if (index > 0) @node(panel_button("Back", &tutorial_back));
				@node(accent_button(last ? "Done" : "Next", &tutorial_next));
				if (!last) @node(panel_button("Skip", &tutorial_skip));
			};
		};
	};
}

// ---------------------------------------------------------------------------
// The overlay

struct TutorialOverlay (Widget)
{
	// The step the card was last placed for, and the rectangle it was placed
	// against, so it moves when either changes and not every frame — a card the
	// user dragged elsewhere stays where they put it.
	usz placed_for;
	Vec2[2] hole_pos;
	Vec2[2] hole_size;
	usz holes;
	Vec2 window;
	bool dimmed;
}

fn void TutorialOverlay.mount(&self, Element* elem) @dynamic
{
	elem.ignores_pointer = true;
	self.placed_for = (usz)-1;
}

fn Vec2 TutorialOverlay.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	elem.raised = true;
	return constraints.max;
}

fn void TutorialOverlay.update(&self, Element* elem, float dt) @dynamic
{
	Ui* ui = elem.ui;
	AppState* app = elem.inherit(AppState)!!;
	if (!app.tutorial_active)
	{
		if (self.dimmed)
		{
			self.dimmed = false;
			self.holes = 0;
			elem.request_paint();
		}
		return;
	}

	usz index = math::min(app.tutorial_step, (usz)TUTORIAL_STEPS.len - 1);
	Vec2[2] pos;
	Vec2[2] size;
	usz holes = 0;
	foreach (id : TUTORIAL_STEPS[index].targets)
	{
		if (id.len == 0) continue;
		Element*? found = ui.find_id(id);
		if (catch found) continue;
		if (found.size.x <= 0 || found.size.y <= 0) continue;
		pos[holes] = found.absolute - elem.absolute - (Vec2){ TUTORIAL_HOLE_PAD, TUTORIAL_HOLE_PAD };
		size[holes] = found.size + (Vec2){ 2 * TUTORIAL_HOLE_PAD, 2 * TUTORIAL_HOLE_PAD };
		holes++;
	}

	bool moved = !self.dimmed || holes != self.holes || elem.size != self.window;
	for (usz i = 0; i < holes && !moved; i++)
	{
		moved = pos[i] != self.hole_pos[i] || size[i] != self.hole_size[i];
	}
	if (moved)
	{
		self.dimmed = true;
		self.holes = holes;
		self.hole_pos = pos;
		self.hole_size = size;
		self.window = elem.size;
		elem.request_paint();
	}

	if (self.placed_for != index || moved) self.place_card(elem, index);
}

// Beside the first lit rectangle: right, left, below, above, whichever fits.
// None fitting (a target that fills the window) parks it in the top-left corner of that target, and no
// target at all leaves it centred.
fn void TutorialOverlay.place_card(&self, Element* elem, usz index)
{
	Element*? card = elem.ui.find_id(TUTORIAL_DIALOG_ID);
	if (catch card) return;
	Dialog* dialog = card.widget_as(Dialog);
	if (!dialog.open) return;

	// Only the first placement for a step is ours; after that the card belongs
	// to the user, who may have dragged it out of the way of what they are doing.
	bool first = self.placed_for != index;
	self.placed_for = index;
	if (!first) return;

	if (self.holes == 0)
	{
		dialog.placed = false;
		card.request_layout();
		return;
	}

	Vec2 p = self.hole_pos[0] + elem.absolute;
	Vec2 s = self.hole_size[0];
	Vec2 w = elem.size;
	Vec2 c = { TUTORIAL_CARD_W + 32, TUTORIAL_CARD_H };
	Vec2[4] tries = {
		{ p.x + s.x + TUTORIAL_GAP, p.y },
		{ p.x - c.x - TUTORIAL_GAP, p.y },
		{ p.x, p.y + s.y + TUTORIAL_GAP },
		{ p.x, p.y - c.y - TUTORIAL_GAP },
	};
	// Top-left: a target that fills the window is the 3D view, which sits there.
	Vec2 chosen = { p.x + TUTORIAL_GAP * 4, p.y + TUTORIAL_GAP * 5 };
	// A pane-sized target (the 3D view) has no margin worth the name: the card
	// goes inside it, top-left, rather than in whatever sliver is beside it.
	bool large = s.x > w.x * 0.4 || s.y > w.y * 0.4;
	foreach (t : tries)
	{
		if (large) break;
		if (t.x >= 0 && t.y >= 0 && t.x + c.x <= w.x && t.y + c.y <= w.y)
		{
			chosen = t;
			break;
		}
	}
	dialog.at = chosen;
	dialog.placed = true;
	card.request_layout();
}

fn void TutorialOverlay.paint(&self, Element* elem, Painter* painter) @dynamic
{
	if (!self.dimmed) return;
	Vec2 w = elem.size;
	RectStyle dim = { .color = TUTORIAL_DIM };

	if (self.holes == 0)
	{
		painter.rect({ 0, 0 }, w, dim);
		return;
	}

	// The dim is the window minus the holes, as horizontal bands: split at every
	// hole's top and bottom, and in each band fill what the holes there leave.
	float[6] ys;
	usz n = 0;
	ys[n++] = 0;
	ys[n++] = w.y;
	for (usz i = 0; i < self.holes; i++)
	{
		ys[n++] = math::clamp(self.hole_pos[i].y, 0.0f, w.y);
		ys[n++] = math::clamp(self.hole_pos[i].y + self.hole_size[i].y, 0.0f, w.y);
	}
	for (usz i = 1; i < n; i++)
	{
		float v = ys[i];
		usz j = i;
		while (j > 0 && ys[j - 1] > v)
		{
			ys[j] = ys[j - 1];
			j--;
		}
		ys[j] = v;
	}
	for (usz b = 0; b + 1 < n; b++)
	{
		float y0 = ys[b];
		float y1 = ys[b + 1];
		if (y1 - y0 < 0.5f) continue;
		float mid = (y0 + y1) * 0.5f;
		// The holes covering this band, left to right.
		usz[2] order;
		usz count = 0;
		for (usz i = 0; i < self.holes; i++)
		{
			if (mid < self.hole_pos[i].y || mid > self.hole_pos[i].y + self.hole_size[i].y) continue;
			usz at = count++;
			while (at > 0 && self.hole_pos[order[at - 1]].x > self.hole_pos[i].x)
			{
				order[at] = order[at - 1];
				at--;
			}
			order[at] = i;
		}
		float x = 0;
		for (usz k = 0; k < count; k++)
		{
			usz i = order[k];
			float x0 = math::clamp(self.hole_pos[i].x, 0.0f, w.x);
			float x1 = math::clamp(self.hole_pos[i].x + self.hole_size[i].x, 0.0f, w.x);
			if (x0 > x) painter.rect({ x, y0 }, { x0 - x, y1 - y0 }, dim);
			if (x1 > x) x = x1;
		}
		if (x < w.x) painter.rect({ x, y0 }, { w.x - x, y1 - y0 }, dim);
	}

	for (usz i = 0; i < self.holes; i++)
	{
		painter.rect(self.hole_pos[i], self.hole_size[i],
			{ .border_color = ACCENT, .border_width = 2.0f, .border_radius = { 6, 6, 6, 6 } });
	}
}

// ---------------------------------------------------------------------------
// The welcome dialog

const float WELCOME_W = 380.0;

const String WELCOME_LEAD = "Rigsmith rigs a mesh, poses it and animates it, then exports a .glb.";
const String WELCOME_HELP = "A two-minute tour shows where things are. You can run it again any time from Help > Tutorial.";

fn Element* build_welcome_body(Ui* ui)
{
	return @subtree(ui)
	{
		@tree((Column) { .size = { WELCOME_W, 0 }, .gap = 10 })
		{
			@node((Label) { .text = WELCOME_LEAD, .size = FILE_HEADING_SIZE, .color = TEXT,
				.overflow = TextOverflow.WRAP });
			@node((Label) { .text = WELCOME_HELP, .size = FILE_HEADING_SIZE, .color = TEXT_DIM,
				.overflow = TextOverflow.WRAP });
			@tree((Row) { .gap = 10 })
			{
				@node(accent_button("Start tutorial", &welcome_start));
				@node(panel_button("Skip", &welcome_skip));
			};
		};
	};
}

// Any way out of the dialog answers it: the buttons, the X and Escape all land
// here, so the offer is never repeated once it has been seen.
fn void welcome_closed(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (app.config.tutorial_seen) return;
	app.config.tutorial_seen = true;
	app.config.save();
}

fn void welcome_start(Ui* ui)
{
	set_dialog_open(ui, WELCOME_DIALOG_ID, false);
	tutorial_start(ui);
}

fn void welcome_skip(Ui* ui) => set_dialog_open(ui, WELCOME_DIALOG_ID, false);

<*
 The first-run offer. Called each frame from `AppRoot.update`; acts once.

 Only with a config directory: a session that cannot remember the answer would
 ask every launch, and the test fixtures, which have none, would open a dialog
 over every UI they build.
*>
fn void tutorial_offer_welcome(Ui* ui, AppState* app)
{
	if (app.welcome_checked) return;
	app.welcome_checked = true;
	if (app.config.tutorial_seen || app.config.directory.len == 0) return;
	set_dialog_open(ui, WELCOME_DIALOG_ID, true);
}
