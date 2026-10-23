// The automatic weights on a hand: which joints are digits, the knuckle planes
// that cut a finger into its segments (`rig::band_digits`), how much of its own
// segment a finger joint holds, and a bind that does not depend on the units the
// model was saved in. On a two-finger hand built here, and on the shipped
// humanoid with its own skin set aside so the binder's answer is the one under test.
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
	(void)app.release_all_recorded();
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
 falloff gave them about half on average (0.53, the weakest 0.37), since a
 segment is as long as the finger is thick. Cut at the knuckles they hold 0.98
 on average. The weakest is the thumb's first segment, at 0.88, beside the palm,
 where the wrist keeps the share the binder never gave the thumb.

 *Re-introduce:* drop `rig::band_digits` from `AppState.shape_bind`, and the
 segments hold about half of their middles.
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
	float[] bound = app.weights(mem, &view, AUTOMATIC);
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
	test::@check(overall >= 0.95f, "finger joints hold %f of their segments' middles on average", overall);
	test::@check(worst >= 0.85f, "%s holds %f of the middle of its own segment", worst_name, worst);
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

// The share of a row the hand under `fork` holds: the fork's and all its digits'.
fn float hand_share(rig::DigitBands* bands, rig::DigitFork fork, float[] row)
{
	float hand = row[fork.joint];
	for (usz c = fork.first; c < fork.first + fork.count; c++)
	{
		rig::DigitChain chain = bands.chains[c];
		for (usz k = 0; k < chain.count; k++) hand += row[bands.joints[chain.first + k]];
	}
	return hand;
}

fn bool is_hand_joint(rig::DigitBands* bands, rig::DigitFork fork, usz joint)
{
	if (joint == fork.joint) return true;
	for (usz c = fork.first; c < fork.first + fork.count; c++)
	{
		rig::DigitChain chain = bands.chains[c];
		for (usz k = 0; k < chain.count; k++) if (bands.joints[chain.first + k] == joint) return true;
	}
	return false;
}

<*
 The palm behind the knuckles is the wrist's: no vertex the hand holds most of,
 and that lies behind its finger's first knuckle by more than the blend, has a
 finger joint for its strongest. The binder's falloff alone gave 122 of the
 humanoid's 294 such vertices to a finger's first bone, which then moved the
 palm whenever the finger bent.

 *Re-introduce:* drop `rig::band_digits` from `AppState.shape_bind`, and 122 palm
 vertices are a finger's.
*>
fn void the_palm_behind_the_knuckles_belongs_to_the_wrist() @test
{
	io::printn("the palm behind the knuckles belongs to the wrist");
	crig::AppState app;
	rig::TriMesh mesh;
	open_binder(&app, &mesh, DIGIT_COPY);
	defer close_binder(&app, &mesh, DIGIT_COPY);

	crig::RigView view = app.open_rig(mem)!!;
	defer view.free(mem);
	usz bones = view.len();
	float[] bound = app.weights(mem, &view, AUTOMATIC);
	defer alloc::free(mem, bound);
	rig::DigitBands bands = rig::digit_bands(mem, &view.skeleton);
	defer bands.free(mem);
	test::@check(bands.forks.len == 2, "the humanoid has %d hands", bands.forks.len);

	float[64] along;
	usz behind = 0;
	usz taken = 0;
	foreach (usz v, p : app.geometry.positions)
	{
		float[] row = bound[v * bones : bones];
		float sum = 0.0f;
		foreach (w : row) sum += w;
		foreach (fork : bands.forks)
		{
			if (hand_share(&bands, fork, row) < 0.5f * sum) continue;
			bands.weights(bands.nearest_chain(fork, p), p, app.doc.knuckle_blend_fraction(), along[..]);
			if (along[0] < 1.0f) continue;
			behind++;
			sz owner = crig::row_owner(row);
			if (owner >= 0 && bands.digit[(usz)owner]) taken++;
		}
	}
	test::@check(behind >= 100, "only %d vertices lie behind the knuckles", behind);
	test::@check(taken == 0, "%d of the %d palm vertices behind the knuckles are a finger's", taken, behind);
}

<*
 Past the first knuckle a vertex of the hand is shared by at most two of the
 hand's joints — the two either side of the knuckle it is nearest — where the
 binder's falloff spread nearly every one of them over three or more.

 *Re-introduce:* drop `rig::band_digits` from `AppState.shape_bind`, and 786 of
 the humanoid's 787 finger vertices hold a third joint.
*>
fn void a_knuckle_blends_only_its_two_joints() @test
{
	io::printn("a finger vertex is shared by at most two of the hand's joints");
	crig::AppState app;
	rig::TriMesh mesh;
	open_binder(&app, &mesh, DIGIT_COPY);
	defer close_binder(&app, &mesh, DIGIT_COPY);

	crig::RigView view = app.open_rig(mem)!!;
	defer view.free(mem);
	usz bones = view.len();
	float[] bound = app.weights(mem, &view, AUTOMATIC);
	defer alloc::free(mem, bound);
	rig::DigitBands bands = rig::digit_bands(mem, &view.skeleton);
	defer bands.free(mem);

	float[64] along;
	usz past = 0;
	usz crowded = 0;
	foreach (usz v, p : app.geometry.positions)
	{
		float[] row = bound[v * bones : bones];
		float sum = 0.0f;
		foreach (w : row) sum += w;
		foreach (fork : bands.forks)
		{
			float hand = hand_share(&bands, fork, row);
			if (hand < 0.5f * sum) continue;
			bands.weights(bands.nearest_chain(fork, p), p, app.doc.knuckle_blend_fraction(), along[..]);
			if (along[0] > 0.0f) continue;
			past++;
			usz holding = 0;
			for (usz b = 0; b < bones; b++)
			{
				if (is_hand_joint(&bands, fork, b) && row[b] > 1.0e-3f * hand) holding++;
			}
			if (holding > 2) crowded++;
		}
	}
	test::@check(past >= 500, "only %d vertices lie past the first knuckles", past);
	test::@check(crowded == 0, "%d of %d finger vertices hold a third joint of the hand", crowded, past);
}

<*
 A knuckle blend of nothing cuts every finger at its joints: the bind changes,
 and all but a handful of the hand's vertices are one joint's outright. The
 handful are rows where the binder never trusted the finger with the wrist's
 share (`DIGIT_TRUST_LOW`), and a vertex of the forearm the wrist shares.

 *Re-introduce:* leave the knuckle blend out of `shape_bind`, and the bind does
 not change at all.
*>
fn void knuckle_blend_zero_is_a_hard_switch_and_rebinds() @test
{
	io::printn("a knuckle blend of nothing is a hard switch, and rebinds");
	crig::AppState app;
	rig::TriMesh mesh;
	open_binder(&app, &mesh, DIGIT_COPY);
	defer close_binder(&app, &mesh, DIGIT_COPY);

	crig::RigView view = app.open_rig(mem)!!;
	defer view.free(mem);
	usz bones = view.len();
	float[] soft = app.weights(mem, &view, AUTOMATIC);
	defer alloc::free(mem, soft);

	test::@check(app.set_knuckle_blend_recorded(crig::knuckle_blend_stored(0.0f)), "the blend did not change");
	app.undo_stack.commit();
	app.mark_rig_stale();
	test::@check(app.doc.knuckle_blend_fraction() == 0.0f, "a blend of nothing reads back as %f", app.doc.knuckle_blend_fraction());
	float[] hard = app.weights(mem, &view, AUTOMATIC);
	defer alloc::free(mem, hard);
	rig::DigitBands bands = rig::digit_bands(mem, &view.skeleton);
	defer bands.free(mem);

	usz changed = 0;
	usz rows = 0;
	usz shared = 0;
	foreach (usz v, p : app.geometry.positions)
	{
		float[] row = hard[v * bones : bones];
		for (usz b = 0; b < bones; b++)
		{
			if (math::abs(row[b] - soft[v * bones + b]) <= 1.0e-4f) continue;
			changed++;
			break;
		}
		float sum = 0.0f;
		foreach (w : row) sum += w;
		foreach (fork : bands.forks)
		{
			float hand = hand_share(&bands, fork, row);
			if (hand < 0.5f * sum) continue;
			rows++;
			float most = 0.0f;
			for (usz b = 0; b < bones; b++) if (is_hand_joint(&bands, fork, b)) most = math::max(most, row[b]);
			if (most < 0.999f * hand) shared++;
		}
	}
	test::@check(changed >= 200, "only %d vertices changed with the blend", changed);
	test::@check(rows >= 1000 && shared * 100 < rows, "%d of %d hand vertices are still shared at a blend of nothing", shared, rows);
}

// A forearm and a wrist with two three-joint fingers along +x, one either side of
// the hand's middle, and a root a metre below so the rig has a height to measure
// a digit's length against. The fingers' knuckles stand at x = 0.1, 0.13, 0.16.
const usz BAND_WRIST = 2;
const usz BAND_A1 = 3;
const usz BAND_A2 = 4;
const usz BAND_A3 = 5;
const usz BAND_B1 = 6;
const usz BAND_JOINTS = 9;

fn rig::Skeleton band_hand()
{
	Vec3[] joints = alloc::new_array(mem, Vec3, BAND_JOINTS);
	int[] parents = alloc::new_array(mem, int, BAND_JOINTS);
	Vec3[BAND_JOINTS] at = {
		{ 0, -1, 0 }, { -0.3f, 0, 0 }, { 0, 0, 0 },
		{ 0.1f, 0, 0.02f }, { 0.13f, 0, 0.02f }, { 0.16f, 0, 0.02f },
		{ 0.1f, 0, -0.02f }, { 0.13f, 0, -0.02f }, { 0.16f, 0, -0.02f },
	};
	int[BAND_JOINTS] up = { -1, 0, 1, 2, 3, 4, 2, 6, 7 };
	joints[..] = at[..];
	parents[..] = up[..];
	return { .joints = joints, .parents = parents };
}

// One vertex's row through `band_digits`, as shares.
fn float[BAND_JOINTS] banded(rig::Skeleton* hand, Vec3 at, float[BAND_JOINTS] row, float blend = 0.5f,
	int[] shell_of = {}, int[] riders = {})
{
	Vec3[1] position = { at };
	rig::band_digits(mem, row[..], position[..], hand, blend, shell_of, riders);
	float sum = 0.0f;
	foreach (w : row) sum += w;
	foreach (&w : row) *w /= sum;
	return row;
}

fn void the_hand_has_one_fork_and_two_chains() @test
{
	io::printn("the knuckle planes of a two-finger hand");
	rig::Skeleton hand = band_hand();
	defer hand.free(mem);
	rig::DigitBands bands = rig::digit_bands(mem, &hand);
	defer bands.free(mem);
	test::@check(bands.forks.len == 1 && bands.forks[0].joint == BAND_WRIST, "the wrist is not the hand's one fork");
	test::@check(bands.chains.len == 2 && bands.chains[0].count == 3, "the hand's fingers are not two chains of three");
}

<*
 A row the digits hold nothing of — the forearm, the other hand, the body — comes
 back exactly as the binder made it, unnormalised scores and all: the bands only
 ever move the share the hand already held.

 *Re-introduce:* normalise every row before deciding whether the hand holds any
 of it, and this row comes back as shares.
*>
fn void a_row_without_digits_is_left_alone() @test
{
	io::printn("a row the digits hold nothing of is left alone");
	rig::Skeleton hand = band_hand();
	defer hand.free(mem);
	float[BAND_JOINTS] row = { 3.0f, 5.0f, 2.0f, 1.0e-6f, 0, 0, 0, 0, 0 };
	float[BAND_JOINTS] kept = row;
	Vec3[1] position = { { 0.115f, 0.005f, 0.02f } };
	rig::band_digits(mem, row[..], position[..], &hand, 0.5f);
	foreach (b, w : row) test::@check(w == kept[b], "joint %d went from %f to %f", b, kept[b], w);
}

<*
 The middle of a segment is its own joint's outright, however the binder spread
 it: the planes either side of it are further than the blend reaches.

 *Re-introduce:* weight a finger by the binder's distance falloff, and the middle
 of a segment keeps the share its neighbours were given.
*>
fn void the_middle_of_a_segment_is_its_own_joints() @test
{
	io::printn("the middle of a finger segment is its own joint's");
	rig::Skeleton hand = band_hand();
	defer hand.free(mem);
	float[BAND_JOINTS] row = banded(&hand, { 0.115f, 0.005f, 0.02f }, { 0, 0, 0.3f, 0.4f, 0.3f, 0, 0, 0, 0 });
	test::@check(row[BAND_A1] >= 0.99f, "the segment's joint holds %f of its middle", row[BAND_A1]);
}

<*
 At a knuckle the two joints either side share the vertex and no third joint does:
 the fork and the next knuckle down are a whole ramp away, and the other finger
 keeps only the leak a brush can lift — never nothing.

 *Re-introduce:* spread a knuckle over the whole chain, or zero the other finger,
 and a third joint holds the knuckle or the leak is gone.
*>
fn void a_knuckle_holds_only_its_two_joints() @test
{
	io::printn("a knuckle is shared by the two joints either side of it");
	rig::Skeleton hand = band_hand();
	defer hand.free(mem);
	float[BAND_JOINTS] row = banded(&hand, { 0.13f, 0.005f, 0.02f }, { 0, 0, 0.2f, 0.3f, 0.3f, 0.1f, 0.1f, 0, 0 });
	test::@check(math::abs(row[BAND_A1] - 0.5f) < 0.01f && math::abs(row[BAND_A2] - 0.5f) < 0.01f,
		"the knuckle went %f / %f", row[BAND_A1], row[BAND_A2]);
	test::@check(row[BAND_WRIST] < 1.0e-6f && row[BAND_A3] < 1.0e-4f, "a third joint holds the knuckle: wrist %f, tip %f",
		row[BAND_WRIST], row[BAND_A3]);
	test::@check(row[BAND_B1] > 0.0f && row[BAND_B1] < 1.0e-4f, "the other finger holds %f", row[BAND_B1]);
}

<*
 The palm behind the first knuckle is the wrist's, whatever share of it the
 binder gave a finger: a finger's first bone starts at its knuckle.

 *Re-introduce:* let the band keep the binder's share behind the first plane,
 and the finger moves the palm.
*>
fn void the_palm_goes_to_the_wrist() @test
{
	io::printn("the palm behind the knuckles is the wrist's");
	rig::Skeleton hand = band_hand();
	defer hand.free(mem);
	float[BAND_JOINTS] row = banded(&hand, { 0.06f, 0.01f, 0.02f }, { 0, 0, 0.3f, 0.7f, 0, 0, 0, 0, 0 });
	test::@check(row[BAND_WRIST] >= 0.999f, "the wrist holds %f of the palm", row[BAND_WRIST]);
}

<*
 Past a knuckle plane but held by the fork, the bands take from the fork only
 what the binder already trusted the finger with — the planes run on through
 anything beyond them, a skull past an ear's first knuckle among it.

 *Re-introduce:* drop the trust guard, and the fork's vertex goes to the finger.
*>
fn void the_fork_keeps_what_the_finger_was_never_given() @test
{
	io::printn("the bands take from the fork only what the finger already held");
	rig::Skeleton hand = band_hand();
	defer hand.free(mem);
	float[BAND_JOINTS] row = banded(&hand, { 0.115f, 0.005f, 0.02f }, { 0, 0, 0.9f, 0.1f, 0, 0, 0, 0, 0 });
	test::@check(math::abs(row[BAND_WRIST] - 0.9f) < 1.0e-3f, "the fork went from 0.9 to %f", row[BAND_WRIST]);
}

<*
 A blend of nothing is a hard switch at the joint: a hair either side of a
 knuckle is one joint's or the other's, outright.

 *Re-introduce:* give the ramp a floor width, and a blend of 0 still shares the knuckle.
*>
fn void a_blend_of_nothing_is_a_step() @test
{
	io::printn("a knuckle blend of nothing is a step at the joint");
	rig::Skeleton hand = band_hand();
	defer hand.free(mem);
	float[BAND_JOINTS] spread = { 0, 0, 0.2f, 0.4f, 0.4f, 0, 0, 0, 0 };
	float[BAND_JOINTS] before = banded(&hand, { 0.1299f, 0.005f, 0.02f }, spread, 0.0f);
	float[BAND_JOINTS] after = banded(&hand, { 0.1301f, 0.005f, 0.02f }, spread, 0.0f);
	test::@check(before[BAND_A1] >= 0.999f, "before the knuckle the joint above holds %f", before[BAND_A1]);
	test::@check(after[BAND_A2] >= 0.999f, "past the knuckle the joint below holds %f", after[BAND_A2]);
}

<*
 A piece of the mesh bound rigidly to one joint keeps its row: banding it would
 bend a piece that is meant to move whole.

 *Re-introduce:* band every vertex regardless of its shell's rider.
*>
fn void a_rigid_piece_keeps_its_row() @test
{
	io::printn("a piece riding one joint rigidly is not banded");
	rig::Skeleton hand = band_hand();
	defer hand.free(mem);
	int[1] shell_of = { 0 };
	int[1] riders = { (int)BAND_A2 };
	float[BAND_JOINTS] row = banded(&hand, { 0.115f, 0.005f, 0.02f }, { 0, 0, 0, 0, 1.0f, 0, 0, 0, 0 }, 0.5f,
		shell_of[..], riders[..]);
	test::@check(row[BAND_A2] == 1.0f, "the rigid piece's joint went to %f", row[BAND_A2]);
}
