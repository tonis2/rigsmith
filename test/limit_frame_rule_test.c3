<*
 The near-axis roll rule for derived limit frames (`core/joint_limits.c3`
 `frame_seed`), the pin an older session's tables get on load, and the shipped
 humanoid's hand read on it.

     `c3c test --trust=full --test-filter crig_tests::limit_frame_rule`
*>
module crig_tests::limit_frame_rule;

import crig;
import rig;
import std::core::test;
import std::math;

const String HUMANOID = "assets/animations/humanoid.glb";

fn crig::JointLimitFrame frame_of(crig::RigDocument* doc, uint id)
{
	uint[] ids;
	rig::Skeleton skeleton = crig::build_skeleton(doc, mem, &ids)!!;
	defer
	{
		skeleton.free(mem);
		alloc::free(mem, ids);
	}
	return crig::joint_limit_frame(&skeleton, ids, doc.rotation_limits_of(id));
}

// A wrist and four fingers held out along +X, each leaning a degree or two
// another way, as placed fingers do.
fn void fingers_leaning_by_a_degree_share_their_axes() @test
{
	crig::AppState app = crig::new_app({});
	defer app.free();
	crig::RigDocument* doc = &app.doc;
	uint wrist = doc.add_dot({ 0, 1, 0 }, "wrist");
	Vec3[4] leans = { { 0.1f, -0.003f, 0.007f }, { 0.1f, -0.003f, 0.0f }, { 0.1f, -0.004f, -0.007f }, { 0.1f, 0.0f, -0.013f } };
	foreach (usz i, lean : leans)
	{
		Vec3 base = { 0.1f, 1.0f, 0.02f - 0.015f * (float)i };
		uint knuckle = doc.add_dot(base, "knuckle");
		uint tip = doc.add_dot(base + lean, "tip");
		doc.connect(wrist, knuckle);
		doc.connect(knuckle, tip);
		crig::JointRotationLimits limits = crig::unconstrained_rotation(knuckle);
		limits.constrained = true;
		test::@check(doc.set_rotation_limits(knuckle, limits), "the table did not land");
		Vec3 x = frame_of(doc, knuckle).axis(X);
		test::@check(x.z > 0.99f, "finger %d's X is %s, not across the palm", i, x);
	}
}

// The other arms of the rule: a bone near Y or Z takes world X, one leaning
// further keeps the cardinal it leans on least.
fn void bones_near_y_or_z_take_world_x_and_leaning_ones_the_least_axis() @test
{
	crig::AppState app = crig::new_app({});
	defer app.free();
	crig::RigDocument* doc = &app.doc;
	Vec3[3] bones = { { 0.01f, -1.0f, 0.005f }, { 0.004f, 0.02f, 1.0f }, { 0.25f, -1.0f, 0.12f } };
	Vec3[3] seeds = { { 1, 0, 0 }, { 1, 0, 0 }, { 0, 0, 1 } };
	foreach (usz i, bone : bones)
	{
		Vec3 from = { 2.0f * (float)i, 2, 0 };
		uint joint = doc.add_dot(from, "joint");
		uint end = doc.add_dot(from + bone * 0.4f, "end");
		doc.connect(joint, end);
		crig::JointRotationLimits limits = crig::unconstrained_rotation(joint);
		limits.constrained = true;
		test::@check(doc.set_rotation_limits(joint, limits), "the table did not land");
		Vec3 x = frame_of(doc, joint).axis(X);
		test::@check(x.dot(seeds[i]) > 0.95f, "bone %d's X is %s, not along %s", i, x, seeds[i]);
	}
}

// A version 22 table on a bone the rule now rolls the other way comes back
// pinned to the axes it was written against; one the rule left alone, and the
// same table written today, stay derived.
fn void an_older_sessions_tables_keep_the_axes_they_were_written_on() @test
{
	crig::AppState app = crig::new_app({});
	defer app.free();
	crig::RigDocument* doc = &app.doc;
	uint knuckle = doc.add_dot({ 0, 1, 0 }, "knuckle");
	uint tip = doc.add_dot({ 0.1f, 0.997f, 0.007f }, "tip");
	uint hip = doc.add_dot({ 1, 1, 0 }, "hip");
	uint knee = doc.add_dot({ 1.25f, 0, 0.12f }, "knee");
	doc.connect(knuckle, tip);
	doc.connect(hip, knee);
	foreach (id : (uint[]){ knuckle, hip })
	{
		crig::JointRotationLimits limits = crig::unconstrained_rotation(id);
		limits.constrained = true;
		limits.axes[0] = { .allowed = true, .minimum = -1.5f, .maximum = 0.25f };
		test::@check(doc.set_rotation_limits(id, limits), "the table did not land");
	}
	Vec3 now = frame_of(doc, knuckle).axis(X);

	String text = crig::session_text(mem, doc, "hand.glb", limits: true);
	defer text.free(mem);
	test::@check(text.contains(`"version": 25`), "the session is not version 25");

	crig::RigDocument? current = crig::parse_session(mem, text);
	if (catch current) { test::@check(false, "today's session did not read"); return; }
	crig::RigDocument today = current;
	defer today.free();
	test::@check(!today.rotation_limits_of(knuckle).has_saved_frame, "a current table was pinned");

	String older = text.replace(mem, `"version": 25`, `"version": 22`);
	defer older.free(mem);
	crig::RigDocument? opened = crig::parse_session(mem, older);
	if (catch opened) { test::@check(false, "the version 22 session did not read"); return; }
	crig::RigDocument legacy = opened;
	defer legacy.free();
	crig::JointRotationLimits held = legacy.rotation_limits_of(knuckle);
	test::@check(held.has_saved_frame, "the knuckle's table was left to the new rule");
	Vec3 was = frame_of(&legacy, knuckle).axis(X);
	test::@check(math::abs(was.y) > 0.99f && math::abs(now.z) > 0.99f,
		"the knuckle's X was %s under version 22 and is %s now", was, now);
	test::@check(held.axes[0].minimum == -1.5f, "the pinned table lost its numbers");
	test::@check(!legacy.rotation_limits_of(hip).has_saved_frame, "a table the rule did not move was pinned");
}

// The shipped figure's fingers: every segment curls about its X, closing
// the hand both sides, and spreads only at the knuckle.
fn void the_humanoids_fingers_all_curl_about_x() @test
{
	rig::TriMesh? loaded = rig::load_gltf(mem, HUMANOID);
	if (catch loaded) { test::@check(false, "%s did not load", HUMANOID); return; }
	rig::TriMesh mesh = loaded;
	defer mesh.free(mem);
	crig::AppState app = crig::new_app(mesh, HUMANOID);
	defer app.free();
	app.adopt_source_rig();

	String[4] fingers = { "index", "middle", "ring", "pinky" };
	String[2] sides = { "L", "R" };
	foreach (side : sides)
	{
		foreach (finger : fingers)
		{
			for (int k = 1; k <= 3; k++)
			{
				String name = string::tformat("%s_%d_%s", finger, k, side);
				uint id = 0;
				foreach (dot : app.doc.dots.array_view()) if (dot.name == name) id = dot.id;
				test::@check(id != 0, "no %s", name);
				crig::JointRotationLimits table = app.doc.rotation_limits_of(id);
				test::@check(table.constrained && !table.has_saved_frame, "%s has no plain table", name);
				Vec3 x = frame_of(&app.doc, id).axis(X);
				test::@check(x.z > 0.95f, "%s's X is %s, not across the palm", name, x);
				crig::JointAxisLimit curl = table.axes[0];
				float closes = side == "L" ? -curl.minimum : curl.maximum;
				test::@check(curl.allowed && closes > 1.3f, "%s closes only %f about X", name, closes);
				test::@check(!table.axes[1].allowed, "%s twists", name);
				test::@check(table.axes[2].allowed == (k == 1), "%s %s sideways", name, k == 1 ? "does not spread" : "spreads");
			}
		}
	}
}
