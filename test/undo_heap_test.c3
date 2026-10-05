<*
 The undo stack's history must not live in temp memory.

     `c3c test --trust=full --test-noleak --test-filter crig_tests::undo_heap`
*>
module crig_tests::undo_heap;

import crig;
import std::core::test;

fn void an_edit_recorded_inside_a_pool_survives_the_pool() @test
{
	UndoStack stack;
	defer stack.free();

	// What an MCP call does: the first edit of the session is recorded from
	// inside a scope that closes when the call returns.
	@pool()
	{
		stack.record_clip_swap("first".copy(mem), {});
	};

	// The next scope hands the same temp memory out again and writes over it.
	@pool()
	{
		char[] scribble = alloc::new_array(tmem, char, 4096);
		foreach (&c : scribble) *c = 0x7f;
		stack.record_clip_swap("second".copy(mem), {});
	};

	test::@check(stack.edits.len() == 2, "both edits are still recorded");
	test::@check(stack.clips.len() == 2, "both clip payloads are still recorded");
	test::@check(stack.edits[0].name == "first", "the first edit still reads back");
	test::@check(stack.edits[1].name == "second", "the second edit still reads back");
	test::@check(stack.edits.allocator.ptr == mem.ptr, "the edits are on the heap, not in temp memory");
	test::@check(stack.clips.allocator.ptr == mem.ptr, "the clip payloads are on the heap, not in temp memory");
}
