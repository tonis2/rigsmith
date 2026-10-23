// Every reader of the weights reads the same weights: the survey, the territory
// and falloff views, the posed skin and get_weights' rows all come through
// `AppState.weights`, so on a rig carrying both kinds of hand edit they agree to
// the vertex. On the shipped humanoid.
module crig_tests::weight_funnel;

import crig;
import rig;
import gltf;
import std::core::test;
import std::collections::object;
import std::encoding::json;
import std::io::file;
import std::math;

const String FUNNEL_COPY = "build/weight-funnel-humanoid.glb";

struct FunnelFixture
{
	crig::AppState app;
	rig::TriMesh mesh;
}

fn void FunnelFixture.open(&self)
{
	char[] original = file::load(mem, "assets/animations/humanoid.glb")!!;
	defer alloc::free(mem, original);
	file::save(FUNNEL_COPY, original)!!;
	self.mesh = rig::load_gltf(mem, FUNNEL_COPY)!!;
	self.app = crig::new_app(self.mesh, FUNNEL_COPY);
	test::@check(self.app.import_rig_from_source(), "the humanoid rig must import");
	// The rig wears crig's own bind, so there is a binder answer to edit.
	(void)self.app.release_all_recorded();
}

fn void FunnelFixture.close(&self)
{
	self.app.free();
	self.mesh.free(mem);
	(void)file::delete(FUNNEL_COPY);
	String sidecar = crig::session_path(mem, FUNNEL_COPY);
	defer sidecar.free(mem);
	(void)file::delete(sidecar);
}

fn uint funnel_dot(crig::AppState* app, String name)
{
	foreach (dot : app.doc.dots.array_view())
	{
		if (dot.name == name) return dot.id;
	}
	return 0;
}

<*
 Both edit layers on: an Apply that pins the knee's own part, and a multiplier
 dab elsewhere, so the edited weights differ from the automatic ones and a
 reader that skipped a layer would show it.
*>
fn void FunnelFixture.edit(&self)
{
	crig::AppState* app = &self.app;
	uint knee = funnel_dot(app, "knee_L");
	test::@check(knee != 0, "the humanoid has no knee_L");
	bool[] part = app.area_part_mask(mem, knee, OWN);
	defer alloc::free(mem, part);
	test::@check(app.apply_area(knee, part, app.area_scale(knee) * 0.25f) > 0, "the knee's part wrote nothing");

	// And a multiplier, the layer sessions from before stated rows carry, on a
	// vertex the knee's part did not pin.
	uint thigh = funnel_dot(app, "thigh_L");
	uint shin = 0;
	foreach (v, on : part)
	{
		if (on) continue;
		shin = (uint)v;
		break;
	}
	test::@check(app.doc.set_paint(shin, thigh, 0.3f), "the multiplier did not take");
	test::@check(app.doc.pins.len() > 0 && app.doc.paint.len() > 0, "the fixture carries no hand edits");
}

fn void every_reader_counts_the_same_owners() @test
{
	FunnelFixture f;
	f.open();
	defer f.close();
	f.edit();
	crig::AppState* app = &f.app;

	crig::RigView view = app.open_rig(mem)!!;
	defer view.free(mem);
	usz bones = view.len();
	usz count = app.geometry.positions.len;
	float[] shown = app.weights(mem, &view);
	defer alloc::free(mem, shown);
	test::@check(shown.len == count * bones, "the funnel answered nothing");

	usz[] owns = alloc::new_array(mem, usz, (sz)bones);
	defer alloc::free(mem, owns);
	for (usz v = 0; v < count; v++)
	{
		float sum;
		sz owner = crig::row_owner(shown[v * bones:bones], &sum);
		if (owner >= 0 && sum > 0.0f) owns[(usz)owner]++;
	}

	crig::WeightSurvey survey = app.survey_weights(mem)!!;
	defer survey.free(mem);
	usz apart = 0;
	foreach (j, stake : survey.stakes) if (stake.owns != owns[j]) apart++;
	test::@check(apart == 0, "the survey counts %d joints' ownership differently from the bind", apart);

	// The territory view colours each vertex by the same owner.
	app.show_tint(TERRITORY);
	app.rebind_tints();
	usz miscoloured = 0;
	for (usz v = 0; v < count; v++)
	{
		usz owner = crig::strongest_joint(shown[v * bones:bones]);
		if (app.tints[v] != crig::joint_tint(owner)) miscoloured++;
	}
	test::@check(miscoloured == 0, "the territory view colours %d vertices by another bind", miscoloured);
}

fn void the_falloff_view_and_the_skin_draw_the_funnel() @test
{
	FunnelFixture f;
	f.open();
	defer f.close();
	f.edit();
	crig::AppState* app = &f.app;

	uint knee = funnel_dot(app, "knee_L");
	crig::RigView view = app.open_rig(mem)!!;
	defer view.free(mem);
	usz bones = view.len();
	usz count = app.geometry.positions.len;
	usz joint = (usz)view.joint_of(knee);
	float[] shown = app.weights(mem, &view);
	defer alloc::free(mem, shown);

	app.select(knee);
	app.show_tint(FALLOFF);
	app.rebind_tints();
	usz off = 0;
	for (usz v = 0; v < count; v++)
	{
		if (app.tints[v] != crig::share_tint(crig::joint_share(shown[v * bones:bones], joint))) off++;
	}
	test::@check(off == 0, "the falloff view shades %d vertices from another bind", off);

	// The posed skin is the same bind cut to four influences — nothing else.
	app.skin_stale = true;
	test::@check(app.rebind_skin(&view), "the skin did not bind");
	gltf::SkinBinding cut = gltf::sparsify_weights(mem, shown, count, bones, crig::SKIN_INFLUENCES)!!;
	defer cut.free(mem);
	test::@check(cut.joints == app.skin.joints, "the skin rides different joints from the funnel's bind");
	usz drifted = 0;
	foreach (i, weight : cut.weights) if (math::abs(weight - app.skin.weights[i]) > 1.0e-6f) drifted++;
	test::@check(drifted == 0, "%d skin weights differ from the funnel's bind", drifted);
}

fn void get_weights_rows_read_the_funnel() @test
{
	FunnelFixture f;
	f.open();
	defer f.close();
	f.edit();
	crig::AppState* app = &f.app;

	crig::RigView view = app.open_rig(mem)!!;
	defer view.free(mem);
	usz bones = view.len();
	float[] shown = app.weights(mem, &view);
	defer alloc::free(mem, shown);

	// The edited vertices and a few untouched ones.
	uint[6] rows;
	usz picked = 0;
	foreach (pin : app.doc.pins.array_view())
	{
		if (picked >= 3) break;
		if (picked > 0 && rows[picked - 1] == pin.vertex) continue;
		rows[picked++] = pin.vertex;
	}
	rows[picked++] = 0;
	rows[picked++] = (uint)(app.geometry.positions.len / 2);
	rows[picked++] = (uint)(app.geometry.positions.len - 1);

	String answer = crig::weights_json(app, 0, null, rows[:picked])!!;
	defer answer.free(mem);
	Object* parsed = json::parse(mem, answer)!!;
	defer parsed.free();
	Object* listed = parsed.get("rows")!!;
	test::@check((usz)listed.get_len() == picked, "%d rows for %d vertices", listed.get_len(), picked);

	for (sz i = 0; i < listed.get_len(); i++)
	{
		Object* row = listed.get_at(i);
		usz v = (usz)row.get_int("vertex")!!;
		float[] mine = shown[v * bones:bones];
		float sum = 0.0f;
		foreach (w : mine) sum += w;
		Object* joints = row.get("joints")!!;
		for (sz k = 0; k < joints.get_len(); k++)
		{
			Object* held = joints.get_at(k);
			uint dot = funnel_dot(app, held.get_string("name")!!);
			float want = mine[(usz)view.joint_of(dot)] / sum;
			test::@check(math::abs((float)held.get_float("share")!! - want) < 1.0e-3f,
				"vertex %d: get_weights says %s holds %f, the bind %f", v, held.get_string("name")!!,
				held.get_float("share")!!, want);
		}
	}
}

<*
 The falloff view with nothing selected shows nobody's weight. It used to fall
 back to joint 0 and paint the root's weights under a label naming nobody.
*>
fn void the_falloff_view_with_no_joint_is_grey() @test
{
	FunnelFixture f;
	f.open();
	defer f.close();
	crig::AppState* app = &f.app;

	app.select(funnel_dot(app, "knee_L"));
	app.show_tint(FALLOFF);
	app.select(0);
	app.rebind_tints();
	usz coloured = 0;
	foreach (tint : app.tints) if (tint != crig::share_tint(0.0f)) coloured++;
	test::@check(coloured == 0, "with no joint selected the falloff view still colours %d vertices", coloured);
}
