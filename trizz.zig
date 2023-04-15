const std = @import("std");

var bufWriter = std.io.bufferedWriter(std.io.getStdOut().writer());
const stdout = bufWriter.writer();

const FileArrayList = std.ArrayList(std.fs.IterableDir.Entry);

const GeneralPurposeAllocator = std.heap.GeneralPurposeAllocator;

fn cmp(context: void, a: std.fs.IterableDir.Entry, b: std.fs.IterableDir.Entry) bool {
    _ = context;
    var i: usize = 0;

    while ((i < a.name.len) and (i < b.name.len)) : (i += 1) {
        const ai = std.ascii.toLower(a.name[i]);
        const bi = std.ascii.toLower(b.name[i]);

        if (ai < bi) {
            return true;
        } else if (ai > bi) {
            return false;
        }
    }

    return a.name.len < b.name.len;
}

const Counts = struct {
    dir_count: usize,
    file_count: usize,
};

fn printNode(entryName: []const u8, level: usize, last: bool, colour: []const u8) !void {
    for (0..level) |_| _ = try stdout.write("│   ");
    _ = try stdout.write(if (last) "└── " else "├── ");
    _ = try stdout.write(colour);
    _ = try stdout.write(entryName);
    _ = try stdout.write("\n");
    _ = try stdout.write("\x1b[0m"); // reset escape code
}

fn walk(allocator: *const std.mem.Allocator, path: []u8, filePathBuf: []u8, cap: usize, level: usize, dirs: usize, files: usize) !Counts {
    var dir_count = dirs;
    var file_count = files;

    var entries = FileArrayList.init(allocator.*);
    defer entries.deinit();
    var dir = try std.fs.cwd().openIterableDir(path, .{});
    defer dir.close();
    var it = dir.iterate();

    while (try it.next()) |entry|
        if (!std.mem.startsWith(u8, entry.name, "."))
            try entries.append(entry);

    std.sort.sort(std.fs.IterableDir.Entry, entries.items, {}, cmp);

    for (1.., entries.items) |i, entry| {
        const last = i == entries.items.len;

        switch (entry.kind) {
            .Directory => {
                try printNode(entry.name, level, last, "\x1b[1;34m"); // bold blue escape code
                var slice = try std.fmt.bufPrint(path.ptr[0..cap], "{s}/{s}", .{ path, entry.name });
                const res = try walk(allocator, slice, filePathBuf, cap, level + 1, dir_count + 1, file_count);

                dir_count = res.dir_count;
                file_count = res.file_count;
            },
            .File => {
                const newFileBuf = try std.fmt.bufPrint(filePathBuf.ptr[0..cap], "{s}/{s}", .{ path, entry.name });
                newFileBuf.ptr[newFileBuf.len] = 0;

                var colour = if (std.os.linux.access(@ptrCast([*:0]const u8, newFileBuf.ptr), 1) == 0)
                    "\x1b[1;32m"
                else
                    "";
                try printNode(entry.name, level, last, colour);
                file_count += 1;
            },
            else => {},
        }
    }

    try bufWriter.flush();
    return .{ .dir_count = dir_count, .file_count = file_count };
}

pub fn main() !void {
    var gpa = GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(!gpa.deinit());
    const allocator = gpa.allocator();

    _ = try stdout.write(".\n");
    var pathBuf: [4096]u8 = undefined;
    var filePathBuf: [4096]u8 = undefined;
    const initialPath = try std.fmt.bufPrint(&pathBuf, ".", .{});
    const res = try walk(&allocator, initialPath, &filePathBuf, 4096, 0, 0, 0);

    const dirs = res.dir_count;
    const files = res.file_count;

    const dirstxt = if (dirs == 1) "directory" else "directories";
    const filestxt = if (files == 1) "file" else "files";
    _ = try stdout.print("{d} {s}, {d} {s}\n", .{ dirs, dirstxt, files, filestxt });
    try bufWriter.flush();
}
