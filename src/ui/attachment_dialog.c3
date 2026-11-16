<*
 The Attachment panel: what a joint holds, where it sits, and the two-hand grip.

 Raised from the joint's right-click menu (Attachments…) and left non-modal like
 Ghosts, so the view orbits while a slider is dragged. Each slider writes through
 on `on_change` and closes the undo group on `on_commit`, the physics pane's way,
 so a whole drag is one Ctrl+Z.
*>
module crig;

import cui;
import cui::widgets;
import std::math;

const String ATTACHMENT_DIALOG_ID = "attachment-dialog";
const String ATTACHMENT_PANEL_ID = "attachment-panel";
const String ATTACHMENT_KIND_ID = "attachment-kind";
const String ATTACHMENT_LENGTH_ID = "attachment-length";
const String ATTACHMENT_OFFSET_X_ID = "attachment-offset-x";
const String ATTACHMENT_OFFSET_Y_ID = "attachment-offset-y";
const String ATTACHMENT_OFFSET_Z_ID = "attachment-offset-z";
const String ATTACHMENT_TURN_X_ID = "attachment-turn-x";
const String ATTACHMENT_TURN_Y_ID = "attachment-turn-y";
const String ATTACHMENT_TURN_Z_ID = "attachment-turn-z";
const String ATTACHMENT_HAND_ID = "attachment-hand";
const String ATTACHMENT_GRIP_ID = "attachment-grip";
const String ATTACHMENT_RELEASE_ID = "attachment-release";
const String ATTACHMENT_RESET_ID = "attachment-reset";
const String ATTACHMENT_CLOSE_ID = "attachment-close";

const float ATTACHMENT_W = 300.0f;
const float ATTACHMENT_GAP = 8.0f;
// How far the grip may be moved off the joint, as a percentage of the rig's height.
const float ATTACHMENT_MAX_OFFSET = 30.0f;

String[4] attachment_kinds = { "None", "Sword", "Wand", "Staff" };

const String[7] ATTACHMENT_SLIDER_IDS = {
	ATTACHMENT_LENGTH_ID,
	ATTACHMENT_OFFSET_X_ID, ATTACHMENT_OFFSET_Y_ID, ATTACHMENT_OFFSET_Z_ID,
	ATTACHMENT_TURN_X_ID, ATTACHMENT_TURN_Y_ID, ATTACHMENT_TURN_Z_ID,
};

<*
 Open the panel on `dot_id`. A panel already up is closed first, so it is rebuilt
 for this joint under its name.
*>
fn void open_attachment_dialog(Ui* ui, uint dot_id)
{
	AppState* app = ui.inherit(AppState)!!;
	Dot* dot = app.doc.find(dot_id);
	if (!dot) return;
	set_dialog_open(ui, ATTACHMENT_DIALOG_ID, false);
	app.attachment_dot = dot_id;
	app.attachment_support = 0;
	app.attachment_angles = {};
	if (try Element* panel = ui.find_id(ATTACHMENT_DIALOG_ID))
	{
		panel.widget_as(Dialog).title = string::bformat(app.attachment_title[..], "Attachment · %s",
			dot.name.len > 0 ? dot.name : "joint");
	}
	set_dialog_open(ui, ATTACHMENT_DIALOG_ID, true);
}

fn void attachment_dialog_closed(Ui* ui) => ui.inherit(AppState)!!.attachment_dot = 0;

fn void attachment_close_pressed(Ui* ui) => set_dialog_open(ui, ATTACHMENT_DIALOG_ID, false);

fn Element* build_attachment_body(Ui* ui) => ui.@node((AttachmentPanel) { }).with_id(ATTACHMENT_PANEL_ID);

// What decides the panel's controls and lines; compared each frame, outside a drag.
struct AttachmentSnapshot
{
	uint dot;
	usz dots;
	bool held;
	PropKind kind;
	float length;
	Vec3 offset;
	Vec4 turn;
	AnimTemplate* clip;
	uint support;
	bool gripped; // the support hand holds the prop in that clip
}

fn AttachmentSnapshot attachment_snapshot(AppState* app) @private
{
	uint id = app.attachment_dot;
	HeldProp prop = app.doc.prop_of(id);
	AnimTemplate* clip = app.clip(app.editing);
	uint support = app.attachment_support;
	return {
		.dot = id,
		.dots = (usz)app.doc.dots.len(),
		.held = prop.held(),
		.kind = prop.kind,
		.length = prop.length,
		.offset = prop.offset,
		.turn = prop.turn.v,
		.clip = clip,
		.support = support,
		.gripped = prop.held() && clip && support != 0 && app.gripped_on(support) == id,
	};
}

struct AttachmentPanel (Widget)
{
	AttachmentSnapshot shown;
	char[160] state_line; // "wrist_L holds it in Walk", held for the label to borrow
}

// A column's width, so the turn sliders have track enough for a degree a step.
fn Vec2 AttachmentPanel.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	if (elem.children.len() == 0) return constraints.constrain({ 0, 0 });
	float width = math::min(ATTACHMENT_W, constraints.max.x);
	Vec2 inner = elem.layout_child(0, cui::loose({ width, constraints.max.y }));
	elem.place_child(0, { 0, 0 });
	return constraints.constrain({ width, inner.y });
}

fn void AttachmentPanel.update(&self, Element* elem, float dt) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	// Its joint deleted, or another model or character in focus (which zeroes it).
	if (!app.doc.find(app.attachment_dot))
	{
		set_dialog_open(elem.ui, ATTACHMENT_DIALOG_ID, false);
		return;
	}
	// A rebuild would release the slider being dragged; the panel catches up on the release.
	foreach (id : ATTACHMENT_SLIDER_IDS)
	{
		if (try Element* slider = elem.find_id(id))
		{
			if (slider.widget_as(Slider).dragging) return;
		}
	}
	AttachmentSnapshot now = attachment_snapshot(app);
	if (!fields_differ(now, self.shown)) return;
	self.shown = now;
	elem.request_build();
}

fn Element* AttachmentPanel.build(&self, Element* elem) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	uint id = app.attachment_dot;
	HeldProp prop = app.doc.prop_of(id);
	bool held = prop.held();
	AnimTemplate* clip = app.clip(app.editing);
	app.list_attachment_hands(id);
	usz hand_row;
	foreach (usz i, hand : app.attachment_hand_ids) if (hand == app.attachment_support) hand_row = i;
	// Taken after the hands, which may have picked the support hand.
	self.shown = attachment_snapshot(app);
	app.attachment_angles = app.prop_angles(id, app.attachment_angles);
	Vec3 angles = app.attachment_angles;
	Vec3 offset = prop.offset * 100.0f;

	bool gripped = self.shown.gripped;
	String state;
	if (gripped)
	{
		Dot* hand = app.doc.find(app.attachment_support);
		state = string::bformat(self.state_line[..], "%s holds it in %s",
			hand && hand.name.len > 0 ? hand.name : "the other hand", clip.name);
	}

	return @subtree(elem.ui)
	{
		@tree((Column) { .size = { ATTACHMENT_W, 0 }, .gap = ATTACHMENT_GAP })
		{
			@tree(widgets::tip("What this joint holds in every clip · export writes an empty <joint>.socket node at its grip"))
			{
				@node((Segmented) { .options = attachment_kinds[..], .selected = held ? (sz)prop.kind.ordinal + 1 : 0,
					.on_change = &attachment_kind_chosen, .style = SEGMENTED_STYLE }).with_id(ATTACHMENT_KIND_ID);
			};
			if (held)
			{
				@node((Slider) { .label = "Length", .suffix = "%", .value = prop.length * 100.0f,
					.min = PROP_MIN_LENGTH * 100.0f, .max = PROP_MAX_LENGTH * 100.0f, .step = 1.0f, .decimals = 0,
					.on_change = &attachment_length_moved, .on_commit = &attachment_committed,
					.style = PHYSICS_SLIDER_STYLE }).with_id(ATTACHMENT_LENGTH_ID);
				@tree(widgets::tip("Where the grip sits from the joint, in % of the rig's height along its rest axes"))
				{
					@tree((Column) { .gap = ATTACHMENT_GAP })
					{
						@node(attachment_offset_slider("Offset X", offset.x, &attachment_offset_x_moved)).with_id(ATTACHMENT_OFFSET_X_ID);
						@node(attachment_offset_slider("Offset Y", offset.y, &attachment_offset_y_moved)).with_id(ATTACHMENT_OFFSET_Y_ID);
						@node(attachment_offset_slider("Offset Z", offset.z, &attachment_offset_z_moved)).with_id(ATTACHMENT_OFFSET_Z_ID);
					};
				};
				@tree(widgets::tip("The prop's turn in the joint's frame, in degrees about X, then Y, then Z"))
				{
					@tree((Column) { .gap = ATTACHMENT_GAP })
					{
						@node(attachment_turn_slider("Turn X", angles.x, &attachment_turn_x_moved)).with_id(ATTACHMENT_TURN_X_ID);
						@node(attachment_turn_slider("Turn Y", angles.y, &attachment_turn_y_moved)).with_id(ATTACHMENT_TURN_Y_ID);
						@node(attachment_turn_slider("Turn Z", angles.z, &attachment_turn_z_moved)).with_id(ATTACHMENT_TURN_Z_ID);
					};
				};
			}

			// The grip is a pin of the open clip, so it needs one.
			if (held && clip && app.attachment_hand_ids.len > 0)
			{
				@node((Rectangle) { .size = { 0, 1 }, .style = { .color = PANEL_BORDER } });
				@tree((Row) { .gap = ATTACHMENT_GAP, .cross_align = CENTER })
				{
					@node((Label) { .text = "Two hands", .size = 12.0f, .color = TEXT_DIM });
					@node((Select) { .options = app.attachment_hand_names, .selected = hand_row, .width = 110,
						.style = VIEW_MENU_STYLE, .on_change = &attachment_hand_chosen }).with_id(ATTACHMENT_HAND_ID);
					if (gripped)
					{
						@tree(widgets::tip("Release — let that hand go: its pin comes off the clip"))
						{
							@node(panel_button("Release", &attachment_release_pressed)).with_id(ATTACHMENT_RELEASE_ID);
						};
					}
					else
					{
						@tree(widgets::tip("Grip — hold that hand where it is now on the prop, through the whole clip; it replaces that hand's other pins on the clip"))
						{
							@node(panel_button("Grip", &attachment_grip_pressed)).with_id(ATTACHMENT_GRIP_ID);
						};
					}
				};
				if (gripped)
				{
					@node((Label) { .text = state, .size = 12.0f, .color = DOT_LOCKED });
				}
			}

			@tree((Row) { .gap = ATTACHMENT_GAP })
			{
				if (held)
				{
					@tree(widgets::tip("Reset — back to where a new prop sits in this joint, keeping its type and length"))
					{
						@node(panel_button("Reset", &attachment_reset_pressed)).with_id(ATTACHMENT_RESET_ID);
					};
				}
				@node(panel_button("Close", &attachment_close_pressed)).with_id(ATTACHMENT_CLOSE_ID);
			};
		};
	};
}

fn Slider attachment_offset_slider(String label, float value, OnSlide moved) @private
{
	return { .label = label, .suffix = "%", .value = value, .min = -ATTACHMENT_MAX_OFFSET, .max = ATTACHMENT_MAX_OFFSET,
		.step = 0.5f, .decimals = 1, .on_change = moved, .on_commit = &attachment_committed, .style = PHYSICS_SLIDER_STYLE };
}

fn Slider attachment_turn_slider(String label, float value, OnSlide moved) @private
{
	return { .label = label, .suffix = "°", .value = value, .min = -180.0f, .max = 180.0f,
		.step = 1.0f, .decimals = 0, .on_change = moved, .on_commit = &attachment_committed, .style = PHYSICS_SLIDER_STYLE };
}

<*
 A Type pick, one undo step: None takes the prop away, a kind puts one in or
 changes it where it sits.
*>
fn void attachment_kind_chosen(Ui* ui, usz index)
{
	AppState* app = ui.inherit(AppState)!!;
	uint id = app.attachment_dot;
	Dot* dot = app.doc.find(id);
	if (!dot) return;
	if (index == 0)
	{
		PropKind was = app.doc.prop_of(id).kind;
		if (app.drop_prop(id)) app.@notice("the %s is out of %s's hand", was.label, dot.name);
		return;
	}
	if (index > PropKind::values.len) return;
	PropKind kind = PropKind::from_ordinal(index - 1);
	if (app.retype_prop(id, kind))
	{
		app.@notice("%s holds a %s in every clip · export writes %s.socket", dot.name, kind.label, dot.name);
	}
}

// Live while the handle moves; the group closes in attachment_committed.
fn void attachment_length_moved(Ui* ui, float value)
{
	AppState* app = ui.inherit(AppState)!!;
	(void)app.size_prop(app.attachment_dot, value / 100.0f);
}

fn void attachment_offset_moved(Ui* ui, usz axis, float value) @private
{
	AppState* app = ui.inherit(AppState)!!;
	uint id = app.attachment_dot;
	Vec3 offset = app.doc.prop_of(id).offset;
	offset[axis] = value / 100.0f;
	(void)app.set_prop_placement(id, offset, app.prop_angles(id, app.attachment_angles));
}

fn void attachment_offset_x_moved(Ui* ui, float value) => attachment_offset_moved(ui, 0, value);
fn void attachment_offset_y_moved(Ui* ui, float value) => attachment_offset_moved(ui, 1, value);
fn void attachment_offset_z_moved(Ui* ui, float value) => attachment_offset_moved(ui, 2, value);

fn void attachment_turn_moved(Ui* ui, usz axis, float value) @private
{
	AppState* app = ui.inherit(AppState)!!;
	uint id = app.attachment_dot;
	Vec3 angles = app.prop_angles(id, app.attachment_angles);
	angles[axis] = value;
	app.attachment_angles = angles;
	(void)app.set_prop_placement(id, app.doc.prop_of(id).offset, angles);
}

fn void attachment_turn_x_moved(Ui* ui, float value) => attachment_turn_moved(ui, 0, value);
fn void attachment_turn_y_moved(Ui* ui, float value) => attachment_turn_moved(ui, 1, value);
fn void attachment_turn_z_moved(Ui* ui, float value) => attachment_turn_moved(ui, 2, value);

// Once, when the button comes up: the drag becomes one undo step.
fn void attachment_committed(Ui* ui, float value)
{
	AppState* app = ui.inherit(AppState)!!;
	app.undo_stack.commit();
	app.refresh_ui();
}

fn void attachment_reset_pressed(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (app.reset_prop_placement(app.attachment_dot)) app.@notice("the prop is back where it starts in the hand");
}

fn void attachment_hand_chosen(Ui* ui, usz index)
{
	AppState* app = ui.inherit(AppState)!!;
	if (index < app.attachment_hand_ids.len) app.attachment_support = app.attachment_hand_ids[index];
}

fn void attachment_grip_pressed(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	uint holder = app.attachment_dot;
	Dot* held = app.doc.find(holder);
	Dot* hand = app.doc.find(app.attachment_support);
	if (!held || !hand) return;
	if (app.grip_prop(hand.id, holder))
	{
		app.@notice("%s holds the %s in %s through the clip · its other pins on the clip are gone",
			hand.name, app.doc.prop_of(holder).kind.label, held.name);
	}
	app.refresh_ui();
}

fn void attachment_release_pressed(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	uint support = app.attachment_support;
	if (support == 0 || app.gripped_on(support) != app.attachment_dot) return;
	if (app.set_clip_pin(support, false, false))
	{
		app.sync_clip_pins();
		app.@notice("let go of the prop");
	}
	app.refresh_ui();
}
