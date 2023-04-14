const std = @import("std");
const fs = std.fs;
const os = std.os;
const io = std.io;
const sort = std.sort;
const ascii = std.ascii;

var bufWriter = std.io.bufferedWriter(std.io.getStdOut().writer());
const stdout = bufWriter.writer();

const FileArrayList = std.ArrayList(fs.IterableDir.Entry);
const asc_u8 = sort.asc(u8);
const GeneralPurposeAllocator = std.heap.GeneralPurposeAllocator;

fn cmp(context: void, a: fs.IterableDir.Entry, b: fs.IterableDir.Entry) bool {
    _ = context;
    var i: usize = 0;

    while ((i < a.name.len) and (i < b.name.len)) : (i += 1) {
        const ai = ascii.toLower(a.name[i]);
        const bi = ascii.toLower(b.name[i]);

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

fn walk(allocator: *const std.mem.Allocator, path: []const u8, level: usize, dirs: usize, files: usize) !Counts {
    var len: usize = 0;
    _ = len;
    var dir_count = dirs;
    var file_count = files;

    var entries = FileArrayList.init(allocator.*);
    defer entries.deinit();
    var dir = try fs.cwd().openIterableDir(path, .{});
    defer dir.close();
    var it = dir.iterate();

    while (try it.next()) |entry| {
        if (std.mem.startsWith(u8, entry.name, ".")) {
            continue;
        }
        try entries.append(entry);
    }

    sort.sort(fs.IterableDir.Entry, entries.items, {}, cmp);
    for (1.., entries.items) |i, entry| {
        for (0..level) |_| _ = try stdout.write("│   ");
        if (i == entries.items.len) {
            _ = try stdout.print("└── {s}\n", .{entry.name});
        } else {
            _ = try stdout.print("├── {s}\n", .{entry.name});
        }

        switch (entry.kind) {
            .Directory => {
                const res = try walk(allocator, entry.name, level + 1, dir_count + 1, file_count);
                dir_count = res.dir_count;
                file_count = res.file_count;
            },
            else => {
                file_count += 1;
            },
        }
    }

    try bufWriter.flush();
    return .{ .dir_count = dir_count, .file_count = file_count };
}

pub fn main() !void {
    var gpa = GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(!gpa.deinit());
    const allocator = gpa.allocator();

    // var entryBuf: [256]u8 = undefined;
    _ = try stdout.write(".\n");
    const res = try walk(&allocator, ".", 0, 0, 0);
    const dirs = res.dir_count;
    const files = res.file_count;

    const dirstxt = if (dirs == 1) "directory" else "directories";
    const filestxt = if (files == 1) "file" else "files";
    _ = try stdout.print("{d} {s}, {d} {s}", .{ dirs, dirstxt, files, filestxt });
}
