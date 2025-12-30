const common = @import("ops/common.zig");
const create_mod = @import("ops/create.zig");
const verify_mod = @import("ops/verify.zig");
const recover_mod = @import("ops/recover.zig");

pub const CreateOptions = common.CreateOptions;
pub const RecoverOptions = common.RecoverOptions;
pub const VerifyOptions = common.VerifyOptions;
pub const OutputTarget = common.OutputTarget;
pub const OutputOpener = common.OutputOpener;
pub const StreamInput = common.StreamInput;

pub fn stdoutToStderrEnabled() bool {
    return common.stdoutToStderrEnabled();
}

pub const create = create_mod.create;
pub const createStreams = create_mod.createStreams;
pub const verify = verify_mod.verify;
pub const verifyStreams = verify_mod.verifyStreams;
pub const recover = recover_mod.recover;
pub const recoverStreams = recover_mod.recoverStreams;
