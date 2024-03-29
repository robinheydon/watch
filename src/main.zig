///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////

const std = @import("std");
const builtin = @import("builtin");

///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////

var read_buffer: [64 * 1024]u8 = undefined;
var current_output : std.ArrayList (u8) = undefined;
var last_output : std.ArrayList (u8) = undefined;
var start_time : i64 = 0;
var display_update_required : bool = true;
var running : bool = true;

const Range = struct {
    start : usize,
    end : usize,
};

var current_lines : std.ArrayList (Range) = undefined;
var last_lines : std.ArrayList (Range) = undefined;
var last_size : TerminalSize = .{};

var follow_end : bool = false;

var line_offset : usize = 0;
var number_lines : usize = 0;

var interval : f32 = 2.0;

var command_line : []u8 = undefined;

var exit_buffer : [1024]u8 = undefined;
var exit_message : ?[]const u8 = null;

///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////

const ms = std.time.ns_per_ms;

///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////

fn set_nonblock(handle: std.os.fd_t) !void {
    _ = try std.os.fcntl(handle, std.os.system.F.SETFL, std.os.system.O.NONBLOCK);
}

///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////

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

///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////

var stdout_handle : std.fs.File = undefined;
var stdout : std.fs.File.Writer = undefined;

var stdin : std.fs.File = undefined;

///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////

var child : ?std.ChildProcess = null;

var debug_message : [1024]u8 = undefined;
var debug_len : usize = 0;

///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////

fn intSigHandler(_: c_int) callconv(.C) void {
    end_screen ();
    end_input ();
    if (child) |*process|
    {
        const term = process.kill ();
        std.debug.print ("{!}\n", .{term});
    }
    std.process.exit (0);
}

///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();

    stdout_handle = std.io.getStdOut ();
    stdout = stdout_handle.writer ();

    stdin = std.io.getStdIn ();
    try set_nonblock (stdin.handle);

    debug_len = 0;

    var command_only = false;
    var show_help = false;
    var next_interval = false;

    for (args[1..]) |arg| {
        if (next_interval)
        {
            next_interval = false;
            interval = try std.fmt.parseFloat (f32, arg);
        }
        else if (command_only)
        {
            try argv.append(arg);
        }
        else if (std.mem.eql (u8, arg, "-n"))
        {
            next_interval = true;
        }
        else if (std.mem.eql (u8, arg, "-h"))
        {
            show_help = true;
        }
        else
        {
            command_only = true;
            try argv.append(arg);
        }
    }

    if (show_help)
    {
        std.debug.print (
            \\watch [options] [command]
            \\
            \\  options:
            \\   -n (num)            set interval between execution to be (num) seconds
            \\   -h                  show this help
            \\
            , .{}
        );
        std.process.exit (0);
    }

    current_output = std.ArrayList(u8).init(allocator);
    defer current_output.deinit();

    last_output = std.ArrayList(u8).init(allocator);
    defer last_output.deinit();

    current_lines = std.ArrayList(Range).init(allocator);
    defer current_lines.deinit();

    last_lines = std.ArrayList(Range).init(allocator);
    defer last_lines.deinit();

    start_time = std.time.milliTimestamp ();

    if (argv.items.len == 0)
    {
        std.debug.print ("No command to watch\n", .{});
        std.process.exit (1);
    }

    const int = std.os.system.Sigaction{
        // We set handler to a noop function instead of SIG.IGN so we don't leak our
        // signal disposition to a child process
        .handler = .{ .handler = intSigHandler },
        .mask = std.os.system.empty_sigset,
        .flags = 0,
    };

    var buffer = std.ArrayList (u8).init (allocator);
    var writer = buffer.writer ();
    for (0.., argv.items) |i,arg|
    {
        if (i > 0)
        {
            try writer.writeAll (" ");
        }
        try writer.print ("{s}", .{arg});
    }

    command_line = buffer.items;
    defer buffer.deinit ();

    const err = std.os.system.sigaction (std.os.SIG.INT, &int, null);
    std.debug.assert (err == 0);

    defer show_exit_message ();

    start_screen ();
    defer end_screen ();

    start_input ();
    defer end_input ();

    current_output.clearRetainingCapacity();
    update_display ();

    while (running) {
        child = std.ChildProcess.init(argv.items, allocator);
        child.?.stdin_behavior = .Ignore;
        child.?.stdout_behavior = .Pipe;
        child.?.stderr_behavior = .Pipe;

        try child.?.spawn();

        try set_nonblock(child.?.stdout.?.handle);
        try set_nonblock(child.?.stderr.?.handle);

        var stdout_eof = false;
        var stderr_eof = false;

        while (running and (stdout_eof == false or stderr_eof == false)) {
            const last_len = current_output.items.len;

            stdout_eof = try read_pipe(child.?.stdout.?.handle, &current_output);
            stderr_eof = try read_pipe(child.?.stderr.?.handle, &current_output);

            if (current_output.items.len != last_len) {
                display_update_required = true;
            }

            process_input ();
            update_display ();

            std.time.sleep(100 * ms);
        }

        if (running == false)
        {
            _ = try child.?.kill ();
        }

        _ = child.?.wait() catch |child_err|
        {
            exit_message = std.fmt.bufPrint (&exit_buffer, "Error: {s}", .{@errorName (child_err)}) catch { return; };
            running = false;
        };
        child = null;

        last_output.clearRetainingCapacity();
        try last_output.appendSlice (current_output.items);
        current_output.clearRetainingCapacity();
        display_update_required = true;

        const start_wait = std.time.milliTimestamp ();

        while (running and std.time.milliTimestamp () - start_wait < @as(i64, @intFromFloat (1000 * interval)))
        {
            process_input ();
            update_display ();

            std.time.sleep(100 * ms);
        }
    }
}

///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////

fn show_exit_message () void
{
    if (exit_message) |msg|
    {
        std.debug.print ("{s}\n", .{msg});
    }
}

///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////

const KeyBinding = struct
{
    data : []const u8,
    callback : *const fn () void,
};

const keys = &[_]KeyBinding {
    .{ .data = "\x03", .callback = do_control_c },
    .{ .data = "\x0c", .callback = do_control_l },
    .{ .data = "h", .callback = do_first_line },
    .{ .data = "j", .callback = do_down_line },
    .{ .data = "k", .callback = do_up_line },
    .{ .data = "\x1b[H", .callback = do_first_line },
    .{ .data = "\x1b[F", .callback = do_last_line },
    .{ .data = "\x1b[A", .callback = do_up_line },
    .{ .data = "\x1b[B", .callback = do_down_line },
    .{ .data = "\x1b[5~", .callback = do_page_up },
    .{ .data = "\x1b[6~", .callback = do_page_down },
    .{ .data = "l", .callback = do_last_line },
    .{ .data = " ", .callback = do_follow },
};

///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////

fn process_input () void
{
    var buffer: [1024]u8 = undefined;
    const len = stdin.read (&buffer) catch |err| {
        if (err == error.WouldBlock)
        {
            return;
        }
        const out = std.fmt.bufPrint (&debug_message, "{}", .{err}) catch { return; };
        debug_len = out.len;
        return;
    };

    if (len == 0)
    {
        return;
    }

    var processed : bool = false;
    var index : usize = 0;

    while (index < len)
    {
        for (keys) |key|
        {
            if (index + key.data.len <= len)
            {
                if (std.mem.eql (u8, key.data, buffer[index .. index + key.data.len]))
                {
                    key.callback ();
                    processed = true;
                    index += key.data.len - 1;
                    break;
                }
            }
        }

        index += 1;
    }

    if (processed == false)
    {
        const out = std.fmt.bufPrint (&debug_message, "{}", .{std.zig.fmtEscapes (buffer[0..len])}) catch { return; };
        debug_len = out.len;
    }
}

///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////

fn do_control_c () void
{
    running = false;
}

///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////

fn do_control_l () void
{
    display_update_required = true;
    move_to (0, 0);
    clear_to_end_of_screen ();
}

///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////

fn do_first_line () void
{
    line_offset = 0;
    follow_end = false;
    display_update_required = true;
}

///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////

fn do_page_up () void
{
    if (line_offset > last_size.rows - 2)
    {
        line_offset -= last_size.rows - 2;
    }
    else
    {
        line_offset = 0;
    }
    follow_end = false;
    display_update_required = true;
}

///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////

fn do_page_down () void
{
    line_offset += last_size.rows - 2;
    follow_end = false;
    display_update_required = true;
}

///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////

fn do_down_line () void
{
    line_offset += 1;
    follow_end = false;
    display_update_required = true;
}

///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////

fn do_up_line () void
{
    if (line_offset > 0)
    {
        line_offset -= 1;
    }
    follow_end = false;
    display_update_required = true;
}

///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////

fn do_last_line () void
{
    display_update_required = true;

    line_offset = @max (current_lines.items.len, last_lines.items.len) - 1;
    follow_end = false;
}

///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////

fn do_follow () void
{
    display_update_required = true;
    follow_end = true;
}

///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////

fn move_to (x: i32, y: i32) void
{
    stdout.print ("\x1B[{};{}H", .{ y+1, x+1 }) catch {};
}

///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////

const ColorSpec = struct {
    color: ?u8 = null,
    underline: bool = false,
};

fn set_color (cs: ColorSpec) void
{
    stdout.writeAll ("\x1B[m") catch {};

    if (cs.color) |col|
    {
        stdout.print ("\x1B[{}m", .{col}) catch {};
    }
    if (cs.underline)
    {
        stdout.writeAll ("\x1B[4m") catch {};
    }
    else
    {
        stdout.writeAll ("\x1B[24m") catch {};
    }
}

///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////

fn clear_to_end_of_line () void
{
    stdout.writeAll ("\x1B[K") catch {};
}

///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////

fn clear_to_end_of_screen () void
{
    stdout.writeAll ("\x1B[0J") catch {};
}

///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////

fn clear_screen () void
{
    stdout.writeAll ("\x1B[2J") catch {};
}

///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////

fn update_display () void
{
    const now = std.time.milliTimestamp ();
    const size = get_terminal_size ();

    if (size.cols != last_size.cols)
    {
        display_update_required = true;
        clear_screen ();
    }
    if (size.rows != last_size.rows)
    {
        display_update_required = true;
        clear_screen ();
    }

    last_size = size;

    const day : u64 = @intCast (@mod (now, 1000 * 60 * 60 * 24));
    const seconds = @divFloor (day, 1000);
    const sec = @mod (seconds, 60);
    const min = @mod (@divFloor (seconds, 60), 60);
    const hrs = @mod (@divFloor (seconds, 3600), 24);

    var time_buffer: [1024]u8 = undefined;

    number_lines = @max (current_lines.items.len, last_lines.items.len);

    const time = std.fmt.bufPrint (&time_buffer, "{d:0>2}:{d:0>2}:{d:0>2}", .{
        hrs, min, sec,
    }) catch {return;};

    move_to (0, 0);
    clear_to_end_of_line ();
    set_color (.{.color = 2, .underline = true});
    if (command_line.len + time.len + 3 < size.cols)
    {
        stdout.print ("{s}", .{command_line}) catch {};
        const fill = if (command_line.len + time.len + 3 > size.cols) 0 else @min (1024, size.cols - command_line.len - time.len - 3);
        const spaces = " " ** 1024;
        stdout.print ("{s}", .{spaces[0..fill]}) catch {};
    }
    if (time.len + 3 < size.cols)
    {
        if (child == null)
        {
            stdout.writeAll (" : ") catch {};
        }
        else
        {
            stdout.writeAll (" # ") catch {};
        }
        stdout.print ("{s}", .{time}) catch {};
    }
    set_color (.{});

    if (!display_update_required)
    {
        return;
    }

    calculate_lines (current_output.items, &current_lines, size.cols - 1);
    calculate_lines (last_output.items, &last_lines, size.cols - 1);

    number_lines = @max (current_lines.items.len, last_lines.items.len);

    if (follow_end)
    {
        if (number_lines < size.rows + 1)
        {
            line_offset = 0;
        }
        else
        {
            line_offset = number_lines - size.rows + 1;
        }
    }

    const empty = current_output.items.len == 0;

    set_color (.{});

    for (0..size.rows-1) |i|
    {
        const line = i + line_offset;

        move_to (1, @intCast (i + 1));
        clear_to_end_of_line ();

        if (line < current_lines.items.len)
        {
            const start_index = current_lines.items[line].start;
            const end_index = current_lines.items[line].end;
            stdout.print ("{s}", .{current_output.items[start_index .. end_index]}) catch {};
        }
        else if (line < last_lines.items.len)
        {
            const start_index = last_lines.items[line].start;
            const end_index = last_lines.items[line].end;
            stdout.print ("{s}", .{last_output.items[start_index .. end_index]}) catch {};
        }
        else
        {
        }
    }

    set_color (.{.color = 2, .underline = false});

    for (0..size.rows-1) |i|
    {
        const line = i + line_offset;
        move_to (0, @intCast (i + 1));

        if (line < current_lines.items.len)
        {
            stdout.writeAll ("+") catch {};
        }
        else if (line < last_lines.items.len)
        {
            if (empty)
            {
                stdout.writeAll (" ") catch {};
            }
            else
            {
                stdout.writeAll ("~") catch {};
            }
        }
        else
        {
            stdout.writeAll ("^") catch {};
        }
    }

    display_update_required = false;
}

///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////

fn calculate_lines (buffer: []const u8, lines: *std.ArrayList (Range), width: usize) void
{
    lines.clearRetainingCapacity ();

    var start : usize = 0;
    var index : usize = 0;
    var out_width : usize = 0;

    while (index < buffer.len)
    {
        switch (buffer[index])
        {
            '\x1b' =>
            {
                index += 1;

                while (index < buffer.len)
                {
                    const ch = buffer[index];

                    index += 1;

                    switch (ch)
                    {
                        '@', '`', '{', '|', '}', '~', 'a'...'z', 'A'...'Z' => break,
                        else => {}
                    }
                }
            },
            '\n' =>
            {
                lines.append (.{.start = start, .end = index}) catch {};
                out_width = 0;
                index += 1;
                start = index;
            },
            else =>
            {
                if (out_width < width)
                {
                    out_width += 1;
                }
                else
                {
                    lines.append (.{.start = start, .end = index}) catch {};
                    start = index;
                    out_width = 0;
                }
                index += 1;
            }
        }
    }
}

///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////

var original_term : std.os.termios = undefined;

fn start_input () void
{
    original_term = std.os.tcgetattr (stdin.handle) catch undefined;

    var term = std.mem.zeroes (std.os.termios);

    term.cflag |= std.os.linux.CREAD;
    term.iflag &= ~std.os.linux.BRKINT;
    term.iflag &= ~std.os.linux.ICRNL;
    term.iflag |= std.os.linux.IGNBRK;
    term.iflag |= std.os.linux.IGNCR;
    term.iflag &= ~std.os.linux.IXOFF;
    term.iflag &= ~std.os.linux.IXON;
    term.lflag &= ~std.os.linux.ECHO;
    term.lflag &= ~std.os.linux.ECHOE;
    term.lflag &= ~std.os.linux.ECHOK;
    term.lflag &= ~std.os.linux.ECHONL;
    term.lflag &= ~std.os.linux.ICANON;
    term.lflag &= ~std.os.linux.IEXTEN;
    term.lflag &= ~std.os.linux.ISIG;
    term.cc[std.os.linux.V.MIN] = 0;
    term.cc[std.os.linux.V.TIME] = 1;

    std.os.tcsetattr (stdin.handle, std.os.TCSA.NOW, term) catch {};
}

///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////

fn end_input () void
{
    std.os.tcsetattr (stdin.handle, std.os.TCSA.NOW, original_term) catch {};
}

///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////

fn start_screen () void
{
    // enter_ca_mode
    stdout.writeAll ("\x1B[?1049h\x1B[22;0;0t") catch {};
    // cursor_invisible
    stdout.writeAll ("\x1B[?25l") catch {};
    // enter_am_mode
    stdout.writeAll ("\x1B[?7l") catch {};
}

///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////

fn end_screen () void
{
    // exit_ca_mode
    stdout.writeAll ("\x1B[?1049l\x1B[23;0;0t") catch {};
    // cursor_visible
    stdout.writeAll ("\x1B[?12;25h") catch {};
    // exit_am_mode
    stdout.writeAll ("\x1B[?7h") catch {};
}

///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////

const TerminalSize = struct {
    rows : usize = 0,
    cols : usize = 0,
};

///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////

fn get_terminal_size () TerminalSize
{
    if (builtin.os.tag == .linux)
    {
        var size : std.os.linux.winsize = undefined;
        const err = std.os.linux.ioctl (stdout_handle.handle, std.os.linux.T.IOCGWINSZ, @intFromPtr (&size));
        if (err == 0)
        {
            return .{
                .rows = size.ws_row,
                .cols = size.ws_col,
            };
        }
        else
        {
            std.debug.print ("ioctl IOCGWINSZ {}\n", .{err});
            return .{};
        }
    }
    else if (builtin.os.tag == .macos)
    {
        var size : std.c.winsize = undefined;

        const err = std.c.ioctl (stdout_handle.handle, std.c.T.IOCGWINSZ, @intFromPtr (&size));
        if (err == 0)
        {
            return .{
                .rows = size.ws_row,
                .cols = size.ws_col,
            };
        }
        else
        {
            std.debug.print ("ioctl IOCGWINSZ {}\n", .{err});
            return .{};
        }
    }
    return .{};
}

///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////
