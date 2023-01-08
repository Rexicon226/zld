const UnwindInfo = @This();

const std = @import("std");
const assert = std.debug.assert;
const eh_frame = @import("eh_frame.zig");
const fs = std.fs;
const leb = std.leb;
const log = std.log.scoped(.unwind_info);
const macho = std.macho;
const math = std.math;
const mem = std.mem;
const trace = @import("../tracy.zig").trace;

const Allocator = mem.Allocator;
const Atom = @import("Atom.zig");
const AtomIndex = MachO.AtomIndex;
const EhFrameRecord = eh_frame.EhFrameRecord;
const MachO = @import("../MachO.zig");
const Object = @import("Object.zig");

gpa: Allocator,

/// List of all unwind records gathered from all objects and sorted
/// by source function address.
records: std.ArrayListUnmanaged(macho.compact_unwind_entry) = .{},
records_lookup: std.AutoHashMapUnmanaged(AtomIndex, u32) = .{},

/// List of all personalities referenced by either unwind info entries
/// or __eh_frame entries.
personalities: [max_personalities]MachO.SymbolWithLoc = undefined,
personalities_count: u2 = 0,

/// List of common encodings sorted in descending order with the most common first.
common_encodings: [max_common_encodings]macho.compact_unwind_encoding_t = undefined,
common_encodings_count: u7 = 0,

const max_personalities = 3;
const max_common_encodings = 127;
const max_second_level_page_bytes = 0x1000;
const max_second_level_page_words = max_second_level_page_bytes / @sizeOf(u32);
const max_regular_second_level_entries = (max_second_level_page_bytes - @sizeOf(macho.unwind_info_regular_second_level_page_header)) / @sizeOf(macho.unwind_info_regular_second_level_entry);
const max_compressed_second_level_entries = (max_second_level_page_bytes - @sizeOf(macho.unwind_info_compressed_second_level_page_header)) / @sizeOf(u32);

pub fn deinit(info: *UnwindInfo) void {
    info.records.deinit(info.gpa);
    info.records_lookup.deinit(info.gpa);
}

pub fn scanRelocs(macho_file: *MachO) !void {
    for (macho_file.objects.items) |*object, object_id| {
        const unwind_records = object.getUnwindRecords();
        for (object.exec_atoms.items) |atom_index| {
            const record_id = object.unwind_records_lookup.get(atom_index) orelse continue;
            const record = unwind_records[record_id];
            const enc = try macho.UnwindEncodingArm64.fromU32(record.compactUnwindEncoding);
            switch (enc) {
                .frame, .frameless => if (getPersonalityFunctionReloc(
                    macho_file,
                    @intCast(u32, object_id),
                    record_id,
                )) |rel| {
                    // Personality function; add GOT pointer.
                    const target = parseRelocTarget(
                        macho_file,
                        @intCast(u32, object_id),
                        rel,
                        mem.asBytes(&record),
                        @intCast(i32, record_id * @sizeOf(macho.compact_unwind_entry)),
                    );
                    try Atom.addGotEntry(macho_file, target);
                },
                .dwarf => {}, // Handled separately
            }
        }
    }
}

pub fn collect(info: *UnwindInfo, macho_file: *MachO) !void {
    var records = std.ArrayList(macho.compact_unwind_entry).init(info.gpa);
    defer records.deinit();

    var atom_indexes = std.ArrayList(AtomIndex).init(info.gpa);
    defer atom_indexes.deinit();

    var cies = std.AutoHashMap(u32, void).init(info.gpa);
    defer cies.deinit();

    // TODO handle dead stripping
    for (macho_file.objects.items) |*object, object_id| {
        const unwind_records = object.getUnwindRecords();

        // Contents of unwind records does not have to cover all symbol in executable section
        // so we need insert them ourselves.
        try records.ensureUnusedCapacity(object.exec_atoms.items.len);
        try atom_indexes.ensureUnusedCapacity(object.exec_atoms.items.len);

        var it = object.getEhFrameRecordsIterator();

        for (object.exec_atoms.items) |atom_index| {
            var record = if (object.unwind_records_lookup.get(atom_index)) |record_id| blk: {
                var record = unwind_records[record_id];
                var enc = try macho.UnwindEncodingArm64.fromU32(record.compactUnwindEncoding);
                switch (enc) {
                    .frame, .frameless => {
                        if (getPersonalityFunctionReloc(
                            macho_file,
                            @intCast(u32, object_id),
                            record_id,
                        )) |rel| {
                            const target = parseRelocTarget(
                                macho_file,
                                @intCast(u32, object_id),
                                rel,
                                mem.asBytes(&record),
                                @intCast(i32, record_id * @sizeOf(macho.compact_unwind_entry)),
                            );
                            const personality_index = info.getPersonalityFunction(target) orelse inner: {
                                const personality_index = info.personalities_count;
                                info.personalities[personality_index] = target;
                                info.personalities_count += 1;
                                break :inner personality_index;
                            };

                            record.personalityFunction = personality_index + 1;
                            switch (enc) {
                                .frame => |*x| x.personality_index = personality_index + 1,
                                .frameless => |*x| x.personality_index = personality_index + 1,
                                .dwarf => unreachable,
                            }
                        }

                        if (getLsdaReloc(macho_file, @intCast(u32, object_id), record_id)) |rel| {
                            const target = parseRelocTarget(
                                macho_file,
                                @intCast(u32, object_id),
                                rel,
                                mem.asBytes(&record),
                                @intCast(i32, record_id * @sizeOf(macho.compact_unwind_entry)),
                            );
                            record.lsda = @bitCast(u64, target);
                        }
                    },
                    .dwarf => |*x| {
                        const fde_offset = object.eh_frame_records_lookup.get(atom_index).?;
                        it.seekTo(fde_offset);
                        const fde = (try it.next()).?;
                        const cie_ptr = fde.getCiePointer();
                        const cie_offset = fde_offset + 4 - cie_ptr;
                        it.seekTo(cie_offset);
                        const cie = (try it.next()).?;

                        if (cie.getPersonalityPointerReloc(
                            macho_file,
                            @intCast(u32, object_id),
                            cie_offset,
                        )) |target| {
                            const personality_index = info.getPersonalityFunction(target) orelse inner: {
                                const personality_index = info.personalities_count;
                                info.personalities[personality_index] = target;
                                info.personalities_count += 1;
                                break :inner personality_index;
                            };

                            record.personalityFunction = personality_index + 1;
                            x.personality_index = personality_index + 1;
                        }
                    },
                }
                record.compactUnwindEncoding = enc.toU32();
                break :blk record;
            } else nullRecord();

            const atom = macho_file.getAtom(atom_index);
            const sym = macho_file.getSymbol(atom.getSymbolWithLoc());
            record.rangeStart = sym.n_value;
            record.rangeLength = @intCast(u32, atom.size);

            records.appendAssumeCapacity(record);
            atom_indexes.appendAssumeCapacity(atom_index);

            cies.clearRetainingCapacity();
        }
    }

    // Fold records here
    try info.records.ensureTotalCapacity(info.gpa, records.items.len);
    try info.records_lookup.ensureTotalCapacity(info.gpa, @intCast(u32, atom_indexes.items.len));

    var maybe_prev: ?macho.compact_unwind_entry = null;
    for (records.items) |record, i| {
        const record_id = blk: {
            if (maybe_prev) |prev| {
                const is_dwarf = try isDwarf(record);
                if (is_dwarf or
                    (prev.compactUnwindEncoding != record.compactUnwindEncoding) or
                    (prev.personalityFunction != record.personalityFunction) or
                    record.lsda > 0)
                {
                    const record_id = @intCast(u32, info.records.items.len);
                    info.records.appendAssumeCapacity(record);
                    maybe_prev = record;
                    break :blk record_id;
                } else {
                    break :blk @intCast(u32, info.records.items.len);
                }
            } else {
                const record_id = @intCast(u32, info.records.items.len);
                info.records.appendAssumeCapacity(record);
                maybe_prev = record;
                break :blk record_id;
            }
        };
        info.records_lookup.putAssumeCapacityNoClobber(atom_indexes.items[i], record_id);
    }

    // Calculate common encodings
    const CommonEncWithCount = struct {
        enc: macho.compact_unwind_encoding_t,
        count: u32,

        fn greaterThan(ctx: void, lhs: @This(), rhs: @This()) bool {
            _ = ctx;
            return lhs.count > rhs.count;
        }
    };

    var common_encodings_counts = std.AutoArrayHashMap(
        macho.compact_unwind_encoding_t,
        CommonEncWithCount,
    ).init(info.gpa);
    defer common_encodings_counts.deinit();

    for (info.records.items) |record| {
        assert(!isNull(record));
        if (try isDwarf(record)) continue;
        const enc = record.compactUnwindEncoding;
        const gop = try common_encodings_counts.getOrPut(enc);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{
                .enc = enc,
                .count = 0,
            };
        }
        gop.value_ptr.count += 1;
    }

    var slice = common_encodings_counts.values();
    std.sort.sort(CommonEncWithCount, slice, {}, CommonEncWithCount.greaterThan);

    var i: u7 = 0;
    while (i < max_common_encodings) : (i += 1) {
        if (i >= slice.len) break;
        if (slice[i].count < 2) continue;
        info.common_encodings[i] = slice[i].enc;
        info.common_encodings_count += 1;
        log.debug("adding common encoding: {d} => 0x{x:0>8}", .{ i, info.common_encodings[i] });
    }
}

pub fn calcSectionSize(info: UnwindInfo, macho_file: *MachO) !void {
    const sect_id = macho_file.getSectionByName("__TEXT", "__unwind_info") orelse return;
    const sect = &macho_file.sections.items(.header)[sect_id];

    const size = try info.calcRequiredSize();
    log.warn("size = {x}", .{size});

    // TODO finish this!
    sect.size = 0x1000;
    sect.@"align" = 2;
}

fn calcRequiredSize(info: UnwindInfo) !usize {
    var total_size: usize = 0;
    total_size += @sizeOf(macho.unwind_info_section_header);
    total_size += @intCast(usize, info.common_encodings_count) * @sizeOf(macho.compact_unwind_encoding_t);
    total_size += @intCast(usize, info.personalities_count) * @sizeOf(u32);

    assert(info.records.items.len > 0);

    const page_count = ((info.records.items.len - 1) / max_regular_second_level_entries) + 2;
    log.warn("page_count = {d}", .{page_count});
    total_size += page_count * @sizeOf(macho.unwind_info_section_header_index_entry);

    var lsda_count: usize = 0;
    for (info.records.items) |rec| {
        if (rec.lsda == 0) continue;
        lsda_count += 1;
    }
    total_size += lsda_count * @sizeOf(macho.unwind_info_section_header_lsda_index_entry);
    total_size += page_count * max_second_level_page_bytes;

    return total_size;
}

pub fn write(info: *UnwindInfo, macho_file: *MachO) !void {
    const sect_id = macho_file.getSectionByName("__TEXT", "__unwind_info") orelse return;
    const sect = &macho_file.sections.items(.header)[sect_id];
    const seg_id = macho_file.sections.items(.segment_index)[sect_id];
    const seg = macho_file.segments.items[seg_id];

    const text_sect_id = macho_file.getSectionByName("__TEXT", "__text").?;
    const text_sect = macho_file.sections.items(.header)[text_sect_id];

    var personalities: [max_personalities]u32 = undefined;

    for (info.personalities[0..info.personalities_count]) |target, i| {
        const atom_index = macho_file.getGotAtomIndexForSymbol(target).?;
        const atom = macho_file.getAtom(atom_index);
        const sym = macho_file.getSymbol(atom.getSymbolWithLoc());
        personalities[i] = @intCast(u32, sym.n_value - seg.vmaddr);
    }

    for (personalities[0..info.personalities_count]) |offset, i| {
        log.debug("Personalities:", .{});
        log.debug("  {d}: 0x{x}", .{ i, offset });
    }

    for (info.records.items) |*rec| {
        // Finalize missing address values
        rec.rangeStart += text_sect.addr - seg.vmaddr;
        if (rec.personalityFunction > 0) {
            rec.personalityFunction = personalities[rec.personalityFunction - 1];
        }

        if (rec.compactUnwindEncoding > 0) {
            const enc = try macho.UnwindEncodingArm64.fromU32(rec.compactUnwindEncoding);
            switch (enc) {
                .frame, .frameless => {
                    const lsda_target = @bitCast(MachO.SymbolWithLoc, rec.lsda);
                    if (lsda_target.getFile()) |_| {
                        const sym = macho_file.getSymbol(lsda_target);
                        rec.lsda = sym.n_value - seg.vmaddr;
                    }
                },
                .dwarf => {}, // Handled separately
            }
        }
    }

    for (info.records.items) |record, i| {
        log.debug("Unwind record at offset 0x{x}", .{i * @sizeOf(macho.compact_unwind_entry)});
        log.debug("  start: 0x{x}", .{record.rangeStart});
        log.debug("  length: 0x{x}", .{record.rangeLength});
        log.debug("  compact encoding: 0x{x:0>8}", .{record.compactUnwindEncoding});
        log.debug("  personality: 0x{x}", .{record.personalityFunction});
        log.debug("  LSDA: 0x{x}", .{record.lsda});
    }

    // TODO how do I work out how many records can go in a single page?
    // I think we might need to partition the address space into pages
    var buffer = std.ArrayList(u8).init(info.gpa);
    defer buffer.deinit();
    var cwriter = std.io.countingWriter(buffer.writer());
    const writer = cwriter.writer();

    const common_encodings_offset: u32 = @sizeOf(macho.unwind_info_section_header);
    const common_encodings_count: u32 = info.common_encodings_count;
    const personalities_offset: u32 = common_encodings_offset + common_encodings_count * @sizeOf(u32);
    const personalities_count: u32 = info.personalities_count;
    const indexes_offset: u32 = personalities_offset + personalities_count * @sizeOf(u32);
    const indexes_count: u32 = 2;

    try writer.writeStruct(macho.unwind_info_section_header{
        .commonEncodingsArraySectionOffset = common_encodings_offset,
        .commonEncodingsArrayCount = common_encodings_count,
        .personalityArraySectionOffset = personalities_offset,
        .personalityArrayCount = personalities_count,
        .indexSectionOffset = indexes_offset,
        .indexCount = indexes_count,
    });
    try writer.writeAll(mem.sliceAsBytes(info.common_encodings[0..info.common_encodings_count]));
    try writer.writeAll(mem.sliceAsBytes(personalities[0..info.personalities_count]));

    const first_record = info.records.items[0];
    const last_record = info.records.items[info.records.items.len - 1];
    const sentinel_address = @intCast(u32, last_record.rangeStart + last_record.rangeLength);

    const index_headers_backpatch = cwriter.bytes_written;
    try writer.writeStruct(macho.unwind_info_section_header_index_entry{
        .functionOffset = @intCast(u32, first_record.rangeStart),
        .secondLevelPagesSectionOffset = 0,
        .lsdaIndexArraySectionOffset = 0,
    });
    try writer.writeStruct(macho.unwind_info_section_header_index_entry{
        .functionOffset = sentinel_address,
        .secondLevelPagesSectionOffset = 0,
        .lsdaIndexArraySectionOffset = 0,
    });

    const lsda_start_offset = @intCast(u32, cwriter.bytes_written);
    mem.writeIntLittle(u32, buffer.items[index_headers_backpatch + 8 ..][0..4], lsda_start_offset);

    log.debug("LSDAs:", .{});
    for (info.records.items) |record| {
        if (record.lsda == 0) continue;
        log.debug("  {x}, lsda({x})", .{ record.rangeStart, record.lsda });
        try writer.writeStruct(macho.unwind_info_section_header_lsda_index_entry{
            .functionOffset = @intCast(u32, record.rangeStart),
            .lsdaOffset = @intCast(u32, record.lsda),
        });
    }

    const lsda_end_offset = @intCast(u32, cwriter.bytes_written);
    mem.writeIntLittle(u32, buffer.items[index_headers_backpatch + 4 ..][0..4], lsda_end_offset);
    mem.writeIntLittle(
        u32,
        buffer.items[index_headers_backpatch +
            (indexes_count - 1) * @sizeOf(macho.unwind_info_section_header_index_entry) +
            8 ..][0..4],
        lsda_end_offset,
    );

    var page_encodings = std.AutoArrayHashMap(u32, void).init(info.gpa);
    defer page_encodings.deinit();

    log.debug("Page encodings", .{});
    for (info.records.items) |record| {
        if (info.getCommonEncoding(record.compactUnwindEncoding) != null) continue;
        try page_encodings.putNoClobber(record.compactUnwindEncoding, {});
        log.debug("  {d}: 0x{x:0>8}", .{
            page_encodings.getIndex(record.compactUnwindEncoding).?,
            record.compactUnwindEncoding,
        });
    }

    try writer.writeStruct(macho.unwind_info_compressed_second_level_page_header{
        .entryPageOffset = 0,
        .entryCount = @intCast(u16, info.records.items.len),
        .encodingsPageOffset = @sizeOf(macho.unwind_info_compressed_second_level_page_header),
        .encodingsCount = @intCast(u16, page_encodings.count()),
    });

    for (page_encodings.keys()) |enc| {
        try writer.writeIntLittle(u32, enc);
    }

    const page_offset = @intCast(u16, cwriter.bytes_written - lsda_end_offset);
    mem.writeIntLittle(u16, buffer.items[lsda_end_offset + 4 ..][0..2], page_offset);

    log.debug("Compressed page entries", .{});
    for (info.records.items) |record, i| {
        const compressed = macho.UnwindInfoCompressedEntry{
            .funcOffset = @intCast(u24, record.rangeStart - first_record.rangeStart),
            .encodingIndex = if (info.getCommonEncoding(record.compactUnwindEncoding)) |id|
                @intCast(u8, id)
            else
                @intCast(u8, info.common_encodings_count + page_encodings.getIndex(record.compactUnwindEncoding).?),
        };
        log.debug("  {d}: {x}, enc({d}) => {x}, {}", .{
            i,
            compressed.funcOffset,
            compressed.encodingIndex,
            @bitCast(u32, compressed),
            compressed,
        });
        try writer.writeStruct(compressed);
    }

    try macho_file.base.file.pwriteAll(buffer.items, sect.offset);
}

pub fn parseRelocTarget(
    macho_file: *MachO,
    object_id: u32,
    rel: macho.relocation_info,
    code: []const u8,
    base_offset: i32,
) MachO.SymbolWithLoc {
    const tracy = trace(@src());
    defer tracy.end();

    const object = &macho_file.objects.items[object_id];

    if (rel.r_extern == 0) {
        const sect_id = @intCast(u8, rel.r_symbolnum - 1);
        const rel_offset = @intCast(u32, rel.r_address - base_offset);

        assert(rel.r_pcrel == 0 and rel.r_length == 3);
        const address_in_section = mem.readIntLittle(i64, code[rel_offset..][0..8]);

        // Find containing atom
        const Predicate = struct {
            addr: i64,

            pub fn predicate(pred: @This(), other: i64) bool {
                return if (other == -1) true else other > pred.addr;
            }
        };

        if (object.source_section_index_lookup[sect_id] > -1) {
            const first_sym_index = @intCast(usize, object.source_section_index_lookup[sect_id]);
            const target_sym_index = MachO.lsearch(i64, object.source_address_lookup[first_sym_index..], Predicate{
                .addr = address_in_section,
            });

            if (target_sym_index > 0) {
                return MachO.SymbolWithLoc{
                    .sym_index = @intCast(u32, first_sym_index + target_sym_index - 1),
                    .file = object_id + 1,
                };
            }
        }

        // Start of section is not contained anywhere, return synthetic atom.
        const sym_index = object.getSectionAliasSymbolIndex(sect_id);
        return MachO.SymbolWithLoc{ .sym_index = sym_index, .file = object_id + 1 };
    }

    const sym_index = object.reverse_symtab_lookup[rel.r_symbolnum];
    const sym_loc = MachO.SymbolWithLoc{ .sym_index = sym_index, .file = object_id + 1 };
    const sym = macho_file.getSymbol(sym_loc);

    if (sym.sect() and !sym.ext()) {
        return sym_loc;
    } else if (object.globals_lookup[sym_index] > -1) {
        const global_index = @intCast(u32, object.globals_lookup[sym_index]);
        return macho_file.globals.items[global_index];
    } else return sym_loc;
}

fn getRelocs(
    macho_file: *MachO,
    object_id: u32,
    record_id: usize,
) []align(1) const macho.relocation_info {
    const object = &macho_file.objects.items[object_id];
    const rel_pos = object.unwind_relocs_lookup[record_id];
    const relocs = object.getRelocs(object.unwind_info_sect.?);
    return relocs[rel_pos.start..][0..rel_pos.len];
}

fn isPersonalityFunction(record_id: usize, rel: macho.relocation_info) bool {
    const base_offset = @intCast(i32, record_id * @sizeOf(macho.compact_unwind_entry));
    const rel_offset = rel.r_address - base_offset;
    return rel_offset == 16;
}

fn getPersonalityFunctionReloc(
    macho_file: *MachO,
    object_id: u32,
    record_id: usize,
) ?macho.relocation_info {
    const relocs = getRelocs(macho_file, object_id, record_id);
    for (relocs) |rel| {
        if (isPersonalityFunction(record_id, rel)) return rel;
    }
    return null;
}

fn getPersonalityFunction(info: UnwindInfo, global_index: MachO.SymbolWithLoc) ?u2 {
    comptime var index: u2 = 0;
    inline while (index < max_personalities) : (index += 1) {
        if (index >= info.personalities_count) return null;
        if (info.personalities[index].eql(global_index)) {
            return index;
        }
    }
    return null;
}

fn isLsda(record_id: usize, rel: macho.relocation_info) bool {
    const base_offset = @intCast(i32, record_id * @sizeOf(macho.compact_unwind_entry));
    const rel_offset = rel.r_address - base_offset;
    return rel_offset == 24;
}

fn getLsdaReloc(macho_file: *MachO, object_id: u32, record_id: usize) ?macho.relocation_info {
    const relocs = getRelocs(macho_file, object_id, record_id);
    for (relocs) |rel| {
        if (isLsda(record_id, rel)) return rel;
    }
    return null;
}

pub fn isDwarf(rec: macho.compact_unwind_entry) !bool {
    assert(!isNull(rec));
    if (rec.compactUnwindEncoding == 0) return false;
    const enc = try macho.UnwindEncodingArm64.fromU32(rec.compactUnwindEncoding);
    return switch (enc) {
        .frame, .frameless => false,
        .dwarf => true,
    };
}

pub fn isNull(rec: macho.compact_unwind_entry) bool {
    return rec.rangeStart == 0 and
        rec.rangeLength == 0 and
        rec.compactUnwindEncoding == 0 and
        rec.lsda == 0 and
        rec.personalityFunction == 0;
}

inline fn nullRecord() macho.compact_unwind_entry {
    return .{
        .rangeStart = 0,
        .rangeLength = 0,
        .compactUnwindEncoding = 0,
        .personalityFunction = 0,
        .lsda = 0,
    };
}

fn getCommonEncoding(info: UnwindInfo, enc: macho.compact_unwind_encoding_t) ?u7 {
    comptime var index: u7 = 0;
    inline while (index < max_common_encodings) : (index += 1) {
        if (index >= info.common_encodings_count) return null;
        if (info.common_encodings[index] == enc) {
            return index;
        }
    }
    return null;
}
