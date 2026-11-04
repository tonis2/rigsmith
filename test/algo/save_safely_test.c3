<*
 A save either lands whole or leaves the old file alone. See rules/files.md.
*>
module crig_tests::save_safely;

import gltf_edit;
import std::core::test;
import std::io;
import std::io::file;
import std::io::path;

const String FOLDER @local = "build/save-safely";

fn void a_failed_save_leaves_the_old_file() @test
{
	(void)path::mkdir(FOLDER, true);
	String kept = FOLDER.tconcat("/kept.txt");
	(void)file::save(kept, "old");

	// A folder stands where the temporary file has to go, so the write fails.
	(void)path::mkdir(kept.tconcat(".tmp"), true);
	bool failed;
	if (catch gltf_edit::save_safely(kept, "new")) failed = true;
	test::@check(failed, "the save should have failed");
	char[] left = file::load(mem, kept)!!;
	defer alloc::free(mem, left);
	test::@check((String)left == "old", "the old file was damaged");
}

fn void a_save_replaces_the_file() @test
{
	(void)path::mkdir(FOLDER, true);
	String target = FOLDER.tconcat("/replaced.txt");
	(void)file::save(target, "old");
	gltf_edit::save_safely(target, "new")!!;
	char[] now = file::load(mem, target)!!;
	defer alloc::free(mem, now);
	test::@check((String)now == "new", "the save didn't land");
}
