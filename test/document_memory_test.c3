<*
 A fresh document's lists keep their memory across a script's temp pool.

     `c3c test --test-filter crig_tests::document_memory`
*>
module crig_tests::document_memory;

import crig;
import crig_tests::shared_app;
import std::core::test;

// A pin made inside run_script used to land in that script's temp pool, so the
// next pin that grew the list crashed in realloc.
fn void a_pin_made_in_a_script_outlives_it() @test
{
	crig::AppState app = shared_app::open_cube();
	defer app.free();
	uint dot = app.doc.add_dot({ 0, 0, 0 });

	@pool() { test::@check(app.doc.attach_shell(0, dot), "the first pin is taken"); };
	for (uint shell = 1; shell < 40; shell++) app.doc.attach_shell(shell, dot);

	test::eq(app.doc.attachment_of(0), dot);
	test::eq(app.doc.attachment_of(39), dot);
}
