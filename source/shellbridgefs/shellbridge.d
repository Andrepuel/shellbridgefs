module shellbridgefs.shellbridge;
import core.sys.posix.sys.stat : stat_t;
import std.format : format;
import std.process : Pid, Pipe;
import std.uuid : UUID;

enum CommOsx {
	DD = "/bin/dd",
	STAT = "/usr/local/bin/gstat",
	LS = "/bin/ls",
	RM = "rm",
	TRUNCATE = "/usr/local/bin/gtruncate"
}
enum CommLinux {
	DD = "dd",
	STAT = "stat",
	LS = "/bin/ls",
	RM = "rm",
	TRUNCATE = "truncate"
}

alias Comm=CommLinux;

string escape(const(char)[] a) {
	import std.conv : to;
	return [a].to!string[1..$-1];
}

class FileNotFound : Exception {
	this() {
		super("FileNotFound");
	}
}

struct DelimitedRange(T) {
	T input;
	UUID id;

	string front;

	this(T inputArg, UUID id) {
		this.input = inputArg;
		this.id = id;

		while (front != "%s START\n".format(id.toString)) {
			popFront;
		}
		popFront;
	}

	bool empty() const {
		return front == "%s END\n".format(id.toString);
	}

	void popFront() {
		front = input.readln.idup;
	}
}
DelimitedRange!T delimitedRange(T)(T inputArg, UUID id) {
	return DelimitedRange!T(inputArg, id);
}

string rawDataCommand(const(ubyte)[] data) {
	import std.algorithm : among;
	import std.exception : assumeUnique;
	import std.random : uniform;

	string eofId = "EOF%08X".format(0.uniform(0xFFFFFFFF));
	ubyte[] r;
	r ~= "cat <(cat <<" ~ eofId ~ "\n";
	
	foreach(b; data) {
		if (b.among('`', '\\', '"', '\'')) {
			r ~= '\\';
		}
		r ~= b;
	}

	r ~= "\n" ~ eofId ~ "\n) | "~Comm.DD~" count=1 bs=%s 2>/dev/null".format(data.length);
	return cast(immutable(char)[])(r.assumeUnique);
}

class ShellBridge {
	Pipe stdin;
	Pipe stdout;
	Pid shell;

	this(string[] command) {
		import std.process : spawnProcess, pipe;

		stdin = pipe();
		stdout = pipe();
		shell = spawnProcess(command, stdin.readEnd, stdout.writeEnd);
	}

	void dispose() {
		import std.process : wait;

		stdin.writeEnd.close();
		shell.wait();
	}

	string[] runCommand(string command) {
		import std.array : array;
		import std.uuid : randomUUID;

		debug import std.stdio;
		debug stderr.writeln(command.escape);
		
		UUID commandId = randomUUID;
		stdin.writeEnd.write("echo %s START; %s; echo %s END\n".format(commandId, command, commandId));
		stdin.writeEnd.flush();
		auto r = delimitedRange(stdout.readEnd, commandId).array;
		debug import std.algorithm;
		debug r.each!(x => stderr.writeln(x.escape));
		return r;
	}

	string[] list(const(char)[] path) {
		import std.algorithm : map;
		import std.array : array;
		import std.range : chain;

		return [".", ".."].chain(runCommand(Comm.LS~" %s".format(path.escape)).map!(x => x[0..$-1])).array;
	}
	
	stat_t stat(const(char)[] path) {
		import std.array : array;
		import std.conv : to;
		import std.range : empty, front;
		import std.string : split;

		enum fields = "%f %h %u %g %s %B %b %X %Y %Z %W %d %i";
		auto statOutput = runCommand(Comm.STAT~" -c '%s' %s".format(fields, path.escape));
		if (statOutput.empty) {
			throw new FileNotFound;
		}
		auto stat = statOutput.front[0..$-1].split(" ");
		void set(T, Args...)(ref T t, int idx, Args args) {
			import std.conv : to;

			t = stat[idx].to!(T)(args);
		}
		stat_t r;
		set(r.st_mode, 0, 16);
		set(r.st_nlink, 1);
		set(r.st_uid, 2);
		set(r.st_gid, 3);
		set(r.st_size, 4);
		set(r.st_blksize, 5);
		set(r.st_blocks, 6);
		set(r.st_atime, 7);
		set(r.st_mtime, 8);
		set(r.st_ctime, 9);
		set(r.st_birthtime, 10);
		set(r.st_dev, 11);
		set(r.st_ino, 12);

		return r;
	}

	immutable(ubyte)[] readChunk(const(char)[] path, ulong offset, ulong size) {
		import std.array : join;

		auto contents = runCommand(Comm.DD~" if=%s bs=1 skip=%s count=%s 2>/dev/null; echo".format(path.escape, offset, size)).join();
		return (cast(immutable(ubyte)[])contents)[0..$-1];
	}

	string readLink(const(char)[] path) {
		import std.string : split;
		import std.utf : toUTF32, toUTF8;

		auto link = runCommand(Comm.STAT~" -c %s %s".format("%N", path.escape))[0][0..$-1].toUTF32.split(" -> ");
		return link[$-1][1..$-1].toUTF8;
	}

	void truncate(const(char)[] path, ulong length) {
		runCommand(Comm.TRUNCATE~" --size=%s %s".format(length, path.escape));
	}

	void write(const(char)[] path, const(ubyte)[] data, ulong skip) {
		runCommand(rawDataCommand(data) ~ "| "~Comm.DD~" conv=notrunc iseek=%s bs=1 of=%s 2>/dev/null".format(skip, path.escape));
	}

	void remove(const(char)[] path) {
		runCommand(Comm.RM~" %s".format(path.escape));
	}
}