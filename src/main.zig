const std = @import("std");

var read_buffer: [64*1024]u8 = undefined;

const ms = std.time.ns_per_ms;

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

    var child = std.ChildProcess.init(argv.items, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    _ = try std.os.fcntl (child.stdout.?.handle, std.os.system.F.SETFL, std.os.system.O.NONBLOCK);
    _ = try std.os.fcntl (child.stderr.?.handle, std.os.system.F.SETFL, std.os.system.O.NONBLOCK);

    var stdout_eof = false;
    var stderr_eof = false;
    var output_updated = false;

    while (stdout_eof == false or stderr_eof == false)
    {
        {
            const size_read : usize = std.os.read (child.stdout.?.handle, &read_buffer) catch |err| blk: {
                switch (err)
                {
                    error.WouldBlock => break :blk std.math.maxInt (usize),
                    else => return err
                }
            };

            if (size_read == 0) // end of file
            {
                stdout_eof = true;
            }
            else if (size_read == std.math.maxInt (usize)) // would block
            {
            }
            else
            {
                try output.appendSlice (read_buffer[0..size_read]);
                output_updated = true;
            }
        }
        {
            const size_read : usize = std.os.read (child.stderr.?.handle, &read_buffer) catch |err| blk: {
                switch (err)
                {
                    error.WouldBlock => break :blk std.math.maxInt (usize),
                    else => return err
                }
            };

            if (size_read == 0) // end of file
            {
                stderr_eof = true;
            }
            else if (size_read == std.math.maxInt (usize)) // would block
            {
            }
            else
            {
                try output.appendSlice (read_buffer[0..size_read]);
                output_updated = true;
            }
        }

        std.time.sleep (250 * ms);

        if (output_updated)
        {
            std.debug.print("\n'{'}'\n", .{std.zig.fmtEscapes(output.items)});
            output_updated = false;
        }
    }

    const term = try child.wait();
    _ = term;

    if (output.items.len > 0) {
        std.debug.print("\n'{'}'\n", .{std.zig.fmtEscapes(output.items)});
    }
}
