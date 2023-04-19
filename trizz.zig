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

fn printEntry(entryName: []const u8, level: usize, verticalBars: usize, isLast: bool, color: []const u8, symlinkedTo: ?[]u8) !void {
    var vbar = verticalBars;
    for (0..level) |i| {
        const bit = (vbar >> @intCast(u6, i)) & 1;
        if (bit == 1) {
            _ = try stdout.writeAll("    ");
        } else {
            _ = try stdout.writeAll("│   ");
        }
    }

    _ = try stdout.writeAll(if (isLast) "└── " else "├── ");
    if (!std.mem.eql(u8, color, "")) {
        _ = try stdout.writeAll(color);
        _ = try stdout.writeAll(entryName);
        _ = try stdout.writeAll("\x1b[0m"); // reset escape code
    } else {
        _ = try stdout.writeAll(entryName);
    }
    if (symlinkedTo != null) {
        _ = try stdout.writeAll(" -> ");
        _ = try stdout.writeAll(symlinkedTo.?);
    }
    _ = try stdout.writeAll("\n");
}

// prints an entry, adds it to corresponding count, returns a flag indicating if recursion is needed (true for directories)
inline fn printAndCountEntry(entry: std.fs.IterableDir.Entry, filePathBuf: []u8, path: []u8, cap: usize, level: usize, verticalBars: usize, isLast: bool, c: *Counts, noColor: bool) !bool {
    switch (entry.kind) {
        .Directory => {
            c.dir_count += 1;
            const color = if (noColor) "" else "\x1b[1;34m"; // bold blue
            try printEntry(entry.name, level, verticalBars, isLast, color, null);
            return true;
        },
        .File => {
            const color =
                if (!noColor) picker: {
                    const newFileBuf = try std.fmt.bufPrintZ(filePathBuf.ptr[0..cap], "{s}/{s}", .{ path, entry.name });
                    if (std.os.linux.access(@ptrCast([*:0]const u8, newFileBuf.ptr), 1) == 0) {
                        break :picker "\x1b[1;32m";
                    }
                    else {
                        break :picker "";
                    } // bold green
                }
                else "";
            try printEntry(entry.name, level, verticalBars, isLast, color, null);
            c.file_count += 1;
        },
        .SymLink => {
            const newFileBuf = try std.fmt.bufPrint(filePathBuf.ptr[0..cap], "{s}/{s}", .{ path, entry.name });
            c.file_count += 1;

            const color = if (noColor) "" else "\x1b[1;35m"; // bold purple-ish
            if (std.os.readlink(newFileBuf, filePathBuf)) |linked| {
                try printEntry(entry.name, level, verticalBars, isLast, color, linked);
            } else |err| switch (err) {
                // std.os.ReadLinkError.AccessDenied => return false,
                else => return false
            }
        },
        .BlockDevice, .CharacterDevice => {
            const color = if (noColor) "" else "\x1b[1;33m"; // bold yellow
            try printEntry(entry.name, level, verticalBars, isLast, color, null);
            c.file_count += 1;
        },
        .NamedPipe => {
            const color = if (noColor) "" else "\x1b[38;5;214m"; // regular gold-ish
            try printEntry(entry.name, level, verticalBars, isLast, color, null);
            c.file_count += 1;
        },
        .UnixDomainSocket => {
            const color = if (noColor) "" else  "\x1b[38;5;208m"; // regular orange
            try printEntry(entry.name, level, verticalBars, isLast, color, null);
            c.file_count += 1;
        },
        else => {
            // who cares about whiteout/ doors/ eventports/ unknown anyway
            const color = if (noColor) "" else  "\x1b[1;90m";  // bold black
            try printEntry(entry.name, level, verticalBars, isLast, color, null);
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

fn walkUnsorted(nameBuf: []u8, path: []u8, filePathBuf: []u8, cap: usize, level: usize, verticalBars: u64, hideHidden: bool, noColor: bool) !Counts {
    var counts = Counts{};

    var dir = std.fs.cwd().openIterableDir(path, .{}) catch |err| switch (err) {
        // std.fs.Dir.OpenError.AccessDenied => return counts,
        else => return counts,
    };

    defer dir.close();
    var it = dir.iterate();
    const entryData = try it.next() orelse return counts;

    var entry: std.fs.IterableDir.Entry = copyEntry(nameBuf, &entryData);

    while (try it.next()) |nextEntry| {
        if (!(std.mem.startsWith(u8, entry.name, ".") and hideHidden)) {
            var needsToRecurse = try printAndCountEntry(entry, filePathBuf, path, cap, level, verticalBars, false, &counts, noColor);
            if (needsToRecurse) {
                var slice = try std.fmt.bufPrint(path.ptr[0..cap], "{s}/{s}", .{ path, entry.name });
                const res = try walkUnsorted(nameBuf, slice, filePathBuf, cap, level + 1, verticalBars, hideHidden, noColor);

                counts.dir_count += res.dir_count;
                counts.file_count += res.file_count;
            }
        }
        entry = copyEntry(nameBuf, &nextEntry);
    }
    const vbar = verticalBars | (@intCast(u64, 1) << @intCast(u6, level));
    var needsToRecurse = try printAndCountEntry(entry, filePathBuf, path, cap, level, vbar, true, &counts, noColor);
    if (needsToRecurse) {
        var slice = try std.fmt.bufPrint(path.ptr[0..cap], "{s}/{s}", .{ path, entry.name });
        const res = try walkUnsorted(nameBuf, slice, filePathBuf, cap, level + 1, vbar, hideHidden, noColor);

        counts.dir_count += res.dir_count;
        counts.file_count += res.file_count;
    }

    return counts;
}

fn walkSorted(allocator: std.mem.Allocator, path: []u8, filePathBuf: []u8, cap: usize, level: usize, verticalBars: usize, hideHidden: bool, noColor: bool) !Counts {
    var counts = Counts{};

    var entries = FileArrayList.init(allocator);
    defer entries.deinit();

    var dir = std.fs.cwd().openIterableDir(path, .{}) catch |err| switch (err) {
        // std.fs.Dir.OpenError.AccessDenied => return counts,
        else => return counts,
    };

    defer dir.close();
    var it = dir.iterate();

    while (try it.next()) |entry| {
        if (!(std.mem.startsWith(u8, entry.name, ".") and hideHidden)) {
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

        var needsToRecurse = try printAndCountEntry(entry, filePathBuf, path, cap, level, vbar, isLast, &counts, noColor);
        if (needsToRecurse) {
            var slice = try std.fmt.bufPrint(path.ptr[0..cap], "{s}/{s}", .{ path, entry.name });
            const res = try walkSorted(allocator, slice, filePathBuf, cap, level + 1, vbar, hideHidden, noColor);

            counts.dir_count += res.dir_count;
            counts.file_count += res.file_count;
        }
    }

    return counts;
}

fn strlen(s: [*:0]u8) u64 {
    var len: u64 = 0;
    while (s[len] != 0) len +%= 1;
    return len;
}

pub fn main() !void {
    const CAP = 4097;
    var pathBuf: [CAP]u8 = undefined;
    var filePathBuf: [CAP]u8 = undefined;

    var customPath: ?[*:0]u8 = null;
    var sorted: bool = false;
    var hideHidden: bool = true;
    var noColor: bool = false;
    for (0.., std.os.argv) |i, arg| {
        if (i==0) continue;
        if (!(arg[0] == '-')) {
           customPath.? = arg;
        }
        else {
            const argSlice = arg[0..strlen(arg)];
            // opt in to sorting
            if (std.mem.eql(u8, argSlice, "--sorted")) {
                sorted = true;
            }
            else if (std.mem.eql(u8, argSlice, "-a")) {
                hideHidden = false;
            }
            else if (std.mem.eql(u8, argSlice, "--no-color")) {
                noColor = true;
            }
        }
    }
    // custom path or default (current directory)
    var initialPath: []u8 = undefined;
    if (customPath != null) {
        const len = strlen(customPath.?);
        @memcpy(&pathBuf, customPath.?, len);
        initialPath = pathBuf[0..len];
    } else {
        initialPath = try std.fmt.bufPrint(&pathBuf, ".", .{});
    }


    _ = try stdout.print("{s}\n", .{initialPath});
    var res: Counts = undefined;
    if (sorted) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        res = try walkSorted(allocator, initialPath, &filePathBuf, CAP, 0, 0, hideHidden, noColor);
    } else {
        var nameBuf: [255]u8 = undefined;
        res = try walkUnsorted(&nameBuf, initialPath, &filePathBuf, CAP, 0, 0, hideHidden, noColor);
    }

    const dirs = res.dir_count;
    const files = res.file_count;

    const dirstxt = if (dirs == 1) "directory" else "directories";
    const filestxt = if (files == 1) "file" else "files";
    _ = try stdout.print("\n{d} {s}, {d} {s}\n", .{ dirs, dirstxt, files, filestxt });
    try bufWriter.flush();
}
