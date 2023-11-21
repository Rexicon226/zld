pub const GotSection = struct {
    symbols: std.ArrayListUnmanaged(Symbol.Index) = .{},
    needs_rebase: bool = false,
    needs_bind: bool = false,

    pub const Index = u32;

    pub fn deinit(got: *GotSection, allocator: Allocator) void {
        got.symbols.deinit(allocator);
    }

    pub fn addSymbol(got: *GotSection, sym_index: Symbol.Index, macho_file: *MachO) !void {
        const gpa = macho_file.base.allocator;
        const index = @as(Index, @intCast(got.symbols.items.len));
        const entry = try got.symbols.addOne(gpa);
        entry.* = sym_index;
        const symbol = macho_file.getSymbol(sym_index);
        if (symbol.flags.import) {
            got.needs_bind = true;
        } else {
            got.needs_rebase = true;
        }
        try symbol.addExtra(.{ .got = index }, macho_file);
    }

    pub fn getAddress(got: GotSection, index: Index, macho_file: *MachO) u64 {
        assert(index < got.symbols.items.len);
        const header = macho_file.sections.items(.header)[macho_file.got_sect_index.?];
        return header.addr + index * @sizeOf(u64);
    }

    pub fn size(got: GotSection) usize {
        return got.symbols.items.len * @sizeOf(u64);
    }

    pub fn addRebase(got: GotSection, macho_file: *MachO) !void {
        const gpa = macho_file.base.allocator;
        try macho_file.rebase.entries.ensureUnusedCapacity(gpa, got.symbols.items.len);

        const seg_id = macho_file.sections.items(.segment_id)[macho_file.got_sect_index.?];
        const seg = macho_file.segments.items[seg_id];

        for (got.symbols.items, 0..) |sym_index, idx| {
            const sym = macho_file.getSymbol(sym_index);
            if (sym.flags.import) continue;
            const addr = got.getAddress(@intCast(idx), macho_file);
            macho_file.rebase.entries.appendAssumeCapacity(.{
                .offset = addr - seg.vmaddr,
                .segment_id = seg_id,
            });
        }
    }

    pub fn addBind(got: GotSection, macho_file: *MachO) !void {
        const gpa = macho_file.base.allocator;
        try macho_file.bind.entries.ensureUnusedCapacity(gpa, got.symbols.items.len);

        const seg_id = macho_file.sections.items(.segment_id)[macho_file.got_sect_index.?];
        const seg = macho_file.segments.items[seg_id];

        for (got.symbols.items, 0..) |sym_index, idx| {
            const sym = macho_file.getSymbol(sym_index);
            if (!sym.flags.import) continue;
            const addr = got.getAddress(@intCast(idx), macho_file);
            macho_file.bind.entries.appendAssumeCapacity(.{
                .target = sym_index,
                .offset = addr - seg.vmaddr,
                .segment_id = seg_id,
                .addend = 0,
            });
        }
    }

    pub fn write(got: GotSection, macho_file: *MachO, writer: anytype) !void {
        for (got.symbols.items) |sym_index| {
            const sym = macho_file.getSymbol(sym_index);
            const value = if (sym.flags.import) @as(u64, 0) else sym.getAddress(.{}, macho_file);
            try writer.writeInt(u64, value, .little);
        }
    }

    const FormatCtx = struct {
        got: GotSection,
        macho_file: *MachO,
    };

    pub fn fmt(got: GotSection, macho_file: *MachO) std.fmt.Formatter(format2) {
        return .{ .data = .{ .got = got, .macho_file = macho_file } };
    }

    pub fn format2(
        ctx: FormatCtx,
        comptime unused_fmt_string: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        _ = unused_fmt_string;
        for (ctx.got.symbols.items, 0..) |entry, i| {
            const symbol = ctx.macho_file.getSymbol(entry);
            try writer.print("  {d}@0x{x} => {d}@0x{x} ({s})\n", .{
                i,
                symbol.getGotAddress(ctx.macho_file),
                entry,
                symbol.getAddress(.{}, ctx.macho_file),
                symbol.getName(ctx.macho_file),
            });
        }
    }
};

pub const StubsSection = struct {
    symbols: std.ArrayListUnmanaged(Symbol.Index) = .{},

    pub const Index = u32;

    pub fn deinit(stubs: *StubsSection, allocator: Allocator) void {
        stubs.symbols.deinit(allocator);
    }

    pub fn addSymbol(stubs: *StubsSection, sym_index: Symbol.Index, macho_file: *MachO) !void {
        const gpa = macho_file.base.allocator;
        const index = @as(Index, @intCast(stubs.symbols.items.len));
        const entry = try stubs.symbols.addOne(gpa);
        entry.* = sym_index;
        const symbol = macho_file.getSymbol(sym_index);
        try symbol.addExtra(.{ .stubs = index }, macho_file);
    }

    pub fn getAddress(stubs: StubsSection, index: Index, macho_file: *MachO) u64 {
        assert(index < stubs.symbols.items.len);
        const header = macho_file.sections.items(.header)[macho_file.stubs_sect_index.?];
        return header.addr + index * header.reserved2;
    }

    pub fn size(stubs: StubsSection, macho_file: *MachO) usize {
        const header = macho_file.sections.items(.header)[macho_file.stubs_sect_index.?];
        return stubs.symbols.items.len * header.reserved2;
    }

    pub fn write(stubs: StubsSection, macho_file: *MachO, writer: anytype) !void {
        const cpu_arch = macho_file.options.cpu_arch.?;
        const laptr_sect = macho_file.sections.items(.header)[macho_file.la_symbol_ptr_sect_index.?];

        for (stubs.symbols.items, 0..) |sym_index, idx| {
            const sym = macho_file.getSymbol(sym_index);
            switch (cpu_arch) {
                .x86_64 => {
                    try writer.writeAll(&.{ 0xff, 0x25 });
                    const source = sym.getAddress(.{ .stubs = true }, macho_file);
                    const target = laptr_sect.addr + idx * @sizeOf(u64);
                    try writer.writeInt(i32, @intCast(target - source - 2 - 4), .little);
                },
                .aarch64 => @panic("TODO"),
                else => unreachable,
            }
        }
    }

    const FormatCtx = struct {
        stubs: StubsSection,
        macho_file: *MachO,
    };

    pub fn fmt(stubs: StubsSection, macho_file: *MachO) std.fmt.Formatter(format2) {
        return .{ .data = .{ .stubs = stubs, .macho_file = macho_file } };
    }

    pub fn format2(
        ctx: FormatCtx,
        comptime unused_fmt_string: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        _ = unused_fmt_string;
        for (ctx.stubs.symbols.items, 0..) |entry, i| {
            const symbol = ctx.macho_file.getSymbol(entry);
            try writer.print("  {d}@0x{x} => {d}@0x{x} ({s})\n", .{
                i,
                symbol.getStubsAddress(ctx.macho_file),
                entry,
                symbol.getAddress(.{}, ctx.macho_file),
                symbol.getName(ctx.macho_file),
            });
        }
    }
};

pub const StubsHelperSection = struct {
    pub inline fn preambleSize(cpu_arch: std.Target.Cpu.Arch) usize {
        return switch (cpu_arch) {
            .x86_64 => 15,
            .aarch64 => 6 * @sizeOf(u32),
            else => 0,
        };
    }

    pub inline fn entrySize(cpu_arch: std.Target.Cpu.Arch) usize {
        return switch (cpu_arch) {
            .x86_64 => 10,
            .aarch64 => 3 * @sizeOf(u32),
            else => 0,
        };
    }

    pub fn size(stubs_helper: StubsHelperSection, macho_file: *MachO) usize {
        _ = stubs_helper;
        const cpu_arch = macho_file.options.cpu_arch.?;
        var s: usize = preambleSize(cpu_arch);
        for (macho_file.stubs.symbols.items) |_| {
            s += entrySize(cpu_arch);
        }
        return s;
    }

    pub fn write(stubs_helper: StubsHelperSection, macho_file: *MachO, writer: anytype) !void {
        try stubs_helper.writePreamble(macho_file, writer);

        const cpu_arch = macho_file.options.cpu_arch.?;
        const sect = macho_file.sections.items(.header)[macho_file.stubs_helper_sect_index.?];
        const preamble_size = preambleSize(cpu_arch);
        const entry_size = entrySize(cpu_arch);

        for (0..macho_file.stubs.symbols.items.len, macho_file.lazy_bind.offsets.items) |idx, boff| {
            switch (cpu_arch) {
                .x86_64 => {
                    try writer.writeByte(0x68);
                    try writer.writeInt(u32, boff, .little);
                    try writer.writeByte(0xe9);
                    const source: i64 = @intCast(sect.addr + preamble_size + entry_size * idx);
                    const target: i64 = @intCast(sect.addr);
                    try writer.writeInt(i32, @intCast(target - source - 6 - 4), .little);
                },
                .aarch64 => @panic("TODO"),
                else => {},
            }
        }
    }

    fn writePreamble(stubs_helper: StubsHelperSection, macho_file: *MachO, writer: anytype) !void {
        _ = stubs_helper;
        const cpu_arch = macho_file.options.cpu_arch.?;
        const sect = macho_file.sections.items(.header)[macho_file.stubs_helper_sect_index.?];
        switch (cpu_arch) {
            .x86_64 => {
                try writer.writeAll(&.{ 0x4c, 0x8d, 0x1d });
                {
                    const target = target: {
                        const sym = macho_file.getSymbol(macho_file.dyld_private_index.?);
                        break :target sym.getAddress(.{}, macho_file);
                    };
                    try writer.writeInt(i32, @intCast(target - sect.addr - 3 - 4), .little);
                }
                try writer.writeAll(&.{ 0x41, 0x53, 0xff, 0x25 });
                {
                    const target = target: {
                        const sym = macho_file.getSymbol(macho_file.dyld_stub_binder_index.?);
                        break :target sym.getGotAddress(macho_file);
                    };
                    try writer.writeInt(i32, @intCast(target - sect.addr - 11 - 4), .little);
                }
            },
            .aarch64 => @panic("TODO"),
            else => {},
        }
    }
};

pub const LaSymbolPtrSection = struct {
    pub fn size(laptr: LaSymbolPtrSection, macho_file: *MachO) usize {
        _ = laptr;
        return macho_file.stubs.symbols.items.len * @sizeOf(u64);
    }

    pub fn addLazyBind(laptr: LaSymbolPtrSection, macho_file: *MachO) !void {
        _ = laptr;
        const gpa = macho_file.base.allocator;
        try macho_file.lazy_bind.entries.ensureUnusedCapacity(gpa, macho_file.stubs.symbols.items.len);

        const sect = macho_file.sections.items(.header)[macho_file.la_symbol_ptr_sect_index.?];
        const seg_id = macho_file.sections.items(.segment_id)[macho_file.la_symbol_ptr_sect_index.?];
        const seg = macho_file.segments.items[seg_id];

        for (macho_file.stubs.symbols.items, 0..) |sym_index, idx| {
            const addr = sect.addr + idx * @sizeOf(u64);
            macho_file.lazy_bind.entries.appendAssumeCapacity(.{
                .target = sym_index,
                .offset = addr - seg.vmaddr,
                .segment_id = seg_id,
                .addend = 0,
            });
        }
    }

    pub fn write(laptr: LaSymbolPtrSection, macho_file: *MachO, writer: anytype) !void {
        _ = laptr;
        const cpu_arch = macho_file.options.cpu_arch.?;
        const sect = macho_file.sections.items(.header)[macho_file.stubs_helper_sect_index.?];
        for (0..macho_file.stubs.symbols.items.len) |idx| {
            const value = sect.addr + StubsHelperSection.preambleSize(cpu_arch) +
                StubsHelperSection.entrySize(cpu_arch) * idx;
            try writer.writeInt(u64, @intCast(value), .little);
        }
    }
};

pub const TlvPtrSection = struct {
    symbols: std.ArrayListUnmanaged(Symbol.Index) = .{},

    pub const Index = u32;

    pub fn deinit(tlv: *TlvPtrSection, allocator: Allocator) void {
        tlv.symbols.deinit(allocator);
    }

    pub fn addSymbol(tlv: *TlvPtrSection, sym_index: Symbol.Index, macho_file: *MachO) !void {
        const gpa = macho_file.base.allocator;
        const index = @as(Index, @intCast(tlv.symbols.items.len));
        const entry = try tlv.symbols.addOne(gpa);
        entry.* = sym_index;
        const symbol = macho_file.getSymbol(sym_index);
        try symbol.addExtra(.{ .tlv_ptr = index }, macho_file);
    }

    pub fn getAddress(tlv: TlvPtrSection, index: Index, macho_file: *MachO) u64 {
        assert(index < tlv.symbols.items.len);
        const header = macho_file.sections.items(.header)[macho_file.tlv_ptr_sect_index.?];
        return header.addr + index * @sizeOf(u64) * 3;
    }

    pub fn size(tlv: TlvPtrSection) usize {
        return tlv.symbols.items.len * @sizeOf(u64) * 3;
    }

    const FormatCtx = struct {
        tlv: TlvPtrSection,
        macho_file: *MachO,
    };

    pub fn fmt(tlv: TlvPtrSection, macho_file: *MachO) std.fmt.Formatter(format2) {
        return .{ .data = .{ .tlv = tlv, .macho_file = macho_file } };
    }

    pub fn format2(
        ctx: FormatCtx,
        comptime unused_fmt_string: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        _ = unused_fmt_string;
        for (ctx.tlv.symbols.items, 0..) |entry, i| {
            const symbol = ctx.macho_file.getSymbol(entry);
            try writer.print("  {d}@0x{x} => {d}@0x{x} ({s})\n", .{
                i,
                symbol.getTlvPtrAddress(ctx.macho_file),
                entry,
                symbol.getAddress(.{}, ctx.macho_file),
                symbol.getName(ctx.macho_file),
            });
        }
    }
};

pub const Indsymtab = struct {
    pub inline fn nsyms(ind: Indsymtab, macho_file: *MachO) u32 {
        _ = ind;
        return @intCast(macho_file.stubs.symbols.items.len * 2 + macho_file.got.symbols.items.len);
    }

    pub fn write(ind: Indsymtab, macho_file: *MachO, writer: anytype) !void {
        _ = ind;

        for (macho_file.stubs.symbols.items) |sym_index| {
            const sym = macho_file.getSymbol(sym_index);
            try writer.writeInt(u32, sym.getOutputSymtabIndex(macho_file).?, .little);
        }

        for (macho_file.got.symbols.items) |sym_index| {
            const sym = macho_file.getSymbol(sym_index);
            if (sym.flags.import) {
                try writer.writeInt(u32, sym.getOutputSymtabIndex(macho_file).?, .little);
            } else {
                try writer.writeInt(u32, std.macho.INDIRECT_SYMBOL_LOCAL, .little);
            }
        }

        for (macho_file.stubs.symbols.items) |sym_index| {
            const sym = macho_file.getSymbol(sym_index);
            try writer.writeInt(u32, sym.getOutputSymtabIndex(macho_file).?, .little);
        }
    }
};

pub const RebaseSection = Rebase;
pub const BindSection = bind.Bind;
pub const LazyBindSection = bind.LazyBind;
pub const ExportTrieSection = Trie;

const assert = std.debug.assert;
const bind = @import("dyld_info/bind.zig");
const std = @import("std");

const Allocator = std.mem.Allocator;
const MachO = @import("../MachO.zig");
const Rebase = @import("dyld_info/Rebase.zig");
const Symbol = @import("Symbol.zig");
const Trie = @import("dyld_info/Trie.zig");
