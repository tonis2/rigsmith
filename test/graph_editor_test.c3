<*
 The Curves sheet's data: segment easing in the sampler and its persistence,
 the Euler display and the edits made through the graph.

     `c3c test --trust=full --test-noleak --test-filter crig_tests::graph_editor`
*>
module crig_tests::graph_editor;

import crig;
import rig;
import std::core::test;
import std::io::file;
import std::math;
import std::math::vector;
import std::math::quaternion;

const float EPS = 1.0e-5f;

fn AnimKeyDot hip_key(float angle, float slide, AnimChannels channels = BOTH)
{
	return {
		.joint_name = "hip".copy(mem),
		.axis = { 0, 0, 1 },
		.angle = angle,
		.move = { slide, 0, 0 },
		.channels = channels,
	};
}

// Three keys on "hip": a turn and a slide, 0 → 1 → 0.5 at 0, 0.5, 1.
fn AnimTemplate hip_clip(AnimInterpolation curve = LINEAR)
{
	AnimKeyframe[] keys = alloc::new_array(mem, AnimKeyframe, 3);
	float[3] angles = { 0.0f, 1.0f, 0.5f };
	foreach (usz i, &key : keys)
	{
		AnimKeyDot[] dots = alloc::new_array(mem, AnimKeyDot, 1);
		dots[0] = hip_key(angles[i], angles[i] * 0.1f);
		dots[0].rotation_interpolation = curve;
		dots[0].translation_interpolation = curve;
		*key = { .time = (float)i * 0.5f, .dots = dots };
	}
	AnimTemplate clip = { .name = "sway".copy(mem), .duration = 1.0f, .keyframes = keys, .owned = true };
	clip.compile_tracks(mem);
	return clip;
}

fn bool near(float a, float b, float within = EPS) => math::abs(a - b) <= within;

fn void an_ease_remaps_the_fraction_monotonically() @test
{
	AnimEase none = {};
	for (int i = 0; i <= 20; i++)
	{
		float t = (float)i / 20.0f;
		test::@check(none.remap(t) == t, "no ease changed the fraction at %f", t);
	}
	AnimEase[3] eases = { { 1, 0 }, { 0, 1 }, { 1, 1 } };
	foreach (ease : eases)
	{
		test::@check(ease.remap(0) == 0.0f && near(ease.remap(1), 1.0f), "an ease moved the ends");
		float last = 0;
		for (int i = 1; i <= 100; i++)
		{
			float f = ease.remap((float)i / 100.0f);
			test::@check(f >= last, "an ease ran backwards");
			last = f;
		}
	}
	// Ease in starts flat and slow, ease out arrives flat, in-out is symmetric.
	test::@check(eases[0].remap(0.01f) < 0.001f && eases[0].remap(0.25f) < 0.25f, "ease in did not start slow");
	test::@check(near(eases[1].remap(0.99f), 1.0f, 0.001f) && eases[1].remap(0.75f) > 0.75f, "ease out did not arrive slow");
	test::@check(near(eases[2].remap(0.5f), 0.5f), "ease in-out is not symmetric");
	AnimEase odd = { 7.0f, -2.0f };
	test::@check(odd.clamped().start == 1.0f && odd.clamped().end == 0.0f, "an ease was not clamped");
}

fn void the_sampler_paces_a_segment_by_its_ease() @test
{
	AnimTemplate plain = hip_clip();
	defer plain.free(mem);
	AnimTemplate eased = hip_clip();
	defer eased.free(mem);
	eased.keyframes[0].dots[0].rotation_ease = { 1, 0 };
	eased.keyframes[0].dots[0].translation_ease = { 0, 1 };
	test::@check(eased.uses_easing() && !plain.uses_easing(), "uses_easing is wrong");

	Quaternionf q1 = quaternion::from_axis_angle{float}({ 0, 0, 1 }, 0.0f);
	Quaternionf q2 = quaternion::from_axis_angle{float}({ 0, 0, 1 }, 1.0f);
	for (int i = 0; i <= 10; i++)
	{
		float t = (float)i / 20.0f;
		float blend = t / 0.5f;
		Quaternionf expect = q1.slerp(q2, eased.keyframes[0].dots[0].rotation_ease.remap(blend)).normalize();
		Quaternionf got = eased.rotation_at("hip", t);
		test::@check(1.0f - math::abs(got.v.dot(expect.v)) < 1.0e-6f, "eased turn at %f", t);
		Vec3 slide = eased.translation_at("hip", t);
		test::@check(near(slide.x, 0.1f * (AnimEase){ 0, 1 }.remap(blend)), "eased slide at %f", t);
		// The same clip read without its ease is the plain one.
		Quaternionf natural = eased.rotation_at("hip", t, eased: false);
		test::@check(natural.v == plain.rotation_at("hip", t).v, "reading without ease was not plain");
	}
	// The second segment carries no ease and is untouched.
	test::@check(eased.rotation_at("hip", 0.8f).v == plain.rotation_at("hip", 0.8f).v,
		"an unset ease changed the next segment");

	// A held segment ignores its ease.
	AnimTemplate held = hip_clip(HOLD);
	defer held.free(mem);
	held.keyframes[0].dots[0].rotation_ease = { 1, 1 };
	test::@check(!held.uses_easing() && held.rotation_at("hip", 0.3f).v == held.keyframes[0].rotation_of("hip").v,
		"a held segment used its ease");

	// Smooth: the ease flattens the start.
	AnimTemplate smooth = hip_clip(AUTO);
	defer smooth.free(mem);
	smooth.keyframes[0].dots[0].translation_ease = { 1, 0 };
	float early = smooth.translation_at("hip", 0.005f).x;
	float plain_early = smooth.translation_at("hip", 0.005f, eased: false).x;
	test::@check(math::abs(early) < math::abs(plain_early) * 0.1f, "a smooth segment did not ease in");
	test::@check(near(smooth.translation_at("hip", 0.5f).x, 0.1f), "the eased segment missed its key");
}

fn void euler_degrees_round_trip() @test
{
	Vec3[5] cases = { { 10, 20, 30 }, { -45, 5, 170 }, { 0, 0, 0 }, { 120, -60, -10 }, { 0, 90, 30 } };
	foreach (e : cases)
	{
		Quaternionf q = crig::quat_of_euler(e);
		Vec3 back = crig::euler_of(q, e);
		Quaternionf again = crig::quat_of_euler(back);
		test::@check(1.0f - math::abs(q.v.dot(again.v)) < 1.0e-6f, "euler did not round-trip the turn");
		if (math::abs(e.y) < 89.0f)
		{
			test::@check((back - e).length() < 1.0e-2f, "euler came back as another solution (%s)", back);
		}
	}
	// Single axes read as themselves.
	Vec3 x = crig::euler_of(quaternion::from_axis_angle{float}({ 1, 0, 0 }, 0.5f), {});
	test::@check(near(x.x, 0.5f * 180.0f / (float)math::PI, 1.0e-3f) && near(x.y, 0, 1.0e-3f) && near(x.z, 0, 1.0e-3f),
		"a turn about X read as %s", x);
	// Unwrapped toward a nearby value past ±180.
	Vec3 wrapped = crig::euler_of(crig::quat_of_euler({ 0, 0, 190 }), { 0, 0, 185 });
	test::@check(near(wrapped.z, 190.0f, 1.0e-2f), "a turn past 180 did not unwrap: %s", wrapped);
}

fn void an_ease_round_trips_through_the_sidecar_and_a_pack() @test
{
	AnimTemplate clip = hip_clip();
	defer clip.free(mem);
	clip.keyframes[0].dots[0].rotation_ease = { 1, 0.25f };
	clip.keyframes[1].dots[0].translation_ease = { 0, 1 };
	AnimTemplate[1] source = { clip };

	RigDocument doc = {};
	defer doc.free();
	String text = crig::session_text(mem, &doc, "hero.glb", source[..]);
	defer text.free(mem);
	AnimTemplate[] back = crig::parse_session_clips(mem, text)!!;
	defer crig::free_animations(mem, back);
	test::@check(back.len == 1 && back[0].keyframes.len == 3, "the session lost keys");
	test::@check(back[0].keyframes[0].dots[0].rotation_ease.same({ 1, 0.25f })
		&& back[0].keyframes[0].dots[0].translation_ease.none()
		&& back[0].keyframes[1].dots[0].translation_ease.same({ 0, 1 })
		&& back[0].keyframes[2].dots[0].rotation_ease.none(), "the sidecar changed an ease");

	// No ease writes nothing new.
	AnimTemplate bare = hip_clip();
	defer bare.free(mem);
	AnimTemplate[1] plain = { bare };
	String bare_text = crig::session_text(mem, &doc, "hero.glb", plain[..]);
	defer bare_text.free(mem);
	test::@check(!bare_text.contains("_ease"), "a clip without easing wrote an ease");

	// A pack keeps it in its sparse schedule.
	Vec3[1] joints = { { 0, 1, 0 } };
	int[1] parents = { -1 };
	rig::Skeleton skeleton = { .joints = joints[..], .parents = parents[..] };
	String[1] names = { "hip" };
	String path = "build/graph-ease-pack.glb";
	defer (void)file::delete(path);
	crig::export_animations_glb(mem, path, &skeleton, names[..], source[..])!!;
	AnimPack pack = crig::read_pack(mem, path)!!;
	defer pack.free(mem);
	test::@check(pack.clips.len == 1, "the pack lost its clip");
	if (pack.clips.len != 1) return;
	AnimTemplate read = pack.clips[0];
	test::@check(read.keyframes.len == 3
		&& read.keyframes[0].dots[0].rotation_ease.same({ 1, 0.25f })
		&& read.keyframes[1].dots[0].translation_ease.same({ 0, 1 }), "the pack changed an ease");
	for (int i = 0; i <= 10; i++)
	{
		float t = (float)i / 10.0f;
		test::@check(1.0f - math::abs(read.rotation_at("hip", t).v.dot(clip.rotation_at("hip", t).v)) < 1.0e-6f,
			"the pack plays the eased turn differently at %f", t);
	}
}

struct GraphFixture
{
	AppState app;
	uint hip;
	AnimRef ref;
}

fn void GraphFixture.open(&self, AnimInterpolation curve = LINEAR)
{
	self.app = crig::new_app({});
	self.hip = self.app.doc.add_dot({ 0, 1, 0 }, "hip");
	self.app.doc.root_id = self.hip;
	self.ref = self.app.put_authored_clip(hip_clip(curve));
	(void)self.app.bind_ref(self.ref);
	self.app.undo_stack.commit();
	self.app.undo_stack.clear();
	self.app.editing = self.ref;
	self.app.select(self.hip);
}

fn void GraphFixture.close(&self) => self.app.free();

fn void the_graph_draws_the_selected_joints_channels() @test
{
	GraphFixture f;
	f.open();
	defer f.close();

	Graph rotation = f.app.build_graph(f.app.editing, false);
	defer rotation.free();
	test::@check(rotation.curves.len == 3 && rotation.keys.len == 9, "rotation curves %d keys %d",
		rotation.curves.len, rotation.keys.len);
	if (rotation.curves.len != 3) return;
	test::@check(rotation.curves[2].axis == 2 && rotation.curves[2].primary && rotation.curves[0].joint == "hip",
		"the curves are not the hip's X/Y/Z");
	// The turn is about Z: the Z curve carries it in degrees, X and Y stay flat.
	float deg = 180.0f / (float)math::PI;
	test::@check(near(rotation.keys[5].value, 1.0f * deg, 1.0e-2f) && near(rotation.keys[3].value, 0, 1.0e-3f),
		"the middle key reads %f", rotation.keys[5].value);
	test::@check(rotation.handles.len == 0, "handles were drawn for unselected keys");

	Graph position = f.app.build_graph(f.app.editing, true);
	defer position.free();
	test::@check(position.curves.len == 3 && position.unit > 0, "no position curves");
	if (position.curves.len != 3) return;
	test::@check(near(position.keys[3].value, 0.1f * position.unit, 1.0e-4f), "the slide key reads %f",
		position.keys[3].value);

	// Nothing selected, nothing drawn.
	f.app.select(0);
	Graph empty = f.app.build_graph(f.app.editing, false);
	defer empty.free();
	test::@check(empty.curves.len == 0, "curves drawn with no joint selected");
}

fn void dragging_a_key_value_is_one_undo_step() @test
{
	GraphFixture f;
	f.open();
	defer f.close();

	Graph graph = f.app.build_graph(f.app.editing, false);
	defer graph.free();
	GraphKey key = graph.keys[5]; // the middle key's Z
	sz history = f.app.undo_stack.cursor;
	test::@check(f.app.set_graph_key_value(f.app.editing, "hip", true, key.time, key.shown, 2, 30.0f),
		"the key value edit was refused");
	test::@check(f.app.undo_stack.cursor == history + 1, "a value edit was not one step");
	AnimTemplate* clip = f.app.clip(f.app.editing);
	Vec3 now = crig::euler_of(clip.keyframes[1].rotation_of("hip"), {});
	test::@check(near(now.z, 30.0f, 1.0e-2f) && near(now.x, 0, 1.0e-2f), "the key now reads %s", now);
	test::@check(near(clip.keyframes[1].offset_of("hip").x, 0.1f), "the value edit moved the slide");

	// Position in model units, and back.
	Graph position = f.app.build_graph(f.app.editing, true);
	defer position.free();
	GraphKey slide = position.keys[3];
	test::@check(f.app.set_graph_key_value(f.app.editing, "hip", false, slide.time, slide.shown, 1,
		0.5f * position.unit, position.unit), "the slide edit was refused");
	test::@check(near(f.app.clip(f.app.editing).keyframes[1].offset_of("hip").y, 0.5f),
		"the slide landed at %f", f.app.clip(f.app.editing).keyframes[1].offset_of("hip").y);

	test::@check(f.app.undo() && f.app.undo(), "the edits did not undo");
	AnimTemplate* back = f.app.clip(f.app.editing);
	test::@check(near(back.keyframes[1].dots[0].angle, 1.0f) && near(back.keyframes[1].offset_of("hip").y, 0),
		"undo did not restore the key");
}

fn void presets_and_handles_set_the_ease() @test
{
	GraphFixture f;
	f.open();
	defer f.close();

	test::@check(f.app.select_animation_channel_key(f.app.editing, 0.0f, "hip", ROTATION), "no key to select");
	sz history = f.app.undo_stack.cursor;
	test::@check(f.app.set_selected_animation_ease(f.app.editing, { 1, 1 }), "the preset was refused");
	test::@check(f.app.undo_stack.cursor == history + 1, "a preset was not one step");
	test::@check(f.app.animation_selection_uses_ease(f.app.editing, { 1, 1 }), "the selection does not read its ease");
	AnimKeyDot dot = f.app.clip(f.app.editing).keyframes[0].dots[0];
	test::@check(dot.rotation_ease.same({ 1, 1 }) && dot.translation_ease.none(),
		"the preset reached the wrong channel");

	// The selected key shows its outgoing handle, flat for a full ease.
	Graph graph = f.app.build_graph(f.app.editing, false);
	defer graph.free();
	test::@check(graph.handles.len == 1, "%d handles on one selected key", graph.handles.len);
	if (graph.handles.len != 1) return;
	GraphHandle handle = graph.handles[0];
	GraphKey key = graph.keys[handle.key];
	test::@check(handle.start && near(handle.at.x, 0.5f / 3.0f) && near(handle.at.y, key.value, 1.0e-3f),
		"a fully eased handle is not flat at a third: %s", handle.at);
	// Dragging it back onto the tangent removes the ease; halfway is half.
	test::@check(near(handle.ease_for(key.value, key.value + handle.natural), 0.0f)
		&& near(handle.ease_for(key.value, key.value + handle.natural * 0.5f), 0.5f), "ease_for is not the inverse");
	history = f.app.undo_stack.cursor;
	test::@check(f.app.set_graph_ease(f.app.editing, "hip", true, handle.owner, true, 0.5f), "handle ease refused");
	test::@check(f.app.undo_stack.cursor == history + 1, "a handle drag was not one step");
	test::@check(f.app.clip(f.app.editing).keyframes[0].dots[0].rotation_ease.same({ 0.5f, 1 }),
		"the handle set the wrong end");
	test::@check(f.app.animation_channel_key_selected(f.app.editing, 0.0f, "hip", ROTATION),
		"an ease edit dropped the key selection");
}
