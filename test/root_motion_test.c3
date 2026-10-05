<*
 Root motion and key reduction at export, replayed by the outside glTF player in
 gltf_replay_test, plus the Animations menu's Make in place.

     `c3c test --trust=full --test-filter crig_tests::root_motion`
*>
module crig_tests::root_motion;

import crig;
import rig;
import gltf;
import gltf_edit;
import crig_tests::gltf_replay;
import crig_tests::pose_clipboard;
import crig_tests::trust_fixes;
import std::core::test;
import std::io;
import std::io::file;
import std::math;
import std::math::vector;
import std::math::matrix;
import std::math::quaternion;

const String OUT = "build/root-motion.glb";

// The replay fixture with a root joint at the floor under its hips.
const String[8] ROOTED_JOINTS = {
	"root", "hips", "spine", "head", "arm_L", "arm_R", "leg_L", "leg_R",
};
const int[8] ROOTED_PARENTS = { -1, 0, 1, 2, 2, 2, 1, 1 };

fn rig::Skeleton rooted_skeleton()
{
	Vec3[] joints = alloc::new_array(mem, Vec3, 8);
	int[] parents = alloc::new_array(mem, int, 8);
	joints[0] = { 0.05f, 0.0f, 0.02f };
	foreach (usz j, at : gltf_replay::REST) joints[j + 1] = at;
	foreach (usz j, p : ROOTED_PARENTS) parents[j] = p;
	return { .joints = joints, .parents = parents };
}

fn crig::AnimKeyDot dot(String joint, Vec3 axis, float angle, Vec3 move = {}, crig::AnimChannels channels = BOTH)
{
	return { .joint_name = joint.copy(mem), .axis = axis, .angle = angle, .move = move, .channels = channels };
}

<*
 A walk that carries the hips forward and to the side with a bob and sway on
 the way, and swings an arm. With `turning` the hips also turn 0.8 rad.
*>
fn crig::AnimTemplate walk(bool turning = false, crig::AnimBlend blend = LINEAR, String hips = "hips")
{
	const usz KEYS = 5;
	crig::AnimKeyframe[] frames = alloc::new_array(mem, crig::AnimKeyframe, KEYS);
	for (usz k = 0; k < KEYS; k++)
	{
		float f = (float)k / (float)(KEYS - 1);
		float sway = k % 2 == 1 ? 0.03f : -0.02f;
		float bob = k % 2 == 1 ? 0.02f : 0.0f;
		crig::AnimKeyDot[] dots = alloc::new_array(mem, crig::AnimKeyDot, 2);
		dots[0] = dot(hips, { 0, 1, 0 }, turning ? 0.8f * f : 0.0f, { 0.25f * f + sway, bob, 0.4f * f });
		dots[1] = dot("arm_L", { 0, 0, 1 }, k % 2 == 1 ? -0.7f : 0.2f, {}, ROTATION);
		frames[k] = { .time = f, .dots = dots };
	}
	return { .name = "walk".copy(mem), .duration = 1.0f, .keyframes = frames, .blend = blend, .owned = true };
}

// World position of a joint under a pose.
fn Vec3 joint_at(rig::Skeleton* skeleton, rig::Pose pose, usz joint)
{
	Matrix4f[] palette = rig::joint_palette(mem, skeleton, pose)!!;
	defer alloc::free(mem, palette);
	Vec3 j = skeleton.joints[joint];
	float[<4>] moved = palette[joint].apply({ j.x, j.y, j.z, 1.0f });
	return { moved.x, moved.y, moved.z };
}

<*
 The viewport pose at `t` with the policy applied the way the export applies it.
*>
fn rig::Pose expected_pose(rig::Skeleton* skeleton, String[] names, crig::AnimTemplate clip,
	crig::RootMotionPolicy policy, float t)
{
	rig::Pose pose = clip.pose(mem, skeleton, names, t);
	if (!policy.active()) return pose;
	crig::MotionRoots roots = crig::motion_roots(skeleton, names);
	float until = clip.keyframes[clip.keyframes.len - 1].time;
	rig::Pose first = clip.pose(mem, skeleton, names, 0.0f);
	defer first.free(mem);
	rig::Pose last = clip.pose(mem, skeleton, names, until);
	defer last.free(mem);
	crig::RootTravel travel = crig::measure_root_travel(skeleton, roots, &first, &last, until, policy);
	crig::move_root_in_pose(skeleton, &pose, roots, policy.mode, travel, t);
	return pose;
}

struct Replayed
{
	float joints;   // worst joint gap against the expected pose
	float vertices; // worst vertex gap; 0 when `binding` is empty
	float others;   // worst gap of every joint but the root against the unchanged viewport
}

<*
 Replay the written file against the viewport with the policy applied, joint by
 joint (matched by name) and, with a binding, vertex by vertex.
*>
fn Replayed? replay(String path, rig::Skeleton* skeleton, String[] names, crig::AnimTemplate clip,
	crig::RootMotionPolicy policy, rig::TriMesh body = {}, gltf::SkinBinding binding = {}, usz samples = 49)
{
	gltf::GltfStream stream = gltf::open(path, mem)!;
	defer stream.close();
	stream.load_all_buffers()!;

	gltf::Skin skin = stream.gltf.skins[0];
	usz[] to_crig = alloc::new_array(mem, usz, (sz)skin.joints.len());
	defer alloc::free(mem, to_crig);
	for (usz k = 0; k < (usz)skin.joints.len(); k++)
	{
		String name = stream.gltf.nodes.get_ref((sz)skin.joints[(sz)k]).name;
		to_crig[k] = names.len;
		foreach (usz j, joint : names) if (joint == name) to_crig[k] = j;
	}
	crig::MotionRoots roots = crig::motion_roots(skeleton, names);

	Replayed out;
	Vec3[] here = alloc::new_array(mem, Vec3, (sz)body.positions.len);
	defer alloc::free(mem, here);
	for (usz step = 0; step < samples; step++)
	{
		float t = clip.duration * (float)step / (float)(samples - 1);
		rig::Pose want = expected_pose(skeleton, names, clip, policy, t);
		defer want.free(mem);
		rig::Pose shown = clip.pose(mem, skeleton, names, t);
		defer shown.free(mem);
		Matrix4f[] palette = rig::joint_palette(mem, skeleton, want)!!;
		defer alloc::free(mem, palette);
		Matrix4f[] viewport = rig::joint_palette(mem, skeleton, shown)!!;
		defer alloc::free(mem, viewport);

		gltf_replay::ReplayFrame frame = gltf_replay::replay_frame(mem, &stream, 0, t)!;
		defer frame.free(mem);
		foreach (usz k, at : frame.joints)
		{
			usz j = to_crig[k];
			if (j >= names.len) continue;
			Vec3 rest = skeleton.joints[j];
			float[<4>] a = palette[j].apply({ rest.x, rest.y, rest.z, 1.0f });
			out.joints = math::max(out.joints, (at - (Vec3){ a.x, a.y, a.z }).length());
			if ((sz)j != roots.root)
			{
				float[<4>] b = viewport[j].apply({ rest.x, rest.y, rest.z, 1.0f });
				out.others = math::max(out.others, (at - (Vec3){ b.x, b.y, b.z }).length());
			}
		}
		if (binding.slots > 0)
		{
			gltf_replay::skin_through(here, body.positions, binding, palette);
			foreach (usz v, at : frame.vertices) out.vertices = math::max(out.vertices, (at - here[v]).length());
		}
	}
	return out;
}

// Where a named joint is in the written file at `t`.
fn Vec3? file_joint(String path, String name, float t)
{
	gltf::GltfStream stream = gltf::open(path, mem)!;
	defer stream.close();
	stream.load_all_buffers()!;
	gltf_replay::ReplayFrame frame = gltf_replay::replay_frame(mem, &stream, 0, t)!;
	defer frame.free(mem);
	gltf::Skin skin = stream.gltf.skins[0];
	for (usz k = 0; k < (usz)skin.joints.len(); k++)
	{
		if (stream.gltf.nodes.get_ref((sz)skin.joints[(sz)k]).name == name) return frame.joints[k];
	}
	return {};
}

fn bool same_bytes(char[] a, char[] b)
{
	if (a.len != b.len) return false;
	foreach (usz i, c : a) if (b[i] != c) return false;
	return true;
}

macro bool same_values(a, b)
{
	if (a.len != b.len) return false;
	for (usz i = 0; i < a.len; i++)
	{
		if (!same_bytes(@as_char_view(a[i]), @as_char_view(b[i]))) return false;
	}
	return true;
}

fn void motion_roots_finds_a_root_joint_only_under_the_hips() @test
{
	gltf_replay::Bench* bench = gltf_replay::setup();
	crig::MotionRoots plain = crig::motion_roots(&bench.skeleton, gltf_replay::JOINTS[..]);
	test::eq(plain.root, (sz)-1);
	test::eq(plain.hips, (sz)0);

	rig::Skeleton rooted = rooted_skeleton();
	defer rooted.free(mem);
	crig::MotionRoots found = crig::motion_roots(&rooted, ROOTED_JOINTS[..]);
	test::eq(found.root, (sz)0);
	test::eq(found.hips, (sz)1);
}

<*
 In place: the file replays the viewport with the travel taken off, joints and
 skin, while the sway and bob stay on the hips.
*>
fn void an_in_place_export_replays_the_viewport_without_travel() @test
{
	gltf_replay::Bench* bench = gltf_replay::setup();
	crig::AnimTemplate clip = walk();
	defer clip.free(mem);
	crig::AnimTemplate[1] clips = { clip };
	crig::ExportMotion motion = { .root = { .mode = IN_PLACE } };
	crig::ExportMotionReport report;
	crig::export_rigged_animated_glb(mem, OUT, bench.body, &bench.skeleton, gltf_replay::JOINTS[..],
		bench.dense, clips[..], "body", motion: motion, motion_report: &report)!!;
	defer (void)file::delete(OUT);
	test::eq(report.moved, (usz)1);

	Replayed gaps = replay(OUT, &bench.skeleton, gltf_replay::JOINTS[..], clip, motion.root,
		bench.body, bench.preview)!!;
	io::printfn("  in place: joints %.7f, vertices %.7f", gaps.joints, gaps.vertices);
	test::@check(gaps.joints < gltf_replay::EXACT && gaps.vertices < gltf_replay::EXACT,
		"the in-place file does not replay the viewport minus its travel");

	Vec3 start = file_joint(OUT, "hips", 0.0f)!!;
	Vec3 end = file_joint(OUT, "hips", 1.0f)!!;
	Vec3 middle = file_joint(OUT, "hips", 0.25f)!!;
	test::@check(math::abs(end.x - start.x) < 1.0e-4f && math::abs(end.z - start.z) < 1.0e-4f,
		"the hips still travel (%.4f, %.4f)", end.x - start.x, end.z - start.z);
	test::@check(math::abs(end.y - start.y) < 1.0e-4f, "height changed with height left off");
	test::@check(middle.y - start.y > 0.01f, "the bob was taken off with the travel");
	test::@check(math::abs(middle.x - start.x) > 0.01f, "the sway was taken off with the travel");
}

<*
 On the root joint: every joint but the root replays exactly where the viewport
 shows it, and the root carries the hips' travel.
*>
fn void a_root_motion_export_moves_travel_onto_the_root_joint() @test
{
	gltf_replay::Bench* bench = gltf_replay::setup();
	rig::Skeleton rooted = rooted_skeleton();
	defer rooted.free(mem);
	float[] skin = rig::bind_geometric(mem, bench.body.positions, rooted.joints, rooted.parents);
	defer alloc::free(mem, skin);

	foreach (turning : (bool[]){ false, true })
	{
		crig::AnimTemplate clip = walk(turning);
		defer clip.free(mem);
		crig::AnimTemplate[1] clips = { clip };
		crig::ExportMotion motion = { .root = { .mode = ON_ROOT, .turning = turning } };
		crig::ExportMotionReport report;
		crig::export_rigged_animated_glb(mem, OUT, bench.body, &rooted, ROOTED_JOINTS[..],
			skin, clips[..], "body", motion: motion, motion_report: &report)!!;
		test::eq(report.moved, (usz)1);

		Replayed gaps = replay(OUT, &rooted, ROOTED_JOINTS[..], clip, motion.root)!!;
		io::printfn("  on root (turning %s): joints %.7f, others vs viewport %.7f", turning, gaps.joints, gaps.others);
		float tolerance = turning ? 1.0e-3f : gltf_replay::EXACT;
		test::@check(gaps.joints < tolerance, "the root-motion file does not replay its intended pose");
		test::@check(gaps.others < tolerance, "a joint under the root moved away from the viewport");

		rig::Pose first = clip.pose(mem, &rooted, ROOTED_JOINTS[..], 0.0f);
		defer first.free(mem);
		rig::Pose last = clip.pose(mem, &rooted, ROOTED_JOINTS[..], 1.0f);
		defer last.free(mem);
		Vec3 hips_travel = joint_at(&rooted, last, 1) - joint_at(&rooted, first, 1);
		Vec3 root_travel = file_joint(OUT, "root", 1.0f)!! - file_joint(OUT, "root", 0.0f)!!;
		test::@check(math::abs(root_travel.x - hips_travel.x) < 1.0e-4f
			&& math::abs(root_travel.z - hips_travel.z) < 1.0e-4f && math::abs(root_travel.y) < 1.0e-5f,
			"the root travels (%.4f, %.4f, %.4f); the hips (%.4f, %.4f)", root_travel.x, root_travel.y,
			root_travel.z, hips_travel.x, hips_travel.z);
	}
	(void)file::delete(OUT);
}

<*
 In place on a rig whose travel is already on its root joint: the root and hips
 both end where they start.
*>
fn void in_place_takes_travel_off_a_root_joint_too() @test
{
	gltf_replay::Bench* bench = gltf_replay::setup();
	rig::Skeleton rooted = rooted_skeleton();
	defer rooted.free(mem);
	float[] skin = rig::bind_geometric(mem, bench.body.positions, rooted.joints, rooted.parents);
	defer alloc::free(mem, skin);
	crig::AnimTemplate clip = walk(hips: "root");
	defer clip.free(mem);
	crig::AnimTemplate[1] clips = { clip };
	crig::ExportMotion motion = { .root = { .mode = IN_PLACE } };
	crig::export_rigged_animated_glb(mem, OUT, bench.body, &rooted, ROOTED_JOINTS[..],
		skin, clips[..], "body", motion: motion)!!;
	defer (void)file::delete(OUT);
	foreach (name : (String[]){ "root", "hips" })
	{
		Vec3 moved = file_joint(OUT, name, 1.0f)!! - file_joint(OUT, name, 0.0f)!!;
		test::@check(math::abs(moved.x) < 1.0e-4f && math::abs(moved.z) < 1.0e-4f,
			"%s still travels (%.4f, %.4f)", name, moved.x, moved.z);
	}
	Replayed gaps = replay(OUT, &rooted, ROOTED_JOINTS[..], clip, motion.root)!!;
	test::@check(gaps.joints < gltf_replay::EXACT, "the in-place file misses its intended pose by %.6f", gaps.joints);
}

<*
 Light and Strong write fewer keys and still replay the viewport within their
 tolerance; Strong keeps no more than Light.
*>
fn void a_reduced_export_writes_fewer_keys_and_still_replays() @test
{
	gltf_replay::Bench* bench = gltf_replay::setup();
	crig::AnimTemplate clip = walk(blend: SMOOTH);
	defer clip.free(mem);
	crig::AnimTemplate[1] clips = { clip };
	float height = bench.skeleton.height();
	usz[3] written;
	Replayed baseline;
	foreach (usz i, reduce : (crig::KeyReduction[]){ OFF, LIGHT, STRONG })
	{
		crig::ExportMotion motion = { .reduce = reduce };
		crig::ExportMotionReport report;
		crig::export_rigged_animated_glb(mem, OUT, bench.body, &bench.skeleton, gltf_replay::JOINTS[..],
			bench.dense, clips[..], "body", motion: motion, motion_report: &report)!!;
		written[i] = report.keys_after;
		Replayed gaps = replay(OUT, &bench.skeleton, gltf_replay::JOINTS[..], clip, {},
			bench.body, bench.preview, 97)!!;
		if (reduce == OFF) baseline = gaps;
		// The full bake's own gap between samples, plus what reduction may add.
		float reach = 1.5f * reduce.tolerance(height).reach;
		io::printfn("  reduce %s: %d of %d keys, joints %.6f, vertices %.6f (full bake %.6f / %.6f, + %.6f)",
			reduce, report.keys_after, report.keys_before, gaps.joints, gaps.vertices,
			baseline.joints, baseline.vertices, reach);
		test::@check(gaps.joints <= baseline.joints + reach && gaps.vertices <= baseline.vertices + reach,
			"a reduced file strays from the viewport");
		if (reduce == OFF) test::eq(report.keys_after, report.keys_before);
		if (reduce != OFF) test::@check(report.keys_after < report.keys_before, "reduction dropped no keys");
	}
	test::@check(written[2] <= written[1] && written[1] < written[0], "Strong kept more keys than Light");
	(void)file::delete(OUT);
}

<*
 A held span keeps its start and both sides of its jump: the hips hold exactly
 through the span and jump on the next key.
*>
fn void reduction_keeps_step_edges() @test
{
	gltf_replay::Bench* bench = gltf_replay::setup();
	crig::AnimTemplate clip = walk(blend: SMOOTH);
	defer clip.free(mem);
	clip.keyframes[1].dots[0].translation_interpolation = HOLD;
	crig::AnimTemplate[1] clips = { clip };
	crig::ExportMotion motion = { .reduce = STRONG };
	crig::ExportMotionReport report;
	crig::export_rigged_animated_glb(mem, OUT, bench.body, &bench.skeleton, gltf_replay::JOINTS[..],
		bench.dense, clips[..], "body", motion: motion, motion_report: &report)!!;
	defer (void)file::delete(OUT);
	test::@check(report.keys_after < report.keys_before, "nothing was reduced around the hold");

	foreach (t : (float[]){ 0.25f, 0.3f, 0.4f, 0.4999f, 0.5f })
	{
		rig::Pose shown = clip.pose(mem, &bench.skeleton, gltf_replay::JOINTS[..], t);
		defer shown.free(mem);
		Vec3 want = joint_at(&bench.skeleton, shown, 0);
		Vec3 got = file_joint(OUT, "hips", t)!!;
		test::@check((got - want).length() < 1.0e-4f, "the held hips stray at %.4f s by %.5f", t, (got - want).length());
	}
	Vec3 before = file_joint(OUT, "hips", 0.4999f)!!;
	Vec3 after = file_joint(OUT, "hips", 0.5f)!!;
	test::@check((after - before).length() > 0.01f, "the hold's jump was smoothed away");
}

<*
 The default options write the file the export always wrote: no options, an
 explicit As authored with reduction Off, and a report asked for all give the
 same bytes, on both writers.
*>
fn void default_export_options_write_the_same_bytes() @test
{
	gltf_replay::Bench* bench = gltf_replay::setup();
	crig::AnimTemplate a = gltf_replay::fixture_clip(mem);
	defer a.free(mem);
	crig::AnimTemplate b = walk(blend: SMOOTH);
	defer b.free(mem);
	crig::AnimTemplate[2] clips = { a, b };
	String plain = "build/root-motion-plain.glb";
	String keep = "build/root-motion-keep.glb";
	defer { (void)file::delete(plain); (void)file::delete(keep); }
	crig::export_rigged_animated_glb(mem, plain, bench.body, &bench.skeleton, gltf_replay::JOINTS[..],
		bench.dense, clips[..], "body")!!;
	crig::ExportMotionReport report;
	crig::export_rigged_animated_glb(mem, keep, bench.body, &bench.skeleton, gltf_replay::JOINTS[..],
		bench.dense, clips[..], "body", motion: { .root = { .mode = KEEP }, .reduce = OFF },
		motion_report: &report)!!;
	char[] x = file::load(mem, plain)!!;
	defer alloc::free(mem, x);
	char[] y = file::load(mem, keep)!!;
	defer alloc::free(mem, y);
	test::@check(same_bytes(x, y), "options off changed the written file");
	test::@check(report.keys_before > 0 && report.keys_after == report.keys_before, "the report did not count the keys");

	gltf_edit::ReskinClip[] one = crig::reskin_clips(mem, &bench.skeleton, gltf_replay::JOINTS[..], clips[..]);
	defer crig::free_reskin_clips(mem, one);
	gltf_edit::ReskinClip[] two = crig::reskin_clips(mem, &bench.skeleton, gltf_replay::JOINTS[..], clips[..],
		{}, { .root = { .mode = KEEP }, .reduce = OFF }, &report);
	defer crig::free_reskin_clips(mem, two);
	test::eq(one.len, two.len);
	foreach (usz c, clip : one)
	{
		test::@check(same_values(clip.times, two[c].times), "the model writer's times changed");
		test::eq(clip.curves.len, two[c].curves.len);
		foreach (usz k, curve : clip.curves)
		{
			test::@check(same_values(curve.turns, two[c].curves[k].turns)
				&& same_values(curve.slides, two[c].curves[k].slides),
				"the model writer's curves changed");
		}
	}
}

// The model writer (Save and a whole-model export) reduces the same way.
fn void the_model_writer_reduces_and_counts_keys() @test
{
	gltf_replay::Bench* bench = gltf_replay::setup();
	crig::AnimTemplate clip = walk(blend: SMOOTH);
	defer clip.free(mem);
	crig::AnimTemplate[1] clips = { clip };
	gltf_edit::ReskinClip[] full = crig::reskin_clips(mem, &bench.skeleton, gltf_replay::JOINTS[..], clips[..]);
	defer crig::free_reskin_clips(mem, full);
	crig::ExportMotionReport report;
	gltf_edit::ReskinClip[] light = crig::reskin_clips(mem, &bench.skeleton, gltf_replay::JOINTS[..], clips[..],
		{}, { .reduce = LIGHT, .root = { .mode = IN_PLACE } }, &report);
	defer crig::free_reskin_clips(mem, light);
	test::@check(light.len == 1 && light[0].times.len < full[0].times.len, "the model writer kept every key");
	test::@check(report.moved == 1 && report.keys_after < report.keys_before, "the model writer's report is empty");
	test::@check(light[0].times[0] == full[0].times[0]
		&& light[0].times[light[0].times.len - 1] == full[0].times[full[0].times.len - 1],
		"reduction dropped the first or last key");
}

<*
 Rewriting the clip itself: in place keeps the hips at their start at the last
 key, sway intact; on the root joint every other joint keeps its world place at
 the keys.
*>
fn void the_clip_rewrite_moves_travel_in_its_keys() @test
{
	gltf_replay::Bench* bench = gltf_replay::setup();
	crig::AnimTemplate clip = walk();
	defer clip.free(mem);
	crig::AnimTemplate placed;
	test::eq(crig::clip_root_moved(mem, clip, &bench.skeleton, gltf_replay::JOINTS[..], { .mode = IN_PLACE }, &placed),
		crig::RootMotionOutcome.MOVED);
	defer placed.free(mem);
	rig::Pose start = placed.pose(mem, &bench.skeleton, gltf_replay::JOINTS[..], 0.0f);
	defer start.free(mem);
	rig::Pose end = placed.pose(mem, &bench.skeleton, gltf_replay::JOINTS[..], 1.0f);
	defer end.free(mem);
	Vec3 moved = joint_at(&bench.skeleton, end, 0) - joint_at(&bench.skeleton, start, 0);
	test::@check(math::abs(moved.x) < 1.0e-4f && math::abs(moved.z) < 1.0e-4f, "the rewritten clip still travels");
	for (usz k = 0; k < clip.keyframes.len; k++)
	{
		float t = clip.keyframes[k].time;
		rig::Pose want = expected_pose(&bench.skeleton, gltf_replay::JOINTS[..], clip, { .mode = IN_PLACE }, t);
		defer want.free(mem);
		rig::Pose got = placed.pose(mem, &bench.skeleton, gltf_replay::JOINTS[..], t);
		defer got.free(mem);
		for (usz j = 0; j < bench.skeleton.len(); j++)
		{
			float gap = (joint_at(&bench.skeleton, want, j) - joint_at(&bench.skeleton, got, j)).length();
			test::@check(gap < 1.0e-5f, "joint %d is %.6f off at %.2f s", j, gap, t);
		}
	}
	crig::AnimTemplate again;
	test::eq(crig::clip_root_moved(mem, placed, &bench.skeleton, gltf_replay::JOINTS[..], { .mode = IN_PLACE }, &again),
		crig::RootMotionOutcome.NO_TRAVEL);
	test::eq(crig::clip_root_moved(mem, clip, &bench.skeleton, gltf_replay::JOINTS[..], { .mode = ON_ROOT }, &again),
		crig::RootMotionOutcome.NO_ROOT_JOINT);

	rig::Skeleton rooted = rooted_skeleton();
	defer rooted.free(mem);
	foreach (turning : (bool[]){ false, true })
	{
		crig::AnimTemplate turned = walk(turning);
		defer turned.free(mem);
		crig::AnimTemplate on_root;
		test::eq(crig::clip_root_moved(mem, turned, &rooted, ROOTED_JOINTS[..], { .mode = ON_ROOT, .turning = turning },
			&on_root), crig::RootMotionOutcome.MOVED);
		defer on_root.free(mem);
		for (usz k = 0; k < turned.keyframes.len; k++)
		{
			float t = turned.keyframes[k].time;
			rig::Pose before = turned.pose(mem, &rooted, ROOTED_JOINTS[..], t);
			defer before.free(mem);
			rig::Pose after = on_root.pose(mem, &rooted, ROOTED_JOINTS[..], t);
			defer after.free(mem);
			for (usz j = 1; j < rooted.len(); j++)
			{
				float gap = (joint_at(&rooted, before, j) - joint_at(&rooted, after, j)).length();
				test::@check(gap < 1.0e-4f, "turning %s: joint %d moved %.6f at %.2f s", turning, j, gap, t);
			}
		}
		rig::Pose end_pose = on_root.pose(mem, &rooted, ROOTED_JOINTS[..], 1.0f);
		defer end_pose.free(mem);
		test::@check(joint_at(&rooted, end_pose, 0).z - rooted.joints[0].z > 0.1f, "the root joint does not travel");
	}
}

<*
 Make in place on the edited clip is one undo step, and a rig rooted at its hips
 refuses Move travel to root joint with a notice.
*>
fn void make_in_place_is_one_undo_step() @test
{
	pose_clipboard::Figure f;
	bool opened = f.open();
	defer f.close();
	if (!opened) { test::@check(false, "could not build the biped fixture"); return; }
	test::@check(!f.app.has_root_joint(), "the biped should be rooted at its hips");

	// Carry the hips forward over the clip.
	test::@check(f.app.pose_from_clip(f.app.editing, 1.0f), "could not sample the end");
	f.app.edit_time = 1.0f;
	test::@check(f.app.set_working_pose(f.hips, quaternion::IDENTITY, { 0.3f, 0.0f, 0.5f }), "could not move the hips");
	f.app.pose_edit_pending = true;
	test::@check(f.app.key_pose_edit(), "could not key the travel");
	f.app.undo_stack.clear();
	crig::AnimTemplate* clip = f.app.clip(f.app.editing);
	Vec3 travelled = clip.entry_at("hips", 1.0f).move;
	test::@check(travelled.length() > 0.1f, "the fixture does not travel");

	sz cursor = f.app.undo_stack.cursor;
	test::@check(f.app.move_clip_travel(f.app.editing, { .mode = IN_PLACE }), "Make in place did nothing: %s", f.app.notice());
	test::eq(f.app.undo_stack.cursor, cursor + 1);
	clip = f.app.clip(f.app.editing);
	Vec3 now = clip.entry_at("hips", 1.0f).move - clip.entry_at("hips", 0.0f).move;
	test::@check(math::abs(now.x) < 1.0e-4f && math::abs(now.z) < 1.0e-4f, "the hips still travel");
	test::@check(f.app.undo(), "Make in place would not undo");
	test::@check((f.app.clip(f.app.editing).entry_at("hips", 1.0f).move - travelled).length() < 1.0e-6f,
		"undo did not bring the travel back");

	cursor = f.app.undo_stack.cursor;
	test::@check(!f.app.move_clip_travel(f.app.editing, { .mode = ON_ROOT }), "a hips-rooted rig took root motion");
	test::eq(f.app.undo_stack.cursor, cursor);
	test::@check(f.app.notice().contains("no root joint"), "no notice said why: %s", f.app.notice());
}

<*
 Remove movement with height ticked takes the rise out of the hips' travel as
 well; without it the height is left in.
*>
fn void remove_movement_takes_height_only_when_asked() @test
{
	pose_clipboard::Figure f;
	bool opened = f.open();
	defer f.close();
	if (!opened) { test::@check(false, "could not build the biped fixture"); return; }

	test::@check(f.app.pose_from_clip(f.app.editing, 1.0f), "could not sample the end");
	f.app.edit_time = 1.0f;
	test::@check(f.app.set_working_pose(f.hips, quaternion::IDENTITY, { 0.3f, 0.4f, 0.5f }), "could not move the hips");
	f.app.pose_edit_pending = true;
	test::@check(f.app.key_pose_edit(), "could not key the travel");
	f.app.undo_stack.clear();

	float rise = f.app.clip(f.app.editing).entry_at("hips", 1.0f).move.y - f.app.clip(f.app.editing).entry_at("hips", 0.0f).move.y;
	test::@check(rise > 0.1f, "the fixture does not rise");
	test::@check(f.app.move_clip_travel(f.app.editing, { .mode = IN_PLACE }), "Remove movement did nothing: %s", f.app.notice());
	crig::AnimTemplate* clip = f.app.clip(f.app.editing);
	float kept = clip.entry_at("hips", 1.0f).move.y - clip.entry_at("hips", 0.0f).move.y;
	test::@check(math::abs(kept - rise) < 1.0e-3f, "ground-only removal changed the height (%f vs %f)", kept, rise);

	test::@check(f.app.move_clip_travel(f.app.editing, { .mode = IN_PLACE, .vertical = true }), "removing height did nothing: %s", f.app.notice());
	clip = f.app.clip(f.app.editing);
	float left = clip.entry_at("hips", 1.0f).move.y - clip.entry_at("hips", 0.0f).move.y;
	test::@check(math::abs(left) < 1.0e-3f, "the height is still there (%f)", left);
}

<*
 Pinned removal holds the hips over their start at every key, so a walk that
 goes out and comes back — no travel from start to end — still stays on the
 spot, keeping its height. One undo step.
*>
fn void pinned_removal_holds_an_out_and_back_walk() @test
{
	pose_clipboard::Figure f;
	bool opened = f.open();
	defer f.close();
	if (!opened) { test::@check(false, "could not build the biped fixture"); return; }

	test::@check(f.app.pose_from_clip(f.app.editing, 0.5f), "could not sample the middle");
	f.app.edit_time = 0.5f;
	test::@check(f.app.set_working_pose(f.hips, quaternion::IDENTITY, { 0.3f, 0.2f, 0.5f }), "could not move the hips");
	f.app.pose_edit_pending = true;
	test::@check(f.app.key_pose_edit(), "could not key the excursion");
	test::@check(f.app.pose_from_clip(f.app.editing, 1.0f), "could not sample the end");
	f.app.edit_time = 1.0f;
	f.app.pose_edit_pending = true;
	test::@check(f.app.key_pose_edit(), "could not key the return");
	f.app.undo_stack.clear();
	crig::AnimTemplate* clip = f.app.clip(f.app.editing);
	Vec3 start = clip.entry_at("hips", 0.0f).move;
	Vec3 out = clip.entry_at("hips", 0.5f).move - start;
	test::@check(math::abs(out.x) > 0.1f && math::abs(out.z) > 0.1f, "the fixture does not wander");
	test::@check((clip.entry_at("hips", 1.0f).move - start).length() < 1.0e-4f, "the fixture does not come back");

	test::@check(!f.app.move_clip_travel(f.app.editing, { .mode = IN_PLACE }), "a start-to-end line saw travel in an out-and-back walk");
	sz cursor = f.app.undo_stack.cursor;
	test::@check(f.app.move_clip_travel(f.app.editing, { .mode = IN_PLACE, .pinned = true }), "pinned removal did nothing: %s", f.app.notice());
	test::eq(f.app.undo_stack.cursor, cursor + 1);
	clip = f.app.clip(f.app.editing);
	Vec3 now = clip.entry_at("hips", 0.5f).move - clip.entry_at("hips", 0.0f).move;
	test::@check(math::abs(now.x) < 1.0e-4f && math::abs(now.z) < 1.0e-4f, "the hips still wander (%f, %f)", now.x, now.z);
	test::@check(math::abs(now.y - out.y) < 1.0e-3f, "pinning changed the height (%f vs %f)", now.y, out.y);
}

<*
 Optimize keys drops the keys a straight run of keys does not need, leaves the
 motion where it was, and is one undo step.
*>
fn void optimize_keys_drops_keys_and_keeps_the_motion() @test
{
	pose_clipboard::Figure f;
	bool opened = f.open();
	defer f.close();
	if (!opened) { test::@check(false, "could not build the biped fixture"); return; }

	for (int i = 0; i <= 10; i++)
	{
		float t = (float)i * 0.1f;
		test::@check(f.app.pose_from_clip(f.app.editing, t), "could not sample at %f", t);
		f.app.edit_time = t;
		test::@check(f.app.set_working_pose(f.hips, quaternion::IDENTITY, { 0.01f + 0.3f * t, 0.0f, 0.5f * t }), "could not move the hips");
		f.app.pose_edit_pending = true;
		test::@check(f.app.key_pose_edit(), "could not key at %f", t);
	}
	f.app.undo_stack.clear();
	usz before = f.app.clip(f.app.editing).keyframes.len;
	Vec3 mid_before = f.app.clip(f.app.editing).entry_at("hips", 0.55f).move;
	test::@check(before >= 8, "the fixture has too few keys (%d)", before);

	sz cursor = f.app.undo_stack.cursor;
	test::@check(f.app.optimize_clip_keys(f.app.editing, LIGHT), "Optimize keys did nothing: %s", f.app.notice());
	test::eq(f.app.undo_stack.cursor, cursor + 1);
	usz after = f.app.clip(f.app.editing).keyframes.len;
	test::@check(after < before, "no keys were dropped (%d of %d)", after, before);
	Vec3 mid_after = f.app.clip(f.app.editing).entry_at("hips", 0.55f).move;
	test::@check((mid_after - mid_before).length() < 1.0e-3f, "the motion moved by %f", (mid_after - mid_before).length());
	test::@check(f.app.clip(f.app.editing).keyframes[0].time < 1.0e-4f, "the first key went");

	test::@check(f.app.undo(), "Optimize keys would not undo");
	test::@check(f.app.clip(f.app.editing).keyframes.len == before, "undo left %d keys", f.app.clip(f.app.editing).keyframes.len);
}

<*
 The Export dialog's choices through the app: a whole-model export of the
 humanoid with its bound clip, in place and with Light reduction, says in its
 notice how many keys it wrote, and the project clip is unchanged.
*>
fn void an_app_export_reports_the_keys_it_wrote() @test
{
	String source = "build/root-motion-source.glb";
	String exported = "build/root-motion-export.glb";
	trust_fixes::copy_humanoid(source);
	defer
	{
		trust_fixes::remove_with_sidecar(source);
		trust_fixes::remove_with_sidecar(exported);
	}
	rig::TriMesh mesh = rig::load_gltf(mem, source)!!;
	defer mesh.free(mem);
	crig::AppState app = crig::new_app(mesh, source);
	defer app.free();
	test::@check(app.import_rig_from_source(), "the humanoid rig must import");
	crig::AnimTemplate[] clips = app.bound_templates(mem);
	defer if (clips.len > 0) alloc::free(mem, clips);
	if (clips.len == 0) { test::@check(false, "the humanoid has no bound clip"); return; }
	// One clip is enough to show what an export does to it; exporting them all
	// only multiplies the bake time.
	crig::AnimTemplate[] one = clips[:1];
	usz keys = one[0].keyframes.len;

	app.export_rig(exported, one, { .root = { .mode = IN_PLACE }, .reduce = LIGHT });
	io::printfn("  %s", app.notice());
	test::@check(file::is_file(exported), "the export wrote nothing: %s", app.notice());
	test::@check(app.notice().contains("keys written"), "the notice does not count keys: %s", app.notice());
	crig::AnimTemplate[] after = app.bound_templates(mem);
	defer if (after.len > 0) alloc::free(mem, after);
	test::@check(after.len == clips.len, "the export changed how many clips the project has");
	test::@check(after.len > 0 && after[0].keyframes.len == keys, "the export changed the project clip");

	// Clips alone keep their authored keys: root motion rewrites copies, reduction is skipped and said so.
	String clips_only = "build/root-motion-clips.glb";
	defer (void)file::delete(clips_only);
	app.export_clips_only(clips_only, one, { .root = { .mode = IN_PLACE }, .reduce = LIGHT });
	test::@check(file::is_file(clips_only), "the clips-only export wrote nothing: %s", app.notice());
	test::@check(app.notice().contains("keys kept as authored"), "the clips-only notice: %s", app.notice());
}
