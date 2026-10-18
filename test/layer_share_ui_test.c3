<*
 Lifting joints out of a clip into a layer, and sharing that layer with other
 clips (app/joint_strip.c3, app/layer_edit.c3): a library tail keeps its pose
 when it moves, one edit of a shared layer is an edit of every clip holding it,
 each clip keeps its own fit, and a library clip forks to take one.

     `c3c test --trust=full --test-noleak --test-filter crig_tests::ui::share_`
*>
module crig_tests::ui;

import crig;
import rig;
import cui;
import std::core::test;
import std::math;
import std::math::quaternion;

fn uint share_dot(Fixture* f, String name)
{
	foreach (dot : f.app.doc.dots.array_view()) if (dot.name == name) return dot.id;
	return 0;
}

// A clip of the biped keyed at rest at 0, 1 and 2 s.
fn AnimRef share_clip(Fixture* f, String name, float duration)
{
	AnimRef clip = f.app.new_clip(name, duration, from_rest: true);
	clip = f.app.key_here(clip, 1);
	return f.app.key_here(clip, 2);
}

// Pose the thigh at `time` in the clip being edited and key it: into the active
// layer when one is chosen, the base otherwise.
fn void share_key_thigh(Fixture* f, float time, float angle)
{
	uint thigh = share_dot(f, "thigh_L");
	f.app.edit_time = time;
	test::@check(f.app.pose_from_clip(f.app.editing, time), "could not open a pose draft");
	Quaternionf bend = quaternion::from_axis_angle{float}((Vec3){ 1, 0, 0 }, angle);
	test::@check(f.app.set_working_pose(thigh, bend, {}), "could not pose the thigh");
	f.app.pose_edit_pending = true;
	test::@check(f.app.key_pose_edit(ALL), "keying the thigh failed");
	f.app.discard_pose_edit();
}

fn AnimLayer* share_layer_of(Fixture* f, AnimRef ref, String link)
{
	AnimTemplate* clip = f.app.clip(ref);
	sz at = clip.layer_linked(link);
	return at >= 0 ? &clip.layers[(usz)at] : null;
}

fn rig::Pose share_pose(Fixture* f, AnimRef ref, float time)
{
	RigView view = f.app.open_rig(mem)!!;
	defer view.free(mem);
	return f.app.evaluated_clip_pose(mem, &view, *f.app.clip(ref), ref, time, false);
}

// A layer for the thigh of clip A, shared with B and C.
fn String share_three(Fixture* f, AnimRef* a, AnimRef* b, AnimRef* c)
{
	test::@check(f.app.apply_plan_named("biped"), "could not fit the biped");
	*b = share_clip(f, "B", 2.0f);
	*c = share_clip(f, "C", 6.0f);
	*a = share_clip(f, "A", 4.0f);
	f.app.editing = *a;
	share_key_thigh(f, 1.0f, 0.5f);
	f.app.select(share_dot(f, "thigh_L"));
	test::@check(f.app.move_joints_to_layer(f.app.editing) == 0, "the thigh did not move to a layer");
	*a = f.app.editing;
	AnimRef[2] targets = { *b, *c };
	test::eq(f.app.share_layer(*a, 0, targets[..], STRETCH), (usz)2);
	return f.app.clip(*a).layers[0].link.tcopy();
}

<*
 A library tail moved into a layer plays exactly as it did: the clip forks into
 the authored pack, the tail's keys leave its base, and the layer carries them
 from the bones the library recorded.

 Re-introduce: carry a layer-only joint as written rather than from its layer's
 bone, and the quadruped's tail moves.
*>
fn void share_a_library_tail_moves_to_a_layer_and_keeps_its_pose() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	usz quadruped = (usz)f.app.packs.len();
	foreach (usz i, &pack : f.app.packs) if (pack.plan == "quadruped") quadruped = i;
	test::@check(quadruped < (usz)f.app.packs.len(), "no quadruped pack in the library");
	test::@check(f.app.apply_pack_rig(quadruped), "the quadruped pack gave no rig");
	AnimRef idle = f.app.clip_named_in((int)quadruped, "Idle");
	test::@check(idle.valid() && f.app.ensure_clip_imported(idle), "the quadruped has no Idle");
	float[4] times = { 0.0f, 0.3f, 0.8f, 1.3f };
	rig::Pose[4] before;
	foreach (usz i, t : times) before[i] = share_pose(&f, idle, t);
	defer foreach (&pose : before) pose.free(mem);

	f.app.editing = idle;
	f.app.select(share_dot(&f, "tail_base"));
	test::eq(f.app.move_joints_to_layer(idle), (sz)0);
	AnimRef landed = f.app.editing;
	test::@check(landed.pack == f.app.authored_pack, "the library clip did not fork");
	AnimTemplate* clip = f.app.clip(landed);
	foreach (&frame : clip.keyframes) foreach (dot : frame.dots)
	{
		test::@check(dot.joint_name != "tail_base" && dot.joint_name != "tail_tip", "the base still keys %s", dot.joint_name);
	}
	test::@check(clip.layers.len == 1 && clip.layers[0].keyframes.len > 0, "the tail did not land in a layer");
	foreach (usz i, t : times)
	{
		rig::Pose after = share_pose(&f, landed, t);
		defer after.free(mem);
		foreach (usz j, turn : after.rotations)
		{
			test::@check(1.0f - math::abs(turn.v.dot(before[i].rotations[j].v)) < 1.0e-6f
				&& (after.offsets[j] - before[i].offsets[j]).length() < 1.0e-5f, "joint %d moved at %.1f s", (int)j, t);
		}
	}
}

<*
 Sharing gives every target a copy, as one undo step; after that, an edit of the
 layer in any clip is an edit of all of them, one undo step again, while each
 clip keeps its own fit. Removing it from one leaves the rest, and an unlinked
 copy no longer follows.

 Re-introduce: drop the `sync_linked_layers` call from `put_authored_clip`, and
 the other clips keep the old name and keys.
*>
fn void share_one_edit_of_a_shared_layer_changes_every_clip() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	AnimRef a, b, c;
	String link = share_three(&f, &a, &b, &c);
	test::@check(link.len > 0, "the shared layer has no link");
	test::@check(f.app.clip(a).layers[0].length == 4.0f, "the shared layer did not take its clip's length");
	test::eq(f.app.link_holders(link), (usz)3);
	test::@check(share_layer_of(&f, b, link).same_shared(&f.app.clip(a).layers[0]), "B's copy differs");

	// C keeps the layer's seconds; the others still stretch it.
	sz c_at = f.app.clip(c).layer_linked(link);
	AnimLayer kept = f.app.layer_copy_at(c, (usz)c_at);
	kept.fit = KEEP;
	test::@check(f.app.replace_clip_layer(c, (usz)c_at, kept), "could not change C's fit");
	test::@check(share_layer_of(&f, c, link).fit == KEEP && share_layer_of(&f, b, link).fit == STRETCH
		&& f.app.clip(a).layers[0].fit == STRETCH, "a fit is not each clip's own");

	// A rename in A renames the layer everywhere, in one undo step.
	AnimLayer renamed = f.app.layer_copy_at(a, 0);
	renamed.name.free(mem);
	renamed.name = "Tail".copy(mem);
	test::@check(f.app.replace_clip_layer(a, 0, renamed), "could not rename the layer");
	test::@check(share_layer_of(&f, b, link).name == "Tail" && share_layer_of(&f, c, link).name == "Tail",
		"the rename did not reach the other clips");
	test::@check(share_layer_of(&f, c, link).fit == KEEP, "the rename overwrote C's fit");
	// One Ctrl+Z takes the rename back out of all three.
	test::@check(f.app.undo(), "undo failed");
	test::@check(f.app.clip(a).layers[0].name == "thigh_L motion" && share_layer_of(&f, b, link).name == "thigh_L motion"
		&& share_layer_of(&f, c, link).name == "thigh_L motion", "one undo did not take the rename back everywhere");
	test::@check(f.app.redo() && share_layer_of(&f, c, link).name == "Tail", "redo did not rename them again");

	// A key in A's layer lands in B's and C's.
	usz keys = f.app.clip(a).layers[0].keyframes.len;
	f.app.editing = a;
	f.app.set_active_layer(a, 0);
	share_key_thigh(&f, 3.0f, -0.4f);
	test::@check(f.app.clip(a).layers[0].keyframes.len == keys + 1, "the key did not land in A's layer");
	test::@check(share_layer_of(&f, b, link).same_shared(&f.app.clip(a).layers[0])
		&& share_layer_of(&f, c, link).same_shared(&f.app.clip(a).layers[0]), "the key did not reach the other clips");
	test::@check(f.app.undo(), "undo failed");
	test::@check(share_layer_of(&f, b, link).keyframes.len == keys && share_layer_of(&f, c, link).keyframes.len == keys,
		"undo did not take the key back out of every clip");

	// Off B only; then C unlinked stops following A.
	test::@check(f.app.remove_clip_layer(b, (usz)f.app.clip(b).layer_linked(link)), "could not remove B's copy");
	test::eq(f.app.link_holders(link), (usz)2);
	c_at = f.app.clip(c).layer_linked(link);
	test::@check(f.app.unlink_layer(c, (usz)c_at), "could not unlink C's copy");
	test::eq(f.app.link_holders(link), (usz)1);
	AnimLayer* mine = &f.app.clip(c).layers[(usz)c_at];
	test::@check(mine.link.len == 0 && mine.length == 0.0f, "the unlinked copy still keeps its own clock");
	AnimLayer again = f.app.layer_copy_at(a, 0);
	again.name.free(mem);
	again.name = "Swish".copy(mem);
	test::@check(f.app.replace_clip_layer(a, 0, again), "could not rename A's layer");
	test::@check(f.app.clip(c).layers[(usz)c_at].name == "Tail", "an unlinked copy still follows");
}

<*
 A shared layer stretched onto a shorter clip shows its keys at the stretched
 times there, and a key made there lands at the matching place in the layer's
 own seconds, which the longer clip then shows where it belongs.

 Re-introduce: show a stretched layer's keys at their own times, or key them at
 the playhead's clip time, and the times part.
*>
fn void share_editing_a_stretched_layer_from_a_shorter_clip_maps_times() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	AnimRef a, b, c;
	String link = share_three(&f, &a, &b, &c);
	sz b_at = f.app.clip(b).layer_linked(link);
	f.app.editing = b;
	f.app.set_active_layer(b, b_at);
	AnimTemplate* shown = f.app.key_clip(b);
	AnimLayer* own = &f.app.clip(a).layers[0];
	test::eq(shown.keyframes.len, own.keyframes.len);
	foreach (usz i, frame : shown.keyframes)
	{
		test::@check(math::abs(frame.time - own.keyframes[i].time * 0.5f) < 1.0e-5f,
			"B shows a key at %.3f s, not half of %.3f", frame.time, own.keyframes[i].time);
	}

	share_key_thigh(&f, 0.75f, 0.3f);
	bool landed = false;
	foreach (frame : f.app.clip(a).layers[0].keyframes) if (math::abs(frame.time - 1.5f) < 1.0e-4f) landed = true;
	test::@check(landed, "a key at 0.75 s of the 2 s clip did not land at 1.5 s of the 4 s layer");
	test::@check(f.app.clip(a).duration == 4.0f && f.app.clip(b).duration == 2.0f, "keying a shared layer changed a length");
}

<*
 Sharing into a library clip forks it into the authored pack and binds the fork,
 all in the one undo step that shares.

 Re-introduce: land the targets with `put_authored_clip` instead of
 `land_clip_recorded`, and the library clip is never forked or bound.
*>
fn void share_sharing_into_a_library_clip_forks_and_rebinds_once() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	test::@check(f.app.apply_plan_named("biped"), "could not fit the biped");
	AnimRef library = crig::NO_ANIM;
	foreach (usz i, &pack : f.app.packs)
	{
		if (i == (usz)f.app.authored_pack || !f.app.pack_matches(i) || pack.clips.len == 0) continue;
		library = { .pack = (int)i, .clip = 0 };
		break;
	}
	test::@check(library.valid(), "no library clip fits the biped");
	AnimRef a = share_clip(&f, "A", 4.0f);
	f.app.editing = a;
	share_key_thigh(&f, 1.0f, 0.5f);
	f.app.select(share_dot(&f, "thigh_L"));
	test::eq(f.app.move_joints_to_layer(f.app.editing), (sz)0);
	a = f.app.editing;
	usz authored = f.app.authored().clips.len;
	sz bound = f.app.doc.animations.len();

	AnimRef[1] targets = { library };
	test::eq(f.app.share_layer(a, 0, targets[..], REPEAT), (usz)1);
	String link = f.app.clip(a).layers[0].link;
	test::@check(f.app.authored().clips.len == authored + 1, "the library clip was not forked");
	test::eq(f.app.doc.animations.len(), bound + 1);
	test::eq(f.app.link_holders(link), (usz)2);
	test::@check(f.app.editing.same(a), "sharing moved the clip being edited");

	// One Ctrl+Z takes the share back: the fork, its binding and the link.
	test::@check(f.app.undo(), "undo failed");
	test::@check(f.app.authored().clips.len == authored, "undo left the fork");
	test::eq(f.app.doc.animations.len(), bound);
	test::@check(f.app.clip(a).layers[0].link.len == 0, "undo left the layer shared");
}

<*
 The dialogs: the row menu's Add to animations… lists the other clips, a ticked
 one gets the layer on Add; the + menu's Shared layer… puts it on a third clip.

 Re-introduce: read the ticks from the wrong rows, or leave the dialog's Add
 unwired, and the clips stay without the layer.
*>
fn void share_the_dialogs_add_a_layer_to_ticked_and_picked_clips() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	test::@check(f.app.apply_plan_named("biped"), "could not fit the biped");
	AnimRef b = share_clip(&f, "B", 2.0f);
	AnimRef c = share_clip(&f, "C", 3.0f);
	AnimRef a = share_clip(&f, "A", 4.0f);
	f.app.editing = a;
	f.app.show_edited();
	f.click(tab_center(&f, f.ui.find(AreaTabStrip)!!, TAB_ANIMATIONS));
	f.ui.flush();
	share_key_thigh(&f, 1.0f, 0.5f);
	f.app.select(share_dot(&f, "thigh_L"));
	f.pick_menu_item(crig::ANIM_TOOLS_BUTTON_ID, crig::ANIM_MOVE_JOINTS_ID);
	a = f.app.editing;
	test::eq(f.app.active_layer_of(a), (sz)0);

	crig::anim_layer_menu_share(f.ui);
	f.ui.flush();
	sz row = -1;
	foreach (usz i, target : f.app.layer_share_targets) if (target.same(b)) row = (sz)i;
	test::@check(row >= 0 && f.app.layer_share_targets.len == 2, "the dialog does not list the other two clips");
	f.click(f.center_of(f.app.layer_share_ids[(usz)row])!!);
	f.ui.flush();
	f.click(f.center_of(crig::LAYER_SHARE_ADD_ID)!!);
	f.ui.flush();
	String link = f.app.clip(a).layers[0].link.tcopy();
	test::@check(link.len > 0 && f.app.clip(b).layer_linked(link) >= 0, "the ticked clip did not get the layer");
	test::@check(f.app.clip(c).layer_linked(link) < 0, "an unticked clip got the layer");

	f.app.editing = c;
	f.app.show_edited();
	f.ui.flush();
	lyr_add(&f, crig::ANIM_LAYER_SHARED_ID);
	test::@check(f.app.layer_pick_links.len == 1, "the Shared layer dialog does not offer the one shared layer");
	f.click(f.center_of(crig::LAYER_PICK_ADD_ID)!!);
	f.ui.flush();
	test::@check(f.app.clip(f.app.editing).layer_linked(link) >= 0, "picking the shared layer did not put it on the clip");
	test::eq(f.app.link_holders(link), (usz)3);
}
