<*
 `AppState.apply_document` — a document JavaScript authored, arriving as an
 edit.

 What these check is the half `test/js/main.js` cannot see. That file runs under
 a real host and proves the round trip; it has no way to ask how many entries
 landed on the undo stack, because `js_crig_call` refuses `undo` from inside a
 script on purpose. So the ledger is checked here.

 The claim under test, in one sentence: **an apply is one edit**. Not one edit
 per field that moved — one, whatever it touched, so that a JavaScript panel
 that nudges four dots is a single Ctrl+Z exactly as the C3 panel that nudges
 four dots is.
*>
module crig_tests::apply_doc;

import crig;
import rig;
import std::math;

<*
 A document with a three-dot chain and one loose dot, and no mesh.

 No mesh because nothing in the differ reads geometry — the one call that does,
 `default_reach`, is not on this path — and a bare app is the cheaper fixture.
*>
struct Chain
{
	crig::AppState app;
	uint hips, knee, foot, loose;
}

fn void Chain.open(&self)
{
	self.app = crig::new_app({});
	self.hips = self.app.doc.add_dot({ 0, 1, 0 }, "hips");
	self.knee = self.app.doc.add_dot({ 0, 0.5, 0 }, "knee");
	self.foot = self.app.doc.add_dot({ 0, 0, 0 }, "foot");
	self.app.doc.connect(self.hips, self.knee);
	self.app.doc.connect(self.knee, self.foot);
	self.loose = self.app.doc.add_dot({ 0.5, 0.25, 0 }, "loose");
}

fn void Chain.close(&self) => self.app.free();

<*
 The document crig holds, as a separate one JavaScript could have edited.

 Through `session_text` and `parse_session` rather than a struct copy, because
 that is the crossing the real path makes: what arrives from a script has been
 written and read back, so a field the codec drops is a field these checks
 should see dropped too.
*>
fn crig::RigDocument copy_of(crig::AppState* app)
{
	String text = crig::session_text(tmem, &app.doc, "");
	return crig::parse_session(mem, text, 0.0f)!!;
}

fn void an_unchanged_document_records_nothing() @test
{
	Chain fixture;
	fixture.open();
	defer fixture.close();
	crig::AppState* app = &fixture.app;

	crig::RigDocument want = copy_of(app);
	defer want.free();

	crig::DocumentDiff diff = app.apply_document(&want)!!;

	// The bug this is really about is `move_recorded`: `move_dot` answers true
	// for any dot that exists, moved or not, so an unguarded call would record a
	// MOVE_DOT per dot per apply — and every one of them would undo to itself.
	assert(diff.total() == 0, "an unchanged document recorded %d edits", diff.total());
	assert(!app.undo_stack.can_undo(), "an unchanged document opened an undo group");
}

fn void a_moved_dot_is_one_edit_and_one_undo() @test
{
	Chain fixture;
	fixture.open();
	defer fixture.close();
	crig::AppState* app = &fixture.app;
	uint knee = fixture.knee;

	crig::RigDocument want = copy_of(app);
	defer want.free();
	want.move_dot(knee, { 0.25, 0.5, 0 });

	crig::DocumentDiff diff = app.apply_document(&want)!!;
	assert(diff.moved == 1, "moved %d", diff.moved);
	assert(diff.total() == 1, "a one-dot move recorded %d edits", diff.total());
	assert(app.doc.find(knee).position.x == 0.25f, "the move did not land");

	assert(app.undo(), "an applied edit left nothing to undo");
	assert(app.doc.find(knee).position.x == 0.0f, "undo did not take the move back");
	assert(!app.undo_stack.can_undo(), "one apply left more than one undo step");
}

<*
 Three fields on two dots, and still one Ctrl+Z.

 This is the whole point of routing through `recorded.c3` rather than writing a
 verb per field: the primitives record into the open group and the apply closes
 it once, so the group boundary is the *apply* and not the field.
*>
fn void three_changes_in_one_apply_are_one_undo_step() @test
{
	Chain fixture;
	fixture.open();
	defer fixture.close();
	crig::AppState* app = &fixture.app;
	uint knee = fixture.knee;
	uint foot = fixture.foot;

	crig::RigDocument want = copy_of(app);
	defer want.free();
	want.move_dot(knee, { 0.25, 0.5, 0 });
	want.rename_dot(foot, "ankle");
	want.set_reach(knee, 0.4f);

	crig::DocumentDiff diff = app.apply_document(&want)!!;
	assert(diff.total() == 3, "expected three edits, got %d", diff.total());

	assert(app.undo(), "nothing to undo");
	assert(app.doc.find(knee).position.x == 0.0f, "the move survived the undo");
	assert(app.doc.find(foot).name == "foot", "the rename survived the undo");
	assert(app.doc.find(knee).reach == 0.0f, "the reach survived the undo");
	assert(!app.undo_stack.can_undo(), "three changes made more than one undo step");
}

<*
 An id JavaScript chose is the id crig keeps.

 `add_dot` would mint a fresh one, and every reference the script still holds —
 an edge it just wrote, its own next edit — names the one it chose. So the
 differ inserts rather than adds.
*>
fn void an_added_dot_keeps_the_id_it_arrived_with() @test
{
	Chain fixture;
	fixture.open();
	defer fixture.close();
	crig::AppState* app = &fixture.app;

	crig::RigDocument want = copy_of(app);
	defer want.free();
	want.insert_dot(500, { 9, 9, 9 }, "chosen");
	want.connect(500, want.root_id);

	crig::DocumentDiff diff = app.apply_document(&want)!!;
	assert(diff.added == 1, "added %d", diff.added);
	assert(diff.connected == 1, "connected %d", diff.connected);

	crig::Dot* landed = app.doc.find(500);
	assert(landed != null, "the dot did not arrive under its own id");
	assert(landed.name == "chosen", "the name did not survive");

	// And the counter went up past it, or the next add hands out 500 again.
	assert(app.doc.next_id >= 500, "next_id stayed at %d", app.doc.next_id);

	assert(app.undo(), "nothing to undo");
	assert(app.doc.find(500) == null, "undo left the added dot behind");
}

<*
 A removal takes its edges, and undo brings all three back.

 The ordering check. `remove_dot` drops the edges it touched *silently*, so a
 differ that recorded only DELETE_DOT would undo into a dot with no edges on it
 — the rig would come back in two pieces. The edges are recorded first, exactly
 as `app/edit_ops.c3`'s own delete does it.
*>
fn void a_removal_takes_its_edges_and_undo_brings_both_back() @test
{
	Chain fixture;
	fixture.open();
	defer fixture.close();
	crig::AppState* app = &fixture.app;
	uint hips = fixture.hips;
	uint knee = fixture.knee;
	uint foot = fixture.foot;

	crig::RigDocument want = copy_of(app);
	defer want.free();
	want.remove_dot(knee);

	crig::DocumentDiff diff = app.apply_document(&want)!!;
	assert(diff.removed == 1, "removed %d", diff.removed);
	assert(diff.disconnected == 2, "disconnected %d, expected the two edges the dot carried", diff.disconnected);
	assert(app.doc.edges.len() == 0, "edges survived the removal");

	assert(app.undo(), "nothing to undo");
	assert(app.doc.find(knee) != null, "undo did not restore the dot");
	assert(app.doc.has_edge(hips, knee), "undo did not restore the upper edge");
	assert(app.doc.has_edge(knee, foot), "undo did not restore the lower edge");
	assert(!app.undo_stack.can_undo(), "a removal made more than one undo step");
}

fn void applying_the_same_document_twice_changes_nothing_the_second_time() @test
{
	Chain fixture;
	fixture.open();
	defer fixture.close();
	crig::AppState* app = &fixture.app;
	uint knee = fixture.knee;

	crig::RigDocument want = copy_of(app);
	defer want.free();
	want.move_dot(knee, { 0.25, 0.5, 0 });
	want.set_reach(knee, 0.4f);

	crig::DocumentDiff first = app.apply_document(&want)!!;
	assert(first.total() == 2, "first apply recorded %d", first.total());

	crig::DocumentDiff second = app.apply_document(&want)!!;
	assert(second.total() == 0, "the second apply recorded %d", second.total());
	assert(app.undo(), "nothing to undo");
	assert(!app.undo_stack.can_undo(), "the idempotent apply still opened a group");
}

<*
 The root moves, and it moves after the removals.

 A removal that takes the root reassigns it to whatever is left, so asking for
 the root before that would be asking about a document one step from existing.
*>
fn void the_root_can_move_in_the_same_apply_as_a_removal() @test
{
	Chain fixture;
	fixture.open();
	defer fixture.close();
	crig::AppState* app = &fixture.app;
	uint hips = fixture.hips;
	uint foot = fixture.foot;
	assert(app.doc.root_id == hips, "the fixture did not root at the hips");

	crig::RigDocument want = copy_of(app);
	defer want.free();
	want.remove_dot(hips);
	want.root_id = foot;

	crig::DocumentDiff diff = app.apply_document(&want)!!;
	assert(diff.removed == 1, "removed %d", diff.removed);
	assert(app.doc.root_id == foot, "the root did not follow, it is %d", app.doc.root_id);

	assert(app.undo(), "nothing to undo");
	assert(app.doc.root_id == hips, "undo did not put the root back");
	assert(app.doc.find(hips) != null, "undo did not put the dot back");
}

<*
 The vertex-keyed layers are refused rather than diffed.

 The plan's rule about which layer a structure belongs to, enforced at the
 door. Paint is one entry per (vertex, dot) pair — a hundred thousand of them on
 a real model — so diffing it here would be the boundary doing the exact thing
 it exists to prevent.
*>
fn void paint_does_not_cross_this_door() @test
{
	Chain fixture;
	fixture.open();
	defer fixture.close();
	crig::AppState* app = &fixture.app;

	crig::RigDocument want = copy_of(app);
	defer want.free();
	want.paint.push({ .vertex = 0, .dot_id = app.doc.root_id, .factor = 2.0f });

	if (try app.apply_document(&want))
	{
		assert(false, "a changed paint layer was accepted");
	}
	assert(!app.undo_stack.can_undo(), "a refused apply still recorded an edit");
}

fn void pins_do_not_cross_this_door_either() @test
{
	Chain fixture;
	fixture.open();
	defer fixture.close();
	crig::AppState* app = &fixture.app;

	crig::RigDocument want = copy_of(app);
	defer want.free();
	want.pins.push({ .vertex = 0, .dot_id = app.doc.root_id, .share = 1.0f });

	if (try app.apply_document(&want))
	{
		assert(false, "a changed pin layer was accepted");
	}
	assert(!app.undo_stack.can_undo(), "a refused apply still recorded an edit");
}

<*
 The staleness signal — `UndoStack.revision`.

 A panel holds a document across frames and edits it; an apply is a *diff*, so
 an edit computed against a copy crig has moved past reads as an instruction to
 put everything back. The counter is what lets a panel notice. These check the
 three things a reader depends on: it moves when the document does, it does not
 move when nothing happened, and history counts as movement.
*>
fn void the_revision_moves_when_the_document_does() @test
{
	Chain fixture;
	fixture.open();
	defer fixture.close();
	crig::AppState* app = &fixture.app;

	crig::RigDocument want = copy_of(app);
	defer want.free();
	want.move_dot(fixture.knee, { 0.25, 0.5, 0 });

	uint before = app.undo_stack.revision;
	app.apply_document(&want)!!;
	assert(app.undo_stack.revision != before, "an applied edit left the revision at %d", before);
}

fn void an_apply_that_changed_nothing_leaves_the_revision_alone() @test
{
	Chain fixture;
	fixture.open();
	defer fixture.close();
	crig::AppState* app = &fixture.app;

	crig::RigDocument want = copy_of(app);
	defer want.free();

	uint before = app.undo_stack.revision;
	crig::DocumentDiff diff = app.apply_document(&want)!!;
	assert(diff.total() == 0, "the fixture was not already what it is");
	assert(app.undo_stack.revision == before,
		"an apply that changed nothing moved the revision %d -> %d", before, app.undo_stack.revision);
}

<*
 Undo moves it too, and that is the case a naive counter misses: the document
 changed and nothing was recorded, because a step of history *replays* entries
 rather than adding them.
*>
fn void a_step_of_history_moves_the_revision() @test
{
	Chain fixture;
	fixture.open();
	defer fixture.close();
	crig::AppState* app = &fixture.app;

	crig::RigDocument want = copy_of(app);
	defer want.free();
	want.move_dot(fixture.knee, { 0.25, 0.5, 0 });
	app.apply_document(&want)!!;

	uint before = app.undo_stack.revision;
	assert(app.undo(), "nothing to undo");
	assert(app.undo_stack.revision != before, "undo left the revision at %d", before);

	uint after_undo = app.undo_stack.revision;
	assert(app.redo(), "nothing to redo");
	assert(app.undo_stack.revision != after_undo, "redo left the revision at %d", after_undo);
}
