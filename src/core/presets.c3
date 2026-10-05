<*
 Starting skeletons (M2): a body plan, fitted to whatever mesh is open.

 Every rig up to now began with an empty document and fifteen clicks placed by
 eye. A preset is those clicks pre-written — not a template the rig is bound to,
 which is exactly what crig exists not to have, but a set of ordinary dots and
 bones dropped in as one undoable edit. The moment they land they are indis-
 tinguishable from placed ones: drag them, delete them, add to them, Ctrl+Z the
 lot.

     `FittedDot[] fitted = fit_preset(mem, pack.preset(mem), geometry.bounds(), &voxels);`

 The tables live here as data rather than as files on disk. A preset is a dozen
 lines of numbers, and a data directory would buy nothing except a way for the
 app to be installed without one.

 **The frame.** Dot positions are in normalized bounding-box coordinates — 0 is
 the low corner of the mesh's bounds on that axis and 1 is the high corner, per
 axis independently. Per axis, not a uniform cube fit: a uniform scale is right when the *shape* must be preserved, and
 wrong here, because a dachshund and a giraffe normalize into the same cube and
 their legs are nowhere near each other in it. What a preset wants to say is
 "the knee is a third of the way up", and that is a per-axis statement.

 **The axes**, and the limitation that comes with them: `x` is across the body,
 `y` is up, `z` runs along it with the head at 1. So a preset assumes glTF's +Y
 up and a model whose length runs along Z — the same assumption the editor's own
 mirroring already makes, since `sym_x` reflects across X and nothing else. A
 model laid out along X gets a preset lying across it, and the fix is to rotate
 the model, not to guess here: half-generalizing this while `sym_x` stays fixed
 would give the preset and `mirror_selection` two different ideas of which way
 is sideways. Which *end* is the head is measured rather than assumed — see
 `preset_reversed`.

 See PLAN §14.
*>
module crig;

import rig;
import collision;
import std::core::string;
import std::math;
import std::math::vector;



<*
 One dot of a body plan.

 `parent` indexes back into the same table and is always lower than the dot's
 own index, so a single forward pass can emit the bones as it goes — the same
 parents-before-children order the export BFS produces, arrived at by writing
 the table in that order rather than by sorting it.
*>
struct PresetDot
{
	String name;
	Vec3 at;      // normalized: 0..1 per axis, x across, y up, z head-ward
	int parent;   // index in the same table, or -1 for the root
	bool mirror;  // also emit the reflection through x = 0.5

	<*
	 Part of the plan's vocabulary, but not part of its shape.

	 Fingers are the case. A hand-rigged figure that has them should have them
	 named, and a clip that keys them should reach them — but a biped without
	 them is still a biped, and a fit has no way to place a knuckle from
	 proportions alone. So an optional dot is a name the matcher may use and the
	 fit never places: `fit_preset` skips it, and `JointMatch.usable` leaves it
	 out of the count a rig has to cover.

	 The alternative was two plans, one handed and one not, and it does not work:
	 a rig matches whichever covers the larger fraction of itself, the smaller
	 plan wins that comparison by having less to cover, and tagging the two
	 differently splits the library into clips a handed rig can play and clips a
	 plain one can.
	*>
	bool optional;
}

struct Preset
{
	String name;
	String plan; // the body-plan tag, lowercased; "" for a table that carries none
	PresetDot[] dots;

	<*
	 The box `at` is a fraction of, when the plan was measured off a real one.
	 Zero for a hand-written table, which is a fraction of a box nobody measured.

	 `fit_preset` does not read it — a fraction per axis is exactly the frame it
	 wants, and mapping onto the target's own box is the whole trick. The matcher
	 does: dividing each axis by its own extent flattens a figure into a cube, and
	 comparing a cube-shaped plan against a source rig measured in true proportions
	 is comparing two different shapes.

	 It only shows on a plan with depth to it. Every dot the biped fit places sits
	 at mid-depth, so for seventeen joints the distortion had nothing to act on;
	 the fingers were the first dots to spread across the palm, and a biped is
	 about six times taller than it is deep, so their spread arrived at the matcher
	 six times too wide and their lengths in the wrong order — index and ring came
	 back swapped on every hand.
	*>
	Vec3 extent;
}

<*
 A dot after fitting: where it goes, and whether the mesh was there.

 `parent` has been remapped to index the fitted array, which is longer than the
 table it came from because the mirrored entries have been expanded.
*>
struct FittedDot
{
	String name;
	Vec3 position;
	int parent;
	bool landed;  // false: nothing solid within reach, and this is a guess

	// Carried through from `PresetDot.optional`. Only ever true when the fit was
	// asked to place the optional dots, which the app's own fits are not — this is
	// for the pack writer, which needs the whole plan as a skeleton and then needs
	// to say which of it was optional.
	bool optional;
}

<*
 How far a preset dot may reach for a body, in cells.

 A dot placed by the table can land in air — between the legs, under the chin,
 outside a lean model's belly — and the grid is what pulls it back in. Eight
 cells is a sixth of the model at the default resolution: far enough to cross
 the gap a limb dot misses by, short enough that a dot lost in open space does
 not get quietly attached to the nearest unrelated part of the animal. A dot
 that finds nothing within it stays where the table put it and is reported.
*>
const int PRESET_REACH = 8;

// ---------------------------------------------------------------------------
// The fit.

<*
 The mesh's bounds, and which way round the preset sits in them.
*>
struct PresetFit
{
	rig::Bounds box;
	// The preset's head end is at the mesh's low Z: the whole figure turned half
	// way round about Y, not reflected. A reflection keeps each side's joints on
	// the same X, so a biped fitted facing −Z would have its _L joints on its own
	// right — and a later Turn around (a rotation) could never put them back.
	bool reversed;
}

<*
 Normalized coordinates to model space.
*>
fn Vec3 PresetFit.place(self, Vec3 at)
{
	Vec3 low = self.box.min;
	Vec3 size = self.box.extent();
	float along = self.reversed ? 1.0f - at.z : at.z;
	float across = self.reversed ? 1.0f - at.x : at.x;

	return {
		low.x + size.x * across,
		low.y + size.y * at.y,
		low.z + size.z * along,
	};
}

<*
 The reflection of a normalized position across the body's midline.

 Through the middle of the bounding box, which is where `sym_x` also points on
 a fresh document — so a preset's pairs and a mirrored click land on the same
 plane rather than on two planes a few millimetres apart.
*>
fn Vec3 mirror_at(Vec3 at) => { 1.0f - at.x, at.y, at.z };

<*
 A side written out as a word, wherever it falls in the name:
 `mixamorig:LeftHandThumb1`, `upperarm_left`, `LEFT_FOOT`. Listed both ways
 round, so one pass answers either.

 Three casings rather than a case-insensitive compare, because the answer has to
 be spelled the way the question was — matching `LeftHand` case-blind and
 answering `rightHand` would name a joint no file has.
*>
struct SideWord @local
{
	String from;
	String to;
}

const SideWord[] SIDE_WORDS @local = {
	{ "Left", "Right" }, { "Right", "Left" },
	{ "left", "right" }, { "right", "left" },
	{ "LEFT", "RIGHT" }, { "RIGHT", "LEFT" },
};

<*
 The name a dot's mirror twin would carry, or "" for a name that names no side.

 	`mirror_name("thigh_L") == "thigh_R"`
 	`mirror_name("mixamorig:LeftHandThumb1") == "mixamorig:RightHandThumb1"`

 **Not only crig's own suffix.** `fit_preset` writes `_L`/`_R`, but a rig is
 named from whichever body plan it matched and a plan's words are its pack
 file's own joint names — so a figure matched against a downloaded Mixamo pack
 comes back spelled `mixamorig:LeftHand`, and one exported from Unreal spelled
 `hand_l`. Reading only the suffix left every one of those a name with no
 other side, which is not a rig with no symmetry but a mirror that could not
 see the symmetry it had: it would place a second skeleton on top of the one
 already there rather than square the two halves up.

 Two forms, tried in that order: **a side letter standing as a word of its own**
 — `thigh_L`, `hand.R`, `L_Upperarm`, `Bip01_L_Finger0` — and then **the side
 written out**. The letter is looked for anywhere rather than only at the ends,
 because it is a word of the name wherever it sits, and the conventions that put
 it in the middle are as common as the ones that do not.

 Here rather than beside the rigger that first wanted it, because the suffix is
 this file's invention and both the rig editor and the clip mirror read it.

 The caller owns the returned string when it is non-empty.
*>
fn String mirror_name(Allocator allocator, String name)
{
	foreach (usz i, letter : name)
	{
		char twin = side_letter_twin(letter);
		if (twin == 0) continue;

		// A word of its own: fenced by the characters a joint name breaks on, or by
		// the ends of the name. Without the fence the `r` of `arm` would be a side.
		if (i > 0 && !name_break(name[i - 1])) continue;
		if (i + 1 < name.len && !name_break(name[i + 1])) continue;

		char[] flipped = alloc::clone_slice(allocator, (char[])name);
		flipped[i] = twin;
		return (String)flipped;
	}

	foreach (word : SIDE_WORDS)
	{
		sz found = side_word_at(name, word.from);
		if (found < 0) continue;

		usz at = (usz)found;
		usz after = at + word.from.len;
		return string::format(
			allocator, "%s%s%s", name[:at], word.to, name[after:name.len - after]);
	}

	return "";
}

<*
 Which side a name says it is on, read by `mirror_name`'s rules: the side letter
 standing as a word, then the side written out.

 	`name_side("thigh_L") == 'L'`, `name_side("hand_r") == 'r'`, `name_side("spine") == 0`

 @return `The side letter as the name spells it ('L', 'R', 'l' or 'r'; 'L'/'R' for a written-out side), or 0 for no side.`
*>
fn char name_side(String name)
{
	foreach (usz i, letter : name)
	{
		if (side_letter_twin(letter) == 0) continue;
		if (i > 0 && !name_break(name[i - 1])) continue;
		if (i + 1 < name.len && !name_break(name[i + 1])) continue;
		return letter;
	}
	foreach (word : SIDE_WORDS)
	{
		if (side_word_at(name, word.from) < 0) continue;
		return word.from[0] == 'L' || word.from[0] == 'l' ? 'L' : 'R';
	}
	return 0;
}

// The letter the other side writes this one as, or 0 for a character that names
// no side.
fn char side_letter_twin(char letter) @local
{
	switch (letter)
	{
		case 'L': return 'R';
		case 'R': return 'L';
		case 'l': return 'r';
		case 'r': return 'l';
		default: return 0;
	}
}

// The characters a joint name breaks its words on. Not every non-letter: a
// digit is part of the word beside it — `Spine1` is one word and `Finger0` is
// another — and reading `L` out of `L1` would pair a joint with its own
// neighbour.
fn bool name_break(char c) @local => c == '_' || c == '.' || c == '-';

// Where `word` sits in `name` as a side marker, or -1 for nowhere.
//
// Fenced at both ends, because the marker has to be a word of the name rather
// than a run of letters inside one: `Cleft` is not a left anything and
// `Rightful` is not a right one. A joint name breaks its words with a separator
// or with a capital, so both count as an edge — which is what lets
// `mixamorig:LeftHandThumb1` and `upperarm_left` be read by the same rule.
fn sz side_word_at(String name, String word) @local
{
	if (word.len == 0 || word.len > name.len) return -1;

	for (usz i = 0; i + word.len <= name.len; i++)
	{
		if (name[i:word.len] != word) continue;

		// Before it: the start of the name, a separator, or the lowercase letter a
		// capitalised marker was camel-cased onto.
		if (i > 0)
		{
			char before = name[i - 1];
			if (before.is_alpha() && !(before.is_lower() && word[0].is_upper())) continue;
		}

		// After it: anything that is not a lowercase word carrying on.
		usz after = i + word.len;
		if (after < name.len && name[after].is_lower()) continue;

		return (sz)i;
	}

	return -1;
}

<*
 What it costs to pull one placed dot into the body, in model units.

 Zero when the dot is already inside. Otherwise the distance to the nearest
 interior cell, or the full reach when there is none — a miss has to score
 *worse* than any hit, or a fit that misses everything would win by having
 nothing to correct.
*>
fn float snap_cost(collision::VoxelGrid* grid, Vec3 point) @private
{
	if (grid.inside(point)) return 0.0f;

	int entry = grid.nearest_cell(point, PRESET_REACH);
	if (entry < 0) return (float)PRESET_REACH * grid.cell;

	return (grid.entry_center(entry) - point).length();
}

<*
 Which end of the mesh the preset's head belongs at.

 Both ways round are placed and scored by how far their dots have to be dragged
 to reach solid material; the cheaper one wins. What carries it is the parts of
 a body plan that are *not* front-to-back symmetric — a tail is a thin thing
 low and behind, and fitted backwards its dots hang in the air under the chin,
 where a head fitted backwards still finds the rump. A gross bounding box says
 nothing about facing, and neither does the spine.

 It is a measurement, not a proof: a model with its tail tucked, or one whose
 head is down grazing, weakens the only signal there is. A tie goes to the
 table's own orientation, and the operation reports which way it went, because a
 preset fitted backwards should be legible at a glance rather than mysterious.

 @return `True if the preset should be flipped along Z.`
*>
fn bool preset_reversed(Preset preset, rig::Bounds box, rig::MeshVoxels* voxels)
{
	if (voxels == null || !voxels.usable()) return false;

	collision::VoxelGrid* grid = &voxels.grid;
	float[] weights = branch_weights(tmem, preset);
	float forward = (float)math::FLOAT_MAX;
	float backward = (float)math::FLOAT_MAX;

	// Each way round is scored at its best slide along Z rather than where the
	// box puts it. The box is the mesh's whole extent, so a tail, a cape or a
	// sword behind the figure drags the plan backwards off the body; scored
	// where the box put it, the reversed fit — shoved forward by the same
	// amount — lands its hips and knees in the body and wins on an offset the
	// facing has nothing to do with. Slid to where each fits best, what is
	// left to compare is shape: toes that point the way the feet do.
	float step = box.extent().z * FACING_SLIDE_STEP;
	for (int slide = -FACING_SLIDES; slide <= FACING_SLIDES; slide++)
	{
		Vec3 offset = { 0, 0, step * (float)slide };
		forward = math::min(forward, facing_cost(preset, weights, grid, { .box = box, .reversed = false }, offset));
		backward = math::min(backward, facing_cost(preset, weights, grid, { .box = box, .reversed = true }, offset));
	}
	return backward < forward;
}

const int FACING_SLIDES = 8;
const float FACING_SLIDE_STEP = 0.03f; // of the box's depth, so ±24% either way

fn float facing_cost(Preset preset, float[] weights, collision::VoxelGrid* grid, PresetFit fit, Vec3 offset) @private
{
	float cost = 0.0f;
	foreach (usz i, dot : preset.dots)
	{
		if (dot.optional) continue;
		cost += weights[i] * snap_cost(grid, fit.place(dot.at) + offset);
		if (dot.mirror) cost += weights[i] * snap_cost(grid, fit.place(mirror_at(dot.at)) + offset);
	}
	return cost;
}

<*
 How much each dot's vote on facing counts: every branch shares its parent's
 weight equally, and a chain passes its weight down unchanged.

 So a leg — thigh, knee, ankle, toe, toe tip — votes as one limb, and so does a
 hand however many fingers it carries. Counted dot by dot, a biped's forty
 finger joints outvoted its four toe joints: a hand's pose differs from model to
 model, the toes point forward on nearly all of them, and a character whose
 hands sat a little behind the plan's was fitted facing −Z.
*>
fn float[] branch_weights(Allocator allocator, Preset preset) @private
{
	float[] weights = alloc::new_array(allocator, float, (sz)preset.dots.len);
	foreach (usz i, dot : preset.dots)
	{
		if (dot.parent < 0 || (usz)dot.parent >= i)
		{
			weights[i] = 1.0f;
			continue;
		}
		usz siblings = 0;
		foreach (other : preset.dots)
		{
			if (other.parent == dot.parent && !other.optional) siblings++;
		}
		weights[i] = weights[(usz)dot.parent] / (float)(siblings > 0 ? siblings : 1);
	}
	return weights;
}

<*
 Place a body plan on a mesh.

 Three steps, in order: decide which way round it goes, map every dot out of
 normalized coordinates into the mesh's own, and pull the ones that landed in
 air onto the nearest solid cell. The mirrored entries are expanded here, so
 the result is longer than the table and its `parent` indices have been remapped
 to match — a mirrored dot bones to its parent's *twin* where the parent has
 one, which is what builds two chains down the sides of the body instead of a
 ladder across it.

 **Optional dots are not placed at all** — see `PresetDot.optional`. They are
 vocabulary for the matcher, not shape for the fit, and there is nothing in a
 mesh's proportions that says where a knuckle goes. So the result is shorter
 than the table by however many of them it holds.

 With no grid the dots land where the table put them and all of them report as
 landed. That is the same bargain the geodesic binder makes (§13): every gap
 falls back to something usable rather than refusing, because a preset that
 declines to place anything on an open mesh is worse than one that places a
 rough guess the user can drag.

 The caller owns the returned array.

 @param box : `The mesh's bounds — normally geometry.bounds().`
 @param voxels : `Built from the same mesh; null skips both the facing test and the snap.`
 @param reversed : `Receives which way round it went, for callers that report it.`
 @param place_optional : `Place the optional dots as well. For the pack writer, which turns a whole plan into a skeleton; a fit onto a user's mesh wants the default.`
*>
fn FittedDot[] fit_preset(
	Allocator allocator,
	Preset preset,
	rig::Bounds box,
	rig::MeshVoxels* voxels,
	bool* reversed = null,
	bool place_optional = false)
{
	usz count = 0;
	foreach (dot : preset.dots)
	{
		if (dot.optional && !place_optional) continue;
		count += dot.mirror ? 2 : 1;
	}
	if (count == 0) return {};

	FittedDot[] fitted = alloc::new_array(allocator, FittedDot, (sz)count);

	// Table index -> index of its primary dot in `fitted`. A twin, when there is
	// one, always sits immediately after its primary, so one map is enough.
	//
	// An optional dot is not emitted, so its entry stands for the nearest ancestor
	// that was: a required dot hanging off a skipped one bones to that instead of
	// to nothing. No table the app holds is written that way — fingers hang off
	// fingers — but the map has to answer something, and a stale index into an
	// array this dot is not in is the one answer that corrupts the result quietly.
	int[] emitted = alloc::new_array(allocator, int, (sz)preset.dots.len);
	defer alloc::free(allocator, emitted);

	// Whether the dot `emitted[i]` points at has its twin in the slot after it.
	// Carried separately from the table's own `mirror` flag because a skipped dot
	// inherits its ancestor's answer, and asking the table would then read the
	// flag of a dot that was never emitted.
	bool[] paired = alloc::new_array(allocator, bool, (sz)preset.dots.len);
	defer alloc::free(allocator, paired);

	PresetFit fit = { .box = box, .reversed = preset_reversed(preset, box, voxels) };
	collision::VoxelGrid* grid = voxels != null && voxels.usable() ? &voxels.grid : null;
	if (reversed) *reversed = fit.reversed;

	// How far each emitted dot's snap moved it from where the table put it. A dot
	// the table puts in mid-air takes its parent's move before it is snapped
	// itself, so a hand pulled into a thinner arm brings its fingers along still
	// spread, instead of each finger being pulled onto the same nearest cell.
	Vec3[] shifts = alloc::new_array(allocator, Vec3, (sz)count);
	defer alloc::free(allocator, shifts);

	// Where the table puts every emitted dot, in emission order, before anything is
	// snapped — so a snap can be kept off the spot a dot placed after it will take.
	Vec3[] tables = alloc::new_array(allocator, Vec3, (sz)count);
	defer alloc::free(allocator, tables);
	usz listed = 0;
	foreach (dot : preset.dots)
	{
		if (dot.optional && !place_optional) continue;
		tables[listed++] = fit.place(dot.at);
		if (dot.mirror) tables[listed++] = fit.place(mirror_at(dot.at));
	}

	usz next = 0;
	foreach (usz i, dot : preset.dots)
	{
		int parent = dot.parent >= 0 ? emitted[(usz)dot.parent] : -1;
		bool parent_paired = dot.parent >= 0 && paired[(usz)dot.parent];

		if (dot.optional && !place_optional)
		{
			emitted[i] = parent;
			paired[i] = parent_paired;
			continue;
		}
		emitted[i] = (int)next;
		paired[i] = dot.mirror;

		String primary_name = dot.mirror
			? string::format(allocator, "%s_L", dot.name)
			: (String)alloc::clone_slice(allocator, (char[])dot.name);
		fitted[next] = snap_carried(next, parent, shifts, fitted[:next], tables, primary_name, grid);
		shifts[next] = fitted[next].position - tables[next];
		fitted[next++].optional = dot.optional;
		if (!dot.mirror) continue;

		// The twin follows its parent's twin where the parent had one; a dot on
		// the midline has no twin, and both sides hang off it.
		int twin_parent = parent_paired ? parent + 1 : parent;

		String twin_name = string::format(allocator, "%s_R", dot.name);
		fitted[next] = snap_carried(next, twin_parent, shifts, fitted[:next], tables, twin_name, grid);
		shifts[next] = fitted[next].position - tables[next];
		fitted[next++].optional = dot.optional;
	}

	return fitted;
}

<*
 Release a fit and the names in it.

 Every name is a fresh allocation — the mirrored entries are formatted with
 their side suffix and the rest are copied — so releasing the array alone leaks
 one string per dot.

 @param allocator : `The one fit_preset was given; the names came off it too.`
*>
fn void free_fitted(Allocator allocator, FittedDot[] fitted)
{
	foreach (dot : fitted)
	{
		if (dot.name.len > 0) alloc::free(allocator, dot.name.ptr);
	}
	if (fitted.len > 0) alloc::free(allocator, fitted);
}

<*
 A point pulled inside the mesh, or left where it is when nothing is within
 reach.

 	`Vec3 at = snapped_inside(&voxels.grid, asked_for);`

 What a body plan does to every dot it places, and what anything else placing a
 dot from a computed coordinate wants too — a dot outside the mesh binds nothing,
 and a caller that cannot see the model gets one about as often as not.

 Returning the point unmoved rather than refusing is deliberate. A dot in the
 wrong place is something a person can see and drag; one that was never placed is
 something they have to notice is absent, and in the middle of a chain it breaks
 the chain.

 @param grid : `Null, or a grid with no inside, leaves every point where it is.`
 @param landed : `Set to whether the point ended up inside, if given.`
*>
fn Vec3 snapped_inside(collision::VoxelGrid* grid, Vec3 position, bool* landed = null)
{
	if (landed) *landed = true;
	if (grid == null || grid.inside(position)) return position;

	int entry = grid.nearest_cell(position, PRESET_REACH);
	if (entry < 0)
	{
		if (landed) *landed = false;
		return position;
	}
	// The nearest point of that cell rather than its centre: two points outside
	// the same thin limb share a nearest cell, and its centre would stack them.
	// Held just short of the cell's faces so the result still reads as inside.
	Vec3 center = grid.entry_center(entry);
	float half = grid.cell * SNAP_CELL_INSET;
	Vec3 offset = position - center;
	return center + (Vec3){
		math::clamp(offset.x, -half, half),
		math::clamp(offset.y, -half, half),
		math::clamp(offset.z, -half, half),
	};
}

// How far into its cell, as a fraction of the cell, a snapped point may sit from
// the centre. Under a half so rounding puts it back in the same cell.
const float SNAP_CELL_INSET @private = 0.45;

<*
 One placed dot that may first take its parent's snap. A dot the table already
 puts in solid material stays exactly there; one in mid-air tries where its
 parent's move carries it, and only snaps if that is still outside.

 @param index : `Which emitted dot this is: tables[index] is where the table puts it, placed is everything before it.`
*>
fn FittedDot snap_carried(
	usz index, int parent, Vec3[] shifts, FittedDot[] placed, Vec3[] tables, String name, collision::VoxelGrid* grid) @private
{
	Vec3 table = tables[index];
	Vec3 position = table;
	if (grid == null || grid.inside(position)) return snap(position, name, parent, grid);
	if (parent >= 0) position += shifts[(usz)parent];
	FittedDot dot = snap(position, name, parent, grid);

	// A finger is thinner than a cell, so its whole hand can share one nearest
	// cell and every snap would land on the same few points — fingers stacked on
	// each other, a tip pulled back past its knuckle, a pinky folded into the
	// palm. So the snap only stands if it leaves this dot at least
	// SNAP_SPACING_KEPT of the table's distance from every other one; otherwise
	// the carried point, then the table's own, is the better guess, and the person
	// drags it the rest of the way. Where all three are crowded the roomiest wins.
	Vec3 carry = position - table;
	Vec3[3] candidates = { dot.position, position, table };
	float best = -1.0f;
	usz chosen = 0;
	foreach (usz c, at : candidates)
	{
		float room = snap_room(at, index, carry, placed, tables, grid.cell * SNAP_CROWDED);
		if (room >= SNAP_SPACING_KEPT) { chosen = c; break; }
		if (room > best) { best = room; chosen = c; }
	}
	if (chosen == 0) return dot;
	dot.position = candidates[chosen];
	dot.landed = grid.inside(dot.position);
	return dot;
}

<*
 How much of the table's spacing a dot at `at` keeps from its closest
 neighbour, as a fraction: 1 is the table's own distance, under
 SNAP_SPACING_KEPT is folded together. A dot not placed yet is judged at its
 table spot carried the way this one was, since a hand moves its fingers
 together. Two dots closer than `crowd` count as stacked whatever the table says.
*>
fn float snap_room(Vec3 at, usz index, Vec3 carry, FittedDot[] placed, Vec3[] tables, float crowd) @private
{
	float room = (float)math::FLOAT_MAX;
	foreach (usz k, other : tables)
	{
		if (k == index) continue;
		Vec3 there = k < placed.len ? placed[k].position : other + carry;
		float got = (there - at).length();
		if (got <= crowd) return 0.0f;
		float wanted = (tables[index] - other).length();
		if (wanted <= 0.0f) continue;
		room = math::min(room, got / wanted);
	}
	return room;
}

// Closer than this, as a fraction of a cell, a snapped dot counts as on top of
// another one.
const float SNAP_CROWDED @private = 0.25;

// How much of the table's distance between two dots a snap must leave them. Under
// it the snap has folded them together, and the dot keeps its carried place.
const float SNAP_SPACING_KEPT @private = 0.5;

<*
 One placed dot, pulled inside the mesh if it needs it.
*>
fn FittedDot snap(Vec3 position, String name, int parent, collision::VoxelGrid* grid) @private
{
	bool landed;
	Vec3 at = snapped_inside(grid, position, &landed);
	return { .name = name, .position = at, .parent = parent, .landed = landed };
}

// ---------------------------------------------------------------------------
// The body plans.
//
// Read these as fractions of the bounding box: x = 0.5 is the midline, y = 0 is
// the lowest point of the model and 1 the highest, z = 1 is the head end. The
// numbers are deliberately conservative — a dot slightly inside the body is a
// dot the user nudges, while one outside it is one the grid has to rescue.

// The body-plan tables that used to live here are in tools/body_plans.c3 now.
//
// They are authoring data, not runtime data: a body plan says which joints a
// rig has and what they are called, and the only thing that knows what a clip
// needs is the file the clip came from. So the tables are what the packs are
// *generated* from, and the app reads plans out of the packs — see
// anim/pack.c3. A crig with an empty animations folder offers no plans at
// all, which is the honest answer rather than three guesses.
