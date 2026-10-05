<*
 The everyday animation workflow, end to end: make a clip, edit it the way a
 person does, save and reopen it, export it, and replay the file with a reader
 that knows nothing about crig.

     `c3c test --trust=full --test-filter crig_tests::everyday_workflow`

 Milestone 1's acceptance. The editing steps are the ordinary ones, each
 through the editor's own door rather than the rewriters underneath: pose and
 key, key the selected joint only, key the changed channels only, copy a pose
 and paste it later, mirror a pose onto the other leg, hold a segment, move a
 key, trim the clip. That leaves a genuinely multi-track clip — a leg keyed
 where the hips are not, a hold beside a curve, a translation-only key — which
 is what the sheet, the sidecar and the writer all have to agree about.

 The comparison is the one that matters: the exported file, sampled by
 `gltf_replay`'s independent player between and on the keys, against the pose
 the editor itself evaluates and shows. Save and reopen sit between the edits
 and the export, so the file is written from what came back off disk.
*>
module crig_tests::everyday_workflow;

import crig;
import rig;
import gltf;
import crig_tests::shared_app;
import crig_tests::gltf_replay;
import std::core::test;
import std::io;
import std::io::file;
import std::math;
import std::math::matrix;
import std::math::quaternion;

const String EXPORT = "build/everyday-walk.glb";
const String LEFT = "thigh_L";
const String RIGHT = "thigh_R";
const String HIPS = "hips";
const usz SAMPLES = 25;

fn uint dot_named(crig::AppState* app, String name)
{
	foreach (dot : app.doc.dots.array_view()) if (dot.name == name) return dot.id;
	return 0;
}

fn Quaternionf turn_z(float angle) => quaternion::from_axis_angle{float}(((Vec3){ 0, 0, 1 }), angle);

fn bool keyed_at(crig::AppState* app, float time, String joint, AnimChannels channel)
{
	foreach (frame : app.clip(app.editing).keyframes)
	{
		if (math::abs(frame.time - time) < 1.0e-4f) return frame.has_channel(joint, channel);
	}
	return false;
}

fn void a_clip_made_edited_saved_and_exported_replays_as_shown() @test
{
	crig::AppState app = shared_app::open();
	defer app.free();
	if (!app.apply_plan_named("biped")) { test::@check(false, "the biped would not fit the cube"); return; }
	uint left = dot_named(&app, LEFT);
	uint right = dot_named(&app, RIGHT);
	uint hips = dot_named(&app, HIPS);
	if (left == 0 || right == 0 || hips == 0) { test::@check(false, "the fitted plan lacks a leg or the hips"); return; }
	io::printn("a clip made, edited, saved, reopened and exported replays where the editor showed it");

	float height;
	{
		RigView view = app.open_rig(mem)!!;
		defer view.free(mem);
		height = view.skeleton.height();
	}

	// --- create, and pose the first frame -----------------------------------
	AnimRef clip = app.new_clip("everyday", 1.0f, from_rest: true);
	test::@check(clip.valid(), "a new clip could not be started");
	app.editing = clip;
	test::@check(app.pose_from_clip(clip, 0.0f) && app.set_working_pose(left, turn_z(0.4f), {}), "the first pose would not open");
	app.pose_edit_pending = true;
	test::@check(app.key_pose_edit(), "the first pose would not key");

	// --- Save selected: the leg alone at 0.5 s, the hips left unkeyed there ---
	app.select(left);
	app.edit_time = 0.5f;
	test::@check(app.pose_from_clip(app.editing, 0.5f), "the pose at 0.5 s would not open");
	test::@check(app.set_working_pose(left, turn_z(-0.3f), {}), "the leg would not turn at 0.5 s");
	test::@check(app.set_working_pose(hips, quaternion::IDENTITY, { 0, 0.05f * height, 0 }), "the hips would not lift");
	app.pose_edit_pending = true;
	test::@check(app.key_pose_edit(SELECTED), "Save selected refused the leg");
	test::@check(app.pose_edit_active && app.pose_edit_pending, "Save selected discarded the unkeyed hips lift");
	test::@check(keyed_at(&app, 0.5f, LEFT, ROTATION) && !keyed_at(&app, 0.5f, HIPS, TRANSLATION),
		"Save selected keyed more than the selected leg");
	(void)app.discard_pose_edit();

	// --- Changed channels only: a translation-only hips key at 0.75 s --------
	app.edit_time = 0.75f;
	test::@check(app.pose_from_clip(app.editing, 0.75f), "the pose at 0.75 s would not open");
	test::@check(app.set_working_pose(hips, quaternion::IDENTITY, { 0, 0.05f * height, 0 }), "the hips would not lift");
	app.pose_edit_pending = true;
	test::@check(app.key_pose_edit(CHANGED), "Changed channels refused the hips");
	test::@check(keyed_at(&app, 0.75f, HIPS, TRANSLATION) && !keyed_at(&app, 0.75f, HIPS, ROTATION)
		&& !keyed_at(&app, 0.75f, LEFT, ROTATION), "Changed channels keyed more than the lifted hips");

	// --- Copy the opening leg pose and paste it at the end -------------------
	app.stop_animation();
	app.select(left);
	app.edit_time = 0.0f;
	test::@check(app.copy_pose() == 1, "the leg's pose would not copy");
	app.edit_time = 1.0f;
	test::@check(app.paste_pose(), "the leg's pose would not paste at the end");
	test::@check(keyed_at(&app, 1.0f, LEFT, ROTATION) && !keyed_at(&app, 1.0f, HIPS, ROTATION),
		"the paste keyed more than the copied leg");

	// --- Mirror the leg at 0.5 s onto the other one --------------------------
	app.stop_animation();
	app.edit_time = 0.5f;
	test::@check(app.mirror_pose(), "the leg would not mirror");
	test::@check(keyed_at(&app, 0.5f, RIGHT, ROTATION), "the mirror did not key the right leg at 0.5 s");

	// --- Hold the leg from 0.5 s, and move the hips key later ----------------
	app.stop_animation();
	app.select_animation_channel_key(app.editing, 0.5f, LEFT, ROTATION);
	test::@check(app.set_selected_animation_interpolation(app.editing, HOLD), "the segment would not hold");
	app.clear_animation_key_selection();
	app.select_animation_key(app.editing, 0.75f);
	test::@check(app.move_selected_animation_keys(app.editing, 0.1f), "the hips key would not move");
	app.clear_animation_key_selection();
	test::@check(keyed_at(&app, 0.85f, HIPS, TRANSLATION) && !keyed_at(&app, 0.75f, HIPS, TRANSLATION),
		"the hips key did not land at 0.85 s");

	// --- Trim: keep 0.1 s to 0.95 s ------------------------------------------
	{
		AnimTemplate* before = app.clip(app.editing);
		AnimTemplate part = crig::clip_cropped(mem, *before, 0.1f, 0.95f);
		test::@check(math::abs(part.duration - 0.85f) < 1.0e-6f, "the crop was refused");
		app.editing = app.land_clip(app.editing, part);
		test::@check(app.editing.valid(), "the cropped clip would not land");
	}
	AnimTemplate* edited = app.clip(app.editing);
	test::@check(edited.keyframes.len == 4, "%d keys after the edits; wanted the two edges and the two inside", edited.keyframes.len);
	test::@check(edited.uses_interpolation(HOLD), "the hold did not survive the crop");
	usz tracks;
	foreach (frame : edited.keyframes) foreach (dot : frame.dots) if (dot.channels != BOTH) tracks++;
	test::@check(tracks > 0, "no sparse channel survived; the clip is not multi-track");

	// --- What the editor shows, sampled between and on the keys ---------------
	RigView view = app.open_rig(mem)!!;
	defer view.free(mem);
	test::@check(app.rebind_skin(&view), "the preview skin would not bind");
	usz joints = view.len();
	// Evenly across the clip, and on every key exactly.
	usz samples = SAMPLES + edited.keyframes.len;
	float[] times = alloc::new_array(mem, float, (sz)samples);
	defer alloc::free(mem, times);
	for (usz i = 0; i < SAMPLES; i++) times[i] = edited.duration * (float)i / (float)(SAMPLES - 1);
	foreach (usz k, frame : edited.keyframes) times[SAMPLES + k] = frame.time;
	rig::Pose[] shown = alloc::new_array(mem, rig::Pose, (sz)samples);
	defer
	{
		foreach (&pose : shown) pose.free(mem);
		alloc::free(mem, shown);
	}
	for (usz i = 0; i < samples; i++)
	{
		shown[i] = app.evaluated_clip_pose(mem, &view, *edited, app.editing, times[i]);
	}

	// --- Save, reopen ---------------------------------------------------------
	String sidecar = crig::session_path(mem, EXPORT);
	defer sidecar.free(mem);
	defer (void)file::delete(sidecar);
	defer (void)file::delete(EXPORT);
	test::@check(app.save_rig_beside(EXPORT), "the project would not save");
	AnimTemplate[]? read = crig::read_session_clips(mem, sidecar);
	if (catch read) { test::@check(false, "the saved project would not reopen"); return; }
	AnimTemplate[] reopened = read;
	defer crig::free_animations(mem, reopened);
	sz found = -1;
	foreach (usz i, clip_back : reopened) if (clip_back.name == edited.name) found = (sz)i;
	test::@check(found >= 0, "the edited clip did not come back from the sidecar");
	if (found < 0) return;
	AnimTemplate back = reopened[(usz)found];
	test::@check(back.keyframes.len == edited.keyframes.len && math::abs(back.duration - edited.duration) < 1.0e-6f,
		"the reopened clip has %d keys over %.3f s; %d over %.3f s were saved",
		back.keyframes.len, back.duration, edited.keyframes.len, edited.duration);
	test::@check(back.uses_interpolation(HOLD), "the hold did not survive save and reopen");

	// --- Export what came back, and replay it independently ------------------
	float[] dense = app.bind_dense(mem, &view);
	defer alloc::free(mem, dense);
	AnimTemplate[1] exporting = { back };
	if (catch fault error = crig::export_rigged_animated_glb(mem, EXPORT, app.geometry, &view.skeleton,
		view.names, dense, exporting[..], "body", crig::SKIN_INFLUENCES))
	{
		test::@check(false, "the writer refused the edited clip: %s", error);
		return;
	}
	gltf::GltfStream? opened = gltf::open(EXPORT, mem);
	if (catch opened) { test::@check(false, "the exported file would not open"); return; }
	gltf::GltfStream stream = opened;
	defer stream.close();
	if (catch stream.load_all_buffers()) { test::@check(false, "the exported buffers would not load"); return; }

	gltf::Skin skin = stream.gltf.skins[0];
	usz[] to_rig = alloc::new_array(mem, usz, (sz)skin.joints.len());
	defer alloc::free(mem, to_rig);
	for (usz k = 0; k < (usz)skin.joints.len(); k++)
	{
		String name = stream.gltf.nodes.get_ref((sz)skin.joints[(sz)k]).name;
		usz at = joints;
		foreach (usz j, joint_name : view.names) if (joint_name == name) at = j;
		if (at == joints) { test::@check(false, "the file names a joint the rig does not: %s", name); return; }
		to_rig[k] = at;
	}

	Vec3[] here = alloc::new_array(mem, Vec3, (sz)app.geometry.positions.len);
	defer alloc::free(mem, here);
	float worst_joint;
	float worst_vertex;
	for (usz i = 0; i < samples; i++)
	{
		Matrix4f[] palette = rig::joint_palette(mem, &view.skeleton, shown[i])!!;
		defer alloc::free(mem, palette);
		gltf_replay::skin_through(here, app.geometry.positions, app.skin, palette);

		gltf_replay::ReplayFrame? played = gltf_replay::replay_frame(mem, &stream, 0, times[i]);
		if (catch fault error = played)
		{
			test::@check(false, "the file would not replay at %.3f s: %s", times[i], error);
			return;
		}
		gltf_replay::ReplayFrame frame = played;
		defer frame.free(mem);

		foreach (usz k, at : frame.joints)
		{
			usz j = to_rig[k];
			float[<4>] moved = palette[j].apply({ view.skeleton.joints[j].x, view.skeleton.joints[j].y, view.skeleton.joints[j].z, 1.0f });
			worst_joint = math::max(worst_joint, (at - (Vec3){ moved.x, moved.y, moved.z }).length());
		}
		foreach (usz v, at : frame.vertices)
		{
			worst_vertex = math::max(worst_vertex, (at - here[v]).length());
		}
	}
	io::printfn("  replayed as glTF over %d samples: joints %.7f out, vertices %.7f out", samples, worst_joint, worst_vertex);
	float tolerance = gltf_replay::EXACT * height;
	test::@check(worst_joint < tolerance, "an outside reader puts the joints where the editor showed them (%.6f off)", worst_joint);
	test::@check(worst_vertex < tolerance, "and deforms the mesh where the editor showed it (%.6f off)", worst_vertex);
}
