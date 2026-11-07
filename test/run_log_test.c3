<*
 The run log: its rotation, how it words a run's end, its time stamps, and the
 tool calls it names.

     `c3c test --test-filter crig_tests::run_log`
*>
module crig_tests::run_log;

import crig;
import mcp;
import libc;
import std::core::test;
import std::collections::object;
import std::io;
import std::io::file;
import std::io::path;

const String FOLDER = "build/run-log-test";

fn String read_back(int age) @local
{
	String path = crig::log_path(tmem, FOLDER, age);
	char[]? text = file::load(tmem, path);
	if (catch text) return "<none>";
	return (String)text;
}

// A crash survives the next few restarts, and the folder never grows past five runs.
fn void rotation_keeps_five_runs() @test => @pool()
{
	(void)path::mkdir((Path)FOLDER, recursive: true);
	for (int age = 0; age < crig::KEPT_LOGS; age++)
	{
		file::save(crig::log_path(tmem, FOLDER, age), string::tformat("run %d", age))!!;
	}

	crig::rotate_logs(FOLDER);

	test::eq(read_back(0), "<none>");
	test::eq(read_back(1), "run 0");
	test::eq(read_back(4), "run 3");
}

fn void a_run_end_is_said_in_words() @test => @pool()
{
	test::eq(crig::ending_sentence(tmem, 0), "exit 0");
	test::eq(crig::ending_sentence(tmem, 1 << 8), "exit 1");
	// The C3 runtime prints a crash, then exits 128 + the signal.
	test::eq(crig::ending_sentence(tmem, 139 << 8), "exit 139, after signal 11 (segmentation fault)");
	test::eq(crig::ending_sentence(tmem, 9), "killed by signal 9 (killed: out of memory, or by the system)");
	// A panic traps.
	test::eq(crig::ending_sentence(tmem, 4), "killed by signal 4 (illegal instruction: a panic)");
}

// Only a signal counts as a crash; a refused file at startup does not.
fn void only_a_signal_is_a_crash() @test
{
	test::eq(crig::ending_signal(0), 0);
	test::eq(crig::ending_signal(1 << 8), 0);
	test::eq(crig::ending_signal(139 << 8), 11);
	test::eq(crig::ending_signal(9), 9);
}

// A pipe hands lines over in pieces, so the stamp goes on lines, not on reads.
fn void lines_are_stamped_across_pieces() @test => @pool()
{
	DString out;
	out.tinit();
	bool at_line_start = true;
	crig::stamp_lines(&out, "first\nsec", &at_line_start, "T ");
	crig::stamp_lines(&out, "", &at_line_start, "T ");
	crig::stamp_lines(&out, "ond\nthird", &at_line_start, "T ");
	test::eq(out.str_view(), "T first\nT second\nT third");
	test::@check(!at_line_start, "the unfinished line is left open for the watcher to end");
}

excuse FAKE_REFUSED;

fn String? fake_answers(Object* args, void* user_data, DString* detail) @local
{
	return string::format(mem, "answer %d", *(int*)user_data);
}

fn String? fake_refuses(Object* args, void* user_data, DString* detail) @local
{
	detail.append_string("no");
	return FAKE_REFUSED~;
}

// A crash mid-call says which tool was running, and the call itself is unchanged.
fn void tool_calls_are_named_in_the_log() @test => @pool()
{
	(void)path::mkdir((Path)FOLDER, recursive: true);
	String path = string::tformat("%s/tools.log", FOLDER);
	File log = file::open(path, "w")!!;
	crig::run_log_fd = libc::fileno(log.file);
	defer
	{
		crig::run_log_fd = -1;
		(void)log.close();
	}

	int seven = 7;
	mcp::Server server = mcp::new_server({ .name = "test", .version = "0" });
	server.add_tool({ .name = "fake_answers", .handler = &fake_answers, .user_data = &seven });
	server.add_tool({ .name = "fake_refuses", .handler = &fake_refuses });
	crig::log_tool_calls(&server);

	DString detail;
	detail.tinit();
	String answer = server.tools[0].handler(null, server.tools[0].user_data, &detail)!!;
	defer alloc::free(mem, answer.ptr);
	test::eq(answer, "answer 7");

	String? refused = server.tools[1].handler(null, server.tools[1].user_data, &detail);
	test::@check(@catch(refused) == FAKE_REFUSED, "a refusal comes back as it was");
	test::eq(detail.str_view(), "no");

	String text = (String)file::load(tmem, path)!!;
	test::@check(text.contains("mcp: fake_answers\n"), "the log names the first call: %s", text);
	test::@check(text.contains("mcp: fake_refuses\n"), "and the second: %s", text);
}
