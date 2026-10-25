<*
 Align X/Y/Z on the pose (`app/pose_align.c3`): the selected joints line up
 with the first-selected one by turning bones in the clip, never by moving
 joints on the model.

     `c3c test --trust=full --test-filter crig_tests::pose_align`

 The biped fixture, with a two-key clip whose neck and head lean sideways by
 different amounts at each key — the tilted head a generated clip comes back
 with. The rig is built straight, so at rest the chain is already on one line
 and the rig's own Align has nothing to do: what has to change is the pose.
*>
module crig_tests::pose_align;

import crig;
import rig;
import crig_tests::shared_app;
import std::core::test;
import std::io;
import std::math;
import std::math::quaternion;

const String NECK = "neck";
const String HEAD = "head";
const String TOP = "head_top";
const float[2] TIMES = { 0.0f, 0.5f };

struct Figure
{
	crig::AppState app;
	uint neck;
	uint head;
	uint top;
}

fn uint dot_named(crig::AppState* app, String name)
{
	foreach (dot : app.doc.dots.array_view())
	{
		if (dot.name == name) return dot.id;
	}
	return 0;
}

<*
 A biped whose neck and head lean about Z by a different amount at each key,
 stopped, with neck, head and head top selected in that order.
*>
fn bool Figure.open(&self, bool lean = true)
{
	self.app = shared_app::open();
	if (!self.app.apply_plan_named("biped")) return false;
	self.neck = dot_named(&self.app, NECK);
	self.head = dot_named(&self.app, HEAD);
	self.top = dot_named(&self.app, TOP);
	if (self.neck == 0 || self.head == 0 || self.top == 0) return false;

	crig::AnimRef clip = self.app.new_clip("lean", 1.0f, from_rest: true);
	if (!clip.valid()) return false;
	self.app.editing = clip;
	if (lean)
	{
		if (!self.key_lean(TIMES[0], 0.35f, -0.25f)) return false;
		if (!self.key_lean(TIMES[1], -0.2f, 0.3f)) return false;
	}

	self.app.stop_animation();
	self.app.undo_stack.clear();
	self.app.edit_time = TIMES[0];
	self.app.stage = POSE_STAGE;
	self.app.select(self.neck);
	self.app.extend_selection(self.head);
	self.app.extend_selection(self.top);
	return true;
}

fn bool Figure.key_lean(&self, float time, float neck, float head)
{
	if (!self.app.pose_from_clip(self.app.editing, time)) return false;
	self.app.edit_time = time;
	Vec3 z = { 0, 0, 1 };
	if (!self.app.set_working_pose(self.neck, quaternion::from_axis_angle{float}(z, neck), {})) return false;
	if (!self.app.set_working_pose(self.head, quaternion::from_axis_angle{float}(z, head), {})) return false;
	self.app.pose_edit_pending = true;
	return self.app.key_pose_edit();
}

fn void Figure.close(&self) => self.app.free();

// Where the clip puts `dot` at `time`, played as playback plays it.
fn Vec3 Figure.posed(&self, uint dot, float time)
{
	crig::RigView view = self.app.open_rig(mem)!!;
	defer view.free(mem);
	rig::Pose pose = self.app.evaluated_clip_pose(mem, &view, *self.app.clip(self.app.editing), self.app.editing,
		time, false);
	defer pose.free(mem);
	Matrix4f[] palette = rig::joint_palette(mem, &view.skeleton, pose)!!;
	defer alloc::free(mem, palette);
	sz joint = view.joint_of(dot);
	return view.skeleton.joints[(usz)joint].transform(palette[(usz)joint]);
}

// How far head and head top sit off the neck's X at `time`.
fn float Figure.off_line(&self, float time)
{
	float x = self.posed(self.neck, time).x;
	return math::max(math::abs(self.posed(self.head, time).x - x), math::abs(self.posed(self.top, time).x - x));
}

fn Vec3 Figure.rest(&self, uint dot) => self.app.doc.find(dot).position;

fn void a_leaning_head_lines_up_at_the_playhead() @test
{
	Figure f;
	bool opened = f.open();
	defer f.close();
	if (!opened) { test::@check(false, "could not build the biped fixture with a neck, head and head top"); return; }
	float before = f.off_line(TIMES[0]);
	float other = f.off_line(TIMES[1]);
	io::printfn("neck, head, head top on X at the playhead: %.4f off before", before);
	test::@check(before > 0.01f, "the fixture's chain does not lean (%.4f off)", before);

	Vec3[3] rest = { f.rest(f.neck), f.rest(f.head), f.rest(f.top) };
	float neck_height = f.posed(f.neck, TIMES[0]).y;
	float neck_bone = (f.posed(f.head, TIMES[0]) - f.posed(f.neck, TIMES[0])).length();
	float head_bone = (f.posed(f.top, TIMES[0]) - f.posed(f.head, TIMES[0])).length();
	sz cursor = f.app.undo_stack.cursor;
	usz lined = f.app.align_pose_to_anchor(0);

	test::eq(lined, (usz)2);
	test::@check(f.off_line(TIMES[0]) < 1.0e-3f, "the chain is still %.4f off the neck's X", f.off_line(TIMES[0]));
	test::@check(math::abs(f.off_line(TIMES[1]) - other) < 1.0e-5f, "aligning at the playhead changed the other key");
	test::@check(math::abs(f.posed(f.neck, TIMES[0]).y - neck_height) < 1.0e-5f, "the anchor moved");
	test::@check(math::abs((f.posed(f.head, TIMES[0]) - f.posed(f.neck, TIMES[0])).length() - neck_bone) < 1.0e-4f
		&& math::abs((f.posed(f.top, TIMES[0]) - f.posed(f.head, TIMES[0])).length() - head_bone) < 1.0e-4f,
		"the bones changed length");
	test::@check(f.rest(f.neck) == rest[0] && f.rest(f.head) == rest[1] && f.rest(f.top) == rest[2],
		"aligning the pose moved joints on the model");
	test::@check(f.app.undo_stack.cursor == cursor + 1, "one align was not one history entry");

	test::@check(f.app.undo(), "the align left nothing to undo");
	test::@check(math::abs(f.off_line(TIMES[0]) - before) < 1.0e-5f, "undo did not bring the lean back");
}

fn void whole_clip_lines_up_every_key_as_one_undo() @test
{
	Figure f;
	bool opened = f.open();
	defer f.close();
	if (!opened) { test::@check(false, "could not build the biped fixture with a neck, head and head top"); return; }
	io::printn("Apply to: Whole clip lines the chain up at both keys, one undo entry");

	f.app.key_reach = WHOLE_CLIP;
	sz cursor = f.app.undo_stack.cursor;
	usz lined = f.app.align_pose_to_anchor(0);
	test::eq(lined, (usz)4);
	foreach (time : TIMES)
	{
		test::@check(f.off_line(time) < 1.0e-3f, "at %.2fs the chain is still %.4f off", time, f.off_line(time));
	}
	// Between keys the curve passes through two straight poses, so it stays near the line.
	test::@check(f.off_line(0.25f) < 0.01f, "between the keys the chain swings %.4f off", f.off_line(0.25f));
	test::@check(f.app.undo_stack.cursor == cursor + 1, "aligning the whole clip was not one history entry");

}

fn void the_limits_hold_a_bone_short_and_it_is_counted() @test
{
	Figure f;
	bool opened = f.open();
	defer f.close();
	if (!opened) { test::@check(false, "could not build the biped fixture with a neck, head and head top"); return; }
	// The cube's fitted neck leans forward at rest; with its swing held to a few
	// degrees, standing the head over it on Z asks the neck for more pitch than its
	// table allows, whatever the plan's own proportions are.
	crig::JointRotationLimits table = f.app.doc.rotation_limits_of(f.neck);
	test::@check(table.constrained, "the fixture's neck has no limits to test against");
	table.axes[0] = { .allowed = true, .minimum = -0.05f, .maximum = 0.05f };
	table.axes[2] = { .allowed = true, .minimum = -0.05f, .maximum = 0.05f };
	f.app.doc.set_rotation_limits(f.neck, table);
	float before = math::abs(f.posed(f.head, TIMES[0]).z - f.posed(f.neck, TIMES[0]).z);
	usz lined = f.app.align_pose_to_anchor(2);
	float after = math::abs(f.posed(f.head, TIMES[0]).z - f.posed(f.neck, TIMES[0]).z);
	io::printfn("Z on a forward neck: %d of 2 lined, the head %.4f off before and %.4f after", lined, before, after);
	test::@check(lined < 2, "a turn past the neck's limits was counted as lined up");
	test::@check(after < before, "the head did not come any nearer the line (%.4f, was %.4f)", after, before);
}

<*
 A clip recorded on another rig's bones — what an import or a generated clip
 is — plays through the carry, which rides down the chain. The keys rewritten
 keep the bones they were recorded on, and the chain lines up as it plays.
*>
fn void an_imported_clip_lines_up_as_it_plays() @test
{
	Figure f;
	bool opened = f.open();
	defer f.close();
	if (!opened) { test::@check(false, "could not build the biped fixture with a neck, head and head top"); return; }
	io::printn("keys recorded on leaning bones: lined up as played, bones kept");

	// Every rotation recorded against a bone that leans off this rig's, so each
	// joint, and each above it, is carried.
	Vec3 lean = { 0.25f, 1.0f, 0.15f };
	foreach (&frame : f.app.clip(f.app.editing).keyframes)
	{
		foreach (&dot : frame.dots) if (dot.keys_rotation()) dot.bone = lean.normalize();
	}
	f.app.key_reach = WHOLE_CLIP;
	test::eq(f.app.align_pose_to_anchor(0), (usz)4);
	foreach (time : TIMES)
	{
		test::@check(f.off_line(time) < 1.0e-3f, "at %.2fs the carried chain is still %.4f off", time, f.off_line(time));
	}
	foreach (frame : f.app.clip(f.app.editing).keyframes)
	{
		foreach (dot : frame.dots)
		{
			if (dot.keys_rotation() && (dot.joint_name == NECK || dot.joint_name == HEAD))
			{
				test::@check((dot.bone - lean.normalize()).length() < 1.0e-6f, "%s's key lost the bone it was recorded on", dot.joint_name);
			}
		}
	}
}

fn void a_straight_chain_turns_nothing() @test
{
	Figure f;
	bool opened = f.open(lean: false);
	defer f.close();
	if (!opened) { test::@check(false, "could not build the biped fixture with a neck, head and head top"); return; }
	io::printn("a chain already on the line: nothing keyed, nothing on the ledger");

	sz cursor = f.app.undo_stack.cursor;
	test::eq(f.app.align_pose_to_anchor(0), (usz)2);
	test::@check(f.app.undo_stack.cursor == cursor, "aligning a straight chain wrote history");
}

fn void one_joint_has_nothing_to_line_up_with() @test
{
	Figure f;
	bool opened = f.open();
	defer f.close();
	if (!opened) { test::@check(false, "could not build the biped fixture with a neck, head and head top"); return; }

	f.app.select(f.head);
	sz cursor = f.app.undo_stack.cursor;
	test::eq(f.app.align_pose_to_anchor(0), (usz)0);
	test::@check(f.app.undo_stack.cursor == cursor, "a lone joint wrote history");
}

fn void swinging_keeps_length_and_takes_the_shortest_way() @test
{
	Vec3 from = { 0.3f, 1.0f, 0.2f };
	Vec3 to = crig::swung_onto(from, 0.0f, 0);
	test::@check(math::abs(to.length() - from.length()) < 1.0e-5f, "the swing changed the bone's length");
	test::@check(math::abs(to.x) < 1.0e-6f, "the bone did not reach the line");
	test::@check(math::abs(to.y / to.z - from.y / from.z) < 1.0e-4f, "the swing turned the bone off its plane");

	// Out of reach: as near as it comes, straight along the axis.
	Vec3 far = crig::swung_onto(from, 5.0f, 0);
	test::@check(math::abs(far.x - from.length()) < 1.0e-5f && far.y * far.y + far.z * far.z < 1.0e-8f,
		"a target past the bone's reach did not point the bone at it");
}
