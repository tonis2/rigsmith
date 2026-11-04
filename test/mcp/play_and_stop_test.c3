module crig_tests::mcp;
import crig;
import image;
import image::png;
import mcp;
import three;
import rig;
import crig_tests::library;
import crig_tests::shared_app;
import std::core::test;
import std::collections::object;
import std::encoding::base64;
import std::encoding::json;
import std::io;
import std::io::file;
import std::io::path;
import std::math;
import std::math::quaternion;

// ---------------------------------------------------------------------------
// play and stop
//
// The one pair whose result is meant to be looked at rather than read back, so
// each check asserts both halves: what the tool answered, and what the player
// on `AppState` — the thing the window draws from — is actually doing.

fn bool? playing_body(Object* played, String clip, double time, double duration, bool loop)
{
	bool ok = played.get_bool("playing")! == true;
	ok = ok && played.get_string("clip")! == clip;
	ok = ok && played.get_string("pack")! == "Authored";
	ok = ok && math::abs(played.get_float("time")! - time) < 1e-6;
	ok = ok && math::abs(played.get_float("duration")! - duration) < 1e-6;
	ok = ok && played.get_bool("loop")! == loop;
	// Nothing was fitted: the fixture placed its own rig before any of this.
	ok = ok && played.get_bool("fitted")! == false;
	return ok;
}

fn void play_starts_what_the_user_would_see() @test
{
	Fixture fixture;
	fixture.open_played();
	defer fixture.close();
	Fixture* f = &fixture;
	Object*? played = f.call_tool("play", `{"clip":"bend","t":1.5}`);
	if (catch played)
	{
		test::@check(false, "play accepts a clip in the library");
		return;
	}
	defer played.free();

	crig::AnimRef ref = crig::resolve_clip(&f.app, "bend") ?? crig::NO_ANIM;
	test::@check((playing_body(played, "bend", 1.5, 3.0, false) ?? false)
		&& f.app.animating
		&& f.app.current_ref.same(ref)
		&& f.app.anim_time == 1.5f,
		"play starts the clip on the live player, at the time it was asked for");
}

<*
 The loop override, and the half of it that is easy to get wrong.

 `current_anim` is a copy of the template, so overriding the copy's flag is what
 keeps the override to this run. Writing it through to the library instead would
 change a clip nobody asked to edit — and, for a clip read off disk, silently
 disagree with the file it came from.
*>
fn void play_loops_only_this_run() @test
{
	Fixture fixture;
	fixture.open_played();
	defer fixture.close();
	Fixture* f = &fixture;
	Object*? played = f.call_tool("play", `{"clip":"bend","loop":true}`);
	if (catch played)
	{
		test::@check(false, "play accepts a loop override");
		return;
	}
	defer played.free();

	crig::AnimRef ref = crig::resolve_clip(&f.app, "bend") ?? crig::NO_ANIM;
	crig::AnimTemplate* stored = f.app.clip(ref);
	test::@check((played.get_bool("loop") ?? false) == true
		&& f.app.current_anim.loop == true
		&& stored != null && stored.loop == false,
		"loop:true wraps the run without editing the clip it played");
}

fn void play_wraps_a_looping_time() @test
{
	Fixture fixture;
	fixture.open_played();
	defer fixture.close();
	Fixture* f = &fixture;
	// Two and a half turns through a three-second clip.
	Object*? played = f.call_tool("play", `{"clip":"bend","t":7.5,"loop":true}`);
	if (catch played)
	{
		test::@check(false, "play accepts a time past the end of a looping clip");
		return;
	}
	defer played.free();

	test::@check((playing_body(played, "bend", 1.5, 3.0, true) ?? false) && f.app.anim_time == 1.5f,
		"a time past the end of a looping clip wraps, as playback does");
}

<*
 A refused play leaves the player exactly as it was.

 Asserted here rather than in a check of its own because the refusal only has
 something to disturb while something is running: this one arrives with the
 looping clip from the check above still on screen.
*>
fn void play_refuses_a_time_past_a_one_shot() @test
{
	Fixture fixture;
	fixture.open_playing();
	defer fixture.close();
	Fixture* f = &fixture;
	test::@check(f.refuses_tool("play", `{"clip":"bend","t":7.5}`, "7.5", "3", "does not loop")
		&& f.app.animating
		&& f.app.anim_time == 1.5f,
		"a time past the end of a clip that does not loop is refused, and nothing stops playing");
}

<*
 A chain slack enough that the lag is the whole point.

 A flexibility of 1 is the loosest spring a chain has — see
 `secondary_stiffness` — so this one closes under a hundredth of its gap per
 substep and crosses the turn a step behind the keyframes the whole way. No
 gravity, deliberately: the fixture's leg hangs straight down, where gravity
 pulls along the chain and would prove nothing about anything.
*>
const crig::SecondaryChain SLACK_CHAIN = {
	.preset = crig::SecondaryPreset.CUSTOM,
	.flexibility = 1.0f,
	.damping = 0.1f,
	.gravity = 0.0f,
	.collide = false,
};

// The fixture's knee-to-foot run as that chain.
fn crig::SecondaryChain slack_leg(Fixture* f)
{
	crig::SecondaryChain chain = SLACK_CHAIN;
	chain.root = named_dot(f, "knee");
	chain.tip = named_dot(f, "foot");
	return chain;
}

// A second and a half of playback, hand-driven. Real frames would make this a
// check of this machine's frame rate; the sim's own substep is fixed either way.
const usz PLAYED_FRAMES = 90;
const float PLAYED_STEP = 1.0f / 60.0f;

// One run of `bend` from the top, ticked a frame at a time, and where it left
// the foot on screen — `dot_position` is what the overlay draws and what a click
// lands on, so it is the posed answer rather than a private one.
fn Vec3 played_foot(Fixture* f, String arguments, uint foot)
{
	Object*? played = f.call_tool("play", arguments);
	if (catch played)
	{
		test::@check(false, "play accepts %s", arguments);
		return { 0, 0, 0 };
	}
	played.free();

	for (usz i = 0; i < PLAYED_FRAMES; i++) f.app.tick_animation(PLAYED_STEP);

	crig::Dot* dot = f.app.doc.find(foot);
	return dot ? f.app.dot_position(*dot) : (Vec3){ 0, 0, 0 };
}

<*
 The dynamic bones run under the clip, and `sim` is what turns them off.

 The seam the live preview is: `refresh_animation` samples the clip, the sim is
 advanced against that pose, and the palette everything below reads is built
 from what the sim wrote — so a dynamic knee lands the foot somewhere no
 keyframe put it. Both halves are asserted against the same clip on the same
 frames, because "physics happened" and "physics happened only when asked" are
 one claim measured twice.

 Through `play` rather than through the player, since the flag is the tool's;
 the player is what the ticks below drive, so the seam is exercised either way.
*>
fn void play_simulates_the_dynamic_bones() @test
{
	Fixture fixture;
	fixture.open_played();
	defer fixture.close();
	Fixture* f = &fixture;

	// Knee and foot together: a chain of one bone would turn a leaf, and turning
	// a leaf moves nothing. What the check reads is the foot's *position*, which
	// is the knee's rotation carried down the bone.
	f.app.set_secondary_recorded(slack_leg(f));
	f.app.undo_stack.commit();
	uint foot = named_dot(f, "foot");

	Vec3 keyed = played_foot(f, `{"clip":"bend","sim":false}`, foot);
	Vec3 simulated = played_foot(f, `{"clip":"bend"}`, foot);

	// Neither bound is a tuning. The solve is deterministic and lands at about
	// 0.003 — a hundred-and-seventieth of the bone it hangs off, with the
	// loosest spring a chain has — so the floor is well under what the physics
	// actually does and far over anything float noise could produce, and half a
	// bone is what separates a lag from a solve that blew up and threw the foot
	// across the room.
	float lag = (simulated - keyed).length();
	test::@check(lag > 0.001f && lag < 0.5f,
		"the physics carries the foot off the keyed pose without tearing it off the knee (%.4f)", lag);

	// A repaint is not a frame: `refresh_animation` with no dt in it runs no
	// substeps and still writes, which is what holds a settled tail in place
	// instead of snapping it back onto the keyframes.
	f.app.refresh_animation();
	crig::Dot* dot = f.app.doc.find(foot);
	Vec3 held = dot ? f.app.dot_position(*dot) : (Vec3){ 0, 0, 0 };
	test::@check((held - simulated).length() < 1.0e-5f,
		"and a repaint with no time in it holds the tail where it settled");
}

<*
 A bake on a rig with nothing dynamic is refused, and the refusal says where the
 setting it is missing lives.

 The ordinary state — no rig has a dynamic bone until somebody says so — which
 is exactly why the sentence has to carry a caller who has never met the
 feature. Baking a copy of the clip instead would look like it worked.
*>
fn void bake_physics_says_when_the_rig_has_nothing_dynamic() @test
{
	Fixture fixture;
	fixture.open_played();
	defer fixture.close();
	Fixture* f = &fixture;

	test::@check(
		f.refuses_tool("bake_physics", `{"clip":"bend"}`, "no secondary motion", "property of the rig"),
		"a bake with nothing dynamic says so, and says that physics is set on the rig rather than on the clip");
	test::@check(
		f.refuses_tool("bake_physics", `{"clip":"waltz"}`, "waltz", "The library holds"),
		"and an unknown clip is still named, with what could have been asked for instead");
}

<*
 A bake lands the simulation in the Authored pack as a clip of its own.

 The whole of what M4 is for, over the wire: the same knee and foot the live
 preview swings, recorded into keys that need no solver to play back. Three
 things are asserted and they are the three an agent would ask — where it
 landed, how densely, and which bones the answer is about.

 `hz` is asked for as 50 on purpose. The solver's grid is 1/120 s, so 50 is not
 expressible and the bake snaps to 60; a caller told "50" would go looking for
 its keys in the wrong places.
*>
fn void bake_physics_lands_the_simulation_as_a_clip() @test
{
	Fixture fixture;
	fixture.open_played();
	defer fixture.close();
	Fixture* f = &fixture;

	f.app.set_secondary_recorded(slack_leg(f));
	f.app.undo_stack.commit();

	Object*? answered = f.call_tool("bake_physics", `{"clip":"bend","name":"bend baked","hz":50}`);
	if (catch answered)
	{
		test::@check(false, "bake_physics answers");
		return;
	}
	defer answered.free();

	test::@check((answered.get_string("clip") ?? "") == "bend baked"
		&& (answered.get_string("pack") ?? "") == "Authored"
		&& (answered.get_string("source") ?? "") == "bend"
		&& (answered.get_bool("replaced") ?? true) == false,
		"the baked clip lands in the Authored pack under the name it was given");

	// Three seconds at 60 samples a second, plus the closing key on the duration
	// itself. Stated exactly rather than as "more than none": a bake that lost
	// its grid would still write keyframes.
	test::@check((answered.get_int("keyframes") ?? 0) == 181
		&& math::abs((answered.get_float("samples_hz") ?? 0.0) - 60.0) < 1.0e-6,
		"sampled on the solver's own grid, and the rate reported is the one used rather than the one asked for");

	Object*? dynamic = answered.get("dynamic_joints");
	bool named_both = false;
	if (try dynamic)
	{
		named_both = dynamic.get_len() == 2
			&& (dynamic.get_string_at(0) ?? "") == "knee"
			&& (dynamic.get_string_at(1) ?? "") == "foot";
	}
	test::@check(named_both, "and the answer names the bones it is about, nearest the body first");

	crig::AnimPack* pack = f.app.authored();
	bool held = false;
	if (pack)
	{
		foreach (clip : pack.clips)
		{
			if (clip.name == "bend baked" && clip.keyframes.len == 181) held = true;
		}
	}
	test::@check(held, "and the pack really holds it, not merely the answer");
}
