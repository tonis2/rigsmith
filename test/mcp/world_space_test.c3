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
// World space
//
// `AnimTemplate.pose` composes authored[j] = authored[parent] · turn, so an
// entry's axis is the parent's as the clip has already turned it. These pin what
// "space":"world" buys over that, on the one arrangement where the two genuinely
// disagree: the hips turned a quarter about X, and something below them asked to
// go on pointing the way it rests.

// The hips turned a quarter about X. The root has no parent to be measured
// against, so this entry means the same in either frame — which is what leaves
// the joint below it as the only thing under test.
const String HIPS_QUARTER = `{"name":"hips","rotation":{"axis":[1,0,0],"angle":1.5707963267948966}}`;

// Identity, which in world space means "keep pointing where you rest" and in
// local space means "keep riding your parent". Those are different instructions
// and this is the clip that tells them apart.
fn String level_clip(String name, String joint, String space)
{
	String joints = string::format(
		mem,
		`%s,{"name":"%s","rotation":{"x":0,"y":0,"z":0,"w":1},"space":"%s"}`,
		HIPS_QUARTER,
		joint,
		space);
	defer alloc::free(mem, joints);

	return string::format(
		mem,
		`{"name":"%s","duration":1,"keyframes":[{"time":0,"joints":[%s]},{"time":1,"joints":[%s]}]}`,
		name,
		joints,
		joints);
}

fn float[<4>]? posed_turn(Object* pose, String name)
{
	Object* joints = pose.get("joints")!;
	for (sz i = 0; i < joints.get_len(); i++)
	{
		Object* joint = joints.get_at(i);
		if (joint.get_string("name")! != name) continue;
		Object* turn = joint.get("rotation")!;
		return {
			(float)turn.get_float_at(0)!,
			(float)turn.get_float_at(1)!,
			(float)turn.get_float_at(2)!,
			(float)turn.get_float_at(3)!,
		};
	}
	return NOT_FOUND~;
}

// A quaternion carrying no turn. Read off the scalar part alone, and through its
// magnitude: q and -q are the same rotation, so a check on the sign would fail
// on an answer that is right.
fn bool turns_nothing(float[<4>] turn) => math::abs(math::abs(turn[3]) - 1.0f) < 0.001f;

// Where the fixture's foot lands with the hips turned a quarter about X: the
// knee swings back to (0, 1, -0.5) either way, and then the foot either hangs
// straight down from it in world axes or goes on riding the hips.
const Vec3 FOOT_UNDER_A_LEVEL_KNEE = { 0, 0.5, -0.5 };
const Vec3 FOOT_RIDING_THE_HIPS = { 0, 1, -1 };

fn void a_world_entry_states_where_the_joint_points() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	String arguments = level_clip("level_world", "knee", "world");
	defer alloc::free(mem, arguments);
	Object*? applied = f.call_tool("apply_clip", arguments);
	if (catch applied)
	{
		test::@check(false, "a keyframe entry may ask for world space");
		return;
	}
	applied.free();

	Object*? pose = f.call_tool("get_pose", `{"clip":"level_world","t":0}`);
	if (catch pose)
	{
		test::@check(false, "a world-space clip samples");
		return;
	}
	defer pose.free();

	float[<4>] knee = posed_turn(pose, "knee") ?? (float[<4>]){ 0, 0, 0, 0 };
	Vec3 foot = posed_at(pose, "foot") ?? (Vec3){ 100, 100, 100 };

	// The whole point of the frame: the hips turned and the knee did not, which
	// is only expressible against the model's own axes.
	test::@check(turns_nothing(knee), "a world-space entry lands the joint at the orientation it asked for");
	test::@check((foot - FOOT_UNDER_A_LEVEL_KNEE).length() < 0.001f,
		"and everything below it follows that orientation, not the parent's — foot at (%.4f, %.4f, %.4f)",
		foot.x, foot.y, foot.z);
}

fn void the_same_entry_in_local_space_means_something_else() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	String arguments = level_clip("level_local", "knee", "local");
	defer alloc::free(mem, arguments);
	Object*? applied = f.call_tool("apply_clip", arguments);
	if (catch applied)
	{
		test::@check(false, "local is a space a keyframe entry may name");
		return;
	}
	applied.free();

	Object*? pose = f.call_tool("get_pose", `{"clip":"level_local","t":0}`);
	if (catch pose)
	{
		test::@check(false, "a local-space clip samples");
		return;
	}
	defer pose.free();

	Vec3 foot = posed_at(pose, "foot") ?? (Vec3){ 100, 100, 100 };
	// Identity against the parent leaves the knee riding the hips, so the foot
	// ends up somewhere else entirely. A conversion that quietly did nothing —
	// or did the same thing in both frames — fails here rather than passing the
	// check above by accident.
	test::@check((foot - FOOT_RIDING_THE_HIPS).length() < 0.001f,
		"the same entry read against the parent leaves the joint riding it — foot at (%.4f, %.4f, %.4f)",
		foot.x, foot.y, foot.z);
	test::@check((FOOT_UNDER_A_LEVEL_KNEE - FOOT_RIDING_THE_HIPS).length() > 0.1f,
		"the two frames are asserted against genuinely different answers");
}

fn void a_joint_a_world_keyframe_skips_inherits_its_parent() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	// The knee is not named at all, and the foot below it is stated in world
	// space. Working the foot's turn out needs the knee's world orientation,
	// which is its parent's exactly — the same answer `pose` gives a joint no
	// keyframe drives. Treating the gap as identity instead would leave the foot
	// riding the hips.
	String arguments = level_clip("level_gap", "foot", "world");
	defer alloc::free(mem, arguments);
	Object*? applied = f.call_tool("apply_clip", arguments);
	if (catch applied)
	{
		test::@check(false, "a world-space clip may leave a joint in the chain unnamed");
		return;
	}
	applied.free();

	Object*? pose = f.call_tool("get_pose", `{"clip":"level_gap","t":0}`);
	if (catch pose)
	{
		test::@check(false, "a clip with a gap in the chain samples");
		return;
	}
	defer pose.free();

	float[<4>] foot = posed_turn(pose, "foot") ?? (float[<4>]){ 0, 0, 0, 0 };
	test::@check(turns_nothing(foot),
		"a joint the keyframe skips carries its parent's world orientation, not identity");
}

fn void sparse_channels_round_trip_and_ignore_unrelated_key_times() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;
	const String CLIP = `{"name":"sparse","duration":1,"keyframes":[{"time":0,"joints":[{"name":"knee","rotation":[0,0,0]}]},{"time":0.25,"joints":[{"name":"hips","move":[0.1,0,0]}]},{"time":1,"joints":[{"name":"knee","rotation":[1.5707963267948966,0,0]}]}]}`;
	Object*? applied = f.call_tool("apply_clip", CLIP);
	if (catch applied) { test::@check(false, "apply_clip accepts independent sparse channels"); return; }
	applied.free();

	Object*? read = f.call_tool("get_clip", `{"clip":"sparse"}`);
	if (catch read) { test::@check(false, "get_clip reads sparse channels back"); return; }
	defer read.free();
	Object* keys = read.get("keyframes")!!;
	Object* rotation = keys.get_at(0).get("joints")!!.get_at(0);
	Object* translation = keys.get_at(1).get("joints")!!.get_at(0);
	test::@check(@ok(rotation.get("rotation")) && !@ok(rotation.get("move")),
		"a rotation-only key grew a translation channel");
	test::@check(@ok(translation.get("move")) && !@ok(translation.get("rotation")),
		"a translation-only key grew a rotation channel");

	Object*? pose = f.call_tool("get_pose", `{"clip":"sparse","t":0.25}`);
	if (catch pose) { test::@check(false, "the sparse clip samples at the unrelated hips key"); return; }
	defer pose.free();
	Vec3 knee = posed_at(pose, "knee")!!;
	Vec3 foot = posed_at(pose, "foot")!!;
	test::@check((foot - knee).z < -0.1f,
		"the unrelated hips key interrupted the knee's own rotation track");
}

fn void a_world_key_samples_ancestor_tracks_at_other_times() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;
	const String CLIP = `{"name":"world-between","duration":1,"keyframes":[{"time":0,"joints":[{"name":"hips","rotation":[0,0,0]}]},{"time":0.5,"joints":[{"name":"foot","space":"world","rotation":[0,0,0]}]},{"time":1,"joints":[{"name":"hips","rotation":[1.5707963267948966,0,0]}]}]}`;
	Object*? applied = f.call_tool("apply_clip", CLIP);
	if (catch applied) { test::@check(false, "a world key may sit between its ancestor's keys"); return; }
	applied.free();
	Object*? pose = f.call_tool("get_pose", `{"clip":"world-between","t":0.5}`);
	if (catch pose) { test::@check(false, "the world-space sparse clip samples"); return; }
	defer pose.free();
	float[<4>] knee = posed_turn(pose, "knee") ?? (float[<4>]){};
	float[<4>] foot = posed_turn(pose, "foot") ?? (float[<4>]){};
	test::@check(!turns_nothing(knee), "the hips ancestor track was not sampled between its own keys");
	test::@check(turns_nothing(foot), "the world foot key did not compensate the sampled ancestor track");
}

fn void a_space_that_is_neither_is_refused() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? root = f.request(
		`{"jsonrpc":"2.0","id":93,"method":"tools/call","params":{"name":"apply_clip","arguments":{"name":"sideways","duration":1,"keyframes":[{"time":0,"joints":[{"name":"knee","space":"sideways","rotation":[0,0,0]}]}]}}}`);
	if (catch root)
	{
		test::@check(false, "an unknown space answers");
		return;
	}
	defer root.free();
	test::@check(error_message_contains(root, `space is "sideways"`)
		&& error_message_contains(root, "local")
		&& error_message_contains(root, "world"),
		"a space that is neither names the value and both that would have been taken");
}

fn void the_three_rotation_forms_agree() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;
	Vec3[3] feet;
	String[3] names = { "as_axis", "as_quaternion", "as_euler" };
	String[3] rotations = { QUARTER_TURN_AXIS, QUARTER_TURN_QUAT, QUARTER_TURN_EULER };

	foreach (i, name : names)
	{
		String arguments = bend_clip(name, rotations[i]);
		defer alloc::free(mem, arguments);

		Object*? applied = f.call_tool("apply_clip", arguments);
		if (catch applied)
		{
			test::@check(false, "apply_clip accepts every rotation form");
			return;
		}
		applied.free();

		String ask = string::format(mem, `{"clip":"%s","t":0.5}`, name);
		defer alloc::free(mem, ask);

		Object*? pose = f.call_tool("get_pose", ask);
		if (catch pose)
		{
			test::@check(false, "get_pose answers for every rotation form");
			return;
		}
		defer pose.free();

		Vec3? at = posed_at(pose, "foot");
		if (catch at)
		{
			test::@check(false, "the posed foot comes back");
			return;
		}
		feet[i] = at;
	}

	test::@check((feet[0] - feet[1]).length() < 0.0001f && (feet[0] - feet[2]).length() < 0.0001f,
		"a quaternion, an axis and angle, and euler radians land the same turn");
}

fn void the_same_name_replaces() @test
{
	Fixture fixture;
	fixture.open_authored();
	defer fixture.close();
	Fixture* f = &fixture;
	String arguments = `{"name":"bend","duration":2,"keyframes":[{"time":0,"joints":[]},{"time":1,"joints":[{"name":"knee","rotation":[0.5,0,0]}]}]}`;

	Object*? applied = f.call_tool("apply_clip", arguments);
	if (catch applied)
	{
		test::@check(false, "apply_clip accepts a rewrite");
		return;
	}
	defer applied.free();
	test::@check((applied.get_bool("replaced") ?? false) == true, "rewriting a clip under the same name says it replaced one");

	Object*? scene = f.call_tool("get_scene", "{}");
	if (catch scene)
	{
		test::@check(false, "get_scene answers after a rewrite");
		return;
	}
	defer scene.free();
	test::@check(authored_in_scene_body(scene, 2.0f, 4) ?? false, "the rewrite replaces the clip rather than adding a second of the name");
}

<*
 The one wrinkle the authored pack has: it is not on disk, and `load_packs`
 frees the whole library to re-read the folder.
*>
fn void the_authored_pack_survives_a_library_reload() @test
{
	Fixture fixture;
	fixture.open_authored();
	defer fixture.close();
	Fixture* f = &fixture;
	f.app.load_packs(library::ready());

	Object*? scene = f.call_tool("get_scene", "{}");
	if (catch scene)
	{
		test::@check(false, "get_scene answers after a reload");
		return;
	}
	defer scene.free();

	test::@check(scene_clip_count(scene_pack(scene, "Authored")) == 4,
		"re-reading the library keeps the clips an agent wrote, which no file can give back");
}

fn void a_clip_says_what_was_wrong_with_it() @test
{
	Fixture fixture;
	fixture.open_authored();
	defer fixture.close();
	Fixture* f = &fixture;
	test::@check(f.refuses(
			`{"name":"walk","keyframes":[{"time":0,"joints":[{"name":"thigh_L","move":[0,0,0]}]}]}`,
			"thigh_L", "not a dot on this rig", "knee", "foot"),
		"an unknown joint is named, and so is every dot that would have worked");

	test::@check(f.refuses(
			`{"name":"walk","keyframes":[{"time":0,"joints":[{"name":"bone_4","move":[0,0,0]}]}]}`,
			"bone_4", "name the dot before animating it"),
		"a dot addressed by the bone_<id> get_skeleton shows is told why that cannot work");

	test::@check(f.refuses(
			`{"name":"walk","keyframes":[{"time":0},{"time":0.5},{"time":0.25}]}`,
			"keyframes[2]", "0.25", "increasing time order"),
		"a keyframe out of order names itself, its time and the rule");

	test::@check(f.refuses(
			`{"name":"walk","keyframes":[{"joints":[{"name":"knee","move":[0,0,0]}]}]}`,
			"keyframes[0]", `"time"`),
		"a keyframe with no time says which field is missing");

	test::@check(f.refuses(
			`{"name":"walk","keyframes":[{"time":"soon"}]}`,
			"keyframes[0]", `"time"`),
		"a time that is not a number is refused rather than read as zero");

	test::@check(f.refuses(
			`{"name":"walk","keyframes":[{"time":0,"joints":[{"name":"knee","move":[0,0,0]},{"name":"knee","move":[0,0,0]}]}]}`,
			"twice", "joints[0]", "joints[1]"),
		"one joint named twice in a keyframe names both entries");

	test::@check(f.refuses(
			`{"name":"walk","keyframes":[{"time":0,"joints":[{"name":"knee","rotation":"sideways"}]}]}`,
			"quaternion", "axis", "euler"),
		"a rotation in none of the three forms lists the three forms");

	test::@check(f.refuses(
			`{"name":"still","keyframes":[{"time":0,"joints":[{"name":"knee","move":[0,0,0]}]}]}`,
			"duration", "no length"),
		"a clip with no length is refused rather than stored unplayable");

	test::@check(f.refuses(
			`{"name":"walk","duration":0.5,"keyframes":[{"time":0},{"time":2}]}`,
			"never reaches", "0.5", "2"),
		"a duration shorter than the last keyframe is refused");

	test::@check(f.refuses(
			`{"name":"walk","duration":"a while","keyframes":[{"time":0},{"time":1}]}`,
			"duration", "must be a number"),
		"a duration that is not a number is refused rather than quietly ignored");

	test::@check(f.refuses(`{"keyframes":[{"time":0}]}`, `"name"`),
		"a clip with no name says which field is missing");

	test::@check(f.refuses(`{"name":"walk"}`, "keyframes"),
		"a clip with no keyframes says which field is missing");
}

<*
 Optional fields written as null, and an entry that then keys nothing.

 A client that builds its arguments from a record with defaults sends
 `"rotation": null` where a hand-written payload would omit the key, and the two
 say the same thing: this entry has no rotation channel. It remains valid when a
 move channel is present; with both channels absent there is no key to write and
 the entry is refused rather than silently disappearing.
*>
fn void a_null_field_reads_as_a_missing_one() @test
{
	Fixture fixture;
	fixture.open_authored();
	defer fixture.close();
	Fixture* f = &fixture;
	test::@check(f.refuses(
		`{"name":"empty-null","duration":0.5,"keyframes":[{"time":0.5,"joints":[{"name":"knee","rotation":null,"move":null}]}]}`,
		"needs rotation or move", "explicitly"),
		"an entry whose two null fields key nothing is refused clearly");

	Object*? applied = f.call_tool("apply_clip",
		`{"name":"nulls","duration":null,"keyframes":[{"time":0,"joints":null},{"time":0.5,"joints":[{"name":"knee","rotation":null,"move":[0,0,0]}]}]}`);
	if (catch applied)
	{
		test::@check(false, "a null rotation is absent while an explicit zero move remains a key");
		return;
	}
	defer applied.free();

	test::@check((applied.get_float("duration") ?? 0.0) == 0.5,
		"and a null duration falls back to the last keyframe rather than erroring");
}

<*
 Rewriting the clip that is on screen.

 The player holds a *copy* of the template, pointing at keyframes the rewrite
 frees, so this is the one path in `put_authored_clip` where getting it wrong is
 a use-after-free rather than a wrong answer. Asserting the running copy carries
 the new duration is what proves it was retaken and not merely left alone.
*>
fn void rewriting_the_running_clip_restarts_it() @test
{
	Fixture fixture;
	fixture.open_authored();
	defer fixture.close();
	Fixture* f = &fixture;
	crig::AnimRef ref = crig::resolve_clip(&f.app, "bend") ?? crig::NO_ANIM;
	if (!f.app.play_clip(ref))
	{
		test::@check(false, "the applied clip plays");
		return;
	}

	String arguments = `{"name":"bend","duration":3,"keyframes":[{"time":0,"joints":[]},{"time":1.5,"joints":[{"name":"knee","rotation":[0.25,0,0]}]}]}`;
	Object*? applied = f.call_tool("apply_clip", arguments);
	if (catch applied)
	{
		test::@check(false, "apply_clip accepts a rewrite of the running clip");
		return;
	}
	defer applied.free();

	test::@check(f.app.animating
		&& f.app.current_ref.same(ref)
		&& f.app.current_anim.duration == 3.0f
		&& (applied.get_bool("playing") ?? false) == true,
		"rewriting the clip on screen leaves it playing, from the new keyframes");

	f.app.stop_animation();
}

fn void a_refused_clip_changes_nothing() @test
{
	Fixture fixture;
	fixture.open_authored();
	defer fixture.close();
	Fixture* f = &fixture;
	Object*? scene = f.call_tool("get_scene", "{}");
	if (catch scene)
	{
		test::@check(false, "get_scene answers after the refusals");
		return;
	}
	defer scene.free();

	test::@check(scene_clip_count(scene_pack(scene, "Authored")) == 4,
		"nine refused clips left the library exactly as it was");
}
