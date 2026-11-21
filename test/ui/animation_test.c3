module crig_tests::ui;
import crig;
import libc;
import cui;
import cui::widgets;
import c3w;
import rig;
import gltf;
import collision;
import crig_tests::library;
import crig_tests::shared_app;
import std::core::test;
import std::io;
import std::math;

// ---------------------------------------------------------------------------
// Animation.
// 
// A palette of matrices is not something anyone can read, so every claim below
// is made about where the animation has put a *joint*: the palette maps a rest
// position to its posed one, so a joint's own rest position pushed through its
// own entry is where it now stands. That turns "the arms pop" and "the knee
// bends the wrong way" into arithmetic.

// Comfortably above a biped's joint count; the rig is fitted from a preset, so
// this is not a limit the checks below can drift past by accident.
const usz MAX_TEST_JOINTS = 32;

struct PosedRig
{
	usz count;
	String[MAX_TEST_JOINTS] names;
	Vec3[MAX_TEST_JOINTS] rest;
	Vec3[MAX_TEST_JOINTS] posed;
}

fn PosedRig posed_rig(Fixture* fixture)
{
	PosedRig out;

	Matrix4f[] palette = fixture.app.pose_palette;
	if (palette.len == 0) return out;

	uint[] dot_ids;
	rig::Skeleton? built = crig::build_skeleton(fixture.doc(), mem, &dot_ids);
	if (catch built) return out;
	rig::Skeleton skeleton = built;
	defer skeleton.free(mem);
	defer alloc::free(mem, dot_ids);

	foreach (usz i, joint : skeleton.joints)
	{
		if (i >= MAX_TEST_JOINTS || i >= palette.len) break;
		float[<4>] moved = palette[i].apply({ joint.x, joint.y, joint.z, 1.0f });
		out.rest[i] = joint;
		out.posed[i] = { moved.x, moved.y, moved.z };
		if (i < dot_ids.len)
		{
			crig::Dot* dot = fixture.doc().find(dot_ids[i]);
			if (dot) out.names[i] = dot.name;
		}
		out.count = i + 1;
	}
	return out;
}

<*
 The rig's vertical extent — what a template's offsets are scaled by, and the
 yardstick every distance below is quoted in, so the numbers mean the same thing
 whatever size the fixture's mesh is.
*>
fn float PosedRig.height(&self)
{
	if (self.count == 0) return 0.0f;
	float lowest  = self.rest[0].y;
	float highest = lowest;
	for (usz i = 0; i < self.count; i++)
	{
		if (self.rest[i].y < lowest) lowest = self.rest[i].y;
		if (self.rest[i].y > highest) highest = self.rest[i].y;
	}
	return highest - lowest;
}

fn sz PosedRig.joint_named(&self, String name)
{
	for (usz i = 0; i < self.count; i++)
	{
		if (self.names[i] == name) return (sz)i;
	}
	return -1;
}

<*
 A rig edit reaches a clip that is already playing.

 The binding is built when playback starts, and only `tick_animation`'s guarded
 rebind rebuilds it after that. Without it a dot added mid-clip would deform
 nothing until the clip was restarted — invisible rather than broken, since the
 mesh keeps moving, bound to the rig as it was.

 Asserted on the weights themselves. `skin_generation` says a rebind ran, not
 that it bound the rig the document now holds, so a rebind against a stale
 skeleton would advance the counter and pass any check written against it.
*>
fn void a_rig_edit_reaches_a_running_player() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("a dot added mid-clip:");
	fixture.reset();

	if (!fixture.app.apply_plan_named("biped"))
	{
		test::@check(false, "SKIPPED — no biped body plan in the library");
		return;
	}
	if (!fixture.app.start_animation_at(0))
	{
		test::@check(false, "SKIPPED — no clip to play");
		return;
	}

	usz weight_count = fixture.app.skin.weights.len;
	test::@check(weight_count > 0, "a clip starts on a bound skin");

	float[] before = alloc::new_array(mem, float, (sz)weight_count);
	defer alloc::free(mem, before);
	before[..] = fixture.app.skin.weights[..];
	uint bound = fixture.app.skin_generation;

	// Just inside one of the mesh's own vertices, which is what gives this check
	// something to see. Only a vertex's four strongest joints reach the binding,
	// and this fixture's mesh is an eight-corner cube: a dot placed out in the
	// middle of the rig is beaten at every one of those corners by the joints
	// already there, and the weights come back identical to the last float.
	rig::Bounds box = fixture.app.geometry.bounds();
	Vec3 centre = (box.min + box.max) * 0.5f;
	Vec3 corner = fixture.app.geometry.positions[0];

	uint extra = fixture.app.add_recorded(corner + (centre - corner) * 0.2f, "extra");
	fixture.app.connect_recorded(fixture.doc().root_id, extra);
	fixture.app.mark_rig_stale();

	fixture.app.tick_animation(0.01f);

	test::@check(fixture.app.animating, "the clip is still playing");
	test::@check(fixture.app.skin_generation != bound, "and the skin was rebound under it");

	bool changed = fixture.app.skin.weights.len != weight_count;
	if (!changed)
	{
		foreach (usz i, w : fixture.app.skin.weights)
		{
			if (w != before[i]) { changed = true; break; }
		}
	}
	test::@check(changed, "against the rig as it now is, without playback being restarted");

	fixture.app.stop_animation();
}

const crig::AnimKeyDot[] SPARSE_TURN = {
	{ .joint_name = PLAN_THIGH_L, .axis = { 1, 0, 0 }, .angle = 0.6f },
};

const crig::AnimKeyDot[] SPARSE_REST = {
	{ .joint_name = PLAN_THIGH_L, .axis = { 1, 0, 0 }, .angle = 0.0f },
};

const crig::AnimKeyframe[] SPARSE_FRAMES = {
	{ .time = 0.00f, .dots = SPARSE_TURN[..] },
	{ .time = 0.25f, .dots = SPARSE_REST[..] },
	{ .time = 0.50f, .dots = SPARSE_TURN[..] },
	{ .time = 0.75f, .dots = SPARSE_REST[..] },
	{ .time = 1.00f, .dots = SPARSE_TURN[..] },
};

const crig::AnimTemplate SPARSE_TEMPLATE = {
	.name = "Sparse",
	.duration = 1.0f,
	.keyframes = SPARSE_FRAMES[..],
	.loop = true,
};

fn void an_unnamed_joint_turns_back_to_rest() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("a joint a keyframe does not name:");

	fixture.reset();
	test::@check(fixture.app.apply_plan_named("biped"), "the biped body plan is on offer");
	fixture.ui.flush();

	fixture.app.start_animation(SPARSE_TEMPLATE);
	test::@check(fixture.app.animating, "the template plays");

	// One whole cycle, driven by hand rather than through the menu because this
	// template exists only here.
	// 
	// Watched across every joint, not the turned one: a joint's rotation is
	// about its own position, so turning it leaves it exactly where it was and
	// moves everything hanging off it. The shin is what shows the thigh.
	const usz STEPS   = 200;
	const float STEP  = 0.005f;
	PosedRig previous = posed_rig(fixture);
	test::@check(previous.joint_named(PLAN_THIGH_L) >= 0, "and the rig has the joint it turns");

	float largest_step = 0.0f;
	float swing        = 0.0f;

	for (usz s = 0; s < STEPS; s++)
	{
		fixture.app.tick_animation(STEP);
		PosedRig now = posed_rig(fixture);
		if (now.count == 0 || now.count != previous.count) break;

		for (usz j = 0; j < now.count; j++)
		{
			float moved = (now.posed[j] - previous.posed[j]).length();
			if (moved > largest_step) largest_step = moved;
			float from_rest = (now.posed[j] - now.rest[j]).length();
			if (from_rest > swing) swing = from_rest;
		}

		previous = now;
	}

	test::@check(swing > 0.0f, "the joint the template names does turn");
	test::@check(largest_step > 0.0f && largest_step < swing * 0.25f, "and turns back to rest rather than snapping there");

	fixture.app.stop_animation();

	// A template with no length has no instant to show, and looping one is a
	// subtract-until-inside loop that zero never gets out of. Both the door and
	// the clock have to refuse it — the second because a template can lose its
	// length while it is already playing.
	crig::AnimTemplate no_length = SPARSE_TEMPLATE;
	no_length.duration = 0.0f;
	fixture.app.start_animation(no_length);
	test::@check(!fixture.app.animating, "a template with no length is never started");

	fixture.app.start_animation(SPARSE_TEMPLATE);
	fixture.app.current_anim.duration = 0.0f;
	fixture.app.tick_animation(0.01f);
	test::@check(!fixture.app.animating, "and one that loses it mid-play stops instead of spinning");
}

// Nothing but a slide on the root, held for the whole cycle.
// 
// The angle is deliberately non-zero against an axis that is not there, which
// is the shape a template gets when someone writes a slide and leaves an angle
// beside it. It comes out as no rotation, because an axis of no length stays
// that way through `normalize` and a quaternion with no vector part is not a
// rotation of any size — so the drop below stays exactly vertical.
const float SLIDE_FRACTION = 0.1f;

const crig::AnimKeyDot[] SLIDE_ROOT = {
	{ .joint_name = PLAN_HIPS, .angle = 0.5f, .move = { 0, -SLIDE_FRACTION, 0 } },
};

const crig::AnimKeyframe[] SLIDE_FRAMES = {
	{ .time = 0.00f, .dots = SLIDE_ROOT[..] },
	{ .time = 1.00f, .dots = SLIDE_ROOT[..] },
};

const crig::AnimTemplate SLIDE_TEMPLATE = {
	.name = "Slide",
	.duration = 1.0f,
	.keyframes = SLIDE_FRAMES[..],
	.loop = true,
};

<*
 An offset is a fraction of the rig, not a distance.

 crig opens whatever .glb it is handed, and a template is a shape rather than a
 measurement — the same walk has to bob a figure modelled a unit tall and one
 modelled a hundred units tall by the same proportion. Asserted as an equality
 against the rig's own height rather than by loading two meshes, which is the
 claim itself rather than a consequence of it.
*>
fn void an_offset_scales_with_the_rig() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("a template's offsets scale to the rig:");

	fixture.reset();
	test::@check(fixture.app.apply_plan_named("biped"), "the biped body plan is on offer");
	fixture.ui.flush();

	fixture.app.start_animation(SLIDE_TEMPLATE);
	test::@check(fixture.app.animating, "the slide plays");

	PosedRig now = posed_rig(fixture);
	float height = now.height();
	if (now.count == 0 || height <= 0.0f)
	{
		test::@check(false, "SKIPPED — the rig has no height to scale against");
		return;
	}

	// Everything hangs off the root, so every joint travels the same way and by
	// the same amount. A rigid motion is the one shape an off-by-a-frame or a
	// mis-composed offset cannot fake.
	float expected = SLIDE_FRACTION * height;
	float worst    = 0.0f;
	for (usz j = 0; j < now.count; j++)
	{
		Vec3 wanted = now.rest[j] - (Vec3) { 0, expected, 0 };
		float off   = (now.posed[j] - wanted).length();
		if (off > worst) worst = off;
	}

	test::@check(worst < expected * 0.01f, "every joint drops by exactly the named fraction of the rig's height");

	fixture.app.stop_animation();
}
