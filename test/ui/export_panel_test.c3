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

// ---------------------------------------------------------------------------
// One Export panel: Character, All characters or Cutscene

const String EXPORT_PANEL_FOLDER @local = "build/export-panel";
const String EXPORT_PANEL_BOX @local = "build/export-panel/box.glb";
const String EXPORT_PANEL_HERO @local = "build/export-panel/hero.glb";

// A copy of the shipped humanoid under build, as a second character's own file.
fn bool export_panel_hero() @local
{
	(void)io::path::mkdir((io::path::Path)EXPORT_PANEL_FOLDER, true);
	char[]? bytes = io::file::load(mem, "assets/animations/humanoid.glb");
	if (catch bytes) return false;
	defer free(bytes);
	if (catch io::file::save(EXPORT_PANEL_HERO, bytes)) return false;
	return true;
}

fn crig::ExportWhat export_panel_what(Fixture* f) @local => f.app.export_what;

fn sz export_panel_lit(Fixture* f) @local => f.ui.find_id(crig::EXPORT_WHAT_ID)!!.widget_as(Segmented).selected;

fn String export_panel_line(Fixture* f) @local
{
	if (try Element* line = f.ui.find_id(crig::EXPORT_LINE_ID)) return line.widget_as(Label).text;
	return "";
}

// The middle of segment `index` of the What strip.
fn Vec2 export_panel_segment(Fixture* f, usz index) @local
{
	Element* strip = f.ui.find_id(crig::EXPORT_WHAT_ID)!!;
	Segmented* seg = strip.widget_as(Segmented);
	SegmentedStyle s = seg.style.resolved();
	float left = 0;
	for (usz i = 0; i < index; i++) left += s.segment_width(f.ui, seg.options[i]);
	return strip.absolute + (Vec2){ left + s.segment_width(f.ui, seg.options[index]) * 0.5f, strip.size.y * 0.5f };
}

fn void export_panel_open(Fixture* f) @local
{
	crig::open_export_dialog(f.ui);
	f.ui.flush();
	f.feed(f.ui.input.mouse);
}

fn void export_panel_type(Fixture* f, String path) @local
{
	crig::set_export_path(f.ui, path);
	f.ui.flush();
}

fn bool export_panel_is_glb(String path) @local
{
	char[]? content = io::file::load(mem, path);
	if (catch content) return false;
	defer free(content);
	return content.len > 12 && ((String)content[:4]) == "glTF";
}

fn void export_opens_on_the_character_with_one_character() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	f.reset();
	(void)io::path::mkdir((io::path::Path)EXPORT_PANEL_FOLDER, true);
	f.app.point_at(EXPORT_PANEL_BOX);
	test::@check(f.app.apply_plan_named("biped"), "could not fit the test rig");
	String written = "build/export-panel/box_rigged.glb";
	(void)io::file::delete(written);
	defer (void)io::file::delete(written);
	defer (void)io::file::delete("build/export-panel/box_rigged.rigsmith.json");

	export_panel_open(&f);
	test::@check(export_panel_what(&f) == CHARACTER, "one character opened on %s", export_panel_what(&f));
	test::@check(export_panel_lit(&f) == 0, "the strip lights segment %d", export_panel_lit(&f));
	test::@check(has_id(&f, crig::EXPORT_SUMMARY_ID) && !has_id(&f, crig::EXPORT_LINE_ID), "the Character body is not shown");
	test::eq(field_value(&f, crig::EXPORT_PATH_ID), written);

	test::@check(f.confirm_export(), "no Export button");
	test::@check(export_panel_is_glb(written), "the character was not written as %s", written);
}

fn void export_opens_on_all_characters_with_two() @test
{
	if (!export_panel_hero())
	{
		test::@check(false, "SKIPPED — the humanoid copy could not be made");
		return;
	}
	Fixture f;
	f.open()!!;
	defer f.close();
	f.reset();
	f.app.point_at(EXPORT_PANEL_BOX);
	rig::TriMesh? mesh = rig::load_gltf(mem, EXPORT_PANEL_HERO);
	if (catch mesh)
	{
		test::@check(false, "SKIPPED — the humanoid copy could not be read");
		return;
	}
	(void)f.app.add_character(mesh, EXPORT_PANEL_HERO);
	test::@check(f.app.character_count() == 2, "%d characters", f.app.character_count());
	String written = "build/export-panel/duo.glb";
	(void)io::file::delete(written);
	defer (void)io::file::delete(written);

	export_panel_open(&f);
	test::@check(export_panel_what(&f) == ALL_CHARACTERS, "two characters opened on %s", export_panel_what(&f));
	test::@check(export_panel_lit(&f) == 1, "the strip lights segment %d", export_panel_lit(&f));
	test::eq(export_panel_line(&f), "2 characters · 1 rigged");
	test::@check(!has_id(&f, crig::EXPORT_SUMMARY_ID), "the Character summary is shown for all characters");
	test::eq(field_value(&f, crig::EXPORT_PATH_ID), "build/export-panel/scene.glb");

	// No extension typed: the scene's .glb is added.
	export_panel_type(&f, "build/export-panel/duo");
	test::@check(f.confirm_export(), "no Export button");
	test::@check(export_panel_is_glb(written), "all characters were not written as %s", written);
	test::@check(f.notice_text().starts_with("wrote duo.glb"), "the notice reads '%s'", f.notice_text());
}

fn void export_opens_on_the_cutscene_while_previewed() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	f.reset();
	(void)io::path::mkdir((io::path::Path)EXPORT_PANEL_FOLDER, true);
	f.app.point_at(EXPORT_PANEL_BOX);
	test::@check(f.app.make_actor(f.app.active, "hero"), "the cube is no actor");
	(void)f.app.add_cutscene("Opening");
	(void)f.app.add_cutscene("Ending");
	test::@check(f.app.select_cutscene(1), "no second cutscene");
	test::@check(f.app.set_cutscene_preview(true), "no preview");
	String picked = "build/export-panel/picked.cutscene.glb";
	(void)io::file::delete(picked);
	defer (void)io::file::delete(picked);

	export_panel_open(&f);
	test::@check(export_panel_what(&f) == CUTSCENE, "the preview opened on %s", export_panel_what(&f));
	test::@check(export_panel_lit(&f) == 2, "the strip lights segment %d", export_panel_lit(&f));
	test::@check(export_panel_line(&f).starts_with("Ending · 1 actor · "), "the line reads '%s'", export_panel_line(&f));
	test::eq(field_value(&f, crig::EXPORT_PATH_ID), "build/export-panel/Ending.cutscene.glb");

	// Two cutscenes: the picker picks the one written, and the path follows it.
	Vec2? chooser = f.center_of(crig::EXPORT_CUTSCENE_ID);
	if (catch chooser)
	{
		test::@check(false, "no cutscene picker with two cutscenes");
		return;
	}
	f.click(chooser);
	f.ui.flush();
	Vec2 first;
	bool found;
	f.ui.@each(SelectOption; option)
	{
		if (option.widget_as(SelectOption).index == 0)
		{
			first = option.absolute + option.size * 0.5f;
			found = true;
		}
	};
	test::@check(found, "the picker lists no first cutscene");
	if (!found) return;
	f.click(first);
	f.feed(f.ui.input.mouse);
	test::@check(f.app.cut_active == 0, "the pick did not select Opening");
	test::@check(export_panel_line(&f).starts_with("Opening · "), "the line reads '%s'", export_panel_line(&f));
	test::eq(field_value(&f, crig::EXPORT_PATH_ID), "build/export-panel/Opening.cutscene.glb");

	// Browse names what it writes, and its answer fills the field.
	f.click(f.center_of(crig::EXPORT_BROWSE_ID)!!);
	f.ui.flush();
	Element* dialog = f.ui.find_id(crig::FILE_DIALOG_ID)!!;
	test::@check(dialog.widget_as(Dialog).open, "Browse did not open the chooser");
	test::eq(dialog.widget_as(Dialog).title, "Export the cutscene to");
	Element* path_field = f.ui.find_id(crig::FILE_PATH_ID)!!;
	path_field.widget_as(TextField).set_text(path_field, "build/export-panel/picked");
	path_field.request_focus();
	f.feed_key(Key.RETURN);
	test::@check(!dialog.widget_as(Dialog).open, "Select did not close the chooser");
	test::eq(field_value(&f, crig::EXPORT_PATH_ID), "build/export-panel/picked");

	test::@check(f.confirm_export(), "no Export button");
	test::@check(io::file::is_file(picked), "the cutscene was not written as %s: %s", picked, f.notice_text());
	Cutscene? back = crig::read_cutscene_file(mem, picked);
	if (catch back)
	{
		test::@check(false, "%s does not read back as a cutscene", picked);
		return;
	}
	defer back.free(mem);
	test::eq(back.name, "Opening");
}

fn void an_export_choice_that_does_not_apply_snaps_back() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	f.reset();
	f.app.point_at(EXPORT_PANEL_BOX);

	export_panel_open(&f);
	test::@check(export_panel_what(&f) == CHARACTER, "one character opened on %s", export_panel_what(&f));
	test::eq(field_value(&f, crig::EXPORT_PATH_ID), "build/export-panel/box_rigged.glb");

	// No cutscene, and no character with a rig.
	f.click(export_panel_segment(&f, 2));
	f.feed(f.ui.input.mouse);
	test::@check(export_panel_what(&f) == CHARACTER && export_panel_lit(&f) == 0, "Cutscene with none did not snap back");
	test::eq(f.notice_text(), "the scene has no cutscene to export");
	f.click(export_panel_segment(&f, 1));
	f.feed(f.ui.input.mouse);
	test::@check(export_panel_what(&f) == CHARACTER && export_panel_lit(&f) == 0, "All characters with no rig did not snap back");
	test::eq(f.notice_text(), "no character has a rig to export");
	test::@check(has_id(&f, crig::EXPORT_SUMMARY_ID), "the Character body went");
	test::eq(field_value(&f, crig::EXPORT_PATH_ID), "build/export-panel/box_rigged.glb");

	// A rig makes All characters apply; each switch writes its own path.
	test::@check(f.app.apply_plan_named("biped"), "could not fit the test rig");
	f.click(export_panel_segment(&f, 1));
	f.feed(f.ui.input.mouse);
	test::@check(export_panel_what(&f) == ALL_CHARACTERS && export_panel_lit(&f) == 1, "All characters did not switch");
	test::eq(export_panel_line(&f), "1 character · 1 rigged");
	test::eq(field_value(&f, crig::EXPORT_PATH_ID), "build/export-panel/scene.glb");
	f.click(export_panel_segment(&f, 0));
	f.feed(f.ui.input.mouse);
	test::@check(export_panel_what(&f) == CHARACTER && has_id(&f, crig::EXPORT_SUMMARY_ID), "Character did not switch back");
	test::eq(field_value(&f, crig::EXPORT_PATH_ID), "build/export-panel/box_rigged.glb");

	crig::set_dialog_open(f.ui, crig::EXPORT_DIALOG_ID, false);
}
