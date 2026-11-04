<*
 Explicit tangents on channel keys: the sampler reading them, the helpers that
 seed and convert them, and their persistence.

     `c3c test --trust=full --test-noleak --test-filter crig_tests::tangents`
*>
module crig_tests::tangents;

import crig;
import rig;
import std::core::test;
import std::io;
import std::io::file;
import std::math;
import std::math::vector;
import std::math::quaternion;

const float EPS = 1.0e-5f;
const float STEP = 1.0e-3f;

fn bool near(float a, float b, float within = EPS) => math::abs(a - b) <= within;

// Four keys on "hip" at uneven times, a turn about a different axis at each and
// a slide along a different line, so no component is trivially flat.
fn AnimTemplate wander_clip(AnimBlend blend = SMOOTH)
{
	float[4] times = { 0.0f, 0.4f, 0.7f, 1.2f };
	Vec3[4] axes = { { 0, 0, 1 }, { 1, 0, 0 }, { 0, 1, 1 }, { 1, 1, 0 } };
	float[4] angles = { 0.1f, 0.7f, -0.4f, 0.5f };
	Vec3[4] moves = { { 0, 0, 0 }, { 0.2f, 0.1f, 0 }, { 0.3f, -0.1f, 0.2f }, { 0.1f, 0, -0.1f } };
	AnimKeyframe[] keys = alloc::new_array(mem, AnimKeyframe, 4);
	foreach (usz i, &key : keys)
	{
		AnimKeyDot[] dots = alloc::new_array(mem, AnimKeyDot, 1);
		dots[0] = { .joint_name = "hip".copy(mem), .axis = axes[i].normalize(), .angle = angles[i], .move = moves[i] };
		*key = { .time = times[i], .dots = dots };
	}
	AnimTemplate clip = { .name = "wander".copy(mem), .duration = 1.2f, .keyframes = keys, .blend = blend, .owned = true };
	clip.compile_tracks(mem);
	return clip;
}

fn float turn_between(Quaternionf a, Quaternionf b)
{
	Quaternionf carry = b * a.conjugate();
	return 2.0f * math::atan2(carry.v.xyz.length(), math::abs(carry.v.w));
}

// The scalar Catmull-Rom the sampler used before tangents existed, over
// non-uniform keys that do not loop: ends repeat themselves.
fn float reference(float[] t, float[] v, float at)
{
	usz seg = 0;
	while (seg < 2 && at >= t[seg + 1]) seg++;
	usz p0 = seg == 0 ? 0 : seg - 1;
	usz p3 = seg + 2 > 3 ? 3 : seg + 2;
	float span = t[seg + 1] - t[seg];
	float m1 = (v[seg + 1] - v[p0]) / (t[seg + 1] - t[p0]) * span;
	float m2 = (v[p3] - v[seg]) / (t[p3] - t[seg]) * span;
	float u = (at - t[seg]) / span;
	float s = u * u;
	float c = s * u;
	return (2 * c - 3 * s + 1) * v[seg] + (c - 2 * s + u) * m1 + (-2 * c + 3 * s) * v[seg + 1] + (c - s) * m2;
}

fn void default_keys_play_the_catmull_rom_they_always_did() @test
{
	AnimTemplate clip = wander_clip();
	defer clip.free(mem);
	float[4] t = { 0.0f, 0.4f, 0.7f, 1.2f };
	float[16] q;
	float[12] slide;
	Quaternionf[4] turns;
	foreach (usz i, frame : clip.keyframes)
	{
		turns[i] = frame.rotation_of("hip");
		for (usz c = 0; c < 4; c++) q[c * 4 + i] = turns[i].v[c];
		for (usz c = 0; c < 3; c++) slide[c * 4 + i] = frame.offset_of("hip")[c];
		test::@check(!clip.keyframes[i].dots[0].rotation_tangents.explicit()
			&& !clip.keyframes[i].dots[0].translation_tangents.explicit(), "a plain key has tangents");
	}
	test::@check(!clip.uses_tangents(), "a plain clip claims tangents");
	for (int i = 0; i <= 24; i++)
	{
		float at = 1.2f * (float)i / 24.0f;
		Vec3 moved = clip.translation_at("hip", at);
		for (usz c = 0; c < 3; c++)
		{
			test::@check(near(moved[c], reference(t[..], slide[c * 4:4], at)), "slide %d off the Catmull-Rom at %f", (int)c, at);
		}
		Quaternionf expect = { .v = {
			reference(t[..], q[0:4], at), reference(t[..], q[4:4], at), reference(t[..], q[8:4], at), reference(t[..], q[12:4], at) } };
		test::@check(turn_between(clip.rotation_at("hip", at), expect.normalize()) < 1.0e-4f, "the turn is off the Catmull-Rom at %f", at);
	}
}

fn bool same_playback(AnimTemplate a, AnimTemplate b, float within = 1.0e-4f, bool slides = true)
{
	for (int i = 0; i <= 48; i++)
	{
		float at = a.duration * (float)i / 48.0f;
		float turned = turn_between(a.rotation_at("hip", at), b.rotation_at("hip", at));
		float slid = slides ? (a.translation_at("hip", at) - b.translation_at("hip", at)).length() : 0.0f;
		if (turned > within || slid > within)
		{
			io::printfn("playback differs at %f: turn %f slide %f", at, turned, slid);
			return false;
		}
	}
	return true;
}

fn void auto_to_free_and_broken_keep_the_curve() @test
{
	AnimTemplate reference_clip = wander_clip();
	defer reference_clip.free(mem);
	AnimTangent[2] modes = { FREE, BROKEN };
	foreach (mode : modes)
	{
		AnimTemplate clip = wander_clip();
		defer clip.free(mem);
		for (usz k = 0; k < 4; k++)
		{
			test::@check(crig::set_tangent_mode(&clip, k, "hip", true, mode), "rotation key %d refused", (int)k);
			test::@check(crig::set_tangent_mode(&clip, k, "hip", false, mode), "translation key %d refused", (int)k);
		}
		test::@check(clip.uses_tangents(), "tangents were not set");
		test::@check(same_playback(reference_clip, clip), "switching Auto to mode %d changed the playback", (int)mode.ordinal);
	}

	// One key at a time, and back to Auto.
	AnimTemplate clip = wander_clip();
	defer clip.free(mem);
	test::@check(crig::set_tangent_mode(&clip, 1, "hip", true, FREE) && same_playback(reference_clip, clip), "one key changed the curve");
	test::@check(crig::set_tangent_mode(&clip, 1, "hip", true, AUTO) && same_playback(reference_clip, clip)
		&& !clip.uses_tangents() && clip.keyframes[1].dots[0].rotation_tangents.incoming.length_sq() == 0.0f,
		"going back to Auto left something behind");

	// A key that does not key the channel is refused.
	test::@check(!crig::set_tangent_mode(&clip, 1, "knee", true, FREE) && !crig::set_tangent_mode(&clip, 9, "hip", true, FREE),
		"a missing key took a mode");
}

fn void the_effective_tangent_is_the_velocity_that_plays() @test
{
	AnimTemplate clip = wander_clip();
	defer clip.free(mem);
	foreach (usz k, frame : clip.keyframes)
	{
		float t = frame.time;
		bool first = k == 0;
		bool last = k == 3;
		// One-sided differences, on the side with a segment.
		float dir = last ? -1.0f : 1.0f;
		Vec3 slide = (clip.translation_at("hip", t + dir * STEP) - clip.translation_at("hip", t)) / (dir * STEP);
		Vec3 offered = crig::effective_translation_tangent(clip, k, "hip", first);
		test::@check((offered - slide).length() < 0.02f, "key %d slide tangent %s against velocity %s", (int)k, offered, slide);
		Quaternionf at = clip.rotation_at("hip", t);
		Quaternionf after = clip.rotation_at("hip", t + dir * STEP);
		Vec3 spin = crig::effective_rotation_tangent(clip, k, "hip", first);
		Quaternionf carry = after * at.conjugate();
		if (carry.v.w < 0.0f) carry = -carry;
		Vec3 played = carry.v.xyz * (2.0f / (dir * STEP));
		test::@check((spin - played).length() < 0.03f * math::max(1.0f, spin.length()),
			"key %d rotation tangent %s against velocity %s", (int)k, spin, played);
	}
	// The same key reads the same tangent from either side.
	test::@check((crig::effective_rotation_tangent(clip, 1, "hip", true) - crig::effective_rotation_tangent(clip, 1, "hip", false)).length() < 1.0e-5f,
		"an Auto key's two tangents differ");
	test::@check(crig::effective_rotation_tangent(clip, 1, "knee", true).length_sq() == 0.0f, "a missing channel gave a tangent");
}

fn void a_free_rotation_tangent_is_the_angular_velocity_through_the_key() @test
{
	AnimTemplate clip = wander_clip();
	defer clip.free(mem);
	Vec3 rate = { 0.3f, -1.1f, 2.0f };
	test::@check(crig::set_tangent_rate(&clip, 1, "hip", true, false, rate), "the tangent was refused");
	test::@check(clip.keyframes[1].dots[0].rotation_tangents.mode == BROKEN, "an unset key did not break");
	Quaternionf at = clip.rotation_at("hip", 0.4f);
	Quaternionf after = clip.rotation_at("hip", 0.4f + STEP);
	Quaternionf carry = after * at.conjugate();
	if (carry.v.w < 0.0f) carry = -carry;
	Vec3 played = carry.v.xyz * (2.0f / STEP);
	test::@check((played - rate).length() < 0.02f * rate.length(), "the key leaves at %s, not %s", played, rate);
	// The arriving side kept its auto rate: setting one end broke the key rather than moving both.
	Quaternionf before = clip.rotation_at("hip", 0.4f - STEP);
	Quaternionf arrived = at * before.conjugate();
	if (arrived.v.w < 0.0f) arrived = -arrived;
	Vec3 entering = arrived.v.xyz * (2.0f / STEP);
	test::@check((entering - crig::effective_rotation_tangent(clip, 1, "hip", true)).length() < 0.05f, "the arriving rate moved");
	test::@check((entering - rate).length() > 0.1f, "the arriving rate followed a broken key");

	// A free key turns its other end after the dragged one, keeping its length.
	test::@check(crig::set_tangent_mode(&clip, 1, "hip", true, FREE), "free was refused");
	Vec3 turned = { 0, 2.0f, 0 };
	test::@check(crig::set_tangent_rate(&clip, 1, "hip", true, true, turned), "free tangent refused");
	AnimTangents free = clip.keyframes[1].dots[0].rotation_tangents;
	test::@check((free.incoming - turned).length() < EPS && (free.outgoing.normalize() - turned.normalize()).length() < 1.0e-4f
		&& near(free.outgoing.length(), rate.length(), 1.0e-3f), "the free key's ends are not aligned");
}

fn void a_free_translation_tangent_bends_the_segment_the_way_it_points() @test
{
	AnimTemplate clip = wander_clip();
	defer clip.free(mem);
	Vec3 before = clip.translation_at("hip", 0.2f);
	// A hermite midpoint moves by an eighth of the end tangent times the span.
	test::@check(crig::set_tangent_mode(&clip, 0, "hip", false, FREE), "free was refused");
	Vec3 seeded = clip.keyframes[0].dots[0].translation_tangents.outgoing;
	test::@check(crig::set_tangent_rate(&clip, 0, "hip", false, false, seeded + (Vec3){ 0, 0, 3.0f }), "rate refused");
	Vec3 after = clip.translation_at("hip", 0.2f);
	test::@check(near(after.z - before.z, 3.0f * 0.4f * 0.125f, 1.0e-4f) && near(after.x, before.x, 1.0e-4f)
		&& near(after.y, before.y, 1.0e-4f), "the midpoint moved by %s", after - before);
	// The key's own value is where it was, and the next key's too.
	test::@check((clip.translation_at("hip", 0.0f) - (Vec3){}).length() < EPS
		&& (clip.translation_at("hip", 0.4f) - (Vec3){ 0.2f, 0.1f, 0 }).length() < EPS, "a tangent moved a key");
	// The segment past the next key is untouched but for the arrival at it.
	test::@check(near(clip.translation_at("hip", 1.0f).y, wander_clip_value_y(1.0f), 1.0e-5f), "a tangent reached a far segment");
}

fn float wander_clip_value_y(float at)
{
	AnimTemplate fresh = wander_clip();
	defer fresh.free(mem);
	return fresh.translation_at("hip", at).y;
}

fn void flat_tangents_stop_at_the_key() @test
{
	AnimTemplate plain = wander_clip();
	defer plain.free(mem);
	AnimTemplate clip = wander_clip();
	defer clip.free(mem);
	test::@check(crig::set_tangent_mode(&clip, 1, "hip", true, FLAT) && crig::set_tangent_mode(&clip, 1, "hip", false, FLAT), "flat refused");
	test::@check(crig::effective_rotation_tangent(clip, 1, "hip", false).length_sq() == 0.0f
		&& crig::effective_translation_tangent(clip, 1, "hip", true).length_sq() == 0.0f, "flat reported a rate");
	float moving = (plain.translation_at("hip", 0.4f + STEP) - plain.translation_at("hip", 0.4f)).length();
	float held = (clip.translation_at("hip", 0.4f + STEP) - clip.translation_at("hip", 0.4f)).length();
	float held_in = (clip.translation_at("hip", 0.4f - STEP) - clip.translation_at("hip", 0.4f)).length();
	test::@check(held < moving / 20.0f && held_in < moving / 20.0f, "a flat key still moves: %f against %f", held, moving);
	float turning = turn_between(plain.rotation_at("hip", 0.4f + STEP), plain.rotation_at("hip", 0.4f));
	float stopped = turn_between(clip.rotation_at("hip", 0.4f + STEP), clip.rotation_at("hip", 0.4f));
	test::@check(stopped < turning / 20.0f, "a flat key still turns: %f against %f", stopped, turning);
	// A neighbouring key keeps its own curve.
	test::@check((plain.translation_at("hip", 0.0f) - clip.translation_at("hip", 0.0f)).length() < EPS, "flat moved another key");
}

fn void linear_tangents_head_for_the_neighbours() @test
{
	AnimTemplate clip = wander_clip();
	defer clip.free(mem);
	test::@check(crig::set_tangent_mode(&clip, 1, "hip", false, LINEAR) && crig::set_tangent_mode(&clip, 2, "hip", false, LINEAR), "linear refused");
	// Keys 1 and 2 both head straight at each other, so the segment between them is the straight line.
	for (int i = 1; i < 10; i++)
	{
		float u = (float)i / 10.0f;
		Vec3 a = clip.keyframes[1].offset_of("hip");
		Vec3 b = clip.keyframes[2].offset_of("hip");
		Vec3 line = a + (b - a) * u;
		test::@check((clip.translation_at("hip", 0.4f + 0.3f * u) - line).length() < 1.0e-5f, "the linear segment bends at %f", u);
	}
	Vec3 a = clip.keyframes[1].offset_of("hip");
	Vec3 b = clip.keyframes[2].offset_of("hip");
	test::@check((crig::effective_translation_tangent(clip, 1, "hip", false) - (b - a) / 0.3f).length() < 1.0e-4f, "linear reports the wrong rate");
	test::@check((crig::effective_translation_tangent(clip, 2, "hip", true) - (b - a) / 0.3f).length() < 1.0e-4f, "linear arrives at the wrong rate");
}

fn void a_held_or_linear_segment_ignores_tangents_and_an_ease_gives_way() @test
{
	AnimTemplate plain = wander_clip();
	defer plain.free(mem);
	AnimTemplate clip = wander_clip(LINEAR);
	defer clip.free(mem);
	AnimTemplate straight = wander_clip(LINEAR);
	defer straight.free(mem);
	// On a linear clip a mode is set without asking for a curve.
	test::@check(crig::set_tangent_mode(&clip, 1, "hip", false, FREE, curve: false), "free refused");
	test::@check(!clip.uses_tangents() && same_playback(clip, straight), "a linear segment read a tangent");
	// With `curve` the key goes on a curve.
	test::@check(crig::set_tangent_mode(&clip, 1, "hip", false, FREE) && clip.uses_tangents(), "the key did not take a curve");
	// A held segment stays held.
	AnimTemplate held = wander_clip();
	defer held.free(mem);
	held.keyframes[1].dots[0].translation_interpolation = HOLD;
	test::@check(crig::set_tangent_mode(&held, 1, "hip", false, FREE) && held.keyframes[1].dots[0].translation_interpolation == HOLD
		&& (held.translation_at("hip", 0.5f) - held.keyframes[1].offset_of("hip")).length() < EPS, "a held key was curved");

	// An ease on a segment with an explicit end is ignored: the tangent is the pacing.
	AnimTemplate eased = wander_clip();
	defer eased.free(mem);
	AnimTemplate bare = wander_clip();
	defer bare.free(mem);
	eased.keyframes[1].dots[0].translation_ease = { 1, 1 };
	eased.keyframes[1].dots[0].translation_tangents = { .mode = FLAT };
	bare.keyframes[1].dots[0].translation_tangents = { .mode = FLAT };
	test::@check(same_playback(eased, bare), "an ease paced a segment that has tangents");
	// An Auto key still honours its ease.
	AnimTemplate paced = wander_clip();
	defer paced.free(mem);
	paced.keyframes[1].dots[0].translation_ease = { 1, 1 };
	test::@check(!same_playback(paced, plain), "an ease stopped working on an Auto key");
}

fn void tangents_survive_the_session_and_a_pack() @test
{
	AnimTemplate clip = wander_clip();
	defer clip.free(mem);
	clip.keyframes[0].dots[0].rotation_tangents = { .mode = BROKEN, .incoming = { 0.5f, 0, 0 }, .outgoing = { 0, 1.5f, -0.25f } };
	clip.keyframes[1].dots[0].translation_tangents = { .mode = FREE, .incoming = { 0, 0.5f, 0 }, .outgoing = { 0, 1.0f, 0 } };
	clip.keyframes[2].dots[0].rotation_tangents = { .mode = FLAT };
	clip.keyframes[2].dots[0].translation_tangents = { .mode = LINEAR };
	AnimTemplate[1] source = { clip };

	RigDocument doc = {};
	defer doc.free();
	String text = crig::session_text(mem, &doc, "hero.glb", source[..]);
	defer text.free(mem);
	AnimTemplate[] back = crig::parse_session_clips(mem, text)!!;
	defer crig::free_animations(mem, back);
	test::@check(back.len == 1 && back[0].keyframes.len == 4, "the session lost keys");
	if (back.len == 1)
	{
		test::@check(tangents_kept(clip, back[0]), "the session changed a tangent");
		test::@check(same_playback(clip, back[0]), "the session plays the clip differently");
	}

	// A clip that never had tangents writes none.
	AnimTemplate bare = wander_clip();
	defer bare.free(mem);
	AnimTemplate[1] plain = { bare };
	String bare_text = crig::session_text(mem, &doc, "hero.glb", plain[..]);
	defer bare_text.free(mem);
	test::@check(!bare_text.contains("tangent"), "a clip without tangents wrote some");

	// Two joints, so the rig has a height for the slide to be a fraction of.
	Vec3[2] joints = { { 0, 0, 0 }, { 0, 1, 0 } };
	int[2] parents = { -1, 0 };
	rig::Skeleton skeleton = { .joints = joints[..], .parents = parents[..] };
	String[2] names = { "hip", "head" };
	String path = "build/tangents-pack.glb";
	defer (void)file::delete(path);
	crig::export_animations_glb(mem, path, &skeleton, names[..], source[..])!!;
	AnimPack pack = crig::read_pack(mem, path)!!;
	defer pack.free(mem);
	test::@check(pack.clips.len == 1, "the pack lost its clip");
	if (pack.clips.len != 1) return;
	test::@check(tangents_kept(clip, pack.clips[0]), "the pack changed a tangent");
	// Turns only: a pack hands slides back through the rig's own frame, which this
	// two-joint rig does not reproduce for any clip, tangents or not.
	test::@check(same_playback(clip, pack.clips[0], 2.0e-4f, slides: false), "the pack plays the turns differently");
}

fn bool tangents_kept(AnimTemplate want, AnimTemplate got)
{
	if (want.keyframes.len != got.keyframes.len) return false;
	foreach (usz k, frame : want.keyframes)
	{
		AnimKeyDot a = frame.dots[0];
		AnimKeyDot b = got.keyframes[k].dots[0];
		if (!a.rotation_tangents.same(b.rotation_tangents) || !a.translation_tangents.same(b.translation_tangents)) return false;
	}
	return true;
}

fn void a_baked_export_resamples_the_tangents() @test
{
	AnimTemplate clip = wander_clip();
	defer clip.free(mem);
	test::@check(crig::set_tangent_rate(&clip, 1, "hip", false, false, { 0, 4.0f, 0 }), "rate refused");
	// Export samples an eased or tangent clip densely so glTF's straight lines follow the curve.
	// Two joints, so the rig has a height for the slide to be a fraction of.
	Vec3[2] joints = { { 0, 0, 0 }, { 0, 1, 0 } };
	int[2] parents = { -1, 0 };
	rig::Skeleton skeleton = { .joints = joints[..], .parents = parents[..] };
	String[2] names = { "hip", "head" };
	AnimTemplate[1] source = { clip };
	String path = "build/tangents-baked.glb";
	defer (void)file::delete(path);
	crig::export_animations_glb(mem, path, &skeleton, names[..], source[..])!!;
	AnimPack pack = crig::read_pack(mem, path)!!;
	defer pack.free(mem);
	test::@check(pack.clips.len == 1 && pack.clips[0].keyframes.len >= 4, "the export lost keys");
}

fn void euler_rates_round_trip_and_follow_the_curve() @test
{
	Vec3[4] eulers = { { 10, 20, 30 }, { -40, 60, 170 }, { 0, 0, 0 }, { 120, -75, -33 } };
	Vec3[3] omegas = { { 1, 0, 0 }, { 0.3f, -2, 1.5f }, { -1, 1, 4 } };
	foreach (euler : eulers) foreach (omega : omegas)
	{
		Vec3 rates = crig::euler_rate_of_angular_rate(euler, omega);
		Vec3 back = crig::angular_rate_of_euler_rate(euler, rates);
		test::@check((back - omega).length() < 1.0e-4f, "angular rate %s came back as %s at %s", omega, back, euler);
	}
	// A rate of one Euler angle is the angular velocity of that angle alone, and
	// moving the angles at that rate turns the quaternion by that velocity.
	foreach (euler : eulers)
	{
		Vec3 degrees = { 25, -10, 40 };
		Vec3 omega = crig::angular_rate_of_euler_rate(euler, degrees);
		float dt = 1.0e-3f;
		Quaternionf here = crig::quat_of_euler(euler);
		Quaternionf there = crig::quat_of_euler(euler + degrees * dt);
		Quaternionf carry = there * here.conjugate();
		if (carry.v.w < 0.0f) carry = -carry;
		Vec3 measured = carry.v.xyz * (2.0f / dt);
		test::@check((measured - omega).length() < 0.02f * math::max(1.0f, omega.length()),
			"euler rates %s at %s are %s, not %s", degrees, euler, measured, omega);
	}
	// Next to gimbal lock the answer stays finite.
	Vec3 locked = crig::euler_rate_of_angular_rate({ 0, 90, 0 }, { 1, 1, 1 });
	test::@check(math::is_finite(locked.x) && math::is_finite(locked.y) && math::is_finite(locked.z), "gimbal lock gave a non-finite rate");
}
