// Secondary animation workflows use the same cui forms and dialogs as rigging.
module crig;
import cui;
import cui::widgets;
import std::math;

fn void anim_tracks_toggled(Ui* ui, bool checked)
{
	AppState* app = ui.inherit(AppState)!!;
	app.anim_show_tracks = checked;
	// A hidden sparse selection must not make Poses-mode copy/delete operate on
	// channels the user can no longer see (and vice versa for whole columns).
	app.clear_animation_key_selection();
	refresh_animations_view(ui);
}

fn void anim_tracks_selected_only_toggled(Ui* ui, bool checked)
{
	AppState* app = ui.inherit(AppState)!!;
	app.anim_tracks_selected_only = checked;
	app.clear_animation_key_selection();
	refresh_animations_view(ui);
}

fn void anim_copy_key_clicked(Ui* ui)
{
	if (!anim_can_rewrite(ui)) return;
	AppState* app = ui.inherit(AppState)!!;
	if (app.animation_key_selection_count(app.editing) > 0
		|| app.animation_channel_key_selection_count(app.editing) > 0)
	{
		app.copy_selected_animation_keys(app.editing);
	}
	else
	{
		app.copy_animation_key(app.editing, anim_live_time(app));
	}
}

fn void anim_paste_key_clicked(Ui* ui)
{
	if (!anim_can_rewrite(ui)) return;
	AppState* app = ui.inherit(AppState)!!;
	if (app.paste_animation_keys(app.editing, anim_live_time(app)))
	{
		anim_normalize_selection_for_view(app);
	}
}

const String ANIM_COPY_POSE_ID = "anim-copy-pose";
const String ANIM_PASTE_POSE_ID = "anim-paste-pose";
const String ANIM_PASTE_MIRRORED_ID = "anim-paste-pose-mirrored";
const String ANIM_MIRROR_POSE_ID = "anim-mirror-pose";

// The pose buttons are the viewport chords with a label. They are not behind
// `anim_can_rewrite`: a pending draft is exactly the pose someone wants to copy
// or mirror, and a paste over one keeps whatever it does not overwrite — see
// `AppState.land_pose`. A running preview is parked first, as Save pose does,
// so the pose in hand is the frame on screen.
fn void anim_pose_op(Ui* ui, PoseOp op) @private
{
	AppState* app = ui.inherit(AppState)!!;
	if (!app.clip(app.editing))
	{
		app.@notice("pick an animation to edit first");
		return;
	}
	if (app.animating && !app.anim_paused) anim_seek(ui, anim_live_time(app));
	switch (op)
	{
		case COPY: app.copy_pose();
		case PASTE: app.paste_pose();
		case PASTE_MIRRORED: app.paste_pose(flipped: true);
		case MIRROR: app.mirror_pose();
	}
	refresh_pose_views(ui);
}

enum PoseOp @private
{
	COPY,
	PASTE,
	PASTE_MIRRORED,
	MIRROR,
}

fn void anim_copy_pose_clicked(Ui* ui) @private => anim_pose_op(ui, COPY);
fn void anim_paste_pose_clicked(Ui* ui) @private => anim_pose_op(ui, PASTE);
fn void anim_paste_pose_mirrored_clicked(Ui* ui) @private => anim_pose_op(ui, PASTE_MIRRORED);
fn void anim_mirror_pose_clicked(Ui* ui) @private => anim_pose_op(ui, MIRROR);

fn void anim_choose_clip(Ui* ui, usz row)
{
	AppState* app = ui.inherit(AppState)!!;
	if (!anim_allow_navigation(ui, 3, 0, row)) return;
	if (row >= (usz)app.doc.animations.len()) return;
	if (!app.resolve_bound((sz)row).valid())
	{
		// Picked, so the clip menu's Remove from character acts on it.
		app.anim_selected = row;
		app.@notice("%s is missing. Restore its library file, or use ⋯ > Remove from character.",
			app.doc.animations[(sz)row].clip);
		refresh_animations_view(ui);
		return;
	}
	app.anim_selected = row;
	anim_edit_selected(ui);
	refresh_animations_view(ui);
}

<*
 The ⋯ clip menu: everything done to the clip as a whole, under the pointer.
*>
fn void anim_clip_menu_clicked(Ui* ui)
{
	Element*? elem = ui.find_id(ANIM_CLIP_MENU_ID);
	if (catch elem) return;
	Dialog* menu = elem.widget_as(Dialog);
	menu.at = ui.input.mouse;
	menu.placed = true;
	menu.set_open(elem, true);
}

fn void anim_clip_menu_closed(Ui* ui) => set_dialog_open(ui, ANIM_CLIP_MENU_ID, false);

const String ANIM_NEW_MENU_ID = "anim-new-menu";
const String ANIM_NEW_MENU_BUTTON_ID = "anim-new-menu-button";
const String ANIM_TOOLS_MENU_ID = "anim-tools-menu";
const String ANIM_TOOLS_BUTTON_ID = "anim-tools";
const String ANIM_NEW_EMPTY_ID = "anim-new";
const String ANIM_GENERATE_ID = "anim-generate";

// A popup menu opened where the pointer is, the way the ⋯ menu is.
fn void open_anim_popup(Ui* ui, String id) @private
{
	Element*? elem = ui.find_id(id);
	if (catch elem) return;
	Dialog* menu = elem.widget_as(Dialog);
	menu.at = ui.input.mouse;
	menu.placed = true;
	menu.set_open(elem, true);
}

fn void anim_new_menu_clicked(Ui* ui) => open_anim_popup(ui, ANIM_NEW_MENU_ID);
fn void anim_tools_menu_clicked(Ui* ui) => open_anim_popup(ui, ANIM_TOOLS_MENU_ID);

// The + New menu: where a clip comes from. Each row closes the menu before it
// acts, as the ⋯ menu's do, so the dialog it opens is not stacked under a popup.
fn void anim_new_menu_empty(Ui* ui)
{
	set_dialog_open(ui, ANIM_NEW_MENU_ID, false);
	anim_new_clip_clicked(ui);
}

fn void anim_new_menu_gait(Ui* ui)
{
	set_dialog_open(ui, ANIM_NEW_MENU_ID, false);
	anim_gait_clicked(ui);
}

fn void anim_new_menu_generate(Ui* ui)
{
	set_dialog_open(ui, ANIM_NEW_MENU_ID, false);
	anim_generate_clicked(ui);
}

fn void anim_new_menu_library(Ui* ui)
{
	set_dialog_open(ui, ANIM_NEW_MENU_ID, false);
	anim_from_library_clicked(ui);
}

fn Element* build_anim_new_menu(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	String generate = app.motion_job.running ? "Generating…" : "Generate…";
	MenuStyle style = VIEW_MENU_STYLE.resolved();
	float width = widgets::PANEL_MIN_W;
	foreach (label : (String[]) { "Empty animation…", "Gait…", generate, "From library…" })
	{
		width = math::max(width, widgets::CHECK_GUTTER + ui.text.measure(style.font, label, style.text_size).x + 2 * style.pad_x);
	}
	return @subtree(ui)
	{
		@tree((Column) { })
		{
			@node((PopupMenuItem) { .item = { .label = "Empty animation…", .on_select = &anim_new_menu_empty },
				.style = VIEW_MENU_STYLE, .width = width }).with_id(ANIM_NEW_EMPTY_ID);
			@node((PopupMenuItem) { .item = { .label = "Gait…", .on_select = &anim_new_menu_gait },
				.style = VIEW_MENU_STYLE, .width = width }).with_id(GAIT_BUTTON_ID);
			@node((PopupMenuItem) { .item = { .label = generate, .on_select = &anim_new_menu_generate },
				.style = VIEW_MENU_STYLE, .width = width }).with_id(ANIM_GENERATE_ID);
			@node((PopupMenuItem) { .item = { .label = "From library…", .on_select = &anim_new_menu_library },
				.style = VIEW_MENU_STYLE, .width = width }).with_id(ANIM_FROM_LIBRARY_ID);
		};
	};
}

// The Clip tools menu: what is done to the clip as a whole, apart from its keys.
fn void anim_tools_check(Ui* ui)
{
	set_dialog_open(ui, ANIM_TOOLS_MENU_ID, false);
	anim_check_clicked(ui);
}

fn void anim_tools_plant_feet(Ui* ui)
{
	set_dialog_open(ui, ANIM_TOOLS_MENU_ID, false);
	anim_plant_feet_clicked(ui);
}

fn void anim_tools_contact(Ui* ui)
{
	set_dialog_open(ui, ANIM_TOOLS_MENU_ID, false);
	anim_add_contact_clicked(ui);
}

fn void anim_tools_prevent(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	set_dialog_open(ui, ANIM_TOOLS_MENU_ID, false);
	anim_prevent_toggled(ui, app.doc.allow_intersections);
}

fn Element* build_anim_tools_menu(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	bool none = app.clip(app.editing) == null;
	MenuStyle style = VIEW_MENU_STYLE.resolved();
	float width = widgets::PANEL_MIN_W;
	foreach (label : (String[]) { "Check", "Plant feet", "Add contact", "Remove movement…", "Optimize keys…", "Prevent intersections" })
	{
		width = math::max(width, widgets::CHECK_GUTTER + ui.text.measure(style.font, label, style.text_size).x + 2 * style.pad_x);
	}
	return @subtree(ui)
	{
		@tree((Column) { })
		{
			@node((PopupMenuItem) { .item = { .label = "Check", .on_select = &anim_tools_check, .disabled = none },
				.style = VIEW_MENU_STYLE, .width = width }).with_id(ANIM_CHECK_ID);
			@node((PopupMenuItem) { .item = { .label = "Plant feet", .on_select = &anim_tools_plant_feet, .disabled = none },
				.style = VIEW_MENU_STYLE, .width = width }).with_id(ANIM_PLANT_FEET_ID);
			@node((PopupMenuItem) { .item = { .label = "Add contact", .on_select = &anim_tools_contact,
				.disabled = none || app.anim_show_curves }, .style = VIEW_MENU_STYLE, .width = width }).with_id(ANIM_ADD_CONTACT_ID);
			@node((PopupMenuItem) { .item = { .label = "Remove movement…", .on_select = &anim_tools_motion, .disabled = none },
				.style = VIEW_MENU_STYLE, .width = width }).with_id(ANIM_MOTION_ID);
			@node((PopupMenuItem) { .item = { .label = "Optimize keys…", .on_select = &anim_tools_optimize, .disabled = none },
				.style = VIEW_MENU_STYLE, .width = width }).with_id(ANIM_OPTIMIZE_ID);
			// The one normal collision control; the rest is behind the clip menu's
			// Collision — and none of it with the system switched off in Settings.
			if (app.config.self_collision)
			{
				@node((PopupMenuItem) { .item = { .label = "Prevent intersections", .on_select = &anim_tools_prevent,
					.checked = !app.doc.allow_intersections }, .style = VIEW_MENU_STYLE, .width = width }).with_id(ANIM_PREVENT_ID);
			}
		};
	};
}

fn void anim_key_context(Ui* ui, TimelineMark mark, Vec2 at)
{
	if (!anim_can_rewrite(ui)) return;
	// Reuse marker selection: an existing group stays selected, while an
	// unselected key becomes the sole target. No modifier toggling on right click.
	anim_mark_pressed(ui, mark, false);
	open_anim_key_context(ui, at);
}

<*
 A right press on the sheet away from every key: the playhead goes to that time
 first, so the menu it opens pastes where the press was rather than where the
 playhead happened to be.

 The same popup as a key's, built for a time with no key under it — which is
 what leaves only Paste in it. Nothing to paste is still a menu, saying so,
 rather than a press that silently did nothing.
*>
fn void anim_space_context(Ui* ui, float at, Vec2 pixel)
{
	if (!anim_can_rewrite(ui)) return;
	anim_seek(ui, at);
	open_anim_key_context(ui, pixel);
}

fn void open_anim_key_context(Ui* ui, Vec2 at) @private
{
	Element* elem = ui.find_id("anim-key-context")!!;
	Dialog* menu = elem.widget_as(Dialog);
	menu.at = at;
	menu.placed = true;
	menu.set_open(elem, true);
}

fn void anim_context_delete(Ui* ui)
{
	set_dialog_open(ui, "anim-key-context", false);
	anim_delete_selection(ui);
}

// The key clipboard's two verbs, off the sheet's own menu. Copy takes the
// selection the right press just made — the pressed key, or the group it was
// already part of — and paste lands at the playhead, which the press put under
// the pointer. The pair used to live behind a dialog, away from the
// keys they act on.
fn void anim_context_copy(Ui* ui)
{
	set_dialog_open(ui, "anim-key-context", false);
	anim_copy_key_clicked(ui);
}

fn void anim_context_paste(Ui* ui)
{
	set_dialog_open(ui, "anim-key-context", false);
	anim_paste_key_clicked(ui);
}

<*
 Set how the selected keys move on to the next one. With nothing selected, the
 key under the playhead is the one meant.
*>
fn void anim_apply_interpolation(Ui* ui, AnimInterpolation interpolation)
{
	AppState* app = ui.inherit(AppState)!!;
	if (!anim_can_rewrite(ui)) return;
	bool none = app.animation_key_selection_count(app.editing) == 0
		&& app.animation_channel_key_selection_count(app.editing) == 0;
	if (none)
	{
		sz key = app.key_near(app.editing, anim_live_time(app), ANIM_SAME_TIME);
		if (key < 0)
		{
			app.@notice("Select keys first; Smooth, Linear and Step apply to the selected keys.");
			return;
		}
		app.select_animation_key(app.editing, app.key_clip(app.editing).keyframes[key].time);
	}
	if (!app.set_selected_animation_interpolation(app.editing, interpolation)) return;
	app.@notice("%s", interpolation == HOLD ? "Keys now hold until the next key."
		: (interpolation == LINEAR ? "Keys now move in a straight line to the next key."
		: "Keys now ease smoothly to the next key."));
	app.show_edited();
}

const String ANIM_CONTEXT_COPY_ID = "anim-context-copy";
const String ANIM_CONTEXT_PASTE_ID = "anim-context-paste";

// Keying at the right-pressed time, and the sheet's view settings: the scoped
// keys and the timing options that had no room in the toolbars.
fn void anim_context_key(Ui* ui)
{
	set_dialog_open(ui, "anim-key-context", false);
	anim_key_clicked(ui);
}

fn void anim_context_key_selected(Ui* ui)
{
	set_dialog_open(ui, "anim-key-context", false);
	anim_key_selected_clicked(ui);
}

fn void anim_context_key_changed(Ui* ui)
{
	set_dialog_open(ui, "anim-key-context", false);
	anim_key_changed_clicked(ui);
}

fn void anim_context_snap(Ui* ui)
{
	set_dialog_open(ui, "anim-key-context", false);
	AppState* app = ui.inherit(AppState)!!;
	anim_snap_toggled(ui, app.anim_snap_off);
}

fn void anim_context_fit(Ui* ui)
{
	set_dialog_open(ui, "anim-key-context", false);
	anim_zoom_fit(ui);
}

// The preview ending, which never changes the saved animation: forced to loop,
// forced to play once, or following the clip's own Loop when neither is ticked.
fn void anim_context_preview_loop(Ui* ui)
{
	set_dialog_open(ui, "anim-key-context", false);
	AppState* app = ui.inherit(AppState)!!;
	anim_preview_loop_chosen(ui, app.anim_preview_loop == LOOP ? (usz)AnimPreviewLoop.FOLLOW_CLIP : (usz)AnimPreviewLoop.LOOP);
}

fn void anim_context_preview_once(Ui* ui)
{
	set_dialog_open(ui, "anim-key-context", false);
	AppState* app = ui.inherit(AppState)!!;
	anim_preview_loop_chosen(ui, app.anim_preview_loop == PLAY_ONCE ? (usz)AnimPreviewLoop.FOLLOW_CLIP : (usz)AnimPreviewLoop.PLAY_ONCE);
}

fn Element* build_anim_key_context(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	usz count = app.animation_key_selection_count(app.editing)
		+ app.animation_channel_key_selection_count(app.editing);
	// Opened on a key, or on empty sheet: the playhead is on the press either
	// way, and whether a key sits there is what decides which menu this is.
	bool on_key = app.key_near(app.editing, anim_live_time(app), ANIM_SAME_TIME) >= 0;
	usz copied = app.anim_key_clipboard.keyframes.len;
	String paste = copied == 0 ? "Nothing copied yet" : "Paste copied keys here";
	// Rows share one width, and the widest label sets it: cui's popup item
	// takes the ordinary dropdown minimum otherwise, which the paste line
	// overruns.
	MenuStyle style = VIEW_MENU_STYLE.resolved();
	float width = widgets::PANEL_MIN_W;
	foreach (label : (String[]) { "Copy selected keys", paste, "Interpolation ▸", "Preview always loops" })
	{
		float wanted = widgets::CHECK_GUTTER + ui.text.measure(style.font, label, style.text_size).x + 2 * style.pad_x;
		width = math::max(width, wanted);
	}
	return @subtree(ui)
	{
		@tree((Column) { })
		{
			if (on_key)
			{
				@node((PopupMenuItem) {
					.item = { .label = count > 1 ? "Copy selected keys" : "Copy key",
						.on_select = &anim_context_copy },
					.style = VIEW_MENU_STYLE, .width = width,
				}).with_id(ANIM_CONTEXT_COPY_ID);
			}
			@node((PopupMenuItem) {
				.item = { .label = paste, .on_select = &anim_context_paste, .disabled = copied == 0 },
				.style = VIEW_MENU_STYLE, .width = width,
			}).with_id(ANIM_CONTEXT_PASTE_ID);
			@node((MenuSeparator) { .style = style, .size = { width, widgets::SEPARATOR_H } });
			if (on_key)
			{
				@node((PopupMenuItem) {
					.item = { .label = "Interpolation ▸", .on_select = &anim_context_interpolation_menu },
					.style = VIEW_MENU_STYLE, .width = width,
				}).with_id(ANIM_CONTEXT_INTERP_ID);
				@node((PopupMenuItem) {
					.item = { .label = count > 1 ? "Delete selected keys" : "Delete key",
						.on_select = &anim_context_delete },
					.style = VIEW_MENU_STYLE, .width = width,
				}).with_id("anim-context-delete");
				@node((MenuSeparator) { .style = style, .size = { width, widgets::SEPARATOR_H } });
			}
			else
			{
				@node((PopupMenuItem) {
					.item = { .label = "Key pose here", .on_select = &anim_context_key },
					.style = VIEW_MENU_STYLE, .width = width,
				}).with_id("anim-context-key");
			}
			@node((PopupMenuItem) {
				.item = { .label = "Key selected joints", .on_select = &anim_context_key_selected },
				.style = VIEW_MENU_STYLE, .width = width,
			}).with_id(ANIM_KEY_SELECTED_ID);
			@node((PopupMenuItem) {
				.item = { .label = "Key changed", .on_select = &anim_context_key_changed },
				.style = VIEW_MENU_STYLE, .width = width,
			}).with_id(ANIM_KEY_CHANGED_ID);
			if (!on_key)
			{
				@node((MenuSeparator) { .style = style, .size = { width, widgets::SEPARATOR_H } });
				@node((PopupMenuItem) {
					.item = { .label = "Snap to frames", .on_select = &anim_context_snap,
						.checked = !app.anim_snap_off },
					.style = VIEW_MENU_STYLE, .width = width,
				}).with_id("anim-snap");
				@node((PopupMenuItem) {
					.item = { .label = "Fit animation in view", .on_select = &anim_context_fit },
					.style = VIEW_MENU_STYLE, .width = width,
				}).with_id("anim-zoom-fit");
				@node((PopupMenuItem) {
					.item = { .label = "Preview always loops", .on_select = &anim_context_preview_loop,
						.checked = app.anim_preview_loop == LOOP },
					.style = VIEW_MENU_STYLE, .width = width,
				}).with_id("anim-preview-loop");
				@node((PopupMenuItem) {
					.item = { .label = "Preview plays once", .on_select = &anim_context_preview_once,
						.checked = app.anim_preview_loop == PLAY_ONCE },
					.style = VIEW_MENU_STYLE, .width = width,
				}).with_id("anim-preview-once");
			}
		};
	};
}

fn void anim_properties_clicked(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (!anim_can_rewrite(ui) || !app.clip(app.editing)) return;
	anim_clip_menu_closed(ui);
	app.anim_edit_properties = true;
	if (try Element* dialog = ui.find_id("anim-new-dialog")) dialog.widget_as(Dialog).title = "Animation settings";
	set_dialog_open(ui, "anim-new-dialog", true);
}

fn void anim_duplicate_clicked(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (!anim_can_rewrite(ui)) return;
	AnimTemplate* clip = app.clip(app.editing);
	if (!clip) return;
	String name = app.unused_clip_name(mem, string::tformat("%s copy", clip.name));
	defer name.free(mem);
	app.clear_animation_key_selection();
	app.editing = app.land_clip(NO_ANIM, clip_copy(mem, *clip, name));
	anim_clip_menu_closed(ui);
	app.show_edited();
}

const String ANIM_DELETE_ID = "anim-delete";
const String ANIM_DELETE_CONFIRM_ID = "anim-delete-confirm";

<*
 Delete the clip being edited, after asking.

 Only a clip the project owns: one read from a library file belongs to that
 file, and Remove from character is how it comes off this character.
*>
fn void anim_delete_clicked(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (!anim_can_rewrite(ui)) return;
	AnimTemplate* clip = app.clip(app.editing);
	if (!clip)
	{
		app.@notice("pick an animation to delete");
		return;
	}
	if (app.editing.pack != app.authored_pack)
	{
		AnimPack* pack = app.pack((usz)app.editing.pack);
		app.@notice("%s is read from %s, so it is not deleted here — Remove from character takes it off this character.",
			clip.name, pack ? base_name(pack.path) : "a library file");
		return;
	}

	Element*? panel = ui.find_id(ANIM_DELETE_CONFIRM_ID);
	if (catch panel)
	{
		app.@notice("nowhere to confirm deleting the animation");
		return;
	}
	anim_clip_menu_closed(ui);
	panel.widget_as(ConfirmDialog).ask(panel,
		string::tformat("Delete %s and its keys? Ctrl+Z brings it back.", clip.name),
		&anim_delete_confirmed);
}

<*
 The confirm's answer: take the edited clip out of the project, one undo step
 that also takes its row off the character.
*>
fn void anim_delete_confirmed(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	AnimTemplate* clip = app.clip(app.editing);
	if (!clip || app.editing.pack != app.authored_pack) return;

	String named = clip.name.copy(mem);
	defer named.free(mem);

	app.let_go_of_clip(app.editing);
	if (!app.delete_authored_clip(named)) return;
	app.undo_stack.commit();
	app.refresh_bound_rows();
	app.@notice("deleted %s · Ctrl+Z brings it back", named);
	app.refresh_ui();
}

fn bool anim_can_rewrite(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (!app.pose_edit_pending) return true;
	app.@notice("Key pose or Revert the changed pose first.");
	return false;
}

<*
 The transport's Loop. On, the clip cycles; if its last key sits on the end with
 another pose, it grows by its last key spacing so the wrap eases back to the
 first pose instead of snapping. One undo step either way.
*>
fn void anim_loop_toggled(Ui* ui, bool checked)
{
	AppState* app = ui.inherit(AppState)!!;
	if (!anim_can_rewrite(ui)) { refresh_animations_view(ui); return; }
	AnimTemplate* clip = app.clip(app.editing);
	if (!clip) return;
	bool extended;
	AnimTemplate changed;
	if (checked)
	{
		changed = clip_looped(mem, *clip, &extended);
	}
	else
	{
		changed = clip_copy(mem, *clip);
		changed.loop = false;
	}
	float before = clip.duration;
	app.editing = app.land_clip(app.editing, changed);
	if (extended)
	{
		AnimTemplate* now = app.clip(app.editing);
		app.@notice("Looping · the end pose differs from the start, so %.2f s were added to ease back to it.",
			now ? now.duration - before : 0.0f);
	}
	app.show_edited();
}

// The clip menu's own rows. Each closes the menu before it acts, as the key
// menu's do, so a dialog it opens is not stacked under a popup.
fn void anim_menu_mirror(Ui* ui)
{
	anim_clip_menu_closed(ui);
	anim_mirror_clicked(ui);
}

fn void anim_menu_close_loop(Ui* ui)
{
	anim_clip_menu_closed(ui);
	anim_close_loop_clicked(ui);
}

fn void anim_menu_unbind(Ui* ui)
{
	anim_clip_menu_closed(ui);
	anim_unbind_clicked(ui);
}

fn void anim_menu_move_up(Ui* ui)
{
	anim_clip_menu_closed(ui);
	move_selected_anim(ui, -1);
}

fn void anim_menu_move_down(Ui* ui)
{
	anim_clip_menu_closed(ui);
	move_selected_anim(ui, 1);
}


fn Element* build_anim_clip_menu(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	AnimTemplate* clip = app.clip(app.editing);
	bool none = clip == null;
	sz row = selected_anim_row(ui);
	sz bound = app.doc.animations.len();
	MenuStyle style = VIEW_MENU_STYLE.resolved();
	float width = widgets::PANEL_MIN_W;
	foreach (label : (String[]) { "Rename / duration…", "Remove from character", "Delete animation…" })
	{
		float wanted = widgets::CHECK_GUTTER + ui.text.measure(style.font, label, style.text_size).x + 2 * style.pad_x;
		width = math::max(width, wanted);
	}
	return @subtree(ui)
	{
		@tree((Column) { })
		{
			@node((PopupMenuItem) { .item = { .label = "Rename / duration…", .on_select = &anim_properties_clicked,
				.disabled = none }, .style = VIEW_MENU_STYLE, .width = width }).with_id("anim-properties");
			@node((PopupMenuItem) { .item = { .label = "Duplicate", .on_select = &anim_duplicate_clicked,
				.disabled = none }, .style = VIEW_MENU_STYLE, .width = width }).with_id("anim-duplicate");
			@node((PopupMenuItem) { .item = { .label = "Stretch timing…", .on_select = &anim_retime_clicked,
				.disabled = none }, .style = VIEW_MENU_STYLE, .width = width }).with_id("anim-retime");
			@node((PopupMenuItem) { .item = { .label = "Trim…", .on_select = &anim_trim_clicked,
				.disabled = none }, .style = VIEW_MENU_STYLE, .width = width }).with_id("anim-trim");
			@node((PopupMenuItem) { .item = { .label = "Mirror animation", .on_select = &anim_menu_mirror,
				.disabled = none }, .style = VIEW_MENU_STYLE, .width = width }).with_id("anim-mirror-clip");
			@node((PopupMenuItem) { .item = { .label = "Close loop", .on_select = &anim_menu_close_loop,
				.disabled = none || !clip.loop }, .style = VIEW_MENU_STYLE, .width = width }).with_id("anim-close-loop");
			@node((PopupMenuItem) { .item = { .label = "Fix mapping…", .on_select = &anim_fix_mapping_clicked,
				.disabled = !app.clip_mappable(app.editing) }, .style = VIEW_MENU_STYLE, .width = width }).with_id(ANIM_FIX_MAPPING_ID);
			if (app.config.self_collision)
			{
				@node((PopupMenuItem) { .item = { .label = "Collision…", .on_select = &collision_dialog_clicked },
					.style = VIEW_MENU_STYLE, .width = width }).with_id("anim-collision");
			}
			@node((MenuSeparator) { .style = style, .size = { width, widgets::SEPARATOR_H } });
			@node((PopupMenuItem) { .item = { .label = "Move up in list", .on_select = &anim_menu_move_up,
				.disabled = row <= 0 }, .style = VIEW_MENU_STYLE, .width = width }).with_id("anim-move-up");
			@node((PopupMenuItem) { .item = { .label = "Move down in list", .on_select = &anim_menu_move_down,
				.disabled = row < 0 || row + 1 >= bound }, .style = VIEW_MENU_STYLE, .width = width }).with_id("anim-move-down");
			@node((MenuSeparator) { .style = style, .size = { width, widgets::SEPARATOR_H } });
			@node((PopupMenuItem) { .item = { .label = "Remove from character", .on_select = &anim_menu_unbind,
				.disabled = row < 0 }, .style = VIEW_MENU_STYLE, .width = width }).with_id(ANIM_UNBIND_ID);
			@node((PopupMenuItem) { .item = { .label = "Delete animation…", .on_select = &anim_delete_clicked,
				.disabled = none }, .style = DANGER_MENU_STYLE, .width = width }).with_id(ANIM_DELETE_ID);
		};
	};
}

fn Element* build_anim_new_body(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	Element* body = @subtree(ui)
	{
		@tree((Column) { .size = { 340, 0 }, .gap = ANIM_GAP })
		{
			@node((Label) { .text = "Name", .size = ANIM_TEXT_SIZE, .color = TEXT_DIM });
			@node((TextField) { .width = 340, .style = TEXT_FIELD_STYLE }).with_id("anim-new-name");
			@node((Label) { .text = "Duration (seconds)", .size = ANIM_TEXT_SIZE, .color = TEXT_DIM });
			@node((TextField) { .width = 120, .style = TEXT_FIELD_STYLE }).with_id("anim-new-duration");
			@node((Label) { .text = app.anim_edit_properties
				? "Keyframe times stay unchanged."
				: "The rig's rest pose becomes the first keyframe.",
				.size = ANIM_TEXT_SIZE, .color = TEXT_DIM });
			if (app.anim_edit_properties)
			{
				@node((Checkbox) { .label = "Loop animation", .checked = app.clip(app.editing).loop,
					.style = CHECKBOX_STYLE }).with_id("anim-properties-loop");
				@node((Label) { .text = "Controls loop transitions and the default preview.",
					.size = 12, .color = TEXT_DIM });
			}
			else
			{
				@node((Label) { .text = "New clips play once (hold the last pose). Turn on Loop by the play button to cycle.",
					.size = 12, .color = TEXT_DIM });
			}
			@tree((Row) { .gap = ANIM_GAP })
			{
				@node(accent_button(app.anim_edit_properties ? "Apply" : "Create animation", &anim_create_confirmed)).with_id("anim-create");
				@node(panel_button("Cancel", &anim_create_cancelled));
			};
		};
	};
	AnimTemplate* clip = app.anim_edit_properties ? app.clip(app.editing) : null;
	focus_field(body, "anim-new-name", clip ? clip.name : "Animation");
	Element* duration = body.find_id("anim-new-duration")!!;
	duration.widget_as(TextField).set_text(duration, clip ? string::tformat("%.9g", clip.duration) : "2");
	return body;
}

fn void anim_create_cancelled(Ui* ui) => set_dialog_open(ui, "anim-new-dialog", false);

fn void anim_create_confirmed(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	String name = field_text(ui, "anim-new-name");
	float? parsed = field_text(ui, "anim-new-duration").to_float();
	if (catch parsed) { app.@notice("Enter a duration in seconds, for example 2."); return; }
	float duration = parsed;
	if (!(duration > 0 && duration <= 3600)) { app.@notice("Duration must be between 0 and 3600 seconds."); return; }
	if (name.len == 0) { app.@notice("Give the animation a name."); return; }
	if (app.anim_edit_properties)
	{
		AnimTemplate* clip = app.clip(app.editing);
		if (!clip || !anim_can_rewrite(ui)) return;
		AnimRef taken = app.clip_named_in_authored(name);
		if (taken.valid() && !taken.same(app.editing))
		{
			app.@notice("An animation already has that name.");
			return;
		}
		foreach (key : clip.keyframes)
		{
			if (key.time > duration)
			{
				app.@notice("Duration cannot end before the last key.");
				return;
			}
		}
		bool loop = ui.find_id("anim-properties-loop")!!.widget_as(Checkbox).checked;
		if (clip.name == name && clip.duration == duration && clip.loop == loop) { anim_create_cancelled(ui); return; }
		AnimTemplate changed = clip_copy(mem, *clip, name);
		changed.duration = duration;
		changed.loop = loop;
		// Switching Loop on here eases a differing end back, as the transport's does.
		if (loop && !clip.loop)
		{
			changed.loop = false;
			AnimTemplate looped = clip_looped(mem, changed);
			changed.free(mem);
			changed = looped;
		}
		app.editing = app.land_clip(app.editing, changed);
		app.edit_time = math::min(app.edit_time, duration);
		anim_create_cancelled(ui);
		app.show_edited();
		return;
	}
	// A new hand-authored clip plays once — it holds its last pose so keying a fall
	// (or any one-shot) carries straight on instead of springing back to the first
	// pose. The Loop toggle beside Auto-key opts the clip into a cycle afterwards.
	AnimRef made = app.new_clip(name, duration, from_rest: true, loop: false);
	if (!made.valid()) return;
	anim_create_cancelled(ui);
	// The rest pose already occupies 0.00 s. Leaving the playhead on it makes the
	// first automatic key replace that existing pose, so the sheet still shows
	// one marker and playback stays static — indistinguishable from Auto-key being
	// off. Put the user at the middle of the new clip, where their first pose is a
	// visible second key and immediately makes an animation.
	app.edit_time = duration * 0.5f;
	app.show_edited();
	app.@notice("Starting pose keyed at 0.00s. Pose the model at %.2fs; Auto-key will key it.",
		app.edit_time);
}

<*
 Whether navigation may go ahead over a changed, unkeyed pose.

 The pane shows a banner while a pose is pending, so nothing here blocks. With
 Auto-key on the pose is keyed and navigation carries on. With it off, the first
 move is held and the banner asks; a second move, after the pointer has been let
 go, drops the change and goes. Key pose or Revert in the banner finish the held
 move. Core operations and MCP remain explicit, synchronous APIs.
*>
fn bool anim_allow_navigation(Ui* ui, int action, float at = 0, usz row = 0)
{
	AppState* app = ui.inherit(AppState)!!;
	if (!app.pose_edit_pending) return true;
	if (app.auto_key && app.key_pose_edit(CHANGED)) return true;
	if (app.anim_pending_action != 0 && app.anim_pending_armed)
	{
		app.anim_pending_action = 0;
		app.anim_pending_armed = false;
		app.discard_pose_edit();
		app.@notice("dropped the unkeyed pose change");
		return true;
	}
	app.anim_pending_action = action;
	app.anim_pending_time = at;
	app.anim_pending_row = row;
	app.anim_pending_armed = false;
	refresh_animations_view(ui);
	return false;
}

<*
 Arm the "move again drops it" answer once the gesture that was held has ended,
 so the rest of one scrub drag cannot count as the second move.
*>
fn void anim_arm_pending(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (!app.pose_edit_pending)
	{
		app.anim_pending_action = 0;
		app.anim_pending_armed = false;
		return;
	}
	if (app.anim_pending_action != 0 && !ui.input.down[0]) app.anim_pending_armed = true;
}

fn void anim_pending_save(Ui* ui)
{
	if (!ui.inherit(AppState)!!.key_pose_edit(ALL)) return;
	anim_pending_continue(ui);
}

fn void anim_pending_discard(Ui* ui)
{
	ui.inherit(AppState)!!.discard_pose_edit();
	anim_pending_continue(ui);
}

fn void anim_pending_continue(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	int action = app.anim_pending_action;
	float at = app.anim_pending_time;
	usz row = app.anim_pending_row;
	app.anim_pending_action = 0;
	app.anim_pending_armed = false;
	refresh_animations_view(ui);
	switch (action)
	{
		case 1: anim_seek(ui, at);
		case 2: anim_play_pause_clicked(ui);
		case 3: anim_choose_clip(ui, row);
		case 4: anim_new_clip_clicked(ui);
		default: break;
	}
}

<*
 + From library: the Assets tab, narrowed to animations.

 An Assets pane already open is used; otherwise the pane beside this one that is
 neither the model nor the animations, and only as a last resort this pane.
*>
fn void anim_from_library_clicked(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	AssetFilter narrowed = app.asset_filter;
	narrowed.any_kind = false;
	narrowed.kind = ANIMATION;
	narrowed.any_plan = true;
	narrowed.plan = "";
	narrowed.current_file = false;
	(void)app.set_asset_filter(narrowed);
	app.refresh_asset_sidebar();

	AreaNode* target = find_leaf_showing(area_layout.root, LIBRARY_VIEW);
	if (!target) target = find_leaf_showing(area_layout.root, SCENE_VIEW);
	if (!target) target = find_other_leaf(area_layout.root);
	if (!target) target = find_leaf_showing(area_layout.root, ANIMATION_VIEW);
	if (!target) return;
	target.active = LIBRARY_VIEW;
	ui.@each(AreaPane; pane)
	{
		if (pane.widget_as(AreaPane).node == target) pane.request_build();
	};
	app.refresh_ui();
}

fn AreaNode* find_leaf_showing(AreaNode* node, usz view) @private
{
	if (!node) return null;
	if (node.is_leaf()) return node.active == view ? node : null;
	AreaNode* found = find_leaf_showing(node.first, view);
	return found ? found : find_leaf_showing(node.second, view);
}

// A leaf showing neither the 3D view nor the animations: a pane the user can
// spare for the library.
fn AreaNode* find_other_leaf(AreaNode* node) @private
{
	if (!node) return null;
	if (node.is_leaf()) return node.active != 0 && node.active != ANIMATION_VIEW ? node : null;
	AreaNode* found = find_other_leaf(node.first);
	return found ? found : find_other_leaf(node.second);
}
