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
			if (math::abs(back.share - pin.share) < 1.0e-5f && back.by == pin.by) matched++;
			break;
		}
	}
	test::eq(matched, (usz)saved.len);
}

<*
 Every row an Apply writes is that joint's work — the twin's part the twin's —
 and the authors come back through undo, redo and a save.
*>
fn void pin_authors_survive_save_undo_and_redo() @test
{
	io::printn("pin authors survive undo, redo and a save");
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
	bool[] hand = app.area_part_mask(mem, wrist, WITH_CHILDREN);
	defer alloc::free(mem, hand);
	bool[] other = app.area_twin_part(mem, twin, WITH_CHILDREN, hand, -1);
	defer alloc::free(mem, other);
	test::@check(app.apply_area(wrist, hand, app.area_scale(wrist) * 0.25f, twin, other) > 0, "the apply wrote nothing");

	foreach (pin : app.doc.pins.array_view())
	{
		test::@check(pin.by == wrist || pin.by == twin, "a pin on vertex %d is %d's work", pin.vertex, pin.by);
		if (hand[pin.vertex]) test::@check(pin.by == wrist, "the hand's vertex %d is not the wrist's", pin.vertex);
		if (other[pin.vertex]) test::@check(pin.by == twin, "the other hand's vertex %d is not the twin's", pin.vertex);
	}
	crig::VertexPin[] saved = alloc::new_array(mem, crig::VertexPin, app.doc.pins.len());
	defer alloc::free(mem, saved);
	foreach (i, pin : app.doc.pins.array_view()) saved[i] = pin;

	// The same shares stated by another joint are a change of author, and undo
	// gives the row back to the first.
	uint thumb = named(&app, "thumb_1_L");
	crig::VertexPin taken = saved[0];
	crig::VertexPin[1] restated = { { .vertex = taken.vertex, .dot_id = taken.dot_id, .share = taken.share, .by = thumb } };
	test::eq(app.pin_dabs(restated[..]), (usz)1);
	test::eq(app.doc.pins[0].by, thumb);
	test::@check(app.undo(), "the change of author left nothing to undo");
	test::eq(app.doc.pins[0].by, taken.by);
	test::@check(app.undo() && app.redo(), "the apply did not undo and redo");
	test::eq(app.doc.pins.len(), (sz)saved.len);
	usz same = 0;
	foreach (pin : saved)
	{
		foreach (back : app.doc.pins.array_view())
		{
			if (back.vertex != pin.vertex || back.dot_id != pin.dot_id) continue;
			if (back.share == pin.share && back.by == pin.by) same++;
			break;
		}
	}
	test::eq(same, (usz)saved.len);
}

<*
 A session from before authors were kept reads its pins as nobody's work.
*>
fn void a_version_26_session_reads_its_pins_with_no_author() @test
{
	io::printn("a version 26 session reads its pins as nobody's");
	copy_fixture(AREA_COPY);
	defer remove_fixture(AREA_COPY);

	rig::TriMesh mesh = rig::load_gltf(mem, AREA_COPY)!!;
	defer mesh.free(mem);
	crig::AppState app = crig::new_app(mesh, AREA_COPY);
	defer app.free();
	test::@check(app.import_rig_from_source(), "the humanoid rig must import");

	uint head = named(&app, "head");
	test::@check(app.doc.set_pin(5, head, 1.0f, head), "the pin was refused");
	String text = crig::session_text(mem, &app.doc, AREA_COPY);
	defer text.free(mem);
	String four = string::format(mem, "[5,%d,%s,%d]", head, (crig::JsonFloat)1.0f, head);
	defer four.free(mem);
	String three = string::format(mem, "[5,%d,%s]", head, (crig::JsonFloat)1.0f);
	defer three.free(mem);
	test::@check(text.contains(four), "the pin was not written with its author: %s", four);

	String older = text.replace(mem, four, three);
	defer older.free(mem);
	String versioned = older.replace(mem, `"version": 30`, `"version": 26`);
	defer versioned.free(mem);
	crig::RigDocument doc = crig::parse_session(mem, versioned)!!;
	defer doc.free();
	test::eq(doc.pins.len(), (sz)1);
	test::eq(doc.pins[0].share, 1.0f);
	test::eq(doc.pins[0].by, (uint)0);
}

<*
 Resetting one joint leaves the part a neighbour was given alone: only the rows
 the joint's own Apply wrote change. The neck's Apply took the neck off the head,
 so the head's rows come back as that — the neck's work, without the neck —
 rather than as automatic rows that would hand the neck the head again.
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

	// The neck stays off the head, where its own Apply took it.
	usz returned = 0;
	foreach (v, on : head_part) if (on && !neck_part[v] && neck_after[v] >= crig::AREA_LEAK_FLOOR) returned++;
	test::@check(returned == 0, "the neck came back on %d vertices of the head", returned);

	// What is left of the head is the neck's work: the neck's own rows, and the
	// head's part as the neck's Apply left it, without the neck.
	usz count = app.geometry.positions.len;
	crig::VertexPin[] after;
	int[] after_at = rows_by_vertex(app.doc.pins.array_view(), count, &after);
	defer { alloc::free(mem, after_at); alloc::free(mem, after); }
	for (usz v = 0; v < count; v++)
	{
		crig::VertexPin[] row = after[after_at[v]:after_at[v + 1] - after_at[v]];
		if (row.len == 0) continue;
		test::@check(crig::row_author(row) == neck, "the row on vertex %d is %d's work, not the neck's", v, crig::row_author(row));
	}
}

// Every vertex's row as shown, normalised; `bones` weights to a vertex.
fn float[] shown_rows(crig::AppState* app, usz* bones)
{
	crig::RigView view = app.open_rig(mem)!!;
	defer view.free(mem);
	usz stride = view.len();
	*bones = stride;
	float[] rows = app.painted_bind(mem, &view);
	for (usz v = 0; v < app.geometry.positions.len; v++)
	{
		float sum = 0.0f;
		for (usz b = 0; b < stride; b++) sum += rows[v * stride + b];
		if (sum <= 0.0f) continue;
		for (usz b = 0; b < stride; b++) rows[v * stride + b] /= sum;
	}
	return rows;
}

fn usz joint_index(crig::AppState* app, uint dot_id)
{
	crig::RigView view = app.open_rig(mem)!!;
	defer view.free(mem);
	return (usz)view.joint_of(dot_id);
}

<*
 A joint's Apply keeps what an earlier Apply gave its neighbours: the soft edge
 shares the rest of each vertex among the other joints as they stand, not as the
 automatic weights had them. Finger by finger, the second joint's edge used to
 hand its vertices back to the automatic weights, and the first joint, taken off
 them by its own Apply, reached across again.

 *Re-introduce:* state the soft edge as the joint's share alone, as it was, and
 the first joint comes back outside its part.
*>
fn void applying_a_joint_keeps_what_its_neighbour_was_given() @test
{
	io::printn("applying a joint keeps what an earlier apply gave its neighbours");
	copy_fixture(AREA_COPY);
	defer remove_fixture(AREA_COPY);

	rig::TriMesh mesh = rig::load_gltf(mem, AREA_COPY)!!;
	defer mesh.free(mem);
	crig::AppState app = crig::new_app(mesh, AREA_COPY);
	defer app.free();
	test::@check(app.import_rig_from_source(), "the humanoid rig must import");

	uint first = named(&app, "index_2_L");
	uint second = named(&app, "index_1_L");
	test::@check(first != 0 && second != 0, "the humanoid has no index finger");

	float[] automatic = shares_of(&app, first);
	defer alloc::free(mem, automatic);
	bool[] first_part = app.area_part_mask(mem, first, OWN);
	defer alloc::free(mem, first_part);
	test::@check(app.apply_area(first, first_part, app.area_scale(first) * 0.25f) > 0,
		"the first joint's part wrote nothing");

	// The second part as it stands after the first Apply, which is what the card
	// picks when the next joint is selected.
	bool[] second_part = app.area_part_mask(mem, second, OWN);
	defer alloc::free(mem, second_part);
	usz contested = 0;
	foreach (usz v, on : second_part)
	{
		if (on && !first_part[v] && automatic[v] >= crig::AREA_LEAK_FLOOR) contested++;
	}
	test::@check(contested > 0, "the second part reaches no vertex the first joint was taken off");

	usz bones;
	float[] before = shown_rows(&app, &bones);
	defer alloc::free(mem, before);
	test::@check(app.apply_area(second, second_part, app.area_scale(second) * 0.25f) > 0,
		"the second joint's part wrote nothing");
	float[] after = shown_rows(&app, &bones);
	defer alloc::free(mem, after);
	usz a = joint_index(&app, first);
	usz b = joint_index(&app, second);

	// The first joint stays off everything outside its part.
	usz returned = 0;
	float most = 0.0f;
	foreach (usz v, on : first_part)
	{
		float held = after[v * bones + a];
		if (on || held < crig::AREA_LEAK_FLOOR) continue;
		returned++;
		most = math::max(most, held);
	}
	test::@check(returned == 0, "the first joint came back on %d vertices outside its part, holding up to %f",
		returned, most);

	// On the second part's soft edge the other joints share the rest as they did.
	usz edge = 0;
	usz drifted = 0;
	float worst = 0.0f;
	foreach (usz v, on : second_part)
	{
		if (!on) continue;
		usz at = v * bones;
		float was = before[at + b];
		float now = after[at + b];
		if (was <= 1.0e-3f || was >= 0.999f || now <= 1.0e-3f || now >= 0.999f) continue;
		edge++;
		float gap = 0.0f;
		for (usz j = 0; j < bones; j++)
		{
			if (j != b) gap = math::max(gap, math::abs(after[at + j] / (1.0f - now) - before[at + j] / (1.0f - was)));
		}
		if (gap <= 1.0e-3f) continue;
		drifted++;
		worst = math::max(worst, gap);
	}
	test::@check(edge > 0, "the second part has no soft edge to look at");
	test::@check(drifted == 0, "on %d of %d soft-edge vertices the other joints lost their proportions, by up to %f",
		drifted, edge, worst);
}

<*
 Applying the part a joint already moves changes nothing and records nothing, so
 the card can say so.
*>
fn void applying_the_same_part_twice_writes_nothing() @test
{
	io::printn("applying the same part twice writes nothing the second time");
	copy_fixture(AREA_COPY);
	defer remove_fixture(AREA_COPY);

	rig::TriMesh mesh = rig::load_gltf(mem, AREA_COPY)!!;
	defer mesh.free(mem);
	crig::AppState app = crig::new_app(mesh, AREA_COPY);
	defer app.free();
	test::@check(app.import_rig_from_source(), "the humanoid rig must import");

	uint finger = named(&app, "index_1_L");
	bool[] part = app.area_part_mask(mem, finger, OWN);
	defer alloc::free(mem, part);
	float soft = app.area_scale(finger) * 0.25f;
	test::@check(app.apply_area(finger, part, soft) > 0, "the first apply wrote nothing");
	usz revision = (usz)app.undo_stack.edits.len();
	test::eq(app.apply_area(finger, part, soft), (usz)0);
	test::eq((usz)app.undo_stack.edits.len(), revision);
}

// Each vertex's row, gathered: `start[v]` to `start[v + 1]` in `out`.
fn int[] rows_by_vertex(crig::VertexPin[] pins, usz count, crig::VertexPin[]* out)
{
	int[] start = alloc::new_array(mem, int, (sz)count + 1);
	foreach (pin : pins) if ((usz)pin.vertex < count) start[pin.vertex + 1]++;
	for (usz v = 0; v < count; v++) start[v + 1] += start[v];
	*out = alloc::new_array(mem, crig::VertexPin, (sz)start[count]);
	int[] fill = alloc::new_array(mem, int, (sz)count);
	defer alloc::free(mem, fill);
	fill[..] = start[:count];
	foreach (pin : pins) if ((usz)pin.vertex < count) (*out)[fill[pin.vertex]++] = pin;
	return start;
}

fn bool same_pins_on(crig::VertexPin[] a, crig::VertexPin[] b)
{
	if (a.len != b.len) return false;
	foreach (pin : a)
	{
		bool found = false;
		foreach (other : b) if (other.dot_id == pin.dot_id && other.share == pin.share && other.by == pin.by) found = true;
		if (!found) return false;
	}
	return true;
}

// Apply index_1_L's part and then index_2_L's, each with a soft edge, the way
// fingers are corrected one joint at a time.
fn void apply_two_finger_joints(crig::AppState* app, uint first, uint second, bool[] first_part)
{
	test::@check(app.apply_area(first, first_part, app.area_scale(first) * 0.25f) > 0, "the first joint's part wrote nothing");
	bool[] second_part = app.area_part_mask(mem, second, OWN);
	defer alloc::free(mem, second_part);
	test::@check(app.apply_area(second, second_part, app.area_scale(second) * 0.25f) > 0, "the second joint's part wrote nothing");
}

<*
 Reset takes back one joint's work and nothing a neighbour wrote. A finger
 corrected, the next one applied and then reset, on the file's own weights: the
 first joint stays off the second's segment, where its own Apply took it, and
 every row the first wrote is exactly as it was. (On the binder's weights a
 hand's rows go back to the knuckle bands — see the test after this one.)

 *Re-introduce:* clear the joint's whole rows to the automatic weights, as Reset
 did, and the first joint comes back on the second's segment.
*>
fn void resetting_a_joint_keeps_what_its_neighbours_were_given() @test
{
	io::printn("resetting a joint takes back its own work and nothing a neighbour wrote");
	copy_fixture(AREA_COPY);
	defer remove_fixture(AREA_COPY);

	rig::TriMesh mesh = rig::load_gltf(mem, AREA_COPY)!!;
	defer mesh.free(mem);
	crig::AppState app = crig::new_app(mesh, AREA_COPY);
	defer app.free();
	test::@check(app.import_rig_from_source(), "the humanoid rig must import");

	uint first = named(&app, "index_1_L");
	uint second = named(&app, "index_2_L");
	test::@check(first != 0 && second != 0, "the humanoid has no index finger");
	bool[] first_part = app.area_part_mask(mem, first, OWN);
	defer alloc::free(mem, first_part);
	apply_two_finger_joints(&app, first, second, first_part);

	usz count = app.geometry.positions.len;
	crig::VertexPin[] before;
	int[] before_at = rows_by_vertex(app.doc.pins.array_view(), count, &before);
	defer { alloc::free(mem, before_at); alloc::free(mem, before); }

	test::@check(app.reset_area(second) > 0, "the reset changed nothing");

	// The first joint stays off everything outside its part.
	float[] first_after = shares_of(&app, first);
	defer alloc::free(mem, first_after);
	usz returned = 0;
	float most = 0.0f;
	foreach (usz v, on : first_part)
	{
		if (on || first_after[v] < crig::AREA_LEAK_FLOOR) continue;
		returned++;
		most = math::max(most, first_after[v]);
	}
	test::@check(returned == 0, "the first joint came back on %d vertices outside its part, holding up to %f",
		returned, most);

	// Every row the second joint did not write is exactly as it was, and none of
	// its work is left.
	crig::VertexPin[] after;
	int[] after_at = rows_by_vertex(app.doc.pins.array_view(), count, &after);
	defer { alloc::free(mem, after_at); alloc::free(mem, after); }
	usz moved = 0;
	usz left = 0;
	for (usz v = 0; v < count; v++)
	{
		crig::VertexPin[] was = before[before_at[v]:before_at[v + 1] - before_at[v]];
		crig::VertexPin[] now = after[after_at[v]:after_at[v + 1] - after_at[v]];
		if (now.len > 0 && crig::row_author(now) == second) left++;
		if (was.len > 0 && crig::row_author(was) == second) continue;
		if (!same_pins_on(was, now)) moved++;
	}
	test::@check(moved == 0, "resetting the second joint changed %d rows it did not write", moved);
	test::@check(left == 0, "%d rows are still the second joint's work", left);
}

<*
 Resetting the wrist or a finger joint puts its rows of the hand back to the
 knuckle bands at the blend asked for now, whatever the bind was when it wrote
 them. A wrist and a finger applied with the widest blend, the blend set to a
 hard switch, and both reset: every row of the hand is the automatic row again.

 *Re-introduce:* take a hand's rows back by the others they state, as for any
 other joint, and about a hundred of them keep the wide blend they were written with.
*>
fn void resetting_a_hand_joint_gives_back_the_knuckle_blend() @test
{
	io::printn("resetting a hand joint gives back the knuckle blend asked for now");
	copy_fixture(AREA_COPY);
	defer remove_fixture(AREA_COPY);

	rig::TriMesh mesh = rig::load_gltf(mem, AREA_COPY)!!;
	defer mesh.free(mem);
	crig::AppState app = crig::new_app(mesh, AREA_COPY);
	defer app.free();
	test::@check(app.import_rig_from_source(), "the humanoid rig must import");
	app.doc.skin_from_file = false;
	app.doc.set_knuckle_blend(crig::knuckle_blend_stored(1.0f));
	app.mark_rig_stale();

	uint wrist = named(&app, "wrist_L");
	uint finger = named(&app, "index_2_L");
	test::@check(wrist != 0 && finger != 0, "the humanoid has no left hand");
	uint[2] joints = { wrist, finger };
	foreach (joint : joints)
	{
		bool[] part = app.area_part_mask(mem, joint, OWN);
		defer alloc::free(mem, part);
		test::@check(app.apply_area(joint, part, app.area_scale(joint) * 0.25f) > 0, "an apply wrote nothing");
	}

	app.doc.set_knuckle_blend(crig::knuckle_blend_stored(0.0f));
	app.mark_rig_stale();
	foreach (joint : joints) test::@check(app.reset_area(joint) > 0, "a reset changed nothing");

	usz bones;
	float[] shown = shown_rows(&app, &bones);
	defer alloc::free(mem, shown);
	crig::RigView view = app.open_rig(mem)!!;
	defer view.free(mem);
	float[] automatic = alloc::clone_slice(mem, app.base_bind_for(&view));
	defer alloc::free(mem, automatic);
	usz hand = 0;
	usz off = 0;
	float worst = 0.0f;
	for (usz v = 0; v < app.geometry.positions.len; v++)
	{
		float[] row = automatic[v * bones:bones];
		sz owner = crig::row_owner(row);
		if (owner < 0) continue;
		Dot* dot = app.doc.find(view.dot_ids[(usz)owner]);
		if (!dot || !(dot.name == "wrist_L" || (dot.name.starts_with("index_") && dot.name.ends_with("_L")))) continue;
		hand++;
		float sum = 0.0f;
		foreach (weight : row) sum += weight;
		float gap = 0.0f;
		for (usz b = 0; b < bones; b++) gap = math::max(gap, math::abs(shown[v * bones + b] - row[b] / sum));
		if (gap <= 1.0e-4f) continue;
		off++;
		worst = math::max(worst, gap);
	}
	test::@check(hand > 0, "no vertex is the wrist's or the index finger's");
	test::@check(off == 0, "%d of %d rows of the hand are not the automatic row, by up to %f", off, hand, worst);
}

<*
 A second Reset of the same joint finds nothing of its work left, records
 nothing, and the card says the joint already uses automatic weights.
*>
fn void resetting_twice_writes_nothing() @test
{
	io::printn("resetting the same joint twice writes nothing the second time");
	copy_fixture(AREA_COPY);
	defer remove_fixture(AREA_COPY);

	rig::TriMesh mesh = rig::load_gltf(mem, AREA_COPY)!!;
	defer mesh.free(mem);
	crig::AppState app = crig::new_app(mesh, AREA_COPY);
	defer app.free();
	test::@check(app.import_rig_from_source(), "the humanoid rig must import");

	uint first = named(&app, "index_1_L");
	uint second = named(&app, "index_2_L");
	bool[] first_part = app.area_part_mask(mem, first, OWN);
	defer alloc::free(mem, first_part);
	apply_two_finger_joints(&app, first, second, first_part);

	test::@check(app.reset_area(second) > 0, "the first reset changed nothing");
	usz revision = (usz)app.undo_stack.edits.len();
	test::eq(app.reset_area(second), (usz)0);
	test::eq((usz)app.undo_stack.edits.len(), revision);
}

<*
 On the binder's own weights too — rows with more joints than a skin file keeps
 — a fresh Apply and a Reset leave no pin and the automatic shares exactly.
*>
fn void a_fresh_apply_resets_to_nothing_on_the_binders_weights() @test
{
	io::printn("a fresh apply resets to nothing on the binder's weights");
	copy_fixture(AREA_COPY);
	defer remove_fixture(AREA_COPY);

	rig::TriMesh mesh = rig::load_gltf(mem, AREA_COPY)!!;
	defer mesh.free(mem);
	crig::AppState app = crig::new_app(mesh, AREA_COPY);
	defer app.free();
	test::@check(app.import_rig_from_source(), "the humanoid rig must import");
	app.doc.skin_from_file = false;
	app.mark_rig_stale();

	uint finger = named(&app, "index_2_L");
	float[] before = shares_of(&app, finger);
	defer alloc::free(mem, before);
	bool[] part = app.area_part_mask(mem, finger, OWN);
	defer alloc::free(mem, part);
	test::@check(app.apply_area(finger, part, app.area_scale(finger) * 0.5f) > 0, "the apply wrote nothing");
	test::@check(app.reset_area(finger) > 0, "the reset changed nothing");
	test::eq(app.doc.pins.len(), (sz)0);
	float[] after = shares_of(&app, finger);
	defer alloc::free(mem, after);
	usz off = 0;
	foreach (v, s : after) if (math::abs(s - before[v]) >= 1.0e-5f) off++;
	test::@check(off == 0, "%d vertices did not return to automatic", off);
}
