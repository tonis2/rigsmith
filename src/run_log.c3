<*
 Every run leaves a log in `<config dir>/logs/`, even when Rigsmith crashes.

 A watcher process forks Rigsmith off, copies everything it prints to the
 terminal and, stamped with the time, into `rigsmith.log`, then records how it
 ended. It has to be a second process: a SIGKILL or a crash with no handler
 leaves nothing in-process to write with. See `rules/files.md`.
*>
module crig;

import std::io;
import std::time;
import std::time::datetime;
import std::collections::object;
import std::io::file;
import libc;
import mcp;

const String LOG_FOLDER = "logs";
const int KEPT_LOGS = 5;
const String LAST_CRASH_FILE = "last_crash";
const String NO_LOG_VAR = "RIGSMITH_NO_LOG";

// The run's log, shared by Rigsmith and its watcher; -1 when there is none.
CInt run_log_fd = -1;

<*
 The folder logs go in, or "" when there is no config directory.

 The caller frees a result that isn't empty.
*>
fn String log_folder(Allocator allocator)
{
	String home = config_home(allocator);
	if (home.len == 0) return home;
	defer alloc::free(allocator, home.ptr);
	return string::format(allocator, "%s/%s", home, LOG_FOLDER);
}

<*
 The path of the log `age` runs back: 0 is this run's `rigsmith.log`.

 The caller owns the result.
*>
fn String log_path(Allocator allocator, String folder, int age)
{
	if (age == 0) return string::format(allocator, "%s/rigsmith.log", folder);
	return string::format(allocator, "%s/rigsmith.%d.log", folder, age);
}

<*
 Make room for a new run's log: each older one moves back a place, and the oldest kept is overwritten.
*>
fn void rotate_logs(String folder) => @pool()
{
	for (int age = KEPT_LOGS - 1; age > 0; age--)
	{
		ZString from = log_path(tmem, folder, age - 1).zstr_tcopy();
		ZString to = log_path(tmem, folder, age).zstr_tcopy();
		// A missing log is the ordinary case for the first few runs.
		(void)libc::rename(from, to);
	}
}

<*
 A signal's number in words, or "" for one nothing here expects.
*>
fn String signal_words(CInt signal)
{
	switch (signal)
	{
		case libc::SIGHUP: return "hangup: the terminal closed";
		case libc::SIGINT: return "interrupt: Ctrl+C";
		case libc::SIGILL: return "illegal instruction: a panic";
		case libc::SIGABRT: return "abort";
		case libc::SIGBUS: return "bus error";
		case libc::SIGFPE: return "arithmetic error";
		case libc::SIGKILL: return "killed: out of memory, or by the system";
		case libc::SIGSEGV: return "segmentation fault";
		case libc::SIGTERM: return "terminated";
		default: return "";
	}
}

<*
 The signal a wait status ended in: by the signal itself, or by the 128 + n
 exit the C3 runtime takes after printing a crash. 0 for an ordinary exit.
*>
fn CInt ending_signal(CInt status)
{
	CInt signal = status & 0x7f;
	if (signal != 0) return signal;
	CInt code = (status >> 8) & 0xff;
	if (code > 128 && signal_words(code - 128).len > 0) return code - 128;
	return 0;
}

<*
 How a run ended, from its wait status, as the log's last line says it.

 The caller owns the result.
*>
fn String ending_sentence(Allocator allocator, CInt status)
{
	CInt signal = status & 0x7f;
	if (signal != 0)
	{
		String words = signal_words(signal);
		if (words.len == 0) return string::format(allocator, "killed by signal %d", signal);
		return string::format(allocator, "killed by signal %d (%s)", signal, words);
	}
	CInt code = (status >> 8) & 0xff;
	CInt caught = ending_signal(status);
	if (caught != 0)
	{
		return string::format(allocator, "exit %d, after signal %d (%s)", code, caught, signal_words(caught));
	}
	return string::format(allocator, "exit %d", code);
}

<*
 Copy `bytes` into `out`, putting `stamp` at the start of every line.

 `at_line_start` carries across calls, because a pipe hands lines over in pieces.
*>
fn void stamp_lines(DString* out, char[] bytes, bool* at_line_start, String stamp)
{
	foreach (c : bytes)
	{
		if (*at_line_start) out.append_string(stamp);
		out.append_char(c);
		*at_line_start = c == '\n';
	}
}

<*
 The local time as `HH:MM:SS `, into `buffer`.
*>
fn String clock_stamp(char[] buffer)
{
	TzDateTime now = datetime::now().to_local();
	return (String)io::bprintf(buffer, "%02d:%02d:%02d ", now.hour, now.min, now.sec) ?? "";
}

<*
 One stamped line straight into the log, when this run has one.

 Rigsmith's own notes take this path rather than stdout, so they stay out of the terminal.
*>
macro void @log_note(String format, args...)
{
	if (run_log_fd >= 0)
	{
		@pool()
		{
			char[16] clock;
			String line = string::tformat("%s%s\n", clock_stamp(&clock), string::tformat(format, ...args));
			write_all(run_log_fd, line);
		};
	}
}

fn void write_all(CInt fd, char[] bytes)
{
	while (bytes.len > 0)
	{
		sz written = libc::write(fd, bytes.ptr, bytes.len);
		if (written <= 0) return;
		bytes = bytes[written..];
	}
}

<*
 Read and remove the reason the last run crashed, or "" when it did not.

 The caller frees a result that isn't empty.
*>
fn String take_last_crash(Allocator allocator)
{
	String folder = log_folder(tmem);
	if (folder.len == 0) return "";
	String path = string::tformat("%s/%s", folder, LAST_CRASH_FILE);
	char[]? text = file::load(tmem, path);
	if (catch text) return "";
	(void)file::delete(path);
	String reason = ((String)text).trim();
	if (reason.len == 0) return "";
	return reason.copy(allocator);
}

<*
 Say on screen that the last run crashed, and where its log is.
*>
fn void show_last_crash(AppState* app)
{
	String crash = take_last_crash(mem);
	if (crash.len == 0) return;
	defer alloc::free(mem, crash.ptr);
	// This run's watcher has already moved the crashed run's log back one place.
	String name = run_log_fd >= 0 ? "rigsmith.1.log" : "rigsmith.log";
	app.@notice("Rigsmith closed unexpectedly last time (%s). Its log is %s in %s", crash, name, log_folder(tmem));
}

// ------------------------------------------------------------ tool calls

// What a logged tool forwards to.
struct LoggedTool @local
{
	String name;
	mcp::ToolHandlerFn handler;
	void* user_data;
}

LoggedTool[mcp::MAX_TOOLS] logged_tools @local;

<*
 Note every tool call the server dispatches in the log, so a crash says what was running.

 Nothing changes when this run has no log.

 @param [&inout] server : "Every tool already registered"
*>
fn void log_tool_calls(mcp::Server* server)
{
	if (run_log_fd < 0) return;
	for (usz i = 0; i < server.tools_len; i++)
	{
		mcp::ToolDef* tool = &server.tools[i];
		logged_tools[i] = { .name = tool.name, .handler = tool.handler, .user_data = tool.user_data };
		tool.handler = &logged_call;
		tool.user_data = &logged_tools[i];
	}
}

fn String? logged_call(Object* args, void* user_data, DString* detail) @local
{
	LoggedTool* tool = user_data;
	@log_note("mcp: %s", tool.name);
	return tool.handler(args, tool.user_data, detail);
}

module crig @feat(LINUX, DARWIN);

import std::io;
import std::time::datetime;
import std::os::posix;
import std::os::env;
import std::io::file;
import std::io::path;
import std::net::os;
import libc;

extern fn Pid_t fork_process() @cname("fork") @local;
extern fn CInt dup_onto(CInt from, CInt onto) @cname("dup2") @local;

<*
 Fork Rigsmith off and watch it, when there is a log to write.

 Returns true in the watcher once Rigsmith has ended, with `exit_code` set for
 `main` to return. Returns false in Rigsmith itself, and when nothing is
 watched, and the run carries on.
*>
fn bool watch_run(String[] args, int* exit_code)
{
	if (try off = env::tget_var(NO_LOG_VAR)) { if (off.len > 0) return false; }

	String folder = log_folder(mem);
	if (folder.len == 0) return false;
	defer alloc::free(mem, folder.ptr);
	(void)path::mkdir((Path)folder, recursive: true);
	rotate_logs(folder);

	String path = log_path(mem, folder, 0);
	defer alloc::free(mem, path.ptr);
	File? log = file::open(path, "a");
	if (catch log) return false;
	CInt log_fd = libc::fileno(log.file);

	CInt[2] pipe_ends;
	if (posix::pipe(&pipe_ends) != 0) return false;

	Pid_t child = fork_process();
	if (child < 0)
	{
		libc::close(pipe_ends[0]);
		libc::close(pipe_ends[1]);
		return false;
	}
	if (child == 0)
	{
		libc::close(pipe_ends[0]);
		dup_onto(pipe_ends[1], 1);
		dup_onto(pipe_ends[1], 2);
		libc::close(pipe_ends[1]);
		// A pipe makes stdout fully buffered, which would lose the last lines at a crash.
		libc::setvbuf(io::stdout().file, null, libc::_IOLBF, 0);
		run_log_fd = log_fd;
		return false;
	}

	libc::close(pipe_ends[1]);
	// The watcher stays to record the end, whatever ends Rigsmith.
	libc::signal(libc::SIGINT, (libc::SignalFunction)(uptr)1);
	libc::signal(libc::SIGTERM, (libc::SignalFunction)(uptr)1);
	libc::signal(libc::SIGHUP, (libc::SignalFunction)(uptr)1);
	libc::signal(libc::SIGPIPE, (libc::SignalFunction)(uptr)1);

	@pool()
	{
		TzDateTime now = datetime::now().to_local();
		DString header;
		header.tinit();
		header.appendf("%04d-%02d-%02d %02d:%02d:%02d %s, pid %d:", now.year, now.month.ordinal + 1, now.day,
			now.hour, now.min, now.sec, VERSION_LABEL, child);
		foreach (argument : args) header.appendf(" %s", argument);
		header.append_char('\n');
		write_all(log_fd, header.str_view());
		write_all(1, string::tformat("log: %s\n", path));
	};

	CInt status = watch_output(pipe_ends[0], log_fd, child);
	libc::close(pipe_ends[0]);

	@pool()
	{
		char[16] clock;
		String ending = ending_sentence(tmem, status);
		write_all(log_fd, string::tformat("%sended: %s\n", clock_stamp(&clock), ending));
		if (ending_signal(status) != 0)
		{
			write_all(2, string::tformat("rigsmith: %s. The log is %s\n", ending, path));
			(void)file::save(string::tformat("%s/%s", folder, LAST_CRASH_FILE), ending);
		}
	};
	(void)log.close();

	CInt signal = status & 0x7f;
	*exit_code = signal != 0 ? 128 + signal : (status >> 8) & 0xff;
	return true;
}

<*
 Copy Rigsmith's output to the terminal and the log until it ends, then its wait status.

 Polled rather than read to the end, so a helper process still holding the
 pipe can't keep the watcher waiting after Rigsmith is gone.
*>
fn CInt watch_output(CInt from, CInt log_fd, Pid_t child) @local
{
	char[4096] buffer;
	bool at_line_start = true;
	CInt status = 0;
	bool ended = false;
	while (true)
	{
		os::Posix_pollfd wanted = { .fd = from, .events = os::POLLIN };
		CInt ready = os::poll(&wanted, 1, ended ? 0 : 250);
		if (ready > 0)
		{
			sz got = libc::read(from, &buffer, buffer.len);
			if (got <= 0) break;
			char[] bytes = buffer[:got];
			write_all(1, bytes);
			@pool()
			{
				char[16] clock;
				DString stamped;
				stamped.tinit();
				stamp_lines(&stamped, bytes, &at_line_start, clock_stamp(&clock));
				write_all(log_fd, stamped.str_view());
			};
			continue;
		}
		// Nothing left to read from a Rigsmith that has gone.
		if (ended) break;
		if (posix::waitpid(child, &status, posix::WNOHANG) == child) ended = true;
	}
	if (!at_line_start) write_all(log_fd, "\n");
	if (!ended) posix::waitpid(child, &status, 0);
	return status;
}

module crig @feat(!LINUX) @feat(!DARWIN);

fn bool watch_run(String[] args, int* exit_code) => false;
