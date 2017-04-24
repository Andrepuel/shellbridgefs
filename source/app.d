import errno = core.stdc.errno;
import dfuse.fuse : Fuse, FuseException, Operations, stat_t;
import shellbridgefs.queuecache : QueueCache;
import shellbridgefs.shellbridge : FileNotFound, ShellBridge;
import std.stdio;

class MyFS : Operations
{
	ShellBridge bridge;
	QueueCache!(string, stat_t) statCache;

	this(ShellBridge bridge) {
		this.bridge = bridge;
	}

	private stat_t stat(const(char)[] path) {
		return statCache.fetch(path.idup, () => bridge.stat(path));
	}

	override void getattr(const(char)[] path, ref stat_t s)
	{
		// debug stderr.writeln("getattr ", path);
		s = stat(path);
		if (s == stat_t.init) {
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
		return stat(path) != stat_t.init;
	}

	override int write(const(char)[] path, in ubyte[] data, ulong offset) {
		// debug stderr.writeln("write ", path, "[", offset, "..+", data.length, "]");
		bridge.write(path, data, offset);
		statCache.clear(path.idup);
		return cast(int)data.length;
	}

	override void truncate(const(char)[] path, ulong length) {
		// debug stderr.writeln("truncate ", path, " to ", length);
		bridge.truncate(path, length);
		statCache.clear(path.idup);
	}

	override void mknod(const(char)[] path, int mod, ulong dev)
	{
		// debug stderr.writeln("mknod", path);
		truncate(path, 0);
	}

	override void unlink(const(char)[] path) {
		bridge.remove(path);
		statCache.clear(path.idup);
	}

	override void rename(const(char)[] orig, const(char)[] dest) {
		bridge.rename(orig, dest);
		statCache.clear(orig.idup);
		statCache.clear(dest.idup);
	}

	override void exception(Exception e) {
		debug stderr.writeln(e);
	}
}

void main(string[] args) {
	import shellbridgefs.shellbridge : escape;
	
	string mountpath = args[1];
	ShellBridge bridge = new ShellBridge(args[2..$]);
	scope(exit) bridge.dispose();

	auto fs = new Fuse("MyFS", true, false);
	fs.mount(new MyFS(bridge), mountpath, [/*"allow_other"*/]);
}
