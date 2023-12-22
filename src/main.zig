const std = @import("std");

var read_buffer: [64 * 1024]u8 = undefined;

const ms = std.time.ns_per_ms;

fn set_nonblock(handle: std.os.fd_t) !void {
    _ = try std.os.fcntl(handle, std.os.system.F.SETFL, std.os.system.O.NONBLOCK);
}

fn read_pipe(handle: std.os.fd_t, output: *std.ArrayList(u8)) !bool {
    const size_read: usize = std.os.read(handle, &read_buffer) catch |err| blk: {
        switch (err) {
            error.WouldBlock => break :blk std.math.maxInt(usize),
            else => return err,
        }
    };

    if (size_read == 0) {
        // end of file
        return true;
    } else if (size_read == std.math.maxInt(usize)) {
        // would block
        return false;
    } else {
        // normal read success
        try output.*.appendSlice(read_buffer[0..size_read]);
        return false;
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();

    for (args[1..]) |arg| {
        try argv.append(arg);
    }

    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();

    while (true) {
        var child = std.ChildProcess.init(argv.items, allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();

        try set_nonblock(child.stdout.?.handle);
        try set_nonblock(child.stderr.?.handle);

        var stdout_eof = false;
        var stderr_eof = false;

        while (stdout_eof == false or stderr_eof == false) {
            const last_len = output.items.len;

            stdout_eof = try read_pipe(child.stdout.?.handle, &output);
            stderr_eof = try read_pipe(child.stderr.?.handle, &output);

            std.time.sleep(50 * ms);

            if (output.items.len != last_len) {
                std.debug.print("\n'{'}'\n", .{std.zig.fmtEscapes(output.items)});
            }
        }

        const term = try child.wait();
        _ = term;

        if (output.items.len > 0) {
            std.debug.print("\n'{'}'\n", .{std.zig.fmtEscapes(output.items)});
        }

        output.clearRetainingCapacity();
    }
}
