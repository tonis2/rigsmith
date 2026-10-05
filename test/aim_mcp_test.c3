<*
 Look-at targets through the app: the MCP tools, the aimed sampler and the
 handles the overlay reads.

     `c3c test --trust=full --test-noleak --test-filter crig_tests::aim_mcp`
*>
module crig_tests::aim_mcp;

import crig;
import rig;
import std::collections::object;
import std::core::test;
import std::encoding::json;
import std::math;
import std::math::vector;
import std::math::quaternion;

struct Fixture
{
	crig::AppState app;
	AnimRef ref;
}

// root - a - b - c, straight down from 1.0 in steps of 0.2.
fn void Fixture.open(&self)
{
	self.app = crig::new_app({});
	uint root = self.app.doc.add_dot({ 0, 1, 0 }, "root");
	uint a = self.app.doc.add_dot({ 0, 0.8f, 0 }, "a");
	uint b = self.app.doc.add_dot({ 0, 0.6f, 0 }, "b");
	uint c = self.app.doc.add_dot({ 0, 0.4f, 0 }, "c");
	self.app.doc.connect(root, a);
	self.app.doc.connect(a, b);
	self.app.doc.connect(b, c);
	self.app.doc.root_id = root;
	AnimKeyDot[] first = alloc::new_array(mem, AnimKeyDot, 1);
	first[0] = { .joint_name = "a".copy(mem), .axis = { 0, 1, 0 }, .angle = 0.0f, .channels = ROTATION };
	AnimKeyDot[] second = alloc::new_array(mem, AnimKeyDot, 1);
	second[0] = { .joint_name = "a".copy(mem), .axis = { 0, 1, 0 }, .angle = 0.3f, .channels = ROTATION };
	AnimKeyframe[] keys = alloc::new_array(mem, AnimKeyframe, 2);
	keys[0] = { .time = 0.0f, .dots = first };
	keys[1] = { .time = 1.0f, .dots = second };
	AnimTemplate clip = { .name = "Base".copy(mem), .duration = 1.0f, .keyframes = keys, .loop = true, .owned = true };
	self.ref = self.app.author_clip(clip);
}

fn String call_tool(Fixture* f, String text, bool* ok, bool target_tool)
{
	Object*? parsed = json::parse(mem, text);
	if (catch parsed) { test::@check(false, "arguments did not parse"); return ""; }
	Object* args = parsed;
	defer args.free();
	DString detail = dstring::new(mem);
	defer detail.free();
	String? out = target_tool ? crig::set_aim_target_json(&f.app, args, &detail) : crig::set_aim_json(&f.app, args, &detail);
	if (catch out)
	{
		*ok = false;
		return detail.copy_str(mem);
	}
	*ok = true;
	return out;
}

fn String call_set_aim(Fixture* f, String text, bool* ok) => call_tool(f, text, ok, false);

fn String call_set_aim_target(Fixture* f, String text, bool* ok) => call_tool(f, text, ok, true);

fn void targets_and_locks_are_created_keyed_and_removed_in_one_undo_step_each() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.app.free();
	Fixture* f = &fixture;
	bool ok;

	String made = call_set_aim_target(f, `{"clip":"Base","at":[0.5,0.4,0.5]}`, &ok);
	defer made.free(mem);
	test::@check(ok && made.contains(`"op":"add"`) && made.contains(`"name":"Target 1"`), "target add refused: %s", made);
	AnimTemplate* clip = f.app.clip(f.ref);
	test::@check(clip.aim_targets.len == 1 && clip.aim_targets[0].name == "Target 1" && clip.aims.len == 0
		&& clip.aim_targets[0].keys.len == 1 && clip.aim_targets[0].keys[0].at == (Vec3){ 0.5f, 0.4f, 0.5f }, "the target was not created");
	String second = call_set_aim_target(f, `{"clip":"Base","name":"Gaze","at":[0,0,1]}`, &ok);
	defer second.free(mem);
	test::@check(ok && f.app.clip(f.ref).aim_targets.len == 2 && f.app.clip(f.ref).aim_targets[1].name == "Gaze", "a named target was not created");
	String bare_target = call_set_aim_target(f, `{"clip":"Base","name":"Nope"}`, &ok);
	defer bare_target.free(mem);
	test::@check(!ok, "a new target with no position was accepted");
	test::@check(f.app.undo() && f.app.clip(f.ref).aim_targets.len == 1, "one undo did not take the target back");
	test::@check(f.app.redo() && f.app.clip(f.ref).aim_targets.len == 2, "redo did not put the target back");

	String added = call_set_aim(f, `{"clip":"Base","joint":"c","target":"Target 1"}`, &ok);
	defer added.free(mem);
	test::@check(ok && added.contains(`"op":"add"`), "lock refused: %s", added);
	clip = f.app.clip(f.ref);
	test::@check(clip.aims.len == 1 && clip.aims[0].joint == "c" && clip.aims[0].target == "Target 1"
		&& clip.aims[0].spread == 3, "the lock was not created");
	// The axis is captured so locking turns nothing: it is the direction to the
	// target in the joint's frame, which at rest is the world direction.
	test::@check(math::abs(clip.aims[0].forward.length() - 1.0f) < 1.0e-4f, "the aim axis is not a direction");
	test::@check(f.app.undo() && f.app.clip(f.ref).aims.len == 0, "one undo did not take the lock back");
	test::@check(f.app.redo() && f.app.clip(f.ref).aims.len == 1, "redo did not put the lock back");

	String keyed = call_set_aim_target(f, `{"clip":"Base","name":"Target 1","at":[-0.5,0.4,0.5],"time":0.5}`, &ok);
	defer keyed.free(mem);
	test::@check(ok && keyed.contains(`"op":"update"`), "key refused: %s", keyed);
	String tuned = call_set_aim(f, `{"clip":"Base","joint":"c","spread":2,"influence":0.5}`, &ok);
	defer tuned.free(mem);
	test::@check(ok, "retune refused: %s", tuned);
	clip = f.app.clip(f.ref);
	test::@check(clip.aim_targets[0].keys.len == 2 && clip.aim_targets[0].keys[1].time == 0.5f && clip.aims[0].spread == 2
		&& clip.aims[0].influence == 0.5f && clip.aims[0].target == "Target 1", "the key or the retune was not applied");

	DString detail = dstring::new(mem);
	defer detail.free();
	Object*? parsed = json::parse(mem, `{"clip":"Base"}`);
	Object* args = parsed!!;
	defer args.free();
	String? read = crig::get_aims_json(&f.app, args, &detail);
	if (catch read) { test::@check(false, "get_aims refused: %s", detail.str_view()); return; }
	defer read.free(mem);
	test::@check(read.contains(`"targets":[`) && read.contains(`"locks":[`) && read.contains(`"joint":"c"`)
		&& read.contains(`"target":"Target 1"`) && read.contains(`"spread":2`), "get_aims does not report them: %s", read);

	String muted = call_set_aim(f, `{"clip":"Base","joint":"c","mute":true}`, &ok);
	defer muted.free(mem);
	test::@check(ok && f.app.clip(f.ref).aims[0].mute && f.app.clip(f.ref).aim_targets[0].keys.len == 2, "mute lost keys or was ignored");
	String silenced = call_set_aim_target(f, `{"clip":"Base","name":"Target 1","mute":true}`, &ok);
	defer silenced.free(mem);
	test::@check(ok && f.app.clip(f.ref).aim_targets[0].mute && f.app.clip(f.ref).aim_targets[0].keys.len == 2, "target mute lost keys or was ignored");

	String bad = call_set_aim(f, `{"clip":"Base","joint":"nowhere","target":"Target 1"}`, &ok);
	defer bad.free(mem);
	test::@check(!ok, "an unknown joint was accepted");
	String stray = call_set_aim(f, `{"clip":"Base","joint":"b","target":"Nope"}`, &ok);
	defer stray.free(mem);
	test::@check(!ok && f.app.clip(f.ref).aims.len == 1, "a lock on a missing target was accepted");
	String spread = call_set_aim(f, `{"clip":"Base","joint":"c","spread":9}`, &ok);
	defer spread.free(mem);
	test::@check(!ok && f.app.clip(f.ref).aims[0].spread == 2, "a spread of 9 was accepted");
	String bare = call_set_aim(f, `{"clip":"Base","joint":"b"}`, &ok);
	defer bare.free(mem);
	test::@check(!ok && f.app.clip(f.ref).aims.len == 1, "a new lock with no target was accepted");

	String gone = call_set_aim(f, `{"clip":"Base","joint":"c","remove":true}`, &ok);
	defer gone.free(mem);
	test::@check(ok && f.app.clip(f.ref).aims.len == 0 && f.app.clip(f.ref).aim_targets.len == 2, "remove did not remove only the lock");
	test::@check(f.app.undo() && f.app.clip(f.ref).aims.len == 1, "remove was not one undo step");

	String dropped = call_set_aim_target(f, `{"clip":"Base","name":"Target 1","remove":true}`, &ok);
	defer dropped.free(mem);
	test::@check(ok && f.app.clip(f.ref).aim_targets.len == 1 && f.app.clip(f.ref).aims.len == 0, "removing a target kept its lock");
	test::@check(f.app.undo() && f.app.clip(f.ref).aims.len == 1 && f.app.clip(f.ref).aim_targets.len == 2, "target remove was not one undo step");
}

fn void apply_clip_keeps_the_aims() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.app.free();
	bool ok;
	String made = call_set_aim_target(&fixture, `{"clip":"Base","at":[0.5,0.4,0.5]}`, &ok);
	defer made.free(mem);
	String added = call_set_aim(&fixture, `{"clip":"Base","joint":"c","target":"Target 1"}`, &ok);
	defer added.free(mem);

	DString detail = dstring::new(mem);
	defer detail.free();
	Object*? parsed = json::parse(mem, `{"name":"Base","duration":1,"keyframes":[{"time":0,"joints":[{"name":"a","rotation":{"axis":[0,1,0],"angle":0.1}}]}]}`);
	Object* rewrite = parsed!!;
	defer rewrite.free();
	AnimTemplate? rewritten = crig::parse_clip(&fixture.app, rewrite, &detail);
	if (catch rewritten) { test::@check(false, "apply_clip refused: %s", detail.str_view()); return; }
	AnimTemplate kept = rewritten;
	defer kept.free(mem);
	test::@check(kept.aims.len == 1 && kept.aims[0].joint == "c" && kept.aim_targets.len == 1, "apply_clip dropped the clip's aims");
}

fn void the_aimed_sampler_turns_the_chain_and_the_authored_one_does_not() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.app.free();
	bool ok;
	String made = call_set_aim_target(&fixture, `{"clip":"Base","at":[0.6,0.4,0.0]}`, &ok);
	defer made.free(mem);
	String added = call_set_aim(&fixture, `{"clip":"Base","joint":"c","target":"Target 1","spread":2}`, &ok);
	defer added.free(mem);
	test::@check(ok, "lock refused: %s", added);

	RigView view = fixture.app.open_rig(mem)!!;
	defer view.free(mem);
	{
		// Locking turns nothing: the aimed pose is the authored one.
		AnimTemplate clip = *fixture.app.clip(fixture.ref);
		rig::Pose plain = fixture.app.evaluated_clip_pose(mem, &view, clip, fixture.ref, 0.0f);
		defer plain.free(mem);
		rig::Pose aimed = fixture.app.evaluated_clip_pose(mem, &view, clip, fixture.ref, 0.0f, true, true);
		defer aimed.free(mem);
		float shifted;
		foreach (usz j, q : aimed.rotations) shifted += (q.v - plain.rotations[j].v).length();
		test::@check(shifted < 1.0e-3f, "locking turned the chain by %f", shifted);
	}

	// Moving the target afterwards does.
	String moved_to = call_set_aim_target(&fixture, `{"clip":"Base","name":"Target 1","at":[0.0,0.4,0.6]}`, &ok);
	defer moved_to.free(mem);
	test::@check(ok, "move refused: %s", moved_to);
	AnimTemplate clip = *fixture.app.clip(fixture.ref);
	rig::Pose plain = fixture.app.evaluated_clip_pose(mem, &view, clip, fixture.ref, 0.0f);
	defer plain.free(mem);
	rig::Pose aimed = fixture.app.evaluated_clip_pose(mem, &view, clip, fixture.ref, 0.0f, true, true);
	defer aimed.free(mem);

	usz c = 0;
	foreach (usz j, name : view.names) if (name == "c") c = j;
	float moved;
	foreach (usz j, q : aimed.rotations) moved += (q.v - plain.rotations[j].v).length();
	test::@check(moved > 0.05f, "the aimed pose is the authored one");
	test::@check(math::abs(plain.rotations[c].l) > 0.9999f, "the authored sampler was aimed");

	// The overlay's handle: the target in model units, at the aimed joint.
	Matrix4f[] palette = rig::joint_palette(mem, &view.skeleton, aimed)!!;
	defer alloc::free(mem, palette);
	AimHandle[] handles = fixture.app.aim_handles(&view, clip, fixture.ref, 0.0f, palette);
	defer crig::free_aim_handles(handles);
	test::@check(handles.len == 1 && !handles[0].muted && (handles[0].at - (Vec3){ 0.0f, 0.24f, 0.36f }).length() < 1.0e-4f,
		"the handle is not at the target in model units");
}
