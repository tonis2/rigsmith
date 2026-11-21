<*
 Strips edited on the Cutscene timeline with the mouse: add, pick, drag, resize,
 snap, Esc, delete and the card, each one undo step.
*>
module crig_tests::ui;
import crig;
import crig_tests::helpers;
import cui;
import cui::widgets;
import std::core::test;
import std::math;
import std::math::quaternion;

// A point of the timeline: time `t` on a lane of actor `actor`, `nudge` pixels to the right.
fn Vec2 lane_point(Fixture* f, usz actor, CutLane lane, float t, float nudge = 0.0f) @local
{
	Element* timeline = f.ui.find_id(crig::CUT_TIMELINE_ID)!!;
	CutsceneTimeline* drawn = timeline.widget_as(CutsceneTimeline);
	Cutscene* c = f.app.cutscene();
	float x = drawn.x_of(timeline, c, t) + nudge;
	float y = drawn.lane_top(timeline, c, actor, lane) + crig::CUT_LANE_H * 0.5f;
	return timeline.absolute + (Vec2){ x, y };
}

fn float seconds_per_pixel(Fixture* f) @local
{
	Element* timeline = f.ui.find_id(crig::CUT_TIMELINE_ID)!!;
	CutsceneTimeline* drawn = timeline.widget_as(CutsceneTimeline);
	Cutscene* c = f.app.cutscene();
	return 1.0f / (drawn.x_of(timeline, c, 1.0f) - drawn.x_of(timeline, c, 0.0f));
}

fn CutStrip* hero_strip(Fixture* f, usz k) @local
{
	Cutscene* c = f.app.cutscene();
	if (!c || c.actors.len == 0 || k >= c.actors[0].strips.len) return null;
	return &c.actors[0].strips[k];
}

// Click the row of a popup's list whose label is `label`.
fn bool click_menu_row(Fixture* f, String list_id, String label) @local
{
	Element*? found = f.ui.find_id(list_id);
	if (catch found) return false;
	Tree* tree = found.widget_as(Tree);
	float row_h = tree.style.resolved().row_height;
	foreach (usz i, row : tree.rows)
	{
		if (row.label != label) continue;
		f.click(found.absolute + (Vec2){ found.size.x * 0.5f, ((float)i + 0.5f) * row_h });
		f.feed(f.ui.input.mouse);
		return true;
	}
	return false;
}

fn void strips_are_added_picked_dragged_and_deleted_with_the_mouse() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	test::@check(f.app.apply_plan_named("biped"), "could not fit a rig");
	AnimRef wave_ref = f.app.new_clip("Wave", 1.0f, loop: false);
	AnimRef idle_ref = f.app.new_clip("Idle", 2.0f);
	test::@check(wave_ref.valid() && idle_ref.valid(), "no clips to play");
	String wave = f.app.clip(wave_ref).name.tcopy();
	f.app.stop_animation();
	test::@check(f.app.make_actor(f.app.active, "hero"), "the cube is no actor");
	(void)f.app.add_cutscene();
	// A second actor, with no character, for the turn to face.
	Cutscene two = f.app.cutscene().copy(mem);
	CutActor[] actors = alloc::new_array(mem, CutActor, 2);
	actors[0] = two.actors[0];
	actors[1] = { .row = "guide".copy(mem), .home_rotation = quaternion::IDENTITY };
	free(two.actors);
	two.actors = actors;
	f.app.replace_cutscene(0, two);
	show_cutscene_tab(&f);
	test::@check(cut_bin_has(&f, wave) && cut_bin_has(&f, "Turn"), "no %s and Turn pieces", wave);
	usz steps = helpers::cut_steps(&f.app);

	// The clip's piece: a click lays it at the playhead, one pass long.
	f.click(cut_bin_row(&f, wave));
	f.feed(f.ui.input.mouse);
	CutStrip* s = hero_strip(&f, 0);
	if (!s)
	{
		test::@check(false, "the menu added no strip");
		return;
	}
	test::@check(s.kind == PLAY && s.clip == wave && math::is_approx(s.start, 0, 1e-4f) && math::is_approx(s.end, 1.0f, 1e-4f) && !s.loop,
		"the play is %s %f-%f", s.clip, s.start, s.end);
	test::@check(f.app.cut_selected == s.id, "the new strip is not picked");
	test::eq(helpers::cut_steps(&f.app), steps + 1);
	test::@check(has_id(&f, crig::CUT_CARD_ID), "no card for the picked strip");

	// A click on an empty lane drops the pick; one on the strip picks it again.
	f.click(lane_point(&f, 0, WHAT, 5.0f));
	f.feed(f.ui.input.mouse);
	test::@check(f.app.cut_selected == 0, "an empty lane kept the pick");
	test::@check(!has_id(&f, crig::CUT_CARD_ID), "a card with nothing picked");
	f.click(lane_point(&f, 0, WHAT, 0.5f));
	f.feed(f.ui.input.mouse);
	test::@check(f.app.cut_selected == hero_strip(&f, 0).id, "the click did not pick the strip");
	test::eq(helpers::cut_steps(&f.app), steps + 1);

	// Drag the body: the preview follows while the button is down; the drop is one step.
	test::@check(f.app.set_cutscene_preview(true), "preview");
	f.app.show_cutscene_at(1.0f);
	Vec2 grab = lane_point(&f, 0, WHAT, 0.5f);
	f.feed(grab);
	f.feed(grab, left: true);
	f.feed(lane_point(&f, 0, WHAT, 1.0f), left: true);
	test::@check(math::is_approx(hero_strip(&f, 0).start, 0.5f, 1e-4f), "mid-drag the strip is at %f", hero_strip(&f, 0).start);
	test::@check(math::is_approx(f.app.anim_time, 0.5f, 1e-3f), "the preview shows %f s of the wave, not half a second in", f.app.anim_time);
	Vec2 drop = lane_point(&f, 0, WHAT, 2.5f);
	f.feed(drop, left: true);
	f.feed(drop);
	f.feed(drop);
	test::@check(math::is_approx(hero_strip(&f, 0).start, 2.0f, 1e-4f) && math::is_approx(hero_strip(&f, 0).end, 3.0f, 1e-4f), "the drop put it at %f", hero_strip(&f, 0).start);
	test::eq(helpers::cut_steps(&f.app), steps + 2);
	crig::menu_undo(f.ui);
	f.feed(f.ui.input.mouse);
	test::@check(math::is_approx(hero_strip(&f, 0).start, 0.0f, 1e-4f), "one undo takes back the whole drag, not to %f", hero_strip(&f, 0).start);
	crig::menu_redo(f.ui);
	f.feed(f.ui.input.mouse);
	test::@check(math::is_approx(hero_strip(&f, 0).start, 2.0f, 1e-4f), "redo");

	// Near the playhead the start snaps onto it, off the frames.
	f.app.show_cutscene_at(3.31f);
	float nudge = 2.0f;
	grab = lane_point(&f, 0, WHAT, 2.5f);
	drop = lane_point(&f, 0, WHAT, 2.5f + 1.31f, nudge);
	f.drag(grab, drop);
	f.feed(drop);
	test::@check(math::is_approx(hero_strip(&f, 0).start, 3.31f, 1e-5f), "the start is %f, not on the playhead", hero_strip(&f, 0).start);
	test::eq(helpers::cut_steps(&f.app), steps + 3);

	// Resize: the end, then the start, whose clip stays where it was in time.
	grab = lane_point(&f, 0, WHAT, hero_strip(&f, 0).end);
	f.drag(grab, lane_point(&f, 0, WHAT, 5.0f));
	f.feed(f.ui.input.mouse);
	test::@check(math::is_approx(hero_strip(&f, 0).end, 5.0f, 1e-4f) && math::is_approx(hero_strip(&f, 0).start, 3.31f, 1e-5f), "the end is %f", hero_strip(&f, 0).end);
	test::eq(helpers::cut_steps(&f.app), steps + 4);
	grab = lane_point(&f, 0, WHAT, hero_strip(&f, 0).start);
	f.drag(grab, lane_point(&f, 0, WHAT, 3.81f));
	f.feed(f.ui.input.mouse);
	test::@check(math::is_approx(hero_strip(&f, 0).start, 3.8f, 1e-4f), "the start is %f, not on frame 3.8", hero_strip(&f, 0).start);
	test::@check(math::is_approx(hero_strip(&f, 0).offset, 3.8f - 3.31f, 1e-4f), "the offset is %f", hero_strip(&f, 0).offset);
	test::@check(math::is_approx(hero_strip(&f, 0).end, 5.0f, 1e-4f), "the end stayed");
	test::eq(helpers::cut_steps(&f.app), steps + 5);

	// Esc while dragging puts the strip back and leaves no step.
	float before = hero_strip(&f, 0).start;
	grab = lane_point(&f, 0, WHAT, 4.5f);
	f.feed(grab);
	f.feed(grab, left: true);
	f.feed(lane_point(&f, 0, WHAT, 6.0f), left: true);
	test::@check(!math::is_approx(hero_strip(&f, 0).start, before, 1e-4f), "the drag did not move the strip");
	f.feed(lane_point(&f, 0, WHAT, 6.0f), left: true, keys: { Key.ESCAPE });
	f.feed(lane_point(&f, 0, WHAT, 6.0f));
	f.feed(f.ui.input.mouse);
	test::@check(math::is_approx(hero_strip(&f, 0).start, before, 1e-4f), "Esc left the strip at %f", hero_strip(&f, 0).start);
	test::eq(helpers::cut_steps(&f.app), steps + 5);

	// The Turn piece: the menu of the other actors; the turn faces the one picked.
	f.app.show_cutscene_at(1.0f);
	f.click(cut_bin_row(&f, "Turn"));
	f.feed(f.ui.input.mouse);
	test::@check(click_menu_row(&f, crig::CUT_TURN_LIST_ID, "guide"), "no guide in the turn menu");
	CutStrip* turned = f.app.cut_selected_strip();
	test::@check(turned && turned.kind == TURN && turned.target_row == "guide" && math::is_approx(turned.start, 1.0f, 1e-4f)
		&& math::is_approx(turned.end - turned.start, crig::CUT_TURN_LENGTH, 1e-4f), "the turn toward the guide");
	test::eq(helpers::cut_steps(&f.app), steps + 6);
	test::@check(has_id(&f, crig::CUT_CARD_TARGET_ID) && has_id(&f, crig::CUT_CARD_PICK_ID), "the turn's card has no target");

	// Delete takes the picked strip; Ctrl+Z brings it back.
	// A joint is still selected from the rig: Delete after the menu takes the strip, not the joint.
	usz count = f.app.cutscene().actors[0].strips.len;
	sz joints = f.app.doc.dots.len();
	f.feed_key(Key.DELETE);
	test::@check(f.app.cutscene().actors[0].strips.len == count - 1, "Delete did not take the turn");
	test::@check(f.app.doc.dots.len() == joints, "Delete took a joint too");
	test::@check(f.app.cut_selected == 0, "the pick outlived its strip");
	test::eq(helpers::cut_steps(&f.app), steps + 7);
	crig::menu_undo(f.ui);
	f.feed(f.ui.input.mouse);
	test::@check(f.app.cutscene().actors[0].strips.len == count, "undo did not bring the turn back");

	// The card: a number typed and a switch, each one step.
	f.click(lane_point(&f, 0, WHAT, 4.5f));
	f.feed(f.ui.input.mouse);
	Element* speed = f.ui.find_id(crig::CUT_CARD_SPEED_ID)!!;
	usz at = helpers::cut_steps(&f.app);
	speed.widget_as(TextField).set_text(speed, "");
	f.type_into(speed, "2");
	f.feed_key(Key.RETURN);
	f.feed(f.ui.input.mouse);
	CutStrip* played = f.app.cut_selected_strip();
	test::@check(played && played.kind == PLAY && math::is_approx(played.speed, 2.0f, 1e-4f), "the speed field did not set the speed");
	test::eq(helpers::cut_steps(&f.app), at + 1);
	f.click(id_centre(&f, crig::CUT_CARD_LOOP_ID));
	f.feed(f.ui.input.mouse);
	played = f.app.cut_selected_strip();
	test::@check(played && played.loop, "the loop switch did not loop the clip");
	test::eq(helpers::cut_steps(&f.app), at + 2);
	crig::menu_undo(f.ui);
	f.feed(f.ui.input.mouse);
	played = f.app.cut_selected_strip();
	test::@check(played && !played.loop && math::is_approx(played.speed, 2.0f, 1e-4f), "one undo took back more than the loop");

	// The strips and the actors are parts the agent tools can find.
	Element* timeline = f.ui.find_id(crig::CUT_TIMELINE_ID)!!;
	@pool()
	{
		Description d = timeline.describe();
		bool strip_part;
		bool actor_part;
		foreach (part : d.parts)
		{
			strip_part = strip_part || part.label == "cut-strip-0-0";
			actor_part = actor_part || part.label == "cut-actor-1";
		}
		test::@check(strip_part && actor_part, "the timeline does not name its strips and actors");
	};
}

fn void the_timeline_zooms_pans_and_scrolls_its_actors() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	test::@check(f.app.make_actor(f.app.active, "hero"), "the cube is no actor");
	(void)f.app.add_cutscene();
	// Twelve actors: more lanes than the pane has room for.
	Cutscene many = f.app.cutscene().copy(mem);
	CutActor[] actors = alloc::new_array(mem, CutActor, 12);
	actors[0] = many.actors[0];
	for (usz i = 1; i < 12; i++) actors[i] = { .row = string::format(mem, "extra_%d", i), .home_rotation = quaternion::IDENTITY };
	free(many.actors);
	many.actors = actors;
	f.app.replace_cutscene(0, many);
	show_cutscene_tab(&f);
	Element* timeline = f.ui.find_id(crig::CUT_TIMELINE_ID)!!;
	CutsceneTimeline* drawn = timeline.widget_as(CutsceneTimeline);
	Vec2 over = lane_point(&f, 0, WHERE, 5.0f);

	// Ctrl+wheel zooms about the pointer: the second under it stays put.
	float wide = drawn.x_of(timeline, f.app.cutscene(), 6.0f) - drawn.x_of(timeline, f.app.cutscene(), 5.0f);
	float anchor = drawn.time_of(timeline, f.app.cutscene(), over.x - timeline.absolute.x, true);
	f.ui.wheel(over, 1.0f, held: { Key.LEFT_CTRL });
	f.ui.wheel(over, 1.0f, held: { Key.LEFT_CTRL });
	float close = drawn.x_of(timeline, f.app.cutscene(), 6.0f) - drawn.x_of(timeline, f.app.cutscene(), 5.0f);
	test::@check(f.app.cut_zoom > 1.0f && close > wide * 1.4f, "the zoom is %f: a second is %f px, was %f", f.app.cut_zoom, close, wide);
	float still = drawn.time_of(timeline, f.app.cutscene(), over.x - timeline.absolute.x, true);
	test::@check(math::abs(still - anchor) < 0.01f, "the second under the pointer moved from %f to %f", anchor, still);

	// Shift+wheel pans time.
	float start = drawn.time_of(timeline, f.app.cutscene(), drawn.span(timeline).x, true);
	f.ui.wheel(over, 1.0f, held: { Key.LEFT_SHIFT });
	float later = drawn.time_of(timeline, f.app.cutscene(), drawn.span(timeline).x, true);
	test::@check(later > start, "Shift+wheel did not pan: %f then %f", start, later);

	// The wheel scrolls the actors, which do not fit.
	float top = drawn.lane_top(timeline, f.app.cutscene(), 0, WHERE);
	f.ui.wheel(over, -2.0f);
	float scrolled = drawn.lane_top(timeline, f.app.cutscene(), 0, WHERE);
	test::@check(scrolled < top && f.app.cut_view_top > 0.0f, "the lanes did not scroll: %f then %f", top, scrolled);
	CutTimelineHit hit = drawn.hit(timeline, f.app.cutscene(), { drawn.span(timeline).x + 4.0f, scrolled + crig::CUT_LANE_H * 2.5f });
	test::@check(hit.actor == 1 && hit.lane == WHERE, "a press finds the scrolled lanes: actor %d", hit.actor);
}
