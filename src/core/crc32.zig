const std = @import("std");

pub fn crc32(data: []const u8) u32 {
	var crc: u32 = 0xFFFFFFFF;
	for (data) |b| {
		var x = crc ^ @as(u32, b);
		var i: u32 = 0;
		while (i < 8) : (i += 1) {
			const mask = @as(u32, 0) -% (x & 1);
			x = (x >> 1) ^ (0xEDB88320 & mask);
		}
		crc = x;
	}
	return ~crc;
}
