module crig_tests::animation_preview_loop;

import crig;
import crig_tests::shared_app;
import std::core::test;
import std::math;

const AnimKeyframe[] FRAMES = {
	{ .time = 0 },
	{ .time = 1 },
};

fn bool ready(AppState* app)
{
	*app = shared_app::open();
	return app.apply_plan_named("biped");
}

<*
 Preview repetition belongs to the transport, not the animation document.

 Exercise all three choices against both authored intents.  Keeping the same
 AppState also asserts that the setting is session-wide and survives starting
 another preview, while the cursor and source templates prove that it does not
 become an authored edit.
*>
fn void preview_loop_override_changes_only_transport() @test
{
	AppState app;
	test::@check(ready(&app), "fixture failed");
	defer app.free();

	AnimTemplate once = { .name = "Once", .duration = 1, .keyframes = FRAMES[..], .loop = false };
	AnimTemplate loop = { .name = "Loop", .duration = 1, .keyframes = FRAMES[..], .loop = true };
	sz history = app.undo_stack.cursor;

	app.anim_preview_loop = LOOP;
	app.start_animation(once);
	test::@check(app.animating, "non-looping clip did not start");
	app.tick_animation(1.25f);
	test::@check(app.animating && !app.anim_paused && app.anim_time > 0.24f && app.anim_time < 0.26f,
		"forced preview loop did not wrap");
	test::@check(!app.current_anim.loop && !once.loop, "preview loop rewrote authored intent");

	app.anim_preview_loop = PLAY_ONCE;
	app.start_animation(loop);
	test::@check(app.animating, "looping clip did not start");
	app.tick_animation(1.25f);
	test::@check(app.animating && app.anim_paused && app.anim_time == 1,
		"play-once did not park the editing preview at its final pose");
	test::@check(app.current_anim.loop && loop.loop, "play-once rewrote authored intent");

	app.anim_preview_loop = FOLLOW_CLIP;
	app.start_animation(loop);
	test::@check(app.animating, "follow-loop clip did not start");
	app.tick_animation(1.25f);
	test::@check(!app.anim_paused && app.anim_time > 0.24f && app.anim_time < 0.26f,
		"follow setting ignored authored loop");
	app.start_animation(once);
	test::@check(app.animating, "follow-once clip did not start");
	app.tick_animation(1.25f);
	test::@check(app.anim_paused && app.anim_time == 1,
		"follow setting ignored authored play-once intent");

	test::@check(app.undo_stack.cursor == history, "preview controls created undo history");
}
