<*
 The recent projects, as rows at the top of the file chooser.

 A project is a scene file, or a model on its own: a model's session lives
 beside the mesh and is found from it, so its path is the one name that reopens
 it. A scene row goes through `AppState.request_open_scene` and a model row
 through `AppState.request_open` — a shortcut to a file, not a second way of
 opening one.

 A widget painting rows rather than a Column of Labels, the same trade `AnimList`
 makes and for the same two reasons: the file name and its folder are one row
 that has to stay aligned across all five, and a hovered row is a rectangle
 behind text rather than a property any Label has. It is not in cui because what
 a row *is* here is a crig config entry, and a widget in cui would need the whole
 list handed to it anyway.

 **A row whose file is gone still shows.** It greys and refuses its click
 instead of vanishing, because a project that quietly disappeared off the list
 is indistinguishable from one that was never on it — and a model that is merely
 on an unmounted disk today is one the user still wants to see named.
*>
module crig;

import cui;
import cui::widgets;
import std::core::string;
import std::io::file;
import std::math;

const float RECENT_ROW_H = 26.0;
const float RECENT_PAD = 8.0;
const float RECENT_TEXT_SIZE = 13.0;
const float RECENT_FOLDER_SIZE = 11.0;

// Between the file name and the folder it sits in. Wide enough that the two
// read as separate columns rather than one run-on line.
const float RECENT_GUTTER = 16.0;

const Vec4 RECENT_ROW_RADII = { 4.0, 4.0, 4.0, 4.0 };

<*
 The rows, over `AppState.config.recent`.

 Holds no list of its own: the config is the list, and a widget with a copy of
 it would go stale the moment a model was opened from underneath the dialog.
*>
struct RecentList (Widget)
{
	// Hovered row + 1; 0 is none. The `AnimList` encoding, so that "no row" is
	// the zero value and needs no separate flag.
	int lit;
}

// Rows come and go with the config, so the count is asked for rather than kept.
fn usz RecentList.count(&self, Element* elem)
{
	AppState* app = elem.inherit(AppState)!!;
	return (usz)app.config.recent.len();
}

<*
 One row per remembered project, and nothing at all when there are none.

 Sizes to the rows rather than filling the space offered, so the dialog is
 shorter on a first run than on a hundredth — an empty panel with a heading over
 it is worse than no panel.
*>
fn Vec2 RecentList.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	float height = (float)self.count(elem) * RECENT_ROW_H;
	return constraints.constrain({ constraints.max.x, height });
}

<*
 Which row is under a point, in element-local pixels, or -1 for none.

 Shared by paint's highlight and by `on_mouse`, so the row that lights and the
 row that opens cannot be different ones.
*>
fn int RecentList.hit_at(&self, Element* elem, Vec2 pos)
{
	usz rows = self.count(elem);
	if (rows == 0 || pos.y < 0) return -1;

	int row = (int)(pos.y / RECENT_ROW_H);
	return row >= 0 && row < (int)rows ? row : -1;
}

// Whether the model this row names is still where it was.
fn bool recent_exists(String path) => file::is_file(path);

fn void RecentList.paint(&self, Element* elem, Painter* painter) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;

	foreach (usz i, held : app.config.recent.array_view())
	{
		float y = (float)i * RECENT_ROW_H;
		bool present = recent_exists(held);
		bool hovered = self.lit == (int)i + 1 && present;

		if (hovered)
		{
			painter.rect({ 0, y }, { elem.size.x, RECENT_ROW_H }, {
				.color = BTN_HOVER, .border_radius = RECENT_ROW_RADII,
			});
		}

		String name = base_name(held);
		Vec2 name_size = elem.ui.text.measure(0, name, RECENT_TEXT_SIZE);
		painter.text(
			{ RECENT_PAD, y + (RECENT_ROW_H - name_size.y) * 0.5f },
			name,
			{ .size = RECENT_TEXT_SIZE, .color = present ? TEXT : TEXT_DIM.dim(0.55) }
		);

		// The folder, right-aligned, and the reason the rows are worth more than
		// five file names: two models called `character.glb` in two projects are
		// told apart by nothing else. Dropped from the left when it will not fit,
		// since the end of a path is the part that identifies it.
		String folder = present ? widgets::parent_of(held) : "missing";
		float room = elem.size.x - RECENT_PAD * 2.0f - name_size.x - RECENT_GUTTER;
		String shown = elide_left(elem, folder, room);
		if (shown.len > 0)
		{
			float w = elem.ui.text.measure(0, shown, RECENT_FOLDER_SIZE).x;
			painter.text(
				{ elem.size.x - RECENT_PAD - w, y + (RECENT_ROW_H - RECENT_FOLDER_SIZE) * 0.5f - 1.0f },
				shown,
				{ .size = RECENT_FOLDER_SIZE, .color = TEXT_DIM.dim(present ? 1.0 : 0.55) }
			);
		}
	}
}

<*
 As much of the tail of `text` as fits in `room`, with a leading ellipsis when
 something was cut. Empty when not even the ellipsis fits.

 The tail rather than the head because these are paths: `/Users/me/work/models`
 and `/Users/me/play/models` differ at the end, and every home directory on the
 machine starts the same way.

 The returned slice is a view into `text` or a temporary — good until the next
 frame, which is all a paint needs.
*>
fn String elide_left(Element* elem, String text, float room)
{
	if (room <= 0 || text.len == 0) return "";
	if (elem.ui.text.measure(0, text, RECENT_FOLDER_SIZE).x <= room) return text;

	// One character at a time from the left. The strings are one path deep and
	// this runs once per visible row, so the loop is shorter than the binary
	// search that would replace it.
	for (usz cut = 1; cut < text.len; cut++)
	{
		String candidate = string::tformat("…%s", text[cut..]);
		if (elem.ui.text.measure(0, candidate, RECENT_FOLDER_SIZE).x <= room) return candidate;
	}
	return "";
}

fn bool RecentList.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;

	switch (event.kind)
	{
		case MOVE:
			int over = self.hit_at(elem, event.pos);
			int lit = over < 0 ? 0 : over + 1;
			if (lit == self.lit) return false;
			self.lit = lit;
			elem.request_paint();
			return false;

		case PRESS:
			if (event.button != MouseButton.LEFT) return false;
			int row = self.hit_at(elem, event.pos);
			if (row < 0) return false;

			String held = app.config.recent[(usz)row];

			// A greyed row still consumes its click. It is a control that is off,
			// not a hole — falling through to whatever is behind it would open
			// something the user did not point at.
			if (!recent_exists(held))
			{
				app.@notice("%s is not there any more", base_name(held));
				app.refresh_ui();
				return true;
			}

			// Copied before the dialog closes: closing releases this subtree, and
			// the config entry outlives it — but `request_open` is reached through
			// the same close that would invalidate the row under the pointer.
			String path = held.copy(mem);
			defer path.free(mem);

			close_file_dialog(elem.ui);
			// A scene reopens as itself; a model on its own opens as a new scene
			// with it the only character. Either replaces what is on stage.
			bool scene = path.ends_with(SCENE_SUFFIX);
			if (app.any_character_unsaved())
			{
				ask_before_replacing_scene(elem.ui, path, scene);
			}
			else if (scene)
			{
				app.request_open_scene(path);
			}
			else
			{
				app.request_open(path);
			}
			app.refresh_ui();
			return true;

		default:
			return false;
	}
}

fn void RecentList.on_hover(&self, Element* elem, bool entered) @dynamic
{
	if (entered || self.lit == 0) return;
	self.lit = 0;
	elem.request_paint();
}
