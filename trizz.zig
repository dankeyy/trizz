const std = @import("std");

var bufWriter = std.io.bufferedWriter(std.io.getStdOut().writer());
const stdout = bufWriter.writer();

const FileArrayList = std.ArrayList(std.fs.IterableDir.Entry);

const Counts = struct {
    dir_count: usize = 0,
    file_count: usize = 0,
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

fn printEntry(entryName: []const u8, level: usize, verticalBars: usize, isLast: bool, colour: []const u8, symlinkedTo: ?[]u8) !void {
    var vbar = verticalBars;
    for (0..level) |i| {
        const bit = (vbar >> @intCast(u6, i)) & 1;
        if (bit == 1) {
            _ = try stdout.write("    ");
        } else {
            _ = try stdout.write("│   ");
        }
    }

    _ = try stdout.write(if (isLast) "└── " else "├── ");
    _ = try stdout.write(colour);
    _ = try stdout.write(entryName);
    _ = try stdout.write("\x1b[0m"); // reset escape code
    if (symlinkedTo != null) {
        _ = try stdout.write(" -> ");
        _ = try stdout.write(symlinkedTo.?);
    }
    _ = try stdout.write("\n");
}

// prints an entry, adds it to corresponding count, returns a flag indicating if recursion is needed (true for directories)
inline fn printAndCountEntry(entry: std.fs.IterableDir.Entry, filePathBuf: []u8, path: []u8, cap: usize, level: usize, verticalBars: usize, isLast: bool, c: *Counts) !bool {
    switch (entry.kind) {
        .Directory => {
            c.dir_count += 1;
            try printEntry(entry.name, level, verticalBars, isLast, "\x1b[1;34m", null); // bold blue
            return true;
        },
        .File => {
            const newFileBuf = try std.fmt.bufPrintZ(filePathBuf.ptr[0..cap], "{s}/{s}", .{ path, entry.name });

            var colour = if (std.os.linux.access(@ptrCast([*:0]const u8, newFileBuf.ptr), 1) == 0) // executable
                "\x1b[1;32m" // bold green
            else
                "";
            try printEntry(entry.name, level, verticalBars, isLast, colour, null);
            c.file_count += 1;
        },
        .SymLink => {
            const newFileBuf = try std.fmt.bufPrint(filePathBuf.ptr[0..cap], "{s}/{s}", .{ path, entry.name });
            // const linked: []u8 = undefined;
            c.file_count += 1;
            if (std.os.readlink(newFileBuf, filePathBuf)) |linked| {
                try printEntry(entry.name, level, verticalBars, isLast, "\x1b[1;35m", linked); // bold purple-ish
            } else |err| switch (err) {
                std.os.ReadLinkError.AccessDenied => return false,
                else => unreachable, // TODO?
            }
        },
        .BlockDevice, .CharacterDevice => {
            try printEntry(entry.name, level, verticalBars, isLast, "\x1b[1;33m", null); // bold yellow
            c.file_count += 1;
        },
        .NamedPipe => {
            try printEntry(entry.name, level, verticalBars, isLast, "\x1b[38;5;214m", null); // regular gold-ish
            c.file_count += 1;
        },
        .UnixDomainSocket => {
            try printEntry(entry.name, level, verticalBars, isLast, "\x1b[38;5;208m", null); // regular orange
            c.file_count += 1;
        },
        else => {
            // who cares about whiteout/ doors/ eventports/ unknown anyway
            try printEntry(entry.name, level, verticalBars, isLast, "\x1b[1;90m", null); // bold black
            c.file_count += 1;
        },
    }
    return false;
}

inline fn copyEntry(nameBuf: []u8, nextEntry: *const std.fs.IterableDir.Entry) std.fs.IterableDir.Entry {
    @memcpy(nameBuf.ptr, nextEntry.name.ptr, nextEntry.name.len);
    return std.fs.IterableDir.Entry{
        .name = nameBuf[0..nextEntry.name.len],
        .kind = nextEntry.kind,
    };
}

fn walkUnsorted(nameBuf: []u8, path: []u8, filePathBuf: []u8, cap: usize, level: usize, verticalBars: u64) !Counts {
    var counts = Counts{};

    var dir = std.fs.cwd().openIterableDir(path, .{}) catch |err| switch (err) {
        std.fs.Dir.OpenError.AccessDenied => return counts,
        else => unreachable, // TODO?
    };

    defer dir.close();
    var it = dir.iterate();
    const entryData = try it.next() orelse return counts;

    var entry: std.fs.IterableDir.Entry = copyEntry(nameBuf, &entryData);

    while (try it.next()) |nextEntry| {
        if (!std.mem.startsWith(u8, entry.name, ".")) {
            var needsToRecurse = try printAndCountEntry(entry, filePathBuf, path, cap, level, verticalBars, false, &counts);
            if (needsToRecurse) {
                var slice = try std.fmt.bufPrint(path.ptr[0..cap], "{s}/{s}", .{ path, entry.name });
                const res = try walkUnsorted(nameBuf, slice, filePathBuf, cap, level + 1, verticalBars);

                counts.dir_count += res.dir_count;
                counts.file_count += res.file_count;
            }
        }
        entry = copyEntry(nameBuf, &nextEntry);
    }
    const vbar = verticalBars | (@intCast(u64, 1) << @intCast(u6, level));
    var needsToRecurse = try printAndCountEntry(entry, filePathBuf, path, cap, level, vbar, true, &counts);
    if (needsToRecurse) {
        var slice = try std.fmt.bufPrint(path.ptr[0..cap], "{s}/{s}", .{ path, entry.name });
        const res = try walkUnsorted(nameBuf, slice, filePathBuf, cap, level + 1, vbar);

        counts.dir_count += res.dir_count;
        counts.file_count += res.file_count;
    }

    try bufWriter.flush();
    return counts;
}

fn walkSorted(allocator: *const std.mem.Allocator, path: []u8, filePathBuf: []u8, cap: usize, level: usize, verticalBars: usize) !Counts {
    var counts = Counts{};

    var entries = FileArrayList.init(allocator.*);
    defer entries.deinit();

    var dir = std.fs.cwd().openIterableDir(path, .{}) catch |err| switch (err) {
        std.fs.Dir.OpenError.AccessDenied => return counts,
        else => unreachable, // TODO?
    };

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
        const isLast = i == entries.items.len;
        var vbar: u64 = 0;
        if (isLast) {
            vbar = verticalBars | (@intCast(u64, 1) << @intCast(u6, level));
        } else {
            vbar = 0;
        }

        var needsToRecurse = try printAndCountEntry(entry, filePathBuf, path, cap, level, vbar, isLast, &counts);
        if (needsToRecurse) {
            var slice = try std.fmt.bufPrint(path.ptr[0..cap], "{s}/{s}", .{ path, entry.name });
            const res = try walkSorted(allocator, slice, filePathBuf, cap, level + 1, vbar);

            counts.dir_count += res.dir_count;
            counts.file_count += res.file_count;
        }
    }

    try bufWriter.flush();
    return counts;
}

fn strlen(s: [*:0]u8) u64 {
    var len: u64 = 0;
    while (s[len] != 0) len +%= 1;
    return len;
}

pub fn main() !void {
    var pathBuf: [4096]u8 = undefined;
    var filePathBuf: [4096]u8 = undefined;
    var initialPath: []u8 = undefined;

    // custom path
    if (std.os.argv.len > 1) {
        const len = strlen(std.os.argv[1]);
        @memcpy(&pathBuf, std.os.argv[1], len);
        initialPath = pathBuf[0..len];
    } else {
        initialPath = try std.fmt.bufPrint(&pathBuf, ".", .{});
    }

    // opt in to sorting
    var sorted: bool = false;
    if (std.os.argv.len > 2) {
        const arg = std.os.argv[2][0..strlen(std.os.argv[2])];
        if (std.mem.eql(u8, arg, "--sorted")) {
            sorted = true;
        }
    }

    _ = try stdout.print("{s}\n", .{initialPath});
    var res: Counts = undefined;
    if (sorted) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        res = try walkSorted(&allocator, initialPath, &filePathBuf, 4096, 0, 0);
    } else {
        var nameBuf: [255]u8 = undefined;
        res = try walkUnsorted(&nameBuf, initialPath, &filePathBuf, 4096, 0, 0);
    }

    const dirs = res.dir_count;
    const files = res.file_count;

    const dirstxt = if (dirs == 1) "directory" else "directories";
    const filestxt = if (files == 1) "file" else "files";
    _ = try stdout.print("\n{d} {s}, {d} {s}\n", .{ dirs, dirstxt, files, filestxt });
    try bufWriter.flush();
}
