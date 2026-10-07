<*
 The right-click menu for whatever is selected — one menu, raised from the 3D
 View on a joint and from any row of the Scene outliner.

 Its rows follow the selection rather than where the press landed, so a joint
 offers Move, Rotate, selection growers, Mirror and Delete; the Skeleton row
 offers moving the whole rig at once; the Model row the whole model. Move and
 Rotate switch to the matching tool with its gizmo on the selection — the same
 thing G and R reach — and "Move by…" takes exact offsets for a nudge a drag
 cannot place.
*>
module crig;

import cui;
import cui::widgets;
import std::math;
import std::core::string;

const String MOVE_BY_DIALOG_ID = "move-by-dialog";
const String MOVE_BY_X_ID = "move-by-x";
const String MOVE_BY_Y_ID = "move-by-y";
const String MOVE_BY_Z_ID = "move-by-z";
const String SCALE_MODEL_DIALOG_ID = "scale-model-dialog";
const String SCALE_MODEL_HEIGHT_ID = "scale-model-height";
const String SCALE_MODEL_FACTOR_ID = "scale-model-factor";

struct ContextRow
{
	String label;
	String shortcut;
	OnClick on_select;
	String id;
	bool separator_before;
}

<*
 The rows the context menu shows for the current selection. Borrowed labels
 only: every one is a literal or a `tformat` good for this build.
*>
fn ContextRow[] scene_context_rows(AppState* app) @private
{
	ContextRow[] rows = alloc::new_array(tmem, ContextRow, 16);
	usz n = 0;

	// Opened from a target's ring: the target's own rows, and nothing else.
	if (app.aim_menu_from_ring && app.aim_target_exists())
	{
		return rows[:scene_context_target_rows(app, rows, n)];
	}

	if (app.selected != 0)
	{
		usz count = app.selection_count();
		bool many = count > 1;
		rows[n++] = { .label = many ? "Move joints" : "Move joint", .shortcut = "G",
			.on_select = &scene_context_move, .id = "viewport-context-move" };
		rows[n++] = { .label = "Rotate", .shortcut = "R",
			.on_select = &scene_context_rotate, .id = "viewport-context-rotate" };
		rows[n++] = { .label = "Move by…",
			.on_select = &scene_context_move_by, .id = "viewport-context-move-by" };
		rows[n++] = { .label = "Select children", .separator_before = true,
			.on_select = &scene_context_select_children, .id = "viewport-context-select-children" };
		rows[n++] = { .label = "Select whole skeleton",
			.on_select = &scene_context_select_skeleton, .id = "viewport-context-select-skeleton" };
		if (!many)
		{
			rows[n++] = { .label = "Rename…",
				.on_select = &scene_context_rename, .id = "viewport-context-rename" };
		}
		if (app.animation_pose_ready())
		{
			n = scene_context_aim_rows(app, rows, n, true);
		}
		rows[n++] = { .label = many ? "Mirror joints to other side" : "Mirror joint to other side",
			.separator_before = true, .on_select = &viewport_context_mirror, .id = "viewport-context-mirror" };
		rows[n++] = { .label = many ? "Delete joints" : "Delete joint", .shortcut = "X",
			.separator_before = true, .on_select = &viewport_context_delete, .id = "viewport-context-delete" };
		return rows[:n];
	}

	switch (app.scene_selection)
	{
		case SKELETON:
			rows[n++] = { .label = "Move skeleton", .shortcut = "G",
				.on_select = &scene_context_move, .id = "viewport-context-move" };
			rows[n++] = { .label = "Rotate skeleton", .shortcut = "R",
				.on_select = &scene_context_rotate, .id = "viewport-context-rotate" };
			rows[n++] = { .label = "Move skeleton by…",
				.on_select = &scene_context_move_by, .id = "viewport-context-move-by" };
			rows[n++] = { .label = "Rotate skeleton by…",
				.on_select = &scene_context_rotate_by, .id = "viewport-context-rotate-by" };
			rows[n++] = { .label = "Select all joints", .shortcut = "Ctrl+A", .separator_before = true,
				.on_select = &scene_context_select_joints, .id = "viewport-context-select-joints" };
		case MODEL:
			rows[n++] = { .label = "Move model", .shortcut = "G",
				.on_select = &scene_context_move, .id = "viewport-context-move" };
			rows[n++] = { .label = "Rotate model", .shortcut = "R",
				.on_select = &scene_context_rotate, .id = "viewport-context-rotate" };
			rows[n++] = { .label = "Move model by…",
				.on_select = &scene_context_move_by, .id = "viewport-context-move-by" };
			rows[n++] = { .label = "Scale model…",
				.on_select = &scene_context_scale_model, .id = "viewport-context-scale" };
			if (app.doc.dots.len() > 0)
			{
				rows[n++] = { .label = "Select skeleton", .separator_before = true,
					.on_select = &scene_context_select_skeleton, .id = "viewport-context-select-skeleton" };
			}
			if (app.character_count() > 1)
			{
				rows[n++] = { .label = "Remove from scene", .separator_before = true,
					.on_select = &scene_context_remove_character, .id = "viewport-context-remove-character" };
			}
		case MESH:
		case SCENE:
		case JOINT:
		case NONE:
			// The mesh cannot move on its own yet: it goes with the model. So this
			// menu is a way over to the objects that can.
			if (app.has_mesh() || app.doc.dots.len() > 0)
			{
				rows[n++] = { .label = "Select model",
					.on_select = &scene_context_select_model, .id = "viewport-context-select-model" };
			}
			if (app.doc.dots.len() > 0)
			{
				rows[n++] = { .label = "Select skeleton",
					.on_select = &scene_context_select_skeleton, .id = "viewport-context-select-skeleton" };
				rows[n++] = { .label = "Select all joints", .shortcut = "Ctrl+A",
					.on_select = &scene_context_select_joints, .id = "viewport-context-select-joints" };
			}
	}
	if (app.animation_pose_ready() && app.scene_selection != SKELETON && app.scene_selection != MODEL)
	{
		n = scene_context_aim_rows(app, rows, n, false);
	}
	return rows[:n];
}

<*
 The target the "Lock to" row points at: the selected one, or the only one.
 Borrowed from the editing clip; empty when there is no unambiguous target.
*>
fn String AppState.aim_lock_choice(&self)
{
	AnimTemplate* clip = self.clip(self.editing);
	if (!clip) return "";
	if (self.aim_target_exists()) return self.aim_target_selected;
	if (clip.aim_targets.len == 1) return clip.aim_targets[0].name;
	return "";
}

<*
 Whether the selected target is still a target of the editing clip. It goes
 stale on undo and clip switches, so every use checks.
*>
fn bool AppState.aim_target_exists(&self)
{
	AnimTemplate* clip = self.clip(self.editing);
	if (!clip || self.aim_target_selected.len == 0) return false;
	return aim_target_index_of(clip.aim_targets, self.aim_target_selected) >= 0;
}

// Whether any selected joint is locked to a look-at target.
fn bool AppState.selection_has_aim(&self)
{
	RigView? opened = self.open_rig(mem);
	if (catch opened) return false;
	RigView view = opened;
	defer view.free(mem);
	foreach (dot : self.selected_aim_dots(tmem, &view))
	{
		if (self.aim_index(dot) >= 0) return true;
	}
	return false;
}

fn usz scene_context_aim_rows(AppState* app, ContextRow[] rows, usz n, bool joints) @private
{
	rows[n++] = { .label = "Add look-at target", .separator_before = joints || n > 0,
		.on_select = &scene_context_add_aim, .id = "viewport-context-add-aim" };
	if (!joints) return n;
	String choice = app.aim_lock_choice();
	if (choice.len > 0)
	{
		rows[n++] = { .label = string::tformat("Lock to %s", choice),
			.on_select = &scene_context_lock_aim, .id = "viewport-context-lock-aim" };
	}
	if (app.selection_has_aim())
	{
		rows[n++] = { .label = "Unlock from look-at",
			.on_select = &scene_context_unlock_aim, .id = "viewport-context-unlock-aim" };
	}
	return n;
}

fn usz scene_context_target_rows(AppState* app, ContextRow[] rows, usz n) @private
{
	AnimTemplate* clip = app.clip(app.editing);
	sz at = aim_target_index_of(clip.aim_targets, app.aim_target_selected);
	bool muted = at >= 0 && clip.aim_targets[(usz)at].mute;
	if (app.selected != 0 && app.animation_pose_ready())
	{
		rows[n++] = { .label = "Lock selected joints",
			.on_select = &scene_context_lock_aim, .id = "viewport-context-lock-aim" };
	}
	rows[n++] = { .label = muted ? "Unmute target" : "Mute target",
		.on_select = &scene_context_mute_target, .id = "viewport-context-mute-target" };
	rows[n++] = { .label = "Delete target", .separator_before = n > 0,
		.on_select = &scene_context_delete_target, .id = "viewport-context-delete-target" };
	return n;
}

<*
 The context menu's rows, built each time it opens so its labels read the live
 selection. Rows share one width, the widest label and shortcut setting it —
 cui's popup item takes the ordinary dropdown minimum otherwise.
*>
fn Element* build_viewport_context(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	ContextRow[] rows = scene_context_rows(app);

	MenuStyle style = VIEW_MENU_STYLE.resolved();
	float width = widgets::PANEL_MIN_W;
	foreach (row : rows)
	{
		float wanted = widgets::CHECK_GUTTER + ui.text.measure(style.font, row.label, style.text_size).x + 2 * style.pad_x;
		if (row.shortcut.len > 0) wanted += ui.text.measure(style.font, row.shortcut, style.text_size).x + 3 * style.pad_x;
		width = math::max(width, wanted);
	}

	return @subtree(ui)
	{
		@tree((Column) { })
		{
			if (rows.len == 0)
			{
				@node((PopupMenuItem) {
					.item = { .label = "Nothing to do here — open a model first", .disabled = true },
					.style = VIEW_MENU_STYLE, .width = width,
				});
			}
			foreach (usz i, row : rows)
			{
				if (row.separator_before && i > 0)
				{
					@node((MenuSeparator) { .style = style, .size = { width, widgets::SEPARATOR_H } });
				}
				@node((PopupMenuItem) {
					.item = { .label = row.label, .shortcut = row.shortcut, .on_select = row.on_select },
					.style = VIEW_MENU_STYLE, .width = width,
				}).with_id(row.id);
			}
		};
	};
}

fn void close_scene_context(Ui* ui) @private => set_dialog_open(ui, VIEWPORT_CONTEXT_ID, false);

fn void scene_context_move(Ui* ui)
{
	close_scene_context(ui);
	menu_move_tool(ui);
}

fn void scene_context_rotate(Ui* ui)
{
	close_scene_context(ui);
	menu_rotate_tool(ui);
}

fn void scene_context_rotate_by(Ui* ui)
{
	close_scene_context(ui);
	open_skeleton_rotation_dialog(ui);
}

fn void scene_context_add_aim(Ui* ui)
{
	close_scene_context(ui);
	AppState* app = ui.inherit(AppState)!!;
	(void)app.add_aim_target();
	app.refresh_ui();
}

fn void scene_context_lock_aim(Ui* ui)
{
	close_scene_context(ui);
	AppState* app = ui.inherit(AppState)!!;
	String target = app.aim_lock_choice();
	if (target.len > 0) (void)app.lock_selection_to(target);
	app.refresh_ui();
}

fn void scene_context_unlock_aim(Ui* ui)
{
	close_scene_context(ui);
	AppState* app = ui.inherit(AppState)!!;
	(void)app.unlock_selection();
	app.refresh_ui();
}

fn void scene_context_mute_target(Ui* ui)
{
	close_scene_context(ui);
	AppState* app = ui.inherit(AppState)!!;
	AnimTemplate* clip = app.clip(app.editing);
	if (clip && app.aim_target_exists())
	{
		sz at = aim_target_index_of(clip.aim_targets, app.aim_target_selected);
		(void)app.set_target_muted(app.aim_target_selected, !clip.aim_targets[(usz)at].mute);
	}
	app.refresh_ui();
}

fn void scene_context_delete_target(Ui* ui)
{
	close_scene_context(ui);
	AppState* app = ui.inherit(AppState)!!;
	if (app.aim_target_exists()) (void)app.remove_aim_target(app.aim_target_selected);
	app.refresh_ui();
}

fn void scene_context_rename(Ui* ui)
{
	close_scene_context(ui);
	begin_joint_rename(ui);
}

fn void scene_context_select_skeleton(Ui* ui)
{
	close_scene_context(ui);
	AppState* app = ui.inherit(AppState)!!;
	app.select_scene(SKELETON);
	app.@notice("skeleton selected · %d joints move together — G to move, R to rotate", app.doc.dots.len());
	app.refresh_ui();
}

fn void scene_context_select_model(Ui* ui)
{
	close_scene_context(ui);
	AppState* app = ui.inherit(AppState)!!;
	app.select_scene(MODEL);
	app.@notice("model selected · mesh and skeleton move together — G to move, R to rotate");
	app.refresh_ui();
}

fn void scene_context_select_joints(Ui* ui)
{
	close_scene_context(ui);
	AppState* app = ui.inherit(AppState)!!;
	usz count = app.select_all();
	app.@notice("selected %d joint%s", count, count == 1 ? "" : "s");
	app.refresh_ui();
}

fn void scene_context_select_children(Ui* ui)
{
	close_scene_context(ui);
	AppState* app = ui.inherit(AppState)!!;
	if (app.selected == 0) return;
	usz count = app.select_branch(app.selected);
	app.@notice(count > 1 ? "selected the joint and %d below it" : "this joint has nothing below it",
		count - 1);
	app.refresh_ui();
}

// ---------------------------------------------------------------------------
// Move by…

fn String move_by_subject(AppState* app) @private
{
	TransformTarget target = app.transform_target();
	switch (target.kind)
	{
		case MODEL_TARGET: return "the model";
		case SKELETON_TARGET: return "the whole skeleton";
		case JOINT_TARGETS:
			return target.joint_count > 1
				? string::tformat("%d joints", target.joint_count)
				: "the joint";
		default: return "the selection";
	}
}

fn void scene_context_move_by(Ui* ui)
{
	close_scene_context(ui);
	AppState* app = ui.inherit(AppState)!!;
	TransformTarget target = app.transform_target();
	if (!target.supported())
	{
		app.@notice("select the model, skeleton, or joints to move");
		app.refresh_ui();
		return;
	}
	set_dialog_open(ui, MOVE_BY_DIALOG_ID, true);
}

fn void close_move_by_dialog(Ui* ui) => set_dialog_open(ui, MOVE_BY_DIALOG_ID, false);

fn Element* build_move_by_body(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	Element* body = @subtree(ui)
	{
		@tree((Column) { .size = { 360, 0 }, .gap = 10 })
		{
			@node((Label) { .text = string::tformat("Move %s by an exact offset.", move_by_subject(app)),
				.size = 14, .color = TEXT });
			@node((Label) { .text = "Model units along the world axes · Y is up, +Z is the front of a glTF model.",
				.size = 12, .color = TEXT_DIM });

			@tree((Row) { .gap = 10 })
			{
				@node((Label) { .text = "X", .size = 14, .color = TEXT_DIM });
				@node((TextField) { .width = 80, .style = TEXT_FIELD_STYLE,
					.on_submit = &move_by_entered }).with_id(MOVE_BY_X_ID);
				@node((Label) { .text = "Y", .size = 14, .color = TEXT_DIM });
				@node((TextField) { .width = 80, .style = TEXT_FIELD_STYLE,
					.on_submit = &move_by_entered }).with_id(MOVE_BY_Y_ID);
				@node((Label) { .text = "Z", .size = 14, .color = TEXT_DIM });
				@node((TextField) { .width = 80, .style = TEXT_FIELD_STYLE,
					.on_submit = &move_by_entered }).with_id(MOVE_BY_Z_ID);
			};

			@tree((Row) { .gap = 10 })
			{
				@node(accent_button("Move", &apply_move_by));
				@node(panel_button("Cancel", &close_move_by_dialog));
			};
		};
	};

	foreach (id : (String[]) { MOVE_BY_X_ID, MOVE_BY_Y_ID })
	{
		Element* field = body.find_id(id)!!;
		field.widget_as(TextField).set_text(field, "0");
	}
	// Z first: moving a character forward or back is the nudge this is for.
	focus_field(body, MOVE_BY_Z_ID, "0");
	return body;
}

fn void move_by_entered(Ui* ui, String value) => apply_move_by(ui);

fn float? move_by_axis(Ui* ui, String id) @private
{
	String text = field_text(ui, id);
	if (text.len == 0) return 0.0f;
	float value = text.to_float()!;
	if (!math::is_finite(value)) return NOT_FOUND~;
	return value;
}

fn void apply_move_by(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	float? x = move_by_axis(ui, MOVE_BY_X_ID);
	float? y = move_by_axis(ui, MOVE_BY_Y_ID);
	float? z = move_by_axis(ui, MOVE_BY_Z_ID);
	if (catch x, y, z)
	{
		app.@notice("enter a number for each axis, 0 to leave it");
		app.refresh_ui();
		return;
	}

	String subject = move_by_subject(app);
	switch (app.move_selection_by({ x, y, z }))
	{
		case MOVED:
			close_move_by_dialog(ui);
			app.@notice("moved %s by (%.4g, %.4g, %.4g)", subject, x, y, z);
		case UNCHANGED:
			app.@notice("an offset of 0 leaves %s where it is", subject);
		case LOCKED:
			app.@notice("finish animation posing before editing the rest skeleton");
		case REFUSED:
			app.@notice("select the model, skeleton, or joints to move");
	}
	app.refresh_ui();
}

// ---------------------------------------------------------------------------
// Scale model…
//
// Two ways to say one size: the height the model should stand, or the factor
// to grow it by. Typing in either rewrites the other, so the dialog always
// shows both answers to the same question.

fn void scene_context_scale_model(Ui* ui)
{
	close_scene_context(ui);
	open_scale_model_dialog(ui);
}

<*
 Raise the Scale model dialog, from the model's right-click menu: the exact
 height, where the Scale tool is the hand.
*>
fn void open_scale_model_dialog(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (app.model_height() <= 0.0f)
	{
		app.@notice("open a model to scale");
		app.refresh_ui();
		return;
	}
	set_dialog_open(ui, SCALE_MODEL_DIALOG_ID, true);
}

fn void close_scale_model_dialog(Ui* ui) => set_dialog_open(ui, SCALE_MODEL_DIALOG_ID, false);

fn Element* build_scale_model_body(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	float height = app.model_height();
	Element* body = @subtree(ui)
	{
		@tree((Column) { .size = { 380, 0 }, .gap = 10 })
		{
			@node((Label) { .text = string::tformat("Resize the model, its rig and its reaches together. It stands %.4g units tall now.", height),
				.size = 14, .color = TEXT, .overflow = WRAP });
			@node((Label) { .text = "About the model's origin, so its feet stay on the floor. Clips play the same at any size.",
				.size = 12, .color = TEXT_DIM, .overflow = WRAP });

			@tree((Row) { .gap = 10 })
			{
				@node((Label) { .text = "Height", .size = 14, .color = TEXT_DIM });
				@node((TextField) { .width = 90, .style = TEXT_FIELD_STYLE,
					.on_submit = &scale_model_entered, .on_change = &scale_model_height_typed }).with_id(SCALE_MODEL_HEIGHT_ID);
				@node((Label) { .text = "Factor", .size = 14, .color = TEXT_DIM });
				@node((TextField) { .width = 90, .style = TEXT_FIELD_STYLE,
					.on_submit = &scale_model_entered, .on_change = &scale_model_factor_typed }).with_id(SCALE_MODEL_FACTOR_ID);
			};

			@tree((Row) { .gap = 10 })
			{
				@node(accent_button("Scale", &apply_scale_model));
				@node(panel_button("Cancel", &close_scale_model_dialog));
			};
		};
	};

	Element* factor = body.find_id(SCALE_MODEL_FACTOR_ID)!!;
	factor.widget_as(TextField).set_text(factor, "1");
	// Height first: "make it 1.8 tall" is the question this is usually asked.
	focus_field(body, SCALE_MODEL_HEIGHT_ID, string::tformat("%.4g", height));
	return body;
}

// The other field, rewritten to agree with the one being typed in. A field that
// does not read as a positive number leaves its partner alone until it does.
fn void scale_model_height_typed(Ui* ui, String text)
{
	AppState* app = ui.inherit(AppState)!!;
	float now = app.model_height();
	float? height = text.trim().to_float();
	if (catch height) return;
	if (now <= 0.0f || height <= 0.0f) return;
	set_field(ui, SCALE_MODEL_FACTOR_ID, string::tformat("%.4g", height / now));
}

fn void scale_model_factor_typed(Ui* ui, String text)
{
	AppState* app = ui.inherit(AppState)!!;
	float? factor = text.trim().to_float();
	if (catch factor) return;
	if (factor <= 0.0f) return;
	set_field(ui, SCALE_MODEL_HEIGHT_ID, string::tformat("%.4g", app.model_height() * factor));
}

fn void set_field(Ui* ui, String id, String text) @private
{
	if (try Element* field = ui.find_id(id)) field.widget_as(TextField).set_text(field, text);
}

fn void scale_model_entered(Ui* ui, String value) => apply_scale_model(ui);

fn void apply_scale_model(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	// The factor field is the one both fields agree through; reading it means a
	// height typed and then Return-ed scales by exactly what the dialog showed.
	float? factor = field_text(ui, SCALE_MODEL_FACTOR_ID).to_float();
	if (catch factor)
	{
		app.@notice("enter a height or a factor");
		app.refresh_ui();
		return;
	}

	float before = app.model_height();
	switch (app.scale_model_by(factor))
	{
		case SCALED:
			close_scale_model_dialog(ui);
			app.@notice("scaled the model ×%.4g · %.4g → %.4g units tall · Ctrl+Z undoes it",
				factor, before, app.model_height());
		case UNCHANGED:
			app.@notice("a factor of 1 leaves the model the size it is");
		case LOCKED:
			app.@notice("finish the pose edit before resizing the model");
		case REFUSED:
			app.@notice("scale by a factor between %.4g and %.4g", SCALE_MODEL_MIN, SCALE_MODEL_MAX);
	}
	app.refresh_ui();
}

<*
 Take the character being edited out of the scene, asking first when it holds
 work no save has written — the removal frees it, and there is no undo across it.
*>
fn void scene_context_remove_character(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	close_scene_context(ui);
	if (app.character_count() < 2) return;
	if (!app.unsaved())
	{
		remove_focused_character(ui);
		return;
	}
	Element*? panel = ui.find_id(CONFIRM_DIALOG_ID);
	if (catch panel) return;
	panel.widget_as(ConfirmDialog).ask(panel,
		string::tformat("%s has unsaved changes. Remove it from the scene anyway?", app.label()),
		&remove_focused_character, &keep_focused_character);
}

fn void remove_focused_character(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	String name = app.label().copy(mem);
	defer name.free(mem);
	if (app.remove_character(app.active)) app.@notice("Removed %s from the scene", name);
	app.refresh_ui();
}

fn void keep_focused_character(Ui* ui) @private
{
}
