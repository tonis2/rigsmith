<*
 Authored motion in the project sidecar, independently of the UI and glTF.

     `c3c test --trust=full --test-noleak --test-filter crig_tests::authored_session`
*>
module crig_tests::authored_session;

import crig;
import crig_tests::library;
import gltf_edit;
import rig;
import std::core::test;
import std::io;
import std::io::file;
import std::io::path;
import std::math;
import std::math::vector;
import std::core::string;

const String SESSION = "build/authored-session.rigsmith.json";
const String APP_MESH = "build/authored-app.glb";
const String APP_SESSION = "build/authored-app.rigsmith.json";

fn AnimTemplate authored()
{
	AnimKeyframe[] keys = alloc::new_array(mem, AnimKeyframe, 2);
	foreach (usz i, &key : keys)
	{
		AnimKeyDot[] dots = alloc::new_array(mem, AnimKeyDot, 1);
		dots[0] = {
			.joint_name = "hips \"main\"".copy(mem),
			.axis = { 0.125f, 0.5f, -0.75f },
			.angle = i == 0 ? -1.2345678f : 2.3456781f,
			.move = { 0.012345678f + (float)i, -0.25f, 4.5f },
			.bone = { -0.2f, 0.9f, 0.35f },
			.channels = ROTATION,
			.rotation_interpolation = i == 0 ? HOLD : AUTO,
		};
		*key = { .time = (float)i * 0.8754321f, .dots = dots };
	}
	AnimFoot[] feet = alloc::new_array(mem, AnimFoot, 1);
	feet[0] = { .joint = "foot_L".copy(mem), .down = 0.8123457f, .up = 0.2345678f };
	return {
		.name = "Attack / authored".copy(mem),
		.duration = 1.7508642f,
		.keyframes = keys,
		.loop = true,
		.blend = SMOOTH,
		.ground = { .feet = feet, .floor = -0.12345678f, .floor_set = true },
		.owned = true,
	};
}

fn bool same_float(float a, float b) => math::abs(a - b) < 1.0e-7f;

fn void authored_motion_round_trips_exactly() @test
{
	io::printn("authored keys and grounding round-trip through a project session");
	RigDocument doc = {};
	defer doc.free();
	AnimTemplate clip = authored();
	defer clip.free(mem);
	AnimTemplate[1] source = { clip };

	String text = crig::session_text(mem, &doc, "hero.glb", source[..]);
	defer text.free(mem);
	AnimTemplate[]? parsed = crig::parse_session_clips(mem, text);
	if (catch fault error = parsed)
	{
		test::@check(false, "the authored payload did not parse: %s", error);
		return;
	}
	AnimTemplate[] clips = parsed;
	defer crig::free_animations(mem, clips);
	test::@check(clips.len == 1, "the session returned %d authored clips", clips.len);
	if (clips.len != 1) return;

	AnimTemplate back = clips[0];
	test::@check(back.name == clip.name && back.loop && back.blend == SMOOTH,
		"clip identity/settings changed");
	test::@check(same_float(back.duration, clip.duration), "duration changed in JSON");
	test::@check(back.keyframes.len == 2 && back.keyframes[0].dots.len == 1,
		"the keys or keyed joints changed");
	AnimKeyDot a = clip.keyframes[1].dots[0];
	AnimKeyDot b = back.keyframes[1].dots[0];
	test::@check(b.joint_name == a.joint_name && same_float(b.angle, a.angle)
		&& b.axis == a.axis && b.move == a.move && b.bone == a.bone
		&& b.channels == ROTATION && b.rotation_interpolation == AUTO
		&& b.translation_interpolation == INHERIT,
		"an authored keyed value failed exact float32 preservation");
	test::@check(back.ground.floor_set && same_float(back.ground.floor, clip.ground.floor),
		"the explicit ground floor changed");
	test::@check(back.ground.feet.len == 1 && back.ground.feet[0].joint == "foot_L"
		&& same_float(back.ground.feet[0].down, clip.ground.feet[0].down)
		&& same_float(back.ground.feet[0].up, clip.ground.feet[0].up),
		"the contact interval changed");
}

fn void authored_motion_writes_and_reopens_from_disk() @test
{
	io::printn("an authored clip writes atomically and reopens from disk");
	RigDocument doc = {};
	defer doc.free();
	AnimTemplate clip = authored();
	defer clip.free(mem);
	AnimTemplate[1] source = { clip };

	(void)file::delete(SESSION);
	defer (void)file::delete(SESSION);
	if (catch fault error = crig::write_session(SESSION, &doc, "hero.glb", source[..]))
	{
		test::@check(false, "could not write the authored session: %s", error);
		return;
	}
	test::@check(file::is_file(SESSION), "the atomic writer left no destination file");
	test::@check(!file::is_file("build/authored-session.rigsmith.json.tmp.0"),
		"the successful atomic write left its temporary file behind");

	AnimTemplate[]? read = crig::read_session_clips(mem, SESSION);
	if (catch fault error = read)
	{
		test::@check(false, "the authored session did not reopen: %s", error);
		return;
	}
	AnimTemplate[] clips = read;
	defer crig::free_animations(mem, clips);
	test::@check(clips.len == 1 && clips[0].name == clip.name,
		"the disk round-trip lost the authored clip");
}

fn void a_failed_atomic_save_preserves_the_previous_project() @test
{
	io::printn("a failed atomic save preserves the previous sidecar and live clip");
	RigDocument doc = {};
	defer doc.free();
	AnimTemplate clip = authored();
	defer clip.free(mem);
	AnimTemplate[1] source = { clip };
	(void)file::delete(SESSION);
	defer (void)file::delete(SESSION);
	if (catch crig::write_session(SESSION, &doc, "hero.glb", source[..]))
	{
		test::@check(false, "could not establish the previous sidecar");
		return;
	}
	char[]? loaded = file::load(mem, SESSION);
	if (catch loaded) { test::@check(false, "could not read the previous sidecar"); return; }
	char[] before = loaded;
	defer alloc::free(mem, before);

	// Occupy every exclusive sibling name. The writer must refuse rather than
	// overwrite one of these or fall back to touching the destination in place.
	for (uint i = 0; i < 100; i++)
	{
		String temporary = string::format(mem, "%s.tmp.%d", SESSION, i);
		defer temporary.free(mem);
		if (catch file::save(temporary, "occupied"))
		{
			test::@check(false, "could not occupy atomic temporary %d", i);
			return;
		}
	}
	defer for (uint i = 0; i < 100; i++)
	{
		String temporary = string::format(mem, "%s.tmp.%d", SESSION, i);
		(void)file::delete(temporary);
		temporary.free(mem);
	};

	clip.duration = 9.0f;
	source[0].duration = clip.duration;
	bool failed = false;
	if (catch crig::write_session(SESSION, &doc, "hero.glb", source[..])) failed = true;
	test::@check(failed, "the writer overwrote an occupied temporary sibling");
	crig::AppState app = crig::new_app({});
	defer app.free();
	app.source_path = "build/authored-session.glb".copy(mem);
	app.owns_path = true;
	app.saves_in_place = true;
	app.doc.root_id = app.doc.add_dot({}, "root");
	AnimTemplate[] live = alloc::new_array(mem, AnimTemplate, 1);
	live[0] = authored();
	live[0].duration = 9.0f;
	app.replace_authored_clips(live);
	app.authored_dirty = true;
	app.save_session();
	test::@check(app.authored_dirty && app.authored().clips[0].duration == 9.0f,
		"normal Save failure cleared dirtiness or discarded the live edit");
	char[]? reread = file::load(mem, SESSION);
	if (catch reread) { test::@check(false, "failed save removed the previous sidecar"); return; }
	char[] after = reread;
	defer alloc::free(mem, after);
	test::@check((String)after == (String)before, "failed save changed the previous project bytes");
	test::@check(clip.duration == 9.0f && clip.keyframes.len == 2,
		"failed save mutated the live authored clip");
}

fn void malformed_authored_payload_is_recoverable() @test
{
	io::printn("a malformed authored payload is refused without poisoning later reads");
	// A complete first clip forces the parser to release already-owned content
	// when the second clip fails after copying its joint name.
	const String BROKEN = `{"authored_clips":[{"name":"good","duration":1,"loop":false,"blend":"linear","keys":[{"time":0,"dots":[]}]},{"name":"bad","duration":1,"loop":true,"blend":"smooth","keys":[{"time":0,"dots":[{"joint":"hips"}]}]}]}`;
	AnimTemplate[]? rejected = crig::parse_session_clips(mem, BROKEN);
	bool rejected_bad = false;
	if (catch rejected) rejected_bad = true;
	test::@check(rejected_bad, "a partial keyed joint was accepted as authored motion");

	const String DUPLICATES = `{"authored_clips":[{"name":"same","duration":1,"loop":false,"blend":"linear","keys":[{"time":0,"dots":[]}]},{"name":"same","duration":1,"loop":false,"blend":"linear","keys":[{"time":0,"dots":[]}]}]}`;
	AnimTemplate[]? repeated = crig::parse_session_clips(mem, DUPLICATES);
	bool rejected_duplicates = false;
	if (catch repeated) rejected_duplicates = true;
	test::@check(rejected_duplicates, "duplicate authored clip names were accepted");

	const String UNORDERED = `{"authored_clips":[{"name":"bad times","duration":1,"loop":false,"blend":"linear","keys":[{"time":0.75,"dots":[]},{"time":0.25,"dots":[]}]}]}`;
	AnimTemplate[]? backwards = crig::parse_session_clips(mem, UNORDERED);
	bool rejected_unordered = false;
	if (catch backwards) rejected_unordered = true;
	test::@check(rejected_unordered, "decreasing authored key times were accepted");

	RigDocument doc = {};
	defer doc.free();
	AnimTemplate clip = authored();
	defer clip.free(mem);
	AnimTemplate[1] source = { clip };
	String valid = crig::session_text(mem, &doc, "hero.glb", source[..]);
	defer valid.free(mem);
	AnimTemplate[]? retried = crig::parse_session_clips(mem, valid);
	if (catch retried)
	{
		test::@check(false, "a failed parse poisoned the next valid project read");
		return;
	}
	AnimTemplate[] clips = retried;
	defer crig::free_animations(mem, clips);
	test::@check(clips.len == 1, "the valid retry lost its authored clip");
}

fn void legacy_whole_pose_omissions_remain_rest_keys() @test
{
	io::printn("legacy authored clips expand omissions to explicit rest keys");
	const String LEGACY = `{"authored_clips":[{"name":"legacy","duration":1,"loop":false,"blend":"linear","keys":[{"time":0,"dots":[{"joint":"a","axis":[1,0,0],"angle":0.5,"move":[0,0,0],"bone":[0,1,0]}]},{"time":1,"dots":[{"joint":"b","axis":[0,1,0],"angle":0.25,"move":[0,0,0],"bone":[1,0,0]}]}]}]}`;
	AnimTemplate[]? parsed = crig::parse_session_clips(mem, LEGACY);
	if (catch parsed) { test::@check(false, "legacy authored clip did not parse"); return; }
	AnimTemplate[] clips = parsed;
	defer crig::free_animations(mem, clips);
	test::@check(clips.len == 1 && clips[0].keyframes[0].dots.len == 2
		&& clips[0].keyframes[1].dots.len == 2,
		"legacy omissions were not expanded across the joint union");
	if (clips.len != 1) return;
	test::@check(clips[0].keyframes[0].dots[1].joint_name == "b"
		&& clips[0].keyframes[0].dots[1].angle == 0.0f
		&& clips[0].keyframes[1].dots[1].joint_name == "a"
		&& clips[0].keyframes[1].dots[1].angle == 0.0f,
		"legacy omissions did not become explicit rest values");
}

fn void app_save_and_reload_restores_authored_bindings() @test
{
	io::printn("AppState saves and reloads its authored pack and binding");
	crig::AppState app = crig::new_app({});
	defer app.free();
	app.source_path = APP_MESH.copy(mem);
	app.owns_path = true;
	app.saves_in_place = true;
	uint root = app.doc.add_dot({}, "root");
	app.doc.root_id = root;
	(void)file::delete(APP_SESSION);
	defer (void)file::delete(APP_SESSION);

	AnimTemplate[] clips = alloc::new_array(mem, AnimTemplate, 1);
	clips[0] = authored();
	app.replace_authored_clips(clips);
	app.authored_dirty = true;
	AnimRef original = app.clip_named_in_authored("Attack / authored");
	test::@check(original.valid() && app.bind_ref(original), "the authored clip would not bind");
	app.editing = original;
	app.edit_time = 0.42f;
	app.save_beside_mesh();
	test::@check(file::is_file(APP_SESSION), "AppState wrote no project sidecar");
	test::@check(!app.authored_dirty, "a successful normal save left authored motion dirty");

	app.load_session();
	AnimRef restored = app.clip_named_in_authored("Attack / authored");
	test::@check(restored.valid(), "reload did not restore the authored clip");
	test::@check(app.editing.valid() && app.clip(app.editing).name == "Attack / authored"
		&& app.edit_time == 0.42f,
		"reload did not remap the editing identity and preserve its playhead");
	test::@check(app.resolve_bound(0).valid(), "reload did not resolve its authored binding");
	AnimTemplate* clip = app.clip(restored);
	test::@check(clip != null && clip.keyframes.len == 2 && clip.ground.solves(),
		"reload lost authored keys or grounding");
}

// An authored clip the character no longer holds has no row anywhere to see or
// delete it by, so the sidecar stops carrying it (mog's 3MB generated jump did).
fn void an_unbound_authored_clip_leaves_the_sidecar() @test
{
	crig::AppState app = crig::new_app({});
	defer app.free();
	app.source_path = APP_MESH.copy(mem);
	app.owns_path = true;
	app.saves_in_place = true;
	uint root = app.doc.add_dot({}, "root");
	app.doc.root_id = root;
	(void)file::delete(APP_SESSION);
	defer (void)file::delete(APP_SESSION);

	AnimTemplate[] clips = alloc::new_array(mem, AnimTemplate, 1);
	clips[0] = authored();
	app.replace_authored_clips(clips);
	AnimRef clip = app.clip_named_in_authored("Attack / authored");
	test::@check(clip.valid() && app.bind_ref(clip), "the authored clip would not bind");
	test::@check(app.unbind_recorded(0), "could not un-bind it");
	test::@check(app.clip_named_in_authored("Attack / authored").valid(), "un-bind dropped the clip in memory");

	app.save_beside_mesh();
	char[] text = file::load(mem, APP_SESSION)!!;
	defer alloc::free(mem, text);
	test::@check(!((String)text).contains("Attack / authored"), "the sidecar still carries the un-bound clip");
}

<*
 The clips Save bakes into the model are the character's *bound* clips — an
 authored clip bound to the character reaches the file itself, not only the
 sidecar. This is the fix for authored clips (Walk, Sneak) being missing from a
 saved .glb and from the Asset view that reads it.
*>
fn void a_bound_authored_clip_bakes_into_the_model() @test
{
	io::printn("Save bakes the character's bound clips into the model, not only the file's own");
	crig::AppState app = crig::new_app({});
	defer app.free();

	// A tiny rig whose joints an authored clip can name.
	uint hips = app.doc.add_dot({ 0, 1, 0 }, "hips");
	uint knee = app.doc.add_dot({ 0, 0.5f, 0 }, "knee");
	app.doc.connect(hips, knee);
	app.doc.root_id = hips;

	// An authored clip that turns the knee, bound to the character.
	AnimKeyframe[] keys = alloc::new_array(mem, AnimKeyframe, 2);
	foreach (usz i, &key : keys)
	{
		AnimKeyDot[] dots = alloc::new_array(mem, AnimKeyDot, 1);
		dots[0] = {
			.joint_name = "knee".copy(mem),
			.axis = { 1, 0, 0 },
			.angle = i == 0 ? 0.0f : 0.6f,
			.channels = ROTATION,
		};
		*key = { .time = (float)i * 0.5f, .dots = dots };
	}
	AnimTemplate[] clips = alloc::new_array(mem, AnimTemplate, 1);
	clips[0] = { .name = "Sneak".copy(mem), .duration = 1.0f, .keyframes = keys, .owned = true };
	app.replace_authored_clips(clips);

	AnimRef ref = app.clip_named_in_authored("Sneak");
	test::@check(ref.valid() && app.bind_ref(ref), "the authored clip would not bind");

	RigView? opened = app.open_rig(mem);
	if (catch opened)
	{
		test::@check(false, "the rig would not open");
		return;
	}
	RigView view = opened;
	defer view.free(mem);

	// The bound clips are the only source now, so the bound "Sneak" must be among
	// the baked clips even though no file held it.
	gltf_edit::ReskinClip[] baked = app.model_clips(&view);
	defer crig::free_reskin_clips(mem, baked);

	bool found = false;
	foreach (clip : baked) if (clip.name == "Sneak") found = true;
	test::@check(found, "the bound authored clip was not baked into the model (%d baked)", baked.len);
}

<*
 A clip the source file holds but the character does not bind is dropped by Save.

 The bug this guards: `model_clips` used to union the file's own clips into the
 output, so an animation nobody bound — a Fall clip left in a humanoid.glb —
 survived every save, and there was no way to be rid of it. The bound clips are
 the whole list now: the Animations pane is the source of truth, so what it does
 not show is not written.
*>
fn void an_unbound_file_clip_is_not_saved() @test
{
	io::printn("Save writes only the bound clips — a clip the file holds but the character does not bind is dropped");
	crig::AppState app = crig::new_app({});
	defer app.free();

	// A tiny rig whose joints the fixture clips can name.
	uint hips = app.doc.add_dot({ 0, 1, 0 }, "hips");
	uint knee = app.doc.add_dot({ 0, 0.5f, 0 }, "knee");
	app.doc.connect(hips, knee);
	app.doc.root_id = hips;

	// The source file the save would rewrite holds two clips: Walk and Fall. Only
	// Walk is bound below, so Fall is the unbound file clip that must not survive.
	Vec3[2] jpos = { { 0, 1, 0 }, { 0, 0.5f, 0 } };
	int[2] parents = { -1, 0 };
	rig::Skeleton skel = { .joints = jpos[..], .parents = parents[..] };
	String[2] names = { "hips", "knee" };
	AnimTemplate walk = knee_turn("Walk");
	defer walk.free(mem);
	AnimTemplate fall = knee_turn("Fall");
	defer fall.free(mem);
	AnimTemplate[2] both = { walk, fall };
	String path = "build/model-clips-unbound.glb";
	defer (void)file::delete(path);
	defer (void)file::delete("build/model-clips-unbound.rigsmith.json");
	if (catch crig::export_animations_glb(mem, path, &skel, names[..], both[..]))
	{
		test::@check(false, "could not write the two-clip fixture");
		return;
	}
	app.source_path = path.copy(mem);
	app.owns_path = true;

	// Bind only Walk. Authored, matching how the humanoid's Walk is bound, and so
	// it resolves without a scanned library.
	AnimTemplate[] authored = alloc::new_array(mem, AnimTemplate, 1);
	authored[0] = knee_turn("Walk");
	app.replace_authored_clips(authored);
	AnimRef ref = app.clip_named_in_authored("Walk");
	test::@check(ref.valid() && app.bind_ref(ref), "the authored Walk would not bind");

	RigView? opened = app.open_rig(mem);
	if (catch opened)
	{
		test::@check(false, "the rig would not open");
		return;
	}
	RigView view = opened;
	defer view.free(mem);

	gltf_edit::ReskinClip[] baked = app.model_clips(&view);
	defer crig::free_reskin_clips(mem, baked);

	bool has_walk = false;
	bool has_fall = false;
	foreach (clip : baked)
	{
		if (clip.name == "Walk") has_walk = true;
		if (clip.name == "Fall") has_fall = true;
	}
	test::@check(has_walk, "the bound Walk was dropped (%d baked)", baked.len);
	test::@check(!has_fall, "the unbound Fall from the file was re-added on save (%d baked)", baked.len);
	test::@check(baked.len == 1, "save wrote %d clips, expected only the one bound", baked.len);
}

// A tiny clip that turns the knee, for the reindex fixture below.
fn AnimTemplate knee_turn(String name)
{
	AnimKeyframe[] keys = alloc::new_array(mem, AnimKeyframe, 2);
	foreach (usz i, &key : keys)
	{
		AnimKeyDot[] dots = alloc::new_array(mem, AnimKeyDot, 1);
		dots[0] = {
			.joint_name = "knee".copy(mem),
			.axis = { 1, 0, 0 },
			.angle = (float)i * 0.5f,
			.channels = ROTATION,
		};
		*key = { .time = (float)i * 0.5f, .dots = dots };
	}
	return { .name = name.copy(mem), .duration = 1.0f, .keyframes = keys, .owned = true };
}

// Whether the asset browser's index holds an animation of this name.
fn bool browser_has_clip(crig::AppState* app, String name)
{
	foreach (&entry : app.assets.entries)
	{
		if (entry.kind == crig::AssetKind.ANIMATION && entry.name == name) return true;
	}
	return false;
}

<*
 An animation baked into a library model by Save shows in the asset browser
 without a restart — `reindex_saved_model` re-reads the one file.
*>
fn void the_asset_browser_refreshes_after_a_save() @test
{
	io::printn("a new animation in a library model appears in the asset browser after a save");
	const String DIR = "build/reindex-browser";
	(void)path::mkdir((Path)DIR);
	String glb = string::format(mem, "%s/rig.glb", DIR);
	defer glb.free(mem);
	(void)file::delete(glb);
	defer (void)file::delete(glb);

	Vec3[2] jpos = { { 0, 1, 0 }, { 0, 0.5f, 0 } };
	int[2] parents = { -1, 0 };
	rig::Skeleton skel = { .joints = jpos[..], .parents = parents[..] };
	String[2] names = { "hips", "knee" };

	// The file before the new clip: one animation.
	AnimTemplate walk = knee_turn("Walk");
	defer walk.free(mem);
	AnimTemplate[1] one = { walk };
	if (catch crig::export_animations_glb(mem, glb, &skel, names[..], one[..]))
	{
		test::@check(false, "could not write the one-clip fixture");
		return;
	}

	crig::AppState app = crig::new_app({});
	defer app.free();
	app.config.libraries.init(mem);
	app.config.libraries.push({ .name = "Reindex".copy(mem), .path = DIR.copy(mem) });
	app.rescan_assets();
	test::@check(browser_has_clip(&app, "Walk"), "the first scan should show the existing clip");
	test::@check(!browser_has_clip(&app, "Sneak"), "the new clip is not there before the save");

	// Save baked a second clip into the same file — rewrite it, then reindex the way
	// save_session now does.
	AnimTemplate sneak = knee_turn("Sneak");
	defer sneak.free(mem);
	AnimTemplate[2] both = { walk, sneak };
	if (catch crig::export_animations_glb(mem, glb, &skel, names[..], both[..]))
	{
		test::@check(false, "could not rewrite the fixture with two clips");
		return;
	}
	app.reindex_saved_model(glb);

	test::@check(browser_has_clip(&app, "Sneak"), "the new clip did not appear in the browser after reindex");
	test::@check(browser_has_clip(&app, "Walk"), "the existing clip was lost in the reindex");
}

fn void invalid_app_reload_preserves_the_live_project() @test
{
	io::printn("a failed project reload leaves the live document and authored pack intact");
	crig::AppState app = crig::new_app({});
	defer app.free();
	app.source_path = APP_MESH.copy(mem);
	app.owns_path = true;
	uint root = app.doc.add_dot({}, "root");
	app.doc.root_id = root;
	AnimTemplate[] clips = alloc::new_array(mem, AnimTemplate, 1);
	clips[0] = authored();
	app.replace_authored_clips(clips);
	app.authored_dirty = true;
	AnimRef before = app.clip_named_in_authored("Attack / authored");
	(void)file::delete(APP_SESSION);
	defer (void)file::delete(APP_SESSION);
	if (catch file::save(APP_SESSION, "{ not a project"))
	{
		test::@check(false, "could not build the invalid sidecar fixture");
		return;
	}

	app.load_session();
	AnimRef after = app.clip_named_in_authored("Attack / authored");
	test::@check(before.valid() && after.valid(), "failed load dropped the live authored pack");
	test::@check(app.authored_dirty, "failed load marked unsaved authored motion clean");
	test::@check(app.clip(after).keyframes.len == 2 && app.clip(after).ground.solves(),
		"failed load partially replaced the live authored clip");
}

fn void first_save_copies_then_reopens_authored_motion() @test
{
	io::printn("the first normal save copies the source and reopens authored motion");
	String source = string::format(mem, "%s/humanoid.glb", library::ready());
	defer source.free(mem);
	String target = crig::copy_path(mem, source);
	defer target.free(mem);
	String sidecar = crig::session_path(mem, target);
	defer sidecar.free(mem);
	(void)file::delete(target);
	(void)file::delete(sidecar);
	defer (void)file::delete(target);
	defer (void)file::delete(sidecar);

	crig::AppState app = crig::new_app({});
	defer app.free();
	app.source_path = source.copy(mem);
	app.owns_path = true;
	uint root = app.doc.add_dot({}, "root");
	app.doc.root_id = root;
	AnimTemplate[] clips = alloc::new_array(mem, AnimTemplate, 1);
	clips[0] = authored();
	app.replace_authored_clips(clips);
	// Bound, as every clip made in the editor is: the sidecar keeps only those.
	test::@check(app.bind_ref(app.clip_named_in_authored("Attack / authored")), "the authored clip would not bind");
	app.authored_dirty = true;
	app.save_session();
	test::@check(file::is_file(target) && file::is_file(sidecar),
		"first save did not produce the model copy and its project sidecar");
	test::@check(app.source_path == target && app.saves_in_place,
		"successful first save did not retarget the live project to its copy");
	test::@check(!app.authored_dirty, "successful first save left authored motion dirty");

	crig::AppState reopened = crig::new_app({});
	defer reopened.free();
	reopened.source_path = target.copy(mem);
	reopened.owns_path = true;
	reopened.load_session();
	test::@check(reopened.clip_named_in_authored("Attack / authored").valid(),
		"the copied project did not reopen its authored clip");
}

fn void export_sidecar_does_not_mark_the_project_clean() @test
{
	io::printn("writing an export sidecar does not clear project dirtiness");
	const String EXPORTED = "build/authored-export.glb";
	String sidecar = crig::session_path(mem, EXPORTED);
	defer sidecar.free(mem);
	(void)file::delete(sidecar);
	defer (void)file::delete(sidecar);

	crig::AppState app = crig::new_app({});
	defer app.free();
	uint root = app.doc.add_dot({}, "root");
	app.doc.root_id = root;
	AnimTemplate[] clips = alloc::new_array(mem, AnimTemplate, 1);
	clips[0] = authored();
	app.replace_authored_clips(clips);
	app.authored_dirty = true;
	test::@check(app.save_rig_beside(EXPORTED), "the export sidecar did not write");
	test::@check(file::is_file(sidecar), "the export sidecar is missing");
	test::@check(app.authored_dirty, "export incorrectly marked the project clean");
}

fn AnimTemplate aimed()
{
	AnimTemplate clip = authored();
	clip.aim_targets = alloc::new_array(mem, AnimAimTarget, 2);
	clip.aim_targets[0] = crig::aim_target_defaults(mem, "Target 1", { 0.25f, 0.125f, 0.5f }, 0.1f);
	alloc::free(mem, clip.aim_targets[0].keys);
	clip.aim_targets[0].keys = alloc::new_array(mem, AnimAimKey, 2);
	clip.aim_targets[0].keys[0] = { .time = 0.1f, .at = { 0.25f, 0.125f, 0.5f }, .interpolation = HOLD };
	clip.aim_targets[0].keys[1] = { .time = 1.25f, .at = { -0.5f, 0.3f, 0.7f }, .interpolation = LINEAR };
	clip.aim_targets[0].mute = true;
	clip.aim_targets[1] = crig::aim_target_defaults(mem, "Gaze", { 0.0f, 0.5f, 0.5f }, 0.0f);
	clip.aims = alloc::new_array(mem, AnimAim, 2);
	clip.aims[0] = crig::aim_defaults(mem, "head", "Target 1", { 0, 0, 1 });
	clip.aims[0].spread = 2;
	clip.aims[0].weights = { 0.6f, 0.4f, 0.0f, 0.0f };
	clip.aims[0].influence = 0.75f;
	clip.aims[0].mute = true;
	clip.aims[1] = crig::aim_defaults(mem, "hand_L", "Target 1", { 1, 0, 0 });
	return clip;
}

fn void look_at_targets_round_trip_in_version_22() @test
{
	io::printn("look-at targets and locks round-trip through a v22 session");
	RigDocument doc = {};
	defer doc.free();
	AnimTemplate clip = aimed();
	defer clip.free(mem);
	AnimTemplate[1] source = { clip };
	String text = crig::session_text(mem, &doc, "hero.glb", source[..]);
	defer text.free(mem);
	test::@check(text.contains(`"version": 24`) || text.contains(`"version":24`), "the session is not version 24");

	AnimTemplate[]? parsed = crig::parse_session_clips(mem, text);
	if (catch parsed) { test::@check(false, "an aimed clip did not parse"); return; }
	AnimTemplate[] clips = parsed;
	defer crig::free_animations(mem, clips);
	test::@check(clips.len == 1 && clips[0].aims.len == 2 && clips[0].aim_targets.len == 2, "a lock or target was lost");
	if (clips.len != 1 || clips[0].aims.len != 2 || clips[0].aim_targets.len != 2) return;
	AnimAim a = clip.aims[0];
	AnimAim b = clips[0].aims[0];
	test::@check(b.joint == "head" && b.target == "Target 1" && b.forward == a.forward && b.spread == 2
		&& b.weights == a.weights && b.influence == 0.75f && b.mute && clips[0].aims[1].joint == "hand_L",
		"a lock field changed");
	AnimAimTarget ta = clip.aim_targets[0];
	AnimAimTarget tb = clips[0].aim_targets[0];
	test::@check(tb.name == "Target 1" && tb.mute && tb.keys.len == 2 && tb.keys[0].time == ta.keys[0].time
		&& tb.keys[0].at == ta.keys[0].at && tb.keys[0].interpolation == HOLD && tb.keys[1].at == ta.keys[1].at
		&& tb.keys[1].interpolation == LINEAR, "a target key changed");
	test::@check(clips[0].aim_targets[1].name == "Gaze" && !clips[0].aim_targets[1].mute, "the second target changed");
}

fn void version_21_aims_with_keys_become_targets_and_locks() @test
{
	io::printn("a v21 aim that carries keys reads as a target plus a lock");
	const String OLD = `{"authored_clips":[{"name":"old","duration":1,"loop":false,"blend":"linear","keys":[{"time":0,"dots":[]}],"aims":[`
		`{"joint":"head","forward":[0,0,1],"spread":2,"weights":[0.6,0.4,0,0],"influence":0.5,"mute":true,"keys":[{"time":0.25,"at":[1,2,3],"interp":"hold"},{"time":0.5,"at":[4,5,6]}]},`
		`{"joint":"hand_L","forward":[1,0,0],"spread":1,"weights":[1,0,0,0],"influence":1,"mute":false,"keys":[{"time":0,"at":[0,0,1]}]}]}]}`;
	AnimTemplate[]? parsed = crig::parse_session_clips(mem, OLD);
	if (catch parsed) { test::@check(false, "a version 21 clip did not parse"); return; }
	AnimTemplate[] clips = parsed;
	defer crig::free_animations(mem, clips);
	test::@check(clips.len == 1 && clips[0].aims.len == 2 && clips[0].aim_targets.len == 2, "the migration made %d locks, %d targets",
		clips[0].aims.len, clips[0].aim_targets.len);
	if (clips[0].aims.len != 2 || clips[0].aim_targets.len != 2) return;
	test::@check(clips[0].aim_targets[0].name == "Target 1" && clips[0].aim_targets[1].name == "Target 2", "targets are not named in order");
	test::@check(clips[0].aims[0].joint == "head" && clips[0].aims[0].target == "Target 1" && clips[0].aims[0].spread == 2
		&& clips[0].aims[0].influence == 0.5f && clips[0].aims[0].mute, "the lock settings were lost");
	test::@check(clips[0].aims[1].target == "Target 2", "the second lock points at the wrong target");
	AnimAimTarget first = clips[0].aim_targets[0];
	test::@check(first.keys.len == 2 && first.keys[0].time == 0.25f && first.keys[0].at == (Vec3){ 1, 2, 3 }
		&& first.keys[0].interpolation == HOLD && first.keys[1].at == (Vec3){ 4, 5, 6 }, "the keys moved to the target wrongly");
}

fn void duplicate_target_names_and_orphan_locks() @test
{
	io::printn("duplicate target names are refused, a lock on a missing target is dropped");
	const String HEAD = `{"authored_clips":[{"name":"c","duration":1,"loop":false,"blend":"linear","keys":[{"time":0,"dots":[]}],`;
	const String LOCK = `{"joint":"head","target":"Target 1","forward":[0,0,1],"spread":3,"weights":[0.5,0.3,0.2,0],"influence":1,"mute":false}`;
	const String ORPHAN = `{"joint":"neck","target":"Nope","forward":[0,0,1],"spread":3,"weights":[0.5,0.3,0.2,0],"influence":1,"mute":false}`;
	const String TARGET = `{"name":"Target 1","mute":false,"keys":[{"time":0,"at":[0,0,0]}]}`;

	String twice = string::format(mem, `%s"aim_targets":[%s,%s],"aims":[%s]}]}`, HEAD, TARGET, TARGET, LOCK);
	defer twice.free(mem);
	AnimTemplate[]? refused = crig::parse_session_clips(mem, twice);
	bool bad = false;
	if (catch refused) bad = true;
	test::@check(bad, "two targets of one name were accepted");
	if (try refused) crig::free_animations(mem, refused);

	String dropped = string::format(mem, `%s"aim_targets":[%s],"aims":[%s,%s]}]}`, HEAD, TARGET, LOCK, ORPHAN);
	defer dropped.free(mem);
	AnimTemplate[]? parsed = crig::parse_session_clips(mem, dropped);
	if (catch parsed) { test::@check(false, "a clip with an orphan lock did not parse"); return; }
	AnimTemplate[] clips = parsed;
	defer crig::free_animations(mem, clips);
	test::@check(clips[0].aims.len == 1 && clips[0].aims[0].joint == "head" && clips[0].aim_targets.len == 1,
		"the orphan lock was kept (%d locks)", clips[0].aims.len);
}

fn void version_20_clips_read_with_no_aims() @test
{
	io::printn("a clip with no aims key reads as a clip with none");
	const String OLD = `{"authored_clips":[{"name":"old","duration":1,"loop":false,"blend":"linear","keys":[{"time":0,"dots":[]}]}]}`;
	AnimTemplate[]? parsed = crig::parse_session_clips(mem, OLD);
	if (catch parsed) { test::@check(false, "a version 20 clip did not parse"); return; }
	AnimTemplate[] clips = parsed;
	defer crig::free_animations(mem, clips);
	test::@check(clips.len == 1 && clips[0].aims.len == 0, "an old clip grew aims");
}

fn void malformed_aims_are_refused() @test
{
	io::printn("look-at targets with a bad shape are refused");
	const String HEAD = `{"authored_clips":[{"name":"c","duration":1,"loop":false,"blend":"linear","keys":[{"time":0,"dots":[]}],"aims":[`;
	const String TAIL = `]}]}`;
	String[8] bad = {
		// no keys
		`{"joint":"head","forward":[0,0,1],"spread":3,"weights":[0.5,0.3,0.2,0],"influence":1,"mute":false,"keys":[]}`,
		// spread out of range
		`{"joint":"head","forward":[0,0,1],"spread":5,"weights":[0.5,0.3,0.2,0],"influence":1,"mute":false,"keys":[{"time":0,"at":[0,0,0]}]}`,
		`{"joint":"head","forward":[0,0,1],"spread":0,"weights":[0.5,0.3,0.2,0],"influence":1,"mute":false,"keys":[{"time":0,"at":[0,0,0]}]}`,
		// times not increasing
		`{"joint":"head","forward":[0,0,1],"spread":3,"weights":[0.5,0.3,0.2,0],"influence":1,"mute":false,"keys":[{"time":0.5,"at":[0,0,0]},{"time":0.5,"at":[0,0,0]}]}`,
		// negative time
		`{"joint":"head","forward":[0,0,1],"spread":3,"weights":[0.5,0.3,0.2,0],"influence":1,"mute":false,"keys":[{"time":-1,"at":[0,0,0]}]}`,
		// a point with two numbers
		`{"joint":"head","forward":[0,0,1],"spread":3,"weights":[0.5,0.3,0.2,0],"influence":1,"mute":false,"keys":[{"time":0,"at":[0,0]}]}`,
		// influence out of range
		`{"joint":"head","forward":[0,0,1],"spread":3,"weights":[0.5,0.3,0.2,0],"influence":2,"mute":false,"keys":[{"time":0,"at":[0,0,0]}]}`,
		// not a list
		`7`,
	};
	foreach (i, entry : bad)
	{
		String text = string::format(mem, "%s%s%s", HEAD, entry, TAIL);
		defer text.free(mem);
		AnimTemplate[]? parsed = crig::parse_session_clips(mem, text);
		bool refused = false;
		if (catch parsed) refused = true;
		test::@check(refused, "malformed aim %d was accepted", i);
		if (try parsed) crig::free_animations(mem, parsed);
	}
}
