<*
 What a clip actually does, as numbers.

 A screenshot answers whether something is drawn. It does not answer whether a
 planted foot slid four centimetres while it was supposed to be still, which is
 the difference between a figure walking and a figure skating — and it is
 invisible in a still, obvious in motion, and hard to name once you have seen it.
 Both of the numbers that decide it, `foot_slide` and `floor_penetration`, are
 here.

 Everything is measured against a live skeleton, by sampling `AnimTemplate.pose`
 and reading the joints back through `rig::joint_palette` — the same path the
 player and the exporters take. So these are the clip as it will be played,
 carried onto this rig's bones and with its ground solve run, not the keyframes
 as they were typed.

 **Every length is a fraction of rig height.** The same cycle on a mesh exported
 in metres and one exported in centimetres reports the same stride, which is what
 makes a threshold worth writing down.
*>
module crig;

import rig;
import std::math;
import std::math::vector;



<*
 How far one joint moves over a cycle, and how high it gets.

 `travel` is measured *relative to the root*, so a clip that also carries the
 figure forward does not report every joint as having travelled the length of the
 stride. `low` and `high` are world heights, which is what a hand brushing the
 floor or a knee coming up to the chest is a question about.
*>
struct JointTravel
{
	String name;
	float travel;
	float low;
	float high;
}

<*
 One localized fault in a clip: what kind, where, and how much.

 The aggregate numbers say a clip skates or sinks; these say *which joint*, at
 *which phase*, and by how much — the difference between "this cycle is wrong"
 and an edit. Magnitudes are in the unit the kind is measured in: a fraction of
 rig height for a slide, a penetration or a loop position gap; radians past the
 limit for a saturation; rig heights per second for a loop velocity jump.
*>
enum ClipIssueKind : int
{
	FOOT_SLIDE,
	FLOOR_PENETRATION,
	LIMIT_SATURATION,
	LOOP_POSITION,
	LOOP_VELOCITY,
}

fn String ClipIssueKind.tag(self)
{
	switch (self)
	{
		case FOOT_SLIDE: return "foot_slide";
		case FLOOR_PENETRATION: return "floor_penetration";
		case LIMIT_SATURATION: return "limit_saturation";
		case LOOP_POSITION: return "loop_position";
		case LOOP_VELOCITY: return "loop_velocity";
		default: return "";
	}
}

struct ClipIssue
{
	ClipIssueKind kind;
	String joint;    // borrowed from names; empty when the fault names no one joint
	float phase;     // where in the cycle, 0 to 1
	float magnitude; // the unit is the kind's; see ClipIssueKind
	int axis;        // 0/1/2 = the bone-local X/Y/Z a limit was hit on; -1 otherwise
}

// The thresholds below which a fault is not worth an author's attention: a slide
// or sink under this fraction of rig height, an authored rotation under this many
// radians past a limit, a loop gap under this fraction, a loop velocity step under
// this many rig heights per second. Reported alongside the issues so the caller
// knows what was and was not counted; not the same as the pose-equality epsilons,
// which compare two poses rather than judge one against the floor.
const float ISSUE_SLIDE_TOLERANCE = 0.01f;
const float ISSUE_PENETRATION_TOLERANCE = 0.005f;
const float ISSUE_LIMIT_TOLERANCE = 0.02f;
const float ISSUE_LOOP_POSITION_TOLERANCE = 0.01f;
const float ISSUE_LOOP_VELOCITY_TOLERANCE = 0.25f;
// As many localized rows as one answer carries. A saturated limit is one row per
// axis per joint, so a rig fighting its whole table could name many; past this the
// aggregate is the better read.
const usz ISSUE_MOST = 64;

<*
 A cycle's measurements.

 `foot_slide` and `stride` are zero for a clip with no ground spec: without one
 nothing says which joints are feet, and guessing would answer confidently and
 wrongly. `floor_penetration` is always measured — a figure sinking through the
 ground is worth knowing about whether or not it declared any feet.
*>
struct ClipMetrics
{
	float floor;             // the height everything below was measured against
	float floor_penetration; // deepest any joint got below it; never negative
	float foot_slide;        // worst departure from steady contact; see measure_contact
	float ground_speed;      // how fast the figure must travel not to skate, per second
	Vec3 ground_velocity;    // the same as a direction, in model units per second
	float stride;            // widest horizontal gap between two contact joints
	float root_bob;          // the root's world height range
	JointTravel[] joints;    // one per named joint, in joint order
	ClipIssue[] issues;      // localized faults, worst kept per foot/joint/axis
	usz samples;
}

fn void ClipMetrics.free(&self, Allocator allocator)
{
	if (self.joints.len > 0) alloc::free(allocator, self.joints);
	if (self.issues.len > 0) alloc::free(allocator, self.issues);
	*self = {};
}

<*
 Measure a clip against a rig.

 	`ClipMetrics numbers = clip_metrics(mem, &skeleton, names, clip, 32);`

 Samples are spread evenly over `[0, duration)` — the cycle, not the keyframes —
 because what is being measured is what the player shows, and the player reads
 between the keys.

 The caller owns the result and frees it with `ClipMetrics.free`.

 Localized faults ride along in `issues`. Foot slide, floor penetration and — on
 a looping clip — the loop seam are found from the geometry alone; joint-limit
 saturation needs the rotation-limit tables, so it is measured only when `doc` and
 `dot_ids` are given (the aggregate callers pass neither and pay nothing for it).

 @param samples : `How many instants to look at; clamped to at least two.`
 @param doc : `The document whose rotation-limit tables to test animated poses against, or null to skip limit saturation.`
 @param dot_ids : `The dot each skeleton joint was built from, in joint order — how a limit table is found for a joint. Empty skips limit saturation.`
 @param contacts : `Feet to measure slide by when the clip declares none, such as ones read off its motion. Never posed with: the clip plays as it is.`
 @require skeleton != null
*>
fn ClipMetrics clip_metrics(
	Allocator allocator,
	rig::Skeleton* skeleton,
	String[] names,
	AnimTemplate template,
	usz samples,
	RigDocument* doc = null,
	uint[] dot_ids = {},
	AnimGround contacts = {})
{
	usz joints = skeleton.len();
	ClipMetrics out = { .samples = samples < 2 ? 2 : samples };
	if (joints == 0) return out;

	float height = skeleton.height();
	if (height <= 0.0f) height = 1.0f;

	out.joints = alloc::new_array(allocator, JointTravel, (sz)joints);
	for (usz j = 0; j < joints; j++)
	{
		out.joints[j] = { .name = j < names.len ? names[j] : "", .low = 0, .high = 0 };
	}

	usz root = 0;
	while (skeleton.parents[root] >= 0) root = (usz)skeleton.parents[root];

	// Where the ground is, by the same rule the solve uses — except that a clip
	// with no ground spec still gets a floor to be measured against, taken from
	// the lowest joint the rig rests on. A figure sinking is a fact about the
	// clip whether or not it ever declared a foot.
	out.floor = ground_floor(skeleton, names, template.ground);

	// Every sampled world position, joint-major, so the pairwise travel below can
	// be walked without re-posing.
	// Sized for at least one foot even when the clip declares none: a zero-length
	// allocation has nothing to index and the loops below would still ask.
	AnimGround feet_spec = template.ground.solves() ? template.ground : contacts;
	usz slots = feet_spec.feet.len > 0 ? feet_spec.feet.len : 1;

	Vec3[] tracked = alloc::new_array(allocator, Vec3, (sz)(joints * out.samples));
	bool[] planted = alloc::new_array(allocator, bool, (sz)(slots * out.samples));
	usz[] feet = alloc::new_array(allocator, usz, (sz)slots);
	usz[] feet_entry = alloc::new_array(allocator, usz, (sz)slots);
	defer
	{
		alloc::free(allocator, tracked);
		alloc::free(allocator, planted);
		alloc::free(allocator, feet);
		alloc::free(allocator, feet_entry);
	}

	usz foot_count = ground_joints(skeleton, names, feet_spec, feet, feet_entry);

	// Where each foot's worst slide landed, filled by measure_contact — the worst
	// departure per foot and the sample it happened at, so the aggregate slide can
	// be localized to a foot and a phase.
	float[] foot_slide_worst = alloc::new_array(allocator, float, (sz)slots);
	usz[] foot_slide_sample = alloc::new_array(allocator, usz, (sz)slots);

	// Joint-limit saturation needs the rotation-limit tables, so it runs only when a
	// document and its dot ids are given. The frame is rest data — independent of
	// the pose — so it is derived once per joint here and reused every sample. The
	// worst exceedance per bone-local axis, and the phase it happened at, are kept.
	bool check_limits = doc != null && dot_ids.len >= joints;
	JointLimitFrame[] limit_frame = alloc::new_array(allocator, JointLimitFrame, (sz)joints);
	JointRotationLimits[] limit_table = alloc::new_array(allocator, JointRotationLimits, (sz)joints);
	bool[] limit_active = alloc::new_array(allocator, bool, (sz)joints);
	float[] limit_worst = alloc::new_array(allocator, float, (sz)(joints * 3));
	float[] limit_phase = alloc::new_array(allocator, float, (sz)(joints * 3));
	defer
	{
		alloc::free(allocator, foot_slide_worst);
		alloc::free(allocator, foot_slide_sample);
		alloc::free(allocator, limit_frame);
		alloc::free(allocator, limit_table);
		alloc::free(allocator, limit_active);
		alloc::free(allocator, limit_worst);
		alloc::free(allocator, limit_phase);
	}
	if (check_limits)
	{
		for (usz j = 0; j < joints; j++)
		{
			JointRotationLimits limits = doc.rotation_limits_of(dot_ids[j]);
			limit_table[j] = limits;
			if (!limits.constrained) continue;
			JointLimitFrame frame = joint_limit_frame(skeleton, dot_ids, limits);
			if (!frame.usable()) continue;
			limit_frame[j] = frame;
			limit_active[j] = true;
		}
	}

	// The deepest a joint ever sank below the floor, and where — the aggregate
	// floor_penetration, localized.
	float worst_sink = 0.0f;
	usz worst_sink_joint = 0;
	float worst_sink_phase = 0.0f;

	float low_root = 0;
	float high_root = 0;

	for (usz s = 0; s < out.samples; s++)
	{
		// A cycle stops short of its own end, since phase 1 is phase 0 again and
		// sampling both would weight one instant twice. A clip that does not loop
		// includes its last instant, which is a pose in its own right — and on a
		// one-shot it is usually the pose the whole clip was for.
		float phase = template.loop
			? (float)s / (float)out.samples
			: (float)s / (float)(out.samples - 1);

		rig::Pose pose = template.pose(allocator, skeleton, names, phase * template.duration);
		defer pose.free(allocator);

		Matrix4f[]? built = rig::joint_palette(allocator, skeleton, pose);
		if (catch built) continue;
		Matrix4f[] palette = built;
		defer alloc::free(allocator, palette);

		for (usz j = 0; j < joints; j++)
		{
			Vec3 at = skeleton.joints[j].transform(palette[j]);
			tracked[j * out.samples + s] = at;

			// A joint that rests below the floor (a toe tip modelled under the
			// sole) is measured from its own rest height, so only what it sinks
			// beyond that counts.
			float sunk = math::min(out.floor, skeleton.joints[j].y) - at.y;
			if (sunk > out.floor_penetration) out.floor_penetration = sunk;
			if (sunk > worst_sink)
			{
				worst_sink = sunk;
				worst_sink_joint = j;
				worst_sink_phase = phase;
			}

			if (s == 0 || at.y < out.joints[j].low) out.joints[j].low = at.y;
			if (s == 0 || at.y > out.joints[j].high) out.joints[j].high = at.y;

			// How far this joint's animated rotation asks to go past its limits here,
			// per bone-local axis — an allowed axis past its range, a locked one off
			// its angle. The same swing-twist reading and the same nearest end round
			// the circle the clamp uses, so what is measured is exactly what playback
			// would remove.
			if (check_limits && limit_active[j])
			{
				Vec3 angles = joint_angles_from_rotation(limit_frame[j], pose.rotations[j]);
				for (usz i = 0; i < 3; i++)
				{
					float over = limit_table[j].axes[i].overshoot(angles[i]);
					usz slot = j * 3 + i;
					if (over > limit_worst[slot])
					{
						limit_worst[slot] = over;
						limit_phase[slot] = phase;
					}
				}
			}
		}

		float root_y = tracked[root * out.samples + s].y;
		if (s == 0 || root_y < low_root) low_root = root_y;
		if (s == 0 || root_y > high_root) high_root = root_y;

		for (usz f = 0; f < foot_count; f++)
		{
			planted[f * out.samples + s] = feet_spec.feet[feet_entry[f]].planted(phase);
		}

		// The widest the feet ever get apart, horizontally: a stride is a distance
		// along the ground, and the vertical part of it is the bob.
		for (usz a = 0; a < foot_count; a++)
		{
			for (usz b = a + 1; b < foot_count; b++)
			{
				float apart = flat_distance(
					tracked[feet[a] * out.samples + s], tracked[feet[b] * out.samples + s]);
				if (apart > out.stride) out.stride = apart;
			}
		}
	}

	out.root_bob = high_root - low_root;

	measure_contact(&out, tracked, planted, feet[:foot_count], template.duration,
		foot_slide_worst[:foot_count], foot_slide_sample[:foot_count]);

	// Relative to the root, so a clip that travels does not report every joint as
	// having covered the whole distance the figure did.
	for (usz j = 0; j < joints; j++)
	{
		float worst = 0.0f;
		for (usz a = 0; a < out.samples; a++)
		{
			Vec3 from = tracked[j * out.samples + a] - tracked[root * out.samples + a];
			for (usz b = a + 1; b < out.samples; b++)
			{
				Vec3 to = tracked[j * out.samples + b] - tracked[root * out.samples + b];
				float apart = (to - from).length();
				if (apart > worst) worst = apart;
			}
		}
		out.joints[j].travel = worst / height;
		out.joints[j].low /= height;
		out.joints[j].high /= height;
	}

	out.floor_penetration = math::max(out.floor_penetration, 0.0f) / height;
	out.foot_slide /= height;
	out.ground_speed /= height;
	out.stride /= height;
	out.root_bob /= height;

	collect_issues(&out, allocator, tracked, names, foot_slide_worst[:foot_count],
		foot_slide_sample[:foot_count], feet[:foot_count], root, height, template,
		skeleton, feet_spec, feet_entry[:foot_count],
		worst_sink, worst_sink_joint, worst_sink_phase,
		check_limits, limit_active, limit_worst, limit_phase);
	return out;
}

// Gather the localized faults into `out.issues`: a foot that slid, the joint that
// sank deepest, each limit an animated rotation ran past, and — on a looping clip
// — the joint whose position or velocity jumps hardest across the seam. Kept worst
// per foot, per (joint, axis), and per loop kind, so the list stays an edit list.
fn void collect_issues(
	ClipMetrics* out,
	Allocator allocator,
	Vec3[] tracked,
	String[] names,
	float[] foot_slide_worst,
	usz[] foot_slide_sample,
	usz[] feet,
	usz root,
	float height,
	AnimTemplate template,
	rig::Skeleton* skeleton,
	AnimGround feet_spec,
	usz[] feet_entry,
	float worst_sink,
	usz worst_sink_joint,
	float worst_sink_phase,
	bool check_limits,
	bool[] limit_active,
	float[] limit_worst,
	float[] limit_phase) @local
{
	usz joints = out.joints.len;
	usz samples = out.samples;
	ClipIssue[ISSUE_MOST] scratch;
	usz count = 0;

	// A foot whose slide, localized to its own worst sample, clears the tolerance.
	foreach (usz f, joint : feet)
	{
		if (count >= ISSUE_MOST) break;
		float slide = foot_slide_worst[f] / height;
		if (slide <= ISSUE_SLIDE_TOLERANCE) continue;
		scratch[count++] = {
			.kind = FOOT_SLIDE,
			.joint = joint < names.len ? names[joint] : "",
			.phase = samples > 0 ? (float)foot_slide_sample[f] / (float)samples : 0.0f,
			.magnitude = slide,
			.axis = -1,
		};
	}

	// The deepest sink, as one issue at the joint and phase it happened.
	if (count < ISSUE_MOST && worst_sink / height > ISSUE_PENETRATION_TOLERANCE)
	{
		scratch[count++] = {
			.kind = FLOOR_PENETRATION,
			.joint = worst_sink_joint < names.len ? names[worst_sink_joint] : "",
			.phase = worst_sink_phase,
			.magnitude = worst_sink / height,
			.axis = -1,
		};
	}

	// Every bone-local axis an animated rotation ran past its table on, worst first
	// held per axis already.
	if (check_limits)
	{
		for (usz j = 0; j < joints && count < ISSUE_MOST; j++)
		{
			if (!limit_active[j]) continue;
			for (usz i = 0; i < 3 && count < ISSUE_MOST; i++)
			{
				usz slot = j * 3 + i;
				if (limit_worst[slot] <= ISSUE_LIMIT_TOLERANCE) continue;
				scratch[count++] = {
					.kind = LIMIT_SATURATION,
					.joint = j < names.len ? names[j] : "",
					.phase = limit_phase[slot],
					.magnitude = limit_worst[slot],
					.axis = (int)i,
				};
			}
		}
	}

	// The loop seam, on a looping clip with room for the four-point stencil the
	// finite differences need. Positions are made horizontally root-relative first,
	// which is what "account for intended root travel" means: the root's forward
	// carry across the seam is removed, its vertical bob and every limb kept.
	if (template.loop && samples >= 4 && template.duration > 0.0f && count + 2 <= ISSUE_MOST)
	{
		float step_time = template.duration / (float)samples;
		float worst_pos = 0.0f;
		usz worst_pos_joint = 0;
		float worst_vel = 0.0f;
		usz worst_vel_joint = 0;
		for (usz j = 0; j < joints; j++)
		{
			Vec3 n2 = seam_relative(tracked, samples, j, root, samples - 2);
			Vec3 n1 = seam_relative(tracked, samples, j, root, samples - 1);
			Vec3 z0 = seam_relative(tracked, samples, j, root, 0);
			Vec3 z1 = seam_relative(tracked, samples, j, root, 1);
			Vec3 incoming = n1 - n2;
			Vec3 outgoing = z1 - z0;
			Vec3 across = z0 - n1;
			float position_gap = (across - (incoming + outgoing) * 0.5f).length() / height;
			float velocity_gap = (outgoing - incoming).length() / (step_time * height);
			if (position_gap > worst_pos) { worst_pos = position_gap; worst_pos_joint = j; }
			// A foot touching down or lifting at the seam is an impulse, not a fault:
			// the contact joint and what hangs off it (the toes) are let off.
			if (velocity_gap > worst_vel && !seam_contact_impulse(skeleton, feet_spec, feet, feet_entry, j, samples)) { worst_vel = velocity_gap; worst_vel_joint = j; }
		}
		if (worst_pos > ISSUE_LOOP_POSITION_TOLERANCE)
		{
			scratch[count++] = {
				.kind = LOOP_POSITION,
				.joint = worst_pos_joint < names.len ? names[worst_pos_joint] : "",
				.phase = 0.0f,
				.magnitude = worst_pos,
				.axis = -1,
			};
		}
		if (worst_vel > ISSUE_LOOP_VELOCITY_TOLERANCE)
		{
			scratch[count++] = {
				.kind = LOOP_VELOCITY,
				.joint = worst_vel_joint < names.len ? names[worst_vel_joint] : "",
				.phase = 0.0f,
				.magnitude = worst_vel,
				.axis = -1,
			};
		}
	}

	if (count == 0) return;
	out.issues = alloc::new_array(allocator, ClipIssue, (sz)count);
	out.issues[:count] = scratch[:count];
}

<*
 Whether joint `j` is a ground contact joint, or hangs below one, whose down or up
 edge sits at the loop seam (phase 0) to within one sample.

 A planted foot meeting the floor stops dead: its velocity across that instant is
 the contact itself, which the seam-velocity check would otherwise report as a
 discontinuity in every walk cycle cut at a footfall.
*>
fn bool seam_contact_impulse(rig::Skeleton* skeleton, AnimGround spec, usz[] feet, usz[] feet_entry, usz j, usz samples) @local
{
	float one_sample = 1.0f / (float)samples;
	foreach (usz f, foot : feet)
	{
		// The joint itself or any ancestor of it being this foot.
		bool below = false;
		sz walk = (sz)j;
		for (usz guard = 0; walk >= 0 && guard <= skeleton.len(); guard++)
		{
			if ((usz)walk == foot) { below = true; break; }
			walk = skeleton.parents[(usz)walk];
		}
		if (!below) continue;

		AnimFoot window = spec.feet[feet_entry[f]];
		float down = math::min(window.down, 1.0f - window.down);
		float up = math::min(window.up, 1.0f - window.up);
		if (down <= one_sample + 1.0e-6f || up <= one_sample + 1.0e-6f) return true;
	}
	return false;
}

// One joint's world position at a sample, with the root's horizontal carry taken
// out so a travelling cycle's intended motion does not read as a loop fault. The
// root's own vertical bob survives, since only x and z are subtracted.
fn Vec3 seam_relative(Vec3[] tracked, usz samples, usz joint, usz root, usz s) @local
{
	Vec3 at = tracked[joint * samples + s];
	Vec3 base = tracked[root * samples + s];
	return { at.x - base.x, at.y, at.z - base.z };
}

// Distance ignoring height — what a stride and a slide are both measured along.
fn float flat_distance(Vec3 a, Vec3 b) @local
{
	float dx = a.x - b.x;
	float dz = a.z - b.z;
	return math::sqrt(dx * dx + dz * dz);
}

<*
 What the planted feet did, as slide and as ground speed.

 **A planted foot is supposed to move.** In an in-place cycle — which is what a
 locomotion clip is, and what every clip authored here has been — the figure
 stays put and the world goes by underneath, so the stance foot travels backward
 by a whole stride while it is down. Measuring its raw travel would report a
 correct run cycle as sliding by the length of its own stride, which is both the
 largest number in the answer and completely meaningless.

 What skating actually is, is the foot moving at a rate that *changes*: sticking,
 then catching up. So the foot's horizontal track over each contact window is
 fitted with a straight line at constant speed, and the slide is the worst
 departure from it. A foot planted in world space fits a line of zero speed and
 reports zero; a foot carried backward at a steady rate fits a line of that rate
 and also reports zero; a foot that stalls and lurches reports the lurch.

 The fitted rate is worth keeping in its own right. `ground_speed` is how fast
 the figure has to travel for this cycle not to skate — the number that drives
 root motion in an engine, and one an author has no other way to get.
*>
fn void measure_contact(
	ClipMetrics* out,
	Vec3[] tracked,
	bool[] planted,
	usz[] feet,
	float duration,
	float[] foot_worst,
	usz[] foot_sample) @local
{
	usz samples = out.samples;
	if (samples < 3 || duration <= 0.0f) return;

	float step = duration / (float)samples;
	usz longest = 0;

	foreach (usz f, joint : feet)
	{
		for (usz start = 0; start < samples; start++)
		{
			// Runs are found by their leading edge, and the cycle wraps — so the
			// window that straddles the loop point is one run rather than two, which
			// is the window one foot of a symmetric gait always has.
			usz before = (start + samples - 1) % samples;
			if (!planted[f * samples + start]) continue;
			if (planted[f * samples + before] && !all_planted(planted, f, samples)) continue;

			usz length = 0;
			while (length < samples && planted[f * samples + (start + length) % samples]) length++;
			if (length < 3) break;

			// Least squares through the run: x and z each against elapsed time. The
			// times are the run's own, starting at zero, so the fit does not have to
			// carry the wrap in its intercept.
			float sum_t = 0.0f;
			float sum_tt = 0.0f;
			float sum_x = 0.0f;
			float sum_tx = 0.0f;
			float sum_z = 0.0f;
			float sum_tz = 0.0f;
			for (usz k = 0; k < length; k++)
			{
				Vec3 at = tracked[joint * samples + (start + k) % samples];
				float t = (float)k * step;
				sum_t += t;
				sum_tt += t * t;
				sum_x += at.x;
				sum_tx += t * at.x;
				sum_z += at.z;
				sum_tz += t * at.z;
			}

			float n = (float)length;
			float spread = n * sum_tt - sum_t * sum_t;
			if (spread <= 0.0f) break;

			float rate_x = (n * sum_tx - sum_t * sum_x) / spread;
			float rate_z = (n * sum_tz - sum_t * sum_z) / spread;
			float base_x = (sum_x - rate_x * sum_t) / n;
			float base_z = (sum_z - rate_z * sum_t) / n;

			for (usz k = 0; k < length; k++)
			{
				Vec3 at = tracked[joint * samples + (start + k) % samples];
				float t = (float)k * step;
				float off_x = at.x - (base_x + rate_x * t);
				float off_z = at.z - (base_z + rate_z * t);
				float away = math::sqrt(off_x * off_x + off_z * off_z);
				if (away > out.foot_slide) out.foot_slide = away;
				// This foot's own worst departure and where it fell, so the slide can
				// be named to a foot and a phase, not only summed.
				if (f < foot_worst.len && away > foot_worst[f])
				{
					foot_worst[f] = away;
					foot_sample[f] = (start + k) % samples;
				}
			}

			// The longest contact is the one the speed is read off: a brief one is
			// mostly the fit's own noise, and a gait's feet agree about the ground.
			if (length > longest)
			{
				longest = length;
				out.ground_speed = math::sqrt(rate_x * rate_x + rate_z * rate_z);
				out.ground_velocity = { rate_x, 0, rate_z };
			}
			break;
		}
	}
}

// Whether a foot is down for the whole cycle, which has no leading edge to find
// a run by — a still stance, or a clip whose author never lifted it.
fn bool all_planted(bool[] planted, usz foot, usz samples) @local
{
	for (usz s = 0; s < samples; s++)
	{
		if (!planted[foot * samples + s]) return false;
	}
	return true;
}

<*
 The height a clip's feet rest on: the spec's own floor, the lowest contact
 joint's rest height, or — with no spec at all — the lowest joint in the rig.

 The last case is what lets a clip that never declared a foot still be told it is
 sinking.
*>
fn float ground_floor(rig::Skeleton* skeleton, String[] names, AnimGround ground) @local
{
	if (ground.floor_set) return ground.floor;

	float floor = 0.0f;
	bool found = false;
	foreach (usz j, joint : skeleton.joints)
	{
		String name = j < names.len ? names[j] : "";
		bool contact = false;
		foreach (foot : ground.feet)
		{
			if (!foot.off_floor && foot.joint == name) contact = true;
		}
		if (!contact) continue;
		if (!found || joint.y < floor) floor = joint.y;
		found = true;
	}
	if (found) return floor;
	// No floor contact: the lowest joint the rig rests on.
	foreach (joint : skeleton.joints)
	{
		if (!found || joint.y < floor) floor = joint.y;
		found = true;
	}
	return floor;
}

// Which joints the ground spec's feet resolve to, in the spec's own order.
// Feet naming nothing on this rig are dropped, so `into` may come back shorter.
fn usz ground_joints(rig::Skeleton* skeleton, String[] names, AnimGround ground, usz[] into, usz[] entry) @local
{
	usz found = 0;
	foreach (usz f, foot : ground.feet)
	{
		foreach (usz j, name : names)
		{
			if (name != foot.joint || j >= skeleton.len()) continue;
			entry[found] = f;
			into[found++] = j;
			break;
		}
	}
	return found;
}
