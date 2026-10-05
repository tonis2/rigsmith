<*
 Gait authoring (`anim/gait.c3`, `mcp/gait.c3`) and the baked mode of
 solve_targets.

 The leg solve is checked on synthetic chains — a bare skeleton, no document —
 for reach and for which way the knee bends. The tools are checked on the real
 quadruped and humanoid, which are the rigs a gait has to work on: a walk and a
 trot that do not skate, sink or fail to loop, measured by `measure_clip` the way
 a caller would.
*>
module crig_tests::gait;

import crig;
import rig;
import std::io;
import std::math;
import std::math::vector;
import std::math::matrix;
import std::math::quaternion;
import std::collections::object;
import std::encoding::json;
import std::core::test;

const String QUADRUPED = "assets/animations/quadruped.glb";
const String HUMANOID = "assets/animations/humanoid.glb";

// A model opened the way the app opens one: its own rig imported, the mesh kept
// alive beside it.
struct Rigged
{
	rig::TriMesh mesh;
	crig::AppState app;
}

fn void Rigged.open(&self, String path)
{
	self.mesh = rig::load_gltf(mem, path)!!;
	self.app = crig::new_app(self.mesh, path);
	test::@check(self.app.import_rig_from_source(), "%s must import its rig", path);
}

fn void Rigged.close(&self)
{
	self.app.free();
	self.mesh.free(mem);
}

// author_gait called with JSON arguments: the answer parsed, or null with the reason.
fn Object* call(AppState* app, String arguments, String* reason)
{
	Object*? args = json::parse(mem, arguments);
	if (catch args) return null;
	defer args.free();
	DString detail = dstring::new(mem);
	defer detail.free();
	String? text = crig::author_gait_json(app, args, &detail);
	if (catch text)
	{
		*reason = detail.copy_str(mem);
		return null;
	}
	defer text.free(mem);
	Object*? parsed = json::parse(mem, text);
	if (catch parsed) return null;
	return parsed;
}

fn float number(Object* object, String key)
{
	return (float)(object.get_float(key) ?? -1.0);
}

// The landed clip's metrics, checked against what a gait has to clear.
fn void check_cycle(Rigged* f, String arguments, float duration)
{
	String reason;
	Object* answer = call(&f.app, arguments, &reason);
	if (answer == null)
	{
		test::@check(false, "author_gait refused: %s", reason);
		return;
	}
	defer answer.free();
	Object* metrics = answer.get("metrics")!!;
	float slide = number(metrics, "foot_slide");
	float sink = number(metrics, "floor_penetration");
	io::printfn("  slide %.4f sink %.4f speed %.3f drop %.3f stride %.3f keys %d", slide, sink,
		number(answer, "ground_speed"), number(answer, "pelvis_drop"), number(answer, "stride"), (int)number(answer, "keys"));
	test::@check(slide < 0.01f, "foot slide %.4f rig heights", slide);
	test::@check(sink < 0.005f, "floor penetration %.4f rig heights", sink);
	test::@check(number(answer, "ground_speed") > 0.0f, "no treadmill speed reported");

	// It loops: the pose a whole cycle on is the pose at the start.
	crig::AnimRef ref = f.app.clip_named_in_authored(answer.get_string("clip")!!);
	test::@check(ref.valid(), "the clip did not land in the authored pack");
	crig::AnimTemplate* clip = f.app.clip(ref);
	test::@check(clip.loop, "a gait loops by default");
	crig::RigView view = f.app.open_rig(mem)!!;
	defer view.free(mem);
	rig::Pose start = clip.pose(mem, &view.skeleton, view.names, 0.0f, false);
	defer start.free(mem);
	rig::Pose end = clip.pose(mem, &view.skeleton, view.names, duration, false);
	defer end.free(mem);
	float worst;
	foreach (usz j, turn : start.rotations)
	{
		worst = math::max(worst, 1.0f - math::abs(turn.v.dot(end.rotations[j].v)));
	}
	test::@check(worst < 1.0e-5f, "the cycle does not close: worst joint off by %g", worst);
}

fn void a_quadruped_walk_does_not_skate_or_sink() @test
{
	io::printn("a quadruped walk plants its feet");
	Rigged f;
	f.open(QUADRUPED);
	defer f.close();
	check_cycle(&f, `{"name":"Gait Walk","duration":1.1,"gait":"walk"}`, 1.1f);
}

fn void a_quadruped_trot_does_not_skate_or_sink() @test
{
	io::printn("a quadruped trot plants its feet");
	Rigged f;
	f.open(QUADRUPED);
	defer f.close();
	check_cycle(&f, `{"name":"Gait Trot","duration":0.6,"gait":"trot"}`, 0.6f);
}

fn void a_biped_walk_does_not_skate_or_sink() @test
{
	io::printn("a humanoid walk plants its feet");
	Rigged f;
	f.open(HUMANOID);
	defer f.close();
	check_cycle(&f, `{"name":"Gait Biped","duration":1.0,"gait":"walk"}`, 1.0f);
}

<*
 The feet of a rig are found without being named: four on the dog, two on the
 person — and not their hands, ears or fingers.
*>
fn void the_feet_are_found_on_their_own() @test
{
	io::printn("feet are found without being named");
	Rigged dog;
	dog.open(QUADRUPED);
	defer dog.close();
	crig::RigView view = dog.app.open_rig(mem)!!;
	defer view.free(mem);
	usz[8] feet;
	usz found = crig::gait_find_feet(&view.skeleton, view.names, feet[..]);
	test::@check(found == 4, "the dog has four feet, found %d", found);
	for (usz i = 0; i < found; i++)
	{
		test::@check(view.names[feet[i]].contains("hoof"), "a foot was %s", view.names[feet[i]]);
	}

	Rigged person;
	person.open(HUMANOID);
	defer person.close();
	crig::RigView body = person.app.open_rig(mem)!!;
	defer body.free(mem);
	found = crig::gait_find_feet(&body.skeleton, body.names, feet[..]);
	test::@check(found == 2, "a person has two feet, found %d", found);
	for (usz i = 0; i < found; i++)
	{
		test::@check(body.names[feet[i]].contains("toe"), "a foot was %s", body.names[feet[i]]);
	}
}

// ---------------------------------------------------------------------------
// The leg solve, on chains with no rig behind them.

// A chain whose joints sit at `points`, at rest.
fn crig::LegChain synthetic(Vec3[] points)
{
	crig::LegChain chain = { .bones = points.len - 1, .parent = quaternion::IDENTITY };
	foreach (usz i, p : points)
	{
		chain.at[i] = p;
		chain.turn[i] = quaternion::IDENTITY;
	}
	return chain;
}

// Where the solve's turns put the foot, by forward kinematics on the chain: the
// check that the rotations, not just the solve's own bookkeeping, land it.
fn Vec3 forward_kinematics(crig::LegChain* chain, crig::LegSolve* solved)
{
	Vec3 at = chain.at[0];
	Quaternionf world = chain.parent;
	for (usz i = 0; i < chain.bones; i++)
	{
		world = world.mul(solved.local[i]);
		at += world.rotate_vec3(chain.at[i + 1] - chain.at[i]);
	}
	return at;
}

// How far the knee stands off the line from the root to joint 2, along Z.
fn float knee_forward(crig::LegChain* chain, crig::LegSolve* solved)
{
	Vec3 line = solved.at[2] - chain.at[0];
	Vec3 knee = solved.at[1] - chain.at[0];
	Vec3 off = knee - line * (knee.dot(line) / line.dot(line));
	return off.z;
}

<*
 Two bones reach a point inside their range, the knee stays on the side it
 started on, and the turns reproduce the foot.
*>
fn void a_two_bone_leg_reaches_and_keeps_its_bend() @test
{
	io::printn("two-bone leg reaches a point and keeps its knee forward");
	Vec3[3] points = { { 0, 1, 0 }, { 0, 0.5, 0.1 }, { 0, 0, 0 } };
	crig::LegChain chain = synthetic(points[..]);

	Vec3[3] targets = { { 0, 0.3, 0.2 }, { 0, 0.3, -0.2 }, { 0.1, 0.4, 0.0 } };
	foreach (target : targets)
	{
		crig::LegSolve solved = crig::solve_leg(&chain, target);
		test::@check(solved.gap < 1.0e-4f, "missed %g %g %g by %g", target.x, target.y, target.z, solved.gap);
		Vec3 foot = forward_kinematics(&chain, &solved);
		test::@check((foot - target).length() < 1.0e-3f, "the turns land at %g %g %g, not the target", foot.x, foot.y, foot.z);
		float forward = knee_forward(&chain, &solved);
		test::@check(forward > 0.0f, "the knee flipped: offset z %g for %g %g %g", forward, target.x, target.y, target.z);
	}

	// Out of reach: short by about the shortfall.
	crig::LegSolve far = crig::solve_leg(&chain, { 0, -2, 0 });
	test::@check(far.gap > 0.9f, "an unreachable target came back reached: gap %g", far.gap);
}

<*
 Three bones: the distal segment keeps its preferred tilt while the reach allows,
 and tilts only as far as needed when it does not.
*>
fn void a_three_bone_leg_tilts_its_distal_segment_only_as_needed() @test
{
	io::printn("three-bone leg holds the distal tilt until the reach needs it");
	// Hip, knee forward, hock back, paw below the hock: a dog's hind leg in profile.
	Vec3[4] points = { { 0, 0.45, -0.25 }, { 0, 0.29, -0.19 }, { 0, 0.13, -0.31 }, { 0, 0.035, -0.29 } };
	crig::LegChain chain = synthetic(points[..]);
	Vec3 distal = points[3] - points[2];

	// Comfortably inside reach: the paw lands, and the segment holds exactly the
	// tilt it was asked for.
	Vec3 near = { 0, 0.05, -0.27 };
	crig::LegSolve easy = crig::solve_leg(&chain, near, 0.2f);
	test::@check(easy.gap < 1.0e-4f, "missed the near target by %g", easy.gap);
	test::@check(math::abs(easy.tilt - 0.2f) < 1.0e-6f, "tilted to %g when 0.2 was asked and the reach allowed it", easy.tilt);
	Vec3 foot = forward_kinematics(&chain, &easy);
	test::@check((foot - near).length() < 1.0e-3f, "the turns land %g off", (foot - near).length());
	Vec3 held = easy.world[2].rotate_vec3(distal);
	Quaternionf pitch = quaternion::from_axis_angle{float}(easy.lateral, 0.2f);
	test::@check((held - pitch.rotate_vec3(distal)).length() < 1.0e-4f, "the distal segment is not held at the asked tilt");

	// Reaching far back takes more than the proximal pair has: the tilt moves, by
	// the least that lets it, and the paw still lands.
	crig::LegSolve stretched = crig::solve_leg(&chain, { 0, 0.035, -0.42 }, 0.0f);
	test::@check(math::abs(stretched.tilt) > 0.01f, "the tilt did not move for a stretched reach (gap %g, tilt %g, lat %g %g %g)", stretched.gap, stretched.tilt, stretched.lateral.x, stretched.lateral.y, stretched.lateral.z);
	test::@check(stretched.gap < 1.0e-3f, "the stretched reach missed by %g", stretched.gap);
	crig::LegSolve tight = crig::solve_leg(&chain, { 0, 0.035, -0.38 }, 0.0f);
	test::@check(math::abs(tight.tilt) <= math::abs(stretched.tilt) + 1.0e-6f, "a shorter reach tilted further: %g against %g", tight.tilt, stretched.tilt);
	float forward = knee_forward(&chain, &stretched);
	test::@check(forward > 0.0f, "the knee flipped: offset z %g", forward);
}

<*
 A splayed leg — out of the sagittal plane — is solved in its own plane.
*>
fn void a_splayed_leg_is_solved_in_its_own_plane() @test
{
	io::printn("a splayed leg bends in the plane it rests in");
	float lean = 0.5f;
	Vec3 hip = { 0, 1, 0 };
	Vec3 axis = { math::sin(lean), -math::cos(lean), 0 };
	Vec3 sideways = { math::cos(lean), math::sin(lean), 0 };
	Vec3 knee = hip + axis * 0.5f + (Vec3){ 0, 0, 0.08 };
	Vec3 foot = hip + axis * 1.0f;
	Vec3[3] points = { hip, knee, foot };
	crig::LegChain chain = synthetic(points[..]);

	Vec3 target = hip + axis * 0.7f + sideways * 0.02f + (Vec3){ 0, 0, 0.1 };
	crig::LegSolve solved = crig::solve_leg(&chain, target);
	test::@check(solved.gap < 1.0e-3f, "missed a point out of the rest plane by %g", solved.gap);
	Vec3 reached = forward_kinematics(&chain, &solved);
	test::@check((reached - target).length() < 1.0e-3f, "the turns land %g off", (reached - target).length());
	test::@check(solved.at[1].z > hip.z + 0.01f, "the knee flipped to z %g", solved.at[1].z);
}

// ---------------------------------------------------------------------------
// solve_targets, baked.

fn Object* solve(AppState* app, String arguments, String* reason)
{
	Object*? args = json::parse(mem, arguments);
	if (catch args) return null;
	defer args.free();
	DString detail = dstring::new(mem);
	defer detail.free();
	String? text = crig::solve_targets_json(app, args, &detail);
	if (catch text)
	{
		*reason = detail.copy_str(mem);
		return null;
	}
	defer text.free(mem);
	Object*? parsed = json::parse(mem, text);
	if (catch parsed) return null;
	return parsed;
}

<*
 A foot target given as a path bakes a clip whose foot follows it.
*>
fn void a_baked_target_path_is_followed() @test
{
	io::printn("a keyed foot path bakes into a clip the foot follows");
	Rigged f;
	f.open(QUADRUPED);
	defer f.close();

	// The left hind hoof lifted from where it stands and forward — the quadruped
	// faces −X — over a second.
	String path = `{"bake":{"clip":"Baked Step","duration":1.0,"loop":true,"samples":20},
		"targets":[{"joint":"hind_hoof_L","position":[
			{"time":0,"position":[0.235,0.041,-0.251]},
			{"time":0.5,"position":[0.165,0.146,-0.251]},
			{"time":1.0,"position":[0.235,0.041,-0.251]}]}]}`;
	String reason;
	Object* answer = solve(&f.app, path, &reason);
	if (answer == null)
	{
		test::@check(false, "baked solve_targets refused: %s", reason);
		return;
	}
	defer answer.free();
	test::@check(answer.get_bool("reached")!! == true, "the path was not reached");

	crig::AnimRef ref = f.app.clip_named_in_authored("Baked Step");
	test::@check(ref.valid(), "no clip landed");
	crig::AnimTemplate* clip = f.app.clip(ref);
	test::@check(clip.loop && math::abs(clip.duration - 1.0f) < 1.0e-6f, "the clip is %g long, loop %s", clip.duration, clip.loop);

	crig::RigView view = f.app.open_rig(mem)!!;
	defer view.free(mem);
	usz paw = 0;
	foreach (usz j, name : view.names)
	{
		if (name == "hind_hoof_L") paw = j;
	}
	float worst;
	foreach (float t : (float[]){ 0.0f, 0.25f, 0.5f, 0.75f })
	{
		rig::Pose pose = clip.pose(mem, &view.skeleton, view.names, t, false);
		defer pose.free(mem);
		Matrix4f[] palette = rig::joint_palette(mem, &view.skeleton, pose)!!;
		defer alloc::free(mem, palette);
		Vec3 at = view.skeleton.joints[paw].transform(palette[paw]);
		// The path: a triangle up to 0.146 at 0.5 and back.
		float rise = t <= 0.5f ? t / 0.5f : (1.0f - t) / 0.5f;
		Vec3 want = { 0.235f - 0.07f * rise, 0.041f + 0.105f * rise, -0.251f };
		worst = math::max(worst, (at - want).length());
	}
	test::@check(worst < 0.005f, "the foot is %g off its path", worst);
}
