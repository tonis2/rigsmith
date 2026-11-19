<*
 A one-off made and edited with the mouse: the bin's + One-off on the Clip lane, a
 double-click or Enter on its strip to edit it with the Animations tools, its
 name on the card, and Back to cutscene, all in the Animations dock.
*>
module crig_tests::ui;
import crig;
import cui;
import cui::widgets;
import std::core::test;
import std::math;

// The Animations dock in a pane under the model, showing the first cutscene, one frame later.
fn void one_off_tab(Fixture* f) @local
{
	crig::show_pane_view(f.ui, crig::ANIMATION_VIEW, SplitAxis.VERTICAL, 0.5f);
	(void)f.app.show_cutscene(0);
	f.ui.flush();
	f.feed(f.ui.input.mouse);
}

fn Vec2 one_off_centre(Fixture* f, String id) @local
{
	Element* elem = f.ui.find_id(id)!!;
	return elem.absolute + elem.size * 0.5f;
}

fn Vec2 one_off_lane(Fixture* f, float t) @local
{
	Element* timeline = f.ui.find_id(crig::CUT_TIMELINE_ID)!!;
	CutsceneTimeline* drawn = timeline.widget_as(CutsceneTimeline);
	Cutscene* c = f.app.cutscene();
	return timeline.absolute + (Vec2){ drawn.x_of(timeline, c, t), drawn.lane_top(timeline, c, 0, WHAT) + crig::CUT_LANE_H * 0.5f };
}

fn CutStrip* first_strip(Fixture* f) @local
{
	Cutscene* c = f.app.cutscene();
	if (!c || c.actors.len == 0 || c.actors[0].strips.len == 0) return null;
	return &c.actors[0].strips[0];
}

fn bool about(float a, float b) @local => math::abs(a - b) <= 1e-4f;

fn void a_one_off_is_made_and_edited_with_the_mouse() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	test::@check(f.app.apply_plan_named("biped"), "could not fit a rig");
	f.app.stop_animation();
	test::@check(f.app.make_actor(f.app.active, "hero"), "the cube is no actor");
	(void)f.app.add_cutscene();
	one_off_tab(&f);
	f.app.show_cutscene_at(1.0f);
	f.click(one_off_lane(&f, 6.0f));
	f.feed(f.ui.input.mouse);
	f.app.show_cutscene_at(1.0f);
	usz steps = (usz)f.app.cut_history.undo.len();

	// New one-off: a 2 s strip of an empty clip of the cutscene at the playhead, picked, one step.
	test::@check(cut_bin_has(&f, "+ One-off"), "no + One-off piece in the bin");
	f.click(cut_bin_row(&f, "+ One-off"));
	f.feed(f.ui.input.mouse);
	CutStrip* s = first_strip(&f);
	if (!s)
	{
		test::@check(false, "no strip was added");
		return;
	}
	test::@check(s.one_off && about(s.start, 1.0f) && about(s.end, 3.0f), "the strip is %s %f-%f", s.clip, s.start, s.end);
	test::@check(f.app.cut_selected == s.id, "the new strip is not picked");
	test::eq((usz)f.app.cut_history.undo.len(), steps + 1);
	test::@check(has_id(&f, crig::CUT_CARD_ONE_OFF_ID) && has_id(&f, crig::CUT_CARD_EDIT_ID) && has_id(&f, crig::CUT_CARD_DROP_ID),
		"the card has no name, edit or delete for the one-off");

	// Renamed from the card, with its strip.
	Element* name = f.ui.find_id(crig::CUT_CARD_ONE_OFF_ID)!!;
	name.widget_as(TextField).set_text(name, "");
	f.type_into(name, "bow");
	f.feed_key(Key.RETURN);
	f.feed(f.ui.input.mouse);
	test::@check(first_strip(&f).clip == "bow" && f.app.cutscene().one_offs[0].clip.name == "bow", "the rename did not land");
	test::eq((usz)f.app.cut_history.undo.len(), steps + 2);

	// A double-click on the strip edits it: the character's own tools, and the way back.
	f.ui.click(one_off_lane(&f, 2.0f), count: 2);
	f.feed(f.ui.input.mouse);
	f.feed(f.ui.input.mouse);
	test::@check(f.app.one_off_open(), "the double-click did not open the one-off");
	test::@check(f.app.doc.animations.len() == 1 && f.app.doc.animations[0].clip == "bow", "the timeline does not edit the one-off");
	test::@check(has_id(&f, crig::ANIM_BACK_ID), "no Back to cutscene in the Animations tab");
	// The dock shows the one-off as a clip, not the cutscene.
	test::@check(!has_id(&f, crig::CUT_TIMELINE_ID), "the dock still shows the cutscene while its one-off is edited");

	// Back: the edit is over and the cutscene is where it was.
	if (!has_id(&f, crig::ANIM_BACK_ID)) return;
	f.click(one_off_centre(&f, crig::ANIM_BACK_ID));
	f.feed(f.ui.input.mouse);
	test::@check(!f.app.one_off_open(), "Back did not end the edit");
	test::@check(!has_id(&f, crig::ANIM_BACK_ID), "the way back outlived the edit");
	foreach (bound : f.app.doc.animations) test::@check(bound.clip != "bow", "the one-off was left among the cube's clips");

	// Enter on the picked strip edits it too. Clicks apart, so they are no double-click.
	f.click(one_off_lane(&f, 1.4f));
	f.feed(f.ui.input.mouse);
	f.feed_key(Key.RETURN);
	f.feed(f.ui.input.mouse);
	test::@check(f.app.one_off_open(), "Enter did not open the one-off");
	(void)f.app.back_to_cutscene();
	f.feed(f.ui.input.mouse);

	// Deleted from the card, with every strip that plays it; Ctrl+Z brings both back.
	f.feed(f.ui.input.mouse);
	test::@check(has_id(&f, crig::CUT_TIMELINE_ID), "the dock did not show the cutscene again");
	f.click(one_off_lane(&f, 2.6f));
	f.feed(f.ui.input.mouse);
	test::@check(has_id(&f, crig::CUT_CARD_DROP_ID), "no card for the picked one-off");
	if (!has_id(&f, crig::CUT_CARD_DROP_ID)) return;
	f.click(one_off_centre(&f, crig::CUT_CARD_DROP_ID));
	f.feed(f.ui.input.mouse);
	test::@check(f.app.cutscene().one_offs.len == 0 && f.app.cutscene().actors[0].strips.len == 0, "the one-off or its strip is still there");
	crig::menu_undo(f.ui);
	f.feed(f.ui.input.mouse);
	test::@check(f.app.cutscene().one_offs.len == 1 && f.app.cutscene().actors[0].strips.len == 1, "undo did not bring them back");
}
