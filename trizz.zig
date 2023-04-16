const std = @import("std");

var bufWriter = std.io.bufferedWriter(std.io.getStdOut().writer());
const stdout = bufWriter.writer();

const FileArrayList = std.ArrayList(std.fs.IterableDir.Entry);

const Counts = struct {
    dir_count: usize,
    file_count: usize,
};

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

fn printNode(entryName: []const u8, level: usize, last: bool, colour: []const u8, symlinkedTo: ?[]u8) !void {
    // _ = try stdout.write("│   ");
    // std.debug.print("\n{any}\n", .{last});
    for (0..level) |_| _ = try stdout.write("│   ");

    _ = try stdout.write(if (last) "└── " else "├── ");
    _ = try stdout.write(colour);
    _ = try stdout.write(entryName);
    _ = try stdout.write("\x1b[0m"); // reset escape code
    if (symlinkedTo != null) {
        _ = try stdout.write(" -> ");
        _ = try stdout.write(symlinkedTo.?);
    }
    _ = try stdout.write("\n");
}

inline fn printAndCount(entry: std.fs.IterableDir.Entry, nameBuf: []u8, filePathBuf: []u8, path: []u8, cap: usize, level: usize, last: bool, c: *Counts) !void {
    switch (entry.kind) {
        .Directory => {
            c.dir_count += 1;
            try printNode(entry.name, level, last, "\x1b[1;34m", null); // bold blue
            var slice = try std.fmt.bufPrint(path.ptr[0..cap], "{s}/{s}", .{ path, entry.name });
            const res = try walkUnsorted(nameBuf, slice, filePathBuf, cap, level + 1);

            c.dir_count += res.dir_count;
            c.file_count += res.file_count;
        },

        .File => {
            const newFileBuf = try std.fmt.bufPrint(filePathBuf.ptr[0..cap], "{s}/{s}", .{ path, entry.name });
            newFileBuf.ptr[newFileBuf.len] = 0;

            var colour = if (std.os.linux.access(@ptrCast([*:0]const u8, newFileBuf.ptr), 1) == 0) // executable
                "\x1b[1;32m" // bold green
            else
                "";
            try printNode(entry.name, level, last, colour, null);
            c.file_count += 1;
        },
        .SymLink => {
            const newFileBuf = try std.fmt.bufPrint(filePathBuf.ptr[0..cap], "{s}/{s}", .{ path, entry.name });
            const linked = try std.os.readlink(newFileBuf, filePathBuf);
            try printNode(entry.name, level, last, "\x1b[1;35m", linked); // bold purple-ish
            c.file_count += 1;
        },
        .BlockDevice, .CharacterDevice => {
            try printNode(entry.name, level, last, "\x1b[1;33m", null); // bold yellow
            c.file_count += 1;
        },
        .NamedPipe => {
            try printNode(entry.name, level, last, "\x1b[38;5;214m", null); // regular gold-ish
            c.file_count += 1;
        },
        .UnixDomainSocket => {
            try printNode(entry.name, level, last, "\x1b[38;5;208m", null); // regular orange
            c.file_count += 1;
        },

        else => {
            // who cares about whiteout/ doors/ eventports/ unknown anyway
            try printNode(entry.name, level, last, "\x1b[1;90m", null); // bold black
            c.file_count += 1;
        },
    }
}

inline fn cpy(nameBuf: []u8, nextEntry: *const std.fs.IterableDir.Entry) std.fs.IterableDir.Entry {
    @memcpy(nameBuf.ptr, nextEntry.name.ptr, nextEntry.name.len);
    return std.fs.IterableDir.Entry{
        .name = nameBuf[0..nextEntry.name.len],
        .kind = nextEntry.kind,
    };
}

fn walkUnsorted(nameBuf: []u8, path: []u8, filePathBuf: []u8, cap: usize, level: usize) !Counts {
    var counts = Counts{ .dir_count = 0, .file_count = 0 };

    var dir = try std.fs.cwd().openIterableDir(path, .{});
    defer dir.close();
    var it = dir.iterate();
    var entryData: std.fs.IterableDir.Entry = undefined;

    var iteratorData = try it.next();
    if (iteratorData != null) {
        entryData = iteratorData.?;
    } else {
        return counts;
    }

    var entry: std.fs.IterableDir.Entry = cpy(nameBuf, &entryData);

    while (try it.next()) |nextEntry| {
        if (!std.mem.startsWith(u8, entry.name, ".")) {
            try printAndCount(entry, nameBuf, filePathBuf, path, cap, level, false, &counts);
        }
        entry = cpy(nameBuf, &nextEntry);
    }
    try printAndCount(entry, nameBuf, filePathBuf, path, cap, level, true, &counts);

    try bufWriter.flush();
    return counts;
}

fn walkSorted(allocator: *const std.mem.Allocator, path: []u8, filePathBuf: []u8, cap: usize, level: usize) !Counts {
    var dir_count: usize = 0;
    var file_count: usize = 0;

    var entries = FileArrayList.init(allocator.*);
    defer entries.deinit();
    var dir = try std.fs.cwd().openIterableDir(path, .{});
    defer dir.close();
    var it = dir.iterate();

    while (try it.next()) |entry| {
        if (!std.mem.startsWith(u8, entry.name, ".")) {
            try entries.append(std.fs.IterableDir.Entry{
                .name = try allocator.dupe(u8, entry.name),
                .kind = entry.kind,
            });
        }
    }

    std.sort.sort(std.fs.IterableDir.Entry, entries.items, {}, cmp);

    for (1.., entries.items) |i, entry| {
        const last = i == entries.items.len;

        switch (entry.kind) {
            .Directory => {
                try printNode(entry.name, level, last, "\x1b[1;34m", null); // bold blue escape code
                var slice = try std.fmt.bufPrint(path.ptr[0..cap], "{s}/{s}", .{ path, entry.name });
                const res = try walkSorted(allocator, slice, filePathBuf, cap, level + 1);

                dir_count += res.dir_count + 1;
                file_count += res.file_count;
            },

            .File => {
                const newFileBuf = try std.fmt.bufPrint(filePathBuf.ptr[0..cap], "{s}/{s}", .{ path, entry.name });
                newFileBuf.ptr[newFileBuf.len] = 0;

                var colour = if (std.os.linux.access(@ptrCast([*:0]const u8, newFileBuf.ptr), 1) == 0) // executable
                    "\x1b[1;32m" // bold green
                else
                    "";
                try printNode(entry.name, level, last, colour, null);
                file_count += 1;
            },
            .SymLink => {
                const newFileBuf = try std.fmt.bufPrint(filePathBuf.ptr[0..cap], "{s}/{s}", .{ path, entry.name });
                const linked = try std.os.readlink(newFileBuf, filePathBuf);
                try printNode(entry.name, level, last, "\x1b[1;35m", linked); // bold purple-ish
                file_count += 1;
            },
            .BlockDevice, .CharacterDevice => {
                try printNode(entry.name, level, last, "\x1b[1;33m", null); // bold yellow
                file_count += 1;
            },
            .NamedPipe => {
                try printNode(entry.name, level, last, "\x1b[38;5;214m", null); // regular gold-ish
                file_count += 1;
            },
            .UnixDomainSocket => {
                try printNode(entry.name, level, last, "\x1b[38;5;208m", null); // regular orange
                file_count += 1;
            },

            else => {
                // who cares about whiteout/ doors/ eventports/ unknown anyway
                try printNode(entry.name, level, last, "\x1b[1;90m", null); // bold black
                file_count += 1;
            },
        }
    }

    try bufWriter.flush();
    return .{ .dir_count = dir_count, .file_count = file_count };
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    _ = allocator;

    _ = try stdout.write(".\n");
    var pathBuf: [4096]u8 = undefined;
    const initialPath = try std.fmt.bufPrint(&pathBuf, ".", .{});
    var filePathBuf: [4096]u8 = undefined;
    var nameBuf: [255]u8 = undefined;

    // const res = try walkSorted(&allocator, initialPath, &filePathBuf, 4096, 0);
    const res = try walkUnsorted(&nameBuf, initialPath, &filePathBuf, 4096, 0);

    const dirs = res.dir_count;
    const files = res.file_count;

    const dirstxt = if (dirs == 1) "directory" else "directories";
    const filestxt = if (files == 1) "file" else "files";
    _ = try stdout.print("\n{d} {s}, {d} {s}\n", .{ dirs, dirstxt, files, filestxt });
    try bufWriter.flush();
}
