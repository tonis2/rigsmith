<*
 The skin over a clip: the mesh posed by the rig's own weights at instants
 through the clip, and every edge measured against its length at rest. The half
 of a clip's check that the joint numbers cannot see (`algo/skin/skin_stretch.c3`).

 	`SkinStretch[] faults = app.clip_skin_faults(mem, &view, *clip, ref, 48);`
*>
module crig;

import gltf;
import rig;
import std::math;

// How many instants the skin is posed at. Each is the whole mesh skinned and its
// every edge measured, so it is fewer than the joint numbers take.
const usz SKIN_SAMPLES = 48;
// As many regions as one answer names.
const usz SKIN_FAULTS_MOST = 12;

<*
 The regions of the skin the clip stretches past tolerance, worst first. Empty
 without a mesh or weights. The caller owns the result.

 @param samples : "Instants to pose at; SKIN_SAMPLES at most"
*>
fn SkinStretch[] AppState.clip_skin_faults(&self, Allocator allocator, RigView* view, AnimTemplate clip, AnimRef ref,
	usz samples = SKIN_SAMPLES)
{
	usz vertices = self.geometry.positions.len;
	if (vertices == 0 || view.len() == 0 || clip.duration <= 0.0f) return {};
	float height = view.skeleton.height();
	if (height <= 0.0f) return {};

	float[] dense = self.weights(mem, view);
	defer if (dense.len > 0) alloc::free(mem, dense);
	if (dense.len == 0) return {};
	gltf::SkinBinding? bound = gltf::sparsify_weights(mem, dense, vertices, view.len(), SKIN_INFLUENCES);
	if (catch bound) return {};
	gltf::SkinBinding binding = bound;
	defer binding.free(mem);

	SkinEdge[] edges = skin_edges(mem, self.geometry.positions, self.geometry.indices);
	defer if (edges.len > 0) alloc::free(mem, edges);
	Vec3[] posed = alloc::new_array(mem, Vec3, (sz)vertices);
	defer alloc::free(mem, posed);
	int[] shell_of = self.shells.of.len == vertices ? self.shells.of : (int[]){};

	SkinStretchLog log = new_skin_stretch_log(mem);
	defer log.free();
	usz count = math::clamp(samples, (usz)2, SKIN_SAMPLES);
	for (usz s = 0; s < count; s++)
	{
		float time = clip.duration * (float)s / (float)(clip.loop ? count : count - 1);
		rig::Pose pose = self.evaluated_clip_pose(mem, view, clip, ref, time, aimed: true);
		defer pose.free(mem);
		Matrix4f[]? palette = rig::joint_palette(mem, &view.skeleton, pose);
		if (catch palette) continue;
		defer alloc::free(mem, palette);
		skinned_positions(self.geometry.positions, binding, palette, posed);
		log.measure(edges, self.geometry.positions, posed, shell_of, binding, s);
	}

	// The shell's owner and size first, which is what decides how much it may grow.
	foreach (&row : log.worst)
	{
		if (!row.candidate(height)) continue;
		row.phase = (float)row.sample / (float)count;
		row.owner = shell_owner(binding, shell_of, row.shell, view.len(), &row.shell_vertices);
	}
	usz faults = 0;
	foreach (row : log.worst) if (row.faulty(height, vertices)) faults++;
	if (faults == 0) return {};
	SkinStretch[] out = alloc::new_array(allocator, SkinStretch, (sz)faults);
	usz written = 0;
	foreach (row : log.worst) if (row.faulty(height, vertices)) out[written++] = row;
	// Worst first, so the answer names the spike before the seam.
	for (usz i = 1; i < out.len; i++)
	{
		SkinStretch held = out[i];
		usz j = i;
		while (j > 0 && out[j - 1].stretch < held.stretch)
		{
			out[j] = out[j - 1];
			j--;
		}
		out[j] = held;
	}
	return out;
}

<*
 The skin faults as clip issues, laid onto `numbers`: each names the joints the
 stretched edge runs between and the phase it is worst at. `names` lends the
 joint names.
*>
fn void ClipMetrics.add_skin_faults(&self, Allocator allocator, SkinStretch[] faults, String[] names)
{
	usz kept = math::min((usz)faults.len, (usz)SKIN_FAULTS_MOST);
	if (kept == 0) return;
	ClipIssue[] issues = alloc::new_array(mem, ClipIssue, (sz)kept);
	defer alloc::free(mem, issues);
	foreach (usz i, found : faults[:kept])
	{
		issues[i] = {
			.kind = SKIN_STRETCH,
			.joint = found.joint_a >= 0 && (usz)found.joint_a < names.len ? names[(usz)found.joint_a] : "",
			.other = found.joint_b >= 0 && (usz)found.joint_b < names.len ? names[(usz)found.joint_b] : "",
			.phase = found.phase,
			.magnitude = found.stretch,
			.axis = -1,
		};
	}
	self.add_issues(allocator, issues);
}

// The joint holding the most of one shell's weight, summed over its vertices, and
// how many vertices it has. -1 when nothing holds it.
fn int shell_owner(gltf::SkinBinding binding, int[] shell_of, int shell, usz joints, usz* vertices) @private
{
	*vertices = 0;
	if (joints == 0 || binding.slots == 0) return -1;
	float[] held = alloc::new_array(mem, float, (sz)joints);
	defer alloc::free(mem, held);
	for (usz v = 0; v < binding.vertices; v++)
	{
		if (shell_of.len > v && shell_of[v] != shell) continue;
		(*vertices)++;
		for (usz s = 0; s < binding.slots; s++)
		{
			usz j = binding.joints[v * binding.slots + s];
			if (j < joints) held[j] += binding.weights[v * binding.slots + s];
		}
	}
	int best = -1;
	float most = 0.0f;
	foreach (usz j, w : held)
	{
		if (w > most)
		{
			most = w;
			best = (int)j;
		}
	}
	return best;
}

<*
 A small piece of the mesh split between joints: what stretches into a spike
 the moment those joints move apart, found from the rig at rest.
*>
struct LooseShell
{
	usz shell;
	int owner;     // the joint holding most of it
	int second;    // the joint holding the next most
	float share;   // the owner's share of the piece's weight
	float second_share;
}

// A piece whose owner holds less than this share of it is split.
const float LOOSE_SHELL_SHARE = 0.9f;
const usz LOOSE_SHELLS_MOST = 16;

<*
 The small pieces (`skin_small_piece`) no joint holds whole and nothing pins,
 smaller than the gap between the two joints holding them: a knot whose cords
 run to a thigh and the hips, a tusk split between head and jaw. A glove over a
 hand spans its joints and is meant to bend with them, so it is left out.

 @return `How many were written to the front of into.`
*>
fn usz AppState.loose_shells(&self, RigView* view, LooseShell[] into)
{
	usz vertices = self.geometry.positions.len;
	usz joints = view.len();
	if (vertices == 0 || joints < 2 || !self.shells.split() || self.shells.of.len != vertices) return 0;
	float[] dense = self.weights(mem, view);
	defer if (dense.len > 0) alloc::free(mem, dense);
	if (dense.len != vertices * joints) return 0;

	ShellRow[] rows = self.shell_rows(mem);
	defer if (rows.len > 0) alloc::free(mem, rows);
	float[] held = alloc::new_array(mem, float, (sz)joints);
	defer alloc::free(mem, held);
	usz count = 0;
	foreach (row : rows)
	{
		if (count >= into.len) break;
		if (!skin_small_piece(row.vertices, vertices)) continue;
		if (self.doc.attachment_of((uint)row.shell) != 0) continue;
		held[..] = 0.0f;
		float total = 0.0f;
		for (usz v = 0; v < vertices; v++)
		{
			if (self.shells.of[v] != (int)row.shell) continue;
			for (usz j = 0; j < joints; j++)
			{
				held[j] += dense[v * joints + j];
				total += dense[v * joints + j];
			}
		}
		if (total <= 0.0f) continue;
		int first = -1;
		int second = -1;
		foreach (usz j, w : held)
		{
			if (first < 0 || w > held[(usz)first])
			{
				second = first;
				first = (int)j;
			}
			else if (second < 0 || w > held[(usz)second])
			{
				second = (int)j;
			}
		}
		if (first < 0 || second < 0) continue;
		float share = held[(usz)first] / total;
		if (share >= LOOSE_SHELL_SHARE) continue;
		float gap = (view.skeleton.joints[(usz)first] - view.skeleton.joints[(usz)second]).length();
		if ((row.high - row.low).length() >= gap) continue;
		into[count++] = { .shell = row.shell, .owner = first, .second = second, .share = share,
			.second_share = held[(usz)second] / total };
	}
	return count;
}
