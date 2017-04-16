import errno = core.stdc.errno;
import dfuse.fuse : Fuse, FuseException, Operations, stat_t;
import shellbridgefs.shellbridge : FileNotFound, ShellBridge;
import std.stdio;

class MyFS : Operations
{
	ShellBridge bridge;
	this(ShellBridge bridge) {
		this.bridge = bridge;
	}

	override void getattr(const(char)[] path, ref stat_t s)
	{
		try {
			// debug stderr.writeln("getattr ", path);
			s = bridge.stat(path);
			// debug stderr.writeln(s);
		} catch(FileNotFound) {
			throw new FuseException(errno.ENOENT);
		}
	}
	
	override string[] readdir(const(char)[] path)
	{
		// debug stderr.writeln("readdir ", path);
		return bridge.list(path);
	}
	
	override ulong read(const(char)[] path, ubyte[] buf, ulong offset)
	{
		import std.algorithm : min;

		// debug stderr.writeln("read ", path);

		auto read = bridge.readChunk(path, offset, buf.length);
		buf[0..$.min(read.length)] = read;
		return read.length;
	}

	override ulong readlink(const(char)[] path, ubyte[] buf) {
		auto link = bridge.readLink(path);
		assert(buf.length >= link.length);
		buf[0..link.length] = cast(const(ubyte)[])link;
		// debug stderr.writeln("link of ", path, " is ", link);
		return link.length;
	}

	override bool access(const(char)[] path, int mode) {
		// debug stderr.writeln("try access ", path, " with ", mode);
		try {
			bridge.stat(path);
			// debug writeln("yes");
			return true;
		} catch(FileNotFound) {
			// debug writeln("nopes");
			return false;
		}
	}

	override int write(const(char)[] path, in ubyte[] data, ulong offset) {
		// debug stderr.writeln("write ", path, "[", offset, "..+", data.length, "]");
		bridge.write(path, data, offset);
		return cast(int)data.length;
	}

	override void truncate(const(char)[] path, ulong length) {
		// debug stderr.writeln("truncate ", path, " to ", length);
		bridge.truncate(path, length);
	}

	override void mknod(const(char)[] path, int mod, ulong dev)
	{
		truncate(path, 0);
	}

	override void unlink(const(char)[] path) {
		bridge.remove(path);
	}
}

void main(string[] args) {
	import shellbridgefs.shellbridge : escape;
	
	string mountpath = args[1];
	ShellBridge bridge = new ShellBridge(args[2..$]);
	scope(exit) bridge.dispose();

	auto fs = new Fuse("MyFS", true, false);
	fs.mount(new MyFS(bridge), mountpath, ["allow_other"]);
}