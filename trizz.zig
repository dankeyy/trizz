const std = @import("std");

const fs = std.fs;
const os = std.os;
const io = std.io;
const sort = std.sort;
const ascii = std.ascii;

var bufWriter = std.io.bufferedWriter(std.io.getStdOut().writer());
const stdout = bufWriter.writer();

const FileArrayList = std.ArrayList(fs.IterableDir.Entry);

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


fn printNode(entryName: []const u8, level: usize, last: bool, colour: []const u8) !void {
    if (level != 0) {
        _ = try stdout.write("│   ");
    }
    if (level > 1){
        for(0..level-1) |_| _ = try stdout.write("    ");
    }
    _ = try stdout.write(if (last) "└── " else "├── ");
    _ = try stdout.write(colour);
    _ = try stdout.write(entryName);
    _ = try stdout.write("\n");
    _ = try stdout.write("\x1b[0m"); // reset escape code
}


fn walk(allocator: *const std.mem.Allocator, path: []const u8, level: usize, dirs: usize, files: usize) !Counts {
    var dir_count = dirs;
    var file_count = files;

    var entries = FileArrayList.init(allocator.*);
    defer entries.deinit();
    var dir = try fs.cwd().openIterableDir(path, .{});
    defer dir.close();
    var it = dir.iterate();

    while (try it.next()) |entry|
        if (!std.mem.startsWith(u8, entry.name, "."))
            try entries.append(entry);

    sort.sort(fs.IterableDir.Entry, entries.items, {}, cmp);

    for (1.., entries.items) |i, entry| {
        const last = i==entries.items.len;

        switch (entry.kind) {
            .Directory => {
                try printNode(entry.name, level, last, "\x1b[1;34m"); // bold blue escape code
                const res = try walk(allocator, entry.name, level + 1, dir_count + 1, file_count);
                dir_count = res.dir_count;
                file_count = res.file_count;
            },
            else => {
                try printNode(entry.name, level, last, "");
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

    _ = try stdout.write(".\n");
    const res = try walk(&allocator, ".", 0, 0, 0);
    const dirs = res.dir_count;
    const files = res.file_count;

    const dirstxt = if (dirs == 1) "directory" else "directories";
    const filestxt = if (files == 1) "file" else "files";
    _ = try stdout.print("{d} {s}, {d} {s}", .{ dirs, dirstxt, files, filestxt });
}
