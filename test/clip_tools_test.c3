<*
 Small fixes and clip tools: the plan tag surviving a sidecar without one, a smooth
 clip planted without ringing, bare clip names ranked, footfall impulses left out of
 the loop seam, unbind_clip / delete_model_clip, `extras.clips` surviving a save
 and a deferred read, and the root's pivot turn.

     `c3c test --test-noleak --test-filter crig_tests::clip_tools`
*>
module crig_tests::clip_tools;

import crig;
import gltf;
import rig;
import crig_tests::library;
import crig_tests::mcp;
import crig_tests::shared_app;
import std::collections::object;
import std::core::test;
import std::io;
import std::io::file;
import std::io::path;
import std::math;
import std::math::vector;

const String QUADRUPED = "assets/animations/quadruped.glb";

// ---------------------------------------------------------------------------
// 1. The plan tag

<*
 A glb that declares a plan whose sidecar does not must open with that plan, and
 a save must not strip it.
*>
fn void a_plan_only_the_glb_declares_survives_the_open() @test
{
	io::printn("a model's extras.plan fills a sidecar that names none");
	const String GLB = "build/clip-tools-plan.glb";
	String sidecar = crig::session_path(mem, GLB);
	defer sidecar.free(mem);
	(void)file::delete(GLB);
	(void)file::delete(sidecar);
	defer (void)file::delete(GLB);
	defer (void)file::delete(sidecar);

	Vec3[2] jpos = { { 0, 1, 0 }, { 0, 0.5f, 0 } };
	int[2] parents = { -1, 0 };
	rig::Skeleton skel = { .joints = jpos[..], .parents = parents[..] };
	String[2] names = { "hips", "knee" };
	crig::AnimTemplate walk = swing_clip("Walk", false);
	defer walk.free(mem);
	crig::AnimTemplate[1] one = { walk };
	if (catch crig::export_pack_glb(mem, GLB, &skel, names[..], one[..], {}, { .plan = "biped", .name = "Plan" }))
	{
		test::@check(false, "could not write the plan fixture");
		return;
	}

	// The sidecar, written by a document that declares no plan.
	{
		crig::AppState writer = crig::new_app({});
		defer writer.free();
		uint hips = writer.doc.add_dot({ 0, 1, 0 }, "hips");
		uint knee = writer.doc.add_dot({ 0, 0.5f, 0 }, "knee");
		writer.doc.connect(hips, knee);
		writer.doc.root_id = hips;
		test::@check(writer.doc.plan.len == 0, "the writer should declare no plan");
		test::@check(writer.save_rig_beside(GLB), "the sidecar did not write");
	}

	crig::AppState app = crig::new_app({});
	defer app.free();
	app.source_path = GLB.copy(mem);
	app.owns_path = true;
	app.adopt_source_rig();
	test::@check(app.doc.plan == "biped", "the glb's plan was not adopted (got '%s')", app.doc.plan);

	// And the save that follows keeps the tag in the file.
	test::@check(app.save_rig_beside(GLB), "the save did not write");
	crig::AnimPack? read = crig::read_pack(mem, GLB);
	if (catch read) { test::@check(false, "the saved file would not read"); return; }
	crig::AnimPack pack = read;
	defer pack.free(mem);
	test::@check(pack.plan == "biped", "the saved file lost its plan (got '%s')", pack.plan);
}

// ---------------------------------------------------------------------------
// 2. plant_feet on a smooth clip

<*
 A smooth clip with sparse swing keys, planted: the foot slides far less after,
 and the keys it added are linear.
*>
fn void planting_a_smooth_clip_does_not_ring() @test
{
	io::printn("plant_feet on a smooth sparse clip cuts foot_slide and keys linearly");
	mcp::Fixture fixture;
	if (!fixture.open_model(QUADRUPED)) return;
	defer fixture.close();
	mcp::Fixture* f = &fixture;

	Object*? authored = f.call_tool("apply_clip", SMOOTH_STEP);
	if (catch authored) { test::@check(false, "the smooth clip authors"); return; }
	authored.free();

	Object*? planted = f.call_tool("plant_feet", `{"clip":"smooth_step"}`);
	if (catch planted) { test::@check(false, "plant_feet answers"); return; }
	defer planted.free();

	Object* slide = planted.get("foot_slide")!!;
	double before = slide.get_float("before")!!;
	double after = slide.get_float("after")!!;
	test::@check(before > 0.01, "the clip skated to begin with (%.6g)", before);
	test::@check(after < before * 0.4, "planting cut foot_slide clearly (%.6g -> %.6g)", before, after);

	// Every rotation key it wrote into the leg is linear, not inherited.
	crig::AnimRef ref = crig::resolve_clip(&f.app, "smooth_step")!!;
	crig::AnimTemplate* clip = f.app.clip(ref);
	usz linear = 0;
	usz inherited = 0;
	foreach (frame : clip.keyframes)
	{
		foreach (dot : frame.dots)
		{
			if (dot.joint_name != "hip_L" && dot.joint_name != "hind_knee_L") continue;
			if (dot.rotation_interpolation == LINEAR) linear++;
			if (dot.rotation_interpolation == INHERIT) inherited++;
		}
	}
	test::@check(linear > 10, "the planted leg keys are linear (%d linear)", linear);
	test::@check(clip.blend == SMOOTH, "the clip itself stays smooth");
	(void)inherited;
}

// A smooth hind-left swing over sparse keys, with the hoof down for the first half.
// The quadruped faces −X, so its legs swing about Z.
const String SMOOTH_STEP @local = `{"name":"smooth_step","duration":1.0,"loop":true,"blend":"smooth","keyframes":[{"time":0,"joints":[{"name":"hip_L","rotation":{"axis":[0,0,1],"angle":0.5}},{"name":"hind_knee_L","rotation":{"axis":[0,0,1],"angle":0.2}}]},{"time":0.5,"joints":[{"name":"hip_L","rotation":{"axis":[0,0,1],"angle":-0.5}},{"name":"hind_knee_L","rotation":{"axis":[0,0,1],"angle":-0.2}}]}],"ground":{"feet":[{"joint":"hind_hoof_L","down":0.0,"up":0.5}]}}`;


// ---------------------------------------------------------------------------
// 3. Bare names ranked

<*
 A name several packs hold resolves to the bound clip, then Authored, instead of
 being an error.
*>
fn void a_bare_clip_name_is_ranked() @test
{
	io::printn("a bare clip name resolves by rank: bound, then Authored, then the rest");
	mcp::Fixture fixture;
	fixture.open();
	defer fixture.close();
	mcp::Fixture* f = &fixture;

	// A library pack and a bound copy of one of its clips, found by name.
	crig::AnimRef library_ref = crig::NO_ANIM;
	String name = "";
	foreach (p, pack : f.app.packs)
	{
		foreach (c, clip : pack.clips)
		{
			if (clip.name != "Idle") continue;
			library_ref = { (int)p, (int)c };
			name = clip.name;
			break;
		}
		if (library_ref.valid()) break;
	}
	test::@check(library_ref.valid(), "the library holds an Idle to shadow");
	if (!library_ref.valid()) return;

	// Before anything is authored the name is shared among library packs alone; it
	// may still be ambiguous there. Author one of the same name.
	Object*? authored = f.call_tool("apply_clip",
		`{"name":"Idle","duration":1.0,"keyframes":[{"time":0,"joints":[{"name":"knee","rotation":{"axis":[1,0,0],"angle":0.2}}]}]}`);
	if (catch authored) { test::@check(false, "the authored Idle writes"); return; }
	authored.free();

	// apply_clip binds the authored clip, so it is rank 1 and 0 at once.
	crig::AnimRef first = crig::resolve_clip(&f.app, "Idle")!!;
	test::@check(first.pack == f.app.authored_pack, "a bare name finds the authored clip");

	// Bind the library's own copy: a bound clip outranks Authored.
	f.app.doc.free_animations();
	test::@check(f.app.bind_ref(library_ref), "the library Idle binds");
	crig::AnimRef second = crig::resolve_clip(&f.app, "Idle")!!;
	test::@check(second.same(library_ref), "the bound library clip outranks the authored one");

	// Unbound again, Authored wins over the library packs.
	test::@check(f.app.unbind_recorded(0), "the library Idle unbinds");
	crig::AnimRef third = crig::resolve_clip(&f.app, "Idle")!!;
	test::@check(third.pack == f.app.authored_pack, "Authored outranks an unbound library clip");

	// A qualified name is still exact.
	crig::AnimRef exact = crig::resolve_clip(&f.app,
		string::tformat("%s/Idle", f.app.packs[(usz)library_ref.pack].name))!!;
	test::@check(exact.pack != f.app.authored_pack, "Pack/Clip still says which pack");
}

<*
 Two packs holding the same name, neither bound nor authored, tie: the bare name is
 still ambiguous and the refusal says to qualify it.
*>
fn void a_tied_bare_name_is_still_ambiguous() @test
{
	io::printn("a bare name two packs tie on is refused, telling the caller to qualify");
	const String DIR = "build/clip-tools-tie";
	(void)path::mkdir((Path)DIR);
	Vec3[2] jpos = { { 0, 1, 0 }, { 0, 0.5f, 0 } };
	int[2] parents = { -1, 0 };
	rig::Skeleton skel = { .joints = jpos[..], .parents = parents[..] };
	String[2] names = { "hips", "knee" };
	crig::AnimTemplate walk = swing_clip("Sneak", false);
	defer walk.free(mem);
	crig::AnimTemplate[1] one = { walk };
	String[2] files = { "build/clip-tools-tie/first.glb", "build/clip-tools-tie/second.glb" };
	foreach (file : files)
	{
		if (catch crig::export_pack_glb(mem, file, &skel, names[..], one[..], {}, { .name = file[24..^4] }))
		{
			test::@check(false, "could not write a tie fixture");
			return;
		}
	}
	defer (void)file::delete(files[0]);
	defer (void)file::delete(files[1]);

	crig::AppState app = crig::new_app({});
	defer app.free();
	uint hips = app.doc.add_dot({ 0, 1, 0 }, "hips");
	uint knee = app.doc.add_dot({ 0, 0.5f, 0 }, "knee");
	app.doc.connect(hips, knee);
	app.doc.root_id = hips;
	app.load_packs(DIR);

	DString detail = dstring::new(mem);
	defer detail.free();
	crig::AnimRef? found = crig::resolve_named(&app, "Sneak", &detail);
	test::@check(@catch(found) == crig::CLIP_AMBIGUOUS, "a tie is ambiguous");
	test::@check(detail.str_view().contains("Pack/Clip"), "and says how to qualify it: %s", detail.str_view());
}

// ---------------------------------------------------------------------------
// 4. Footfall impulses at the loop seam

fn Object* issue_of(Object* metrics, String kind)
{
	Object*? issues = metrics.get("issues");
	if (catch issues) return null;
	for (sz i = 0; i < issues.get_len(); i++)
	{
		Object* row = issues.get_at(i);
		if ((row.get_string("kind") ?? "") == kind) return row;
	}
	return null;
}

<*
 A foot touching down at the seam is an impulse, not a loop fault. The same swing
 with its window elsewhere is still reported.
*>
fn void a_footfall_at_the_seam_is_not_a_loop_fault() @test
{
	io::printn("measure_clip leaves a contact joint's seam impulse out of loop_velocity");
	mcp::Fixture fixture;
	fixture.open();
	defer fixture.close();
	mcp::Fixture* f = &fixture;

	String edge = `{"name":"at_seam","duration":1.0,"loop":true,"keyframes":[{"time":0,"joints":[{"name":"knee","rotation":{"x":0,"y":0,"z":0,"w":1}}]},{"time":0.5,"joints":[{"name":"knee","rotation":{"axis":[1,0,0],"angle":1.0}}]}],"ground":{"feet":[{"joint":"foot","down":0.0,"up":0.5}]}}`;
	String inside = `{"name":"mid_cycle","duration":1.0,"loop":true,"keyframes":[{"time":0,"joints":[{"name":"knee","rotation":{"x":0,"y":0,"z":0,"w":1}}]},{"time":0.5,"joints":[{"name":"knee","rotation":{"axis":[1,0,0],"angle":1.0}}]}],"ground":{"feet":[{"joint":"foot","down":0.25,"up":0.75}]}}`;

	Object*? a = f.call_tool("apply_clip", edge);
	if (catch a) { test::@check(false, "the seam clip authors"); return; }
	a.free();
	Object*? b = f.call_tool("apply_clip", inside);
	if (catch b) { test::@check(false, "the mid-cycle clip authors"); return; }
	b.free();

	Object*? at_seam = f.call_tool("measure_clip", `{"clip":"at_seam"}`);
	if (catch at_seam) { test::@check(false, "measure_clip answers"); return; }
	defer at_seam.free();
	test::@check(issue_of(at_seam, "loop_velocity") == null,
		"a foot whose window starts at the seam reports no loop_velocity");

	Object*? mid = f.call_tool("measure_clip", `{"clip":"mid_cycle"}`);
	if (catch mid) { test::@check(false, "measure_clip answers"); return; }
	defer mid.free();
	test::@check(issue_of(mid, "loop_velocity") != null,
		"the same swing with its window elsewhere still reports the seam");
}

// ---------------------------------------------------------------------------
// 5. unbind_clip / delete_model_clip

fn void unbind_clip_takes_a_clip_off_the_character() @test
{
	io::printn("unbind_clip drops a binding and refuses what is not bound");
	mcp::Fixture fixture;
	fixture.open();
	defer fixture.close();
	mcp::Fixture* f = &fixture;

	Object*? authored = f.call_tool("apply_clip", SWING_CLIP);
	if (catch authored) { test::@check(false, "the clip authors"); return; }
	authored.free();
	test::@check(f.app.doc.bound_index("", "swing") >= 0, "apply_clip binds the clip");

	Object*? gone = f.call_tool("unbind_clip", `{"clip":"swing"}`);
	if (catch gone) { test::@check(false, "unbind_clip answers"); return; }
	defer gone.free();
	test::@check((gone.get_string("unbound") ?? "") == "swing", "it names what it unbound");
	test::@check(f.app.doc.bound_index("", "swing") < 0, "the binding is gone");
	test::@check(f.app.clip_named_in_authored("swing").valid(), "the clip itself stays in its pack");

	test::@check(f.refuses_tool("unbind_clip", `{"clip":"swing"}`, "no bound clip"),
		"a clip that is not bound is refused");
	test::@check(f.refuses_tool("unbind_clip", `{}`, "clip"), "a call without a clip is refused");
}

const String SWING_CLIP @local = `{"name":"swing","duration":1.0,"keyframes":[{"time":0,"joints":[{"name":"knee","rotation":{"axis":[1,0,0],"angle":0.3}}]}]}`;

<*
 delete_model_clip re-saves the model without the clip, and says no to a clip the
 file does not hold or a document with no mesh.
*>
fn void delete_model_clip_re_saves_the_model() @test
{
	io::printn("delete_model_clip removes a clip from the loaded model's file");
	String path = "build/clip-tools-delete.glb";
	char[] original = file::load(mem, "assets/animations/humanoid.glb")!!;
	defer alloc::free(mem, original);
	file::save(path, original)!!;
	defer (void)file::delete(path);
	defer (void)file::delete("build/clip-tools-delete.rigsmith.json");

	rig::TriMesh mesh = rig::load_gltf(mem, path)!!;
	defer mesh.free(mem);
	mcp::Fixture fixture;
	fixture.app = crig::new_app(mesh, path);
	fixture.tools = crig::new_tool_table(&fixture.app);
	fixture.server = crig::serve_table(&fixture.tools, &fixture.app);
	defer fixture.close();
	mcp::Fixture* f = &fixture;
	f.app.saves_in_place = true;
	test::@check(f.app.import_rig_from_source(), "the humanoid rig must import");
	f.app.reindex_current_model();

	String victim = "";
	foreach (&entry : f.app.assets.entries)
	{
		if (entry.kind == crig::AssetKind.ANIMATION && entry.current) { victim = entry.name.copy(mem); break; }
	}
	defer if (victim.len > 0) victim.free(mem);
	test::@check(victim.len > 0, "the model lists a clip of its own");
	if (victim.len == 0) return;

	test::@check(f.refuses_tool("delete_model_clip", `{"clip":"no such clip"}`, "not one of the loaded model"),
		"a clip the file does not hold is refused");

	String args = string::format(mem, `{"clip":"%s"}`, victim);
	defer args.free(mem);
	Object*? deleted = f.call_tool("delete_model_clip", args);
	if (catch deleted) { test::@check(false, "delete_model_clip answers"); return; }
	deleted.free();

	gltf::GltfStream after = gltf::open(path, mem)!!;
	bool still_there = false;
	foreach (anim : after.gltf.animations) if (anim.name == victim) still_there = true;
	after.close();
	test::@check(!still_there, "the clip is gone from the file");

	// No mesh: the model cannot be re-saved, and the tool says so.
	mcp::Fixture bare;
	bare.open_bare();
	defer bare.close();
	test::@check(bare.refuses_tool("delete_model_clip", `{"clip":"x"}`, "no model"),
		"with no model open there is nothing to delete from");
}

// ---------------------------------------------------------------------------
// 6. extras.clips

<*
 A tiny smooth, non-looping clip with a ground spec, so every setting extras.clips
 carries has a value to lose.
*>
fn crig::AnimTemplate swing_clip(String name, bool loop)
{
	crig::AnimKeyframe[] keys = alloc::new_array(mem, crig::AnimKeyframe, 2);
	foreach (usz i, &key : keys)
	{
		crig::AnimKeyDot[] dots = alloc::new_array(mem, crig::AnimKeyDot, 1);
		dots[0] = {
			.joint_name = "knee".copy(mem),
			.axis = { 1, 0, 0 },
			.angle = i == 0 ? 0.0f : 0.6f,
			.channels = ROTATION,
		};
		*key = { .time = (float)i * 0.5f, .dots = dots };
	}
	crig::AnimFoot[] feet = alloc::new_array(mem, crig::AnimFoot, 1);
	feet[0] = { .joint = "knee".copy(mem), .down = 0.25f, .up = 0.75f };
	return {
		.name = name.copy(mem),
		.duration = 1.0f,
		.keyframes = keys,
		.owned = true,
		.loop = loop,
		.blend = SMOOTH,
		.ground = { .feet = feet },
	};
}

// What a clip read back from a file declared for itself.
fn bool settings_survive(crig::AnimTemplate* clip)
{
	return clip.blend == SMOOTH && !clip.loop && clip.ground.feet.len == 1
		&& clip.ground.feet[0].joint == "knee";
}

<*
 Save stamps the bound clips' settings rather than removing the member.
*>
fn void a_save_keeps_the_clips_blend_loop_and_ground() @test
{
	io::printn("a save keeps extras.clips (blend, loop, ground)");
	const String GLB = "build/clip-tools-extras.glb";
	String sidecar = crig::session_path(mem, GLB);
	defer sidecar.free(mem);
	(void)file::delete(sidecar);
	defer (void)file::delete(GLB);
	defer (void)file::delete(sidecar);

	Vec3[2] jpos = { { 0, 1, 0 }, { 0, 0.5f, 0 } };
	int[2] parents = { -1, 0 };
	rig::Skeleton skel = { .joints = jpos[..], .parents = parents[..] };
	String[2] names = { "hips", "knee" };
	crig::AnimTemplate walk = swing_clip("Sneak", false);
	defer walk.free(mem);
	crig::AnimTemplate[1] one = { walk };
	if (catch crig::export_animations_glb(mem, GLB, &skel, names[..], one[..]))
	{
		test::@check(false, "could not write the fixture");
		return;
	}
	{
		crig::AnimPack? read = crig::read_pack(mem, GLB);
		if (catch read) { test::@check(false, "the fixture would not read"); return; }
		crig::AnimPack pack = read;
		defer pack.free(mem);
		test::@check(settings_survive(&pack.clips[0]), "the fixture carries its settings");
	}

	crig::AppState app = crig::new_app({});
	defer app.free();
	uint hips = app.doc.add_dot({ 0, 1, 0 }, "hips");
	uint knee = app.doc.add_dot({ 0, 0.5f, 0 }, "knee");
	app.doc.connect(hips, knee);
	app.doc.root_id = hips;

	// No clips handed over leaves the member alone: what the export wrote stays.
	test::@check(app.save_rig_beside(GLB), "the save did not write");
	{
		crig::AnimPack? read = crig::read_pack(mem, GLB);
		if (catch read) { test::@check(false, "the saved file would not read"); return; }
		crig::AnimPack pack = read;
		defer pack.free(mem);
		test::@check(settings_survive(&pack.clips[0]), "a save with no clips stripped extras.clips");
	}

	// Handing the bound clips over rewrites them from the live templates.
	crig::AnimTemplate[1] live = { walk };
	test::@check(app.save_rig_beside(GLB, stamped_clips: live[..]), "the stamped save did not write");
	{
		crig::AnimPack? read = crig::read_pack(mem, GLB);
		if (catch read) { test::@check(false, "the stamped file would not read"); return; }
		crig::AnimPack pack = read;
		defer pack.free(mem);
		test::@check(settings_survive(&pack.clips[0]), "a stamped save lost the settings");
	}
}

<*
 A deferred pack's clip keeps its blend, loop and ground when it is read on demand.
*>
fn void a_deferred_clip_keeps_its_settings_when_imported() @test
{
	io::printn("ensure_clip_imported keeps the stub's extras.clips settings");
	const String DIR = "build/clip-tools-deferred";
	(void)path::mkdir((Path)DIR);
	String glb = string::format(mem, "%s/rig.glb", DIR);
	defer glb.free(mem);
	(void)file::delete(glb);
	defer (void)file::delete(glb);

	Vec3[2] jpos = { { 0, 1, 0 }, { 0, 0.5f, 0 } };
	int[2] parents = { -1, 0 };
	rig::Skeleton skel = { .joints = jpos[..], .parents = parents[..] };
	String[2] names = { "hips", "knee" };
	crig::AnimTemplate walk = swing_clip("Sneak", false);
	defer walk.free(mem);
	crig::AnimTemplate[1] one = { walk };
	if (catch crig::export_animations_glb(mem, glb, &skel, names[..], one[..]))
	{
		test::@check(false, "could not write the fixture");
		return;
	}

	crig::AppState app = crig::new_app({});
	defer app.free();
	int pack = app.pack_for_file(glb);
	if (pack < 0)
	{
		// Not under a library: adopt it by file the way a binding would.
		app.config.libraries.init(mem);
		app.config.libraries.push({ .name = "Deferred".copy(mem), .path = DIR.copy(mem) });
		app.rescan_assets();
		pack = app.pack_for_file(glb);
	}
	test::@check(pack >= 0, "the pack loads");
	if (pack < 0) return;

	crig::AnimRef ref = app.clip_named_in(pack, "Sneak");
	test::@check(ref.valid(), "the clip is found by name");
	test::@check(app.clip(ref).lazy, "the pack deferred the clip");
	test::@check(app.ensure_clip_imported(ref), "the clip imports");
	crig::AnimTemplate* clip = app.clip(ref);
	test::@check(!clip.lazy && clip.keyframes.len > 0, "it holds its keys now");
	test::@check(settings_survive(clip), "the imported clip lost its blend, loop or ground (blend %s, loop %s)",
		clip.blend == SMOOTH ? "smooth" : "linear", clip.loop ? "true" : "false");
}

// ---------------------------------------------------------------------------
// 7. The root's pivot

fn void a_root_turn_can_pivot_about_another_joint() @test
{
	io::printn("apply_clip's root pivot keeps the pivot joint where it was");
	mcp::Fixture fixture;
	fixture.open();
	defer fixture.close();
	mcp::Fixture* f = &fixture;

	// The hips turned a radian about Z, pivoting on the foot at the origin.
	Object*? authored = f.call_tool("apply_clip",
		`{"name":"pivoted","duration":1.0,"keyframes":[{"time":0,"joints":[{"name":"hips","rotation":{"axis":[0,0,1],"angle":1.0},"pivot":"foot"}]}]}`);
	if (catch authored) { test::@check(false, "the pivoted clip authors"); return; }
	authored.free();

	Object*? plain = f.call_tool("apply_clip",
		`{"name":"unpivoted","duration":1.0,"keyframes":[{"time":0,"joints":[{"name":"hips","rotation":{"axis":[0,0,1],"angle":1.0}}]}]}`);
	if (catch plain) { test::@check(false, "the plain clip authors"); return; }
	plain.free();

	Object*? pose = f.call_tool("get_pose", `{"clip":"pivoted","t":0}`);
	if (catch pose) { test::@check(false, "get_pose answers"); return; }
	defer pose.free();
	Vec3 foot = mcp::posed_at(pose, "foot")!!;
	Vec3 hips = mcp::posed_at(pose, "hips")!!;
	test::@check(foot.length() < 0.001f, "the pivot joint did not move (%.4f, %.4f, %.4f)", foot.x, foot.y, foot.z);
	test::@check((hips - (Vec3){ 0, 1, 0 }).length() > 0.1f, "the root moved to make it so");

	// Without the pivot the foot swings away, which is what the pivot corrected.
	Object*? swung = f.call_tool("get_pose", `{"clip":"unpivoted","t":0}`);
	if (catch swung) { test::@check(false, "get_pose answers"); return; }
	defer swung.free();
	test::@check(mcp::posed_at(swung, "foot")!!.length() > 0.1f, "the unpivoted turn moves the foot");

	test::@check(f.refuses_tool("apply_clip",
		`{"name":"bad","duration":1.0,"keyframes":[{"time":0,"joints":[{"name":"knee","rotation":{"axis":[1,0,0],"angle":0.2},"pivot":"foot"}]}]}`,
		"pivot", "root"), "a pivot on a joint that is not the root is refused");
	test::@check(f.refuses_tool("apply_clip",
		`{"name":"bad","duration":1.0,"keyframes":[{"time":0,"joints":[{"name":"hips","rotation":{"axis":[1,0,0],"angle":0.2},"pivot":"elbow"}]}]}`,
		"elbow", "not a joint"), "a pivot naming nothing is refused");
}
