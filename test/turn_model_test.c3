// Turn model: the mesh, the rig and every direction the character holds turned
// together by quarter turns, undone exactly in one step, and written into the
// model by the next save.
module crig_tests::turn_model;

import crig;
import crig_tests::mcp;
import crig_tests::shared_app;
import rig;
import std::collections::object;
import std::core::test;
import std::io;
import std::io::file;
import std::math;

const String HUMANOID = "assets/animations/humanoid.glb";

struct Opened
{
	rig::TriMesh mesh;
	crig::AppState app;
	String path;
}

fn void Opened.open(&self, String path)
{
	self.path = path;
	char[] original = file::load(mem, HUMANOID)!!;
	defer alloc::free(mem, original);
	file::save(path, original)!!;

	self.mesh = rig::load_gltf(mem, path)!!;
	self.app = crig::new_app(self.mesh, path);
	self.app.adopt_source_rig();
	self.app.saves_in_place = true;
}

fn void Opened.close(&self)
{
	self.app.free();
	self.mesh.free(mem);
	(void)file::delete(self.path);
	String sidecar = crig::session_path(mem, self.path);
	defer sidecar.free(mem);
	(void)file::delete(sidecar);
}

fn Vec3 dot_at(crig::AppState* app, String name)
{
	crig::Dot* dot = app.dot_named(name);
	return dot ? dot.position : (Vec3){};
}

fn bool same_bits(Vec3[] a, Vec3[] b)
{
	if (a.len != b.len) return false;
	foreach (usz i, v : a) if (v != b[i]) return false;
	return true;
}

<*
 A quarter turn moves every vertex, normal and joint by exactly that turn, the
 feet then read the new way, and undo gives back the same bits.
*>
fn void turning_the_model_turns_mesh_and_rig_as_one_undo_step() @test
{
	io::printn("turn model: one exact undo step for the mesh and the rig");
	Opened f;
	f.open("build/turn-model-undo.glb");
	defer f.close();
	crig::AppState* app = &f.app;

	test::@check(app.mesh_facing() == crig::MeshFacing.PLUS_Z, "the humanoid's feet read %s, not +z", app.mesh_facing().label);
	Vec3[] positions = alloc::clone_slice(mem, app.geometry.positions);
	defer alloc::free(mem, positions);
	Vec3[] normals = alloc::clone_slice(mem, app.geometry.normals);
	defer alloc::free(mem, normals);
	Vec3 wrist = dot_at(app, "wrist_L");
	float sym = app.doc.sym_x;

	test::@check(app.turn_model_by(1) == crig::TurnModelResult.TURNED, "the turn was refused");
	usz middle = positions.len / 2;
	test::@check(app.geometry.positions[middle] == (Vec3){ positions[middle].z, positions[middle].y, -positions[middle].x },
		"a vertex did not turn a quarter");
	test::@check(normals.len == 0 || app.geometry.normals[middle] == crig::quarter_turned(normals[middle], 1), "a normal did not turn");
	test::@check(dot_at(app, "wrist_L") == crig::quarter_turned(wrist, 1), "the wrist did not turn with the mesh");
	test::@check(app.mesh_facing() == crig::MeshFacing.PLUS_X, "after a quarter turn the feet read %s, not +x", app.mesh_facing().label);
	test::@check(app.mesh_resized && app.mesh_turns == 1, "the model does not know its file faces the old way");

	test::@check(app.undo(), "nothing to undo");
	test::@check(same_bits(app.geometry.positions, positions), "undo left the vertices moved");
	test::@check(same_bits(app.geometry.normals, normals), "undo left the normals turned");
	test::@check(dot_at(app, "wrist_L") == wrist, "undo left the wrist moved");
	test::@check(app.doc.sym_x == sym, "undo left the mirror plane at %f, not %f", app.doc.sym_x, sym);

	test::@check(app.redo(), "nothing to redo");
	test::@check(dot_at(app, "wrist_L") == crig::quarter_turned(wrist, 1), "redo did not turn again");

	// Back round to the front from what the feet read: three more quarters.
	crig::MeshFacing read;
	test::@check(app.turn_model_to_front(crig::MeshFacing.UNDECIDED, &read) == crig::TurnModelResult.TURNED, "the turn to the front was refused");
	test::@check(read == crig::MeshFacing.PLUS_X, "the feet read %s before turning to the front", read.label);
	test::@check(same_bits(app.geometry.positions, positions), "four quarter turns did not give back the same vertices");
	test::@check(app.mesh_turns == 0, "four quarter turns left %d", app.mesh_turns);
	test::@check(app.turn_model_by(4) == crig::TurnModelResult.UNCHANGED, "a whole turn should change nothing");
}

// A clip keyed about world axes, with a move on the hips and a pin, so the keys,
// the moves and the pins all have something to turn.
fn crig::AnimTemplate swinging_clip()
{
	const usz KEYS = 4;
	crig::AnimKeyframe[] frames = alloc::new_array(mem, crig::AnimKeyframe, KEYS);
	foreach (usz i, &frame : frames)
	{
		float swing = 0.5f * math::sin((float)i / (float)KEYS * 2.0f * (float)math::PI);
		crig::AnimKeyDot[] dots = alloc::new_array(mem, crig::AnimKeyDot, 4);
		dots[0] = { .joint_name = "hips".copy(mem), .channels = BOTH, .axis = { 0, 1, 0 }, .angle = swing * 0.3f, .move = { 0.02f, -0.02f, 0.03f } };
		dots[1] = { .joint_name = "thigh_L".copy(mem), .channels = ROTATION, .axis = { 1, 0, 0 }, .angle = swing };
		dots[2] = { .joint_name = "shoulder_R".copy(mem), .channels = ROTATION, .axis = { 0, 0, 1 }, .angle = swing };
		dots[3] = { .joint_name = "elbow_L".copy(mem), .channels = ROTATION, .axis = { 0.6f, 0, 0.8f }, .angle = 0.4f + swing };
		*frame = { .time = (float)i / (float)KEYS, .dots = dots };
	}
	return { .name = "Swing".copy(mem), .duration = 1.0f, .loop = true, .keyframes = frames, .owned = true };
}

// Every joint's place over the clip, by dot id, so two rigs are compared joint for joint.
fn Vec3[] played(crig::AppState* app, crig::AnimRef ref, uint[]* ids)
{
	crig::RigView view = app.open_rig(mem)!!;
	defer view.free(mem);
	usz joints = view.skeleton.len();
	*ids = alloc::clone_slice(mem, view.dot_ids);
	const usz SAMPLES = 12;
	Vec3[] out = alloc::new_array(mem, Vec3, (sz)(joints * SAMPLES));
	crig::AnimTemplate clip = *app.clip(ref);
	for (usz s = 0; s < SAMPLES; s++)
	{
		rig::Pose pose = app.evaluated_clip_pose(mem, &view, clip, ref, (float)s / (float)SAMPLES);
		defer pose.free(mem);
		Matrix4f[] palette = rig::joint_palette(mem, &view.skeleton, pose)!!;
		defer alloc::free(mem, palette);
		for (usz j = 0; j < joints; j++) out[s * joints + j] = view.skeleton.joints[j].transform(palette[j]);
	}
	return out;
}

<*
 A clip authored on the rig plays the same motion turned: every joint, at every
 moment, lands where the turn carries it from where it was. That is the keys'
 axes and moves, the limit tables' frames and the clip's pins all turning.
*>
fn void a_turned_clip_plays_the_same_motion_turned() @test
{
	io::printn("turn model: an authored clip plays the same motion, turned");
	Opened f;
	f.open("build/turn-model-clip.glb");
	defer f.close();
	crig::AppState* app = &f.app;

	crig::AnimRef ref = app.author_clip(swinging_clip());
	test::@check(ref.valid(), "the clip did not land");
	uint[] ids_before;
	Vec3[] before = played(app, ref, &ids_before);
	defer
	{
		alloc::free(mem, before);
		alloc::free(mem, ids_before);
	}

	test::@check(app.turn_model_by(-1) == crig::TurnModelResult.TURNED, "the turn was refused");
	uint[] ids_after;
	Vec3[] after = played(app, ref, &ids_after);
	defer
	{
		alloc::free(mem, after);
		alloc::free(mem, ids_after);
	}
	test::@check(ids_after.len == ids_before.len, "the turn changed the joint count");
	test::@check(after.len == before.len, "the clip played a different number of samples");

	float height = app.model_height();
	usz joints = ids_before.len;
	float worst = 0.0f;
	for (usz i = 0; i < before.len; i++)
	{
		// Matched by dot, in case the joint order moved.
		usz j = i % joints;
		usz k = j;
		foreach (usz m, id : ids_after) if (id == ids_before[j]) { k = m; break; }
		Vec3 expected = crig::quarter_turned(before[i], -1);
		worst = math::max(worst, (after[i - j + k] - expected).length());
	}
	test::@check(worst < height * 1.0e-4f, "a joint played %f off where the turn puts it", worst);

	test::@check(app.undo(), "nothing to undo");
	Vec3[] back = played(app, ref, &ids_after);
	defer alloc::free(mem, back);
	float drift = 0.0f;
	foreach (usz i, p : back) drift = math::max(drift, (p - before[i]).length());
	test::@check(drift < height * 1.0e-6f, "undo left the clip playing %f off", drift);
}

<*
 Save writes the turned positions and normals into the model with the skin, so
 the file reopens facing the new way, with its rig.
*>
fn void a_turned_save_reopens_facing_the_new_way() @test
{
	io::printn("turn model: the save writes the turn into the model");
	Opened f;
	f.open("build/turn-model-save.glb");
	defer f.close();
	crig::AppState* app = &f.app;

	Vec3 wrist = dot_at(app, "wrist_L");
	sz joints = app.doc.dots.len();
	test::@check(app.turn_model_by(1) == crig::TurnModelResult.TURNED, "the turn was refused");
	Vec3[] positions = alloc::clone_slice(mem, app.geometry.positions);
	defer alloc::free(mem, positions);
	Vec3[] normals = alloc::clone_slice(mem, app.geometry.normals);
	defer alloc::free(mem, normals);
	app.save_session();
	test::@check(app.source_path == f.path, "the save went to %s, not back into the model", app.source_path);
	test::@check(!app.mesh_resized && app.mesh_turns == 0, "the save did not take the turn: %s", app.notice());

	rig::TriMesh reread = rig::load_gltf(mem, f.path)!!;
	defer reread.free(mem);
	test::@check(reread.positions.len == positions.len, "the file has %d vertices, not %d", reread.positions.len, positions.len);
	float far = 0.0f;
	foreach (usz i, p : reread.positions) far = math::max(far, (p - positions[i]).length());
	test::@check(far < 1.0e-4f, "a vertex reopened %f from where the turn put it", far);
	float bent = 0.0f;
	if (normals.len == reread.normals.len)
	{
		foreach (usz i, n : reread.normals) bent = math::max(bent, (n - normals[i]).length());
	}
	test::@check(normals.len == reread.normals.len && bent < 1.0e-3f, "the normals reopened %f off the turned ones", bent);

	crig::AppState reopened = crig::new_app(reread, f.path);
	defer reopened.free();
	reopened.adopt_source_rig();
	test::@check(reopened.mesh_facing() == crig::MeshFacing.PLUS_X, "the reopened model faces %s, not +x", reopened.mesh_facing().label);
	test::@check(reopened.doc.dots.len() == joints, "the reopened rig has %d joints, not %d", reopened.doc.dots.len(), joints);
	test::@check((dot_at(&reopened, "wrist_L") - crig::quarter_turned(wrist, 1)).length() < 1.0e-4f, "the reopened wrist is not where the turn put it");
}

<*
 A plan fitted to a figure facing sideways lies across it, so apply_plan refuses
 one whose feet point along X and names the turn; turned to the front, it fits.
*>
fn void a_sideways_model_is_turned_before_a_plan_fits() @test
{
	io::printn("turn model: apply_plan refuses a model facing +X");
	Fixture* f = mem::new(Fixture);
	defer free(f);
	if (!f.open_model(HUMANOID)) return;
	defer f.close();
	shared_app::attach_all_packs(&f.app);

	Object* turned = f.call_checked("turn_model", `{"degrees":90}`);
	if (!turned) return;
	defer turned.free();
	test::@check(turned.get_string("facing") ?? "" == "+x", "a quarter turn left the humanoid facing %s", turned.get_string("facing") ?? "");

	Object*? refused = f.request(
		`{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"apply_plan","arguments":{"plan":"biped"}}}`);
	if (catch refused)
	{
		test::@check(false, "apply_plan did not answer");
		return;
	}
	defer refused.free();
	test::@check(mcp::error_message_contains(refused, "turn_model") && mcp::error_message_contains(refused, `"+x"`),
		"apply_plan fitted a model facing +X instead of naming the turn");

	Object* front = f.call_checked("turn_model", `{"facing":"auto"}`);
	if (!front) return;
	defer front.free();
	test::@check(front.get_string("facing_before") ?? "" == "+x" && front.get_string("facing") ?? "" == "+z",
		"turning to the front read %s and left %s", front.get_string("facing_before") ?? "", front.get_string("facing") ?? "");
	Object* fitted = f.call_checked("apply_plan", `{"plan":"biped"}`);
	if (!fitted) return;
	defer fitted.free();
	Object* fit = crig::member(fitted, "fit");
	test::@check(fit != null && (fit.get_string("verdict") ?? "") == "fits", "the plan did not fit the turned model");
}
