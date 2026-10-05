<*
 Writing poses down as keyframes, and rewriting the clips that hold them.

     `c3c test --trust=full --test-filter crig_tests::keying`

 `anim/keying.c3` is what the timeline edits *through*: every operation it offers
 is "build a new clip from the old one", because that is what `put_authored_clip`
 turns into a single undo entry. So the checks here are about the rewriters
 themselves, with no window, no `AppState` and no library — which is also the
 shape `make-anims` can reach them in.

 Two things are asserted everywhere and stated once here. **Ownership**: a
 rewriter's result owns its strings and its arrays, so each check frees the
 result and the leak-tracked run is what proves it. **Immutability of the
 source**: every rewriter leaves what it was given alone, because the clip it was
 given is the one still in the library.
*>
module crig_tests::keying;

import crig;
import rig;
import std::core::test;
import std::io;
import std::math;
import std::math::vector;
import std::math::quaternion;



<*
 Release a keyframe nothing took ownership of.

 `AnimTemplate.free` walks the keys inside a clip, so a key handed to
 `clip_with_key` is freed with the clip that took it. One built and left standing
 — which is what these checks do to look at it — has no owner, and this is it.
*>
fn void free_key(AnimKeyframe key)
{
	foreach (dot : key.dots)
	{
		if (dot.joint_name.len > 0) alloc::free(mem, dot.joint_name.ptr);
	}
	if (key.dots.len > 0) alloc::free(mem, key.dots);
}

// Three joints, named, which is the least a keyframe can address.
String[3] names = { "hips", "knee", "foot" };

// One bone direction per joint, so entries record something to retarget from.
Vec3[3] bones = { { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 } };

<*
 A pose with `knee` turned and `hips` slid, and `foot` left at rest.
*>
fn rig::Pose posed(float angle = 0.5f)
{
	rig::Pose pose = rig::rest_pose(mem, 3);
	pose.rotations[1] = quaternion::from_axis_angle{float}(((Vec3){ 1, 0, 0 }), angle);
	pose.offsets[0] = { 0, 0.25f, 0 };
	return pose;
}

<*
 A clip of `count` keys, one every 0.25 s, each a slightly different pose.
*>
fn AnimTemplate built(usz count, bool loops = false)
{
	AnimKeyframe[] frames = alloc::new_array(mem, AnimKeyframe, (sz)count);
	for (usz i = 0; i < count; i++)
	{
		rig::Pose pose = posed(0.2f + 0.1f * (float)i);
		defer pose.free(mem);
		frames[i] = crig::keyframe_of_pose(mem, pose, names[..], bones[..], 1.0f, 0.25f * (float)i);
	}

	return {
		.name = "walk".copy(mem),
		.duration = 0.25f * (float)(count - 1),
		.keyframes = frames,
		.loop = loops,
		.owned = true,
	};
}

<*
 A pose becomes a keyframe carrying every joint away from rest, and only those.

 The cull is the claim: an omitted joint already *means* rest to
 `AnimTemplate.pose`, so writing an identity entry for it would be two vectors
 and a name per joint per key saying what silence says. The other half is that
 the joints which did move are all there — a key that dropped one would be a pose
 nobody authored.
*>
fn void a_pose_becomes_a_keyframe() @test
{
	io::printn("a pose is written down as the joints that left rest");

	rig::Pose pose = posed();
	defer pose.free(mem);

	AnimKeyframe key = crig::keyframe_of_pose(mem, pose, names[..], bones[..], 1.0f, 0.5f);
	defer free_key(key);

	test::@check(key.time == 0.5f, "the key landed at %s", key.time);
	test::@check(key.dots.len == 3, "%d joints were written, wanted all three including rest", key.dots.len);

	bool has_hips = false;
	bool has_knee = false;
	foreach (dot : key.dots)
	{
		if (dot.joint_name == "hips") has_hips = true;
		if (dot.joint_name == "knee") has_knee = true;
		if (dot.joint_name == "foot") test::@check(dot.angle == 0 && dot.move == (Vec3){}, "rest key changed the pose");
	}
	test::@check(has_hips && has_knee, "a joint that moved was left out");

	// The bone direction rides along, which is the whole of retargeting: an entry
	// with no bone is one `AnimTemplate.pose` will not carry onto another rig.
	foreach (dot : key.dots)
	{
		test::@check(dot.bone.length() > 0.5f, "%s recorded no bone to retarget from", dot.joint_name);
	}

	// The offset is a fraction of rig height, so the same pose on a rig twice as
	// tall writes half the number. This is the unit the format is in and the one
	// thing about it a caller can get wrong.
	AnimKeyframe scaled = crig::keyframe_of_pose(mem, pose, names[..], bones[..], 2.0f, 0.0f);
	defer free_key(scaled);
	test::@check(math::abs(scaled.offset_of("hips").y - 0.125f) < 1.0e-6f,
		"the offset was not divided by the rig height — %s", scaled.offset_of("hips").y);

	// A rig with no height would divide by zero. One is the stand-in, so the
	// entry comes back as the raw offset rather than as an infinity.
	AnimKeyframe flat = crig::keyframe_of_pose(mem, pose, names[..], bones[..], 0.0f, 0.0f);
	defer free_key(flat);
	test::@check(math::abs(flat.offset_of("hips").y - 0.25f) < 1.0e-6f,
		"a zero height did not fall back to 1 — %s", flat.offset_of("hips").y);
}

<*
 Keying at a time that already has a key replaces it rather than adding a second.

 Two keys at one instant is a clip `span_at` cannot read: it looks for the span a
 time falls inside, and a zero-width span is not one. It is also what a person
 pressing **Key** twice at one playhead means — this pose instead, not both.
*>
fn void keying_twice_at_one_time_replaces() @test
{
	io::printn("keying at an occupied time replaces rather than stacks");

	AnimTemplate clip = built(3);
	defer clip.free(mem);

	rig::Pose pose = posed(1.2f);
	defer pose.free(mem);

	// Exactly on the middle key.
	AnimKeyframe key = crig::keyframe_of_pose(mem, pose, names[..], bones[..], 1.0f, 0.25f);
	AnimTemplate edited = crig::clip_with_key(mem, clip, key);
	defer edited.free(mem);

	test::@check(edited.keyframes.len == 3, "%d keys after replacing one of three", edited.keyframes.len);
	test::@check(clip.keyframes.len == 3, "the source clip was mutated");

	// And it is the new pose that is there.
	float angle = 0.0f;
	Vec3 axis;
	crig::axis_angle_of(edited.keyframes[1].rotation_of("knee"), &axis, &angle);
	test::@check(math::abs(angle - 1.2f) < 1.0e-3f, "the replaced key kept the old pose — %s", angle);

	// A time inside the tolerance counts as the same instant: a playhead is a
	// float arrived at by dragging, and two keys a microsecond apart are a clip
	// nobody can select the first of.
	rig::Pose again = posed(0.9f);
	defer again.free(mem);
	AnimKeyframe near = crig::keyframe_of_pose(mem, again, names[..], bones[..], 1.0f, 0.25f + 1.0e-5f);
	AnimTemplate twice = crig::clip_with_key(mem, edited, near);
	defer twice.free(mem);
	test::@check(twice.keyframes.len == 3, "a key a hair away stacked instead of replacing");
}

<*
 A key past the end lengthens the clip, and one in the middle sorts into place.

 The first is what makes the playhead somewhere you can always key: refusing, or
 clamping to the duration, would leave a region of the timeline that looks like
 the clip and cannot be written to. The second is what everything downstream
 assumes — `span_at`, the writers and the metrics all read the keys as being in
 increasing time order.
*>
fn void a_key_lands_in_order_and_can_extend_the_clip() @test
{
	io::printn("a key sorts into place, and past the end it extends the clip");

	AnimTemplate clip = built(3); // keys at 0.0, 0.25, 0.5; duration 0.5
	defer clip.free(mem);

	rig::Pose pose = posed();
	defer pose.free(mem);

	// Between the first two.
	AnimKeyframe middle = crig::keyframe_of_pose(mem, pose, names[..], bones[..], 1.0f, 0.125f);
	AnimTemplate four = crig::clip_with_key(mem, clip, middle);
	defer four.free(mem);

	test::@check(four.keyframes.len == 4, "%d keys after inserting one", four.keyframes.len);
	for (usz i = 1; i < four.keyframes.len; i++)
	{
		test::@check(four.keyframes[i].time > four.keyframes[i - 1].time,
			"the keys came back out of order at %d", i);
	}
	test::@check(four.duration == 0.5f, "inserting inside the clip changed its duration");

	// And past the end.
	AnimKeyframe late = crig::keyframe_of_pose(mem, pose, names[..], bones[..], 1.0f, 0.8f);
	AnimTemplate longer = crig::clip_with_key(mem, four, late);
	defer longer.free(mem);

	test::@check(longer.keyframes.len == 5, "%d keys after keying past the end", longer.keyframes.len);
	test::@check(math::abs(longer.duration - 0.8f) < 1.0e-6f,
		"keying past the end left the duration at %s", longer.duration);
}

<*
 Retiming scales the key times with the duration.

 Setting the number alone would leave the motion where it was and add dead air at
 the end, which is a thing to author rather than a thing to arrive at by typing a
 duration. Halving the length has to halve the walk.
*>
fn void retiming_scales_the_keys() @test
{
	io::printn("retiming a clip scales its keys with it");

	AnimTemplate clip = built(3); // duration 0.5
	defer clip.free(mem);

	AnimTemplate quick = crig::clip_retimed(mem, clip, 0.25f);
	defer quick.free(mem);

	test::@check(math::abs(quick.duration - 0.25f) < 1.0e-6f, "the duration is %s", quick.duration);
	test::@check(math::abs(quick.keyframes[1].time - 0.125f) < 1.0e-6f,
		"the middle key sits at %s rather than half of where it was", quick.keyframes[1].time);
	test::@check(math::abs(quick.keyframes[2].time - 0.25f) < 1.0e-6f,
		"the last key sits at %s", quick.keyframes[2].time);

	// A duration of zero has no scale to apply and is refused rather than
	// collapsing every key onto the start.
	AnimTemplate refused = crig::clip_retimed(mem, clip, 0.0f);
	defer refused.free(mem);
	test::@check(math::abs(refused.duration - 0.5f) < 1.0e-6f, "a zero duration was accepted");
}

<*
 Closing the seam restates the opening pose at the end, and only when it has to.

 A cycle whose last key is not its first pose snaps on the wrap, which reads as a
 hitch in the walk and is the commonest thing wrong with a hand-keyed loop. The
 "only when it has to" half matters as much: run twice, this must not keep adding
 keys, and a clip the player already reads as seamless must come back untouched.
*>
fn void closing_the_seam_restates_the_first_pose() @test
{
	io::printn("closing a loop's seam, once");

	AnimTemplate clip = built(3, loops: true);
	defer clip.free(mem);

	test::@check(!clip.keyframes[2].same_pose(clip.keyframes[0]),
		"the fixture already closes, so this check proves nothing");

	AnimTemplate closed = crig::clip_seam_closed(mem, clip);
	defer closed.free(mem);

	test::@check(closed.keyframes.len == 4, "%d keys after closing the seam", closed.keyframes.len);
	AnimKeyframe last = closed.keyframes[closed.keyframes.len - 1];
	test::@check(last.same_pose(closed.keyframes[0]), "the closing key is not the opening pose");
	test::@check(last.time > closed.keyframes[2].time, "the closing key landed before the last one");

	// Again: nothing to do.
	AnimTemplate twice = crig::clip_seam_closed(mem, closed);
	defer twice.free(mem);
	test::@check(twice.keyframes.len == 4, "closing an already-closed loop added another key");

	// And a clip that does not loop has no seam to close.
	AnimTemplate once = built(3);
	defer once.free(mem);
	AnimTemplate untouched = crig::clip_seam_closed(mem, once);
	defer untouched.free(mem);
	test::@check(untouched.keyframes.len == 3, "a clip that does not loop was given a closing key");
}

<*
 Turning Loop on eases the wrap back to the opening pose.

 A clip that stops short of its duration already loops seamlessly: the sampler
 carries the last key round to the first over the time that is left. A clip
 whose last key sits on the duration with another pose would snap, so it grows
 by its last key spacing and restates the opening pose at the new end.
*>
fn void turning_loop_on_eases_back_across_the_wrap() @test
{
	// Keys at 0, 0.25 and 0.5, the last on the duration with its own pose.
	AnimTemplate once = built(3);
	defer once.free(mem);

	bool extended;
	AnimTemplate looped = crig::clip_looped(mem, once, &extended);
	defer looped.free(mem);
	test::@check(looped.loop && extended, "a clip ending on a different pose was not given room to return");
	test::@check(math::abs(looped.duration - 0.75f) < 1.0e-5f, "the return took %s s, not one key spacing", looped.duration);
	test::eq(looped.keyframes.len, (sz)4);
	test::@check(looped.keyframes[3].same_pose(looped.keyframes[0]), "the new end is not the opening pose");
	test::@check(looped.keyframes[2].same_pose(once.keyframes[2]), "the authored end pose was lost");

	// No snap: just before the wrap the knee is where it is at 0 s.
	float seam = 1.0f - math::abs(looped.rotation_at("knee", 0.75f - 1.0e-4f).v.dot(looped.rotation_at("knee", 0.0f).v));
	test::@check(seam < 1.0e-6f, "the loop still jumps by %s at the wrap", seam);
	// And halfway back it is between the last authored pose and the first.
	float back = looped.rotation_at("knee", 0.625f).v.dot(once.rotation_at("knee", 0.5f).v);
	test::@check(back < 0.99999f, "the return does not move");

	// A clip that ends before its duration only has its flag set: the sampler
	// already blends from its last key back to the first across the wrap.
	AnimTemplate short_end = crig::clip_copy(mem, once);
	defer short_end.free(mem);
	short_end.duration = 1.0f;
	AnimTemplate gap = crig::clip_looped(mem, short_end, &extended);
	defer gap.free(mem);
	test::@check(gap.loop && !extended && gap.keyframes.len == 3 && gap.duration == 1.0f,
		"a clip with time left after its last key was rewritten");
	float wrap = 1.0f - math::abs(gap.rotation_at("knee", 1.0f - 1.0e-4f).v.dot(gap.rotation_at("knee", 0.0f).v));
	test::@check(wrap < 1.0e-6f, "the wrap span does not arrive at the opening pose (%s)", wrap);
	Quaternionf middle = gap.rotation_at("knee", 0.75f);
	test::@check(middle.v.dot(gap.rotation_at("knee", 0.5f).v) < 0.99999f
		&& middle.v.dot(gap.rotation_at("knee", 0.0f).v) < 0.99999f,
		"the wrap span holds a pose instead of blending last to first");

	// Once looped and closed, again changes nothing.
	AnimTemplate twice = crig::clip_looped(mem, looped, &extended);
	defer twice.free(mem);
	test::@check(!extended && twice.keyframes.len == 4, "looping a closed loop grew it again");
}

<*
 A copy is deep: the original can be freed and the copy still reads.

 What copy-on-edit stands on. A clip forked out of a library pack has to survive
 that pack being re-read, which frees every string the original held — so a
 shallow copy would leave the authored clip naming joints in released memory, and
 the failure would land somewhere else entirely.
*>
fn void a_copy_outlives_what_it_was_copied_from() @test
{
	io::printn("a copied clip owns everything it needs");

	AnimTemplate source = built(3);
	AnimTemplate copy = crig::clip_copy(mem, source, "mine");

	// The original goes away entirely, the way a library re-read takes it.
	source.free(mem);
	defer copy.free(mem);

	test::@check(copy.name == "mine", "the copy is called %s", copy.name);
	test::@check(copy.keyframes.len == 3, "%d keys survived", copy.keyframes.len);
	test::@check(copy.keyframes[0].names("knee"), "a joint name did not survive the source being freed");
	test::@check(copy.owned, "a copy that does not own its data will not be freed");
}

fn void sparse_same_time_keying_merges_only_incoming_channels() @test
{
	AnimKeyDot[2] initial = {
		{ .joint_name = "knee", .axis = { 1, 0, 0 }, .angle = 0.7f, .channels = ROTATION },
		{ .joint_name = "hips", .move = { 0, 0.2f, 0 }, .channels = TRANSLATION },
	};
	AnimKeyframe[1] frames = { { .time = 0, .dots = initial[..] } };
	AnimTemplate source = { .name = "merge", .duration = 1, .keyframes = frames[..] };
	AnimKeyDot[] added = alloc::new_array(mem, AnimKeyDot, 1);
	added[0] = { .joint_name = "knee".copy(mem), .move = { 0.1f, 0, 0 }, .channels = TRANSLATION };
	AnimTemplate merged = crig::clip_with_key(mem, source, { .time = 0.00001f, .dots = added });
	defer merged.free(mem);
	test::@check(merged.keyframes.len == 1 && merged.keyframes[0].time == 0, "same instant duplicated or drifted");
	test::@check(merged.keyframes[0].dots.len == 2, "unrelated channel was lost");
	AnimKeyDot knee = merged.keyframes[0].dots[0];
	test::@check(knee.channels == BOTH && knee.angle == 0.7f && knee.move.x == 0.1f, "complementary channels did not merge");
	test::@check(merged.keyframes[0].dots[1].move.y == 0.2f, "keying knee changed hips");
	AnimKeyDot[] rest = alloc::new_array(mem, AnimKeyDot, 1);
	rest[0] = { .joint_name = "knee".copy(mem), .axis = { 1, 0, 0 }, .channels = ROTATION };
	AnimTemplate replaced = crig::clip_with_key(mem, merged, { .time = 0, .dots = rest });
	defer replaced.free(mem);
	test::@check(replaced.keyframes[0].dots[0].angle == 0, "explicit identity was discarded");
	test::@check(replaced.keyframes[0].dots[0].move.x == 0.1f, "rotation replacement erased translation");
	test::@check(merged.keyframes[0].dots[0].angle == 0.7f, "rewriter mutated source");
}

fn void closing_a_sparse_seam_includes_channels_absent_from_the_first_frame() @test
{
	AnimKeyDot[1] a = { { .joint_name = "hips", .move = { 0, 0.2f, 0 }, .channels = TRANSLATION } };
	AnimKeyDot[1] b = { { .joint_name = "knee", .axis = { 1, 0, 0 }, .angle = 0.5f, .channels = ROTATION } };
	AnimKeyframe[2] frames = { { .time = 0, .dots = a[..] }, { .time = 0.5f, .dots = b[..] } };
	AnimTemplate source = { .name = "close", .duration = 1, .loop = true, .keyframes = frames[..] };
	AnimTemplate closed = crig::clip_seam_closed(mem, source);
	defer closed.free(mem);
	AnimKeyframe last = closed.keyframes[closed.keyframes.len - 1];
	test::@check(last.dots.len == 2, "closing copied only the first sparse frame");
	test::@check(last.dots[0].channels == TRANSLATION && last.dots[1].channels == ROTATION, "closing invented absent channels");
	test::@check(last.dots[1].angle > 0.49f, "closing lost the constant rotation track");
}

// ---------------------------------------------------------------------------
// Trim and crop

<*
 A sparse clip to trim: hips slide alone at 0 and 1 s, the knee turns alone at
 0.2 and 0.8 s. Two joints, one channel each, so a restated edge that invented
 the other channel would show.
*>
fn AnimTemplate sparse_take(bool loops = false, AnimInterpolation knee_curve = INHERIT)
{
	AnimKeyframe[] frames = alloc::new_array(mem, AnimKeyframe, 4);
	AnimKeyDot[] a = alloc::new_array(mem, AnimKeyDot, 1);
	a[0] = { .joint_name = "hips".copy(mem), .channels = TRANSLATION };
	AnimKeyDot[] b = alloc::new_array(mem, AnimKeyDot, 1);
	b[0] = { .joint_name = "knee".copy(mem), .axis = { 1, 0, 0 }, .angle = 0.2f, .channels = ROTATION,
		.rotation_interpolation = knee_curve };
	AnimKeyDot[] c = alloc::new_array(mem, AnimKeyDot, 1);
	c[0] = { .joint_name = "knee".copy(mem), .axis = { 1, 0, 0 }, .angle = 0.8f, .channels = ROTATION };
	AnimKeyDot[] d = alloc::new_array(mem, AnimKeyDot, 1);
	d[0] = { .joint_name = "hips".copy(mem), .move = { 1, 0, 0 }, .channels = TRANSLATION };
	frames[0] = { .time = 0, .dots = a };
	frames[1] = { .time = 0.2f, .dots = b };
	frames[2] = { .time = 0.8f, .dots = c };
	frames[3] = { .time = 1, .dots = d };
	return { .name = "take".copy(mem), .duration = 1, .keyframes = frames, .loop = loops, .owned = true };
}

fn sz key_at(AnimTemplate clip, float time)
{
	foreach (usz i, frame : clip.keyframes) if (math::abs(frame.time - time) < 1.0e-5f) return (sz)i;
	return -1;
}

fn void a_crop_keeps_the_range_and_restates_its_edges_channel_by_channel() @test
{
	io::printn("cropping keeps the keys inside, rebased, and keys each driven channel at the edges");
	AnimTemplate source = sparse_take();
	defer source.free(mem);

	AnimTemplate part = crig::clip_cropped(mem, source, 0.5f, 1.0f);
	defer part.free(mem);

	test::@check(math::abs(part.duration - 0.5f) < 1.0e-6f, "the duration is %.3f, wanted the range", part.duration);
	test::@check(part.keyframes.len == 3, "%d keys; wanted the edge, the knee key and the far edge", part.keyframes.len);

	// The new start: both channels restated, each on its own joint and mask.
	sz first = key_at(part, 0);
	test::@check(first == 0, "no key at the new start");
	if (first < 0) return;
	AnimKeyframe edge = part.keyframes[(usz)first];
	test::@check(edge.dots.len == 2, "the start edge names %d joints", edge.dots.len);
	AnimKeyDot hips, knee;
	test::@check(edge.channel_dot("hips", false, &hips) && !edge.channel_dot("hips", true, &hips),
		"the hips edge key should slide and not turn");
	test::@check(edge.channel_dot("knee", true, &knee) && !edge.channel_dot("knee", false, &knee),
		"the knee edge key should turn and not slide");
	test::@check(math::abs(hips.move.x - 0.5f) < 1.0e-5f, "the hips slid %.3f at the edge; halfway was sampled", hips.move.x);
	test::@check(math::abs(knee.angle - 0.5f) < 1.0e-5f, "the knee turned %.3f at the edge; halfway was sampled", knee.angle);

	// The kept key, rebased.
	test::@check(key_at(part, 0.3f) >= 0, "the knee key at 0.8 s did not land at 0.3 s");

	// The far edge: the hips key was already there, so only the knee is added.
	sz last = key_at(part, 0.5f);
	test::@check(last >= 0, "no key at the new end");
	if (last < 0) return;
	AnimKeyframe far = part.keyframes[(usz)last];
	test::@check(far.dots.len == 2 && far.channel_dot("knee", true, &knee) && math::abs(knee.angle - 0.8f) < 1.0e-5f,
		"the far edge did not restate the knee's held end");
	test::@check(far.channel_dot("hips", false, &hips) && hips.move.x == 1.0f, "the far edge lost the hips key that was there");

	// And the motion inside the range is the take's, second for second — to
	// within the library slerp's own drift from linear, which a shorter span
	// halves; the restated edge is exact, the curve between is not the same
	// curve.
	foreach (t : (float[]) { 0.55f, 0.7f, 0.85f, 0.95f })
	{
		AnimKeyDot was = source.entry_at("knee", t);
		AnimKeyDot now = part.entry_at("knee", t - 0.5f);
		test::@check(math::abs(was.angle - now.angle) < 1.0e-3f, "the knee at %.2f s changed from %.4f to %.4f", t, was.angle, now.angle);
		test::@check(math::abs(source.entry_at("hips", t).move.x - part.entry_at("hips", t - 0.5f).move.x) < 1.0e-5f,
			"the hips at %.2f s changed", t);
	}
	test::@check(source.keyframes.len == 4 && source.duration == 1.0f, "cropping mutated the source");
}

fn void a_crop_carries_a_hold_into_its_edge_key() @test
{
	io::printn("an edge cut out of a held span is held, and holds the held value");
	AnimTemplate source = sparse_take(knee_curve: HOLD);
	defer source.free(mem);

	AnimTemplate part = crig::clip_cropped(mem, source, 0.5f, 1.0f);
	defer part.free(mem);
	AnimKeyDot knee;
	test::@check(part.keyframes[0].channel_dot("knee", true, &knee), "no knee at the start");
	test::@check(knee.rotation_interpolation == HOLD, "the edge key does not hold");
	test::@check(math::abs(knee.angle - 0.2f) < 1.0e-5f, "the edge shows %.3f; a hold shows the value held", knee.angle);
	test::@check(knee.translation_interpolation == INHERIT, "a rotation-only edge key stated a translation curve");
}

fn void a_crop_refuses_what_it_cannot_keep() @test
{
	io::printn("a range outside the clip, or too short, leaves the clip alone");
	AnimTemplate source = sparse_take();
	defer source.free(mem);

	foreach (range : (float[2][]) { { -0.1f, 0.5f }, { 0.5f, 1.1f }, { 0.5f, 0.5f }, { 0.6f, 0.5f } })
	{
		AnimTemplate same = crig::clip_cropped(mem, source, range[0], range[1]);
		defer same.free(mem);
		test::@check(same.duration == 1.0f && same.keyframes.len == 4,
			"cropping to %.2f..%.2f changed the clip", range[0], range[1]);
	}
}

fn void a_cut_closes_the_gap_and_restates_nothing() @test
{
	io::printn("cutting drops the keys inside, moves the rest up, and invents no key");
	AnimTemplate source = sparse_take();
	defer source.free(mem);

	AnimTemplate joined = crig::clip_range_cut(mem, source, 0.3f, 0.7f);
	defer joined.free(mem);

	test::@check(math::abs(joined.duration - 0.6f) < 1.0e-6f, "the duration is %.3f", joined.duration);
	test::@check(joined.keyframes.len == 4, "%d keys; the four all lie outside the cut", joined.keyframes.len);
	test::@check(key_at(joined, 0) == 0 && key_at(joined, 0.2f) == 1 && key_at(joined, 0.4f) == 2 && key_at(joined, 0.6f) == 3,
		"the keys did not land at 0, 0.2, 0.4 and 0.6");
	AnimKeyDot knee;
	test::@check(joined.keyframes[2].channel_dot("knee", true, &knee) && knee.angle == 0.8f
		&& !joined.keyframes[2].channel_dot("knee", false, &knee), "the moved knee key changed");
	test::@check(joined.keyframes[3].dots.len == 1 && joined.keyframes[3].dots[0].channels == TRANSLATION,
		"the moved hips key grew a channel");

	// Inside the cut the motion is whatever the survivors interpolate: the knee
	// runs straight from its 0.2 s key to its moved 0.4 s key.
	test::@check(math::abs(joined.entry_at("knee", 0.3f).angle - 0.5f) < 1.0e-5f,
		"the join does not interpolate the surviving keys");
}

fn void a_cut_between_two_keys_joins_them_with_the_later_winning() @test
{
	io::printn("keys on both edges of a cut land on one instant, the later one's channels on top");
	AnimTemplate source = built(5);
	defer source.free(mem);

	// Keys at 0, 0.25, 0.5, 0.75, 1.0 with knee angles 0.2 through 0.6.
	AnimTemplate joined = crig::clip_range_cut(mem, source, 0.25f, 0.75f);
	defer joined.free(mem);
	test::@check(joined.keyframes.len == 3, "%d keys; wanted 0, the joined 0.25 and the moved 1.0", joined.keyframes.len);
	test::@check(math::abs(joined.duration - 0.5f) < 1.0e-6f, "the duration is %.3f", joined.duration);
	AnimKeyDot knee;
	test::@check(key_at(joined, 0.25f) == 1 && joined.keyframes[1].channel_dot("knee", true, &knee)
		&& math::abs(knee.angle - 0.5f) < 1.0e-5f,
		"the seam holds %.3f; the key from 0.75 s should have landed on top", knee.angle);
	test::@check(key_at(joined, 0.5f) == 2, "the last key did not move up");
	test::@check(source.keyframes.len == 5, "cutting mutated the source");

	AnimTemplate all = crig::clip_range_cut(mem, source, 0.0f, 1.0f);
	defer all.free(mem);
	test::@check(all.keyframes.len == 5 && all.duration == 1.0f, "cutting the whole clip did not refuse");
}

<*
 The contact windows are checked by asking the question they answer: is this
 foot down at this second? Every second the edit keeps must answer as it did.
*>
fn AnimGround gait_ground()
{
	AnimFoot[] feet = alloc::new_array(mem, AnimFoot, 2);
	feet[0] = { .joint = "foot_L".copy(mem), .down = 0.1f, .up = 0.4f };
	feet[1] = { .joint = "foot_R".copy(mem), .down = 0.7f, .up = 0.05f };
	return { .feet = feet, .floor = -0.5f, .floor_set = true };
}

fn bool foot_planted(AnimGround ground, String joint, float phase)
{
	foreach (foot : ground.feet) if (foot.joint == joint) return foot.planted(phase);
	return false;
}

fn void a_crop_keeps_every_foot_down_when_it_was() @test
{
	io::printn("a cropped clip plants each foot at the seconds the take did");
	AnimTemplate source = sparse_take(loops: true);
	source.ground = gait_ground();
	defer source.free(mem);

	foreach (range : (float[2][]) { { 0.5f, 1.0f }, { 0.0f, 0.5f }, { 0.02f, 0.8f }, { 0.0f, 1.0f }, { 0.15f, 0.35f } })
	{
		AnimTemplate part = crig::clip_cropped(mem, source, range[0], range[1]);
		defer part.free(mem);
		float length = range[1] - range[0];
		foreach (joint : (String[]) { "foot_L", "foot_R" })
		{
			for (float t = range[0] + 0.005f; t < range[1]; t += 0.01f)
			{
				bool was = foot_planted(source.ground, joint, t / source.duration);
				bool now = foot_planted(part.ground, joint, (t - range[0]) / length);
				test::@check(was == now, "%s at %.3f s was %s, and after cropping to %.2f..%.2f is %s",
					joint, t, was ? "down" : "up", range[0], range[1], now ? "down" : "up");
				if (was != now) break;
			}
		}
		test::@check(part.ground.floor == -0.5f && part.ground.floor_set, "the floor was lost");
	}

	// A foot never down inside the range is not carried.
	AnimTemplate right_only = crig::clip_cropped(mem, source, 0.5f, 0.65f);
	defer right_only.free(mem);
	test::@check(right_only.ground.feet.len == 0, "a range with no contact carried %d feet", right_only.ground.feet.len);
}

fn void a_cut_keeps_every_surviving_foot_down_when_it_was() @test
{
	io::printn("a cut clip plants each foot at the seconds that survived");
	AnimTemplate source = sparse_take(loops: true);
	source.ground = gait_ground();
	defer source.free(mem);

	foreach (range : (float[2][]) { { 0.3f, 0.7f }, { 0.0f, 0.5f }, { 0.5f, 1.0f }, { 0.05f, 0.95f }, { 0.2f, 0.3f } })
	{
		AnimTemplate joined = crig::clip_range_cut(mem, source, range[0], range[1]);
		defer joined.free(mem);
		float removed = range[1] - range[0];
		float length = source.duration - removed;
		foreach (joint : (String[]) { "foot_L", "foot_R" })
		{
			for (float t = 0.005f; t < source.duration; t += 0.01f)
			{
				if (t > range[0] && t < range[1]) continue;
				float after = t < range[0] ? t : t - removed;
				bool was = foot_planted(source.ground, joint, t / source.duration);
				bool now = foot_planted(joined.ground, joint, after / length);
				test::@check(was == now, "%s at %.3f s was %s, and after cutting %.2f..%.2f is %s at %.3f s",
					joint, t, was ? "down" : "up", range[0], range[1], now ? "down" : "up", after);
				if (was != now) break;
			}
		}
	}

	// A window entirely inside the cut is a foot that no longer touches.
	AnimTemplate no_left = crig::clip_range_cut(mem, source, 0.08f, 0.45f);
	defer no_left.free(mem);
	test::@check(no_left.ground.feet.len == 1 && no_left.ground.feet[0].joint == "foot_R",
		"the foot whose whole window was cut is still listed");
}

// A key may hold a joint's two halves as separate dots — rotation in one, move in
// the other. Asking for either channel must find its own dot, not stop at the
// first one with the name.
fn void a_split_key_answers_for_both_channels() @test
{
	AnimKeyDot[2] dots = {
		{ .joint_name = "hips", .axis = { 1, 0, 0 }, .angle = 0.5f, .channels = ROTATION },
		{ .joint_name = "hips", .move = { 0, 0.2f, 0 }, .channels = TRANSLATION },
	};
	AnimKeyframe key = { .time = 0, .dots = dots[..] };
	test::@check(key.has_channel("hips", ROTATION), "the rotation half was missed");
	test::@check(key.has_channel("hips", TRANSLATION), "the move half was missed behind the rotation dot");
	test::@check(!key.has_channel("knee", ROTATION), "a joint the key does not hold was reported");
}
