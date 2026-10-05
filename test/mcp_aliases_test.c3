<*
 The small conveniences an agent leans on: a clip is `name` or `clip` to any
 tool, and a planted clip's key density follows its length.

     `c3c test --trust=full --test-filter crig_tests::mcp_aliases`
*>
module crig_tests::mcp_aliases;

import crig;
import std::collections::object;
import std::core::test;
import std::encoding::json;

fn void a_clip_is_named_by_either_spelling() @test
{
	Object*? by_name = json::parse(mem, `{"name":"Walk"}`);
	Object*? by_clip = json::parse(mem, `{"clip":"Run"}`);
	if (catch by_name) { test::@check(false, "parse"); return; }
	if (catch by_clip) { test::@check(false, "parse"); return; }
	defer by_name.free();
	defer by_clip.free();

	DString detail = dstring::new(mem);
	defer detail.free();

	String got;
	test::@check(crig::required_string(by_name, "clip", &got, &detail, "x") && got == "Walk", "name reaches a tool that asks for clip");
	test::@check(crig::required_string(by_clip, "name", &got, &detail, "x") && got == "Run", "clip reaches a tool that asks for name");
	Object*? none = json::parse(mem, `{}`);
	if (catch none) return;
	defer none.free();
	test::@check(!crig::required_string(none, "clip", &got, &detail, "x"), "neither spelling is still a refusal");
}

fn void planting_takes_more_keys_for_a_longer_cycle() @test
{
	test::@check(crig::plant_samples_for(0.3f) == 24, "a short clip keeps the floor");
	test::@check(crig::plant_samples_for(1.0f) == 48, "a second of clip is 48 keys");
	test::@check(crig::plant_samples_for(60.0f) == crig::PLANT_SAMPLES_MOST, "and it stops at the most");
}
