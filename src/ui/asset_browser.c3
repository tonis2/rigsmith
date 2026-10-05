<*
 The Assets view: the configured libraries as a searchable grid of cells, with
 the categories down the left.

 The unit here is an **item**, not a file. One `.glb` may hold a skin, half a
 dozen clips and a body, and what a person wants is one of those — so a cell is a
 clip rather than a card that has to be opened to find one. See `core/assets.c3`
 for the index behind it, which is read from each file's JSON alone.

 Three parts, and each is a cui widget rather than something painted here: the
 toolbar is a `Select` and a `TextField`, the sidebar is a `Tree`, the grid is a
 `Grid` of `AssetCell`s. Only the cell is crig's, because only the cell knows
 what an asset looks like.

 **What a cell does when it is pressed depends on what it is.** A skin or a
 skeleton goes through the confirm, because it replaces every dot in the document.
 A clip does nothing at all beyond coming to the front: the + on it puts it on the
 character, and the Animations pane is where the character's clips are played. The
 grid used to play them, which made the library's pane the only way to start an
 animation and left the pane listing the character's own clips with less to do
 than the one listing everybody's. See `AppState.activate_asset`, and `asset_flags`
 for what greys.

 The category rows and the chooser's options are held on the AppState rather than
 built here: cui borrows both for the life of the element, and a temporary made
 inside a build does not last that long.
*>
module crig;

import cui;
import cui::widgets;


import std::math;

const String ASSETS_SEARCH_ID = "assets-search";
const String ASSETS_TREE_ID = "assets-tree";
const String ASSETS_GRID_ID = "assets-grid";
const String ASSETS_LIBRARY_ID = "assets-library";

// Wide enough for "Animations" indented one step with a count beside it, which
// is the longest row the sidebar generates.
const float ASSET_SIDEBAR_W = 150.0;

const float ASSET_TOOLBAR_H = 34.0;
const float ASSET_SEARCH_W = 180.0;
const float ASSET_LIBRARY_W = 150.0;
const float ASSET_PAD = 10.0;

// A cell is a thumbnail box with two lines under it: the name, and what the
// asset is. The box is empty for now and drawn as a recess — previews are a
// later change, and a cell that reserves no room for one would move every other
// cell on the day they arrive.
const Vec2 ASSET_CELL = { 118.0, 132.0 };
const float ASSET_CELL_GAP = 10.0;
const float ASSET_THUMB_H = 88.0;
const float ASSET_NAME_SIZE = 12.0;
const float ASSET_META_SIZE = 11.0;
const Vec4 ASSET_CELL_RADII = { 6.0, 6.0, 6.0, 6.0 };

// The gear in a hovered cell's corner: half the width it takes, and how far its
// centre sits in from the top-right. Sized so the square it is hit-tested in is
// a comfortable target without covering the thumbnail it sits on.
const float ASSET_GEAR_R = 8.0;
const float ASSET_GEAR_INSET = 12.0;

// The bind target sits in the thumbnail's *top left*, diagonally opposite the
// gear, so the two small targets in one cell cannot be confused for each other
// and neither is where a thumbnail's subject will be when previews arrive.
const float ASSET_BIND_R = 8.0;
const float ASSET_BIND_INSET = 12.0;

// What an empty grid says. A surface with nothing on it reads as a broken build
// rather than as a search that matched nothing.
const String ASSETS_EMPTY = "No assets found";
const String ASSETS_NO_MATCH = "Nothing matches that search";

<*
 Rebuild the sidebar rows from the categories the scan found.

 The `trailing` column is the count, which is what says whether a category is
 worth opening. Each is formatted into an owned string rather than a temporary: a
 `Tree` borrows what it is given for the life of its element, and a `tformat`
 result does not survive the frame that made it.

 Called from the view's builder, so the rows are rebuilt after any rescan and
 before the tree is drawn against categories that have been replaced under it.
*>
fn void AppState.refresh_category_rows(&self)
{
	self.free_category_rows();
	if (self.asset_categories.len == 0) return;

	self.category_rows = alloc::new_array(mem, TreeRow, (sz)self.asset_categories.len);
	foreach (usz i, category : self.asset_categories)
	{
		self.category_rows[i] = {
			.label = category.label,
			.trailing = string::format(mem, "%d", category.count),
			.depth = category.depth,
			// A kind heading is the only row with anything under it. Which way its
			// mark points is read back off the same flags `categories` was given, so
			// the triangle and the rows it claims to control cannot disagree.
			.expandable = category.depth == 1,
			.expanded = !self.kind_collapsed(category.kind),
		};
	}
}

fn void AppState.free_category_rows(&self)
{
	foreach (row : self.category_rows) alloc::free(mem, row.trailing.ptr);
	if (self.category_rows.len > 0) alloc::free(mem, self.category_rows);
	self.category_rows = {};
}

<*
 Which sidebar row the current filter came from, so it opens on the right one.

 Matched rather than remembered: the rows are rebuilt whenever the libraries are
 rescanned, and a row number kept across that can end up pointing at a category
 that is no longer there.
*>
fn usz selected_category(AppState* app)
{
	foreach (usz i, category : app.asset_categories)
	{
		if (category.any_kind != app.asset_filter.any_kind) continue;
		if (!category.any_kind && category.kind != app.asset_filter.kind) continue;
		if (category.any_plan != app.asset_filter.any_plan) continue;
		if (!category.any_plan && category.plan != app.asset_filter.plan) continue;
		// "Current file" differs from the plain Animations row only here.
		if (category.current_file != app.asset_filter.current_file) continue;
		return i;
	}
	return app.asset_categories.len; // past the end: nothing selected
}

<*
 The Assets view: the toolbar over the sidebar and the grid.

 The sidebar and the grid scroll separately, because they are different lengths —
 a library of three hundred clips under four categories would otherwise scroll its
 categories off the top to reach the bottom of the grid.

 Built through `ViewPanel` rather than a Column so the toolbar can be the *last*
 child and still sit at the top. The library chooser drops a list down over the
 sidebar, and cui records an open `Select`'s popup in its own element's slot in
 the paint order — a toolbar built first is a popup painted under everything
 built after it.
*>
fn Element* build_assets_view(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	app.refresh_category_rows();

	return @subtree(ui)
	{
		@tree((ViewPanel) { .bar_height = ASSET_TOOLBAR_H })
		{
			@tree((Row) { })
			{
				@tree((Scroll) { .size = { ASSET_SIDEBAR_W, 0 } })
				{
					@node((Tree) {
						.rows = app.category_rows,
						.selected = selected_category(app),
						.on_select = &asset_category_chosen,
						.on_toggle = &asset_category_toggled,
						.style = TREE_STYLE,
					}).with_id(ASSETS_TREE_ID);
				};

				@tree((Scroll) { })
				{
					@node((AssetSheet) { });
				};
			};

			@node((AssetToolbar) { });
		};
	};
}

<*
 The bar over the browser: which library, and the search box.

 A widget rather than a bare Row so the two controls can be placed against the
 bar's own edges — a Row would centre them in whatever width it was handed, and
 the search box belongs at the right whatever the pane is doing.
*>
struct AssetToolbar (Widget)
{
	Vec2 size;
}

fn Element* AssetToolbar.build(&self, Element* elem) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;

	return @subtree(elem.ui)
	{
		@tree((Row) { .gap = ASSET_PAD, .cross_align = CrossAlign.CENTER })
		{
			@node((Select) {
				.options = app.library_labels,
				.selected = app.asset_filter.library < 0 ? 0 : (usz)app.asset_filter.library + 1,
				.on_change = &asset_library_chosen,
				.style = MENU_STYLE,
				.width = ASSET_LIBRARY_W,
			}).with_id(ASSETS_LIBRARY_ID);

			@node((TextField) {
				.placeholder = "Search",
				.on_change = &asset_search_typed,
				.style = TEXT_FIELD_STYLE,
				.width = ASSET_SEARCH_W,
			}).with_id(ASSETS_SEARCH_ID);
		};
	};
}

fn Vec2 AssetToolbar.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	Vec2 own = constraints.constrain({ constraints.max.x, ASSET_TOOLBAR_H });
	if (elem.children.len() > 0)
	{
		Vec2 inner = elem.layout_child(0, cui::loose({ own.x - 2 * ASSET_PAD, own.y }));
		elem.place_child(0, { ASSET_PAD, (own.y - inner.y) * 0.5f });
	}
	return own;
}

fn void AssetToolbar.paint(&self, Element* elem, Painter* painter) @dynamic
{
	painter.rect({ 0, 0 }, elem.size, { .color = PANEL });
	// The hairline under the bar, so the controls read as a bar rather than as
	// two widgets floating over the grid.
	painter.rect({ 0, elem.size.y - 1 }, { elem.size.x, 1 }, { .color = PANEL_BORDER });
}

<*
 The grid of cells, plus the line that stands in for it when there are none.

 A widget around the `Grid` rather than the Grid itself, because an empty grid is
 not an empty panel: it has to say whether the library is empty or the search
 matched nothing, and those are different things to a person who has just typed.
*>
struct AssetSheet (Widget)
{
	Vec2 size;
}

fn Element* AssetSheet.build(&self, Element* elem) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;

	return @subtree(elem.ui)
	{
		@tree((Padding) { .insets = widgets::insets_all(ASSET_PAD) })
		{
			@tree((Grid) {
				.cell = ASSET_CELL,
				.gap_x = ASSET_CELL_GAP,
				.gap_y = ASSET_CELL_GAP,
			})
			{
				for (usz i = 0; i < app.visible_assets.len; i++) @node((AssetCell) { .row = i });
			};
		}.with_id(ASSETS_GRID_ID);
	};
}

fn Vec2 AssetSheet.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	if (elem.children.len() == 0) return constraints.constrain({ constraints.max.x, 0 });

	Vec2 inner = elem.layout_child(0, constraints);
	elem.place_child(0, { 0, 0 });

	// As wide as offered so the empty line has somewhere to sit and the grid is
	// not centred in a column of its own width.
	return constraints.constrain({ constraints.max.x, math::max(inner.y, ASSET_CELL.y) });
}

fn void AssetSheet.paint(&self, Element* elem, Painter* painter) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	if (app.visible_assets.len > 0) return;

	// Which of the two lines depends on why it is empty: a library with nothing in
	// it is a configuration to fix, and a search that matched nothing is a word to
	// retype. Saying "no assets" to the second would send the user to the settings.
	bool searching = app.asset_filter.search.len > 0
		|| !app.asset_filter.any_kind
		|| app.asset_filter.library >= 0;
	painter.text({ ASSET_PAD, ASSET_PAD }, app.assets.entries.len > 0 && searching
		? ASSETS_NO_MATCH
		: ASSETS_EMPTY, {
		.size = ASSET_NAME_SIZE,
		.color = TEXT_DIM,
	});
}

<*
 One cell: a thumbnail box, the asset's name, and what it is.

 Holds the row it draws rather than the entry, because the entry moves — a rescan
 replaces the index under it, and a filter changes what row a position means. The
 row is re-read from the AppState on every paint and every click, so a cell can
 never act on an asset that is no longer the one under it.
*>
struct AssetCell (Widget)
{
	usz row;
	bool hovered;

	// Whether the pointer is on the gear rather than on the cell around it. The
	// two do different things on a click, so the cell has to say which one is
	// about to happen before the click happens.
	bool on_gear;

	// And the same for the bind target. Three meanings on one cell now — play it,
	// name its file, add it to the character — so the cell tracks which of the two
	// small ones the pointer is inside and treats everything else as the body.
	bool on_bind;
}

<*
 Where the bind target sits, in element-local pixels.

 `gear_at`'s counterpart, and the same bargain: one arithmetic shared by the
 paint and the hit test, so the two cannot disagree about where the target is.
*>
fn Vec2 AssetCell.bind_at(&self, Vec2 size)
{
	return { ASSET_BIND_INSET, ASSET_BIND_INSET };
}

fn bool AssetCell.over_bind(&self, Element* elem, Vec2 pos)
{
	Vec2 at = self.bind_at(elem.size);
	return pos.x >= at.x - ASSET_BIND_R && pos.x <= at.x + ASSET_BIND_R
		&& pos.y >= at.y - ASSET_BIND_R && pos.y <= at.y + ASSET_BIND_R;
}

<*
 Where the gear sits in a cell of this size, in element-local pixels.

 One arithmetic for the paint and the hit test, so the two cannot disagree about
 where the target is. Everything else in a cell is hit-tested by the cell's own
 rect, which layout settles; this is the one target inside it that is not.
*>
fn Vec2 AssetCell.gear_at(&self, Vec2 size)
{
	return { size.x - ASSET_GEAR_INSET, ASSET_GEAR_INSET };
}

// Squared off rather than round: a target this small is easier to hit than to
// aim at, and the corner of the cell does nothing else.
fn bool AssetCell.over_gear(&self, Element* elem, Vec2 pos)
{
	Vec2 at = self.gear_at(elem.size);
	return pos.x >= at.x - ASSET_GEAR_R && pos.x <= at.x + ASSET_GEAR_R
		&& pos.y >= at.y - ASSET_GEAR_R && pos.y <= at.y + ASSET_GEAR_R;
}

fn Vec2 AssetCell.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	// Tight from the Grid, so this is the cell size the grid decided rather than a
	// size of this widget's own — which is what keeps the columns lined up.
	return constraints.constrain(ASSET_CELL);
}

<*
 What the second line says: the one number that tells assets of a kind apart.

 Whichever number the kind is chosen by — a rig by how many joints it has, a clip
 by how long it runs, a mesh by how heavy it is. Kinds with no such number get an
 empty line rather than a placeholder.

 The body plan is on the entry but deliberately not here. A library is nearly
 always one creature's worth of clips, so the tag read the same on every cell of
 every row and spent the line's width saying what the cell beside it had just
 said. Where it earns its place is the sidebar, which lists each plan once and
 narrows to it.

 The result is a temporary and is drawn immediately; it does not outlive the call.
*>
fn String asset_detail(AssetEntry* entry)
{
	switch (entry.kind)
	{
		case SKIN:
		case JOINTS:
			return string::tformat("%d joints", entry.joints);
		case ANIMATION:
			return string::tformat("%.1fs", entry.duration);
		default:
			return "";
	}
}

fn void AssetCell.paint(&self, Element* elem, Painter* painter) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	AssetEntry* entry = app.visible_asset(self.row);
	if (!entry) return;

	MenuItemFlags flags = app.asset_flags(self.row);
	bool lit = self.hovered && !flags.disabled;
	bool chosen = app.selected_asset >= 0
		&& (usz)app.selected_asset == app.visible_assets[self.row];

	Color fill = BTN;
	if (flags.checked) { fill = ACCENT; }
	else if (lit) { fill = BTN_HOVER; }
	else if (chosen) { fill = BTN_PRESS; }
	painter.rect({ 0, 0 }, elem.size, { .color = fill, .border_radius = ASSET_CELL_RADII });

	// The thumbnail box, drawn as a recess. Empty until previews exist; the room
	// is reserved now so their arrival does not move every cell.
	painter.rect({ 1, 1 }, { elem.size.x - 2, ASSET_THUMB_H }, {
		.color = BG,
		.border_radius = { 5, 5, 0, 0 },
	});

	// The kind, centred in the box, standing in for the picture. A cell showing
	// nothing at all cannot be told from one whose preview failed to load.
	String kind = entry.kind.label();
	Vec2 kind_size = elem.ui.text.measure(0, kind, ASSET_META_SIZE);
	painter.text(
		{ (elem.size.x - kind_size.x) * 0.5f, 1 + (ASSET_THUMB_H - kind_size.y) * 0.5f },
		kind,
		{ .size = ASSET_META_SIZE, .color = TEXT_DIM.dim(0.7) }
	);

	Color ink = TEXT;
	if (flags.checked) { ink = DOT_OUTLINE; }
	else if (flags.disabled) { ink = TEXT_DIM.dim(0.55); }

	float text_y = ASSET_THUMB_H + 8.0f;
	painter.text({ 8, text_y }, elide(elem, entry.name, elem.size.x - 16.0f, ASSET_NAME_SIZE), {
		.size = ASSET_NAME_SIZE,
		.color = ink,
	});
	// Elided like the name above it. Nothing `asset_detail` writes is long enough
	// to need it today; the guard is here because a line running under the cell
	// beside it is worse than one that stops, and a cell is a fixed width.
	painter.text(
		{ 8, text_y + ASSET_NAME_SIZE + 4.0f },
		elide(elem, asset_detail(entry), elem.size.x - 16.0f, ASSET_META_SIZE),
		{ .size = ASSET_META_SIZE, .color = flags.checked ? DOT_OUTLINE : TEXT_DIM }
	);

	// Only while the pointer is on the cell. A gear on every cell at once turns
	// the grid into a sheet of controls; on the one being pointed at it is an
	// affordance, and there is only ever one pointer.
	//
	// Drawn for a greyed cell too: a clip that does not fit the rig standing here
	// cannot be played, but its file can still be named and tagged, and that is
	// the file the tag belongs to.
	if (self.hovered)
	{
		paint_gear(painter, self.gear_at(elem.size), ASSET_GEAR_R,
			self.on_gear ? TEXT : TEXT_DIM, BG);
	}

	// The bind mark, and the one thing in a cell drawn whether or not the pointer
	// is here: which animations belong to this character is the question the grid
	// is being read for, and an answer that only appears under the pointer is one
	// the user has to sweep the grid to collect.
	//
	// Animations only. A body plan is applied rather than accumulated — there is
	// one skeleton — so a bind mark on one would be offering something that does
	// not exist.
	if (entry.kind == AssetKind.ANIMATION)
	{
		bool bound = app.is_bound_entry(entry);
		if (bound || self.hovered)
		{
			paint_bind_mark(painter, self.bind_at(elem.size), ASSET_BIND_R, bound,
				self.on_bind ? TEXT : TEXT_DIM);
		}
	}
}

<*
 The mark that says whether a clip is one of this character's.

 A filled ring with a bar through it for bound, an open ring with a plus for not
 — so the two read apart at a glance and at this size, where a tick and a cross
 do not. Filled in the accent, because the bound set is the thing the grid is
 being scanned for.

 Drawn with the painter's own primitives, like `paint_gear`: an icon font would
 be a second text pipeline for eleven pixels.
*>
fn void paint_bind_mark(Painter* painter, Vec2 at, float r, bool bound, Color hint)
{
	// A disc behind it either way, so the mark reads over the thumbnail recess as
	// well as over the cell fill.
	painter.circle(at, r, { .color = bound ? ACCENT : BG });

	Color ink = bound ? DOT_OUTLINE : hint;
	float arm = r * 0.45f;

	if (!bound)
	{
		painter.circle(at, r, { .color = { 0, 0, 0, 0 }, .border_color = ink, .border_width = 1.0 });
		// The upright of the plus. Only for the unbound state: with the bar below
		// it, the two together are what tells "add" from "added".
		painter.line({ at.x, at.y - arm }, { at.x, at.y + arm }, 1.5, ink);
	}
	painter.line({ at.x - arm, at.y }, { at.x + arm, at.y }, 1.5, ink);
}

<*
 As much of `text` as fits in `width`, with an ellipsis when it did not.

 A name is whatever the file said and a cell is a fixed width, so something has
 to give. Cutting it is better than letting it run into the cell beside it, and
 the mark is what says the name goes on — a bare cut reads as the asset's real
 name.

 Returns a temporary, drawn immediately.
*>
fn String elide(Element* elem, String text, float width, float size)
{
	if (elem.ui.text.measure(0, text, size).x <= width) return text;

	// Backwards from the whole string: a name that fits is the common case and is
	// answered above, and one that does not is usually only a little too long.
	for (usz keep = text.len; keep > 1; keep--)
	{
		String shorter = string::tformat("%s…", text[:keep - 1]);
		if (elem.ui.text.measure(0, shorter, size).x <= width) return shorter;
	}
	return "…";
}

fn bool AssetCell.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;

	switch (event.kind)
	{
		case PRESS:
			if (event.button != MouseButton.LEFT) return false;

			// Before the greying: the gear is about the file, and a cell can be
			// greyed for reasons that have nothing to do with what its file is
			// called.
			if (self.over_gear(elem, event.pos))
			{
				open_asset_settings(elem.ui, self.row);
				return true;
			}

			// Before the greying too, and for a different reason: a clip may be
			// bound to a character it does not currently fit — the rig is still
			// being built, or a plan has yet to be applied — and refusing to
			// remember the choice until the rig catches up would make the user
			// come back and make it again.
			if (self.over_bind(elem, event.pos))
			{
				if (app.toggle_bound_row(self.row)) app.refresh_ui();
				elem.request_paint();
				return true;
			}

			// A greyed cell still consumes: it is a control that is off, not a hole
			// through to the sheet behind it.
			if (app.asset_flags(self.row).disabled) return true;

			if (app.activate_asset(self.row))
			{
				// Through the app rather than this element: what moved is which cell is
				// the chosen one, so the cell that *was* chosen has to be repainted too
				// and it is not this one. A body plan applied from here also changes what
				// every other cell greys.
				app.refresh_ui();
			}
			return true;

		case MOVE:
			bool gear = self.over_gear(elem, event.pos);
			bool bind = !gear && self.over_bind(elem, event.pos);
			if (!self.hovered || gear != self.on_gear || bind != self.on_bind)
			{
				self.hovered = true;
				self.on_gear = gear;
				self.on_bind = bind;
				elem.request_paint();
			}
			return false;

		default:
			return false;
	}
}

// Leaving produces no MOVE, so the highlight would stay lit on the cell the
// pointer left through.
fn void AssetCell.on_hover(&self, Element* elem, bool entered) @dynamic
{
	if (self.hovered == entered) return;
	self.hovered = entered;
	if (!entered)
	{
		self.on_gear = false;
		self.on_bind = false;
	}
	elem.request_paint();
}

// ---------------------------------------------------------------------------
// What the three controls do. Each reaches the app by type and goes through
// `set_asset_filter`, which is the one place the visible list is decided.

<*
 A category row was picked: narrow to it, or open and close it.

 Two meanings on one target, decided by what is already narrowed to. The first
 click on a kind heading narrows the grid to that kind; a second click on the
 same row, now that it is the one the grid is showing, opens or closes it. A
 heading is the only row with anything under it, so a plan row's second click
 stays what it was — a click on the row it already chose.

 The disclosure mark does the same open and close without touching the filter,
 but it is one indent step wide and the row is the width of the sidebar. Hiding
 the commonest thing a person wants from a category behind the smallest target
 in it is what made the marks look broken.

 The row carries the kind and the plan, so narrowing is a copy rather than a
 lookup — and the search box is left alone, because a category and a search are
 two narrowings a person expects to combine.
*>
fn void asset_category_chosen(Ui* ui, usz row)
{
	AppState* app = ui.inherit(AppState)!!;
	if (row >= app.asset_categories.len) return;

	AssetCategory category = app.asset_categories[row];
	if (category.depth == 1 && row == selected_category(app))
	{
		app.set_kind_collapsed(category.kind, !app.kind_collapsed(category.kind));
		app.refresh_asset_sidebar();
		app.refresh_ui();
		return;
	}

	AssetFilter narrowed = app.asset_filter;
	narrowed.any_kind = category.any_kind;
	narrowed.kind = category.kind;
	narrowed.any_plan = category.any_plan;
	narrowed.plan = category.plan;
	narrowed.current_file = category.current_file;

	if (app.set_asset_filter(narrowed)) app.refresh_ui();
}

<*
 A kind's disclosure mark was clicked: show or hide the body plans under it.

 Only the mark reaches this — cui's Tree hands a click on the label to
 `on_select` instead — so closing a category and narrowing to it stay two
 separate gestures on the same row.

 Depth 1 is the only depth with anything under it. "All" and the plan rows are
 not marked expandable, so a click on one cannot arrive here; the guard is for
 the day a third level does.
*>
fn void asset_category_toggled(Ui* ui, usz row)
{
	AppState* app = ui.inherit(AppState)!!;
	if (row >= app.asset_categories.len) return;

	AssetCategory category = app.asset_categories[row];
	if (category.depth != 1) return;

	app.set_kind_collapsed(category.kind, !app.kind_collapsed(category.kind));
	app.refresh_asset_sidebar();
	app.refresh_ui();
}

// The first option is "All libraries", so the chooser's index is one past the
// position in the configured list.
fn void asset_library_chosen(Ui* ui, usz option)
{
	AppState* app = ui.inherit(AppState)!!;

	AssetFilter narrowed = app.asset_filter;
	narrowed.library = option == 0 ? -1 : (int)option - 1;
	if (app.set_asset_filter(narrowed)) app.refresh_ui();
}

// Every keystroke, not only Return — see cui's `TextField.on_change`. The filter
// keeps its own copy of the text, so the field is free to be rebuilt under it.
fn void asset_search_typed(Ui* ui, String text)
{
	AppState* app = ui.inherit(AppState)!!;

	AssetFilter narrowed = app.asset_filter;
	narrowed.search = text;
	if (app.set_asset_filter(narrowed)) app.refresh_ui();
}
