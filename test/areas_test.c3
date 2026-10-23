// Joint areas on the shipped humanoid (a temp copy): which vertices a part takes,
// what Apply writes — the joint's column and no other — and that it undoes,
// resets and survives the session.
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
	float[] painted = app.weights(mem, &view);
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
	float[] painted = app.weights(mem, &view);
	defer alloc::free(mem, painted);
	uint[] out = alloc::new_array(mem, uint, (sz)count);
	for (usz v = 0; v < count; v++)
	{
		sz best = crig::row_owner(painted[v * bones:bones]);
		out[v] = best >= 0 ? view.dot_ids[(usz)best] : 0;
	}
	return out;
}

// One joint's own weight on every vertex, as the views show it.
fn float[] weights_of(crig::AppState* app, uint dot_id)
{
	crig::RigView view = app.open_rig(mem)!!;
	defer view.free(mem);
	return app.column_of(mem, &view, dot_id);
}

// The whole matrix as the views show it, unnormalised; `bones` weights to a vertex.
fn float[] shown_matrix(crig::AppState* app, usz* bones)
{
	crig::RigView view = app.open_rig(mem)!!;
	defer view.free(mem);
	*bones = view.len();
	return app.weights(mem, &view);
}

// The automatic weights every unheld joint follows; `bones` weights to a vertex.
fn float[] automatic_matrix(crig::AppState* app, usz* bones)
{
	crig::RigView view = app.open_rig(mem)!!;
	defer view.free(mem);
	*bones = view.len();
	return app.weights(mem, &view, AUTOMATIC);
}

fn usz joint_index(crig::AppState* app, uint dot_id)
{
	crig::RigView view = app.open_rig(mem)!!;
	defer view.free(mem);
	return (usz)view.joint_of(dot_id);
}

// How many entries of every column but `except` (joint indices, -1 for none)
// differ between two matrices, bit for bit.
fn usz others_moved(float[] before, float[] after, usz bones, sz except, sz also = -1)
{
	if (before.len != after.len) return (usz)math::max(before.len, after.len);
	usz moved = 0;
	foreach (usz i, w : before)
	{
		sz j = (sz)(i % bones);
		if (j == except || j == also) continue;
		if (w != after[i]) moved++;
	}
	return moved;
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
 is one shell, and once applied the head holds all of its own weight there.
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

	// A whole piece: one shell, taken whole, and the head's whole weight once applied.
	sz seed = -1;
	foreach (v, on : own) if (on) { seed = (sz)v; break; }
	bool[] piece = app.area_part_mask(mem, head, PIECE, seed);
	defer alloc::free(mem, piece);
	int shell = app.shells.of[(usz)seed];
	foreach (v, on : piece) test::@check(on == (app.shells.of[v] == shell), "vertex %d: piece is not one shell", v);

	test::@check(app.apply_area(head, piece, app.area_scale(head)) > 0, "applying the piece wrote nothing");
	float[] weights = weights_of(&app, head);
	defer alloc::free(mem, weights);
	foreach (v, on : piece)
	{
		if (!on) continue;
		test::@check(weights[v] == 1.0f, "vertex %d of the piece holds %f of the head's weight, not all of it", v, weights[v]);
	}
}

<*
 Soft 0 writes only full weights, and nothing outside the part keeps the joint;
 a soft edge writes a band that falls monotonically over the surface to the
 edge. No other joint's weight moves, the joint is held, applying is one undo
 step, and Reset puts the automatic weights back in one more.

 *Re-introduce:* restate the rows outside the part without the joint, and the
 neighbours' columns change.
*>
fn void applying_a_part_writes_its_band_and_undoes_in_one_step() @test
{
	io::printn("apply writes a rigid or banded column in one undo step, and reset restores");
	copy_fixture(AREA_COPY);
	defer remove_fixture(AREA_COPY);

	rig::TriMesh mesh = rig::load_gltf(mem, AREA_COPY)!!;
	defer mesh.free(mem);
	crig::AppState app = crig::new_app(mesh, AREA_COPY);
	defer app.free();
	test::@check(app.import_rig_from_source(), "the humanoid rig must import");
	// From the automatic weights: the import holds every joint with the file's.
	(void)app.release_all_recorded();
	app.undo_stack.clear();

	uint head = named(&app, "head");
	usz bones;
	float[] before = shown_matrix(&app, &bones);
	defer alloc::free(mem, before);
	usz h = joint_index(&app, head);
	test::eq(app.doc.pins.len(), (sz)0);

	bool[] family = app.area_part_mask(mem, head, WITH_CHILDREN);
	defer alloc::free(mem, family);

	// --- soft 0: full weights only, and nothing outside -----------------------
	test::@check(app.apply_area(head, family, 0) > 0, "a rigid apply wrote nothing");
	test::@check(app.weights_held(head), "the head's weights are not its own after an Apply");
	foreach (pin : app.doc.pins.array_view())
	{
		test::@check(pin.dot_id == head, "an Apply on the head wrote another joint's weights");
		test::@check(family[pin.vertex], "a head weight landed outside the part");
		test::@check(pin.share == 1.0f, "a rigid part wrote %f", pin.share);
	}
	float[] rigid = shown_matrix(&app, &bones);
	defer alloc::free(mem, rigid);
	foreach (usz v, on : family)
	{
		float w = rigid[v * bones + h];
		test::@check(on ? w == 1.0f : w == 0.0f, "vertex %d holds %f of the head", v, w);
	}
	test::eq(others_moved(before, rigid, bones, (sz)h), (usz)0);

	// One step back to the automatic weights.
	test::@check(app.undo(), "the apply left nothing to undo");
	test::eq(app.doc.pins.len(), (sz)0);
	test::@check(!app.weights_held(head), "undoing the apply left the head held");
	test::@check(!app.undo(), "the apply took more than one undo step");

	// --- soft: a band half the head's bone deep, falling to the edge ---------
	float soft = app.area_scale(head) * 0.5f;
	test::@check(app.apply_area(head, family, soft) > 0, "a soft apply wrote nothing");
	float[] banded = weights_of(&app, head);
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
		test::@check(s > 0.0f && s <= 1.0f, "part vertex %d holds %f", v, s);
		if (s >= 1.0f) whole++;
		by_class[(usz)around.class_of[v]] = s;
		at[(usz)around.class_of[v]] = app.geometry.positions[v];
	}
	test::@check(whole > 0, "nothing deeper than the soft edge holds the whole weight");

	// Monotone over the surface: across an edge of the mesh the weight changes by
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

	// --- reset: back to the automatic weights, in one step --------------------
	test::@check(app.release_recorded(head), "reset changed nothing");
	app.undo_stack.commit();
	test::eq(app.doc.pins.len(), (sz)0);
	float[] after = shown_matrix(&app, &bones);
	defer alloc::free(mem, after);
	test::eq(others_moved(before, after, bones, -1), (usz)0);
	test::@check(app.undo(), "reset left nothing to undo");
	test::@check(app.doc.pins.len() > 0 && app.weights_held(head), "undoing the reset did not bring the part back");
	float[] undone = weights_of(&app, head);
	defer alloc::free(mem, undone);
	usz off = 0;
	foreach (v, w : undone) if (w != banded[v]) off++;
	test::@check(off == 0, "one undo of the reset left %d of the band's weights off", off);
}

<*
 The mirrored part lands on the twin in the same undo step, and both columns
 and the held flags survive a save and a reload.
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
	// From the automatic weights: the import holds every joint with the file's.
	(void)app.release_all_recorded();
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
	test::@check(!app.weights_held(wrist) && !app.weights_held(twin), "the undo left a wrist held");
	test::@check(app.redo(), "the mirrored apply did not redo");
	test::@check(app.weights_held(wrist) && app.weights_held(twin), "the redo did not hold both wrists");

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
	test::@check(reopened.weights_held(wrist) && reopened.weights_held(twin), "the held flags did not survive the session");
	usz matched = 0;
	foreach (pin : saved)
	{
		foreach (back : reopened.doc.pins.array_view())
		{
			if (back.vertex != pin.vertex || back.dot_id != pin.dot_id) continue;
			if (back.share == pin.share) matched++;
			break;
		}
	}
	test::eq(matched, (usz)saved.len);
}

<*
 A session from before version 32 opens looking as it was saved: its pins were
 whole rows over one automatic bind, and the joints whose columns those rows
 changed — the one pinned, and a neighbour the row took off — come back held
 with the columns it showed, while every other joint follows the automatic
 weights.

 *Re-introduce:* load the pins as they are, as columns, and the vertex's other
 joints come back beside the pinned one.
*>
fn void an_older_session_opens_with_the_weights_it_showed() @test
{
	io::printn("an older session opens with the weights it showed");
	copy_fixture(AREA_COPY);
	defer remove_fixture(AREA_COPY);

	rig::TriMesh mesh = rig::load_gltf(mem, AREA_COPY)!!;
	defer mesh.free(mem);
	crig::AppState app = crig::new_app(mesh, AREA_COPY);
	defer app.free();
	test::@check(app.import_rig_from_source(), "the humanoid rig must import");
	(void)app.release_all_recorded();
	app.mark_rig_stale();

	// A vertex the neck holds, pinned whole to the head as a version 31 binary
	// wrote it: a four-number pin with its author, and no held flags.
	uint head = named(&app, "head");
	uint neck = app.parent_dot(head);
	uint[] owners = owners_of(&app);
	defer alloc::free(mem, owners);
	sz picked = -1;
	foreach (v, owner : owners) if (owner == neck) { picked = (sz)v; break; }
	test::@check(picked >= 0, "the neck owns nothing");
	String text = crig::session_text(mem, &app.doc, AREA_COPY);
	defer text.free(mem);
	String pins = string::format(mem, `, "pins": [[%d,%d,%s,%d]]`, picked, head, (crig::JsonFloat)1.0f, head);
	defer pins.free(mem);
	String closing = string::format(mem, `"attachments": []%s`, pins);
	defer closing.free(mem);
	String older = text.replace(mem, `"attachments": []`, closing);
	defer older.free(mem);
	String versioned = older.replace(mem, `"version": 33`, `"version": 31`);
	defer versioned.free(mem);
	test::@check(versioned.contains(`"pins"`) && versioned.contains(`"version": 31`), "the older session was not written: %s", versioned);
	String sidecar = crig::session_path(mem, AREA_COPY);
	defer sidecar.free(mem);
	file::save(sidecar, versioned)!!;

	app.load_session();
	test::@check(app.weights_held(head), "the pinned head was not held");
	test::@check(app.weights_held(neck), "the neck the pin took off was not held");
	usz bones;
	float[] shown = shown_matrix(&app, &bones);
	defer alloc::free(mem, shown);
	usz at = (usz)picked * bones;
	float total = 0.0f;
	for (usz b = 0; b < bones; b++) total += shown[at + b];
	test::@check(math::abs(shown[at + joint_index(&app, head)] / total - 1.0f) < 1.0e-5f,
		"the pinned vertex is not the head's alone after the load");
}

<*
 A session before version 32 that wore the model file's own weights opens
 wearing them still: every joint the file's columns cover differently from the
 binder comes back held with the file's column.

 *Re-introduce:* skip reading the file's skin before the migration, and the rig
 opens on the binder's weights.
*>
fn void an_older_session_on_the_files_weights_keeps_them() @test
{
	io::printn("an older session on the file's own weights keeps them");
	copy_fixture(AREA_COPY);
	defer remove_fixture(AREA_COPY);

	rig::TriMesh mesh = rig::load_gltf(mem, AREA_COPY)!!;
	defer mesh.free(mem);
	crig::AppState app = crig::new_app(mesh, AREA_COPY);
	defer app.free();
	test::@check(app.import_rig_from_source(), "the humanoid rig must import");
	usz bones;
	float[] file_weights = shown_matrix(&app, &bones);
	defer alloc::free(mem, file_weights);

	// As a version 31 binary wrote it: the flag, and no columns.
	(void)app.release_all_recorded();
	String text = crig::session_text(mem, &app.doc, AREA_COPY);
	defer text.free(mem);
	String flagged = text.replace(mem, `  "dots": [`, `  "skin_from_file": true,
  "dots": [`);
	defer flagged.free(mem);
	String versioned = flagged.replace(mem, `"version": 33`, `"version": 31`);
	defer versioned.free(mem);
	test::@check(versioned.contains(`"skin_from_file"`), "the older session was not written");
	String sidecar = crig::session_path(mem, AREA_COPY);
	defer sidecar.free(mem);
	file::save(sidecar, versioned)!!;

	app.load_session();
	test::@check(app.weights_edited(), "no joint kept the file's weights");
	test::@check(!app.doc.legacy_skin_from_file, "the older session's flag outlived its migration");
	float[] shown = shown_matrix(&app, &bones);
	defer alloc::free(mem, shown);
	usz off = 0;
	foreach (usz i, w : shown) if (math::abs(w - file_weights[i]) > 1.0e-5f) off++;
	test::@check(off == 0, "%d weights differ from the file's after the migration", off);
}

<*
 Applying a joint's part leaves every other joint's weights exactly as they
 were — a finger corrected, the next joint applied, and the first finger's
 column bit for bit the same.

 *Re-introduce:* share the rest of each soft-edge vertex out among the other
 joints, as Apply did, and the first finger's column moves.
*>
fn void applying_a_joint_leaves_every_other_joint_alone() @test
{
	io::printn("applying a joint leaves every other joint's weights alone");
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
	bool[] first_part = app.area_part_mask(mem, first, OWN);
	defer alloc::free(mem, first_part);
	test::@check(app.apply_area(first, first_part, app.area_scale(first) * 0.25f) > 0,
		"the first joint's part wrote nothing");

	usz bones;
	float[] before = shown_matrix(&app, &bones);
	defer alloc::free(mem, before);
	bool[] second_part = app.area_part_mask(mem, second, OWN);
	defer alloc::free(mem, second_part);
	test::@check(app.apply_area(second, second_part, app.area_scale(second) * 0.25f) > 0,
		"the second joint's part wrote nothing");
	float[] after = shown_matrix(&app, &bones);
	defer alloc::free(mem, after);
	test::eq(others_moved(before, after, bones, (sz)joint_index(&app, second)), (usz)0);
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

<*
 Reset lets one joint go and touches nobody else: two finger joints applied,
 the second reset, and the first's column bit for bit what it was, while the
 second follows the automatic weights again — exactly, on the binder's weights
 as on the file's.

 *Re-introduce:* rebuild the reset rows from the automatic weights for every
 joint on them, as Reset did, and the first finger's column moves.
*>
fn void resetting_a_joint_lets_it_go_and_spares_its_neighbours() @test
{
	io::printn("resetting a joint lets it go and spares its neighbours");
	copy_fixture(AREA_COPY);
	defer remove_fixture(AREA_COPY);

	rig::TriMesh mesh = rig::load_gltf(mem, AREA_COPY)!!;
	defer mesh.free(mem);
	crig::AppState app = crig::new_app(mesh, AREA_COPY);
	defer app.free();
	test::@check(app.import_rig_from_source(), "the humanoid rig must import");

	foreach (from_file : (bool[]){ true, false })
	{
		(void)app.release_all_recorded();
		if (from_file) app.adopt_model_weights();
		app.undo_stack.commit();
		app.mark_rig_stale();

		uint first = named(&app, "index_1_L");
		uint second = named(&app, "index_2_L");
		test::@check(first != 0 && second != 0, "the humanoid has no index finger");
		usz bones;
		float[] automatic = automatic_matrix(&app, &bones);
		defer alloc::free(mem, automatic);
		usz b = joint_index(&app, second);

		bool[] first_part = app.area_part_mask(mem, first, OWN);
		defer alloc::free(mem, first_part);
		test::@check(app.apply_area(first, first_part, app.area_scale(first) * 0.25f) > 0, "the first joint's part wrote nothing");
		bool[] second_part = app.area_part_mask(mem, second, OWN);
		defer alloc::free(mem, second_part);
		test::@check(app.apply_area(second, second_part, app.area_scale(second) * 0.25f) > 0, "the second joint's part wrote nothing");

		float[] before = shown_matrix(&app, &bones);
		defer alloc::free(mem, before);
		test::@check(app.release_recorded(second), "the reset changed nothing");
		app.undo_stack.commit();
		test::@check(!app.weights_held(second) && app.weights_held(first), "the reset let go of the wrong joint");

		float[] after = shown_matrix(&app, &bones);
		defer alloc::free(mem, after);
		test::eq(others_moved(before, after, bones, (sz)b), (usz)0);
		usz off = 0;
		for (usz v = 0; v < app.geometry.positions.len; v++)
		{
			if (after[v * bones + b] != automatic[v * bones + b]) off++;
		}
		test::@check(off == 0, "%d vertices of the reset joint are not its automatic weights", off);
	}
}

<*
 A second Reset of the same joint finds nothing to let go of and records
 nothing; the card says the joint already uses automatic weights.
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
	// From the automatic weights: the import holds every joint with the file's.
	(void)app.release_all_recorded();

	uint finger = named(&app, "index_2_L");
	bool[] part = app.area_part_mask(mem, finger, OWN);
	defer alloc::free(mem, part);
	test::@check(app.apply_area(finger, part, app.area_scale(finger) * 0.25f) > 0, "the apply wrote nothing");

	app.select(finger);
	test::eq(app.reset_joint_area(), (usz)1);
	usz revision = (usz)app.undo_stack.edits.len();
	test::eq(app.reset_joint_area(), (usz)0);
	test::eq((usz)app.undo_stack.edits.len(), revision);
	test::@check(app.notice().contains("already uses automatic weights"), "the second reset said: %s", app.notice());
}
