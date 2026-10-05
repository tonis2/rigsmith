module crig;

import cui;
import cui::widgets;
import std::math;

const String SKELETON_ROTATION_DIALOG_ID = "skeleton-rotation-dialog";
const String SKELETON_ROTATION_AXIS_ID = "skeleton-rotation-axis";
const String SKELETON_ROTATION_ANGLE_ID = "skeleton-rotation-angle";

String[3] skeleton_rotation_axes = { "X axis", "Y axis (up)", "Z axis" };

fn void open_skeleton_rotation_dialog(Ui* ui)
{
	set_dialog_open(ui, SKELETON_ROTATION_DIALOG_ID, true);
}

fn void close_skeleton_rotation_dialog(Ui* ui)
{
	set_dialog_open(ui, SKELETON_ROTATION_DIALOG_ID, false);
}

fn Element* build_skeleton_rotation_body(Ui* ui)
{
	Element* body = @subtree(ui)
	{
		@tree((Column) { .size = { 390, 0 }, .gap = 10 })
		{
			@node((Label) { .text = "Rotate every joint around the model's centre.",
				.size = 14, .color = TEXT });
			@node((Label) { .text = "The mesh stays fixed, correcting a body plan that faces the wrong way.",
				.size = 12, .color = TEXT_DIM });

			@node((Label) { .text = "Axis", .size = 14, .color = TEXT_DIM });
			@node((Select) { .options = skeleton_rotation_axes[..], .selected = 1,
				.width = 180, .style = VIEW_MENU_STYLE }).with_id(SKELETON_ROTATION_AXIS_ID);

			@node((Label) { .text = "Angle (degrees)", .size = 14, .color = TEXT_DIM });
			@node((TextField) { .width = 180, .style = TEXT_FIELD_STYLE,
				.on_submit = &skeleton_rotation_entered }).with_id(SKELETON_ROTATION_ANGLE_ID);
			@node((Label) { .text = "For an upright glTF rig facing backward, use Y and 180°.",
				.size = 12, .color = TEXT_DIM });

			@tree((Row) { .gap = 10 })
			{
				@node(accent_button("Rotate skeleton", &apply_skeleton_rotation));
				@node(panel_button("Cancel", &close_skeleton_rotation_dialog));
			};
		};
	};

	focus_field(body, SKELETON_ROTATION_ANGLE_ID, "180");
	return body;
}

fn void skeleton_rotation_entered(Ui* ui, String value) => apply_skeleton_rotation(ui);

fn void apply_skeleton_rotation(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	Select*? chosen = ui.get_widget_id(SKELETON_ROTATION_AXIS_ID, Select);
	if (catch chosen) return;
	if (chosen.selected > 2) return;

	float? parsed = field_text(ui, SKELETON_ROTATION_ANGLE_ID).to_float();
	if (catch parsed)
	{
		app.@notice("Enter an angle between -3600 and 3600 degrees.");
		return;
	}
	if (!math::is_finite(parsed) || math::abs(parsed) > 3600.0f)
	{
		app.@notice("Enter an angle between -3600 and 3600 degrees.");
		return;
	}

	float degrees = parsed;
	usz moved = app.rotate_skeleton((int)chosen.selected, math::deg_to_rad(degrees));
	if (moved == 0)
	{
		app.@notice("That rotation leaves the skeleton where it is.");
		return;
	}

	close_skeleton_rotation_dialog(ui);
	app.refresh_pose_display();
	app.@notice("rotated %d joint%s %.3g° around %s", moved, moved == 1 ? "" : "s",
		degrees, skeleton_rotation_axes[chosen.selected]);
	app.refresh_ui();
}
