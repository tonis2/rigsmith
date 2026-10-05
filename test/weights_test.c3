// What `AppState.survey_weights` promises, asserted on the numbers rather than
// through the wire. The MCP checks in test/mcp_test.c3 cover the JSON these come
// out as; these cover the arithmetic underneath it, which is the half that can
// be wrong without any tool call looking odd.
module crig_tests::weights;
import crig;
import rig;
import crig_tests::shared_app;
import std::core::test;

import std::math;
import std::collections::list;
import std::math::matrix;
import std::math::quaternion;

// A cube of corners: every vertex is far from the chain below, which is what
// makes the middle dot own none of it — see `a_dot_can_own_nothing_and_still_reach`.
//
// The same cube `shared_app` measures once for the process. The chain fixtures
// below open that one; these arrays stay for the checks that count its vertices,
// frame it in a viewport, or build a two-cube mesh out of it.
Vec3[8] cube_positions = {
	{ -1, -1, -1 }, { 1, -1, -1 }, { 1, 1, -1 }, { -1, 1, -1 },
	{ -1, -1, 1 }, { 1, -1, 1 }, { 1, 1, 1 }, { -1, 1, 1 },
};

uint[36] cube_indices = {
	4, 5, 6, 4, 6, 7,
	1, 0, 3, 1, 3, 2,
	3, 7, 6, 3, 6, 2,
	0, 1, 5, 0, 5, 4,
	1, 2, 6, 1, 6, 5,
	0, 4, 7, 0, 7, 3,
};

<*
 A three-dot chain down the middle of the cube, plus one dot off to the side.

 The caller frees it with `AppState.free`. The mesh and its measurements are
 static and borrowed from `shared_app`, which is what `owns_geometry` being
 false means here — and why a bind in these checks costs milliseconds rather
 than the second a production-resolution grid over the cube took.
*>
fn crig::AppState chained()
{
	crig::AppState app = shared_app::open_cube();

	uint hips = app.doc.add_dot({ 0, 1, 0 }, "hips");
	uint knee = app.doc.add_dot({ 0, 0.5, 0 }, "knee");
	uint foot = app.doc.add_dot({ 0, 0, 0 }, "foot");
	app.doc.connect(hips, knee);
	app.doc.connect(knee, foot);
	app.doc.add_dot({ 0.5, 0.25, 0 }, "stray");

	return app;
}

// The dot id `name` was given, or 0.
fn uint dot_named(crig::AppState* app, String name)
{
	foreach (dot : app.doc.dots.array_view())
	{
		if (dot.name == name) return dot.id;
	}
	return 0;
}

<*
 Ownership is exclusive and total: every vertex belongs to exactly one dot.

 The survey's strongest claim, and the one a loop that counted twice or skipped a
 row would break. Asserted as a sum, because no individual dot's share is a
 number this test could know without recomputing the bind it is checking.
*>
fn void every_vertex_is_owned_exactly_once() @test
{
	crig::AppState app = chained();
	defer app.free();

	crig::WeightSurvey survey = app.survey_weights(mem)!!;
	defer survey.free(mem);

	usz owned = 0;
	foreach (stake : survey.stakes) owned += stake.owns;

	test::eq(survey.vertices, (usz)cube_positions.len);
	test::eq(owned, survey.vertices);
	test::eq(survey.stakes.len, (sz)4);
}

<*
 No dot owns mass it does not reach.

 Not free: reach is a threshold and ownership is an argmax, so on a rig with
 enough joints the winner's share can fall under the floor. `survey_weights`
 counts the owner in regardless, and this is that guard.
*>
fn void reach_covers_what_is_owned() @test
{
	crig::AppState app = chained();
	defer app.free();

	crig::WeightSurvey survey = app.survey_weights(mem)!!;
	defer survey.free(mem);

	foreach (stake : survey.stakes) test::@check(stake.reaches >= stake.owns, "%s reaches less than it owns", stake.name);
}

<*
 A surveyed dot's reach is exactly what it owns plus what it shares.

 An identity, not a bound: a vertex it reaches is either its own or someone
 else's, and the shared rows group the second kind by owner. A survey that
 double-counted, dropped a neighbour, or applied the floor differently in the two
 passes breaks this and nothing else here would notice.
*>
fn void reach_is_owned_plus_shared() @test
{
	crig::AppState app = chained();
	defer app.free();

	uint knee = dot_named(&app, "knee");
	crig::WeightSurvey survey = app.survey_weights(mem, knee)!!;
	defer survey.free(mem);

	usz elsewhere = 0;
	foreach (share : survey.shared)
	{
		elsewhere += share.vertices;
		test::@check(share.dot != knee, "a dot is listed as its own neighbour");
		test::@check(share.peak >= share.mean, "a peak share below the mean");
	}

	crig::JointStake surveyed = {};
	foreach (stake : survey.stakes)
	{
		if (stake.dot == knee) surveyed = stake;
	}

	test::eq(surveyed.reaches, surveyed.owns + elsewhere);
}

<*
 A dot can own nothing and still pull hard on the mesh.

 The reason `owns` and `reaches` are two numbers. Every vertex of this cube is a
 corner, so the middle of the chain is nearest to none of them — and it is still
 strong enough on its neighbours' vertices to move them. A joint in exactly that
 state smears a mesh without holding any of it, which is the thing the survey
 exists to make visible.
*>
fn void a_dot_can_own_nothing_and_still_reach() @test
{
	crig::AppState app = chained();
	defer app.free();

	uint knee = dot_named(&app, "knee");
	crig::WeightSurvey survey = app.survey_weights(mem, knee)!!;
	defer survey.free(mem);

	crig::JointStake surveyed = {};
	foreach (stake : survey.stakes)
	{
		if (stake.dot == knee) surveyed = stake;
	}

	test::eq(surveyed.owns, (usz)0);
	test::@check(surveyed.reaches > 0, "the middle of the chain reaches nothing at all");
	test::@check(survey.shared.len > 0, "and takes from no neighbour");
}

<*
 Shared rows come worst first, so a caller reading only the head reads the
 boundary most likely to tear.
*>
fn void shared_rows_are_worst_first() @test
{
	crig::AppState app = chained();
	defer app.free();

	crig::WeightSurvey survey = app.survey_weights(mem, dot_named(&app, "hips"))!!;
	defer survey.free(mem);

	for (usz i = 1; i < survey.shared.len; i++)
	{
		test::@check(
			survey.shared[i - 1].vertices >= survey.shared[i].vertices,
			"shared rows are out of order at %d", i);
	}
}

<*
 A dot that is not in the rig is refused rather than surveyed as joint zero.
*>
fn void an_absent_dot_is_refused() @test
{
	crig::AppState app = chained();
	defer app.free();

	crig::WeightSurvey? survey = app.survey_weights(mem, 9999);
	if (try survey)
	{
		survey.free(mem);
		test::@check(false, "a dot id no rig carries was surveyed anyway");
	}
}

// The cube above, plus a second box floating clear of it: two shells, so a pin
// on one of them has somewhere to be visible.
Vec3[16] two_piece_positions = {
	{ -1, -1, -1 }, { 1, -1, -1 }, { 1, 1, -1 }, { -1, 1, -1 },
	{ -1, -1, 1 },  { 1, -1, 1 },  { 1, 1, 1 },  { -1, 1, 1 },

	// Far enough out that nothing in the chain is anywhere near it — the pin has
	// to be what puts it on a joint, not proximity.
	{ 5, 5, -0.2 },   { 5.4, 5, -0.2 },   { 5.4, 5.4, -0.2 },   { 5, 5.4, -0.2 },
	{ 5, 5, 0.2 },    { 5.4, 5, 0.2 },    { 5.4, 5.4, 0.2 },    { 5, 5.4, 0.2 },
};

uint[72] two_piece_indices = {
	4, 5, 6, 4, 6, 7,     1, 0, 3, 1, 3, 2,
	3, 7, 6, 3, 6, 2,     0, 1, 5, 0, 5, 4,
	1, 2, 6, 1, 6, 5,     0, 4, 7, 0, 7, 3,

	12, 13, 14, 12, 14, 15,   9, 8, 11, 9, 11, 10,
	11, 15, 14, 11, 14, 10,   8, 9, 13, 8, 13, 12,
	9, 10, 14, 9, 14, 13,     8, 12, 15, 8, 15, 11,
};

<*
 A pinned shell rides the dot it was pinned to, all the way through the survey.

 The whole point of pinning: a piece the binder would otherwise hand to whichever
 bone happens to be least far away is nailed to a named one instead. The far box
 in the fixture is nearest the "stray" dot by a wide margin, so the check is that
 pinning moves it somewhere it would never have gone — onto "foot", at the other
 end of the chain and further from the box than every other dot.

 This is the only check that the document's attachments reach the binder at all.
 Everything else about pinning is asserted on the *document* — that a click sets
 it, that undo takes it back, that the session keeps it — which passes just as
 well if the binder is never told. `RigView` is the wire between the two, and
 `attachment_joints` is what fills it.
*>
fn void a_pinned_shell_rides_the_dot_it_was_pinned_to() @test
{
	crig::AppState app = crig::new_app(
		{ .positions = two_piece_positions[..], .indices = two_piece_indices[..] });
	defer app.free();

	uint hips = app.doc.add_dot({ 0, 1, 0 }, "hips");
	uint knee = app.doc.add_dot({ 0, 0.5, 0 }, "knee");
	uint foot = app.doc.add_dot({ 0, 0, 0 }, "foot");
	app.doc.connect(hips, knee);
	app.doc.connect(knee, foot);
	uint stray = app.doc.add_dot({ 4.0, 4.0, 0 }, "stray");

	if (app.shells.count != 2)
	{
		test::@check(false, "SKIPPED — the fixture is %d shells, not two", app.shells.count);
		return;
	}

	// Which shell the far box became. `build_shells` numbers by first vertex, so
	// this is asked rather than assumed.
	int far = app.shells.of[8];

	crig::WeightSurvey loose = app.survey_weights(mem)!!;
	usz stray_before = owned_by(loose, stray);
	usz foot_before = owned_by(loose, foot);
	loose.free(mem);

	test::@check(stray_before >= 8, "the near dot owns the far box unpinned (%d of 8)", stray_before);

	app.doc.attach_shell((uint)far, foot);

	crig::WeightSurvey pinned = app.survey_weights(mem)!!;
	usz stray_after = owned_by(pinned, stray);
	usz foot_after = owned_by(pinned, foot);
	pinned.free(mem);

	test::@check(foot_after == foot_before + 8,
		"the pinned dot gains all eight of the box's vertices (%d -> %d)", foot_before, foot_after);
	test::@check(stray_after == stray_before - 8,
		"and the dot that had them keeps none (%d -> %d)", stray_before, stray_after);
}

// How many vertices the survey says `dot` owns.
fn usz owned_by(crig::WeightSurvey survey, uint dot)
{
	foreach (stake : survey.stakes)
	{
		if (stake.dot == dot) return stake.owns;
	}
	return 0;
}

// ---------------------------------------------------------------------------
// The paint layer
//
// `final = base x paint`, with `base` whatever the binder currently produces.
// These assert the multiply itself and the one property that makes it worth
// being a multiplier: it means the same thing after the base underneath it has
// moved, so a dragged dot re-derives without a stroke having to be redone.

// One dot's raw weight on one vertex, bound through the whole app path.
fn float weight_on(crig::AppState* app, uint vertex, uint dot)
{
	crig::RigView? opened = app.open_rig(mem);
	if (catch opened) return -1.0f;
	crig::RigView view = opened;
	defer view.free(mem);

	sz joint = view.joint_of(dot);
	if (joint < 0) return -1.0f;

	float[] dense = app.bind_dense(mem, &view);
	defer alloc::free(mem, dense);

	usz at = (usz)vertex * view.len() + (usz)joint;
	return at < dense.len ? dense[at] : -1.0f;
}

<*
 A dab scales exactly one dot's hold on exactly one vertex.

 The narrowest thing the layer promises, and the one a wrong row stride would
 break silently — a dab landing on the right vertex of the wrong joint still
 looks like paint doing something.
*>
fn void a_dab_scales_one_dots_hold_on_one_vertex() @test
{
	crig::AppState app = chained();
	defer app.free();

	uint hips = dot_named(&app, "hips");
	uint knee = dot_named(&app, "knee");

	float hips_was = weight_on(&app, 0, hips);
	float knee_was = weight_on(&app, 0, knee);
	float hips_elsewhere = weight_on(&app, 5, hips);

	test::@check(app.doc.set_paint(0, hips, 0.25f), "the dab took");

	test::@check(math::abs(weight_on(&app, 0, hips) - hips_was * 0.25f) < 1.0e-9f,
		"the painted column is scaled by exactly the factor");
	test::@check(weight_on(&app, 0, knee) == knee_was,
		"the other joints on that vertex are untouched");
	test::@check(weight_on(&app, 5, hips) == hips_elsewhere,
		"and the same joint on other vertices is untouched");
}

<*
 A correction outlives the base it was painted over.

 The whole reason the layer is multiplicative rather than additive. The binder
 returns `1 / (d^2 + eps)`, so moving the dot changes the base by orders of
 magnitude — an absolute correction would mean something different afterwards,
 while a ratio means the same thing. This is what lets a dot be dragged after a
 stroke without the stroke being redone.
*>
fn void a_dab_survives_the_dot_moving() @test
{
	crig::AppState app = chained();
	defer app.free();

	uint hips = dot_named(&app, "hips");
	test::@check(app.doc.set_paint(0, hips, 0.25f), "the dab took");

	app.doc.move_dot(hips, { 0, 0.8, 0 });

	// Re-derived from scratch at the new position, so this is not the old number.
	float painted = weight_on(&app, 0, hips);
	test::@check(app.doc.set_paint(0, hips, 1.0f), "clearing the dab took");
	float bare = weight_on(&app, 0, hips);

	test::@check(bare > 0.0f && math::abs(painted - bare * 0.25f) < 1.0e-9f,
		"the correction is still a quarter of whatever the binder now says");
}

<*
 A factor of one is stored as nothing.

 "Is anything painted" has to stay a length test, and a stroke that puts a vertex
 back where the binder had it should leave no trace — otherwise the layer grows
 forever under a brush being used to undo itself.
*>
fn void painting_back_to_one_leaves_nothing_behind() @test
{
	crig::AppState app = chained();
	defer app.free();

	uint hips = dot_named(&app, "hips");

	test::@check(app.doc.set_paint(0, hips, 0.5f) && app.doc.paint.len() == 1, "one dab stored");
	test::@check(!app.doc.set_paint(0, hips, 0.5f), "setting the same factor again changes nothing");
	test::@check(app.doc.set_paint(0, hips, 1.0f) && app.doc.paint.len() == 0, "back to one clears it");
	test::@check(!app.doc.set_paint(0, hips, 1.0f), "and clearing an absent dab is not a change");
	test::@check(app.doc.paint_of(0, hips) == 1.0f, "an unpainted vertex reads as no correction");
}

<*
 A dab on a dot that is no longer in the rig is skipped, not carried.

 The document keeps it so undo can bring it back with the dot — the rule the
 attachment and pose lists already follow — but there is no column to multiply
 while the dot is gone, and resolving one would land on whichever joint inherited
 the index.
*>
fn void a_dab_on_a_deleted_dot_binds_as_if_it_were_not_there() @test
{
	crig::AppState app = chained();
	defer app.free();

	uint hips = dot_named(&app, "hips");
	uint knee = dot_named(&app, "knee");
	test::@check(app.doc.set_paint(0, hips, 0.25f), "the dab took");

	float knee_was = weight_on(&app, 0, knee);
	app.doc.remove_dot(hips);

	test::@check(app.doc.paint.len() == 1, "the document still holds the dab for undo");
	test::@check(weight_on(&app, 0, knee) == knee_was,
		"but nothing in the rig that is left has been scaled by it");
}

<*
 The survey sees the paint.

 `get_weights` and the HUD read `survey_weights`, which binds for itself rather
 than reading whatever the screen last painted. That is deliberate — but it means
 the multiply has to be applied there too, or an agent asking who owns what gets
 the binder's opinion and the file gets a different one.
*>
fn void the_survey_counts_painted_weights() @test
{
	crig::AppState app = chained();
	defer app.free();

	uint hips = dot_named(&app, "hips");

	crig::WeightSurvey before = app.survey_weights(mem)!!;
	usz owned_before = 0;
	foreach (stake : before.stakes)
	{
		if (stake.dot == hips) owned_before = stake.owns;
	}
	before.free(mem);

	test::@check(owned_before > 0, "hips owns something to take away");

	// Nothing at all, everywhere: the strongest statement the layer can make.
	for (uint v = 0; v < (uint)cube_positions.len; v++) app.doc.set_paint(v, hips, 0.0f);

	crig::WeightSurvey after = app.survey_weights(mem)!!;
	defer after.free(mem);

	usz owned_after = 1;
	foreach (stake : after.stakes)
	{
		if (stake.dot == hips) owned_after = stake.owns;
	}
	test::@check(owned_after == 0, "a dot painted to nothing owns nothing in the survey");
}

<*
 The territory view sees the paint.

 Same reason as the survey, one step further out: the three tint views each bind
 for themselves, so each is its own chance for the picture to stop agreeing with
 the file. This is the one the user actually looks at.
*>
fn void the_territory_view_shows_painted_weights() @test
{
	crig::AppState app = chained();
	defer app.free();

	uint hips = dot_named(&app, "hips");

	app.show_tint(crig::TintMode.TERRITORY);
	app.rebind_tints();
	test::@check(app.tints.len == cube_positions.len, "the view painted every vertex");

	uint[8] before;
	foreach (usz i, tint : app.tints) before[i] = tint;

	for (uint v = 0; v < (uint)cube_positions.len; v++) app.doc.set_paint(v, hips, 0.0f);
	app.rebind_tints();

	usz moved = 0;
	foreach (usz i, tint : app.tints)
	{
		if (tint != before[i]) moved++;
	}
	test::@check(moved > 0, "painting a dot out of the rig recoloured the vertices it held");
}

<*
 The falloff view sees the paint.

 The third of the three binds a user can be looking at, and the one reach mode
 leaves on screen — so it is the view a stroke is most likely to be judged
 against. `F` shows one joint's share of every vertex on a ramp, and a share that
 ignored the correction would show a hold the file does not have.
*>
fn void the_falloff_view_shows_painted_weights() @test
{
	crig::AppState app = chained();
	defer app.free();

	uint hips = dot_named(&app, "hips");
	app.selected = hips;

	app.show_tint(crig::TintMode.FALLOFF);
	app.rebind_tints();
	test::@check(app.tints.len == cube_positions.len, "the view painted every vertex");

	uint[8] before;
	foreach (usz i, tint : app.tints) before[i] = tint;

	for (uint v = 0; v < (uint)cube_positions.len; v++) app.doc.set_paint(v, hips, 0.0f);
	app.rebind_tints();

	usz moved = 0;
	foreach (usz i, tint : app.tints)
	{
		if (tint != before[i]) moved++;
	}
	test::@check(moved > 0, "painting the selected dot to nothing changed its ramp");
}

<*
 Every one-joint view reads on the Weights card's scale: grey where the joint
 holds nothing, orange where it holds everything.
*>
fn void the_falloff_view_runs_grey_to_orange() @test
{
	crig::AppState app = chained();
	defer app.free();

	uint hips = dot_named(&app, "hips");
	app.selected = hips;
	for (uint v = 0; v < (uint)cube_positions.len; v++) app.doc.set_paint(v, hips, 0.0f);
	app.show_tint(crig::TintMode.FALLOFF);
	app.rebind_tints();
	foreach (usz i, tint : app.tints)
	{
		test::@check(tint == crig::share_tint(0.0f), "vertex %d the hips do not hold is %x, not grey", i, tint);
	}

	uint grey = crig::share_tint(0.0f);
	uint half = crig::share_tint(0.5f);
	uint orange = crig::share_tint(1.0f);
	test::@check((grey & 0xFF) < (half & 0xFF) && (half & 0xFF) < (orange & 0xFF), "the ramp does not redden as the share rises");
	test::@check(((orange >> 16) & 0xFF) < ((grey >> 16) & 0xFF), "full weight is not orange");
}

// ---------------------------------------------------------------------------
// Strokes and the ledger
//
// The second payload type on the undo stack, and the first proof that the store
// built for clips is actually generic rather than clip-shaped. A stroke is one
// step over thousands of vertices — an edit per vertex would make Ctrl+Z useless
// exactly where it is most wanted.

<*
 A stroke is one undo step however many vertices it touched.
*>
fn void a_stroke_undoes_in_one_step() @test
{
	crig::AppState app = chained();
	defer app.free();

	uint hips = dot_named(&app, "hips");

	crig::PaintDab[4] stroke = {
		{ .vertex = 0, .dot_id = hips, .factor = 0.25f },
		{ .vertex = 1, .dot_id = hips, .factor = 0.25f },
		{ .vertex = 2, .dot_id = hips, .factor = 0.5f },
		{ .vertex = 3, .dot_id = hips, .factor = 0.5f },
	};

	test::eq(app.paint_dabs(stroke[..]), (usz)4);
	test::eq(app.doc.paint.len(), (sz)4);

	test::@check(app.undo(), "the stroke is one step on the ledger");
	test::eq(app.doc.paint.len(), (sz)0);

	test::@check(app.redo(), "and it redoes as one step");
	test::eq(app.doc.paint.len(), (sz)4);
	test::@check(app.doc.paint_of(2, hips) == 0.5f, "with every dab's own factor, not one of them repeated");
}

<*
 A stroke over already-painted mesh remembers what was underneath it.

 The reason a change carries both sides. The previous factor is not recoverable
 from the binder — that gives the base, not the correction that was there — so an
 undo that recomputed instead of remembering would silently clear the earlier
 stroke as well.
*>
fn void a_stroke_undoes_to_the_stroke_beneath_it() @test
{
	crig::AppState app = chained();
	defer app.free();

	uint hips = dot_named(&app, "hips");

	crig::PaintDab[1] first = {{ .vertex = 0, .dot_id = hips, .factor = 0.25f }};
	crig::PaintDab[1] second = {{ .vertex = 0, .dot_id = hips, .factor = 0.75f }};

	app.paint_dabs(first[..]);
	app.paint_dabs(second[..]);
	test::@check(app.doc.paint_of(0, hips) == 0.75f, "the second stroke is what stands");

	test::@check(app.undo(), "taking back the second");
	test::@check(app.doc.paint_of(0, hips) == 0.25f, "leaves the first, not bare mesh");

	test::@check(app.undo(), "taking back the first");
	test::@check(app.doc.paint_of(0, hips) == 1.0f, "leaves nothing");
}

<*
 A stroke that changes nothing records nothing.

 What makes it safe to call on every mouse move: a brush dragged back over mesh
 it has already painted to the same value must not fill the history with steps
 that undo to themselves.
*>
fn void a_stroke_that_changes_nothing_is_not_recorded() @test
{
	crig::AppState app = chained();
	defer app.free();

	uint hips = dot_named(&app, "hips");
	crig::PaintDab[1] dab = {{ .vertex = 0, .dot_id = hips, .factor = 0.25f }};

	test::eq(app.paint_dabs(dab[..]), (usz)1);
	sz after_first = app.undo_stack.edits.len();

	test::eq(app.paint_dabs(dab[..]), (usz)0);
	test::eq(app.undo_stack.edits.len(), after_first);
}

<*
 Forking the timeline drops the abandoned stroke's range.

 The stroke store is a stack for the same reason the clip store is, and this is
 the path that proves it: a range dropped from anywhere but the top would leave
 the next stroke's indices pointing at somebody else's numbers. The precondition
 in `drop_last` fires if it ever does.
*>
fn void forking_the_timeline_drops_the_abandoned_stroke() @test
{
	crig::AppState app = chained();
	defer app.free();

	uint hips = dot_named(&app, "hips");
	crig::PaintDab[1] first = {{ .vertex = 0, .dot_id = hips, .factor = 0.25f }};
	crig::PaintDab[2] second = {
		{ .vertex = 1, .dot_id = hips, .factor = 0.5f },
		{ .vertex = 2, .dot_id = hips, .factor = 0.5f },
	};

	app.paint_dabs(first[..]);
	app.paint_dabs(second[..]);
	test::@check(app.undo(), "step back over the second stroke");
	test::@check(app.undo_stack.can_redo(), "it is sitting in the redo tail");

	// A third stroke forks the timeline, discarding the second's range.
	crig::PaintDab[1] third = {{ .vertex = 3, .dot_id = hips, .factor = 0.1f }};
	app.paint_dabs(third[..]);

	test::@check(!app.undo_stack.can_redo(), "the tail is gone");
	test::@check(app.doc.paint_of(0, hips) == 0.25f && app.doc.paint_of(3, hips) == 0.1f,
		"the branch that was kept is intact");
	test::@check(app.doc.paint_of(1, hips) == 1.0f, "and the abandoned one left nothing behind");

	// Both surviving strokes back off, which walks the store down to empty.
	test::@check(app.undo() && app.undo(), "both surviving strokes still undo");
	test::eq(app.doc.paint.len(), (sz)0);
}

<*
 Clearing takes the whole layer off in one step.
*>
fn void clearing_the_paint_is_one_step() @test
{
	crig::AppState app = chained();
	defer app.free();

	uint hips = dot_named(&app, "hips");
	crig::PaintDab[2] stroke = {
		{ .vertex = 0, .dot_id = hips, .factor = 0.25f },
		{ .vertex = 1, .dot_id = hips, .factor = 0.5f },
	};
	app.paint_dabs(stroke[..]);

	test::eq(app.clear_paint(), (usz)2);
	test::eq(app.doc.paint.len(), (sz)0);

	test::@check(app.undo(), "the clear is one step");
	test::@check(app.doc.paint_of(0, hips) == 0.25f && app.doc.paint_of(1, hips) == 0.5f,
		"and it comes back with each dab's own factor");

	test::@check(app.redo() && app.doc.paint.len() == 0, "the clear redoes");
	test::@check(app.clear_paint() == 0, "clearing an empty layer is not a step");
}

// ---------------------------------------------------------------------------
// The share verb
//
// The one thing a caller says out loud. Everything under it is multipliers,
// which mean nothing without knowing the base; a share means the same thing at
// every vertex and either side of the renormalisation. So what these assert is
// that asking for a share and then measuring it gives the number back.

// One dot's share of one vertex, normalised the way the views and the file are.
fn float share_of(crig::AppState* app, uint vertex, uint dot)
{
	crig::RigView? opened = app.open_rig(mem);
	if (catch opened) return -1.0f;
	crig::RigView view = opened;
	defer view.free(mem);

	sz joint = view.joint_of(dot);
	if (joint < 0) return -1.0f;

	float[] dense = app.bind_dense(mem, &view);
	defer alloc::free(mem, dense);

	usz bones = view.len();
	usz at = (usz)vertex * bones;
	float sum = 0.0f;
	for (usz b = 0; b < bones; b++) sum += dense[at + b];
	return sum > 0.0f ? dense[at + (usz)joint] / sum : 0.0f;
}

<*
 A share asked for is the share measured.

 The whole verb in one check. If this holds, the solve is right; if it drifts,
 every layer above it is describing something the file does not contain.
*>
fn void a_share_asked_for_is_the_share_measured() @test
{
	crig::AppState app = chained();
	defer app.free();

	uint hips = dot_named(&app, "hips");
	uint[1] one = { 0 };

	float[4] targets = { 0.0f, 0.1f, 0.5f, 0.85f };
	foreach (want : targets)
	{
		crig::PaintResult did = app.paint_share(hips, one[..], want);
		test::@check(did.unreachable == 0 && did.alone == 0,
			"the vertex can be given a share of %s", want);
		test::@check(math::abs(share_of(&app, 0, hips) - want) < 1.0e-5f,
			"asked for %s, measured %s", want, share_of(&app, 0, hips));
	}
}

<*
 The brush states shares, so it can raise a joint the vertex gave nothing — which
 no multiplier can — and a stroke of several moves is one undo step.
*>
fn void the_brush_raises_a_zero_weight_in_one_step() @test
{
	crig::AppState app = chained();
	defer app.free();

	uint hips = dot_named(&app, "hips");
	uint knee = dot_named(&app, "knee");
	uint[1] one = { 0 };

	// Vertex 0 wholly the hips', so the knee holds exactly nothing there.
	app.pin_vertices(one[..], hips, 1.0f);
	test::@check(share_of(&app, 0, knee) == 0.0f, "the knee did not start at nothing");

	app.begin_stroke();
	float[1] half = { 0.5f };
	test::@check(app.brush_share(knee, one[..], 1.0f, half[..]) > 0, "the dab changed nothing");
	float first = share_of(&app, 0, knee);
	test::@check(math::abs(first - 0.5f) < 1.0e-5f, "a half pull from nothing landed at %f", first);
	app.brush_share(knee, one[..], 1.0f, half[..]);
	test::@check(math::abs(share_of(&app, 0, knee) - 0.75f) < 1.0e-5f,
		"a second half pull landed at %f", share_of(&app, 0, knee));
	app.end_stroke();

	test::@check(app.undo(), "the stroke left nothing to undo");
	test::@check(share_of(&app, 0, knee) == 0.0f, "one undo left the knee at %f", share_of(&app, 0, knee));
	test::@check(math::abs(share_of(&app, 0, hips) - 1.0f) < 1.0e-5f, "undo did not give the hips the vertex back");

	// Taking off goes all the way to nothing too.
	app.redo();
	app.begin_stroke();
	float[1] all = { 1.0f };
	app.brush_share(knee, one[..], 0.0f, all[..]);
	app.end_stroke();
	test::@check(share_of(&app, 0, knee) == 0.0f, "a full take-off left %f", share_of(&app, 0, knee));
}

<*
 A share is relative to the rig as it now stands.

 `R` in the solve is the *painted* total of the other dots, not the binder's — so
 painting one dot down gives the room up and the next dot asked for a share takes
 it from what is left. A solve against the raw base would drift the moment two
 dots were painted on the same vertex.
*>
fn void shares_compose_across_two_dots() @test
{
	crig::AppState app = chained();
	defer app.free();

	uint hips = dot_named(&app, "hips");
	uint knee = dot_named(&app, "knee");
	uint[1] one = { 0 };

	app.paint_share(hips, one[..], 0.25f);
	app.paint_share(knee, one[..], 0.5f);

	test::@check(math::abs(share_of(&app, 0, knee) - 0.5f) < 1.0e-5f,
		"the second dot got exactly what it asked for");
	// hips kept a quarter of what was left over after knee took half.
	test::@check(share_of(&app, 0, hips) > 0.0f && share_of(&app, 0, hips) < 0.25f,
		"and the first gave up room rather than holding its old number");
}

<*
 A share of one is not reachable, and the ceiling is what happens instead.

 Exactly 1 would mean every other dot holds nothing — a statement about those
 dots, not this one — so the request stops just short and the others keep
 whatever they were given.
*>
fn void asking_for_all_of_a_vertex_stops_at_the_ceiling() @test
{
	crig::AppState app = chained();
	defer app.free();

	uint hips = dot_named(&app, "hips");
	uint[1] one = { 0 };

	app.paint_share(hips, one[..], 1.0f);

	float got = share_of(&app, 0, hips);
	test::@check(math::abs(got - crig::PAINT_SHARE_CEILING) < 1.0e-4f,
		"asking for all of it lands on the ceiling, measured %s", got);
	test::@check(got < 1.0f, "and never actually reaches one");
}

<*
 A dot that already holds the whole vertex has no share to give up.

 Not caller error — the rig is saying there is no second dot near enough to take
 what is offered, and a solve would divide by the nothing that is left.
*>
fn void a_lone_dot_reports_that_there_is_no_share_to_take() @test
{
	crig::AppState app = shared_app::open_cube();
	defer app.free();

	uint only = app.doc.add_dot({ 0, 0, 0 }, "only");
	uint[1] one = { 0 };

	crig::PaintResult did = app.paint_share(only, one[..], 0.5f);
	test::@check(did.alone == 1 && did.changed == 0,
		"a one-dot rig cannot give half of a vertex to anything else");
	test::@check(app.doc.paint.len() == 0, "and nothing was written");
}

<*
 The correction outlives the share it was solved for.

 The documented bargain, asserted rather than assumed: `p` is stored and `b` is
 not, so moving the dot moves the share. A test that expected the share to hold
 would be describing an auto-rig that stops helping the moment it is touched.
*>
fn void a_share_drifts_when_the_dot_moves() @test
{
	crig::AppState app = chained();
	defer app.free();

	uint hips = dot_named(&app, "hips");
	uint[1] one = { 0 };

	app.paint_share(hips, one[..], 0.5f);
	test::@check(math::abs(share_of(&app, 0, hips) - 0.5f) < 1.0e-5f, "solved to a half");

	// Toward vertex 0 at (-1,-1,-1), and it has to be *toward*. Moving it the
	// other way changes nothing measurable: hips' bone runs down to knee, and
	// `segment_distance_sq` clamps to the segment — so for a vertex behind the
	// joint the closest point is the knee end either way, and the base does not
	// move. The same clamping PLAN.md calls the sibling tie.
	app.doc.move_dot(hips, { -0.9, -0.9, -0.9 });

	test::@check(math::abs(share_of(&app, 0, hips) - 0.5f) > 1.0e-4f,
		"moving the dot moves the share, because the correction is a ratio and not a value");
	test::@check(app.doc.paint.len() == 1, "the correction itself is untouched");
}

<*
 A share request is one undoable stroke over every vertex it touched.
*>
fn void a_share_request_is_one_step() @test
{
	crig::AppState app = chained();
	defer app.free();

	uint hips = dot_named(&app, "hips");
	uint[4] some = { 0, 1, 2, 3 };

	crig::PaintResult did = app.paint_share(hips, some[..], 0.2f);
	test::eq(did.changed, (usz)4);

	test::@check(app.undo(), "the whole request is one step");
	test::eq(app.doc.paint.len(), (sz)0);
}

// ---------------------------------------------------------------------------
// What live use turned up
//
// Four things the tests above could not have caught, because each is about the
// mode being *used* rather than about the arithmetic: two modes open at once,
// a view that never repaints while the hand is moving, and a brush with two
// settings and nothing between them.

<*
 The Area tool and the brush cannot both be open: both claim a press on the
 mesh for the selected joint.
*>
fn void the_brush_and_the_area_tool_are_exclusive() @test
{
	crig::AppState app = chained();
	defer app.free();

	app.select(dot_named(&app, "hips"));

	test::@check(app.begin_area(), "the Area tool opened");
	test::@check(app.begin_brush(), "the brush opened over it");
	test::@check(!app.areaing, "opening the brush left the Area tool open underneath it");

	test::@check(app.begin_area(), "the Area tool opened again");
	test::@check(!app.brushing, "opening the Area tool left the brush open underneath it");
	app.end_area();
}

<*
 A clip parked with the knee bent, so the brush has a posed body to aim at.

 The chain fixture keyed once through the same door the viewport's G uses:
 `key_pose_edit` lands the draft and parks the clip at the keyed frame, which
 leaves `animating` set with the clock stopped — the state the animation
 workspace sits in between edits. Returns the knee.
*>
fn uint park_bent_knee(crig::AppState* app)
{
	uint knee = dot_named(app, "knee");
	AnimRef clip = app.new_clip("bend", 1.0f, from_rest: true);
	app.editing = clip;
	Quaternionf turn = quaternion::from_axis_angle{float}(((Vec3){ 0, 0, 1 }), 1.2f);
	if (!app.pose_from_clip(clip, 0.0f) || !app.set_working_pose(knee, turn, {})) return 0;
	app.pose_edit_pending = true;
	if (!app.key_pose_edit()) return 0;
	return knee;
}

<*
 The brush opens over a parked clip and paints the body on screen, not the one
 it was modelled in.

 The whole reason to paint a pose: a fold is only visible while the joint is
 bent, and the animation workspace is where every joint is. So the stroke reads
 the vertices where the palette put them — a circle around a posed vertex's
 pixel takes it, and a circle around the rest-pose pixel it left behind does
 not — and the mesh reskins as the stroke lands, without the clip being stopped.

 The accelerator over the skin is the one thing a stroke puts off: it stands
 while the button is down and is rebuilt once on release, so the frames in
 between pay for a sparsify and an upload rather than a mirrored tree.
*>
fn void the_brush_paints_the_posed_body_under_a_parked_clip() @test
{
	crig::AppState app = chained();
	defer app.free();

	uint knee = park_bent_knee(&app);
	test::@check(knee != 0, "the fixture could not key a bent knee");
	test::@check(app.animating && app.anim_paused && app.rig_locked(),
		"keying the pose did not leave the clip parked");
	test::@check(app.posed_surface_shown(), "the parked clip put no posed surface on screen");

	app.select(knee);
	test::@check(app.begin_brush(), "the brush refused to open over the parked clip");
	test::@check(app.animating && app.anim_paused, "opening the brush stopped the clip");

	// The posed vertex nearest the eye that the bend actually moved: in sight by
	// construction, and far enough from its rest position for the two pixels
	// to be told apart.
	Vec2 viewport = { 800, 600 };
	Matrix4f vp = app.camera.view_projection(viewport.x / viewport.y);
	Vec3 eye = app.camera.eye();
	usz count = app.geometry.positions.len;
	usz chosen = count;
	float nearest = float::max;
	for (usz v = 0; v < count; v++)
	{
		Vec3 posed = app.shown_position(v);
		if ((posed - app.geometry.positions[v]).length() < 0.2f) continue;
		float gap = (posed - eye).length();
		if (gap < nearest) { nearest = gap; chosen = v; }
	}
	test::@check(chosen < count, "the bend moved no vertex of the cube");
	Vec2 posed_pixel = crig::project(vp, app.shown_position(chosen), viewport)!!;
	Vec2 rest_pixel = crig::project(vp, app.geometry.positions[chosen], viewport)!!;
	float radius = 6.0f;
	test::@check((posed_pixel - rest_pixel).length() > 2.0f * radius,
		"the bend moved the vertex only %.1f px on screen — the two circles overlap",
		(posed_pixel - rest_pixel).length());

	uint[] under = alloc::new_array(mem, uint, (sz)count);
	defer alloc::free(mem, under);
	float[] strength = alloc::new_array(mem, float, (sz)count);
	defer alloc::free(mem, strength);

	usz at_posed = app.brush_vertices(under, strength, vp, viewport, eye, posed_pixel, radius);
	bool took = false;
	for (usz i = 0; i < at_posed; i++) took = took || under[i] == (uint)chosen;
	test::@check(took, "a circle around the posed vertex's pixel did not take it (%d under it)", at_posed);

	usz at_rest = app.brush_vertices(under, strength, vp, viewport, eye, rest_pixel, radius);
	bool ghost = false;
	for (usz i = 0; i < at_rest; i++) ghost = ghost || under[i] == (uint)chosen;
	test::@check(!ghost, "a circle around the rest-pose pixel took the vertex the pose moved away");

	// A stroke: the knee comes off the vertex, the skin on screen follows on
	// the same call, and the clip stays parked throughout.
	sz joint;
	{
		RigView view = app.open_rig(mem)!!;
		defer view.free(mem);
		joint = view.joint_of(knee);
	}
	float before = skin_weight(&app, chosen, joint);
	test::@check(before > 0.0f, "the fixture's knee holds none of the chosen vertex to begin with");

	uint skin_was = app.skin_generation;
	app.begin_stroke();
	usz hit = app.brush_vertices(under, strength, vp, viewport, eye, posed_pixel, radius);
	for (usz i = 0; i < hit; i++) strength[i] = app.stroke_pull(under[i], strength[i]);
	crig::PaintResult did = app.paint_share(knee, under[:hit], 0.0f, strength[:hit]);
	test::@check(did.changed > 0, "the stroke changed nothing");
	test::@check(app.skin_generation > skin_was, "the stroke did not reskin the parked body");
	test::@check(skin_weight(&app, chosen, joint) < before,
		"the reskinned body still gives the knee %.3f of the vertex, was %.3f",
		skin_weight(&app, chosen, joint), before);
	test::@check(app.stroke_open && app.surface_stale && app.deformed_surface.root != null,
		"the stroke rebuilt the posed surface on the move rather than leaving it standing");
	test::@check(app.animating && app.anim_paused && app.pose_palette.len > 0,
		"the stroke took the clip down");

	app.end_stroke();
	test::@check(!app.stroke_open && !app.surface_stale,
		"lifting the button did not rebuild the posed surface");
	test::@check(app.posed_surface_shown(), "the rebuilt surface does not serve the palette on screen");

	// Rest-mesh tools stay off: the clip is still parked, and painting has not
	// made the body on screen the one a dot would be placed in.
	test::@check(app.rig_locked(), "painting over the clip unlocked the rest rig");
	app.end_brush();
}

// The sparse weight the GPU is given for `joint` at `vertex`, or 0 when the
// joint is not among its influences.
fn float skin_weight(crig::AppState* app, usz vertex, sz joint)
{
	if (joint < 0 || app.skin.slots == 0) return 0.0f;
	usz base = vertex * (usz)app.skin.slots;
	for (uint slot = 0; slot < app.skin.slots; slot++)
	{
		if ((sz)app.skin.joints[base + slot] == joint) return app.skin.weights[base + slot];
	}
	return 0.0f;
}

<*
 A rig edit under a parked clip reaches the body on screen once the hand is
 still.

 A paused player skips its tick and a draft never has one, so nothing rebinds
 the skin after a reach notch or a dot drag: the tints caught up on the
 debounce and the body did not, until the playhead happened to move. Now the
 skin runs on the same timer — a stream of notches is one bind, and the body
 follows the last of them.
*>
fn void a_rig_edit_under_a_parked_clip_reskins_after_the_debounce() @test
{
	crig::AppState app = chained();
	defer app.free();

	uint knee = park_bent_knee(&app);
	test::@check(knee != 0, "the fixture could not key a bent knee");
	uint skin_was = app.skin_generation;

	test::@check(app.set_reach_recorded(knee, 0.4f), "the reach would not set");
	app.undo_stack.commit();
	app.mark_rig_stale();
	test::@check(app.skin_stale && app.skin_generation == skin_was,
		"a reach change rebound the skin on the spot rather than waiting for the hand to still");
	test::@check(app.ticking(), "a parked body waiting on a rebind asked for no frames");

	app.tick_skin(crig::WEIGHT_DEBOUNCE * 0.5f);
	test::@check(app.skin_generation == skin_was, "the skin rebound before the debounce ran out");
	// A second edit inside the window starts it over, the way the tints' does.
	app.mark_rig_stale();
	app.tick_skin(crig::WEIGHT_DEBOUNCE * 0.75f);
	test::@check(app.skin_generation == skin_was, "a second edit did not restart the countdown");

	app.tick_skin(crig::WEIGHT_DEBOUNCE);
	test::@check(app.skin_generation > skin_was && !app.skin_stale,
		"the parked body did not reskin once the hand was still");
	test::@check(app.animating && app.anim_paused && app.posed_surface_shown(),
		"the rebind took the clip down");
}

<*
 Opening the brush over a *running* clip parks it where it is.

 A body walking out from under the circle is not one anybody can aim at, and
 stopping playback outright would put the mesh back at rest — the one thing a
 user opening a brush over a pose did not ask for. So the clock stops, the
 same way a scrub stops it, and the playhead lands on the frame that was
 showing.
*>
fn void the_brush_parks_a_running_clip() @test
{
	crig::AppState app = chained();
	defer app.free();

	uint knee = park_bent_knee(&app);
	test::@check(knee != 0, "the fixture could not key a bent knee");
	app.resume_clip();
	test::@check(app.animating && !app.anim_paused, "the clip did not resume");
	app.anim_time = 0.4f;

	app.select(knee);
	test::@check(app.begin_brush(), "the brush refused to open over the running clip");
	test::@check(app.animating && app.anim_paused, "opening the brush did not park the clip");
	test::@check(app.edit_time == 0.4f, "the playhead did not land where the clip was stopped (%.2f)", app.edit_time);
	app.end_brush();
	test::@check(app.animating && app.anim_paused, "closing the brush changed the clip's state");
}

<*
 A cube with one dot on the plane and one off it, to mirror paint across.

 The corners are the whole mesh, and the cube is symmetric about x = 0, so
 every corner's reflection is another corner: -1 ↔ +1 in x with y and z kept,
 which in `cube_positions` pairs 0↔1, 3↔2, 4↔5 and 7↔6. Returns the off-plane
 dot; the plane one is there so the rig has a bone.
*>
fn uint arm_over_the_cube(crig::AppState* app)
{
	uint hip = app.add_recorded({ 0, 0, 0 }, "hip");
	uint arm = app.add_recorded({ -0.5f, 0.5f, 0 }, "arm_L");
	app.connect_recorded(hip, arm);
	app.undo_stack.commit();
	return arm;
}

<*
 Mirroring a dot carries its paint and pins across to the twin, at the
 mirror-image vertices, in the same undo step.

 Painting one side and mirroring is the whole workflow — nobody wants to fix
 the same fold twice — and a twin that arrived in the right place with a clean
 layer was a twin that still had to be painted. The vertex mapping is the
 part that can be wrong quietly, so it is asserted corner by corner.
*>
fn void a_mirrored_dot_takes_its_paint_with_it() @test
{
	crig::AppState app = shared_app::open_cube();
	defer app.free();

	uint arm = arm_over_the_cube(&app);
	// The other side is already placed, exactly across the plane. Mirror crosses
	// the paint onto it — it never makes the twin.
	uint twin = app.add_recorded({ 0.5f, 0.5f, 0 }, "arm_R");
	app.connect_recorded(dot_named(&app, "hip"), twin);
	app.undo_stack.commit();

	crig::PaintDab[2] dabs = {
		{ .vertex = 0, .dot_id = arm, .factor = 0.3f },
		{ .vertex = 7, .dot_id = arm, .factor = 0.6f },
	};
	test::eq(app.paint_dabs(dabs[..]), (usz)2);
	crig::VertexPin[1] pins = {{ .vertex = 4, .dot_id = arm, .share = 0.8f }};
	test::eq(app.pin_dabs(pins[..]), (usz)1);
	sz history = app.undo_stack.cursor;

	app.select(arm);
	usz moved;
	usz square;
	usz unmatched;
	bool painted;
	usz total = app.mirror_selection(&moved, &square, &unmatched, &painted);
	test::@check(total == 1 && moved == 1 && unmatched == 0, "the arm's paint did not cross (total %d, moved %d, unmatched %d)", total, moved, unmatched);
	test::@check(painted, "the mirror did not report the paint crossing");

	test::@check(app.doc.paint_of(1, twin) == 0.3f, "corner 0's dab did not land on corner 1 (%.2f)", app.doc.paint_of(1, twin));
	test::@check(app.doc.paint_of(6, twin) == 0.6f, "corner 7's dab did not land on corner 6 (%.2f)", app.doc.paint_of(6, twin));
	test::@check(app.doc.pin_of(5, twin) == 0.8f, "corner 4's pin did not land on corner 5 (%.2f)", app.doc.pin_of(5, twin));
	test::@check(app.doc.paint_of(0, twin) == 1.0f && app.doc.paint_of(0, arm) == 0.3f,
		"the crossing painted the wrong side");
	test::eq(app.doc.paint.len(), (sz)4);
	test::eq(app.doc.pins.len(), (sz)2);

	// One undo takes the paint back off the twin — the twin dot stays, it was
	// there before the mirror; one redo brings the crossed paint back.
	test::@check(app.undo(), "the mirror would not undo");
	test::eq(app.undo_stack.cursor, history);
	test::@check(dot_named(&app, "arm_R") == twin, "undo disturbed the pre-placed twin");
	test::eq(app.doc.paint.len(), (sz)2);
	test::eq(app.doc.pins.len(), (sz)1);
	test::@check(app.redo(), "the mirror would not redo");
	test::@check(app.doc.paint_of(1, twin) == 0.3f && app.doc.pin_of(5, twin) == 0.8f,
		"redo did not bring the twin's paint back");
}

<*
 The twin's own paint is overwritten by the source's, the way its position and
 reach are — and a twin already carrying the right paint is already in place.

 "The selection is the side that survives" has to hold for the layer too, or
 mirroring a repainted side onto a twin painted last week would merge the two
 into something nobody painted. A vertex the source leaves clean is cleared on
 the twin; a vertex with no partner across the plane is left alone, since the
 source says nothing about it.
*>
fn void mirroring_overwrites_the_twins_paint_with_the_sources() @test
{
	crig::AppState app = shared_app::open_cube();
	defer app.free();

	uint arm = arm_over_the_cube(&app);
	uint twin = app.add_recorded({ 0.5f, 0.5f, 0 }, "arm_R");
	app.connect_recorded(dot_named(&app, "hip"), twin);
	app.undo_stack.commit();

	crig::PaintDab[3] dabs = {
		{ .vertex = 0, .dot_id = arm, .factor = 0.3f },  // crosses onto corner 1
		{ .vertex = 1, .dot_id = twin, .factor = 0.9f }, // overwritten by it
		{ .vertex = 2, .dot_id = twin, .factor = 0.1f }, // corner 3 is clean on the source: cleared
	};
	test::eq(app.paint_dabs(dabs[..]), (usz)3);

	app.select(arm);
	usz moved;
	usz square;
	usz unmatched;
	bool painted;
	usz total = app.mirror_selection(&moved, &square, &unmatched, &painted);
	test::@check(total == 1 && moved == 1 && unmatched == 0 && painted,
		"a square twin with the wrong paint was not pulled into line (total %d, moved %d)", total, moved);
	test::@check(app.doc.paint_of(1, twin) == 0.3f, "the source's dab did not overwrite the twin's (%.2f)", app.doc.paint_of(1, twin));
	test::@check(app.doc.paint_of(2, twin) == 1.0f, "a dab the source has no partner for was kept (%.2f)", app.doc.paint_of(2, twin));
	test::eq(app.doc.paint.len(), (sz)2);

	// Mirrored again, there is nothing left to do — and the notice can say so.
	total = app.mirror_selection(&moved, &square, &unmatched, &painted);
	test::@check(total == 0 && square == 1 && !painted,
		"a twin whose paint already matches was mirrored again (total %d, square %d)", total, square);
}

<*
 A stroke asks for the view back at once; a rig edit still waits.

 `WEIGHT_DEBOUNCE` swallows a stream of rig edits, each of which needs a full
 geodesic bind. A stroke is also a stream but it moves no dot, so there is
 nothing expensive to defer — and because every mouse move restarts the timer,
 debouncing it means the picture never arrives until the hand stops. That is not
 a slow brush, it is one that looks like it has jammed.
*>
fn void painting_does_not_wait_for_the_debounce() @test
{
	crig::AppState app = chained();
	defer app.free();

	uint hips = dot_named(&app, "hips");
	crig::PaintDab[1] dab = {{ .vertex = 0, .dot_id = hips, .factor = 0.5f }};

	app.mark_rig_stale();
	test::@check(app.weights_due > 0.0f, "a rig edit stopped waiting out its debounce");

	app.paint_dabs(dab[..]);
	test::@check(app.weights_due == 0.0f, "a stroke was made to wait out the rig debounce");
	test::@check(app.weights_stale, "and it did not ask for the view back at all");
}

<*
 The base bind is kept across a stroke and dropped when the rig moves.

 The whole reason a stroke can repaint per frame: a bind is a pass over every
 vertex against every bone through the voxel grid, and applying a correction is
 one multiply per dab. Caching the half a stroke does not change is what makes
 the immediate answer affordable.
*>
fn void a_stroke_keeps_the_bind_underneath_it() @test
{
	crig::AppState app = chained();
	defer app.free();

	uint hips = dot_named(&app, "hips");
	app.select(hips);
	app.show_tint(crig::TintMode.FALLOFF);
	app.rebind_tints();
	test::@check(app.base_bind.len > 0, "the view did not leave a bind behind to reuse");

	crig::PaintDab[1] dab = {{ .vertex = 0, .dot_id = hips, .factor = 0.5f }};
	app.paint_dabs(dab[..]);
	test::@check(app.base_bind.len > 0, "a stroke threw away the bind it did not change");

	app.mark_rig_stale();
	test::@check(app.base_bind.len == 0, "moving the rig kept a bind that no longer describes it");
}

<*
 A stroke depends on where the circle passed, not on how long it was held there.

 The brush's whole promise, and the reason the radial falloff is the mechanism
 rather than a flow rate: the same gesture twice has to give the same answer.
 `stroke_pull` asks for the part of the falloff this stroke has not already
 given, so a hand that stops moving asks for nothing — while a *new* stroke
 starts the memory over, which is the one place repetition should count because
 it is the one the hand meant.
*>
fn void a_stroke_depends_on_where_it_passed_not_how_long() @test
{
	crig::AppState app = chained();
	defer app.free();

	uint hips = dot_named(&app, "hips");
	uint[1] one = { 0 };

	app.paint_share(hips, one[..], 0.8f);
	test::@check(math::abs(share_of(&app, 0, hips) - 0.8f) < 1.0e-5f, "the starting share was not set");

	// One stroke, the rim of the circle over this vertex the whole way.
	app.begin_stroke();
	float[1] pull = { app.stroke_pull(0, 0.5f) };
	app.paint_share(hips, one[..], 0.0f, pull[..]);
	float after = share_of(&app, 0, hips);
	test::@check(math::abs(after - 0.4f) < 1.0e-5f,
		"half of the way from 0.8 toward 0 is 0.4, measured %s", after);

	// Held still: the same distance, over and over, and nothing more is owed.
	for (usz i = 0; i < 20; i++)
	{
		float[1] again = { app.stroke_pull(0, 0.5f) };
		test::@check(again[0] == 0.0f, "dwelling at the same distance asked for more pull");
		app.paint_share(hips, one[..], 0.0f, again[..]);
	}
	test::@check(math::abs(share_of(&app, 0, hips) - after) < 1.0e-6f,
		"holding the brush still moved the vertex");

	// Closer in, same stroke: the extra is owed and the total is the new falloff.
	float[1] closer = { app.stroke_pull(0, 0.75f) };
	app.paint_share(hips, one[..], 0.0f, closer[..]);
	test::@check(math::abs(share_of(&app, 0, hips) - 0.2f) < 1.0e-5f,
		"three quarters of the way from 0.8 is 0.2, measured %s", share_of(&app, 0, hips));

	// A second stroke starts the memory over, so it can carry further.
	app.begin_stroke();
	float[1] fresh = { app.stroke_pull(0, 0.75f) };
	test::@check(fresh[0] > 0.0f, "a new stroke was still owed nothing from the last one");
}

<*
 A partial request moves a vertex part of the way, and repeating it goes further.

 The layer underneath the brush, which knows nothing about strokes: `paint_share`
 blends from where the vertex is toward the target, so composing two pulls lands
 further than one and never overshoots. `stroke_pull` is what turns that into a
 gesture that does not depend on dwelling.
*>
fn void a_partial_request_lands_part_of_the_way() @test
{
	crig::AppState app = chained();
	defer app.free();

	uint hips = dot_named(&app, "hips");
	uint[1] one = { 0 };
	float[1] half = { 0.5f };

	// From a known starting point, so the fractions below are predictable.
	app.paint_share(hips, one[..], 0.8f);
	float start = share_of(&app, 0, hips);
	test::@check(math::abs(start - 0.8f) < 1.0e-5f, "the starting share was not set");

	app.paint_share(hips, one[..], 0.0f, half[..]);
	float once = share_of(&app, 0, hips);
	test::@check(math::abs(once - 0.4f) < 1.0e-5f,
		"half way from 0.8 toward 0 is 0.4, measured %s", once);

	app.paint_share(hips, one[..], 0.0f, half[..]);
	float twice = share_of(&app, 0, hips);
	test::@check(math::abs(twice - 0.2f) < 1.0e-5f,
		"and again is 0.2, measured %s", twice);

	// It approaches the target and never crosses it, however many times it runs.
	for (usz i = 0; i < 40; i++) app.paint_share(hips, one[..], 0.0f, half[..]);
	float settled = share_of(&app, 0, hips);
	test::@check(settled >= 0.0f && settled < 0.01f,
		"repeated partial strokes did not converge on the target, landing at %s", settled);
}

<*
 The brush keeps the on-demand loop awake, and lets it sleep again on the way out.

 crig draws only when something asks for a frame, which is what makes an idle
 editor cost nothing — and it is also what left the brush circle sitting still
 until an unrelated event forced a paint. The circle is drawn where the pointer
 is, so the mode genuinely has somewhere to get to on every frame; `ticking` is
 how anything says so.

 The second half is the part worth guarding: a mode that forgot to stop asking
 would pin the loop at full rate for the rest of the session, and nothing on
 screen would say why.
*>
fn void the_brush_keeps_the_frame_loop_awake() @test
{
	crig::AppState app = chained();
	defer app.free();

	app.select(dot_named(&app, "hips"));
	app.show_tint(crig::TintMode.OFF);
	app.rebind_tints();
	test::@check(!app.ticking(), "the fixture was already asking for frames before the brush opened");

	test::@check(app.begin_brush(), "the brush opened");

	// Settled first, and this is the whole test: opening the mode puts the
	// falloff up, which marks the weights stale, which makes `ticking` true all
	// by itself. Asserting before the rebind would pass whether or not the brush
	// asked for anything.
	app.rebind_tints();
	test::@check(!app.weights_stale, "the rebind did not settle");
	test::@check(app.ticking(), "the brush did not ask the loop to stay awake");

	app.end_brush();
	app.rebind_tints();
	test::@check(!app.ticking(), "closing the brush left the loop running at full rate");
}

<*
 One centred pass is not enough; several are.

 The complaint this answers: a pull of 1 at the centre made the brush a switch —
 one tap and the vertex was fully red, with the values in between reachable only
 by clipping it with the rim. Capping what a *stroke* can give turns "how much"
 into "how many passes".

 Written as the arithmetic the brush actually performs, since the geometry that
 produces the falloff needs a camera and this does not: a centred vertex gets
 `BRUSH_STRENGTH` and each stroke starts the memory over.
*>
fn void one_centred_pass_does_not_finish_the_job() @test
{
	crig::AppState app = chained();
	defer app.free();

	uint hips = dot_named(&app, "hips");
	uint[1] one = { 0 };

	// From nothing to as much as the dot can hold, the way ctrl-drag goes.
	app.paint_share(hips, one[..], 0.0f);
	test::@check(share_of(&app, 0, hips) < 1.0e-4f, "the vertex did not start at nothing");

	float target = crig::PAINT_SHARE_CEILING;

	// Through `stroke_pull`, which is what the viewport does — going straight to
	// `paint_share` would leave the stroke memory empty and the checks below
	// would be measuring a path nothing takes.
	app.begin_stroke();
	float[1] centred = { app.stroke_pull(0, crig::BRUSH_STRENGTH) };
	app.paint_share(hips, one[..], target, centred[..]);
	float first = share_of(&app, 0, hips);
	test::@check(first > 0.2f && first < 0.45f,
		"one centred pass should land near a third of the way, measured %s", first);

	// Held there, the same stroke gives nothing more however many frames arrive.
	for (usz i = 0; i < 20; i++)
	{
		float[1] again = { app.stroke_pull(0, crig::BRUSH_STRENGTH) };
		app.paint_share(hips, one[..], target, again[..]);
	}
	test::@check(math::abs(share_of(&app, 0, hips) - first) < 1.0e-5f,
		"holding the brush still carried it further");

	// Lifting and going again is what gets there.
	float last = first;
	for (usz pass = 0; pass < 3; pass++)
	{
		app.begin_stroke();
		float[1] pull = { app.stroke_pull(0, crig::BRUSH_STRENGTH) };
		app.paint_share(hips, one[..], target, pull[..]);

		float now = share_of(&app, 0, hips);
		test::@check(now > last, "pass %d carried it no further than the one before", pass + 2);
		last = now;
	}
	test::@check(last > 0.75f, "four centred passes should be most of the way, measured %s", last);
	test::@check(last < target, "and never past what was asked for");
}

// ---------------------------------------------------------------------------
// Blend sharpness
//
// The one bind control that is not about a dot: a power over every weight at
// once, which narrows every transition band together. The checks split the same
// way the code does — the primitive on its own arrays, then the two funnels that
// have to agree about it, since a sharpness applied in one and not the other is
// a survey describing a bind nobody is looking at.

<*
 The two values that mean "leave the bind alone" leave it alone, bit for bit.

 Not a nicety: a zero-initialised document is what every rig starts as, so γ=0
 is what the primitive is handed on the overwhelming majority of binds. Reading
 that zero literally would raise every weight to the power of nothing, flatten
 the whole matrix to ones and hand each vertex to whichever joint the tie-break
 picked. Equality rather than an epsilon, because the promise is that the array
 is not touched at all.
*>
fn void an_unset_sharpness_leaves_the_bind_alone() @test
{
	// The binder's real range, ends included: scores span orders of magnitude.
	float[6] scores = { 0.0f, 1.0e-6f, 0.25f, 1.0f, 7.5f, 1.0e6f };
	float[6] want = scores;

	crig::sharpen_weights(scores[..], 1.0f);
	foreach (usz i, value : scores)
	{
		test::@check(value == want[i], "gamma 1 moved weight %d from %s to %s", i, want[i], value);
	}

	crig::sharpen_weights(scores[..], 0.0f);
	foreach (usz i, value : scores)
	{
		test::@check(value == want[i], "an unset gamma moved weight %d from %s to %s", i, want[i], value);
	}

	// Below zero is the same unset state — the clamp on the document stores 0 for
	// it, and nothing downstream should have to know that.
	crig::sharpen_weights(scores[..], -2.0f);
	foreach (usz i, value : scores)
	{
		test::@check(value == want[i], "a negative gamma moved weight %d from %s to %s", i, want[i], value);
	}
}

<*
 Sharpening never changes which joint wins a vertex.

 A power is monotone, so the order within a row survives it — which is the whole
 reason this is safe to do to unnormalised scores between the binder and the
 paint. If it were not true the territory map would repaint itself every time
 the sharpness moved, and the user would be watching joints trade mesh when they
 asked for a crisper seam.
*>
fn void sharpening_keeps_the_order_within_a_row() @test
{
	float[5] row = { 0.004f, 0.9f, 0.05f, 12.0f, 0.05f };
	float[5] before = row;

	crig::sharpen_weights(row[..], 3.0f);

	foreach (usz i, value : row)
	{
		foreach (usz j, other : row)
		{
			if (i == j) continue;
			test::@check((before[i] > before[j]) == (value > other),
				"gamma 3 swapped %d and %d (%s,%s became %s,%s)", i, j, before[i], before[j], value, other);
		}
	}
}

<*
 A row that is already rigid comes back untouched, at any sharpness.

 1 and 0 are their own powers, so a shell pinned to one dot — and every
 auto-rigid piece the binder decides for itself — is unaffected by this control
 in both directions. Worth asserting rather than deriving, since it is what
 makes the sharpness safe to reach for on a model whose loose pieces are already
 settled.
*>
fn void a_rigid_row_survives_any_sharpness() @test
{
	float[4] rigid = { 0.0f, 1.0f, 0.0f, 0.0f };
	float[3] gammas = { 0.25f, 2.0f, 4.0f };

	foreach (gamma : gammas)
	{
		float[4] row = rigid;
		crig::sharpen_weights(row[..], gamma);
		foreach (usz i, value : row)
		{
			test::@check(value == rigid[i], "gamma %s moved a rigid row's %d from %s to %s",
				gamma, i, rigid[i], value);
		}
	}
}

<*
 How many rows still have more than one bone meaningfully in play: the vertices
 whose strongest normalised share falls short of `floor`.

 Shares rather than raw weights, because that is what the exporter writes and
 what the falloff view paints — a count over the binder's own units would mean
 something different on every row.
*>
fn usz band_rows(float[] dense, usz bones, float floor)
{
	usz counted = 0;
	for (usz at = 0; at + bones <= dense.len; at += bones)
	{
		float sum = 0.0f;
		float top = 0.0f;
		for (usz b = 0; b < bones; b++)
		{
			sum += dense[at + b];
			if (dense[at + b] > top) top = dense[at + b];
		}
		if (sum > 0.0f && top / sum < floor) counted++;
	}
	return counted;
}

<*
 The point of the whole feature: the band between two bones gets narrower.

 A ramp across forty-one vertices in the binder's own units — unnormalised
 scores, which is what the primitive is handed — and the measure is the count of
 vertices still shared between the two bones. On a model assembled from solid
 pieces that count is what reads as mush.
*>
fn void sharpening_narrows_the_transition_band() @test
{
	float[82] soft;
	for (usz v = 0; v < 41; v++)
	{
		float t = (float)v / 40.0f;
		soft[v * 2] = 0.02f + 4.0f * (1.0f - t);
		soft[v * 2 + 1] = 0.02f + 4.0f * t;
	}
	float[82] sharp = soft;

	usz before = band_rows(soft[..], 2, 0.9f);
	test::@check(before > 0, "the fixture has no transition band to narrow");

	crig::sharpen_weights(sharp[..], 4.0f);
	usz after = band_rows(sharp[..], 2, 0.9f);

	test::@check(after < before, "gamma 4 left %d of the %d shared vertices shared", after, before);

	// And nothing at either end changed hands — the ends are the sanity check on
	// the middle, since a band that narrowed by handing vertices to the wrong bone
	// would count the same and look nothing like it.
	test::@check(sharp[0] > sharp[1] && soft[0] > soft[1], "the first vertex changed owner");
	test::@check(sharp[80] < sharp[81] && soft[80] < soft[81], "the last vertex changed owner");
}

<*
 The bind the app hands out carries the document's sharpness.

 `bind_dense` is the funnel the preview, the export and the paint solver all come
 through, so this is the check that the setting reaches anything at all: the
 dominant dot's share of a vertex rises and a rival's falls, without either of
 them moving.
*>
fn void a_sharpened_document_binds_sharper() @test
{
	crig::AppState app = chained();
	defer app.free();

	uint hips = dot_named(&app, "hips");
	uint foot = dot_named(&app, "foot");

	float hips_soft = share_of(&app, 0, hips);
	float foot_soft = share_of(&app, 0, foot);
	test::@check(hips_soft > 0.0f && foot_soft > 0.0f, "the fixture vertex is not shared to begin with");

	test::@check(app.doc.set_sharpness(4.0f), "the document did not take the sharpness");
	app.mark_rig_stale();

	float hips_sharp = share_of(&app, 0, hips);
	float foot_sharp = share_of(&app, 0, foot);

	bool hips_wins = hips_soft > foot_soft;
	test::@check(hips_wins ? hips_sharp > hips_soft : hips_sharp < hips_soft,
		"the dominant dot's share went from %s to %s", hips_soft, hips_sharp);
	test::@check(hips_wins ? foot_sharp < foot_soft : foot_sharp > foot_soft,
		"the weaker dot's share went from %s to %s", foot_soft, foot_sharp);
}

<*
 A share asked for is still the share measured under a sharpened bind.

 The interaction that decides where the sharpening goes. It is applied *before*
 the paint and inside the base the solver borrows, so `p = S·R / ((1 − S)·b)` is
 solved against the numbers the user is looking at. Applied afterwards — or in
 the preview and not in the base — the correction would be solved against one
 bind and measured against another, and every painted share would land somewhere
 else.
*>
fn void a_share_asked_for_survives_a_sharpened_bind() @test
{
	crig::AppState app = chained();
	defer app.free();

	uint hips = dot_named(&app, "hips");
	uint[1] one = { 0 };

	test::@check(app.doc.set_sharpness(2.0f), "the document did not take the sharpness");
	app.mark_rig_stale();

	crig::PaintResult did = app.paint_share(hips, one[..], 0.7f);
	test::@check(did.unreachable == 0 && did.alone == 0, "the vertex can be given a share under gamma 2");
	test::@check(math::abs(share_of(&app, 0, hips) - 0.7f) < 1.0e-5f,
		"asked for 0.7 under gamma 2, measured %s", share_of(&app, 0, hips));
}

<*
 The survey reads the sharpened bind too.

 It is the second funnel — it binds for itself, because it needs the riders and
 the per-vertex distances that only come out of the bind — so a sharpness
 applied in `bind_dense` alone would leave `get_weights` reporting overlaps the
 mesh no longer has, which is the one thing a diagnostic must not do.

 Measured as reach beyond ownership: how many (dot, vertex) pairs a joint holds
 a reportable share of without owning. That is exactly the overlap the setting
 exists to shrink, and unlike an individual share it can only fall — a joint
 that owns a vertex still owns it, and the ones underneath it are pushed toward
 zero and out from under `BLEND_FLOOR`.
*>
fn void the_survey_reads_the_sharpened_bind() @test
{
	crig::AppState app = chained();
	defer app.free();

	uint knee = dot_named(&app, "knee");

	crig::WeightSurvey soft = app.survey_weights(mem, knee)!!;
	defer soft.free(mem);

	usz overlap_soft = 0;
	foreach (stake : soft.stakes) overlap_soft += stake.reaches - stake.owns;
	test::@check(overlap_soft > 0, "the fixture has no overlap to sharpen away");

	test::@check(app.doc.set_sharpness(4.0f), "the document did not take the sharpness");
	app.mark_rig_stale();

	crig::WeightSurvey sharp = app.survey_weights(mem, knee)!!;
	defer sharp.free(mem);

	usz overlap_sharp = 0;
	foreach (stake : sharp.stakes) overlap_sharp += stake.reaches - stake.owns;

	test::@check(overlap_sharp < overlap_soft,
		"the survey still reports %d shared holds, against %d before the sharpening",
		overlap_sharp, overlap_soft);

	// Ownership is an argmax and a power is monotone, so nothing changed hands —
	// which is what makes the shrinking overlap a narrower band rather than a
	// different bind.
	foreach (usz i, stake : soft.stakes)
	{
		test::@check(sharp.stakes[i].owns == stake.owns,
			"%s owned %d vertices before the sharpening and %d after",
			stake.name, stake.owns, sharp.stakes[i].owns);
	}
}

// ---------------------------------------------------------------------------
// The binder's own rigid choices, kept rather than thrown away
//
// `rig::rigid_shells` decides which bone an unreachable piece must ride, and
// until `AppState.shell_riders` existed it made that decision inside the bind
// and dropped it on the way out. The checks below are about the app holding on
// to it — that a bind fills it, that a rig edit invalidates it, and that a
// refresh brings it back — since the decision itself is asserted next door in
// test/geodesic_test.c3.

// A subdivided quad, so the fixture below has enough vertices for the prop rule
// to have a proportion to measure against.
fn void add_quad(Vec3List* positions, UintList* indices, Vec3 a, Vec3 b, Vec3 c, Vec3 d, int steps)
{
	uint first = (uint)positions.len();
	int stride = steps + 1;

	for (int j = 0; j <= steps; j++)
	{
		float v = (float)j / (float)steps;
		Vec3 left = a + (d - a) * v;
		Vec3 right = b + (c - b) * v;
		for (int i = 0; i <= steps; i++)
		{
			positions.push(left + (right - left) * ((float)i / (float)steps));
		}
	}

	for (int j = 0; j < steps; j++)
	{
		for (int i = 0; i < steps; i++)
		{
			uint corner = first + (uint)(j * stride + i);
			indices.push(corner);
			indices.push(corner + (uint)stride);
			indices.push(corner + 1);
			indices.push(corner + 1);
			indices.push(corner + (uint)stride);
			indices.push(corner + (uint)stride + 1);
		}
	}
}

// A closed axis-aligned box, six subdivided quads.
fn void add_box(Vec3List* positions, UintList* indices, Vec3 low, Vec3 high, int steps)
{
	Vec3 a = { low.x, low.y, low.z };
	Vec3 b = { high.x, low.y, low.z };
	Vec3 c = { high.x, high.y, low.z };
	Vec3 d = { low.x, high.y, low.z };
	Vec3 e = { low.x, low.y, high.z };
	Vec3 f = { high.x, low.y, high.z };
	Vec3 g = { high.x, high.y, high.z };
	Vec3 h = { low.x, high.y, high.z };

	add_quad(positions, indices, a, b, c, d, steps);
	add_quad(positions, indices, f, e, h, g, steps);
	add_quad(positions, indices, e, f, b, a, steps);
	add_quad(positions, indices, d, c, g, h, steps);
	add_quad(positions, indices, e, a, d, h, steps);
	add_quad(positions, indices, b, f, g, c, steps);
}

<*
 A tall body with a small box floating clear of it: the sword case, and the same
 measurements `body_with_prop` in test/geodesic_test.c3 is built to — the prop
 is clear of the body by several cells, small enough to pass the prop rule's
 size bar, and long enough to lie along two bones so that which one carries it
 is a question rather than a coincidence.

 Writes the number of body vertices to `body_vertices`; everything from there on
 is the prop. The caller frees the mesh.
*>
fn rig::TriMesh body_and_prop(usz* body_vertices)
{
	Vec3List positions;
	UintList indices;
	positions.init(mem);
	indices.init(mem);
	defer
	{
		positions.free();
		indices.free();
	}

	add_box(&positions, &indices, { -0.15, -0.5, -0.15 }, { 0.15, 0.5, 0.15 }, 6);
	*body_vertices = (usz)positions.len();
	add_box(&positions, &indices, { 0.25, -0.05, -0.05 }, { 0.35, 0.50, 0.05 }, 1);

	return { .positions = positions.to_array(mem), .indices = indices.to_array(mem) };
}

<*
 A three-dot spine with the prop hanging beside it, bound through the app.

 The mesh is freed after the state, because the picker's BVH points into it —
 the defers below run in reverse, which is what puts them in that order.
*>
fn crig::AppState propped(rig::TriMesh mesh)
{
	crig::AppState app = crig::new_app(mesh);
	uint hips = app.doc.add_dot({ 0, -0.3, 0 }, "hips");
	uint spine = app.doc.add_dot({ 0, 0, 0 }, "spine");
	uint chest = app.doc.add_dot({ 0, 0.3, 0 }, "chest");
	app.doc.connect(hips, spine);
	app.doc.connect(spine, chest);
	return app;
}

<*
 A bind says which bone the loose piece was frozen onto, and the answer survives
 the bind that produced it.

 The one thing `get_shells`' `auto` is made of. Without it
 a piece can be rigid with nothing anywhere saying why, which reads as a pin
 somebody forgot making rather than as the binder doing its job.
*>
fn void a_bind_names_the_bone_a_loose_piece_rides() @test
{
	usz body_vertices;
	rig::TriMesh mesh = body_and_prop(&body_vertices);
	defer mesh.free(mem);

	crig::AppState app = propped(mesh);
	defer app.free();

	if (app.shells.count != 2)
	{
		test::@check(false, "SKIPPED — the fixture is %d shells, not two", app.shells.count);
		return;
	}
	int prop = app.shells.of[body_vertices];

	crig::RigView? opened = app.open_rig(mem);
	if (catch opened)
	{
		test::@check(false, "the three-dot chain produced no skeleton");
		return;
	}
	crig::RigView view = opened;
	defer view.free(mem);

	app.base_bind_for(&view);

	test::@check(!app.riders_stale, "a bind left the riders stale, so nothing may read them");
	test::@check(app.shell_riders.len == app.shells.count,
		"the riders are %d long for %d pieces", app.shell_riders.len, app.shells.count);

	int rides = app.shell_rider((usz)prop);
	test::@check(rides >= 0, "the binder left the loose piece to the falloff");
	if (rides < 0) return;

	// Named through the view that produced the index, which is the only correct
	// conversion: joint indices are breadth-first output.
	test::@check(view.names[(usz)rides] == "spine",
		"the prop rides \"%s\" rather than the bone carrying the whole piece", view.names[(usz)rides]);

	// And the body is not frozen onto anything, or the rule froze the mesh it was
	// measuring.
	test::@check(app.shell_rider((usz)(1 - prop)) < 0,
		"the body itself was reported as riding joint %d", app.shell_rider((usz)(1 - prop)));
}

<*
 A rig edit takes the riders away, and a refresh brings them back.

 The indices are positions in a breadth-first joint order, so an edit that
 renumbers the joints leaves every one of them naming a real bone that is not
 the one the binder chose. Nothing is allowed to read them across that, which is
 what `riders_stale` is for — and what a Shells pane's "…" column was.
*>
fn void a_rig_edit_makes_the_riders_stale() @test
{
	usz body_vertices;
	rig::TriMesh mesh = body_and_prop(&body_vertices);
	defer mesh.free(mem);

	crig::AppState app = propped(mesh);
	defer app.free();

	if (app.shells.count != 2)
	{
		test::@check(false, "SKIPPED — the fixture is %d shells, not two", app.shells.count);
		return;
	}
	int prop = app.shells.of[body_vertices];

	crig::RigView? opened = app.open_rig(mem);
	if (catch opened)
	{
		test::@check(false, "the three-dot chain produced no skeleton");
		return;
	}
	crig::RigView view = opened;
	defer view.free(mem);

	app.base_bind_for(&view);
	int before = app.shell_rider((usz)prop);
	test::@check(before >= 0, "the fixture's prop rides nothing, so there is nothing to invalidate");

	uint generation = app.rig_generation;
	app.mark_rig_stale();

	test::@check(app.riders_stale, "a rig edit left the riders looking fresh");
	test::@check(app.rig_generation != generation, "the generation did not move, so no debounce would restart");
	test::@check(app.shell_rider((usz)prop) < 0,
		"a stale rider still answers with joint %d", app.shell_rider((usz)prop));

	// The debounce's own door, and the one the pane goes through.
	app.refresh_shell_riders();
	test::@check(!app.riders_stale, "the refresh left them stale");
	test::@check(app.shell_rider((usz)prop) == before,
		"the refreshed rider is joint %d where the bind said %d", app.shell_rider((usz)prop), before);
}

// ---------------------------------------------------------------------------
// The pin layer
//
// The one layer that states a weight rather than correcting one, so what these
// assert is arithmetic with an exact answer: a share of 1 has to reproduce the
// row `rigid_shells` writes, bit for bit, or a region drawn by hand and a piece
// frozen by the binder would deform differently while claiming to say the same
// thing.

<*
 The primitive stores, updates, removes and refuses.

 `set_paint`'s claims one layer up, with the one difference that matters: the
 value that removes an entry is 0 here and 1 there, because a pin is a share and
 a dab is a multiplier.
*>
fn void a_pin_is_stored_updated_and_removed() @test
{
	crig::AppState app = chained();
	defer app.free();

	uint hips = dot_named(&app, "hips");

	test::@check(app.doc.pin_of(0, hips) == 0.0f, "an absent pin reads as something other than nothing");

	test::@check(app.doc.set_pin(0, hips, 0.5f) && app.doc.pins.len() == 1, "one pin stored");
	test::@check(app.doc.pin_of(0, hips) == 0.5f, "and reads back as itself");
	test::@check(!app.doc.set_pin(0, hips, 0.5f), "setting the same share again changes nothing");

	test::@check(app.doc.set_pin(0, hips, 1.0f) && app.doc.pin_of(0, hips) == 1.0f, "the share moved");
	test::@check(app.doc.pins.len() == 1, "and did not store a second entry for the same pair");

	// Out of range is clamped rather than refused: a share is a fraction of one
	// vertex and 1.4 has no reading other than "all of it".
	test::@check(app.doc.set_pin(1, hips, 1.4f) && app.doc.pin_of(1, hips) == 1.0f, "a share above one is clamped");
	test::@check(!app.doc.set_pin(2, hips, -1.0f), "a negative share is a removal of nothing");

	test::@check(app.doc.set_pin(0, hips, 0.0f) && app.doc.pins.len() == 1, "zero removes the entry");
	test::@check(app.doc.pin_of(0, hips) == 0.0f, "and it reads as absent again");
	test::@check(!app.doc.set_pin(0, hips, 0.0f), "removing an absent pin is not a change");

	// A dot that is not in the rig, and the null id.
	test::@check(!app.doc.set_pin(0, 9999, 1.0f), "a pin was made to a dot that does not exist");
	test::@check(!app.doc.set_pin(0, 0, 1.0f), "a pin was made to the null dot");
}

// One vertex's row of a dense matrix, so the checks below read as rows rather
// than as offsets.
fn float[] row_of(float[] dense, usz vertex, usz bones) @local => dense[vertex * bones : bones];

<*
 A share of 1 writes exactly the row a rigidly bound shell gets.

 The claim the whole layer rests on. `rig::rigid_shells` zeroes a row and puts a
 single 1 in it, and a lasso drawn over that same piece has to land on the same
 numbers — "near enough" would mean the two routes to a rigid vertex deform
 differently at the seam.
*>
fn void a_full_pin_writes_the_rigid_row() @test
{
	float[3] dense = { 2.0f, 6.0f, 2.0f };
	crig::PinColumn[1] pins = {{ .vertex = 0, .joint = 1, .share = 1.0f }};

	crig::pin_over(dense[..], 3, pins[..]);

	test::@check(dense[0] == 0.0f && dense[2] == 0.0f, "the other joints kept a hold on a rigid vertex");
	test::@check(dense[1] == 1.0f, "the pinned joint came out at %.9f rather than 1", dense[1]);
}

<*
 A partial pin takes its share and leaves the rest in the proportion it found it.

 What makes a fractional pin worth having at all — the smooth op writes these,
 and a rest that was flattened rather than scaled would turn every boundary band
 into a two-way tie.
*>
fn void a_half_pin_shares_the_rest_pro_rata() @test
{
	float[3] dense = { 2.0f, 6.0f, 2.0f };
	crig::PinColumn[1] pins = {{ .vertex = 0, .joint = 0, .share = 0.5f }};

	crig::pin_over(dense[..], 3, pins[..]);

	test::@check(dense[0] == 0.5f, "the pinned joint holds %.9f rather than the half asked for", dense[0]);
	test::@check(math::abs(dense[1] - 0.375f) < 1.0e-6f, "the larger of the rest holds %.9f rather than 0.375", dense[1]);
	test::@check(math::abs(dense[2] - 0.125f) < 1.0e-6f, "the smaller holds %.9f rather than 0.125", dense[2]);

	float sum = dense[0] + dense[1] + dense[2];
	test::@check(math::abs(sum - 1.0f) < 1.0e-6f, "the row sums to %.9f", sum);

	// The ratio the binder had between the two un-pinned joints, unchanged.
	test::@check(math::abs(dense[1] / dense[2] - 3.0f) < 1.0e-5f,
		"the rest came out at %.9f : 1 where the binder said 3 : 1", dense[1] / dense[2]);
}

<*
 Two dots each promised most of a vertex are scaled to fit, keeping their ratio.

 A refusal would be the wrong answer: both statements are things a user can
 reasonably have said — a region drawn twice, an op writing a top-four — and the
 only division of one vertex that respects both is the proportional one.
*>
fn void pins_that_overpromise_are_scaled_to_one() @test
{
	float[3] dense = { 5.0f, 5.0f, 5.0f };
	crig::PinColumn[2] pins = {
		{ .vertex = 0, .joint = 0, .share = 0.4f },
		{ .vertex = 0, .joint = 1, .share = 1.0f },
	};

	crig::pin_over(dense[..], 3, pins[..]);

	float sum = dense[0] + dense[1] + dense[2];
	test::@check(math::abs(sum - 1.0f) < 1.0e-6f, "the row sums to %.9f rather than 1", sum);
	test::@check(dense[2] == 0.0f, "an un-pinned joint kept %.9f of a fully promised vertex", dense[2]);
	test::@check(math::abs(dense[0] - 0.4f / 1.4f) < 1.0e-6f,
		"the smaller claim came out at %.9f rather than its share of the two", dense[0]);
	test::@check(math::abs(dense[1] - 1.0f / 1.4f) < 1.0e-6f,
		"the larger claim came out at %.9f", dense[1]);
}

<*
 A pin on a row the binder left empty survives normalisation.

 The case the layer exists for: where every weight is zero there is no ratio to
 keep and no multiplier that reaches anything, so the pinned column is the only
 thing in the row — and every consumer divides by the row's own sum, which hands
 the vertex to it outright.
*>
fn void a_pin_over_an_empty_row_takes_the_whole_vertex() @test
{
	float[3] dense = { 0.0f, 0.0f, 0.0f };
	crig::PinColumn[1] pins = {{ .vertex = 0, .joint = 2, .share = 0.5f }};

	crig::pin_over(dense[..], 3, pins[..]);

	test::@check(dense[0] == 0.0f && dense[1] == 0.0f, "something appeared in a row the binder left empty");
	test::@check(dense[2] == 0.5f, "the pinned joint holds %.9f", dense[2]);

	float sum = dense[0] + dense[1] + dense[2];
	test::@check(sum > 0.0f && math::abs(dense[2] / sum - 1.0f) < 1.0e-6f,
		"the row does not normalise to the pinned joint holding all of it");
}

// No pins is the ordinary case and has to cost nothing and change nothing.
fn void no_pins_leaves_the_matrix_alone() @test
{
	float[6] dense = { 2.0f, 6.0f, 2.0f, 1.0f, 0.0f, 3.0f };
	float[6] before = dense;

	crig::pin_over(dense[..], 3, {});

	for (usz i = 0; i < 6; i++)
	{
		test::@check(dense[i] == before[i], "cell %d moved from %.9f to %.9f", i, before[i], dense[i]);
	}
}

<*
 The columns a bind is handed arrive grouped by vertex.

 `pin_over` rewrites a whole row around every pin on it at once, so a vertex
 appearing twice in the input would have its row rescaled a second time against
 numbers the first pass had already replaced. The document stores pins in the
 order they were made, which interleaves vertices as soon as a second region
 crosses the first — so the grouping is `pin_columns`' promise and this is it.
*>
fn void pin_columns_arrive_grouped_by_vertex() @test
{
	crig::AppState app = chained();
	defer app.free();

	uint hips = dot_named(&app, "hips");
	uint foot = dot_named(&app, "foot");

	// Interleaved on purpose: vertex 0, then 1, then 0 again.
	app.doc.set_pin(0, hips, 0.5f);
	app.doc.set_pin(1, hips, 0.5f);
	app.doc.set_pin(0, foot, 0.25f);

	crig::RigView? opened = app.open_rig(mem);
	if (catch opened)
	{
		test::@check(false, "the fixture produced no skeleton");
		return;
	}
	crig::RigView view = opened;
	defer view.free(mem);

	test::eq((usz)view.pins.len, (usz)3);
	for (usz i = 1; i < view.pins.len; i++)
	{
		test::@check(view.pins[i].vertex >= view.pins[i - 1].vertex,
			"pin %d is on vertex %d after vertex %d", i, view.pins[i].vertex, view.pins[i - 1].vertex);
	}
}

<*
 A region of thousands of vertices is one entry on the ledger, and undo puts
 back exactly what was under it.

 The bulk path's whole reason. `set_pin` is a scan of the layer, so a commit or
 a replay that went through it once per vertex would be quadratic in the region
 — and the lasso's ordinary gesture is tens of thousands of vertices.
*>
fn void a_large_region_is_one_step_and_undoes_exactly() @test
{
	crig::AppState app = chained();
	defer app.free();

	uint hips = dot_named(&app, "hips");
	uint foot = dot_named(&app, "foot");

	const usz REGION = 4000;

	// Something already underneath, so the undo has a value to come back to
	// rather than only an absence.
	crig::VertexPin[] under = alloc::new_array(mem, crig::VertexPin, REGION / 2);
	defer alloc::free(mem, under);
	for (usz v = 0; v < REGION / 2; v++)
	{
		under[v] = { .vertex = (uint)v, .dot_id = hips, .share = 0.25f };
	}
	test::eq(app.pin_dabs(under), REGION / 2);

	sz edits_before = app.undo_stack.edits.len();

	crig::VertexPin[] region = alloc::new_array(mem, crig::VertexPin, REGION);
	defer alloc::free(mem, region);
	for (usz v = 0; v < REGION; v++)
	{
		region[v] = { .vertex = (uint)v, .dot_id = hips, .share = 1.0f };
	}

	test::eq(app.pin_dabs(region), REGION);
	test::eq(app.undo_stack.edits.len(), edits_before + 1);

	test::@check(app.undo(), "the region is one step on the ledger");

	usz wrong = 0;
	for (usz v = 0; v < REGION; v++)
	{
		float want = v < REGION / 2 ? 0.25f : 0.0f;
		if (app.doc.pin_of((uint)v, hips) != want) wrong++;
	}
	test::eq(wrong, (usz)0);
	test::eq(app.doc.pins.len(), (sz)(REGION / 2));

	test::@check(app.redo(), "and it redoes as one step");
	test::@check(app.doc.pin_of(0, hips) == 1.0f && app.doc.pin_of((uint)(REGION - 1), hips) == 1.0f,
		"the redo did not put every share back");
	test::eq(app.doc.pins.len(), (sz)REGION);

	// A batch that asks for what is already there records nothing at all, which
	// is what keeps a second lasso over the same region off the ledger.
	sz settled = app.undo_stack.edits.len();
	test::eq(app.pin_dabs(region), (usz)0);
	test::eq(app.undo_stack.edits.len(), settled);

	// And one that removes: the layer empties and comes back whole.
	crig::VertexPin[] lift = alloc::new_array(mem, crig::VertexPin, REGION);
	defer alloc::free(mem, lift);
	for (usz v = 0; v < REGION; v++)
	{
		lift[v] = { .vertex = (uint)v, .dot_id = hips, .share = 0.0f };
	}
	test::eq(app.pin_dabs(lift), REGION);
	test::eq(app.doc.pins.len(), (sz)0);

	test::@check(app.undo() && app.doc.pins.len() == (sz)REGION, "undoing the removal left %d pins", app.doc.pins.len());
	test::@check(app.doc.pin_of(7, hips) == 1.0f, "and the shares came back wrong");

	// Unrelated to any of it, so the compaction pass is proven to leave the rest
	// of the layer alone.
	test::@check(app.doc.pin_of(0, foot) == 0.0f, "a rival dot picked up a pin from nowhere");
}

<*
 Pinning a region takes it off whichever dot had it.

 The second half of "these vertices belong to this dot". Without it two dots
 each state a share of the same vertex and `pin_over` divides it between them,
 which is the opposite of what drawing over a region means.
*>
fn void pinning_a_region_clears_a_rivals_pins() @test
{
	crig::AppState app = chained();
	defer app.free();

	uint hips = dot_named(&app, "hips");
	uint foot = dot_named(&app, "foot");

	uint[3] region = { 0, 1, 2 };
	test::eq(app.pin_vertices(region[..], hips, 1.0f), (usz)3);

	// The same region to the other dot: three new pins and three rivals cleared.
	test::eq(app.pin_vertices(region[..], foot, 1.0f), (usz)6);
	test::eq(app.doc.pins.len(), (sz)3);
	test::@check(app.doc.pin_of(0, hips) == 0.0f, "the first dot kept its hold on a re-pinned vertex");
	test::@check(app.doc.pin_of(0, foot) == 1.0f, "the second dot did not take it");

	// One Ctrl+Z takes the whole exchange back — the clearing and the pinning are
	// one gesture, not two.
	test::@check(app.undo(), "the exchange is one step");
	test::@check(app.doc.pin_of(0, hips) == 1.0f && app.doc.pin_of(0, foot) == 0.0f,
		"undo did not restore the first dot's region");

	// Without exclusivity both stand, which is what a caller asking for a
	// fractional split wants.
	app.redo();
	test::eq(app.pin_vertices(region[..], hips, 0.5f, exclusive: false), (usz)3);
	test::@check(app.doc.pin_of(0, hips) == 0.5f && app.doc.pin_of(0, foot) == 1.0f,
		"a non-exclusive pin cleared the rival anyway");
}

<*
 Clearing takes the whole layer off in one step, and leaves the corrections.
*>
fn void clearing_the_pins_is_one_step() @test
{
	crig::AppState app = chained();
	defer app.free();

	uint hips = dot_named(&app, "hips");

	uint[2] region = { 0, 1 };
	app.pin_vertices(region[..], hips, 1.0f);

	crig::PaintDab[1] dab = {{ .vertex = 0, .dot_id = hips, .factor = 0.25f }};
	app.paint_dabs(dab[..]);

	test::eq(app.clear_pins(), (usz)2);
	test::eq(app.doc.pins.len(), (sz)0);
	test::@check(app.doc.paint_of(0, hips) == 0.25f, "clearing the pins took a correction with it");

	test::@check(app.undo() && app.doc.pins.len() == (sz)2, "the clear is one step");
	test::@check(app.doc.pin_of(0, hips) == 1.0f && app.doc.pin_of(1, hips) == 1.0f,
		"and each pin came back with its own share");

	test::@check(app.redo() && app.doc.pins.len() == 0, "the clear redoes");
	test::eq(app.clear_pins(), (usz)0);
	test::@check(!app.undo_stack.can_redo(), "clearing an empty layer forked the timeline");
}

<*
 A pinned vertex owns its dot in the survey.

 The survey binds for itself rather than through `bind_dense` — it needs the
 riders and the distances only the bind itself produces — so the pins have to be
 applied there too, or the numbers report a bind nobody is looking at.
*>
fn void a_pinned_vertex_owns_its_dot_in_the_survey() @test
{
	crig::AppState app = chained();
	defer app.free();

	uint stray = dot_named(&app, "stray");

	crig::WeightSurvey before = app.survey_weights(mem)!!;
	usz had = 0;
	foreach (stake : before.stakes)
	{
		if (stake.dot == stray) had = stake.owns;
	}
	before.free(mem);

	// The whole cube, so the answer is unambiguous whatever the binder thought.
	uint[8] whole = { 0, 1, 2, 3, 4, 5, 6, 7 };
	app.pin_vertices(whole[..], stray, 1.0f);

	crig::WeightSurvey after = app.survey_weights(mem)!!;
	defer after.free(mem);

	usz now = 0;
	foreach (stake : after.stakes)
	{
		if (stake.dot != stray)
		{
			test::eq(stake.owns, (usz)0);
		}
		else
		{
			now = stake.owns;
		}
	}
	test::@check(had < (usz)cube_positions.len, "the fixture already gave the stray dot the whole mesh");
	test::eq(now, (usz)cube_positions.len);
}

<*
 A correction on a pinned vertex is written and is not visible, and the result
 says so.

 Precedence stated as a number. The dab lands — it comes back the moment the pin
 is lifted — but `pin_over` runs after `paint_over`, so the deformation does not
 move; a caller reading "painted 1" with no other word would take that for an
 effect it can see.
*>
fn void a_correction_under_a_pin_is_counted_and_invisible() @test
{
	crig::AppState app = chained();
	defer app.free();

	uint hips = dot_named(&app, "hips");

	uint[1] one = { 0 };
	app.pin_vertices(one[..], hips, 1.0f);

	crig::PaintResult did = app.paint_share(hips, one[..], 0.0f);
	test::eq(did.pinned, (usz)1);

	crig::RigView? opened = app.open_rig(mem);
	if (catch opened)
	{
		test::@check(false, "the fixture produced no skeleton");
		return;
	}
	crig::RigView view = opened;
	defer view.free(mem);

	float[] painted = app.painted_bind(mem, &view);
	defer alloc::free(mem, painted);

	usz bones = view.len();
	sz mine = view.joint_of(hips);
	test::@check(mine >= 0, "the pinned dot is not in the rig");

	float[] row = row_of(painted, 0, bones);
	for (usz b = 0; b < bones; b++)
	{
		float want = b == (usz)mine ? 1.0f : 0.0f;
		test::@check(row[b] == want, "column %d of a pinned vertex is %.9f rather than %.9f", b, row[b], want);
	}

	// And an unpinned vertex still answers to the brush, so the check above is
	// about the pin and not about the paint having stopped working.
	uint[1] other = { 1 };
	crig::PaintResult elsewhere = app.paint_share(hips, other[..], 0.0f);
	test::eq(elsewhere.pinned, (usz)0);
	test::@check(app.doc.paint_of(1, hips) < 1.0f, "the brush did nothing on an unpinned vertex either");
}

<*
 A pinned vertex is never reported as stranded.

 The riders' fiat one step finer: the user has said which dot holds it, so how
 far the nearest bone happens to be has stopped being the question.
*>
fn void unclaimed_never_flags_a_pinned_vertex() @test
{
	float[3] nearest = { 0.0f, 100.0f, 100.0f };

	bool[] stray = crig::unclaimed_mask(mem, nearest[..], 3);
	defer alloc::free(mem, stray);
	test::@check(!stray[0] && stray[1] && stray[2], "the fixture does not strand what this is about");

	crig::PinColumn[1] pins = {{ .vertex = 1, .joint = 0, .share = 1.0f }};
	bool[] guarded = crig::unclaimed_mask(mem, nearest[..], 3, null, {}, pins[..]);
	defer alloc::free(mem, guarded);

	test::@check(!guarded[1], "a pinned vertex is still counted as stranded");
	test::@check(guarded[2], "the pin rescued a vertex nobody pinned");
}

<*
 A piece that rides a bone is never counted as stranded.

 The unclaimed count answers "where do I still need a dot", and a piece the
 binder pinned rigidly is not such a place. It cannot be told from the weight
 matrix alone, which is the whole reason `bind_geodesic` reports what it pinned:
 a piece bound rigidly holds weight 1 on one joint, and the distance that
 inverts out of a 1 is a vertex a whole model-unit from any bone — the exact
 reading the cut calls unreached. Without `riders` the count would report every
 prop in the file as work still to do, most loudly for the ones already dealt
 with.

 Two cubes rather than the one the rest of this file uses: the property needs a
 piece no bone reaches, and a single shell with the dots inside it has none.
*>
fn void unclaimed_never_flags_a_pinned_piece() @test
{
	// Quarter scale, and that is load-bearing rather than tidy. A rigidly bound
	// vertex holds weight exactly 1, which inverts to a distance of exactly one
	// model unit — so whether the count mistakes it for unreached mass depends on
	// how big the model is next to that 1. On anything under about a unit and a
	// half it does, which is most characters, and this fixture has to be one of
	// them or it would pass while the count was still lying.
	Vec3[16] positions;
	uint[72] indices;
	foreach (i, position : cube_positions)
	{
		positions[i] = position * 0.25f;
		positions[i + 8] = position * 0.25f + (Vec3) { 1.5, 0, 0 };
	}
	foreach (i, index : cube_indices)
	{
		indices[i] = index;
		indices[i + 36] = index + 8;
	}

	rig::TriMesh pair      = { .positions = positions[..], .indices = indices[..] };
	rig::MeshVoxels voxels = rig::build_voxels(mem, pair);
	defer voxels.free(mem);
	rig::MeshShells shells = rig::build_shells(mem, pair);
	defer shells.free(mem);

	Vec3[1] joints = { { 0, 0, 0 } };
	int[1] parents = { -1 };

	if (shells.count != 2)
	{
		test::@check(false, "SKIPPED — the two cubes did not come out as two shells");
		return;
	}

	// Loose first: nothing is attached, so the far cube is judged on its distance
	// and the count has to see it. Without this half the second one proves
	// nothing — a mask that flagged no vertex at all would pass it.
	usz flagged = count_stray(pair, &voxels, &shells, joints[..], parents[..], {});
	test::@check(flagged == 8, "the far cube is stranded while no bone reaches it, got %d of 8", flagged);

	// Pinned to the only joint there is, which is the answer a piece-sized pin
	// gives. The binder writes that into `riders`, and the mask reads it.
	int[2] attachments = { -1, 0 };
	usz still_flagged  = count_stray(pair, &voxels, &shells, joints[..], parents[..], attachments[..]);
	test::@check(still_flagged == 0, "the far cube is still stranded once it rides a joint, %d of 8", still_flagged);
}

<*
 How many of the second cube's eight vertices `unclaimed_mask` calls stranded,
 through the same bind the app makes.

 @param attachments : `One joint index per shell, -1 to decide automatically.`
*>
fn usz count_stray(
	rig::TriMesh geometry,
	rig::MeshVoxels* voxels,
	rig::MeshShells* shells,
	Vec3[] joints,
	int[] parents,
	int[] attachments) @local
{
	int[] riders = alloc::new_array(mem, int, (sz)shells.count);
	defer alloc::free(mem, riders);

	float[] nearest = alloc::new_array(mem, float, (sz)geometry.positions.len);
	defer alloc::free(mem, nearest);

	float[] dense = rig::bind_geodesic(
		mem, voxels, geometry.positions, joints, parents,
		shells, attachments, riders, {}, nearest);
	defer alloc::free(mem, dense);

	bool[] stray = crig::unclaimed_mask(mem, nearest, geometry.positions.len, shells, riders);
	defer alloc::free(mem, stray);

	usz flagged = 0;
	for (usz v = 8; v < 16; v++) if (stray[v]) flagged++;
	return flagged;
}

// ---------------------------------------------------------------------------
// The region test the lasso gathers with

<*
 A convex region takes what is inside it and nothing else.
*>
fn void a_convex_region_holds_what_is_inside_it() @test
{
	Vec2[4] square = { { 0, 0 }, { 10, 0 }, { 10, 10 }, { 0, 10 } };

	test::@check(crig::inside_polygon(square[..], { 5, 5 }), "the middle of a square is outside it");
	test::@check(!crig::inside_polygon(square[..], { 15, 5 }), "a point beside a square is inside it");
	test::@check(!crig::inside_polygon(square[..], { 5, -1 }), "a point above a square is inside it");

	// On the other side, where the ray crosses *both* edges: counting them rather
	// than merely finding one is the whole of the even-odd rule, and a test that
	// only ever produced one crossing would pass on a version that never counted.
	test::@check(!crig::inside_polygon(square[..], { -5, 5 }),
		"a point the ray reaches the square through twice reads as inside");

	// Two points and one are not a region, whatever they enclose.
	Vec2[2] line = { { 0, 0 }, { 10, 10 } };
	test::@check(!crig::inside_polygon(line[..], { 5, 5 }), "a line has an inside");
}

<*
 A concave region excludes the bite taken out of it.

 The case the bounding box alone cannot answer, and the reason the gather runs
 the crossing test after the box rather than instead of it: a C drawn around a
 shoulder has its opening well inside its own box, and a tool that pinned the
 whole box would take the arm the user was drawing around.
*>
fn void a_concave_region_excludes_its_bite() @test
{
	// A C opening to the right: the notch spans x 4..10 at y 4..6.
	Vec2[8] c_shape = {
		{ 0, 0 }, { 10, 0 }, { 10, 4 }, { 4, 4 },
		{ 4, 6 }, { 10, 6 }, { 10, 10 }, { 0, 10 },
	};

	test::@check(crig::inside_polygon(c_shape[..], { 2, 5 }), "the back of the C is outside it");
	test::@check(crig::inside_polygon(c_shape[..], { 7, 2 }), "the top arm of the C is outside it");
	test::@check(crig::inside_polygon(c_shape[..], { 7, 8 }), "the bottom arm of the C is outside it");

	// Inside the box the shape sits in, and outside the shape.
	test::@check(!crig::inside_polygon(c_shape[..], { 7, 5 }),
		"the bite out of the C reads as inside — the box is deciding, not the shape");
}

// ---------------------------------------------------------------------------
// What a drawn region catches
//
// `lasso_vertices`' rule: the visible vertices inside the outline are seeds, and
// the region grows from them along the mesh's own edges into vertices that are
// themselves inside the outline. These fixtures are the cases that tell that rule
// apart from the two simpler ones it sits between — front faces only, which loses
// the back of whatever was drawn around, and plain x-ray, which takes whatever
// happens to be standing behind it.
//
// All of them are looked at head-on, so which vertex hides behind which is
// arithmetic rather than a guess, and the polygons are built from where the
// fixture actually lands rather than from pixel constants — the projection is the
// thing under test's input, not its subject.

// The pane the outlines below are drawn in. Any size does; this one is far enough
// from square that a polygon built for one axis cannot pass by accident on the
// other.
const Vec2 LASSO_VIEWPORT = { 800, 600 };

// Head-on down -z, which is what makes the far side of a fixture the far side.
fn crig::OrbitCamera head_on(Vec3 target, float distance)
{
	return {
		.target = target,
		.distance = distance,
		.yaw = 0.0f,
		.pitch = 0.0f,
		.fov = 45.0f,
		.near_plane = 0.05f,
		.far_plane = 200.0f,
	};
}

<*
 A rectangle around wherever these points land, grown by a margin.

 The outline every check below draws. Built from the projection rather than
 written out in pixels so the fixtures stay readable as geometry: what a test
 means is "around that part of the model", and a constant would have to be
 recomputed by hand the moment a camera moved.

 @require points.len > 0 : `A frame around nothing has no edges.`
*>
fn Vec2[4] frame_around(Matrix4f view_projection, Vec3[] points, float margin)
{
	Vec2 low = crig::project(view_projection, points[0], LASSO_VIEWPORT)!!;
	Vec2 high = low;

	foreach (point : points)
	{
		Vec2 where = crig::project(view_projection, point, LASSO_VIEWPORT)!!;
		if (where.x < low.x) low.x = where.x;
		if (where.y < low.y) low.y = where.y;
		if (where.x > high.x) high.x = where.x;
		if (where.y > high.y) high.y = where.y;
	}

	return {
		{ low.x - margin, low.y - margin },
		{ high.x + margin, low.y - margin },
		{ high.x + margin, high.y + margin },
		{ low.x - margin, high.y + margin },
	};
}

// How many of these positions the picker says are behind something. The guard the
// checks below open with: a fixture whose far half turns out to be in plain sight
// would pass under any rule at all.
fn usz hidden_count(crig::AppState* app, Vec3[] positions)
{
	Vec3 eye = app.camera.eye();
	usz unseen = 0;
	foreach (position : positions)
	{
		if (app.picker.hidden_surface(eye, position)) unseen++;
	}
	return unseen;
}

// Whether a gather caught this vertex.
fn bool caught_by(uint[] caught, uint vertex) @local
{
	foreach (v : caught)
	{
		if (v == vertex) return true;
	}
	return false;
}

<*
 A region drawn around a whole silhouette takes the far side of it too.

 The defect this rule exists for, at its smallest: a leg lassoed from the front,
 with the back of that same leg left holding the bone it had and nothing but the
 falloff view to say so. Every back corner here is hidden behind a front one and
 joined to it around the silhouette without leaving the outline, so every one of
 them is in the region.
*>
fn void a_region_takes_the_far_side_of_what_it_encircles() @test
{
	crig::AppState app = crig::new_app({ .positions = cube_positions[..], .indices = cube_indices[..] });
	defer app.free();

	app.camera = head_on({ 0, 0, 0 }, 6.0f);
	Matrix4f vp = app.camera.view_projection(LASSO_VIEWPORT.x / LASSO_VIEWPORT.y);

	// Half the cube is genuinely out of sight, which is the half a front-faces
	// pass would drop and this one has to find.
	test::eq(hidden_count(&app, cube_positions[..]), (usz)4);

	Vec2[4] shape = frame_around(vp, cube_positions[..], 12.0f);

	uint[8] caught;
	usz found = app.lasso_vertices(caught[..], vp, LASSO_VIEWPORT, app.camera.eye(), shape[..], false);

	test::eq(found, (usz)8);
	for (uint v = 0; v < 8; v++)
	{
		test::@check(caught_by(caught[:found], v), "corner %d of the cube was left out of the region", v);
	}
}

// Two boxes, the near one much the bigger and directly in front of the other:
// judged on the screen alone the far box is inside whatever is drawn around the
// near one, and there is not a triangle joining them.
Vec3[8] near_box_positions = {
	{ -1, -1, -1 }, { 1, -1, -1 }, { 1, 1, -1 }, { -1, 1, -1 },
	{ -1, -1, 1 }, { 1, -1, 1 }, { 1, 1, 1 }, { -1, 1, 1 },
};

Vec3[8] far_box_positions = {
	{ -0.4, -0.4, -5.4 }, { 0.4, -0.4, -5.4 }, { 0.4, 0.4, -5.4 }, { -0.4, 0.4, -5.4 },
	{ -0.4, -0.4, -4.6 }, { 0.4, -0.4, -4.6 }, { 0.4, 0.4, -4.6 }, { -0.4, 0.4, -4.6 },
};

// Both boxes in one mesh, the far one's corners numbered 8 to 15 and its
// triangles the cube's own, shifted along.
fn crig::AppState two_boxes(Vec3[16]* positions, uint[72]* indices)
{
	for (usz i = 0; i < 8; i++)
	{
		(*positions)[i] = near_box_positions[i];
		(*positions)[8 + i] = far_box_positions[i];
	}
	for (usz i = 0; i < 36; i++)
	{
		(*indices)[i] = cube_indices[i];
		(*indices)[36 + i] = cube_indices[i] + 8;
	}

	crig::AppState app = crig::new_app({ .positions = (*positions)[..], .indices = (*indices)[..] });
	app.camera = head_on({ 0, 0, 0 }, 6.0f);
	return app;
}

<*
 A region drawn around the near piece does not take the piece hiding behind it.

 The half of the rule that keeps it from being x-ray with extra steps. Every
 corner of the far box is inside the outline — it is smaller and further away, so
 it projects well within the near box's silhouette — and every one of them is out
 of sight behind it. What decides them is that no edge of the mesh leads there.
*>
fn void a_region_leaves_the_piece_hiding_behind_it() @test
{
	Vec3[16] positions;
	uint[72] indices;

	crig::AppState app = two_boxes(&positions, &indices);
	defer app.free();

	Matrix4f vp = app.camera.view_projection(LASSO_VIEWPORT.x / LASSO_VIEWPORT.y);

	// The far box is hidden outright, and so is the near box's own back.
	test::eq(hidden_count(&app, far_box_positions[..]), (usz)8);
	test::eq(hidden_count(&app, near_box_positions[..]), (usz)4);

	Vec2[4] shape = frame_around(vp, near_box_positions[..], 12.0f);

	// And the far box is inside the outline, so nothing but the walk is excluding
	// it — a fixture where it fell outside would pass on any rule whatever.
	foreach (position : far_box_positions)
	{
		Vec2 where = crig::project(vp, position, LASSO_VIEWPORT)!!;
		test::@check(crig::inside_polygon(shape[..], where),
			"the far box projects outside the outline, so this fixture proves nothing");
	}

	uint[16] caught;
	usz found = app.lasso_vertices(caught[..], vp, LASSO_VIEWPORT, app.camera.eye(), shape[..], false);

	test::eq(found, (usz)8);
	foreach (v : caught[:found])
	{
		test::@check(v < 8, "vertex %d of the far box joined a region drawn around the near one", v);
	}
}

// Two walls facing the camera, one behind the other, joined only along the floor
// between them: 0..3 is the near tower, 4..7 the far one, 8..11 the floor's own
// corners. The only path from one tower to the other runs down through the floor,
// which is below both of them on screen.
Vec3[12] tower_positions = {
	{ -0.5, 1, 1 }, { 0.5, 1, 1 }, { 0.5, 3, 1 }, { -0.5, 3, 1 },
	{ -0.5, 1, -1 }, { 0.5, 1, -1 }, { 0.5, 3, -1 }, { -0.5, 3, -1 },
	{ -0.5, 0, 1 }, { 0.5, 0, 1 }, { -0.5, 0, -1 }, { 0.5, 0, -1 },
};

uint[30] tower_indices = {
	0, 1, 2, 0, 2, 3,       // the near tower
	4, 5, 6, 4, 6, 7,       // the far one
	8, 9, 1, 8, 1, 0,       // near tower down to the floor
	10, 11, 5, 10, 5, 4,    // far tower down to the floor
	8, 9, 11, 8, 11, 10,    // and the floor between them
};

fn crig::AppState two_towers()
{
	crig::AppState app = crig::new_app({ .positions = tower_positions[..], .indices = tower_indices[..] });
	app.camera = head_on({ 0, 2, 0 }, 8.0f);
	return app;
}

<*
 One mesh, and the far half of it is still left alone when the way to it leaves
 the outline.

 The case that separates the walk from plain x-ray, and the one that dies first if
 anyone ever "simplifies" the seeding. Both towers are the same body — there is a
 floor joining them — and the far tower is inside the outline drawn tightly around
 the near one. It stays out because the only edges leading to it run down through
 that floor, and the floor is below the outline.
*>
fn void a_region_stops_where_the_mesh_leaves_the_outline() @test
{
	crig::AppState app = two_towers();
	defer app.free();

	Matrix4f vp = app.camera.view_projection(LASSO_VIEWPORT.x / LASSO_VIEWPORT.y);

	// The far tower is behind the near one, and the near one is in plain sight.
	test::eq(hidden_count(&app, tower_positions[4:4]), (usz)4);
	test::eq(hidden_count(&app, tower_positions[:4]), (usz)0);

	Vec2[4] shape = frame_around(vp, tower_positions[:4], 12.0f);

	// The far tower is inside the outline and the floor is not, which is the whole
	// arrangement: without the first this proves nothing, and without the second
	// there would be a way through.
	for (usz v = 4; v < 12; v++)
	{
		Vec2 where = crig::project(vp, tower_positions[v], LASSO_VIEWPORT)!!;
		bool inside = crig::inside_polygon(shape[..], where);
		test::@check(inside == (v < 8),
			"vertex %d is %s the outline, which is not the fixture this check needs", v,
			inside ? "inside" : "outside");
	}

	uint[12] caught;
	usz found = app.lasso_vertices(caught[..], vp, LASSO_VIEWPORT, app.camera.eye(), shape[..], false);

	test::eq(found, (usz)4);
	foreach (v : caught[:found])
	{
		test::@check(v < 4, "vertex %d was reached through a floor the outline does not contain", v);
	}
}

<*
 Alt takes everything inside the outline, joined or not, seen or not — and
 nothing outside it.

 The deliberate override, and the reason the default can afford to be careful. It
 is the polygon alone: the far box joins the region here, and so does a tower the
 walk refused, but the floor under those towers is still outside the outline and
 still out of the region. X-ray reaches through the model, not around the gesture.
*>
fn void the_xray_lasso_takes_everything_inside_the_outline() @test
{
	Vec3[16] positions;
	uint[72] indices;

	crig::AppState boxes = two_boxes(&positions, &indices);
	defer boxes.free();

	Matrix4f box_vp = boxes.camera.view_projection(LASSO_VIEWPORT.x / LASSO_VIEWPORT.y);
	Vec2[4] box_shape = frame_around(box_vp, near_box_positions[..], 12.0f);

	uint[16] boxed;
	usz found = boxes.lasso_vertices(boxed[..], box_vp, LASSO_VIEWPORT, boxes.camera.eye(), box_shape[..], true);
	test::eq(found, (usz)16);

	crig::AppState towers = two_towers();
	defer towers.free();

	Matrix4f tower_vp = towers.camera.view_projection(LASSO_VIEWPORT.x / LASSO_VIEWPORT.y);
	Vec2[4] tower_shape = frame_around(tower_vp, tower_positions[:4], 12.0f);

	uint[12] reached;
	usz through = towers.lasso_vertices(reached[..], tower_vp, LASSO_VIEWPORT, towers.camera.eye(),
		tower_shape[..], true);

	test::eq(through, (usz)8);
	foreach (v : reached[:through])
	{
		test::@check(v < 8, "x-ray took the floor, which was never inside the outline");
	}
}

<*
 A mesh with no edges to walk still gathers, and gathers what can be seen.

 The fallback, on the one mesh that can reach it: adjacency is unusable only when
 there is not a triangle anywhere, and a mesh with no triangles has no surface to
 hide behind either — so what "visible only" comes to here is everything inside
 the outline. What is being checked is that the path is taken at all rather than
 walking a CSR with no rows in it.
*>
fn void a_region_over_a_point_cloud_gathers_what_it_can_see() @test
{
	crig::AppState app = crig::new_app({ .positions = cube_positions[..] });
	defer app.free();

	app.camera = head_on({ 0, 0, 0 }, 6.0f);
	Matrix4f vp = app.camera.view_projection(LASSO_VIEWPORT.x / LASSO_VIEWPORT.y);

	test::@check(!app.adjacency_for().usable(), "a point cloud has neighbourhoods to walk");

	Vec2[4] shape = frame_around(vp, cube_positions[..], 12.0f);

	uint[8] caught;
	usz found = app.lasso_vertices(caught[..], vp, LASSO_VIEWPORT, app.camera.eye(), shape[..], false);
	test::eq(found, (usz)8);
}

// ---------------------------------------------------------------------------
// Mesh adjacency
//
// The one structure crig builds along the edges rather than through the volume,
// and the whole reason it is not simply the index buffer read back is the weld:
// a glTF exporter splits a vertex at every seam, and a neighbourhood that
// stopped at one would leave a smooth pass showing where the model was
// unwrapped.

// Two quads side by side whose middle edge is duplicated: 2 and 4 sit on the
// same point, as do 3 and 5, and no triangle references both copies. Judged on
// the indices alone this is two pieces that never touch.
Vec3[8] seam_positions = {
	{ 0, 0, 0 }, { 0, 1, 0 },
	{ 1, 0, 0 }, { 1, 1, 0 },
	{ 1, 0, 0 }, { 1, 1, 0 },
	{ 2, 0, 0 }, { 2, 1, 0 },
};

uint[12] seam_indices = {
	0, 2, 3, 0, 3, 1,
	4, 6, 7, 4, 7, 5,
};

// A triangle with two corners on one point. Welded they are one, so the side
// between them is a point rather than a link — and a link from a weld to itself
// would put a vertex into its own average.
Vec3[3] pinched_positions = { { 0, 0, 0 }, { 0, 0, 0 }, { 1, 0, 0 } };
uint[3] pinched_indices = { 0, 1, 2 };

// Whether a weld id is in a neighbour list, for the set claims below.
fn bool lists(uint[] neighbours, uint want) @local
{
	foreach (id : neighbours)
	{
		if (id == want) return true;
	}
	return false;
}

<*
 Neighbourhoods cross a duplicated seam, and the CSR they arrive in is
 well-formed.

 The claim smoothing rests on. Without the weld the two quads here are separate
 neighbourhoods and a Laplacian pass over the boundary between them would stop
 dead at the seam, leaving a ridge exactly where the model happened to be
 unwrapped — which is the defect this exists to prevent and is invisible on any
 mesh that was never split.
*>
fn void a_duplicated_seam_does_not_break_a_neighbourhood() @test
{
	rig::TriMesh mesh = { .positions = seam_positions[..], .indices = seam_indices[..] };

	rig::MeshAdjacency around = rig::build_adjacency(mem, mesh);
	defer around.free(mem);

	test::@check(around.usable(), "a two-quad strip has no neighbourhoods at all");
	test::eq(around.vertices(), (usz)8);

	// Six distinct points from eight vertices: the weld found both copies.
	test::eq(around.classes(), (usz)6);
	test::@check(around.class_of[2] == around.class_of[4] && around.class_of[3] == around.class_of[5],
		"the coincident copies were left in separate welds");

	// And the welded seam reaches both ways, which is the whole point.
	uint seam = around.class_of[2];
	test::@check(lists(around.around(seam), around.class_of[0]),
		"the seam does not reach the quad on its left");
	test::@check(lists(around.around(seam), around.class_of[6]),
		"the seam does not reach the quad on its right");

	// A welded copy is not a second entry to keep in step: both indices resolve to
	// one weld, so they read one list and cannot disagree about it.
	test::@check(around.around(around.class_of[2]).ptr == around.around(around.class_of[4]).ptr,
		"the two copies of the seam read different neighbour lists");

	test::eq((usz)around.offsets.len, around.classes() + 1);
	test::eq((usz)around.offsets[around.offsets.len - 1], (usz)around.neighbours.len);

	usz previous = 0;
	for (usz g = 0; g < around.offsets.len; g++)
	{
		test::@check((usz)around.offsets[g] >= previous,
			"the CSR runs backwards at row %d: %d after %d", g, around.offsets[g], previous);
		previous = (usz)around.offsets[g];
	}

	for (usz g = 0; g < around.classes(); g++)
	{
		test::@check(!lists(around.around(g), (uint)g), "weld %d is its own neighbour", g);

		// Symmetric, since a mean over a neighbourhood on one side has to be a mean
		// over the same edge on the other.
		foreach (n : around.around(g))
		{
			test::@check(lists(around.around((usz)n), (uint)g),
				"weld %d lists %d but not the other way round", g, n);
		}
	}
}

<*
 A triangle side whose ends weld together contributes no link.

 The degenerate case the seam fixture cannot reach: without the guard the pinched
 corner would list its own weld, and a Laplacian pass would then average a point
 partly with itself — a smoothing that quietly does less at exactly the vertices
 a modelling accident produced.
*>
fn void a_pinched_triangle_is_nobodys_own_neighbour() @test
{
	rig::TriMesh mesh = { .positions = pinched_positions[..], .indices = pinched_indices[..] };

	rig::MeshAdjacency around = rig::build_adjacency(mem, mesh);
	defer around.free(mem);

	test::eq(around.classes(), (usz)2);
	test::@check(around.class_of[0] == around.class_of[1], "the pinched corners are two welds");

	uint corner = around.class_of[0];
	test::eq((usz)around.around(corner).len, (usz)1);
	test::@check(!lists(around.around(corner), corner), "the pinched corner is its own neighbour");
	test::@check(lists(around.around(corner), around.class_of[2]), "and it does not reach the third corner");
}

// A mesh with nothing to walk comes back empty rather than refused, the rule
// every structure built off the geometry follows.
fn void a_mesh_with_no_triangles_has_no_neighbourhoods() @test
{
	rig::MeshAdjacency nothing = rig::build_adjacency(mem, {});
	defer nothing.free(mem);
	test::@check(!nothing.usable(), "an empty mesh reports neighbourhoods");
	test::eq(nothing.vertices(), (usz)0);

	rig::TriMesh cloud = { .positions = pinched_positions[..] };
	rig::MeshAdjacency loose = rig::build_adjacency(mem, cloud);
	defer loose.free(mem);
	test::@check(!loose.usable(), "a point cloud reports neighbourhoods");
	test::eq(loose.vertices(), (usz)3);
	test::eq((usz)loose.offsets[loose.offsets.len - 1], (usz)0);
}

// Built on demand and not before: nothing on the binder's path wants it, so a
// session that never smooths never pays for the sort.
fn void the_adjacency_is_built_when_it_is_asked_for() @test
{
	crig::AppState app = chained();
	defer app.free();

	test::eq(app.adjacency.vertices(), (usz)0);

	rig::MeshAdjacency* around = app.adjacency_for();
	test::eq(around.vertices(), (usz)cube_positions.len);
	test::@check(around.usable(), "the cube came back with no neighbourhoods");

	// Kept rather than rebuilt on the next ask, which is what the length check
	// buys. Marked in place to prove it: two builds of one mesh are equal down to
	// the byte, and an array freed and taken again is frequently the same array.
	app.adjacency.class_of[0] = 4242;
	test::eq((usz)app.adjacency_for().class_of[0], (usz)4242);

	// A different body under the same rig gets its own: the welds are keyed to
	// vertices this mesh does not have.
	rig::TriMesh other = strip_mesh(6);
	app.replace_geometry(other);
	test::eq(app.adjacency_for().vertices(), (usz)other.positions.len);
	test::@check(app.adjacency.class_of[0] != 4242, "the mark survived the mesh being replaced");
}

// ---------------------------------------------------------------------------
// Harden and smooth
//
// Two ops over the whole mesh, both of which compute a share and then state it.
// What these assert is the deciding — which vertices each one picks up and which
// it leaves — since the writing itself is `pin_dabs` and is covered above.

<*
 A vertex one dot nearly holds is handed over outright; one it merely leads on is
 left alone.

 The threshold, asserted on shares put in by hand rather than on the binder's
 opinion of a cube: 0.85 is over the line, 0.75 is under it, and a vertex already
 stated rigid is a row with nothing to harden.
*>
fn void harden_takes_the_nearly_rigid_and_leaves_the_rest() @test
{
	crig::AppState app = chained();
	defer app.free();

	uint hips = dot_named(&app, "hips");
	uint foot = dot_named(&app, "foot");

	uint[1] nearly = { 0 };
	uint[1] leading = { 1 };
	uint[1] rigid = { 2 };
	app.pin_vertices(nearly[..], hips, 0.85f);
	app.pin_vertices(leading[..], hips, 0.75f);
	app.pin_vertices(rigid[..], foot, 1.0f);

	sz edits_before = app.undo_stack.edits.len();

	usz did = app.harden_weights();
	test::@check(did > 0, "harden found nothing on a fixture built for it");
	test::@check(app.notice().contains("rigid"), "and said nothing about it: \"%s\"", app.notice());

	// One entry however much of the mesh moved.
	test::eq(app.undo_stack.edits.len(), edits_before + 1);

	test::@check(app.doc.pin_of(0, hips) == 1.0f,
		"the vertex at 0.85 came out at %s rather than rigid", app.doc.pin_of(0, hips));
	test::@check(app.doc.pin_of(1, hips) == 0.75f,
		"the vertex at 0.75 was moved to %s", app.doc.pin_of(1, hips));
	test::@check(app.doc.pin_of(2, foot) == 1.0f, "an already-rigid vertex was rewritten");
	test::@check(app.doc.pin_of(2, hips) == 0.0f, "an already-rigid vertex changed hands");

	test::@check(app.undo(), "harden is one step on the ledger");
	test::@check(app.doc.pin_of(0, hips) == 0.85f,
		"undo left the vertex at %s rather than the 0.85 it found", app.doc.pin_of(0, hips));
	test::@check(app.doc.pin_of(1, hips) == 0.75f && app.doc.pin_of(2, foot) == 1.0f,
		"undo did not put the rest of the layer back");
}

<*
 A bind that is already rigid everywhere records nothing.

 The `pin_dabs` rule one level up, and what keeps a menu item that was clicked
 twice off the ledger: a single-influence row is what hardening writes, so a mesh
 made of them has nothing to say.
*>
fn void hardening_an_already_rigid_bind_records_nothing() @test
{
	crig::AppState app = chained();
	defer app.free();

	uint hips = dot_named(&app, "hips");

	// The binder's own rigid rows first, and they are the half that can go wrong
	// quietly: an attached piece is bound to one joint outright with nothing in
	// the pin layer to say so, so an op that read only the layer would write a
	// pin per vertex and call it work.
	app.select(hips);
	app.pin_shell(0);
	test::eq(app.doc.attachment_of(0), hips);

	sz settled = app.undo_stack.edits.len();
	test::eq(app.harden_weights(), (usz)0);
	test::eq(app.undo_stack.edits.len(), settled);
	test::eq(app.doc.pins.len(), (sz)0);
	test::@check(app.notice().contains("nothing to make rigid"), "the refusal says \"%s\"", app.notice());

	// And again through the pin layer, which reaches the same row by the other
	// door.
	uint[8] whole = { 0, 1, 2, 3, 4, 5, 6, 7 };
	app.pin_vertices(whole[..], hips, 1.0f);

	settled = app.undo_stack.edits.len();
	test::eq(app.harden_weights(), (usz)0);
	test::eq(app.undo_stack.edits.len(), settled);
}

<*
	Both ops refuse while an animation draft deforms the body, and say why.

 The lasso's rule, for the lasso's reason: they read the bind, the bind is
	against the rest mesh, and a share computed off a draft is a share of something
 nobody was looking at.
*>
fn void the_cleanup_ops_refuse_during_animation_editing() @test
{
	crig::AppState app = chained();
	defer app.free();

	app.pose_edit_active = true;
	test::@check(app.rig_locked(), "the fixture did not lock the rig");

	sz settled = app.undo_stack.edits.len();
	test::eq(app.harden_weights(), (usz)0);
	test::@check(app.notice().contains("animation editing"), "harden said \"%s\"", app.notice());
	test::eq(app.smooth_boundaries(), (usz)0);
	test::@check(app.notice().contains("animation editing"), "smooth said \"%s\"", app.notice());

	test::eq(app.undo_stack.edits.len(), settled);
	test::eq(app.doc.pins.len(), (sz)0);
}

<*
 A flat strip of quads running along x: two rows of `columns` points, two
 triangles per quad between them.

 Long and thin on purpose. A boundary between two dots at its ends falls at one
 column, so "the band" is a handful of columns around a known place and "monotone
 across it" is a claim a check can make. The caller frees the mesh with
 `TriMesh.free` once the AppState over it is gone.
*>
fn rig::TriMesh strip_mesh(usz columns)
{
	usz quads = columns - 1;
	rig::TriMesh mesh = {
		.positions = alloc::new_array(mem, Vec3, (sz)(columns * 2)),
		.indices = alloc::new_array(mem, uint, (sz)(quads * 6)),
	};

	for (usz i = 0; i < columns; i++)
	{
		float x = (float)i / (float)(columns - 1);
		mesh.positions[i * 2] = { x, 0.0f, 0.0f };
		mesh.positions[i * 2 + 1] = { x, 0.4f, 0.0f };
	}
	for (usz q = 0; q < quads; q++)
	{
		uint a = (uint)(q * 2);
		mesh.indices[q * 6] = a;
		mesh.indices[q * 6 + 1] = a + 1;
		mesh.indices[q * 6 + 2] = a + 3;
		mesh.indices[q * 6 + 3] = a;
		mesh.indices[q * 6 + 4] = a + 3;
		mesh.indices[q * 6 + 5] = a + 2;
	}
	return mesh;
}

// Every vertex's share of one dot, as the bind currently stands — pins included,
// which is what makes a smoothed band readable as numbers. The caller frees it.
fn float[] shares_of(crig::AppState* app, uint dot)
{
	crig::RigView? opened = app.open_rig(mem);
	if (catch opened) return {};
	crig::RigView view = opened;
	defer view.free(mem);

	sz joint = view.joint_of(dot);
	usz bones = view.len();

	float[] painted = app.painted_bind(mem, &view);
	defer if (painted.len > 0) alloc::free(mem, painted);
	if (joint < 0 || painted.len == 0) return {};

	usz count = app.geometry.positions.len;
	float[] out = alloc::new_array(mem, float, (sz)count);
	for (usz v = 0; v < count; v++)
	{
		float sum = 0.0f;
		for (usz b = 0; b < bones; b++) sum += painted[v * bones + b];
		out[v] = sum > 0.0f ? painted[v * bones + (usz)joint] / sum : 0.0f;
	}
	return out;
}

// How far from an even split the whole mesh is: the number that says "sharper"
// as one figure, so a second smoothing pass can be asserted to soften without
// naming any vertex's share.
fn float sharpness_of(float[] shares)
{
	float total = 0.0f;
	foreach (share : shares) total += math::abs(share - 0.5f);
	return total;
}

<*
 Smoothing turns a hard step into a ramp, over a band it finds for itself.

 The step is stated rather than bound for, which is exactly the case the op is
 reached for: two lassos meeting down the middle of a strip leave every vertex
 rigid and the seam between them a cliff, and no amount of rebinding softens it
 because a pin is not a thing the binder has an opinion about. What the op writes
 is the ramp: every vertex it touches lands strictly between the two sides it
 lies between, and the shares fall monotonically across it.
*>
fn void smoothing_widens_a_hard_boundary() @test
{
	rig::TriMesh mesh = strip_mesh(12);
	crig::AppState app = crig::new_app(mesh);
	defer
	{
		app.free();
		mesh.free(mem);
	}

	uint left = app.doc.add_dot({ 0.0f, 0.2f, 0.0f }, "left");
	uint right = app.doc.add_dot({ 1.0f, 0.2f, 0.0f }, "right");
	app.doc.connect(left, right);

	// Half the strip each, rigid: the cliff, put in by hand.
	uint[12] near;
	uint[12] far;
	for (usz i = 0; i < 6; i++)
	{
		near[i * 2] = (uint)(i * 2);
		near[i * 2 + 1] = (uint)(i * 2 + 1);
		far[i * 2] = (uint)((i + 6) * 2);
		far[i * 2 + 1] = (uint)((i + 6) * 2 + 1);
	}
	app.pin_vertices(near[..], left, 1.0f);
	app.pin_vertices(far[..], right, 1.0f);

	float[] before = shares_of(&app, left);
	defer alloc::free(mem, before);

	// The fixture's premise: a hard step, and only one of them.
	usz steps = 0;
	for (usz i = 0; i + 1 < 12; i++)
	{
		if ((before[i * 2] > 0.5f) != (before[(i + 1) * 2] > 0.5f)) steps++;
	}
	test::eq(steps, (usz)1);

	sz edits_before = app.undo_stack.edits.len();

	usz did = app.smooth_boundaries();
	test::@check(did > 0, "smoothing found no boundary on a two-dot strip: \"%s\"", app.notice());
	test::@check(app.notice().contains("smoothed"), "and said nothing about it: \"%s\"", app.notice());
	test::eq(app.undo_stack.edits.len(), edits_before + 1);

	float[] after = shares_of(&app, left);
	defer alloc::free(mem, after);

	// The band, as the op decided it: the columns whose shares moved.
	sz first = -1;
	sz last = -1;
	for (usz i = 0; i < 12; i++)
	{
		if (after[i * 2] == before[i * 2]) continue;
		if (first < 0) first = (sz)i;
		last = (sz)i;
	}
	test::@check(first > 0 && last > first && last < 11,
		"the band runs from column %d to %d — it should be inside the strip", first, last);

	// Every column between carries a share of both dots, so the band is one run
	// rather than a scatter — a hole in it would be a dilation that skipped a ring.
	for (usz i = (usz)first; i <= (usz)last; i++)
	{
		test::@check(app.doc.pin_of((uint)(i * 2), left) > 0.0f
			&& app.doc.pin_of((uint)(i * 2), right) > 0.0f,
			"column %d is inside the band and does not ride both dots", i);
	}

	// Strictly between the two sides, which is what "a ramp" means.
	float above = before[(usz)(first - 1) * 2];
	float below = before[(usz)(last + 1) * 2];
	for (usz i = (usz)first; i <= (usz)last; i++)
	{
		test::@check(after[i * 2] < above && after[i * 2] > below,
			"column %d came out at %s, outside the %s .. %s the sides left it",
			i, after[i * 2], below, above);
	}

	// And monotone across it, per row: a blend that rose again on the way across
	// would be a fold in the deformation rather than a transition.
	for (usz row = 0; row < 2; row++)
	{
		for (usz i = (usz)first; i < (usz)last; i++)
		{
			test::@check(after[i * 2 + row] > after[(i + 1) * 2 + row],
				"row %d rises across the band: column %d holds %s and %d holds %s",
				row, i, after[i * 2 + row], i + 1, after[(i + 1) * 2 + row]);
		}
	}

	// Running it again smooths further rather than repeating itself, which is what
	// makes the op a knob the user turns until it looks right. Measured as one
	// figure — how far from an even split the whole mesh is — rather than as any
	// vertex's share, since what a further pass is worth is not a number a check
	// should be asserting from the outside.
	float sharp_once = sharpness_of(after);
	test::@check(app.smooth_boundaries() > 0, "the second pass found nothing to do");

	float[] twice = shares_of(&app, left);
	defer alloc::free(mem, twice);
	test::@check(sharpness_of(twice) < sharp_once,
		"the second pass left the mesh at %s where the first left it at %s",
		sharpness_of(twice), sharp_once);

	// Both passes undo exactly, in the order they were made — back to the two
	// rigid halves the fixture stated, not back to nothing.
	test::@check(app.undo() && app.undo(), "the two passes are two steps");
	test::eq(app.doc.pins.len(), (sz)24);

	float[] back = shares_of(&app, left);
	defer alloc::free(mem, back);
	usz wrong = 0;
	for (usz v = 0; v < back.len; v++)
	{
		if (back[v] != before[v]) wrong++;
	}
	test::eq(wrong, (usz)0);
}

<*
 A mesh one dot holds everywhere has no boundary, and nothing to write.

 The other half of "the band is found rather than drawn": with one winner there
 is nowhere two joints meet, so the op is a no-op on the ledger rather than a
 pass that quietly bakes the whole model into pins.
*>
fn void smoothing_a_mesh_with_one_winner_records_nothing() @test
{
	rig::TriMesh mesh = strip_mesh(12);
	crig::AppState app = crig::new_app(mesh);
	defer
	{
		app.free();
		mesh.free(mem);
	}

	app.doc.add_dot({ 0.5f, 0.2f, 0.0f }, "only");

	sz settled = app.undo_stack.edits.len();
	test::eq(app.smooth_boundaries(), (usz)0);
	test::eq(app.undo_stack.edits.len(), settled);
	test::eq(app.doc.pins.len(), (sz)0);
	test::@check(app.notice().contains("nothing to smooth"), "the refusal says \"%s\"", app.notice());
}

// A square grid of `side` × `side` vertices facing +Z, centred on `centre`.
fn void grid_into(List{Vec3}* positions, List{uint}* indices, Vec3 centre, float size, uint side)
{
	uint first = (uint)positions.len();
	for (uint row = 0; row < side; row++)
	{
		for (uint col = 0; col < side; col++)
		{
			float u = (float)col / (float)(side - 1) - 0.5f;
			float w = (float)row / (float)(side - 1) - 0.5f;
			positions.push(centre + (Vec3){ u * size, w * size, 0.0f });
		}
	}
	for (uint row = 0; row + 1 < side; row++)
	{
		for (uint col = 0; col + 1 < side; col++)
		{
			uint a = first + row * side + col;
			indices.push(a); indices.push(a + 1); indices.push(a + side);
			indices.push(a + 1); indices.push(a + side + 1); indices.push(a + side);
		}
	}
}

<*
 A brush circle over a hand held in front of the chest paints the hand, not the
 chest showing round it: only the surface under the cursor is taken.
*>
fn void the_brush_paints_only_the_surface_under_it() @test
{
	List{Vec3} positions;
	positions.init(mem);
	defer positions.free();
	List{uint} indices;
	indices.init(mem);
	defer indices.free();
	grid_into(&positions, &indices, { 0, 0, 0 }, 2.0f, 21);   // the chest
	usz chest = (usz)positions.len();
	grid_into(&positions, &indices, { 0, 0, 1 }, 0.3f, 7);    // the hand, in front of it

	crig::AppState app = crig::new_app({ .positions = positions.array_view(), .indices = indices.array_view() });
	defer app.free();
	app.camera.target = { 0, 0, 0 };
	app.camera.distance = 4.0f;
	app.camera.yaw = 0.0f;
	app.camera.pitch = 0.0f;

	Vec2 viewport = { 800, 600 };
	Matrix4f vp = app.camera.view_projection(viewport.x / viewport.y);
	Vec3 eye = app.camera.eye();
	usz count = app.geometry.positions.len;
	uint[] under = alloc::new_array(mem, uint, (sz)count);
	defer alloc::free(mem, under);
	float[] strength = alloc::new_array(mem, float, (sz)count);
	defer alloc::free(mem, strength);

	// Wide enough to take the chest all round the hand.
	Vec2 hand = crig::project(vp, { 0, 0, 1 }, viewport)!!;
	usz hit = app.brush_vertices(under, strength, vp, viewport, eye, hand, 150.0f);
	usz on_hand = 0;
	usz on_chest = 0;
	for (usz i = 0; i < hit; i++)
	{
		if ((usz)under[i] >= chest) { on_hand++; } else { on_chest++; }
	}
	test::@check(on_hand > 0, "the circle over the hand took none of it");
	test::eq(on_chest, (usz)0);

	// Over the chest, clear of the hand, it is the chest that is painted.
	Vec2 side = crig::project(vp, { 0.7f, 0, 0 }, viewport)!!;
	hit = app.brush_vertices(under, strength, vp, viewport, eye, side, 40.0f);
	on_hand = 0;
	on_chest = 0;
	for (usz i = 0; i < hit; i++)
	{
		if ((usz)under[i] >= chest) { on_hand++; } else { on_chest++; }
	}
	test::@check(on_chest > 0, "the circle over the chest took none of it");
	test::eq(on_hand, (usz)0);
}
