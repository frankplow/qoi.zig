const std = @import("std");
const AnyReader = std.io.AnyReader;
const AnyBitReader = std.io.BitReader(.big, AnyReader);
const testing = std.testing;

const QOIError = error{
    UnexpectedEOF,
    InvalidData,
    OutOfMemory,
};

const QOIChannels = enum(u8) {
    rgb  = 0x03,
    rgba = 0x04,
};

const QOIColorspace = enum(u8) {
    srgb   = 0x00,
    linear = 0x01,
};

const QOIHeader = struct {
    width: u32,
    height: u32,
    channels: QOIChannels,
    colorspace: QOIColorspace,
};

fn readQOIHeader(reader: *AnyReader) QOIError!QOIHeader {
    const magic = try (reader.readBytesNoEof(4) catch QOIError.UnexpectedEOF);
    if (!(std.meta.eql(magic, [_]u8{ 'q', 'o', 'i', 'f' }))) {
        return QOIError.InvalidData;
    }

    const width = try (reader.readInt(u32, .big) catch QOIError.UnexpectedEOF);

    const height = try (reader.readInt(u32, .big) catch QOIError.UnexpectedEOF);

    const channels_int = try (reader.readByte() catch QOIError.UnexpectedEOF);
    if (channels_int != 3 and channels_int != 4) {
        return QOIError.InvalidData;
    }
    const channels: QOIChannels = @enumFromInt(channels_int);

    const colorspace_int = try (reader.readByte() catch QOIError.UnexpectedEOF);
    if (colorspace_int != 0 and colorspace_int != 1) {
        return QOIError.InvalidData;
    }
    const colorspace: QOIColorspace = @enumFromInt(colorspace_int);

    return QOIHeader{
        .width = width,
        .height = height,
        .channels = channels,
        .colorspace = colorspace,
    };
}

const QOIChunk = union(enum) {
    rgb: struct {
        red: u8,
        green: u8,
        blue: u8,
    },
    rgba: struct {
        red: u8,
        green: u8,
        blue: u8,
        alpha: u8,
    },
    index: u6,
    diff: struct {
        // @TODO: Could these just be i2s?
        dr_plus2: u2,
        dg_plus2: u2,
        db_plus2: u2,
    },
    luma: struct {
        // @TODO: Same as .diff
        dg_plus32: u6,
        dr_plus8: u4,
        db_plus8: u4,
    },
    run: u6,
};

const QOIChunkType = std.meta.Tag(QOIChunk);

fn readQOITag(reader: *AnyBitReader) QOIError!QOIChunkType {
    const two_bit = try (reader.readBitsNoEof(u2, 2) catch QOIError.UnexpectedEOF);
    return switch (two_bit) {
        0b00 => QOIChunkType.index,
        0b01 => QOIChunkType.diff,
        0b10 => QOIChunkType.luma,
        0b11 => blk: {
            const prev_bit_count = reader.bit_count;
            const prev_bit_buffer = reader.bit_buffer;
            const six_bit = try (reader.readBitsNoEof(u6, 6) catch QOIError.UnexpectedEOF);
            switch (six_bit) {
                0b111110 => break :blk QOIChunkType.rgb,
                0b111111 => break :blk QOIChunkType.rgba,
                else => {
                    // Rewind the last six bits read as they are part
                    // of the payload and not the tag. Note the way this
                    // is implemented only works as the tag is
                    // byte-aligned.
                    reader.bit_count = prev_bit_count;
                    reader.bit_buffer = prev_bit_buffer;
                    break :blk QOIChunkType.run;
                }
            }
        },
    };
}


fn readQOIChunkPayload(reader: *AnyBitReader, T: type) QOIError!T {
    const info = @typeInfo(T);
    var payload: T = undefined;
    switch (info) {
        .Struct => {
            inline for (info.Struct.fields) |field| {
                const size = @typeInfo(field.type).Int.bits;
                const val = try (reader.readBitsNoEof(field.type, size) catch QOIError.UnexpectedEOF);
                @field(payload, field.name) = val;
            }
        },
        .Int => {
            const size = info.Int.bits;
            const val = try (reader.readBitsNoEof(T, size) catch QOIError.UnexpectedEOF);
            payload = val;
        },
        else => unreachable,
    }
    return payload;
}

fn readQOIChunk(reader: *AnyReader) QOIError!QOIChunk {
    var bit_reader = std.io.bitReader(.big, reader.*);

    const chunk_type = try readQOITag(&bit_reader);

    // @TODO: Is it possible to do this comptime?
    //        chunk_type is runtime, so we can't use std.meta.TagPayload
    inline for (@typeInfo(QOIChunk).Union.fields) |field| {
        if (std.mem.eql(u8, field.name, @tagName(chunk_type))) {
            const payload = try readQOIChunkPayload(&bit_reader, field.type);
            return @unionInit(QOIChunk, field.name, payload);
        }
    }
    unreachable;
}

const QOIPixel = packed struct {
    red: u8,
    green: u8,
    blue: u8,
    alpha: u8,

    fn hash(self: *const QOIPixel) u8 {
        const r: u16 = self.red;
        const g: u16 = self.green;
        const b: u16 = self.blue;
        const a: u16 = self.alpha;
        return @truncate((r * 3 + g * 5 + b * 7 + a * 11) % 64);
    }
};

pub fn readQOI(reader: *AnyReader, allocator: std.mem.Allocator) QOIError![]QOIPixel {
    var array = [_]QOIPixel{QOIPixel{
        .red = 0,
        .green = 0,
        .blue = 0,
        .alpha = 0,
    }} ** 64;
    var prev = QOIPixel{
        .red = 0,
        .green = 0,
        .blue = 0,
        .alpha = 255,
    };

    const header = try readQOIHeader(reader);
    const pixcnt = header.width * header.height;
    var data = try (allocator.alloc(QOIPixel, pixcnt) catch QOIError.OutOfMemory);

    var i: usize = 0;
    // @TODO: Alternatively detect the end code:
    //        0x0000000000000001
    while (i < pixcnt) {
        const chunk = try readQOIChunk(reader);
        // @TODO: This should be broken into multiple functions, probably
        //        manipulating a context struct.
        switch (chunk) {
            .rgb => |payload| {
                const pixel = QOIPixel{
                    .red = payload.red,
                    .green = payload.green,
                    .blue = payload.blue,
                    .alpha = prev.alpha,
                };
                array[pixel.hash()] = pixel;
                data[i] = pixel;
                i += 1;
                prev = pixel;
            },
            .rgba => |payload| {
                const pixel = QOIPixel{
                    .red = payload.red,
                    .green = payload.green,
                    .blue = payload.blue,
                    .alpha = payload.alpha,
                };
                array[pixel.hash()] = pixel;
                data[i] = pixel;
                i += 1;
                prev = pixel;
            },
            .index => |index| {
                const pixel = array[index];
                data[i] = pixel;
                i += 1;
                prev = pixel;
            },
            .diff => |payload| {
                const dr = @as(i8, payload.dr_plus2) - 2;
                const dg = @as(i8, payload.dg_plus2) - 2;
                const db = @as(i8, payload.db_plus2) - 2;
                const pixel = QOIPixel{
                    .red = prev.red +% @as(u8, @bitCast(dr)),
                    .green = prev.green +% @as(u8, @bitCast(dg)),
                    .blue = prev.blue +% @as(u8, @bitCast(db)),
                    .alpha = prev.alpha,
                };
                array[pixel.hash()] = pixel;
                data[i] = pixel;
                i += 1;
                prev = pixel;
            },
            .luma => |payload| {
                const dr_dg = @as(i8, payload.dr_plus8) - 8;
                const dg = @as(i8, payload.dg_plus32) - 32;
                const db_dg = @as(i8, payload.db_plus8) - 8;
                const dr = dr_dg + dg;
                const db = db_dg + dg;
                const pixel = QOIPixel{
                    .red = prev.red +% @as(u8, @bitCast(dr)),
                    .green = prev.green +% @as(u8, @bitCast(dg)),
                    .blue = prev.blue +% @as(u8, @bitCast(db)),
                    .alpha = prev.alpha,
                };
                array[pixel.hash()] = pixel;
                data[i] = pixel;
                i += 1;
                prev = pixel;
            },
            .run => |run| {
                for (0..run + 1) |_| {
                    data[i] = prev;
                    i += 1;
                }
                // https://github.com/phoboslab/qoi/issues/258
                array[prev.hash()] = prev;
            },
        }
    }

    return data;
}

test "header" {
    const fixedBufferStream = std.io.fixedBufferStream;

    const buffer1 = [_]u8{ 'q', 'o', 'i', 'f',
                           0x00, 0x01, 0x02, 0x03,
                           0x10, 0x11, 0x12, 0x13,
                           0x03,
                           0x00 };
    var buffer_stream1 = fixedBufferStream(buffer1[0..]);
    var reader1 = buffer_stream1.reader().any();
    const header1 = try readQOIHeader(&reader1);
    try testing.expect(header1.width == 66051);
    try testing.expect(header1.height == 269554195);
    try testing.expect(header1.channels == QOIChannels.rgb);
    try testing.expect(header1.colorspace == QOIColorspace.srgb);
}

test "chunk" {
    const fixedBufferStream = std.io.fixedBufferStream;

    const buffer1 = [_]u8{ 0b11111110, 0x01, 0x02, 0x03 };
    var buffer_stream1 = fixedBufferStream(buffer1[0..]);
    var reader1 = buffer_stream1.reader().any();
    const chunk1 = try readQOIChunk(&reader1);
    try testing.expect(std.meta.eql(chunk1, QOIChunk{
        .rgb = .{
            .red = 0x01,
            .green = 0x02,
            .blue = 0x03,
        }
    }));

    const buffer2 = [_]u8{ 0b11111111, 0x01, 0x02, 0x03, 0x04 };
    var buffer_stream2 = fixedBufferStream(buffer2[0..]);
    var reader2 = buffer_stream2.reader().any();
    const chunk2 = try readQOIChunk(&reader2);
    try testing.expect(std.meta.eql(chunk2, QOIChunk{
        .rgba = .{
            .red = 0x01,
            .green = 0x02,
            .blue = 0x03,
            .alpha = 0x04,
        }
    }));

    const buffer3 = [_]u8{ 0b00110101 };
    var buffer_stream3 = fixedBufferStream(buffer3[0..]);
    var reader3 = buffer_stream3.reader().any();
    const chunk3 = try readQOIChunk(&reader3);
    try testing.expect(std.meta.eql(chunk3, QOIChunk{
        .index = 0b110101,
    }));

    const buffer4 = [_]u8{ 0b01001101 };
    var buffer_stream4 = fixedBufferStream(buffer4[0..]);
    var reader4 = buffer_stream4.reader().any();
    const chunk4 = try readQOIChunk(&reader4);
    try testing.expect(std.meta.eql(chunk4, QOIChunk{
        .diff = .{
            .dr_plus2 = 0b00,
            .dg_plus2 = 0b11,
            .db_plus2 = 0b01,
        }
    }));

    const buffer5 = [_]u8{ 0b10101101, 0b10101110 };
    var buffer_stream5 = fixedBufferStream(buffer5[0..]);
    var reader5 = buffer_stream5.reader().any();
    const chunk5 = try readQOIChunk(&reader5);
    try testing.expect(std.meta.eql(chunk5, QOIChunk{
        .luma = .{
            .dg_plus32 = 0b101101,
            .dr_plus8 = 0b1010,
            .db_plus8 = 0b1110,
        }
    }));

    const buffer6 = [_]u8{ 0b11010110 };
    var buffer_stream6 = fixedBufferStream(buffer6[0..]);
    var reader6 = buffer_stream6.reader().any();
    const chunk6 = try readQOIChunk(&reader6);
    try testing.expect(std.meta.eql(chunk6, QOIChunk{
        .run = 0b010110,
    }));
}

test "end-to-end" {
    const dir = std.fs.cwd();
    const allocator = std.heap.page_allocator;
    const Testcase = struct {
        path: []const u8,
        md5: []const u8,
    };
    const testcases = [_]Testcase{
         Testcase{ .path = "tests/dice.qoi",          .md5 = "e1fd5899a63d9afd3421a20689a6e45f" },
         Testcase{ .path = "tests/edgecase.qoi",      .md5 = "c6db06f18cd79b477f7a6b24da9bc71c" },
         Testcase{ .path = "tests/kodim10.qoi",       .md5 = "3faf196e3581a7cde5cda8ce256cb9df" },
         Testcase{ .path = "tests/kodim23.qoi",       .md5 = "f9b3eb87b30413a6cd59ff3b8579000a" },
         Testcase{ .path = "tests/qoi_logo.qoi",      .md5 = "4520d0de7d5422a2e5a0d50f343e5766" },
         Testcase{ .path = "tests/testcard.qoi",      .md5 = "87e9f502ec41334ff320fcfd61d63924" },
         Testcase{ .path = "tests/testcard_rgba.qoi", .md5 = "9d03f697098290d4c19e7551bfc76224" },
         Testcase{ .path = "tests/wikipedia_008.qoi", .md5 = "d87260df78c17b21d29f9916de0cca2d" },
    };
    for (testcases) |testcase| {
        const file = try dir.openFile(testcase.path,
                                      std.fs.File.OpenFlags{ .mode = .read_only });
        defer file.close();
        var reader = file.reader().any();
        const data = try readQOI(&reader, allocator);
        defer allocator.free(data);
        var hash: [16]u8 = undefined;
        std.crypto.hash.Md5.hash(std.mem.sliceAsBytes(data), &hash, std.crypto.hash.Md5.Options{ });
        var hash_expected: [16]u8 = undefined;
        _ = try std.fmt.hexToBytes(&hash_expected, testcase.md5);
        testing.expect(std.meta.eql(hash, hash_expected)) catch |err| {
            std.debug.print("Testcase {s} failed.\n", .{ testcase.path });
            return err;
        };
    }
}
