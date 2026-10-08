<*
 The pack library the fixtures read.

 A disposable copy of `assets/animations`, not the folder itself. The copying is the
 point: several checks add a library, tag a file or write a pack, and pointing
 them at the shipped folder would let a test run edit what crig ships. The copy
 lives under `build`, which is not tracked and which `c3c clean` empties.

 Refreshed once per test process, even when last run's files still exist. The
 humanoid copy receives generated sample animations and an explicit optional
 finger policy for animation/browser tests. Its mesh and skeleton come from the
 current asset; the shipped rig is allowed to contain no animations at all.
 Asset-contract tests read the shipped file directly. No generated binary is
 committed, and no user's sidecar is read or modified by this fixture.
*>
module crig_tests::library;

import std::io;
import std::io::file;
import std::io::path;
import crig;
import make_anims;

// The one folder a .glb is kept in. Everything below is a copy of it.
const String PACK_SOURCE = "assets/animations";

// Under `build`, which is not tracked, so a run leaves nothing behind to commit.
const String TEST_LIBRARY = "build/test-library";

<*
 A second folder holding the same packs.

 For the checks about *several* libraries, which need two paths that are not the
 same string — a library list refuses a folder it already holds, so the same path
 twice is not a second library. Holding identical contents is the point: a count
 over both is exactly twice the count over one, whatever is on the machine.
*>
const String SECOND_LIBRARY = "build/test-library-2";

// The two source assets; only the disposable humanoid copy gains sample clips.
const String[2] PACKS = { "humanoid.glb", "quadruped.glb" };

<*
 Make sure the fixture library exists, and hand back its path.

 Cheap to call repeatedly: only the first call refreshes the files. Regeneration
 failures are fatal rather than silently falling back to a stale fixture.
*>
bool primary_ready @local;
bool secondary_ready @local;

fn String ready()
{
	if (!primary_ready) { fill(TEST_LIBRARY); primary_ready = true; }
	return TEST_LIBRARY;
}

<*
 The same, for the second folder — see `SECOND_LIBRARY`.
*>
fn String ready_second()
{
	if (!secondary_ready) { fill(SECOND_LIBRARY); secondary_ready = true; }
	return SECOND_LIBRARY;
}

// A byte copy of the shipped humanoid, clips and all. `ready` puts generated sample
// clips on its copy in place of the shipped ones; this one keeps what the file ships
// (`Walk_slow`, `Climb ladder`), for a check on the clips as they play. Still a copy
// under `build`, never the asset itself.
const String SHIPPED_COPY = "build/test-shipped";
const String SHIPPED_HUMANOID = "build/test-shipped/humanoid.glb";
bool shipped_copied @local;

<*
 Make the shipped-clips copy once, and hand back its path.
*>
fn String shipped_humanoid()
{
	if (shipped_copied) return SHIPPED_HUMANOID;
	if (catch path::mkdir((Path)SHIPPED_COPY))
	{
		// Already there, which is the ordinary case after the first check.
	}
	String source = string::tformat("%s/humanoid.glb", PACK_SOURCE);
	char[] bytes = file::load(mem, source)!!;
	defer alloc::free(mem, bytes);
	file::save(SHIPPED_HUMANOID, bytes)!!;
	shipped_copied = true;
	return SHIPPED_HUMANOID;
}

// Refresh the exact fixture files, leaving unrelated files alone.
fn String fill(String folder) @local
{
	if (catch path::mkdir((Path)folder))
	{
		// Already there, which is the ordinary case after the first check.
	}

	foreach (name : PACKS)
	{
		String destination = string::format(mem, "%s/%s", folder, name);
		defer alloc::free(mem, destination.ptr);

		String source = string::format(mem, "%s/%s", PACK_SOURCE, name);
		defer alloc::free(mem, source.ptr);

		char[] bytes = file::load(mem, source)!!;
		defer alloc::free(mem, bytes);

		file::save(destination, bytes)!!;
		// The shipped humanoid is a rig template, not an animation library.
		// Give the disposable test copy explicit sample clips so browser/editor
		// tests don't depend on animations being attached to the user's template.
		if (name == "humanoid.glb") add_sample_clips(destination);
	}

	return folder;
}

fn void add_sample_clips(String destination) @local
{
	AnimPack pack = crig::read_pack(mem, destination)!!;
	defer pack.free(mem);
	AnimTemplate[] clips = make_anims::humanoid_clips(mem);
	defer
	{
		// Generator templates borrow their names but own their frames and dots.
		foreach (clip : clips)
		{
			foreach (frame : clip.keyframes) alloc::free(mem, frame.dots);
			alloc::free(mem, clip.keyframes);
		}
		alloc::free(mem, clips);
	}
	StringList optional;
	optional.init(mem);
	defer optional.free();
	foreach (dot : make_anims::humanoid_dots)
	{
		if (dot.optional) optional.push(dot.name);
	}
	// The rig's own limits ride along: the shipped figure carries a table on
	// every joint that turns, and a fit from the test copy has to adopt them
	// the way a fit from the shipped file does.
	crig::export_pack_glb(mem, destination, &pack.rest, pack.joint_names, clips, pack.mesh,
		{ .plan = pack.plan, .name = pack.name, .tags = pack.tags,
		  .optional = optional.array_view() }, pack.physics, pack.constraints)!!;
}
