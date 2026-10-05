<*
 Look-at targets (anim/aim.c3): the sampler, the chain math, the clip rewriters
 and the copy and mirror helpers. Pure data: no app, no files.

     `c3c test --trust=full --test-noleak --test-filter crig_tests::aim`
*>
module crig_tests::aim;

import crig;
import rig;
import std::core::test;
import std::io;
import std::math;
import std::math::vector;
import std::math::quaternion;

// hips - chest - neck - head, straight up; the head looks down +Z at rest.
Vec3[4] chain_joints @local = { { 0, 1, 0 }, { 0, 1.3f, 0 }, { 0, 1.6f, 0 }, { 0, 1.8f, 0 } };
int[4] chain_parents @local = { -1, 0, 1, 2 };
String[4] chain_names @local = { "hips", "chest", "neck", "head" };
const Vec3 FORWARD = { 0, 0, 1 };

fn rig::Skeleton chain_rig() => { .joints = chain_joints[..], .parents = chain_parents[..] };

fn float turn_angle(Quaternionf q) => 2.0f * math::acos(math::min(1.0f, math::abs(q.l)));

fn bool pose_finite(rig::Pose pose)
{
	foreach (q : pose.rotations)
	{
		if (!math::is_finite(q.i) || !math::is_finite(q.j) || !math::is_finite(q.k) || !math::is_finite(q.l)) return false;
		if (math::abs(q.v.length() - 1.0f) > 1.0e-3f) return false;
	}
	return true;
}

<*
 The angle left between the head's aim axis and `target`, read from the pose.
*>
fn float miss(rig::Pose pose, Vec3 target, usz joint = 3)
{
	rig::Skeleton skeleton = chain_rig();
	Matrix4f[] palette = rig::joint_palette(mem, &skeleton, pose)!!;
	defer alloc::free(mem, palette);
	Quaternionf[] world = pose.world_rotations(mem, &skeleton)!!;
	defer alloc::free(mem, world);
	Vec3 to = (target - skeleton.joints[joint].transform(palette[joint])).normalize();
	Vec3 now = world[joint].rotate_vec3(FORWARD).normalize();
	return math::acos(math::clamp(to.dot(now), -1.0f, 1.0f));
}

fn Quaternionf neck_stiff(void* ctx, usz joint, Quaternionf local)
{
	return joint == 2 ? (Quaternionf)quaternion::IDENTITY : local;
}

<*
 A three-joint spread, default weights, and the target in front and to the side.
*>
fn float aim_head(rig::Pose* pose, Vec3 target, usz spread = 3, float influence = 1.0f, AimClamp clamp = null)
{
	rig::Skeleton skeleton = chain_rig();
	AimChain chain = crig::aim_chain_of(&skeleton, 3, spread);
	return crig::aim_chain(mem, &skeleton, pose, chain, crig::AIM_DEFAULT_WEIGHTS, FORWARD, target, influence, clamp);
}

fn void the_head_lands_exactly_on_the_target() @test
{
	io::printn("the aimed joint ends facing the target");
	rig::Pose pose = rig::rest_pose(mem, 4);
	defer pose.free(mem);
	Vec3 target = { 1.0f, 1.8f, 1.0f };
	float left = aim_head(&pose, target);
	test::@check(left < 1.0e-3f, "the chain reported %f radians left", left);
	test::@check(miss(pose, target) < 1.0e-3f, "the head is %f radians off its target", miss(pose, target));
	test::@check(pose_finite(pose), "a rotation lost its unit length");
	test::@check(turn_angle(pose.rotations[0]) == 0.0f, "the joint outside the chain turned");
}

fn void the_chest_takes_its_share_of_the_turn() @test
{
	io::printn("the top of the chain takes about a fifth of the turn");
	rig::Pose pose = rig::rest_pose(mem, 4);
	defer pose.free(mem);
	// The head looks 45 degrees round: the whole turn is a quarter of a half-turn.
	aim_head(&pose, { 1.0f, 1.8f, 1.0f });
	float whole = (float)math::PI / 4.0f;
	float chest = turn_angle(pose.rotations[1]);
	test::@check(math::abs(chest - 0.2f * whole) < 0.01f, "the chest turned %f of %f", chest, whole);
	test::@check(turn_angle(pose.rotations[3]) > turn_angle(pose.rotations[2]) * 0.9f,
		"the head took less than the neck");
}

fn void a_clamped_neck_leaves_its_share_to_the_head() @test
{
	io::printn("a joint a limit stops hands its share down the chain");
	rig::Pose free_pose = rig::rest_pose(mem, 4);
	defer free_pose.free(mem);
	rig::Pose stiff = rig::rest_pose(mem, 4);
	defer stiff.free(mem);
	Vec3 target = { 1.0f, 1.8f, 1.0f };
	aim_head(&free_pose, target);
	float left = aim_head(&stiff, target, 3, 1.0f, &neck_stiff);
	test::@check(turn_angle(stiff.rotations[2]) < 1.0e-4f, "the clamp was ignored");
	test::@check(turn_angle(stiff.rotations[3]) > turn_angle(free_pose.rotations[3]) + 0.05f,
		"the head did not make up the neck's share");
	test::@check(left < 1.0e-3f && miss(stiff, target) < 1.0e-3f, "the head missed by %f once the neck was held", left);
}

fn void degenerate_targets_give_no_nan() @test
{
	io::printn("a target behind, on the joint, or not a number turns nothing wrong");
	rig::Pose behind = rig::rest_pose(mem, 4);
	defer behind.free(mem);
	float left = aim_head(&behind, { 0, 1.8f, -1.0f });
	test::@check(pose_finite(behind) && math::is_finite(left), "a target straight behind made a bad rotation");
	test::@check(miss(behind, { 0, 1.8f, -1.0f }) < 1.0e-2f, "the head did not turn round to a target behind");

	rig::Pose on_it = rig::rest_pose(mem, 4);
	defer on_it.free(mem);
	aim_head(&on_it, { 0, 1.8f, 0 });
	test::@check(pose_finite(on_it), "a target on the joint made a bad rotation");
	foreach (q : on_it.rotations) test::@check(turn_angle(q) < 1.0e-4f, "a target on the joint turned something");

	rig::Pose nan = rig::rest_pose(mem, 4);
	defer nan.free(mem);
	aim_head(&nan, { float::nan, 0, 0 });
	test::@check(pose_finite(nan), "a NaN target made a bad rotation");
}

fn void influence_scales_the_turn() @test
{
	io::printn("influence 0 changes nothing and 0.5 gives half the turn");
	rig::Pose none = rig::rest_pose(mem, 4);
	defer none.free(mem);
	aim_head(&none, { 1.0f, 1.8f, 1.0f }, 3, 0.0f);
	foreach (q : none.rotations) test::@check(turn_angle(q) == 0.0f, "influence 0 still turned a joint");

	rig::Pose full = rig::rest_pose(mem, 4);
	defer full.free(mem);
	rig::Pose half = rig::rest_pose(mem, 4);
	defer half.free(mem);
	aim_head(&full, { 1.0f, 1.8f, 1.0f }, 1);
	aim_head(&half, { 1.0f, 1.8f, 1.0f }, 1, 0.5f);
	float ratio = turn_angle(half.rotations[3]) / turn_angle(full.rotations[3]);
	test::@check(math::abs(ratio - 0.5f) < 0.01f, "half influence gave %f of the turn", ratio);
}

fn AnimAimTarget two_keys(AnimInterpolation first = LINEAR)
{
	AnimAimTarget target = crig::aim_target_defaults(mem, "Target 1", { 0, 0, 0 }, 1.0f);
	alloc::free(mem, target.keys);
	target.keys = alloc::new_array(mem, AnimAimKey, 2);
	target.keys[0] = { .time = 1.0f, .at = { 0, 0, 0 }, .interpolation = first };
	target.keys[1] = { .time = 3.0f, .at = { 2, 0, 4 }, .interpolation = LINEAR };
	return target;
}

fn void the_sampler_holds_blends_and_wraps() @test
{
	io::printn("target_at holds the edges, blends, honours HOLD and wraps a loop");
	AnimAimTarget target = two_keys();
	defer target.free(mem);
	test::@check(target.target_at(0.0f, 4.0f, false) == (Vec3){ 0, 0, 0 }, "before the first key holds it");
	test::@check(target.target_at(9.0f, 4.0f, false) == (Vec3){ 2, 0, 4 }, "after the last key holds it");
	Vec3 mid = target.target_at(2.0f, 4.0f, false);
	test::@check(math::abs(mid.x - 1.0f) < 1.0e-5f && math::abs(mid.z - 2.0f) < 1.0e-5f, "the midpoint is not the middle");

	// Looping, duration 4: past the last key (t=3) the target comes back toward
	// the first (t=1 + 4 = 5), so t=4 is halfway home and t=0 is the same instant.
	Vec3 back = target.target_at(4.0f, 4.0f, true);
	test::@check(math::abs(back.x - 1.0f) < 1.0e-5f && math::abs(back.z - 2.0f) < 1.0e-5f, "the loop did not close: %s", back);
	Vec3 zero = target.target_at(0.0f, 4.0f, true);
	test::@check(math::abs(zero.x - 1.0f) < 1.0e-5f, "time 0 and time 4 of a loop disagree: %s", zero);
	Vec3 wrapped = target.target_at(6.0f, 4.0f, true);
	Vec3 once = target.target_at(2.0f, 4.0f, true);
	test::@check((wrapped - once).length() < 1.0e-5f, "a later cycle reads differently");

	AnimAimTarget held = two_keys(HOLD);
	defer held.free(mem);
	test::@check(held.target_at(2.0f, 4.0f, false) == (Vec3){ 0, 0, 0 }, "HOLD blended");
	test::@check(held.target_at(3.5f, 4.0f, false) == (Vec3){ 2, 0, 4 }, "the end key was not held");
}

fn AnimTemplate aimed_clip()
{
	AnimKeyDot[] dots = alloc::new_array(mem, AnimKeyDot, 1);
	dots[0] = { .joint_name = "hips".copy(mem), .axis = { 0, 1, 0 }, .angle = 0.1f, .channels = ROTATION };
	AnimKeyframe[] keys = alloc::new_array(mem, AnimKeyframe, 1);
	keys[0] = { .time = 0.0f, .dots = dots };
	AnimAimTarget[] targets = alloc::new_array(mem, AnimAimTarget, 1);
	targets[0] = two_keys();
	AnimAim[] aims = alloc::new_array(mem, AnimAim, 1);
	aims[0] = crig::aim_defaults(mem, "head_L", "Target 1", FORWARD);
	return { .name = "look".copy(mem), .duration = 4.0f, .keyframes = keys, .aims = aims, .aim_targets = targets,
		.loop = true, .owned = true };
}

fn void clip_rewriters_carry_the_aims() @test
{
	io::printn("every clip copy and rewrite keeps the aims and targets, retimes and crops move them");
	AnimTemplate clip = aimed_clip();
	defer clip.free(mem);

	AnimTemplate copy = crig::clip_copy(mem, clip);
	defer copy.free(mem);
	test::@check(copy.aims.len == 1 && copy.aim_targets.len == 1 && copy.aim_targets[0].keys.len == 2
		&& copy.aims[0].joint == "head_L" && copy.aims[0].target == "Target 1"
		&& copy.aims[0].joint.ptr != clip.aims[0].joint.ptr
		&& copy.aim_targets[0].keys.ptr != clip.aim_targets[0].keys.ptr, "crig::clip_copy lost or shared the aim");

	AnimTemplate retimed = crig::clip_retimed(mem, clip, 8.0f);
	defer retimed.free(mem);
	test::@check(retimed.aim_targets.len == 1 && retimed.aim_targets[0].keys[1].time == 6.0f, "a retime left the target times alone");

	AnimTemplate cropped = crig::clip_cropped(mem, clip, 0.5f, 3.5f);
	defer cropped.free(mem);
	test::@check(cropped.aims.len == 1 && cropped.aim_targets[0].keys[0].time == 0.5f && cropped.aim_targets[0].keys[1].time == 2.5f,
		"a crop did not shift the target times");

	AnimTemplate cut = crig::clip_range_cut(mem, clip, 1.0f, 2.0f);
	defer cut.free(mem);
	test::@check(cut.aims.len == 1 && cut.aim_targets.len == 1, "a range cut dropped the aim");

	AnimTemplate mirrored = crig::mirror_template(mem, clip, "look R", 0.0f);
	defer mirrored.free(mem);
	test::@check(mirrored.aims.len == 1 && mirrored.aims[0].joint == "head_R" && mirrored.aims[0].target == "Target 1"
		&& mirrored.aim_targets[0].name == "Target 1"
		&& mirrored.aim_targets[0].keys[1].at == (Vec3){ -2, 0, 4 }, "the mirror kept the left head, the name or the x sign");
}

fn void target_rewriters_edit_one_target() @test
{
	io::printn("crig::clip_with_aim_target, _target_key, _without_target_keys and _without_aim_target");
	AnimTemplate clip = aimed_clip();
	defer clip.free(mem);

	AnimTemplate keyed = crig::clip_with_target_key(mem, clip, "Target 1", { .time = 2.0f, .at = { 5, 5, 5 }, .interpolation = HOLD });
	defer keyed.free(mem);
	test::@check(keyed.aim_targets[0].keys.len == 3 && keyed.aim_targets[0].keys[1].time == 2.0f
		&& keyed.aim_targets[0].keys[1].at.x == 5.0f, "a key was not inserted in order");
	test::@check(clip.aim_targets[0].keys.len == 2, "the source clip was changed");

	AnimTemplate moved = crig::clip_with_target_key(mem, keyed, "Target 1", { .time = 2.0f, .at = { 9, 9, 9 } });
	defer moved.free(mem);
	test::@check(moved.aim_targets[0].keys.len == 3 && moved.aim_targets[0].keys[1].at.x == 9.0f,
		"a key at the same time was not replaced");

	AnimTemplate stranger = crig::clip_with_target_key(mem, clip, "Nothing", { .time = 2.0f });
	defer stranger.free(mem);
	test::@check(stranger.aim_targets[0].keys.len == 2, "a key for a missing target changed another");

	float[1] gone = { 2.0f };
	AnimTemplate thinned = crig::clip_without_target_keys(mem, moved, "Target 1", gone[..]);
	defer thinned.free(mem);
	test::@check(thinned.aim_targets[0].keys.len == 2, "the key was not removed");

	float[2] both = { 1.0f, 3.0f };
	AnimTemplate emptied = crig::clip_without_target_keys(mem, clip, "Target 1", both[..]);
	defer emptied.free(mem);
	test::@check(emptied.aim_targets.len == 0 && emptied.aims.len == 0, "a target left with no keys stayed, or its lock did");

	AnimTemplate second = crig::clip_with_aim_target(mem, clip, crig::aim_target_defaults(mem, "Target 2", { 1, 1, 1 }));
	defer second.free(mem);
	test::@check(second.aim_targets.len == 2 && second.aim_targets[1].name == "Target 2", "a target was not added");
	String next = crig::next_target_name(mem, second.aim_targets);
	defer next.free(mem);
	test::@check(next == "Target 3", "the next name is %s", next);
	AnimTemplate replaced = crig::clip_with_aim_target(mem, second, crig::aim_target_defaults(mem, "Target 2", { 7, 7, 7 }));
	defer replaced.free(mem);
	test::@check(replaced.aim_targets.len == 2 && replaced.aim_targets[1].keys[0].at.x == 7.0f, "a target of the same name was not replaced");

	AnimTemplate dropped = crig::clip_without_aim_target(mem, clip, "Target 1");
	defer dropped.free(mem);
	test::@check(dropped.aim_targets.len == 0 && dropped.aims.len == 0, "removing a target kept its lock");
	test::@check(clip.aims.len == 1, "the source lost its lock");
	String lowest = crig::next_target_name(mem, dropped.aim_targets);
	defer lowest.free(mem);
	test::@check(lowest == "Target 1", "the lowest unused name was not reused");
}

fn void lock_rewriters_edit_one_joint() @test
{
	io::printn("crig::clip_with_aim, _with_aims_added and _without_aim are keyed by joint");
	AnimTemplate clip = aimed_clip();
	defer clip.free(mem);

	AnimAim fresh = crig::aim_defaults(mem, "tail", "Target 1", FORWARD);
	AnimTemplate added = crig::clip_with_aim(mem, clip, fresh);
	defer added.free(mem);
	test::@check(added.aims.len == 2 && added.aims[1].joint == "tail" && added.aim_targets.len == 1, "a lock was not added");
	AnimAim again = crig::aim_defaults(mem, "tail", "Target 1", { 1, 0, 0 });
	AnimTemplate replaced = crig::clip_with_aim(mem, added, again);
	defer replaced.free(mem);
	test::@check(replaced.aims.len == 2 && replaced.aims[1].forward.x == 1.0f, "a lock on the same joint was not replaced");

	AnimAim[] batch = alloc::new_array(mem, AnimAim, 3);
	batch[0] = crig::aim_defaults(mem, "tail", "Target 1", { 0, 1, 0 }); // replaces
	batch[1] = crig::aim_defaults(mem, "hand_L", "Target 1", FORWARD);
	batch[2] = crig::aim_defaults(mem, "hand_R", "Target 1", FORWARD);
	AnimTemplate many = crig::clip_with_aims_added(mem, replaced, batch);
	defer many.free(mem);
	test::@check(many.aims.len == 4 && many.aims[1].forward.y == 1.0f && many.aims[3].joint == "hand_R",
		"a batch of locks was not added with replacement");

	AnimTemplate removed = crig::clip_without_aim(mem, replaced, "head_L");
	defer removed.free(mem);
	test::@check(removed.aims.len == 1 && removed.aims[0].joint == "tail" && removed.aim_targets.len == 1,
		"the wrong lock was removed, or the target went with it");
}

fn void aim_pose_applies_by_name_and_records_what_it_touched() @test
{
	io::printn("crig::aim_pose resolves joints and targets by name, skips muted, and records the originals");
	rig::Skeleton skeleton = chain_rig();
	rig::Pose pose = rig::rest_pose(mem, 4);
	defer pose.free(mem);
	AnimAimTarget[] targets = alloc::new_array(mem, AnimAimTarget, 1);
	targets[0] = crig::aim_target_defaults(mem, "Target 1", { 0.5f, 0.9f, 0.5f });
	defer crig::free_aim_targets(mem, targets);
	AnimAim aim = crig::aim_defaults(mem, "head", "Target 1", FORWARD);
	defer aim.free(mem);
	AnimAim[1] aims = { aim };

	// Muted lock: nothing happens.
	aims[0].mute = true;
	crig::aim_pose(mem, &skeleton, chain_names[..], aims[..], targets, 0.0f, 1.0f, false, &pose, 2.0f);
	test::@check(turn_angle(pose.rotations[3]) == 0.0f, "a muted lock turned the head");
	aims[0].mute = false;

	// Muted target, and a target that is not there.
	targets[0].mute = true;
	crig::aim_pose(mem, &skeleton, chain_names[..], aims[..], targets, 0.0f, 1.0f, false, &pose, 2.0f);
	test::@check(turn_angle(pose.rotations[3]) == 0.0f, "a muted target turned the head");
	targets[0].mute = false;
	crig::aim_pose(mem, &skeleton, chain_names[..], aims[..], {}, 0.0f, 1.0f, false, &pose, 2.0f);
	test::@check(turn_angle(pose.rotations[3]) == 0.0f, "a missing target turned the head");

	AimAppliedSet applied;
	defer applied.free(mem);
	crig::aim_pose(mem, &skeleton, chain_names[..], aims[..], targets, 0.0f, 1.0f, false, &pose, 2.0f, null, null, &applied);
	test::@check(turn_angle(pose.rotations[3]) > 0.1f, "the head did not turn");
	test::@check(applied.joints.len == 3 && applied.has(1) && applied.has(2) && applied.has(3) && !applied.has(0),
		"the applied set holds %d joints", applied.joints.len);
	test::@check(turn_angle(applied.before_of(3)) == 0.0f, "the recorded rotation is not the one from before");
	// Targets are fractions of the rig's height: 2.0 here, so the target is {1,1.8,1}.
	test::@check(miss(pose, { 1.0f, 1.8f, 1.0f }) < 1.0e-3f, "the target was not scaled by the rig height");

	rig::Pose faded = rig::rest_pose(mem, 4);
	defer faded.free(mem);
	crig::aim_pose(mem, &skeleton, chain_names[..], aims[..], targets, 0.0f, 1.0f, false, &faded, 2.0f, null, null, null, 0.0f);
	test::@check(turn_angle(faded.rotations[3]) == 0.0f, "a zero gain still turned the head");
}

fn void locks_apply_parents_first() @test
{
	io::printn("a chain locked together lands both joints on the target, whatever the order of the locks");
	rig::Skeleton skeleton = chain_rig();
	rig::Pose pose = rig::rest_pose(mem, 4);
	defer pose.free(mem);
	AnimAimTarget[] targets = alloc::new_array(mem, AnimAimTarget, 1);
	targets[0] = crig::aim_target_defaults(mem, "Target 1", { 0.5f, 0.9f, 0.5f });
	defer crig::free_aim_targets(mem, targets);
	// The child is listed first on purpose; each turns by itself (spread 1).
	AnimAim[] aims = alloc::new_array(mem, AnimAim, 2);
	defer crig::free_aims(mem, aims);
	aims[0] = crig::aim_defaults(mem, "head", "Target 1", FORWARD);
	aims[0].spread = 1;
	aims[1] = crig::aim_defaults(mem, "neck", "Target 1", FORWARD);
	aims[1].spread = 1;

	crig::aim_pose(mem, &skeleton, chain_names[..], aims, targets, 0.0f, 1.0f, false, &pose, 2.0f);
	Vec3 target = { 1.0f, 1.8f, 1.0f };
	test::@check(miss(pose, target, 2) < 1.0e-3f, "the neck is %f off its target", miss(pose, target, 2));
	test::@check(miss(pose, target, 3) < 1.0e-3f, "the head is %f off its target", miss(pose, target, 3));
}

fn void two_locks_follow_one_target() @test
{
	io::printn("two joints locked to one target both turn when it moves");
	rig::Skeleton skeleton = chain_rig();
	AnimAimTarget[] targets = alloc::new_array(mem, AnimAimTarget, 1);
	targets[0] = two_keys();
	defer crig::free_aim_targets(mem, targets);
	AnimAim[] aims = alloc::new_array(mem, AnimAim, 2);
	defer crig::free_aims(mem, aims);
	aims[0] = crig::aim_defaults(mem, "head", "Target 1", FORWARD);
	aims[0].spread = 1;
	aims[1] = crig::aim_defaults(mem, "chest", "Target 1", FORWARD);
	aims[1].spread = 1;

	rig::Pose early = rig::rest_pose(mem, 4);
	defer early.free(mem);
	rig::Pose late = rig::rest_pose(mem, 4);
	defer late.free(mem);
	crig::aim_pose(mem, &skeleton, chain_names[..], aims, targets, 1.0f, 4.0f, false, &early, 2.0f);
	crig::aim_pose(mem, &skeleton, chain_names[..], aims, targets, 3.0f, 4.0f, false, &late, 2.0f);
	test::@check(miss(early, { 0, 0, 0 }, 3) < 1.0e-3f && miss(late, { 4.0f, 0, 8.0f }, 3) < 1.0e-3f, "the head did not follow");
	test::@check(miss(early, { 0, 0, 0 }, 1) < 1.0e-3f && miss(late, { 4.0f, 0, 8.0f }, 1) < 1.0e-3f, "the chest did not follow");
}

fn void aim_copy_and_mirror_leave_nothing_behind() @test
{
	io::printn("crig::aims_copy, aim_targets_copy, the mirrors and the free functions balance");
	AnimAimTarget[] targets = alloc::new_array(mem, AnimAimTarget, 1);
	targets[0] = two_keys();
	defer crig::free_aim_targets(mem, targets);
	AnimAim[] source = alloc::new_array(mem, AnimAim, 2);
	source[0] = crig::aim_defaults(mem, "head", "Target 1", FORWARD);
	source[1] = crig::aim_defaults(mem, "hand_L", "Target 1", { 1, 0, 0 });
	defer crig::free_aims(mem, source);

	AnimAim[] copy = crig::aims_copy(mem, source);
	test::@check(copy.len == 2 && copy[0].joint == "head" && copy[0].target == "Target 1"
		&& copy[0].target.ptr != source[0].target.ptr, "the copy is shallow");
	crig::free_aims(mem, copy);
	AnimAimTarget[] kept = crig::aim_targets_copy(mem, targets);
	test::@check(kept.len == 1 && kept[0].keys.len == 2 && kept[0].keys.ptr != targets[0].keys.ptr, "the target copy is shallow");
	crig::free_aim_targets(mem, kept);

	AnimAim[] mirrored = crig::aims_mirrored(mem, source);
	defer crig::free_aims(mem, mirrored);
	test::@check(mirrored[1].joint == "hand_R" && mirrored[1].forward.x == -1.0f && mirrored[1].target == "Target 1",
		"the mirror did not flip the twin and x");
	test::@check(mirrored[0].joint == "head", "a joint with no twin was renamed");
	AnimAimTarget[] flipped = crig::aim_targets_mirrored(mem, targets);
	defer crig::free_aim_targets(mem, flipped);
	test::@check(flipped[0].name == "Target 1" && flipped[0].keys[1].at.x == -2.0f && targets[0].keys[1].at.x == 2.0f,
		"the target mirror did not flip x, or changed its source");
}
