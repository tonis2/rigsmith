<*
 A pack loaded to bind a clip stubs its clips — name and length only — and reads
 a clip's curves the first time it is sampled. These check the stub carries what
 the browser and the binding need, that it names a clip exactly as the eager read
 would (so a binding stored against the stub resolves), and that reading it on
 demand reproduces the eager clip.

 quadruped.glb is small and holds one clip, so this exercises the machinery
 without the cost of a real animation library.
*>
module crig_tests::lazy_pack;

import crig;
import gltf;
import std::core::test;

const String GLB = "assets/animations/quadruped.glb";

fn void a_deferred_pack_stubs_its_clips() @test
{
	crig::AnimPack? read = crig::read_pack(mem, GLB, defer_clips: true);
	if (catch read) { test::@check(false, "deferred read_pack failed"); return; }
	crig::AnimPack pack = read;
	defer pack.free(mem);

	test::eq(pack.clips.len, (sz)1);
	test::@check(pack.clips[0].lazy, "the clip was retargeted instead of stubbed");
	test::@check(pack.clips[0].keyframes.len == 0, "a stub carried keyframes");
	test::@check(pack.clips[0].name == "Idle", "stub named the clip wrong: %s", pack.clips[0].name);
	test::@check(pack.clips[0].duration > 0.0f, "the stub has no length");
	test::@check(pack.stream_held, "a deferred pack did not keep its parsed file");
}

fn void a_stub_names_the_clip_the_eager_read_would() @test
{
	crig::AnimPack? lazy_read = crig::read_pack(mem, GLB, defer_clips: true);
	if (catch lazy_read) { test::@check(false, "deferred read failed"); return; }
	crig::AnimPack lazy = lazy_read;
	defer lazy.free(mem);

	crig::AnimPack? eager_read = crig::read_pack(mem, GLB);
	if (catch eager_read) { test::@check(false, "eager read failed"); return; }
	crig::AnimPack eager = eager_read;
	defer eager.free(mem);

	test::eq(lazy.clips.len, eager.clips.len);
	// The invariant binding depends on: a binding is stored under the stub's name,
	// and must still find the clip once it is read.
	test::@check(lazy.clips[0].name == eager.clips[0].name,
		"stub name %s != eager name %s", lazy.clips[0].name, eager.clips[0].name);
	test::@check(eager.clips[0].keyframes.len > 0, "the eager clip has no keyframes to compare against");
	test::@check(!eager.clips[0].lazy, "the eager clip was left marked lazy");
}

fn void a_stub_retargets_to_the_same_clip_on_demand() @test
{
	crig::AnimPack? lazy_read = crig::read_pack(mem, GLB, defer_clips: true);
	if (catch lazy_read) { test::@check(false, "deferred read failed"); return; }
	crig::AnimPack lazy = lazy_read;
	defer lazy.free(mem);

	crig::AnimPack? eager_read = crig::read_pack(mem, GLB);
	if (catch eager_read) { test::@check(false, "eager read failed"); return; }
	crig::AnimPack eager = eager_read;
	defer eager.free(mem);

	// Reproduce what `ensure_clip_imported` does: import the stub's source clip
	// from the pack's held stream. With no plans it keeps source names, the same
	// terms both reads above used.
	crig::AnimImportOptions naming = { .keep_source_names = true, .index = lazy.clips[0].source };
	crig::AnimTemplate? imported = crig::import_animation(mem, &lazy.stream, naming);
	if (catch imported) { test::@check(false, "on-demand retarget failed"); return; }
	crig::AnimTemplate one = imported;
	defer one.free(mem);

	test::eq(one.keyframes.len, eager.clips[0].keyframes.len);
	test::@check(!one.lazy, "the on-demand import is still marked lazy");
	test::@check(one.name == eager.clips[0].name, "on-demand name %s != eager %s",
		one.name, eager.clips[0].name);
}
