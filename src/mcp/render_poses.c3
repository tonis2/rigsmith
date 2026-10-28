<*
 render_poses: the character drawn in poses it can take, for training a joint
 finder on it (llm-runner's creature plugin, POST /train).

 Every pose stays inside the rig's own rotation limits. A limited joint's swing
 and twist are each drawn uniformly in their ranges, then pulled toward rest by
 a share the pose picks, so calm poses come up as well as extreme ones. A joint
 with no limits turns at random by up to `spread` degrees. The root turns about
 the vertical by up to `heading` and tips by up to `tilt`.

 With `clips`, a share of the poses (`clip_share`) are frames of clips the rig
 plays instead, each joint nudged by up to `clip_noise` degrees inside its
 limits and the root turned as a random pose's is: the finder sees mostly
 poses a body takes, and the far reaches of the limits as well.

 Each pose is photographed from every camera in `cameras`: yaw and pitch
 against the way the rig faces, each jittered, zoomed so the box round the
 joints fills a random share of the picture. `blur` of them are motion-blurred: the
 average of four sub-frames on the way to another pose.

 Each picture has its own light, `light_jitter` of the way from the scene's:
 the sun from anywhere above, brighter or dimmer, warmer or cooler, the shadowed
 side lifted more or less.

 The pictures are RGBA PNGs with the background left transparent, so the
 trainer can lay its own behind them. Each is drawn twice, over black and over
 white, and the alpha is where the two differ: the readback has none of its
 own. Nothing else reaches them — no interface, floor, rig overlay or gizmo.

 One call draws `count` poses from index `first`, and the same seed and index
 always draw the same picture. A big set is therefore drawn a few hundred at a
 time (the window stands still for a call) and can be extended later. Beside
 the pictures goes poses_<first>.json:
 - the joints and their parents, and the cameras;
 - per picture, each joint's pixel (x, y from the top left), its depth along
   the camera's view, and whether it is in sight: inside the picture with no
   part of the body in front of it;
 - per pose, every joint's turn against its parent.

 `landmarks: "auto"` follows points on the surface as well, where the joints
 alone do not show how the body turns: the front and back of the root, of the
 joint the shoulders branch from and of the head, each heel. Not the head's
 two sides: each is the other's mirror image, and a finder takes one for the
 other. Each is a vertex of the mesh, skinned as the GPU skins it; the set
 lists them (the joint each rides, its offset from it at rest) and each
 picture their pixels, depths and whether they are in sight.

 `motion` draws an exam instead: one smooth movement inside the limits, frame
 `first` onward at `fps`, from cameras held still. A finder's answer on it can
 be fitted and checked against the turns that made it. With `clip` the movement
 is a clip from the library played on the rig, as the player shows it (inside
 the limits, on the floor), walking on the spot unless `travel` is asked for: a
 walk the way a video shows one.

 The user's document is never written: the pose goes straight into the
 palette, and the palette, the floor setting and the target size are put back
 before the call answers.
*>
module crig;

import cui;
import image;
import image::png;
import rig;
import three;
import std::collections::list;
import std::collections::object;
import std::io::file;
import std::io::path;
import std::math;
import std::math::quaternion;
import std::time;

faultdef RENDER_POSES_REFUSED;

// Poses one call may draw, and cameras it may draw them from.
const usz POSES_MOST = 1000;
const usz POSES_CAMERAS = 8;
// Sub-frames a blurred picture averages.
const usz BLUR_FRAMES = 4;
// Clips one call may draw poses from, and points on the surface it may follow.
const usz POSES_CLIPS = 32;
const usz POSES_LANDMARKS = 24;
// How far from rest a limited axis is drawn at most, whatever its row allows:
// about 150 degrees, so a row left at a whole turn does not fold the body.
const float LIMIT_REACH = 2.6f;

const String RENDER_POSES_SCHEMA = `{"type":"object","properties":{
	"out":{"type":"string","description":"The folder the pictures and poses_<first>.json go in; made when missing."},
	"count":{"type":"integer","description":"Poses (or motion frames) this call draws. Default 100, at most 1000."},
	"first":{"type":"integer","description":"The index of the first. The same seed and index always draw the same picture, so a set is drawn in calls of a few hundred. Default 0."},
	"seed":{"type":"integer","description":"Default 1."},
	"size":{"type":"integer","description":"The pictures' side in pixels, a multiple of 16 from 64 to 1024. Default 448."},
	"cameras":{"type":"array","items":{"type":"object","properties":{
		"name":{"type":"string","description":"Part of each picture's file name."},
		"yaw":{"type":"number","description":"Degrees about +Y from in front of the rig: 0 looks at its face, 90 at its left side."},
		"pitch":{"type":"number","description":"Degrees above the horizon. Default 8."},
		"distance":{"type":"number","description":"How far away the camera stands, in rig sizes (the rest mesh's bounding radius). The picture is zoomed to the framing, so this sets only how strong the perspective is. Default 4."},
		"yaw_jitter":{"type":"number","description":"Up to this many degrees either way, per picture (per call with motion). Default 15."},
		"pitch_jitter":{"type":"number","description":"Default 8."}},"required":["name","yaw"]},
		"description":"Default a front camera (yaw 0) and a side one (yaw 90), both 8 degrees up: the two views of a two-camera video."},
	"fill":{"type":"array","items":{"type":"number"},"description":"[least, most]: the share of the picture the box round the joints takes, along its longer side. Default [0.45, 0.75]: the mesh reaches past its joints."},
	"shift":{"type":"number","description":"The framing's centre moves up to this share of the picture either way. Default 0.08."},
	"spread":{"type":"number","description":"Degrees a joint without limits turns at most. Default 20."},
	"heading":{"type":"number","description":"Degrees the root turns about the vertical at most, either way. Default 30."},
	"tilt":{"type":"number","description":"Degrees the root tips at most. Default 10."},
	"blur":{"type":"number","description":"The share of pictures motion-blurred; with motion, the shutter as a share of a frame. Default 0.3."},
	"motion":{"type":"boolean","description":"Draw an exam: one smooth movement inside the limits, a frame per index, the cameras held still. Default false."},
	"clip":{"type":"string","description":"Draw an exam of this library clip (as list_clips names it) instead of a made-up movement; implies motion."},
	"clip_start":{"type":"number","description":"Seconds into the clip frame 0 shows. Default 0."},
	"clip_speed":{"type":"number","description":"Clip seconds per exam second. Default 1."},
	"travel":{"type":"boolean","description":"Keep the clip's travel across the floor; without it the clip walks on the spot, as a camera that follows it sees. Default false."},
	"fps":{"type":"number","description":"The motion's frame rate. Default 24."},
	"clips":{"description":"Clips (names as get_scene lists them, or \"all\" for every clip that plays on the rig) a share of the random poses are drawn from, each nudged."},
	"clip_share":{"type":"number","description":"The share of random poses drawn from clips. Default 0.5."},
	"clip_noise":{"type":"number","description":"Degrees each joint of a clip's pose is nudged at most, inside its limits. Default 12."},
	"light_jitter":{"type":"number","description":"How far each picture's light strays from the scene's, 0 to 1. Default 1."},
	"landmarks":{"type":"string","description":"\"auto\": follow points on the surface (the front and back of the head, chest and root, the heels) as well as the joints. Default none."}
},"required":["out"]}`;

struct PoseCamera
{
	String name;
	float yaw;
	float pitch;
	float distance;
	float yaw_jitter;
	float pitch_jitter;
}

// What a call was asked for; `pose_shoot_defaults` has a call's defaults.
struct PoseShoot
{
	String out;
	usz count;
	usz first;
	ulong seed;
	uint size;
	PoseCamera[POSES_CAMERAS] cameras;
	usz camera_count;
	float fill_least;
	float fill_most;
	float shift;
	float spread;
	float heading;
	float tilt;
	float blur;
	bool motion;
	float fps;
	// The exam's clip, when it plays one; empty for the made-up movement.
	String clip;
	float clip_start;
	float clip_speed;
	bool travel;
	// Clips the random poses are drawn from (a share of them, each nudged);
	// `all_clips` for every clip that plays on the rig.
	String[POSES_CLIPS] clips;
	usz clip_count;
	bool all_clips;
	float clip_share;
	float clip_noise;
	// How far each picture's light strays from the scene's, 0 to 1.
	float light_jitter;
	// Follow points on the surface as well as the joints.
	bool landmarks;
}

// The settings a call with nothing but `out` draws with.
fn PoseShoot pose_shoot_defaults()
{
	PoseShoot shoot = {
		.count = 100, .seed = 1, .size = 448, .camera_count = 2,
		.fill_least = 0.45f, .fill_most = 0.75f, .shift = 0.08f,
		.spread = 20, .heading = 30, .tilt = 10, .blur = 0.3f, .fps = 24, .clip_speed = 1,
		.clip_share = 0.5f, .clip_noise = 12, .light_jitter = 1,
	};
	shoot.cameras[0] = { .name = "front", .yaw = 0, .pitch = 8, .distance = 4, .yaw_jitter = 15, .pitch_jitter = 8 };
	shoot.cameras[1] = { .name = "side", .yaw = 90, .pitch = 8, .distance = 4, .yaw_jitter = 15, .pitch_jitter = 8 };
	return shoot;
}

// ============================================================================
// Random numbers: splitmix64, one stream per (seed, index, purpose), so a
// picture is the same whichever call draws it.
// ============================================================================

struct PoseDraw
{
	ulong state;
}

fn PoseDraw pose_draw(ulong seed, ulong index, ulong purpose) @local
{
	PoseDraw draw = { .state = seed * 0x9e3779b97f4a7c15UL ^ (index + 1) * 0xbf58476d1ce4e5b9UL ^ (purpose + 1) * 0x94d049bb133111ebUL };
	draw.next();
	return draw;
}

fn ulong PoseDraw.next(&self)
{
	self.state += 0x9e3779b97f4a7c15UL;
	ulong z = self.state;
	z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9UL;
	z = (z ^ (z >> 27)) * 0x94d049bb133111ebUL;
	return z ^ (z >> 31);
}

// In [0, 1).
fn float PoseDraw.unit(&self) => (float)((double)(self.next() >> 11) / 9007199254740992.0);

fn float PoseDraw.between(&self, float least, float most) => least + (most - least) * self.unit();

// A direction uniform on the sphere.
fn Vec3 PoseDraw.direction(&self)
{
	float z = self.between(-1.0f, 1.0f);
	float around = self.between(0.0f, (float)math::TAU);
	float across = (float)math::sqrt(math::max(0.0f, 1.0f - z * z));
	return { across * (float)math::cos(around), across * (float)math::sin(around), z };
}

// Purposes, each its own stream.
const ulong DRAW_POSE = 0;
const ulong DRAW_BLUR = 1;
const ulong DRAW_CAMERA = 2;
const ulong DRAW_MOTION = 3;
const ulong DRAW_SOURCE = 4;
const ulong DRAW_NUDGE = 5;
const ulong DRAW_LIGHT = 6;

// ============================================================================
// Poses
// ============================================================================

<*
 A limited joint's row read as the range a draw spans: its own, cut to
 LIMIT_REACH from rest, and rest itself held inside it.
*>
fn void drawn_range(JointAxisLimit row, float* least, float* most, float* rest) @local
{
	*least = math::max(row.minimum, -LIMIT_REACH);
	*most = math::min(row.maximum, LIMIT_REACH);
	if (*most < *least)
	{
		*least = row.minimum;
		*most = row.maximum;
	}
	*rest = math::clamp(0.0f, *least, *most);
}

<*
 Joint `joint`'s turn in a random pose: inside its limits when it has them,
 `spread` radians at most when it has none. `calm` in [0, 1] pulls a limited
 draw back toward rest.
*>
fn Quaternionf random_turn(RigDocument* doc, rig::Skeleton* skeleton, uint[] dot_ids, usz joint, PoseDraw* draw, float spread, float calm) @local
{
	JointRotationLimits limits = doc.rotation_limits_of(dot_ids[joint]);
	JointLimitFrame frame;
	if (limits.constrained) frame = joint_limit_frame(skeleton, dot_ids, limits);
	if (!limits.constrained || !frame.usable())
	{
		Vec3 axis = draw.direction();
		return quaternion::from_axis_angle{float}(axis, draw.between(0.0f, spread));
	}
	Vec3 angles;
	for (usz axis = 0; axis < 3; axis++)
	{
		JointAxisLimit row = limits.axes[axis];
		if (!row.allowed)
		{
			angles[axis] = row.locked;
			continue;
		}
		float least, most, rest;
		drawn_range(row, &least, &most, &rest);
		angles[axis] = rest + (draw.between(least, most) - rest) * (1.0f - calm);
	}
	return rotation_from_joint_angles(frame, angles);
}

// The root's turn: about the vertical, then tipped.
fn Quaternionf root_turn(float heading, float tilt_axis, float tilt) @local
{
	Quaternionf turn = quaternion::from_axis_angle{float}({ 0, 1, 0 }, heading);
	Vec3 across = { (float)math::cos(tilt_axis), 0, (float)math::sin(tilt_axis) };
	return quaternion::from_axis_angle{float}(across, tilt).mul(turn).normalize();
}

<*
 Pose `index` of a random set: every joint drawn on its own, the root turned,
 the whole pose pulled toward rest by one share. The caller frees it.

 @param dot_ids : `The dot each joint was built from, for its limits.`
*>
fn rig::Pose random_pose(RigDocument* doc, rig::Skeleton* skeleton, uint[] dot_ids, PoseShoot* shoot, ulong index, ulong purpose)
{
	usz count = skeleton.len();
	rig::Pose pose = rig::rest_pose(mem, count);
	PoseDraw draw = pose_draw(shoot.seed, index, purpose);
	// How far toward the ends of their ranges this pose's joints may reach: the
	// square root of a uniform draw, so most reach far (one pose in nine stays
	// within a third of the way); the calm poses come from clips (`clips`).
	float wild = draw.unit();
	float calm = 1.0f - math::sqrt(wild);
	for (usz joint = 0; joint < count; joint++)
	{
		if (skeleton.parents[joint] < 0)
		{
			float heading = math::deg_to_rad(shoot.heading);
			pose.rotations[joint] = root_turn(
				draw.between(-heading, heading),
				draw.between(0.0f, (float)math::TAU),
				draw.between(0.0f, math::deg_to_rad(shoot.tilt)));
			continue;
		}
		pose.rotations[joint] = random_turn(doc, skeleton, dot_ids, joint, &draw, math::deg_to_rad(shoot.spread) * (1.0f - 0.5f * calm), calm);
	}
	return pose;
}

<*
 The exam's movement at `seconds`: every axis of every joint a slow sine of its
 own inside its range (the draws are the joint's, so every frame agrees), a
 free joint swinging about an axis of its own, the root turning a little.
*>
fn rig::Pose motion_pose(RigDocument* doc, rig::Skeleton* skeleton, uint[] dot_ids, PoseShoot* shoot, float seconds)
{
	usz count = skeleton.len();
	rig::Pose pose = rig::rest_pose(mem, count);
	float tau = (float)math::TAU;
	for (usz joint = 0; joint < count; joint++)
	{
		PoseDraw draw = pose_draw(shoot.seed, joint, DRAW_MOTION);
		// How much of its range this joint uses, and how fast it moves.
		float reach = draw.between(0.25f, 0.8f);
		if (skeleton.parents[joint] < 0)
		{
			float hz = draw.between(0.1f, 0.3f);
			float phase = draw.between(0.0f, tau);
			float heading = math::deg_to_rad(shoot.heading) * 0.5f * (float)math::sin(tau * hz * seconds + phase);
			pose.rotations[joint] = root_turn(heading, phase, math::deg_to_rad(shoot.tilt) * 0.3f * (float)math::sin(tau * hz * 1.7f * seconds));
			continue;
		}
		JointRotationLimits limits = doc.rotation_limits_of(dot_ids[joint]);
		JointLimitFrame frame;
		if (limits.constrained) frame = joint_limit_frame(skeleton, dot_ids, limits);
		if (!limits.constrained || !frame.usable())
		{
			Vec3 axis = draw.direction();
			float hz = draw.between(0.3f, 1.2f);
			float phase = draw.between(0.0f, tau);
			float angle = math::deg_to_rad(shoot.spread) * reach * (float)math::sin(tau * hz * seconds + phase);
			pose.rotations[joint] = quaternion::from_axis_angle{float}(axis, angle);
			continue;
		}
		Vec3 angles;
		for (usz axis = 0; axis < 3; axis++)
		{
			JointAxisLimit row = limits.axes[axis];
			float hz = draw.between(0.3f, 1.2f);
			float phase = draw.between(0.0f, tau);
			if (!row.allowed)
			{
				angles[axis] = row.locked;
				continue;
			}
			float least, most, rest;
			drawn_range(row, &least, &most, &rest);
			float middle = (least + most) * 0.5f;
			float centre = rest + (middle - rest) * reach;
			float swing = (most - least) * 0.5f * reach;
			angles[axis] = math::clamp(centre + swing * (float)math::sin(tau * hz * seconds + phase), least, most);
		}
		pose.rotations[joint] = rotation_from_joint_angles(frame, angles);
	}
	return pose;
}

<*
 The exam's pose at `seconds`: the made-up movement, or `shoot.clip` (resolved
 to `ref`) sampled as the player samples it, wrapped round its length, its
 root's slide across the floor taken out unless `travel` is asked for. The
 caller frees it.
*>
fn rig::Pose exam_pose(AppState* app, RigView* view, PoseShoot* shoot, AnimRef ref, float seconds)
{
	if (shoot.clip.len == 0) return motion_pose(&app.doc, &view.skeleton, view.dot_ids, shoot, seconds);
	AnimTemplate* clip = app.clip(ref);
	float time = shoot.clip_start + seconds * shoot.clip_speed;
	if (clip.duration > 0.0f) time -= clip.duration * (float)math::floor(time / clip.duration);
	rig::Pose pose = app.evaluated_clip_pose(mem, view, *clip, ref, time);
	if (!shoot.travel)
	{
		foreach (usz j, parent : view.skeleton.parents)
		{
			if (parent >= 0 || j >= pose.offsets.len) continue;
			pose.offsets[j].x = 0;
			pose.offsets[j].z = 0;
		}
	}
	return pose;
}

// `from` turned `share` of the way to `to`, joint by joint. The caller frees it.
fn rig::Pose between_poses(rig::Pose from, rig::Pose to, float share) @local
{
	rig::Pose out = from.copy(mem);
	foreach (usz i, rotation : from.rotations) out.rotations[i] = rotation.slerp(to.rotations[i], share).normalize();
	return out;
}

<*
 Joint `joint`'s `turn` nudged by up to `noise` radians: each limited axis moved
 inside its range, a joint without limits turned about an axis of its own.
*>
fn Quaternionf nudged_turn(RigDocument* doc, rig::Skeleton* skeleton, uint[] dot_ids, usz joint, Quaternionf turn, PoseDraw* draw, float noise) @local
{
	JointRotationLimits limits = doc.rotation_limits_of(dot_ids[joint]);
	JointLimitFrame frame;
	if (limits.constrained) frame = joint_limit_frame(skeleton, dot_ids, limits);
	if (!limits.constrained || !frame.usable())
	{
		Vec3 axis = draw.direction();
		return quaternion::from_axis_angle{float}(axis, draw.between(-noise, noise)).mul(turn).normalize();
	}
	Vec3 angles = joint_angles_from_rotation(frame, turn);
	for (usz axis = 0; axis < 3; axis++)
	{
		JointAxisLimit row = limits.axes[axis];
		float step = draw.between(-noise, noise);
		if (!row.allowed)
		{
			angles[axis] = row.locked;
			continue;
		}
		float least, most, rest;
		drawn_range(row, &least, &most, &rest);
		angles[axis] = math::clamp(angles[axis] + step, least, most);
	}
	return rotation_from_joint_angles(frame, angles);
}

<*
 Pose `index` drawn from a clip: `ref` at `time` (wrapped round its length) as
 the player samples it, every joint nudged by up to `clip_noise` degrees inside
 its limits, the root turned and tipped as a random pose's is. The nudges are
 the index's own, so the same pose a moment later (a blurred picture's) is
 nudged the same way. The caller frees it.
*>
fn rig::Pose clip_drawn_pose(AppState* app, RigView* view, PoseShoot* shoot, AnimRef ref, ulong index, float time)
{
	AnimTemplate* clip = app.clip(ref);
	if (clip.duration > 0.0f) time -= clip.duration * (float)math::floor(time / clip.duration);
	rig::Pose pose = app.evaluated_clip_pose(mem, view, *clip, ref, time, false);
	PoseDraw draw = pose_draw(shoot.seed, index, DRAW_NUDGE);
	float noise = math::deg_to_rad(shoot.clip_noise);
	foreach (usz joint, parent : view.skeleton.parents)
	{
		if (parent < 0)
		{
			float heading = math::deg_to_rad(shoot.heading);
			Quaternionf turn = root_turn(
				draw.between(-heading, heading),
				draw.between(0.0f, (float)math::TAU),
				draw.between(0.0f, math::deg_to_rad(shoot.tilt)));
			pose.rotations[joint] = turn.mul(pose.rotations[joint]).normalize();
			continue;
		}
		pose.rotations[joint] = nudged_turn(&app.doc, &view.skeleton, view.dot_ids, joint, pose.rotations[joint], &draw, noise);
	}
	return pose;
}

// ============================================================================
// Light
// ============================================================================

<*
 The light for one picture: the sun from anywhere above, brighter or dimmer,
 warmer or cooler, the shadowed side lifted more or less, `light_jitter` of the
 way from `base` (the scene's own). The picture's own stream, so both its mattes
 and every later drawing of it agree.
*>
fn three::Lighting picture_lighting(three::Lighting* base, PoseShoot* shoot, ulong index, usz camera)
{
	PoseDraw draw = pose_draw(shoot.seed, index, DRAW_LIGHT + 16 * (camera + 1));
	three::Lighting lit = *base;
	float share = shoot.light_jitter;
	Vec3 toward = draw.direction();
	toward.y = 0.2f + 0.8f * math::abs(toward.y);
	float intensity = draw.between(0.7f, 1.7f);
	float warmth = draw.between(-1.0f, 1.0f);
	float ambient = draw.between(0.25f, 0.7f);
	float fill = draw.between(0.0f, 0.15f);
	Vec3 white = { 1, 1, 1 };
	Vec3 tint = warmth > 0.0f ? white + (Vec3){ 0.0f, -0.14f, -0.3f } * warmth : white + (Vec3){ -0.25f, -0.14f, 0.0f } * -warmth;

	float[4] was = base.lights[0].direction;
	Vec3 sun = { was[0], was[1], was[2] };
	float length = sun.length();
	sun = length > 1.0e-6f ? sun / length : (Vec3){ 0, 1, 0 };
	Vec3 now = sun + (toward.normalize() - sun) * share;
	now = now.length() > 1.0e-6f ? now.normalize() : sun;
	lit.lights[0].direction = { now.x, now.y, now.z, was[3] };
	float[4] colour = base.lights[0].color;
	for (usz c = 0; c < 3; c++) lit.lights[0].color[c] = colour[c] + (tint[c] * colour[c] - colour[c]) * share;
	lit.lights[0].color[3] = colour[3] * (1.0f + (intensity - 1.0f) * share);
	lit.ambient = base.ambient + (ambient - base.ambient) * share;
	for (usz c = 0; c < 3; c++) lit.world[c] = base.world[c] + (fill - base.world[c]) * share;
	return lit;
}

// ============================================================================
// Points on the surface
// ============================================================================

// A vertex followed as a landmark: the joint it is named for and which way
// from it, and the joint it rides (the one its skin follows) with its offset
// from that joint at rest.
struct PoseLandmark
{
	usz named;
	usz joint;
	usz vertex;
	Vec3 offset;
	String side;
}

// A landmark looked for: on which joint, which way from it, and its name's end.
struct LandmarkWant
{
	usz joint;
	Vec3 toward;
	String side;
}

// The joint weighing most on vertex `v`, or -1 when none weighs over half.
fn int dominant_joint(AppState* app, usz v) @local
{
	usz slots = (usz)app.skin.slots;
	int best = -1;
	float most = 0.5f;
	for (usz s = 0; s < slots; s++)
	{
		float weight = app.skin.weights[v * slots + s];
		if (weight <= most) continue;
		most = weight;
		best = (int)app.skin.joints[v * slots + s];
	}
	return best;
}

<*
 The surface points a call follows, into `into`; how many. On the root, on the
 joint the shoulders branch from (the one on the way from the root to the head
 with the most children) and on the head (the parent of the highest leaf), the
 vertices furthest to the front and the back; under each foot the heel. Not
 the head's sides: a mirror pair on one joint, which a finder confuses. Each is the vertex mostly weighted
 to that joint (or to a leaf below it: a skin may hang the head on its tip)
 lying furthest that way from it at rest, kept when it lies 2% of the rig's
 height out or more, and when no point already kept is within 2%. It rides the
 joint its skin follows. Front is +Z, the way the rig faces.
*>
fn usz pose_landmarks(AppState* app, RigView* view, float height, PoseLandmark[] into)
{
	Vec3[] rest = app.geometry.positions;
	if (app.skin.slots == 0 || app.skin.vertices != rest.len) return 0;
	rig::Skeleton* skeleton = &view.skeleton;
	usz count = skeleton.len();
	int[] children = alloc::new_array(mem, int, (sz)count);
	defer alloc::free(mem, children);
	usz root = 0;
	float lowest = 1.0e30f;
	foreach (usz j, parent : skeleton.parents)
	{
		if (parent < 0)
		{
			root = j;
		}
		else
		{
			children[(usz)parent]++;
		}
		lowest = math::min(lowest, skeleton.joints[j].y);
	}
	usz top = root;
	foreach (usz j, joint : skeleton.joints)
	{
		if (children[j] == 0 && joint.y > skeleton.joints[top].y) top = j;
	}

	LandmarkWant[POSES_LANDMARKS] wants;
	usz wanted = 0;
	Vec3 front = { 0, 0, 1 };
	Vec3 back = { 0, 0, -1 };
	wants[wanted++] = { root, front, "front" };
	wants[wanted++] = { root, back, "back" };
	int head = skeleton.parents[top];
	if (head >= 0 && (usz)head != root)
	{
		int branch = -1;
		for (int j = skeleton.parents[(usz)head]; j >= 0 && (usz)j != root; j = skeleton.parents[(usz)j])
		{
			if (children[(usz)j] >= 3 && (branch < 0 || children[(usz)j] > children[(usz)branch])) branch = j;
		}
		if (branch >= 0)
		{
			wants[wanted++] = { (usz)branch, front, "front" };
			wants[wanted++] = { (usz)branch, back, "back" };
		}
		wants[wanted++] = { (usz)head, front, "front" };
		wants[wanted++] = { (usz)head, back, "back" };
	}

	usz kept = 0;
	float out_least = 0.02f * height;
	for (usz w = 0; w < wanted && kept < into.len; w++)
	{
		LandmarkWant want = wants[w];
		Vec3 at = skeleton.joints[want.joint];
		long best = -1;
		int rider = -1;
		usz carried = 0;
		float furthest = out_least;
		foreach (usz v, p : rest)
		{
			int owner = dominant_joint(app, v);
			if (owner < 0 || (usz)owner >= count) continue;
			if (owner != (int)want.joint && (skeleton.parents[(usz)owner] != (int)want.joint || children[(usz)owner] != 0)) continue;
			carried++;
			float out = (p - at).dot(want.toward);
			if (out <= furthest) continue;
			furthest = out;
			best = (long)v;
			rider = owner;
		}
		// A joint carrying a handful of vertices has no surface of its own.
		if (best < 0 || carried < 20) continue;
		bool near = false;
		for (usz k = 0; k < kept; k++) near = near || (rest[into[k].vertex] - rest[(usz)best]).length() < out_least;
		if (near) continue;
		into[kept++] = {
			.named = want.joint, .joint = (usz)rider, .vertex = (usz)best,
			.offset = rest[(usz)best] - skeleton.joints[(usz)rider], .side = want.side,
		};
	}

	// Under each foot (a low leaf), the heel: of the vertices the leaf, the joint
	// above it and the one above that carry (a toe tip, a toe, an ankle: a skin
	// may hang the foot on any of them), those below the ankle, the one furthest
	// back, kept when it is 1% of the rig's height from the ankle (a heel is a
	// point of its own however little it reaches back).
	float low = lowest + 0.3f * (skeleton.joints[root].y - lowest);
	foreach (usz j, joint : skeleton.joints)
	{
		if (children[j] != 0 || joint.y >= low || kept >= into.len) continue;
		int toe = skeleton.parents[j];
		if (toe < 0 || (usz)toe == root) continue;
		int ankle = skeleton.parents[(usz)toe];
		if (ankle < 0 || (usz)ankle == root) ankle = toe;
		Vec3 at = skeleton.joints[(usz)ankle];
		long best = -1;
		int rider = -1;
		usz carried = 0;
		float furthest = -1.0e30f;
		foreach (usz v, p : rest)
		{
			int owner = dominant_joint(app, v);
			if (owner < 0 || (owner != (int)j && owner != toe && owner != ankle) || p.y > at.y) continue;
			carried++;
			float out = at.z - p.z;
			if (out <= furthest) continue;
			furthest = out;
			best = (long)v;
			rider = owner;
		}
		if (best < 0 || carried < 20 || (rest[(usz)best] - at).length() < 0.01f * height) continue;
		bool near = false;
		for (usz k = 0; k < kept; k++) near = near || (rest[into[k].vertex] - rest[(usz)best]).length() < out_least;
		if (near) continue;
		into[kept++] = {
			.named = (usz)ankle, .joint = (usz)rider, .vertex = (usz)best,
			.offset = rest[(usz)best] - skeleton.joints[(usz)rider], .side = "heel",
		};
	}
	return kept;
}

// ============================================================================
// Pictures
// ============================================================================

<*
 The camera for one picture: `cam`'s angles against the way the rig faces
 (jittered by `draw`), standing `cam.distance` rig sizes away (the rest mesh's
 bounding radius), aimed and zoomed so the box round the joints in `framed`
 (model space) is centred and its longer side fills `fill` of the picture,
 then the aim moved by up to `shift` of it.

 Zoomed rather than moved: moving in on a long animal seen end on blows its
 head up past its body, which no video does. The joints' box and not the
 mesh's, because the box is what a finder sees of its own answer, and it crops
 a video's frames round the joints it found the same way.
*>
fn OrbitCamera pose_camera(AppState* app, PoseCamera cam, PoseDraw* draw, Vec3[] framed, float radius, PoseShoot* shoot) @local
{
	Vec3 origin = app.doc.model_transform.point({ 0, 0, 0 });
	Vec3 ahead = app.doc.model_transform.point({ 0, 0, 1 }) - origin;
	float facing = math::rad_to_deg((float)math::atan2(ahead.x, ahead.z));
	float fill = draw.between(shoot.fill_least, shoot.fill_most);
	OrbitCamera camera = {
		.target = posed_centre(app, framed),
		.yaw = facing + cam.yaw + draw.between(-cam.yaw_jitter, cam.yaw_jitter),
		.pitch = math::clamp(cam.pitch + draw.between(-cam.pitch_jitter, cam.pitch_jitter), -80.0f, 80.0f),
		.fov = 30.0f,
		.distance = radius * cam.distance,
	};
	camera.near_plane = camera.distance * 0.01f;
	camera.far_plane = camera.distance * 10.0f;
	camera.min_distance = camera.near_plane;
	camera.max_distance = camera.far_plane;
	float yaw = math::deg_to_rad(camera.yaw);
	float pitch = math::deg_to_rad(camera.pitch);
	// Right and up as the camera sees them, for moving the aim in the picture.
	Vec3 right = { (float)math::cos(yaw), 0, -(float)math::sin(yaw) };
	Vec3 up = { -(float)math::sin(pitch) * (float)math::sin(yaw), (float)math::cos(pitch), -(float)math::sin(pitch) * (float)math::cos(yaw) };
	float size = (float)shoot.size;
	// Twice: re-aiming moves the box a little in the picture.
	for (int pass = 0; pass < 2; pass++)
	{
		Matrix4f projection = app.model_view_projection(&camera, 1.0f);
		float least_x = 1.0e30f;
		float least_y = 1.0e30f;
		float most_x = -1.0e30f;
		float most_y = -1.0e30f;
		foreach (p : framed)
		{
			Vec4 clip = projection.apply({ p.x, p.y, p.z, 1.0f });
			if (clip.w <= 1.0e-6f) continue;
			float x = (clip.x / clip.w * 0.5f + 0.5f) * size;
			float y = (clip.y / clip.w * 0.5f + 0.5f) * size;
			least_x = math::min(least_x, x);
			most_x = math::max(most_x, x);
			least_y = math::min(least_y, y);
			most_y = math::max(most_y, y);
		}
		if (most_x < least_x) break;
		float spread = (float)math::tan(math::deg_to_rad(camera.fov) * 0.5f);
		float per_pixel = 2.0f * camera.distance * spread / size;
		camera.target = camera.target
			+ right * (((least_x + most_x) * 0.5f - size * 0.5f) * per_pixel)
			- up * (((least_y + most_y) * 0.5f - size * 0.5f) * per_pixel);
		float extent = math::max(math::max(most_x - least_x, most_y - least_y), 1.0f);
		camera.fov = math::clamp(2.0f * math::rad_to_deg((float)math::atan(spread * extent / (fill * size))), 1.0f, 120.0f);
	}
	float seen = 2.0f * camera.distance * (float)math::tan(math::deg_to_rad(camera.fov) * 0.5f);
	camera.target = camera.target
		+ right * (draw.between(-shoot.shift, shoot.shift) * seen)
		+ up * (draw.between(-shoot.shift, shoot.shift) * seen);
	return camera;
}

// Where the posed joints are, in model space. The caller frees it.
fn Vec3[] posed_joints(RigView* view, Matrix4f[] palette) @private
{
	Vec3[] at = alloc::new_array(mem, Vec3, (sz)view.skeleton.len());
	foreach (usz i, joint : view.skeleton.joints) at[i] = joint.transform(palette[i]);
	return at;
}

// The middle of the posed joints' box, in the world.
fn Vec3 posed_centre(AppState* app, Vec3[] at) @local
{
	Vec3 least = at[0];
	Vec3 most = at[0];
	foreach (p : at)
	{
		least = math::min(least, p);
		most = math::max(most, p);
	}
	return app.doc.model_transform.point((least + most) * 0.5f);
}

<*
 Three's camera for an OrbitCamera, as `scene_camera` makes it for the panes.
*>
fn three::Camera pose_scene_camera(OrbitCamera* from)
{
	three::Camera camera = {
		.target = { from.target[0], from.target[1], from.target[2] },
		.distance = from.distance,
		.yaw = from.yaw,
		.pitch = from.pitch,
		.fov = from.fov,
		.near_plane = from.near_plane,
		.far_plane = from.far_plane,
	};
	camera.clamp_angles();
	return camera;
}

<*
 One frame of `pose` from `camera`, over `clear`, with nothing but the scene in
 it: the pose put in the palette, the scene brought up to date, then the view
 set to the whole (square) target and the interface left out of the capture.
*>
fn image::Image? pose_frame(AppState* app, RigView* view, rig::Pose pose, OrbitCamera* camera, float[4] clear) @private
{
	Matrix4f[] palette = rig::joint_palette(mem, &view.skeleton, pose)!;
	Matrix4f[] held = app.pose_palette;
	app.pose_palette = palette;
	app.next_pose_generation();
	defer
	{
		app.pose_palette = held;
		alloc::free(mem, palette);
	}

	sync_scene(app);
	three::MeshPass* pass = stage_pass();
	three::SceneView[] none = { };
	pass.set_extra_views(none);
	pass.follow = {};
	pass.camera = pose_scene_camera(camera);
	pass.view_rect = { 0, 0, 1, 1 };

	three::Renderer* renderer = stage_renderer();
	float[4] was_clear = renderer.clear;
	Ui* ui = renderer.ui.ui;
	renderer.clear = clear;
	renderer.ui.ui = null;
	defer
	{
		renderer.clear = was_clear;
		renderer.ui.ui = ui;
	}
	return renderer.capture();
}

<*
 Premultiplied colour and alpha of one pose, added into `sum` (four floats a
 pixel): the frame over black is the colour times alpha, and white shows
 through it by one minus alpha.
*>
fn void? add_matted(AppState* app, RigView* view, rig::Pose pose, OrbitCamera* camera, float[] sum) @private
{
	image::Image dark = pose_frame(app, view, pose, camera, { 0, 0, 0, 1 })!;
	defer dark.free();
	image::Image light = pose_frame(app, view, pose, camera, { 1, 1, 1, 1 })!;
	defer light.free();
	usz pixels = (usz)dark.width * dark.height;
	for (usz i = 0; i < pixels; i++)
	{
		float through = 0.0f;
		for (usz c = 0; c < 3; c++) through += (float)light.pixels[i * 4 + c] - (float)dark.pixels[i * 4 + c];
		float alpha = math::clamp(1.0f - through / (3.0f * 255.0f), 0.0f, 1.0f);
		for (usz c = 0; c < 3; c++) sum[i * 4 + c] += (float)dark.pixels[i * 4 + c];
		sum[i * 4 + 3] += alpha * 255.0f;
	}
}

<*
 The averaged frames as an RGBA PNG at `path`: colour un-premultiplied, alpha
 kept, `frames` frames in `sum`.
*>
fn void? save_matted(float[] sum, uint size, usz frames, String path) @local
{
	usz pixels = (usz)size * size;
	char[] bytes = alloc::new_array(mem, char, (sz)(pixels * 4));
	defer alloc::free(mem, bytes);
	float scale = 1.0f / (float)frames;
	for (usz i = 0; i < pixels; i++)
	{
		float alpha = sum[i * 4 + 3] * scale;
		for (usz c = 0; c < 3; c++)
		{
			float colour = alpha > 1.0f ? sum[i * 4 + c] * scale * 255.0f / alpha : 0.0f;
			bytes[i * 4 + c] = (char)math::clamp(colour + 0.5f, 0.0f, 255.0f);
		}
		bytes[i * 4 + 3] = (char)math::clamp(alpha + 0.5f, 0.0f, 255.0f);
	}
	image::Image out = { .width = size, .height = size, .bit_depth = 8, .format = image::PixelFormat.RGBA, .pixels = bytes, .allocator = mem };
	png::save_file(&out, path)!;
}

<*
 One point as a picture shows it, appended as [x, y, depth, seen]: its pixel
 from the top left, its depth along the view, and 1 when it is inside the
 picture with no part of the body in front of it. `on_surface` for a point on
 the skin (a landmark), which faces the camera or not, rather than one inside
 the body (a joint), which another part may hide — by the overlay's own rule,
 `rig_point_hidden`, given the joint's thickness and the posed bones.
*>
fn void append_seen_point(DString* out, AppState* app, Matrix4f projection, Vec3 eye, Vec3 p, uint size, bool on_surface,
	float radius = -1.0f, RigBone[] bones = {}, uint dot = 0) @local
{
	Vec4 clip = projection.apply({ p.x, p.y, p.z, 1.0f });
	float w = math::abs(clip.w) < 1.0e-9f ? 1.0e-9f : clip.w;
	float x = (clip.x / w * 0.5f + 0.5f) * (float)size;
	float y = (clip.y / w * 0.5f + 0.5f) * (float)size;
	bool inside = clip.w > 0.0f && x >= 0.0f && y >= 0.0f && x < (float)size && y < (float)size;
	bool seen = inside && !(on_surface ? app.mesh_hidden_surface(eye, p) : app.rig_point_hidden(eye, p, radius, bones, dot));
	out.appendf("[%s,%s,%s,%d]", (JsonFloat)x, (JsonFloat)y, (JsonFloat)clip.w, seen ? 1 : 0);
}

// ============================================================================
// Arguments
// ============================================================================

// A number under `key`, `fallback` when it is missing, refused outside [least, most].
fn bool poses_number(Object* args, String key, double fallback, double least, double most, double* into, DString* detail) @local
{
	*into = fallback;
	Object* value = member(args, key);
	if (value == null) return true;
	double? given = args.get_float(key);
	if (catch given)
	{
		detail.appendf(`render_poses' "%s" must be a number`, key);
		return false;
	}
	if (given < least || given > most)
	{
		detail.appendf(`render_poses' "%s" is %s; it is from %s to %s.`, key, (JsonFloat)given, (JsonFloat)least, (JsonFloat)most);
		return false;
	}
	*into = given;
	return true;
}

fn bool poses_camera_number(Object* entry, String key, float fallback, float* into, DString* detail) @local
{
	*into = fallback;
	Object* value = member(entry, key);
	if (value == null) return true;
	double? given = entry.get_float(key);
	if (catch given)
	{
		detail.appendf(`a camera's "%s" must be a number`, key);
		return false;
	}
	*into = (float)given;
	return true;
}

fn bool read_pose_shoot(Object* args, PoseShoot* shoot, DString* detail) @local
{
	if (!takes_object(args, detail, `render_poses takes an object: {"out": folder, "count": n, "first": n, "cameras": [{"name": "front", "yaw": 0}], ...}`)) return false;
	if (!required_string(args, "out", &shoot.out, detail, `render_poses needs "out": the folder to write the pictures in.`)) return false;
	double v;
	if (!poses_number(args, "count", 100, 1, (double)POSES_MOST, &v, detail)) return false;
	shoot.count = (usz)v;
	if (!poses_number(args, "first", 0, 0, 1.0e9, &v, detail)) return false;
	shoot.first = (usz)v;
	if (!poses_number(args, "seed", 1, 0, 1.0e15, &v, detail)) return false;
	shoot.seed = (ulong)v;
	if (!poses_number(args, "size", 448, 64, 1024, &v, detail)) return false;
	shoot.size = (uint)v;
	if (shoot.size % 16 != 0)
	{
		detail.appendf(`render_poses' "size" is %d; it is a multiple of 16, the backbone's patch.`, shoot.size);
		return false;
	}
	if (!poses_number(args, "shift", 0.08, 0, 0.4, &v, detail)) return false;
	shoot.shift = (float)v;
	if (!poses_number(args, "spread", 20, 0, 180, &v, detail)) return false;
	shoot.spread = (float)v;
	if (!poses_number(args, "heading", 30, 0, 180, &v, detail)) return false;
	shoot.heading = (float)v;
	if (!poses_number(args, "tilt", 10, 0, 90, &v, detail)) return false;
	shoot.tilt = (float)v;
	if (!poses_number(args, "blur", 0.3, 0, 1, &v, detail)) return false;
	shoot.blur = (float)v;
	if (!poses_number(args, "fps", 24, 1, 240, &v, detail)) return false;
	shoot.fps = (float)v;
	shoot.motion = args.get_bool("motion") ?? false;
	if (!poses_number(args, "clip_start", 0, 0, 1.0e6, &v, detail)) return false;
	shoot.clip_start = (float)v;
	if (!poses_number(args, "clip_speed", 1, 0.01, 100, &v, detail)) return false;
	shoot.clip_speed = (float)v;
	shoot.travel = args.get_bool("travel") ?? false;
	shoot.clip = "";
	if (member(args, "clip") != null)
	{
		if (!required_string(args, "clip", &shoot.clip, detail, `render_poses' "clip" is a clip's name, as get_scene lists it`)) return false;
		shoot.motion = true;
	}
	if (!poses_number(args, "clip_share", 0.5, 0, 1, &v, detail)) return false;
	shoot.clip_share = (float)v;
	if (!poses_number(args, "clip_noise", 12, 0, 90, &v, detail)) return false;
	shoot.clip_noise = (float)v;
	if (!poses_number(args, "light_jitter", 1, 0, 1, &v, detail)) return false;
	shoot.light_jitter = (float)v;
	shoot.clip_count = 0;
	shoot.all_clips = false;
	Object* clips = member(args, "clips");
	if (clips != null)
	{
		if (clips.is_string() && clips.s == "all")
		{
			shoot.all_clips = true;
		}
		else if (clips.is_array() && clips.get_len() > 0 && clips.get_len() <= (sz)POSES_CLIPS)
		{
			for (usz i = 0; i < (usz)clips.get_len(); i++)
			{
				String? name = clips.get_string_at((sz)i);
				if (catch name)
				{
					detail.append_string(`render_poses' "clips" lists clips by name`);
					return false;
				}
				shoot.clips[shoot.clip_count++] = name;
			}
		}
		else
		{
			detail.appendf(`render_poses' "clips" is "all" or a list of 1 to %d clip names`, POSES_CLIPS);
			return false;
		}
	}
	shoot.landmarks = false;
	Object* landmarks = member(args, "landmarks");
	if (landmarks != null)
	{
		if (!landmarks.is_string() || (landmarks.s != "auto" && landmarks.s != "none"))
		{
			detail.append_string(`render_poses' "landmarks" is "auto" (or "none")`);
			return false;
		}
		shoot.landmarks = landmarks.s == "auto";
	}

	shoot.fill_least = 0.45f;
	shoot.fill_most = 0.75f;
	Object* fill = member(args, "fill");
	if (fill != null)
	{
		if (!fill.is_array() || fill.get_len() != 2)
		{
			detail.append_string(`render_poses' "fill" is [least, most], two shares of the picture's height`);
			return false;
		}
		double? least = fill.get_float_at(0);
		double? most = fill.get_float_at(1);
		if (catch least, most)
		{
			detail.append_string(`render_poses' "fill" is [least, most], two shares of the picture's height`);
			return false;
		}
		if (!(least > 0.05 && least <= most && most <= 1.5))
		{
			detail.append_string(`render_poses' "fill" wants 0.05 < least <= most <= 1.5`);
			return false;
		}
		shoot.fill_least = (float)least;
		shoot.fill_most = (float)most;
	}

	Object* cameras = member(args, "cameras");
	if (cameras == null)
	{
		shoot.cameras[0] = { .name = "front", .yaw = 0, .pitch = 8, .distance = 4, .yaw_jitter = 15, .pitch_jitter = 8 };
		shoot.cameras[1] = { .name = "side", .yaw = 90, .pitch = 8, .distance = 4, .yaw_jitter = 15, .pitch_jitter = 8 };
		shoot.camera_count = 2;
		return true;
	}
	if (!cameras.is_array() || cameras.get_len() == 0 || cameras.get_len() > (sz)POSES_CAMERAS)
	{
		detail.appendf(`render_poses' "cameras" is a list of 1 to %d cameras, each {"name", "yaw", "pitch"?, "distance"?}`, POSES_CAMERAS);
		return false;
	}
	shoot.camera_count = (usz)cameras.get_len();
	for (usz i = 0; i < shoot.camera_count; i++)
	{
		Object* entry = cameras.get_at((sz)i);
		PoseCamera* cam = &shoot.cameras[i];
		if (!entry.is_keyable() || !required_string(entry, "name", &cam.name, detail, `each camera needs a "name"`)) return false;
		if (member(entry, "yaw") == null)
		{
			detail.appendf(`camera "%s" needs a "yaw": degrees from in front of the rig`, cam.name);
			return false;
		}
		if (!poses_camera_number(entry, "yaw", 0, &cam.yaw, detail)) return false;
		if (!poses_camera_number(entry, "pitch", 8, &cam.pitch, detail)) return false;
		if (!poses_camera_number(entry, "distance", 4, &cam.distance, detail)) return false;
		if (!poses_camera_number(entry, "yaw_jitter", 15, &cam.yaw_jitter, detail)) return false;
		if (!poses_camera_number(entry, "pitch_jitter", 8, &cam.pitch_jitter, detail)) return false;
		if (cam.distance < 1.2f || cam.distance > 100)
		{
			detail.appendf(`camera "%s" stands %s rig sizes away; it is from 1.2 to 100.`, cam.name, (JsonFloat)cam.distance);
			return false;
		}
	}
	return true;
}

// ============================================================================
// The tool
// ============================================================================

fn String? tool_render_poses(Object* args, void* user_data, DString* detail) @private
{
	PoseShoot shoot;
	if (!read_pose_shoot(args, &shoot, detail)) return RENDER_POSES_REFUSED~;
	return ((AppState*)user_data).render_pose_set(&shoot, detail);
}

<*
 The set `given` asks for, drawn and written (the pictures and
 poses_<first>.json), as render_poses draws it: its answer, or a fault with
 why in `detail`. The window stands still while it draws; a set drawn a few
 poses a call (`count`, `first`) lets it repaint between them — the Capture
 pane draws its training set so.
*>
fn String? AppState.render_pose_set(&self, PoseShoot* given, DString* detail)
{
	AppState* app = self;
	PoseShoot shoot = *given;
	if (!hosted() || stage_renderer() == null)
	{
		detail.append_string("there is no renderer: this Rigsmith is running headless.");
		return RENDER_POSES_REFUSED~;
	}
	if (app.doc.dots.len() == 0 || !app.has_mesh())
	{
		detail.append_string("there is nothing to photograph: render_poses needs a rigged mesh.");
		return RENDER_POSES_REFUSED~;
	}
	RigView? opened = app.open_rig(mem);
	if (catch opened)
	{
		detail.append_string("the rig could not be read.");
		return RENDER_POSES_REFUSED~;
	}
	RigView view = opened;
	defer view.free(mem);
	if (!app.rebind_skin(&view))
	{
		detail.append_string("the mesh could not be skinned to the rig.");
		return RENDER_POSES_REFUSED~;
	}
	if (catch path::mkdir(shoot.out, true))
	{
		// Already there, or it cannot be made: the first write says which.
	}
	if (!file::is_dir(shoot.out))
	{
		detail.appendf(`"%s" is not a folder and could not be made.`, shoot.out);
		return RENDER_POSES_REFUSED~;
	}
	AnimRef clip_ref = NO_ANIM;
	if (shoot.clip.len > 0)
	{
		AnimRef? named = resolve_named(app, shoot.clip, detail);
		if (catch named) return RENDER_POSES_REFUSED~;
		clip_ref = named;
		app.ensure_clip_imported(clip_ref);
		AnimTemplate* clip = app.clip(clip_ref);
		if (clip == null || clip.keyframes.len == 0)
		{
			detail.appendf(`clip "%s" has no keys to play.`, shoot.clip);
			return RENDER_POSES_REFUSED~;
		}
	}
	// The clips random poses are drawn from: those named, or every clip that
	// plays on the rig.
	AnimRef[POSES_CLIPS] pose_clips;
	usz pose_clip_count = 0;
	if (shoot.all_clips)
	{
		foreach (usz p, &pack : app.packs)
		{
			foreach (usz c, &clip : pack.clips)
			{
				AnimRef ref = { (int)p, (int)c };
				if (pose_clip_count < POSES_CLIPS && app.clip_applies(ref)) pose_clips[pose_clip_count++] = ref;
			}
		}
	}
	for (usz i = 0; i < shoot.clip_count; i++)
	{
		AnimRef? named = resolve_named(app, shoot.clips[i], detail);
		if (catch named) return RENDER_POSES_REFUSED~;
		pose_clips[pose_clip_count++] = named;
	}
	usz playable = 0;
	for (usz i = 0; i < pose_clip_count; i++)
	{
		app.ensure_clip_imported(pose_clips[i]);
		AnimTemplate* clip = app.clip(pose_clips[i]);
		if (clip != null && clip.keyframes.len > 0 && clip.duration > 0.0f) pose_clips[playable++] = pose_clips[i];
	}
	pose_clip_count = playable;
	if ((shoot.all_clips || shoot.clip_count > 0) && pose_clip_count == 0)
	{
		detail.append_string("none of the clips asked for plays on this rig.");
		return RENDER_POSES_REFUSED~;
	}

	// Everything below changes what the window shows; every way out puts it back.
	three::Renderer* renderer = stage_renderer();
	uint was_width = renderer.target.extent.width;
	uint was_height = renderer.target.extent.height;
	bool was_editing = app.pose_edit_active;
	bool was_floorless = app.config.hide_floor;
	three::MeshPass* pass = stage_pass();
	three::Lighting was_lighting = pass.lighting;
	app.pose_edit_active = true;
	app.config.hide_floor = true;
	defer
	{
		pass.note_lighting_change(was_lighting);
		pass.lighting = was_lighting;
		app.pose_edit_active = was_editing;
		app.config.hide_floor = was_floorless;
		(void)renderer.resize_target(was_width, was_height);
		app.next_pose_generation();
		app.refresh_ui();
	}
	if (catch renderer.resize_target(shoot.size, shoot.size))
	{
		detail.appendf("a %d-pixel target could not be made.", shoot.size);
		return RENDER_POSES_REFUSED~;
	}

	rig::Bounds bounds = app.world_bounds();
	float height = math::max(bounds.max.y - bounds.min.y, 1.0e-4f);
	float radius = math::max((bounds.max - bounds.min).length() * 0.5f, 1.0e-4f);
	usz joints = view.skeleton.len();
	usz pixels = (usz)shoot.size * shoot.size;
	float[] sum = alloc::new_array(mem, float, (sz)(pixels * 4));
	defer alloc::free(mem, sum);

	PoseLandmark[POSES_LANDMARKS] landmarks;
	usz landmark_count = shoot.landmarks ? pose_landmarks(app, &view, height, landmarks[..]) : 0;

	DString labels = dstring::new(mem);
	defer labels.free();
	DString poses = dstring::new(mem);
	defer poses.free();
	usz pictures = 0;
	Clock started = clock::now();

	// What the exam's cameras frame: the rig at rest for the made-up movement, the
	// clip's first frame for a clip (a T-pose's arms would frame a walk too wide).
	Vec3[] exam_framed = view.skeleton.joints;
	Vec3[] clip_framed;
	defer { if (clip_framed.len > 0) alloc::free(mem, clip_framed); }
	if (shoot.clip.len > 0)
	{
		rig::Pose first_pose = exam_pose(app, &view, &shoot, clip_ref, 0.0f);
		defer first_pose.free(mem);
		Matrix4f[]? first_palette = rig::joint_palette(mem, &view.skeleton, first_pose);
		if (catch first_palette)
		{
			detail.append_string("the clip's pose did not fit the rig.");
			return RENDER_POSES_REFUSED~;
		}
		defer alloc::free(mem, first_palette);
		clip_framed = posed_joints(&view, first_palette);
		exam_framed = clip_framed;
	}

	for (usz k = 0; k < shoot.count; k++)
	{
		ulong index = (ulong)(shoot.first + k);
		float seconds = (float)index / shoot.fps;
		// A random pose, or a share of them a clip's frame nudged.
		AnimRef from_clip = NO_ANIM;
		float clip_time = 0.0f;
		if (!shoot.motion && pose_clip_count > 0)
		{
			PoseDraw source = pose_draw(shoot.seed, index, DRAW_SOURCE);
			if (source.unit() < shoot.clip_share)
			{
				from_clip = pose_clips[(usz)(source.unit() * (float)pose_clip_count) % pose_clip_count];
				clip_time = source.unit() * app.clip(from_clip).duration;
			}
		}
		rig::Pose pose;
		if (shoot.motion)
		{
			pose = exam_pose(app, &view, &shoot, clip_ref, seconds);
		}
		else if (from_clip.pack >= 0)
		{
			pose = clip_drawn_pose(app, &view, &shoot, from_clip, index, clip_time);
		}
		else
		{
			pose = random_pose(&app.doc, &view.skeleton, view.dot_ids, &shoot, index, DRAW_POSE);
		}
		defer pose.free(mem);

		// The sub-frames a blurred picture averages: toward another pose, or
		// across the shutter; the labels are the pose at their middle.
		PoseDraw blur_draw = pose_draw(shoot.seed, index, DRAW_BLUR);
		bool blurred = shoot.motion ? shoot.blur > 0.0f : blur_draw.unit() < shoot.blur;
		rig::Pose[BLUR_FRAMES] subs;
		usz sub_count = 1;
		rig::Pose middle = pose.copy(mem);
		defer middle.free(mem);
		if (blurred)
		{
			sub_count = BLUR_FRAMES;
			if (shoot.motion)
			{
				for (usz s = 0; s < BLUR_FRAMES; s++)
				{
					float at = seconds + shoot.blur / shoot.fps * ((float)s / (float)(BLUR_FRAMES - 1) - 0.5f);
					subs[s] = exam_pose(app, &view, &shoot, clip_ref, at);
				}
			}
			else
			{
				// Toward another pose; a clip's toward its own a quarter second on.
				rig::Pose toward = from_clip.pack >= 0
					? clip_drawn_pose(app, &view, &shoot, from_clip, index, clip_time + 0.25f)
					: random_pose(&app.doc, &view.skeleton, view.dot_ids, &shoot, index, DRAW_BLUR + 16);
				defer toward.free(mem);
				float reach = blur_draw.between(0.05f, 0.2f);
				for (usz s = 0; s < BLUR_FRAMES; s++) subs[s] = between_poses(pose, toward, reach * (float)s / (float)(BLUR_FRAMES - 1));
				middle.free(mem);
				middle = between_poses(pose, toward, reach * 0.5f);
			}
		}
		else
		{
			subs[0] = pose.copy(mem);
		}
		defer
		{
			for (usz s = 0; s < sub_count; s++) subs[s].free(mem);
		}

		Matrix4f[]? palette = rig::joint_palette(mem, &view.skeleton, middle);
		if (catch palette)
		{
			detail.append_string("a pose did not fit the rig.");
			return RENDER_POSES_REFUSED~;
		}
		defer alloc::free(mem, palette);
		Vec3[] at = posed_joints(&view, palette);
		defer alloc::free(mem, at);

		if (poses.len() > 0) poses.append_char(',');
		poses.appendf(`{"index":%d,"rotations":[`, index);
		foreach (usz j, q : middle.rotations)
		{
			if (j > 0) poses.append_char(',');
			poses.appendf("[%s,%s,%s,%s]", (JsonFloat)q.v.x, (JsonFloat)q.v.y, (JsonFloat)q.v.z, (JsonFloat)q.v.w);
		}
		poses.append_char(']');
		// The root's slide from rest, where the pose moves it (a clip's bob).
		foreach (usz j, parent : view.skeleton.parents)
		{
			if (parent >= 0 || j >= middle.offsets.len) continue;
			Vec3 o = middle.offsets[j];
			poses.appendf(`,"root":[%s,%s,%s]`, (JsonFloat)o.x, (JsonFloat)o.y, (JsonFloat)o.z);
			break;
		}
		poses.append_char('}');

		for (usz c = 0; c < shoot.camera_count; c++)
		{
			PoseCamera cam = shoot.cameras[c];
			// With motion the camera is the call's (the seed's), so the exam's
			// frames are one shot; otherwise each picture's own.
			PoseDraw camera_draw = pose_draw(shoot.seed, shoot.motion ? 0 : index, DRAW_CAMERA + 16 * (c + 1));
			// The exam's camera frames the rig at rest, so it holds still while the
			// rig moves; a random pose frames itself.
			OrbitCamera camera = pose_camera(app, cam, &camera_draw, shoot.motion ? exam_framed : at, radius, &shoot);
			String name = string::tformat("%06d_%s.png", index, cam.name);

			// What the picture shows of each joint and surface point: its pixel,
			// its depth, and whether it is in sight (inside the picture, no part of
			// the body in front of it), against the middle pose's skinned surface.
			Matrix4f projection = app.model_view_projection(&camera, 1.0f);
			Matrix4f[] shown = app.pose_palette;
			app.pose_palette = palette;
			app.next_pose_generation();
			Vec3 eye = app.model_eye(&camera);
			if (labels.len() > 0) labels.append_char(',');
			labels.appendf(`{"file":"%s","camera":%d,"pose":%d,"blur":%s,"yaw":%s,"pitch":%s,"fov":%s,"points":[`,
				name, c, index, blurred ? "true" : "false", (JsonFloat)camera.yaw, (JsonFloat)camera.pitch, (JsonFloat)camera.fov);
			// The posed bones, for the overlay's question of whose skin is in front.
			List{RigBone} bones;
			bones.init(tmem);
			foreach (usz j, parent : view.skeleton.parents)
			{
				if (parent < 0) continue;
				bones.push({ .a = view.dot_ids[(usz)parent], .b = view.dot_ids[j], .from = at[(usz)parent], .to = at[j] });
			}
			for (usz j = 0; j < joints; j++)
			{
				if (j > 0) labels.append_char(',');
				// Held against the joint's rest radius, as the overlay holds its dot.
				Dot* dot = app.doc.find(view.dot_ids[j]);
				append_seen_point(&labels, app, projection, eye, at[j], shoot.size, false,
					dot ? app.dot_body_radius(*dot) : -1.0f, bones.array_view(), view.dot_ids[j]);
			}
			labels.append_string("]");
			if (landmark_count > 0)
			{
				labels.append_string(`,"marks":[`);
				for (usz m = 0; m < landmark_count; m++)
				{
					if (m > 0) labels.append_char(',');
					append_seen_point(&labels, app, projection, eye, app.shown_position(landmarks[m].vertex), shoot.size, true);
				}
				labels.append_string("]");
			}
			labels.append_string("}");
			app.pose_palette = shown;

			if (shoot.light_jitter > 0.0f)
			{
				// An exam's light holds still with its cameras: one per call.
				three::Lighting lit = picture_lighting(&was_lighting, &shoot, shoot.motion ? 0 : index, c);
				pass.note_lighting_change(lit);
				pass.lighting = lit;
			}
			foreach (&v : sum) *v = 0.0f;
			for (usz s = 0; s < sub_count; s++)
			{
				if (catch err = add_matted(app, &view, subs[s], &camera, sum))
				{
					detail.appendf("a picture could not be drawn: %s", err);
					return RENDER_POSES_REFUSED~;
				}
			}
			String file_path = string::tformat("%s/%s", shoot.out, name);
			if (catch save_matted(sum, shoot.size, sub_count, file_path))
			{
				detail.appendf("could not write %s", file_path);
				return RENDER_POSES_REFUSED~;
			}
			pictures++;
		}
	}

	// The set's file for this call: what every picture shows and how.
	DString out = dstring::new(mem);
	defer out.free();
	out.append_string(`{"joints":[`);
	for (usz j = 0; j < joints; j++)
	{
		if (j > 0) out.append_char(',');
		out.append_char('"');
		json_escape_into(&out, view.names[j]);
		out.append_char('"');
	}
	out.append_string(`],"parents":[`);
	for (usz j = 0; j < joints; j++)
	{
		if (j > 0) out.append_char(',');
		out.appendf("%d", view.skeleton.parents[j]);
	}
	out.append_string(`],"rest":[`);
	for (usz j = 0; j < joints; j++)
	{
		if (j > 0) out.append_char(',');
		Vec3 p = view.skeleton.joints[j];
		out.appendf("[%s,%s,%s]", (JsonFloat)p.x, (JsonFloat)p.y, (JsonFloat)p.z);
	}
	out.appendf(`],"size":%d,"seed":%d,"first":%d,"count":%d,"motion":%s,"fps":%s,"height":%s,"fill":[%s,%s],"cameras":[`,
		shoot.size, shoot.seed, shoot.first, shoot.count, shoot.motion ? "true" : "false", (JsonFloat)shoot.fps, (JsonFloat)height,
		(JsonFloat)shoot.fill_least, (JsonFloat)shoot.fill_most);
	for (usz c = 0; c < shoot.camera_count; c++)
	{
		PoseCamera cam = shoot.cameras[c];
		if (c > 0) out.append_char(',');
		out.append_string(`{"name":"`);
		json_escape_into(&out, cam.name);
		out.appendf(`","yaw":%s,"pitch":%s,"distance":%s}`, (JsonFloat)cam.yaw, (JsonFloat)cam.pitch, (JsonFloat)cam.distance);
	}
	out.append_string(`],"clip":"`);
	json_escape_into(&out, shoot.clip);
	out.append_string(`","landmarks":[`);
	for (usz k = 0; k < landmark_count; k++)
	{
		PoseLandmark mark = landmarks[k];
		if (k > 0) out.append_char(',');
		out.append_string(`{"name":"`);
		json_escape_into(&out, view.names[mark.named]);
		out.appendf(`.%s","joint":"`, mark.side);
		json_escape_into(&out, view.names[mark.joint]);
		out.appendf(`","vertex":%d,"offset":[%s,%s,%s]}`, mark.vertex, (JsonFloat)mark.offset.x, (JsonFloat)mark.offset.y, (JsonFloat)mark.offset.z);
	}
	out.append_string(`],"images":[`);
	out.append_string(labels.str_view());
	out.append_string(`],"poses":[`);
	out.append_string(poses.str_view());
	out.append_string("]}");
	String set_path = string::tformat("%s/poses_%06d.json", shoot.out, shoot.first);
	if (catch file::save(set_path, (char[])out.str_view()))
	{
		detail.appendf("could not write %s", set_path);
		return RENDER_POSES_REFUSED~;
	}

	double took = (double)(long)started.to_now() / 1.0e9;
	DString answer = dstring::new(mem);
	defer answer.free();
	answer.appendf(`{"pictures":%d,"poses":%d,"first":%d,"next":%d,"joints":%d,"labels":"`, pictures, shoot.count, shoot.first, shoot.first + shoot.count, joints);
	json_escape_into(&answer, set_path);
	answer.appendf(`","seconds":%s}`, (JsonFloat)took);
	return answer.copy_str(mem);
}
