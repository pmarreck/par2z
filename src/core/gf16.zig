const std = @import("std");

pub const GF16 = struct {
	exp: [65535]u16,
	log: [65536]u16,
	valid_exponent_count: u32,
};

const poly: u32 = 0x1100B;

pub const tables: GF16 = initTables();

const max_valid_index_count: usize = @intCast(tables.valid_exponent_count);

const IndexTables = struct {
	constants: [max_valid_index_count]u16,
	exponents: [max_valid_index_count]u32,
};

pub const index_tables: IndexTables = initIndexTables();

fn initIndexTables() IndexTables {
	@setEvalBranchQuota(200000);
	var constants: [max_valid_index_count]u16 = undefined;
	var exponents: [max_valid_index_count]u32 = undefined;
	var count: usize = 0;
	var exp: u32 = 1;
	while (exp < 65535) : (exp += 1) {
		if (isValidExponent(exp)) {
			constants[count] = constantForExponent(exp);
			exponents[count] = exp;
			count += 1;
		}
	}
	return .{ .constants = constants, .exponents = exponents };
}

fn initTables() GF16 {
	@setEvalBranchQuota(200000);
	var exp: [65535]u16 = undefined;
	var log: [65536]u16 = undefined;
	log[0] = 0;
	var x: u32 = 1;
	var i: usize = 0;
	while (i < 65535) : (i += 1) {
		exp[i] = @as(u16, @intCast(x));
		log[@as(usize, @intCast(x))] = @as(u16, @intCast(i));
		x <<= 1;
		if ((x & 0x10000) != 0) {
			x ^= poly;
		}
	}
	var count: u32 = 0;
	var e: u32 = 1;
	while (e < 65535) : (e += 1) {
		if (isValidExponent(e)) count += 1;
	}
	return .{ .exp = exp, .log = log, .valid_exponent_count = count };
}

pub fn mul(a: u16, b: u16) u16 {
	if (a == 0 or b == 0) return 0;
	const la = tables.log[a];
	const lb = tables.log[b];
	const idx = (@as(u32, la) + @as(u32, lb)) % 65535;
	return tables.exp[@as(usize, @intCast(idx))];
}

pub fn inv(a: u16) u16 {
	if (a == 0) return 0;
	const la = tables.log[a];
	const idx = (65535 - la) % 65535;
	return tables.exp[@as(usize, @intCast(idx))];
}

pub fn pow(base: u16, exponent: u32) u16 {
	if (base == 0) return 0;
	const lb = tables.log[base];
	const idx = (@as(u64, lb) * @as(u64, exponent)) % 65535;
	return tables.exp[@as(usize, @intCast(idx))];
}

pub fn isValidExponent(exp: u32) bool {
	return (exp % 3 != 0) and (exp % 5 != 0) and (exp % 17 != 0) and (exp % 257 != 0);
}

pub fn constantForExponent(exp: u32) u16 {
	return tables.exp[@as(usize, @intCast(exp % 65535))];
}

pub fn constantForIndex(index: u32) u16 {
	std.debug.assert(index < maxValidIndexCount());
	return index_tables.constants[@as(usize, @intCast(index))];
}

pub fn exponentForIndex(index: u32) u32 {
	std.debug.assert(index < maxValidIndexCount());
	return index_tables.exponents[@as(usize, @intCast(index))];
}

pub fn maxValidIndexCount() u32 {
	return tables.valid_exponent_count;
}
