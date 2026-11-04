<* The pure half of src/app/generate.c3: no state, undo or notices. *>
module crig;

import std::math;
import std::core::string;
import rig;

<*
 A clip name out of a prompt: its first clause, cut to about forty characters at a
 word, with the first letter raised. "a person walks forward and waves" is its own
 name; "a person jumps, then lands" is "A person jumps".
*>
fn String motion_clip_name(Allocator allocator, String prompt)
{
	String text = prompt.trim();
	// A clause is a name: "walks forward, then sits" is "Walks forward".
	foreach (usz i, c : text)
	{
		if (i >= 12 && (c == ',' || c == '.' || c == ';' || c == '!' || c == '?'))
		{
			text = text[:i];
			break;
		}
	}
	usz cut = text.len;
	if (cut > 40)
	{
		cut = 40;
		while (cut > 20 && text[cut] != ' ') cut--;
		if (text[cut] != ' ') cut = 40;
	}
	String name = text[:cut].trim().copy(allocator);
	if (name.len > 0 && name[0] >= 'a' && name[0] <= 'z') name[0] -= 32;
	return name;
}

<*
 The step a line of the pipeline's output reports, as "step 40/100": true and the
 two numbers when it is one, false for every other line.
*>
fn bool parse_motion_step(String line, uint* step, uint* steps)
{
	String text = line.trim();
	if (!text.starts_with("step ")) return false;
	String rest = text[5..];
	sz? found   = rest.index_of_char('/');
	if (catch found) return false;
	usz slash = (usz)found;
	usz end   = slash + 1;
	while (end < rest.len && rest[end] >= '0' && rest[end] <= '9') end++;
	uint? done  = rest[:slash].to_uint();
	uint? total = rest[slash + 1:end - slash - 1].to_uint();
	if (catch done) return false;
	if (catch total) return false;
	if (total == 0) return false;
	*step = done;
	*steps = total;
	return true;
}

fn void append_json_point(DString* out, Vec3 p)
{
	out.appendf("[%.5f, %.5f, %.5f]", p.x, p.y, p.z);
}

<*
 Which of Kimodo's hands and feet a Kimodo joint belongs to: "LeftHand" for the
 left arm from the shoulder down, "LeftFoot" for the left leg from the hip down,
 and the same on the right; "" for the hips, spine, neck, head and eyes.
*>
fn String kimodo_limb(String joint)
{
	foreach (side : (String[]) { "Left", "Right" })
	{
		if (!joint.starts_with(side)) continue;
		String part = joint[side.len..];
		foreach (arm : (String[]) { "Shoulder", "Arm", "ForeArm", "Hand" })
		{
			if (part.starts_with(arm)) return side == "Left" ? "LeftHand" : "RightHand";
		}
		foreach (leg : (String[]) { "Leg", "Shin", "Foot", "Toe" })
		{
			if (part.starts_with(leg)) return side == "Left" ? "LeftFoot" : "RightFoot";
		}
	}
	return "";
}

<*
 Which way a figure faces, as a turn about Y from +Z in radians, read the way
 Kimodo reads its own: the line from its right side to its left points along −X
 for a figure facing +Z. Zero when `across` has no length over the floor.
*>
fn float heading_of(Vec3 across) @local
{
	if (across.x * across.x + across.z * across.z < 1.0e-12f) return 0.0f;
	return math::atan2(across.z, -across.x);
}

<*
 What heading is left once matched, read off the joints answering to Kimodo's
 hips and shoulders — for a rig whose names say no side, or one turned by less
 than its names can tell.
*>
fn float matched_heading(rig::Skeleton* skeleton, PackReach* reach, bool[] sent)
{
	Vec3 across;
	foreach (pair : (String[2][]) { { "RightLeg", "LeftLeg" }, { "RightArm", "LeftArm" } })
	{
		int right = -1;
		int left  = -1;
		foreach (usz i, name : reach.names)
		{
			if (i >= sent.len || !sent[i]) continue;
			if (name == pair[0]) right = (int)i;
			if (name == pair[1]) left = (int)i;
		}
		if (right >= 0 && left >= 0) across += skeleton.joints[right] - skeleton.joints[left];
	}
	return heading_of(across);
}

// `p` turned about the Y axis by `angle` radians, +Z toward +X.
fn Vec3 turned_about_y(Vec3 p, float angle)
{
	float c = math::cos(angle);
	float s = math::sin(angle);
	return { p.x * c + p.z * s, p.y, p.z * c - p.x * s };
}

<*
 The rig's heading from its joint names, before anything is matched: the
 average right-named joint to the average left-named one. The shape matcher
 tells left from right by the sign of x, so a rig has to be stood facing +Z
 before it is measured against Kimodo's skeleton at all — the same reading
 `faces_back` takes of a file. Zero for a rig naming fewer than two joints on
 each side.
*>
fn float rig_heading_by_names(RigView* view)
{
	Vec3 left;
	Vec3 right;
	usz lefts;
	usz rights;
	foreach (usz i, name : view.names)
	{
		char side = name_side(name);
		if (side == 0) continue;
		if (side == 'L' || side == 'l')
		{
			left += view.skeleton.joints[i];
			lefts++;
		}
		else
		{
			right += view.skeleton.joints[i];
			rights++;
		}
	}
	if (lefts < 2 || rights < 2) return 0.0f;
	return heading_of(right / (float)rights - left / (float)lefts);
}
