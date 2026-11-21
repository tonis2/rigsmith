<*
 The guided tour: starting, stepping, ending, the overlay lighting what a step
 names, and the first-run welcome staying out of fixtures that cannot remember
 its answer.

     `c3c test --trust=full --test-noleak --test-filter crig_tests::ui::tutorial`
*>
module crig_tests::ui;

import crig;
import cui;
import cui::widgets;
import std::core::test;

fn bool tutorial_dialog_open(Fixture* f, String id)
{
	Element* dialog = f.ui.find_id(id)!!;
	return dialog.widget_as(Dialog).open;
}

fn void tutorial_settle(Fixture* f)
{
	for (int i = 0; i < 3; i++) f.feed({ 600, 400 });
}

// Starting opens the card on the first step; Back stops there, Next and Back move
// one step and keep the card open; Next past the last step ends the tour.
fn void tutorial_steps_forward_and_back_and_ends_after_the_last() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();

	test::@check(!f.app.tutorial_active, "the tour starts idle");
	crig::tutorial_start(f.ui);
	tutorial_settle(&f);
	test::@check(f.app.tutorial_active, "starting turns it on");
	test::@check(f.app.tutorial_step == 0, "at the first step");
	test::@check(tutorial_dialog_open(&f, crig::TUTORIAL_DIALOG_ID), "and opens the card");

	crig::tutorial_back(f.ui);
	test::@check(f.app.tutorial_step == 0, "Back on the first step stays there");
	crig::tutorial_next(f.ui);
	crig::tutorial_next(f.ui);
	test::@check(f.app.tutorial_step == 2, "two Nexts is the third step");
	crig::tutorial_back(f.ui);
	test::@check(f.app.tutorial_step == 1, "Back goes one step");
	tutorial_settle(&f);
	test::@check(tutorial_dialog_open(&f, crig::TUTORIAL_DIALOG_ID), "the card stays open between steps");

	for (usz i = 1; i < crig::TUTORIAL_STEPS.len; i++) crig::tutorial_next(f.ui);
	tutorial_settle(&f);
	test::@check(!f.app.tutorial_active, "Done on the last step did not end the tour");
	test::@check(!tutorial_dialog_open(&f, crig::TUTORIAL_DIALOG_ID), "Done on the last step did not close the card");
}

fn void tutorial_skip_and_closing_the_card_end_it() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();

	crig::tutorial_start(f.ui);
	crig::tutorial_skip(f.ui);
	tutorial_settle(&f);
	test::@check(!f.app.tutorial_active, "Skip ends it");
	test::@check(!tutorial_dialog_open(&f, crig::TUTORIAL_DIALOG_ID), "and closes the card");

	crig::tutorial_start(f.ui);
	tutorial_settle(&f);
	crig::set_dialog_open(f.ui, crig::TUTORIAL_DIALOG_ID, false);
	tutorial_settle(&f);
	test::@check(!f.app.tutorial_active, "the card's own close ends it too");
}

fn void tutorial_step_with_nothing_mounted_still_shows_its_card() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();

	// The fixture is one pane, so the timeline is not mounted: the step has no
	// target to light and must still be readable rather than failing.
	crig::tutorial_start(f.ui);
	while (f.app.tutorial_step < 7) crig::tutorial_next(f.ui);
	tutorial_settle(&f);
	test::@check(f.app.tutorial_active, "the tour carries on");
	test::@check(tutorial_dialog_open(&f, crig::TUTORIAL_DIALOG_ID), "with its card showing");
	Element* overlay = f.ui.find_id(crig::TUTORIAL_OVERLAY_ID)!!;
	test::@check(overlay.widget_as(crig::TutorialOverlay).holes == 0, "and nothing lit");
}

// The first-run welcome opens on a first run, and stays shut in a fixture with
// no config directory to remember the answer in.
fn void tutorial_welcome_opens_only_on_a_first_run_that_can_remember() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();

	tutorial_settle(&f);
	test::@check(!tutorial_dialog_open(&f, crig::WELCOME_DIALOG_ID), "a fixture that cannot save the answer is not asked");

	f.app.config.directory = "/nonexistent-rigsmith-config";
	f.app.config.tutorial_seen = false;
	f.app.welcome_checked = false;
	tutorial_settle(&f);
	test::@check(tutorial_dialog_open(&f, crig::WELCOME_DIALOG_ID), "a first run is offered the tour");
	// Back to nothing so closing the fixture has no config to write.
	f.app.config.tutorial_seen = true;
	f.app.config.directory = "";
}
