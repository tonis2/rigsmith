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
// Editing the rig, and reading a clip back as numbers.

// How many dots the fixture starts with: hips, knee, foot and the unnamed one.
const sz FIXTURE_DOTS = 4;

<*
 A repair is one call and one undo step.

 Place a dot, name it, hang it off the foot. What the rig gains is three
 primitives, and what a user who does not like it has to press is Ctrl+Z once —
 which is the whole reason `edit_rig` takes a list rather than being seven tools.
*>
fn void a_batch_of_rig_edits_undoes_in_one_step() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? edited = f.call_tool("edit_rig",
		`{"ops":[{"op":"place","position":[0.5,0,0],"name":"toe","connect_to":"foot"}]}`);
	if (catch edited)
	{
		test::@check(false, "edit_rig places a dot");
		return;
	}
	defer edited.free();

	test::@check((edited.get_int("dots") ?? 0) == (int)FIXTURE_DOTS + 1,
		"after placing one dot the rig has %d", edited.get_int("dots") ?? -1);
	test::@check((edited.get_int("bones") ?? 0) == 3, "the new dot arrived with its bone");
	test::@check(f.app.has_dot_named("toe"), "the placed dot carries the name it was given");

	Object*? back = f.call_tool("undo", "{}");
	if (catch back)
	{
		test::@check(false, "undo answers");
		return;
	}
	defer back.free();

	test::@check((back.get_int("dots") ?? 0) == (int)FIXTURE_DOTS,
		"one undo left %d dots rather than %d", back.get_int("dots") ?? -1, FIXTURE_DOTS);
	test::@check((back.get_int("bones") ?? 0) == 2, "one undo left the bone behind");
	test::@check(!f.app.has_dot_named("toe"), "one undo left the name behind");
}

<*
 And the same for a batch of moves, which record differently.

 A placement is one primitive and its own edit; a move records where the dot was
 as well as where it went, so a group of them undoes only if every `before` was
 read before its own op ran. Two moves in one call is the smallest arrangement
 where reading them in the wrong order would still look right on the way in.
*>
fn void a_batch_of_moves_undoes_in_one_step() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Vec3 knee_was = f.app.doc.find(f.app.doc.dots[1].id).position;
	Vec3 foot_was = f.app.doc.find(f.app.doc.dots[2].id).position;

	Object*? moved = f.call_tool("edit_rig",
		`{"ops":[{"op":"move","joint":"knee","position":[0.2,0.5,0]},{"op":"move","joint":"foot","position":[0.3,0,0]}],"snap":false}`);
	if (catch moved)
	{
		test::@check(false, "edit_rig moves two dots");
		return;
	}
	moved.free();

	test::@check((f.app.doc.find(f.app.doc.dots[1].id).position - knee_was).length() > 0.1f,
		"the batch did not move the knee at all");

	Object*? back = f.call_tool("undo", "{}");
	if (catch back)
	{
		test::@check(false, "undo answers");
		return;
	}
	back.free();

	test::@check((f.app.doc.find(f.app.doc.dots[1].id).position - knee_was).length() < 1.0e-5f,
		"one undo left the knee where the batch put it");
	test::@check((f.app.doc.find(f.app.doc.dots[2].id).position - foot_was).length() < 1.0e-5f,
		"one undo took back only the last move of the batch");
}

<*
 edit_rig's grow sets the Weights card's Grow and Soft edge by number: the joint
 holds more without moving and keeps it as its own weights, get_skeleton
 reports both, and one undo takes the batch back.
*>
fn void a_grow_crosses_the_wire_and_undoes() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	uint knee = f.app.doc.dots[1].id;
	Vec3 was = f.app.doc.find(knee).position;

	f.call_tool("edit_rig", `{"ops":[{"op":"grow","joint":"knee","grow":0.1,"soft":0.8}]}`)!!.free();
	test::@check(math::abs(f.app.doc.find(knee).grow - 0.1f) < 1.0e-6f, "the grow came out as %.4f", f.app.doc.find(knee).grow);
	test::@check(math::abs(f.app.doc.find(knee).band - 0.8f) < 1.0e-6f, "the soft edge came out as %.4f", f.app.doc.find(knee).band);
	test::@check((f.app.doc.find(knee).position - was).length() < 1.0e-6f, "growing a joint moved it");

	Object* seen = f.call_tool("get_skeleton", "{}")!!;
	defer seen.free();
	bool reported = false;
	Object* dots = seen.get("dots")!!;
	for (sz i = 0; i < dots.get_len(); i++)
	{
		Object* entry = dots.get_at(i);
		if ((entry.get_string("name") ?? "") != "knee") continue;
		reported = math::abs((float)(entry.get_float("grow") ?? 0.0) - 0.1f) < 1.0e-6f
			&& math::abs((float)(entry.get_float("soft") ?? 0.0) - 0.8f) < 1.0e-6f;
	}
	test::@check(reported, "get_skeleton does not report the grow and soft edge");

	test::@check(f.app.weights_held(knee), "the grow did not write the knee's own weights");

	f.call_tool("undo", "{}")!!.free();
	test::@check(f.app.doc.find(knee).grow == 0.0f && f.app.doc.find(knee).band == 0.0f, "one undo did not take the grow back");
	test::@check(!f.app.weights_held(knee), "one undo left the knee's weights held");

	test::@check(f.refuses_tool("edit_rig", `{"ops":[{"op":"grow","joint":"knee","soft":5}]}`, "share of the bone"),
		"a soft edge past the range was not named back");
}

<*
 A reach travels the wire, changes the bind and undoes.

 The point of the op is that it changes what a dot holds *without moving it*, so
 the check is exactly that: the position is read before and after and has to be
 the same, while the reach shows up on the dot and in what `get_skeleton`
 reports. That pairing is the whole feature — before it, the only way to stop a
 dot pulling on mesh it should not was to drag the joint somewhere it does not
 belong.
*>
fn void a_reach_crosses_the_wire_and_undoes() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	uint knee = f.app.doc.dots[1].id;
	Vec3 was = f.app.doc.find(knee).position;

	Object*? set = f.call_tool("edit_rig", `{"ops":[{"op":"reach","joint":"knee","reach":0.25}]}`);
	if (catch set)
	{
		test::@check(false, "edit_rig sets a reach");
		return;
	}
	set.free();

	test::@check(math::abs(f.app.doc.find(knee).reach - 0.25f) < 1.0e-6f,
		"the reach came out as %.4f", f.app.doc.find(knee).reach);
	test::@check((f.app.doc.find(knee).position - was).length() < 1.0e-6f,
		"setting a reach moved the dot, which is the thing it exists to avoid");

	Object*? seen = f.call_tool("get_skeleton", "{}");
	if (catch seen)
	{
		test::@check(false, "get_skeleton answers");
		return;
	}
	defer seen.free();

	bool reported = false;
	Object* dots = seen.get("dots")!!;
	for (sz i = 0; i < dots.get_len(); i++)
	{
		Object* entry = dots.get_at(i);
		if ((entry.get_string("name") ?? "") != "knee") continue;
		reported = math::abs((float)(entry.get_float("reach") ?? 0.0) - 0.25f) < 1.0e-6f;
	}
	test::@check(reported, "get_skeleton does not report the reach it was just given");

	Object*? back = f.call_tool("undo", "{}");
	if (catch back)
	{
		test::@check(false, "undo answers");
		return;
	}
	back.free();

	test::@check(f.app.doc.find(knee).reach == 0.0f,
		"one undo left the reach at %.4f", f.app.doc.find(knee).reach);
}

<*
 A complete local-axis table crosses edit_rig, is read back by get_skeleton,
 and remains one history step. Numbers are deliberately uneven so a swapped
 axis or a dropped parked value cannot pass as a plausible default.
*>
fn void joint_limits_cross_the_wire_read_back_and_undo() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? set = f.call_tool("edit_rig", `{"ops":[{"op":"limits","joint":"knee","x":{"allow":true,"minimum":-0.125,"maximum":2.375,"locked":0.25},"y":{"allow":false,"minimum":-0.5,"maximum":0.75,"locked":0.0625},"z":{"allow":false,"minimum":-0.25,"maximum":0.25,"locked":-0.03125},"primary_child":"foot"}]}`);
	if (catch set)
	{
		test::@check(false, "edit_rig refused a valid limit table");
		return;
	}
	set.free();

	uint knee = f.app.doc.dots[1].id;
	crig::JointRotationLimits held = f.app.doc.rotation_limits_of(knee);
	test::@check(held.constrained && held.primary_child == f.app.doc.dots[2].id,
		"the active state or primary child did not land");
	test::@check(held.axes[0].allowed && math::abs(held.axes[0].maximum - 2.375f) < 1.0e-6f
		&& !held.axes[1].allowed && math::abs(held.axes[1].locked - 0.0625f) < 1.0e-6f,
		"axis values changed on the way into the document");

	Object*? skeleton = f.call_tool("get_skeleton", `{}`);
	if (catch skeleton)
	{
		test::@check(false, "get_skeleton did not read limits back");
		return;
	}
	defer skeleton.free();
	Object* dot = skeleton_dot(skeleton, "knee");
	Object* limits = dot == null ? null : crig::member(dot, "limits");
	bool reported = limits != null && (limits.get_bool("active") ?? false)
		&& (limits.get_string("primary_child") ?? "") == "foot";
	if (reported)
	{
		Object* x = limits.get("x")!!;
		Object* y = limits.get("y")!!;
		reported = (x.get_bool("allow") ?? false)
			&& math::abs((float)(x.get_float("maximum") ?? 0.0) - 2.375f) < 1.0e-6f
			&& !(y.get_bool("allow") ?? true)
			&& math::abs((float)(y.get_float("locked") ?? 0.0) - 0.0625f) < 1.0e-6f;
	}
	test::@check(reported, "get_skeleton did not return the complete stored table");

	Object*? undone = f.call_tool("undo", `{}`);
	if (catch undone)
	{
		test::@check(false, "the limit edit would not undo");
		return;
	}
	undone.free();
	test::@check(!f.app.doc.rotation_limits_of(knee).constrained
		&& f.app.doc.rotation_limits.len() == 0,
		"one undo left the joint constrained");

	Object*? redone = f.call_tool("redo", `{}`);
	if (catch redone)
	{
		test::@check(false, "the limit edit would not redo");
		return;
	}
	redone.free();
	test::@check(f.app.doc.rotation_limits_of(knee).constrained,
		"redo did not restore the limit table");

	Object*? reset = f.call_tool("edit_rig",
		`{"ops":[{"op":"limits","joint":"knee","reset":true}]}`);
	if (catch reset)
	{
		test::@check(false, "edit_rig would not reset a limit table");
		return;
	}
	reset.free();
	test::@check(f.app.doc.rotation_limits.len() == 0,
		"reset left a sparse limit entry behind");
	Object*? restored = f.call_tool("undo", `{}`);
	if (catch restored)
	{
		test::@check(false, "the reset would not undo");
		return;
	}
	restored.free();
	test::@check(f.app.doc.rotation_limits_of(knee).constrained,
		"undoing reset did not restore the table");
}

<*
 A collision exclusion crosses edit_rig either way round, is listed by
 get_skeleton by name, is one history step, and is refused for one joint
 against itself.
*>
fn void collision_exclusions_cross_the_wire_read_back_and_undo() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;
	uint hips = f.app.doc.dots[0].id;
	uint foot = f.app.doc.dots[2].id;

	Object*? excluded = f.call_tool("edit_rig", `{"ops":[{"op":"exclude","a":"foot","b":"hips"}]}`);
	if (catch excluded)
	{
		test::@check(false, "edit_rig refused a valid exclusion");
		return;
	}
	excluded.free();
	test::@check(f.app.doc.has_exclusion(hips, foot), "the exclusion did not land");
	test::eq(f.app.doc.collision_exclusions.len(), (sz)1);

	Object*? skeleton = f.call_tool("get_skeleton", `{}`);
	if (catch skeleton)
	{
		test::@check(false, "get_skeleton did not read the exclusion back");
		return;
	}
	defer skeleton.free();
	Object*? listed = skeleton.get("exclusions");
	bool reported = false;
	if (try list = listed)
	{
		reported = list.get_len() == 1
			&& (list.get_at(0).get_string("a") ?? "") == "foot"
			&& (list.get_at(0).get_string("b") ?? "") == "hips";
	}
	test::@check(reported, "get_skeleton did not list the exclusion by name, foot then hips as it was given");

	// Reaching the asked-for state again records nothing.
	Object*? again = f.call_tool("edit_rig", `{"ops":[{"op":"exclude","a":"hips","b":"foot"}]}`);
	if (catch again)
	{
		test::@check(false, "excluding the same pair reversed was refused");
		return;
	}
	again.free();
	test::eq(f.app.doc.collision_exclusions.len(), (sz)1);

	// get_scene says how the check stands, so a tool whose pose came back
	// short can tell a blocked joint from an unreachable target.
	Object*? scene = f.call_tool("get_scene", `{}`);
	if (catch scene)
	{
		test::@check(false, "get_scene failed with an exclusion set");
		return;
	}
	defer scene.free();
	// Described whether or not the system is switched on — a tool reading a
	// pose that came back short needs to know which — and the switch itself
	// is the first thing said.
	Object*? collision = scene.get("collision");
	bool described = false;
	if (try state = collision)
	{
		described = !(state.get_bool("enabled") ?? true)
			&& (state.get_bool("prevent") ?? false)
			&& math::abs((float)(state.get_float("clearance") ?? 0.0) - crig::COLLISION_CLEARANCE) < 1.0e-6f
			&& (state.get_string("mode") ?? "") == "full";
	}
	test::@check(described, "get_scene does not describe the collision check, or reports the switch on");
	f.app.set_self_collision(true);
	Object*? switched = f.call_tool("get_scene", `{}`);
	if (try on = switched)
	{
		defer on.free();
		Object*? live = on.get("collision");
		bool switched_on = false;
		if (try state = live) switched_on = state.get_bool("enabled") ?? false;
		test::@check(switched_on, "get_scene does not report the switch on");
	}

	Object*? undone = f.call_tool("undo", `{}`);
	if (catch undone)
	{
		test::@check(false, "the exclusion would not undo");
		return;
	}
	undone.free();
	test::@check(!f.app.doc.has_exclusion(hips, foot), "one undo left the exclusion in place");

	Object*? redone = f.call_tool("redo", `{}`);
	if (catch redone)
	{
		test::@check(false, "the exclusion would not redo");
		return;
	}
	redone.free();
	test::@check(f.app.doc.has_exclusion(hips, foot), "redo did not restore the exclusion");

	Object*? included = f.call_tool("edit_rig", `{"ops":[{"op":"include","a":"hips","b":"foot"}]}`);
	if (catch included)
	{
		test::@check(false, "edit_rig refused to include the pair again");
		return;
	}
	included.free();
	test::@check(f.app.doc.collision_exclusions.len() == 0, "include left the exclusion behind");

	Object*? plain = f.call_tool("get_skeleton", `{}`);
	if (catch plain)
	{
		test::@check(false, "get_skeleton failed after the include");
		return;
	}
	defer plain.free();
	if (try leftover = plain.get("exclusions"))
	{
		test::@check(false, "an unexcluded rig still lists exclusions: %d", leftover.get_len());
	}

	test::@check(f.refuses_tool("edit_rig", `{"ops":[{"op":"exclude","a":"knee","b":"knee"}]}`, "against itself"),
		"a joint excluded against itself was accepted, or refused without saying why");
	test::@check(f.app.doc.collision_exclusions.len() == 0, "a self-exclusion was stored");
	test::@check(f.refuses_tool("edit_rig", `{"ops":[{"op":"exclude","a":"knee"}]}`, `needs "a" and "b"`),
		"an exclusion missing its other joint was accepted, or refused without naming the fields");
}

<*
 bone_axes moves a table pinned to a frame of its own onto its bone's axes over
 the wire, its swing rows traded by the quarter turn between the two, as one
 undo step. Beside clear_frame it is refused, and changes nothing.

 Re-introduce: drop the `bone_axes` read from `op_limits`, and the call is
 refused as given nothing to change.
*>
fn void bone_axes_moves_a_pinned_table_onto_the_bones_axes() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;
	uint knee = f.app.doc.dots[1].id;

	crig::JointRotationLimits table = crig::unconstrained_rotation(knee);
	table.constrained = true;
	table.axes[0] = { .allowed = true, .minimum = -0.25f, .maximum = 1.5f };
	table.axes[2] = { .allowed = false };
	crig::RigView view = f.app.open_rig(mem)!!;
	crig::JointLimitFrame derived = crig::joint_limit_frame(&view.skeleton, view.dot_ids, table);
	view.free(mem);
	table.has_saved_frame = true;
	table.saved_frame = derived.rotation.mul(quaternion::from_axis_angle{float}({ 0, 1, 0 },
		(float)math::PI * 0.5f)).normalize();
	test::@check(f.app.set_rotation_limits_recorded(knee, table), "the pinned table did not land");
	f.app.undo_stack.commit();

	test::@check(f.refuses_tool("edit_rig",
		`{"ops":[{"op":"limits","joint":"knee","bone_axes":true,"clear_frame":true}]}`, "bone_axes", "clear_frame"),
		"bone_axes beside clear_frame was accepted, or refused without naming both");
	test::@check(f.app.doc.rotation_limits_of(knee).has_saved_frame, "a refused call dropped the frame");

	Object*? moved = f.call_tool("edit_rig", `{"ops":[{"op":"limits","joint":"knee","bone_axes":true}]}`);
	if (catch moved)
	{
		test::@check(false, "edit_rig refused bone_axes on a pinned table");
		return;
	}
	moved.free();
	crig::JointRotationLimits held = f.app.doc.rotation_limits_of(knee);
	test::@check(!held.has_saved_frame, "bone_axes left the frame saved");
	test::@check(!held.axes[0].allowed && held.axes[2].allowed
		&& held.axes[2].minimum == -1.5f && held.axes[2].maximum == 0.25f,
		"the swing rows did not trade by the quarter turn");

	Object*? undone = f.call_tool("undo", `{}`);
	if (catch undone)
	{
		test::@check(false, "bone_axes would not undo");
		return;
	}
	undone.free();
	test::@check(f.app.doc.rotation_limits_of(knee).has_saved_frame, "one undo did not bring the frame back");
}

fn void joint_limits_refuse_invalid_ranges_and_take_a_forks_own_child() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	test::@check(f.refuses_tool("edit_rig",
		`{"ops":[{"op":"limits","joint":"knee","x":{"minimum":1,"maximum":-1}}]}`,
		"minimum", "above", "maximum"),
		"an inverted range did not explain why it was refused");
	test::@check(f.app.doc.rotation_limits.len() == 0 && !f.app.undo_stack.can_undo(),
		"a refused range changed the document or history");

	// Turn hips into a fork. Limits there need no primary child: the root's axes
	// follow the child leading the most of the rig, the knee, not the new leaf.
	uint branch = f.app.doc.add_dot({ 0.5f, 0.75f, 0 }, "branch");
	f.app.doc.connect(f.app.doc.dots[0].id, branch);
	Object*? set = f.call_tool("edit_rig",
		`{"ops":[{"op":"limits","joint":"hips","x":{"allow":true,"minimum":-1,"maximum":1}}]}`);
	if (catch set)
	{
		test::@check(false, "a branching joint's limits were refused");
		return;
	}
	defer set.free();
	crig::RigView view = f.app.open_rig(mem)!!;
	defer view.free(mem);
	crig::JointRotationLimits held = f.app.doc.rotation_limits_of(f.app.doc.dots[0].id);
	crig::JointLimitFrame frame = crig::joint_limit_frame(&view.skeleton, view.dot_ids, held);
	test::@check(held.constrained && held.primary_child == 0 && frame.usable()
		&& frame.direction_dot == f.app.doc.dots[1].id,
		"the fork's axes did not follow the knee (%s, dot %d)", frame.status, frame.direction_dot);
}

<*
 A blend sharpness crosses the wire, undoes in one step, and is refused outside
 the band the arithmetic survives.

 The op that names no joint. It is the only entry in `edit_rig` that is a
 property of the model rather than of a dot, so the check is that it lands
 without one — and that a caller working from a wrong idea of the scale is told
 the range rather than quietly clamped, which is the difference between "you
 asked for something that does not exist" and "your call did something other
 than what you asked for".
*>
fn void a_blend_sharpness_crosses_the_wire_and_undoes() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	test::@check(f.app.doc.sharpness == 0.0f, "the fixture rig starts with a sharpness set");

	Object*? set = f.call_tool("edit_rig", `{"ops":[{"op":"sharpness","value":2}]}`);
	if (catch set)
	{
		test::@check(false, "edit_rig sets a blend sharpness");
		return;
	}
	set.free();

	test::@check(math::abs(f.app.doc.sharpness - 2.0f) < 1.0e-6f,
		"the sharpness came out as %.4f", f.app.doc.sharpness);

	Object*? back = f.call_tool("undo", "{}");
	if (catch back)
	{
		test::@check(false, "undo answers");
		return;
	}
	back.free();

	test::@check(f.app.doc.sharpness == 0.0f,
		"one undo left the sharpness at %.4f rather than back at unset", f.app.doc.sharpness);

	// Out of range, and the sentence carries the range — an agent that guessed a
	// percentage or an exponent in the tens can correct itself from the refusal.
	test::@check(f.refuses_tool("edit_rig", `{"ops":[{"op":"sharpness","value":10}]}`, "ops[0]", "0.25 to 4"),
		"a sharpness of 10 is refused, naming the band it fell outside");
	test::@check(f.app.doc.sharpness == 0.0f, "the refused call left a sharpness behind");

	// And the op needs its number: `joint` is not read here, so a call carrying
	// only a joint has said nothing.
	test::@check(f.refuses_tool("edit_rig", `{"ops":[{"op":"sharpness","joint":"knee"}]}`, "ops[0]", "value"),
		"a sharpness op with no value is refused, and says which key it wanted");
}

<*
 A knuckle blend crosses the wire, undoes in one step back to unset, and is
 refused outside 0 to 1 with the range in the refusal — the other op that names
 no joint, on the sharpness's terms.
*>
fn void a_knuckle_blend_crosses_the_wire_and_undoes() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	test::@check(f.app.doc.knuckle_blend == 0.0f, "the fixture rig starts with a knuckle blend set");

	Object*? set = f.call_tool("edit_rig", `{"ops":[{"op":"knuckle_blend","value":0}]}`);
	if (catch set)
	{
		test::@check(false, "edit_rig sets a knuckle blend");
		return;
	}
	set.free();
	test::@check(f.app.doc.knuckle_blend_fraction() == 0.0f && f.app.doc.knuckle_blend > 0.0f,
		"a blend of 0 came out as %.4f (stored %.4f)", f.app.doc.knuckle_blend_fraction(), f.app.doc.knuckle_blend);

	Object*? back = f.call_tool("undo", "{}");
	if (catch back)
	{
		test::@check(false, "undo answers");
		return;
	}
	back.free();
	test::@check(f.app.doc.knuckle_blend == 0.0f,
		"one undo left the knuckle blend stored as %.4f rather than unset", f.app.doc.knuckle_blend);

	test::@check(f.refuses_tool("edit_rig", `{"ops":[{"op":"knuckle_blend","value":25}]}`, "ops[0]", "runs from 0"),
		"a knuckle blend of 25 is refused, naming the range it fell outside");
	test::@check(f.app.doc.knuckle_blend == 0.0f, "the refused call left a knuckle blend behind");
	test::@check(f.refuses_tool("edit_rig", `{"ops":[{"op":"knuckle_blend"}]}`, "ops[0]", "value"),
		"a knuckle blend op with no value is refused, and says which key it wanted");
}

<*
 A shell pinned over the wire is one undo step, and `get_shells` says so.

 The pin already existed for the mouse — `pin_shell` commits its own group — so
 what is being checked here is the uncommitted half: a batch has to be able to
 pin without closing the group under itself, or a repair made of two pins takes
 two Ctrl+Z to undo.
*>
fn void a_pinned_shell_is_one_edit_rig_batch() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	if (f.app.shells.count == 0)
	{
		test::@check(false, "the fixture mesh has no pieces to pin");
		return;
	}

	Object*? pinned = f.call_tool("edit_rig", `{"ops":[{"op":"attach","shell":0,"joint":"knee"}]}`);
	if (catch pinned)
	{
		test::@check(false, "edit_rig pins a shell");
		return;
	}
	pinned.free();

	uint knee = f.app.doc.dots[1].id;
	test::@check(f.app.doc.attachment_of(0) == knee, "the pin did not take");

	Object*? listed = f.call_tool("get_shells", "{}");
	if (catch listed)
	{
		test::@check(false, "get_shells answers");
		return;
	}
	defer listed.free();

	test::@check((listed.get_int("pieces") ?? 0) > 0, "get_shells reports no pieces at all");

	Object*? back = f.call_tool("undo", "{}");
	if (catch back)
	{
		test::@check(false, "undo answers");
		return;
	}
	back.free();

	test::@check(f.app.doc.attachment_of(0) == 0, "one undo left the shell pinned");
}

<*
 A batch that fails part-way leaves the rig where it found it.

 The first op is good and the second names a joint that does not exist. Without
 the rollback the call refuses *and* the rig keeps the first op, which is the
 worst of both — a caller told nothing happened, looking at a rig where something
 did.
*>
fn void a_refused_batch_changes_nothing() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	test::@check(f.refuses_tool("edit_rig",
		`{"ops":[{"op":"place","position":[0.5,0,0],"name":"toe"},{"op":"name","joint":"elbow","name":"shin"}]}`,
		"ops[1]", "elbow"),
		"a batch naming a joint the rig lacks is refused, and says which op and which joint");

	test::@check(f.app.doc.dots.len() == FIXTURE_DOTS,
		"the refused batch left %d dots behind", f.app.doc.dots.len());
	test::@check(!f.app.has_dot_named("toe"), "the refused batch left its first op applied");
}

<*
 The loop that was impossible before: name a dot, then animate it.

 A clip addresses joints by name and a hand-placed dot carries none, so the
 fixture's fourth dot could be seen, surveyed and pointed at — and never moved.
*>
fn void a_clip_can_address_a_dot_the_wire_just_named() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	uint free_dot = f.app.doc.dots[(usz)FIXTURE_DOTS - 1].id;
	String call = string::format(mem, `{"ops":[{"op":"name","joint":"bone_%d","name":"tail"}]}`, free_dot);
	defer alloc::free(mem, call.ptr);

	Object*? named = f.call_tool("edit_rig", call);
	if (catch named)
	{
		test::@check(false, "edit_rig names an unnamed dot through its bone_<id> address");
		return;
	}
	named.free();

	String arguments = bend_clip("Wag", QUARTER_TURN_AXIS);
	defer alloc::free(mem, arguments);
	String tail = arguments.treplace("knee", "tail");

	String message = string::format(
		mem,
		`{"jsonrpc":"2.0","id":40,"method":"tools/call","params":{"name":"apply_clip","arguments":%s}}`,
		tail);
	defer alloc::free(mem, message);

	Object*? root = f.request(message);
	if (catch root)
	{
		test::@check(false, "apply_clip answers for the newly named joint");
		return;
	}
	defer root.free();
	test::@check(root.get("result") ?? null, "a clip can now turn a dot that had no name to turn by");
}

<*
 A ground spec is refused in the same voice a keyframe is: naming the value.

 Three ways to get it wrong, and each has to say which one it was. A phase given
 in seconds is the one that will actually happen — every other time on this
 surface is seconds, and the windows are the exception.
*>
fn void a_bad_ground_spec_names_the_value() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	test::@check(f.refuses_tool("apply_clip",
		`{"name":"Step","keyframes":[{"time":0,"joints":[{"name":"knee","rotation":[0.2,0,0]}]}],"duration":1,"ground":{"feet":[{"joint":"heel","down":0,"up":0.4}]}}`,
		"heel", "not a dot on this rig"),
		"a foot naming no dot is refused and says so");

	test::@check(f.refuses_tool("apply_clip",
		`{"name":"Step","keyframes":[{"time":0,"joints":[{"name":"knee","rotation":[0.2,0,0]}]}],"duration":1,"ground":{"feet":[{"joint":"foot","down":0,"up":1.4}]}}`,
		"cycle phase", "not seconds"),
		"a window given in seconds is refused and says what a window is in");

	test::@check(f.refuses_tool("apply_clip",
		`{"name":"Step","keyframes":[{"time":0,"joints":[{"name":"knee","rotation":[0.2,0,0]}]}],"duration":1,"blend":"cubic"}`,
		"blend", "smooth"),
		"a blend that is neither mode is refused and names the two that are");
}

<*
 measure_clip agrees with what get_pose shows.

 The metrics exist so an agent does not have to make fifty round trips to work
 out whether a foot is sliding; if they disagreed with the fifty round trips they
 would be worse than nothing.
*>
fn void measure_answers_what_get_pose_would() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	String arguments = bend_clip("Bend", QUARTER_TURN_AXIS);
	defer alloc::free(mem, arguments);
	Object*? applied = f.call_tool("apply_clip", arguments);
	if (catch applied)
	{
		test::@check(false, "apply_clip takes the clip to measure");
		return;
	}
	applied.free();

	Object*? measured = f.call_tool("measure_clip", `{"clip":"Bend","samples":16}`);
	if (catch measured)
	{
		test::@check(false, "measure_clip answers");
		return;
	}
	defer measured.free();

	// The foot hangs off the knee the clip turns, so its travel is the one number
	// the fixture can be asked for and checked against a pose.
	double reported = 0;
	Object* rows = measured.get("joints")!!;
	for (sz i = 0; i < rows.get_len(); i++)
	{
		Object* row = rows.get_at(i);
		if ((row.get_string("name") ?? "") == "foot") reported = row.get_float("travel") ?? 0.0;
	}
	test::@check(reported > 0.0, "the clip turns the knee and the foot below it reports no travel at all");

	// The same quantity out of the other read path: the widest the foot ever gets
	// from where it was, relative to the root, over the same grid of instants the
	// metric walks. A cycle stops short of its own end — phase 1 is phase 0 again
	// — so the grid is [0, duration), which is what makes this a like-for-like
	// comparison rather than a restatement of the endpoint.
	float height = 1.0f;
	Object*? skeleton = f.call_tool("get_skeleton", "{}");
	if (try skeleton)
	{
		height = (float)(skeleton.get_float("height") ?? 1.0);
		skeleton.free();
	}

	const usz SAMPLES = 16;
	Vec3[SAMPLES] seen;
	for (usz i = 0; i < SAMPLES; i++)
	{
		float t = BEND_DURATION * (float)i / (float)SAMPLES;
		seen[i] = swing_joint(f, "Bend", t, "foot") - swing_joint(f, "Bend", t, "hips");
	}

	float widest = 0.0f;
	for (usz a = 0; a < SAMPLES; a++)
	{
		for (usz b = a + 1; b < SAMPLES; b++)
		{
			float apart = (seen[b] - seen[a]).length();
			if (apart > widest) widest = apart;
		}
	}
	widest /= height;

	test::@check(math::abs((float)reported - widest) < 1.0e-3f,
		"measure_clip reports %.5f of travel and the same walk over get_pose gives %.5f", reported, widest);
}

// How long `bend_clip` runs. Named because two checks now depend on it and a
// sampling grid that disagreed with the clip would compare two different things.
const float BEND_DURATION = 0.5f;

// One joint's world position out of get_pose, for a check that wants to compare
// the two read paths rather than trust either.
fn Vec3 swing_joint(Fixture* f, String clip, float t, String joint)
{
	String call = string::format(mem, `{"clip":"%s","t":%f}`, clip, t);
	defer alloc::free(mem, call.ptr);

	Object*? pose = f.call_tool("get_pose", call);
	if (catch pose) return { 0, 0, 0 };
	defer pose.free();

	Object* joints = pose.get("joints")!!;
	for (sz i = 0; i < joints.get_len(); i++)
	{
		Object* row = joints.get_at(i);
		if ((row.get_string("name") ?? "") != joint) continue;
		Object* at = row.get("position")!!;
		return {
			(float)(at.get_float_at(0) ?? 0.0),
			(float)(at.get_float_at(1) ?? 0.0),
			(float)(at.get_float_at(2) ?? 0.0),
		};
	}
	return { 0, 0, 0 };
}

<*
 Deleting the clip that is playing stops the player first.

 `current_anim` is a copy pointing into the keyframes about to be freed, so a
 delete that left the player running would run it over dead memory — the same
 hazard `put_authored_clip` guards, reached down the other path.
*>
fn void delete_clip_stops_a_clip_it_is_playing() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	String arguments = bend_clip("Bend", QUARTER_TURN_AXIS);
	defer alloc::free(mem, arguments);
	Object*? applied = f.call_tool("apply_clip", arguments);
	if (catch applied)
	{
		test::@check(false, "apply_clip takes the clip to delete");
		return;
	}
	applied.free();

	Object*? started = f.call_tool("play", `{"clip":"Bend"}`);
	if (catch started)
	{
		test::@check(false, "play starts the clip");
		return;
	}
	started.free();
	test::@check(f.app.animating, "the clip is playing before it is deleted");

	Object*? gone = f.call_tool("delete_clip", `{"clip":"Bend"}`);
	if (catch gone)
	{
		test::@check(false, "delete_clip answers");
		return;
	}
	defer gone.free();

	test::@check(!f.app.animating, "deleting the running clip left the player running over it");
	test::@check((gone.get_int("remaining") ?? -1) == 0, "the authored pack still holds the clip");
	test::@check(f.refuses_tool("delete_clip", `{"clip":"Bend"}`, "no clip is called"),
		"deleting it twice is refused and says the pack does not hold it");
}
