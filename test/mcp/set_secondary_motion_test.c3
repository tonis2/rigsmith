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
// set_secondary_motion
//
// The authoring half of the feature, and the only one an agent can reach without
// a clip. What is worth pinning is not that the setter works — recorded.c3's own
// checks cover that — but that the wire surface says the same thing the document
// holds: the preset a bare entry resolves to, the tip a root alone infers, the
// shapes that are refused by name, and that a refusal really does leave the rig
// where it found it.

// One dot's row in get_skeleton's `dots` array, or null when no dot answers.
fn Object* skeleton_dot(Object* skeleton, String name)
{
	Object*? dots = skeleton.get("dots");
	if (catch dots) return null;

	for (sz i = 0; i < dots.get_len(); i++)
	{
		Object* dot = dots.get_at(i);
		if ((dot.get_string("name") ?? "") == name) return dot;
	}
	return null;
}

// The chain rooted at a named dot in get_skeleton's `secondary` list, or null
// where there is none.
fn Object* skeleton_chain(Object* skeleton, String root)
{
	Object*? chains = skeleton.get("secondary");
	if (catch chains) return null;

	for (sz i = 0; i < chains.get_len(); i++)
	{
		Object* chain = chains.get_at(i);
		if ((chain.get_string("root") ?? "") == root) return chain;
	}
	return null;
}

// Whether a chain row names these joints, root first.
fn bool chain_runs(Object* chain, String... joints)
{
	if (chain == null) return false;
	Object*? run = chain.get("joints");
	if (catch run) return false;
	if (run.get_len() != (sz)joints.len) return false;
	foreach (usz i, joint : joints)
	{
		if ((run.get_string_at((sz)i) ?? "") != joint) return false;
	}
	return true;
}

<*
 A chain added over the wire, with every value resolved in the answer, and
 get_skeleton reading the whole of it back.

 The readback is the half that matters: `set_secondary_motion` answering with
 numbers it was just handed proves nothing, and an agent's next call is
 `get_skeleton`. The entry names no tip on purpose — the inferred run and the
 preset's resolved values are the two things a caller cannot work out for
 themselves, and they have to be in the answer rather than only in the schema.
*>
fn void set_secondary_motion_adds_a_chain_and_get_skeleton_reads_it_back() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? answered = f.call_tool("set_secondary_motion",
		`{"chains":[{"root":"knee","preset":"hair","flexibility":0.8,"gravity":0.25}],`
		`"colliders":[{"joint":"knee"}]}`);
	if (catch answered)
	{
		test::@check(false, "set_secondary_motion answers");
		return;
	}
	defer answered.free();

	Object*? rows = answered.get("chains");
	bool resolved = false;
	if (try rows && rows.get_len() == 1)
	{
		Object* row = rows.get_at(0);
		// Hair's damping stays where the preset put it; the rest is what the entry
		// said; the tip is the end of the run below the knee.
		resolved = (row.get_string("root") ?? "") == "knee"
			&& (row.get_string("tip") ?? "") == "foot"
			&& chain_runs(row, "knee", "foot")
			&& (row.get_string("preset") ?? "") == "hair"
			&& math::abs((row.get_float("flexibility") ?? 0.0) - 0.8) < 1.0e-6
			&& math::abs((row.get_float("damping") ?? 0.0) - 0.6) < 1.0e-6
			&& math::abs((row.get_float("gravity") ?? 0.0) - 0.25) < 1.0e-6
			&& (row.get_bool("collide") ?? false)
			&& (row.get_bool("added") ?? false);
	}
	test::@check(resolved, "set_secondary_motion answers with the tip inferred and every omitted value resolved from the preset");

	// knee sits half a unit above foot, and foot is the tail knee's bone runs to,
	// so a capsule with no radius given is an eighth of a unit.
	Object*? capsules = answered.get("colliders");
	bool sized = false;
	if (try capsules)
	{
		sized = capsules.get_len() == 1
			&& (capsules.get_at(0).get_string("joint") ?? "") == "knee"
			&& math::abs((capsules.get_at(0).get_float("radius") ?? 0.0) - 0.125) < 1.0e-6;
	}
	test::@check(sized, "and sizes an omitted collider radius at a quarter of the bone it sweeps");

	// The counts are read back through the same resolver the viewport and the
	// bake use, which is the only thing that tells a chain of two from two of one.
	test::@check((answered.get_int("chain_count") ?? 0) == 1
		&& (answered.get_int("dynamic_bones") ?? 0) == 2
		&& (answered.get_int("capsules") ?? 0) == 1,
		"and reports the knee and the foot as one chain of two");

	Object*? skeleton = f.call_tool("get_skeleton", "{}");
	if (catch skeleton)
	{
		test::@check(false, "get_skeleton answers after set_secondary_motion");
		return;
	}
	defer skeleton.free();

	Object* knee = skeleton_chain(skeleton, "knee");
	bool carried = knee != null;
	if (carried)
	{
		carried = (knee.get_string("tip") ?? "") == "foot"
			&& chain_runs(knee, "knee", "foot")
			&& (knee.get_string("preset") ?? "") == "hair"
			&& math::abs((knee.get_float("flexibility") ?? 0.0) - 0.8) < 1.0e-4
			&& math::abs((knee.get_float("damping") ?? 0.0) - 0.6) < 1.0e-4
			&& math::abs((knee.get_float("gravity") ?? 0.0) - 0.25) < 1.0e-4;
	}
	test::@check(carried, "get_skeleton carries the same chain back in the same shape");

	// The two numbers a chain no longer has are refused by name, with where
	// each of them went: a cone was a bound on the solver alone, the joint's
	// own limits are the rig's; a thickness is measured now, not typed.
	test::@check(f.refuses_tool("set_secondary_motion", `{"chains":[{"root":"knee","swing":0.4}]}`, "swing", "rotation limits"),
		"a swing on a chain is refused with where the limit lives now");
	test::@check(f.refuses_tool("set_secondary_motion", `{"chains":[{"root":"knee","thickness":0.05}]}`, "thickness", "skin"),
		"a thickness on a chain is refused with where the number comes from now");

	// Chains are a list beside the joints, not a field on every dot: the dots
	// say nothing, which is what keeps the answer for a rig with no physics
	// byte-identical to what it always was.
	Object* foot = skeleton_dot(skeleton, "foot");
	bool bare = foot != null && skeleton_chain(skeleton, "foot") == null;
	if (foot != null)
	{
		if (try Object* held = foot.get("physics")) bare = false;
		if (try Object* held = foot.get("secondary")) bare = false;
	}
	test::@check(bare, "and a bone inside the run is not reported as a chain of its own");

	Object*? read_capsules = skeleton.get("colliders");
	bool listed = false;
	if (try read_capsules)
	{
		listed = read_capsules.get_len() == 1
			&& (read_capsules.get_at(0).get_string("joint") ?? "") == "knee"
			&& math::abs((read_capsules.get_at(0).get_float("radius") ?? 0.0) - 0.125) < 1.0e-4;
	}
	test::@check(listed, "and the capsules come back as a list beside the joints");
}

<*
 A root alone is a whole tail, and a second call on the same root retunes it.

 Naming only the root is the difference between authoring a braid in one entry
 and authoring it in eleven, and the rule it walks is the rig's own shape rather
 than a length anybody configures: down while there is exactly one child. The
 second call states one value and keeps the rest, which is what makes "a bit
 looser" one field rather than a restatement of the whole chain.
*>
fn void a_root_alone_infers_the_run_and_a_second_call_retunes_it() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? answered = f.call_tool("set_secondary_motion", `{"chains":[{"root":"knee"}]}`);
	if (catch answered)
	{
		test::@check(false, "set_secondary_motion takes a bare root");
		return;
	}
	defer answered.free();

	Object*? rows = answered.get("chains");
	bool walked = false;
	if (try rows && rows.get_len() == 1)
	{
		Object* row = rows.get_at(0);
		// Tail is the preset a bare entry starts from, and these are Tail's values.
		walked = chain_runs(row, "knee", "foot")
			&& (row.get_string("preset") ?? "") == "tail"
			&& math::abs((row.get_float("flexibility") ?? 0.0) - 0.4) < 1.0e-6
			&& math::abs((row.get_float("damping") ?? 0.0) - 0.7) < 1.0e-6
			&& math::abs((row.get_float("gravity") ?? 0.0) - 1.0) < 1.0e-6
			&& (row.get_bool("collide") ?? false);
	}
	test::@check(walked && (answered.get_int("chain_count") ?? 0) == 1
		&& (answered.get_int("dynamic_bones") ?? 0) == 2,
		"a bare root infers the run below it and starts from Tail");

	// And the document really holds the chain, not merely the answer.
	crig::SecondaryChain held = f.app.doc.secondary_of(named_dot(f, "knee"));
	test::@check(held.present() && held.tip == named_dot(f, "foot"),
		"and the chain on the document runs to the foot");

	Object*? retuned = f.call_tool("set_secondary_motion", `{"chains":[{"root":"knee","flexibility":0.9,"collide":false}]}`);
	if (catch retuned)
	{
		test::@check(false, "a second call on the same root retunes it");
		return;
	}
	defer retuned.free();

	Object*? again = retuned.get("chains");
	bool kept = false;
	if (try again && again.get_len() == 1)
	{
		Object* row = again.get_at(0);
		kept = math::abs((row.get_float("flexibility") ?? 0.0) - 0.9) < 1.0e-6
			&& !(row.get_bool("collide") ?? true)
			&& math::abs((row.get_float("damping") ?? 0.0) - 0.7) < 1.0e-6
			&& (row.get_string("tip") ?? "") == "foot"
			&& !(row.get_bool("added") ?? true);
	}
	test::@check(kept, "a retune changes the values it names, keeps the rest, and says it added nothing");
	test::@check((retuned.get_int("chain_count") ?? 0) == 1, "and the rig still holds one chain, not two");
}

<*
 The shapes that are refused, each naming the joint or the field it is refusing.

 An agent cannot see the rig, so a refusal that says only "invalid" costs a whole
 turn to guess at. A root on the skeleton's root, a tip above its root and a
 run crossing another chain are refused rather than taken because
 `jiggle_specs_from_document` answers each with a shrug — it skips the chain —
 and a shrug reported as success is a chain that never moves.
*>
fn void set_secondary_motion_refuses_by_name() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	test::@check(
		f.refuses_tool("set_secondary_motion", `{"chains":[{"root":"tail"}]}`, "chains[0]", "tail", "hips", "knee"),
		"an unknown root is named, with the dots that could have been asked for");

	test::@check(
		f.refuses_tool("set_secondary_motion", `{"chains":[{"root":"hips"}]}`, "hips", "root", "knee"),
		"a chain on the skeleton's root is refused by name, with why it cannot hinge and which joint below it could");

	test::@check(
		f.refuses_tool("set_secondary_motion", `{"chains":[{"root":"foot","tip":"knee"}]}`, "chains[0]", "below the root"),
		"a tip above its root is refused");

	test::@check(
		f.refuses_tool("set_secondary_motion", `{"chains":[{"root":"knee","preset":"fluffy"}]}`, "chains[0]", "fluffy", "hair"),
		"an unknown preset is refused naming the ones there are");

	test::@check(
		f.refuses_tool("set_secondary_motion", `{"chains":[{"root":"knee","flexibility":3}]}`, "chains[0]", "flexibility", "3"),
		"a flexibility past 1 is refused naming the field");

	test::@check(
		f.refuses_tool("set_secondary_motion", `{"chains":[{"root":"knee","damping":true}]}`, "chains[0]", "damping", "number"),
		"a damping that is not a number is refused naming the field");

	// A chain from the knee, then one from the foot: the second would cross the
	// first at the foot, and is refused rather than quietly losing its only bone.
	Object*? first = f.call_tool("set_secondary_motion", `{"chains":[{"root":"knee"}]}`);
	if (catch first)
	{
		test::@check(false, "the check could set a chain to cross");
		return;
	}
	first.free();

	test::@check(
		f.refuses_tool("set_secondary_motion", `{"chains":[{"root":"foot"}]}`, "chains[0]", "crosses a chain"),
		"a run through a joint another chain owns is refused");

	test::@check(f.app.doc.secondary.len() == 1 && f.app.doc.secondary_of(named_dot(f, "knee")).present(),
		"and the refusal leaves the first chain as it was");
}

<*
 What a call takes back, and what it says it took back.

 Only what really changed is reported: the setter answers false for a root that
 carried no chain, and listing it as cleared would describe work nobody did.
*>
fn void set_secondary_motion_clears_what_it_set() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? marked = f.call_tool("set_secondary_motion",
		`{"chains":[{"root":"knee"}],"colliders":[{"joint":"knee","radius":0.2}]}`);
	if (catch marked)
	{
		test::@check(false, "the check could give the leg a chain");
		return;
	}
	marked.free();

	Object*? answered = f.call_tool("set_secondary_motion",
		`{"clear":["knee","hips"],"clear_colliders":["knee","foot"]}`);
	if (catch answered)
	{
		test::@check(false, "set_secondary_motion clears");
		return;
	}
	defer answered.free();

	Object*? cleared = answered.get("cleared");
	Object*? uncapped = answered.get("cleared_colliders");
	bool took = false;
	if (try cleared && try uncapped)
	{
		// "hips" rooted no chain and "foot" never had a capsule: both resolve, both
		// are quietly left alone, and neither is reported as work.
		took = cleared.get_len() == 1 && (cleared.get_string_at(0) ?? "") == "knee"
			&& uncapped.get_len() == 1 && (uncapped.get_string_at(0) ?? "") == "knee";
	}
	test::@check(took, "clear reports the chains that really went and no others");

	test::@check((answered.get_int("chain_count") ?? 0) == 0
		&& (answered.get_int("dynamic_bones") ?? 0) == 0
		&& (answered.get_int("capsules") ?? 0) == 0,
		"and the rig re-resolves to nothing dynamic");

	Object*? skeleton = f.call_tool("get_skeleton", "{}");
	if (catch skeleton)
	{
		test::@check(false, "get_skeleton answers after a clear");
		return;
	}
	defer skeleton.free();

	bool gone = skeleton_chain(skeleton, "knee") == null;
	if (try Object* leftover = skeleton.get("secondary")) gone = false;
	if (try Object* leftover = skeleton.get("colliders")) gone = false;
	test::@check(gone, "and get_skeleton stops reporting what was taken back, capsules included");

	// A clear and a set on the same root in one call is a chain moved rather than
	// two calls: the clears run first.
	Object*? moved = f.call_tool("set_secondary_motion",
		`{"chains":[{"root":"knee","tip":"knee"}],"clear":["knee"]}`);
	if (catch moved)
	{
		test::@check(false, "a clear and a set on one root in one call is taken");
		return;
	}
	defer moved.free();
	test::@check((moved.get_int("chain_count") ?? 0) == 1 && (moved.get_int("dynamic_bones") ?? 0) == 1,
		"and lands as the one-bone chain the set described");
}

<*
 A batch with one bad entry in it changes nothing at all.

 The rule `edit_rig` follows, and the reason it matters more here: a setup is
 several chains and capsules, so a call refused half-way through would leave a
 rig neither the caller nor the person at the screen described. Asserted
 against a rig that already carries a chain, so what is checked is that the
 refusal *restores* rather than that it leaves an empty list empty — and
 asserted on `get_skeleton`'s own bytes, since that is what an agent would
 compare.
*>
fn void set_secondary_motion_is_all_or_nothing() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? first = f.call_tool("set_secondary_motion",
		`{"chains":[{"root":"foot","flexibility":0.8}],"colliders":[{"joint":"knee","radius":0.2}]}`);
	if (catch first)
	{
		test::@check(false, "the check could set the chain it is about to try to disturb");
		return;
	}
	first.free();

	String before = crig::skeleton_json(&f.app);
	defer alloc::free(mem, before);

	// The foot's chain is cleared and set again looser, the capsule would move —
	// all of it behind one name that does not resolve.
	test::@check(
		f.refuses_tool("set_secondary_motion",
			`{"chains":[{"root":"foot","flexibility":0.1},{"root":"nowhere"}],`
			`"colliders":[{"joint":"foot","radius":0.3}],"clear":["foot"]}`,
			"nowhere"),
		"one entry that misses refuses the whole call");

	String after = crig::skeleton_json(&f.app);
	defer alloc::free(mem, after);

	test::@check(before == after, "and the rig is byte for byte where the call found it");
}

fn void play_names_the_clips_it_has() @test
{
	Fixture fixture;
	fixture.open_authored();
	defer fixture.close();
	Fixture* f = &fixture;
	test::@check(f.refuses_tool("play", `{"clip":"waltz"}`, "waltz", "The library holds", "bend"),
		"play on an unknown clip names it and lists what could have been asked for");
}

fn void play_says_why_a_clip_will_not_take() @test
{
	Fixture stranger;
	stranger.open_stranger();
	defer stranger.close();

	String clip = inapplicable_clip_name(&stranger.app);
	if (clip.len == 0)
	{
		test::@check(false, "the library holds a uniquely-named clip this rig cannot play");
		return;
	}

	String arguments = string::format(mem, `{"clip":"%s"}`, clip);
	defer alloc::free(mem, arguments);
	test::@check(stranger.refuses_tool("play", arguments, clip, "names no joint this rig has", "get_skeleton")
		&& !stranger.app.animating,
		"a clip written for another rig is refused by name, with the joints it turns");
}

fn void stop_says_what_it_stopped() @test
{
	Fixture fixture;
	fixture.open_playing();
	defer fixture.close();
	Fixture* f = &fixture;
	Object*? stopped = f.call_tool("stop", "{}");
	if (catch stopped)
	{
		test::@check(false, "stop answers");
		return;
	}
	defer stopped.free();

	test::@check((stopped.get_bool("playing") ?? true) == false
		&& (stopped.get_string("stopped") ?? "") == "bend"
		&& !f.app.animating,
		"stop ends playback and names the clip it took off the screen");
}

// Null rather than a missing key or an empty string: an answer that names no
// clip has to be readable without guessing which of the three it meant.
fn bool? stopped_nothing_body(Object* stopped)
{
	return stopped.get_bool("playing")! == false && stopped.get("stopped")!.is_null();
}

fn void stopping_nothing_is_not_an_error() @test
{
	Fixture fixture;
	fixture.open_authored();
	defer fixture.close();
	Fixture* f = &fixture;
	Object*? stopped = f.call_tool("stop", "{}");
	if (catch stopped)
	{
		test::@check(false, "a second stop answers");
		return;
	}
	defer stopped.free();

	test::@check(stopped_nothing_body(stopped) ?? false,
		"stopping when nothing plays says so rather than failing");
}
