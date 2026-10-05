<*
 The Animations dock: a clip manager on the left and the Layers column on the
 right (layer_strip.c3), a draggable divider between them.

 The clip manager is for choosing, creating, timing and seeing keys: a header
 (clip, + New menu, ⋯ clip menu), the transport, a key row, a strip of sheet
 options, the sheet itself — which fills what the dock's height leaves — and a
 slim status bar. The default sheet summarizes whole poses; joint tracks are
 opt-in. Posing tools (rest pose, mirror, copy/paste, balance, pins, the pose
 library) are in the N-panel's Pose tab (pose_panel.c3). In the Joints stage the
 key row and the Layers column are greyed out.
*>
module crig;

import cui;
import cui::widgets;



import std::math;
import std::math::vector;

const String ANIM_PANEL_ID = "anim-panel";
const String ANIM_SHEET_ID = "anim-sheet";
const String ANIM_KEY_ID = "anim-key";
const String ANIM_KEY_SELECTED_ID = "anim-key-selected";
const String ANIM_KEY_CHANGED_ID = "anim-key-changed";
const String ANIM_UNBIND_ID = "anim-unbind";
const String ANIM_START_ID = "anim-transport-start";
const String ANIM_PREV_ID = "anim-transport-prev";
const String ANIM_TRANSPORT_PLAY_ID = "anim-transport-play";
const String ANIM_NEXT_ID = "anim-transport-next";
const String ANIM_END_ID = "anim-transport-end";
const String ANIM_AUTO_KEY_ID = "anim-autokey";
const String ANIM_BALANCE_ID = "anim-balance";
const String ANIM_LOOP_TOGGLE_ID = "anim-loop-toggle";
const String ANIM_TIME_ID = "anim-time-readout";
const String ANIM_SAVE_STATUS_ID = "anim-save-status";
const String ANIM_MORE_ID = "anim-more";
const String ANIM_CLIP_MENU_ID = "anim-clip-menu";
const String ANIM_FROM_LIBRARY_ID = "anim-from-library";
const String ANIM_RATE_ID = "anim-rate";
const String ANIM_SPEED_ID = "anim-speed";
const String ANIM_PENDING_BANNER_ID = "anim-pending-banner";

const float ANIM_PAD = 12.0;
const float ANIM_GAP = 8.0;
const float ANIM_TEXT_SIZE = 13.0;
// Past this many bound clips the clip chooser grows a search field, rather than
// making the reader scroll a list that no longer fits the dropdown.
const usz ANIM_CHOOSER_SEARCH_MIN = 8;
// A toggle cell: "Prevent intersections" with its box, and a little air.
const float ANIM_TOGGLE_CELL_W = 172.0;

// A dense whole-pose key has one lane for every named joint. Letting all of
// those lanes contribute to the panel's natural height puts the transport and
// Key buttons below the pane, precisely when a full rig is being animated.
// Keep a useful handful visible and scroll the sheet independently; the outer
// panel scroll remains for genuinely short windows.
const float ANIM_SHEET_H = 5 * TREE_STYLE.row_height;

// Room for the sheet to say why it is empty, when it is.
const float ANIM_SHEET_EMPTY_H = 40.0;

const String ANIM_SHEET_NONE =
	"Choose an animation, or press + New to start one.";

const String ANIM_SHEET_EMPTY =
	"This clip drives no joints";

<*
 What the right-hand column of a row says: how long the clip runs, or why it
 could not be found.

 Owned by the caller — `free_anim_rows` releases it.
*>
fn String AppState.anim_row_text(&self, sz index)
{
	AnimRef ref = self.resolve_bound(index);
	if (!ref.valid())
	{
		BoundClip bound = self.doc.animations[index];
		// Named by what is wrong with it, because the two are fixed differently: a
		// file that moved is found again by adding its folder in Settings, and an
		// authored clip absent from the project needs a different explanation.
		return bound.file.len == 0
			? "missing project clip".copy(mem)
			: string::format(mem, "%s?", base_name(bound.file));
	}

	AnimTemplate* clip = self.clip(ref);
	if (!clip) return "".copy(mem);

	// The one number that tells clips apart, the same one the browser's cells
	// print. A clip this rig cannot currently carry says so instead: it is bound,
	// it will export, and it will not play until the rig grows the joints it
	// names — which is worth knowing here rather than by clicking it.
	if (!self.clip_applies(ref)) return string::format(mem, "%.1fs · some joints don't match", clip.duration);
	return string::format(mem, "%.1fs", clip.duration);
}

<*
 Rebuild the bound rows (name and length, or why a row cannot be found) and keep
 `anim_selected` inside the set, since every path that changes it calls this.
*>
fn void AppState.refresh_anim_rows(&self)
{
	self.free_anim_rows();

	sz count = self.doc.animations.len();
	if (count == 0)
	{
		self.anim_selected = 0;
		return;
	}
	if (self.anim_selected >= (usz)count) self.anim_selected = (usz)count - 1;

	self.anim_rows = alloc::new_array(mem, TreeRow, count);
	for (sz i = 0; i < count; i++)
	{
		self.anim_rows[i] = {
			.label = self.doc.animations[i].clip,
			.trailing = self.anim_row_text(i),
			.depth = 0,
		};
	}
}

fn void AppState.free_anim_rows(&self)
{
	foreach (row : self.anim_rows)
	{
		if (row.trailing.len > 0) alloc::free(mem, row.trailing.ptr);
	}
	if (self.anim_rows.len > 0) alloc::free(mem, self.anim_rows);
	self.anim_rows = {};
}

fn Element* build_animations_view(Ui* ui)
{
	// No scroll or padding out here: the panel fills the pane, and each of its two
	// sides pads and scrolls on its own.
	return @subtree(ui)
	{
		@node((AnimPanel) { }).with_id(ANIM_PANEL_ID);
	};
}

// Every pane showing it, not the first: the workspace can be split so two do.
fn void refresh_animations_view(Ui* ui)
{
	ui.@each_id(ANIM_PANEL_ID; panel)
	{
		panel.request_build();
	};
}

<*
 What decides the *shape* of the pane, as against what is written in it.

 `PhysicsSnapshot`'s counterpart and the same discipline: a rebuild releases the
 element under the pointer, so it must happen when the set of controls changes
 and not when a number does.
*>
struct AnimSnapshot
{
	sz bound;
	usz dots;
	int playing_pack;
	int playing_clip;
	bool animating;
	bool paused;
	bool auto_key;
	// The edited clip's own loop flag drives the Loop toggle beside Auto-key.
	bool clip_loops;
	// The self-collision system's switch and, under it, the per-rig control
	// and the mode: the clip tools menu's shape follows all three.
	bool self_collision;
	bool prevent;
	CollisionMode collision_mode;
	bool show_tracks;
	bool show_curves;
	bool graph_position;
	bool selected_tracks_only;
	uint selected_joint;
	uint selected_joints_hash;
	// Joints stage: the key row and the Layers column are greyed out.
	bool posing;
	// The layer form's three folded sections.
	bool blend_collapsed;
	bool motion_collapsed;
	bool mask_collapsed;
	bool pending_pose;
	bool pending_asked;
	bool authored_dirty;
	uint revision;

	// The clip being edited, and how many keys it has. The count is what makes
	// the sheet follow an edit: every edit replaces the whole `AnimTemplate`, and
	// a key added or taken away changes the markers the sheet is drawing.
	int edit_pack;
	int edit_clip;
	// The layer strip: which layer is active (-1 = base) and how many there are.
	int active_layer;
	usz layers;
	usz keys;
	usz tracks;
	// The look-at targets and their keys together: either changing redraws the lanes.
	usz aims;
	usz aim_keys;
	// The last Check, when it is about this clip.
	bool checked;
	usz issues;
	// Ghosts shade the timeline around the playhead: on or off, and how far.
	bool ghosts;
	int ghost_past;
	int ghost_future;
	int ghost_step;
	int fps;
}

fn usz anim_aim_key_total(AnimTemplate* clip) @private
{
	usz total;
	if (clip) foreach (&target : clip.aim_targets) total += target.keys.len;
	return total;
}

fn AnimSnapshot anim_snapshot(AppState* app) @private
{
	uint selected_hash = app.selected * 16777619u;
	foreach (id : app.also_selected.array_view()) selected_hash = (selected_hash ^ id) * 16777619u;
	return {
		.bound = app.doc.animations.len(),
		// The rig, because whether a clip can play on it is printed in every row.
		.dots = (usz)app.doc.dots.len(),
		.playing_pack = app.current_ref.pack,
		.playing_clip = app.current_ref.clip,
		.animating = app.animating,
		.paused = app.anim_paused,
		.auto_key = app.auto_key,
		.clip_loops = app.clip(app.editing) ? app.clip(app.editing).loop : false,
		.self_collision = app.config.self_collision,
		.prevent = !app.doc.allow_intersections,
		.collision_mode = app.collision_mode,
		.show_tracks = app.anim_show_tracks,
		.show_curves = app.anim_show_curves,
		.graph_position = app.anim_graph_position,
		.selected_tracks_only = app.anim_tracks_selected_only,
		.selected_joint = app.selected,
		.selected_joints_hash = selected_hash,
		.posing = app.stage == POSE_STAGE,
		.blend_collapsed = app.layer_blend_collapsed,
		.motion_collapsed = app.layer_motion_collapsed,
		.mask_collapsed = app.layer_mask_collapsed,
		.pending_pose = app.pose_edit_pending,
		.pending_asked = app.anim_pending_action != 0,
		.authored_dirty = app.authored_dirty,
		.revision = app.undo_stack.revision,
		.edit_pack = app.editing.pack,
		.edit_clip = app.editing.clip,
		.active_layer = (int)app.active_layer_of(app.editing),
		.layers = app.clip(app.editing) ? app.clip(app.editing).layers.len : 0,
		.keys = app.key_clip(app.editing) ? app.key_clip(app.editing).keyframes.len : 0,
		.tracks = app.timeline_tracks.len,
		.aims = app.clip(app.editing) ? app.clip(app.editing).aim_targets.len : 0,
		.aim_keys = anim_aim_key_total(app.clip(app.editing)),
		.checked = app.anim_check.ran && app.anim_check.ref.same(app.editing),
		.issues = app.anim_check.issues.len,
		.ghosts = app.config.show_ghosts,
		.ghost_past = app.ghost_past_count(),
		.ghost_future = app.ghost_future_count(),
		.ghost_step = app.ghost_step_frames(),
		.fps = app.anim_fps,
	};
}

fn bool AnimSnapshot.differs(self, AnimSnapshot other)
{
	return self.bound != other.bound
		|| self.dots != other.dots
		|| self.playing_pack != other.playing_pack
		|| self.playing_clip != other.playing_clip
		|| self.animating != other.animating
		|| self.paused != other.paused
		|| self.auto_key != other.auto_key
		|| self.clip_loops != other.clip_loops
		|| self.self_collision != other.self_collision
		|| self.prevent != other.prevent
		|| self.collision_mode != other.collision_mode
		|| self.show_tracks != other.show_tracks
		|| self.show_curves != other.show_curves
		|| self.graph_position != other.graph_position
		|| self.selected_tracks_only != other.selected_tracks_only
		|| self.selected_joint != other.selected_joint
		|| self.selected_joints_hash != other.selected_joints_hash
		|| self.posing != other.posing
		|| self.blend_collapsed != other.blend_collapsed
		|| self.motion_collapsed != other.motion_collapsed
		|| self.mask_collapsed != other.mask_collapsed
		|| self.pending_pose != other.pending_pose
		|| self.pending_asked != other.pending_asked
		|| self.authored_dirty != other.authored_dirty
		|| self.revision != other.revision
		|| self.edit_pack != other.edit_pack
		|| self.edit_clip != other.edit_clip
		|| self.active_layer != other.active_layer
		|| self.layers != other.layers
		|| self.keys != other.keys
		|| self.tracks != other.tracks
		|| self.aims != other.aims
		|| self.aim_keys != other.aim_keys
		|| self.checked != other.checked
		|| self.issues != other.issues
		|| self.ghosts != other.ghosts
		|| self.ghost_past != other.ghost_past
		|| self.ghost_future != other.ghost_future
		|| self.ghost_step != other.ghost_step
		|| self.fps != other.fps;
}

// ---------------------------------------------------------------------------
// The dock's frame: a clip manager on the left, a Layers column on the right, a
// draggable divider between them.

// The divider's grab width and the least the sheet is given, however short the
// dock is (the clip manager scrolls instead).
const float ANIM_DIVIDER_W = 6.0;
const float ANIM_SHEET_MIN_H = 96.0;

// Shown over the key row and the Layers column while the Joints stage is on.
const String ANIM_STAGE_HINT = "Switch to Pose to animate";

const String ANIM_DOCK_ID = "anim-dock";
const String ANIM_CLIP_SIDE_ID = "anim-clip-side";
const String ANIM_LAYERS_SIDE_ID = "anim-layers-side";
const String ANIM_DIVIDER_ID = "anim-divider";
const String ANIM_SHEET_SLOT_ID = "anim-sheet-slot";
const String ANIM_KEY_ROW_ID = "anim-key-row";
const String ANIM_SHEET_STRIP_ID = "anim-sheet-strip";
const String ANIM_STAGE_SHADE_ID = "anim-stage-shade";

<*
 The share of the dock's width the Layers column takes: the remembered one, or
 the default when the divider was never dragged.
*>
fn float AppState.layers_ratio(&self)
{
	float ratio = self.config.anim_layers_ratio;
	if (ratio < MIN_LAYERS_RATIO || ratio > MAX_LAYERS_RATIO) return DEFAULT_LAYERS_RATIO;
	return ratio;
}

<*
 Three children in build order: the clip manager, the divider, the Layers column.
 Fills what it is offered and remembers the height, which is what lets the sheet
 fill what the clip manager's other rows leave (`AnimClipManager`).
*>
struct AnimDock (Widget)
{
	float viewport_h;
}

fn Vec2 AnimDock.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	float w = constraints.max.x;
	float h = constraints.max.y >= cui::UNBOUNDED ? ANIMATION_DOCK_H : constraints.max.y;
	self.viewport_h = h;
	if (elem.children.len() < 3) return constraints.constrain({ w, h });

	float room = math::max(w - ANIM_DIVIDER_W, 0.0f);
	float layers_w = math::floor(room * app.layers_ratio());
	float clip_w = room - layers_w;
	elem.layout_child(0, cui::tight({ clip_w, h }));
	elem.layout_child(1, cui::tight({ ANIM_DIVIDER_W, h }));
	elem.layout_child(2, cui::tight({ layers_w, h }));
	elem.place_child(0, { 0, 0 });
	elem.place_child(1, { clip_w, 0 });
	elem.place_child(2, { clip_w + ANIM_DIVIDER_W, 0 });
	return constraints.constrain({ w, h });
}

<*
 The bar between the two sides. Dragging it writes the Layers column's share of
 the width into the config; the release saves it.
*>
struct AnimDockDivider (Widget)
{
	bool dragging;
	bool hovered;
}

fn void AnimDockDivider.on_hover(&self, Element* elem, bool entered) @dynamic
{
	self.hovered = entered;
	if (entered) elem.set_cursor(Cursor.RESIZE_H);
	elem.request_paint();
}

fn void AnimDockDivider.paint(&self, Element* elem, Painter* painter) @dynamic
{
	bool lit = self.dragging || self.hovered;
	float w = lit ? 3.0f : 1.0f;
	painter.rect({ (elem.size.x - w) * 0.5f, 0 }, { w, elem.size.y }, { .color = lit ? ACCENT : PANEL_BORDER });
}

fn bool AnimDockDivider.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	switch (event.kind)
	{
		case PRESS:
			if (event.button != MouseButton.LEFT) return false;
			self.dragging = true;
			elem.request_paint();
			return true;
		case RELEASE:
			if (event.button != MouseButton.LEFT || !self.dragging) return false;
			self.dragging = false;
			app.config.save();
			elem.request_paint();
			return true;
		case MOVE:
			if (!self.dragging) return false;
			Element* dock = elem.parent;
			float room = dock.size.x - ANIM_DIVIDER_W;
			if (room <= 0) return true;
			// The pointer holds the divider's centre; what lies to its left is the
			// clip manager, what is left of the room is the Layers column.
			float clip_w = event.absolute.x - dock.absolute.x - ANIM_DIVIDER_W * 0.5f;
			app.config.anim_layers_ratio = math::clamp((room - clip_w) / room, MIN_LAYERS_RATIO, MAX_LAYERS_RATIO);
			dock.request_layout();
			return true;
		default:
			return false;
	}
}

<*
 The clip manager's column: every child at its own height, except the sheet
 (the child with id `ANIM_SHEET_SLOT_ID`), which is given whatever the dock's
 height leaves — so the sheet fills the dock instead of a fixed five rows.

 When the rows and the smallest sheet do not fit, the whole column grows past the
 dock and its Scroll takes over.
*>
struct AnimClipManager (Widget)
{
	float gap;
}

fn Vec2 AnimClipManager.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	sz count = elem.children.len();
	float w = constraints.max.x;

	float room = 0;
	for (Element* at = elem.parent; at; at = at.parent)
	{
		if (!at.is_widget(AnimDock)) continue;
		room = at.widget_as(AnimDock).viewport_h - 2 * ANIM_PAD;
		break;
	}

	float used = count > 1 ? self.gap * (float)(count - 1) : 0.0f;
	sz flex = -1;
	for (sz i = 0; i < count; i++)
	{
		if (elem.children[i].id == ANIM_SHEET_SLOT_ID)
		{
			flex = i;
			continue;
		}
		used += elem.layout_child(i, cui::loose({ w, cui::UNBOUNDED })).y;
	}
	if (flex >= 0)
	{
		float height = room > 0 ? math::max(room - used, ANIM_SHEET_MIN_H) : ANIM_SHEET_H;
		elem.layout_child(flex, cui::tight({ w, height }));
	}

	float cursor = 0;
	for (sz i = 0; i < count; i++)
	{
		elem.place_child(i, { 0, cursor });
		cursor += elem.children[i].size.y + self.gap;
	}
	return constraints.constrain({ w, count > 0 ? cursor - self.gap : 0.0f });
}

<*
 Wraps the content of a region that only makes sense while posing. Its optional
 second child is a `StageShade`, which greys the content and eats the pointer.
*>
struct StageGate (Widget)
{
	bool locked; // the caller's own reading of the stage, for whoever inspects the tree
}

fn Vec2 StageGate.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	if (elem.children.len() == 0) return constraints.constrain({ 0, 0 });
	Vec2 inner = elem.layout_child(0, constraints);
	elem.place_child(0, { 0, 0 });
	if (elem.children.len() > 1)
	{
		elem.layout_child(1, cui::tight(inner));
		elem.place_child(1, { 0, 0 });
	}
	return inner;
}

<*
 A veil over a disabled region, with its reason. It handles no pointer event, and
 being the last child it is hit first — so everything under it is blocked.
*>
struct StageShade (Widget)
{
	String hint;
}

fn void StageShade.paint(&self, Element* elem, Painter* painter) @dynamic
{
	painter.rect({ 0, 0 }, elem.size, { .color = { PANEL[0], PANEL[1], PANEL[2], 0.78f }, .border_radius = R8 });
	Vec2 text = elem.ui.text.measure(0, self.hint, ANIM_TEXT_SIZE);
	float y = math::min((elem.size.y - text.y) * 0.5f, 36.0f);
	painter.text({ math::max((elem.size.x - text.x) * 0.5f, 4.0f), y }, self.hint,
		{ .size = ANIM_TEXT_SIZE, .color = TEXT_DIM });
}

struct AnimPanel (Widget)
{
	bool restore_timeline_focus;
	AnimSnapshot shown;
}

// Fills the dock it is in; the two sides scroll on their own.
fn Vec2 AnimPanel.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	if (elem.children.len() == 0) return constraints.constrain({ 0, 0 });

	float width = constraints.max.x;
	float height = constraints.max.y >= cui::UNBOUNDED ? ANIMATION_DOCK_H : constraints.max.y;
	elem.layout_child(0, cui::tight({ width, height }));
	elem.place_child(0, { 0, 0 });
	return constraints.constrain({ width, height });
}

fn void AnimPanel.update(&self, Element* elem, float dt) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	anim_arm_pending(elem.ui);
	AnimSnapshot now = anim_snapshot(app);
	if (!now.differs(self.shown)) return;
	// A clip picked by any route becomes the clip menu's row, unless the row
	// picked is one whose source is missing, which stays picked so it can be
	// removed.
	if (now.edit_pack != self.shown.edit_pack || now.edit_clip != self.shown.edit_clip)
	{
		sz row = app.bound_row_of(app.editing);
		if (row >= 0) app.anim_selected = (usz)row;
		// Another clip starts on its base keys.
		app.active_layer = -1;
	}
	if (((app.anim_show_tracks && app.anim_tracks_selected_only) || app.anim_show_curves)
		&& (now.selected_joint != self.shown.selected_joint
			|| now.selected_joints_hash != self.shown.selected_joints_hash))
	{
		// Viewport selection changes what the sheet exposes. Do not retain sparse
		// keys that have just become invisible and could be deleted by surprise.
		app.clear_animation_key_selection();
	}
	if (elem.ui.focused && elem.ui.focused.is_widget(CurvePlot))
	{
		CurvePlot* plot = elem.ui.focused.widget_as(CurvePlot);
		// As for the sheet below: a rebuild mid-gesture would replace the plot
		// that owns the pointer.
		if (plot.held != 0 || plot.held_handle != 0 || plot.scrubbing || plot.panning) return;
	}
	if (elem.ui.focused && elem.ui.focused.is_widget(Timeline))
	{
		for (Element* at = elem.ui.focused; at; at = at.parent)
		{
			if (at != elem) continue;
			Timeline* timeline = elem.ui.focused.widget_as(Timeline);
			// Clicking a key can stop playback, which changes the transport's
			// snapshot. Defer that cosmetic rebuild until the pointer gesture ends;
			// rebuilding here would replace the Timeline that owns mouse capture.
			if (timeline.held != TIMELINE_NONE || timeline.scrubbing || timeline.bar_held != TIMELINE_NONE) return;
			self.restore_timeline_focus = true;
		}
	}

	self.shown = now;
	elem.request_build();
}

fn Element* AnimPanel.build(&self, Element* elem) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	app.refresh_anim_rows();
	if (app.default_editing())
	{
		sz row = app.bound_row_of(app.editing);
		if (row >= 0) app.anim_selected = (usz)row;
	}
	app.refresh_timeline_tracks(app.editing);
	self.shown = anim_snapshot(app);
	bool restore_focus = self.restore_timeline_focus;
	self.restore_timeline_focus = false;
	bool has_clip = app.clip(app.editing) != null;
	// Joints stage: keying and layers are a posing job, so they are greyed out
	// with the way to enable them. Transport and clip choosing stay live.
	bool locked = app.stage != POSE_STAGE;

	Element* dock = @subtree(elem.ui)
	{
		@tree((AnimDock) { })
		{
			// ---- the clip manager ----
			Element* clip_side = @tree((Scroll) { })
			{
				@tree((Padding) { .insets = widgets::insets_all(ANIM_PAD) })
				{
					@tree((AnimClipManager) { .gap = ANIM_GAP })
					{
						// The header: which clip, where a new one comes from, and what can
						// be done to this one.
						@tree((Wrap) { .gap_x = ANIM_GAP, .gap_y = ANIM_GAP, .cross_align = CENTER })
						{
							@node((AnimChooser) { });
							@node(panel_button("+ New ▾", &anim_new_menu_clicked)).with_id(ANIM_NEW_MENU_BUTTON_ID);
							@tree(widgets::tip("More — rename, duplicate, trim, mirror, un-bind or delete this animation"))
							{
								@node(panel_button("⋯", &anim_clip_menu_clicked)).with_id(ANIM_MORE_ID);
							};
						};
						if (!has_clip)
						{
							@node((Label) { .text = "Create your first animation", .size = 18, .color = TEXT });
							@node((Label) { .text = "Key poses at different times to make your character move.", .size = ANIM_TEXT_SIZE, .color = TEXT_DIM });
							@node(accent_button("Create animation", &anim_new_clip_clicked));
						}
						else
						{
							// The transport. Ghosts opens its floating panel; Path is in there
							// and in the View menu.
							@tree((Wrap) { .gap_x = ANIM_GAP, .gap_y = ANIM_GAP, .cross_align = CENTER })
							{
								@tree(widgets::tip("Start (Home) — jump to the first frame"))
								{
									@node(panel_button("|<", &anim_start_clicked)).with_id(ANIM_START_ID);
								};
								@tree(widgets::tip("Previous key ([) — jump to the key before the playhead"))
								{
									@node(panel_button("<", &anim_prev_key_clicked)).with_id(ANIM_PREV_ID);
								};
								@tree(widgets::tip("Play / pause (Space)"))
								{
									@node(accent_button(
										app.animating && app.current_ref.same(app.editing) && !app.anim_paused ? "❚❚" : "▶",
										&anim_play_pause_clicked)).with_id(ANIM_TRANSPORT_PLAY_ID);
								};
								@tree(widgets::tip("Next key (]) — jump to the key after the playhead"))
								{
									@node(panel_button(">", &anim_next_key_clicked)).with_id(ANIM_NEXT_ID);
								};
								@tree(widgets::tip("End (End) — jump to the last frame"))
								{
									@node(panel_button(">|", &anim_end_clicked)).with_id(ANIM_END_ID);
								};
								@node((AnimTimeField) { }).with_id(ANIM_TIME_ID);
								@node((Select) { .options = timing_rate_options[..], .selected = anim_rate_row(app),
									.width = 86, .style = VIEW_MENU_STYLE, .on_change = &anim_rate_chosen }).with_id(ANIM_RATE_ID);
								@node((Select) { .options = timing_speed_options[..], .selected = anim_speed_row(app),
									.width = 76, .style = VIEW_MENU_STYLE, .on_change = &anim_speed_chosen }).with_id(ANIM_SPEED_ID);
								// The clip's own loop flag. Turning it on eases a differing end
								// back to the first pose; see `clip_looped`.
								@node((ToggleButton) { .label = "Loop", .on = app.clip(app.editing).loop,
									.on_change = &anim_loop_toggled, .style = SEGMENTED_STYLE }).with_id(ANIM_LOOP_TOGGLE_ID);
								// Onion skin: lit while on; the panel it opens is movable.
								@tree(widgets::tip("Ghosts — show the pose before and after the playhead as see-through copies. Opens its settings."))
								{
									@node(app.config.show_ghosts ? accent_button("Ghosts", &anim_ghosts_clicked)
										: panel_button("Ghosts", &anim_ghosts_clicked)).with_id(ANIM_GHOSTS_ID);
								};
							};
							// The key row: the only editing left in the dock. Greyed out in
							// the Joints stage.
							Element* key_row = @tree((StageGate) { .locked = locked })
							{
								@tree((Wrap) { .gap_x = ANIM_GAP, .gap_y = ANIM_GAP, .cross_align = CENTER })
								{
									@tree(widgets::tip("Key pose (K) — key the whole pose at the playhead"))
									{
										@node(accent_button("Key pose", &anim_key_clicked)).with_id(ANIM_KEY_ID);
									};
									@tree(widgets::tip("Auto-key (Shift+K) — key every joint you pose, as you pose it"))
									{
										@node((ToggleButton) { .label = "Auto-key", .on = app.auto_key,
											.on_change = &anim_auto_key_toggled, .style = SEGMENTED_STYLE }).with_id(ANIM_AUTO_KEY_ID);
									};
									@node((AnimInterpPicker) { }).with_id(ANIM_INTERP_ID);
									// The sheet as key lanes or as the selected joints' curves.
									@node((Segmented) { .options = anim_sheet_mode_options[..], .selected = app.anim_show_curves ? 1 : 0,
										.on_change = &anim_sheet_mode_chosen, .style = SEGMENTED_STYLE }).with_id(ANIM_SHEET_MODE_ID);
								};
								if (locked) @node((StageShade) { .hint = ANIM_STAGE_HINT }).with_id(ANIM_STAGE_SHADE_ID);
							};
							key_row.with_id(ANIM_KEY_ROW_ID);
							// What the sheet shows, and the tools for the clip it belongs to.
							@tree((Wrap) { .gap_x = ANIM_GAP, .gap_y = ANIM_GAP, .cross_align = CENTER })
							{
								if (app.anim_show_curves)
								{
									@node((Segmented) { .options = anim_graph_channel_options[..], .selected = app.anim_graph_position ? 1 : 0,
										.on_change = &anim_graph_channel_chosen, .style = SEGMENTED_STYLE }).with_id(ANIM_GRAPH_CHANNEL_ID);
								}
								else
								{
									@node((ToggleButton) { .label = "Show tracks", .on = app.anim_show_tracks,
										.on_change = &anim_tracks_toggled, .style = SEGMENTED_STYLE }).with_id("anim-show-tracks");
									if (app.anim_show_tracks)
									{
										@node((Checkbox) { .label = "Focus selected joints", .checked = app.anim_tracks_selected_only,
											.on_change = &anim_tracks_selected_only_toggled, .style = CHECKBOX_STYLE })
											.with_id("anim-selected-joints-only");
									}
								}
								@node(panel_button("Clip tools ▾", &anim_tools_menu_clicked)).with_id(ANIM_TOOLS_BUTTON_ID);
							};
							if (app.anim_show_curves)
							{
								@node((AnimCurves) { }).with_id(ANIM_SHEET_SLOT_ID);
							}
							else
							{
								Element* slot = @tree((Scroll) { })
								{
									@node((AnimSheet) { .restore_focus = restore_focus }).with_id(ANIM_SHEET_ID);
								};
								slot.with_id(ANIM_SHEET_SLOT_ID);
							}
							// A library clip with joints that play nothing here says so, with
							// the way to match them.
							usz unmatched = app.unmatched_joints(app.editing);
							if (unmatched > 0)
							{
								@tree((Wrap) { .gap_x = ANIM_GAP, .gap_y = 4, .cross_align = CENTER })
								{
									@node((OwnedLabel) { .text = unmatched == 1
										? "1 joint of this animation doesn't match this character".copy(mem)
										: string::format(mem, "%d joints of this animation don't match this character", unmatched),
										.size = ANIM_TEXT_SIZE, .color = TEXT_DIM });
									@node(panel_button("Fix mapping…", &anim_fix_mapping_clicked)).with_id(ANIM_FIX_MAPPING_INLINE_ID);
								};
							}
							// Only when the check is not simply on: off, or cut back for this
							// mesh. A check that is working says nothing here.
							if (collision_status_shown(app))
							{
								@node(collision_status_line()).with_id(ANIM_COLLISION_STATUS_ID);
							}
							// The slim bar at the bottom. The pending-pose banner takes the
							// save status's place, so nothing above it moves when it appears
							// under a pose being dragged.
							if (app.pose_edit_pending)
							{
								Element* banner = @tree((Row) { .gap = ANIM_GAP, .cross_align = CENTER })
								{
									@node((Label) {
										.text = app.anim_pending_action != 0 ? "Pose changed · move again to drop it"
											: "Pose changed",
										.size = ANIM_TEXT_SIZE, .color = ACCENT });
									@node(accent_button("Key pose", &anim_pending_save)).with_id("anim-pending-save");
									@node(panel_button("Revert", &anim_pending_discard)).with_id("anim-pending-discard");
								};
								banner.with_id(ANIM_PENDING_BANNER_ID);
							}
							else
							{
								@node((Label) {
									.text = app.authored_dirty ? "Animation changes unsaved · Ctrl+S to save"
										: app.editing.pack == app.authored_pack ? "Animation keys saved with project"
										: "Library animation — your first edit makes a local copy.",
									.size = ANIM_TEXT_SIZE, .color = TEXT_DIM,
								}).with_id(ANIM_SAVE_STATUS_ID);
							}
						}
					};
				};
			};
			clip_side.with_id(ANIM_CLIP_SIDE_ID);
			@node((AnimDockDivider) { }).with_id(ANIM_DIVIDER_ID);
			// ---- the Layers column ----
			Element* layers_side = @tree((Scroll) { })
			{
				@tree((Padding) { .insets = widgets::insets_all(ANIM_PAD) })
				{
					@tree((StageGate) { .locked = locked })
					{
						@node((AnimLayerStrip) { }).with_id(ANIM_LAYERS_ID);
						if (locked && has_clip) @node((StageShade) { .hint = ANIM_STAGE_HINT });
					};
				};
			};
			layers_side.with_id(ANIM_LAYERS_SIDE_ID);
		};
	};
	dock.with_id(ANIM_DOCK_ID);
	return dock;
}

// Select owns its labels, so replacing a clip or refreshing the library cannot
// leave its borrowed option strings pointing into released animation data.
struct AnimChooser (Widget)
{
	String[] labels;
}

fn void AnimChooser.release(&self)
{
	foreach (label : self.labels) label.free(mem);
	if (self.labels.len > 0) alloc::free(mem, self.labels);
	self.labels = {};
}

fn void AnimChooser.unmount(&self, Element* elem) @dynamic => self.release();

fn Element* AnimChooser.build(&self, Element* elem) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	self.release();
	self.labels = alloc::new_array(mem, String, math::max(app.doc.animations.len(), (sz)1));
	usz selected = 0;
	if (app.doc.animations.len() == 0) self.labels[0] = "No animation".copy(mem);
	foreach (sz i, bound : app.doc.animations.array_view())
	{
		AnimRef ref = app.resolve_bound(i);
		// A binding whose source cannot be found is still listed, so it can be
		// picked and taken off the character from the clip menu.
		self.labels[i] = ref.valid() ? bound.clip.copy(mem) : string::format(mem, "%s (missing)", bound.clip);
		if (ref.same(app.editing)) selected = (usz)i;
	}
	if (app.anim_selected < self.labels.len && app.doc.animations.len() > 0
		&& !app.resolve_bound((sz)app.anim_selected).valid()) selected = app.anim_selected;
	// A rig can carry dozens of bound clips (UAL2 and friends), more than fit a
	// plain dropdown — past a handful the list gets a search field so the right
	// one is a few keystrokes away rather than a long scroll.
	bool searchable = self.labels.len > ANIM_CHOOSER_SEARCH_MIN;
	return @subtree(elem.ui)
	{
		@node((Select) { .options = self.labels, .selected = selected,
			.width = 190, .style = VIEW_MENU_STYLE, .searchable = searchable,
			.on_change = &anim_choose_clip }).with_id("anim-chooser");
	};
}

fn Vec2 AnimChooser.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	Vec2 own = elem.layout_child(0, constraints);
	elem.place_child(0, { 0, 0 });
	return own;
}

<*
 The dopesheet for the clip being edited, or the line that stands in for one.

 A wrapper around cui's `Timeline` for `EmptyStateTree`'s reason: a sheet with no lanes
 lays out flat and paints nothing, which inside a panel reads as a build that
 failed rather than as "no clip is being edited".

 The tracks come off the AppState, rebuilt whenever the clip changes — every edit
 replaces the whole `AnimTemplate`, so a lane array pointing into the old one
 would be pointing at freed keyframes.
*>
struct AnimSheet (Widget)
{
	bool restore_focus;
	Vec2 size;

	// The two arrays the `Timeline` borrows, in its own shapes. Built here from
	// `app.timeline_tracks` rather than stored on the state in this form, because
	// they are a *view* of the tracks — the widget's vocabulary, not crig's.
	TimelineLane[] lanes;
	TimelineMark[] marks;
	TimelineFlag[] flags;
	TimelineBar[] bars;
}

// Track names use the edited clip's vocabulary, while viewport selection uses
// document dot ids. Resolve that mapping once per rebuild rather than once for
// every track (and again while counting its markers).
fn void anim_selected_track_names(AppState* app, StringList* selected) @private
{
	RigView? opened = app.open_rig(mem);
	if (catch opened) return;
	RigView view = opened;
	defer view.free(mem);
	String[] names = app.names_for(&view, app.editing);
	foreach (usz i, name : names)
	{
		if (i < view.dot_ids.len && app.is_selected(view.dot_ids[i])) selected.push(name);
	}
}

fn bool anim_track_visible(bool filtering, String[] selected, String joint) @private
{
	if (!filtering) return true;
	foreach (name : selected) if (name == joint) return true;
	return false;
}

// How the key a lane shows at `at` leaves for the next one, resolved through
// the clip's blend so a legacy INHERIT key reads as the curve it plays.
fn AnimInterpolation anim_key_curve(AnimTemplate* clip, String joint, bool rotation, float at) @private
{
	if (!clip) return INHERIT;
	foreach (frame : clip.keyframes)
	{
		if (math::abs(frame.time - at) >= ANIM_SAME_TIME) continue;
		AnimKeyDot dot;
		if (frame.channel_dot(joint, rotation, &dot)) return dot.interpolation(rotation, clip.blend);
		return INHERIT;
	}
	return INHERIT;
}

// The curve every channel of a whole-pose key shares, or INHERIT for a mix.
fn AnimInterpolation anim_frame_curve(AnimTemplate* clip, AnimKeyframe frame) @private
{
	AnimInterpolation shared = INHERIT;
	foreach (dot : frame.dots)
	{
		for (int c = 0; c < 2; c++)
		{
			bool rotation = c == 0;
			if (rotation ? !dot.keys_rotation() : !dot.keys_translation()) continue;
			AnimInterpolation curve = dot.interpolation(rotation, clip.blend);
			if (shared == INHERIT) { shared = curve; }
			else if (shared != curve) { return INHERIT; }
		}
	}
	return shared;
}

fn void AnimSheet.rebuild(&self, AppState* app)
{
	self.release();
	if (app.anim_check.ran && app.anim_check.ref.same(app.editing) && app.anim_check.issues.len > 0)
	{
		self.flags = alloc::new_array(mem, TimelineFlag, app.anim_check.issues.len);
		foreach (usz i, issue : app.anim_check.issues) self.flags[i] = { .at = issue.time };
	}

	TimelineTrack[] tracks = app.timeline_tracks;
	AnimTemplate* clip = app.clip(app.editing);
	// The keys drawn: the base's, or the active keyed layer's (see `key_clip`).
	// Contacts are the clip's and stay on it either way.
	AnimTemplate* shown = app.key_clip(app.editing);
	AnimLayer* layer = app.keyed_layer_of(app.editing);
	usz contacts = clip ? contact_lane_count(clip.ground) : 0;
	// One lane per look-at target, after the contact lanes, in both views.
	usz aims = clip ? clip.aim_targets.len : 0;
	usz aim_keys = anim_aim_key_total(clip);
	if (!app.anim_show_tracks && clip)
	{
		self.lanes = alloc::new_array(mem, TimelineLane, (sz)(1 + contacts + aims));
		self.lanes[0] = { .label = layer ? layer.name : "Poses" };
		self.contact_rows(clip, 1);
		self.marks = alloc::new_array(mem, TimelineMark, (sz)(shown.keyframes.len + aim_keys));
		foreach (usz i, key : shown.keyframes)
			self.marks[i] = { .lane = 0, .at = key.time, .curve = anim_frame_curve(shown, key),
				.selected = app.animation_key_selected(app.editing, key.time) };
		self.aim_rows(app, clip, 1 + contacts, shown.keyframes.len);
		return;
	}
	if (tracks.len == 0 && aims == 0) return;
	bool filtering = app.anim_tracks_selected_only;
	StringList selected_names;
	selected_names.init(mem);
	defer selected_names.free();
	if (filtering && app.selection_count() > 0) anim_selected_track_names(app, &selected_names);
	String[] selected = selected_names.array_view();

	usz lanes = 0;
	usz total = 0;
	foreach (track : tracks)
	{
		if (!anim_track_visible(filtering, selected, track.joint)) continue;
		if (track.rotation_times.len > 0) { lanes++; total += track.rotation_times.len; }
		if (track.translation_times.len > 0) { lanes++; total += track.translation_times.len; }
	}

	self.lanes = alloc::new_array(mem, TimelineLane, (sz)(lanes + contacts + aims));
	self.marks = alloc::new_array(mem, TimelineMark, (sz)(total + aim_keys));
	if (clip) self.contact_rows(clip, 0);

	usz lane = contacts;
	usz write = 0;
	foreach (track : tracks)
	{
		if (!anim_track_visible(filtering, selected, track.joint)) continue;
		// Dimmed when the open rig has no joint answering to this name: the clip
		// drives it and this figure cannot, which is worth seeing rather than
		// hiding — it is the whole reason a borrowed clip moves less than expected.
		bool dimmed = !app.rig_answers_to(track.joint);
		if (track.rotation_times.len > 0)
		{
			self.lanes[lane] = { .label = track.joint, .trailing = "Rotation", .dimmed = dimmed,
				.joint = track.joint, .channel = ROTATION, .depth = track.depth };
			foreach (at : track.rotation_times)
			{
				self.marks[write++] = { .lane = lane, .at = at, .joint = track.joint, .channel = ROTATION,
					.curve = anim_key_curve(shown, track.joint, true, at),
					.selected = app.animation_key_selected(app.editing, at)
						|| app.animation_channel_key_selected(app.editing, at, track.joint, ROTATION) };
			}
			lane++;
		}
		if (track.translation_times.len > 0)
		{
			self.lanes[lane] = { .label = track.joint, .trailing = "Position", .dimmed = dimmed,
				.joint = track.joint, .channel = TRANSLATION, .depth = track.depth };
			foreach (at : track.translation_times)
			{
				self.marks[write++] = { .lane = lane, .at = at, .joint = track.joint, .channel = TRANSLATION,
					.curve = anim_key_curve(shown, track.joint, false, at),
					.selected = app.animation_key_selected(app.editing, at)
						|| app.animation_channel_key_selected(app.editing, at, track.joint, TRANSLATION) };
			}
			lane++;
		}
	}
	self.aim_rows(app, clip, lane, write);
}

<*
 The clip's look-at lanes from lane `first` on, and their target keys as marks
 from mark `first_mark` on.
*>
fn void AnimSheet.aim_rows(&self, AppState* app, AnimTemplate* clip, usz first, usz first_mark)
{
	if (!clip) return;
	usz lane = first;
	usz write = first_mark;
	// The lane's and marks' `joint` carry the target's name.
	foreach (&target : clip.aim_targets)
	{
		if (lane >= self.lanes.len) break;
		self.lanes[lane] = { .label = target.name, .trailing = "Look at", .dimmed = target.mute,
			.joint = target.name, .aim = true };
		foreach (key : target.keys)
		{
			if (write >= self.marks.len) break;
			self.marks[write++] = { .lane = lane, .at = key.time, .joint = target.name, .aim = true,
				.curve = key.interpolation == HOLD ? HOLD : LINEAR,
				.selected = app.animation_aim_key_selected(app.editing, target.name, key.time) };
		}
		lane++;
	}
}

<*
 The clip's contact lanes from lane `first` on, and their bars: a window
 across a loop's seam is two pieces, each open at the seam.
*>
fn void AnimSheet.contact_rows(&self, AnimTemplate* clip, usz first)
{
	AnimGround ground = clip.ground;
	foreach (usz i, foot : ground.feet)
	{
		if (contact_first_of(ground, foot.joint) != i) continue;
		usz lane = first + contact_lane_of(ground, i);
		if (lane < self.lanes.len)
		{
			self.lanes[lane] = { .label = foot.joint, .trailing = foot.off_floor ? "Hold" : "Contact",
				.joint = foot.joint, .contact = true };
		}
	}
	if (ground.feet.len == 0) return;
	float d = clip.duration;
	usz pieces = 0;
	foreach (foot : ground.feet) pieces += foot.up > foot.down ? 1 : 2;
	self.bars = alloc::new_array(mem, TimelineBar, (sz)pieces);
	usz at = 0;
	foreach (usz i, foot : ground.feet)
	{
		usz lane = first + contact_lane_of(ground, i);
		if (foot.up > foot.down)
		{
			self.bars[at++] = { .lane = lane, .from = foot.down * d, .to = foot.up * d, .window = i };
			continue;
		}
		self.bars[at++] = { .lane = lane, .from = foot.down * d, .to = d, .window = i, .open_to = true };
		self.bars[at++] = { .lane = lane, .from = 0, .to = foot.up * d, .window = i, .open_from = true };
	}
}

fn void AnimSheet.release(&self)
{
	if (self.lanes.len > 0) alloc::free(mem, self.lanes);
	if (self.marks.len > 0) alloc::free(mem, self.marks);
	if (self.flags.len > 0) alloc::free(mem, self.flags);
	if (self.bars.len > 0) alloc::free(mem, self.bars);
	self.lanes = {};
	self.marks = {};
	self.flags = {};
	self.bars = {};
}

fn void AnimSheet.unmount(&self, Element* elem) @dynamic => self.release();

fn void AnimSheet.update(&self, Element* elem, float dt) @dynamic
{
	if (elem.children.len() == 0) return;
	AppState* app = elem.inherit(AppState)!!;
	Timeline* timeline = elem.children[0].widget_as(Timeline);
	foreach (&mark : self.marks)
	{
		bool selected = mark.aim
			? app.animation_aim_key_selected(app.editing, mark.joint, mark.at)
			: mark.joint.len == 0
			? app.animation_key_selected(app.editing, mark.at)
			: app.animation_key_selected(app.editing, mark.at)
				|| app.animation_channel_key_selected(app.editing, mark.at, mark.joint, mark.channel);
		if (mark.selected != selected)
		{
			mark.selected = selected;
			elem.children[0].request_paint();
		}
	}
	float at = anim_live_time(app);
	if (timeline.playhead == at) return;
	timeline.playhead = at;
	elem.children[0].request_paint();
}

fn Element* AnimSheet.build(&self, Element* elem) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	self.rebuild(app);

	AnimTemplate* clip = app.clip(app.editing);

	TimelineStyle style = TIMELINE_STYLE;
	style.gutter_width = app.anim_show_tracks ? 184.0f : (self.bars.len > 0 ? 128.0f : 56.0f);
	Element* body = @subtree(elem.ui)
	{
		@node((Timeline) {
			.lanes = self.lanes,
			.marks = self.marks,
			.flags = self.flags,
			.on_flag = &anim_check_go,
			.bars = self.bars,
			.on_bar_edit = &anim_contact_bar_edited,
			.on_bar_add = &anim_contact_bar_added,
			.on_bar_context = &anim_contact_bar_context,
			.on_lane_context = &anim_contact_lane_context,
			.duration = clip ? clip.duration : 0.0f,
			.playhead = app.edit_time,
			// Display/snapping are independent of the stored key times and export.
			.snap = app.anim_snap_off ? 0 : 1.0f / (float)app.anim_fps,
			.fps = app.anim_fps,
			.ghost_past = app.config.show_ghosts ? app.ghost_past_span() : 0.0f,
			.ghost_future = app.config.show_ghosts ? app.ghost_future_span() : 0.0f,
			.ghost_loop = clip ? clip.loop : false,
			.zoom = math::max(app.anim_timeline_zoom, 1.0f),
			.view_start = clip ? math::clamp(app.anim_timeline_start, 0.0f,
				clip.duration - clip.duration / math::max(app.anim_timeline_zoom, 1.0f)) : 0,
			.on_view = &anim_timeline_view_changed,
			.on_scrub = &anim_seek,
			.on_mark = &anim_mark_pressed,
			.on_mark_range = &anim_mark_range,
			.on_context = &anim_key_context,
			.on_space_context = &anim_space_context,
			.on_mark_drag = &anim_mark_dragged,
			.on_cancel_drag = &anim_mark_pressed,
			.on_range = &anim_range_selected,
			.on_copy = &anim_copy_selection,
			.on_paste = &anim_paste_key_clicked,
			.on_delete = &anim_delete_selection,
			.style = style,
		});
	};
	if (self.restore_focus)
	{
		elem.ui.focused = body;
		self.restore_focus = false;
	}
	return body;
}

fn Vec2 AnimSheet.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	if (elem.children.len() == 0) return constraints.constrain({ constraints.max.x, ANIM_SHEET_EMPTY_H });

	Vec2 inner = elem.layout_child(0, constraints);
	elem.place_child(0, { 0, 0 });
	return constraints.constrain({ constraints.max.x, math::max(inner.y, ANIM_SHEET_EMPTY_H) });
}

fn void AnimSheet.paint(&self, Element* elem, Painter* painter) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	if (self.lanes.len > 0) return;

	painter.text({ TREE_STYLE.padding, TREE_STYLE.padding },
		app.editing.valid() && app.anim_show_tracks && app.anim_tracks_selected_only
			&& app.selection_count() == 0 ? "Select a joint in the viewport to show its tracks."
			: app.editing.valid() ? ANIM_SHEET_EMPTY : ANIM_SHEET_NONE,
		{ .size = TREE_STYLE.text_size, .color = TEXT_DIM });
}

<*
 The bound row the clip menu acts on, or -1: a missing binding picked in the
 chooser, otherwise the row of the clip being edited.
*>
fn sz selected_anim_row(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	usz count = (usz)app.doc.animations.len();
	if (app.anim_selected < count && !app.resolve_bound((sz)app.anim_selected).valid()) return (sz)app.anim_selected;
	sz row = app.bound_row_of(app.editing);
	if (row >= 0) return row;
	return app.anim_selected < count ? (sz)app.anim_selected : -1;
}

// The bound row that resolves to `ref`, or -1.
fn sz AppState.bound_row_of(&self, AnimRef ref)
{
	if (!ref.valid()) return -1;
	for (sz i = 0; i < self.doc.animations.len(); i++)
	{
		if (self.resolve_bound(i).same(ref)) return i;
	}
	return -1;
}


fn void anim_balance_toggled(Ui* ui, bool checked) @private
{
	AppState* app = ui.inherit(AppState)!!;
	app.balance_off = !checked;
	app.@notice(checked
		? "balance on · pulling the hips back leans the body over the pinned feet"
		: "balance off · the body stays as pulled, for a pose held up by a chair or a wall");
	app.refresh_ui();
}

fn void anim_auto_key_toggled(Ui* ui, bool checked) @private
{
	AppState* app = ui.inherit(AppState)!!;
	app.auto_key = checked;
	app.refresh_ui();
}

<*
 K keys the pose, Shift+K flips Auto-key: the dock's key row from the keyboard.
 Only where the row itself would answer — a clip open and the Pose stage — so the
 letter does nothing rather than something surprising anywhere else.
*>
fn bool animation_keying_key(Ui* ui, Key key, bool shift)
{
	if (key != Key.K) return false;
	AppState* app = ui.inherit(AppState)!!;
	if (!app.editing.valid() || app.stage != POSE_STAGE) return false;
	if (shift)
	{
		app.auto_key = !app.auto_key;
		app.@notice("Auto-key %s", app.auto_key ? "on" : "off");
		app.refresh_ui();
	}
	else
	{
		anim_key_clicked(ui);
	}
	return true;
}

fn void anim_seek(Ui* ui, float at) @private
{
	AppState* app = ui.inherit(AppState)!!;
	if (!app.editing.valid()) return;
	if (!anim_allow_navigation(ui, 1, at)) return;
	app.prepare_timeline_navigation();
	AnimTemplate* clip = app.clip(app.editing);
	if (!clip) return;
	app.edit_time = math::clamp(at, 0.0f, clip.duration);
	if (!(app.current_ref.same(app.editing) && app.scrub_to(app.edit_time)))
	{
		app.park_clip(app.editing, app.edit_time);
	}
	app.refresh_ui();
}

fn float anim_live_time(AppState* app) @private
{
	return app.animating && app.current_ref.same(app.editing) ? app.anim_time : app.edit_time;
}

fn void anim_start_clicked(Ui* ui) @private => anim_seek(ui, 0.0f);

fn void anim_end_clicked(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	AnimTemplate* clip = app.clip(app.editing);
	if (clip) anim_seek(ui, clip.duration);
}

fn void anim_prev_key_clicked(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	AnimTemplate* clip = app.key_clip(app.editing);
	if (!clip) return;
	float target = 0.0f;
	foreach (key : clip.keyframes)
	{
		if (key.time < anim_live_time(app) - 0.0001f) target = math::max(target, key.time);
	}
	anim_seek(ui, target);
}

fn void anim_next_key_clicked(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	AnimTemplate* clip = app.key_clip(app.editing);
	if (!clip) return;
	float target = clip.duration;
	foreach (key : clip.keyframes)
	{
		if (key.time > anim_live_time(app) + 0.0001f) target = math::min(target, key.time);
	}
	anim_seek(ui, target);
}

fn void anim_play_pause_clicked(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	if (!app.editing.valid()) return;
	if (!anim_allow_navigation(ui, 2)) return;
	app.prepare_timeline_navigation();
	if (app.doc.dots.len() == 0)
	{
		if (!app.play_clip(app.editing)) return;
		app.refresh_ui();
		return;
	}
	if (app.animating && app.current_ref.same(app.editing))
	{
		if (app.anim_paused) { app.resume_clip(); } else { app.pause_clip(); }
	}
	else
	{
		if (!app.park_clip(app.editing, app.edit_time)) return;
		app.resume_clip();
	}
	app.refresh_ui();
}

// Workspace shortcuts share the transport's implementation. They only claim
// the keys while a clip is open in the sheet, leaving arrows available to
// focused controls in every other workflow.
fn bool animation_transport_key(Ui* ui, Key key)
{
	AppState* app = ui.inherit(AppState)!!;
	if (!app.editing.valid()) return false;
	switch (key)
	{
		case Key.SPACE: anim_play_pause_clicked(ui);
		case Key.HOME: anim_start_clicked(ui);
		case Key.END: anim_end_clicked(ui);
		case Key.COMMA: anim_seek(ui, anim_live_time(app) - 1.0f / (float)app.anim_fps);
		case Key.PERIOD: anim_seek(ui, anim_live_time(app) + 1.0f / (float)app.anim_fps);
		case Key.LEFT_BRACKET:
		case Key.RIGHT_BRACKET:
			// Remembering an edited clip does not put the viewport in animation
			// mode: brackets still adjust skinning after leaving its preview.
			if (!app.pose_edit_active
				&& !(app.animating && app.current_ref.same(app.editing))) return false;
			if (key == Key.LEFT_BRACKET) { anim_prev_key_clicked(ui); }
			else { anim_next_key_clicked(ui); }
		default: return false;
	}
	return true;
}

<*
 Take the selected clip off the character.

 No confirmation: nothing on disk is touched, and Ctrl+Z puts the row back.
*>
fn void anim_unbind_clicked(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	if (!anim_can_rewrite(ui)) return;

	sz row = selected_anim_row(ui);
	if (row < 0)
	{
		app.@notice("pick an animation to remove from the character");
		return;
	}

	// The name moves to the undo stack with the row; copied for the notice.
	String named = app.doc.animations[row].clip.copy(mem);
	defer named.free(mem);

	if (!app.unbind_recorded(row)) return;
	app.@notice("removed %s from the character · Ctrl+Z puts it back", named);
	app.refresh_ui();
}

<*
 Move the selected clip through the list.

 Order is the user's and an export walks it, so this is not decoration: it is how
 the first animation in a shipped file gets to be the idle rather than whichever
 one happened to be bound first.

 The selection follows the moved row — see the comment in the body.
*>
fn void move_selected_anim(Ui* ui, sz step) @private
{
	AppState* app = ui.inherit(AppState)!!;

	sz row = selected_anim_row(ui);
	if (row < 0)
	{
		app.@notice("pick an animation to move");
		return;
	}

	sz to = row + step;
	if (to < 0 || to >= app.doc.animations.len()) return;
	// Recorded, and the rows rebuilt with it: reordering changes no count, and
	// `AnimSnapshot` deliberately only watches the shape.
	if (!app.reorder_bound_recorded(row, to)) return;

	// The selection follows the row rather than staying at the index, or holding
	// the button would walk the list past the clip being moved. On the state, so it
	// survives the next rebuild and reaches a second pane showing the same list.
	app.anim_selected = (usz)to;
	refresh_animations_view(ui);
	app.refresh_ui();
}

// ---------------------------------------------------------------------------
// The sheet's own callbacks

<*
 Rebuild the tracks for whatever is being edited, and put it on screen at the
 playhead.

 Called after anything that changes the clip. The park is what makes the figure
 show the edit: a rewritten clip is a different `AnimTemplate`, and the player is
 holding a copy of the old one.
*>
fn void AppState.show_edited(&self)
{
	self.refresh_timeline_tracks(self.editing);
	if (self.editing.valid()) self.park_clip(self.editing, self.edit_time);
	self.refresh_ui();
}

<*
 Start editing the bound clip at `anim_selected`, the row the chooser picked.
*>
fn void anim_edit_selected(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;

	if (app.anim_selected >= (usz)app.doc.animations.len()) return;
	sz row = (sz)app.anim_selected;

	AnimRef ref = app.resolve_bound(row);
	if (!ref.valid()) return;

	if (!anim_allow_navigation(ui, 3, 0, (usz)row)) return;
	app.prepare_timeline_navigation();
	if (!app.editing.same(ref)) app.clear_animation_key_selection();
	app.editing = ref;
	app.edit_time = 0.0f;
	app.show_edited();
}

<*
 A key was pressed: put the playhead on it.

 Selecting a key and scrubbing to it are the same gesture here, which is what
 makes "click the key, look at the pose" one action rather than two.
*>
fn void anim_mark_pressed(Ui* ui, TimelineMark mark, bool toggle) @private
{
	AppState* app = ui.inherit(AppState)!!;

	float at = mark.at;
	if (at < 0.0f) return;

	// A look-at key is the aim's, not a pose key: select it and show where it is.
	if (mark.aim)
	{
		bool held = app.animation_aim_key_selected(app.editing, mark.joint, at);
		app.select_animation_aim_key(app.editing, mark.joint, at, additive: toggle || held, toggle: toggle);
		app.anim_key_anchor = at;
		anim_seek(ui, at);
		return;
	}

	// A plain press starts a new selection, except on a key already in the
	// selection: keeping that set intact is what lets the following drag move it.
	bool channel = mark.joint.len > 0;
	bool already = channel
		? app.animation_channel_key_selected(app.editing, at, mark.joint, mark.channel)
		: app.animation_key_selected(app.editing, at);
	if (channel)
	{
		app.select_animation_channel_key(app.editing, at, mark.joint, mark.channel,
			additive: toggle || already, toggle: toggle);
	}
	else { app.select_animation_key(app.editing, at, additive: toggle || already, toggle: toggle); }
	// This key becomes the anchor a following Ctrl+Shift press measures its span from.
	app.anim_key_anchor = at;
	anim_seek(ui, at);
}

<*
 Ctrl+Shift on a key: select every key from the anchor — the last key clicked —
 through this one, so "click frame 1, Ctrl+Shift-click frame 30" marks the whole
 span, the keys between included. Additive, so it widens a selection rather than
 replacing it, and the anchor stays put so the range can be re-aimed by pressing
 another key.

 With no anchor yet (nothing clicked in this clip), it falls back to a plain
 press: this key is selected and becomes the anchor for the next Ctrl+Shift press.
*>
fn void anim_mark_range(Ui* ui, TimelineMark mark) @private
{
	AppState* app = ui.inherit(AppState)!!;
	float at = mark.at;
	if (at < 0.0f) return;
	if (mark.aim)
	{
		if (app.animation_aim_key_selection_count(app.editing) > 0 && app.anim_key_anchor >= 0.0f)
		{
			app.select_animation_aim_keys_between(app.editing, mark.joint, app.anim_key_anchor, at, additive: true);
			anim_seek(ui, at);
			return;
		}
		anim_mark_pressed(ui, mark, false);
		return;
	}
	if (!app.anim_key_selection_ref.same(app.editing) || app.anim_key_anchor < 0.0f)
	{
		anim_mark_pressed(ui, mark, false);
		return;
	}
	// A channel row selects that lane's own keys across the span; the summary
	// Poses row selects whole-pose keys. Either way the anchor is a time, so the
	// span reads the same whichever key opened it.
	if (mark.joint.len > 0)
	{
		app.select_animation_channel_keys_between(app.editing, mark.joint, mark.channel,
			app.anim_key_anchor, at, additive: true);
	}
	else
	{
		app.select_animation_keys_between(app.editing, app.anim_key_anchor, at, additive: true);
	}
	anim_seek(ui, at);
}

fn void anim_range_selected(Ui* ui, TimelineLane[] lanes, usz first_lane, usz last_lane,
	float from, float to, bool additive) @private
{
	AppState* app = ui.inherit(AppState)!!;
	if (!app.anim_show_tracks)
	{
		app.select_animation_keys_between(app.editing, from, to, additive: additive);
	}
	else
	{
		if (!additive) app.clear_animation_key_selection();
		for (usz lane = first_lane; lane <= last_lane && lane < lanes.len; lane++)
		{
			if (lanes[lane].contact || lanes[lane].aim) continue;
			app.select_animation_channel_keys_between(app.editing, lanes[lane].joint,
				lanes[lane].channel, from, to, additive: true);
		}
	}
	// Look-at keys are only picked when no pose key was, as the two never mix.
	bool poses = app.animation_key_selection_count(app.editing) > 0
		|| app.animation_channel_key_selection_count(app.editing) > 0;
	if (!poses)
	{
		bool first = !additive;
		for (usz lane = first_lane; lane <= last_lane && lane < lanes.len; lane++)
		{
			if (!lanes[lane].aim) continue;
			app.select_animation_aim_keys_between(app.editing, lanes[lane].joint, from, to,
				additive: !first || additive);
			first = false;
		}
	}
	// So a Ctrl+Shift press after a box drag extends from where the box opened.
	app.anim_key_anchor = math::min(from, to);
	app.refresh_ui();
}

<*
 A key is being dragged, and on release it lands.

 Nothing is written until `done`: the live half only moves the playhead, so the
 figure follows the drag, and the clip is rewritten once — which is what keeps a
 drag one undo entry instead of one per pixel.
*>
fn void anim_mark_dragged(Ui* ui, TimelineMark mark, float to, bool done) @private
{
	AppState* app = ui.inherit(AppState)!!;
	// Retiming a look-at key by dragging is not built; leave it where it is.
	if (mark.aim) return;
	if (!anim_allow_navigation(ui, 1, to)) return;
	app.prepare_timeline_navigation();

	app.edit_time = to;
	if (!done)
	{
		anim_seek(ui, to);
		return;
	}

	AnimTemplate* clip = app.key_clip(app.editing);
	if (!clip) return;

	sz key = app.key_near(app.editing, mark.at, ANIM_SAME_TIME);
	if (key < 0) return;
	float delta = to - clip.keyframes[key].time;
	if (math::abs(delta) < ANIM_SAME_TIME) return;

	if (app.move_selected_animation_keys(app.editing, delta))
	{
		app.show_edited();
	}
	else
	{
		app.@notice("Selected keys cannot move there without leaving the clip or overlapping another key.");
		anim_seek(ui, clip.keyframes[key].time);
	}
}

fn void anim_copy_selection(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	app.copy_selected_animation_keys(app.editing);
}

// Pasting keeps its channel granularity. If that granularity cannot be shown in
// the active view, drop only the selection: retaining it would let the next
// delete act on invisible keys, while promoting it would broaden that delete.
fn void anim_normalize_selection_for_view(AppState* app)
{
	bool channels_shown = app.anim_show_tracks || app.anim_show_curves;
	bool invisible_channels = !channels_shown
		&& app.animation_channel_key_selection_count(app.editing) > 0;
	bool invisible_poses = channels_shown
		&& app.animation_key_selection_count(app.editing) > 0;
	if (invisible_channels || invisible_poses)
	{
		app.clear_animation_key_selection();
		return;
	}
	if ((app.anim_show_tracks && app.anim_tracks_selected_only) || app.anim_show_curves)
	{
		StringList visible;
		visible.init(mem);
		defer visible.free();
		anim_selected_track_names(app, &visible);
		foreach (selected : app.anim_channel_key_selection)
		{
			if (!anim_track_visible(true, visible.array_view(), selected.joint))
			{
				app.clear_animation_key_selection();
				break;
			}
		}
	}
}

fn void anim_delete_selection(Ui* ui) @private
{
	if (!anim_can_rewrite(ui)) return;
	AppState* app = ui.inherit(AppState)!!;
	if (app.delete_selected_animation_keys(app.editing)) app.show_edited();
}

// ---------------------------------------------------------------------------
// The buttons under the sheet

fn void anim_key_clicked(Ui* ui) @private
{
	anim_key_scope(ui, ALL);
}

fn void anim_key_selected_clicked(Ui* ui) @private
{
	anim_key_scope(ui, SELECTED);
}

<*
 Rest pose: shows the mesh in its rest shape without touching the clip.

 Now that editing a joint keeps the pose on screen — a moving rig dot no longer
 drops the body to rest — this is the deliberate way to get the default pose back
 when you want it. `stop_deformed_display` drops the palette and any unsaved
 draft, so the body returns to rest, while every saved keyframe stays exactly as
 it was: the clip is still selected in the timeline, and scrubbing or Play brings
 the pose straight back. Unkeyed posing is what Key pose beside this button is
 for, and a pending change has to be keyed or reverted first.
*>
fn void anim_reset_pose_clicked(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	// It would drop an unkeyed pose with it; the banner's Key pose or Revert first.
	if (!anim_can_rewrite(ui)) return;
	if (!app.skinned())
	{
		app.@notice("already showing the rest pose");
		return;
	}
	app.stop_deformed_display();
	app.@notice("showing the rest pose · the animation is unchanged; scrub or play to see it again");
	app.refresh_ui();
}

fn void anim_key_changed_clicked(Ui* ui) @private
{
	anim_key_scope(ui, CHANGED);
}

fn void anim_key_scope(Ui* ui, AnimKeyScope scope) @private
{
	AppState* app = ui.inherit(AppState)!!;
	if (!app.editing.valid())
	{
		app.@notice("pick an animation to key into, or press + New");
		return;
	}

	if (app.animating && !app.anim_paused) anim_seek(ui, anim_live_time(app));

	if (app.pose_edit_active)
	{
		if (!app.key_pose_edit(scope)) return;
	}
	else
	{
		if (scope == CHANGED)
		{
			app.@notice("no unkeyed pose changes");
			return;
		}
		AnimRef landed = app.key_here(app.editing, app.edit_time, scope);
		if (!landed.valid()) return;
		app.editing = landed;
	}
	app.@notice("keyed the pose at %.2fs", app.edit_time);
	if (!app.pose_edit_active) app.show_edited();
}

fn void anim_new_clip_clicked(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	if (!anim_allow_navigation(ui, 4)) return;
	if (app.doc.dots.len() == 0)
	{
		app.@notice("Add a skeleton before creating an animation.");
		return;
	}
	app.anim_edit_properties = false;
	if (try Element* dialog = ui.find_id("anim-new-dialog")) dialog.widget_as(Dialog).title = "Create animation";
	set_dialog_open(ui, "anim-new-dialog", true);
}

fn void anim_close_loop_clicked(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	if (!anim_can_rewrite(ui)) return;

	AnimTemplate* clip = app.clip(app.editing);
	if (!clip)
	{
		app.@notice("pick an animation to edit first");
		return;
	}
	if (!clip.loop)
	{
		app.@notice("%s does not loop, so it has no seam to close", clip.name);
		return;
	}

	usz before = clip.keyframes.len;
	app.editing = app.land_clip(app.editing, clip_seam_closed(mem, *clip));

	AnimTemplate* after = app.clip(app.editing);
	app.@notice(after && after.keyframes.len > before
		? "restated the opening pose at the end — the loop no longer jumps"
		: "the loop already closes on itself");
	app.show_edited();
}

fn void anim_mirror_clicked(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	if (!anim_can_rewrite(ui)) return;

	AnimTemplate* clip = app.clip(app.editing);
	if (!clip)
	{
		app.@notice("pick an animation to edit first");
		return;
	}

	// `mirror_template` fills in the other side from the one that was authored,
	// which is what makes a walk out of half a walk — the commonest reason a
	// hand-keyed cycle is twice the work it needs to be.
	//
	// Under its own name, so it replaces the clip rather than making a second
	// one: this is an edit to what is being worked on, and `put_authored_clip` is
	// an upsert. Half a cycle behind, which is what a walk and a run both are —
	// anything else is a phase somebody has to think about, and the button is for
	// the case nobody should have to.
	String named = clip.name.copy(mem);
	defer named.free(mem);
	app.editing = app.land_clip(app.editing, mirror_template(mem, *clip, named, 0.5f));
	app.@notice("filled in the other side of %s, half a cycle behind", named);
	app.show_edited();
}
