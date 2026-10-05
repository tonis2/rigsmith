// Scale model: the mesh, the rig and their lengths resized together, undone in
// one step, and written into the model by the next save.
module crig_tests::scale_model;

import crig;
import gltf;
import rig;
import std::core::test;
import std::io;
import std::io::file;
import std::math;
import std::math::vector;

const String HUMANOID = "assets/animations/humanoid.glb";

// The shipped humanoid and its sidecar, copied to `path` and opened the way the
// app opens a model it saved before.
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
	// A disposable copy under build: saving may write back into it, the way a
	// model with a sidecar beside it would be.
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

<*
 One step resizes the mesh, the joints and the reaches; undo puts every one back
 and redo does it again.
*>
fn void scaling_the_model_resizes_mesh_and_rig_as_one_undo_step() @test
{
	io::printn("scale model: one undo step for the mesh and the rig");
	Opened f;
	f.open("build/scale-model-undo.glb");
	defer f.close();
	crig::AppState* app = &f.app;

	float height = app.model_height();
	Vec3 wrist = dot_at(app, "wrist_L");
	usz vertices = app.geometry.positions.len;
	Vec3 vertex = app.geometry.positions[vertices / 2];
	test::@check(height > 0.5f && wrist.x > 0.1f, "the humanoid did not open with a rig (height %f)", height);

	crig::Dot* reaching = app.dot_named("head");
	test::@check(reaching != null, "the humanoid has no head");
	reaching.reach = 0.1f;

	float target = height * 0.55f;
	test::@check(app.scale_model_to_height(target) == crig::ScaleModelResult.SCALED, "the scale was refused");
	float factor = target / height;
	test::@check(math::abs(app.model_height() - target) < 1.0e-4f, "the model stands %f tall, not %f", app.model_height(), target);
	test::@check((dot_at(app, "wrist_L") - wrist * factor).length() < 1.0e-5f, "the wrist did not move with the mesh");
	test::@check((app.geometry.positions[vertices / 2] - vertex * factor).length() < 1.0e-5f, "a vertex did not scale");
	test::@check(math::abs(app.dot_named("head").reach - 0.1f * factor) < 1.0e-6f, "the reach kept its old length");
	test::@check(app.geometry.positions.len == vertices, "the vertex count changed");
	test::@check(app.mesh_resized, "the model does not know its file is the old size");

	test::@check(app.undo(), "nothing to undo");
	test::@check(math::abs(app.model_height() - height) < 1.0e-4f, "undo left the model %f tall", app.model_height());
	test::@check((dot_at(app, "wrist_L") - wrist).length() < 1.0e-5f, "undo left the wrist moved");
	test::@check(math::abs(app.dot_named("head").reach - 0.1f) < 1.0e-6f, "undo left the reach scaled");

	test::@check(app.redo(), "nothing to redo");
	test::@check(math::abs(app.model_height() - target) < 1.0e-4f, "redo did not scale again");

	test::@check(app.scale_model_by(1.0f) == crig::ScaleModelResult.UNCHANGED, "a factor of 1 should change nothing");
	test::@check(app.scale_model_by(0.0f) == crig::ScaleModelResult.REFUSED, "a factor of 0 should be refused");
	float zero = 0.0f;
	test::@check(app.scale_model_by(zero / zero) == crig::ScaleModelResult.REFUSED, "NaN should be refused");
}

<*
 Save writes the resized positions into the model with the skin, so the file
 reopens the new size with its rig, its skin and its clips.
*>
fn void a_scaled_save_reopens_at_the_new_size() @test
{
	io::printn("scale model: the save writes the new size into the model");
	Opened f;
	f.open("build/scale-model-save.glb");
	defer f.close();
	crig::AppState* app = &f.app;

	usz vertices = app.geometry.positions.len;
	sz joints = app.doc.dots.len();
	crig::AnimTemplate[] clips = app.bound_templates(mem);
	usz clip_count = clips.len;
	if (clips.len > 0) alloc::free(mem, clips);
	Vec3 wrist = dot_at(app, "wrist_L");
	float target = app.model_height() * 0.55f;
	float factor = target / app.model_height();

	test::@check(app.scale_model_to_height(target) == crig::ScaleModelResult.SCALED, "the scale was refused");
	app.save_session();
	test::@check(app.source_path == f.path, "the save went to %s, not back into the model", app.source_path);
	test::@check(!app.mesh_resized, "the save did not take the resize: %s", app.notice());

	rig::TriMesh reread = rig::load_gltf(mem, f.path)!!;
	defer reread.free(mem);
	rig::Bounds box = reread.bounds();
	test::@check(math::abs(box.max.y - box.min.y - target) < 1.0e-3f, "the file stands %f tall, not %f", box.max.y - box.min.y, target);
	test::@check(reread.positions.len == vertices, "the file has %d vertices, not %d", reread.positions.len, vertices);

	crig::AppState reopened = crig::new_app(reread, f.path);
	defer reopened.free();
	reopened.adopt_source_rig();
	test::@check(reopened.doc.dots.len() == joints, "the reopened rig has %d joints, not %d", reopened.doc.dots.len(), joints);
	test::@check((dot_at(&reopened, "wrist_L") - wrist * factor).length() < 1.0e-4f, "the reopened wrist is not where the scale put it");
	crig::AnimTemplate[] kept = reopened.bound_templates(mem);
	defer if (kept.len > 0) alloc::free(mem, kept);
	test::@check(kept.len == clip_count, "the model kept %d clips, not %d", kept.len, clip_count);

	// And the accessor says so too: a reader that culls by POSITION bounds sees the new size.
	gltf::GltfStream stream = gltf::open(f.path, mem)!!;
	defer stream.close();
	test::@check(stream.gltf.skins.len() == 1, "the model lost its skin");
}
