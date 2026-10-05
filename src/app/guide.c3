<*
 The workflow guide: where the open project stands on Model › Skeleton › Skin ›
 Animations › Export, in numbers the guide bar and the hint bar turn into words.

 Cheap per frame. Counting names is a walk over the dots; the bound-clip count
 resolves every binding, so it is kept until the history moves; and which joints
 hold no skin needs a bind, so that is surveyed once the rig has been still for
 `GUIDE_SURVEY_DELAY`, over the same cached base bind the weight views share.
*>
module crig;

import rig;
import std::math;

const float GUIDE_SURVEY_DELAY = 0.3;

// The skin a joint must hold, in vertices' worth, not to count as holding none.
const float SKINLESS_MASS = 1.0;

enum GuideStep : char
{
	MODEL,
	SKELETON,
	SKIN,
	ANIMATIONS,
	EXPORT,
}

enum GuideState : char
{
	NOT_YET,
	DONE,
	ATTENTION,
}

<*
 Which joints hold no skin, as of the last survey.

 Only joints with a parent and a child count: a tip joint (head_top, a finger
 end) closes the bone before it, and a root is often a control joint on the
 floor, so both hold nothing by design.
*>
struct SkinSurvey
{
	bool ready; // the numbers below describe the rig as keyed
	bool surveyed; // they describe some earlier rig at least; kept while a new survey waits
	bool keyed; // `rig`/`revision`/`geometry` have been read at least once
	uint rig;
	uint revision;
	uint geometry;
	float due;
	usz skinless;
	uint first_skinless; // dot id, 0 = none
	bool from_file; // the model's own weights are in use: what they leave empty was the artist's choice
}

struct BoundTally
{
	bool ready;
	uint revision;
	usz bindings;
	usz packs;
	usz total;
	usz found;
}

struct GuideStatus
{
	bool has_mesh;
	usz joints;
	usz unnamed;
	uint first_unnamed;
	bool skin_known;
	bool skin_from_file;
	usz skinless;
	uint first_skinless;
	usz clips;
	usz clips_found;
	bool unsaved;
	bool saved; // the document writes a file crig made: a save or export happened
}

<*
 Per joint, whether it holds essentially none of the mesh: under one vertex's
 worth (`SKINLESS_MASS`), or under `rig::DEFAULT_PRUNE_SHARE` of a mesh too small
 for that to be less. With `influences` set, each vertex
 counts only its strongest that many joints, renormalised, which is what the
 written skin keeps. The caller owns the array.
*>
fn bool[] skinless_joints(Allocator allocator, float[] skin, usz vertices, usz joints, uint influences = 0)
{
	bool[] idle = alloc::new_array(allocator, bool, (sz)joints);
	if (joints == 0 || vertices == 0 || skin.len != vertices * joints) return idle;

	float[] mass = alloc::new_array(mem, float, (sz)joints);
	defer alloc::free(mem, mass);
	bool top_only = influences > 0 && (usz)influences < joints;
	usz[8] top;
	usz keep = top_only ? math::min((usz)influences, (usz)top.len) : 0;
	for (usz v = 0; v < vertices; v++)
	{
		float[] row = skin[v * joints : joints];
		if (!top_only)
		{
			float sum = 0.0f;
			foreach (w : row) sum += w;
			if (sum <= 0.0f) continue;
			foreach (j, w : row) mass[j] += w / sum;
			continue;
		}
		// The `keep` strongest, by insertion.
		usz held = 0;
		foreach (usz j, w : row)
		{
			if (w <= 0.0f) continue;
			usz at = held < keep ? held++ : keep;
			if (at == keep && w <= row[top[keep - 1]]) continue;
			if (at == keep) at = keep - 1;
			while (at > 0 && row[top[at - 1]] < w)
			{
				top[at] = top[at - 1];
				at--;
			}
			top[at] = j;
		}
		float sum = 0.0f;
		for (usz k = 0; k < held; k++) sum += row[top[k]];
		if (sum <= 0.0f) continue;
		for (usz k = 0; k < held; k++) mass[top[k]] += row[top[k]] / sum;
	}

	// Less than one vertex's worth: a share of the whole would call a finger bone
	// on a dense mesh empty (0.5% of 11000 vertices is more than a finger holds),
	// while a joint that is truly idle — outside the body, nobody's top four —
	// holds next to nothing at any density.
	float floor_mass = math::min(rig::DEFAULT_PRUNE_SHARE * (float)vertices, SKINLESS_MASS);
	foreach (usz j, held : mass) idle[j] = held < floor_mass;
	return idle;
}

<*
 Whether edits have been made since the project was opened or last saved.

 An opened or loaded project starts with an empty history, so a history with
 nothing in it is clean; after a save the revision is remembered. Undoing back
 to the saved state still reads as unsaved.
*>
fn bool AppState.unsaved(&self)
{
	if (self.authored_dirty) return true;
	if (self.undo_stack.edits.len() == 0) return false;
	return self.undo_stack.revision != self.saved_revision;
}

fn void AppState.mark_saved(&self)
{
	self.saved_revision = self.undo_stack.revision;
}

<*
 Advance the skin survey: rekey on a rig, history or mesh change, and survey
 once the rig has been still for `GUIDE_SURVEY_DELAY`. Nothing while a gesture
 is in flight, since the document is mid-edit.
*>
fn void AppState.tick_guide(&self, float dt)
{
	if (self.config.hide_guide) return;
	SkinSurvey* s = &self.skin_survey;
	if (!s.keyed || s.rig != self.rig_generation || s.revision != self.undo_stack.revision
		|| s.geometry != self.geometry_generation)
	{
		s.keyed = true;
		s.rig = self.rig_generation;
		s.revision = self.undo_stack.revision;
		s.geometry = self.geometry_generation;
		s.ready = false;
		s.due = GUIDE_SURVEY_DELAY;
	}
	if (s.ready) return;
	if (self.drag.dot != 0 || self.stroke_open || self.transform_interaction.active) return;
	s.due -= dt;
	if (s.due > 0.0f) return;
	self.survey_skin();
}

fn bool AppState.guide_pending(&self) => !self.config.hide_guide && !self.skin_survey.ready;

<*
 Bind (through the shared cache) and count the joints with a child that hold no
 skin. An empty rig or mesh is surveyed as nothing to report.
*>
fn void AppState.survey_skin(&self)
{
	SkinSurvey* s = &self.skin_survey;
	s.ready = true;
	s.surveyed = true;
	s.skinless = 0;
	s.first_skinless = 0;
	s.from_file = false;
	if (!self.has_mesh() || self.doc.dots.len() == 0) return;

	RigView? opened = self.open_rig(mem);
	if (catch opened) return;
	RigView view = opened;
	defer view.free(mem);

	float[] dense = self.painted_bind(mem, &view);
	if (dense.len == 0) return;
	defer alloc::free(mem, dense);

	if (self.doc.skin_from_file)
	{
		float[] taken = self.imported_dense(mem, &view);
		s.from_file = taken.len > 0;
		if (taken.len > 0) alloc::free(mem, taken);
	}

	usz joints = view.len();
	bool[] idle = skinless_joints(mem, dense, self.geometry.positions.len, joints, SKIN_INFLUENCES);
	defer alloc::free(mem, idle);

	bool[] parent_of = alloc::new_array(mem, bool, (sz)joints);
	defer alloc::free(mem, parent_of);
	foreach (parent : view.skeleton.parents)
	{
		if (parent >= 0 && (usz)parent < joints) parent_of[parent] = true;
	}
	for (usz j = 0; j < joints; j++)
	{
		if (!idle[j] || !parent_of[j] || view.skeleton.parents[j] < 0) continue;
		if (s.skinless == 0) s.first_skinless = view.dot_ids[j];
		s.skinless++;
	}
}

<*
 How many clips are bound and how many of them resolve, kept until the history,
 the binding list or the library moves.
*>
fn void AppState.tally_bound(&self, usz* total, usz* found)
{
	BoundTally* t = &self.bound_tally;
	usz bindings = (usz)self.doc.animations.len();
	usz packs = (usz)self.packs.len();
	if (!t.ready || t.revision != self.undo_stack.revision || t.bindings != bindings || t.packs != packs)
	{
		self.bound_counts(&t.total, &t.found);
		t.ready = true;
		t.revision = self.undo_stack.revision;
		t.bindings = bindings;
		t.packs = packs;
	}
	*total = t.total;
	*found = t.found;
}

fn GuideStatus AppState.guide_status(&self)
{
	GuideStatus g = {
		.has_mesh = self.has_mesh(),
		.joints = (usz)self.doc.dots.len(),
		.skin_known = self.skin_survey.surveyed,
		.skinless = self.skin_survey.skinless,
		.first_skinless = self.skin_survey.first_skinless,
		.skin_from_file = self.skin_survey.from_file,
		.unsaved = self.unsaved(),
		.saved = self.saves_in_place,
	};
	foreach (dot : self.doc.dots.array_view())
	{
		if (dot.name.len > 0) continue;
		if (g.unnamed == 0) g.first_unnamed = dot.id;
		g.unnamed++;
	}
	self.tally_bound(&g.clips, &g.clips_found);
	return g;
}

fn GuideState GuideStatus.state(self, GuideStep step)
{
	switch (step)
	{
		case MODEL:
			return self.has_mesh ? DONE : NOT_YET;
		case SKELETON:
			if (self.joints == 0) return NOT_YET;
			return self.unnamed > 0 && self.clips > 0 ? ATTENTION : DONE;
		case SKIN:
			if (!self.has_mesh || self.joints == 0 || !self.skin_known) return NOT_YET;
			return self.skinless > 0 && !self.skin_from_file ? ATTENTION : DONE;
		case ANIMATIONS:
			if (self.clips == 0) return NOT_YET;
			return self.clips_found < self.clips ? ATTENTION : DONE;
		case EXPORT:
			if (!self.has_mesh || self.joints == 0) return NOT_YET;
			if (self.unsaved) return ATTENTION;
			return self.saved ? DONE : NOT_YET;
	}
}

<*
 The first step that is not done, in flow order — the one the guide outlines and
 the hint bar's "Next:" line is about. Animations are optional, so an empty list
 is next only once everything before it is done; -1 when all are.
*>
fn sz GuideStatus.next_step(self)
{
	for (sz i = 0; i < GuideStep::len; i++)
	{
		if (self.state((GuideStep)i) != DONE) return i;
	}
	return -1;
}
