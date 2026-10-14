// The paint limit on the shipped humanoid (a temp copy): the brush and Apply give a
// joint weight only on its own limb, take it off anywhere, and the weight view
// shows where the limit is.
module crig_tests::paint_limit;

import crig;
import rig;
import std::core::test;
import std::io;
import std::math;
import crig_tests::areas;

const String LIMIT_COPY = "build/paint-limit-humanoid.glb";

// Up to `most` vertices owned by `dot` in the bind as shown, ascending.
fn uint[] owned_by(crig::AppState* app, uint dot, usz most)
{
	uint[] owners = areas::owners_of(app);
	defer alloc::free(mem, owners);
	usz n = 0;
	foreach (owner : owners) if (owner == dot && n < most) n++;
	uint[] out = alloc::new_array(mem, uint, (sz)n);
	usz at = 0;
	foreach (v, owner : owners)
	{
		if (owner != dot || at == n) continue;
		out[at++] = (uint)v;
	}
	return out;
}

fn float[] full_pulls(usz n)
{
	float[] out = alloc::new_array(mem, float, (sz)n);
	out[..] = 1.0f;
	return out;
}

<*
 Every part the Weights card offers by name — Own bone and With children, for
 every joint — lies on that joint's limb, on the binder's weights and on the
 file's, so the limit never cuts into a part the card itself chose.

 Re-introduce: `limb_family` without the joint's descendants, and With children
 of the shoulder loses the hand.
*>
fn void every_part_the_card_offers_is_on_its_joints_limb() @test
{
	io::printn("every part the card offers is on its joint's limb");
	areas::copy_fixture(LIMIT_COPY);
	defer areas::remove_fixture(LIMIT_COPY);

	rig::TriMesh mesh = rig::load_gltf(mem, LIMIT_COPY)!!;
	defer mesh.free(mem);
	crig::AppState app = crig::new_app(mesh, LIMIT_COPY);
	defer app.free();
	test::@check(app.import_rig_from_source(), "the humanoid rig must import");

	foreach (from_file : (bool[]){ true, false })
	{
		app.doc.skin_from_file = from_file;
		app.mark_rig_stale();
		crig::RigView view = app.open_rig(mem)!!;
		defer view.free(mem);
		foreach (id : view.dot_ids)
		{
			bool[] limb = app.limb_mask(mem, &view, id);
			defer if (limb.len > 0) alloc::free(mem, limb);
			test::eq(limb.len, (sz)app.geometry.positions.len);
			foreach (part : (crig::AreaPart[]){ OWN, WITH_CHILDREN })
			{
				bool[] mask = app.area_part_mask(mem, id, part);
				defer if (mask.len > 0) alloc::free(mem, mask);
				usz off = 0;
				foreach (v, on : mask) if (on && !limb[v]) off++;
				test::@check(off == 0, "%s of %s has %d vertices off its limb (file weights %s)",
					part.label(), app.doc.find(id).name, off, from_file);
			}
		}
	}
}

<*
 A finger stroked over the foot gives it nothing there, and says so when the
 stroke ends; the same stroke on the finger's own hand paints, and taking the
 finger off a foot vertex that holds it is allowed.

 Re-introduce: drop the `on_limb` check in `brush_share`, and the foot takes
 the ring finger.
*>
fn void a_finger_is_never_painted_onto_the_foot() @test
{
	io::printn("a finger is never painted onto the foot");
	areas::copy_fixture(LIMIT_COPY);
	defer areas::remove_fixture(LIMIT_COPY);

	rig::TriMesh mesh = rig::load_gltf(mem, LIMIT_COPY)!!;
	defer mesh.free(mem);
	crig::AppState app = crig::new_app(mesh, LIMIT_COPY);
	defer app.free();
	test::@check(app.import_rig_from_source(), "the humanoid rig must import");
	app.doc.skin_from_file = false;
	app.mark_rig_stale();

	uint ring = areas::named(&app, "ring_1_L");
	uint ankle = areas::named(&app, "ankle_L");
	uint hand_joint = areas::named(&app, "ring_2_L");
	test::@check(ring != 0 && ankle != 0 && hand_joint != 0, "the humanoid has no ring finger or ankle");
	app.select(ring);

	uint[] foot = owned_by(&app, ankle, 40);
	defer alloc::free(mem, foot);
	test::@check(foot.len > 10, "the left ankle owns only %d vertices", foot.len);
	float[] pulls = full_pulls(foot.len);
	defer alloc::free(mem, pulls);

	sz pins_before = app.doc.pins.len();
	app.begin_stroke();
	test::eq(app.brush_share(ring, foot, 1.0f, pulls), (usz)0);
	test::@check(app.stroke_blocked, "a stroke off the limb was not noted");
	app.end_stroke();
	test::@check(app.notice().contains("only painted on its own limb"), "the stroke ended without saying why: %s", app.notice());
	test::eq(app.doc.pins.len(), pins_before);
	float[] shares = areas::shares_of(&app, ring);
	defer alloc::free(mem, shares);
	foreach (v : foot) test::@check(shares[v] < 1.0e-4f, "foot vertex %d took %f of the ring finger", v, shares[v]);

	// On its own hand the brush paints as before, and says nothing.
	uint[] finger = owned_by(&app, hand_joint, 10);
	defer alloc::free(mem, finger);
	test::@check(finger.len > 0, "ring_2_L owns nothing");
	app.begin_stroke();
	test::@check(app.brush_share(ring, finger, 1.0f, pulls[:finger.len]) > 0, "the finger's own segment took nothing");
	test::@check(!app.stroke_blocked, "a stroke on the hand was taken for one off it");
	app.end_stroke();

	// A foot vertex handed over on purpose (Lasso pin) is not limited, and the
	// brush can always take the finger off it again.
	app.pin_vertices(foot[:1], ring, 1.0f);
	float[] pinned = areas::shares_of(&app, ring);
	defer alloc::free(mem, pinned);
	test::@check(pinned[foot[0]] > 0.99f, "the lasso pin did not hand the vertex over: %f", pinned[foot[0]]);
	app.begin_stroke();
	test::@check(app.brush_share(ring, foot[:1], 0.0f, pulls[:1]) > 0, "the finger could not be taken off the foot");
	app.end_stroke();
	float[] taken = areas::shares_of(&app, ring);
	defer alloc::free(mem, taken);
	test::@check(taken[foot[0]] < 1.0e-4f, "taking off left %f", taken[foot[0]]);
}

<*
 A part reaching off the joint's limb applies only where it is on it: the foot
 is counted as left out and given nothing, and a part wholly off the limb
 writes nothing. What the joint already holds there stays its own on the next
 Apply, and a Whole piece or UV islands part is applied whole.

 Re-introduce: drop the `on_limb` check in `area_rows`, and the foot takes the
 ring finger on Apply; drop the held share from it, and a second Apply strips
 what the first one gave.
*>
fn void an_apply_stops_at_the_joints_limb() @test
{
	io::printn("an apply stops at the joint's limb");
	areas::copy_fixture(LIMIT_COPY);
	defer areas::remove_fixture(LIMIT_COPY);

	rig::TriMesh mesh = rig::load_gltf(mem, LIMIT_COPY)!!;
	defer mesh.free(mem);
	crig::AppState app = crig::new_app(mesh, LIMIT_COPY);
	defer app.free();
	test::@check(app.import_rig_from_source(), "the humanoid rig must import");
	app.doc.skin_from_file = false;
	app.mark_rig_stale();

	uint ring = areas::named(&app, "ring_1_L");
	uint ankle = areas::named(&app, "ankle_L");
	uint[] foot = owned_by(&app, ankle, 40);
	defer alloc::free(mem, foot);
	test::@check(foot.len > 10, "the left ankle owns only %d vertices", foot.len);
	float soft = app.area_scale(ring) * 0.25f;

	// Wholly off the limb: nothing is written.
	bool[] off = alloc::new_array(mem, bool, (sz)app.geometry.positions.len);
	defer alloc::free(mem, off);
	foreach (v : foot) off[v] = true;
	usz refused = 0;
	test::eq(app.apply_area(ring, off, soft, refused: &refused), (usz)0);
	test::eq(refused, (usz)foot.len);
	test::eq(app.doc.pins.len(), (sz)0);

	// The finger's own part with the foot added: the finger applies, the foot
	// is left out.
	bool[] part = app.area_part_mask(mem, ring, OWN);
	defer alloc::free(mem, part);
	usz own = areas::count_of(part);
	foreach (v : foot) part[v] = true;
	test::eq(app.apply_area(ring, part, soft, refused: &refused), own);
	test::eq(refused, (usz)foot.len);
	float[] shares = areas::shares_of(&app, ring);
	defer alloc::free(mem, shares);
	foreach (v : foot) test::@check(shares[v] < 1.0e-4f, "foot vertex %d holds %f of the ring finger after Apply", v, shares[v]);

	// Two foot vertices handed over on purpose (Lasso pin): the next Apply of a
	// part holding them keeps them the finger's rather than leaving them out.
	app.pin_vertices(foot[:2], ring, 1.0f);
	test::eq(app.apply_area(ring, part, 0.0f, refused: &refused), own + 2);
	test::eq(refused, (usz)foot.len - 2);
	float[] kept = areas::shares_of(&app, ring);
	defer alloc::free(mem, kept);
	foreach (v : foot[:2]) test::@check(kept[v] > 0.99f, "foot vertex %d the finger held went to %f", v, kept[v]);

	// A whole piece is the menu's choice, not the pointer's: applied whole.
	test::eq(app.apply_area(ring, off, 0.0f, pieces: true, refused: &refused), (usz)foot.len);
	test::eq(refused, (usz)0);
	float[] pieced = areas::shares_of(&app, ring);
	defer alloc::free(mem, pieced);
	foreach (v : foot) test::@check(pieced[v] > 0.99f, "foot vertex %d of a whole piece holds %f", v, pieced[v]);
}

<*
 While the brush is open on the falloff view, the mesh off the selected joint's
 limb is drawn in its own darker grey — except a vertex the joint still holds,
 which keeps its colour so it can be found and taken off — and the grey goes
 with the brush.

 Re-introduce: drop `overlay_limb_tints` from `rebind_tints`.
*>
fn void the_weight_view_greys_out_what_the_joint_cannot_take() @test
{
	io::printn("the weight view greys out what the joint cannot take");
	areas::copy_fixture(LIMIT_COPY);
	defer areas::remove_fixture(LIMIT_COPY);

	rig::TriMesh mesh = rig::load_gltf(mem, LIMIT_COPY)!!;
	defer mesh.free(mem);
	crig::AppState app = crig::new_app(mesh, LIMIT_COPY);
	defer app.free();
	test::@check(app.import_rig_from_source(), "the humanoid rig must import");
	app.doc.skin_from_file = false;
	app.mark_rig_stale();

	uint ring = areas::named(&app, "ring_1_L");
	uint ankle = areas::named(&app, "ankle_L");
	uint hand_joint = areas::named(&app, "ring_2_L");
	uint[] foot = owned_by(&app, ankle, 40);
	defer alloc::free(mem, foot);
	uint[] finger = owned_by(&app, hand_joint, 10);
	defer alloc::free(mem, finger);
	app.pin_vertices(foot[:1], ring, 1.0f);

	app.select(ring);
	test::@check(app.begin_brush(), "the brush would not open");
	app.rebind_tints();
	uint grey = crig::off_limb_tint();
	test::eq(app.tints.len, (sz)app.geometry.positions.len);
	test::@check(app.tints[foot[0]] != grey, "the stray hold on the foot was greyed out");
	foreach (v : foot[1..]) test::@check(app.tints[v] == grey, "foot vertex %d is not greyed out", v);
	foreach (v : finger) test::@check(app.tints[v] != grey, "finger vertex %d is greyed out", v);

	app.end_brush();
	app.show_tint(FALLOFF);
	app.rebind_tints();
	foreach (v : foot[1..]) test::@check(app.tints[v] != grey, "foot vertex %d stayed grey with the brush closed", v);
}
