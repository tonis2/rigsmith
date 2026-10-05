<*
 What the sheet says beyond where the keys are: rows in tree order and
 indented by depth, a held key marked as held, and a status line that always
 says whether the playhead is on a saved pose.
*>
module crig_tests::ui;

import crig;
import cui;
import cui::widgets;
import std::core::test;
import std::math;

// A 2 s clip keying every joint at 0, 1 and 2 s, with tracks shown.
fn void cues_workspace(Fixture* f)
{
	test::@check(f.app.apply_plan_named("biped"), "could not fit rig");
	AnimRef clip = f.app.new_clip("Cues", 2, from_rest: true);
	clip = f.app.key_here(clip, 1);
	f.app.editing = f.app.key_here(clip, 2);
	f.app.edit_time = 0;
	f.app.show_edited();
	f.click(tab_center(f, f.ui.find(AreaTabStrip)!!, TAB_ANIMATIONS));
	f.ui.flush();
	f.click(f.center_of("anim-show-tracks")!!);
	f.ui.flush();
}

fn void dopesheet_cues_rows_read_as_the_rig_tree() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	cues_workspace(&f);

	RigView view = f.app.open_rig(mem)!!;
	defer view.free(mem);
	String[] names = f.app.names_for(&view, f.app.editing);
	TimelineTrack[] tracks = f.app.timeline_tracks;
	test::@check(tracks.len == view.len(), "%d tracks for %d joints", tracks.len, view.len());
	if (tracks.len == 0) return;
	test::@check(tracks[0].depth == 0 && view.skeleton.parents[joint_named(names, tracks[0].joint)] < 0,
		"the first row is not the root");

	// Pre-order: a row one level deeper than the row before hangs from it, and
	// no row is more than one level deeper than its predecessor.
	uint deepest;
	for (usz i = 1; i < tracks.len; i++)
	{
		deepest = math::max(deepest, tracks[i].depth);
		test::@check(tracks[i].depth <= tracks[i - 1].depth + 1,
			"row %d jumps from depth %d to %d", i, tracks[i - 1].depth, tracks[i].depth);
		if (tracks[i].depth != tracks[i - 1].depth + 1) continue;
		usz child = joint_named(names, tracks[i].joint);
		usz parent = joint_named(names, tracks[i - 1].joint);
		test::@check(view.skeleton.parents[child] == (int)parent,
			"%s is drawn under %s but does not hang from it", tracks[i].joint, tracks[i - 1].joint);
	}
	test::@check(deepest >= 3, "a biped should reach at least three levels; the deepest row is %d", deepest);

	// Every subtree is contiguous: once a row shallower than a joint appears,
	// none of that joint's descendants may follow.
	foreach (usz i, track : tracks)
	{
		bool closed;
		for (usz j = i + 1; j < tracks.len; j++)
		{
			if (tracks[j].depth <= track.depth) closed = true;
			if (!closed) continue;
			usz joint = joint_named(names, tracks[j].joint);
			usz ancestor = joint_named(names, track.joint);
			for (int up = view.skeleton.parents[joint]; up >= 0; up = view.skeleton.parents[(usz)up])
			{
				test::@check((usz)up != ancestor, "%s is a descendant of %s but is drawn after its subtree closed",
					tracks[j].joint, track.joint);
			}
		}
	}

	// The lanes carry the depth, both channel rows of a joint alike.
	Timeline* timeline = f.ui.find(Timeline)!!.widget_as(Timeline);
	foreach (lane : timeline.lanes)
	{
		foreach (track : tracks)
		{
			if (track.joint == lane.label) test::@check(lane.depth == track.depth, "%s's lane lost its depth", lane.label);
		}
	}
}

fn usz joint_named(String[] names, String wanted)
{
	foreach (usz i, name : names) if (name == wanted) return i;
	return 0;
}

fn void dopesheet_cues_a_held_key_is_marked_as_held() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	cues_workspace(&f);

	Timeline* timeline = f.ui.find(Timeline)!!.widget_as(Timeline);
	foreach (mark : timeline.marks)
	{
		test::@check(mark.curve == LINEAR, "a plain key on a linear clip reads as %s", mark.curve);
	}

	// Hold the pose at 1 s: every mark at 1 s becomes a hold, no other does.
	f.app.select_animation_key(f.app.editing, 1);
	test::@check(f.app.set_selected_animation_interpolation(f.app.editing, HOLD), "could not hold the key");
	// As the context menu leaves it: the panel notices the new revision on the
	// next frame and rebuilds the sheet on the one after.
	f.app.show_edited();
	f.feed(VIEWPORT_CENTER);
	f.feed(VIEWPORT_CENTER);
	timeline = f.ui.find(Timeline)!!.widget_as(Timeline);
	usz held;
	foreach (mark : timeline.marks)
	{
		bool at_one = math::abs(mark.at - 1) < 1.0e-4f;
		test::@check(at_one == (mark.curve == HOLD), "the mark at %.2f s in lane %d reads as %s", mark.at, mark.lane, mark.curve);
		if (mark.curve == HOLD) held++;
	}
	test::@check(held > 0 && held == timeline.lanes.len, "%d held marks for %d lanes", held, timeline.lanes.len);
}
