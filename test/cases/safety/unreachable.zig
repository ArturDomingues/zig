const std = @import("std");

pub fn panic(message: []const u8, stack_trace: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    _ = stack_trace;
    if (std.mem.eql(u8, message, "reached unreachable code")) {
        std.process.exit(0);
    }
    std.process.exit(1);
}
pub fn main() !void {
    unreachable;
}
// run
// backend=stage2,llvm
// target=x86_64-linux,aarch64-linux
