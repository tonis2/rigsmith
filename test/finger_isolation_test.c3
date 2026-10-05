// A finger is its own part: on the shipped humanoid, no vertex a finger owns holds
// weight on a neighbouring finger, whichever way the weights were made, and
// bending one finger leaves the next one where it was.
module crig_tests::finger_isolation;

import crig;
import rig;
import gltf;
import std::core::test;
import std::io;
import std::io::file;
import std::math;

const String FINGER_COPY = "build/finger-isolation-humanoid.glb";

struct Fixture
{
	crig::AppState app;
	crig::RigView view;
	rig::TriMesh mesh;
}

fn void Fixture.open(&self)
{
	char[] original = file::load(mem, "assets/animations/humanoid.glb")!!;
	defer alloc::free(mem, original);
	file::save(FINGER_COPY, original)!!;
	self.mesh = rig::load_gltf(mem, FINGER_COPY)!!;
	self.app = crig::new_app(self.mesh, FINGER_COPY);
	test::@check(self.app.import_rig_from_source(), "the humanoid rig must import");
	self.view = self.app.open_rig(mem)!!;
}

fn void Fixture.close(&self)
{
	self.view.free(mem);
	self.app.free();
	self.mesh.free(mem);
	(void)file::delete(FINGER_COPY);
	String sidecar = crig::session_path(mem, FINGER_COPY);
	defer sidecar.free(mem);
	(void)file::delete(sidecar);
}

// Which finger a joint belongs to ("index", "middle", ...) on the left hand, or "".
fn String finger_of(String name)
{
	if (!name.ends_with("_L")) return "";
	String[4] fingers = { "index_", "middle_", "ring_", "pinky_" };
	foreach (finger : fingers)
	{
		if (name.starts_with(finger)) return finger;
	}
	return "";
}

// Vertices owned by `finger` that hold more than `floor` of the row on `other`.
fn usz leaks(Fixture* f, float[] dense, String finger, String other, float floor)
{
	usz bones = f.view.len();
	usz count = f.app.geometry.positions.len;
	usz found = 0;
	usz owned = 0;
	for (usz v = 0; v < count; v++)
	{
		sz owner = crig::row_owner(dense[v * bones:bones]);
		if (owner < 0 || finger_of(f.view.names[(usz)owner]) != finger) continue;
		owned++;
		float sum = 0.0f;
		float foreign = 0.0f;
		for (usz b = 0; b < bones; b++)
		{
			sum += dense[v * bones + b];
			if (finger_of(f.view.names[b]) == other) foreign += dense[v * bones + b];
		}
		if (foreign / sum > floor) found++;
	}
	test::@check(owned > 0, "no vertex is owned by %s", finger);
	return found;
}

<*
 The weights the app shows and deforms with (the file's, on this asset) and the
 binder's own, both, keep every finger's vertices off the fingers beside it.
*>
fn void a_finger_holds_nothing_of_its_neighbour() @test
{
	io::printn("a finger's vertices hold no weight on the neighbouring finger");
	Fixture f;
	f.open();
	defer f.close();

	float[] shown = f.app.painted_bind(mem, &f.view);
	defer alloc::free(mem, shown);
	float[] binder = rig::bind_geodesic(mem, &f.app.voxels, f.app.geometry.positions,
		f.view.skeleton.joints, f.view.skeleton.parents, &f.app.shells, f.view.attachments,
		reaches: f.view.reaches);
	defer alloc::free(mem, binder);

	float[][2] both = { shown, binder };
	foreach (dense : both)
	{
		String[] fingers = { "index_", "middle_", "ring_", "pinky_" };
		foreach (a : fingers)
		{
			foreach (b : fingers)
			{
				if (a == b) continue;
				test::eq(leaks(&f, dense, a, b, 1.0e-3f), (usz)0);
			}
		}
	}
}

<*
 Bending the index knuckle 66 degrees leaves every vertex of the middle finger
 exactly where it was. The palm may blend between the wrist and the knuckles, so
 only what a finger owns is held still.
*>
fn void bending_one_finger_leaves_the_next_still() @test
{
	io::printn("bending index_1_L leaves the middle finger's vertices unmoved");
	Fixture f;
	f.open();
	defer f.close();

	usz bones = f.view.len();
	usz count = f.app.geometry.positions.len;
	float[] painted = f.app.painted_bind(mem, &f.view);
	defer alloc::free(mem, painted);

	gltf::SkinBinding binding = gltf::sparsify_weights(mem, painted, count, bones, crig::SKIN_INFLUENCES)!!;
	defer binding.free(mem);

	rig::Pose pose = rig::rest_pose(mem, bones);
	defer { alloc::free(mem, pose.rotations); alloc::free(mem, pose.offsets); }
	usz index_1 = bones;
	foreach (j, name : f.view.names) if (name == "index_1_L") index_1 = (usz)j;
	test::@check(index_1 < bones, "the humanoid has no index_1_L");
	pose.turn(index_1, { 0, 0, 1 }, 66.0f * math::PI / 180.0f);

	Matrix4f[] palette = rig::joint_palette(mem, &f.view.skeleton, pose)!!;
	defer alloc::free(mem, palette);
	Vec3[] out = alloc::new_array(mem, Vec3, (sz)count);
	defer alloc::free(mem, out);
	rig::skin_positions(out, f.app.geometry.positions, binding, palette)!!;

	usz middle = 0;
	usz index = 0;
	float index_travel = 0.0f;
	for (usz v = 0; v < count; v++)
	{
		sz owner = crig::row_owner(painted[v * bones:bones]);
		String finger = finger_of(f.view.names[(usz)owner]);
		float moved = (out[v] - f.app.geometry.positions[v]).length();
		if (finger == "middle_")
		{
			middle++;
			test::@check(moved < 1.0e-4f, "middle vertex %d moved %f", v, (double)moved);
		}
		if (finger == "index_")
		{
			index++;
			if (moved > index_travel) index_travel = moved;
		}
	}
	test::@check(middle > 0 && index > 0, "no finger vertices found");
	test::@check(index_travel > 0.005f, "the index finger did not move (%f)", (double)index_travel);
}
