// The pose library, in the N-panel Pose tab: save the pose at the playhead under a
// name, and apply a saved one — whole, mirrored, or to the selected joints only.
// See app/pose_library.c3.
module crig;
import cui;
import cui::widgets;
import std::math;

const String ANIM_POSE_PANEL_ID = "anim-pose-panel";
const String ANIM_POSE_NAME_ID = "anim-pose-name";
const String ANIM_POSE_SAVE_ID = "anim-pose-save";
const String ANIM_POSE_RENAME_CANCEL_ID = "anim-pose-rename-cancel";
const String ANIM_POSE_SELECTED_ONLY_ID = "anim-pose-selected-only";
const String ANIM_POSE_LIST_ID = "anim-pose-list";
const String ANIM_POSE_APPLY_ID = "anim-pose-apply";
const String ANIM_POSE_APPLY_MIRRORED_ID = "anim-pose-apply-mirrored";
const String ANIM_POSE_RENAME_ID = "anim-pose-rename";
const String ANIM_POSE_DELETE_ID = "anim-pose-delete";
// Rows the list shows before it scrolls.
const float ANIM_POSE_ROWS = 5;

fn void anim_pose_name_changed(Ui* ui, String text)
{
	AppState* app = ui.inherit(AppState)!!;
	app.pose_library_name.free(mem);
	app.pose_library_name = text.copy(mem);
}

// Return in the name field does what the button beside it says.
fn void anim_pose_name_submitted(Ui* ui, String text)
{
	anim_pose_name_changed(ui, text);
	anim_pose_save_clicked(ui);
}

fn void anim_pose_save_clicked(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	String name = field_text(ui, ANIM_POSE_NAME_ID);
	if (app.pose_library_renaming)
	{
		if (app.rename_saved_pose(app.pose_library_row, name) || app.doc.poses.len == 0
			|| app.doc.poses[app.pose_library_row].name == name)
		{
			app.pose_library_renaming = false;
			app.pose_library_name.free(mem);
			app.pose_library_name = {};
		}
		refresh_pose_views(ui);
		return;
	}
	if (app.animating && !app.anim_paused) anim_seek(ui, anim_live_time(app));
	if (app.save_named_pose(name) >= 0)
	{
		app.pose_library_name.free(mem);
		app.pose_library_name = {};
	}
	refresh_pose_views(ui);
}

fn void anim_pose_rename_clicked(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (app.pose_library_row >= app.doc.poses.len) return;
	app.pose_library_renaming = true;
	refresh_pose_views(ui);
}

fn void anim_pose_rename_cancelled(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	app.pose_library_renaming = false;
	app.pose_library_name.free(mem);
	app.pose_library_name = {};
	refresh_pose_views(ui);
}

fn void anim_pose_selected_only_toggled(Ui* ui, bool checked)
{
	ui.inherit(AppState)!!.pose_library_selected_only = checked;
	refresh_pose_views(ui);
}

fn void anim_pose_row_chosen(Ui* ui, usz row)
{
	AppState* app = ui.inherit(AppState)!!;
	app.pose_library_row = row;
	app.pose_library_renaming = false;
	refresh_pose_views(ui);
}

fn void anim_pose_apply(Ui* ui, bool mirrored) @private
{
	AppState* app = ui.inherit(AppState)!!;
	if (app.animating && !app.anim_paused) anim_seek(ui, anim_live_time(app));
	app.apply_saved_pose(app.pose_library_row, mirrored, app.pose_library_selected_only);
	refresh_pose_views(ui);
}

fn void anim_pose_apply_clicked(Ui* ui) => anim_pose_apply(ui, false);
fn void anim_pose_apply_mirrored_clicked(Ui* ui) => anim_pose_apply(ui, true);

fn void anim_pose_delete_clicked(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	app.pose_library_renaming = false;
	app.delete_saved_pose(app.pose_library_row);
	refresh_pose_views(ui);
}

struct AnimPosesPanel (Widget)
{
	TreeRow[] rows;
}

fn void AnimPosesPanel.release(&self)
{
	foreach (row : self.rows)
	{
		row.label.free(mem);
		row.trailing.free(mem);
	}
	if (self.rows.len > 0) alloc::free(mem, self.rows);
	self.rows = {};
}

fn void AnimPosesPanel.unmount(&self, Element* elem) @dynamic => self.release();

fn Element* AnimPosesPanel.build(&self, Element* elem) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	self.release();
	SavedPose[] poses = app.doc.poses;
	if (app.pose_library_row >= poses.len) app.pose_library_row = poses.len > 0 ? poses.len - 1 : 0;
	bool renaming = app.pose_library_renaming && poses.len > 0;
	if (poses.len > 0)
	{
		self.rows = alloc::new_array(mem, TreeRow, poses.len);
		foreach (usz i, pose : poses)
		{
			self.rows[i] = { .label = pose.name.copy(mem), .trailing = string::format(mem, "%d joint%s",
				pose.dots.len, pose.dots.len == 1 ? "" : "s") };
		}
	}
	Element* body = @subtree(elem.ui)
	{
		@tree((Column) { .gap = 4 })
		{
			@tree((Wrap) { .gap_x = ANIM_GAP, .gap_y = 4, .cross_align = CENTER })
			{
				@node((TextField) { .width = 160, .style = TEXT_FIELD_STYLE, .placeholder = "Pose name",
					.on_change = &anim_pose_name_changed, .on_submit = &anim_pose_name_submitted }).with_id(ANIM_POSE_NAME_ID);
				@node(accent_button(renaming ? "Rename" : "Save pose", &anim_pose_save_clicked)).with_id(ANIM_POSE_SAVE_ID);
				if (renaming)
				{
					@node(panel_button("Cancel", &anim_pose_rename_cancelled)).with_id(ANIM_POSE_RENAME_CANCEL_ID);
				}
				@node((Checkbox) { .label = "Selected joints only", .checked = app.pose_library_selected_only,
					.on_change = &anim_pose_selected_only_toggled, .style = CHECKBOX_STYLE }).with_id(ANIM_POSE_SELECTED_ONLY_ID);
			};
			if (self.rows.len > 0)
			{
				@tree((Scroll) { .size = { 0, math::min((float)self.rows.len, ANIM_POSE_ROWS) * TREE_STYLE.row_height } })
				{
					@node((Tree) { .rows = self.rows, .selected = app.pose_library_row, .on_select = &anim_pose_row_chosen,
						.style = TREE_STYLE }).with_id(ANIM_POSE_LIST_ID);
				};
				@tree((Wrap) { .gap_x = ANIM_GAP, .gap_y = 4, .cross_align = CENTER })
				{
					@node(panel_button("Apply", &anim_pose_apply_clicked)).with_id(ANIM_POSE_APPLY_ID);
					@node(panel_button("Apply mirrored", &anim_pose_apply_mirrored_clicked)).with_id(ANIM_POSE_APPLY_MIRRORED_ID);
					@node(panel_button("Rename…", &anim_pose_rename_clicked)).with_id(ANIM_POSE_RENAME_ID);
					@node(panel_button("Delete", &anim_pose_delete_clicked)).with_id(ANIM_POSE_DELETE_ID);
				};
			}
			if (self.rows.len == 0)
			{
				@node((Label) { .text = "No saved poses yet. Pose the character, then Save pose (the selected joints, or all). The agent can read saved poses by name.",
					.size = ANIM_TEXT_SIZE, .color = TEXT_DIM });
			}
		};
	};

	// Through the subtree: the field is not attached yet.
	if (try Element* field = body.find_id(ANIM_POSE_NAME_ID))
	{
		TextField* text = field.widget_as(TextField);
		if (renaming)
		{
			text.set_text(field, poses[app.pose_library_row].name);
			text.select_all(field);
			field.request_focus();
		}
		else if (app.pose_library_name.len > 0)
		{
			text.set_text(field, app.pose_library_name);
		}
		else
		{
			text.set_text(field, app.next_pose_name(tmem));
		}
	}
	return body;
}

fn Vec2 AnimPosesPanel.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	Vec2 own = elem.layout_child(0, constraints);
	elem.place_child(0, { 0, 0 });
	return own;
}
