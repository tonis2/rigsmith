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
// B7: the session file, the occlusion cue and the two diagnostic views

// Where the session checks work. Beside a mesh that does not exist on disk —
// nothing reads the .glb back, the path only decides where the .json goes.
const String SESSION_MESH = "build/ui_test_cube.glb";
const String SESSION_FILE = "build/ui_test_cube.rigsmith.json";

<*
 Save, wreck the rig, load: the document that comes back is the one that was
 saved, down to the ids.

 Asserted on the document rather than on the text, because the text is not the
 promise — reopening a mesh and finding the same rig is. Ids matter as much as
 positions: a load that renumbered would look right on screen and quietly break
 every reference the user has in their head.
*>
fn void session_round_trips() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("a session saves and loads");
	fixture.reset();

	fixture.app.point_at(SESSION_MESH);
	(void)io::file::delete(SESSION_FILE);

	// A rig with something to lose in every field the file carries: a chain of
	// three, a moved root and chaining off.
	fixture.click(SPOT_A);
	fixture.click(SPOT_B);
	fixture.click(SPOT_C);
	fixture.chord(SPOT_C, Key.LEFT_CTRL, Key.R);
	fixture.tap(SPOT_C, Key.A);

	sz dots  = fixture.doc().dots.len();
	sz edges = fixture.doc().edges.len();
	if (dots != 3 || edges != 2)
	{
		test::@check(false, "SKIPPED — the rig to save did not build");
		return;
	}
	uint root = fixture.doc().root_id;
	uint next = fixture.doc().next_id;
	Dot last  = fixture.doc().dots[dots - 1];

	// Ctrl+S rather than the item: the keyboard is what a user reaches for
	// mid-edit, and it is the whole of the save half either way.
	fixture.chord(SPOT_C, Key.LEFT_CTRL, Key.S);
	test::@check(io::file::is_file(SESSION_FILE), "ctrl+S writes the session beside the mesh");
	test::@check(fixture.notice_text().starts_with("saved "), "and the notice says so");

	// Change the document out from under the file, so a load that merged into
	// what is there instead of replacing it would be visible.
	fixture.tap(SPOT_C, Key.X);
	fixture.click(SPOT_LEFT);
	test::@check(fixture.doc().find(last.id) == null, "the rig is edited away before loading");

	fixture.app.load_session();

	test::@check(fixture.doc()
		.dots.len() == dots && fixture.doc().edges.len() == edges, "loading brings the dots and the bones back");
	test::@check(fixture.doc()
		.root_id == root && fixture.doc().next_id == next, "with the root and the id counter it was saved under");
	test::@check(!fixture.doc().auto_connect, "and the editing setting that was off");

	Dot* back = fixture.doc().find(last.id);
	test::@check(
		back != null && (back.position - last.position).length() == 0.0f,
		"each dot returns under its own id, exactly where it was"
	);

	test::@check(fixture.hud_text().contains("3 joints · ") && fixture.hud_text().contains("no chain"),
		"the loaded rig does not reach the HUD: \"%s\"", fixture.hud_text());
	test::@check(fixture.notice_text().starts_with("loaded "), "and the notice says what arrived");

	// Dropped rather than kept: the edits in the history name ids from the
	// document that was just replaced, so replaying them is not a shorter
	// history, it is a wrong one.
	test::@check(!fixture.app.undo_stack.can_undo(), "the undo history does not survive a load");

	(void)io::file::delete(SESSION_FILE);
	fixture.app.point_at("");
}

<*
 A dot named with a quote does not take the whole session down with it.

 The writer builds its JSON by hand, so every string in it is a place the file
 can stop being JSON. A dot's name is the one a user types, and a quote in it
 ends the string early: what follows is read as structure, the parse fails, and
 the session does not lose a *name* — it fails to open at all, taking the
 positions, the bones and the root with it.

 Loaded through `read_session` rather than through the menu, so the check is on
 the reader's own answer and not on whatever the interface does with a failure.
 The name is asserted last and separately: a load that succeeded and dropped the
 name would be a different, much smaller bug, and this has to be able to tell
 them apart.
*>
fn void a_session_survives_a_quoted_dot_name() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("a session survives a dot named with a quote");
	fixture.reset();

	fixture.app.point_at(SESSION_MESH);
	(void)io::file::delete(SESSION_FILE);

	fixture.click(SPOT_A);
	fixture.click(SPOT_B);
	if (fixture.doc().dots.len() != 2)
	{
		test::@check(false, "SKIPPED — the rig to save did not build");
		return;
	}

	// A quote, a backslash and a tab: the three escapes with a short spelling, and
	// the backslash is the one that also breaks a writer that escapes only quotes.
	String awkward = `he"llo\there`;
	uint id = fixture.doc().dots[0].id;
	fixture.app.doc.rename_dot(id, awkward);

	fixture.chord(SPOT_B, Key.LEFT_CTRL, Key.S);
	if (!io::file::is_file(SESSION_FILE))
	{
		test::@check(false, "SKIPPED — nothing was written to load back");
		return;
	}

	crig::RigDocument? read = crig::read_session(mem, SESSION_FILE);
	if (catch fault error = read)
	{
		test::@check(false, "the session did not parse at all (%s)", error);
		(void)io::file::delete(SESSION_FILE);
		fixture.app.point_at("");
		return;
	}
	crig::RigDocument back = read;
	defer back.free();

	test::@check(back.dots.len() == 2, "both dots come back (%d)", back.dots.len());

	Dot* named = back.find(id);
	test::@check(named != null && named.name == awkward,
		"and the name arrives with its quote and backslash intact: \"%s\"",
		named ? named.name : "");

	(void)io::file::delete(SESSION_FILE);
	fixture.app.point_at("");
}

<*
 A session from an older version is refused, and the rig on screen stays.
 One version is read: see rules/files.md.
*>
fn void an_older_session_is_refused() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("a session from an older version is refused");
	fixture.reset();
	fixture.app.point_at(SESSION_MESH);

	fixture.click(SPOT_B);
	sz dots = fixture.doc().dots.len();

	String older = `{ "version": 32, "dots": [{"id":1,"position":[0,0,0]},{"id":2,"position":[0,1,0]},{"id":3,"position":[0,2,0]}], "edges": [[1,2]] }`;
	if (catch io::file::save(SESSION_FILE, (char[])older))
	{
		test::@check(false, "SKIPPED — could not write the older session");
		return;
	}

	fixture.app.load_session();

	test::@check(fixture.notice_text().ends_with("is from an older Rigsmith, so it was not read"),
		"the load did not say why: %s", fixture.notice_text());
	test::@check(fixture.doc().dots.len() == dots, "and the rig on screen is left alone");

	(void)io::file::delete(SESSION_FILE);
	fixture.app.point_at("");
}

<*
 A reach survives being written, read, undone and redone.

 No window for any of it: a reach is a number on a dot, so the two things that
 can lose it are the file and the ledger, and both are reachable without one.

 The delete leg is the easy one to miss. `insert_dot` is what undo puts a dot
 back with, and it takes the reach as an argument — so a `DELETE_DOT` that
 forgot to record one restores the dot at no limit and the mesh quietly rebinds
 differently from how it was a moment earlier.
*>
fn void a_reach_survives_undo_and_the_session() @test
{
	io::printn("a reach round-trips through the session file and the undo ledger");

	RigDocument doc;
	doc.dots.init(mem);
	doc.edges.init(mem);
	doc.attachments.init(mem);
	defer doc.free();

	uint hips = doc.add_dot({ 0, 0, 0 }, "hips");
	uint head = doc.add_dot({ 0, 1, 0 }, "head");
	doc.connect(hips, head);
	doc.set_reach(head, 0.42f);

	// --- the file ---------------------------------------------------------

	if (catch io::file::delete(SESSION_FILE)) {}
	if (catch fault error = crig::write_session(SESSION_FILE, &doc, SESSION_MESH))
	{
		test::@check(false, "could not write the session (%s)", error);
		return;
	}

	RigDocument? reloaded = crig::read_session(mem, SESSION_FILE);
	if (catch reloaded)
	{
		test::@check(false, "the session did not read back");
		return;
	}
	RigDocument back = reloaded;
	defer back.free();
	(void)io::file::delete(SESSION_FILE);

	Dot* head_back = back.find(head);
	Dot* hips_back = back.find(hips);
	test::@check(head_back != null && math::abs(head_back.reach - 0.42f) < 1.0e-6f,
		"the reach came back as %.4f", head_back ? head_back.reach : -1.0f);
	test::@check(hips_back != null && hips_back.reach == 0.0f,
		"a dot that asked for no limit came back with one");

	// --- the ledger -------------------------------------------------------

	Edit widen = { .kind = SET_REACH, .id = head, .reach_before = 0.42f, .reach_after = 0.9f };
	doc.apply_edit(widen);
	test::@check(doc.find(head).reach == 0.9f, "applying a reach edit did not take");
	doc.revert_edit(widen);
	test::@check(doc.find(head).reach == 0.42f, "reverting a reach edit did not put the old one back");

	// --- and through a deletion -------------------------------------------

	Edit gone = {
		.kind = DELETE_DOT,
		.id = head,
		.before = { 0, 1, 0 },
		.other = hips,
		.name = "head",
		.reach_before = 0.42f,
	};
	doc.apply_edit(gone);
	test::@check(doc.find(head) == null, "the dot did not go");
	doc.revert_edit(gone);

	Dot* restored = doc.find(head);
	test::@check(restored != null && restored.reach == 0.42f,
		"the dot came back with a reach of %.4f", restored ? restored.reach : -1.0f);
}

<*
 A blend sharpness survives the session file and the undo ledger, and an unset
 one leaves no key behind at all.

 The absence is half the claim. Zero is the unset state and one is what unset is
 read as, so both are written by writing nothing — which is what keeps the key
 out of every session belonging to a model that never needed it, and what makes
 stepping the sharpness back down to the binder's own blend leave a file
 indistinguishable from one saved before the setting existed.

 The ledger half is the other reading of the same zero: `SET_SHARPNESS` carries
 no dot, so its two floats are the whole edit, and reverting the first
 sharpening a model ever had has to land back on unset rather than on 1.
*>
fn void a_blend_sharpness_survives_undo_and_the_session() @test
{
	io::printn("a blend sharpness round-trips through the session file and the undo ledger");

	RigDocument doc;
	doc.dots.init(mem);
	doc.edges.init(mem);
	doc.attachments.init(mem);
	defer doc.free();

	uint hips = doc.add_dot({ 0, 0, 0 }, "hips");
	uint head = doc.add_dot({ 0, 1, 0 }, "head");
	doc.connect(hips, head);

	// --- what unset writes: nothing ---------------------------------------

	String bare = crig::session_text(mem, &doc, SESSION_MESH);
	defer bare.free(mem);
	test::@check(!bare.contains("sharpness"), "an untouched document wrote a sharpness key");

	test::@check(doc.set_sharpness(1.0f), "the document refused a sharpness of 1");
	String plain = crig::session_text(mem, &doc, SESSION_MESH);
	defer plain.free(mem);
	test::@check(!plain.contains("sharpness"),
		"the binder's own blend was written out as a key rather than as absence");

	// --- and what a real one writes ---------------------------------------

	test::@check(doc.set_sharpness(2.5f), "the document refused a sharpness of 2.5");

	if (catch io::file::delete(SESSION_FILE)) {}
	if (catch fault error = crig::write_session(SESSION_FILE, &doc, SESSION_MESH))
	{
		test::@check(false, "could not write the session (%s)", error);
		return;
	}

	RigDocument? reloaded = crig::read_session(mem, SESSION_FILE);
	if (catch reloaded)
	{
		test::@check(false, "the session did not read back");
		return;
	}
	RigDocument back = reloaded;
	defer back.free();
	(void)io::file::delete(SESSION_FILE);

	// %.9g round-trips a float32 exactly, so this is equality and not an epsilon.
	test::@check(back.sharpness == 2.5f, "the sharpness came back as %.4f", back.sharpness);

	// A file naming a power the arithmetic cannot carry is clamped on the way in
	// rather than reaching the binder: the reader goes through the setter.
	RigDocument? absurd = crig::parse_session(mem,
		`{"version":33,"mesh":"cube.glb","root":0,"next_id":1,"sharpness":40,"dots":[],"edges":[]}`);
	if (try absurd)
	{
		RigDocument clamped = absurd;
		defer clamped.free();
		test::@check(clamped.sharpness == crig::SHARPNESS_MAX,
			"a session asking for 40 came back with %.4f", clamped.sharpness);
	}
	else
	{
		test::@check(false, "a session carrying a sharpness did not parse");
	}

	// --- the ledger -------------------------------------------------------

	Edit sharper = { .kind = SET_SHARPNESS, .sharp_before = 2.5f, .sharp_after = 4.0f };
	doc.apply_edit(sharper);
	test::@check(doc.sharpness == 4.0f, "applying a sharpness edit did not take");
	doc.revert_edit(sharper);
	test::@check(doc.sharpness == 2.5f, "reverting it did not put the old one back");

	// The first one a model ever has, taken back: unset, not 1.
	Edit first = { .kind = SET_SHARPNESS, .sharp_before = 0.0f, .sharp_after = 2.5f };
	doc.revert_edit(first);
	test::@check(doc.sharpness == 0.0f,
		"undoing the first sharpening left %.4f rather than the unset state", doc.sharpness);
}

<*
 A knuckle blend round-trips through the session file and the undo ledger.

 Zero is the unset state, read as the default, and a blend of nothing is a real
 setting stored apart from it — so an untouched model and one set back to the
 default write no key, a hard switch writes 0 and reads back hard, and a version
 27 file with no key reads as the default. Undoing the first change lands on
 unset, not on a copy of the default.

 *Re-introduce:* store a blend of nothing as zero, and it reads back as the
 default.
*>
fn void a_knuckle_blend_survives_undo_and_the_session() @test
{
	io::printn("a knuckle blend round-trips through the session file and the undo ledger");

	RigDocument doc;
	doc.dots.init(mem);
	doc.edges.init(mem);
	doc.attachments.init(mem);
	defer doc.free();
	uint hips = doc.add_dot({ 0, 0, 0 }, "hips");
	uint head = doc.add_dot({ 0, 1, 0 }, "head");
	doc.connect(hips, head);

	String bare = crig::session_text(mem, &doc, SESSION_MESH);
	defer bare.free(mem);
	test::@check(!bare.contains("knuckle_blend"), "an untouched document wrote a knuckle blend");
	test::@check(doc.knuckle_blend_fraction() == crig::KNUCKLE_BLEND_DEFAULT, "unset reads as %f", doc.knuckle_blend_fraction());

	test::@check(!doc.set_knuckle_blend(crig::knuckle_blend_stored(crig::KNUCKLE_BLEND_DEFAULT)),
		"setting the default changed an unset document");

	test::@check(doc.set_knuckle_blend(crig::knuckle_blend_stored(0.0f)), "the document refused a blend of nothing");
	String hard = crig::session_text(mem, &doc, SESSION_MESH);
	defer hard.free(mem);
	test::@check(hard.contains(`"knuckle_blend": 0,`), "a hard switch was written as: %s", hard);

	RigDocument? reread = crig::parse_session(mem, hard);
	if (catch reread)
	{
		test::@check(false, "the session with a knuckle blend did not parse");
		return;
	}
	RigDocument back = reread;
	defer back.free();
	test::@check(back.knuckle_blend_fraction() == 0.0f, "a hard switch came back as %f", back.knuckle_blend_fraction());

	RigDocument? unset = crig::parse_session(mem,
		`{"version":33,"mesh":"cube.glb","root":0,"next_id":1,"dots":[],"edges":[]}`);
	if (try unset)
	{
		RigDocument plain = unset;
		defer plain.free();
		test::@check(plain.knuckle_blend == 0.0f && plain.knuckle_blend_fraction() == crig::KNUCKLE_BLEND_DEFAULT,
			"a session with no knuckle blend came back with %f", plain.knuckle_blend_fraction());
	}
	else
	{
		test::@check(false, "a session with no knuckle blend did not parse");
	}

	RigDocument? wide = crig::parse_session(mem,
		`{"version":33,"mesh":"cube.glb","root":0,"next_id":1,"knuckle_blend":3,"dots":[],"edges":[]}`);
	if (try wide)
	{
		RigDocument clamped = wide;
		defer clamped.free();
		test::@check(clamped.knuckle_blend_fraction() == crig::KNUCKLE_BLEND_MAX,
			"a session asking for 3 came back with %f", clamped.knuckle_blend_fraction());
	}
	else
	{
		test::@check(false, "a session with a wide knuckle blend did not parse");
	}

	Edit first = { .kind = SET_KNUCKLE_BLEND, .knuckle_before = 0.0f, .knuckle_after = 0.3f };
	doc.apply_edit(first);
	test::@check(doc.knuckle_blend_fraction() == 0.3f, "applying a knuckle blend edit left %f", doc.knuckle_blend_fraction());
	doc.revert_edit(first);
	test::@check(doc.knuckle_blend == 0.0f, "undoing the first knuckle blend left %f stored rather than unset", doc.knuckle_blend);
}

<*
 The bracket keys step the blend sharpness, and each press drops the base bind.

 Two claims and the second is the one worth the fixture. The sharpening lives
 *inside* the cached base — it is applied before the paint, so a correction is
 solved against the numbers the user can see — which makes it the one bind
 control that has to invalidate the cache rather than merely the corrections. A
 press that only marked the paint stale would leave every later stroke solving
 against the previous sharpness, and nothing on screen would say so.

 Stepping is a ratio, so the values are exact: 1 × 1.25 × 1.25 lands on 1.5625
 and dividing back down lands on 1, which is stored as unset so the session key
 disappears again.
*>
fn void the_bracket_keys_step_the_blend_sharpness() @test
{
	io::printn("] and [ step the blend sharpness, and each press drops the cached bind");

	Fixture fixture;
	if (catch fault error = fixture.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer fixture.close();

	uint hips = fixture.doc().add_dot({ 0, -0.2f, 0 }, "hips");
	uint chest = fixture.doc().add_dot({ 0, 0.2f, 0 }, "chest");
	fixture.doc().connect(hips, chest);
	fixture.app.select(chest);
	fixture.app.refresh_ui();

	// The cache filled, so its going is something this check can see.
	test::@check(!fixture.app.editing.valid(), "a fresh rig started editing a library clip");
	// Merely remembering a clip must not steal the skinning shortcuts either.
	fixture.app.editing = { 0, 0 };
	RigView view = fixture.app.open_rig(mem)!!;
	defer view.free(mem);
	test::@check(fixture.app.base_bind_for(&view).len > 0, "the fixture mesh did not bind at all");

	fixture.feed_key(Key.RIGHT_BRACKET);
	test::@check(math::abs(fixture.doc().sharpness - 1.25f) < 1.0e-6f,
		"] left the sharpness at %.4f", fixture.doc().sharpness);
	test::@check(fixture.app.base_bind.len == 0,
		"] left the cached base bind in place, so the next stroke would solve against the old sharpness");
	test::@check(fixture.app.weights_stale, "] did not mark the weights stale");

	fixture.feed_key(Key.RIGHT_BRACKET);
	test::@check(math::abs(fixture.doc().sharpness - 1.5625f) < 1.0e-6f,
		"a second ] left the sharpness at %.4f", fixture.doc().sharpness);

	// One press is one Ctrl+Z, both ways.
	test::@check(fixture.app.undo(), "] left nothing on the ledger");
	test::@check(math::abs(fixture.doc().sharpness - 1.25f) < 1.0e-6f,
		"one undo left the sharpness at %.4f rather than back at the first step",
		fixture.doc().sharpness);
	test::@check(fixture.app.redo(), "redo had nothing to put back");
	test::@check(math::abs(fixture.doc().sharpness - 1.5625f) < 1.0e-6f,
		"redo left the sharpness at %.4f", fixture.doc().sharpness);

	// And back down, where the floor is the binder's own blend — stored as unset,
	// so a model softened all the way back writes no session key.
	fixture.feed_key(Key.LEFT_BRACKET);
	test::@check(math::abs(fixture.doc().sharpness - 1.25f) < 1.0e-6f,
		"[ left the sharpness at %.4f", fixture.doc().sharpness);

	fixture.feed_key(Key.LEFT_BRACKET);
	test::@check(fixture.doc().sharpness == 0.0f,
		"stepping back to the binder's own blend left %.4f rather than the unset state",
		fixture.doc().sharpness);

	// The floor holds: another press has nothing to do, so it records nothing.
	fixture.app.undo_stack.clear();
	fixture.feed_key(Key.LEFT_BRACKET);
	test::@check(fixture.doc().sharpness == 0.0f, "[ went below the binder's own blend");
	test::@check(!fixture.app.undo(), "a press that changed nothing still went on the ledger");
}

<*
 The Area tool paints the falloff while it is open and hands the previous view
 back when it closes — unless the user picked a view while it was open.
*>
fn void the_area_tool_borrows_the_falloff_view() @test
{
	io::printn("the Area tool paints the falloff, and gives the previous view back on the way out");

	Fixture fixture;
	if (catch fault error = fixture.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer fixture.close();

	uint hips = fixture.doc().add_dot({ 0, -0.2f, 0 }, "hips");
	uint chest = fixture.doc().add_dot({ 0, 0.2f, 0 }, "chest");
	fixture.doc().connect(hips, chest);
	fixture.app.select(chest);
	fixture.app.refresh_ui();

	test::@check(fixture.app.tint_mode == TintMode.OFF, "the fixture did not start with the mesh unpainted");

	fixture.feed_key(Key.W);
	test::@check(fixture.app.areaing, "W did not open the Area tool");
	test::@check(fixture.app.tint_mode == TintMode.FALLOFF,
		"opening the Area tool left the mesh on %s rather than painting the falloff", fixture.app.tint_mode);

	fixture.feed_key(Key.W);
	test::@check(!fixture.app.areaing, "W did not close the Area tool");
	test::@check(fixture.app.tint_mode == TintMode.OFF,
		"closing it left the mesh painted with %s instead of putting the view back", fixture.app.tint_mode);

	fixture.app.show_tint(TERRITORY);
	fixture.feed_key(Key.W);
	test::@check(fixture.app.tint_mode == TintMode.FALLOFF, "the tool did not take the view over");
	// The first escape drops the part the card picked, the second leaves.
	fixture.feed_key(Key.ESCAPE);
	fixture.feed_key(Key.ESCAPE);
	test::@check(!fixture.app.areaing, "escape did not close the Area tool");
	test::@check(fixture.app.tint_mode == TintMode.TERRITORY,
		"escape left the mesh on %s rather than the territory map it interrupted", fixture.app.tint_mode);

	// Escape left the card up with the tool closed; W puts the card away.
	fixture.feed_key(Key.W);
	test::@check(!fixture.app.weights_card_open(), "W did not hide the Weights card");
	fixture.app.show_tint(OFF);
	fixture.feed_key(Key.W);
	crig::menu_weights(fixture.ui);
	test::@check(fixture.app.tint_mode == TintMode.TERRITORY, "the territory map did not reach the app inside the tool");
	fixture.feed_key(Key.W);
	test::@check(fixture.app.tint_mode == TintMode.TERRITORY,
		"closing the tool overwrote the view the user asked for with %s", fixture.app.tint_mode);
}

<*
 Once any dot is limited, none of them is unlimited.

 Zero is not a neutral reach on a rig where other dots have one. `reach_bias`
 scores an unlimited bone 1 at every distance while a sized one falls away from
 its own radius, so a few unsized dots among many sized ones outrank the many
 *everywhere* — and distance stops costing them anything at all. On a self-rigged
 squirrel that gave two hind feet a third of the body, head included, and bending
 a hind leg skewed the torso. Setting reaches on most of a rig was strictly worse
 than setting none, which nobody can be expected to guess.

 The figure filled in is `default_reach`, which the viewport already draws as an
 unlimited dot's ghost ring — so the binder is being made to agree with what was
 already on screen rather than handed a number from nowhere.

 A rig where *nothing* is limited still sends the binder an empty array, so the
 shipped rigs — none of which set a reach — bind exactly as they always have.
*>
fn void a_mixed_rig_has_no_unlimited_dots() @test
{
	io::printn("one reach anywhere gives every other dot its default instead of no limit");

	Fixture fixture;
	if (catch fault error = fixture.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer fixture.close();

	uint hips = fixture.doc().add_dot({ 0, -0.2f, 0 }, "hips");
	uint chest = fixture.doc().add_dot({ 0, 0.2f, 0 }, "chest");
	uint head = fixture.doc().add_dot({ 0, 0.4f, 0 }, "head");
	fixture.doc().connect(hips, chest);
	fixture.doc().connect(chest, head);
	fixture.app.refresh_ui();

	// --- nothing limited: the binder is told nothing -------------------------

	RigView? untouched = fixture.app.open_rig(mem);
	if (catch untouched)
	{
		test::@check(false, "the rig would not open with three dots in it");
		return;
	}
	RigView bare = untouched;
	test::@check(bare.reaches.len == 0,
		"a rig with no reach on any dot sent the binder %d of them", bare.reaches.len);
	bare.free(mem);

	// --- one limited: every dot comes back with a size -----------------------

	fixture.doc().set_reach(chest, 0.1f);

	RigView? limited = fixture.app.open_rig(mem);
	if (catch limited)
	{
		test::@check(false, "the rig would not open once a dot was limited");
		return;
	}
	RigView view = limited;
	defer view.free(mem);

	test::@check(view.reaches.len == view.dot_ids.len,
		"one reach produced %d figures for %d joints", view.reaches.len, view.dot_ids.len);
	if (view.reaches.len != view.dot_ids.len) return;

	foreach (usz j, id : view.dot_ids)
	{
		float want = id == chest ? 0.1f : fixture.app.default_reach(id);
		test::@check(view.reaches[j] > 0.0f,
			"dot %d came through unlimited on a rig that has a reach in it", id);
		test::@check(math::abs(view.reaches[j] - want) < 1.0e-6f,
			"dot %d came through at %.4f rather than the %.4f expected of it",
			id, view.reaches[j], want);
	}
}

<*
 A hint lasts exactly as long as the tool it is about.

 What this pins: the same sentences used to be printed as notices when a mode
 opened, and a notice has no idea the mode has closed. "scroll to size the ring"
 stayed on screen over a viewport with no ring in it and a wheel back to zooming
 — a control that reads as still armed. Deriving the line from the state each
 frame is what makes that impossible rather than merely fixed.
*>
fn void a_hint_lasts_exactly_as_long_as_its_mode() @test
{
	io::printn("the hint bar follows the mode instead of outliving it");

	Fixture fixture;
	if (catch fault error = fixture.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer fixture.close();

	uint hips = fixture.doc().add_dot({ 0, -0.2f, 0 }, "hips");
	uint chest = fixture.doc().add_dot({ 0, 0.2f, 0 }, "chest");
	fixture.doc().connect(hips, chest);
	fixture.app.select(chest);
	fixture.app.refresh_ui();

	test::@check(fixture.in_tree("hints"), "the pane was built without a hint bar");
	test::@check(crig::hint_line(&fixture.app).len == 0,
		"an idle viewport is hinting at something: \"%s\"", crig::hint_line(&fixture.app));

	fixture.feed_key(Key.W);
	test::@check(crig::hint_line(&fixture.app).contains("grow the joint"),
		"the Area tool is open and the hint reads \"%s\"", crig::hint_line(&fixture.app));
	test::@check(fixture.notice_text().len == 0,
		"the invitation went to the result line, which cannot take it back: \"%s\"",
		fixture.notice_text());

	fixture.feed_key(Key.W);
	test::@check(!fixture.app.areaing, "W did not close the Area tool");
	test::@check(crig::hint_line(&fixture.app).len == 0,
		"the mode closed and the hint stayed up: \"%s\"", crig::hint_line(&fixture.app));
}

// What the bar currently reads, measured at the size it is painted in.
fn float hint_width(Fixture* fixture) => fixture.ui.text.measure(
	0, crig::hint_line(&fixture.app), crig::HUD_TEXT_SIZE).x;

<*
 Every hint fits the box it is painted in.

 The bar is a fixed width — anchored by its own edges, so a width that moved
 with the text would move the text with it — and a line longer than the box is
 clipped at the tail with nothing anywhere to say so. The tail is where the
 escape clause lives, which is the one clause a user in a mode they did not mean
 to open actually needs.

 Every modal line in `hint_line`, driven through the keys that open each mode,
 so a new mode with a long sentence fails here rather than on somebody's screen.
*>
fn void every_hint_fits_the_bar() @test
{
	io::printn("every hint bar line fits the box it is painted in");

	Fixture fixture;
	if (catch fault error = fixture.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer fixture.close();

	uint hips = fixture.doc().add_dot({ 0, -0.2f, 0 }, "hips");
	uint chest = fixture.doc().add_dot({ 0, 0.2f, 0 }, "chest");
	fixture.doc().connect(hips, chest);
	fixture.app.select(chest);
	fixture.app.refresh_ui();

	// One entry per modal line, in the order `hint_line` resolves them: the brush
	// and the lasso's pinning job are the shifted halves of their letters, and the
	// plain T is the lasso's other job, which has a line of its own. Each mode is
	// closed before the next opens, or the line measured would be the previous
	// one's.
	Key[4] opens = { Key.W, Key.W, Key.T, Key.T };
	bool[4] shifted = { false, true, true, false };

	for (usz i = 0; i < opens.len; i++)
	{
		if (shifted[i])
		{
			fixture.chord(VIEWPORT_CENTER, Key.LEFT_SHIFT, opens[i]);
		}
		else
		{
			fixture.feed_key(opens[i]);
		}

		String line = crig::hint_line(&fixture.app);
		float wide = hint_width(&fixture);
		test::@check(line.len > 0, "step %d opened no mode, so nothing was measured", i);
		test::@check(wide <= crig::HINT_BOX_W,
			"\"%s\" is %.1f wide and the bar is %.1f — the tail is clipped",
			line, wide, crig::HINT_BOX_W);

		// The brush has four lines: Add or Remove, with the X-ray box on or off.
		if (fixture.app.brushing)
		{
			for (int k = 0; k < 4; k++)
			{
				fixture.app.brush_removes = (k & 1) != 0;
				fixture.app.config.brush_xray = (k & 2) != 0;
				String variant = crig::hint_line(&fixture.app);
				float variant_wide = hint_width(&fixture);
				test::@check(variant_wide <= crig::HINT_BOX_W,
					"\"%s\" is %.1f wide and the bar is %.1f — the tail is clipped",
					variant, variant_wide, crig::HINT_BOX_W);
			}
			fixture.app.brush_removes = false;
			fixture.app.config.brush_xray = false;
		}

		// Out again: each remaining modal tool closes with escape.
		fixture.feed_key(Key.ESCAPE);
	}

	// The Weights card W opened keeps its tool open under every mode the walk
	// closed; hiding the card closes it.
	if (fixture.app.weights_card_open()) fixture.feed_key(Key.W);

	// With the pointer over the mesh and a joint selected, the only line left is
	// auto-connect's chaining line — which has to fit too.
	String left = crig::hint_line(&fixture.app);
	test::@check(left.len == 0 || left.starts_with("chaining from"),
		"a mode was left open behind the walk: \"%s\"", left);
	test::@check(hint_width(&fixture) <= crig::HINT_BOX_W, "the chaining line is clipped: \"%s\"", left);

	// The Area tool's second line, once a part is waiting for Apply.
	fixture.feed_key(Key.W);
	test::@check(fixture.app.set_area_part(WITH_CHILDREN), "the chest owns none of the cube");
	String picked = crig::hint_line(&fixture.app);
	float picked_wide = hint_width(&fixture);
	test::@check(picked.contains("apply") && picked_wide <= crig::HINT_BOX_W,
		"\"%s\" is %.1f wide and the bar is %.1f", picked, picked_wide, crig::HINT_BOX_W);
	fixture.feed_key(Key.ESCAPE);
	fixture.feed_key(Key.ESCAPE);
	test::@check(!fixture.app.areaing, "two escapes did not drop the part and close the tool");

	// The selecting job has two lines, not one: with nothing selected it drops the
	// clause about the letter that switches to pinning, because that step is about
	// to refuse. The walk above measured the other one — this is the variant a user
	// meets first, before anything has been picked.
	fixture.app.select(0);
	fixture.app.refresh_ui();
	fixture.feed_key(Key.T);
	test::@check(fixture.app.lassoing, "the lasso did not open with nothing selected");

	String bare = crig::hint_line(&fixture.app);
	float bare_wide = hint_width(&fixture);
	test::@check(bare_wide <= crig::HINT_BOX_W,
		"\"%s\" is %.1f wide and the bar is %.1f — the tail is clipped",
		bare, bare_wide, crig::HINT_BOX_W);
	fixture.feed_key(Key.ESCAPE);
}

<*
 A result goes quiet on its own.

 Two halves, because two things have to hold: the frames that age it have to
 keep arriving after the user has gone still — going still is exactly what
 follows a result — and the line has to come down when its time is up.

 The second half is jumped rather than played out: `NOTICE_LIFE` is five hundred
 frames at the fixture's dt, and a test that fed all of them would be measuring
 the layout pass, not the timer.
*>
fn void a_result_line_goes_quiet_by_itself() @test
{
	io::printn("a result fades instead of sitting over the model until the next one");

	Fixture fixture;
	if (catch fault error = fixture.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer fixture.close();

	// A refusal, which is the kind of notice that most wants to go away: it is
	// about a state the user is on their way out of.
	fixture.chord(VIEWPORT_CENTER, Key.LEFT_SHIFT, Key.W);
	test::@check(fixture.notice_text().starts_with("select a joint"),
		"shift+W with nothing selected said \"%s\"", fixture.notice_text());

	test::@check(fixture.app.ticking(),
		"nothing is asking for frames, so the notice would hang there until the next click");

	float aged = fixture.app.notice_age;
	fixture.feed(VIEWPORT_CENTER);
	test::@check(fixture.app.notice_age > aged,
		"a frame went by without ageing the notice — %.4f both times", aged);
	test::@check(fixture.notice_text().len > 0, "one frame was enough to take the result away");

	fixture.app.tick_notice(crig::NOTICE_LIFE);
	test::@check(fixture.notice_text().len == 0,
		"the notice is still up past its %.0f seconds: \"%s\"",
		crig::NOTICE_LIFE, fixture.notice_text());
	test::@check(!fixture.app.ticking(),
		"the notice is down and the loop is still being kept awake for it");
}

<*
 A body plan survives a session, and a rig that declares one is offered only the
 packs that match it.

 Two claims in one check because they are one feature: the tag is written down
 so that the *next* session still knows which packs fit, and a tag nothing reads
 would be a field nobody could tell was broken.

 The mismatch half is asserted on behaviour rather than on the flag — the greyed
 cell has to swallow its click — because a rule that greyed correctly and played
 anyway would look right in every screenshot.
*>
fn void a_plan_survives_a_session() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("a body plan is written down and read back");
	fixture.reset();
	fixture.app.point_at(SESSION_MESH);

	test::@check(fixture.app.apply_plan_named("biped"), "the biped plan applies");
	test::@check(fixture.doc().plan == "biped", "and stamps the document with its tag");

	fixture.chord(VIEWPORT_CENTER, Key.LEFT_CTRL, Key.S);

	// Edited away, so what comes back is the file rather than what was in memory.
	fixture.reset();
	fixture.app.point_at(SESSION_MESH);
	test::@check(fixture.doc().plan.len == 0, "a fresh document declares no plan");

	fixture.app.load_session();

	test::@check(fixture.doc().dots.len() == (sz)PLAN_DOTS, "loading brings the rig back");
	test::@check(fixture.doc().plan == "biped", "and the plan it was built from with it");

	// The shipped pack is a biped, so a biped rig is offered it and a rig
	// claiming to be something else is not.
	test::@check(fixture.app.pack_matches(0), "a biped rig is offered the biped pack");
	fixture.doc().set_plan("quadruped");
	test::@check(!fixture.app.pack_matches(0), "and a quadruped rig is not");

	Element*? strip = fixture.ui.find(AreaTabStrip);
	if (catch strip)
	{
		test::@check(false, "SKIPPED — no tab strip in the tree");
		return;
	}
	fixture.click(tab_center(fixture, strip, 1));

	Element* clip = asset_cell(fixture, crig::AssetKind.ANIMATION);
	if (!clip)
	{
		test::@check(false, "SKIPPED — the Assets view offered no clip");
		return;
	}

	test::@check(crig::clip_flags(&fixture.app, { 0, 0 }).disabled, "every clip in it greys out");
	fixture.click(cell_center(clip));
	test::@check(!fixture.app.animating, "and the greyed cell swallows the click rather than playing");

	// Nothing declared falls back to the older rule, which is what keeps a
	// hand-built rig and every pre-pack file usable.
	fixture.doc().set_plan("");
	test::@check(fixture.app.pack_matches(0), "a rig that declares nothing is offered everything");
	test::@check(!crig::clip_flags(&fixture.app, { 0, 0 }).disabled, "and its clips are judged on the names they have in common");

	// Back to the 3D view, and re-fetch the viewport: switching tabs rebuilds
	// the pane, so every element pointer held from before this check is stale.
	if (try Element* back = fixture.ui.find(AreaTabStrip)) fixture.click(tab_center(fixture, back, 0));
	fixture.viewport = fixture.ui.find(Viewport)!!;

	(void)io::file::delete(SESSION_FILE);
	fixture.app.point_at("");
}

<*
 A rig with no bones in it saves and loads like any other.

 Its own check because the empty list is a shape the JSON layer gets wrong on
 its own: `Object.is_array()` is false for `[]` — a container is only tagged as
 a list once something is pushed into it — so validating with it refuses every
 rig up to its second dot. A round trip that always has both a dot and a bone
 in it never touches that path.
*>
fn void session_survives_a_rig_with_no_bones() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("a rig with no bones round-trips too");
	fixture.reset();

	fixture.app.point_at(SESSION_MESH);
	(void)io::file::delete(SESSION_FILE);

	fixture.click(SPOT_B);
	if (fixture.doc().dots.len() != 1 || fixture.doc().edges.len() != 0)
	{
		test::@check(false, "SKIPPED — the lone dot did not land");
		return;
	}

	fixture.chord(SPOT_B, Key.LEFT_CTRL, Key.S);
	fixture.tap(SPOT_B, Key.X);
	test::@check(fixture.doc().dots.len() == 0, "the one dot is deleted before loading");

	fixture.app.load_session();

	test::@check(fixture.doc()
		.dots.len() == 1 && fixture.doc().edges.len() == 0, "the dot comes back with its empty bone list");
	test::@check(fixture.notice_text().starts_with("loaded "), "and the load reports success");

	(void)io::file::delete(SESSION_FILE);
	fixture.app.point_at("");
}

<*
 A file crig did not write is refused, and refused without touching the rig on
 screen.

 Both cases are *valid JSON* on purpose. Parsing is the half that fails loudly
 and by itself; what has to be checked is the half that does not — a document
 of the wrong shape, and one from a version this build does not understand.
 Either would otherwise be adopted as a rig, on top of the one the user has.
*>
fn void session_refuses_what_it_did_not_write() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("a foreign file is not a session");
	fixture.reset();
	fixture.app.point_at(SESSION_MESH);

	fixture.click(SPOT_B);
	sz dots = fixture.doc().dots.len();

	String[3] impostors = { // The right keys, the wrong shape.
		`{ "version": 33, "dots": "not a list", "edges": [] }`, // The right shape, from a version this build has never seen. Refused on
		// the version alone, which is the whole reason the field is written.
		`{ "version": 99, "dots": [], "edges": [] }`, // Someone else's JSON that happens to share the name. A reader that
		// only checks the version when one is present accepts every file that
		// omits it, which is the loosest possible reading of "is this ours".
		`{ "dots": [], "edges": [] }`,
	};

	foreach (impostor : impostors)
	{
		if (catch io::file::save(SESSION_FILE, (char[])impostor))
		{
			test::@check(false, "SKIPPED — could not write the file to be refused");
			return;
		}

		fixture.app.load_session();

		test::@check(fixture.notice_text().ends_with("is not a crig project file"), "the load is refused");
		test::@check(fixture.doc().dots.len() == dots, "and the rig on screen is left alone");
	}

	(void)io::file::delete(SESSION_FILE);
	fixture.app.point_at("");
}

<*
 Occlusion dimming, which is `Picker.occluded` and nothing else: the overlay
 draws with no depth test, so this function is the only thing that knows a dot
 is behind the body.

 Three points along one ray, and the middle one is the check that matters. Dots
 live *inside* the mesh by construction, so a rule that answered "is there
 geometry in front of this point" would dim every joint in the rig — and a test
 that only tried a point in front and a point behind would pass with it.
*>
fn void occlusion_only_dims_what_is_behind() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("occlusion dims only what the body is in front of");
	fixture.reset();

	Vec3 eye = { 0, 0, 6 };
	test::@check(!fixture.app.picker.occluded(eye, { 0, 0, 2 }), "a point in front of the cube is seen");
	test::@check(!fixture.app.picker.occluded(eye, { 0, 0, 0 }), "so is one inside it, where dots live");
	test::@check(fixture.app.picker.occluded(eye, { 0, 0, -6 }), "one behind the whole body is not");
}

<*
 The diagnostic view B7 adds beside the territory map: one joint's weight on a
 ramp (F), and the switch back to the territory map from it.

 Both go through the same tint buffer, debounce and generation counter the
 preview already had, so what is new is which rows become which colours — and,
 for the falloff view, that changing the selection changes the picture. The
 selection *is* the view there, which is the one thing a mode that reads a
 joint index once gets wrong.
*>
fn void the_falloff_view_paints_the_mesh() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("the falloff view paints the mesh, and the territory map takes over from it");
	fixture.reset();

	// Falloff shows one joint, so with nothing selected there is no view to
	// show. Saying so beats painting joint 0's falloff, which is not the joint
	// the user is thinking about.
	fixture.tap(SPOT_B, Key.F);
	test::@check(fixture.app.tint_mode == TintMode.OFF, "F with nothing selected turns nothing on");
	test::@check(fixture.notice_text().starts_with("select a joint first"), "and says why");

	fixture.click(SPOT_A);
	fixture.click(SPOT_C);
	if (fixture.doc().dots.len() != 2)
	{
		test::@check(false, "SKIPPED — the two dots did not land");
		return;
	}
	uint first = fixture.doc().dots[0].id;

	fixture.tap(SPOT_C, Key.F);
	test::@check(fixture.app.tint_mode == TintMode.FALLOFF, "with a dot selected F switches the view on");
	fixture.settle_weights();
	test::@check(fixture.app.tints.len == cube().positions.len, "one colour per vertex");
	test::@check(distinct_tints(fixture) >= 2, "and the ramp varies over the mesh");

	// Selecting the other dot is a rig change as far as this view is concerned.
	uint painted = fixture.app.tint_generation;
	Vec2? at     = fixture.pixel_of(first);
	if (catch at)
	{
		test::@check(false, "SKIPPED — the first dot is not on screen");
		return;
	}
	fixture.click(at);
	fixture.settle_weights();
	test::@check(fixture.app.selected == first, "clicking the other dot selects it");
	test::@check(fixture.app.tint_generation != painted, "and the falloff view follows the selection");

	// Switching views with the rig untouched. The colours on the model are the
	// assertion, not the mode field: `weights_stale` is a statement about the
	// *rig*, and nothing about the rig changes when the question does — so a
	// switch that only re-armed a stale rig leaves the previous view painted and
	// both W and F show whichever one was computed first.
	uint[] falloff = tints_copy(fixture);
	defer alloc::free(mem, falloff);
	painted = fixture.app.tint_generation;

	fixture.toggle_weights(SPOT_C);
	fixture.settle_weights();
	test::@check(fixture.app.tint_mode == TintMode.TERRITORY, "the weight view takes over from F rather than toggling it off");
	test::@check(fixture.app.tints.len == cube().positions.len, "which also colours every vertex");
	test::@check(fixture.app.tint_generation != painted, "switching views rebinds without any edit");
	test::@check(!same_tints(fixture, falloff), "and repaints the mesh as the territory map");

	fixture.toggle_weights(SPOT_C);
	test::@check(fixture.app.tint_mode == TintMode.OFF, "and the same item turns it back off");
}

<*
 The colours currently on the model, copied out — the buffer itself is freed
 and replaced on every rebind, so a comparison across one has to own its copy.
*>
fn uint[] tints_copy(Fixture* fixture)
{
	uint[] copy = alloc::new_array(mem, uint, (sz)fixture.app.tints.len);
	foreach (usz i, tint : fixture.app.tints) copy[i] = tint;
	return copy;
}

fn bool same_tints(Fixture* fixture, uint[] other)
{
	if (fixture.app.tints.len != other.len) return false;
	foreach (usz i, tint : fixture.app.tints) if (tint != other[i]) return false;
	return true;
}

<*
 How many different colours are on the model. Two is the interesting answer:
 one means the view is painting a flat sheet, which every one of these views
 would do if the row-to-colour function collapsed.
*>
fn uint distinct_tints(Fixture* fixture)
{
	uint unique = 0;
	foreach (usz i, tint : fixture.app.tints)
	{
		bool seen = false;
		for (usz j = 0; j < i; j++) if (fixture.app.tints[j] == tint) seen = true;
		if (!seen) unique++;
	}
	return unique;
}

<*
 The middle of one tint button, in window coordinates.

 Measured off the strip's own element rather than from the theme constants, for
 the same reason `center_of` is: the point of aiming at a button is to hit where
 it actually ended up.
*>
fn Vec2 tint_cell(Element* strip, usz index)
{
	return strip.absolute + (Vec2) {
		crig::TINT_CELL_W * ((float)index + 0.5f),
		crig::TINT_CELL_H * 0.5f,
	};
}

<*
 What a tint button is currently showing — the state the last repaint drew, not
 a fresh poll, so this asserts that the widget noticed, rather than that the
 query it polls is right.
*>
fn MenuItemFlags tint_flags(Element* strip, usz index)
{
	return strip.widget_as(IconStrip).shown[index];
}

<*
 The icon strip on the right of the 3D view's header: one button per tint view,
 lit while its view is showing and greyed while there is nothing to colour by.

 Worth its own check rather than trusting the menu items it shares its queries
 with, because the two are polled on opposite schedules. A dropdown asks when it
 opens, which is always after the change; the strip is on screen the whole time
 and has to ask every frame — so this is the only path where "the button is
 right" and "something remembered to tell it" are different statements.
*>
fn void tint_toggles_switch_views() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("the tint buttons switch views from the 3D view's header");
	fixture.reset();
	fixture.feed(VIEWPORT_CENTER); // one frame, so the strip has polled

	Element*? strip = fixture.ui.find_id("tints");
	if (catch strip)
	{
		test::@check(false, "SKIPPED — the tint strip is not in the pane");
		return;
	}
	test::@check(strip.absolute.x + strip.size.x <= crig::WIN_W, "the strip sits inside the window");
	test::@check(
		strip.absolute.y >= crig::BAR_H + TAB_H && strip.absolute.y < CHROME_H,
		"and inside the pane's header rather than on the window bar"
	);

	Vec2 weights = tint_cell(strip, 0);
	Vec2 falloff = tint_cell(strip, 1);
	test::@check(tint_flags(strip, 0).disabled, "with no dots placed the weights button is greyed");
	test::@check(tint_flags(strip, 1).disabled, "and so is the falloff one, which has no joint to ramp from");

	fixture.click(weights);
	test::@check(fixture.app.tint_mode == TintMode.OFF, "and clicking it turns nothing on");

	// Two dots, so the territory map has more than one region to draw. Placing
	// selects, which is what the falloff button needs — it ramps from the
	// selection and stays greyed without one.
	fixture.click(SPOT_A);
	fixture.click(SPOT_B);
	sz placed = fixture.doc().dots.len();
	fixture.ensure_a_dot();
	if (fixture.app.selected == 0)
	{
		test::@check(false, "SKIPPED — placing a dot left nothing selected for the falloff button");
		return;
	}

	fixture.feed(VIEWPORT_CENTER);
	test::@check(!tint_flags(strip, 0).disabled, "placing a dot un-greys it");
	test::@check(!tint_flags(strip, 1).disabled, "and selecting one un-greys the falloff button");

	fixture.click(weights);
	test::@check(fixture.app.tint_mode == TintMode.TERRITORY, "clicking it switches the territory map on");
	test::@check(fixture.doc().dots.len() == placed, "and does not also place a dot behind the bar");

	fixture.feed(VIEWPORT_CENTER);
	test::@check(tint_flags(strip, 0).checked, "the button lights up for the view it turned on");

	// The two are one control, not two: switching moves the light rather than
	// adding a second one.
	fixture.click(falloff);
	fixture.feed(VIEWPORT_CENTER);
	test::@check(fixture.app.tint_mode == TintMode.FALLOFF, "the second button takes the view over");
	test::@check(!tint_flags(strip, 0).checked && tint_flags(strip, 1).checked, "and the light moves rather than doubling");

	fixture.click(falloff);
	test::@check(fixture.app.tint_mode == TintMode.OFF, "clicking the lit one turns the view off");

	// The half that only a per-frame poll can pass: nothing on the menu item's
	// path knows the strip exists.
	fixture.toggle_weights(VIEWPORT_CENTER);
	fixture.feed(VIEWPORT_CENTER);
	test::@check(tint_flags(strip, 0).checked, "the menu item lights the button too");
	fixture.toggle_weights(VIEWPORT_CENTER);

	// The window bar's dropdown (Rig and View live there too): it covers the
	// whole window with a catcher the strip is *below*, so the click
	// that dismisses it is swallowed there rather than also switching a view —
	// the same modality a click on the model gets.
	Vec2? file_title = fixture.center_of("File");
	if (catch file_title)
	{
		test::@check(false, "SKIPPED — the File title is not on the bar");
		return;
	}
	fixture.click(file_title);
	test::@check(fixture.in_tree("Quit"), "the File menu opens");

	TintMode before = fixture.app.tint_mode;
	fixture.click(weights);
	test::@check(!fixture.in_tree("Quit"), "a tint button dismisses a window-bar dropdown");
	test::@check(fixture.app.tint_mode == before, "and that click does not also switch the view");
}

<*
 The middle of one tool cell, in window coordinates.

 Off the column's own element, `tint_cell`'s reason: the point of aiming at a
 button is to hit where it actually ended up. The cells are a `Column`, so they
 step by a cell plus the gap between two.
*>
fn Vec2 tool_cell(Element* column, usz index)
{
	return column.absolute + (Vec2) {
		crig::TOOL_CELL_W * 0.5f,
		(crig::TOOL_CELL_H + crig::TOOL_CELL_GAP) * (float)index + crig::TOOL_CELL_H * 0.5f,
	};
}

<*
 The tool column down the left edge of the 3D view: a click picks a tool, and the
 lit cell follows the tool however it was opened.

 The second half is the one with teeth, and it is why this is a check about the
 *widget* rather than about the queries it borrows. What a cell looks like is its
 button's style, decided when the subtree is built — so a lasso opened from the
 keyboard reaches the screen only if the column noticed and asked to be built
 again. Nothing on the key's path knows the column exists.
*>
fn void the_tool_column_picks_and_follows_a_tool() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("the tool column picks a tool, and follows one opened from the keyboard");
	fixture.reset();
	fixture.two_dots();
	fixture.feed(VIEWPORT_CENTER); // one frame, so the column has polled and built

	Element*? column = fixture.ui.find_id("tools");
	if (catch column)
	{
		test::@check(false, "SKIPPED — the tool column is not in the pane");
		return;
	}

	// Against the left edge and below the header, which is where a toolbar goes —
	// and clear of the stats block, which moved right to make room for it.
	test::@check(column.absolute.y >= CHROME_H, "the column is over the pane's header");
	test::@check(column.absolute.x + crig::TOOL_CELL_W < crig::HUD_LEFT_MARGIN,
		"the column runs under the stats block instead of beside it");

	Vec2 tweak = tool_cell(column, 0);
	Vec2 move = tool_cell(column, 1);
	Vec2 rotate = tool_cell(column, 2);
	Vec2 lasso = tool_cell(column, 4);

	// Un-greyed before anything is clicked. The column was built when the document
	// was empty and the cell had nothing to select, so this is already the poll
	// working: a cell left as it was built would still be carrying no handler at
	// all, and every click below would land on a dead button.
	test::@check(!column.widget_as(crig::ToolColumn).shown[4].disabled,
		"the lasso cell is still greyed after two dots were placed");

	fixture.click(move);
	test::@check(fixture.app.transform_tool == crig::TransformTool.MOVE_TOOL,
		"clicking the move cell did not select the persistent move tool");
	test::@check(crig::query_move_tool(fixture.ui).checked,
		"the move cell is not checked after selecting it");
	test::@check(crig::hint_line(&fixture.app).contains("drag a joint to place it on the model"),
		"the selected move tool does not explain its gesture");

	fixture.click(rotate);
	test::@check(fixture.app.transform_tool == crig::TransformTool.ROTATE_TOOL,
		"clicking the rotate cell did not select the persistent rotate tool");
	test::@check(crig::query_rotate_tool(fixture.ui).checked,
		"the rotate cell is not checked after selecting it");
	test::@check(crig::hint_line(&fixture.app).contains("drag a colored ring"),
		"the selected rotate tool does not explain its gesture");

	fixture.click(tweak);
	test::@check(fixture.app.transform_tool == crig::TransformTool.SELECT_TOOL,
		"clicking tweak did not restore direct joint manipulation");

	// A click opens the tool the cell is for, on its first job.
	fixture.click(lasso);
	test::@check(fixture.app.lassoing && fixture.app.lasso_job == crig::LassoJob.SELECT,
		"clicking the lasso cell did not open it on the selecting job");
	test::@check(fixture.doc().dots.len() == 2, "and it placed a dot in the model behind the cell");

	// Clicking the lit cell walks the tool on, exactly as its key does — the cell
	// and the letter run the same handler, so they cannot disagree about the order.
	fixture.click(lasso);
	test::@check(fixture.app.lasso_job == crig::LassoJob.PIN,
		"clicking the lit lasso cell did not walk it on to pinning");

	// The first cell means *no tool*, whichever tool is running.
	fixture.click(tweak);
	test::@check(!fixture.app.lassoing, "the tweak cell left the lasso open");

	// Including the two tools the column does not list. A cell that only closed
	// what it can show would leave the drag claimed by something invisible here.
	fixture.chord(VIEWPORT_CENTER, Key.LEFT_SHIFT, Key.W);
	test::@check(fixture.app.brushing, "the brush did not open");
	fixture.click(tweak);
	test::@check(!fixture.app.brushing, "the tweak cell left the brush running");

	// And the half only a per-frame poll can pass: the key knows nothing about the
	// column, so the cell is lit here or the widget never noticed.
	fixture.feed_key(Key.T);
	fixture.feed(VIEWPORT_CENTER);
	test::@check(column.widget_as(crig::ToolColumn).shown[4].checked,
		"a lasso opened from the keyboard did not light its cell");
	test::@check(!column.widget_as(crig::ToolColumn).shown[0].checked,
		"and the tweak cell stayed lit beside it");

	fixture.feed_key(Key.ESCAPE);
	fixture.feed(VIEWPORT_CENTER);
	test::@check(column.widget_as(crig::ToolColumn).shown[0].checked,
		"closing the tool did not put the light back on the tweak cell");
}

fn void a_move_begun_on_the_pivot_does_not_jump_on_the_first_motion() @test
{
	Fixture fixture;
	if (catch fault error = fixture.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer fixture.close();

	// G pressed with the pointer on the thing being moved: the first nudge of the
	// mouse moves it by that nudge, not by a jump sideways.
	fixture.app.select_scene(crig::SceneSelection.MODEL);
	fixture.app.refresh_ui();
	fixture.feed(VIEWPORT_CENTER);
	fixture.feed_key(Key.G);
	test::@check(fixture.app.transform_interaction.active, "G did not begin a move");
	Vec2 anchor = fixture.app.transform_interaction.anchor;
	test::@check((anchor - VIEWPORT_CENTER + fixture.app.transform_interaction.viewport_origin).length() < 1.0e-3f,
		"the move did not start from the pointer (anchor %s)", anchor);

	fixture.feed(VIEWPORT_CENTER + (Vec2){ 1, 0 });
	Vec3 moved = fixture.app.doc.model_transform.location;
	test::@check(moved.x >= 0.0f, "the first motion threw the model back along -X: %s", moved);
	test::@check(moved.length() < 0.05f, "a one pixel nudge moved the model %s", moved);
	fixture.feed_key(Key.ESCAPE);
}

fn void a_keyboard_move_draws_no_gizmo_and_still_takes_an_axis() @test
{
	Fixture fixture;
	if (catch fault error = fixture.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer fixture.close();

	// G puts no handles on screen: a click ends the move, so they could never be
	// grabbed. X still holds the move to its axis.
	fixture.app.select_scene(crig::SceneSelection.MODEL);
	fixture.app.refresh_ui();
	fixture.feed(VIEWPORT_CENTER);
	fixture.feed_key(Key.G);
	test::@check(fixture.app.transform_interaction.active, "G did not begin a move");
	crig::Viewport* viewport = fixture.viewport.widget_as(crig::Viewport);
	test::@check(!@ok(viewport.transform_gizmo_frame(fixture.viewport)), "G put a gizmo up");
	fixture.feed_key(Key.X);
	test::@check(fixture.app.transform_interaction.axis == DragAxis.X, "X did not hold the move to its axis");
	fixture.feed_key(Key.ESCAPE);
}

<*
 G on a joint carries it into the mesh under the pointer, and Ctrl lets go.

 The dot starts in front of the cube on the eye's line through its centre — where
 a view-plane move made from the front leaves a joint that looks right and is
 nowhere near the body from the side. A G move picks its depth from the mesh the
 way a drag does; with Ctrl held it keeps the depth it had.
*>
fn void a_keyboard_move_of_a_joint_lands_in_the_mesh() @test
{
	foreach (ctrl : (bool[2]){ false, true })
	{
		Fixture fixture;
		if (catch fault error = fixture.open())
		{
			test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
			return;
		}
		defer fixture.close();

		Vec3 toward_eye = (fixture.app.camera.eye() - fixture.app.camera.target).normalize();
		uint id = fixture.app.place({});
		fixture.doc().find(id).position = toward_eye * 3.0f;
		fixture.app.select(id);
		fixture.app.refresh_ui();
		fixture.ui.flush();

		Vec2? at = fixture.pixel_of(id);
		if (catch at)
		{
			test::@check(false, "the dot is on screen to move");
			return;
		}
		Key[1] held = { Key.LEFT_CTRL };
		Key[] keys = ctrl ? held[..] : (Key[]){};
		fixture.feed(at);
		fixture.feed_key(Key.G);
		test::@check(fixture.app.transform_interaction.active, "G did not begin a move of the joint");
		fixture.feed(at + (Vec2){ 4, 0 }, keys: keys);
		fixture.feed(at + (Vec2){ 8, 0 }, keys: keys);
		fixture.feed_key(Key.RETURN);
		test::@check(!fixture.app.transform_interaction.active, "Enter did not finish the move");

		Dot* moved = fixture.doc().find(id);
		if (!moved)
		{
			test::@check(false, "the dot survived the move");
			return;
		}
		float depth = moved.position.dot(toward_eye);
		if (ctrl)
		{
			test::@check(math::abs(depth - 3.0f) < 0.05f, "Ctrl held, the move changed the joint's depth to %f", depth);
		}
		else
		{
			test::@check(math::abs(depth) < 1.0f, "the move left the joint out of the cube at depth %f", depth);
		}
	}
}

fn void keyboard_transforms_take_numbers_and_cancel_exactly() @test
{
	Fixture fixture;
	if (catch fault error = fixture.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer fixture.close();

	io::printn("G and R take constraints, typed values, commit, and exact cancellation");
	fixture.app.select_scene(crig::SceneSelection.MODEL);
	fixture.app.refresh_ui();
	fixture.feed(VIEWPORT_CENTER);

	fixture.feed_key(Key.G);
	test::@check(fixture.app.transform_interaction.active
		&& fixture.app.transform_interaction.operation == crig::TransformOperation.MOVE_TRANSFORM,
		"G did not begin a model move");
	fixture.feed_key(Key.X);
	fixture.feed_key(Key.KEY_2);
	fixture.feed_key(Key.PERIOD);
	fixture.feed_key(Key.KEY_5);
	test::@check(math::abs(fixture.app.doc.model_transform.location.x - 2.5f) < 1.0e-5f
		&& math::abs(fixture.app.doc.model_transform.location.y) < 1.0e-5f
		&& math::abs(fixture.app.doc.model_transform.location.z) < 1.0e-5f,
		"the typed X value did not drive the live preview");
	String status = crig::hint_line(&fixture.app);
	test::@check(status.contains("Move") && status.contains("X")
		&& status.contains("Global") && status.contains("2.5 m")
		&& status.contains("confirm") && status.contains("cancel"),
		"the transform hint does not report the operation, axis, space, value, and controls");

	fixture.feed_key(Key.RETURN);
	test::@check(!fixture.app.transform_interaction.active
		&& fixture.app.undo_stack.can_undo(),
		"Enter did not commit the transform as an undoable edit");
	test::@check(fixture.app.undo(), "the keyboard transform did not undo");
	test::@check(fixture.app.doc.model_transform.is_identity()
		&& !fixture.app.undo_stack.can_undo(),
		"one undo did not restore the model or the transform split into several steps");

	fixture.feed_key(Key.G);
	fixture.feed_key(Key.X);
	fixture.feed_key(Key.KEY_3);
	fixture.feed_key(Key.ESCAPE);
	test::@check(!fixture.app.transform_interaction.active
		&& fixture.app.doc.model_transform.is_identity()
		&& !fixture.app.undo_stack.can_undo(),
		"Escape did not restore the exact starting transform without history");

	fixture.feed_key(Key.R);
	fixture.feed_key(Key.Z);
	fixture.feed_key(Key.KEY_1);
	fixture.feed_key(Key.KEY_8);
	fixture.feed_key(Key.KEY_0);
	test::@check(!fixture.app.doc.model_transform.is_identity(),
		"a typed rotation did not preview");
	fixture.right_click(VIEWPORT_CENTER);
	test::@check(!fixture.app.transform_interaction.active
		&& fixture.app.doc.model_transform.is_identity()
		&& !fixture.app.undo_stack.can_undo(),
		"right-click did not cancel the rotation exactly");
}

fn void move_and_rotate_gizmos_hit_and_drag() @test
{
	Fixture fixture;
	if (catch fault error = fixture.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer fixture.close();

	io::printn("the move arrows and rotate rings are hittable in the viewport");
	uint root = fixture.doc().add_dot({ 0, -0.25f, 0 }, "root");
	uint tip = fixture.doc().add_dot({ 0, 0.25f, 0 }, "tip");
	uint side = fixture.doc().add_dot({ 0.22f, 0.08f, 0.13f }, "side");
	fixture.doc().connect(root, tip);
	fixture.doc().connect(root, side);
	fixture.app.select_scene(crig::SceneSelection.SKELETON);
	fixture.app.refresh_ui();
	fixture.feed(VIEWPORT_CENTER);

	crig::Viewport* viewport = fixture.viewport.widget_as(crig::Viewport);
	crig::menu_move_tool(fixture.ui);
	fixture.feed(VIEWPORT_CENTER);
	crig::TransformGizmoFrame? built = viewport.transform_gizmo_frame(fixture.viewport);
	if (catch built)
	{
		test::@check(false, "the move tool produced no gizmo frame");
		return;
	}
	crig::TransformGizmoFrame frame = built;
	int component = frame.visible_axes[0] ? 0 : (frame.visible_axes[1] ? 1 : 2);
	Vec2 local_start = frame.projected_pivot
		+ frame.screen_axes[component] * (crig::TRANSFORM_AXIS_LENGTH * 0.78f);
	crig::TransformGizmoPart hit = viewport.hit_transform_gizmo(fixture.viewport, local_start);
	test::@check(hit != crig::TransformGizmoPart.NO_GIZMO_PART,
		"the visible move arrow did not hit-test");

	Vec3 before = fixture.doc().find(root).position;
	Vec2 start = fixture.viewport.absolute + local_start;
	fixture.drag(start, start + frame.screen_axes[component] * 28.0f);
	test::@check(!fixture.app.transform_interaction.active
		&& (fixture.doc().find(root).position - before).length() > 1.0e-4f
		&& fixture.app.undo_stack.can_undo(),
		"dragging a move arrow did not commit one visible transform");
	test::@check(fixture.app.undo(), "the gizmo move did not undo");

	// Applying a body plan leaves its root joint selected. A rest rotation of
	// that one joint therefore turns its whole descendant branch; rotating the
	// root point around itself would accept the gesture and visibly do nothing.
	fixture.app.select(root);
	fixture.app.refresh_ui();
	crig::menu_rotate_tool(fixture.ui);
	fixture.feed(VIEWPORT_CENTER);
	crig::TransformGizmoFrame? rotate_built = viewport.transform_gizmo_frame(fixture.viewport);
	if (catch rotate_built)
	{
		test::@check(false, "the rotate tool produced no gizmo frame");
		return;
	}
	frame = rotate_built;
	bool ring_hit = false;
	Vec2 ring_start;
	for (int axis = 0; axis < 3 && !ring_hit; axis++)
	{
		int first = (axis + 1) % 3;
		int second = (axis + 2) % 3;
		for (int step = 0; step < 16 && !ring_hit; step++)
		{
			float angle = 2.0f * (float)math::PI * (float)step / 16.0f;
			Vec3 point = frame.pivot + (frame.axes[first] * math::cos(angle)
				+ frame.axes[second] * math::sin(angle)) * frame.radius;
			Vec2? projected = crig::project(frame.projection, point, frame.size);
			if (catch projected) continue;
			crig::TransformGizmoPart part = viewport.hit_transform_gizmo(fixture.viewport, projected);
			ring_hit = part != crig::TransformGizmoPart.NO_GIZMO_PART;
			if (ring_hit) ring_start = projected;
		}
	}
	test::@check(ring_hit, "none of the visible rotate rings hit-test where it is drawn");
	if (!ring_hit) return;

	Vec3 side_before = fixture.doc().find(side).position;
	Vec2 arm = (ring_start - frame.projected_pivot).normalize();
	Vec2 tangent = { -arm.y, arm.x };
	fixture.drag(fixture.viewport.absolute + ring_start,
		fixture.viewport.absolute + ring_start + tangent * 32.0f);
	test::@check(!fixture.app.transform_interaction.active
		&& (fixture.doc().find(side).position - side_before).length() > 1.0e-4f
		&& fixture.app.undo_stack.can_undo(),
		"dragging a rotate ring did not rotate and commit the skeleton");
	test::@check(fixture.app.undo(), "the gizmo rotation did not undo");
}

<*
 Pressing the middle of the move gizmo never locks an axis.

 All three arrows meet at the pivot, so a press on the joint used to grab
 whichever arrow was tested first and slide the joint along it — "moves
 everywhere except where I point". The middle is the free handle: over a joint
 it is that joint's own drag, which lands it on the model.
*>
fn void the_move_gizmo_middle_is_a_free_drag() @test
{
	Fixture fixture;
	if (catch fault error = fixture.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer fixture.close();

	uint root = fixture.doc().add_dot({ 0, -0.25f, 0 }, "root");
	uint tip = fixture.doc().add_dot({ 0, 0.25f, 0 }, "tip");
	fixture.doc().connect(root, tip);
	fixture.app.select(tip);
	fixture.app.refresh_ui();
	fixture.feed(VIEWPORT_CENTER);

	crig::Viewport* viewport = fixture.viewport.widget_as(crig::Viewport);
	crig::menu_move_tool(fixture.ui);
	fixture.feed(VIEWPORT_CENTER);
	crig::TransformGizmoFrame? built = viewport.transform_gizmo_frame(fixture.viewport);
	if (catch built)
	{
		test::@check(false, "the move tool produced no gizmo frame");
		return;
	}
	crig::TransformGizmoFrame frame = built;
	for (int component = 0; component < 3; component++)
	{
		if (!frame.visible_axes[component]) continue;
		Vec2 near_pivot = frame.projected_pivot + frame.screen_axes[component] * 6.0f;
		test::@check(viewport.hit_transform_gizmo(fixture.viewport, near_pivot)
			== crig::TransformGizmoPart.GIZMO_FREE,
			"a press beside the joint on arrow %d locked that axis", component);
	}

	// Press on the joint and pull: a free drag of the joint, not an axis slide.
	Vec2 at = fixture.viewport.absolute + frame.projected_pivot;
	fixture.feed(at);
	fixture.feed(at, left: true);
	fixture.feed(at + (Vec2){ 30, 20 }, left: true);
	test::@check(!fixture.app.transform_interaction.active,
		"pressing the joint started an axis transform instead of dragging the joint");
	test::@check(fixture.app.drag.dot == tip, "pressing the joint under the gizmo did not drag it");
	test::@check(!fixture.app.drag.axis.is_direction() && !fixture.app.drag.axis.is_plane(),
		"the joint drag came with an axis lock");
	fixture.feed(at + (Vec2){ 30, 20 });

	// Arrows still work from their outer part, around where the joint went.
	crig::TransformGizmoFrame? moved = viewport.transform_gizmo_frame(fixture.viewport);
	if (catch moved)
	{
		test::@check(false, "the moved joint lost its gizmo");
		return;
	}
	frame = moved;
	crig::TransformGizmoPart arrow = crig::TransformGizmoPart.NO_GIZMO_PART;
	for (int component = 0; component < 3; component++)
	{
		if (!frame.visible_axes[component]) continue;
		arrow = viewport.hit_transform_gizmo(fixture.viewport,
			frame.projected_pivot + frame.screen_axes[component] * (crig::TRANSFORM_AXIS_LENGTH * 0.8f));
		break;
	}
	test::@check(arrow != crig::TransformGizmoPart.NO_GIZMO_PART
		&& arrow != crig::TransformGizmoPart.GIZMO_FREE,
		"the outer part of an arrow no longer hit-tests");
}

// The furthest any vertex travelled between two arrays of the same mesh.
fn float max_travel(Vec3[] rest, Vec3[] posed)
{
	float worst = 0.0f;
	foreach (i, position : rest)
	{
		float moved = (posed[i] - position).length();
		if (moved > worst) worst = moved;
	}
	return worst;
}

<*
 A displayed animation pose puts the sampled pose on the mesh and takes the rest
 rig away.

 Two claims, and the second is the one with teeth. The picker's BVH is built
 against the mesh at rest and is never rebuilt, so every ray crig casts describes
 the undeformed body. Letting a click place a dot while the body on screen has
 been carried elsewhere would put it exactly where the ray said and nowhere the
 user pointed.
*>
fn void animation_display_skins_and_locks_the_rest_rig() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("an animation display skins the mesh and locks the rest rig");
	fixture.reset();

	fixture.click(SPOT_A);
	fixture.click(SPOT_C);
	if (fixture.doc().dots.len() != 2)
	{
		test::@check(false, "SKIPPED — the two dots did not land");
		return;
	}

	AnimRef clip = fixture.app.new_clip("Lock rest rig", 1.0f, from_rest: true);
	test::@check(fixture.app.park_clip(clip, 0.0f), "the animation would not park");
	test::@check(fixture.app.animating && fixture.app.anim_paused,
		"the chosen animation was not displayed at its first frame");
	test::@check(fixture.app.skinned(), "the renderer is told to skin");
	test::@check(fixture.app.pose_palette.len == 2, "the palette carries one matrix per joint");
	test::@check(fixture.app.posed_dots.len == 2,
		"and the overlay follows the pose — which is what carries the dots, the bones and the pick test");

	// Nothing is posed yet, so every palette entry is the identity and the mesh
	// has to be exactly where it was modelled. This is the cheapest check that
	// the frames agree, and the one that fails if the rest inverse is dropped.
	Vec3[] rest = fixture.app.geometry.positions;
	Vec3[] shown = alloc::new_array(mem, Vec3, (sz)rest.len);
	defer alloc::free(mem, shown);
	if (catch rig::skin_positions(shown, rest, fixture.app.skin, fixture.app.pose_palette))
	{
		test::@check(false, "SKIPPED — the palette and the binding disagree");
		return;
	}
	test::@check(max_travel(rest, shown) < 1.0e-5f, "an unposed rig leaves the mesh exactly at rest");

	// --- the lock ---------------------------------------------------------

	sz before = fixture.doc().dots.len();
	fixture.click(SPOT_B);
	test::@check(fixture.doc().dots.len() == before, "a click on an animated body placed a rest dot");
	test::@check(fixture.notice_text().starts_with("stop the clip"), "and it did not explain why");

	// With a joint selected on Pose, the tool poses it rather than edit the
	// locked rest rig, and says so.
	crig::menu_rotate_tool(fixture.ui);
	test::@check(fixture.notice_text().contains("posing")
		&& crig::hint_line(&fixture.app).contains("posing"),
		"the rotate tool did not offer to pose the joint behind the animation lock");
	crig::Viewport* viewport = fixture.viewport.widget_as(crig::Viewport);
	crig::TransformGizmoFrame? pose_gizmo = viewport.transform_gizmo_frame(fixture.viewport);
	if (catch pose_gizmo) test::@check(false, "the rotate tool showed no rings to pose the joint with");
	fixture.app.select_scene(crig::SceneSelection.MODEL);
	fixture.app.refresh_ui();
	crig::TransformGizmoFrame? model_gizmo = viewport.transform_gizmo_frame(fixture.viewport);
	if (catch model_gizmo)
	{
		test::@check(false,
			"the whole-model rotate gizmo is unavailable while an animation is displayed");
	}

	fixture.app.stop_animation();
	test::@check(fixture.app.pose_palette.len == 0, "and drops the palette, which puts the mesh back");
	test::@check(fixture.app.posed_dots.len == 0, "and the overlay with it");

	crig::menu_tweak(fixture.ui);
	fixture.click(SPOT_B);
	test::@check(fixture.doc().dots.len() > before, "and the rig is editable again on the way out");
}

<*
 A rig with one fork and one two-bone limb hanging off it.

 	hips ─┬─ chest
 	      └─ thigh ── knee ── ankle

 The fork is the whole point: `ancestor_run` from the ankle has to stop at the
 hips, because the hips also carry the chest and turning them to place a foot
 would swing the torso. Built into the document rather than clicked, because
 where these land matters and a click puts a dot wherever the ray finds material.
*>
fn PosedLimb build_limb(Fixture* fixture)
{
	PosedLimb limb;
	limb.hips = fixture.doc().add_dot({ 0, 0.2f, 0 }, "hips");
	limb.chest = fixture.doc().add_dot({ 0, 0.6f, 0 }, "chest");
	limb.thigh = fixture.doc().add_dot({ 0, -0.1f, 0 }, "thigh");
	limb.knee = fixture.doc().add_dot({ 0, -0.4f, 0 }, "knee");
	limb.ankle = fixture.doc().add_dot({ 0, -0.7f, 0 }, "ankle");

	fixture.doc().connect(limb.hips, limb.chest);
	fixture.doc().connect(limb.hips, limb.thigh);
	fixture.doc().connect(limb.thigh, limb.knee);
	fixture.doc().connect(limb.knee, limb.ankle);
	fixture.doc().root_id = limb.hips;

	fixture.app.mark_rig_stale();
	fixture.ui.flush();
	return limb;
}

struct PosedLimb
{
	uint hips, chest, thigh, knee, ankle;
}

<*
 G moves the joint by what the pointer moves, not to the pointer: pressed with
 the pointer beside the joint, the first move leaves it where it is, and the
 next carries it by the pointer's change.
*>
fn void g_moves_the_joint_by_the_pointer_not_to_it() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("G anchors on the pointer, so the joint does not jump to it");
	fixture.reset();

	PosedLimb limb = build_limb(fixture);
	AnimRef clip = fixture.app.new_clip("G anchor", 1.0f, from_rest: true);
	fixture.app.editing = clip;
	fixture.app.auto_key = false;
	test::@check(fixture.app.park_clip(clip, 0.0f), "the clip would not park");
	fixture.app.stop_animation();
	fixture.app.select(limb.ankle);

	Vec2? projected = fixture.pixel_of(limb.ankle);
	if (catch projected)
	{
		test::@check(false, "SKIPPED — the rig did not project");
		return;
	}
	Vec2 beside = { projected.x + 40.0f, projected.y };
	Vec3 ankle_was = fixture.app.dot_position(*fixture.doc().find(limb.ankle));
	fixture.tap(beside, Key.G);
	if (fixture.app.drag.dot != limb.ankle || fixture.app.drag.verb != DragVerb.POSE)
	{
		test::@check(false, "SKIPPED — G did not start a pose gesture (%s)", fixture.notice_text());
		return;
	}
	fixture.feed(beside);
	fixture.feed({ beside.x + 1.0f, beside.y });
	Vec3 after_small = fixture.app.dot_position(*fixture.doc().find(limb.ankle));
	test::@check((after_small - ankle_was).length() < 0.02f,
		"a one-pixel move carried the ankle %.3f — it jumped to the pointer", (after_small - ankle_was).length());

	for (usz i = 0; i < 6; i++) fixture.feed({ beside.x + 1.0f, beside.y - 30.0f });
	Vec3 after = fixture.app.dot_position(*fixture.doc().find(limb.ankle));
	test::@check(after.y > ankle_was.y + 0.01f, "moving the pointer up did not carry the ankle up");
	(void)fixture.app.cancel_drag();
}

<*
 G bends the limb, and the fork above it barely moves.

 The claim the whole feature rests on: grabbing a foot turns the knee and the
 thigh, and the hips — which the other limb hangs off — join in only by their
 weight. The whole body is in every solve, so a foot pulled out of the leg's
 reach would bring the hips; one the leg can reach on its own leaves them nearly
 where they were, and only this check would notice a solver that swung the
 chest instead.

 **Two mouse moves, not one.** From rest every joint's world rotation is the
 identity, so a conversion that forgot to divide by the parent's rotation is
 exactly right on the first move and wrong on every one after it. One move would
 pass over that bug completely.
*>
fn void posing_bends_the_limb_and_barely_moves_the_fork() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("G bends the limb above the grabbed joint and barely moves the fork");
	fixture.reset();

	PosedLimb limb = build_limb(fixture);
	AnimRef clip = fixture.app.new_clip("IK gesture", 1.0f, from_rest: true);
	fixture.app.editing = clip;
	fixture.app.auto_key = false;
	test::@check(fixture.app.park_clip(clip, 0.0f), "the IK clip would not park");
	fixture.app.stop_animation();
	test::@check(fixture.app.animation_pose_ready(),
		"stopping preview also disabled regular-view posing");
	fixture.app.select(limb.ankle);

	Vec2? projected = fixture.pixel_of(limb.ankle);
	if (catch projected)
	{
		test::@check(false, "SKIPPED — the rig did not project");
		return;
	}
	Vec2 aimed = projected;
	Vec3 hips_was = fixture.app.dot_position(*fixture.doc().find(limb.hips));
	Vec3 ankle_was = fixture.app.dot_position(*fixture.doc().find(limb.ankle));

	fixture.tap(aimed, Key.G);
	if (fixture.app.drag.dot != limb.ankle || fixture.app.drag.verb != DragVerb.POSE)
	{
		test::@check(false, "SKIPPED — G did not start a pose gesture (%s)", fixture.notice_text());
		return;
	}

	// Sideways and up, in several steps. Several rather than one because the
	// per-sweep clamp rations how far a pivot may turn in a frame — a drag is
	// meant to be walked, not teleported — and because of the two-move rule above.
	// Alt held throughout: the grabbed joint keeps its world angle.
	Vec2 target = { aimed.x + 40.0f, aimed.y - 20.0f };
	Key[1] hold_alt = { Key.LEFT_ALT };
	for (usz i = 0; i < 6; i++) fixture.feed(target, keys: hold_alt[..]);
	fixture.feed(target, left: true, keys: hold_alt[..]);
	fixture.feed(target, keys: hold_alt[..]);
	fixture.feed(target);

	// --- who moved --------------------------------------------------------

	test::@check(fixture.app.working_pose(limb.thigh).rotation.v[3] != 1.0f, "the thigh did not turn");
	test::@check(fixture.app.working_pose(limb.knee).rotation.v[3] != 1.0f, "the knee did not turn");
	// With Alt the grabbed joint keeps the angle it faced, softly, rather than being
	// left to turn with the shin: its own turn is whatever cancels the leg's, so in
	// the world it has not moved from the identity it began with (a degree or two).
	test::@check(math::abs(fixture.app.dot_world_rotation(limb.ankle).v[3]) > 0.9998f,
		"with Alt the grabbed joint did not keep its angle — it turned with the limb");

	Vec3 hips_now = fixture.app.dot_position(*fixture.doc().find(limb.hips));
	Vec3 ankle_now = fixture.app.dot_position(*fixture.doc().find(limb.ankle));

	test::@check((ankle_now - ankle_was).length() > 0.05f,
		"the grabbed joint only travelled %.5f", (ankle_now - ankle_was).length());
	test::@check((hips_now - hips_was).length() < (ankle_now - ankle_was).length() * 0.1f,
		"the fork moved %.5f, against the foot's %.5f", (hips_now - hips_was).length(), (ankle_now - ankle_was).length());

	// --- and it arrived where the pointer was -----------------------------
	//
	// The promise IK actually makes, and the assertion with teeth in it. A
	// conversion that treats the solver's world rotations as if they were local
	// still turns the thigh and the knee, still leaves the hips alone, and still
	// moves the foot — it just moves it somewhere else. Only this notices.
	Vec2? arrived = fixture.pixel_of(limb.ankle);
	if (catch arrived)
	{
		test::@check(false, "SKIPPED — the posed ankle did not project");
		return;
	}
	test::@check((arrived - target).length() < 8.0f,
		"the pointer was at %s and the joint landed at %s", target, arrived);

	// --- one solve, from a limb that is already bent ----------------------
	//
	// Everything above survives a conversion that treats the solver's world
	// rotations as if they were the parent-relative ones crig stores. It has to:
	// each frame re-reads the joints' real positions and solves again from there,
	// so a wrong conversion is corrected by the next frame and the drag still
	// converges. What it corrupts is the single step.
	//
	// So this asks for one. The limb above is bent, so the knee's parent now
	// carries a real rotation and dividing by it is no longer a no-op — and one
	// mouse move has to land the joint on the pointer by itself.
	Vec2 again = { target.x - 30.0f, target.y - 15.0f };
	fixture.tap(target, Key.G);
	if (fixture.app.drag.dot != limb.ankle)
	{
		test::@check(false, "SKIPPED — the second gesture did not start");
		return;
	}
	Quaternionf own = fixture.app.working_pose(limb.ankle).rotation;
	Quaternionf faced = fixture.app.dot_world_rotation(limb.ankle);
	fixture.feed(again);

	// Without Alt the joint is a limb's, so it keeps its angle to its parent and
	// turns with the shin: its own turn stays as the last gesture left it, and in
	// the world it has turned with the leg.
	Quaternionf own_now = fixture.app.working_pose(limb.ankle).rotation;
	test::@check(math::abs(own_now.v.dot(own.v)) > 0.99999f,
		"without Alt the grabbed joint turned against its parent instead of riding the limb");
	test::@check(math::abs(fixture.app.dot_world_rotation(limb.ankle).v.dot(faced.v)) < 0.9999f,
		"without Alt the grabbed joint kept its world angle — it did not turn with the limb");

	Vec2? single = fixture.pixel_of(limb.ankle);
	if (catch single)
	{
		test::@check(false, "SKIPPED — the ankle did not project after one move");
		return;
	}
	test::@check((single - again).length() < 8.0f,
		"one solve on a bent limb put the joint at %s with the pointer at %s", single, again);
	(void)fixture.app.cancel_drag();

	// --- and the mesh went with it ----------------------------------------

	Vec3[] rest = fixture.app.geometry.positions;
	Vec3[] shown = alloc::new_array(mem, Vec3, (sz)rest.len);
	defer alloc::free(mem, shown);
	if (catch rig::skin_positions(shown, rest, fixture.app.skin, fixture.app.pose_palette))
	{
		test::@check(false, "SKIPPED — the palette and the binding disagree");
		return;
	}

	// Something moved, and nothing moved further than the joint that was dragged.
	// The second half is what a palette that scaled instead of rotating would
	// fail: it would move the mesh, which is all a "something moved" check asks.
	float carried = max_travel(rest, shown);
	test::@check(carried > 0.01f, "the mesh did not follow the pose (%.5f)", carried);
	test::@check(carried < (ankle_now - ankle_was).length() * 3.0f,
		"the mesh travelled %.4f where the joint went %.4f — the palette is not a rotation",
		carried, (ankle_now - ankle_was).length());
}

<*
 On the posing stage a dot drag poses the joint, and never edits the rest dot.

 The drag a user means as a pose must not fall through into a rest-rig move —
 that was the footgun: forgetting G moved the rest skeleton and lost the pose.
 A drag runs the same IK as G, with Alt held too; the rest skeleton is edited on
 Joints.
*>
fn void dragging_a_joint_poses_it_and_never_edits_the_rest_dot() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("a drag poses the joint; Pose never edits the rest dot");
	fixture.reset();

	PosedLimb limb = build_limb(fixture);
	AnimRef clip = fixture.app.new_clip("direct_timeline_pose", 1.0f, from_rest: true);
	if (!clip.valid())
	{
		test::@check(false, "the animation fixture could not create a clip");
		return;
	}
	fixture.app.edit_time = 0.25f;
	test::@check(fixture.app.park_clip(clip, fixture.app.edit_time), "the clip would not park");
	test::@check(fixture.app.animation_pose_ready(), "the selected animation was not pose-ready");
	fixture.app.select(0);

	Vec2? projected = fixture.pixel_of(limb.ankle);
	if (catch projected)
	{
		test::@check(false, "SKIPPED — the ankle did not project");
		return;
	}
	Vec2 target = { projected.x + 40.0f, projected.y - 20.0f };

	// --- a bare drag poses the joint, leaving the rest dot where it was ----
	// Several move frames, not one: the per-sweep clamp rations how far a pivot
	// turns per frame, the same reason `posing_bends_the_limb_and_holds_the_fork`
	// walks its drag. The release keys the pose (auto_key), closing the draft.
	usz keys_before = fixture.app.clip(clip).keyframes.len;
	Vec3 rest_before = fixture.doc().find(limb.ankle).position;
	Vec3 ankle_before = fixture.app.dot_position(*fixture.doc().find(limb.ankle));
	fixture.feed(projected);
	fixture.feed(projected, left: true);
	for (usz i = 0; i < 6; i++) fixture.feed(target, left: true);
	fixture.feed(target);

	test::@check(fixture.app.selected == limb.ankle, "the direct drag did not select the ankle");
	test::@check((fixture.doc().find(limb.ankle).position - rest_before).length() < 0.005f,
		"the bare drag moved the rest-rig dot; it should have posed the joint instead");
	usz keys_after = fixture.app.clip(clip).keyframes.len;
	test::@check(keys_after > keys_before,
		"the bare drag recorded no animation key (%d → %d) — it did not pose",
		keys_before, keys_after);
	Vec3 ankle_posed = fixture.app.dot_position(*fixture.doc().find(limb.ankle));
	test::@check((ankle_posed - ankle_before).length() > 0.01f,
		"the bare drag did not move the posed joint (%.5f) — IK did not run",
		(ankle_posed - ankle_before).length());

	// --- an Alt-drag poses too: Pose never edits the rest dot ----
	Vec2? posed_px = fixture.pixel_of(limb.ankle);
	if (catch posed_px)
	{
		test::@check(false, "SKIPPED — the posed ankle did not project");
		return;
	}
	Vec3 rest_pinned = fixture.doc().find(limb.ankle).position;
	Vec2 rest_target = { posed_px.x - 35.0f, posed_px.y + 15.0f };
	fixture.alt_drag(posed_px, rest_target);

	test::@check((fixture.doc().find(limb.ankle).position - rest_pinned).length() < 0.005f,
		"the Alt-drag moved the rest-rig dot on Pose");
	test::@check(fixture.app.clip(clip).keyframes.len >= keys_after,
		"the Alt-drag threw the posed animation away");
}

<*
 On Pose, the Move tool's arrow poses the joint: dragging the hips' up arrow
 lifts the whole figure in the clip — a jump — and edits nothing in the rest rig.

 The user's case: the tool refused joints while posing and pointed at Model,
 which moves the character in the scene and is not keyed into the clip. The
 joint moves by what the pointer moves, not out to the arrow tip it was grabbed by.
*>
fn void the_move_arrow_on_the_hips_lifts_the_pose() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("the Move tool's arrow on the hips lifts the pose");
	fixture.reset();

	PosedLimb limb = build_limb(fixture);
	AnimRef clip = fixture.app.new_clip("jump", 1.0f, from_rest: true);
	test::@check(clip.valid(), "the clip could not be made");
	test::@check(fixture.app.park_clip(clip, 0.0f), "the clip would not park");
	test::@check(fixture.app.animation_pose_ready(), "the clip was not pose-ready");
	fixture.app.select(limb.hips);
	fixture.app.refresh_ui();

	crig::Viewport* viewport = fixture.viewport.widget_as(crig::Viewport);
	crig::menu_move_tool(fixture.ui);
	fixture.feed(VIEWPORT_CENTER);
	crig::TransformGizmoFrame? built = viewport.transform_gizmo_frame(fixture.viewport);
	if (catch built)
	{
		test::@check(false, "the Move tool showed no arrows while posing");
		return;
	}
	crig::TransformGizmoFrame frame = built;
	test::@check(frame.visible_axes[1], "the up arrow is edge-on");

	Vec3 hips_before = fixture.app.dot_position(*fixture.doc().find(limb.hips));
	Vec3 ankle_before = fixture.app.dot_position(*fixture.doc().find(limb.ankle));
	Vec3 rest_before = fixture.doc().find(limb.hips).position;

	Vec2 grab = fixture.viewport.absolute + frame.projected_pivot
		+ frame.screen_axes[1] * (crig::TRANSFORM_AXIS_LENGTH * 0.78f);
	test::eq(viewport.hit_transform_gizmo(fixture.viewport, grab - fixture.viewport.absolute),
		crig::TransformGizmoPart.GIZMO_Y);
	Vec2 lifted = grab + frame.screen_axes[1] * 30.0f;
	fixture.feed(grab);
	fixture.feed(grab, left: true);
	// The press alone moves nothing: the arrow tip is not where the joint goes.
	Vec3 pressed = fixture.app.dot_position(*fixture.doc().find(limb.hips));
	test::@check((pressed - hips_before).length() < 1.0e-4f,
		"pressing the arrow jumped the hips %.4f", (pressed - hips_before).length());
	for (usz i = 0; i < 4; i++) fixture.feed(lifted, left: true);
	fixture.feed(lifted);

	Vec3 hips_after = fixture.app.dot_position(*fixture.doc().find(limb.hips));
	Vec3 ankle_after = fixture.app.dot_position(*fixture.doc().find(limb.ankle));
	Vec3 rose = hips_after - hips_before;
	test::@check(rose.y > 0.02f, "the hips did not rise (%s)", rose);
	test::@check(math::abs(rose.x) < 1.0e-3f && math::abs(rose.z) < 1.0e-3f,
		"the up arrow moved the hips sideways (%s)", rose);
	test::@check(((ankle_after - ankle_before) - rose).length() < 1.0e-3f,
		"the foot did not rise with the hips (%s vs %s)", ankle_after - ankle_before, rose);
	test::@check((fixture.doc().find(limb.hips).position - rest_before).length() < 1.0e-6f,
		"the arrow moved the rest-rig hips");
	// Keyed into the clip: parked afresh, the frame still stands lifted.
	test::@check(!fixture.app.pose_edit_pending, "the lift was left pending, not keyed");
	test::@check(fixture.app.park_clip(clip, 0.0f), "the clip would not park again");
	Vec3 replayed = fixture.app.dot_position(*fixture.doc().find(limb.hips));
	test::@check((replayed - hips_after).length() < 1.0e-3f,
		"the clip plays the hips at %s, not the lifted %s", replayed, hips_after);
}

<*
 The header's Joints | Pose switch: with an animation on the character, Joints
 goes back to moving joints on the model and Pose comes back to the clip.

 The user's case: once a clip was added every drag posed, and moving a joint on
 the model again was a modifier nobody could find.
*>
fn void the_header_switch_moves_joints_or_poses_them() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("the Joints | Pose switch chooses what a joint drag changes");
	fixture.reset();

	PosedLimb limb = build_limb(fixture);
	AnimRef clip = fixture.app.new_clip("stage_switch", 1.0f, from_rest: true);
	if (!clip.valid())
	{
		test::@check(false, "the animation fixture could not create a clip");
		return;
	}
	fixture.app.edit_time = 0.25f;
	test::@check(fixture.app.park_clip(clip, fixture.app.edit_time), "the clip would not park");
	fixture.app.select(0);
	fixture.feed(VIEWPORT_CENTER);

	Element*? found = fixture.ui.find_id(crig::STAGE_SWITCH_ID);
	if (catch found)
	{
		test::@check(false, "the 3D view header has no Joints | Pose switch");
		return;
	}
	Element* strip = found;
	Vec2 joints_at = strip.absolute + (Vec2){ strip.size.x * 0.25f, strip.size.y * 0.5f };
	Vec2 pose_at = strip.absolute + (Vec2){ strip.size.x * 0.8f, strip.size.y * 0.5f };
	test::@check(fixture.app.stage == crig::EditStage.POSE_STAGE, "a clip on show did not move the switch to Pose");
	test::@check(strip.widget_as(Segmented).selected == 1, "the switch is not lit on Pose");

	// --- Joints: the clip leaves the model, and a bare drag moves the joint ---
	fixture.click(joints_at);
	test::@check(fixture.app.stage == crig::EditStage.JOINTS_STAGE, "clicking Joints did not switch");
	test::@check(!fixture.app.animating && !fixture.app.pose_edit_active, "the model still shows the pose on Joints");
	test::@check(fixture.app.editing.same(clip), "leaving Pose let go of the animation");
	fixture.feed(VIEWPORT_CENTER);
	test::@check(strip.widget_as(Segmented).selected == 0, "the switch is not lit on Joints");

	Vec2 at = fixture.pixel_of(limb.ankle)!!;
	Vec3 rest_before = fixture.doc().find(limb.ankle).position;
	usz keys_before = fixture.app.clip(clip).keyframes.len;
	fixture.drag(at, at + (Vec2){ 30, -15 });
	test::@check((fixture.doc().find(limb.ankle).position - rest_before).length() > 0.005f,
		"a bare drag on Joints did not move the joint");
	test::@check(fixture.app.clip(clip).keyframes.len == keys_before, "a joint move on Joints keyed the animation");
	test::@check(fixture.app.undo(), "the move did not undo");

	// --- Pose: the clip comes back, and a bare drag poses ---
	fixture.click(pose_at);
	test::@check(fixture.app.stage == crig::EditStage.POSE_STAGE, "clicking Pose did not switch");
	test::@check(fixture.app.animating && fixture.app.current_ref.same(fixture.app.editing),
		"Pose did not put the animation back on show");

	fixture.app.auto_key = false;
	Vec2 from = fixture.pixel_of(limb.ankle)!!;
	Vec2 target = { from.x + 40.0f, from.y - 20.0f };
	fixture.feed(from);
	fixture.feed(from, left: true);
	for (usz i = 0; i < 6; i++) fixture.feed(target, left: true);
	fixture.feed(target);
	test::@check((fixture.doc().find(limb.ankle).position - rest_before).length() < 0.005f,
		"a bare drag on Pose moved the joint on the model");
	test::@check(fixture.app.pose_edit_pending, "a bare drag on Pose did not pose");

	// A changed, unkeyed pose holds the switch on Pose rather than being lost.
	fixture.click(joints_at);
	test::@check(fixture.app.stage == crig::EditStage.POSE_STAGE && fixture.app.pose_edit_pending,
		"Joints threw away an unkeyed pose");
	fixture.app.discard_pose_edit();
	fixture.click(joints_at);
	test::@check(fixture.app.stage == crig::EditStage.JOINTS_STAGE, "Joints refused once the pose was reverted");
}

<*
 Several joints selected, one Alt-drag carries them all — the rest positions move
 as one rigid piece and undo takes the whole group back in a single step.

 The grabbed joint leads and snaps through the mesh; every other selected joint
 translates by the same delta. This is the multi-select half of the Alt-move
 gesture: a bare drag still poses one joint, and Alt still means "move the rest
 dot", but now it moves the whole selection at once. A joint outside the set is
 left where it is.
*>
fn void an_alt_drag_moves_the_whole_selection() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("an Alt-drag moves every selected joint as one rigid group");
	fixture.reset();

	PosedLimb limb = build_limb(fixture);

	// Three joints picked out as a set; the knee is the one the pointer grabs.
	fixture.app.select(limb.thigh);
	fixture.app.extend_selection(limb.knee);
	fixture.app.extend_selection(limb.ankle);
	test::eq(fixture.app.selection_count(), (usz)3);

	Vec2? grab = fixture.pixel_of(limb.knee);
	if (catch grab)
	{
		test::@check(false, "SKIPPED — the knee did not project");
		return;
	}

	Vec3 thigh_before = fixture.doc().find(limb.thigh).position;
	Vec3 knee_before  = fixture.doc().find(limb.knee).position;
	Vec3 ankle_before = fixture.doc().find(limb.ankle).position;
	// The hips are in neither the anchor nor the rest of the set — they must not move.
	Vec3 hips_before  = fixture.doc().find(limb.hips).position;

	fixture.alt_drag(grab, { grab.x + DRAG_PIXELS, grab.y - 20.0f });

	Vec3 knee_delta  = fixture.doc().find(limb.knee).position - knee_before;
	Vec3 thigh_delta = fixture.doc().find(limb.thigh).position - thigh_before;
	Vec3 ankle_delta = fixture.doc().find(limb.ankle).position - ankle_before;

	test::@check(knee_delta.length() > 0.01f,
		"the grabbed knee did not move (%.5f)", knee_delta.length());
	test::@check((thigh_delta - knee_delta).length() < 1.0e-4f,
		"the thigh did not follow the group rigidly (delta off by %.5f)",
		(thigh_delta - knee_delta).length());
	test::@check((ankle_delta - knee_delta).length() < 1.0e-4f,
		"the ankle did not follow the group rigidly (delta off by %.5f)",
		(ankle_delta - knee_delta).length());
	test::@check((fixture.doc().find(limb.hips).position - hips_before).length() == 0.0f,
		"an unselected joint moved with the group");

	// One undo takes the whole slab back, not three.
	test::@check(fixture.app.undo(), "the group move left nothing on the ledger");
	test::@check((fixture.doc().find(limb.thigh).position - thigh_before).length() == 0.0f
		&& (fixture.doc().find(limb.knee).position - knee_before).length() == 0.0f
		&& (fixture.doc().find(limb.ankle).position - ankle_before).length() == 0.0f,
		"one undo did not restore the whole group");
	test::@check(!fixture.app.undo(), "the group move was more than one edit on the ledger");
}

<*
 A plain click on a joint that is part of a multi-selection collapses the set to
 just that joint.

 The press keeps the group alive so an Alt-drag *could* move it as one; when no
 drag follows, the click means "select this one" after all — the same thing a
 click on any single dot has always meant. So the group is sticky only for the
 length of one press-that-becomes-a-drag, never longer.
*>
fn void a_click_on_a_group_member_keeps_only_it() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("a plain click on a member of a selected group keeps only that joint");
	fixture.reset();

	PosedLimb limb = build_limb(fixture);

	fixture.app.select(limb.thigh);
	fixture.app.extend_selection(limb.knee);
	fixture.app.extend_selection(limb.ankle);
	test::eq(fixture.app.selection_count(), (usz)3);

	Vec2? at = fixture.pixel_of(limb.knee);
	if (catch at)
	{
		test::@check(false, "SKIPPED — the knee did not project");
		return;
	}

	Vec3 knee_before = fixture.doc().find(limb.knee).position;
	fixture.click(at);

	test::eq(fixture.app.selection_count(), (usz)1);
	test::@check(fixture.app.selected == limb.knee,
		"the click did not collapse the selection onto the clicked joint");
	test::@check((fixture.doc().find(limb.knee).position - knee_before).length() == 0.0f,
		"a click with no travel moved a joint");
	test::@check(!fixture.app.undo(), "a click that only selected still recorded an edit");
}

<*
 Moving a joint's rest dot no longer drops the mesh out of a parked clip's pose.

 The old behaviour stopped the clip and put the body back at rest the instant an
 Alt-drag began, so editing a joint threw away the pose the user was looking at.
 Now the parked clip stays up and re-solves against the edited rig — the mesh
 keeps its pose while the skeleton is shaped under it — and not one keyframe is
 touched.
*>
fn void an_alt_rest_move_keeps_a_parked_clip_posed() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("an Alt rest-move keeps the mesh in a parked clip's pose");
	fixture.reset();

	PosedLimb limb = build_limb(fixture);
	AnimRef clip = fixture.app.new_clip("hold_pose", 1.0f, from_rest: true);
	if (!clip.valid())
	{
		test::@check(false, "the animation fixture could not create a clip");
		return;
	}
	fixture.app.edit_time = 0.25f;
	test::@check(fixture.app.park_clip(clip, fixture.app.edit_time), "the clip would not park");
	test::@check(fixture.app.skinned(), "a parked clip should pose the mesh");
	usz keys_before = fixture.app.clip(clip).keyframes.len;

	Vec2? grab = fixture.pixel_of(limb.knee);
	if (catch grab)
	{
		test::@check(false, "SKIPPED — the knee did not project");
		return;
	}
	Vec3 rest_before = fixture.doc().find(limb.knee).position;

	// The rest rig is edited on Joints.
	fixture.app.stage = crig::EditStage.JOINTS_STAGE;
	fixture.alt_drag(grab, { grab.x + DRAG_PIXELS, grab.y - 15.0f });

	test::@check(fixture.app.skinned(), "the Alt rest-move dropped the mesh out of its pose");
	test::@check(fixture.app.animating, "the Alt rest-move stopped the parked clip");
	test::@check((fixture.doc().find(limb.knee).position - rest_before).length() > 0.01f,
		"the Alt-drag did not move the rest dot");
	usz keys_after = fixture.app.clip(clip).keyframes.len;
	test::@check(keys_after == keys_before, "the rest edit changed the clip: %d keys, was %d", (int)keys_after, (int)keys_before);
}

<*
 The Rest pose button returns the mesh to its default shape and leaves the clip
 alone — the deliberate way to the default pose now that editing a joint keeps
 the pose up.
*>
fn void reset_pose_returns_to_default_without_touching_the_clip() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("Rest pose returns the mesh to rest without changing the clip");
	fixture.reset();

	PosedLimb limb = build_limb(fixture);
	AnimRef clip = fixture.app.new_clip("hold_pose", 1.0f, from_rest: true);
	if (!clip.valid())
	{
		test::@check(false, "the animation fixture could not create a clip");
		return;
	}
	fixture.app.bind_ref(clip);
	fixture.app.editing = clip;
	fixture.app.edit_time = 0.25f;
	test::@check(fixture.app.park_clip(clip, fixture.app.edit_time), "the clip would not park");
	fixture.ui.flush();
	test::@check(fixture.app.skinned(), "a parked clip should pose the mesh");
	usz keys_before = fixture.app.clip(clip).keyframes.len;

	// The Rest pose button lives in the Pose tab of the N-panel; bring it up.
	fixture.open_pose_tab();

	Vec2? reset = fixture.center_of("anim-reset-pose");
	if (catch reset)
	{
		test::@check(false, "SKIPPED — the anim panel has no Rest pose button");
		return;
	}
	fixture.click(reset);
	fixture.ui.flush();

	test::@check(!fixture.app.skinned(), "Rest pose left the mesh deformed");
	usz keys_after = fixture.app.clip(clip).keyframes.len;
	test::@check(keys_after == keys_before, "the rest edit changed the clip: %d keys, was %d", (int)keys_after, (int)keys_before);
}

<*
 N hides and shows the joint panel, the way Blender's N-panel key does — the card
 is up by default and toggles off even while a joint is selected.
*>
fn void n_hides_and_shows_the_joint_panel() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("N hides and shows the joint panel");
	fixture.reset();

	fixture.click(SPOT_B);
	uint id = fixture.app.selected;
	test::@check(id != 0, "the click placed no dot to select");
	fixture.app.select(id);
	fixture.ui.flush();

	test::@check(fixture.app.show_joint_panel, "the joint panel is on by default");
	test::@check(fixture.in_tree(crig::JOINT_RENAME_ID), "a selected joint shows the panel by default");

	fixture.feed_key(Key.N);
	fixture.ui.flush();
	test::@check(!fixture.app.show_joint_panel, "N did not flip the joint-panel flag off");
	test::@check(!fixture.in_tree(crig::JOINT_RENAME_ID), "hiding the joint panel left its contents up");
	test::@check(fixture.in_tree(crig::JOINT_TAB_JOINT_ID) && fixture.in_tree(crig::JOINT_TAB_ALIGN_ID),
		"hiding the joint panel also removed its category rail");

	fixture.feed_key(Key.N);
	fixture.ui.flush();
	test::@check(fixture.app.show_joint_panel, "N did not bring the joint panel back");
	test::@check(fixture.in_tree(crig::JOINT_RENAME_ID), "showing the joint panel did not restore its contents");
}

<*
 Joint and Align are Blender-style category tabs stacked down the right edge.
 Selecting one replaces the body; clicking the active tab closes that body but
 leaves the rail available to reopen either category.
*>
fn void the_joint_panel_has_vertical_category_tabs() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("the joint panel has vertical Joint and Align category tabs");
	fixture.reset();

	// Two placed dots, selected as a pair, so Joint has a card and Align offers
	// X/Y/Z when its tab is selected.
	fixture.click(SPOT_A);
	uint a = fixture.app.selected;
	fixture.click(SPOT_B);
	uint b = fixture.app.selected;
	test::@check(a != 0 && b != 0 && a != b, "the two clicks did not place two dots");
	if (a == 0 || b == 0 || a == b) return;
	fixture.app.select(a);
	fixture.app.extend_selection(b);
	fixture.idle_frame();
	fixture.ui.flush();

	Element*? joint_tab = fixture.ui.find_id(crig::JOINT_TAB_JOINT_ID);
	Element*? align_tab = fixture.ui.find_id(crig::JOINT_TAB_ALIGN_ID);
	if (catch joint_tab) { test::@check(false, "the sidebar has no Joint tab"); return; }
	if (catch align_tab) { test::@check(false, "the sidebar has no Align tab"); return; }
	test::@check(align_tab.absolute.y > joint_tab.absolute.y && align_tab.absolute.x == joint_tab.absolute.x,
		"the sidebar tabs are not stacked vertically");
	test::@check(fixture.app.joint_panel_tab == crig::JointPanelTab.JOINT,
		"a fresh sidebar did not select Joint");
	test::@check(fixture.in_tree(crig::JOINT_SECTION_ID) && fixture.in_tree(crig::JOINT_RENAME_ID),
		"the Joint tab does not show the joint panel");
	test::@check(!fixture.in_tree(crig::ALIGN_SECTION_ID) && !fixture.in_tree("joint-align-x"),
		"Align is visible before its tab is selected");

	// Align replaces Joint without closing the sidebar.
	fixture.click(align_tab.absolute + align_tab.size * 0.5f);
	fixture.ui.flush();
	test::@check(fixture.app.show_joint_panel && fixture.app.joint_panel_tab == crig::JointPanelTab.ALIGN,
		"clicking Align did not select its category");
	test::@check(fixture.in_tree(crig::ALIGN_SECTION_ID) && fixture.in_tree("joint-align-x"),
		"the Align tab does not show its tools");
	test::@check(!fixture.in_tree(crig::JOINT_SECTION_ID) && !fixture.in_tree(crig::JOINT_RENAME_ID),
		"the Joint body stayed visible under Align");

	// Clicking the active tab closes only the body. Both little tabs remain.
	align_tab = fixture.ui.find_id(crig::JOINT_TAB_ALIGN_ID)!!;
	fixture.click(align_tab.absolute + align_tab.size * 0.5f);
	fixture.ui.flush();
	test::@check(!fixture.app.show_joint_panel, "clicking the active Align tab did not close the sidebar body");
	test::@check(!fixture.in_tree(crig::ALIGN_SECTION_ID)
		&& fixture.in_tree(crig::JOINT_TAB_JOINT_ID) && fixture.in_tree(crig::JOINT_TAB_ALIGN_ID),
		"closing the body also removed the tab rail");

	// A different tab opens directly onto its own panel.
	joint_tab = fixture.ui.find_id(crig::JOINT_TAB_JOINT_ID)!!;
	fixture.click(joint_tab.absolute + joint_tab.size * 0.5f);
	fixture.ui.flush();
	test::@check(fixture.app.show_joint_panel && fixture.app.joint_panel_tab == crig::JointPanelTab.JOINT
		&& fixture.in_tree(crig::JOINT_RENAME_ID), "Joint did not reopen its own panel");

	// Return to Align and prove its action still works.
	align_tab = fixture.ui.find_id(crig::JOINT_TAB_ALIGN_ID)!!;
	fixture.click(align_tab.absolute + align_tab.size * 0.5f);
	fixture.ui.flush();

	float ax = fixture.doc().find(a).position.x;
	Vec2? xbtn = fixture.center_of("joint-align-x");
	if (catch xbtn) { test::@check(false, "SKIPPED — no Align X button"); return; }
	fixture.click(xbtn);
	fixture.ui.flush();
	test::@check(fixture.doc().find(b).position.x == ax,
		"clicking Align X did not line the second dot up on the anchor's X");

}

<*
 Align X/Y/Z lines the rest of the selection up with the anchor on one axis,
 leaving the other two coordinates and the anchor itself alone, as one undo.
*>
fn void align_lines_the_selection_up_with_the_anchor() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("Align X lines the selection up with the anchor's X");
	fixture.reset();

	uint a = fixture.app.add_recorded({ 0.10f, 0.20f, 0.05f }, "a");
	uint b = fixture.app.add_recorded({ -0.20f, 0.40f, -0.10f }, "b");
	uint c = fixture.app.add_recorded({ 0.30f, -0.10f, 0.20f }, "c");
	fixture.app.undo_stack.commit();

	fixture.app.select(a);
	fixture.app.extend_selection(b);
	fixture.app.extend_selection(c);

	Vec3 a_before = fixture.doc().find(a).position;
	Vec3 b_before = fixture.doc().find(b).position;
	Vec3 c_before = fixture.doc().find(c).position;
	float ax = a_before.x;

	usz moved = fixture.app.align_selection_to_anchor(0);
	test::eq(moved, (usz)2);

	test::@check(fixture.doc().find(a).position == a_before, "the anchor moved when aligning to it");
	Vec3 b_now = fixture.doc().find(b).position;
	Vec3 c_now = fixture.doc().find(c).position;
	test::@check(b_now.x == ax && b_now.y == b_before.y && b_now.z == b_before.z,
		"b did not take the anchor's X on X only");
	test::@check(c_now.x == ax && c_now.y == c_before.y && c_now.z == c_before.z,
		"c did not take the anchor's X on X only");

	test::@check(fixture.app.undo(), "the align left nothing on the ledger");
	test::@check(fixture.doc().find(b).position == b_before && fixture.doc().find(c).position == c_before,
		"one undo did not restore both aligned joints");

	// One joint selected: there is nothing to align to, so it is a no-op.
	fixture.app.select(a);
	test::eq(fixture.app.align_selection_to_anchor(1), (usz)0);
}

// Where the clip being edited puts `dot` at the playhead.
fn Vec3 posed_at_playhead(crig::AppState* app, uint dot)
{
	crig::RigView view = app.open_rig(mem)!!;
	defer view.free(mem);
	rig::Pose pose = app.evaluated_clip_pose(mem, &view, *app.clip(app.editing), app.editing, app.edit_time, false);
	defer pose.free(mem);
	Matrix4f[] palette = rig::joint_palette(mem, &view.skeleton, pose)!!;
	defer alloc::free(mem, palette);
	usz joint = (usz)view.joint_of(dot);
	return view.skeleton.joints[joint].transform(palette[joint]);
}

<*
 On Pose, the Align tab's X lines the posed neck, head and head top up by
 turning bones in the clip, and leaves the joints on the model where they are —
 the rig is built straight, so moving them would do nothing for the lean.
*>
fn void align_on_pose_turns_the_clip_not_the_model() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("Align X on Pose lines the leaning head up in the clip");
	fixture.reset();
	if (!fixture.app.apply_plan_named("biped"))
	{
		test::@check(false, "SKIPPED — the biped plan could not be fitted to the cube");
		return;
	}
	uint neck, head, top;
	foreach (dot : fixture.doc().dots.array_view())
	{
		if (dot.name == "neck") neck = dot.id;
		if (dot.name == "head") head = dot.id;
		if (dot.name == "head_top") top = dot.id;
	}
	if (neck == 0 || head == 0 || top == 0)
	{
		test::@check(false, "SKIPPED — the fitted plan has no neck, head and head_top");
		return;
	}

	AnimRef ref = fixture.app.new_clip("lean", 1.0f, from_rest: true);
	test::@check(ref.valid(), "a clip could not be started");
	if (!ref.valid()) return;
	fixture.app.editing = ref;
	Vec3 z = { 0, 0, 1 };
	test::@check(fixture.app.pose_from_clip(ref, 0.0f)
		&& fixture.app.set_working_pose(neck, quaternion::from_axis_angle{float}(z, 0.35f), {}), "could not lean the neck");
	fixture.app.pose_edit_pending = true;
	test::@check(fixture.app.key_pose_edit(), "the lean was not keyed");
	fixture.app.stop_animation();
	fixture.app.edit_time = 0.0f;
	fixture.app.stage = crig::EditStage.POSE_STAGE;
	fixture.app.select(neck);
	fixture.app.extend_selection(head);
	fixture.app.extend_selection(top);
	fixture.app.show_joint_panel = true;
	fixture.app.joint_panel_tab = crig::JointPanelTab.ALIGN;
	fixture.idle_frame();
	fixture.ui.flush();

	Vec3 head_rest = fixture.doc().find(head).position;
	Vec3 top_rest = fixture.doc().find(top).position;
	float before = posed_at_playhead(&fixture.app, head).x - posed_at_playhead(&fixture.app, neck).x;
	test::@check(math::abs(before) > 0.01f, "the keyed lean does not move the head off the neck's X");

	Vec2? xbtn = fixture.center_of("joint-align-x");
	if (catch xbtn) { test::@check(false, "no Align X button on Pose"); return; }
	fixture.click(xbtn);
	fixture.ui.flush();

	float neck_x = posed_at_playhead(&fixture.app, neck).x;
	test::@check(math::abs(posed_at_playhead(&fixture.app, head).x - neck_x) < 1.0e-3f
		&& math::abs(posed_at_playhead(&fixture.app, top).x - neck_x) < 1.0e-3f,
		"clicking Align X on Pose did not line the posed head up with the neck");
	test::@check(fixture.doc().find(head).position == head_rest && fixture.doc().find(top).position == top_rest,
		"Align on Pose moved joints on the model");
}

<*
 Centre on mesh drops a single selected joint onto the mesh's bounding-box middle,
 and refuses a multi-selection so a group is never stacked onto one point.
*>
fn void center_drops_a_lone_joint_onto_the_mesh_middle() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("Centre on mesh drops a lone joint onto the mesh middle");
	fixture.reset();

	uint a = fixture.app.add_recorded({ 0.30f, 0.30f, 0.30f }, "a");
	fixture.app.undo_stack.commit();
	fixture.app.select(a);

	Vec3 center = fixture.app.geometry.bounds().center();
	test::@check(fixture.app.center_selected_on_mesh(), "centre did nothing for a single joint");
	test::@check((fixture.doc().find(a).position - center).length() < 1.0e-5f,
		"the joint did not land on the mesh centre");

	test::@check(fixture.app.undo(), "centring left nothing on the ledger");

	// A second joint added and both selected: centring is refused.
	uint bb = fixture.app.add_recorded({ 0.10f, 0.10f, 0.10f }, "b");
	fixture.app.undo_stack.commit();
	fixture.app.select(a);
	fixture.app.extend_selection(bb);
	test::@check(!fixture.app.center_selected_on_mesh(), "centre acted on a multi-selection");
}

fn void pose_mode_is_not_part_of_the_interface() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("the Rig menu and P shortcut expose no separate pose mode");
	fixture.reset();
	PosedLimb limb = build_limb(fixture);

	fixture.feed_key(Key.P);
	test::@check(!fixture.app.skinned(), "P changed the rest-rig display");

	Vec2? rig_title = fixture.center_of("Rig");
	if (catch rig_title)
	{
		test::@check(false, "SKIPPED — the Rig title is not on the header");
		return;
	}
	fixture.click(rig_title);
	test::@check(!fixture.in_tree("Pose") && !fixture.in_tree("Clear pose"),
		"the Rig menu still offers standalone pose controls");
	fixture.feed_key(Key.ESCAPE);

	// P also remains inert while a manual timeline draft is waiting for Save
	// pose—the exact state transition that used to lose the key.
	AnimRef clip = fixture.app.new_clip("No pose mode", 1.0f, from_rest: true);
	fixture.app.auto_key = false;
	fixture.app.edit_time = 0.25f;
	test::@check(fixture.app.park_clip(clip, fixture.app.edit_time), "the clip would not park");
	fixture.app.select(limb.thigh);
	test::@check(fixture.app.begin_turn(), "the animation turn would not begin");
	fixture.app.turn_joint({ 0, 0, 1 }, 0.4f);
	fixture.app.end_drag();
	test::@check(fixture.app.pose_edit_pending, "the manual draft was not kept");
	fixture.feed_key(Key.P);
	test::@check(fixture.app.pose_edit_active && fixture.app.pose_edit_pending,
		"P discarded the animation pose draft");
}

<*
 R turns the selected joint in place and carries everything below it.

 The joint itself must not move a hair. `joint_palette` applies a joint's
 rotation *after* the translation that places it, so a turn pivots the subtree
 about the joint and leaves the joint alone — and that is the whole difference
 between R and G. A conversion that composed the two the other way round would
 swing the grabbed joint too, and it would look almost right.

 **The direction is asserted, and it is the assertion that decides the code.**
 Screen y runs downward while the world is y-up, and the camera axis points at
 the eye, so whether a sweep one way is a positive turn is not a thing to be
 confident about from reading. Dragging clockwise on screen has to turn the limb
 clockwise on screen; the sign in `turn_pose` exists to satisfy this.
*>
fn void turning_holds_the_joint_and_carries_the_limb() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("R turns a joint in place and the limb below it follows the sweep");
	fixture.reset();

	PosedLimb limb = build_limb(fixture);
	// The thigh: a joint whose parent forks. G carries the body from it; R turns
	// it in place, which is what this checks.
	AnimRef clip = fixture.app.new_clip("Turn gesture", 1.0f, from_rest: true);
	fixture.app.editing = clip;
	test::@check(fixture.app.park_clip(clip, 0.0f), "the turn clip would not park");
	fixture.app.select(limb.thigh);

	Vec2? pivot_px = fixture.pixel_of(limb.thigh);
	Vec2? tip_px = fixture.pixel_of(limb.ankle);
	if (catch pivot_px)
	{
		test::@check(false, "SKIPPED — the thigh did not project");
		return;
	}
	if (catch tip_px)
	{
		test::@check(false, "SKIPPED — the ankle did not project");
		return;
	}

	// G begins on it — the body moves from any joint — and escape puts it back.
	Vec3 thigh_was = fixture.app.dot_position(*fixture.doc().find(limb.thigh));
	fixture.tap(pivot_px, Key.G);
	test::@check(fixture.app.drag.dot == limb.thigh && fixture.app.drag.verb == DragVerb.POSE,
		"G did not begin on a joint whose parent forks");
	test::@check(fixture.app.cancel_drag(), "escape found no gesture");
	test::@check((fixture.app.dot_position(*fixture.doc().find(limb.thigh)) - thigh_was).length() < 1.0e-5f,
		"escape left the thigh moved");

	// R begins the turn outright — nothing is drawn around the joint to press,
	// which is the point: a ring there hid the very limb being turned. The
	// pointer sweeps around the pivot and a click confirms.
	Vec2 arm = { 60.0f, 0.0f };
	Vec2 start = pivot_px + arm;
	fixture.tap(start, Key.R);
	if (fixture.app.drag.dot != limb.thigh || fixture.app.drag.verb != DragVerb.TURN)
	{
		test::@check(false, "SKIPPED — R did not start a turn (%s)", fixture.notice_text());
		return;
	}
	test::@check(!fixture.app.drag.held, "R's turn is holding a button nobody pressed");

	// The first move anchors the sweep — the key arrived with no pointer — and
	// the second turns. A pointer that has not moved sends no move at all, so
	// the anchor is taken a pixel further out along the same arm.
	fixture.feed(pivot_px + arm * 1.02f);
	float turn = 0.65f;
	Vec2 moved = pivot_px + (Vec2){
		arm.x * math::cos(turn) - arm.y * math::sin(turn),
		arm.x * math::sin(turn) + arm.y * math::cos(turn),
	};
	fixture.feed(moved);
	test::@check(math::abs(fixture.app.drag.turned) > 0.1f,
		"the pointer sweep did not reach the turn gesture (%.3f)", fixture.app.drag.turned);
	fixture.click(moved);

	// --- the joint held still ---------------------------------------------

	Vec3 thigh_now = fixture.app.dot_position(*fixture.doc().find(limb.thigh));
	test::@check((thigh_now - thigh_was).length() < 1.0e-5f,
		"the turned joint moved %.5f — a turn pivots about it, it does not carry it",
		(thigh_now - thigh_was).length());

	// --- and the limb followed the sweep ----------------------------------

	Vec2? swung = fixture.pixel_of(limb.ankle);
	if (catch swung)
	{
		test::@check(false, "SKIPPED — the swung ankle did not project");
		return;
	}

	test::@check((swung - tip_px).length() > 20.0f,
		"the ankle only travelled %.1f px", (swung - tip_px).length());
	test::@check(fixture.app.drag.dot == 0, "the confirming click left the turn active");
}

<*
 Held joints' columns survive the session file, a fractional weight comes back
 exactly, and the key is absent when there is nothing to say.

 The omission is asserted as well as the round trip. Most rigs keep the
 automatic weights, and a `"weights": []` written into every session would be a
 line of noise in all of them. A column of a joint that is not held, or of one
 deleted since, does not reach the file.
*>
fn void held_columns_round_trip_through_the_session() @test
{
	io::printn("held columns round-trip through the session file");

	RigDocument doc;
	doc.dots.init(mem);
	doc.edges.init(mem);
	doc.attachments.init(mem);
	doc.pins.init(mem);
	defer doc.free();

	uint hips = doc.add_dot({ 0, 0, 0 }, "hips");
	uint knee = doc.add_dot({ 0, -0.5f, 0 }, "knee");
	doc.connect(hips, knee);

	// Nothing held yet, so the writer has nothing to say and must say nothing.
	String bare = crig::session_text(mem, &doc, SESSION_MESH);
	defer bare.free(mem);
	test::@check(!bare.contains(`"weights"`) && !bare.contains(`"pins"`), "a rig with no held joint still wrote weights");

	// One full weight, and one fraction that needs every bit to come back as
	// itself — the smooth op writes those, so the exactness is not decorative.
	doc.set_held(hips, true);
	doc.set_held(knee, true);
	doc.set_pin(3, hips, 1.0f);
	doc.set_pin(3, knee, 0.123456789f);
	doc.set_pin(41, knee, 0.5f);

	// A column on a dot that is about to go. It stays in the document — undo
	// could still bring the dot back — and must not reach the file.
	uint doomed = doc.add_dot({ 1, 0, 0 }, "doomed");
	doc.set_held(doomed, true);
	doc.set_pin(7, doomed, 1.0f);
	doc.remove_dot(doomed);
	test::@check(doc.pins.len() == 4, "the document kept the stale column for undo");

	if (catch io::file::delete(SESSION_FILE)) {}
	if (catch fault error = crig::write_session(SESSION_FILE, &doc, SESSION_MESH))
	{
		test::@check(false, "could not write the session (%s)", error);
		return;
	}

	RigDocument? reloaded = crig::read_session(mem, SESSION_FILE);
	if (catch reloaded)
	{
		test::@check(false, "the session did not read back");
		return;
	}
	RigDocument back = reloaded;
	defer back.free();
	(void)io::file::delete(SESSION_FILE);

	// The bits themselves are written, so this is equality and not an epsilon.
	test::@check(back.pin_of(3, hips) == 1.0f, "the full weight came back as %s", back.pin_of(3, hips));
	test::@check(back.pin_of(3, knee) == 0.123456789f,
		"the fractional weight came back as %s", back.pin_of(3, knee));
	test::@check(back.pin_of(41, knee) == 0.5f, "the second dot's weight came back as %s", back.pin_of(41, knee));
	test::@check(back.pins.len() == 3, "the stale column was dropped on the way out");
	test::@check(back.find(hips).held && back.find(knee).held, "the held flags did not come back");
}

<*
 An attachment survives the session file: pinned, saved, cleared, loaded, and the
 piece rides the same dot again.

 The layer above the pin layer, and the same promise about a different key. Which
 bone a prop rides is exactly the kind of decision nobody wants to make twice — a
 sword pinned to a hand and lost on reopen is worse than one never pinned, since
 the second time round the user has no reason to trust the pin.

 Driven through `AppState.pin_shell` and `AppState.load_session` rather than
 through the writer, so what is asserted is the whole route the interface takes:
 the pane pins, Ctrl+S writes, and a reopen reads it back.
*>
fn void an_attachment_survives_the_session_file() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("an attachment comes back with the session");
	fixture.reset();

	fixture.click(SPOT_A);
	if (fixture.doc().dots.len() != 1)
	{
		test::@check(false, "SKIPPED — the dot to pin to did not land");
		return;
	}
	uint dot = fixture.doc().dots[0].id;
	fixture.app.select(dot);

	// The fixture's mesh is one cube, so the piece pinned is the whole body — odd
	// to do and exactly as good a test of the file, which is about ids and the
	// writer rather than about which piece is which.
	fixture.app.pin_shell(0);
	if (fixture.doc().attachment_of(0) != dot)
	{
		test::@check(false, "SKIPPED — the pin did not take");
		return;
	}

	fixture.app.point_at(SESSION_MESH);
	(void)io::file::delete(SESSION_FILE);
	fixture.chord(SPOT_A, Key.LEFT_CTRL, Key.S);
	test::@check(io::file::is_file(SESSION_FILE), "ctrl+S wrote no session beside the mesh");

	// Cleared in the document rather than undone, so what the load has to bring
	// back is a pin nothing still in memory remembers.
	fixture.app.doc.attach_shell(0, 0);
	if (fixture.doc().attachment_of(0) != 0)
	{
		test::@check(false, "SKIPPED — the pin did not clear");
		return;
	}

	fixture.app.load_session();
	test::@check(fixture.doc().attachment_of(0) == dot,
		"a saved session brings the pin back with the rig");

	(void)io::file::delete(SESSION_FILE);
	fixture.app.point_at("");
}

<*
 The bound animations round-trip through the session, and an entry that cannot
 be found survives the trip.

 The bound set is what makes a character's animations outlast the process, so
 the write and the read are one claim and are checked together. The second half
 is the one worth spelling out: a binding whose file has gone comes back
 *present*, because the alternative is a list that quietly shortens itself on
 load — the user chose that clip, and losing the record of it at the quietest
 possible moment is the failure this format is shaped to avoid.

 Order is asserted because an export walks the list in it: which animation is
 first in a shipped file is a choice the panel offers, and a round trip that
 sorted them would take it away.
*>
fn void the_bound_animations_round_trip_through_the_session() @test
{
	io::printn("bound animations round-trip through the session file");

	RigDocument doc;
	doc.dots.init(mem);
	doc.edges.init(mem);
	doc.attachments.init(mem);
	doc.animations.init(mem);
	defer doc.free();

	uint hips = doc.add_dot({ 0, 0, 0 }, "hips");
	uint knee = doc.add_dot({ 0, -0.5f, 0 }, "knee");
	doc.connect(hips, knee);

	test::@check(doc.bind_clip("anims/humanoid.glb", "Walk"), "the first clip bound");
	test::@check(doc.bind_clip("anims/humanoid.glb", "Idle"), "and a second from the same file");
	// An authored clip: no file, which is a real state rather than a malformed one.
	test::@check(doc.bind_clip("", "hand_made"), "and one with no file behind it");

	// The same pair twice is one binding, not two — a clip is either on the
	// character or it is not.
	test::@check(!doc.bind_clip("anims/humanoid.glb", "Walk"), "binding the same clip twice added it again");
	test::@check(doc.animations.len() == 3, "three bindings, not %d", doc.animations.len());

	// A name shared by two files is two bindings: the file is half the identity.
	test::@check(doc.bind_clip("anims/other.glb", "Walk"), "the same name in another file is another clip");

	String text = crig::session_text(mem, &doc, "goat.glb");
	defer text.free(mem);

	RigDocument? parsed = crig::parse_session(mem, text);
	if (catch parsed)
	{
		test::@check(false, "the session text with animations in it did not parse");
		return;
	}
	RigDocument back = parsed;
	defer back.free();

	test::@check(back.animations.len() == 4, "%d bindings came back", back.animations.len());

	// In the order they were bound, which is the order an export walks.
	test::@check(back.animations[0].clip == "Walk" && back.animations[0].file == "anims/humanoid.glb",
		"the first binding came back as %s in %s", back.animations[0].clip, back.animations[0].file);
	test::@check(back.animations[1].clip == "Idle", "the second came back as %s", back.animations[1].clip);
	test::@check(back.animations[2].clip == "hand_made" && back.animations[2].file.len == 0,
		"the authored one kept its empty file");
	test::@check(back.animations[3].file == "anims/other.glb", "and the fourth kept its own file");

	// Unbinding by the pair, and only the pair.
	test::@check(back.bound_index("anims/humanoid.glb", "Walk") == 0, "the first is still findable");
	test::@check(back.bound_index("anims/other.glb", "Idle") < 0,
		"a file and a name that were never bound together are not found");
	test::@check(back.unbind_at(0), "unbinding the first");
	test::@check(back.animations.len() == 3, "left %d", back.animations.len());
	test::@check(back.bound_index("anims/other.glb", "Walk") >= 0, "and took the wrong Walk with it");

	// Reordering, which is what the panel's Move up and Move down do.
	test::@check(back.reorder_bound(2, 0), "moving the last to the front");
	test::@check(back.animations[0].file == "anims/other.glb", "put %s there instead",
		back.animations[0].file);
	test::@check(!back.reorder_bound(0, 0), "a move that goes nowhere is not a change");
	test::@check(!back.reorder_bound(0, 9), "and one that goes off the end is refused");
}
