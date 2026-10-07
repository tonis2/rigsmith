<*
 The selected joint's small, contextual editor inside the 3D view.

 This is deliberately an overlay rather than another permanent pane. Assets
 keeps the useful right-hand pane, Animation keeps the wide bottom timeline, and
 this small card floats in the 3D view. It follows Blender's N-panel: a vertical
 rail on the right selects Joint or Align, N toggles the selected category, and
 clicking the active tab closes its body. The rail stays visible so every panel
 can be opened with the mouse. Each category keeps its own disclosure state.
 Open with no joint selected the Joint panel prompts for one rather than
 vanishing. The card is assembled from cui's Button, Column, PopupPanel, Grid,
 TextField and Checkbox widgets plus the rotation dials of `joint_dials.c3`;
 this widget owns only the document-specific rebuilding and icon painting.

 Pose and limits are two separate transactions. Rotation fields edit the pose
 currently shown at the playhead and follow Auto-key/manual Save pose. Rotation
 limits write rig metadata through their own one-entry undo operation and never
 key a clip.

 The name is a third, and the smallest. A name is the only handle anything in
 crig has on a joint — clips address one by name (`AnimKeyframe.rotation_of`),
 body plans claim one by name, and the rig settings a `.glb` carries in its
 `extras` are keyed by name — so a dot with none is invisible to all three at
 once. The title of this card is that name, and the button beside it turns the
 title into a field: Return puts the name on the dot through `AppState.rename`,
 which commits, so one Ctrl+Z takes it back; Escape or Cancel drops it. The
 field is the selected dot's, the way everything on this card is: selecting
 another dot rebuilds the card for that one and the half-typed name goes with
 the old card, written nowhere. It used to be a panel of its own on R, and R is
 now only the turn — a rename lives where the dot's other facts already are.

 Names are not required to be unique and are not made so here: `rename_dot` says
 why (swapping two names has to be reachable one edit at a time), and a
 collision is reported afterwards rather than refused, which is the same bargain
 the rest of the card strikes.
*>
module crig;

import cui;
import cui::widgets;
import rig;
import std::core::string;
import std::math;
import std::math::quaternion;

const String JOINT_PANEL_ID = "joint-panel";
const String JOINT_PIN_FROM_ID = "joint-pin-from";
const String JOINT_PIN_TO_ID = "joint-pin-to";
const String JOINT_PIN_BLEND_ID = "joint-pin-blend";
const String JOINT_TAB_JOINT_ID = "joint-tab-joint";
const String JOINT_TAB_ALIGN_ID = "joint-tab-align";
const String JOINT_TAB_WEIGHTS_ID = "joint-tab-weights";
const String JOINT_TAB_POSE_ID = "joint-tab-pose";
const String WEIGHTS_SECTION_ID = "weights-section";
const String WEIGHTS_PART_ID = "weights-part";
const String WEIGHTS_GROW_ID = "weights-grow";
const String WEIGHTS_CLEAR_ID = "weights-clear";
const String WEIGHTS_BRUSH_ID = "weights-brush";
const String WEIGHTS_INVERT_ID = "weights-invert";
const String WEIGHTS_SHRINK_ID = "weights-shrink";
const String WEIGHTS_SOFT_ID = "weights-soft";
const String WEIGHTS_MIRROR_ID = "weights-mirror";
const String WEIGHTS_APPLY_ID = "weights-apply";
const String WEIGHTS_RESET_ID = "weights-reset";
const String WEIGHTS_READOUT_ID = "weights-readout";

// The Part selector's rows, in `AreaPart` order.
String[3] weights_part_labels = { "Own bone", "With children", "UV islands" };
const String JOINT_SECTION_ID = "joint-section";
const String ALIGN_SECTION_ID = "align-section";
const String JOINT_RENAME_ID = "joint-rename";
const String JOINT_NAME_FIELD_ID = "joint-name-field";
const String JOINT_PRIMARY_CHILD_ID = "joint-primary-child";
const String JOINT_LIMITS_ACTIVE_ID = "joint-limits-active";
const String JOINT_LIMITS_RESET_ID = "joint-limits-reset";
const String JOINT_LIMIT_X_ALLOW_ID = "joint-limit-x-allow";
const String JOINT_LIMIT_Y_ALLOW_ID = "joint-limit-y-allow";
const String JOINT_LIMIT_Z_ALLOW_ID = "joint-limit-z-allow";
const String JOINT_ROTATION_X_ID = "joint-rotation-x";
const String JOINT_ROTATION_Y_ID = "joint-rotation-y";
const String JOINT_ROTATION_Z_ID = "joint-rotation-z";
const String JOINT_LIMIT_X_MIN_ID = "joint-limit-x-min";
const String JOINT_LIMIT_X_MAX_ID = "joint-limit-x-max";
const String JOINT_LIMIT_Y_MIN_ID = "joint-limit-y-min";
const String JOINT_LIMIT_Y_MAX_ID = "joint-limit-y-max";
const String JOINT_LIMIT_Z_MIN_ID = "joint-limit-z-min";
const String JOINT_LIMIT_Z_MAX_ID = "joint-limit-z-max";

// Per-axis tables for the rotation fields and the limit grid, indexed by
// `JointRotationAxis`, so each row is written once and looped.
const String[3] JOINT_ROTATION_CAPTIONS = { "X · degrees", "Y · degrees", "Z · degrees" };
const String[3] JOINT_ROTATION_IDS = { JOINT_ROTATION_X_ID, JOINT_ROTATION_Y_ID, JOINT_ROTATION_Z_ID };
const OnSubmit[3] JOINT_ROTATION_ENTRIES = {
	&joint_rotation_x_entered, &joint_rotation_y_entered, &joint_rotation_z_entered };
const String[3] JOINT_LIMIT_ALLOW_IDS = { JOINT_LIMIT_X_ALLOW_ID, JOINT_LIMIT_Y_ALLOW_ID, JOINT_LIMIT_Z_ALLOW_ID };
const String[3] JOINT_LIMIT_MIN_IDS = { JOINT_LIMIT_X_MIN_ID, JOINT_LIMIT_Y_MIN_ID, JOINT_LIMIT_Z_MIN_ID };
const String[3] JOINT_LIMIT_MAX_IDS = { JOINT_LIMIT_X_MAX_ID, JOINT_LIMIT_Y_MAX_ID, JOINT_LIMIT_Z_MAX_ID };
const OnToggle[3] JOINT_LIMIT_ALLOWED = {
	&joint_limit_x_allowed, &joint_limit_y_allowed, &joint_limit_z_allowed };
const OnSubmit[3] JOINT_LIMIT_MIN_ENTERED = {
	&joint_limit_x_min_entered, &joint_limit_y_min_entered, &joint_limit_z_min_entered };
const OnSubmit[3] JOINT_LIMIT_MAX_ENTERED = {
	&joint_limit_x_max_entered, &joint_limit_y_max_entered, &joint_limit_z_max_entered };

const float JOINT_PANEL_W = 306.0f;
const float JOINT_SECTION_W = JOINT_PANEL_W + 20.0f;
const float JOINT_SIDEBAR_W = JOINT_SECTION_W + 16.0f;
const float JOINT_PANEL_GAP = 8.0f;
const float JOINT_TAB_W = 46.0f;
const float JOINT_TAB_H = 54.0f;
const float JOINT_TAB_GAP = 4.0f;
const float JOINT_TAB_TEXT = 11.0f;
const float JOINT_TAB_STROKE = 1.6f;
// What the card's width leaves beside the Rename and Cancel buttons, less a
// little: a Row squeezes its last child into whatever is left, and a Cancel
// button squeezed to half its label is what a field sized to the exact
// remainder gets. Wide enough for the longest name a body plan uses —
// `shoulder_L` and friends — with room to see it is not truncated.
const float JOINT_NAME_FIELD_W = 128.0f;
// The three rotation columns: a dial over a degree field, one per axis.
const float JOINT_ROTATION_CELL_W = 98.0f;
const float JOINT_PANEL_CELL_W = 72.0f;
const float JOINT_PANEL_CELL_H = 26.0f;
const float JOINT_PANEL_GRID_GAP = 6.0f;

const PopupPanel JOINT_PANEL_SURFACE = {
	.style = {
		.color = PANEL,
		.border_color = PANEL_BORDER,
		.border_width = 1.0f,
		.border_radius = R8,
	},
	.insets = { 8.0f, 8.0f, 8.0f, 8.0f },
	.shadow = 8.0f,
	.shadow_color = { 0, 0, 0, 0.35f },
};

const DisclosureStyle JOINT_SECTION_STYLE = {
	.background = PANEL,
	.header = BTN,
	.header_hover = BTN_HOVER,
	.border = PANEL_BORDER,
	.text = TEXT,
	.mark = TEXT_DIM,
	.radius = R8,
	.header_height = 32.0f,
	.text_size = 14.0f,
	.padding = 10.0f,
	.gap = JOINT_PANEL_GAP,
	.border_width = 1.0f,
};

// The rail is built from ordinary CUI Buttons. Only this face is crig-specific:
// the tiny bone/alignment glyphs have no icon font to come from.
struct JointPanelTabFace (Widget)
{
	JointPanelTab tab;
	bool active;
}

fn Vec2 JointPanelTabFace.layout(&self, Element* elem, Constraints constraints) @dynamic
	=> constraints.constrain({ JOINT_TAB_W, JOINT_TAB_H });

fn void JointPanelTabFace.paint(&self, Element* elem, Painter* painter) @dynamic
{
	Color ink = self.active ? TEXT : TEXT_DIM;
	Color glyph = self.active ? ACCENT : TEXT_DIM;
	float cx = elem.size.x * 0.5f;

	if (self.active)
	{
		painter.rect({ 0, 7.0f }, { 2.0f, elem.size.y - 14.0f }, {
			.color = ACCENT,
			.border_radius = { 1.0f, 1.0f, 1.0f, 1.0f },
		});
	}

	switch (self.tab)
	{
		case JOINT:
			Vec2 a = { cx - 6.0f, 13.0f };
			Vec2 b = { cx + 6.0f, 21.0f };
			painter.line(a, b, JOINT_TAB_STROKE, glyph);
			painter.circle(a, 3.2f, { .border_width = JOINT_TAB_STROKE, .border_color = glyph });
			painter.circle(b, 3.2f, { .border_width = JOINT_TAB_STROKE, .border_color = glyph });
		case ALIGN:
			float left = cx - 7.0f;
			painter.line({ left, 10.0f }, { left, 24.0f }, JOINT_TAB_STROKE, glyph);
			painter.line({ left, 12.0f }, { cx + 7.0f, 12.0f }, JOINT_TAB_STROKE, glyph);
			painter.line({ left, 17.0f }, { cx + 3.0f, 17.0f }, JOINT_TAB_STROKE, glyph);
			painter.line({ left, 22.0f }, { cx + 9.0f, 22.0f }, JOINT_TAB_STROKE, glyph);
		case WEIGHTS:
			painter.circle({ cx, 17.0f }, 7.0f, { .border_width = JOINT_TAB_STROKE, .border_color = glyph });
			painter.circle({ cx + 1.5f, 18.5f }, 3.5f, { .color = glyph });
		case POSE:
			// A stick figure with one arm raised: head, spine, arms, legs.
			painter.circle({ cx, 9.0f }, 2.8f, { .border_width = JOINT_TAB_STROKE, .border_color = glyph });
			painter.line({ cx, 12.0f }, { cx, 20.0f }, JOINT_TAB_STROKE, glyph);
			painter.line({ cx - 6.0f, 16.0f }, { cx, 14.0f }, JOINT_TAB_STROKE, glyph);
			painter.line({ cx, 14.0f }, { cx + 5.0f, 9.0f }, JOINT_TAB_STROKE, glyph);
			painter.line({ cx, 20.0f }, { cx - 4.0f, 26.0f }, JOINT_TAB_STROKE, glyph);
			painter.line({ cx, 20.0f }, { cx + 4.0f, 26.0f }, JOINT_TAB_STROKE, glyph);
	}

	String label = "Joint";
	if (self.tab == JointPanelTab.ALIGN) label = "Align";
	if (self.tab == JointPanelTab.WEIGHTS) label = "Weights";
	if (self.tab == JointPanelTab.POSE) label = "Pose";
	Vec2 text = elem.ui.text.measure(0, label, JOINT_TAB_TEXT);
	painter.text({ (elem.size.x - text.x) * 0.5f, 34.0f }, label, {
		.size = JOINT_TAB_TEXT,
		.color = ink,
	});
}

fn Button joint_panel_tab_button(bool active, OnClick on_click) @private
{
	Color fill = active ? BTN_HOVER : BTN;
	return {
		.size = { JOINT_TAB_W, JOINT_TAB_H },
		.style = {
			.color = fill,
			.border_color = active ? ACCENT : PANEL_BORDER,
			.border_width = 1.0f,
			.border_radius = R8,
		},
		.hover_style = {
			.color = BTN_HOVER,
			.border_color = active ? ACCENT : PANEL_BORDER,
			.border_width = 1.0f,
			.border_radius = R8,
		},
		.press_style = { .color = BTN_PRESS, .border_radius = R8 },
		.on_click = on_click,
	};
}

struct JointPanelSnapshot
{
	uint selected;
	uint renaming;
	usz dots;
	usz edges;
	uint rig_generation;
	uint revision;
	bool animating;
	bool paused;
	bool pose_edit_active;
	bool pose_edit_pending;
	uint drag_dot;
	float edit_time;
	int current_pack;
	int current_clip;
	int edit_pack;
	int edit_clip;
	bool show_joint_panel;
	JointPanelTab tab;
	bool joint_info_collapsed;
	bool align_info_collapsed;
	bool weights_info_collapsed;
	bool pose_info_collapsed;
	bool pose_options_collapsed;
	bool pose_library_collapsed;
	// What the Pose tab lists: the balance switch, the pins, the saved poses.
	bool balance_off;
	uint locks_hash;
	usz poses;
	usz pose_row;
	bool pose_renaming;
	bool pose_selected_only;
	usz selection_count;
	bool areaing;
	bool brushing;
	uint area_generation;
}

fn JointPanelSnapshot joint_panel_snapshot(AppState* app) @private
{
	return {
		.selected = app.selected,
		.renaming = app.renaming_dot,
		.dots = (usz)app.doc.dots.len(),
		.edges = (usz)app.doc.edges.len(),
		.rig_generation = app.rig_generation,
		.revision = app.undo_stack.revision,
		.animating = app.animating,
		.paused = app.anim_paused,
		.pose_edit_active = app.pose_edit_active,
		.pose_edit_pending = app.pose_edit_pending,
		.drag_dot = app.drag.dot,
		.edit_time = app.edit_time,
		.current_pack = app.current_ref.pack,
		.current_clip = app.current_ref.clip,
		.edit_pack = app.editing.pack,
		.edit_clip = app.editing.clip,
		.show_joint_panel = app.show_joint_panel,
		.tab = app.joint_panel_tab,
		.joint_info_collapsed = app.joint_info_collapsed,
		.align_info_collapsed = app.align_info_collapsed,
		.weights_info_collapsed = app.weights_info_collapsed,
		.pose_info_collapsed = app.pose_info_collapsed,
		.pose_options_collapsed = app.pose_options_collapsed,
		.pose_library_collapsed = app.pose_library_collapsed,
		.balance_off = app.balance_off,
		.locks_hash = lock_list_hash(app),
		.poses = app.doc.poses.len,
		.pose_row = app.pose_library_row,
		.pose_renaming = app.pose_library_renaming,
		.pose_selected_only = app.pose_library_selected_only,
		.selection_count = app.selection_count(),
		.areaing = app.areaing,
		.brushing = app.brushing,
		.area_generation = app.area_generation,
	};
}

fn bool JointPanelSnapshot.differs(self, JointPanelSnapshot other)
{
	return self.selected != other.selected || self.renaming != other.renaming
		|| self.dots != other.dots
		|| self.edges != other.edges || self.rig_generation != other.rig_generation
		|| self.revision != other.revision
		|| self.animating != other.animating || self.paused != other.paused
		|| self.pose_edit_active != other.pose_edit_active
		|| self.pose_edit_pending != other.pose_edit_pending
		|| self.drag_dot != other.drag_dot || self.edit_time != other.edit_time
		|| self.current_pack != other.current_pack || self.current_clip != other.current_clip
		|| self.edit_pack != other.edit_pack || self.edit_clip != other.edit_clip
		|| self.show_joint_panel != other.show_joint_panel
		|| self.tab != other.tab
		|| self.joint_info_collapsed != other.joint_info_collapsed
		|| self.align_info_collapsed != other.align_info_collapsed
		|| self.weights_info_collapsed != other.weights_info_collapsed
		|| self.pose_info_collapsed != other.pose_info_collapsed
		|| self.pose_options_collapsed != other.pose_options_collapsed
		|| self.pose_library_collapsed != other.pose_library_collapsed
		|| self.balance_off != other.balance_off
		|| self.locks_hash != other.locks_hash
		|| self.poses != other.poses
		|| self.pose_row != other.pose_row
		|| self.pose_renaming != other.pose_renaming
		|| self.pose_selected_only != other.pose_selected_only
		|| self.selection_count != other.selection_count
		|| self.areaing != other.areaing
		|| self.brushing != other.brushing
		|| self.area_generation != other.area_generation;
}

struct JointPanel (Widget)
{
	JointPanelSnapshot shown;
	char[320] readout; // the Weights card's readout line, held for the label to borrow
	String[] child_labels;
	uint[] child_ids;
}

fn void JointPanel.release_choices(&self)
{
	foreach (label : self.child_labels) if (label.len > 0) alloc::free(mem, label.ptr);
	if (self.child_labels.len > 0) alloc::free(mem, self.child_labels);
	if (self.child_ids.len > 0) alloc::free(mem, self.child_ids);
	self.child_labels = {};
	self.child_ids = {};
}

fn void JointPanel.unmount(&self, Element* elem) @dynamic => self.release_choices();

fn void JointPanel.update(&self, Element* elem, float dt) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	// A dial drag changes the snapshot on its first move and on every one after,
	// and a rebuild here would destroy the dial being held — taking the pointer
	// capture with it, so the drag would end a frame after it began. The dial
	// keeps its own numbers live; the card catches up on the release.
	if (app.drag.dial) return;
	// The name field is the selected dot's. Once the selection has moved on, the
	// field would be rebuilt on the new dot's card holding the old dot's name —
	// and Return there would put it on the wrong joint — so the rename ends with
	// the card it was opened on, written nowhere.
	if (app.renaming_dot != 0 && app.renaming_dot != app.selected) app.renaming_dot = 0;
	JointPanelSnapshot now = joint_panel_snapshot(app);
	if (!now.differs(self.shown)) return;
	self.shown = now;
	elem.request_build();
}

<*
 Escape while the name field is up drops the rename and nothing else.

 The field lets Escape through on purpose, and left to bubble it would reach
 `AppRoot.on_key`, whose reading of a bare Escape is "clear the selection" —
 which would take the card away along with the field. Here it stops one level
 up, where "cancel" can mean the field alone. Every other key falls through,
 so the card being the focus after a click on it changes nothing for the
 shortcuts.
*>
fn bool JointPanel.on_key(&self, Element* elem, KeyEvent event) @dynamic
{
	if (!event.down || event.key != Key.ESCAPE) return false;
	AppState* app = elem.inherit(AppState)!!;
	if (app.renaming_dot == 0) return false;
	app.renaming_dot = 0;
	elem.request_build();
	return true;
}

fn void refresh_joint_panel(Ui* ui)
{
	ui.@each(JointPanel; panel) { panel.request_build(); };
}

fn PosedJoint joint_panel_pose(AppState* app, RigView* view, uint id) @private
{
	if (app.pose_edit_active) return app.working_pose(id);

	// A running clip already built this exact pose for the frame on screen — read
	// the joint out of it rather than sampling the whole clip again for one value.
	// Only while the clock runs: a paused or scrubbed pose is sampled fresh below
	// so an edit begins from the untouched authored value, not a grounded one.
	if (app.animating && !app.anim_paused && app.player_pose_live)
	{
		sz cached = view.joint_of(id);
		if (cached >= 0 && (usz)cached < app.player_pose.rotations.len)
		{
			return {
				.dot_id = id,
				.rotation = app.player_pose.rotations[(usz)cached],
				.offset = app.player_pose.offsets[(usz)cached],
			};
		}
	}

	AnimRef shown = app.animating ? app.current_ref : app.editing;
	AnimTemplate* clip = app.clip(shown);
	if (!clip) return { .dot_id = id, .rotation = quaternion::IDENTITY };

	float at = shown.same(app.editing) ? app.edit_time : app.anim_time;
	rig::Pose pose = app.evaluated_clip_pose(mem, view, *clip, shown, at, false);
	defer pose.free(mem);
	sz joint = view.joint_of(id);
	if (joint < 0 || (usz)joint >= pose.rotations.len)
	{
		return { .dot_id = id, .rotation = quaternion::IDENTITY };
	}
	return {
		.dot_id = id,
		.rotation = pose.rotations[(usz)joint],
		.offset = pose.offsets[(usz)joint],
	};
}

fn String joint_pose_note(AppState* app) @private
{
	if (app.animating && !app.anim_paused) return "Pause playback to edit this pose.";
	if (app.animating && !app.current_ref.same(app.editing)) return "Open this animation in the timeline to edit it.";
	if (app.editing.valid() || app.animating || app.pose_edit_active)
	{
		return app.auto_key
			? "Auto-key saves a key at the playhead."
			: "Changes wait for Key pose.";
	}
	return "Choose an animation to pose this joint.";
}

fn String joint_frame_note(JointLimitFrameStatus status) @private
{
	switch (status)
	{
		case READY: return "";
		case NEEDS_PRIMARY_CHILD: return "Choose which child defines the bone axes.";
		case PRIMARY_CHILD_INVALID: return "Choose a valid child for the bone axes.";
		case ZERO_LENGTH: return "This bone has zero length; local axes are unavailable.";
		case NO_DIRECTION: return "This joint has no bone direction for local axes.";
		case INVALID_SAVED_FRAME: return "The saved bone-axis frame is invalid.";
		case JOINT_NOT_FOUND: return "This joint is no longer in the rig.";
	}
}

fn void JointPanel.collect_child_choices(&self, AppState* app, RigView* view, usz joint)
{
	usz count = 0;
	foreach (usz i, int parent : view.skeleton.parents)
	{
		if (parent != (int)joint) continue;
		if ((view.skeleton.joints[i] - view.skeleton.joints[joint]).length_sq() <= LIMIT_FRAME_EDGE_SQ) continue;
		count++;
	}
	if (count < 2) return;

	self.child_labels = alloc::new_array(mem, String, (sz)count + 1);
	self.child_ids = alloc::new_array(mem, uint, (sz)count + 1);
	self.child_labels[0] = "Choose child...".copy(mem);

	usz at = 1;
	foreach (usz i, int parent : view.skeleton.parents)
	{
		if (parent != (int)joint) continue;
		if ((view.skeleton.joints[i] - view.skeleton.joints[joint]).length_sq() <= LIMIT_FRAME_EDGE_SQ) continue;
		uint id = view.dot_ids[i];
		Dot* dot = app.doc.find(id);
		self.child_ids[at] = id;
		self.child_labels[at] = (dot && dot.name.len > 0 ? dot.name : "unnamed joint").copy(mem);
		at++;
	}
}

fn void set_joint_degree_field(Element* body, String id, float radians) @private
{
	if (try Element* field = body.find_id(id))
	{
		char[40] buffer;
		field.widget_as(TextField).set_text(field,
			string::bformat(buffer[..], "%.1f", math::rad_to_deg(radians)));
	}
}

<*
 The three degree fields, rewritten from the working pose without a rebuild —
 what a dial drag calls on every move, since the card holds still for it.
*>
fn void refresh_joint_degree_fields(Ui* ui, AppState* app)
{
	Element*? body = ui.find_id(JOINT_PANEL_ID);
	if (catch body) return;
	if (app.selected == 0) return;

	RigView? opened = app.open_rig(mem);
	if (catch opened) return;
	RigView view = opened;
	defer view.free(mem);
	JointLimitFrame frame = joint_limit_frame(&view.skeleton, view.dot_ids,
		app.doc.rotation_limits_of(app.selected));
	if (!frame.usable()) return;

	Vec3 angles = joint_angles_from_rotation(frame, joint_panel_pose(app, &view, app.selected).rotation);
	for (usz i = 0; i < 3; i++) set_joint_degree_field(body, JOINT_ROTATION_IDS[i], angles[i]);
}

fn Element* JointPanel.build(&self, Element* elem) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	self.release_choices();
	self.shown = joint_panel_snapshot(app);

	Dot* dot = app.doc.find(app.selected);
	bool renaming = dot != null && app.renaming_dot == dot.id;

	// The Joint section's detail is looked up only when a real joint is selected;
	// opening the rig for a card showing a prompt is wasted work.
	bool rig_ok = false;
	RigView view;
	bool view_open = false;
	usz joint = 0;
	JointRotationLimits limits = {};
	JointLimitFrame frame = {};
	Vec3 angles = {};
	JointRotationAxis[3] posable;
	usz posable_count = 0;
	usz primary = 0;

	if (app.show_joint_panel && app.joint_panel_tab == JointPanelTab.JOINT && dot)
	{
		RigView? opened = app.open_rig(mem);
		if (try opened)
		{
			view = opened;
			view_open = true;
			sz found = view.joint_of(dot.id);
			if (found >= 0)
			{
				joint = (usz)found;
				rig_ok = true;
				limits = app.doc.rotation_limits_of(dot.id);
				frame = joint_limit_frame(&view.skeleton, view.dot_ids, limits);
				self.collect_child_choices(app, &view, joint);
				foreach (usz i, id : self.child_ids) if (id == limits.primary_child) { primary = i; break; }
				PosedJoint pose = joint_panel_pose(app, &view, dot.id);
				angles = joint_angles_from_rotation(frame, pose.rotation);
				// Only the axes the joint may turn about get a dial and a field. A
				// locked axis has one number, held in the limits table below.
				posable_count = posable_axes(limits, posable[..]);
			}
		}
	}
	defer if (view_open) view.free(mem);

	Element* body = @subtree(elem.ui)
	{
		@tree((Row) { .gap = JOINT_TAB_GAP, .cross_align = START })
		{
			if (app.show_joint_panel)
			{
				@tree((Scroll) { .size = { JOINT_SIDEBAR_W, 0 }, .radii = R8 })
				{
					@tree(JOINT_PANEL_SURFACE)
					{
						@tree((Column) { .size = { JOINT_SECTION_W, 0 }, .gap = JOINT_PANEL_GAP })
						{
							if (app.joint_panel_tab == JointPanelTab.JOINT)
							{
								Element* joint_section = @tree((Disclosure) {
									.label = "Joint", .expanded = !app.joint_info_collapsed,
									.width = JOINT_SECTION_W, .style = JOINT_SECTION_STYLE,
									.on_change = &joint_section_changed })
								{
									@tree((Column) { .size = { JOINT_PANEL_W, 0 }, .gap = JOINT_PANEL_GAP })
									{
										if (!dot)
										{
											@node((Label) { .text = "Select a joint to edit it — click one in the view.",
												.size = 12.0f, .color = TEXT_DIM });
										}
										else if (!rig_ok)
										{
											@node((Label) { .text = "The selected joint is not part of a usable rig.",
												.size = 13.0f, .color = TEXT_DIM });
										}
										else
										{
											if (renaming)
											{
												@tree((Row) { .gap = JOINT_PANEL_GAP, .cross_align = CENTER,
													.size = { JOINT_PANEL_W, 0 } })
												{
													@node((TextField) { .placeholder = "thigh_L", .style = TEXT_FIELD_STYLE,
														.width = JOINT_NAME_FIELD_W, .on_submit = &joint_name_submitted })
														.with_id(JOINT_NAME_FIELD_ID);
													@node(accent_button("Rename", &joint_rename_confirmed));
													@node(panel_button("Cancel", &joint_rename_cancelled));
												};
												@node((Label) { .text = "Used in clips. Blank un-names it.", .size = 12.0f,
													.color = TEXT_DIM });
											}
											else
											{
												@tree((Row) { .cross_align = CENTER, .main_align = SPACE_BETWEEN,
													.size = { JOINT_PANEL_W, 0 } })
												{
													@node((Label) { .text = dot.name.len > 0 ? dot.name : "Unnamed joint",
														.size = 17.0f, .color = TEXT });
													@node(panel_button("Rename", &joint_rename_pressed)).with_id(JOINT_RENAME_ID);
												};
											}

											if (self.child_labels.len > 0)
											{
												@node((Label) { .text = "Bone axes follow", .size = 12.0f, .color = TEXT_DIM });
												@node((Select) { .options = self.child_labels, .selected = primary,
													.width = JOINT_PANEL_W, .style = VIEW_MENU_STYLE,
													.on_change = &joint_primary_child_chosen }).with_id(JOINT_PRIMARY_CHILD_ID);
											}

											// The anchors live with the pose controls, and appear when posing is
											// possible: they hold a joint's world position and orientation while
											// another moves, which only has meaning against a clip. They need no
											// bone-local frame — a foot is held by its own place and tilt, not by a
											// turn — so they are not inside the `frame.usable()` gate the dials and
											// limits are. Two padlocks: move, and rotate; see `lock_toggles.c3`.
											if (app.animation_pose_ready())
											{
												@node((Rectangle) { .size = { 0, 1 }, .style = { .color = PANEL_BORDER } });
												@node((Label) { .text = "Pin · held in place while you pose another joint",
													.size = 12.0f, .color = TEXT_DIM });
												@tree(widgets::tip_probe(&lock_tip)) { @node((LockToggles) { }).with_id(LOCK_TOGGLES_ID); };

												// A pin on the open clip is the clip's: held while it plays, over a
												// window. Seconds into the clip; one undo step per commit.
												AnimPin* clip_pin = app.clip_pin_of(app.selected);
												AnimTemplate* pin_clip = app.clip(app.editing);
												if (clip_pin && pin_clip)
												{
													float span = math::max(pin_clip.duration, 0.01f);
													@node((Label) { .text = "Holds from · to · blend (seconds)", .size = 12.0f,
														.color = TEXT_DIM });
													@node((Slider) { .label = "From", .value = clip_pin.from, .max = span, .step = 0.01f,
														.decimals = 2, .suffix = " s", .on_commit = &joint_pin_from_committed,
														.style = PHYSICS_SLIDER_STYLE }).with_id(JOINT_PIN_FROM_ID);
													@node((Slider) { .label = "To", .value = clip_pin.to, .max = span, .step = 0.01f,
														.decimals = 2, .suffix = " s", .on_commit = &joint_pin_to_committed,
														.style = PHYSICS_SLIDER_STYLE }).with_id(JOINT_PIN_TO_ID);
													@node((Slider) { .label = "Blend", .value = clip_pin.blend, .max = span, .step = 0.01f,
														.decimals = 2, .suffix = " s", .on_commit = &joint_pin_blend_committed,
														.style = PHYSICS_SLIDER_STYLE }).with_id(JOINT_PIN_BLEND_ID);
												}
											}

											if (!frame.usable())
											{
												@node((Label) { .text = joint_frame_note(frame.status), .size = 12.0f, .color = TEXT_DIM });
											}
											else
											{
												if (app.animation_pose_ready() && posable_count == 0)
												{
													@node((Label) { .text = "Rotation · bone local", .size = 13.0f, .color = TEXT_DIM });
													@node((Label) { .text = "Every axis is locked. Allow one below to pose this joint.",
														.size = 12.0f, .color = TEXT_DIM });
												}
												else if (app.animation_pose_ready())
												{
													@node((Label) { .text = "Rotation · bone local", .size = 13.0f, .color = TEXT_DIM });
													// The dials over the fields they drive, one column each.
													// This is where the joint is turned by hand: off the
													// model, so a wrist or a head is not hidden under its
													// own control while it turns.
													@node((JointDials) { .axes = posable, .count = posable_count }).with_id(JOINT_DIALS_ID);
													@tree((Grid) { .cell = { JOINT_ROTATION_CELL_W, 50.0f },
														.gap_x = JOINT_PANEL_GRID_GAP,
														.size = { JOINT_PANEL_W, 0 } })
													{
														for (usz i = 0; i < posable_count; i++)
														{
															JointRotationAxis axis = posable[i];
															@tree((Column) { .gap = 3.0f })
															{
																@node((Label) { .text = JOINT_ROTATION_CAPTIONS[axis.component()], .size = 11.0f,
																	.color = joint_axis_color(axis.component()) });
																@node((TextField) { .style = TEXT_FIELD_STYLE,
																	.on_submit = JOINT_ROTATION_ENTRIES[axis.component()] })
																	.with_id(JOINT_ROTATION_IDS[axis.component()]);
															};
														}
													};
													@node((Label) { .text = joint_pose_note(app), .size = 12.0f, .color = TEXT_DIM });
												}

												@node((Rectangle) { .size = { 0, 1 }, .style = { .color = PANEL_BORDER } });
												@tree((Row) { .gap = JOINT_PANEL_GAP, .cross_align = CENTER })
												{
													@node((Checkbox) { .label = "Limit rotation", .checked = limits.constrained,
														.on_change = &joint_limits_toggled, .style = CHECKBOX_STYLE })
														.with_id(JOINT_LIMITS_ACTIVE_ID);
													if (limits.constrained)
													{
														@node(panel_button("Reset", &joint_limits_reset)).with_id(JOINT_LIMITS_RESET_ID);
													}
												};

												if (limits.constrained)
												{
													@tree((Grid) { .cell = { JOINT_PANEL_CELL_W, JOINT_PANEL_CELL_H },
														.gap_x = JOINT_PANEL_GRID_GAP, .gap_y = JOINT_PANEL_GRID_GAP,
														.size = { JOINT_PANEL_W, 0 } })
													{
														@node((Label) { .text = "Axis", .size = 11.0f, .color = TEXT_DIM });
														@node((Label) { .text = "Allow", .size = 11.0f, .color = TEXT_DIM });
														@node((Label) { .text = "Min °", .size = 11.0f, .color = TEXT_DIM });
														@node((Label) { .text = "Max °", .size = 11.0f, .color = TEXT_DIM });

														for (usz i = 0; i < 3; i++)
														{
															@node((Label) { .text = ((JointRotationAxis)i).label(), .size = 13.0f,
																.color = joint_axis_color(i) });
															@node((Checkbox) { .label = "", .checked = limits.axes[i].allowed,
																.on_change = JOINT_LIMIT_ALLOWED[i], .style = CHECKBOX_STYLE })
																.with_id(JOINT_LIMIT_ALLOW_IDS[i]);
															if (limits.axes[i].allowed)
															{
																@node((TextField) { .style = TEXT_FIELD_STYLE,
																	.on_submit = JOINT_LIMIT_MIN_ENTERED[i] }).with_id(JOINT_LIMIT_MIN_IDS[i]);
																@node((TextField) { .style = TEXT_FIELD_STYLE,
																	.on_submit = JOINT_LIMIT_MAX_ENTERED[i] }).with_id(JOINT_LIMIT_MAX_IDS[i]);
															}
															else
															{
																// A locked axis cannot rotate about itself, so it has no
																// angle to type: both value cells read "Locked", and the
																// joint is held at rest about this axis.
																@node((Label) { .text = "Locked", .size = 12.0f, .color = TEXT_DIM });
																@node((Label) { .text = "Locked", .size = 12.0f, .color = TEXT_DIM });
															}
														}
													};
												}
											}
										}
									};
								};
								joint_section.with_id(JOINT_SECTION_ID);
							}
							else if (app.joint_panel_tab == JointPanelTab.WEIGHTS)
							{
								Element* weights_section = @tree((Disclosure) {
									.label = "Weights", .expanded = !app.weights_info_collapsed,
									.width = JOINT_SECTION_W, .style = JOINT_SECTION_STYLE,
									.on_change = &weights_section_changed })
								{
									@tree((Column) { .size = { JOINT_PANEL_W, 0 }, .gap = JOINT_PANEL_GAP })
									{
										if (!dot)
										{
											@node((Label) { .text = "Select a joint to pick the part of the mesh it moves.",
												.size = 12.0f, .color = TEXT_DIM });
										}
										else
										{
											@node((Label) { .text = dot.name.len > 0 ? dot.name : "Unnamed joint",
												.size = 17.0f, .color = TEXT });
											@node((Label) { .text = "Part", .size = 12.0f, .color = TEXT_DIM });
											@node((Select) { .options = weights_part_labels[..],
												.selected = (usz)(app.areaing ? app.area_origin : AreaPart.OWN),
												.width = JOINT_PANEL_W, .style = VIEW_MENU_STYLE,
												.on_change = &weights_part_chosen }).with_id(WEIGHTS_PART_ID);
											@tree((Row) { .gap = JOINT_PANEL_GAP, .cross_align = CENTER })
											{
												@node(panel_button("Grow", &weights_grow_pressed)).with_id(WEIGHTS_GROW_ID);
												@node(panel_button("Shrink", &weights_shrink_pressed)).with_id(WEIGHTS_SHRINK_ID);
											};
											if (app.areaing && app.area_islands)
											{
												// Islands picked by hand: start from none, or flip to the rest.
												@tree((Row) { .gap = JOINT_PANEL_GAP, .cross_align = CENTER })
												{
													@node(panel_button("Clear", &weights_clear_pressed)).with_id(WEIGHTS_CLEAR_ID);
													@node(panel_button("Invert", &weights_invert_pressed)).with_id(WEIGHTS_INVERT_ID);
												};
											}
											@node((Slider) {
												.label = "Soft edge",
												.suffix = "% of bone",
												.value = app.area_soft * 100.0f,
												.max = AREA_SOFT_MAX * 100.0f,
												.step = 5.0f,
												.on_change = &weights_soft_moved,
												.on_commit = &weights_soft_committed,
												.style = PHYSICS_SLIDER_STYLE,
											}).with_id(WEIGHTS_SOFT_ID);
											@node((Checkbox) { .label = "Also mirror", .checked = app.area_mirrors(),
												.on_change = &weights_mirror_toggled, .style = CHECKBOX_STYLE })
												.with_id(WEIGHTS_MIRROR_ID);
											@tree((Row) { .gap = JOINT_PANEL_GAP, .cross_align = CENTER })
											{
												@node(accent_button("Apply", &weights_apply_pressed)).with_id(WEIGHTS_APPLY_ID);
												@node(panel_button("Reset to automatic", &weights_reset_pressed)).with_id(WEIGHTS_RESET_ID);
											};
											@node((Label) { .text = weights_readout(app, &self.readout),
												.size = 12.0f, .color = TEXT_DIM, .overflow = WRAP }).with_id(WEIGHTS_READOUT_ID);
											// Painting by hand lives here too, beside the parts it corrects.
											@node((Label) { .text = "Brush", .size = 12.0f, .color = TEXT_DIM });
											@node(app.brushing ? accent_button("Stop painting", &menu_weight_brush)
												: panel_button("Paint brush", &menu_weight_brush)).with_id(WEIGHTS_BRUSH_ID);
											@node((Label) { .text = "Shift+W · drag the mesh to paint, ctrl-drag takes off, hold F to size",
												.size = 12.0f, .color = TEXT_DIM, .overflow = WRAP });
										}
									};
								};
								weights_section.with_id(WEIGHTS_SECTION_ID);
							}
							else if (app.joint_panel_tab == JointPanelTab.POSE)
							{
								// What is done to the pose on show. The dock keeps the clip; this
								// keeps the pose (pose_panel.c3).
								Element* pose_section = @tree((Disclosure) {
									.label = "Pose", .expanded = !app.pose_info_collapsed,
									.width = JOINT_SECTION_W, .style = JOINT_SECTION_STYLE,
									.on_change = &pose_section_changed })
								{
									@tree((Column) { .size = { JOINT_PANEL_W, 0 }, .gap = JOINT_PANEL_GAP })
									{
										@tree((Wrap) { .gap_x = JOINT_PANEL_GRID_GAP, .gap_y = JOINT_PANEL_GRID_GAP, .cross_align = CENTER })
										{
											// Shows the rest pose without touching a key; scrubbing or Play
											// brings the animation back.
											@node(panel_button("Rest pose", &anim_reset_pose_clicked)).with_id("anim-reset-pose");
											@node(panel_button("Mirror pose", &anim_mirror_pose_clicked)).with_id(ANIM_MIRROR_POSE_ID);
											@node(panel_button("Copy", &anim_copy_pose_clicked)).with_id(ANIM_COPY_POSE_ID);
											@node(panel_button("Paste", &anim_paste_pose_clicked)).with_id(ANIM_PASTE_POSE_ID);
											@node(panel_button("Paste mirrored", &anim_paste_pose_mirrored_clicked)).with_id(ANIM_PASTE_MIRRORED_ID);
										};
										@node((Label) { .text = app.clip(app.editing) ? "Acts on the pose at the playhead."
											: "Choose an animation to copy, mirror or paste a pose.",
											.size = 12.0f, .color = TEXT_DIM });
									};
								};
								pose_section.with_id(POSE_SECTION_ID);

								Element* options_section = @tree((Disclosure) {
									.label = "Posing options", .expanded = !app.pose_options_collapsed,
									.width = JOINT_SECTION_W, .style = JOINT_SECTION_STYLE,
									.on_change = &pose_options_section_changed })
								{
									@tree((Column) { .size = { JOINT_PANEL_W, 0 }, .gap = JOINT_PANEL_GAP })
									{
										// Over pinned feet, the body leans to keep its weight on them. Off for a
										// pose that is held up by something else — a chair, a wall.
										@node((ToggleButton) { .label = "Balance", .on = !app.balance_off,
											.on_change = &anim_balance_toggled, .style = SEGMENTED_STYLE }).with_id(ANIM_BALANCE_ID);
										@node((Label) { .text = "Pinned joints", .size = 12.0f, .color = TEXT_DIM });
										@node((PosePinList) { }).with_id(POSE_PINS_ID);
									};
								};
								options_section.with_id(POSE_OPTIONS_SECTION_ID);

								Element* library_section = @tree((Disclosure) {
									.label = "Pose library", .expanded = !app.pose_library_collapsed,
									.width = JOINT_SECTION_W, .style = JOINT_SECTION_STYLE,
									.on_change = &pose_library_section_changed })
								{
									@tree((Column) { .size = { JOINT_PANEL_W, 0 }, .gap = JOINT_PANEL_GAP })
									{
										@node((AnimPosesPanel) { }).with_id(ANIM_POSE_PANEL_ID);
									};
								};
								library_section.with_id(POSE_LIBRARY_SECTION_ID);
							}
							else
							{
								Element* align_section = @tree((Disclosure) {
									.label = "Align Tools", .expanded = !app.align_info_collapsed,
									.width = JOINT_SECTION_W, .style = JOINT_SECTION_STYLE,
									.on_change = &align_section_changed })
								{
									@tree((Column) { .size = { JOINT_PANEL_W, 0 }, .gap = JOINT_PANEL_GAP })
									{
										// A group lines up on an axis with the first-selected joint; a lone
										// joint drops onto the mesh centre.
										if (app.selection_count() > 1)
										{
											@node((Label) { .text = "Align to first-selected", .size = 12.0f, .color = TEXT_DIM });
											@tree((Row) { .gap = JOINT_PANEL_GAP, .cross_align = CENTER,
												.size = { JOINT_PANEL_W, 0 } })
											{
												@node(panel_button("X", &joint_align_x)).with_id("joint-align-x");
												@node(panel_button("Y", &joint_align_y)).with_id("joint-align-y");
												@node(panel_button("Z", &joint_align_z)).with_id("joint-align-z");
											};
											@node((Label) { .text = "Each takes the first-selected joint's X, Y or Z.",
												.size = 12.0f, .color = TEXT_DIM });
										}
										else if (app.selected != 0)
										{
											@node(panel_button("Centre on mesh", &joint_center_on_mesh)).with_id("joint-center-mesh");
											@node((Label) { .text = "Drops this joint onto the mesh middle. Pick two or more to line up on an axis.",
												.size = 12.0f, .color = TEXT_DIM });
										}
										else
										{
											@node((Label) { .text = "Select one joint to centre it on the mesh, or two or more to line them up on X, Y or Z.",
												.size = 12.0f, .color = TEXT_DIM });
										}
									};
								};
								align_section.with_id(ALIGN_SECTION_ID);
							}
						};
					};
				};
			}

			@tree((Column) { .gap = JOINT_TAB_GAP, .size = { JOINT_TAB_W, 0 } })
			{
				bool joint_active = app.show_joint_panel && app.joint_panel_tab == JointPanelTab.JOINT;
				Element* joint_tab;
				@tree(widgets::tip("Joint (N) — pose, limits and pins for the selected joint"))
				{
					joint_tab = @tree(joint_panel_tab_button(joint_active, &joint_tab_pressed))
					{
						@node((JointPanelTabFace) { .tab = JointPanelTab.JOINT, .active = joint_active });
					};
				};
				joint_tab.with_id(JOINT_TAB_JOINT_ID);

				bool align_active = app.show_joint_panel && app.joint_panel_tab == JointPanelTab.ALIGN;
				Element* align_tab;
				@tree(widgets::tip("Align (N) — centre a joint on the mesh, or line several up on an axis"))
				{
					align_tab = @tree(joint_panel_tab_button(align_active, &align_tab_pressed))
					{
						@node((JointPanelTabFace) { .tab = JointPanelTab.ALIGN, .active = align_active });
					};
				};
				align_tab.with_id(JOINT_TAB_ALIGN_ID);

				bool weights_active = app.show_joint_panel && app.joint_panel_tab == JointPanelTab.WEIGHTS;
				Element* weights_tab;
				@tree(widgets::tip("Weights (N) — how the selected joint's bind is shared over the mesh"))
				{
					weights_tab = @tree(joint_panel_tab_button(weights_active, &weights_tab_pressed))
					{
						@node((JointPanelTabFace) { .tab = JointPanelTab.WEIGHTS, .active = weights_active });
					};
				};
				weights_tab.with_id(JOINT_TAB_WEIGHTS_ID);

				bool pose_active = app.show_joint_panel && app.joint_panel_tab == JointPanelTab.POSE;
				Element* pose_tab;
				@tree(widgets::tip("Pose (N) — rest, mirror, copy and paste the pose, balance, pins and the pose library"))
				{
					pose_tab = @tree(joint_panel_tab_button(pose_active, &pose_tab_pressed))
					{
						@node((JointPanelTabFace) { .tab = JointPanelTab.POSE, .active = pose_active });
					};
				};
				pose_tab.with_id(JOINT_TAB_POSE_ID);
			};
		};
	};

	// Through the subtree, not the Ui: none of this is attached yet, so the
	// tree-wide lookup cannot see it. Filled and focused here rather than by the
	// button that asked for it, because the field does not exist until this
	// build runs.
	if (renaming && rig_ok) if (try Element* field = body.find_id(JOINT_NAME_FIELD_ID))
	{
		// An empty name is left on the placeholder, the way `fill_field` does it
		// next door: a field holding "" and one holding nothing look the same.
		if (dot.name.len > 0)
		{
			TextField* text = field.widget_as(TextField);
			text.set_text(field, dot.name);

			// Selected, not just filled. The commonest rename replaces the name
			// outright — a plan named a limb the wrong side round, or a dot came
			// in as `joint_7` — and a caret parked at the end would make every one
			// of those start with a held backspace.
			text.select_all(field);
		}
		field.request_focus();
	}

	if (rig_ok && frame.usable())
	{
		for (usz i = 0; i < 3; i++) set_joint_degree_field(body, JOINT_ROTATION_IDS[i], angles[i]);
	}
	if (rig_ok && limits.constrained)
	{
		// Only the allowed axes have fields to fill — a locked row is two "Locked"
		// labels and holds no number of its own.
		foreach (usz i, axis : limits.axes)
		{
			if (!axis.allowed) continue;
			set_joint_degree_field(body, JOINT_LIMIT_MIN_IDS[i], axis.minimum);
			set_joint_degree_field(body, JOINT_LIMIT_MAX_IDS[i], axis.maximum);
		}
	}
	return body;
}

// ---------------------------------------------------------------------------
// The name

<*
 Turn the card's title into a field, on the selected dot.

 Rig > Rename joint comes here too. Refuses with a notice rather than opening
 nothing: with no dot selected there is no card, so there is nowhere for the
 field to be, and the notice says what to do about it. The menu item is greyed
 for the same case, so this is the keyboard's copy of that.
*>
fn void begin_joint_rename(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (app.selected == 0)
	{
		app.@notice("select a joint to rename it");
		return;
	}
	app.renaming_dot = app.selected;
	refresh_joint_panel(ui);
}

fn void joint_rename_pressed(Ui* ui) @private => begin_joint_rename(ui);

// The align tools' buttons. X/Y/Z line the selection up with the first-selected
// joint on that axis; Centre drops a lone joint onto the mesh middle. Each says
// what it did, so a button that could not act (a group of one, a lone dot already
// centred) is a notice rather than a silent nothing.
fn void joint_align_x(Ui* ui) @private => joint_align_axis(ui, 0);
fn void joint_align_y(Ui* ui) @private => joint_align_axis(ui, 1);
fn void joint_align_z(Ui* ui) @private => joint_align_axis(ui, 2);

fn void joint_align_axis(Ui* ui, int component) @private
{
	AppState* app = ui.inherit(AppState)!!;
	String axis = component == 0 ? "X" : (component == 1 ? "Y" : "Z");
	usz moved = app.align_selection_to_anchor(component);
	if (moved == 0)
	{
		app.@notice("select two or more joints to align them on %s", axis);
	}
	else
	{
		app.@notice("aligned %d joint%s on %s", (int)moved, moved == 1 ? "" : "s", axis);
	}
	app.refresh_ui();
}

fn void joint_center_on_mesh(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	if (app.center_selected_on_mesh())
	{
		app.@notice("centred the joint on the mesh");
	}
	else
	{
		app.@notice("select one joint to centre it on the mesh");
	}
	app.refresh_ui();
}

fn void joint_section_changed(Ui* ui, bool expanded) @private
{
	AppState* app = ui.inherit(AppState)!!;
	app.joint_info_collapsed = !expanded;
	app.remember_ui();
	app.refresh_ui();
}

fn void align_section_changed(Ui* ui, bool expanded) @private
{
	AppState* app = ui.inherit(AppState)!!;
	app.align_info_collapsed = !expanded;
	app.remember_ui();
	app.refresh_ui();
}

fn void joint_tab_pressed(Ui* ui) @private => joint_panel_tab_pressed(ui, JointPanelTab.JOINT);
fn void align_tab_pressed(Ui* ui) @private => joint_panel_tab_pressed(ui, JointPanelTab.ALIGN);
fn void weights_tab_pressed(Ui* ui) @private => joint_panel_tab_pressed(ui, JointPanelTab.WEIGHTS);
fn void pose_tab_pressed(Ui* ui) @private => joint_panel_tab_pressed(ui, JointPanelTab.POSE);

fn void joint_panel_tab_pressed(Ui* ui, JointPanelTab tab, bool say = true) @private
{
	AppState* app = ui.inherit(AppState)!!;
	if (app.show_joint_panel && app.joint_panel_tab == tab)
	{
		app.show_joint_panel = false;
		app.@notice("sidebar hidden (N)");
	}
	else
	{
		app.joint_panel_tab = tab;
		app.show_joint_panel = true;
		if (tab == WEIGHTS && app.transform_interaction.active) (void)app.finish_transform_interaction(false);
		if (say) switch (tab)
		{
			case JOINT: app.@notice("Joint panel shown");
			case ALIGN: app.@notice("Align panel shown");
			case WEIGHTS: app.@notice("Weights panel shown");
			case POSE: app.@notice("Pose panel shown");
		}
	}
	app.sync_weights_card();
	app.remember_ui();
	app.refresh_ui();
}

fn void joint_rename_cancelled(Ui* ui) @private
{
	ui.inherit(AppState)!!.renaming_dot = 0;
	refresh_joint_panel(ui);
}

// Return in the field is the same answer as the button. The text arrives with
// the callback, but it is read back out of the field anyway so both routes go
// through one path and cannot drift.
fn void joint_name_submitted(Ui* ui, String text) @private => joint_rename_confirmed(ui);

<*
 Put the name on the dot.

 Copied out before the card rebuilds, because the rebuild releases the subtree
 the field lives in and the value is a view into its buffer — the rule
 `asset_settings_saved` follows for the same reason.
*>
fn void joint_rename_confirmed(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	uint id = app.renaming_dot;
	String name = field_text(ui, JOINT_NAME_FIELD_ID).copy(mem);
	defer name.free(mem);

	app.renaming_dot = 0;
	refresh_joint_panel(ui);
	if (id == 0) return;

	// Asked before the rename, or the dot being renamed would answer to it.
	Dot* clash = name.len > 0 ? app.dot_named(name) : null;
	bool taken = clash != null && clash.id != id;

	if (!app.rename(id, name))
	{
		// The only two ways `rename` refuses: the dot went away while the field
		// was up, or the name is the one it already carries. Neither is worth a
		// notice — the second is what pressing Return on an unchanged field does.
		return;
	}

	if (taken)
	{
		app.@notice("two joints are now called %s — no clip can tell them apart", name);
	}
	else if (name.len == 0)
	{
		app.@notice("joint %d un-named — no clip can reach it", id);
	}
	else
	{
		app.@notice("renamed to %s", name);
	}
}


<*
 The axes the selected joint may turn about, in X/Y/Z order: every axis of a
 free joint, and the allowed rows of a limited one. A locked axis has one
 angle, and that angle is the limits table's to edit, so the pose row leaves it
 out rather than offering a control that can only refuse.

 @param out : `Room for three.`
 @return `How many were written.`
*>
fn usz posable_axes(JointRotationLimits limits, JointRotationAxis[] out)
{
	usz count = 0;
	foreach (usz i, axis : JOINT_DIAL_AXES)
	{
		if (limits.constrained && !limits.axes[i].allowed) continue;
		out[count++] = axis;
	}
	return count;
}

fn bool prepare_joint_numeric_pose(AppState* app) @private
{
	return app.prepare_animation_pose();
}

fn void joint_rotation_entered(Ui* ui, String value, JointRotationAxis axis) @private
{
	float? parsed = value.trim().to_float();
	if (catch parsed)
	{
		ui.inherit(AppState)!!.@notice("Enter a rotation in degrees.");
		return;
	}
	if (!math::is_finite(parsed))
	{
		ui.inherit(AppState)!!.@notice("Enter a rotation in degrees.");
		return;
	}
	AppState* app = ui.inherit(AppState)!!;
	if (app.selected == 0 || !prepare_joint_numeric_pose(app))
	{
		refresh_joint_panel(ui);
		return;
	}

	RigView? opened = app.open_rig(mem);
	if (catch opened) return;
	RigView view = opened;
	defer view.free(mem);
	JointRotationLimits limits = app.doc.rotation_limits_of(app.selected);
	JointLimitFrame frame = joint_limit_frame(&view.skeleton, view.dot_ids, limits);
	if (!frame.usable())
	{
		app.@notice("Cannot edit bone-local rotation: %s.", frame.status.reason());
		refresh_joint_panel(ui);
		return;
	}

	PosedJoint before = app.working_pose(app.selected);
	Vec3 angles = joint_angles_from_rotation(frame, before.rotation);
	angles[axis.component()] = math::deg_to_rad(parsed);
	Quaternionf rotation = constrain_joint_rotation(frame, limits,
		rotation_from_joint_angles(frame, angles));

	if (app.pose_edit_active)
	{
		// The mesh after the limits, as R has it: a number that would drive the
		// joint through the body lands where the surface stops it, and the field
		// shows the angle it landed on rather than the one typed — the same
		// silent stop a limit makes.
		rotation = app.numeric_joint_rotation(&view, app.selected, rotation, frame, limits);
		if (!app.set_working_pose(app.selected, rotation, before.offset))
		{
			refresh_joint_panel(ui);
			return;
		}
		app.pose_edit_pending = true;
		app.refresh_posed();
		if (app.auto_key) (void)app.key_pose_edit(CHANGED);
	}

	app.refresh_ui();
	refresh_animations_view(ui);
	refresh_joint_panel(ui);
}

fn void joint_rotation_x_entered(Ui* ui, String value) => joint_rotation_entered(ui, value, X);
fn void joint_rotation_y_entered(Ui* ui, String value) => joint_rotation_entered(ui, value, Y);
fn void joint_rotation_z_entered(Ui* ui, String value) => joint_rotation_entered(ui, value, Z);

fn bool commit_joint_limits(Ui* ui, JointRotationLimits limits) @private
{
	AppState* app = ui.inherit(AppState)!!;
	if (!app.set_rotation_limits_recorded(app.selected, limits))
	{
		refresh_joint_panel(ui);
		return false;
	}
	app.undo_stack.commit();
	app.refresh_ui();
	refresh_joint_panel(ui);
	return true;
}

fn void joint_primary_child_chosen(Ui* ui, usz row) @private
{
	AppState* app = ui.inherit(AppState)!!;
	RigView? opened = app.open_rig(mem);
	if (catch opened) return;
	RigView view = opened;
	defer view.free(mem);
	sz selected = view.joint_of(app.selected);
	if (selected < 0) return;

	usz at = 0;
	uint chosen = 0;
	foreach (usz i, int parent : view.skeleton.parents)
	{
		if (parent != selected) continue;
		if ((view.skeleton.joints[i] - view.skeleton.joints[(usz)selected]).length_sq()
			<= LIMIT_FRAME_EDGE_SQ) continue;
		at++;
		if (at == row) { chosen = view.dot_ids[i]; break; }
	}
	if (row > 0 && chosen == 0) return;

	JointRotationLimits limits = app.doc.rotation_limits_of(app.selected);
	limits.primary_child = chosen;
	(void)commit_joint_limits(ui, limits);
}

fn void joint_pin_from_committed(Ui* ui, float value)
{
	AppState* app = ui.inherit(AppState)!!;
	(void)app.set_clip_pin_window(app.selected, value, -1.0f, -1.0f);
	refresh_joint_panel(ui);
}

fn void joint_pin_to_committed(Ui* ui, float value)
{
	AppState* app = ui.inherit(AppState)!!;
	(void)app.set_clip_pin_window(app.selected, -1.0f, value, -1.0f);
	refresh_joint_panel(ui);
}

fn void joint_pin_blend_committed(Ui* ui, float value)
{
	AppState* app = ui.inherit(AppState)!!;
	(void)app.set_clip_pin_window(app.selected, -1.0f, -1.0f, value);
	refresh_joint_panel(ui);
}

fn void joint_limits_toggled(Ui* ui, bool checked) @private
{
	AppState* app = ui.inherit(AppState)!!;
	JointRotationLimits limits = app.doc.rotation_limits_of(app.selected);
	if (checked)
	{
		RigView? opened = app.open_rig(mem);
		if (catch opened) return;
		RigView view = opened;
		defer view.free(mem);
		JointLimitFrame frame = joint_limit_frame(&view.skeleton, view.dot_ids, limits);
		if (!frame.usable())
		{
			app.@notice("Cannot enable limits: %s.", frame.status.reason());
			refresh_joint_panel(ui);
			return;
		}
	}
	limits.constrained = checked;
	(void)commit_joint_limits(ui, limits);
}

fn void joint_limit_allowed(Ui* ui, bool allowed, JointRotationAxis axis) @private
{
	AppState* app = ui.inherit(AppState)!!;
	JointRotationLimits limits = app.doc.rotation_limits_of(app.selected);
	if (!limits.constrained) { refresh_joint_panel(ui); return; }
	limits.axes[axis.component()].allowed = allowed;
	(void)commit_joint_limits(ui, limits);
}

fn void joint_limit_x_allowed(Ui* ui, bool allowed) => joint_limit_allowed(ui, allowed, X);
fn void joint_limit_y_allowed(Ui* ui, bool allowed) => joint_limit_allowed(ui, allowed, Y);
fn void joint_limit_z_allowed(Ui* ui, bool allowed) => joint_limit_allowed(ui, allowed, Z);

enum JointLimitNumber
{
	MINIMUM,
	MAXIMUM,
}

fn void joint_limit_number_entered(
	Ui* ui,
	String value,
	JointRotationAxis axis,
	JointLimitNumber which) @private
{
	float? parsed = value.trim().to_float();
	if (catch parsed)
	{
		ui.inherit(AppState)!!.@notice("Enter a limit in degrees.");
		return;
	}
	if (!math::is_finite(parsed))
	{
		ui.inherit(AppState)!!.@notice("Enter a limit in degrees.");
		return;
	}
	AppState* app = ui.inherit(AppState)!!;
	JointRotationLimits limits = app.doc.rotation_limits_of(app.selected);
	if (!limits.constrained) { refresh_joint_panel(ui); return; }

	JointAxisLimit* row = &limits.axes[axis.component()];
	float radians = math::deg_to_rad(parsed);
	switch (which)
	{
		case MINIMUM: row.minimum = radians;
		case MAXIMUM: row.maximum = radians;
	}
	if (!row.valid())
	{
		app.@notice("Minimum must not be greater than maximum.");
		return;
	}
	(void)commit_joint_limits(ui, limits);
}

fn void joint_limit_x_min_entered(Ui* ui, String value) => joint_limit_number_entered(ui, value, X, MINIMUM);
fn void joint_limit_x_max_entered(Ui* ui, String value) => joint_limit_number_entered(ui, value, X, MAXIMUM);
fn void joint_limit_y_min_entered(Ui* ui, String value) => joint_limit_number_entered(ui, value, Y, MINIMUM);
fn void joint_limit_y_max_entered(Ui* ui, String value) => joint_limit_number_entered(ui, value, Y, MAXIMUM);
fn void joint_limit_z_min_entered(Ui* ui, String value) => joint_limit_number_entered(ui, value, Z, MINIMUM);
fn void joint_limit_z_max_entered(Ui* ui, String value) => joint_limit_number_entered(ui, value, Z, MAXIMUM);

fn void joint_limits_reset(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	if (app.selected == 0) return;
	(void)commit_joint_limits(ui, unconstrained_rotation(app.selected));
}

// ---------------------------------------------------------------------------
// The Weights card: the Area tool's controls, as buttons and a slider

// What the pending part holds, or how to pick one.
fn String weights_readout(AppState* app, char[] buffer) @private
{
	if (app.brushing) return "Painting by hand — the brush strip at the top sets its size and add or remove.";
	if (!app.areaing || !app.area_pending()) return "Click the mesh, or choose a part above.";
	usz held = app.area_held();
	usz total = app.geometry.positions.len;
	int percent = total > 0 ? (int)math::round((float)held * 100.0f / (float)total) : 0;
	String edge = app.area_soft > 0.0f
		? string::tformat("edge fades over %d%% of the bone", (int)math::round(app.area_soft * 100.0f))
		: "hard edge";
	if (app.area_islands)
	{
		if (held == 0) return "No islands picked — click the mesh to add one, or shift-drag across several.";
		usz islands = app.area_island_count();
		return string::bformat(buffer, "holds %d vertices in %d UV island%s (%d%% of the mesh) · %s · click an island to add or remove it, shift-drag paints islands in, ctrl-drag paints them out",
			held, islands, islands == 1 ? "" : "s", percent, edge);
	}
	return string::bformat(buffer, "holds %d vertices (%d%% of the mesh) · %s", held, percent, edge);
}

fn void weights_section_changed(Ui* ui, bool expanded) @private
{
	AppState* app = ui.inherit(AppState)!!;
	app.weights_info_collapsed = !expanded;
	app.remember_ui();
	app.refresh_ui();
}

fn void pose_section_changed(Ui* ui, bool expanded)
{
	AppState* app = ui.inherit(AppState)!!;
	app.pose_info_collapsed = !expanded;
	app.remember_ui();
	app.refresh_ui();
}

fn void pose_options_section_changed(Ui* ui, bool expanded) @private
{
	AppState* app = ui.inherit(AppState)!!;
	app.pose_options_collapsed = !expanded;
	app.remember_ui();
	app.refresh_ui();
}

fn void pose_library_section_changed(Ui* ui, bool expanded)
{
	AppState* app = ui.inherit(AppState)!!;
	app.pose_library_collapsed = !expanded;
	app.remember_ui();
	app.refresh_ui();
}

fn void weights_part_chosen(Ui* ui, usz row) @private
{
	AppState* app = ui.inherit(AppState)!!;
	if (row >= weights_part_labels.len) return;
	if (!app.areaing)
	{
		menu_area_tool(ui);
		if (!app.areaing) return;
	}
	app.set_area_part((AreaPart)row);
	app.refresh_ui();
	refresh_joint_panel(ui);
}

fn void weights_resize(Ui* ui, int rings) @private
{
	AppState* app = ui.inherit(AppState)!!;
	if (!app.areaing || !app.area_pending())
	{
		app.@notice("pick a part first — click the mesh");
	}
	else if (!app.resize_area(rings))
	{
		app.@notice(rings > 0 ? "the part cannot grow any further" : "the part cannot shrink any further");
	}
	app.refresh_ui();
}

fn void weights_clear_pressed(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	if (app.clear_area_islands()) app.@notice("no islands picked — click the mesh to add them");
	app.refresh_ui();
}

fn void weights_invert_pressed(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	app.invert_area_islands();
	app.refresh_ui();
}

fn void weights_grow_pressed(Ui* ui) @private => weights_resize(ui, 1);
fn void weights_shrink_pressed(Ui* ui) @private => weights_resize(ui, -1);

// Live while the handle moves: the card is not rebuilt under the drag, only the
// mesh repainted.
fn void weights_soft_moved(Ui* ui, float value) @private
{
	AppState* app = ui.inherit(AppState)!!;
	float soft = math::round(value / 5.0f) * 0.05f;
	if (math::abs(soft - app.area_soft) < 1.0e-4f) return;
	app.area_soft = soft;
	if (app.tint_mode != OFF)
	{
		app.weights_stale = true;
		app.weights_due = 0.0f;
	}
}

// The readout names the edge width, so the card catches up once the handle is let go.
fn void weights_soft_committed(Ui* ui, float value) @private => refresh_joint_panel(ui);

fn void weights_mirror_toggled(Ui* ui, bool checked) @private
{
	AppState* app = ui.inherit(AppState)!!;
	app.area_solo = !checked;
	if (app.areaing)
	{
		app.refresh_area_twin();
		app.area_changed();
	}
	app.refresh_ui();
}

fn void weights_apply_pressed(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	app.commit_area();
	app.refresh_ui();
	refresh_joint_panel(ui);
}

fn void weights_reset_pressed(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	app.reset_joint_area();
	app.refresh_ui();
	refresh_joint_panel(ui);
}
