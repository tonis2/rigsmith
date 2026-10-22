// The distance field the automatic weights are made from, and the band they end
// at: a joint holds a vertex only while it is nearly as near as the vertex's
// owner, so nothing far away keeps a sliver. On the shipped humanoid.
module crig_tests::weight_field;

import crig;
import rig;
import std::core::test;
import std::io::file;
import std::math;

const String FIELD_COPY = "build/weight-field-humanoid.glb";

fn void open_field(crig::AppState* app, rig::TriMesh* mesh)
{
	char[] original = file::load(mem, "assets/animations/humanoid.glb")!!;
	defer alloc::free(mem, original);
	file::save(FIELD_COPY, original)!!;
	*mesh = rig::load_gltf(mem, FIELD_COPY)!!;
	*app = crig::new_app(*mesh, FIELD_COPY);
	test::@check(app.import_rig_from_source(), "the humanoid rig must import");
	app.doc.skin_from_file = false;
}

fn void close_field(crig::AppState* app, rig::TriMesh* mesh)
{
	app.free();
	mesh.free(mem);
	(void)file::delete(FIELD_COPY);
	String sidecar = crig::session_path(mem, FIELD_COPY);
	defer sidecar.free(mem);
	(void)file::delete(sidecar);
}

<*
 Every joint holding a vertex sits within its band of the vertex's owner — the
 window's own promise, read back off the bind the app hands out.
*>
fn void no_joint_holds_weight_past_its_band() @test
{
	crig::AppState app;
	rig::TriMesh mesh;
	open_field(&app, &mesh);
	defer close_field(&app, &mesh);

	crig::RigView view = app.open_rig(mem)!!;
	defer view.free(mem);
	usz bones = view.len();
	usz count = app.geometry.positions.len;
	float[] automatic = app.weights(mem, &view, AUTOMATIC);
	defer alloc::free(mem, automatic);
	test::@check(app.field_distances.len == count * bones, "the bind kept no distances");
	float[] bands = app.bind_bands(mem, &view);
	defer alloc::free(mem, bands);

	usz past = 0;
	for (usz v = 0; v < count; v++)
	{
		float[] row = automatic[v * bones:bones];
		usz owner = crig::strongest_joint(row);
		float reference = app.field_distances[v * bones + owner];
		for (usz b = 0; b < bones; b++)
		{
			if (b == owner || row[b] <= 0.0f) continue;
			float band = math::max(bands[b], bands[owner]);
			if (app.field_distances[v * bones + b] - reference >= band) past++;
		}
	}
	test::@check(past == 0, "%d holds sit past their joint's band", past);
}

<*
 The case the window exists for: the hips hold nothing of the legs below the
 knees. A geodesic falloff with no end gave them a percent or two of every boot,
 and taking a leg joint off a shin then handed the shin to the hips.
*>
fn void the_hips_hold_nothing_below_the_knees() @test
{
	crig::AppState app;
	rig::TriMesh mesh;
	open_field(&app, &mesh);
	defer close_field(&app, &mesh);

	crig::RigView view = app.open_rig(mem)!!;
	defer view.free(mem);
	usz bones = view.len();
	sz hips = -1;
	sz knee = -1;
	foreach (j, name : view.names)
	{
		if (name == "hips") hips = (sz)j;
		if (name == "knee_L") knee = (sz)j;
	}
	test::@check(hips >= 0 && knee >= 0, "the humanoid has no hips or knee_L");
	float below = view.skeleton.joints[(usz)knee].y;

	float[] automatic = app.weights(mem, &view, AUTOMATIC);
	defer alloc::free(mem, automatic);
	float most = 0.0f;
	foreach (v, p : app.geometry.positions)
	{
		if (p.y >= below) continue;
		most = math::max(most, crig::joint_share(automatic[(usz)v * bones:bones], (usz)hips));
	}
	test::@check(most == 0.0f, "the hips hold up to %f of a vertex below the knees", most);
}

<*
 Taking a leg joint off a shin hands the shin down the leg, never to the hips —
 the brush's handoff reads the field, not the slivers on the row.
*>
fn void taking_the_knee_off_a_shin_hands_it_down_the_leg() @test
{
	crig::AppState app;
	rig::TriMesh mesh;
	open_field(&app, &mesh);
	defer close_field(&app, &mesh);

	crig::RigView view = app.open_rig(mem)!!;
	defer view.free(mem);
	usz bones = view.len();
	uint knee_dot = 0;
	sz knee = -1;
	sz hips = -1;
	foreach (j, name : view.names)
	{
		if (name == "knee_L") { knee = (sz)j; knee_dot = view.dot_ids[j]; }
		if (name == "hips") hips = (sz)j;
	}
	float[] automatic = app.weights(mem, &view, AUTOMATIC);
	defer alloc::free(mem, automatic);

	// Every vertex the knee holds almost all of: the middle of the shin.
	uint[] shin = alloc::new_array(mem, uint, (sz)app.geometry.positions.len);
	defer alloc::free(mem, shin);
	usz held = 0;
	foreach (v, p : app.geometry.positions)
	{
		if (crig::joint_share(automatic[(usz)v * bones:bones], (usz)knee) >= 0.95f) shin[held++] = (uint)v;
	}
	test::@check(held > 20, "only %d vertices are the knee's outright", held);

	crig::PaintResult did = app.paint_share(knee_dot, shin[:held], 0.0f);
	test::@check(did.changed > 0 && did.alone == 0, "taking the knee off its shin changed nothing");

	// A fresh view: one resolves the pins when it is opened.
	crig::RigView after = app.open_rig(mem)!!;
	defer after.free(mem);
	float[] shown = app.weights(mem, &after);
	defer alloc::free(mem, shown);
	usz to_hips = 0;
	usz left = 0;
	foreach (v : shin[:held])
	{
		if (crig::joint_share(shown[(usz)v * bones:bones], (usz)hips) > 0.0f) to_hips++;
		if (crig::joint_share(shown[(usz)v * bones:bones], (usz)knee) > 0.0f) left++;
	}
	test::@check(left == 0, "the knee kept %d of the shin", left);
	test::@check(to_hips == 0, "%d shin vertices went to the hips", to_hips);
}

<*
 A rig saved before the weights ended at a band says so once, when it opens:
 the same dots bind tighter now, and a model that deforms otherwise with nothing
 said would read as a broken file.
*>
fn void an_older_session_says_its_weights_were_re_derived() @test
{
	crig::AppState app;
	rig::TriMesh mesh;
	open_field(&app, &mesh);
	defer close_field(&app, &mesh);

	app.save_beside_mesh();
	String path = crig::session_path(mem, FIELD_COPY);
	defer path.free(mem);
	char[] saved = file::load(mem, path)!!;
	defer alloc::free(mem, saved);
	String text = (String)saved;
	test::@check(text.contains(`"version": 31`), "the session is not version 31");

	String older = text.replace(mem, `"version": 31`, `"version": 30`);
	defer older.free(mem);
	file::save(path, older)!!;
	app.load_session();
	test::@check(app.notice().contains("re-derived"), "an older session opened saying: %s", app.notice());

	app.save_beside_mesh();
	app.load_session();
	test::@check(!app.notice().contains("re-derived"), "a current session still said: %s", app.notice());
}

fn uint field_dot(crig::AppState* app, String name)
{
	foreach (dot : app.doc.dots.array_view()) if (dot.name == name) return dot.id;
	return 0;
}

fn float[] automatic_now(crig::AppState* app)
{
	crig::RigView view = app.open_rig(mem)!!;
	defer view.free(mem);
	return app.weights(mem, &view, AUTOMATIC);
}

fn usz rows_apart(float[] a, float[] b)
{
	if (a.len != b.len) return a.len + b.len + 1;
	usz apart = 0;
	foreach (i, w : a) if (math::abs(w - b[i]) > 1.0e-6f * math::max(math::abs(w), 1.0f)) apart++;
	return apart;
}

<*
 Grow and Shrink are one live edge run two ways: two steps out and two back is
 the bind it started from, and Reset after a Grow is the automatic bind — not a
 part the steps left behind.
*>
fn void grow_and_shrink_undo_each_other_and_reset_is_automatic() @test
{
	crig::AppState app;
	rig::TriMesh mesh;
	open_field(&app, &mesh);
	defer close_field(&app, &mesh);

	uint ankle = field_dot(&app, "ankle_R");
	app.select(ankle);
	float[] start = automatic_now(&app);
	defer alloc::free(mem, start);

	test::@check(app.grow_joint(2), "the ankle would not grow");
	float[] grown = automatic_now(&app);
	defer alloc::free(mem, grown);
	test::@check(rows_apart(start, grown) > 0, "growing the ankle changed no weight");
	test::@check(app.doc.pins.len() == 0, "Grow wrote pins");

	test::@check(app.grow_joint(-2), "the ankle would not shrink back");
	float[] back = automatic_now(&app);
	defer alloc::free(mem, back);
	usz apart = rows_apart(start, back);
	test::@check(apart == 0, "two steps out and two back left %d weights changed", apart);

	app.grow_joint(3);
	app.soften_joint(1.0f);
	app.undo_stack.commit(); // the slider's release
	app.reset_joint_area();
	float[] reset = automatic_now(&app);
	defer alloc::free(mem, reset);
	apart = rows_apart(start, reset);
	test::@check(apart == 0, "Reset after a grow left %d weights off the automatic bind", apart);
	test::@check(app.undo(), "the reset left nothing to undo");
	test::@check(app.doc.find(ankle).grow > 0.0f && app.doc.find(ankle).band > 0.0f, "one undo did not bring the edge back");
}

<*
 With Mirror on, a Grow grows the twin by its own step too; with it off, only
 the joint pressed.
*>
fn void a_grow_mirrors_to_the_twin() @test
{
	crig::AppState app;
	rig::TriMesh mesh;
	open_field(&app, &mesh);
	defer close_field(&app, &mesh);

	uint right = field_dot(&app, "knee_R");
	uint left = field_dot(&app, "knee_L");
	app.select(right);
	test::@check(app.grow_joint(1), "the knee would not grow");
	test::@check(app.doc.find(right).grow > 0.0f && app.doc.find(left).grow > 0.0f, "the twin did not grow with Mirror on");
	test::@check(math::abs(app.doc.find(right).grow - app.doc.find(left).grow) < 1.0e-6f, "the twins grew by different steps");

	app.area_solo = true;
	float twin_was = app.doc.find(left).grow;
	test::@check(app.grow_joint(1), "the knee would not grow again");
	test::@check(app.doc.find(left).grow == twin_was, "the twin grew with Mirror off");
}

<*
 A grow is an offset to the joint's distance, so it travels with the dot: moved,
 the grown joint still holds more than the same joint moved ungrown.
*>
fn void a_grow_moves_with_its_dot() @test
{
	crig::AppState app;
	rig::TriMesh mesh;
	open_field(&app, &mesh);
	defer close_field(&app, &mesh);

	uint knee = field_dot(&app, "knee_L");
	crig::Dot* dot = app.doc.find(knee);
	Vec3 moved = dot.position + (Vec3){ 0.0f, 0.02f, 0.0f };
	app.doc.move_dot(knee, moved);

	crig::RigView view = app.open_rig(mem)!!;
	usz joint = (usz)view.joint_of(knee);
	usz bones = view.len();
	view.free(mem);
	float[] plain = automatic_now(&app);
	defer alloc::free(mem, plain);

	app.select(knee);
	test::@check(app.grow_joint(2), "the knee would not grow");
	float[] grown = automatic_now(&app);
	defer alloc::free(mem, grown);

	usz owns_plain = 0;
	usz owns_grown = 0;
	for (usz v = 0; v < app.geometry.positions.len; v++)
	{
		if (crig::strongest_joint(plain[v * bones:bones]) == joint) owns_plain++;
		if (crig::strongest_joint(grown[v * bones:bones]) == joint) owns_grown++;
	}
	test::@check(owns_grown > owns_plain, "the moved, grown knee owns %d vertices against %d ungrown", owns_grown, owns_plain);
}

<*
 The multipliers a session before version 31 carried come back as stated rows:
 the one hand-edit layer every tool now writes. The vertex shows what the
 multiplier made of it, and nothing writes multipliers again.
*>
fn void an_older_sessions_multipliers_load_as_stated_rows() @test
{
	crig::AppState app;
	rig::TriMesh mesh;
	open_field(&app, &mesh);
	defer close_field(&app, &mesh);

	uint knee = field_dot(&app, "knee_L");
	crig::RigView view = app.open_rig(mem)!!;
	usz bones = view.len();
	usz joint = (usz)view.joint_of(knee);
	float[] base = app.weights(mem, &view, AUTOMATIC);
	view.free(mem);
	defer alloc::free(mem, base);
	// A vertex the knee shares, so a multiplier on it moves the share.
	uint shared = 0;
	for (usz v = 0; v < app.geometry.positions.len; v++)
	{
		float share = crig::joint_share(base[v * bones:bones], joint);
		if (share > 0.2f && share < 0.8f) { shared = (uint)v; break; }
	}
	test::@check(shared != 0, "the knee shares no vertex");
	float[] row = alloc::new_array(mem, float, (sz)bones);
	defer alloc::free(mem, row);
	row[..] = base[(usz)shared * bones:bones];
	row[joint] *= 0.25f;
	float want = crig::joint_share(row, joint);

	app.save_beside_mesh();
	String path = crig::session_path(mem, FIELD_COPY);
	defer path.free(mem);
	char[] saved = file::load(mem, path)!!;
	defer alloc::free(mem, saved);
	String older = ((String)saved).replace(mem, `"version": 31`, `"version": 30`);
	defer older.free(mem);
	String painted = older.replace(mem, `"attachments": [`,
		string::tformat(`"paint": [[%d,%d,0.25]],
  "attachments": [`, shared, knee));
	defer painted.free(mem);
	file::save(path, painted)!!;

	app.load_session();
	test::@check(app.doc.paint.len() == 0, "the multipliers were kept as multipliers");
	test::@check(app.doc.pins.len() > 0, "the multiplier did not become a stated row");
	crig::RigView after = app.open_rig(mem)!!;
	defer after.free(mem);
	float[] shown = app.weights(mem, &after);
	defer alloc::free(mem, shown);
	float got = crig::joint_share(shown[(usz)shared * bones:bones], joint);
	test::@check(math::abs(got - want) < 0.05f, "the knee holds %f of the vertex, the multiplier made it %f", got, want);
	test::@check(!app.undo_stack.can_undo(), "loading left the conversion on the history");
}

<*
 The case that started the redesign: a boot vertex stated wholly to the hips —
 a leg joint taken off it once handed it there — can have the hips taken off
 again, and goes back to the leg rather than staying put.
*>
fn void taking_the_hips_off_a_vertex_they_hold_whole_hands_it_to_the_leg() @test
{
	crig::AppState app;
	rig::TriMesh mesh;
	open_field(&app, &mesh);
	defer close_field(&app, &mesh);

	uint hips = field_dot(&app, "hips");
	uint ankle = field_dot(&app, "ankle_L");
	crig::RigView view = app.open_rig(mem)!!;
	usz bones = view.len();
	usz ankle_joint = (usz)view.joint_of(ankle);
	usz hips_joint = (usz)view.joint_of(hips);
	float[] base = app.weights(mem, &view, AUTOMATIC);
	view.free(mem);
	defer alloc::free(mem, base);
	uint boot = 0;
	for (usz v = 0; v < app.geometry.positions.len; v++)
	{
		if (crig::joint_share(base[v * bones:bones], ankle_joint) > 0.9f) { boot = (uint)v; break; }
	}
	test::@check(boot != 0, "the ankle holds no vertex outright");

	uint[1] one = { boot };
	app.pin_vertices(one[..], hips, 1.0f);
	crig::PaintResult did = app.paint_share(hips, one[..], 0.0f);
	test::@check(did.changed > 0 && did.alone == 0, "taking the hips off their whole vertex was refused");

	crig::RigView after = app.open_rig(mem)!!;
	defer after.free(mem);
	float[] shown = app.weights(mem, &after);
	defer alloc::free(mem, shown);
	float[] row = shown[(usz)boot * bones:bones];
	test::@check(crig::joint_share(row, hips_joint) == 0.0f, "the hips kept %f", crig::joint_share(row, hips_joint));
	test::@check(crig::joint_share(row, ankle_joint) > 0.5f, "the boot went to %f ankle rather than back to the leg",
		crig::joint_share(row, ankle_joint));
}

<*
 The view draws the weights the mesh wears and nothing over them: a hand edit
 shows as its new share, in the same colours as every other vertex.
*>
fn void the_view_shows_the_edited_weights_plainly() @test
{
	crig::AppState app;
	rig::TriMesh mesh;
	open_field(&app, &mesh);
	defer close_field(&app, &mesh);

	uint knee = field_dot(&app, "knee_L");
	app.select(knee);
	app.show_joint_panel = true;
	app.joint_panel_tab = WEIGHTS;
	app.sync_weights_card();
	app.rebind_tints();
	uint[] automatic = alloc::clone_slice(mem, app.tints);
	defer alloc::free(mem, automatic);

	// A vertex the knee holds outright, so taking it off changes the picture.
	crig::RigView view = app.open_rig(mem)!!;
	usz bones = view.len();
	usz joint = (usz)view.joint_of(knee);
	float[] weights = app.weights(mem, &view, AUTOMATIC);
	view.free(mem);
	defer alloc::free(mem, weights);
	uint[1] one = { 0 };
	for (usz v = 0; v < app.geometry.positions.len; v++)
	{
		if (crig::joint_share(weights[v * bones:bones], joint) > 0.9f) { one[0] = (uint)v; break; }
	}
	app.paint_share(knee, one[..], 0.0f);
	app.rebind_tints();
	test::@check(app.tints[one[0]] != automatic[one[0]], "the edited vertex looks as it did");
	test::@check(app.tints[one[0]] == crig::share_tint(0.0f), "the edited vertex is not drawn as the share it now holds");
}

<*
 One Mirror for every weight tool: with it on, a brush stroke and a lasso both
 change the twin across the plane too, and with it off neither does.
*>
fn void the_brush_and_the_lasso_mirror_to_the_twin() @test
{
	crig::AppState app;
	rig::TriMesh mesh;
	open_field(&app, &mesh);
	defer close_field(&app, &mesh);

	uint left = field_dot(&app, "knee_L");
	uint right = field_dot(&app, "knee_R");
	crig::RigView view = app.open_rig(mem)!!;
	usz bones = view.len();
	usz joint = (usz)view.joint_of(left);
	float[] automatic = app.weights(mem, &view, AUTOMATIC);
	view.free(mem);
	defer alloc::free(mem, automatic);
	uint[4] some;
	usz found = 0;
	for (usz v = 0; v < app.geometry.positions.len && found < 4; v++)
	{
		if (crig::joint_share(automatic[v * bones:bones], joint) > 0.9f) some[found++] = (uint)v;
	}
	test::@check(found == 4, "the left knee holds too little");

	app.select(left);
	test::@check(app.begin_brush(), "the brush would not open");
	app.begin_stroke();
	float[4] pulls = { 1.0f, 1.0f, 1.0f, 1.0f };
	app.brush_share(left, some[..], 0.0f, pulls[..]);
	app.end_stroke();
	usz twin_rows = 0;
	foreach (pin : app.doc.pins.array_view()) if (pin.by == right) twin_rows++;
	test::@check(twin_rows > 0, "the stroke did not reach the right knee with Mirror on");
	test::@check(app.undo(), "the mirrored stroke left nothing to undo");
	test::eq(app.doc.pins.len(), (sz)0);
	app.end_brush();

	// The lasso, through its commit's own mirror.
	app.pin_vertices(some[..], left, 1.0f, commit: false);
	app.lasso_mirror(some[..], 1.0f);
	app.undo_stack.commit();
	bool mirrored = false;
	foreach (pin : app.doc.pins.array_view()) if (pin.dot_id == right) mirrored = true;
	test::@check(mirrored, "the lasso did not reach the right knee with Mirror on");
	test::@check(app.undo() && app.doc.pins.len() == 0, "the region and its mirror were not one undo step");

	app.area_solo = true;
	app.begin_brush();
	app.begin_stroke();
	app.brush_share(left, some[..], 0.0f, pulls[..]);
	app.end_stroke();
	foreach (pin : app.doc.pins.array_view())
	{
		test::@check(pin.by != right, "a stroke with Mirror off reached the right knee");
	}
}

<*
 The lasso's pinning job shows the joint's weights it is editing, the way the
 brush and the card do, and gives the view back when it closes.
*>
fn void lasso_pinning_shows_the_falloff() @test
{
	crig::AppState app;
	rig::TriMesh mesh;
	open_field(&app, &mesh);
	defer close_field(&app, &mesh);

	app.select(field_dot(&app, "knee_L"));
	test::@check(app.tint_mode == OFF, "the fixture started with a view on");
	test::@check(app.begin_lasso(PIN), "the lasso would not open on pinning");
	test::@check(app.tint_mode == FALLOFF, "pinning did not show the falloff");
	app.end_lasso();
	test::@check(app.tint_mode == OFF, "closing the lasso left the falloff up");
}
