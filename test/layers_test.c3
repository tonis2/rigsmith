<*
 Animation layers (anim/layers.c3): evaluation inside `AnimTemplate.pose`, the
 project sidecar, the writers that keep authored keys, and the MCP tools.

     `c3c test --trust=full --test-noleak --test-filter crig_tests::layers`
*>
module crig_tests::layers;

import crig;
import rig;
import std::collections::object;
import std::core::test;
import std::core::string;
import std::encoding::json;
import std::io;
import std::io::file;
import std::math;
import std::math::vector;
import std::math::quaternion;

// root
//  |- a - b - c
//  `- d
Vec3[5] rig_joints @local = {
	{ 0, 1, 0 }, { 0, 0.8f, 0 }, { 0, 0.6f, 0 }, { 0, 0.4f, 0 }, { 0.3f, 0.9f, 0 },
};
int[5] rig_parents @local = { -1, 0, 1, 2, 0 };
String[5] rig_names @local = { "root", "a", "b", "c", "d" };

const Vec3 X = { 1, 0, 0 };
const Vec3 Y = { 0, 1, 0 };

fn rig::Skeleton small_rig() => { .joints = rig_joints[..], .parents = rig_parents[..] };

// ---------------------------------------------------------------------------
// Builders. Every string is a heap copy: `AnimTemplate.free` releases them.

fn AnimKeyframe key_of(float time, String joint, Vec3 axis, float angle)
{
	AnimKeyDot[] dots = alloc::new_array(mem, AnimKeyDot, 1);
	dots[0] = { .joint_name = joint.copy(mem), .axis = axis, .angle = angle, .channels = ROTATION };
	return { .time = time, .dots = dots };
}

fn AnimTemplate clip_of(String name, float duration, bool loop, AnimKeyframe[] keys)
{
	return { .name = name.copy(mem), .duration = duration, .keyframes = keys, .loop = loop, .owned = true };
}

fn AnimKeyframe[] keys_of(AnimKeyframe first, AnimKeyframe second = {})
{
	usz count = second.dots.len > 0 ? 2 : 1;
	AnimKeyframe[] keys = alloc::new_array(mem, AnimKeyframe, (sz)count);
	keys[0] = first;
	if (count == 2) keys[1] = second;
	return keys;
}

fn AnimLayer keyed_layer(String name, AnimLayerMode mode, float weight, AnimKeyframe[] keys)
{
	AnimLayer layer = crig::anim_layer_defaults(name.copy(mem));
	layer.mode = mode;
	layer.weight = weight;
	layer.keyframes = keys;
	return layer;
}

fn AnimLayer wave_layer(String name, String joint, float amplitude, float cycles)
{
	AnimLayer layer = crig::anim_layer_defaults(name.copy(mem));
	layer.kind = WAVE;
	layer.joint = joint.copy(mem);
	layer.amplitude = amplitude;
	layer.cycles = cycles;
	layer.lag = 0.15f;
	layer.falloff = 1.2f;
	return layer;
}

fn void give_layers(AnimTemplate* clip, AnimLayer[] layers)
{
	clip.layers = alloc::new_array(mem, AnimLayer, layers.len);
	foreach (usz i, layer : layers) clip.layers[i] = layer;
}

// The turn a quaternion makes about a unit axis, shortest way round.
fn float turn_about(Quaternionf q, Vec3 axis)
{
	if (q.v.w < 0.0f) q = -q;
	Vec3 part = { q.v.x, q.v.y, q.v.z };
	return 2.0f * math::atan2(part.dot(axis), q.v.w);
}

// Whether an optional result is a fault.
macro bool @failed(#result)
{
	if (catch #result) return true;
	return false;
}

fn bool near(float a, float b, float tolerance = 1.0e-4f) => math::abs(a - b) <= tolerance;

fn bool same_rotation(Quaternionf a, Quaternionf b, float tolerance = 1.0e-4f)
{
	return 1.0f - math::abs(a.v.dot(b.v)) <= tolerance;
}

fn rig::Pose pose_of(AnimTemplate* clip, float time, bool honor_solo = true)
{
	rig::Skeleton skeleton = small_rig();
	return clip.pose(mem, &skeleton, rig_names[..], time, false, honor_solo);
}

// ---------------------------------------------------------------------------
// 1. A wave on a chain loops seamlessly.

fn void a_wave_layer_loops_seamlessly() @test
{
	AnimKeyframe[] keys = keys_of(key_of(0.0f, "a", Y, 0.0f), key_of(1.0f, "a", Y, 0.0f));
	AnimTemplate clip = clip_of("loops", 1.0f, true, keys);
	defer clip.free(mem);
	// 1.6 cycles would not close; a looping clip rounds it to 2.
	AnimLayer[1] stack = { wave_layer("wave", "a", 0.3f, 1.6f) };
	give_layers(&clip, stack[..]);

	rig::Pose start = pose_of(&clip, 0.0f);
	defer start.free(mem);
	rig::Pose end = pose_of(&clip, 1.0f);
	defer end.free(mem);
	rig::Pose middle = pose_of(&clip, 0.125f);
	defer middle.free(mem);

	for (usz j = 0; j < 5; j++)
	{
		test::@check(same_rotation(start.rotations[j], end.rotations[j]),
			"joint %s differs between t=0 and t=duration", rig_names[j]);
	}
	// It moves in between, and down the chain: a, b and c, but not d.
	test::@check(math::abs(turn_about(middle.rotations[1], X)) > 0.05f, "the wave did not move a");
	test::@check(math::abs(turn_about(middle.rotations[3], X)) > 0.05f, "the wave did not reach c");
	test::@check(same_rotation(middle.rotations[4], quaternion::IDENTITY), "the wave moved d, off its chain");
	// Falloff above one grows toward the tip: c swings further than a at its peak
	// (lag 0.15 per joint puts the peaks at different instants, so compare maxima).
	float peak_a = 0.0f;
	float peak_c = 0.0f;
	for (uint i = 0; i < 64; i++)
	{
		rig::Pose p = pose_of(&clip, (float)i / 64.0f);
		defer p.free(mem);
		peak_a = math::max(peak_a, math::abs(turn_about(p.rotations[1], X)));
		peak_c = math::max(peak_c, math::abs(turn_about(p.rotations[3], X)));
	}
	test::@check(peak_c > peak_a * 1.3f, "falloff 1.2 did not grow the wave toward the tip (%.3f vs %.3f)", peak_a, peak_c);
}

fn void noise_and_pulse_layers_loop_and_stay_bounded() @test
{
	AnimKeyframe[] keys = keys_of(key_of(0.0f, "a", Y, 0.0f), key_of(1.0f, "a", Y, 0.0f));
	AnimTemplate clip = clip_of("procedural", 1.0f, true, keys);
	defer clip.free(mem);
	AnimLayer noise = wave_layer("noise", "d", 0.25f, 3.0f);
	noise.kind = NOISE;
	noise.seed = 7;
	AnimLayer pulse = wave_layer("pulse", "c", 0.5f, 1.0f);
	pulse.kind = PULSE;
	pulse.at = 0.5f;
	pulse.width = 0.05f;
	AnimLayer[2] stack = { noise, pulse };
	give_layers(&clip, stack[..]);

	rig::Pose start = pose_of(&clip, 0.0f);
	defer start.free(mem);
	rig::Pose end = pose_of(&clip, 1.0f);
	defer end.free(mem);
	for (usz j = 0; j < 5; j++)
	{
		test::@check(same_rotation(start.rotations[j], end.rotations[j]), "noise/pulse does not close on %s", rig_names[j]);
	}
	float biggest = 0.0f;
	for (uint i = 0; i < 100; i++)
	{
		rig::Pose p = pose_of(&clip, (float)i / 100.0f);
		defer p.free(mem);
		biggest = math::max(biggest, math::abs(turn_about(p.rotations[4], X)));
	}
	test::@check(biggest > 0.05f && biggest <= 0.25f + 1.0e-4f, "noise peak %.3f is not within its amplitude", biggest);
	rig::Pose hit = pose_of(&clip, 0.5f);
	defer hit.free(mem);
	test::@check(near(math::abs(turn_about(hit.rotations[3], X)), 0.5f, 2.0e-3f),
		"the pulse did not peak at its amplitude at `at` (%.4f)", turn_about(hit.rotations[3], X));
	rig::Pose far = pose_of(&clip, 0.9f);
	defer far.free(mem);
	test::@check(math::abs(turn_about(far.rotations[3], X)) < 1.0e-3f, "the pulse has not died away");
}

// ---------------------------------------------------------------------------
// 2. Additive keyed layers: exact delta, weight, mute, solo.

// A base that holds b at 0.2 about X, and the hold a keyed layer adds to.
fn AnimTemplate base_b()
{
	return clip_of("base", 1.0f, false, keys_of(key_of(0.0f, "b", X, 0.2f)));
}

fn AnimKeyframe[] delta_b(float angle) => keys_of(key_of(0.0f, "b", X, angle));

fn float b_angle(AnimTemplate* clip, bool honor_solo = true)
{
	rig::Pose p = pose_of(clip, 0.5f, honor_solo);
	defer p.free(mem);
	return turn_about(p.rotations[2], X);
}

fn void an_additive_keyed_layer_adds_exactly_its_delta() @test
{
	AnimTemplate clip = base_b();
	defer clip.free(mem);
	test::@check(near(b_angle(&clip), 0.2f), "the base alone is not 0.2");

	AnimLayer[1] full = { keyed_layer("nod", ADDITIVE, 1.0f, delta_b(0.4f)) };
	give_layers(&clip, full[..]);
	test::@check(near(b_angle(&clip), 0.6f), "weight 1 gives %.5f, not base + delta", b_angle(&clip));

	clip.layers[0].weight = 0.5f;
	test::@check(near(b_angle(&clip), 0.4f), "weight 0.5 gives %.5f, not base + half the delta", b_angle(&clip));

	clip.layers[0].weight = 0.0f;
	test::@check(near(b_angle(&clip), 0.2f), "weight 0 changed the pose");

	clip.layers[0].weight = 1.0f;
	clip.layers[0].mute = true;
	test::@check(near(b_angle(&clip), 0.2f), "a muted layer changed the pose");
}

fn void solo_isolates_one_layer_but_an_export_ignores_it() @test
{
	AnimTemplate clip = base_b();
	defer clip.free(mem);
	AnimLayer[2] stack = {
		keyed_layer("big", ADDITIVE, 1.0f, delta_b(0.4f)),
		keyed_layer("small", ADDITIVE, 1.0f, delta_b(0.1f)),
	};
	give_layers(&clip, stack[..]);
	test::@check(near(b_angle(&clip), 0.7f), "both layers add: %.5f", b_angle(&clip));

	clip.layers[1].solo = true;
	test::@check(near(b_angle(&clip), 0.3f), "solo leaves only the soloed layer: %.5f", b_angle(&clip));
	test::@check(near(b_angle(&clip, false), 0.7f), "an export must ignore solo: %.5f", b_angle(&clip, false));

	// A muted layer cannot solo the others away.
	clip.layers[1].mute = true;
	test::@check(near(b_angle(&clip), 0.6f), "a muted solo layer silenced the rest: %.5f", b_angle(&clip));
}

fn void a_layer_can_drive_a_joint_the_base_never_keys() @test
{
	AnimTemplate clip = clip_of("sparse", 1.0f, false, keys_of(key_of(0.0f, "a", Y, 0.3f)));
	defer clip.free(mem);
	AnimLayer[1] stack = { keyed_layer("c only", ADDITIVE, 1.0f, keys_of(key_of(0.0f, "c", X, 0.5f))) };
	give_layers(&clip, stack[..]);
	rig::Pose p = pose_of(&clip, 0.0f);
	defer p.free(mem);
	test::@check(near(turn_about(p.rotations[3], X), 0.5f), "the layer did not move c");
	test::@check(near(turn_about(p.rotations[1], Y), 0.3f), "the base on a was disturbed");
}

// ---------------------------------------------------------------------------
// 3. Override, limited to its mask.

fn void an_override_layer_acts_only_inside_its_mask() @test
{
	AnimKeyframe[] base_keys = alloc::new_array(mem, AnimKeyframe, 1);
	AnimKeyDot[] dots = alloc::new_array(mem, AnimKeyDot, 3);
	String[3] joints = { "a", "b", "c" };
	foreach (usz i, joint : joints) dots[i] = { .joint_name = joint.copy(mem), .axis = Y, .angle = 0.3f, .channels = ROTATION };
	base_keys[0] = { .time = 0.0f, .dots = dots };
	AnimTemplate clip = clip_of("override", 1.0f, false, base_keys);
	defer clip.free(mem);

	AnimKeyDot[] layer_dots = alloc::new_array(mem, AnimKeyDot, 3);
	foreach (usz i, joint : joints) layer_dots[i] = { .joint_name = joint.copy(mem), .axis = Y, .angle = 1.0f, .channels = ROTATION };
	AnimKeyframe[] layer_keys = alloc::new_array(mem, AnimKeyframe, 1);
	layer_keys[0] = { .time = 0.0f, .dots = layer_dots };
	AnimLayer layer = keyed_layer("arm", OVERRIDE, 1.0f, layer_keys);
	layer.mask = alloc::new_array(mem, String, 1);
	layer.mask[0] = "b".copy(mem);
	AnimLayer[1] stack = { layer };
	give_layers(&clip, stack[..]);

	rig::Pose p = pose_of(&clip, 0.0f);
	defer p.free(mem);
	test::@check(near(turn_about(p.rotations[1], Y), 0.3f), "a, outside the mask, was overridden (%.4f)", turn_about(p.rotations[1], Y));
	test::@check(near(turn_about(p.rotations[2], Y), 1.0f), "b, the mask's joint, was not overridden");
	test::@check(near(turn_about(p.rotations[3], Y), 1.0f), "c, below the masked joint, was not overridden");

	clip.layers[0].weight = 0.5f;
	rig::Pose half = pose_of(&clip, 0.0f);
	defer half.free(mem);
	test::@check(near(turn_about(half.rotations[2], Y), 0.65f, 1.0e-3f), "half weight did not blend (%.4f)", turn_about(half.rotations[2], Y));
	test::@check(near(turn_about(half.rotations[1], Y), 0.3f), "a moved at half weight");
}

fn void a_ranged_layer_fades_in_and_out_of_its_window() @test
{
	AnimTemplate clip = base_b();
	defer clip.free(mem);
	clip.duration = 4.0f;
	AnimLayer layer = keyed_layer("window", ADDITIVE, 1.0f, delta_b(0.4f));
	layer.start = 1.0f;
	layer.end = 3.0f;
	layer.fade_in = 1.0f;
	layer.fade_out = 1.0f;
	AnimLayer[1] stack = { layer };
	give_layers(&clip, stack[..]);

	float at_before;
	{
		rig::Pose p = pose_of(&clip, 0.5f);
		defer p.free(mem);
		at_before = turn_about(p.rotations[2], X);
	}
	rig::Pose rising = pose_of(&clip, 1.5f);
	defer rising.free(mem);
	rig::Pose middle = pose_of(&clip, 2.0f);
	defer middle.free(mem);
	rig::Pose after = pose_of(&clip, 3.5f);
	defer after.free(mem);
	test::@check(near(at_before, 0.2f), "the layer acts before its range (%.4f)", at_before);
	test::@check(near(turn_about(rising.rotations[2], X), 0.4f), "half way through the fade-in is half the delta");
	test::@check(near(turn_about(middle.rotations[2], X), 0.6f), "full delta in the middle of the range");
	test::@check(near(turn_about(after.rotations[2], X), 0.2f), "the layer acts after its range");
}

// ---------------------------------------------------------------------------
// 4. The sidecar.

fn AnimTemplate layered_clip(String name)
{
	AnimKeyframe[] keys = keys_of(key_of(0.0f, "a", Y, 0.0f), key_of(1.0f, "a", Y, 0.25f));
	AnimTemplate clip = clip_of(name, 1.0f, true, keys);
	AnimLayer breath = keyed_layer("breath \"in\"", ADDITIVE, 0.75f, delta_b(0.125f));
	breath.mask = alloc::new_array(mem, String, 2);
	breath.mask[0] = "b".copy(mem);
	breath.mask[1] = "d".copy(mem);
	breath.start = 0.25f;
	breath.end = 0.875f;
	breath.fade_in = 0.0625f;
	breath.fade_out = 0.125f;
	breath.solo = true;
	AnimLayer wave = wave_layer("tail wave", "a", 0.3f, 2.0f);
	wave.tip = "c".copy(mem);
	wave.axis = { 0, 0, 1 };
	wave.phase = 0.25f;
	AnimLayer noise = wave_layer("noise", "b", 0.1f, 3.0f);
	noise.kind = NOISE;
	noise.seed = 4242;
	noise.mute = true;
	AnimLayer pulse = wave_layer("pulse", "c", 0.4f, 1.0f);
	pulse.kind = PULSE;
	pulse.mode = OVERRIDE;
	pulse.at = 0.5f;
	pulse.width = 0.0625f;
	AnimLayer[4] stack = { breath, wave, noise, pulse };
	give_layers(&clip, stack[..]);
	return clip;
}

fn void the_layer_stack_round_trips_through_the_sidecar() @test
{
	RigDocument doc = {};
	defer doc.free();
	AnimTemplate clip = layered_clip("Layered");
	defer clip.free(mem);
	AnimTemplate[1] source = { clip };

	String text = crig::session_text(mem, &doc, "hero.glb", source[..]);
	defer text.free(mem);
	AnimTemplate[]? parsed = crig::parse_session_clips(mem, text);
	if (catch fault error = parsed)
	{
		test::@check(false, "the layered session did not parse: %s", error);
		return;
	}
	AnimTemplate[] clips = parsed;
	defer crig::free_animations(mem, clips);
	test::@check(clips.len == 1 && clips[0].layers.len == 4, "the stack came back with %d layers", clips.len == 1 ? clips[0].layers.len : 0);
	if (clips.len != 1 || clips[0].layers.len != 4) return;

	AnimLayer* breath = &clips[0].layers[0];
	test::@check(breath.name == "breath \"in\"" && breath.mode == ADDITIVE && breath.kind == KEYED
		&& breath.weight == 0.75f && breath.solo && !breath.mute
		&& breath.start == 0.25f && breath.end == 0.875f && breath.fade_in == 0.0625f && breath.fade_out == 0.125f
		&& breath.mask.len == 2 && breath.mask[1] == "d"
		&& breath.keyframes.len == 1 && breath.keyframes[0].dots[0].angle == 0.125f,
		"the keyed layer changed on the way through");
	AnimLayer* wave = &clips[0].layers[1];
	test::@check(wave.kind == WAVE && wave.joint == "a" && wave.tip == "c" && wave.axis == (Vec3){ 0, 0, 1 }
		&& wave.amplitude == 0.3f && wave.cycles == 2.0f && wave.lag == 0.15f && wave.falloff == 1.2f && wave.phase == 0.25f,
		"the wave layer changed on the way through");
	test::@check(clips[0].layers[2].kind == NOISE && clips[0].layers[2].seed == 4242 && clips[0].layers[2].mute,
		"the noise layer changed on the way through");
	test::@check(clips[0].layers[3].kind == PULSE && clips[0].layers[3].mode == OVERRIDE
		&& clips[0].layers[3].at == 0.5f && clips[0].layers[3].width == 0.0625f,
		"the pulse layer changed on the way through");

	// Byte-stable: writing what was read gives the same text, so a save does not
	// drift the stack.
	AnimTemplate[1] again = { clips[0] };
	String second = crig::session_text(mem, &doc, "hero.glb", again[..]);
	defer second.free(mem);
	test::@check(second == text, "a second write of the read stack is different");
}

fn void a_version_19_sidecar_without_layers_still_reads() @test
{
	RigDocument doc = {};
	defer doc.free();
	AnimTemplate clip = clip_of("Plain", 1.0f, false, keys_of(key_of(0.0f, "a", Y, 0.5f)));
	defer clip.free(mem);
	AnimTemplate[1] source = { clip };
	String text = crig::session_text(mem, &doc, "hero.glb", source[..]);
	defer text.free(mem);
	test::@check(!text.contains(`"layers"`), "a clip with no layers wrote a layers member");
	test::@check(text.contains(`"version": 20`), "the sidecar is not version 20");

	String old = text.replace(mem, `"version": 20`, `"version": 19`);
	defer old.free(mem);
	RigDocument? opened = crig::parse_session(mem, old);
	if (catch fault error = opened)
	{
		test::@check(false, "a version 19 session was refused: %s", error);
		return;
	}
	RigDocument read = opened;
	read.free();
	AnimTemplate[]? clips = crig::parse_session_clips(mem, old);
	if (catch fault error = clips)
	{
		test::@check(false, "the version 19 clips did not read: %s", error);
		return;
	}
	AnimTemplate[] back = clips;
	defer crig::free_animations(mem, back);
	test::@check(back.len == 1 && back[0].layers.len == 0 && back[0].keyframes.len == 1, "a clip with no layers came back with some");

	String future = text.replace(mem, `"version": 20`, `"version": 21`);
	defer future.free(mem);
	RigDocument? refused = crig::parse_session(mem, future);
	test::@check(@failed(refused), "a version from the future was accepted");
}

fn void a_malformed_layer_refuses_the_sidecar() @test
{
	const String BROKEN = `{"authored_clips":[{"name":"x","duration":1,"loop":false,"blend":"linear","keys":[{"time":0,"dots":[]}],"layers":[{"name":"w","kind":"wave","weight":2}]}]}`;
	AnimTemplate[]? refused = crig::parse_session_clips(mem, BROKEN);
	test::@check(@failed(refused), "a layer with a weight of 2 was accepted");
	const String NO_JOINT = `{"authored_clips":[{"name":"x","duration":1,"loop":false,"blend":"linear","keys":[{"time":0,"dots":[]}],"layers":[{"name":"w","kind":"wave"}]}]}`;
	AnimTemplate[]? joint = crig::parse_session_clips(mem, NO_JOINT);
	test::@check(@failed(joint), "a wave with no joint was accepted");
}

// ---------------------------------------------------------------------------
// 5. Save in place: flattened channels in the glb, the stack in the sidecar.

fn void save_flattens_the_layers_into_the_model_and_the_sidecar_keeps_them() @test
{
	String source = "assets/animations/humanoid.glb";
	String path = "build/layers-humanoid.glb";
	String sidecar = "build/layers-humanoid.rigsmith.json";
	char[] original = file::load(mem, source)!!;
	defer alloc::free(mem, original);
	file::save(path, original)!!;
	defer (void)file::delete(path);
	String source_sidecar = crig::session_path(mem, source);
	defer source_sidecar.free(mem);
	char[] session = file::load(mem, source_sidecar)!!;
	defer alloc::free(mem, session);
	file::save(sidecar, session)!!;
	defer (void)file::delete(sidecar);

	rig::TriMesh mesh = rig::load_gltf(mem, path)!!;
	defer mesh.free(mem);
	crig::AppState app = crig::new_app(mesh, path);
	defer app.free();
	app.adopt_source_rig();
	// The humanoid's limits would clamp a baked wave and make the file differ from
	// the raw sampler on purpose; this test is about the layers.
	app.doc.rotation_limits.clear();
	app.saves_in_place = true;

	AnimKeyframe[] keys = keys_of(key_of(0.0f, "hips", Y, 0.0f), key_of(1.0f, "hips", Y, 0.2f));
	AnimTemplate clip = clip_of("Layered", 1.0f, true, keys);
	AnimLayer wave = wave_layer("arm wave", "shoulder_L", 0.3f, 2.0f);
	wave.axis = { 0, 0, 1 };
	AnimLayer[1] stack = { wave };
	give_layers(&clip, stack[..]);
	AnimRef ref = app.author_clip(clip);
	test::@check(ref.valid(), "the layered clip did not land");

	app.save_session();

	// The glb: flattened channels, and no layer data anywhere in it.
	char[] saved = file::load(mem, path)!!;
	defer alloc::free(mem, saved);
	test::@check(!((String)saved).contains(`"layers"`) && !((String)saved).contains("arm wave"),
		"the saved model carries layer data");

	crig::AnimPack pack = crig::read_pack(mem, path)!!;
	defer pack.free(mem);
	AnimTemplate* baked = null;
	foreach (&held : pack.clips) if (held.name == "Layered") baked = held;
	test::@check(baked != null, "the model holds no Layered clip");
	if (baked == null) return;
	test::@check(baked.layers.len == 0, "the model's clip has layers");

	RigView view = app.open_rig(mem)!!;
	defer view.free(mem);
	AnimTemplate* live = app.clip(ref);
	usz shoulder = 0;
	foreach (usz j, name : view.names) if (name == "shoulder_L") shoulder = j;
	// 32 samples a second is the bake grid for a two-cycle wave (16 per cycle).
	for (uint i = 0; i < 32; i += 4)
	{
		float t = (float)i / 32.0f;
		rig::Pose want = live.pose(mem, &view.skeleton, view.names, t, false);
		defer want.free(mem);
		rig::Pose got = baked.pose(mem, &view.skeleton, view.names, t, false);
		defer got.free(mem);
		test::@check(same_rotation(want.rotations[shoulder], got.rotations[shoulder], 1.0e-4f),
			"the file's channel differs from the layered pose at t=%.3f (%.4f vs %.4f)", t,
			turn_about(want.rotations[shoulder], Y), turn_about(got.rotations[shoulder], Y));
	}
	test::@check(math::abs(turn_about(pose_rotation(baked, &view, "shoulder_L", 0.125f), Z_AXIS)) > 0.05f,
		"the baked file does not hold the wave");

	// Reopening reads the project back: the stack is there, and sampling it gives
	// the same pose once — not the wave laid over a file that already holds it.
	rig::Pose before = live.pose(mem, &view.skeleton, view.names, 0.125f, false);
	defer before.free(mem);
	app.load_session();
	AnimRef reopened = app.clip_named_in_authored("Layered");
	test::@check(reopened.valid(), "the project did not restore the clip");
	AnimTemplate* again = app.clip(reopened);
	test::@check(again != null && again.layers.len == 1 && again.layers[0].name == "arm wave" && again.layers[0].kind == WAVE,
		"the project did not restore the layer stack");
	if (again == null) return;
	RigView view2 = app.open_rig(mem)!!;
	defer view2.free(mem);
	rig::Pose after = again.pose(mem, &view2.skeleton, view2.names, 0.125f, false);
	defer after.free(mem);
	test::@check(same_rotation(before.rotations[shoulder], after.rotations[shoulder]),
		"the reopened clip poses differently — the wave was doubled or lost");
}

const Vec3 Z_AXIS = { 0, 0, 1 };

fn Quaternionf pose_rotation(AnimTemplate* clip, RigView* view, String joint, float time)
{
	rig::Pose p = clip.pose(mem, &view.skeleton, view.names, time, false);
	defer p.free(mem);
	foreach (usz j, name : view.names) if (name == joint) return p.rotations[j];
	return quaternion::IDENTITY;
}

// ---------------------------------------------------------------------------
// 6. The writers that keep authored keys bake a layered clip.

fn void a_pack_export_bakes_a_layered_clip() @test
{
	AnimKeyframe[] keys = keys_of(key_of(0.0f, "a", Y, 0.0f), key_of(1.0f, "a", Y, 0.0f));
	AnimTemplate clip = clip_of("Waving", 1.0f, true, keys);
	defer clip.free(mem);
	AnimLayer[2] stack = { wave_layer("wave", "a", 0.3f, 2.0f), wave_layer("muted", "d", 0.5f, 1.0f) };
	stack[1].mute = true;
	stack[1].solo = true; // solo must not matter to a file
	give_layers(&clip, stack[..]);

	rig::Skeleton skeleton = small_rig();
	String path = "build/layers-pack.glb";
	defer (void)file::delete(path);
	AnimTemplate[1] written = { clip };
	if (catch fault error = crig::export_animations_glb(mem, path, &skeleton, rig_names[..], written[..]))
	{
		test::@check(false, "the export failed: %s", error);
		return;
	}
	// Nothing of the caller's clip was consumed.
	test::@check(clip.layers.len == 2 && clip.keyframes.len == 2, "the export changed the source clip");

	crig::AnimPack pack = crig::read_pack(mem, path)!!;
	defer pack.free(mem);
	test::@check(pack.clips.len == 1, "the file holds %d clips", pack.clips.len);
	if (pack.clips.len != 1) return;
	AnimTemplate* back = &pack.clips[0];
	test::@check(back.layers.len == 0, "the file's clip has layers");
	test::@check(back.keyframes.len > 2, "the layered clip was written as its two raw keys (%d)", back.keyframes.len);
	for (uint i = 0; i <= 32; i += 4)
	{
		float t = (float)i / 32.0f;
		rig::Pose want = pose_of(&clip, t, false);
		defer want.free(mem);
		rig::Pose got = back.pose(mem, &skeleton, rig_names[..], t, false);
		defer got.free(mem);
		for (usz j = 0; j < 5; j++)
		{
			test::@check(same_rotation(want.rotations[j], got.rotations[j], 1.0e-4f),
				"%s differs from the layered pose at t=%.3f", rig_names[j], t);
		}
	}
	// The muted layer left d still.
	rig::Pose mid = back.pose(mem, &skeleton, rig_names[..], 0.25f, false);
	defer mid.free(mem);
	test::@check(same_rotation(mid.rotations[4], quaternion::IDENTITY), "a muted layer was baked");
}

fn void a_library_pack_save_bakes_a_layered_clip() @test
{
	String library = "build/layers-library";
	(void)path::mkdir(library, true);
	crig::AppState app = crig::new_app({});
	defer app.free();
	uint root = app.doc.add_dot({ 0, 1, 0 }, "root");
	uint a = app.doc.add_dot({ 0, 0.8f, 0 }, "a");
	uint b = app.doc.add_dot({ 0, 0.6f, 0 }, "b");
	app.doc.connect(root, a);
	app.doc.connect(a, b);
	app.doc.root_id = root;
	app.library_path = library.copy(mem);

	AnimKeyframe[] keys = keys_of(key_of(0.0f, "a", Y, 0.0f), key_of(1.0f, "a", Y, 0.0f));
	AnimTemplate clip = clip_of("Flap", 1.0f, true, keys);
	AnimLayer[1] stack = { wave_layer("wave", "a", 0.3f, 2.0f) };
	give_layers(&clip, stack[..]);
	test::@check(app.author_clip(clip).valid(), "the layered clip did not land");

	String file_name = "layers-kit.glb";
	String target = "build/layers-library/layers-kit.glb";
	defer (void)file::delete(target);
	int? saved = app.save_authored_pack(file_name, "Kit", "");
	if (catch fault error = saved)
	{
		test::@check(false, "the pack did not save: %s", error);
		return;
	}
	crig::AnimPack pack = crig::read_pack(mem, target)!!;
	defer pack.free(mem);
	bool found = false;
	foreach (&held : pack.clips)
	{
		if (held.name != "Flap") continue;
		found = true;
		test::@check(held.keyframes.len > 2, "the pack holds the clip's two raw keys, not the wave (%d keys)", held.keyframes.len);
	}
	test::@check(found, "the pack has no Flap clip");
	// The project's own clip keeps its layers: publishing spends nothing.
	test::@check(app.authored().clips[0].layers.len == 1, "publishing consumed the project's layers");
}

// ---------------------------------------------------------------------------
// 7. The MCP tools.

fn Object* args_of(String text)
{
	Object*? parsed = json::parse(mem, text);
	if (catch parsed) { test::@check(false, "test arguments did not parse: %s", text); return null; }
	return parsed;
}

struct ToolFixture
{
	crig::AppState app;
	AnimRef ref;
}

fn void ToolFixture.open(&self)
{
	self.app = crig::new_app({});
	uint root = self.app.doc.add_dot({ 0, 1, 0 }, "root");
	uint a = self.app.doc.add_dot({ 0, 0.8f, 0 }, "a");
	uint b = self.app.doc.add_dot({ 0, 0.6f, 0 }, "b");
	uint c = self.app.doc.add_dot({ 0, 0.4f, 0 }, "c");
	self.app.doc.connect(root, a);
	self.app.doc.connect(a, b);
	self.app.doc.connect(b, c);
	self.app.doc.root_id = root;
	AnimKeyframe[] keys = keys_of(key_of(0.0f, "a", Y, 0.0f), key_of(1.0f, "a", Y, 0.3f));
	self.ref = self.app.author_clip(clip_of("Base", 1.0f, true, keys));
}

fn String call_set_layer(ToolFixture* f, String text, bool* ok)
{
	Object* args = args_of(text);
	defer args.free();
	DString detail = dstring::new(mem);
	defer detail.free();
	String? out = crig::set_layer_json(&f.app, args, &detail);
	if (catch out)
	{
		*ok = false;
		return detail.copy_str(mem);
	}
	*ok = true;
	return out;
}

fn void set_layer_adds_replaces_moves_and_removes_in_one_undo_step_each() @test
{
	ToolFixture fixture;
	fixture.open();
	defer fixture.app.free();
	ToolFixture* f = &fixture;
	bool ok;

	// Add a generator.
	String added = call_set_layer(f, `{"clip":"Base","op":"add","layer":{"name":"tail","kind":"wave","joint":"a","axis":[1,0,0],"amplitude":0.3,"cycles":2,"lag":0.1}}`, &ok);
	defer added.free(mem);
	test::@check(ok && added.contains(`"tail"`), "add refused or unreported: %s", added);
	test::@check(f.app.clip(f.ref).layers.len == 1 && f.app.clip(f.ref).layers[0].kind == WAVE, "the wave was not added");
	test::@check(f.app.undo(), "the add did not undo");
	test::@check(f.app.clip(f.ref).layers.len == 0 && f.app.clip(f.ref).keyframes.len == 2, "one undo did not take the add back");
	test::@check(f.app.redo(), "the add did not redo");
	test::@check(f.app.clip(f.ref).layers.len == 1, "redo did not put the layer back");

	// Add a keyed layer in apply_clip's own keyframe shape, below the wave.
	String keyed = call_set_layer(f, `{"clip":"Base","op":"add","index":0,"layer":{"name":"nod","keyframes":[{"time":0,"joints":[{"name":"b","rotation":{"axis":[1,0,0],"angle":0.4}}]}],"weight":0.5}}`, &ok);
	defer keyed.free(mem);
	test::@check(ok, "keyed add refused: %s", keyed);
	AnimTemplate* clip = f.app.clip(f.ref);
	test::@check(clip.layers.len == 2 && clip.layers[0].name == "nod" && clip.layers[1].name == "tail"
		&& clip.layers[0].kind == KEYED && clip.layers[0].keyframes.len == 1
		&& near(clip.layers[0].keyframes[0].dots[0].angle, 0.4f) && clip.layers[0].weight == 0.5f,
		"the keyed layer is not at the bottom of the stack");

	// Replace merges: only the named fields change.
	String replaced = call_set_layer(f, `{"clip":"Base","op":"replace","name":"tail","layer":{"mute":true,"amplitude":0.6}}`, &ok);
	defer replaced.free(mem);
	test::@check(ok, "replace refused: %s", replaced);
	clip = f.app.clip(f.ref);
	test::@check(clip.layers[1].mute && clip.layers[1].amplitude == 0.6f && clip.layers[1].cycles == 2.0f && clip.layers[1].joint == "a",
		"replace lost fields it was not given");
	test::@check(f.app.undo() && !f.app.clip(f.ref).layers[1].mute, "the replace was not one undo step");
	test::@check(f.app.redo(), "replace redo");

	// Move the top layer to the bottom.
	String moved = call_set_layer(f, `{"clip":"Base","op":"move","name":"tail","to":0}`, &ok);
	defer moved.free(mem);
	test::@check(ok, "move refused: %s", moved);
	clip = f.app.clip(f.ref);
	test::@check(clip.layers[0].name == "tail" && clip.layers[1].name == "nod", "move did not reorder");
	test::@check(f.app.undo() && f.app.clip(f.ref).layers[0].name == "nod", "the move was not one undo step");
	test::@check(f.app.redo(), "move redo");

	// Remove.
	String removed = call_set_layer(f, `{"clip":"Base","op":"remove","index":0}`, &ok);
	defer removed.free(mem);
	test::@check(ok, "remove refused: %s", removed);
	clip = f.app.clip(f.ref);
	test::@check(clip.layers.len == 1 && clip.layers[0].name == "nod", "remove took the wrong layer");
	test::@check(f.app.undo() && f.app.clip(f.ref).layers.len == 2, "the remove was not one undo step");

	// Refusals change nothing.
	String bad = call_set_layer(f, `{"clip":"Base","op":"add","layer":{"name":"x","kind":"wave","joint":"nowhere"}}`, &ok);
	defer bad.free(mem);
	test::@check(!ok && bad.contains("not a dot"), "an unknown joint was accepted: %s", bad);
	String heavy = call_set_layer(f, `{"clip":"Base","op":"add","layer":{"name":"x","kind":"wave","joint":"a","weight":3}}`, &ok);
	defer heavy.free(mem);
	test::@check(!ok, "a weight of 3 was accepted");
	test::@check(f.app.clip(f.ref).layers.len == 2, "a refusal changed the stack");

	// get_clip reports the stack and apply_clip keeps it when it has no `layers`.
	DString detail = dstring::new(mem);
	defer detail.free();
	String? read = crig::clip_json(&f.app, "Base", &detail);
	if (catch read)
	{
		test::@check(false, "get_clip refused: %s", detail.str_view());
		return;
	}
	defer read.free(mem);
	test::@check(read.contains(`"layers":[`) && read.contains(`"name":"nod"`), "get_clip does not report the layers");
}

fn void merge_layers_bakes_the_stack_into_keys_in_one_undo_step() @test
{
	ToolFixture fixture;
	fixture.open();
	defer fixture.app.free();
	ToolFixture* f = &fixture;
	bool ok;
	String added = call_set_layer(f, `{"clip":"Base","layer":{"name":"tail","kind":"wave","joint":"a","axis":[1,0,0],"amplitude":0.3,"cycles":2,"lag":0.1}}`, &ok);
	defer added.free(mem);
	String muted = call_set_layer(f, `{"clip":"Base","layer":{"name":"off","kind":"wave","joint":"b","amplitude":0.9,"mute":true}}`, &ok);
	defer muted.free(mem);
	test::@check(ok && f.app.clip(f.ref).layers.len == 2, "could not build the stack");

	// What the layered clip looks like, to compare the merge with.
	rig::Skeleton skeleton = small_rig();
	rig::Pose[9] expected;
	AnimTemplate* layered = f.app.clip(f.ref);
	for (usz i = 0; i < 9; i++) expected[i] = layered.pose(mem, &skeleton, rig_names[..], (float)i / 8.0f, false);
	defer foreach (&p : expected) p.free(mem);

	Object* args = args_of(`{"clip":"Base"}`);
	defer args.free();
	DString detail = dstring::new(mem);
	defer detail.free();
	String? merged = crig::merge_layers_json(&f.app, args, &detail);
	if (catch merged)
	{
		test::@check(false, "merge refused: %s", detail.str_view());
		return;
	}
	defer merged.free(mem);

	AnimTemplate* flat = f.app.clip(f.ref);
	test::@check(flat.layers.len == 0, "the stack was not cleared");
	test::@check(flat.keyframes.len > 2, "the keys were not baked (%d)", flat.keyframes.len);
	for (usz i = 0; i < 9; i++)
	{
		rig::Pose got = flat.pose(mem, &skeleton, rig_names[..], (float)i / 8.0f, false);
		defer got.free(mem);
		for (usz j = 0; j < 5; j++)
		{
			test::@check(same_rotation(expected[i].rotations[j], got.rotations[j], 1.0e-3f),
				"%s differs after the merge at t=%.3f", rig_names[j], (float)i / 8.0f);
		}
	}

	test::@check(f.app.undo(), "the merge did not undo");
	test::@check(f.app.clip(f.ref).layers.len == 2 && f.app.clip(f.ref).keyframes.len == 2,
		"one undo did not restore the stack and the base keys");

	// Nothing to merge is refused.
	f.app.undo();
	f.app.undo();
	DString why = dstring::new(mem);
	defer why.free();
	String? nothing = crig::merge_layers_json(&f.app, args, &why);
	test::@check(@failed(nothing) && why.str_view().contains("no layers"), "a clip without layers was merged");
}

fn void apply_clip_keeps_the_stack_unless_it_states_one() @test
{
	ToolFixture fixture;
	fixture.open();
	defer fixture.app.free();
	ToolFixture* f = &fixture;
	bool ok;
	String added = call_set_layer(f, `{"clip":"Base","layer":{"name":"tail","kind":"wave","joint":"a","amplitude":0.3}}`, &ok);
	defer added.free(mem);

	DString detail = dstring::new(mem);
	defer detail.free();
	Object* rewrite = args_of(`{"name":"Base","duration":1,"keyframes":[{"time":0,"joints":[{"name":"a","rotation":{"axis":[0,1,0],"angle":0.1}}]}]}`);
	defer rewrite.free();
	AnimTemplate? rewritten = crig::parse_clip(&f.app, rewrite, &detail);
	if (catch rewritten) { test::@check(false, "apply_clip refused: %s", detail.str_view()); return; }
	AnimTemplate kept = rewritten;
	defer kept.free(mem);
	test::@check(kept.layers.len == 1 && kept.layers[0].name == "tail", "apply_clip dropped the clip's layers");

	Object* cleared = args_of(`{"name":"Base","duration":1,"keyframes":[{"time":0,"joints":[{"name":"a","rotation":{"axis":[0,1,0],"angle":0.1}}]}],"layers":[]}`);
	defer cleared.free();
	AnimTemplate? emptied = crig::parse_clip(&f.app, cleared, &detail);
	if (catch emptied) { test::@check(false, "apply_clip refused an empty layers array"); return; }
	AnimTemplate none = emptied;
	defer none.free(mem);
	test::@check(none.layers.len == 0, "an empty layers array did not clear the stack");

	Object* stated = args_of(`{"name":"Other","duration":1,"keyframes":[{"time":0,"joints":[{"name":"a","rotation":{"axis":[0,1,0],"angle":0.1}}]}],"layers":[{"name":"p","kind":"pulse","joint":"b","amplitude":0.2,"at":0.5,"width":0.1}]}`);
	defer stated.free();
	AnimTemplate? with_layer = crig::parse_clip(&f.app, stated, &detail);
	if (catch with_layer) { test::@check(false, "apply_clip refused its layers: %s", detail.str_view()); return; }
	AnimTemplate have = with_layer;
	defer have.free(mem);
	test::@check(have.layers.len == 1 && have.layers[0].kind == PULSE && have.layers[0].width == 0.1f, "apply_clip did not read its layers");
}
