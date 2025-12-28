const std = @import("std");
const core = @import("core");

pub fn main() !void {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	defer _ = gpa.deinit();
	var arena = std.heap.ArenaAllocator.init(gpa.allocator());
	defer arena.deinit();
	const allocator = arena.allocator();
	const scratch = gpa.allocator();

	var args = try std.process.argsAlloc(allocator);
	defer std.process.argsFree(allocator, args);

	if (args.len < 3) {
		try usage();
		return;
	}

	const cmd = args[1];
	if (std.mem.eql(u8, cmd, "verify")) {
		const parsed = parseVerifyArgs(args[2..]) catch {
			try usage();
			return;
		};
		try cmdVerify(allocator, parsed.par2_path, parsed.data_paths, parsed.basepath, parsed.verbosity);
		return;
	}
	if (std.mem.eql(u8, cmd, "recover")) {
		const parsed = parseRecoverArgs(args[2..]) catch {
			try usage();
			return;
		};
		try cmdRecover(
			allocator,
			scratch,
			parsed.par2_path,
			parsed.data_paths,
			parsed.stdout_only,
			parsed.out_dir,
			parsed.allow_unsafe_paths,
			parsed.basepath,
			parsed.verbosity,
			parsed.memory_mb,
		);
		return;
	}
	if (std.mem.eql(u8, cmd, "create")) {
		const parsed = parseCreateArgs(args[2..]) catch {
			try usage();
			return;
		};
		try cmdCreate(parsed);
		return;
	}
	try usage();
}

fn usage() !void {
	try std.fs.File.stdout().writeAll(
	"Usage:\n  par2-cli verify <par2 file> <data files...>\n  par2-cli recover [-o|--out-dir <dir>] [--allow-unsafe-paths] <par2 file> <data files...>\n  par2-cli recover --stdout [--allow-unsafe-paths] <par2 file> <data files...>\n  par2-cli create [--block-size <bytes> | --block-count <n>] [--redundancy-percent <n> | --recovery-blocks <n>] [--comment <text>] [--mute-defaults] [--include-input-slices] [--emit-packed] [--no-rfsc] [--no-volume-meta] <par2 file> <data files...>\n\nNotes:\n  verify/recover match input files by exact path when possible, then by basename.\n  If basenames are ambiguous, verification/recovery fails unless exact paths are used.\n\npar2cmdline-turbo compatible options (subset):\n  -b<n> (block count)  -s<n> (block size)  -r<n> (redundancy %% )  -c<n> (recovery blocks)\n  -f<n> (first recovery block)  -u (uniform)  -l (limit)  -n<n> (recovery files)\n  -R (recurse)  -B<path> (basepath)  -m<n> (memory MB)  -v/-q (verbosity)\n",
	);
}

fn cmdVerify(
	allocator: std.mem.Allocator,
	par2_path: []const u8,
	data_paths: []const []const u8,
	basepath: ?[]const u8,
	verbosity: i32,
) !void {
	const par2_bytes = try std.fs.cwd().readFileAlloc(allocator, par2_path, 1 << 24);
	var ctx = core.api.initContext(allocator);
	var offset: usize = 0;
	while (offset + 64 <= par2_bytes.len) : (offset += 1) {
		const remaining = par2_bytes[offset..];
		const hdr = core.packet.parseHeader(remaining) catch {
			continue;
		};
		const end: usize = @intCast(hdr.length);
		if (end > remaining.len) break;
		const pkt = remaining[0..end];
		try core.api.addPacket(allocator, &ctx, pkt);
		offset += end - 1;
	}
	if (ctx.recovery_set == null) return error.InvalidInput;
	const rs_set = ctx.recovery_set.?;
	var data_files = try allocator.alloc([]const u8, rs_set.recovery_files.len);
	var present = try allocator.alloc(bool, rs_set.recovery_files.len);
	@memset(present, false);
	if (data_paths.len == 0) {
		var i: usize = 0;
		while (i < rs_set.recovery_files.len) : (i += 1) {
			const entry = rs_set.recovery_files[i];
			if (entry.desc == null) continue;
			const name = entry.desc.?.file_name;
			const candidate = if (basepath) |bp|
				try std.fs.path.join(allocator, &.{ bp, name })
			else
				name;
			data_files[i] = std.fs.cwd().readFileAlloc(allocator, candidate, 1 << 24) catch {
				continue;
			};
			present[i] = true;
		}
	} else {
		var i: usize = 0;
		while (i < data_paths.len) : (i += 1) {
			const path = data_paths[i];
			const base = std.fs.path.basename(path);
			const rel = if (basepath) |bp| try relativePathForInput(allocator, bp, path) else null;
			const idx = try findRecoveryIndexByName(rs_set, path, base, rel);
			if (present[idx]) return error.InvalidInput;
			data_files[idx] = try std.fs.cwd().readFileAlloc(allocator, path, 1 << 24);
			present[idx] = true;
		}
	}
	for (present) |p| {
		if (!p) return error.InvalidInput;
	}
	var i: usize = 0;
	while (i < rs_set.recovery_files.len) : (i += 1) {
		const entry = rs_set.recovery_files[i];
		if (entry.desc == null) return error.InvalidInput;
		if (entry.ifsc != null) continue;
		var computed: [16]u8 = undefined;
		try core.md5.md5Digest(data_files[i], &computed);
		if (!std.mem.eql(u8, &computed, &entry.desc.?.file_hash)) return error.InvalidInput;
	}
	const store = core.storage.MemoryStore{ .files = data_files };
	try core.api.verifyStore(allocator, &ctx, store);
	if (verbosity >= 0) {
		try std.fs.File.stdout().writeAll("OK\n");
	}
}

const CreateArgs = struct {
	block_size: ?u64,
	block_count: ?u64,
	redundancy_percent: ?u64,
	recovery_blocks: ?u64,
	first_recovery_block: ?u64,
	uniform_recovery: bool,
	limit_recovery: bool,
	recovery_file_count: ?u64,
	par2_path: []const u8,
	data_paths: []const []const u8,
	mute_defaults: bool,
	comment: ?[]const u8,
	include_input_slices: bool,
	emit_packed: bool,
	emit_rfsc: bool,
	include_volume_meta: bool,
	basepath: ?[]const u8,
	verbosity: i32,
	memory_mb: ?u64,
	recurse: bool,
};

const FileMeta = struct {
	path: []const u8,
	name: []const u8,
	length: u64,
	file_id: [16]u8,
	file_hash_16k: [16]u8,
};

const CreateInput = struct {
	path: []const u8,
	name: []const u8,
	length: u64,
};

fn parseCreateArgs(args: []const []const u8) !CreateArgs {
	var block_size: ?u64 = null;
	var block_count: ?u64 = null;
	var redundancy_percent: ?u64 = null;
	var recovery_blocks: ?u64 = null;
	var first_recovery_block: ?u64 = null;
	var uniform_recovery = false;
	var limit_recovery = false;
	var recovery_file_count: ?u64 = null;
	var mute_defaults = false;
	var comment: ?[]const u8 = null;
	var include_input_slices = false;
	var emit_packed = false;
	var emit_rfsc = true;
	var include_volume_meta = true;
	var basepath: ?[]const u8 = null;
	var verbosity: i32 = 0;
	var memory_mb: ?u64 = null;
	var recurse = false;
	var i: usize = 0;
	while (i < args.len) {
		const a = args[i];
		if (std.mem.eql(u8, a, "--")) {
			i += 1;
			break;
		}
		if (std.mem.eql(u8, a, "-v")) {
			verbosity += 1;
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, a, "-q")) {
			verbosity -= 1;
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, a, "-R")) {
			recurse = true;
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, a, "-m")) {
			if (i + 1 >= args.len) return error.InvalidInput;
			memory_mb = try std.fmt.parseInt(u64, args[i + 1], 10);
			i += 2;
			continue;
		}
		if (std.mem.startsWith(u8, a, "-m") and a.len > 2) {
			memory_mb = try std.fmt.parseInt(u64, a[2..], 10);
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, a, "-B") or std.mem.eql(u8, a, "--basepath")) {
			if (i + 1 >= args.len) return error.InvalidInput;
			basepath = args[i + 1];
			i += 2;
			continue;
		}
		if (std.mem.startsWith(u8, a, "-B") and a.len > 2) {
			basepath = a[2..];
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, a, "--mute-defaults")) {
			mute_defaults = true;
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, a, "--comment")) {
			if (i + 1 >= args.len) return error.InvalidInput;
			comment = args[i + 1];
			i += 2;
			continue;
		}
		if (std.mem.eql(u8, a, "--include-input-slices")) {
			include_input_slices = true;
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, a, "--emit-packed")) {
			emit_packed = true;
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, a, "--no-rfsc")) {
			emit_rfsc = false;
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, a, "--no-volume-meta")) {
			include_volume_meta = false;
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, a, "--block-size")) {
			if (i + 1 >= args.len) return error.InvalidInput;
			block_size = try std.fmt.parseInt(u64, args[i + 1], 10);
			i += 2;
			continue;
		}
		if (std.mem.eql(u8, a, "-s")) {
			if (i + 1 >= args.len) return error.InvalidInput;
			block_size = try std.fmt.parseInt(u64, args[i + 1], 10);
			i += 2;
			continue;
		}
		if (std.mem.startsWith(u8, a, "-s") and a.len > 2) {
			block_size = try std.fmt.parseInt(u64, a[2..], 10);
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, a, "--block-count")) {
			if (i + 1 >= args.len) return error.InvalidInput;
			block_count = try std.fmt.parseInt(u64, args[i + 1], 10);
			i += 2;
			continue;
		}
		if (std.mem.eql(u8, a, "-b")) {
			if (i + 1 >= args.len) return error.InvalidInput;
			block_count = try std.fmt.parseInt(u64, args[i + 1], 10);
			i += 2;
			continue;
		}
		if (std.mem.startsWith(u8, a, "-b") and a.len > 2) {
			block_count = try std.fmt.parseInt(u64, a[2..], 10);
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, a, "--redundancy-percent")) {
			if (i + 1 >= args.len) return error.InvalidInput;
			redundancy_percent = try std.fmt.parseInt(u64, args[i + 1], 10);
			i += 2;
			continue;
		}
		if (std.mem.eql(u8, a, "-r")) {
			if (i + 1 >= args.len) return error.InvalidInput;
			redundancy_percent = try std.fmt.parseInt(u64, args[i + 1], 10);
			i += 2;
			continue;
		}
		if (std.mem.startsWith(u8, a, "-r") and a.len > 2) {
			redundancy_percent = try std.fmt.parseInt(u64, a[2..], 10);
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, a, "--recovery-blocks")) {
			if (i + 1 >= args.len) return error.InvalidInput;
			recovery_blocks = try std.fmt.parseInt(u64, args[i + 1], 10);
			i += 2;
			continue;
		}
		if (std.mem.eql(u8, a, "-c")) {
			if (i + 1 >= args.len) return error.InvalidInput;
			recovery_blocks = try std.fmt.parseInt(u64, args[i + 1], 10);
			i += 2;
			continue;
		}
		if (std.mem.startsWith(u8, a, "-c") and a.len > 2) {
			recovery_blocks = try std.fmt.parseInt(u64, a[2..], 10);
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, a, "-f")) {
			if (i + 1 >= args.len) return error.InvalidInput;
			first_recovery_block = try std.fmt.parseInt(u64, args[i + 1], 10);
			i += 2;
			continue;
		}
		if (std.mem.startsWith(u8, a, "-f") and a.len > 2) {
			first_recovery_block = try std.fmt.parseInt(u64, a[2..], 10);
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, a, "-u")) {
			uniform_recovery = true;
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, a, "-l")) {
			limit_recovery = true;
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, a, "-R")) {
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, a, "-n")) {
			if (i + 1 >= args.len) return error.InvalidInput;
			recovery_file_count = try std.fmt.parseInt(u64, args[i + 1], 10);
			i += 2;
			continue;
		}
		if (std.mem.startsWith(u8, a, "-n") and a.len > 2) {
			recovery_file_count = try std.fmt.parseInt(u64, a[2..], 10);
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, a, "-B")) {
			if (i + 1 >= args.len) return error.InvalidInput;
			i += 2;
			continue;
		}
		if (std.mem.startsWith(u8, a, "-B") and a.len > 2) {
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, a, "-m")) {
			if (i + 1 >= args.len) return error.InvalidInput;
			i += 2;
			continue;
		}
		if (std.mem.startsWith(u8, a, "-m") and a.len > 2) {
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, a, "-v") or std.mem.eql(u8, a, "-q")) {
			i += 1;
			continue;
		}
		break;
	}
	if (block_size != null and block_count != null) return error.InvalidInput;
	if (redundancy_percent != null and recovery_blocks != null) return error.InvalidInput;
	if (uniform_recovery and limit_recovery) return error.InvalidInput;
	if (limit_recovery and recovery_file_count != null) return error.InvalidInput;
	if (recovery_file_count) |count| {
		if (count == 0 or count > 31) return error.InvalidInput;
	}
	if (i >= args.len) return error.InvalidInput;
	const par2_path = args[i];
	const data_paths = args[i + 1 ..];
	if (data_paths.len == 0) return error.InvalidInput;
	if (redundancy_percent == null and recovery_blocks == null) {
		redundancy_percent = 5;
	}
	return .{
		.block_size = block_size,
		.block_count = block_count,
		.redundancy_percent = redundancy_percent,
		.recovery_blocks = recovery_blocks,
		.first_recovery_block = first_recovery_block,
		.uniform_recovery = uniform_recovery,
		.limit_recovery = limit_recovery,
		.recovery_file_count = recovery_file_count,
		.par2_path = par2_path,
		.data_paths = data_paths,
		.mute_defaults = mute_defaults,
		.comment = comment,
		.include_input_slices = include_input_slices,
		.emit_packed = emit_packed,
		.emit_rfsc = emit_rfsc,
		.include_volume_meta = include_volume_meta,
		.basepath = basepath,
		.verbosity = verbosity,
		.memory_mb = memory_mb,
		.recurse = recurse,
	};
}

fn cmdCreate(args: CreateArgs) !void {
	var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
	defer arena.deinit();
	const allocator = arena.allocator();

	const inputs = try collectCreateInputs(allocator, args.data_paths, args.recurse, args.basepath);
	var total_size: u64 = 0;
	var max_file_len: u64 = 0;
	for (inputs) |input| {
		total_size += input.length;
		if (input.length > max_file_len) max_file_len = input.length;
	}
	const block_size = if (args.block_size) |v|
		v
	else if (args.block_count) |c|
		core.create_plan.blockSizeFromCount(total_size, c)
	else
		core.heuristics.blockSizeHeuristic(total_size);
	const cap_bytes = try memoryCapBytes(args.memory_mb);
	if (cap_bytes) |cap| {
		if (cap == 0) return error.InvalidInput;
		if (block_size > cap) return error.InvalidInput;
	}
	const data_blocks = if (block_size == 0) 0 else (total_size + block_size - 1) / block_size;
	const recovery_blocks = if (args.recovery_blocks) |v|
		v
	else
		core.create_plan.recoveryBlocksFromPercent(data_blocks, args.redundancy_percent orelse 0) catch return error.InvalidInput;

	const mute_defaults = args.mute_defaults or envMuteDefaults();
	if (!mute_defaults) {
		if (args.block_size == null and args.block_count == null) {
			var buf: [128]u8 = undefined;
			const msg = try std.fmt.bufPrint(&buf, "default block size: {d}\n", .{block_size});
			try std.fs.File.stderr().writeAll(msg);
		}
		if (args.recovery_blocks == null and args.redundancy_percent != null) {
			var buf2: [128]u8 = undefined;
			const msg2 = try std.fmt.bufPrint(&buf2, "default redundancy percent: {d}\n", .{args.redundancy_percent.?});
			try std.fs.File.stderr().writeAll(msg2);
		}
		var plan_buf: [256]u8 = undefined;
		const plan = try std.fmt.bufPrint(
			&plan_buf,
			"derived plan: total_size={d} block_size={d} data_blocks={d} recovery_blocks={d}\n",
		.{ total_size, block_size, data_blocks, recovery_blocks },
	);
	try std.fs.File.stderr().writeAll(plan);
	}

	var files = try allocator.alloc(FileMeta, inputs.len);
	var i: usize = 0;
	while (i < inputs.len) : (i += 1) {
		const input = inputs[i];
		const file_hash_16k = try md5First16k(input.path);
		const file_id = try core.file_id.fileIdFromHash16k(allocator, file_hash_16k, input.length, input.name);
		files[i] = .{
			.path = input.path,
			.name = input.name,
			.length = input.length,
			.file_id = file_id,
			.file_hash_16k = file_hash_16k,
		};
	}

	std.sort.insertion(FileMeta, files, {}, fileMetaLessThan);

	var file_ids = try allocator.alloc([16]u8, files.len);
	i = 0;
	while (i < files.len) : (i += 1) {
		file_ids[i] = files[i].file_id;
	}
	const main_body = try core.create_packets.buildMainBody(allocator, block_size, file_ids);
	var recovery_set_id: [16]u8 = undefined;
	try core.md5.md5Digest(main_body, &recovery_set_id);

	const creator_text = @import("par2").version_string;
	const creator_pkt = try core.create_packets.buildCreatorPacket(allocator, recovery_set_id, creator_text);
	const main_pkt = try core.create_packets.buildMainPacket(allocator, recovery_set_id, main_body);

	var main_packets = std.ArrayList([]const u8).empty;
	defer main_packets.deinit(allocator);
	var volume_meta_packets = std.ArrayList([]const u8).empty;
	defer volume_meta_packets.deinit(allocator);
	try main_packets.append(allocator, main_pkt);
	if (args.include_volume_meta) {
		try volume_meta_packets.append(allocator, main_pkt);
	}
	if (args.emit_packed) {
		const pkd_body = try core.create_packets.buildPackedMainBody(allocator, block_size, block_size, file_ids, &.{});
		const pkd_pkt = try core.create_packets.buildPackedMainPacket(allocator, recovery_set_id, pkd_body);
		try main_packets.append(allocator, pkd_pkt);
	}
	if (args.comment) |text| {
		if (isAscii(text)) {
			const comm = try core.create_packets.buildCommentAsciiPacket(allocator, recovery_set_id, text);
			try main_packets.append(allocator, comm);
		} else {
			const ascii = try transliterateAscii(allocator, text);
			if (ascii) |ascii_text| {
				const comm = try core.create_packets.buildCommentAsciiPacket(allocator, recovery_set_id, ascii_text);
				try main_packets.append(allocator, comm);
				const commu = try core.create_packets.buildCommentUnicodePacketWithAscii(allocator, recovery_set_id, text, ascii_text);
				try main_packets.append(allocator, commu);
			} else {
				const commu = try core.create_packets.buildCommentUnicodePacket(allocator, recovery_set_id, text);
				try main_packets.append(allocator, commu);
			}
		}
	}
	try main_packets.append(allocator, creator_pkt);

	const slice_size = std.math.cast(usize, block_size) orelse return error.InvalidInput;
	var file_infos = try allocator.alloc(core.layout.FileInfo, files.len);
	i = 0;
	while (i < files.len) : (i += 1) {
		file_infos[i] = .{ .length = files[i].length };
	}

	var main_file = try std.fs.cwd().createFile(args.par2_path, .{ .truncate = true });
	defer main_file.close();
	for (main_packets.items) |pkt| {
		try main_file.writeAll(pkt);
	}

	i = 0;
	while (i < files.len) : (i += 1) {
		var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
		defer file_arena.deinit();
		const temp_alloc = file_arena.allocator();
		const f = files[i];
		const info = try computeFileInfoAndMaybeWriteSlices(
			temp_alloc,
			f.path,
			f.file_id,
			recovery_set_id,
			slice_size,
			args.include_input_slices,
			main_file,
		);
		const filedesc_pkt = try core.create_packets.buildFileDescPacket(
			temp_alloc,
			recovery_set_id,
			f.file_id,
			info.file_hash,
			f.file_hash_16k,
			f.length,
			f.name,
		);
		try main_file.writeAll(filedesc_pkt);
		if (args.include_volume_meta) {
			const copy = try allocator.dupe(u8, filedesc_pkt);
			try volume_meta_packets.append(allocator, copy);
		}
		const ifsc_pkt = try core.create_packets.buildIfscPacket(
			temp_alloc,
			recovery_set_id,
			f.file_id,
			info.ifsc_entries,
		);
		try main_file.writeAll(ifsc_pkt);
		if (args.include_volume_meta) {
			const copy = try allocator.dupe(u8, ifsc_pkt);
			try volume_meta_packets.append(allocator, copy);
		}
		if (!isAscii(f.name)) {
			const uni_pkt = try core.create_packets.buildUnicodeFilenamePacket(temp_alloc, recovery_set_id, f.file_id, f.name);
			try main_file.writeAll(uni_pkt);
		}
	}
	if (args.include_volume_meta) {
		try volume_meta_packets.append(allocator, creator_pkt);
	}

	if (recovery_blocks > 0) {
		const offset = args.first_recovery_block orelse 0;
		if (offset > std.math.maxInt(u32)) return error.InvalidInput;
		if (recovery_blocks > 0 and offset > std.math.maxInt(u32) - (recovery_blocks - 1)) return error.InvalidInput;
		var file_entries = try allocator.alloc(core.storage.FileEntry, files.len);
		i = 0;
		while (i < files.len) : (i += 1) {
			file_entries[i] = .{ .path = files[i].path, .length = files[i].length, .present = true };
		}
		const store = core.storage.FileStore{ .files = file_entries };
		var plan = blk: {
			if (args.recovery_file_count) |count| {
				if (count == 0 or count > recovery_blocks) return error.InvalidInput;
				if (args.uniform_recovery) {
					break :blk try core.create_plan.splitRecoveryBlocksUniform(allocator, recovery_blocks, count);
				}
				break :blk try core.create_plan.splitRecoveryBlocksCounted(allocator, recovery_blocks, count);
			}
			if (args.uniform_recovery) {
				const count = core.create_plan.defaultVolumeCount(recovery_blocks);
				break :blk try core.create_plan.splitRecoveryBlocksUniform(allocator, recovery_blocks, count);
			}
			if (args.limit_recovery) {
				const max_blocks = if (block_size == 0) 0 else (max_file_len + block_size - 1) / block_size;
				break :blk try core.create_plan.splitRecoveryBlocksLimited(allocator, recovery_blocks, max_blocks);
			}
			break :blk try core.create_plan.splitRecoveryBlocksDefault(allocator, recovery_blocks);
		};
		var pi: usize = 0;
		while (pi < plan.len) : (pi += 1) {
			plan[pi].start += offset;
		}
		if (cap_bytes) |cap| {
			const slice_size_u64: u64 = @intCast(slice_size);
			for (plan) |vol| {
				const mul = @mulWithOverflow(vol.count, slice_size_u64);
				if (mul[1] != 0) return error.InvalidInput;
				if (mul[0] > cap) return error.InvalidInput;
			}
		}
		const width = volumeIndexWidth(recovery_blocks, offset);
		if (plan.len <= 1) {
			for (plan) |vol| {
				try buildVolume(
					allocator,
					volume_meta_packets.items,
					store,
					file_infos,
					slice_size,
					vol,
					width,
					args.par2_path,
					recovery_set_id,
					args.emit_rfsc,
					args.emit_packed,
					args.include_volume_meta,
					cap_bytes,
					true,
				);
			}
		} else {
			const cpu = std.Thread.getCpuCount() catch 1;
			const thread_count = if (args.memory_mb != null) 1 else @min(cpu, plan.len);
			if (thread_count <= 1) {
				for (plan) |vol| {
					try buildVolume(
						allocator,
						volume_meta_packets.items,
						store,
						file_infos,
						slice_size,
						vol,
						width,
						args.par2_path,
						recovery_set_id,
						args.emit_rfsc,
						args.emit_packed,
						args.include_volume_meta,
						cap_bytes,
						true,
					);
				}
			} else {
				var shared = VolumeShared{
					.volume_meta_packets = volume_meta_packets.items,
					.store = store,
					.file_infos = file_infos,
					.slice_size = slice_size,
					.plan = plan,
					.width = width,
					.par2_path = args.par2_path,
					.recovery_set_id = recovery_set_id,
					.emit_rfsc = args.emit_rfsc,
					.emit_packed = args.emit_packed,
					.include_volume_meta = args.include_volume_meta,
					.cap_bytes = cap_bytes,
					.next_index = std.atomic.Value(usize).init(0),
					.stop = std.atomic.Value(u8).init(0),
					.err = null,
					.err_mutex = .{},
				};
				var threads = try allocator.alloc(std.Thread, thread_count - 1);
				defer allocator.free(threads);
				var t: usize = 0;
				while (t + 1 < thread_count) : (t += 1) {
					threads[t] = std.Thread.spawn(.{}, volumeWorker, .{&shared}) catch {
						shared.stop.store(1, .monotonic);
						break;
					};
				}
				volumeWorker(&shared);
				t = 0;
				while (t + 1 < thread_count) : (t += 1) {
					threads[t].join();
				}
				if (shared.err) |e| return e;
			}
		}
	}

	try std.fs.File.stdout().writeAll("create: done\n");
}

fn fileMetaLessThan(_: void, a: FileMeta, b: FileMeta) bool {
	return std.mem.lessThan(u8, &a.file_id, &b.file_id);
}

fn isAscii(s: []const u8) bool {
	for (s) |c| {
		if (c >= 0x80) return false;
	}
	return true;
}

fn transliterateAscii(allocator: std.mem.Allocator, utf8: []const u8) !?[]const u8 {
	var out = std.ArrayList(u8).empty;
	defer out.deinit(allocator);
	var i: usize = 0;
	var changed = false;
	while (i < utf8.len) {
		const b = utf8[i];
		if (b < 0x80) {
			try out.append(allocator, b);
			i += 1;
			continue;
		}
		const r = try mapLatin1(allocator, utf8[i..]);
		if (r == null) return null;
		try out.appendSlice(allocator, r.?.bytes);
		allocator.free(r.?.bytes);
		i += r.?.len;
		changed = true;
	}
	if (!changed) return null;
	return try out.toOwnedSlice(allocator);
}

const MapResult = struct {
	bytes: []const u8,
	len: usize,
};

fn mapLatin1(allocator: std.mem.Allocator, s: []const u8) !?MapResult {
	if (s.len < 2) return null;
	const first = s[0];
	const second = s[1];
	if (first == 0xC3) {
		switch (second) {
			0xA1, 0xA0, 0xA4, 0xA2, 0xA3, 0xA5 => return asciiMap(allocator, "a?"),
			0x81, 0x80, 0x84, 0x82, 0x83, 0x85 => return asciiMap(allocator, "A?"),
			0xA9, 0xA8, 0xAB, 0xAA => return asciiMap(allocator, "e?"),
			0x89, 0x88, 0x8B, 0x8A => return asciiMap(allocator, "E?"),
			0xAD, 0xAC, 0xAF, 0xAE => return asciiMap(allocator, "i?"),
			0x8D, 0x8C, 0x8F, 0x8E => return asciiMap(allocator, "I?"),
			0xB3, 0xB2, 0xB6, 0xB4, 0xB5 => return asciiMap(allocator, "o?"),
			0x93, 0x92, 0x96, 0x94, 0x95 => return asciiMap(allocator, "O?"),
			0xBA, 0xB9, 0xBC, 0xBB => return asciiMap(allocator, "u?"),
			0x9A, 0x99, 0x9C, 0x9B => return asciiMap(allocator, "U?"),
			0xB1 => return asciiMap(allocator, "n?"),
			0x91 => return asciiMap(allocator, "N?"),
			0xA7 => return asciiMap(allocator, "c?"),
			0x87 => return asciiMap(allocator, "C?"),
			0x9F => return asciiMap(allocator, "ss?"),
			0xA6 => return asciiMap(allocator, "ae?"),
			0x86 => return asciiMap(allocator, "AE?"),
			0xB8 => return asciiMap(allocator, "o?"),
			0x98 => return asciiMap(allocator, "O?"),
			else => return null,
		}
	}
	return null;
}

fn asciiMap(allocator: std.mem.Allocator, text: []const u8) !?MapResult {
	const bytes = try allocator.dupe(u8, text);
	return .{ .bytes = bytes, .len = 2 };
}

const FileInfoResult = struct {
	file_hash: [16]u8,
	ifsc_entries: []core.packet_types.IfscEntry,
};

fn md5First16k(path: []const u8) ![16]u8 {
	var file = try std.fs.cwd().openFile(path, .{});
	defer file.close();
	var buf: [16384]u8 = undefined;
	const n = try file.readAll(&buf);
	var out: [16]u8 = undefined;
	try core.md5.md5Digest(buf[0..n], &out);
	return out;
}

fn computeFileInfoAndMaybeWriteSlices(
	allocator: std.mem.Allocator,
	path: []const u8,
	file_id: [16]u8,
	recovery_set_id: [16]u8,
	slice_size: usize,
	include_input_slices: bool,
	writer: std.fs.File,
) !FileInfoResult {
	var file = try std.fs.cwd().openFile(path, .{});
	defer file.close();
	const info = try file.stat();
	const file_len = info.size;
	const slice_count = try core.slices.sliceCount(file_len, slice_size);
	var entries = try allocator.alloc(core.packet_types.IfscEntry, slice_count);
	var md5_ctx = core.md5.Md5Ctx.init();

	var slice_buf = try allocator.alloc(u8, slice_size);
	defer allocator.free(slice_buf);
	var slice_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
	defer slice_arena.deinit();

	var remaining = file_len;
	var slice_index: usize = 0;
	while (slice_index < slice_count) : (slice_index += 1) {
		const chunk_len = @min(remaining, slice_size);
		if (chunk_len > 0) {
			const n = try file.readAll(slice_buf[0..@as(usize, @intCast(chunk_len))]);
			if (n != chunk_len) return error.InvalidInput;
			md5_ctx.update(slice_buf[0..@as(usize, @intCast(chunk_len))]);
			remaining -= chunk_len;
		}
		if (chunk_len < slice_size) {
			@memset(slice_buf[@as(usize, @intCast(chunk_len))..], 0);
		}
		try core.md5.md5Digest(slice_buf, &entries[slice_index].md5);
		entries[slice_index].crc32 = core.crc32.crc32(slice_buf);
		if (include_input_slices) {
			const pkt = try core.create_packets.buildFileSlicPacket(
				slice_arena.allocator(),
				recovery_set_id,
				file_id,
				@as(u64, @intCast(slice_index)),
				slice_buf,
			);
			try writer.writeAll(pkt);
			_ = slice_arena.reset(.retain_capacity);
		}
	}
	var file_hash: [16]u8 = undefined;
	md5_ctx.final(&file_hash);
	return .{ .file_hash = file_hash, .ifsc_entries = entries };
}

fn writePacketFile(path: []const u8, packets: []const []const u8) !void {
	var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
	defer file.close();
	for (packets) |pkt| {
		try file.writeAll(pkt);
	}
}

fn volumePath(allocator: std.mem.Allocator, par2_path: []const u8, start: u64, count: u64, width: usize) ![]const u8 {
	var base = par2_path;
	if (std.mem.endsWith(u8, par2_path, ".par2")) {
		base = par2_path[0 .. par2_path.len - 5];
	}
	const start_s = try indexPadded(allocator, start, width);
	var count_buf: [32]u8 = undefined;
	const count_s = try std.fmt.bufPrint(&count_buf, "{d}", .{count});
	const suffix = try std.mem.concat(allocator, u8, &.{ ".vol", start_s, "+", count_s, ".par2" });
	return try std.mem.concat(allocator, u8, &.{ base, suffix });
}

fn volumeIndexWidth(total: u64, first: u64) usize {
	if (total == 0) return 1;
	var max_index = first;
	if (total > 0) {
		const add = total - 1;
		const sum = @addWithOverflow(first, add);
		if (sum[1] == 0) max_index = sum[0];
	}
	var digits_total: usize = 0;
	var t = total;
	while (t > 0) : (t /= 10) {
		digits_total += 1;
	}
	var digits_max: usize = 0;
	t = max_index;
	while (t > 0) : (t /= 10) {
		digits_max += 1;
	}
	if (digits_total == 0) digits_total = 1;
	if (digits_max == 0) digits_max = 1;
	return if (digits_total > digits_max) digits_total else digits_max;
}

fn indexPadded(allocator: std.mem.Allocator, value: u64, width: usize) ![]const u8 {
	var buf: [32]u8 = undefined;
	const s = try std.fmt.bufPrint(&buf, "{d}", .{value});
	if (s.len >= width) return allocator.dupe(u8, s);
	const out = try allocator.alloc(u8, width);
	const pad_len = width - s.len;
	@memset(out[0..pad_len], '0');
	@memcpy(out[pad_len..], s);
	return out;
}

const VolumeShared = struct {
	volume_meta_packets: []const []const u8,
	store: core.storage.FileStore,
	file_infos: []const core.layout.FileInfo,
	slice_size: usize,
	plan: []const core.create_plan.VolumePlan,
	width: usize,
	par2_path: []const u8,
	recovery_set_id: [16]u8,
	emit_rfsc: bool,
	emit_packed: bool,
	include_volume_meta: bool,
	cap_bytes: ?u64,
	next_index: std.atomic.Value(usize),
	stop: std.atomic.Value(u8),
	err: ?anyerror,
	err_mutex: std.Thread.Mutex,
};

fn volumeWorker(shared: *VolumeShared) void {
	var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
	defer arena.deinit();
	while (shared.stop.load(.monotonic) == 0) {
		const idx = shared.next_index.fetchAdd(1, .monotonic);
		if (idx >= shared.plan.len) return;
		const vol = shared.plan[idx];
		buildVolume(
			arena.allocator(),
			shared.volume_meta_packets,
			shared.store,
			shared.file_infos,
			shared.slice_size,
			vol,
			shared.width,
			shared.par2_path,
			shared.recovery_set_id,
			shared.emit_rfsc,
			shared.emit_packed,
			shared.include_volume_meta,
			shared.cap_bytes,
			false,
		) catch |e| {
			setVolumeError(shared, e);
			return;
		};
	}
}

fn setVolumeError(shared: *VolumeShared, err: anyerror) void {
	shared.err_mutex.lock();
	defer shared.err_mutex.unlock();
	if (shared.err == null) shared.err = err;
	shared.stop.store(1, .monotonic);
}

fn buildVolume(
	allocator: std.mem.Allocator,
	volume_meta_packets: []const []const u8,
	store: core.storage.FileStore,
	file_infos: []const core.layout.FileInfo,
	slice_size: usize,
	vol: core.create_plan.VolumePlan,
	width: usize,
	par2_path: []const u8,
	recovery_set_id: [16]u8,
	emit_rfsc: bool,
	emit_packed: bool,
	include_volume_meta: bool,
	cap_bytes: ?u64,
	parallel_slices: bool,
) !void {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	defer _ = gpa.deinit();
	var limited: LimitedAllocator = undefined;
	var tmp_alloc = gpa.allocator();
	if (cap_bytes) |cap| {
		limited = LimitedAllocator.init(tmp_alloc, @intCast(cap));
		tmp_alloc = limited.allocator();
	}

	const vol_path = try volumePath(allocator, par2_path, vol.start, vol.count, width);
	var vol_file = try std.fs.cwd().createFile(vol_path, .{ .truncate = true });
	defer vol_file.close();
	var offset: usize = 0;
	const count_usize = std.math.cast(usize, vol.count) orelse return error.InvalidInput;
	var exponents = try tmp_alloc.alloc(u32, count_usize);
	defer tmp_alloc.free(exponents);
	var r: usize = 0;
	while (r < count_usize) : (r += 1) {
		exponents[r] = core.gf16.exponentForIndex(@as(u32, @intCast(vol.start + r)));
	}
	const rec_slices = if (parallel_slices)
		try core.block_api.computeRecoverySlicesFileStoreBatchParallel(tmp_alloc, store, file_infos, slice_size, exponents)
	else
		try core.block_api.computeRecoverySlicesFileStoreBatch(tmp_alloc, store, file_infos, slice_size, exponents);
	defer {
		var i: usize = 0;
		while (i < rec_slices.len) : (i += 1) {
			tmp_alloc.free(rec_slices[i]);
		}
		tmp_alloc.free(rec_slices);
	}
	var rfsc_entries = std.ArrayList(core.packet_types.RfscEntry).empty;
	defer rfsc_entries.deinit(allocator);
	r = 0;
	while (r < count_usize) : (r += 1) {
		const exp = exponents[r];
		const rec_slice = rec_slices[r];
		const pkt = try core.create_packets.buildRecvSlicPacket(allocator, recovery_set_id, exp, rec_slice);
		try vol_file.writeAll(pkt);
		offset += pkt.len;
		if (emit_rfsc) {
			var entry: core.packet_types.RfscEntry = undefined;
			try core.md5.md5Digest(rec_slice, &entry.md5);
			entry.crc32 = core.crc32.crc32(rec_slice);
			entry.exponent = exp;
			try rfsc_entries.append(allocator, entry);
		}
		if (emit_packed) {
			const pkd_pkt = try core.create_packets.buildPackedRecvSlicPacket(allocator, recovery_set_id, exp, rec_slice);
			try vol_file.writeAll(pkd_pkt);
			offset += pkd_pkt.len;
		}
	}
	var rfsc_offset: ?usize = null;
	if (emit_rfsc) {
		if (offset >= 16384) {
			const file_id: [16]u8 = .{0} ** 16;
			const rfsc_pkt = try core.create_packets.buildRfscPacket(allocator, recovery_set_id, file_id, rfsc_entries.items);
			rfsc_offset = offset;
			try vol_file.writeAll(rfsc_pkt);
			offset += rfsc_pkt.len;
		}
	}
	if (include_volume_meta) {
		for (volume_meta_packets) |pkt| {
			try vol_file.writeAll(pkt);
			offset += pkt.len;
		}
	}
	if (emit_rfsc and rfsc_offset != null) {
		try patchRfscFileId(vol_path, rfsc_offset.?);
	}
}

fn patchRfscFileId(path: []const u8, rfsc_offset: usize) !void {
	if (rfsc_offset < 16384) return;
	var file = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
	defer file.close();
	const info = try file.stat();
	const length = info.size;
	var buf: [16384]u8 = undefined;
	const read_len = @min(@as(u64, buf.len), length);
	_ = try file.readAll(buf[0..@as(usize, @intCast(read_len))]);
	var md5_16k: [16]u8 = undefined;
	try core.md5.md5Digest(buf[0..@as(usize, @intCast(read_len))], &md5_16k);
	const name = std.fs.path.basename(path);
	var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
	defer arena.deinit();
	const file_id = try core.file_id.fileIdFromHash16k(arena.allocator(), md5_16k, length, name);
	try file.seekTo(@as(u64, @intCast(rfsc_offset)));
	var header: [64]u8 = undefined;
	_ = try file.readAll(&header);
	const pkt_len = core.bytes.readU64Le(&header, 8) catch return error.InvalidInput;
	if (pkt_len < 64) return error.InvalidInput;
	var packet = try arena.allocator().alloc(u8, @as(usize, @intCast(pkt_len)));
	@memcpy(packet[0..64], &header);
	if (pkt_len > 64) {
		_ = try file.readAll(packet[64..]);
	}
	@memcpy(packet[64..80], &file_id);
	var digest: [16]u8 = undefined;
	try core.md5.md5Digest(packet[32..], &digest);
	@memcpy(packet[16..32], &digest);
	try file.seekTo(@as(u64, @intCast(rfsc_offset)));
	try file.writeAll(packet);
}

fn totalSizeBytes(paths: []const []const u8) !u64 {
	var total: u64 = 0;
	for (paths) |path| {
		const info = try std.fs.cwd().statFile(path);
		total += info.size;
	}
	return total;
}

fn memoryCapBytes(memory_mb: ?u64) !?u64 {
	if (memory_mb == null) return null;
	const mb = memory_mb.?;
	const mul = @mulWithOverflow(mb, @as(u64, 1024 * 1024));
	if (mul[1] != 0) return error.InvalidInput;
	return mul[0];
}

const LimitedAllocator = struct {
	child: std.mem.Allocator,
	cap: usize,
	used: usize,

	pub fn init(child: std.mem.Allocator, cap: usize) LimitedAllocator {
		return .{ .child = child, .cap = cap, .used = 0 };
	}

	pub fn allocator(self: *LimitedAllocator) std.mem.Allocator {
		return .{ .ptr = self, .vtable = &vtable };
	}

	fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
		const self: *LimitedAllocator = @ptrCast(@alignCast(ctx));
		const new_used = self.used + len;
		if (new_used > self.cap) return null;
		const ptr = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
		self.used = new_used;
		return ptr;
	}

	fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
		const self: *LimitedAllocator = @ptrCast(@alignCast(ctx));
		if (new_len <= buf.len) {
			const ok = self.child.rawResize(buf, alignment, new_len, ret_addr);
			if (!ok) return false;
			self.used -= buf.len - new_len;
			return true;
		}
		const add = new_len - buf.len;
		if (self.used + add > self.cap) return false;
		const ok = self.child.rawResize(buf, alignment, new_len, ret_addr);
		if (!ok) return false;
		self.used += add;
		return true;
	}

	fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
		const self: *LimitedAllocator = @ptrCast(@alignCast(ctx));
		if (new_len <= buf.len) {
			const ptr = self.child.rawRemap(buf, alignment, new_len, ret_addr) orelse return null;
			self.used -= buf.len - new_len;
			return ptr;
		}
		const add = new_len - buf.len;
		if (self.used + add > self.cap) return null;
		const ptr = self.child.rawRemap(buf, alignment, new_len, ret_addr) orelse return null;
		self.used += add;
		return ptr;
	}

	fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
		const self: *LimitedAllocator = @ptrCast(@alignCast(ctx));
		self.child.rawFree(buf, alignment, ret_addr);
		if (self.used >= buf.len) {
			self.used -= buf.len;
		} else {
			self.used = 0;
		}
	}

	const vtable = std.mem.Allocator.VTable{
		.alloc = alloc,
		.resize = resize,
		.remap = remap,
		.free = free,
	};
};

fn trimTrailingSeparators(path: []const u8) []const u8 {
	if (path.len == 0) return path;
	var end = path.len;
	while (end > 1) : (end -= 1) {
		const c = path[end - 1];
		if (c != '/' and c != '\\') break;
	}
	return path[0..end];
}

fn isPathPrefix(base: []const u8, full: []const u8) bool {
	if (!std.mem.startsWith(u8, full, base)) return false;
	if (full.len == base.len) return true;
	const next = full[base.len];
	return next == '/' or next == '\\';
}

fn relativePathForInput(allocator: std.mem.Allocator, basepath: []const u8, path: []const u8) !?[]const u8 {
	const base_abs = try std.fs.cwd().realpathAlloc(allocator, basepath);
	defer allocator.free(base_abs);
	const base_norm = trimTrailingSeparators(base_abs);
	const path_abs = try std.fs.cwd().realpathAlloc(allocator, path);
	defer allocator.free(path_abs);
	return relativePathUnderBase(allocator, base_norm, path_abs);
}

fn relativePathUnderBase(allocator: std.mem.Allocator, base_abs: []const u8, file_abs: []const u8) !?[]const u8 {
	if (!isPathPrefix(base_abs, file_abs)) return null;
	var start = base_abs.len;
	if (file_abs.len > base_abs.len) {
		const c = file_abs[start];
		if (c == '/' or c == '\\') start += 1;
	}
	if (start >= file_abs.len) return null;
	const rel = file_abs[start..];
	if (hasTraversalSegment(rel)) return null;
	if (hasWindowsDrivePrefix(rel)) return null;
	if (std.fs.path.isAbsolute(rel)) return null;
	const out = try allocator.dupe(u8, rel);
	return out;
}

fn collectCreateInputs(
	allocator: std.mem.Allocator,
	inputs: []const []const u8,
	recurse: bool,
	basepath: ?[]const u8,
) ![]CreateInput {
	var list = std.ArrayList(CreateInput).empty;
	defer list.deinit(allocator);

	var base_abs: ?[]u8 = null;
	if (basepath) |bp| {
		const abs = try std.fs.cwd().realpathAlloc(allocator, bp);
		base_abs = abs;
	}
	if (base_abs) |abs| {
		base_abs = try allocator.dupe(u8, trimTrailingSeparators(abs));
	}

	for (inputs) |path| {
		const info = std.fs.cwd().statFile(path) catch continue;
		if (info.kind == .file) {
			const entry = try buildCreateInput(allocator, path, info.size, base_abs);
			if (entry) |value| try list.append(allocator, value);
			continue;
		}
		if (info.kind != .directory or !recurse) continue;
		var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
		defer dir.close();
		var walker = try dir.walk(allocator);
		defer walker.deinit();
		while (try walker.next()) |item| {
			if (item.kind != .file) continue;
			const full_path = try std.fs.path.join(allocator, &.{ path, item.path });
			const file_info = std.fs.cwd().statFile(full_path) catch {
				allocator.free(full_path);
				continue;
			};
			const entry = try buildCreateInput(allocator, full_path, file_info.size, base_abs);
			if (entry) |value| {
				try list.append(allocator, value);
			} else {
				allocator.free(full_path);
			}
		}
	}

	if (list.items.len == 0) return error.InvalidInput;
	return list.toOwnedSlice(allocator);
}

fn buildCreateInput(
	allocator: std.mem.Allocator,
	path: []const u8,
	length: u64,
	base_abs: ?[]const u8,
) !?CreateInput {
	if (base_abs) |base| {
		const abs = try std.fs.cwd().realpathAlloc(allocator, path);
		const rel = try relativePathUnderBase(allocator, base, abs);
		if (rel == null) {
			var buf: [256]u8 = undefined;
			const msg = try std.fmt.bufPrint(&buf, "Ignoring out of basepath source file: {s}\n", .{abs});
			try std.fs.File.stdout().writeAll(msg);
			allocator.free(abs);
			return null;
		}
		allocator.free(abs);
		return .{
			.path = try allocator.dupe(u8, path),
			.name = rel.?,
			.length = length,
		};
	}
	const name = try safeFileName(path);
	return .{
		.path = try allocator.dupe(u8, path),
		.name = name,
		.length = length,
	};
}

fn envMuteDefaults() bool {
	const val = std.process.getEnvVarOwned(std.heap.page_allocator, "PAR2_MUTE_DEFAULTS") catch return false;
	defer std.heap.page_allocator.free(val);
	if (val.len == 0) return false;
	if (std.mem.eql(u8, val, "0")) return false;
	if (std.mem.eql(u8, val, "false")) return false;
	return true;
}

fn envFlagSet(name: []const u8) bool {
	const val = std.process.getEnvVarOwned(std.heap.page_allocator, name) catch return false;
	defer std.heap.page_allocator.free(val);
	if (val.len == 0) return false;
	if (std.mem.eql(u8, val, "0")) return false;
	if (std.mem.eql(u8, val, "false")) return false;
	return true;
}

test "parseCreateArgs rejects both block size and block count" {
	try std.testing.expectError(error.InvalidInput, parseCreateArgs(&.{
		"--block-size",
		"4096",
		"--block-count",
		"10",
		"out.par2",
		"file.bin",
	}));
}

test "parseCreateArgs rejects both redundancy percent and recovery blocks" {
	try std.testing.expectError(error.InvalidInput, parseCreateArgs(&.{
		"--redundancy-percent",
		"10",
		"--recovery-blocks",
		"5",
		"out.par2",
		"file.bin",
	}));
}

test "parseCreateArgs requires data files" {
	try std.testing.expectError(error.InvalidInput, parseCreateArgs(&.{ "out.par2" }));
}

test "parseCreateArgs parses flags and paths" {
	const parsed = try parseCreateArgs(&.{
		"--block-size",
		"4096",
		"--redundancy-percent",
		"10",
		"out.par2",
		"file.bin",
		"file2.bin",
	});
	try std.testing.expectEqual(@as(u64, 4096), parsed.block_size.?);
	try std.testing.expectEqual(@as(u64, 10), parsed.redundancy_percent.?);
	try std.testing.expectEqualStrings("out.par2", parsed.par2_path);
	try std.testing.expectEqual(@as(usize, 2), parsed.data_paths.len);
	try std.testing.expect(parsed.include_volume_meta);
}

test "parseCreateArgs defaults redundancy percent" {
	const parsed = try parseCreateArgs(&.{ "out.par2", "file.bin" });
	try std.testing.expectEqual(@as(u64, 5), parsed.redundancy_percent.?);
}

test "parseCreateArgs accepts mute defaults" {
	const parsed = try parseCreateArgs(&.{ "--mute-defaults", "out.par2", "file.bin" });
	try std.testing.expect(parsed.mute_defaults);
}

test "parseCreateArgs accepts comment" {
	const parsed = try parseCreateArgs(&.{ "--comment", "hello", "out.par2", "file.bin" });
	try std.testing.expectEqualStrings("hello", parsed.comment.?);
}

test "parseCreateArgs accepts include input slices" {
	const parsed = try parseCreateArgs(&.{ "--include-input-slices", "out.par2", "file.bin" });
	try std.testing.expect(parsed.include_input_slices);
}

test "parseCreateArgs accepts emit packed" {
	const parsed = try parseCreateArgs(&.{ "--emit-packed", "out.par2", "file.bin" });
	try std.testing.expect(parsed.emit_packed);
}

test "parseCreateArgs accepts no rfsc" {
	const parsed = try parseCreateArgs(&.{ "--no-rfsc", "out.par2", "file.bin" });
	try std.testing.expect(!parsed.emit_rfsc);
}

test "parseCreateArgs accepts no volume meta" {
	const parsed = try parseCreateArgs(&.{ "--no-volume-meta", "out.par2", "file.bin" });
	try std.testing.expect(!parsed.include_volume_meta);
}

test "parseCreateArgs accepts par2-style short flags" {
	const parsed = try parseCreateArgs(&.{ "-s4096", "-r10", "out.par2", "file.bin" });
	try std.testing.expectEqual(@as(u64, 4096), parsed.block_size.?);
	try std.testing.expectEqual(@as(u64, 10), parsed.redundancy_percent.?);
}

test "parseCreateArgs parses basepath, memory, and verbosity" {
	const parsed = try parseCreateArgs(&.{ "-v", "-q", "-m", "64", "-B", "base", "out.par2", "file.bin" });
	try std.testing.expectEqual(@as(i32, 0), parsed.verbosity);
	try std.testing.expectEqual(@as(u64, 64), parsed.memory_mb.?);
	try std.testing.expectEqualStrings("base", parsed.basepath.?);
}

test "parseCreateArgs accepts recovery split flags" {
	const parsed = try parseCreateArgs(&.{ "-u", "-n3", "-f5", "out.par2", "file.bin" });
	try std.testing.expect(parsed.uniform_recovery);
	try std.testing.expectEqual(@as(u64, 3), parsed.recovery_file_count.?);
	try std.testing.expectEqual(@as(u64, 5), parsed.first_recovery_block.?);
}

test "parseCreateArgs accepts limit recovery" {
	const parsed = try parseCreateArgs(&.{ "-l", "out.par2", "file.bin" });
	try std.testing.expect(parsed.limit_recovery);
}

test "parseCreateArgs rejects uniform and limit" {
	try std.testing.expectError(error.InvalidInput, parseCreateArgs(&.{ "-u", "-l", "out.par2", "file.bin" }));
}

test "parseCreateArgs rejects limit and recovery file count" {
	try std.testing.expectError(error.InvalidInput, parseCreateArgs(&.{ "-l", "-n3", "out.par2", "file.bin" }));
}

test "transliterateAscii maps latin1 accents" {
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();
	const out = try transliterateAscii(arena.allocator(), "hé");
	try std.testing.expectEqualStrings("he?", out.?);
}

test "transliterateAscii returns null on unmapped" {
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();
	const out = try transliterateAscii(arena.allocator(), "€");
	try std.testing.expect(out == null);
}

test "transliterateAscii covers all latin1 mappings" {
	const cases = [_]struct { in: []const u8, out: []const u8 }{
		.{ .in = "á", .out = "a?" }, .{ .in = "à", .out = "a?" }, .{ .in = "ä", .out = "a?" }, .{ .in = "â", .out = "a?" },
		.{ .in = "ã", .out = "a?" }, .{ .in = "å", .out = "a?" }, .{ .in = "Á", .out = "A?" }, .{ .in = "À", .out = "A?" },
		.{ .in = "Ä", .out = "A?" }, .{ .in = "Â", .out = "A?" }, .{ .in = "Ã", .out = "A?" }, .{ .in = "Å", .out = "A?" },
		.{ .in = "é", .out = "e?" }, .{ .in = "è", .out = "e?" }, .{ .in = "ë", .out = "e?" }, .{ .in = "ê", .out = "e?" },
		.{ .in = "É", .out = "E?" }, .{ .in = "È", .out = "E?" }, .{ .in = "Ë", .out = "E?" }, .{ .in = "Ê", .out = "E?" },
		.{ .in = "í", .out = "i?" }, .{ .in = "ì", .out = "i?" }, .{ .in = "ï", .out = "i?" }, .{ .in = "î", .out = "i?" },
		.{ .in = "Í", .out = "I?" }, .{ .in = "Ì", .out = "I?" }, .{ .in = "Ï", .out = "I?" }, .{ .in = "Î", .out = "I?" },
		.{ .in = "ó", .out = "o?" }, .{ .in = "ò", .out = "o?" }, .{ .in = "ö", .out = "o?" }, .{ .in = "ô", .out = "o?" },
		.{ .in = "õ", .out = "o?" }, .{ .in = "Ó", .out = "O?" }, .{ .in = "Ò", .out = "O?" }, .{ .in = "Ö", .out = "O?" },
		.{ .in = "Ô", .out = "O?" }, .{ .in = "Õ", .out = "O?" }, .{ .in = "ú", .out = "u?" }, .{ .in = "ù", .out = "u?" },
		.{ .in = "ü", .out = "u?" }, .{ .in = "û", .out = "u?" }, .{ .in = "Ú", .out = "U?" }, .{ .in = "Ù", .out = "U?" },
		.{ .in = "Ü", .out = "U?" }, .{ .in = "Û", .out = "U?" }, .{ .in = "ñ", .out = "n?" }, .{ .in = "Ñ", .out = "N?" },
		.{ .in = "ç", .out = "c?" }, .{ .in = "Ç", .out = "C?" }, .{ .in = "ß", .out = "ss?" }, .{ .in = "æ", .out = "ae?" },
		.{ .in = "Æ", .out = "AE?" }, .{ .in = "ø", .out = "o?" }, .{ .in = "Ø", .out = "O?" },
	};
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();
	for (cases) |c| {
		const out = try transliterateAscii(arena.allocator(), c.in);
		try std.testing.expect(out != null);
		try std.testing.expectEqualStrings(c.out, out.?);
	}
}

test "transliterateAscii preserves ascii and maps accents in mixed string" {
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();
	const out = try transliterateAscii(arena.allocator(), "File_éß.txt");
	try std.testing.expectEqualStrings("File_e?ss?.txt", out.?);
}

fn cmdRecover(
	allocator: std.mem.Allocator,
	scratch: std.mem.Allocator,
	par2_path: []const u8,
	data_paths: []const []const u8,
	stdout_only: bool,
	out_dir: ?[]const u8,
	allow_unsafe_paths: bool,
	basepath: ?[]const u8,
	verbosity: i32,
	memory_mb: ?u64,
) !void {
	const debug_recover = envFlagSet("PAR2_DEBUG_RECOVER");
	const cap_bytes = try memoryCapBytes(memory_mb);
	var limited: LimitedAllocator = undefined;
	var recover_alloc = allocator;
	if (cap_bytes) |cap| {
		limited = LimitedAllocator.init(scratch, @intCast(cap));
		recover_alloc = limited.allocator();
	}
	var ctx = core.api.initContext(allocator);
	var recovery_slices = std.ArrayList(core.rs.RecoverySlice).empty;
	defer recovery_slices.deinit(allocator);
	var packed_slices = std.ArrayList(core.rs.RecoverySlice).empty;
	defer packed_slices.deinit(allocator);
	var file_slices = std.ArrayList(core.packet_types.FileSlicPacket).empty;
	defer file_slices.deinit(allocator);
	var rfsc_packets = std.ArrayList(core.packet_types.RfscPacket).empty;
	defer rfsc_packets.deinit(allocator);
	var recovery_set_id: ?[16]u8 = null;

	try loadPar2File(allocator, &ctx, &recovery_slices, &packed_slices, &file_slices, &rfsc_packets, par2_path, &recovery_set_id);
	try loadVolumeFiles(allocator, &ctx, &recovery_slices, &packed_slices, &file_slices, &rfsc_packets, par2_path, &recovery_set_id);

	if (ctx.recovery_set == null) return error.InvalidInput;
	if (debug_recover) {
		var desc_count: usize = 0;
		var ifsc_count: usize = 0;
		for (ctx.recovery_set.?.recovery_files) |entry| {
			if (entry.desc != null) desc_count += 1;
			if (entry.ifsc != null) ifsc_count += 1;
		}
		var buf: [128]u8 = undefined;
		const msg = try std.fmt.bufPrint(&buf, "debug: desc={d} ifsc={d} file_slices={d} rec_slices={d}\n", .{ desc_count, ifsc_count, file_slices.items.len, recovery_slices.items.len });
		try std.fs.File.stderr().writeAll(msg);
	}
	const rs_set = ctx.recovery_set.?;
	const slice_size = std.math.cast(usize, rs_set.slice_size) orelse return error.InvalidInput;
	if (recovery_slices.items.len == 0 and packed_slices.items.len > 0) {
		const packed_main = ctx.packed_main orelse ctx.main;
		if (packed_main) |m| {
			if (m.subslice_size != null and m.subslice_size.? == m.slice_size) {
				try recovery_slices.appendSlice(allocator, packed_slices.items);
			} else {
				return error.InvalidInput;
			}
		} else {
			return error.InvalidInput;
		}
	}

	var files = try allocator.alloc(core.layout.FileInfo, rs_set.recovery_files.len);
	var file_entries = try allocator.alloc(core.storage.FileEntry, rs_set.recovery_files.len);
	var i: usize = 0;
	while (i < rs_set.recovery_files.len) : (i += 1) {
		const entry = rs_set.recovery_files[i];
		if (entry.desc == null) return error.InvalidInput;
		const desc = entry.desc.?;
		files[i] = .{ .length = desc.file_length };
		file_entries[i] = .{ .path = "", .length = desc.file_length, .present = false };
	}

	var p: usize = 0;
	if (data_paths.len == 0) {
		while (p < rs_set.recovery_files.len) : (p += 1) {
			const entry = rs_set.recovery_files[p];
			if (entry.desc == null) continue;
			const name = entry.desc.?.file_name;
			const candidate = if (basepath) |bp|
				try std.fs.path.join(allocator, &.{ bp, name })
			else
				name;
			_ = std.fs.cwd().statFile(candidate) catch continue;
			file_entries[p].path = candidate;
			file_entries[p].present = true;
		}
	} else {
		while (p < data_paths.len) : (p += 1) {
			const path = data_paths[p];
			const base = std.fs.path.basename(path);
			const rel = if (basepath) |bp| try relativePathForInput(allocator, bp, path) else null;
			const idx = try findRecoveryIndexByName(rs_set, path, base, rel);
			if (file_entries[idx].present) return error.InvalidInput;
			file_entries[idx].path = path;
			file_entries[idx].present = true;
		}
	}

	const base_store = core.storage.FileStore{ .files = file_entries };
	var missing_flags = try allocator.alloc([]bool, rs_set.recovery_files.len);
	i = 0;
	while (i < rs_set.recovery_files.len) : (i += 1) {
		const entry = rs_set.recovery_files[i];
		if (entry.desc == null) return error.InvalidInput;
		const desc = entry.desc.?;
		const slice_count = try core.slices.sliceCount(desc.file_length, slice_size);
		var flags = try allocator.alloc(bool, slice_count);
		@memset(flags, false);
		if (!file_entries[i].present) {
			@memset(flags, true);
		} else {
			if (entry.ifsc == null) return error.InvalidInput;
			const expected = entry.ifsc.?.entries;
			if (expected.len != slice_count) return error.InvalidInput;
			var si: usize = 0;
			while (si < slice_count) : (si += 1) {
				const slice = base_store.readSlice(scratch, i, slice_size, si) catch {
					flags[si] = true;
					continue;
				};
				defer scratch.free(slice);
				const computed = try computeSliceEntry(slice);
				if (!std.mem.eql(u8, &computed.md5, &expected[si].md5) or computed.crc32 != expected[si].crc32) {
					flags[si] = true;
				}
			}
		}
		missing_flags[i] = flags;
	}

	const order = try core.layout.buildSliceOrder(allocator, files, slice_size);
	var overrides = std.AutoHashMap(u128, []const u8).init(allocator);
	defer overrides.deinit();
	if (file_slices.items.len > 0) {
		var id_map = std.AutoHashMap([16]u8, usize).init(allocator);
		defer id_map.deinit();
		i = 0;
		while (i < rs_set.recovery_files.len) : (i += 1) {
			const entry = rs_set.recovery_files[i];
			if (entry.desc == null) continue;
			try id_map.put(entry.desc.?.file_id, i);
		}
		for (file_slices.items) |fs| {
			const idx = id_map.get(fs.file_id) orelse continue;
			const slice_idx = std.math.cast(usize, fs.slice_index) orelse continue;
			if (slice_idx >= missing_flags[idx].len) continue;
			const key = makeSliceKey(idx, slice_idx);
			try overrides.put(key, fs.data);
			missing_flags[idx][slice_idx] = false;
		}
	}
	const store = SliceOverrideStore{
		.base = base_store,
		.overrides = &overrides,
	};
	if (cap_bytes) |cap| {
		if (cap == 0) return error.InvalidInput;
		const count_u64: u64 = @intCast(order.len);
		const slice_u64: u64 = @intCast(slice_size);
		const mul = @mulWithOverflow(count_u64, slice_u64);
		if (mul[1] != 0) return error.InvalidInput;
		if (mul[0] > cap) return error.InvalidInput;
	}
	var missing_indices = std.ArrayList(usize).empty;
	defer missing_indices.deinit(allocator);
	var oi: usize = 0;
	while (oi < order.len) : (oi += 1) {
		const ref = order[oi];
		if (missing_flags[ref.file_index][ref.slice_index]) {
			try missing_indices.append(allocator, oi);
		}
	}

	var missing_files_count: usize = 0;
	i = 0;
	while (i < rs_set.recovery_files.len) : (i += 1) {
		if (!file_entries[i].present or anyMissing(missing_flags[i])) missing_files_count += 1;
	}
	if (missing_indices.items.len == 0 and missing_files_count == 0) {
		if (verbosity >= 0) {
			try std.fs.File.stdout().writeAll("Nothing to recover\n");
		}
		return;
	}
	if (missing_indices.items.len > 0 and recovery_slices.items.len < missing_indices.items.len) return error.InvalidInput;

	const recovered = if (missing_indices.items.len == 0)
		try allocator.alloc([]u8, 0)
	else
		try core.api.recoverMissingSlicesMemory(
			recover_alloc,
			files,
			store,
			missing_indices.items,
			recovery_slices.items[0..missing_indices.items.len],
			slice_size,
		);
	defer {
		if (cap_bytes != null) {
			var ri: usize = 0;
			while (ri < recovered.len) : (ri += 1) {
				recover_alloc.free(recovered[ri]);
			}
			recover_alloc.free(recovered);
		}
	}

	var recovered_for = try allocator.alloc(?usize, order.len);
	@memset(recovered_for, null);
	for (missing_indices.items, 0..) |global_idx, rec_idx| {
		recovered_for[global_idx] = rec_idx;
	}
	if (stdout_only and missing_files_count != 1) return error.InvalidInput;

	i = 0;
	while (i < rs_set.recovery_files.len) : (i += 1) {
		if (file_entries[i].present and !anyMissing(missing_flags[i])) continue;
		const desc = rs_set.recovery_files[i].desc.?;
		var computed: [16]u8 = undefined;
		if (stdout_only) {
			const stdout = std.fs.File.stdout();
			computed = try writeRecoveredFileSlicesWithHash(scratch, store, order, recovered_for, recovered, i, slice_size, stdout);
		} else {
			const target_dir = out_dir orelse basepath;
			const out_path = try outputPath(allocator, target_dir, desc.file_name, allow_unsafe_paths);
			computed = try writeRecoveredFilePathWithHash(scratch, store, order, recovered_for, recovered, i, slice_size, out_path);
		}
		if (!std.mem.eql(u8, &computed, &desc.file_hash)) return error.InvalidInput;
	}

	if (verbosity >= 0) {
		var msg_buf: [64]u8 = undefined;
		const msg = try std.fmt.bufPrint(&msg_buf, "Recovered {d} slices\n", .{missing_indices.items.len});
		try std.fs.File.stdout().writeAll(msg);
	}
}

const RecoverArgs = struct {
	stdout_only: bool,
	out_dir: ?[]const u8,
	par2_path: []const u8,
	data_paths: []const []const u8,
	allow_unsafe_paths: bool,
	basepath: ?[]const u8,
	verbosity: i32,
	memory_mb: ?u64,
};

fn parseRecoverArgs(args: []const []const u8) !RecoverArgs {
	var stdout_only = false;
	var out_dir: ?[]const u8 = null;
	var allow_unsafe_paths = false;
	var basepath: ?[]const u8 = null;
	var verbosity: i32 = 0;
	var memory_mb: ?u64 = null;
	var i: usize = 0;
	while (i < args.len) {
		const a = args[i];
		if (std.mem.eql(u8, a, "--")) {
			i += 1;
			break;
		}
		if (std.mem.eql(u8, a, "--stdout")) {
			stdout_only = true;
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, a, "--allow-unsafe-paths")) {
			allow_unsafe_paths = true;
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, a, "-o") or std.mem.eql(u8, a, "--out-dir")) {
			if (i + 1 >= args.len) return error.InvalidInput;
			out_dir = args[i + 1];
			i += 2;
			continue;
		}
		if (std.mem.eql(u8, a, "-v")) {
			verbosity += 1;
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, a, "-q")) {
			verbosity -= 1;
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, a, "-R")) return error.InvalidInput;
		if (std.mem.eql(u8, a, "-m")) {
			if (i + 1 >= args.len) return error.InvalidInput;
			memory_mb = try std.fmt.parseInt(u64, args[i + 1], 10);
			i += 2;
			continue;
		}
		if (std.mem.startsWith(u8, a, "-m") and a.len > 2) {
			memory_mb = try std.fmt.parseInt(u64, a[2..], 10);
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, a, "-B") or std.mem.eql(u8, a, "--basepath")) {
			if (i + 1 >= args.len) return error.InvalidInput;
			basepath = args[i + 1];
			i += 2;
			continue;
		}
		if (std.mem.startsWith(u8, a, "-B") and a.len > 2) {
			basepath = a[2..];
			i += 1;
			continue;
		}
		break;
	}
	if (stdout_only and out_dir != null) return error.InvalidInput;
	if (i >= args.len) return error.InvalidInput;
	const par2_path = args[i];
	const data_paths = args[i + 1 ..];
	return .{
		.stdout_only = stdout_only,
		.out_dir = out_dir,
		.par2_path = par2_path,
		.data_paths = data_paths,
		.allow_unsafe_paths = allow_unsafe_paths,
		.basepath = basepath,
		.verbosity = verbosity,
		.memory_mb = memory_mb,
	};
}

const VerifyArgs = struct {
	par2_path: []const u8,
	data_paths: []const []const u8,
	basepath: ?[]const u8,
	verbosity: i32,
	memory_mb: ?u64,
};

fn parseVerifyArgs(args: []const []const u8) !VerifyArgs {
	var basepath: ?[]const u8 = null;
	var verbosity: i32 = 0;
	var memory_mb: ?u64 = null;
	var i: usize = 0;
	while (i < args.len) {
		const a = args[i];
		if (std.mem.eql(u8, a, "--")) {
			i += 1;
			break;
		}
		if (std.mem.eql(u8, a, "-v")) {
			verbosity += 1;
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, a, "-q")) {
			verbosity -= 1;
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, a, "-R")) return error.InvalidInput;
		if (std.mem.eql(u8, a, "-m")) {
			if (i + 1 >= args.len) return error.InvalidInput;
			memory_mb = try std.fmt.parseInt(u64, args[i + 1], 10);
			i += 2;
			continue;
		}
		if (std.mem.startsWith(u8, a, "-m") and a.len > 2) {
			memory_mb = try std.fmt.parseInt(u64, a[2..], 10);
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, a, "-B") or std.mem.eql(u8, a, "--basepath")) {
			if (i + 1 >= args.len) return error.InvalidInput;
			basepath = args[i + 1];
			i += 2;
			continue;
		}
		if (std.mem.startsWith(u8, a, "-B") and a.len > 2) {
			basepath = a[2..];
			i += 1;
			continue;
		}
		break;
	}
	if (i >= args.len) return error.InvalidInput;
	const par2_path = args[i];
	const data_paths = args[i + 1 ..];
	return .{
		.par2_path = par2_path,
		.data_paths = data_paths,
		.basepath = basepath,
		.verbosity = verbosity,
		.memory_mb = memory_mb,
	};
}

test "parseRecoverArgs accepts basepath, memory, and verbosity" {
	const parsed = try parseRecoverArgs(&.{ "-v", "-q", "-m", "32", "-B", "base", "file.par2" });
	try std.testing.expectEqual(@as(i32, 0), parsed.verbosity);
	try std.testing.expectEqual(@as(u64, 32), parsed.memory_mb.?);
	try std.testing.expectEqualStrings("base", parsed.basepath.?);
}

test "parseRecoverArgs rejects -R" {
	try std.testing.expectError(error.InvalidInput, parseRecoverArgs(&.{ "-R", "file.par2" }));
}

test "parseVerifyArgs parses basepath and memory" {
	const parsed = try parseVerifyArgs(&.{ "-m", "64", "-B", "base", "file.par2" });
	try std.testing.expectEqual(@as(u64, 64), parsed.memory_mb.?);
	try std.testing.expectEqualStrings("base", parsed.basepath.?);
}

fn loadPar2File(
	allocator: std.mem.Allocator,
	ctx: *core.api.Par2Context,
	recs: *std.ArrayList(core.rs.RecoverySlice),
	packed_recs: *std.ArrayList(core.rs.RecoverySlice),
	file_slices: *std.ArrayList(core.packet_types.FileSlicPacket),
	rfsc_packets: *std.ArrayList(core.packet_types.RfscPacket),
	path: []const u8,
	expected_id: *?[16]u8,
) !void {
	var local_recs = std.ArrayList(core.rs.RecoverySlice).empty;
	defer local_recs.deinit(allocator);
	var local_packed = std.ArrayList(core.rs.RecoverySlice).empty;
	defer local_packed.deinit(allocator);
	var local_rfsc = std.ArrayList(core.packet_types.RfscEntry).empty;
	defer local_rfsc.deinit(allocator);
	const info = try std.fs.cwd().statFile(path);
	const max_len = std.math.cast(usize, info.size) orelse return error.InvalidInput;
	const par2_bytes = try std.fs.cwd().readFileAlloc(allocator, path, max_len);
	var offset: usize = 0;
	while (offset + 64 <= par2_bytes.len) : (offset += 1) {
		const remaining = par2_bytes[offset..];
		const hdr = core.packet.parseHeader(remaining) catch {
			continue;
		};
		const end: usize = @intCast(hdr.length);
		if (end > remaining.len) break;
		const pkt = remaining[0..end];
		core.packet.verifyPacketHash(pkt) catch {
			continue;
		};
		if (expected_id.*) |value| {
			if (!std.mem.eql(u8, &value, &hdr.recovery_set_id)) {
				offset += end - 1;
				continue;
			}
		} else {
			expected_id.* = hdr.recovery_set_id;
		}
		try core.api.addPacket(allocator, ctx, pkt);
		if (isRecvSlicType(hdr.packet_type)) {
			const parsed = try core.packet_types.parseRecvSlic(pkt);
			try local_recs.append(allocator, .{ .exponent = parsed.exponent, .data = parsed.data });
			offset += end - 1;
			continue;
		}
		if (isPackedRecvSlicType(hdr.packet_type)) {
			const parsed = try core.packet_types.parsePackedRecvSlic(pkt);
			try local_packed.append(allocator, .{ .exponent = parsed.exponent, .data = parsed.data });
			offset += end - 1;
			continue;
		}
		if (isFileSlicType(hdr.packet_type)) {
			const parsed = try core.packet_types.parseFileSlic(pkt);
			try file_slices.append(allocator, parsed);
			offset += end - 1;
			continue;
		}
		if (isRfscType(hdr.packet_type)) {
			const parsed = try core.packet_types.parseRfsc(pkt, allocator);
			try rfsc_packets.append(allocator, parsed);
			for (parsed.entries) |entry| {
				try local_rfsc.append(allocator, entry);
			}
			offset += end - 1;
			continue;
		}
		offset += end - 1;
	}
	if (local_rfsc.items.len == 0) {
		try recs.appendSlice(allocator, local_recs.items);
		try packed_recs.appendSlice(allocator, local_packed.items);
		return;
	}
	var rfsc_map = std.AutoHashMap(u32, core.packet_types.RfscEntry).init(allocator);
	defer rfsc_map.deinit();
	for (local_rfsc.items) |entry| {
		_ = try rfsc_map.put(entry.exponent, entry);
	}
	for (local_recs.items) |rec| {
		if (rfsc_map.get(rec.exponent)) |entry| {
			var md5: [16]u8 = undefined;
			try core.md5.md5Digest(rec.data, &md5);
			const crc = core.crc32.crc32(rec.data);
			if (std.mem.eql(u8, &md5, &entry.md5) and crc == entry.crc32) {
				try recs.append(allocator, rec);
			}
		}
	}
	for (local_packed.items) |rec| {
		if (rfsc_map.get(rec.exponent)) |entry| {
			var md5: [16]u8 = undefined;
			try core.md5.md5Digest(rec.data, &md5);
			const crc = core.crc32.crc32(rec.data);
			if (std.mem.eql(u8, &md5, &entry.md5) and crc == entry.crc32) {
				try packed_recs.append(allocator, rec);
			}
		}
	}
}

fn loadVolumeFiles(
	allocator: std.mem.Allocator,
	ctx: *core.api.Par2Context,
	recs: *std.ArrayList(core.rs.RecoverySlice),
	packed_recs: *std.ArrayList(core.rs.RecoverySlice),
	file_slices: *std.ArrayList(core.packet_types.FileSlicPacket),
	rfsc_packets: *std.ArrayList(core.packet_types.RfscPacket),
	par2_path: []const u8,
	expected_id: *?[16]u8,
) !void {
	const dir_path = std.fs.path.dirname(par2_path) orelse ".";
	const base_name = std.fs.path.basename(par2_path);
	var base = if (std.mem.endsWith(u8, base_name, ".par2")) base_name[0 .. base_name.len - 5] else base_name;
	if (std.mem.indexOf(u8, base, ".vol")) |idx| {
		base = base[0..idx];
	}
	var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
	defer dir.close();
	var it = dir.iterate();
	while (try it.next()) |entry| {
		if (entry.kind != .file) continue;
		if (!std.mem.startsWith(u8, entry.name, base)) continue;
		if (!std.mem.endsWith(u8, entry.name, ".par2")) continue;
		if (std.mem.indexOf(u8, entry.name, ".vol") == null) continue;
		if (std.mem.eql(u8, entry.name, base_name)) continue;
		const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
		try loadPar2File(allocator, ctx, recs, packed_recs, file_slices, rfsc_packets, full_path, expected_id);
	}
}

fn isRecvSlicType(t: [16]u8) bool {
	const recvslic = [_]u8{ 'P','A','R',' ','2','.','0',0,'R','e','c','v','S','l','i','c' };
	return std.mem.eql(u8, &t, &recvslic);
}

fn isPackedRecvSlicType(t: [16]u8) bool {
	const recvslic = [_]u8{ 'P','A','R',' ','2','.','0',0,'P','k','d','R','e','c','v','S' };
	return std.mem.eql(u8, &t, &recvslic);
}

fn isFileSlicType(t: [16]u8) bool {
	const fileslic = [_]u8{ 'P','A','R',' ','2','.','0',0,'F','i','l','e','S','l','i','c' };
	return std.mem.eql(u8, &t, &fileslic);
}

fn isRfscType(t: [16]u8) bool {
	const rfsc = [_]u8{ 'P','A','R',' ','2','.','0',0,'R','F','S','C',0,0,0,0 };
	return std.mem.eql(u8, &t, &rfsc);
}

fn findRecoveryIndexByName(set: core.recovery_set.RecoverySet, path: []const u8, base: []const u8, rel: ?[]const u8) !usize {
	var exact_match: ?usize = null;
	var i: usize = 0;
	while (i < set.recovery_files.len) : (i += 1) {
		const entry = set.recovery_files[i];
		if (entry.desc == null) continue;
		const name = entry.desc.?.file_name;
		if (std.mem.eql(u8, name, path) or (rel != null and std.mem.eql(u8, name, rel.?))) {
			if (exact_match != null and exact_match.? != i) return error.InvalidInput;
			exact_match = i;
		}
	}
	if (exact_match != null) return exact_match.?;

	var base_match: ?usize = null;
	i = 0;
	while (i < set.recovery_files.len) : (i += 1) {
		const entry = set.recovery_files[i];
		if (entry.desc == null) continue;
		const name = entry.desc.?.file_name;
		if (std.mem.eql(u8, name, base)) {
			if (base_match != null and base_match.? != i) return error.InvalidInput;
			base_match = i;
			continue;
		}
		const entry_base = std.fs.path.basename(name);
		if (std.mem.eql(u8, entry_base, base)) {
			if (base_match != null and base_match.? != i) return error.InvalidInput;
			base_match = i;
		}
	}
	if (base_match == null) return error.NotFound;
	return base_match.?;
}

fn anyMissing(flags: []const bool) bool {
	for (flags) |v| {
		if (v) return true;
	}
	return false;
}

const SliceOverrideStore = struct {
	base: core.storage.FileStore,
	overrides: *std.AutoHashMap(u128, []const u8),

	pub fn readSlice(
		self: SliceOverrideStore,
		allocator: std.mem.Allocator,
		file_index: usize,
		slice_size: usize,
		slice_index: usize,
	) ![]u8 {
		const key = makeSliceKey(file_index, slice_index);
		if (self.overrides.get(key)) |data| {
			var out = try allocator.alloc(u8, slice_size);
			@memset(out, 0);
			const n = @min(slice_size, data.len);
			@memcpy(out[0..n], data[0..n]);
			return out;
		}
		return self.base.readSlice(allocator, file_index, slice_size, slice_index);
	}
};

fn makeSliceKey(file_index: usize, slice_index: usize) u128 {
	return (@as(u128, file_index) << 64) | @as(u128, slice_index);
}

fn computeSliceEntry(slice: []const u8) !core.packet_types.IfscEntry {
	var entry: core.packet_types.IfscEntry = undefined;
	try core.md5.md5Digest(slice, &entry.md5);
	entry.crc32 = core.crc32.crc32(slice);
	return entry;
}

fn writeRecoveredFileSlices(
	scratch: std.mem.Allocator,
	store: anytype,
	order: []const core.layout.SliceRef,
	recovered_for: []const ?usize,
	recovered: [][]u8,
	file_index: usize,
	slice_size: usize,
	writer: anytype,
) !void {
	var oi: usize = 0;
	while (oi < order.len) : (oi += 1) {
		const ref = order[oi];
		if (ref.file_index != file_index) continue;
		const len = ref.length;
		if (recovered_for[oi]) |rec_idx| {
			try writer.writeAll(recovered[rec_idx][0..len]);
			continue;
		}
		const slice = try store.readSlice(scratch, file_index, slice_size, ref.slice_index);
		defer scratch.free(slice);
		try writer.writeAll(slice[0..len]);
	}
}

fn writeRecoveredFileSlicesWithHash(
	scratch: std.mem.Allocator,
	store: anytype,
	order: []const core.layout.SliceRef,
	recovered_for: []const ?usize,
	recovered: [][]u8,
	file_index: usize,
	slice_size: usize,
	writer: anytype,
) ![16]u8 {
	var ctx = core.md5.Md5Ctx.init();
	var oi: usize = 0;
	while (oi < order.len) : (oi += 1) {
		const ref = order[oi];
		if (ref.file_index != file_index) continue;
		const len = ref.length;
		if (recovered_for[oi]) |rec_idx| {
			const data = recovered[rec_idx][0..len];
			ctx.update(data);
			try writer.writeAll(data);
			continue;
		}
		const slice = try store.readSlice(scratch, file_index, slice_size, ref.slice_index);
		defer scratch.free(slice);
		const data = slice[0..len];
		ctx.update(data);
		try writer.writeAll(data);
	}
	var out: [16]u8 = undefined;
	ctx.final(&out);
	return out;
}

fn writeRecoveredFilePath(
	scratch: std.mem.Allocator,
	store: anytype,
	order: []const core.layout.SliceRef,
	recovered_for: []const ?usize,
	recovered: [][]u8,
	file_index: usize,
	slice_size: usize,
	path: []const u8,
) !void {
	if (std.fs.path.dirname(path)) |dir| {
		if (dir.len > 0) {
			try std.fs.cwd().makePath(dir);
		}
	}
	var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
	defer file.close();
	try writeRecoveredFileSlices(scratch, store, order, recovered_for, recovered, file_index, slice_size, file);
}

fn writeRecoveredFilePathWithHash(
	scratch: std.mem.Allocator,
	store: anytype,
	order: []const core.layout.SliceRef,
	recovered_for: []const ?usize,
	recovered: [][]u8,
	file_index: usize,
	slice_size: usize,
	path: []const u8,
) ![16]u8 {
	if (std.fs.path.dirname(path)) |dir| {
		if (dir.len > 0) {
			try std.fs.cwd().makePath(dir);
		}
	}
	var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
	defer file.close();
	return writeRecoveredFileSlicesWithHash(scratch, store, order, recovered_for, recovered, file_index, slice_size, file);
}

fn outputPath(allocator: std.mem.Allocator, out_dir: ?[]const u8, file_name: []const u8, allow_unsafe_paths: bool) ![]const u8 {
	if (!allow_unsafe_paths) {
		if (std.fs.path.isAbsolute(file_name)) return error.InvalidInput;
		if (hasTraversalSegment(file_name)) return error.InvalidInput;
		if (hasWindowsDrivePrefix(file_name)) return error.InvalidInput;
	}
	if (out_dir == null) return file_name;
	return try std.fs.path.join(allocator, &.{ out_dir.?, file_name });
}

fn safeFileName(path: []const u8) ![]const u8 {
	if (hasTraversalSegment(path)) return error.InvalidInput;
	if (hasWindowsDrivePrefix(path)) return error.InvalidInput;
	if (std.fs.path.isAbsolute(path)) {
		return std.fs.path.basename(path);
	}
	return path;
}

fn hasTraversalSegment(path: []const u8) bool {
	if (path.len == 0) return false;
	var start: usize = 0;
	var i: usize = 0;
	while (i <= path.len) : (i += 1) {
		if (i == path.len or path[i] == '/' or path[i] == '\\') {
			const seg = path[start..i];
			if (seg.len == 2 and seg[0] == '.' and seg[1] == '.') return true;
			start = i + 1;
		}
	}
	return false;
}

fn hasWindowsDrivePrefix(path: []const u8) bool {
	if (path.len < 2) return false;
	const c = path[0];
	if (!((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z'))) return false;
	if (path[1] != ':') return false;
	return true;
}

test "outputPath rejects absolute file names" {
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();
	try std.testing.expectError(error.InvalidInput, outputPath(arena.allocator(), "/tmp/out", "/var/tmp/file.bin", false));
}

test "outputPath rejects traversal segments" {
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();
	try std.testing.expectError(error.InvalidInput, outputPath(arena.allocator(), "/tmp/out", "../file.bin", false));
	try std.testing.expectError(error.InvalidInput, outputPath(arena.allocator(), "/tmp/out", "a/../file.bin", false));
}

test "outputPath rejects windows drive prefix" {
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();
	try std.testing.expectError(error.InvalidInput, outputPath(arena.allocator(), "/tmp/out", "C:\\tmp\\file.bin", false));
}

test "outputPath allows unsafe when flag set" {
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();
	const out = try outputPath(arena.allocator(), "/tmp/out", "/var/tmp/file.bin", true);
	try std.testing.expectEqualStrings("/tmp/out/var/tmp/file.bin", out);
}

test "outputPath accepts unicode names" {
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();
	const out = try outputPath(arena.allocator(), "/tmp/out", "café.txt", false);
	try std.testing.expectEqualStrings("/tmp/out/café.txt", out);
}

test "loadPar2File skips packets with invalid hash" {
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	const rec_id: [16]u8 = .{1} ** 16;
	const main_body = try core.create_packets.buildMainBody(arena.allocator(), 4, &.{});
	const pkt = try core.create_packets.buildMainPacket(arena.allocator(), rec_id, main_body);
	var corrupted = try arena.allocator().dupe(u8, pkt);
	corrupted[16] ^= 0xFF;
	var file = try tmp.dir.createFile("bad.par2", .{ .truncate = true });
	defer file.close();
	try file.writeAll(corrupted);
	var ctx = core.api.initContext(arena.allocator());
	var recs = std.ArrayList(core.rs.RecoverySlice).empty;
	defer recs.deinit(arena.allocator());
	var packed_list = std.ArrayList(core.rs.RecoverySlice).empty;
	defer packed_list.deinit(arena.allocator());
	var files = std.ArrayList(core.packet_types.FileSlicPacket).empty;
	defer files.deinit(arena.allocator());
	var rfscs = std.ArrayList(core.packet_types.RfscPacket).empty;
	defer rfscs.deinit(arena.allocator());
	var expected_id: ?[16]u8 = null;
	try loadPar2File(arena.allocator(), &ctx, &recs, &packed_list, &files, &rfscs, try tmp.dir.realpathAlloc(arena.allocator(), "bad.par2"), &expected_id);
	try std.testing.expect(ctx.main == null);
	try std.testing.expect(expected_id == null);
}

test "loadPar2File ignores packets from other recovery set" {
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	const rec_id_other: [16]u8 = .{2} ** 16;
	const main_body = try core.create_packets.buildMainBody(arena.allocator(), 4, &.{});
	const pkt = try core.create_packets.buildMainPacket(arena.allocator(), rec_id_other, main_body);
	var file = try tmp.dir.createFile("other.par2", .{ .truncate = true });
	defer file.close();
	try file.writeAll(pkt);
	var ctx = core.api.initContext(arena.allocator());
	var recs = std.ArrayList(core.rs.RecoverySlice).empty;
	defer recs.deinit(arena.allocator());
	var packed_list = std.ArrayList(core.rs.RecoverySlice).empty;
	defer packed_list.deinit(arena.allocator());
	var files = std.ArrayList(core.packet_types.FileSlicPacket).empty;
	defer files.deinit(arena.allocator());
	var rfscs = std.ArrayList(core.packet_types.RfscPacket).empty;
	defer rfscs.deinit(arena.allocator());
	var expected_id: ?[16]u8 = .{3} ** 16;
	const path = try tmp.dir.realpathAlloc(arena.allocator(), "other.par2");
	try loadPar2File(arena.allocator(), &ctx, &recs, &packed_list, &files, &rfscs, path, &expected_id);
	try std.testing.expect(ctx.main == null);
}
