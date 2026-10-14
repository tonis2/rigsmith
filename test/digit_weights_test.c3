// The automatic weights on a hand: which joints are digits, how much of its own
// segment a finger joint holds, and a bind that does not depend on the units the
// model was saved in. All on the shipped humanoid, with its own skin set aside so
// the binder's answer is the one under test.
module crig_tests::digit_weights;

import crig;
import rig;
import std::core::test;
import std::io;
import std::io::file;
import std::math;

const String DIGIT_COPY = "build/digit-weights-humanoid.glb";

// The humanoid with its own skin set aside, optionally saved `scale` times larger.
fn void open_binder(crig::AppState* app, rig::TriMesh* mesh, String path, float scale = 1.0f)
{
	char[] original = file::load(mem, "assets/animations/humanoid.glb")!!;
	defer alloc::free(mem, original);
	file::save(path, original)!!;
	*mesh = rig::load_gltf(mem, path)!!;
	foreach (&p : mesh.positions) *p *= scale;
	*app = crig::new_app(*mesh, path);
	test::@check(app.import_rig_from_source(), "the humanoid rig must import");
	foreach (&dot : app.doc.dots.array_view())
	{
		dot.position *= scale;
		dot.reach *= scale;
	}
	app.doc.skin_from_file = false;
	app.mark_rig_stale();
}

fn void close_binder(crig::AppState* app, rig::TriMesh* mesh, String path)
{
	app.free();
	mesh.free(mem);
	(void)file::delete(path);
	String sidecar = crig::session_path(mem, path);
	defer sidecar.free(mem);
	(void)file::delete(sidecar);
}

fn bool is_finger(String name)
{
	String[5] fingers = { "index_", "middle_", "ring_", "pinky_", "thumb_" };
	foreach (finger : fingers) if (name.starts_with(finger)) return true;
	return false;
}

fn void digits_are_the_finger_chains() @test
{
	io::printn("the digits of the humanoid are its forty finger joints");
	crig::AppState app;
	rig::TriMesh mesh;
	open_binder(&app, &mesh, DIGIT_COPY);
	defer close_binder(&app, &mesh, DIGIT_COPY);

	crig::RigView view = app.open_rig(mem)!!;
	defer view.free(mem);
	bool[] digits = view.skeleton.digits(mem);
	defer alloc::free(mem, digits);
	usz marked = 0;
	foreach (b, digit : digits)
	{
		crig::Dot* dot = app.doc.find(view.dot_ids[b]);
		String name = dot ? dot.name : "";
		test::@check(digit == is_finger(name), "%s is %s a digit", name, digit ? "wrongly" : "not");
		if (digit) marked++;
	}
	test::eq(marked, (usz)40);
}

<*
 The middle of a finger segment moves with its own joint. Measured over the
 vertices nearest the segment that project into its middle 40%: the binder's
 falloff, flat at a finger's thickness, gave them under half on average (0.33 to
 0.61); a knuckle is where two joints share a vertex, and the middle of a
 segment is not. Now about four in five on average. The weakest is a ring finger
 segment whose skin touches the middle finger's, where the binder hands some
 vertices to the other finger outright.

 *Re-introduce:* bind with the fixed softness and no digit sharpening, and the
 segments hold under half of their middles.
*>
fn void a_finger_joint_holds_the_middle_of_its_segment() @test
{
	io::printn("a finger joint holds the middle of its own segment");
	crig::AppState app;
	rig::TriMesh mesh;
	open_binder(&app, &mesh, DIGIT_COPY);
	defer close_binder(&app, &mesh, DIGIT_COPY);

	crig::RigView view = app.open_rig(mem)!!;
	defer view.free(mem);
	usz bones = view.len();
	float[] bound = app.bind_dense(mem, &view, painted: false);
	defer alloc::free(mem, bound);
	Vec3[] tails = view.skeleton.tails(mem);
	defer alloc::free(mem, tails);
	bool[] digits = view.skeleton.digits(mem);
	defer alloc::free(mem, digits);

	// Each vertex's nearest segment, and where along it the vertex projects.
	Vec3[] joints = view.skeleton.joints;
	float worst = 1.0f;
	String worst_name = "";
	usz measured = 0;
	float overall = 0.0f;
	for (usz b = 0; b < bones; b++)
	{
		// The leaf's segment is extruded past the tip, not a bone between two joints.
		if (!digits[b] || !has_child(&view.skeleton, b)) continue;
		Vec3 axis = tails[b] - joints[b];
		float length_sq = axis.dot(axis);
		float held = 0.0f;
		usz counted = 0;
		foreach (usz v, p : app.geometry.positions)
		{
			float t = (p - joints[b]).dot(axis) / length_sq;
			if (t < 0.3f || t > 0.7f) continue;
			float own = segment_sq(p, joints[b], tails[b]);
			bool nearest = true;
			for (usz o = 0; o < bones && nearest; o++)
			{
				if (o != b && segment_sq(p, joints[o], tails[o]) < own) nearest = false;
			}
			if (!nearest) continue;
			float sum = 0.0f;
			for (usz o = 0; o < bones; o++) sum += bound[v * bones + o];
			held += sum > 0.0f ? bound[v * bones + b] / sum : 0.0f;
			counted++;
		}
		if (counted == 0) continue;
		measured++;
		float mean = held / (float)counted;
		overall += mean;
		if (mean < worst)
		{
			worst = mean;
			crig::Dot* dot = app.doc.find(view.dot_ids[b]);
			worst_name = dot ? dot.name : "";
		}
	}
	test::@check(measured >= 10, "only %d finger segments had a middle to measure", measured);
	overall /= (float)math::max(measured, (usz)1);
	test::@check(overall >= 0.75f, "finger joints hold %f of their segments' middles on average", overall);
	test::@check(worst >= 0.5f, "%s holds %f of the middle of its own segment", worst_name, worst);
}

fn bool has_child(rig::Skeleton* skeleton, usz joint)
{
	foreach (parent : skeleton.parents) if (parent == (int)joint) return true;
	return false;
}

fn float segment_sq(Vec3 p, Vec3 head, Vec3 tail)
{
	Vec3 axis = tail - head;
	float length_sq = axis.dot(axis);
	float t = length_sq > 0.0f ? math::clamp((p - head).dot(axis) / length_sq, 0.0f, 1.0f) : 0.0f;
	Vec3 d = p - (head + axis * t);
	return d.dot(d);
}

<*
 The binder's softness is a share of the model, not a length: the same model
 saved a hundred times larger gets a softness ten thousand times larger, and its
 falloff, measured straight to the bones, gives every vertex the same shares.
 (The geodesic bind's voxel grid rounds cell edges a little differently at each
 size, so the whole bind is not compared.)

 *Re-introduce:* have `bind_eps` return the fixed `1e-4`, and the larger model's
 finger vertices take different shares.
*>
fn void the_binders_softness_is_a_share_of_the_model() @test
{
	io::printn("the binder's softness is a share of the model's size");
	crig::AppState app;
	rig::TriMesh mesh;
	open_binder(&app, &mesh, DIGIT_COPY);
	defer close_binder(&app, &mesh, DIGIT_COPY);

	String scaled_path = "build/digit-weights-humanoid-scaled.glb";
	crig::AppState large;
	rig::TriMesh large_mesh;
	open_binder(&large, &large_mesh, scaled_path, 100.0f);
	defer close_binder(&large, &large_mesh, scaled_path);

	float small_eps = app.bind_eps();
	float large_eps = large.bind_eps();
	test::@check(math::abs(large_eps / small_eps - 1.0e4f) < 1.0f, "the softness went from %f to %f", small_eps, large_eps);

	crig::RigView view = app.open_rig(mem)!!;
	defer view.free(mem);
	crig::RigView large_view = large.open_rig(mem)!!;
	defer large_view.free(mem);
	usz bones = view.len();
	test::eq(large_view.len(), bones);
	float[] small_bind = rig::bind_geometric(mem, app.geometry.positions, view.skeleton.joints, view.skeleton.parents, eps: small_eps);
	defer alloc::free(mem, small_bind);
	float[] large_bind = rig::bind_geometric(mem, large.geometry.positions, large_view.skeleton.joints,
		large_view.skeleton.parents, eps: large_eps);
	defer alloc::free(mem, large_bind);

	usz differ = 0;
	float most = 0.0f;
	for (usz v = 0; v < app.geometry.positions.len; v++)
	{
		float a = 0.0f;
		float b = 0.0f;
		for (usz j = 0; j < bones; j++)
		{
			a += small_bind[v * bones + j];
			b += large_bind[v * bones + j];
		}
		if (a <= 0.0f || b <= 0.0f) continue;
		float gap = 0.0f;
		for (usz j = 0; j < bones; j++) gap = math::max(gap, math::abs(small_bind[v * bones + j] / a - large_bind[v * bones + j] / b));
		if (gap > 1.0e-3f) differ++;
		most = math::max(most, gap);
	}
	test::@check(differ == 0, "%d vertices bind differently at a hundred times the size, by up to %f", differ, most);
}

fn void sharpen_by_joint_leaves_rows_without_digits_alone() @test
{
	io::printn("sharpening by joint leaves rows without digits as they were");
	float[3] gammas = { 1.0f, 3.0f, 1.0f };
	float[9] dense = {
		2.0f, 0.0f, 2.0f,      // no digit: untouched
		3.0f, 1.0f, 0.0f,      // a quarter digit: a power between 1 and 3
		1.0f, 1.0e-6f, 0.0f,   // a digit's leak: kept above the floor
	};
	crig::sharpen_by_joint(dense[..], gammas[..]);

	test::@check(dense[0] == 2.0f && dense[1] == 0.0f && dense[2] == 2.0f, "a row with no digit changed: %s", dense[0:3]);

	float sum = dense[3] + dense[4] + dense[5];
	test::@check(dense[3] > dense[4], "the strongest joint of a row changed");
	test::@check(dense[4] / sum < 0.25f, "the digit's share was not narrowed: %f", dense[4] / sum);
	test::@check(math::abs(dense[4] / sum - 0.161f) < 0.01f, "the row was not raised to the mean power: %f", dense[4] / sum);

	test::@check(dense[7] > 0.0f, "a digit's leak was sharpened to nothing");
}
