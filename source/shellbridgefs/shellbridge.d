module shellbridgefs.shellbridge;
import core.sys.posix.sys.stat : stat_t;
import std.format : format;
import std.process : Pid, Pipe;
import std.typecons : Tuple;
import std.uuid : UUID;

enum CommOsx {
	DD = "/bin/dd",
	STAT = "/usr/local/bin/gstat",
	LS = "/bin/ls",
	RM = "rm",
	TRUNCATE = "/usr/local/bin/gtruncate",
	MV = "mv",
}
enum CommLinux {
	DD = "dd",
	STAT = "stat",
	LS = "/bin/ls",
	RM = "rm",
	TRUNCATE = "truncate",
	MV = "mv",
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

string rawDataCommand2(const(ubyte)[] data) {
	import std.algorithm : among;
	import std.exception : assumeUnique;
	import std.random : uniform;

	string eofId = "EOF%08X".format(0.uniform(0xFFFFFFFF));
	ubyte[] r;
	r ~= "cat <(cat <<" ~ eofId ~ "\n";
	
	foreach(b; data) {
		if (b.among('`', '\\', '$')) {
			r ~= '\\';
		}
		r ~= b;
	}

	r ~= "\n" ~ eofId ~ "\n) | "~Comm.DD~" count=1 bs=%s".format(data.length);
	return cast(immutable(char)[])(r.assumeUnique);
}

string rawDataCommand(const(ubyte)[] data) {
	import std.base64 : Base64;

	return "echo %s | base64 -d".format(Base64.encode(data));
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

	Tuple!(stat_t, string, string)[] list(const(char)[] path) {
		import std.algorithm : countUntil, filter, map;
		import std.array : array;
		import std.range : chain;
		import std.string : split;
		import std.utf : toUTF32, toUTF8;

		enum fields = "%f %h %u %g %s %B %b %X %Y %Z %W %d %i/%N";
		auto statOutput = runCommand(Comm.STAT~" -c '%s' %2$s/.* %2$s/* %2$s/".format(fields, path.escape));
		return statOutput
		.filter!(x => x != "\n")
		.map!((statLine) {
			Tuple!(stat_t, string, string) r;
			size_t statNameBound = statLine.countUntil("/");
			auto stat = statLine[0..statNameBound].split(" ");
			auto link = statLine[statNameBound+1..$-1].toUTF32.split(" -> ");
			r[1] = link[0][1..$-1].toUTF8;
			if (link.length > 1) {
				r[2] = link[1][1..$-1].toUTF8;
			}

			void set(T, Args...)(ref T t, int idx, Args args) {
				import std.conv : to;

				t = stat[idx].to!(T)(args);
			}
			set(r[0].st_mode, 0, 16);
			set(r[0].st_nlink, 1);
			set(r[0].st_uid, 2);
			set(r[0].st_gid, 3);
			set(r[0].st_size, 4);
			set(r[0].st_blksize, 5);
			set(r[0].st_blocks, 6);
			set(r[0].st_atime, 7);
			set(r[0].st_mtime, 8);
			set(r[0].st_ctime, 9);
			set(r[0].st_birthtime, 10);
			set(r[0].st_dev, 11);
			set(r[0].st_ino, 12);

			return r;
		}).array;
	}
	
	immutable(ubyte)[] readChunkOld(const(char)[] path, ulong offset, ulong size) {
		import std.array : join;

		auto contents = runCommand(Comm.DD~" if=%s bs=1 skip=%s count=%s; echo".format(path.escape, offset, size)).join();
		return (cast(immutable(ubyte)[])contents)[0..$-1];
	}

	immutable(ubyte)[] readChunk(const(char)[] path, ulong offset, ulong size) {
		import std.base64 : Base64;
		
		auto contents = runCommand(Comm.DD~" if=%s bs=1 skip=%s count=%s | base64 -w 0; echo".format(path.escape, offset, size));
		return Base64.decode(contents[0][0..$-1]);
	}

	void truncate(const(char)[] path, ulong length) {
		runCommand(Comm.TRUNCATE~" --size=%s %s".format(length, path.escape));
	}

	void write(const(char)[] path, const(ubyte)[] data, ulong skip) {
		runCommand(rawDataCommand(data) ~ "| "~Comm.DD~" conv=notrunc seek=%s bs=1 of=%s".format(skip, path.escape));
	}

	void remove(const(char)[] path) {
		runCommand(Comm.RM~" %s".format(path.escape));
	}

	void rename(const(char)[] orig, const(char)[] dest) {
		runCommand(Comm.MV~" %s %s".format(orig.escape, dest.escape));
	}
}