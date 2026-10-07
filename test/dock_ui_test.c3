<*
 The Animations dock re-plan: the dock split into a clip manager and a Layers
 column, the Pose tab of the N-panel, and the Joints stage that greys out the key
 row and the Layers column.

     `c3c test --trust=full --test-noleak --test-filter crig_tests::ui::dock`
*>
module crig_tests::ui;

import crig;
import cui;
import cui::widgets;
import std::core::test;
import std::math;

// A biped and a clip to pose, the N-panel's Pose tab up.
fn void dock_pose_workspace(Fixture* f)
{
	test::@check(f.app.apply_plan_named("biped"), "could not fit a rig");
	f.app.editing = f.app.new_clip("Posing", 2, from_rest: true);
	f.app.show_edited();
	f.open_pose_tab();
}

fn void dock_pose_tab_holds_the_posing_controls() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	dock_pose_workspace(&f);

	test::@check(f.app.joint_panel_tab == crig::JointPanelTab.POSE, "the Pose tab did not open");
	foreach (id : (String[]) { crig::POSE_SECTION_ID, crig::POSE_OPTIONS_SECTION_ID, crig::POSE_LIBRARY_SECTION_ID,
		"anim-reset-pose", crig::ANIM_MIRROR_POSE_ID, crig::ANIM_COPY_POSE_ID, crig::ANIM_PASTE_POSE_ID,
		crig::ANIM_PASTE_MIRRORED_ID, crig::ANIM_BALANCE_ID, crig::POSE_PINS_ID,
		crig::ANIM_POSE_PANEL_ID, crig::ANIM_POSE_SAVE_ID })
	{
		test::@check(f.in_tree(id), "the Pose tab has no %s", id);
	}
	test::@check(f.in_tree(crig::POSE_PIN_NONE_ID), "an empty pin list does not say so");

	// Off the dock: none of them is in the Animations pane any more.
	if (try Element* strip = f.ui.find(AreaTabStrip)) f.click(tab_center(&f, strip, TAB_ANIMATIONS));
	f.ui.flush();
	foreach (id : (String[]) { "anim-reset-pose", crig::ANIM_MIRROR_POSE_ID, crig::ANIM_COPY_POSE_ID,
		crig::ANIM_PASTE_POSE_ID, crig::ANIM_PASTE_MIRRORED_ID, crig::ANIM_BALANCE_ID, crig::ANIM_POSE_PANEL_ID,
		"anim-pin-feet", "anim-poses" })
	{
		test::@check(!f.in_tree(id), "the dock still has %s", id);
	}
}

fn void dock_pose_tab_lists_the_pins_and_clears_them() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	dock_pose_workspace(&f);

	Dot* hips = f.app.dot_named("hips");
	test::@check(hips != null, "the biped has no hips");
	if (!hips) return;
	uint id = hips.id;
	f.app.set_anchor(id, true, true);
	f.feed({ 0, 0 });
	f.feed({ 0, 0 });
	test::@check(!f.in_tree(crig::POSE_PIN_NONE_ID) && f.in_tree(crig::POSE_PIN_LIST_ID), "the pin is not listed");
	Tree* list = f.ui.find_id(crig::POSE_PIN_LIST_ID)!!.widget_as(Tree);
	test::@check(list.rows.len == 1, "the list has %d rows", (int)list.rows.len);
	test::@check(list.rows[0].label == "hips" && list.rows[0].trailing == "position + angle",
		"the row does not say what is held (%s, %s)", list.rows[0].label, list.rows[0].trailing);

	// A row selects its joint.
	f.app.select(0);
	f.feed({ 0, 0 });
	Element* row = f.ui.find_id(crig::POSE_PIN_LIST_ID)!!;
	f.click(row.absolute + (Vec2){ row.size.x * 0.5f, crig::TREE_STYLE.row_height * 0.5f });
	test::@check(f.app.selected == id, "the row did not select its joint");

	f.click(f.center_of(crig::POSE_PIN_CLEAR_ID)!!);
	f.feed({ 0, 0 });
	f.feed({ 0, 0 });
	test::@check(f.app.position_locks.len == 0, "Clear all left pins");
	test::@check(f.in_tree(crig::POSE_PIN_NONE_ID), "a cleared list is still listed");
}

fn void dock_pose_tab_remembers_folded_sections_and_the_tab() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	dock_pose_workspace(&f);

	test::@check(!f.app.pose_info_collapsed, "the sections start folded");
	crig::pose_section_changed(f.ui, false);
	test::@check(f.app.pose_info_collapsed, "folding a section was not kept");
	crig::pose_library_section_changed(f.ui, false);
	test::@check(f.app.config.folded_sections == ((1u << crig::FoldedSection.POSE_INFO.ordinal)
		| (1u << crig::FoldedSection.POSE_LIBRARY.ordinal)), "the folds did not reach the config");
	test::@check(f.app.config.joint_panel_tab == (int)crig::JointPanelTab.POSE.ordinal, "the tab did not reach the config");

	// Another run reads them back.
	f.app.pose_info_collapsed = false;
	f.app.pose_library_collapsed = false;
	f.app.joint_panel_tab = crig::JointPanelTab.JOINT;
	f.app.restore_ui_memory();
	test::@check(f.app.pose_info_collapsed && f.app.pose_library_collapsed && !f.app.pose_options_collapsed,
		"the folded sections did not come back");
	test::@check(f.app.joint_panel_tab == crig::JointPanelTab.POSE, "the open tab did not come back");
}

fn void dock_splits_into_clips_and_layers() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	lyr_workspace(&f);

	Element* clips = f.ui.find_id(crig::ANIM_CLIP_SIDE_ID)!!;
	Element* layers = f.ui.find_id(crig::ANIM_LAYERS_SIDE_ID)!!;
	Element* divider = f.ui.find_id(crig::ANIM_DIVIDER_ID)!!;
	test::@check(clips.size.x > layers.size.x * 2.5f && clips.size.x < layers.size.x * 3.5f,
		"the clip manager is not about three quarters (%s vs %s)", clips.size.x, layers.size.x);
	test::@check(divider.absolute.x >= clips.absolute.x + clips.size.x
		&& layers.absolute.x >= divider.absolute.x + divider.size.x, "the divider is not between the sides");

	// The clips' controls on the left, the layers' on the right.
	test::@check(f.ui.find_id(crig::ANIM_KEY_ID)!!.absolute.x < divider.absolute.x, "Key pose is not in the clip manager");
	test::@check(f.ui.find_id(crig::ANIM_LAYER_ADD_ID)!!.absolute.x > divider.absolute.x, "+ is not in the Layers column");
	test::@check(f.ui.find(Timeline)!!.absolute.x < divider.absolute.x, "the sheet is not in the clip manager");

	// The retired buttons are gone from the header.
	foreach (id : (String[]) { "anim-pin-feet", crig::ANIM_CHECK_ID, crig::ANIM_PLANT_FEET_ID, crig::ANIM_ADD_CONTACT_ID,
		"anim-ghosts", "anim-path" })
	{
		test::@check(!f.in_tree(id), "the dock still shows %s", id);
	}
	foreach (id : (String[]) { crig::ANIM_NEW_MENU_BUTTON_ID, crig::ANIM_MORE_ID, crig::ANIM_TOOLS_BUTTON_ID,
		crig::ANIM_INTERP_ID })
	{
		test::@check(f.in_tree(id), "the dock has no %s", id);
	}

	// The sheet fills what the rows leave: taller than the old five rows, and ending
	// above the status bar.
	Element* slot = f.ui.find_id(crig::ANIM_SHEET_SLOT_ID)!!;
	test::@check(slot.size.y > crig::ANIM_SHEET_H, "the sheet is still the fixed five rows (%s)", slot.size.y);
	test::@check(slot.absolute.y + slot.size.y <= clips.absolute.y + clips.size.y, "the sheet runs off the dock");

	// Dragging the divider left widens the Layers column, and the release keeps it.
	float before = layers.size.x;
	Vec2 at = f.center_of(crig::ANIM_DIVIDER_ID)!!;
	f.feed(at);
	f.feed(at, left: true);
	f.feed({ at.x - 150, at.y }, left: true);
	f.feed({ at.x - 150, at.y });
	f.ui.flush();
	test::@check(f.app.config.anim_layers_ratio > 0.25f, "dragging did not move the divider (%s)", f.app.config.anim_layers_ratio);
	test::@check(f.ui.find_id(crig::ANIM_LAYERS_SIDE_ID)!!.size.x > before + 100, "the Layers column did not widen");
}

fn void dock_layers_column_says_so_when_there_is_no_clip() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	f.click(tab_center(&f, f.ui.find(AreaTabStrip)!!, TAB_ANIMATIONS));
	f.ui.flush();

	test::@check(f.in_tree(crig::ANIM_LAYERS_SIDE_ID) && f.in_tree(crig::ANIM_CLIP_SIDE_ID), "the dock has no two columns");
	test::@check(f.in_tree(crig::ANIM_LAYERS_EMPTY_ID), "the Layers column has no empty state");
	test::@check(!f.in_tree(crig::ANIM_LAYER_ADD_ID) && !f.in_tree(crig::ANIM_LAYER_TREE_ID),
		"the Layers column offers layers with no clip");
}

fn void dock_joints_stage_greys_out_the_key_row_and_layers() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	lyr_workspace(&f);
	test::@check(f.app.stage == crig::EditStage.POSE_STAGE, "showing a clip did not put the stage on Pose");
	test::@check(!f.in_tree(crig::ANIM_STAGE_SHADE_ID), "the key row is greyed out while posing");

	test::@check(f.app.enter_joint_stage(), "the Joints stage would not open");
	f.feed({ 0, 0 });
	f.feed({ 0, 0 });
	test::@check(f.in_tree(crig::ANIM_STAGE_SHADE_ID), "the key row is not greyed out in the Joints stage");
	test::@check(f.in_tree(crig::ANIM_LAYERS_ID), "the Layers column went away");

	// The key row and the Layers column swallow the pointer.
	f.app.edit_time = 3.0f;
	sz history = f.app.undo_stack.cursor;
	f.click(f.center_of(crig::ANIM_KEY_ID)!!);
	test::@check(f.app.undo_stack.cursor == history, "a greyed-out button acted");
	f.click(f.center_of(crig::ANIM_LAYER_ADD_ID)!!);
	f.ui.flush();
	test::@check(!f.in_tree(crig::ANIM_LAYER_WAVE_ID), "the layer menu opened in the Joints stage");
	// Transport and clip choosing stay live.
	test::@check(f.in_tree(crig::ANIM_TRANSPORT_PLAY_ID) && f.in_tree("anim-chooser"),
		"the transport or the chooser went");
	f.click(f.center_of(crig::ANIM_END_ID)!!);
	test::@check(math::abs(f.app.edit_time - f.app.clip(f.app.editing).duration) < 1.0e-4f,
		"the transport is greyed out as well");

	// Back on Pose, both work again.
	test::@check(f.app.enter_pose_stage(), "the Pose stage would not open");
	f.feed({ 0, 0 });
	f.feed({ 0, 0 });
	test::@check(!f.in_tree(crig::ANIM_STAGE_SHADE_ID), "the key row stays greyed out on Pose");
	f.app.edit_time = 3.0f;
	history = f.app.undo_stack.cursor;
	f.click(f.center_of(crig::ANIM_KEY_ID)!!);
	test::@check(f.app.undo_stack.cursor > history, "Key pose did nothing on Pose");
}

fn void dock_layer_menu_rows_act_on_the_right_clicked_layer() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	lyr_workspace(&f);
	lyr_add(&f, crig::ANIM_LAYER_WAVE_ID);
	lyr_add(&f, crig::ANIM_LAYER_NOISE_ID);
	test::eq(f.app.clip(f.app.editing).layers.len, (sz)2);

	// The verbs left the column for the row's right-click menu.
	test::@check(!f.in_tree(crig::ANIM_LAYER_DELETE_ID) && !f.in_tree(crig::ANIM_LAYER_UP_ID), "the verbs are still on the column");
	// Right-click the lower row (the wave): it becomes active and the menu opens.
	Element* tree = f.ui.find_id(crig::ANIM_LAYER_TREE_ID)!!;
	Vec2 at = tree.absolute + (Vec2){ 40, crig::OUTLINER_STYLE.row_height * 1.5f };
	crig::anim_layer_row_context(f.ui, 1, at);
	f.ui.flush();
	test::@check(f.app.active_layer_of(f.app.editing) == 0, "the right-click did not make the row active");
	test::@check(f.in_tree(crig::ANIM_LAYER_DELETE_ID) && f.in_tree(crig::ANIM_LAYER_MASK_ID)
		&& f.in_tree(crig::ANIM_LAYER_UP_ID) && f.in_tree(crig::ANIM_LAYER_DOWN_ID) && f.in_tree(crig::ANIM_LAYER_MASK_CLEAR_ID),
		"the row menu is missing a verb");
	f.click(f.center_of(crig::ANIM_LAYER_DELETE_ID)!!);
	f.ui.flush();
	test::eq(f.app.clip(f.app.editing).layers.len, (sz)1);
	test::@check(f.app.clip(f.app.editing).layers[0].kind == NOISE, "the wrong layer was deleted");
}

fn void dock_layer_form_folds_into_blend_motion_and_mask() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	lyr_workspace(&f);
	lyr_add(&f, crig::ANIM_LAYER_WAVE_ID);

	foreach (id : (String[]) { crig::ANIM_LAYER_BLEND_ID, crig::ANIM_LAYER_MOTION_ID, crig::ANIM_LAYER_MASK_SECTION_ID,
		crig::ANIM_LAYER_WEIGHT_ID, crig::ANIM_LAYER_AMPLITUDE_ID, crig::ANIM_LAYER_FADE_IN_ID })
	{
		test::@check(f.in_tree(id), "the layer form has no %s", id);
	}
	crig::layer_motion_section_changed(f.ui, false);
	test::@check(f.app.layer_motion_collapsed, "folding Motion was not kept");
	test::@check((f.app.config.folded_sections & (1u << crig::FoldedSection.LAYER_MOTION.ordinal)) != 0,
		"the fold did not reach the config");
}

fn void dock_check_results_open_in_a_dialog() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	lyr_workspace(&f);

	test::@check(!f.ui.find_id(crig::ANIM_CHECK_DIALOG_ID)!!.widget_as(Dialog).open, "the check dialog is open before a Check");
	f.pick_menu_item(crig::ANIM_TOOLS_BUTTON_ID, crig::ANIM_CHECK_ID);
	f.ui.flush();
	test::@check(f.ui.find_id(crig::ANIM_CHECK_DIALOG_ID)!!.widget_as(Dialog).open, "Check did not open its results");
	test::@check(f.app.anim_check.ran, "Check did not run");
	crig::anim_check_hide(f.ui);
	f.ui.flush();
	test::@check(!f.ui.find_id(crig::ANIM_CHECK_DIALOG_ID)!!.widget_as(Dialog).open, "Hide left the results up");
}

<*
 Posing options carries the selected joint's Weight: no slider with nothing
 selected, a commit that sets it, and Auto that puts it back on the mesh's own.
*>
fn void the_pose_tab_sets_a_joints_weight() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	dock_pose_workspace(&f);

	f.app.select(0);
	f.app.refresh_ui();
	f.ui.flush();
	f.feed({ 0, 0 });
	f.ui.flush();
	test::@check(!f.in_tree(crig::JOINT_POSE_WEIGHT_ID), "a Weight slider with nothing selected (selected %d)", f.app.selected);

	uint hips;
	foreach (dot : f.app.doc.dots.array_view()) if (dot.name == "hips") hips = dot.id;
	f.app.select(hips);
	f.app.refresh_ui();
	f.ui.flush();
	f.feed({ 0, 0 });
	f.ui.flush();
	test::@check(f.in_tree(crig::JOINT_POSE_WEIGHT_ID), "no Weight slider for the selected joint");
	test::@check(!f.in_tree(crig::JOINT_POSE_WEIGHT_AUTO_ID), "Auto offered for a joint at its own weight");

	crig::joint_pose_weight_committed(f.ui, 2.0f);
	f.ui.flush();
	test::@check(f.app.doc.find(hips).pose_weight == 2.0f, "the commit did not set the weight");
	test::@check(f.in_tree(crig::JOINT_POSE_WEIGHT_AUTO_ID), "no Auto for a weight that was set");

	crig::joint_pose_weight_auto(f.ui);
	f.ui.flush();
	test::@check(f.app.doc.find(hips).pose_weight == 0.0f, "Auto did not put the weight back");
}
