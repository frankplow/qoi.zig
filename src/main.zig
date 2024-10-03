const std = @import("std");
const root = @import("root.zig");

const Args = struct {
    help: bool,
    input_path: ?[]const u8,
    output_path: ?[]const u8,
};

const Error = error{
    InvalidUsage,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const dir = std.fs.cwd();
    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    const args = getArgs() catch |err| {
        switch (err) {
            Error.InvalidUsage => {
                _ = stderr.write("Error: Invalid usage\n\n") catch return err;
                printHelp(stderr.any()) catch return err;
                std.process.exit(1);
            },
            else => return err,
        }
    };

    if (args.help) {
        try printHelp(stdout.any());
        return;
    }

    var input_file = dir.openFile(args.input_path.?, std.fs.File.OpenFlags{ .mode = .read_only }) catch |err| {
        switch (err) {
            std.fs.File.OpenError.AccessDenied => {
                stderr.print("Error: Not permitted to read from {s}\n", .{ args.input_path.? }) catch return err;
                std.process.exit(1);
            },
            std.fs.File.OpenError.FileNotFound => {
                stderr.print("Error: Could not find file {s}\n", .{ args.input_path.? }) catch return err;
                std.process.exit(1);
            },
            else => return err,
        }
    };
    defer input_file.close();
    var reader = input_file.reader().any();

    const decoded_data = try root.readQOI(&reader, allocator);
    defer allocator.free(data);

    const output_file = dir.createFile(args.output_path.?, std.fs.File.CreateFlags{ .exclusive = true }) catch |err| {
        switch (err) {
            std.fs.File.OpenError.AccessDenied => {
                stderr.print("Error: Not permitted to write to {s}\n", .{ args.input_path.? }) catch return err;
                std.process.exit(1);
            },
            std.fs.File.OpenError.PathAlreadyExists => {
                stderr.print("Error: File {s} already exists\n", .{ args.input_path.? }) catch return err;
                std.process.exit(1);
            },
            else => return err,
        }
    };
    defer output_file.close();
    var writer = output_file.writer().any();
    for (decoded_data) |pixel| {
        try writer.writeStruct(pixel);
    }
}

fn getArgs() Error!Args {
    var args = std.process.args();
    // Skip argv[0] (the executable)
    _ = args.skip();
    var pos_args: [2]([]const u8) = undefined;
    var pos_arg_idx: usize = 0;
    var args_struct = Args{
        .help = false,
        .input_path = null,
        .output_path = null,
    };
    var arg = args.next();
    while (arg != null) : (arg = args.next()) {
        if (std.mem.eql(u8, arg.?, "-h") or std.mem.eql(u8, arg.?, "--help")) {
            args_struct.help = true;
            return args_struct;
        } else if (arg.?[0] == '-') {
            // Unrecognised flag
            return Error.InvalidUsage;
        } else {
            // Positional argument
            if (pos_arg_idx >= pos_args.len) return Error.InvalidUsage;
            pos_args[pos_arg_idx] = arg.?;
            pos_arg_idx += 1;
        }
    }
    if (pos_arg_idx < pos_args.len) return Error.InvalidUsage;
    args_struct.input_path = pos_args[0];
    args_struct.output_path = pos_args[1];
    return args_struct;
}

const usage = 
    \\Usage: qoi.zig [options] <input path> <output path>
    \\
    \\Options:
    \\  -h|--help: Print this help message
    \\
    ;

fn printHelp(writer: std.io.AnyWriter) anyerror!void {
    _ = try writer.write(usage);
}
