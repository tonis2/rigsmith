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
		test::@check(ease.remap(0) == 0.0f && math::is_approx(ease.remap(1), 1.0f, EPS), "an ease moved the ends");
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
	test::@check(math::is_approx(eases[1].remap(0.99f), 1.0f, 0.001f) && eases[1].remap(0.75f) > 0.75f, "ease out did not arrive slow");
	test::@check(math::is_approx(eases[2].remap(0.5f), 0.5f, EPS), "ease in-out is not symmetric");
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
		test::@check(math::is_approx(slide.x, 0.1f * (AnimEase){ 0, 1 }.remap(blend), EPS), "eased slide at %f", t);
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
	test::@check(math::is_approx(smooth.translation_at("hip", 0.5f).x, 0.1f, EPS), "the eased segment missed its key");
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
	test::@check(math::is_approx(x.x, 0.5f * 180.0f / (float)math::PI, 1.0e-3f) && math::is_approx(x.y, 0, 1.0e-3f) && math::is_approx(x.z, 0, 1.0e-3f),
		"a turn about X read as %s", x);
	// Unwrapped toward a nearby value past ±180.
	Vec3 wrapped = crig::euler_of(crig::quat_of_euler({ 0, 0, 190 }), { 0, 0, 185 });
	test::@check(math::is_approx(wrapped.z, 190.0f, 1.0e-2f), "a turn past 180 did not unwrap: %s", wrapped);
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

	// Rotation and position are both drawn: three curves and nine keys of each.
	Graph rotation = f.app.build_graph(f.app.editing);
	defer rotation.free();
	test::@check(rotation.curves.len == 6 && rotation.keys.len == 18 && rotation.channels.len == 2,
		"curves %d keys %d channels %d", rotation.curves.len, rotation.keys.len, rotation.channels.len);
	if (rotation.curves.len != 6) return;
	test::@check(rotation.mixed && rotation.curves[3].half > 0.0f, "two kinds were not normalised");
	test::@check(rotation.curves[2].axis == 2 && rotation.curves[2].primary && rotation.curves[0].joint == "hip",
		"the curves are not the hip's X/Y/Z");
	// The turn is about Z: the Z curve carries it in degrees, X and Y stay flat.
	float deg = 180.0f / (float)math::PI;
	test::@check(math::is_approx(rotation.keys[5].value, 1.0f * deg, 1.0e-2f) && math::is_approx(rotation.keys[3].value, 0, 1.0e-3f),
		"the middle key reads %f", rotation.keys[5].value);
	test::@check(rotation.handles.len == 0, "handles were drawn for unselected keys");

	Graph position = rotation;
	test::@check(!position.curves[3].rotation && position.unit > 0, "no position curves");
	test::@check(math::is_approx(position.keys[12].value, 0.1f * position.unit, 1.0e-4f), "the slide key reads %f",
		position.keys[12].value);
	// A mixed curve reads -1..1 and converts back to its real value.
	GraphCurve slide = position.curves[3];
	test::@check(math::is_approx(slide.real(slide.shown(0.7f)), 0.7f, 1.0e-6f)
		&& math::is_approx(slide.shown(slide.mid + slide.half), 1.0f, EPS), "the normalised range is not -1..1");

	// Nothing selected, nothing drawn.
	f.app.select(0);
	Graph empty = f.app.build_graph(f.app.editing);
	defer empty.free();
	test::@check(empty.curves.len == 0, "curves drawn with no joint selected");
}

<*
 A hidden curve is left out of the graph, keys and handles with it; solo, add
 and toggle work on joint, channel and axis groups, and the hiding outlasts the
 joint's selection. One kind drawn alone keeps its real units.
*>
fn void hidden_curves_leave_the_graph() @test
{
	GraphFixture f;
	f.open();
	defer f.close();

	f.app.set_graph_hidden(f.hip, true, 0, true); // hip rotation X
	Graph graph = f.app.build_graph(f.app.editing);
	test::@check(graph.curves.len == 5 && graph.keys.len == 15 && graph.channels.len == 2,
		"%d curves %d keys %d channels", graph.curves.len, graph.keys.len, graph.channels.len);
	foreach (curve : graph.curves) test::@check(!(curve.rotation && curve.axis == 0), "the hidden X is drawn");
	foreach (key : graph.keys) test::@check(key.curve < graph.curves.len, "a key points past the curves");
	graph.free();

	// The hiding is by joint, so it survives the joint being deselected.
	f.app.select(0);
	f.app.select(f.hip);
	graph = f.app.build_graph(f.app.editing);
	test::@check(graph.curves.len == 5, "reselecting the joint showed its hidden curve");
	graph.free();
	GraphChannel[2] list = { { .id = f.hip, .rotation = true }, { .id = f.hip } };
	GraphChannel[] channels = list[..];

	// Solo a kind: the other is gone, and the one left reads its real units.
	f.app.pick_graph_curves(channels, { .joint = f.hip, .kind = 1, .axis = -1 }, SOLO);
	graph = f.app.build_graph(f.app.editing);
	test::@check(graph.curves.len == 3 && !graph.curves[0].rotation && !graph.mixed && graph.curves[0].half == 0.0f,
		"soloing Position left %d curves, mixed %s", graph.curves.len, graph.mixed);
	test::@check(math::is_approx(graph.keys[1].value, 0.1f * graph.unit, 1.0e-4f), "an unmixed curve is not in real units");
	graph.free();

	// Add one rotation axis back, then toggle it off again.
	f.app.pick_graph_curves(channels, { .joint = f.hip, .kind = 0, .axis = 2 }, ADD);
	graph = f.app.build_graph(f.app.editing);
	test::@check(graph.curves.len == 4 && graph.mixed, "adding Z gave %d curves", graph.curves.len);
	graph.free();
	GraphPick z = { .joint = f.hip, .kind = 0, .axis = 2 };
	test::@check(f.app.graph_pick_drawn(channels, z, true), "Z is not drawn");
	f.app.pick_graph_curves(channels, z, TOGGLE);
	test::@check(!f.app.graph_pick_drawn(channels, z, false), "the toggle did not hide Z");
	f.app.pick_graph_curves(channels, z, TOGGLE);
	test::@check(f.app.graph_pick_drawn(channels, z, true), "the toggle did not show Z");

	// A hidden curve has no keys and no handles to drag; all back again.
	f.app.show_all_graph_curves();
	graph = f.app.build_graph(f.app.editing);
	defer graph.free();
	test::@check(graph.curves.len == 6 && f.app.graph_pick_drawn(channels, { .kind = -1, .axis = -1 }, true),
		"show all left %d curves", graph.curves.len);
}

fn void dragging_a_key_value_is_one_undo_step() @test
{
	GraphFixture f;
	f.open();
	defer f.close();

	Graph graph = f.app.build_graph(f.app.editing);
	defer graph.free();
	GraphKey key = graph.keys[5]; // the middle key's Z
	sz history = f.app.undo_stack.cursor;
	test::@check(f.app.set_graph_key_value(f.app.editing, "hip", true, key.time, key.shown, 2, 30.0f),
		"the key value edit was refused");
	test::@check(f.app.undo_stack.cursor == history + 1, "a value edit was not one step");
	AnimTemplate* clip = f.app.clip(f.app.editing);
	Vec3 now = crig::euler_of(clip.keyframes[1].rotation_of("hip"), {});
	test::@check(math::is_approx(now.z, 30.0f, 1.0e-2f) && math::is_approx(now.x, 0, 1.0e-2f), "the key now reads %s", now);
	test::@check(math::is_approx(clip.keyframes[1].offset_of("hip").x, 0.1f, EPS), "the value edit moved the slide");

	// Position in model units, and back.
	Graph position = f.app.build_graph(f.app.editing);
	defer position.free();
	GraphKey slide = position.keys[12];
	test::@check(f.app.set_graph_key_value(f.app.editing, "hip", false, slide.time, slide.shown, 1,
		0.5f * position.unit, position.unit), "the slide edit was refused");
	test::@check(math::is_approx(f.app.clip(f.app.editing).keyframes[1].offset_of("hip").y, 0.5f, EPS),
		"the slide landed at %f", f.app.clip(f.app.editing).keyframes[1].offset_of("hip").y);

	test::@check(f.app.undo() && f.app.undo(), "the edits did not undo");
	AnimTemplate* back = f.app.clip(f.app.editing);
	test::@check(math::is_approx(back.keyframes[1].dots[0].angle, 1.0f, EPS) && math::is_approx(back.keyframes[1].offset_of("hip").y, 0, EPS),
		"undo did not restore the key");
}

fn void presets_set_the_ease_on_the_selected_channel() @test
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
	test::@check(f.app.animation_channel_key_selected(f.app.editing, 0.0f, "hip", ROTATION),
		"an ease edit dropped the key selection");
}

// The Euler rates of the key at `time` in degrees per second, as the sampler plays them.
fn Vec3 played_rate(AnimTemplate* clip, float time) @local
{
	float h = 1.0e-3f;
	Vec3 near = crig::euler_of(clip.rotation_at("hip", time), {});
	Vec3 before = crig::euler_of(clip.rotation_at("hip", time - h), near);
	Vec3 after = crig::euler_of(clip.rotation_at("hip", time + h), near);
	return (after - before) * (1.0f / (2.0f * h));
}

<*
 A selected key shows an incoming and an outgoing handle on every drawn axis, a
 third of its segment from the key and on the slope the curve really has there
 (checked against the sampler), in real units even when the graph is normalised.
 The ends have one, and a held or linear segment none.
*>
fn void tangent_handles_sit_on_the_curves_own_slope() @test
{
	GraphFixture f;
	f.open(AUTO);
	defer f.close();

	select_hip_keys(&f, { 0.5f });
	Graph graph = f.app.build_graph(f.app.editing);
	defer graph.free();
	test::@check(graph.mixed, "the graph is not normalised");
	// Three rotation axes, two sides: the position channel's key is not selected.
	test::@check(graph.handles.len == 6, "%d handles", graph.handles.len);
	if (graph.handles.len != 6) return;
	AnimTemplate* clip = f.app.clip(f.app.editing);
	Vec3 slope = played_rate(clip, 0.5f);
	foreach (handle : graph.handles)
	{
		GraphKey key = graph.keys[handle.key];
		GraphCurve curve = graph.curves[key.curve];
		float run = handle.incoming ? -0.5f / 3.0f : 0.5f / 3.0f;
		test::@check(curve.rotation && math::is_approx(key.time, 0.5f, EPS) && math::is_approx(handle.length, 0.5f / 3.0f, EPS), "the handle is not at the key");
		test::@check(math::is_approx(handle.at.x, 0.5f + run, EPS), "the handle is at %f, not a third out", handle.at.x);
		test::@check(math::is_approx(handle.at.y, key.value + slope[curve.axis] * run, 0.05f),
			"axis %d handle is at %f, the curve's slope puts it at %f", curve.axis, handle.at.y, key.value + slope[curve.axis] * run);
		// Normalised, the plot sees the same point through the curve's own range.
		test::@check(math::is_approx(curve.real(curve.shown(handle.at.y)), handle.at.y, 1.0e-3f), "the handle did not round-trip");
	}

	// The ends: the first key has only its outgoing handle, the last only its incoming one.
	select_hip_keys(&f, { 0.0f, 1.0f });
	Graph ends = f.app.build_graph(f.app.editing);
	defer ends.free();
	test::@check(ends.handles.len == 6, "%d handles on the two ends", ends.handles.len);
	foreach (handle : ends.handles) test::@check(handle.incoming == (ends.keys[handle.key].time > 0.9f), "an end key shows its far side");

	// A position key: the handle is in model units, the effective rate times the rig's unit.
	f.app.restart_key_selection(f.app.editing);
	f.app.select_channel(0.5f, "hip", TRANSLATION);
	Graph moves = f.app.build_graph(f.app.editing);
	defer moves.free();
	test::@check(moves.handles.len == 6, "%d position handles", moves.handles.len);
	Vec3 tangent = crig::effective_translation_tangent(*clip, 1, "hip", false) * moves.unit;
	foreach (handle : moves.handles)
	{
		GraphKey key = moves.keys[handle.key];
		GraphCurve curve = moves.curves[key.curve];
		float run = handle.incoming ? -0.5f / 3.0f : 0.5f / 3.0f;
		test::@check(!curve.rotation && math::is_approx(handle.at.y, key.value + tangent[curve.axis] * run, 1.0e-4f),
			"a position handle is at %f", handle.at.y);
	}

	// Held and linear segments draw none.
	AnimInterpolation[2] flat = { HOLD, LINEAR };
	foreach (kind : flat)
	{
		GraphFixture g;
		g.open(kind);
		defer g.close();
		select_hip_keys(&g, { 0.5f });
		Graph bare = g.app.build_graph(g.app.editing);
		defer bare.free();
		test::@check(bare.handles.len == 0, "a %s segment drew %d handles", kind.serialized(), bare.handles.len);
	}
}

<*
 A handle dragged on an Auto key frees it: the dragged side takes the slope, the
 other side turns to follow, and the curve between the keys follows the handle.
 With Alt the key is broken and the other side stays put. One undo step each,
 selection kept; and switching a key to Free by itself changes nothing played.
*>
fn void dragging_a_tangent_handle_frees_or_breaks_the_key() @test
{
	GraphFixture f;
	f.open(AUTO);
	defer f.close();
	select_hip_keys(&f, { 0.5f });
	Graph graph = f.app.build_graph(f.app.editing);
	defer graph.free();
	GraphKey key;
	foreach (handle : graph.handles)
	{
		if (graph.keys[handle.key].time == 0.5f && graph.curves[graph.keys[handle.key].curve].axis == 2) key = graph.keys[handle.key];
	}
	AnimTemplate* clip = f.app.clip(f.app.editing);
	Vec3 before_in = crig::effective_rotation_tangent(*clip, 1, "hip", true);
	Vec3 before_out = crig::effective_rotation_tangent(*clip, 1, "hip", false);
	float mid_before = crig::euler_of(clip.rotation_at("hip", 0.75f), {}).z;
	Vec3 slope = played_rate(clip, 0.5f);

	// Steeper going out: an Auto key becomes Free, the incoming side follows, the middle of the segment rises.
	sz history = f.app.undo_stack.cursor;
	test::@check(f.app.set_graph_tangent(f.app.editing, "hip", true, key.time, key.shown, 2, false, slope.z + 60.0f),
		"the handle drag was refused");
	test::@check(f.app.undo_stack.cursor == history + 1, "a handle drag was not one step");
	clip = f.app.clip(f.app.editing);
	AnimTangents own = clip.keyframes[1].dots[0].rotation_tangents;
	test::@check(own.mode == FREE, "the key is %s, not free", own.mode);
	test::@check(math::is_approx(crig::euler_rate_of_angular_rate(key.shown, own.outgoing).z, slope.z + 60.0f, 0.05f),
		"the outgoing slope is %f", crig::euler_rate_of_angular_rate(key.shown, own.outgoing).z);
	test::@check(own.incoming.length() > 0 && own.incoming.normalize().dot(own.outgoing.normalize()) > 0.9999f
		&& math::is_approx(own.incoming.length(), before_in.length(), 1.0e-4f), "the incoming side did not follow");
	test::@check(crig::euler_of(clip.rotation_at("hip", 0.75f), {}).z > mid_before + 0.5f, "the segment did not rise");
	test::@check(f.app.animation_channel_key_selected(f.app.editing, 0.5f, "hip", ROTATION), "the drag dropped the selection");

	// Alt: broken, the incoming side exactly where it was.
	Vec3 held_in = own.incoming;
	history = f.app.undo_stack.cursor;
	test::@check(f.app.set_graph_tangent(f.app.editing, "hip", true, key.time, key.shown, 2, false, slope.z - 20.0f, 1.0f, true),
		"the broken drag was refused");
	test::@check(f.app.undo_stack.cursor == history + 1, "a broken drag was not one step");
	own = f.app.clip(f.app.editing).keyframes[1].dots[0].rotation_tangents;
	test::@check(own.mode == BROKEN && (own.incoming - held_in).length() < 1.0e-6f, "the incoming side moved");
	test::@check(math::is_approx(crig::euler_rate_of_angular_rate(key.shown, own.outgoing).z, slope.z - 20.0f, 0.05f), "the outgoing slope is wrong");

	// A fresh Auto key broken straight away leaves the other side on what it played.
	test::@check(f.app.undo() && f.app.undo(), "the drags did not undo");
	test::@check(f.app.set_graph_tangent(f.app.editing, "hip", true, key.time, key.shown, 2, true, slope.z + 30.0f, 1.0f, true),
		"an Alt drag on an Auto key was refused");
	clip = f.app.clip(f.app.editing);
	own = clip.keyframes[1].dots[0].rotation_tangents;
	test::@check(own.mode == BROKEN && (own.outgoing - before_out).length() < 1.0e-4f, "the outgoing side moved");
	test::@check(math::is_approx(crig::euler_rate_of_angular_rate(key.shown, own.incoming).z, slope.z + 30.0f, 0.05f), "the incoming slope is wrong");
}

// The drawn key of the hip's rotation or position `axis` at `time`.
fn GraphKey drawn_key(Graph* graph, bool rotation, int axis, float time)
{
	foreach (key : graph.keys)
	{
		GraphCurve curve = graph.curves[key.curve];
		if (curve.rotation == rotation && curve.axis == axis && math::abs(key.time - time) < EPS) return key;
	}
	return {};
}

<*
 A handle dragged far too steep is held where neither segment at the key strays
 past a quarter turn, as close to that as it gets, and says it was held. A sane
 slope is not held.
*>
fn void a_handle_drag_cannot_spin_its_segment() @test
{
	GraphFixture f;
	f.open(AUTO);
	defer f.close();
	select_hip_keys(&f, { 0.5f });
	Graph graph = f.app.build_graph(f.app.editing);
	defer graph.free();
	GraphKey key = drawn_key(&graph, true, 0, 0.5f);

	bool held;
	test::@check(f.app.set_graph_tangent(f.app.editing, "hip", true, key.time, key.shown, 0, false, 200000.0f, 1.0f, false, &held),
		"the steep drag was refused");
	test::@check(held, "a slope of 200000 degrees per second was not held");
	AnimTemplate* clip = f.app.clip(f.app.editing);
	float leaving = crig::segment_swing(clip, "hip", true, 0.5f, 1.0f);
	float arriving = crig::segment_swing(clip, "hip", true, 0.0f, 0.5f);
	test::@check(leaving <= crig::TURN_SWING_LIMIT + 1.0e-3f && arriving <= crig::TURN_SWING_LIMIT + 1.0e-3f,
		"the segments swing %f and %f", leaving, arriving);
	test::@check(leaving > 0.5f, "held further than it had to be: the segment swings %f", leaving);

	test::@check(f.app.undo(), "the drag did not undo");
	test::@check(f.app.set_graph_tangent(f.app.editing, "hip", true, key.time, key.shown, 0, false, 30.0f, 1.0f, false, &held)
		&& !held, "a gentle slope was held");
}

<*
 A rotation curve grabbed between keys bends through the pointer on the axis
 grabbed, off the turn's plane (X) and along it (Z): the two keys turn Free, the
 keys keep their values, and one undo puts it back.
*>
fn void bending_a_rotation_segment_puts_the_curve_under_the_pointer() @test
{
	GraphFixture f;
	f.open(AUTO);
	defer f.close();
	Graph graph = f.app.build_graph(f.app.editing);
	defer graph.free();
	float unit = graph.unit;
	int[2] axes = { 0, 2 };
	foreach (axis : axes)
	{
		GraphKey from = drawn_key(&graph, true, axis, 0.5f);
		GraphKey to = drawn_key(&graph, true, axis, 1.0f);
		Vec3 near = (from.shown + to.shown) * 0.5f;
		float now = crig::graph_value(f.app.clip(f.app.editing), "hip", true, 0.75f, near, unit)[axis];
		float want = now + 20.0f;
		sz history = f.app.undo_stack.cursor;
		bool held;
		test::@check(f.app.bend_graph_segment(f.app.editing, "hip", true, axis, 0.75f, want, from.shown, to.shown, unit, false, &held),
			"the bend on axis %d was refused", axis);
		test::@check(f.app.undo_stack.cursor == history + 1 && !held, "the bend was %d steps, held %s",
			f.app.undo_stack.cursor - history, held);
		AnimTemplate* clip = f.app.clip(f.app.editing);
		near[axis] = want;
		float got = crig::graph_value(clip, "hip", true, 0.75f, near, unit)[axis];
		test::@check(math::abs(got - want) < 0.5f, "axis %d bent to %f, wanted %f", axis, got, want);
		test::@check(clip.keyframes[1].dots[0].rotation_tangents.mode == FREE && clip.keyframes[2].dots[0].rotation_tangents.mode == FREE,
			"the keys either side are not Free");
		test::@check(math::is_approx(clip.keyframes[1].dots[0].angle, 1.0f, EPS) && math::is_approx(clip.keyframes[2].dots[0].angle, 0.5f, EPS),
			"a key's value moved");
		test::@check(f.app.undo(), "the bend did not undo");
		float back = crig::graph_value(f.app.clip(f.app.editing), "hip", true, 0.75f, near, unit)[axis];
		test::@check(math::abs(back - now) < 1.0e-3f, "undo left the curve at %f, not %f", back, now);
	}
}

fn void bending_a_position_segment_is_exact() @test
{
	GraphFixture f;
	f.open(AUTO);
	defer f.close();
	Graph graph = f.app.build_graph(f.app.editing);
	defer graph.free();
	float unit = graph.unit;
	GraphKey from = drawn_key(&graph, false, 0, 0.0f);
	GraphKey to = drawn_key(&graph, false, 0, 0.5f);
	float now = crig::graph_value(f.app.clip(f.app.editing), "hip", false, 0.2f, {}, unit).x;
	float want = now + 0.05f * unit;
	test::@check(f.app.bend_graph_segment(f.app.editing, "hip", false, 0, 0.2f, want, from.shown, to.shown, unit),
		"the position bend was refused");
	AnimTemplate* clip = f.app.clip(f.app.editing);
	float got = crig::graph_value(clip, "hip", false, 0.2f, {}, unit).x;
	test::@check(math::abs(got - want) < 1.0e-4f * unit, "the slide bent to %f, wanted %f", got, want);
	test::@check(clip.keyframes[0].dots[0].translation_tangents.mode == FREE
		&& clip.keyframes[0].dots[0].rotation_tangents.mode == AUTO, "the wrong channel was freed");
}

fn void a_held_segment_refuses_a_bend() @test
{
	GraphFixture f;
	f.open(HOLD);
	defer f.close();
	sz history = f.app.undo_stack.cursor;
	test::@check(!f.app.bend_graph_segment(f.app.editing, "hip", true, 2, 0.75f, 40.0f, {}, {}), "a held segment bent");
	// On a key, or past the last one, there is no segment to bend.
	test::@check(!f.app.bend_graph_segment(f.app.editing, "hip", true, 2, 0.5f, 40.0f, {}, {}), "a key bent");
	test::@check(!f.app.bend_graph_segment(f.app.editing, "hip", true, 2, 1.0f, 40.0f, {}, {}), "the end bent");
	test::@check(f.app.undo_stack.cursor == history, "a refused bend left an undo step");
}

<*
 The mode menu's call: every selected channel key takes the mode as one undo
 step, Auto to Free changes nothing that plays, Flat and Linear do what they say,
 and the selection reads the mode back (or none, mixed).
*>
fn void selected_keys_take_a_tangent_mode_without_jumping() @test
{
	GraphFixture f;
	f.open(AUTO);
	defer f.close();
	select_hip_keys(&f, { 0.0f, 0.5f, 1.0f });
	AnimTemplate* clip = f.app.clip(f.app.editing);
	float[9] before;
	foreach (i, &v : before) *v = crig::euler_of(clip.rotation_at("hip", (float)i / 8.0f), {}).z;

	AnimTangent mode;
	bool mixed;
	test::@check(f.app.animation_selection_tangent_mode(f.app.editing, &mode) && mode == AUTO, "the keys do not read Auto");
	sz history = f.app.undo_stack.cursor;
	test::@check(f.app.set_selected_tangent_mode(f.app.editing, FREE), "Free was refused");
	test::@check(f.app.undo_stack.cursor == history + 1, "a mode change was not one step");
	clip = f.app.clip(f.app.editing);
	foreach (i, v : before)
	{
		test::@check(math::is_approx(crig::euler_of(clip.rotation_at("hip", (float)i / 8.0f), {}).z, v, 0.05f), "Auto to Free moved the curve at %d", i);
	}
	test::@check(f.app.animation_selection_tangent_mode(f.app.editing, &mode) && mode == FREE, "the keys do not read Free");
	test::@check(clip.keyframes[0].dots[0].translation_tangents.mode == AUTO, "the position channel changed too");
	test::@check(f.app.animation_channel_key_selection_count(f.app.editing) == 3, "the change dropped the selection");

	// One key apart: mixed, which reads as no mode.
	f.app.restart_key_selection(f.app.editing);
	f.app.select_channel(0.5f, "hip", ROTATION);
	test::@check(f.app.set_selected_tangent_mode(f.app.editing, FLAT), "Flat was refused");
	select_hip_keys(&f, { 0.0f, 0.5f });
	test::@check(!f.app.animation_selection_tangent_mode(f.app.editing, &mode, &mixed) && mixed, "a mix reads as one mode");
	// Flat: the key is level, and its rate is zero.
	clip = f.app.clip(f.app.editing);
	test::@check(crig::effective_rotation_tangent(*clip, 1, "hip", false).length() == 0.0f, "a flat key has a slope");
	// Linear on a pose selection reaches every channel keyed there.
	f.app.restart_key_selection(f.app.editing);
	f.app.select_time(0.5f);
	test::@check(f.app.set_selected_tangent_mode(f.app.editing, LINEAR), "Linear was refused");
	AnimKeyDot dot = f.app.clip(f.app.editing).keyframes[1].dots[0];
	test::@check(dot.rotation_tangents.mode == LINEAR && dot.translation_tangents.mode == LINEAR, "a pose selection missed a channel");
	// Nothing selected: nothing to do.
	f.app.restart_key_selection(f.app.editing);
	test::@check(!f.app.set_selected_tangent_mode(f.app.editing, FREE), "a mode was set with nothing selected");
	test::@check(f.app.undo() && f.app.undo() && f.app.undo(), "the mode changes did not undo");
	test::@check(f.app.clip(f.app.editing).keyframes[1].dots[0].rotation_tangents.mode == AUTO, "undo did not restore Auto");
}

<*
 Tangent rates are per second, so a retime that scales key times scales them back:
 a clip stretched to twice as long has half the rate; a move leaves them alone.
*>
fn void retiming_scales_stored_tangent_rates() @test
{
	GraphFixture f;
	f.open(AUTO);
	defer f.close();
	select_hip_keys(&f, { 0.5f });
	test::@check(f.app.set_selected_tangent_mode(f.app.editing, BROKEN), "Broken was refused");
	AnimTemplate* clip = f.app.clip(f.app.editing);
	AnimTangents original = clip.keyframes[1].dots[0].rotation_tangents;
	test::@check(original.outgoing.length() > 0, "no rate to scale");

	// The whole clip, twice as long.
	AnimTemplate stretched = crig::clip_retimed(mem, *clip, 2.0f);
	defer stretched.free(mem);
	AnimTangents slow = stretched.keyframes[1].dots[0].rotation_tangents;
	test::@check((slow.outgoing * 2.0f - original.outgoing).length() < 1.0e-5f
		&& (slow.incoming * 2.0f - original.incoming).length() < 1.0e-5f, "a stretch left the rates alone");
	test::@check(stretched.keyframes[0].dots[0].rotation_tangents.mode == AUTO, "a stretch changed an Auto key");

	// A move keeps them; a scale about the clip's start (the selected key and the last one) divides them.
	test::@check(f.app.move_selected_animation_keys(f.app.editing, 0.1f), "the move was refused");
	AnimTangents moved;
	foreach (frame : f.app.clip(f.app.editing).keyframes)
	{
		AnimKeyDot dot;
		if (math::is_approx(frame.time, 0.6f, EPS) && frame.channel_dot("hip", true, &dot)) moved = dot.rotation_tangents;
	}
	test::@check((moved.outgoing - original.outgoing).length() < 1.0e-6f, "a move changed the rates");
	test::@check(f.app.undo(), "the move did not undo");
	select_hip_keys(&f, { 0.5f });
	test::@check(f.app.scale_graph_key_times(f.app.editing, 0.5f, 0.0f), "the scale was refused");
	AnimTemplate* scaled = f.app.clip(f.app.editing);
	test::@check(math::is_approx(scaled.keyframes[1].time, 0.25f, EPS), "the key is at %f", scaled.keyframes[1].time);
	AnimTangents quick = scaled.keyframes[1].dots[0].rotation_tangents;
	test::@check((quick.outgoing * 0.5f - original.outgoing).length() < 1.0e-5f, "a channel scale left the rates alone");
	test::@check(f.app.undo(), "the scale did not undo");

	// The same through a pose selection.
	f.app.restart_key_selection(f.app.editing);
	f.app.select_time(0.5f);
	test::@check(f.app.scale_graph_key_times(f.app.editing, 0.5f, 0.0f), "the pose scale was refused");
	quick = f.app.clip(f.app.editing).keyframes[1].dots[0].rotation_tangents;
	test::@check((quick.outgoing * 0.5f - original.outgoing).length() < 1.0e-5f, "a pose scale left the rates alone");
}

<*
 A pending pose with no draft behind it, whatever left it so, is not a trap:
 Revert takes the banner down instead of finding nothing to discard.
*>
fn void revert_clears_a_pending_pose_that_has_no_draft() @test
{
	GraphFixture f;
	f.open();
	defer f.close();

	f.app.pose_edit_pending = true;
	test::@check(!f.app.pose_edit_active, "the fixture has a draft");
	test::@check(f.app.discard_pose_edit(), "Revert found nothing to discard");
	test::@check(!f.app.pose_edit_pending, "Revert left the banner up");
	test::@check(!f.app.discard_pose_edit(), "Revert with nothing pending claimed a discard");
}

fn void select_hip_keys(GraphFixture* f, float[] times)
{
	f.app.restart_key_selection(f.app.editing);
	foreach (time : times) f.app.select_channel(time, "hip", ROTATION);
}

<*
 Offset, scale and exact value act on one axis of every selected key, leave the
 other axes and the unselected keys alone, keep the selection, and are one undo
 step each.
*>
fn void multi_key_edits_move_the_whole_selection() @test
{
	GraphFixture f;
	f.open();
	defer f.close();
	float deg = 180.0f / (float)math::PI;
	select_hip_keys(&f, { 0.5f, 1.0f });
	Graph graph = f.app.build_graph(f.app.editing);
	defer graph.free();

	// Z up by 10°: the two selected keys, together, as one step.
	sz history = f.app.undo_stack.cursor;
	test::@check(f.app.set_graph_keys_offset(f.app.editing, &graph, true, 2, 10.0f), "the offset was refused");
	test::@check(f.app.undo_stack.cursor == history + 1, "an offset was not one step");
	AnimTemplate* clip = f.app.clip(f.app.editing);
	test::@check(math::is_approx(crig::euler_of(clip.keyframes[0].rotation_of("hip"), {}).z, 0, 1.0e-2f), "an unselected key moved");
	test::@check(math::is_approx(crig::euler_of(clip.keyframes[1].rotation_of("hip"), {}).z, 1.0f * deg + 10.0f, 1.0e-2f),
		"the middle key reads %f", crig::euler_of(clip.keyframes[1].rotation_of("hip"), {}).z);
	test::@check(math::is_approx(crig::euler_of(clip.keyframes[2].rotation_of("hip"), {}).z, 0.5f * deg + 10.0f, 1.0e-2f),
		"the last key reads %f", crig::euler_of(clip.keyframes[2].rotation_of("hip"), {}).z);
	test::@check(math::is_approx(crig::euler_of(clip.keyframes[1].rotation_of("hip"), {}).x, 0, 1.0e-2f), "the offset leaked to X");
	test::@check(f.app.animation_channel_key_selection_count(f.app.editing) == 2, "the edit dropped the selection");
	test::@check(f.app.undo(), "the offset did not undo");
	test::@check(math::is_approx(f.app.clip(f.app.editing).keyframes[1].dots[0].angle, 1.0f, EPS), "undo did not restore the key");

	// X by 20°: one key holds a quaternion, but only the X angle changes.
	select_hip_keys(&f, { 0.5f, 1.0f });
	Graph again = f.app.build_graph(f.app.editing);
	defer again.free();
	test::@check(f.app.set_graph_keys_offset(f.app.editing, &again, true, 0, 20.0f), "the X offset was refused");
	Vec3 now = crig::euler_of(f.app.clip(f.app.editing).keyframes[1].rotation_of("hip"), {});
	test::@check(math::is_approx(now.x, 20.0f, 1.0e-2f) && math::is_approx(now.z, 1.0f * deg, 1.0e-2f), "the key now reads %s", now);
	test::@check(f.app.undo(), "the X offset did not undo");

	// Scale about 0: the selected values double, the first key is not selected.
	select_hip_keys(&f, { 0.5f, 1.0f });
	Graph third = f.app.build_graph(f.app.editing);
	defer third.free();
	history = f.app.undo_stack.cursor;
	test::@check(f.app.scale_graph_keys(f.app.editing, &third, true, 2, 2.0f, 0.0f), "the scale was refused");
	test::@check(f.app.undo_stack.cursor == history + 1, "a scale was not one step");
	clip = f.app.clip(f.app.editing);
	test::@check(math::is_approx(crig::euler_of(clip.keyframes[1].rotation_of("hip"), {}).z, 2.0f * deg, 1.0e-2f)
		&& math::is_approx(crig::euler_of(clip.keyframes[2].rotation_of("hip"), {}).z, 1.0f * deg, 1.0e-2f), "the scale missed");
	test::@check(f.app.undo(), "the scale did not undo");

	// Exact: both read the same, and the field's common value now agrees.
	select_hip_keys(&f, { 0.5f, 1.0f });
	Graph fourth = f.app.build_graph(f.app.editing);
	defer fourth.free();
	float value;
	bool mixed;
	test::@check(fourth.selected_values(true, 2, &value, &mixed) == 2 && mixed, "the two keys differ before");
	test::@check(f.app.set_graph_keys_exact(f.app.editing, &fourth, true, 2, 15.0f), "the exact value was refused");
	Graph after = f.app.build_graph(f.app.editing);
	defer after.free();
	test::@check(after.selected_values(true, 2, &value, &mixed) == 2 && !mixed && math::is_approx(value, 15.0f, 1.0e-2f),
		"the keys do not share 15 (%f, mixed %s)", value, mixed);
	test::@check(f.app.undo(), "the exact value did not undo");
}

<*
 The selection's times scale about a pivot as one step, and a scale that would
 leave the clip changes nothing.
*>
fn void multi_key_times_scale_about_the_playhead() @test
{
	GraphFixture f;
	f.open();
	defer f.close();
	select_hip_keys(&f, { 0.5f, 1.0f });
	sz history = f.app.undo_stack.cursor;
	test::@check(!f.app.scale_graph_key_times(f.app.editing, 2.0f, 0.0f), "a scale past the clip was accepted");
	test::@check(f.app.undo_stack.cursor == history, "a refused scale left an undo step");
	test::@check(f.app.scale_graph_key_times(f.app.editing, 0.5f, 0.0f), "the time scale was refused");
	test::@check(f.app.undo_stack.cursor == history + 1, "a time scale was not one step");
	AnimTemplate* clip = f.app.clip(f.app.editing);
	// Only the rotation channel moved: the slides stay at 0.5 and 1 s.
	test::@check(clip.keyframes.len == 4, "%d keyframes", clip.keyframes.len);
	float[3] turns = { 0.0f, 0.25f, 0.5f };
	foreach (at : turns)
	{
		sz key = f.app.key_near(f.app.editing, at, crig::ANIM_SAME_TIME);
		test::@check(key >= 0 && clip.keyframes[key].has_channel("hip", ROTATION), "no rotation key at %f", at);
	}
	test::@check(!clip.keyframes[f.app.key_near(f.app.editing, 1.0f, crig::ANIM_SAME_TIME)].has_channel("hip", ROTATION),
		"a rotation key stayed at 1 s");
	test::@check(f.app.animation_channel_key_selected(f.app.editing, 0.25f, "hip", ROTATION), "the scale dropped the selection");
}
