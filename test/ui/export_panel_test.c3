module crig_tests::ui;
import crig;
import libc;
import cui;
import cui::widgets;
import c3w;
import rig;
import gltf;
import collision;
import crig_tests::library;
import crig_tests::shared_app;
import std::core::test;
import std::io;
import std::math;

// ---------------------------------------------------------------------------
// The export panel over the whole library, and the gear on a cell

<*
 A second library holding one clip file that declares no body plan.

 The shape every download takes, and the one the export panel could not offer
 before: `scan_libraries` reads whole only the files that declare a plan, so
 this one is indexed and left unloaded. Written out of a pack that is already in
 the library, so the clip inside it is one the fitted biped rig can address.

 @return `The file's path, or "" when it could not be written.`
*>
fn String loose_clip_library(Fixture* fixture)
{
	const String FOLDER = "build/ui-test-loose";
	if (catch io::path::mkdir((io::path::Path)FOLDER))
	{
		// Already there, which is the ordinary case after the first check.
	}

	int planned = fixture.app.plan_pack("biped");
	if (planned < 0) return "";
	AnimPack* source = fixture.app.pack((usz)planned);
	if (!source || source.clips.len == 0) return "";

	String path = "build/ui-test-loose/loose_clip.glb";
	if (catch crig::export_animations_glb(mem, path, &source.rest, source.joint_names, source.clips[:1]))
	{
		return "";
	}

	fixture.app.config.add_library(FOLDER, "Loose");
	fixture.app.scan_libraries();
	return path;
}

<*
 Binding a clip reads the file it lives in.

 The job the export panel's tick used to do — "ticking is what loads" — moved to
 the browser's +, which is where it always belonged: the choice of what a
 character has is made in the browser, so the read that backs it happens there.

 What makes it worth a check: a file that declares no body plan is never loaded
 at startup, so its clips are offered from the index alone. Binding one has to
 open the file, because the name a binding stores is the *pack's* name for the
 clip and only the pack can say what that is.
*>
fn void binding_reads_a_file_nobody_has_read() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("binding a clip reads the file it lives in");
	fixture.reset();

	if (!fixture.app.apply_plan_named("biped"))
	{
		test::@check(false, "SKIPPED — the biped plan could not be fitted to the cube");
		return;
	}

	String loose = loose_clip_library(fixture);
	if (loose.len == 0)
	{
		test::@check(false, "SKIPPED — the loose clip file could not be written");
		return;
	}
	test::@check(fixture.app.loaded_pack_for(loose) < 0,
		"the loose file was loaded at startup, so this check proves nothing");

	fixture.ui.flush();

	// The browser's cells only exist while the Assets pane is the one showing —
	// a pane builds the view its tab selects and nothing else.
	Element*? strip = fixture.ui.find(AreaTabStrip);
	if (catch strip)
	{
		test::@check(false, "SKIPPED — no tab strip in the tree");
		return;
	}
	fixture.click(tab_center(fixture, strip, 1));
	fixture.ui.flush();

	// The row the browser is offering for that file, straight out of the index.
	usz row = fixture.app.visible_assets.len;
	for (usz i = 0; i < fixture.app.visible_assets.len; i++)
	{
		AssetEntry* entry = fixture.app.visible_asset(i);
		if (entry && entry.kind == AssetKind.ANIMATION && entry.file == loose)
		{
			row = i;
			break;
		}
	}
	if (row >= fixture.app.visible_assets.len)
	{
		test::@check(false, "the browser does not offer the unloaded clip at all");
		return;
	}

	if (!fixture.bind_click(row))
	{
		test::@check(false, "SKIPPED — the offered row has no cell in the grid");
		return;
	}
	fixture.ui.flush();

	test::@check(fixture.app.loaded_pack_for(loose) >= 0, "binding the clip did not read the file");
	test::@check(fixture.doc().animations.len() == 1, "and it did not bind");

	// And it resolves, which is the claim the read exists to make good: the name
	// stored came from the pack, so looking it up again finds the same clip.
	test::@check(fixture.app.resolve_bound(0).valid(), "the binding does not resolve back to a clip");

	fixture.doc().free_animations();
	if (try Element* back = fixture.ui.find(AreaTabStrip)) fixture.click(tab_center(fixture, back, 0));
	fixture.viewport = fixture.ui.find(Viewport)!!;
	fixture.ui.flush();
}

<*
 Export rig unticked writes the clips and no model.

 The setting is the one thing the merged panel added that the two commands it
 replaced could not express. What makes it worth asserting rather than reading:
 the file still has to carry a skeleton — a clip addresses joints by name, and a
 file with no joints in it is one nothing can be played against — so "no rig"
 and "no bones" are different claims and only the first is meant.
*>
fn void export_unbound_template_writes_rig_without_animations() @test
{
	Fixture fixture;
	if (catch fault error = fixture.open())
	{
		test::@check(false, "could not build the interface: %s", error);
		return;
	}
	defer fixture.close();
	fixture.reset();
	test::@check(fixture.app.apply_plan_named("biped"), "could not fit the test rig");
	fixture.doc().free_animations();
	// The humanoid plan brings a table for every joint it places; this is about
	// the writer carrying one knee, so the rest are taken off first.
	fixture.doc().rotation_limits.clear();
	crig::Dot* knee = fixture.app.dot_named(PLAN_KNEE_L);
	crig::Dot* ankle = fixture.app.dot_named(PLAN_ANKLE_L);
	if (!knee || !ankle)
	{
		test::@check(false, "the fitted test rig has no knee/ankle chain");
		return;
	}
	crig::JointRotationLimits limits = crig::unconstrained_rotation(knee.id);
	limits.constrained = true;
	limits.primary_child = ankle.id;
	limits.axes[0] = { .allowed = true, .minimum = -0.25f, .maximum = 2.25f };
	limits.axes[1] = { .allowed = false, .locked = 0.0f };
	limits.axes[2] = { .allowed = false, .locked = 0.0f };
	test::@check(fixture.doc().set_rotation_limits(knee.id, limits),
		"could not constrain the exported test knee");
	fixture.app.point_at("build/ui_test_template.glb");
	String written = "build/ui_test_template_rigged.glb";
	defer (void)io::file::delete(written);
	defer (void)io::file::delete("build/ui_test_template_rigged.rigsmith.json");
	fixture.app.export_with_rig = false;
	crig::open_export_dialog(fixture.ui);
	fixture.ui.flush();
	test::@check(fixture.app.export_with_rig, "an unbound template must default to rig-only export");
	test::@check(fixture.confirm_export(), "the export button must be reachable without animations");
	crig::AnimPack? loaded = crig::read_pack(mem, written);
	if (catch fault error = loaded)
	{
		test::@check(false, "could not reopen the exported template: %s", error);
		return;
	}
	crig::AnimPack pack = loaded;
	defer pack.free(mem);
	test::@check(pack.clips.len == 0, "template export must not attach animations");
	test::@check(pack.mesh.positions.len == 8, "template export must retain the mesh");
	test::@check(pack.rest.joints.len == fixture.doc().dots.len(), "template export must retain every joint");
	test::@check(io::file::is_file("build/ui_test_template_rigged.rigsmith.json"), "editable rig sidecar must be saved");

	// P3 will recover this into `pack.constraints`. P2 is checked against the
	// file itself: a rig-only export must take the KHR-capable writer even though
	// it has no animation to force that path.
	gltf::GltfStream? opened = gltf::open(written, mem);
	if (catch opened)
	{
		test::@check(false, "could not inspect the exported KHR constraint");
		return;
	}
	gltf::GltfStream stream = opened;
	defer stream.close();
	test::@check(stream.gltf.physics_joints.len() == 1,
		"constraint-only export wrote %d KHR joints, not one knee",
		stream.gltf.physics_joints.len());
	if (stream.gltf.physics_joints.len() == 1)
	{
		test::@check(stream.gltf.physics_joints[0].angular_limits.len() == 3,
			"the exported knee does not retain independent X/Y/Z angular rows");
	}
}

fn void export_rig_off_writes_the_clips_alone() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("Export rig unticked writes an animation pack");
	fixture.reset();

	if (!fixture.app.apply_plan_named("biped"))
	{
		test::@check(false, "SKIPPED — the biped plan could not be fitted to the cube");
		return;
	}

	fixture.app.point_at("build/ui_test_cliponly.glb");
	String written = "build/ui_test_cliponly_rigged.glb";
	(void)io::file::delete(written);

	crig::open_export_dialog(fixture.ui);
	fixture.ui.flush();

	Element*? box = fixture.ui.find(Checkbox);
	if (catch box)
	{
		test::@check(false, "SKIPPED — the panel has no Export rig tick");
		return;
	}
	test::@check(fixture.app.export_with_rig, "the panel opens with the rig on");
	fixture.click(box.absolute + box.size * 0.5f);
	test::@check(!fixture.app.export_with_rig, "clicking the tick did not turn the rig off");

	// Bound directly rather than through the browser's +: what this check is about
	// is the rig tick, and `binding_a_clip_puts_it_on_the_character` is what covers
	// the target that puts a clip on the character.
	AnimRef usable = crig::NO_ANIM;
	foreach (usz p, &pack : fixture.app.packs)
	{
		foreach (usz c, clip : pack.clips)
		{
			AnimRef ref = { (int)p, (int)c };
			if (fixture.app.clip_applies(ref) && !usable.valid()) usable = ref;
		}
	}
	if (!usable.valid())
	{
		test::@check(false, "SKIPPED — no clip in the library can address the fitted rig");
		return;
	}
	test::@check(fixture.app.bind_ref(usable), "the clip did not bind");

	if (!fixture.confirm_export())
	{
		test::@check(false, "SKIPPED — the panel has no Export button");
		return;
	}

	crig::AnimPack? read_back = crig::read_pack(mem, written);
	if (catch read_back)
	{
		test::@check(false, "what it wrote could not be read back as a pack");
		(void)io::file::delete(written);
		return;
	}
	crig::AnimPack pack = read_back;
	defer pack.free(mem);

	test::@check(pack.clips.len == 1, "the file carries %d clips rather than the one bound", pack.clips.len);
	test::@check(pack.mesh.positions.len == 0, "the model went in anyway");
	test::@check(pack.rest.joints.len > 0, "the skeleton was left out, so nothing can play the clips");

	(void)io::file::delete(written);
	fixture.doc().free_animations();
	fixture.app.export_with_rig = true;
}

<*
 The gear on a cell opens that cell's settings, and does not activate it.

 The second half is the point of the gear being a target of its own rather than
 a second meaning for the cell: a click on a skin cell replaces every dot in the
 document, and a click on the gear must not. Cancelled rather than saved —
 saving writes to the fixture library, which every other check in this file
 reads.
*>
fn void the_gear_opens_one_assets_settings() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("the gear on a cell opens its settings");
	fixture.reset();

	Element*? strip = fixture.ui.find(AreaTabStrip);
	if (catch strip)
	{
		test::@check(false, "SKIPPED — no tab strip in the tree");
		return;
	}
	fixture.click(tab_center(fixture, strip, 1));

	Element* cell = asset_cell(fixture, crig::AssetKind.SKIN);
	if (!cell)
	{
		test::@check(false, "SKIPPED — no skin in the browser");
		return;
	}
	usz row = cell.widget_as(crig::AssetCell).row;
	crig::AssetEntry* entry = fixture.app.visible_asset(row);
	if (!entry)
	{
		test::@check(false, "SKIPPED — the cell stands for nothing");
		return;
	}
	String wanted = entry.name;

	test::@check(fixture.doc().dots.len() == 0, "the document starts with nothing placed");

	Vec2 gear = cell.absolute + cell.widget_as(crig::AssetCell).gear_at(cell.size);
	fixture.click(gear);

	Dialog*? panel = fixture.ui.get_widget_id(crig::ASSET_SETTINGS_DIALOG_ID, Dialog);
	if (catch panel)
	{
		test::@check(false, "SKIPPED — there is no asset settings panel in the tree");
		return;
	}
	test::@check(panel.open, "the gear did not raise the panel");
	test::@check(fixture.doc().dots.len() == 0, "the gear applied the rig as well as opening the panel");

	crig::AssetEntry* opened = fixture.app.settings_entry();
	if (!opened)
	{
		test::@check(false, "the panel opened on nothing");
		return;
	}
	test::eq(opened.name, wanted);

	// The name comes up filled in, because the commonest edit is a small change to
	// what is already there rather than a fresh answer.
	TextField*? name = fixture.ui.get_widget_id(crig::ASSET_SETTINGS_NAME_ID, TextField);
	if (catch name)
	{
		test::@check(false, "the panel has no name field");
		return;
	}
	test::eq(name.value(), wanted);

	panel.set_open(fixture.ui.find_id(crig::ASSET_SETTINGS_DIALOG_ID)!!, false);
	fixture.app.settings_asset = -1;
	fixture.ui.flush();
}
