pub const BytesError = error{
    OutOfBounds,
    Overflow,
    Unimplemented,
};

pub fn readU32Le(buf: []const u8, offset: usize) BytesError!u32 {
    try ensureRange(buf.len, offset, 4);
    return @as(u32, buf[offset]) |
        (@as(u32, buf[offset + 1]) << 8) |
        (@as(u32, buf[offset + 2]) << 16) |
        (@as(u32, buf[offset + 3]) << 24);
}

pub fn readU16Le(buf: []const u8, offset: usize) BytesError!u16 {
    try ensureRange(buf.len, offset, 2);
    return @as(u16, buf[offset]) |
        (@as(u16, buf[offset + 1]) << 8);
}

pub fn readU64Le(buf: []const u8, offset: usize) BytesError!u64 {
    try ensureRange(buf.len, offset, 8);
    return @as(u64, buf[offset]) |
        (@as(u64, buf[offset + 1]) << 8) |
        (@as(u64, buf[offset + 2]) << 16) |
        (@as(u64, buf[offset + 3]) << 24) |
        (@as(u64, buf[offset + 4]) << 32) |
        (@as(u64, buf[offset + 5]) << 40) |
        (@as(u64, buf[offset + 6]) << 48) |
        (@as(u64, buf[offset + 7]) << 56);
}

pub fn readBytes(buf: []const u8, offset: usize, len: usize) BytesError![]const u8 {
    try ensureRange(buf.len, offset, len);
    const end = addChecked(offset, len) catch return error.Overflow;
    return buf[offset..end];
}

fn ensureRange(buf_len: usize, offset: usize, len: usize) BytesError!void {
    const end = addChecked(offset, len) catch return error.Overflow;
    if (end > buf_len) return error.OutOfBounds;
}

fn addChecked(a: usize, b: usize) BytesError!usize {
    const res = @addWithOverflow(a, b);
    if (res[1] != 0) return error.Overflow;
    return res[0];
}
