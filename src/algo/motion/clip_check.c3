<* The pure half of src/app/clip_check.c3: no state, undo or notices. *>
module crig;

import std::math;
import std::sort;

// Instants a check looks at: enough to catch a slide inside a stance window.
const usz CHECK_SAMPLES = 64;

struct CheckIssue
{
	ClipIssueKind kind;
	float time;
	float magnitude; // in the unit of its kind; see ClipIssueKind
	String label; // owned
	String trailing; // owned
}

struct ClipCheck
{
	AnimRef ref;
	bool ran;
	// The history revision the check read; a later edit makes it out of date.
	uint revision;
	CheckIssue[] issues;
}

fn String ClipIssueKind.words(self)
{
	switch (self)
	{
		case FOOT_SLIDE: return "Foot slides";
		case FLOOR_PENETRATION: return "Goes through the floor";
		case LIMIT_SATURATION: return "Past its joint limit";
		case LOOP_POSITION: return "Loop jumps";
		case LOOP_VELOCITY: return "Loop changes speed";
		case POP: return "Pops";
		case ROOT_POP: return "Body height jumps";
		case LIMITS_INVERTED: return "Joint limits fold it backward";
		case LIMITS_BLOCKED: return "Joint limits keep it from bending";
		case LIMITS_STALE: return "Joint limits no longer follow the bone";
		case AIM_STARE: return "Looks at a fixed point";
		default: return "Issue";
	}
}

<*
 The feet a clip is measured and planted by: its own ground spec, else the ones
 read off its motion. Owned only in the second case — see `owned`.
*>
fn AnimGround clip_contacts(RigView* view, String[] names, AnimTemplate* clip, bool* owned)
{
	*owned = false;
	if (clip.ground.solves()) return clip.ground;
	*owned = true;
	return derived_contacts(&view.skeleton, names, *clip);
}
