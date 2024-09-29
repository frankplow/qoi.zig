const std = @import("std");
const AnyReader = std.io.AnyReader;
const AnyBitReader = std.io.BitReader(.big, AnyReader);
const testing = std.testing;

const QOIError = error{
    UnexpectedEOF,
    InvalidData,
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

fn readQOIHeader(reader: AnyReader) QOIError!QOIHeader {
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
        dr_minus2: u2,
        dg_minus2: u2,
        db_minus2: u2,
    },
    luma: struct {
        dg_minus32: u6,
        dr_minus8: u4,
        db_minus8: u4,
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

test "header" {
    const fixedBufferStream = std.io.fixedBufferStream;

    const buffer1 = [_]u8{ 'q', 'o', 'i', 'f',
                           0x00, 0x01, 0x02, 0x03,
                           0x10, 0x11, 0x12, 0x13,
                           0x03,
                           0x00 };
    var buffer_stream1 = fixedBufferStream(buffer1[0..]);
    const reader1 = buffer_stream1.reader();
    const header1 = try readQOIHeader(reader1.any());
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
            .dr_minus2 = 0b00,
            .dg_minus2 = 0b11,
            .db_minus2 = 0b01,
        }
    }));

    const buffer5 = [_]u8{ 0b10101101, 0b10101110 };
    var buffer_stream5 = fixedBufferStream(buffer5[0..]);
    var reader5 = buffer_stream5.reader().any();
    const chunk5 = try readQOIChunk(&reader5);
    try testing.expect(std.meta.eql(chunk5, QOIChunk{
        .luma = .{
            .dg_minus32 = 0b101101,
            .dr_minus8 = 0b1010,
            .db_minus8 = 0b1110,
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
