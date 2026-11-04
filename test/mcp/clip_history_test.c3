module crig_tests::mcp;
import crig;
import image;
import image::png;
import mcp;
import three;
import rig;
import crig_tests::library;
import crig_tests::shared_app;
import std::core::test;
import std::collections::object;
import std::encoding::base64;
import std::encoding::json;
import std::io;
import std::io::file;
import std::io::path;
import std::math;
import std::math::quaternion;

// ---------------------------------------------------------------------------
// Clip history
//
// A clip write is one undo step however many keyframes it carried, because a
// script writes hundreds of them and taking the run back has to be one Ctrl+Z.
// The template itself moves between the pack and the undo stack rather than
// being copied, so what these are really asserting is that exactly one of the
// two owns it at any moment — the leak-tracked run is the other half of that,
// and it is the half that catches a slot dropped out of order.

// One clip under a given name, told apart from the next by its duration alone.
fn String timed_clip(String name, String duration)
{
	return string::format(
		mem,
		`{"name":"%s","duration":%s,"keyframes":[{"time":0,"joints":[]},{"time":0.25,"joints":[{"name":"knee","rotation":[0.25,0,0]}]}]}`,
		name,
		duration);
}

// Writes one, failing the calling test rather than the helper if it will not go.
fn bool write_timed(Fixture* f, String name, String duration)
{
	String arguments = timed_clip(name, duration);
	defer alloc::free(mem, arguments);

	Object*? applied = f.call_tool("apply_clip", arguments);
	if (catch applied)
	{
		test::@check(false, "apply_clip takes %s at duration %s", name, duration);
		return false;
	}
	applied.free();
	return true;
}

// What the pack holds under this name, or null when it holds nothing.
fn crig::AnimTemplate* held_clip(Fixture* f, String name)
{
	crig::AnimRef? found = crig::resolve_clip(&f.app, name);
	if (catch found) return null;
	return f.app.clip(found);
}

<*
 Rewriting a clip and taking the rewrite back.

 The template is not copied on the way in — the displaced one moves to the undo
 stack — so this is asserting that undo hands back the clip *itself*, keyframes
 and all, rather than something reconstructed from what the edit remembered.
*>
fn void a_rewritten_clip_undoes_to_the_one_before_it() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	if (!write_timed(f, "Bend", "1")) return;
	if (!write_timed(f, "Bend", "3")) return;

	crig::AnimTemplate* live = held_clip(f, "Bend");
	test::@check(live != null && live.duration == 3.0f, "the rewrite is what the pack holds");

	test::@check(f.app.undo(), "the rewrite is on the ledger to take back");
	live = held_clip(f, "Bend");
	test::@check(live != null && live.duration == 1.0f && live.keyframes.len == 2,
		"undo puts back the clip that was there, keyframes and all");

	test::@check(f.app.redo(), "and the rewrite is still ahead of the cursor");
	live = held_clip(f, "Bend");
	test::@check(live != null && live.duration == 3.0f, "redo brings the rewrite back");
}

<*
 A write that replaced nothing, undone, leaves the pack without the clip.

 The parked side of a first write is an empty template, which is the whole of
 how "there was no clip of this name" is said — so this is the check that an
 empty one going back in removes rather than writes a blank.
*>
fn void undoing_a_first_write_takes_the_clip_out() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	if (!write_timed(f, "Solo", "1")) return;
	test::@check(held_clip(f, "Solo") != null, "the clip is there before the undo");

	test::@check(f.app.undo(), "the write is on the ledger");
	test::@check(held_clip(f, "Solo") == null, "undoing a first write leaves the clip gone");
	test::@check(f.refuses_tool("delete_clip", `{"clip":"Solo"}`, "no clip is called"),
		"and the pack agrees it does not hold it");

	test::@check(f.app.redo() && held_clip(f, "Solo") != null, "redo writes it again");
}

<*
 Deleting a clip and putting it back.

 `delete_clip` is a swap with an empty template going in, so undo is the same
 exchange in the other direction — the clip that comes back is the one that left,
 not a rebuild of it.
*>
fn void a_deleted_clip_comes_back_whole() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	if (!write_timed(f, "Gone", "2")) return;

	Object*? removed = f.call_tool("delete_clip", `{"clip":"Gone"}`);
	if (catch removed)
	{
		test::@check(false, "delete_clip takes the clip out");
		return;
	}
	removed.free();
	test::@check(held_clip(f, "Gone") == null, "the clip is out before the undo");

	test::@check(f.app.undo(), "the delete is on the ledger");
	crig::AnimTemplate* back = held_clip(f, "Gone");
	test::@check(back != null && back.duration == 2.0f && back.keyframes.len == 2,
		"undoing a delete puts the clip back whole");

	test::@check(f.app.redo() && held_clip(f, "Gone") == null, "redo takes it out again");
}

<*
 delete_clip names a clip the way every clip tool does, "Pack/Clip" included, and
 an undo puts the clip back in the slot it left — the clips after it keep their
 references, and one open below it stays open.
*>
fn void delete_clip_takes_a_qualified_name_and_undo_keeps_the_order() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	if (!write_timed(f, "First", "1")) return;
	if (!write_timed(f, "Middle", "2")) return;
	if (!write_timed(f, "Last", "3")) return;
	AnimRef last = f.app.clip_named_in_authored("Last");
	f.app.editing = last;

	Object*? removed = f.call_tool("delete_clip", `{"clip":"Authored/Middle"}`);
	if (catch removed)
	{
		test::@check(false, "delete_clip refused a Pack/Clip name");
		return;
	}
	removed.free();
	test::@check(held_clip(f, "Middle") == null, "the qualified delete left the clip");
	AnimRef shifted = f.app.clip_named_in_authored("Last");
	test::@check(f.app.editing.same(shifted), "the clip open after the deleted one lost its place");

	test::@check(f.app.undo(), "the delete is on the ledger");
	test::@check(f.app.clip_named_in_authored("Middle").clip == last.clip - 1, "undo did not put the clip back in its slot");
	test::@check(f.app.editing.same(last), "the open clip did not follow the restored slot");
	test::@check(f.app.clip(f.app.editing).name == "Last", "the editor points at another clip after undo");

	test::@check(f.refuses_tool("delete_clip", `{"clip":"Authored/Nobody"}`, "Nobody"),
		"delete_clip accepted a clip that is not there");
}

// A three-second take keyed sixty times a second: the knee strides with a period
// of 0.75 s and trembles frame to frame, the hips drift forward.
fn String dense_take_json(String name)
{
	DString out = dstring::new(mem);
	out.appendf(`{"name":"%s","duration":3.0,"keyframes":[`, name);
	for (int k = 0; k <= 180; k++)
	{
		float t = (float)k / 60.0f;
		float angle = 0.5f * (float)math::sin(t * (float)math::PI * 2.0f / 0.75f) + (k % 2 == 0 ? 0.03f : -0.03f);
		if (k > 0) out.append_char(',');
		out.appendf(`{"time":%.6f,"joints":[{"name":"knee","rotation":[%.6f,0,0]},{"name":"hips","move":[0,0,%.6f]}]}`, t, angle, 0.02f * t);
	}
	out.append_string("]}");
	String json = out.copy_str(mem);
	out.free();
	return json;
}

<*
 The clip tools an agent repairs a take with, over the wire: trim and retime
 reshape it, close_loop refuses a clip that does not loop, smooth_clip keeps the
 keys and calms the tremble, and make_loop cuts a looping stride out of it as a
 clip of its own, or loops the whole of it. Each answers with the clip and its measurements.
*>
fn void the_repair_tools_reshape_a_take() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	String take = dense_take_json("take");
	defer alloc::free(mem, take);
	Object*? applied = f.call_tool("apply_clip", take);
	if (catch applied) { test::@check(false, "the take did not author"); return; }
	applied.free();

	Object*? looped = f.call_tool("make_loop", `{"clip":"take","name":"stride","period":[0.6,0.9]}`);
	if (catch looped) { test::@check(false, "make_loop refused the take"); return; }
	defer looped.free();
	double period = looped.get("cut")!!.get_float("period")!!;
	test::@check(math::abs(period - 0.75) < 0.03, "the cycle is %.3f s, not the stride's 0.75", period);
	Object* cycle = looped.get("cycle")!!;
	test::@check(cycle.get_string("clip")!! == "stride" && (cycle.get_bool("loop") ?? false), "the cycle is not a looping clip called stride");
	test::@check(held_clip(f, "take") != null, "make_loop consumed the take");

	// An idle keeps its length: the whole take loops, less the crossfade.
	Object*? whole = f.call_tool("make_loop", `{"clip":"take","name":"kept","whole":true,"crossfade":0.2}`);
	if (catch whole) { test::@check(false, "make_loop refused to loop the whole take"); return; }
	defer whole.free();
	double looped_over = whole.get("cut")!!.get_float("period")!!;
	test::@check(math::abs(looped_over - 2.8) < 0.03, "the whole take loops over %.3f s, not 2.8", looped_over);
	test::@check(whole.get("cycle")!!.get_bool("loop") ?? false, "the whole take does not loop");

	Object*? smoothed = f.call_tool("smooth_clip", `{"clip":"take","window":0.1}`);
	if (catch smoothed) { test::@check(false, "smooth_clip refused"); return; }
	defer smoothed.free();
	test::@check((smoothed.get_int("keyframes") ?? 0) == 181, "smoothing changed the keys");

	Object*? kept = f.call_tool("trim_clip", `{"clip":"take","keep":[0.5,2.0]}`);
	if (catch kept) { test::@check(false, "trim_clip refused"); return; }
	defer kept.free();
	test::@check(math::abs((kept.get_float("duration") ?? 0.0) - 1.5) < 1e-4, "the trimmed take is not 1.5 s long");

	Object*? stretched = f.call_tool("retime_clip", `{"clip":"take","duration":3.0}`);
	if (catch stretched) { test::@check(false, "retime_clip refused"); return; }
	defer stretched.free();
	test::@check(math::abs((stretched.get_float("duration") ?? 0.0) - 3.0) < 1e-4, "the retimed take is not 3 s long");

	test::@check(f.refuses_tool("close_loop", `{"clip":"take"}`, "does not loop"), "close_loop closed a clip that does not loop");
	test::@check(f.refuses_tool("trim_clip", `{"clip":"take","keep":[1,2],"cut":[0,1]}`, "one of them"), "trim took keep and cut at once");

	Object*? thin = f.call_tool("optimize_clip", `{"clip":"stride","strength":"strong"}`);
	if (catch thin) { test::@check(false, "optimize_clip refused"); return; }
	defer thin.free();
	test::@check((thin.get("metrics") ?? null) != null, "optimize_clip did not answer with the measurements");
}

<*
 Forking the timeline frees the clip the abandoned branch was holding.

 The one path where a parked template is released rather than swapped back, and
 it fires on an edit that has nothing to do with clips — which is exactly why the
 payload store has to be a stack: the discarded edits own the newest slots, so
 the store is truncated from the end. A slot dropped out of order would free
 somebody else's template, so the leak-tracked run is the real assertion here.
*>
fn void forking_the_timeline_frees_the_abandoned_clip() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	if (!write_timed(f, "Bend", "1")) return;
	if (!write_timed(f, "Bend", "3")) return;
	test::@check(f.app.undo(), "step back over the rewrite, leaving it redoable");
	test::@check(f.app.undo_stack.can_redo(), "the rewrite is sitting in the redo tail");

	// A write under a different name, which discards that tail and with it the
	// template the abandoned branch was parking.
	if (!write_timed(f, "Other", "2")) return;

	test::@check(!f.app.undo_stack.can_redo(), "the new write forked the timeline");

	crig::AnimTemplate* bend = held_clip(f, "Bend");
	crig::AnimTemplate* other = held_clip(f, "Other");
	test::@check(bend != null && bend.duration == 1.0f, "the branch that was kept is what the pack holds");
	test::@check(other != null && other.duration == 2.0f, "and the write that forked it landed");

	// Back over both, which walks the store down to empty the way `free` does.
	test::@check(f.app.undo() && f.app.undo(), "both surviving writes still undo");
	test::@check(held_clip(f, "Bend") == null && held_clip(f, "Other") == null,
		"leaving the pack as it started");
}

<*
 Undoing a rewrite while the clip is playing.

 The forward hazard is documented on `swap_authored_clip`; this is the mirror,
 and it is the worse one. After the swap the template that was live is the
 *parked* one, and a parked template is freed when the redo tail is discarded —
 on some later, unrelated edit. A player left pointing into it is a use-after-free
 that fires nowhere near the undo that caused it, so the check is that the
 running copy is the one that came back.
*>
fn void undoing_a_rewrite_retakes_the_playing_clip() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	if (!write_timed(f, "Bend", "1")) return;

	Object*? started = f.call_tool("play", `{"clip":"Bend"}`);
	if (catch started)
	{
		test::@check(false, "play starts the clip");
		return;
	}
	started.free();

	if (!write_timed(f, "Bend", "3")) return;
	test::@check(f.app.animating && f.app.current_anim.duration == 3.0f,
		"the rewrite left the player running on the new keyframes");

	test::@check(f.app.undo(), "the rewrite undoes while it is playing");
	test::@check(f.app.animating && f.app.current_anim.duration == 1.0f,
		"undo retook the player onto the clip that came back, not the one now parked");

	f.app.stop_animation();
}

// The dot a name resolves to, or 0. `resolve_dot` writes its refusal into a
// DString and has nowhere to put one here, so it gets a scratch one.
fn uint named_dot(Fixture* f, String name)
{
	DString said = dstring::new(mem);
	defer said.free();
	return crig::resolve_dot(&f.app, name, &said) ?? 0;
}
