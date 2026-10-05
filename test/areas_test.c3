// Joint areas on the shipped humanoid (a temp copy): which vertices a part takes,
// what Apply writes, and that it undoes, resets and survives the session.
module crig_tests::areas;

import crig;
import rig;
import std::core::test;
import std::io;
import std::io::file;
import std::math;

const String AREA_COPY = "build/areas-humanoid.glb";

fn void copy_fixture(String path)
{
	char[] original = file::load(mem, "assets/animations/humanoid.glb")!!;
	defer alloc::free(mem, original);
	file::save(path, original)!!;
}

fn void remove_fixture(String path)
{
	(void)file::delete(path);
	String sidecar = crig::session_path(mem, path);
	defer sidecar.free(mem);
	(void)file::delete(sidecar);
	String copy = crig::copy_path(mem, path);
	defer copy.free(mem);
	(void)file::delete(copy);
	String copy_sidecar = crig::session_path(mem, copy);
	defer copy_sidecar.free(mem);
	(void)file::delete(copy_sidecar);
}

fn uint named(crig::AppState* app, String name)
{
	foreach (dot : app.doc.dots.array_view())
	{
		if (dot.name == name) return dot.id;
	}
	return 0;
}

// Each vertex's share of one joint in the bind as shown, normalised.
fn float[] shares_of(crig::AppState* app, uint dot_id)
{
	crig::RigView view = app.open_rig(mem)!!;
	defer view.free(mem);
	usz bones = view.len();
	usz count = app.geometry.positions.len;
	usz joint = (usz)view.joint_of(dot_id);
	float[] painted = app.painted_bind(mem, &view);
	defer alloc::free(mem, painted);
	float[] out = alloc::new_array(mem, float, (sz)count);
	for (usz v = 0; v < count; v++)
	{
		float sum = 0.0f;
		for (usz b = 0; b < bones; b++) sum += painted[v * bones + b];
		out[v] = sum > 0.0f ? painted[v * bones + joint] / sum : 0.0f;
	}
	return out;
}

// Each vertex's strongest joint, as a dot id.
fn uint[] owners_of(crig::AppState* app)
{
	crig::RigView view = app.open_rig(mem)!!;
	defer view.free(mem);
	usz bones = view.len();
	usz count = app.geometry.positions.len;
	float[] painted = app.painted_bind(mem, &view);
	defer alloc::free(mem, painted);
	uint[] out = alloc::new_array(mem, uint, (sz)count);
	for (usz v = 0; v < count; v++)
	{
		sz best = crig::row_owner(painted[v * bones:bones]);
		out[v] = best >= 0 ? view.dot_ids[(usz)best] : 0;
	}
	return out;
}

fn usz count_of(bool[] mask)
{
	usz n = 0;
	foreach (on : mask) if (on) n++;
	return n;
}

<*
 Own bone is exactly the vertices whose strongest joint is the head; With
 children is exactly those of the head and everything under it; a whole piece
 is one shell and comes back rigid.
*>
fn void a_part_takes_exactly_what_it_names() @test
{
	io::printn("own bone, with children and whole piece take exactly what they name");
	copy_fixture(AREA_COPY);
	defer remove_fixture(AREA_COPY);

	rig::TriMesh mesh = rig::load_gltf(mem, AREA_COPY)!!;
	defer mesh.free(mem);
	crig::AppState app = crig::new_app(mesh, AREA_COPY);
	defer app.free();
	test::@check(app.import_rig_from_source(), "the humanoid rig must import");

	uint head = named(&app, "head");
	uint head_top = named(&app, "head_top");
	test::@check(head != 0 && head_top != 0, "the humanoid has no head and head_top");

	uint[] owners = owners_of(&app);
	defer alloc::free(mem, owners);

	bool[] own = app.area_part_mask(mem, head, OWN);
	defer alloc::free(mem, own);
	bool[] family = app.area_part_mask(mem, head, WITH_CHILDREN);
	defer alloc::free(mem, family);
	test::eq(own.len, (sz)owners.len);
	test::eq(family.len, (sz)owners.len);

	usz own_count = 0;
	usz family_count = 0;
	usz top_count = 0;
	foreach (v, owner : owners)
	{
		test::@check(own[v] == (owner == head), "vertex %d: own part disagrees with the strongest joint", v);
		test::@check(family[v] == (owner == head || owner == head_top),
			"vertex %d: with-children disagrees with the head's subtree", v);
		if (own[v]) own_count++;
		if (family[v]) family_count++;
		if (owner == head_top) top_count++;
	}
	test::@check(own_count > 0, "the head owns nothing");
	test::eq(family_count, own_count + top_count);

	// The humanoid's head_top holds no skin of its own, so the subtree is shown
	// growing on the hand: the wrist with its fingers.
	uint wrist = named(&app, "wrist_L");
	bool[] palm = app.area_part_mask(mem, wrist, OWN);
	defer alloc::free(mem, palm);
	bool[] hand = app.area_part_mask(mem, wrist, WITH_CHILDREN);
	defer alloc::free(mem, hand);
	foreach (v, on : palm) test::@check(!on || hand[v], "vertex %d: the wrist's own part is not inside its hand", v);
	test::@check(count_of(hand) > count_of(palm) + 100, "the hand (%d) barely grew past the wrist (%d)",
		count_of(hand), count_of(palm));

	// A whole piece: one shell, taken whole, and rigid once applied.
	sz seed = -1;
	foreach (v, on : own) if (on) { seed = (sz)v; break; }
	bool[] piece = app.area_part_mask(mem, head, PIECE, seed);
	defer alloc::free(mem, piece);
	int shell = app.shells.of[(usz)seed];
	foreach (v, on : piece) test::@check(on == (app.shells.of[v] == shell), "vertex %d: piece is not one shell", v);

	test::@check(app.apply_area(head, piece, app.area_scale(head)) > 0, "applying the piece wrote nothing");
	float[] shares = shares_of(&app, head);
	defer alloc::free(mem, shares);
	foreach (v, on : piece)
	{
		if (!on) continue;
		test::@check(math::abs(shares[v] - 1.0f) < 1.0e-5f, "vertex %d of the piece holds %f of the head, not all of it", v, shares[v]);
	}
}

<*
 Soft 0 states only whole shares, and nothing outside the part keeps the joint;
 a soft edge states a band that falls monotonically over the surface to the edge.
 Applying is one undo step, and Reset to automatic puts the automatic rows back
 in one more.
*>
fn void applying_a_part_writes_its_band_and_undoes_in_one_step() @test
{
	io::printn("apply writes a rigid or banded part in one undo step, and reset restores");
	copy_fixture(AREA_COPY);
	defer remove_fixture(AREA_COPY);

	rig::TriMesh mesh = rig::load_gltf(mem, AREA_COPY)!!;
	defer mesh.free(mem);
	crig::AppState app = crig::new_app(mesh, AREA_COPY);
	defer app.free();
	test::@check(app.import_rig_from_source(), "the humanoid rig must import");
	app.undo_stack.clear();

	uint head = named(&app, "head");
	float[] before = shares_of(&app, head);
	defer alloc::free(mem, before);
	test::eq(app.doc.pins.len(), (sz)0);

	bool[] family = app.area_part_mask(mem, head, WITH_CHILDREN);
	defer alloc::free(mem, family);

	// --- soft 0: whole shares only, and nothing outside -----------------------
	test::@check(app.apply_area(head, family, 0) > 0, "a rigid apply wrote nothing");
	foreach (pin : app.doc.pins.array_view())
	{
		if (pin.dot_id != head) continue;
		test::@check(family[pin.vertex], "a head pin landed outside the part");
		test::@check(pin.share == 1.0f, "a rigid part stated %f", pin.share);
	}
	float[] rigid = shares_of(&app, head);
	defer alloc::free(mem, rigid);
	foreach (v, on : family)
	{
		if (on)
		{
			test::@check(math::abs(rigid[v] - 1.0f) < 1.0e-5f, "part vertex %d holds %f", v, rigid[v]);
		}
		else
		{
			test::@check(rigid[v] < crig::AREA_LEAK_FLOOR, "outside vertex %d still holds %f of the head", v, rigid[v]);
		}
	}

	// One step back to the automatic rows.
	test::@check(app.undo(), "the apply left nothing to undo");
	test::eq(app.doc.pins.len(), (sz)0);
	test::@check(!app.undo(), "the apply took more than one undo step");

	// --- soft: a band half the head's bone deep, falling to the edge ---------
	float soft = app.area_scale(head) * 0.5f;
	test::@check(app.apply_area(head, family, soft) > 0, "a soft apply wrote nothing");
	float[] banded = shares_of(&app, head);
	defer alloc::free(mem, banded);

	rig::MeshAdjacency* around = app.adjacency_for();
	float[] by_class = alloc::new_array(mem, float, (sz)around.classes());
	defer alloc::free(mem, by_class);
	Vec3[] at = alloc::new_array(mem, Vec3, (sz)around.classes());
	defer alloc::free(mem, at);
	by_class[..] = -1.0f;
	usz whole = 0;
	foreach (v, on : family)
	{
		if (!on) continue;
		float s = banded[v];
		test::@check(s > 0.0f && s <= 1.0f + 1.0e-5f, "part vertex %d holds %f", v, s);
		if (s >= 1.0f - 1.0e-5f) whole++;
		by_class[(usz)around.class_of[v]] = s;
		at[(usz)around.class_of[v]] = app.geometry.positions[v];
	}
	test::@check(whole > 0, "nothing deeper than the soft edge holds the whole share");

	// Monotone over the surface: across an edge of the mesh the share changes by
	// no more than that edge's length over the band, and an edge point of the part
	// holds no more than the walk to the outside allows.
	usz edges = 0;
	for (usz g = 0; g < by_class.len; g++)
	{
		if (by_class[g] < 0.0f) continue;
		bool edge = false;
		foreach (n : around.around(g))
		{
			float step = (at[n] - at[g]).length() / soft;
			if (by_class[n] < 0.0f)
			{
				edge = true;
				test::@check(by_class[g] <= step + 1.0e-3f, "an edge point holds %f, over the %f its edge allows", by_class[g], step);
				continue;
			}
			test::@check(math::abs(by_class[g] - by_class[n]) <= step + 1.0e-3f,
				"neighbours jump from %f to %f", by_class[g], by_class[n]);
		}
		if (edge) edges++;
	}
	test::@check(edges > 0, "the part has no edge to band");

	// --- reset: back to the automatic rows, in one step -----------------------
	usz revision = (usz)app.undo_stack.edits.len();
	test::@check(app.reset_area(head) > 0, "reset cleared nothing");
	test::eq(app.doc.pins.len(), (sz)0);
	float[] after = shares_of(&app, head);
	defer alloc::free(mem, after);
	foreach (v, s : after) test::@check(math::abs(s - before[v]) < 1.0e-5f, "vertex %d did not return to automatic", v);
	test::eq((usz)app.undo_stack.edits.len(), revision + 1);
	test::@check(app.undo(), "reset left nothing to undo");
	test::@check(app.doc.pins.len() > 0, "undoing the reset did not bring the part back");
}

<*
 The mirrored part lands on the twin in the same undo step, and a part survives
 a save and a reload.
*>
fn void a_part_mirrors_and_survives_the_session() @test
{
	io::printn("a part mirrors onto the twin and survives save and reload");
	copy_fixture(AREA_COPY);
	defer remove_fixture(AREA_COPY);

	rig::TriMesh mesh = rig::load_gltf(mem, AREA_COPY)!!;
	defer mesh.free(mem);
	crig::AppState app = crig::new_app(mesh, AREA_COPY);
	defer app.free();
	test::@check(app.import_rig_from_source(), "the humanoid rig must import");
	app.undo_stack.clear();

	uint wrist = named(&app, "wrist_L");
	uint twin = app.mirror_twin(wrist);
	test::@check(twin == named(&app, "wrist_R"), "wrist_L's twin is not wrist_R");

	bool[] hand = app.area_part_mask(mem, wrist, WITH_CHILDREN);
	defer alloc::free(mem, hand);
	bool[] other = app.area_twin_part(mem, twin, WITH_CHILDREN, hand, -1);
	defer alloc::free(mem, other);
	test::@check(count_of(other) > 0, "the twin's hand came back empty");

	usz held = app.apply_area(wrist, hand, app.area_scale(wrist) * 0.25f, twin, other);
	test::eq(held, count_of(hand) + count_of(other));
	usz left = 0;
	usz right = 0;
	foreach (pin : app.doc.pins.array_view())
	{
		if (pin.dot_id == wrist) left++;
		if (pin.dot_id == twin) right++;
	}
	test::eq(left, count_of(hand));
	test::eq(right, count_of(other));
	test::@check(app.undo(), "the mirrored apply left nothing to undo");
	test::eq(app.doc.pins.len(), (sz)0);
	test::@check(app.redo(), "the mirrored apply did not redo");

	crig::VertexPin[] saved = alloc::new_array(mem, crig::VertexPin, app.doc.pins.len());
	defer alloc::free(mem, saved);
	foreach (i, pin : app.doc.pins.array_view()) saved[i] = pin;

	app.save_session();
	String target = app.source_path.copy(mem);
	defer target.free(mem);

	rig::TriMesh reread = rig::load_gltf(mem, target)!!;
	defer reread.free(mem);
	crig::AppState reopened = crig::new_app(reread, target);
	defer reopened.free();
	reopened.load_session();
	test::eq(reopened.doc.pins.len(), (sz)saved.len);
	usz matched = 0;
	foreach (pin : saved)
	{
		foreach (back : reopened.doc.pins.array_view())
		{
			if (back.vertex != pin.vertex || back.dot_id != pin.dot_id) continue;
			if (math::abs(back.share - pin.share) < 1.0e-5f) matched++;
			break;
		}
	}
	test::eq(matched, (usz)saved.len);
}

<*
 Resetting one joint leaves the part a neighbour was given alone: only the
 joint's own pins, and the rows its Apply stated around itself, go.
*>
fn void resetting_a_joint_spares_its_neighbours() @test
{
	io::printn("reset to automatic touches only the joint it is for");
	copy_fixture(AREA_COPY);
	defer remove_fixture(AREA_COPY);

	rig::TriMesh mesh = rig::load_gltf(mem, AREA_COPY)!!;
	defer mesh.free(mem);
	crig::AppState app = crig::new_app(mesh, AREA_COPY);
	defer app.free();
	test::@check(app.import_rig_from_source(), "the humanoid rig must import");

	uint head = named(&app, "head");
	uint neck = head != 0 ? app.parent_dot(head) : 0;
	test::@check(head != 0 && neck != 0, "the humanoid has no head under a neck");

	float[] before = shares_of(&app, head);
	defer alloc::free(mem, before);

	bool[] neck_part = app.area_part_mask(mem, neck, WITH_CHILDREN);
	defer alloc::free(mem, neck_part);
	bool[] head_part = app.area_part_mask(mem, head, WITH_CHILDREN);
	defer alloc::free(mem, head_part);
	foreach (v, &on : neck_part) if (head_part[v]) *on = false;
	test::@check(app.apply_area(neck, neck_part, app.area_scale(neck) * 0.3f) > 0, "the neck's part wrote nothing");
	float[] neck_only = shares_of(&app, neck);
	defer alloc::free(mem, neck_only);
	test::@check(app.apply_area(head, head_part, app.area_scale(head) * 0.3f) > 0, "the head's part wrote nothing");

	float[] neck_held = shares_of(&app, neck);
	defer alloc::free(mem, neck_held);
	test::@check(app.reset_area(head) > 0, "reset cleared nothing");

	// Where the head still reached into the neck's soft edge, its Apply restated
	// the row without itself: that row is the head's now, and the reset may take
	// it back. Every row only the neck wrote must stay exactly as it was.
	float[] neck_after = shares_of(&app, neck);
	defer alloc::free(mem, neck_after);
	usz moved = 0;
	foreach (v, on : neck_part)
	{
		bool restated = math::abs(neck_held[v] - neck_only[v]) > 1.0e-4f;
		if (on && !restated && math::abs(neck_after[v] - neck_held[v]) > 1.0e-4f) moved++;
	}
	test::@check(moved == 0, "resetting the head changed %d vertices of the neck's part", moved);
	foreach (pin : app.doc.pins.array_view())
	{
		test::@check(pin.dot_id != head, "a head pin outlived the reset on vertex %d", pin.vertex);
	}
}
