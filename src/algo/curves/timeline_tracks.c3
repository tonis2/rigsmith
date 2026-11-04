<* The dopesheet's rows, read from a clip. *>
module crig;

import rig;
import std::collections::list;

<*
 One row of the dopesheet: a joint the clip drives, and where it has keys.

 The times are a *copy* rather than a view into the clip, because the clip is
 replaced wholesale by every edit and a widget borrows its rows for the life of
 its element — a slice into the old template would be pointing at freed
 keyframes the moment anything was dragged.
*>
struct TimelineTrack
{
	String joint; // borrowed from the clip, rebuilt with the rows
	float[] times; // owned; union retained for the simple pose-row UI
	float[] rotation_times; // owned
	float[] translation_times; // owned
	// How far below the rig's root this joint hangs, for the sheet to indent
	// by; zero for a joint the rig does not have.
	uint depth;
}

<*
 Every joint named anywhere in the clip, in first-seen order.

 @param [&inout] out : `Receives the names, borrowed from the clip.`
*>
fn void clip_joint_names(StringList* out, AnimTemplate* clip)
{
	foreach (frame : clip.keyframes)
	{
		foreach (dot : frame.dots)
		{
			bool seen = false;
			foreach (have : out.array_view())
			{
				if (have == dot.joint_name) { seen = true; break; }
			}
			if (!seen) out.push(dot.joint_name);
		}
	}
}

<*
 The names of `order`, read as the rig's tree, then whatever the rig has no joint for.

 @param [&inout] out : `Receives the names.`
 @param [&inout] depths : `Receives how far below its root each hangs.`
 @param words : `The clip's name for each joint.`
*>
fn void joints_in_rig_order(StringList* out, List{uint}* depths, rig::Skeleton* skeleton, String[] words, String[] order)
{
	// The tree, read root first and each subtree whole: the builder's joints
	// are parents-before-children, so a stack of "next child to visit" per
	// joint walks it without recursion. Children come in joint order, which
	// is the order the builder found them in.
	usz count = skeleton.len();
	usz[] stack = alloc::new_array(mem, usz, (sz)count);
	uint[] depth = alloc::new_array(mem, uint, (sz)count);
	defer alloc::free(mem, stack);
	defer alloc::free(mem, depth);
	usz top;
	for (usz root = 0; root < count; root++)
	{
		if (skeleton.parents[root] >= 0) continue;
		stack[top++] = root;
		while (top > 0)
		{
			usz joint = stack[--top];
			String word = joint < words.len ? words[joint] : "";
			if (word.len > 0)
			{
				foreach (have : order)
				{
					if (have != word) continue;
					out.push(have);
					depths.push(depth[joint]);
					break;
				}
			}
			// Pushed last-first so the first child is visited next.
			for (usz child = count; child-- > joint + 1;)
			{
				if (skeleton.parents[child] != (int)joint) continue;
				depth[child] = depth[joint] + 1;
				stack[top++] = child;
			}
		}
	}
	// Then whatever the clip drives that this rig has no joint for.
	foreach (have : order)
	{
		bool placed = false;
		foreach (already : out.array_view())
		{
			if (already == have) { placed = true; break; }
		}
		if (!placed)
		{
			out.push(have);
			depths.push(0);
		}
	}
}

<*
 One dopesheet row per joint, with where it has keys.

 @param depths : `Per joint; missing ones are zero.`
 @return `Owned by the caller, with the times of each row.`
*>
fn TimelineTrack[] timeline_tracks_of(Allocator allocator, AnimTemplate* clip, String[] order, uint[] depths)
{
	TimelineTrack[] tracks = alloc::new_array(allocator, TimelineTrack, (sz)order.len);
	foreach (usz i, joint : order)
	{
		usz count = 0;
		usz rotations, translations;
		foreach (frame : clip.keyframes)
		{
			if (frame.names(joint)) count++;
			if (frame.has_channel(joint, ROTATION)) rotations++;
			if (frame.has_channel(joint, TRANSLATION)) translations++;
		}

		float[] times = alloc::new_array(allocator, float, (sz)count);
		float[] rotation_times = alloc::new_array(allocator, float, (sz)rotations);
		float[] translation_times = alloc::new_array(allocator, float, (sz)translations);
		usz write = 0;
		usz rotation_write, translation_write;
		foreach (frame : clip.keyframes)
		{
			if (frame.names(joint)) times[write++] = frame.time;
			if (frame.has_channel(joint, ROTATION)) rotation_times[rotation_write++] = frame.time;
			if (frame.has_channel(joint, TRANSLATION)) translation_times[translation_write++] = frame.time;
		}
		tracks[i] = { .joint = joint, .times = times,
			.rotation_times = rotation_times, .translation_times = translation_times,
			.depth = i < depths.len ? depths[i] : 0 };
	}
	return tracks;
}
