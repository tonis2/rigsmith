module crig_tests::ui;
import crig;
import cui;
import cui::widgets;
import rig;
import std::core::test;
import std::math;

fn void animation_workspace_key_clipboard_shortcuts_are_timeline_scoped() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	test::@check(f.app.apply_plan_named("biped"), "could not fit rig");
	AnimRef clip = f.app.new_clip("Clipboard", 2);
	f.app.show_edited();
	f.click(tab_center(&f, f.ui.find(AreaTabStrip)!!, TAB_ANIMATIONS));
	f.ui.flush();
	sz initial_history = f.app.undo_stack.cursor;
	f.app.resume_clip();
	f.feed({ 0, 0 });
	Element* sheet = f.ui.find(Timeline)!!;
	Timeline* timeline = sheet.widget_as(Timeline);
	Vec2 key = sheet.absolute + (Vec2){ timeline.x_of(sheet, 0), timeline.lane_y(0) };
	f.click(key);
	f.feed(key, keys: { Key.LEFT_CTRL, Key.C });
	f.feed(key);
	test::@check(f.app.anim_key_clipboard.keyframes.len == 1, "timeline Ctrl+C did not copy");
	sheet = f.ui.find(Timeline)!!;
	timeline = sheet.widget_as(Timeline);
	test::@check(timeline.marks[0].selected, "current pose key was not highlighted");
	test::@check(f.app.undo_stack.cursor == initial_history, "selecting/copying a key added history");
	sz history = f.app.undo_stack.cursor;
	Vec2 destination = sheet.absolute + (Vec2){ timeline.x_of(sheet, 1), 5 };
	f.click(destination);
	f.feed(destination, keys: { Key.LEFT_CTRL, Key.V });
	f.feed(destination);
	test::@check(f.app.clip(f.app.editing).keyframes.len == 2, "timeline Ctrl+V did not paste");
	test::@check(f.app.undo_stack.cursor == history + 1, "paste was not one history edit");
	sheet = f.ui.find(Timeline)!!;
	timeline = sheet.widget_as(Timeline);
	key = sheet.absolute + (Vec2){ timeline.x_of(sheet, 1), timeline.lane_y(0) };
	f.click(key);
	f.feed(key, keys: { Key.DELETE });
	f.feed(key);
	test::@check(f.app.clip(f.app.editing).keyframes.len == 1 && f.app.doc.dots.len() > 0,
		"timeline Delete removed rig data or left the key");
	test::@check(f.app.undo() && f.app.clip(f.app.editing).keyframes.len == 2, "delete did not undo");
	test::@check(f.app.undo() && f.app.clip(f.app.editing).keyframes.len == 1, "paste did not undo separately");
}

fn void animation_workspace_timing_controls_preserve_keys_and_history() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	test::@check(f.app.apply_plan_named("biped"), "could not fit rig");
	AnimRef clip = f.app.new_clip("Timing", 4);
	f.app.editing = f.app.key_here(clip, 0.413f);
	f.app.show_edited();
	f.click(tab_center(&f, f.ui.find(AreaTabStrip)!!, TAB_ANIMATIONS));
	f.ui.flush();
	sz history = f.app.undo_stack.cursor;
	test::@check(f.app.anim_fps == 30 && !f.app.anim_snap_off, "default is not 30 fps snapping");
	// Typing a frame into the readout goes there.
	Element* readout = f.ui.find_id(crig::ANIM_TIME_ID)!!.children[0];
	TextField* typed = readout.widget_as(TextField);
	typed.set_text(readout, "45");
	crig::anim_time_submitted(f.ui, typed.value());
	f.ui.flush();
	test::@check(math::abs(f.app.edit_time - 1.5f) < 0.00001f, "frame entry did not seek");
	f.feed({ 0, 0 });
	test::@check(typed.value() == "f 45 · 1.50 s", "the readout did not follow the playhead: %s", typed.value());

	// The preview ending lives on the sheet's menu and never touches the clip.
	bool authored_loop = f.app.clip(clip).loop;
	crig::anim_space_context(f.ui, 1.5f, readout.absolute);
	f.ui.flush();
	f.click(f.center_of("anim-preview-loop")!!);
	f.ui.flush();
	test::@check(f.app.anim_preview_loop == LOOP && f.app.clip(clip).loop == authored_loop,
		"preview loop changed the saved animation");
	crig::anim_preview_loop_chosen(f.ui, 0);
	f.ui.flush();

	// Frame rate and speed are inline; snapping is on the sheet's menu.
	crig::anim_rate_chosen(f.ui, 2);
	crig::anim_speed_chosen(f.ui, 1);
	f.ui.flush();
	test::@check(f.ui.find_id(crig::ANIM_RATE_ID)!!.widget_as(Select).selected == 2, "fps dropdown did not follow");
	crig::anim_space_context(f.ui, 1.5f, readout.absolute);
	f.ui.flush();
	f.click(f.center_of("anim-snap")!!);
	f.ui.flush();
	test::@check(f.app.anim_fps == 60 && f.app.anim_snap_off, "timing settings did not apply");
	crig::anim_time_submitted(f.ui, "-1");
	test::@check(f.app.edit_time == 1.5f, "invalid time changed the playhead");
	crig::anim_time_submitted(f.ui, "0.413 s");
	f.ui.flush();
	test::@check(math::abs(f.app.edit_time - 0.413f) < 0.00001f, "time entry lost subframe precision");
	f.app.resume_clip();
	float before = f.app.anim_time;
	f.app.tick_animation(0.2f);
	test::@check(math::abs(f.app.anim_time - before - 0.1f) < 0.00001f, "half speed did not scale playback");
	f.app.anim_paused = true;
	crig::anim_zoom_set(f.ui, 4);
	f.ui.flush();
	Element* sheet = f.ui.find(Timeline)!!;
	Timeline* timeline = sheet.widget_as(Timeline);
	test::@check(timeline.zoom == 4 && timeline.fps == 60 && timeline.snap == 0,
		"timeline did not adopt display settings");
	float at = timeline.view_start + 0.413f;
	test::@check(math::abs(timeline.at_of(sheet, timeline.x_of(sheet, at)) - at) < 0.00001f,
		"zoomed unsnapped ruler does not round-trip");
	Vec2 mouse = sheet.absolute + (Vec2){ sheet.size.x * 0.7f, 5 };
	f.ui.process_input({ .mouse = mouse, .scroll = 1 }, DT);
	f.ui.flush();
	test::@check(f.app.anim_timeline_start > 0, "wheel did not pan the zoomed timeline");
	f.ui.process_input({ .mouse = mouse, .scroll = 1, .keys_down = { Key.LEFT_CTRL } }, DT);
	f.ui.flush();
	test::@check(f.app.anim_timeline_zoom > 4, "Ctrl+wheel did not zoom");
	f.feed(mouse);
	crig::anim_zoom_fit(f.ui);
	test::@check(f.app.anim_timeline_zoom == 1 && f.app.anim_timeline_start == 0, "Fit did not restore full clip");
	test::@check(f.app.clip(clip).keyframes[1].time == 0.413f && f.app.clip(clip).duration == 4,
		"preview controls changed stored timing");
	test::@check(f.app.undo_stack.cursor == history, "preview controls created document edits");
}

// A hand-keyed clip is a one-shot by default: past the last key it holds that
// pose rather than blending back to the first. That is what lets someone key a
// fall and carry straight on — the character does not rise back up on its own.
fn void a_new_animation_holds_its_last_pose_by_default() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	test::@check(f.app.apply_plan_named("biped"), "could not fit rig");
	f.click(tab_center(&f, f.ui.find(AreaTabStrip)!!, TAB_ANIMATIONS));
	f.ui.flush();

	f.pick_menu_item(crig::ANIM_NEW_MENU_BUTTON_ID, crig::ANIM_NEW_EMPTY_ID);
	f.ui.flush();
	f.click(f.center_of("anim-create")!!);
	f.ui.flush();
	test::@check(f.app.clip(f.app.editing) && !f.app.clip(f.app.editing).loop,
		"a hand-authored clip should hold its last pose, not spring back to the first");
}

// The loop is one toggle away: the Loop checkbox beside Auto-key flips the
// current clip into a cycle, the same intent the properties dialog and Close
// loop serve for a saved clip.
fn void the_loop_toggle_makes_the_current_clip_cycle() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	test::@check(f.app.apply_plan_named("biped"), "could not fit rig");
	f.click(tab_center(&f, f.ui.find(AreaTabStrip)!!, TAB_ANIMATIONS));
	f.ui.flush();

	f.pick_menu_item(crig::ANIM_NEW_MENU_BUTTON_ID, crig::ANIM_NEW_EMPTY_ID);
	f.ui.flush();
	f.click(f.center_of("anim-create")!!);
	f.ui.flush();
	test::@check(f.app.clip(f.app.editing) && !f.app.clip(f.app.editing).loop,
		"a fresh clip should start non-looping");

	Element* loop = f.ui.find_id("anim-loop-toggle")!!;
	test::@check(!loop.widget_as(ToggleButton).on, "the Loop toggle should start off");
	f.click(f.center_of("anim-loop-toggle")!!);
	f.ui.flush();
	test::@check(f.app.clip(f.app.editing) && f.app.clip(f.app.editing).loop,
		"toggling Loop beside Auto-key should make the current clip cycle");
}

fn void animation_workspace_new_starts_at_rest_and_old_clip_still_plays() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	test::@check(f.app.apply_plan_named("biped"), "could not fit a rig");
	AnimRef old = f.app.new_clip("Old", 2);
	f.app.clip(old).loop = false;
	test::@check(f.app.pose_from_clip(old, 2), "could not sample old clip");
	f.app.set_working_pose(f.app.doc.dots[0].id,
		quaternion::from_axis_angle{float}(((Vec3){ 0, 1, 0 }), 0.7f), {});
	f.app.pose_edit_pending = true;
	f.app.edit_time = 2;
	test::@check(f.app.key_pose_edit(), "could not save old final pose");
	crig::build_ui(f.ui, &f.app);
	f.ui.flush();
	f.pick_menu_item(crig::ANIM_NEW_MENU_BUTTON_ID, crig::ANIM_NEW_EMPTY_ID);
	f.ui.flush();
	Element* name = f.ui.find_id("anim-new-name")!!;
	name.widget_as(TextField).set_text(name, "New");
	f.click(f.center_of("anim-create")!!);
	f.ui.flush();
	AnimRef made = f.app.editing;
	test::@check(f.app.clip(made).name == "New", "new clip was not selected");
	RigView view = f.app.open_rig(mem)!!;
	defer view.free(mem);
	rig::Pose pose = f.app.clip(made).pose(mem, &view.skeleton, view.names, 0, false);
	defer pose.free(mem);
	foreach (rotation : pose.rotations)
	{
		test::@check(math::abs(rotation.v.w) > 0.99999f, "new clip inherited an animated rotation");
	}
	foreach (offset : pose.offsets)
	{
		test::@check(offset.length_sq() < 1.0e-10f, "new clip inherited an animated offset");
	}
	foreach (row : (usz[]) { 0, 1, 0 })
	{
		f.feed({ 0, 0 });
		f.click(f.center_of("anim-chooser")!!);
		f.ui.flush();
		Vec2 target;
		Select* chooser = f.ui.find_id("anim-chooser")!!.widget_as(Select);
		test::@check(chooser.open, "chooser did not open for row %d (options %d)", row, chooser.options.len);
		bool found = false;
		f.ui.@each(SelectOption; option)
		{
			if (option.widget_as(SelectOption).index == row)
			{
				target = option.absolute + option.size * 0.5f;
				found = true;
			}
		};
		test::@check(found, "clip option missing for row %d", row);
		f.click(target);
		f.ui.flush();
		test::@check(!f.ui.find_id("anim-chooser")!!.widget_as(Select).open, "selection left chooser open for row %d", row);
		AnimRef expected = row == 0 ? old : made;
		test::@check(f.app.editing.same(expected), "choosing clip did not switch the timeline (row %d)", row);
		test::@check(f.app.current_ref.same(expected) && f.app.animating && f.app.anim_paused
			&& f.app.edit_time == 0.0f && f.app.anim_time == 0.0f,
			"switching animations did not park the chosen clip on its first frame");
		f.click(f.center_of(crig::ANIM_TRANSPORT_PLAY_ID)!!);
		f.ui.flush();
		test::@check(f.app.current_ref.same(expected) && f.app.animating && !f.app.anim_paused,
			"selected clip did not play");
		test::@check(!f.ui.find_id("anim-chooser")!!.widget_as(Select).open, "play opened chooser row %d", row);
		f.click(f.center_of(crig::ANIM_END_ID)!!);
		f.ui.flush();
		f.click(f.center_of(crig::ANIM_TRANSPORT_PLAY_ID)!!);
		f.ui.flush();
		test::@check(f.app.anim_time < 0.5f && !f.app.anim_paused,
			"Play at the end did not restart the clip");
	}
}

fn void animation_workspace_creates_a_named_clip_and_wraps() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	test::@check(f.app.apply_plan_named("biped"), "could not fit a rig");
	f.click(tab_center(&f, f.ui.find(AreaTabStrip)!!, TAB_ANIMATIONS));
	f.ui.flush();
	test::@check(f.app.auto_key, "automatic pose keying should be the default");
	f.pick_menu_item(crig::ANIM_NEW_MENU_BUTTON_ID, crig::ANIM_NEW_EMPTY_ID);
	f.ui.flush();
	Element* name = f.ui.find_id("anim-new-name")!!;
	name.widget_as(TextField).set_text(name, "Wave");
	Element* duration = f.ui.find_id("anim-new-duration")!!;
	duration.widget_as(TextField).set_text(duration, "-1");
	f.click(f.center_of("anim-create")!!);
	test::@check(f.app.doc.animations.len() == 0, "invalid duration created a clip");
	duration.widget_as(TextField).set_text(duration, "2.5");
	f.click(f.center_of("anim-create")!!);
	f.ui.flush();
	test::@check(f.app.clip(f.app.editing).name == "Wave", "name was not used");
	test::@check(f.app.clip(f.app.editing).duration == 2.5f, "duration was not used");
	test::@check(f.app.doc.animations.len() == 1, "created clip was not added to export set");
	Timeline* sheet = f.ui.find(Timeline)!!.widget_as(Timeline);
	test::@check(sheet.lanes.len == 1 && sheet.marks.len == 1, "default timeline is not a pose summary");
	test::@check(f.ui.find_id(crig::ANIM_KEY_ID)!!.widget_as(Button).label == "Key pose", "primary action is unclear");
	f.ui.resize({ 420, 650 });
	f.ui.flush();
	foreach (id : (String[]) { crig::ANIM_NEW_MENU_BUTTON_ID, "anim-more", crig::ANIM_KEY_ID, crig::ANIM_AUTO_KEY_ID })
	{
		Element* control = f.ui.find_id(id)!!;
		test::@check(control.size.x > 0 && control.absolute.x + control.size.x <= 420,
			"%s is clipped in a narrow pane", id);
	}
	f.ui.resize({ 1000, 650 });
	f.ui.flush();
	// The clip manager is three quarters of the dock now, so the timeline fills that, not the window.
	test::@check(f.ui.find(Timeline)!!.size.x > 650, "timeline still has a fixed-width cap");
	f.click(f.center_of("anim-show-tracks")!!);
	f.ui.flush();
	test::@check(f.ui.find(Timeline)!!.widget_as(Timeline).lanes.len > 1, "detailed tracks are unavailable");
}

fn void a_new_animation_auto_keys_without_toggling_the_checkbox() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	test::@check(f.app.apply_plan_named("biped"), "could not fit a rig");
	f.click(tab_center(&f, f.ui.find(AreaTabStrip)!!, TAB_ANIMATIONS));
	f.ui.flush();

	// Create through the same dialog as the user. The initial checked state must
	// be the working state; clicking the checkbox once or twice must not be the
	// operation that arms automatic keying.
	f.pick_menu_item(crig::ANIM_NEW_MENU_BUTTON_ID, crig::ANIM_NEW_EMPTY_ID);
	f.ui.flush();
	f.ui.find_id("anim-new-name")!!.widget_as(TextField).set_text(
		f.ui.find_id("anim-new-name")!!, "Untoggled auto key");
	f.click(f.center_of("anim-create")!!);
	f.ui.flush();
	test::@check(f.app.auto_key, "creating a clip disabled the initially checked Auto-key setting");

	AnimRef clip = f.app.editing;
	usz before = f.app.clip(clip).keyframes.len;
	test::@check(math::abs(f.app.edit_time - 1.0f) < 0.00001f,
		"new clip left the playhead on its existing starting key");
	RigView view = f.app.open_rig(mem)!!;
	defer view.free(mem);
	f.app.select(view.dot_ids[1]);
	test::@check(f.app.begin_turn(), "new clip did not become editable at the playhead");
	f.app.turn_joint({ 0, 0, 1 }, 0.7f);
	f.app.end_drag();
	f.feed(VIEWPORT_CENTER);

	test::eq(f.app.clip(f.app.editing).keyframes.len, (sz)before + 1);
	test::@check(!f.app.pose_edit_pending, "initial Auto-key left the changed pose unsaved");
	test::eq(f.ui.find(Timeline)!!.widget_as(Timeline).marks.len, (sz)before + 1);
}

fn void animation_workspace_navigation_keeps_or_discards_the_draft_explicitly() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	test::@check(f.app.apply_plan_named("biped"), "could not fit a rig");
	AnimRef clip = f.app.new_clip("Draft", 2);
	f.app.show_edited();
	f.click(tab_center(&f, f.ui.find(AreaTabStrip)!!, TAB_ANIMATIONS));
	f.ui.flush();
	test::@check(f.app.pose_from_clip(clip, 0), "could not sample the starting pose");
	uint joint = f.app.doc.dots[0].id;
	f.app.set_working_pose(joint, quaternion::from_axis_angle{float}(((Vec3){ 0, 1, 0 }), 0.4f), {});
	f.app.pose_edit_pending = true;
	f.app.auto_key = false;
	f.feed({ 0, 0 });
	f.ui.flush();
	test::@check(f.in_tree(crig::ANIM_PENDING_BANNER_ID), "a changed pose shows no banner");
	sz before = f.app.undo_stack.cursor;
	f.click(f.center_of(crig::ANIM_END_ID)!!);
	f.ui.flush();
	test::@check(f.app.edit_time == 0 && f.app.pose_edit_pending && f.app.undo_stack.cursor == before,
		"navigation discarded the draft before asking");
	f.click(f.center_of("anim-pending-save")!!);
	f.ui.flush();
	test::@check(!f.app.pose_edit_pending && f.app.edit_time == 2, "Key pose did not continue navigation");
	test::@check(f.app.undo_stack.cursor == before + 1, "keying the draft was not one edit");
	test::@check(!f.in_tree(crig::ANIM_PENDING_BANNER_ID), "the banner outlived the change");
	test::@check(f.app.pose_from_clip(f.app.editing, 2), "could not sample the final pose");
	f.app.set_working_pose(joint, quaternion::from_axis_angle{float}(((Vec3){ 0, 1, 0 }), -0.4f), {});
	f.app.pose_edit_pending = true;
	before = f.app.undo_stack.cursor;
	f.feed({ 0, 0 });
	f.click(f.center_of(crig::ANIM_START_ID)!!);
	f.ui.flush();
	f.click(f.center_of("anim-pending-discard")!!);
	f.ui.flush();
	test::@check(!f.app.pose_edit_pending && f.app.edit_time == 0, "Revert did not continue navigation");
	test::@check(f.app.undo_stack.cursor == before, "Revert recorded an edit");

	// Asked once: a second move drops the change and goes.
	test::@check(f.app.pose_from_clip(f.app.editing, 0), "could not sample the first pose");
	f.app.set_working_pose(joint, quaternion::from_axis_angle{float}(((Vec3){ 0, 1, 0 }), 0.3f), {});
	f.app.pose_edit_pending = true;
	f.feed({ 0, 0 });
	f.click(f.center_of(crig::ANIM_END_ID)!!);
	f.ui.flush();
	test::@check(f.app.pose_edit_pending && f.app.edit_time == 0, "the first move did not ask");
	f.feed({ 0, 0 });
	f.click(f.center_of(crig::ANIM_END_ID)!!);
	f.ui.flush();
	test::@check(!f.app.pose_edit_pending && f.app.edit_time == 2, "the second move did not drop the change and go");
	test::@check(f.app.undo_stack.cursor == before, "dropping the change recorded an edit");

	// With Auto-key on, moving keys the change instead of asking.
	f.app.auto_key = true;
	test::@check(f.app.pose_from_clip(f.app.editing, 2), "could not sample the last pose");
	f.app.set_working_pose(joint, quaternion::from_axis_angle{float}(((Vec3){ 0, 1, 0 }), 0.2f), {});
	f.app.pose_edit_pending = true;
	f.feed({ 0, 0 });
	f.click(f.center_of(crig::ANIM_START_ID)!!);
	f.ui.flush();
	test::@check(!f.app.pose_edit_pending && f.app.edit_time == 0 && f.app.undo_stack.cursor == before + 1,
		"Auto-key did not key the change on the move");
}

// The bug: posing on top of a parked clip and then discarding the change at the
// navigation prompt left the discarded pose on screen — the mesh kept it. Discard
// must put the body back to what the clip actually says at the landing time.
fn void discarding_the_pending_pose_reverts_the_shown_body() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	test::@check(f.app.apply_plan_named("biped"), "could not fit a rig");
	AnimRef clip = f.app.new_clip("Discard revert", 2);
	f.app.show_edited();
	f.click(tab_center(&f, f.ui.find(AreaTabStrip)!!, TAB_ANIMATIONS));
	f.ui.flush();

	usz n = (usz)f.app.doc.dots.len();
	Vec3[] rest = alloc::new_array(mem, Vec3, (sz)n);
	defer alloc::free(mem, rest);
	foreach (usz i, dot : f.app.doc.dots) rest[i] = f.app.dot_position(dot);

	// Pose a joint hard at the shown time, so the whole subtree swings visibly.
	// Through `prepare_animation_pose` — the door the real G gesture opens, which
	// stops the parked preview (animating → false) before sampling the draft, the
	// state the discard actually has to clean up. A fresh clip is flat rest, so
	// what it shows at 0 s and at the end match — the revert target after landing
	// at the end is still `rest`.
	uint joint = f.app.doc.dots[0].id;
	f.app.select(joint);
	test::@check(f.app.prepare_animation_pose(), "could not open the pose to edit");
	f.app.set_working_pose(joint, quaternion::from_axis_angle{float}(((Vec3){ 0, 1, 0 }), 1.2f), {});
	f.app.pose_edit_pending = true;
	f.app.refresh_posed();

	// The dot that moved most under the pose is the one to watch back down.
	usz watch = 0;
	float swing = 0.0f;
	foreach (usz i, dot : f.app.doc.dots)
	{
		float d = (f.app.dot_position(dot) - rest[i]).length();
		if (d > swing) { swing = d; watch = i; }
	}
	test::@check(swing > 0.02f, "the pose did not visibly move the body (%.5f) — test is inert", swing);

	// Move the needle to the end; Revert the change at the banner.
	f.app.auto_key = false;
	f.feed({ 0, 0 });
	f.click(f.center_of(crig::ANIM_END_ID)!!);
	f.ui.flush();
	test::@check(f.app.anim_pending_action != 0,
		"moving the needle did not raise the save-or-discard prompt");
	f.click(f.center_of("anim-pending-discard")!!);
	f.ui.flush();

	test::@check(!f.app.pose_edit_active && !f.app.pose_edit_pending,
		"Discard left the pose draft active");
	Dot watched = f.app.doc.dots[(sz)watch];
	float back = (f.app.dot_position(watched) - rest[watch]).length();
	test::@check(back < 0.005f,
		"Discard kept the pose on screen: the watched dot is %.5f from where the clip puts it at 0s",
		back);
}

// `discard_pose_edit` must restore the shown body on its own, not on the trust
// that whatever called it will refresh next. Over a parked clip (`animating`
// stays true) it used to leave the draft's overlay up and lean on a follow-up
// navigation to redraw — so any caller without one kept the discarded pose.
fn void discard_pose_edit_restores_the_shown_body_by_itself() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	test::@check(f.app.apply_plan_named("biped"), "could not fit a rig");
	AnimRef clip = f.app.new_clip("Discard alone", 2);
	f.app.show_edited();

	// A parked preview, with a draft posed on top while it stays parked — the
	// `animating == true` branch of discard.
	test::@check(f.app.park_clip(clip, 0.0f), "the clip would not park");
	usz n = (usz)f.app.doc.dots.len();
	Vec3[] rest = alloc::new_array(mem, Vec3, (sz)n);
	defer alloc::free(mem, rest);
	foreach (usz i, dot : f.app.doc.dots) rest[i] = f.app.dot_position(dot);

	test::@check(f.app.pose_from_clip(clip, 0.0f), "could not sample the pose to edit");
	test::@check(f.app.animating, "the clip stopped parking — wrong branch under test");
	uint joint = f.app.doc.dots[0].id;
	f.app.set_working_pose(joint, quaternion::from_axis_angle{float}(((Vec3){ 0, 1, 0 }), 1.2f), {});
	f.app.pose_edit_pending = true;
	f.app.refresh_posed();

	usz watch = 0;
	float swing = 0.0f;
	foreach (usz i, dot : f.app.doc.dots)
	{
		float d = (f.app.dot_position(dot) - rest[i]).length();
		if (d > swing) { swing = d; watch = i; }
	}
	test::@check(swing > 0.02f, "the pose did not visibly move the body (%.5f) — test is inert", swing);

	// Discard alone, with no navigation to lean on afterwards.
	test::@check(f.app.discard_pose_edit(), "there was no draft to discard");

	Dot watched = f.app.doc.dots[(sz)watch];
	float back = (f.app.dot_position(watched) - rest[watch]).length();
	test::@check(back < 0.005f,
		"discard_pose_edit left the pose on screen: the watched dot is %.5f from the clip pose", back);
}

fn void animation_workspace_summary_drag_moves_one_whole_pose() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	test::@check(f.app.apply_plan_named("biped"), "could not fit a rig");
	AnimRef ref = f.app.new_clip("Drag", 2);
	f.app.editing = f.app.key_here(ref, 1);
	f.app.show_edited();
	f.click(tab_center(&f, f.ui.find(AreaTabStrip)!!, TAB_ANIMATIONS));
	f.ui.flush();
	usz joints = f.app.clip(f.app.editing).keyframes[1].dots.len;
	sz before = f.app.undo_stack.cursor;
	Element* element = f.ui.find(Timeline)!!;
	Timeline* sheet = element.widget_as(Timeline);
	Vec2 start = element.absolute + (Vec2){ sheet.x_of(element, 1), sheet.lane_y(0) };
	Vec2 end = element.absolute + (Vec2){ sheet.x_of(element, 1.5f), sheet.lane_y(0) };
	f.drag(start, end);
	f.ui.flush();
	AnimTemplate* moved = f.app.clip(f.app.editing);
	test::@check(moved.keyframes.len == 2 && math::abs(moved.keyframes[1].time - 1.5f) < 0.001f,
		"summary marker did not move the second keyframe");
	test::@check(moved.keyframes[1].dots.len == joints, "summary drag dropped joints");
	test::@check(f.app.undo_stack.cursor == before + 1, "summary drag was not one undo entry");
}

fn void animation_workspace_properties_and_duplicates_keep_history() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	test::@check(f.app.apply_plan_named("biped"), "could not fit a rig");
	AnimRef source = f.app.new_clip("Original", 2);
	f.app.show_edited();
	f.click(tab_center(&f, f.ui.find(AreaTabStrip)!!, TAB_ANIMATIONS));
	f.ui.flush();
	sz before = f.app.undo_stack.cursor;
	f.click(f.center_of("anim-more")!!);
	f.ui.flush();
	f.click(f.center_of("anim-duplicate")!!);
	f.ui.flush();
	test::@check(f.app.doc.animations.len() == 2, "Duplicate replaced the original binding");
	test::@check(f.app.clip(source).name == "Original", "Duplicate changed its source");
	test::@check(f.app.undo_stack.cursor == before + 2, "Duplicate should record a clip and binding");
	AnimRef duplicate = f.app.editing;
	f.click(f.center_of("anim-more")!!);
	f.ui.flush();
	f.click(f.center_of("anim-properties")!!);
	f.ui.flush();
	Element* name = f.ui.find_id("anim-new-name")!!;
	Element* duration = f.ui.find_id("anim-new-duration")!!;
	name.widget_as(TextField).set_text(name, "Wave");
	duration.widget_as(TextField).set_text(duration, "3");
	f.click(f.center_of("anim-create")!!);
	f.ui.flush();
	test::@check(f.app.clip(f.app.editing).name == "Wave" && f.app.clip(f.app.editing).duration == 3,
		"properties were not applied");
	test::@check(f.app.doc.animations.len() == 2, "Rename added another export binding");
	test::@check(f.app.undo_stack.cursor == before + 4, "Rename should record a clip and binding");
	test::@check(f.app.undo(), "properties could not be undone");
	test::@check(f.app.doc.bound_index("", "Wave") < 0
		&& f.app.doc.bound_index("", f.app.clip(duplicate).name) >= 0, "Undo did not restore the binding");
	test::@check(f.app.undo_stack.cursor == before + 2, "one Undo did not undo the entire rename");
	test::@check(f.app.undo(), "Duplicate could not be undone");
	test::@check(f.app.undo_stack.cursor == before && f.app.doc.animations.len() == 1,
		"one Undo did not remove the entire duplicate");
}

// Turning Loop on in the transport, over a clip whose last key sits on the end
// with another pose, eases the wrap back to the first pose in one undo step.
fn void the_loop_button_eases_a_differing_end_back() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	test::@check(f.app.apply_plan_named("biped"), "could not fit a rig");
	AnimRef clip = f.app.new_clip("Reach", 2, from_rest: true, loop: false);
	f.app.editing = clip;
	test::@check(f.app.pose_from_clip(clip, 2), "could not sample the end");
	f.app.set_working_pose(f.app.doc.dots[0].id, quaternion::from_axis_angle{float}(((Vec3){ 0, 1, 0 }), 0.6f), {});
	f.app.pose_edit_pending = true;
	f.app.edit_time = 2;
	test::@check(f.app.key_pose_edit(), "could not key the end pose");
	f.app.show_edited();
	f.click(tab_center(&f, f.ui.find(AreaTabStrip)!!, TAB_ANIMATIONS));
	f.ui.flush();

	sz history = f.app.undo_stack.cursor;
	f.click(f.center_of(crig::ANIM_LOOP_TOGGLE_ID)!!);
	f.ui.flush();
	AnimTemplate* looped = f.app.clip(f.app.editing);
	test::@check(looped.loop && looped.duration > 2.0f, "Loop did not ease the differing end back (%s s)", looped.duration);
	test::@check(looped.keyframes[looped.keyframes.len - 1].same_pose(looped.keyframes[0]),
		"the new end is not the first pose");
	test::@check(f.ui.find_id(crig::ANIM_LOOP_TOGGLE_ID)!!.widget_as(ToggleButton).on, "the Loop button did not light");
	test::eq(f.app.undo_stack.cursor, history + 1);
	test::@check(f.app.undo(), "Loop could not be undone");
	test::@check(!f.app.clip(f.app.editing).loop && f.app.clip(f.app.editing).duration == 2,
		"undo did not restore the one-shot clip");
}

// Balance starts on, and the button in the Pose tab's Posing options turns it off
// and back.
fn void the_balance_button_switches_the_lean() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	test::@check(f.app.apply_plan_named("biped"), "could not fit a rig");
	f.app.editing = f.app.new_clip("Sit", 1, from_rest: true);
	f.open_pose_tab();

	test::@check(!f.app.balance_off && f.ui.find_id(crig::ANIM_BALANCE_ID)!!.widget_as(ToggleButton).on,
		"Balance did not start on");
	f.click(f.center_of(crig::ANIM_BALANCE_ID)!!);
	f.ui.flush();
	test::@check(f.app.balance_off, "the button did not turn Balance off");
	test::@check(!f.ui.find_id(crig::ANIM_BALANCE_ID)!!.widget_as(ToggleButton).on, "the button still lights");
	f.click(f.center_of(crig::ANIM_BALANCE_ID)!!);
	test::@check(!f.app.balance_off, "the button did not turn Balance back on");
}

// The interpolation popover sets the selected keys, the button names the
// selection, and the sheet draws the key in its new shape.
fn void the_interpolation_popover_sets_the_selected_keys() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	multi_pose_workspace(&f);

	f.click(multi_pose_point(&f, 1));
	f.ui.flush();
	test::eq(f.app.animation_key_selection_count(f.app.editing), (usz)1);
	f.click(f.center_of(crig::ANIM_INTERP_ID)!!);
	f.ui.flush();
	test::@check(f.ui.find_id(crig::ANIM_INTERP_POPOVER_ID)!!.widget_as(Dialog).open, "the button did not open the popover");
	sz history = f.app.undo_stack.cursor;
	f.click(f.center_of(crig::ANIM_INTERP_THUMB_IDS[1])!!);
	f.ui.flush();
	test::eq(f.app.animation_key_selection_count(f.app.editing), (usz)1);
	test::eq(f.app.undo_stack.cursor, history + 1);
	AnimTemplate* clip = f.app.clip(f.app.editing);
	test::@check(clip.keyframes[1].dots[0].rotation_interpolation == LINEAR, "Linear did not reach the key");
	test::@check(clip.keyframes[0].dots[0].rotation_interpolation == INHERIT, "Linear reached an unselected key");
	f.feed({ 0, 0 });
	test::@check(f.app.animation_selection_uses_interpolation(f.app.editing, LINEAR), "selection is not linear");
	test::eq(crig::anim_interp_label(crig::anim_interp_state(&f.app)), "Linear");
	test::@check(f.ui.find(Timeline)!!.widget_as(Timeline).marks[1].curve == LINEAR, "the sheet does not draw the key as Linear");

	// Nothing selected: the key under the playhead is the one set.
	f.app.clear_animation_key_selection();
	f.app.edit_time = 2;
	test::@check(f.app.scrub_to(2), "the parked clip would not scrub");
	crig::anim_interp_apply_preset(f.ui, 2);
	f.ui.flush();
	clip = f.app.clip(f.app.editing);
	test::@check(clip.keyframes[2].dots[0].interpolation(true, clip.blend) == HOLD, "Step did not reach the key at the playhead");
	f.feed({ 0, 0 });
	test::@check(f.ui.find(Timeline)!!.widget_as(Timeline).marks[2].curve == HOLD, "the sheet does not draw the key as Step");
}

// The ⋯ clip menu holds the clip-wide actions, and + From library opens the
// Assets tab narrowed to animations.
fn void the_clip_menu_and_from_library() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	multi_pose_workspace(&f);

	f.click(f.center_of(crig::ANIM_MORE_ID)!!);
	f.ui.flush();
	foreach (id : (String[]) { "anim-properties", "anim-duplicate", "anim-retime", "anim-trim",
		"anim-mirror-clip", "anim-close-loop", "anim-move-up", "anim-move-down", crig::ANIM_UNBIND_ID, crig::ANIM_DELETE_ID })
	{
		test::@check(f.in_tree(id), "the clip menu has no %s", id);
	}
	f.click({ 4, crig::WIN_H - 4 });
	f.ui.flush();
	test::@check(!f.ui.find_id(crig::ANIM_CLIP_MENU_ID)!!.widget_as(Dialog).open, "an outside click left the clip menu open");

	f.pick_menu_item(crig::ANIM_NEW_MENU_BUTTON_ID, crig::ANIM_FROM_LIBRARY_ID);
	test::@check(!f.app.asset_filter.any_kind && f.app.asset_filter.kind == ANIMATION,
		"From library did not narrow the assets to animations");
	test::eq(crig::area_layout.root.active, crig::LIBRARY_VIEW);
	if (try Element* back = f.ui.find(AreaTabStrip)) f.click(tab_center(&f, back, 0));
}

// The View menu keeps Ghosts and Motion path, and reaches the Ghosts panel; all of
// them are what the viewport's aids read.
fn void the_view_menu_toggles_ghosts_and_the_motion_path() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	multi_pose_workspace(&f);
	f.app.select(f.app.doc.dots[1].id);

	test::@check(!f.app.config.show_ghosts, "Ghosts starts off");
	crig::menu_ghosts(f.ui);
	f.ui.flush();
	test::@check(f.app.config.show_ghosts, "Ghosts did not turn on");
	test::@check(crig::query_ghosts(f.ui).checked, "the View item does not show Ghosts on");

	crig::menu_motion_path(f.ui);
	f.ui.flush();
	test::@check(f.app.config.show_motion_path, "Path did not turn on");
	test::@check(crig::query_motion_path(f.ui).checked, "the View item does not show Path on");
	f.feed({ 0, 0 });
	test::@check(f.app.selected_motion_path() != null, "no path for the selected joint");
	test::@check(f.app.ghost_poses().len > 0, "no ghosts around the playhead");

	crig::menu_ghost_settings(f.ui);
	f.ui.flush();
	test::@check(crig::anim_ghosts_dialog_open(f.ui), "Ghost settings did not open the panel");

	crig::menu_ghosts(f.ui);
	crig::menu_motion_path(f.ui);
	f.ui.flush();
	test::@check(!f.app.config.show_ghosts && !f.app.config.show_motion_path, "the toggles did not turn off");
	test::eq(f.app.ghost_poses().len, (sz)0);
}

fn Dialog* ghosts_dialog(Fixture* f)
{
	return f.ui.find_id(crig::ANIM_GHOSTS_DIALOG_ID)!!.widget_as(Dialog);
}

// A press on a slider's track, at `fraction` of its length.
fn void click_slider(Fixture* f, String id, float fraction)
{
	Element* elem = f.ui.find_id(id)!!;
	Vec2 span = elem.widget_as(Slider).track_span(elem);
	f.click(elem.absolute + (Vec2){ span.x + span.y * fraction, elem.size.y * 0.5f });
}

fn void the_ghosts_button_toggles_ghosts_and_opens_a_floating_panel() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	multi_pose_workspace(&f);

	test::@check(f.in_tree(crig::ANIM_GHOSTS_ID), "the transport row has no Ghosts button");
	test::@check(f.in_tree(crig::ANIM_GHOSTS_DIALOG_ID), "the Ghosts panel is not mounted");
	Dialog* panel = ghosts_dialog(&f);
	test::@check(!panel.open && !panel.modal, "the Ghosts panel starts open or modal");
	test::@check(!f.app.config.show_ghosts, "Ghosts starts on");
	Element* button = f.ui.find_id(crig::ANIM_GHOSTS_ID)!!;
	test::@check(button.absolute.y < f.ui.find(Timeline)!!.absolute.y, "the button is not above the sheet");

	// On, and the panel is up, with the sliders on the config.
	f.click(f.center_of(crig::ANIM_GHOSTS_ID)!!);
	f.ui.flush();
	f.feed({ 0, 0 });
	test::@check(f.app.config.show_ghosts, "the button did not turn Ghosts on");
	panel = ghosts_dialog(&f);
	test::@check(panel.open, "the button did not open the panel");
	foreach (id : (String[]) { crig::ANIM_GHOSTS_ON_ID, crig::ANIM_GHOSTS_PAST_ID, crig::ANIM_GHOSTS_FUTURE_ID,
		crig::ANIM_GHOSTS_STEP_ID, crig::ANIM_GHOSTS_OPACITY_ID, crig::ANIM_GHOSTS_SPREAD_ID,
		crig::ANIM_GHOSTS_DIRECTION_ID, crig::ANIM_GHOSTS_PATH_ID })
	{
		test::@check(f.in_tree(id), "the panel has no %s", id);
	}
	test::@check(f.ui.find_id(crig::ANIM_GHOSTS_PAST_ID)!!.widget_as(Slider).value == (float)crig::DEFAULT_GHOST_SIDE,
		"Past does not show the config");
	test::@check(f.ui.find_id(crig::ANIM_GHOSTS_ON_ID)!!.widget_as(Checkbox).checked, "the On box is not ticked");

	// It moves: a Dialog is dragged by its bar and keeps what it is given.
	panel.at = { 40, 60 };
	panel.placed = true;
	f.feed({ 0, 0 });
	test::@check(panel.placed && panel.at.x <= 40.5f, "the panel did not stay where it was put");

	// Pressing the button with the panel up puts both away.
	f.click(f.center_of(crig::ANIM_GHOSTS_ID)!!);
	f.ui.flush();
	test::@check(!f.app.config.show_ghosts && !ghosts_dialog(&f).open, "the second press did not turn Ghosts off");
	// Pressing it on a closed panel with Ghosts on reopens the panel.
	crig::anim_ghosts_toggled(f.ui, true);
	f.ui.flush();
	test::@check(!ghosts_dialog(&f).open, "toggling Ghosts opened the panel");
	f.click(f.center_of(crig::ANIM_GHOSTS_ID)!!);
	f.ui.flush();
	test::@check(f.app.config.show_ghosts && ghosts_dialog(&f).open, "the button did not reopen the panel");
}

fn void the_ghosts_panel_edits_the_config() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	multi_pose_workspace(&f);
	f.click(f.center_of(crig::ANIM_GHOSTS_ID)!!);
	f.ui.flush();
	f.feed({ 0, 0 });

	// Dragging a track writes the config, whatever the number.
	click_slider(&f, crig::ANIM_GHOSTS_PAST_ID, 0.5f);
	test::eq(f.app.config.ghost_past, 15);
	click_slider(&f, crig::ANIM_GHOSTS_FUTURE_ID, 1.0f);
	test::eq(f.app.config.ghost_future, crig::MAX_GHOST_SIDE);
	click_slider(&f, crig::ANIM_GHOSTS_STEP_ID, 1.0f);
	test::eq(f.app.config.ghost_step, crig::MAX_GHOST_STEP);
	click_slider(&f, crig::ANIM_GHOSTS_OPACITY_ID, 1.0f);
	test::@check(f.app.config.ghost_opacity == 1.0f, "the opacity track did not reach 1 (%f)", f.app.config.ghost_opacity);
	test::eq(f.app.ghost_past_count(), 15);

	// Spread is a share of the rig's height, 0 to the cap; Direction is a strip.
	click_slider(&f, crig::ANIM_GHOSTS_SPREAD_ID, 1.0f);
	test::@check(math::abs(f.app.config.ghost_spread - crig::MAX_GHOST_SPREAD) < 1e-4f, "the spread track did not reach the cap (%f)", f.app.config.ghost_spread);
	click_slider(&f, crig::ANIM_GHOSTS_SPREAD_ID, 0.0f);
	test::@check(f.app.config.ghost_spread == 0.0f, "the spread track did not reach 0 (%f)", f.app.config.ghost_spread);
	crig::anim_ghost_spread_moved(f.ui, 9.0f);
	test::@check(f.app.config.ghost_spread == crig::MAX_GHOST_SPREAD, "spread was not clamped");
	test::eq(f.app.config.ghost_direction, 0);
	Element* strip = f.ui.find_id(crig::ANIM_GHOSTS_DIRECTION_ID)!!;
	f.click({ strip.absolute.x + strip.size.x - 6.0f, strip.absolute.y + strip.size.y * 0.5f });
	f.ui.flush();
	test::eq(f.app.config.ghost_direction, 2);
	crig::anim_ghost_direction_chosen(f.ui, 1);
	test::eq(f.app.config.ghost_direction, 1);
	crig::anim_ghost_direction_chosen(f.ui, 7);
	test::eq(f.app.config.ghost_direction, 1);

	// The callbacks clamp: nothing the panel can send breaks the ranges.
	crig::anim_ghost_past_moved(f.ui, -4.0f);
	test::eq(f.app.config.ghost_past, 0);
	crig::anim_ghost_step_moved(f.ui, 0.0f);
	test::eq(f.app.config.ghost_step, 1);
	crig::anim_ghost_opacity_moved(f.ui, 0.0f);
	test::@check(f.app.config.ghost_opacity >= crig::MIN_GHOST_OPACITY, "the opacity went invisible");
	crig::anim_ghost_future_moved(f.ui, 99.0f);
	test::eq(f.app.config.ghost_future, crig::MAX_GHOST_SIDE);

	// The panel's boxes are the same switches the View menu has.
	f.click(f.center_of(crig::ANIM_GHOSTS_PATH_ID)!!);
	f.ui.flush();
	test::@check(f.app.config.show_motion_path && crig::query_motion_path(f.ui).checked, "the panel's Motion path box did not turn it on");
	f.click(f.center_of(crig::ANIM_GHOSTS_ON_ID)!!);
	f.ui.flush();
	test::@check(!f.app.config.show_ghosts && !crig::query_ghosts(f.ui).checked, "the panel's Ghosts box did not turn them off");
}

fn void the_timeline_shades_the_ghosts_reach() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	multi_pose_workspace(&f);

	Timeline* timeline = f.ui.find(Timeline)!!.widget_as(Timeline);
	test::@check(timeline.ghost_past == 0.0f && timeline.ghost_future == 0.0f, "the sheet shades with Ghosts off");

	f.app.config.ghost_past = 4;
	f.app.config.ghost_future = 2;
	f.app.config.ghost_step = 3;
	crig::anim_ghosts_toggled(f.ui, true);
	f.ui.flush();
	f.feed({ 0, 0 });
	timeline = f.ui.find(Timeline)!!.widget_as(Timeline);
	// At 30 fps, three frames is a tenth of a second.
	test::@check(math::abs(timeline.ghost_past - 0.4f) < 1e-4f, "the past shade is %f s, not 0.4", timeline.ghost_past);
	test::@check(math::abs(timeline.ghost_future - 0.2f) < 1e-4f, "the future shade is %f s, not 0.2", timeline.ghost_future);

	crig::anim_ghost_step_moved(f.ui, 1.0f);
	f.ui.flush();
	f.feed({ 0, 0 });
	timeline = f.ui.find(Timeline)!!.widget_as(Timeline);
	test::@check(math::abs(timeline.ghost_past - 4.0f / 30.0f) < 1e-4f, "the shade did not follow the step (%f)", timeline.ghost_past);

	crig::anim_ghosts_toggled(f.ui, false);
	f.ui.flush();
	f.feed({ 0, 0 });
	timeline = f.ui.find(Timeline)!!.widget_as(Timeline);
	test::@check(timeline.ghost_past == 0.0f && timeline.ghost_future == 0.0f, "the shade stayed with Ghosts off");
}
