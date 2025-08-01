const builtin = @import("builtin");
const std = @import("../../std.zig");
const maxInt = std.math.maxInt;
const linux = std.os.linux;
const SYS = linux.SYS;
const socklen_t = linux.socklen_t;
const iovec = std.posix.iovec;
const iovec_const = std.posix.iovec_const;
const uid_t = linux.uid_t;
const gid_t = linux.gid_t;
const pid_t = linux.pid_t;
const stack_t = linux.stack_t;
const sigset_t = linux.sigset_t;
const sockaddr = linux.sockaddr;
const timespec = linux.timespec;

pub fn syscall0(number: SYS) usize {
    return asm volatile (
        \\ sc
        \\ bns+ 1f
        \\ neg 3, 3
        \\ 1:
        : [ret] "={r3}" (-> usize),
        : [number] "{r0}" (@intFromEnum(number)),
        : .{ .memory = true, .cr0 = true, .r0 = true, .r4 = true, .r5 = true, .r6 = true, .r7 = true, .r8 = true, .r9 = true, .r10 = true, .r11 = true, .r12 = true });
}

pub fn syscall1(number: SYS, arg1: usize) usize {
    return asm volatile (
        \\ sc
        \\ bns+ 1f
        \\ neg 3, 3
        \\ 1:
        : [ret] "={r3}" (-> usize),
        : [number] "{r0}" (@intFromEnum(number)),
          [arg1] "{r3}" (arg1),
        : .{ .memory = true, .cr0 = true, .r0 = true, .r4 = true, .r5 = true, .r6 = true, .r7 = true, .r8 = true, .r9 = true, .r10 = true, .r11 = true, .r12 = true });
}

pub fn syscall2(number: SYS, arg1: usize, arg2: usize) usize {
    return asm volatile (
        \\ sc
        \\ bns+ 1f
        \\ neg 3, 3
        \\ 1:
        : [ret] "={r3}" (-> usize),
        : [number] "{r0}" (@intFromEnum(number)),
          [arg1] "{r3}" (arg1),
          [arg2] "{r4}" (arg2),
        : .{ .memory = true, .cr0 = true, .r0 = true, .r4 = true, .r5 = true, .r6 = true, .r7 = true, .r8 = true, .r9 = true, .r10 = true, .r11 = true, .r12 = true });
}

pub fn syscall3(number: SYS, arg1: usize, arg2: usize, arg3: usize) usize {
    return asm volatile (
        \\ sc
        \\ bns+ 1f
        \\ neg 3, 3
        \\ 1:
        : [ret] "={r3}" (-> usize),
        : [number] "{r0}" (@intFromEnum(number)),
          [arg1] "{r3}" (arg1),
          [arg2] "{r4}" (arg2),
          [arg3] "{r5}" (arg3),
        : .{ .memory = true, .cr0 = true, .r0 = true, .r4 = true, .r5 = true, .r6 = true, .r7 = true, .r8 = true, .r9 = true, .r10 = true, .r11 = true, .r12 = true });
}

pub fn syscall4(number: SYS, arg1: usize, arg2: usize, arg3: usize, arg4: usize) usize {
    return asm volatile (
        \\ sc
        \\ bns+ 1f
        \\ neg 3, 3
        \\ 1:
        : [ret] "={r3}" (-> usize),
        : [number] "{r0}" (@intFromEnum(number)),
          [arg1] "{r3}" (arg1),
          [arg2] "{r4}" (arg2),
          [arg3] "{r5}" (arg3),
          [arg4] "{r6}" (arg4),
        : .{ .memory = true, .cr0 = true, .r0 = true, .r4 = true, .r5 = true, .r6 = true, .r7 = true, .r8 = true, .r9 = true, .r10 = true, .r11 = true, .r12 = true });
}

pub fn syscall5(number: SYS, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) usize {
    return asm volatile (
        \\ sc
        \\ bns+ 1f
        \\ neg 3, 3
        \\ 1:
        : [ret] "={r3}" (-> usize),
        : [number] "{r0}" (@intFromEnum(number)),
          [arg1] "{r3}" (arg1),
          [arg2] "{r4}" (arg2),
          [arg3] "{r5}" (arg3),
          [arg4] "{r6}" (arg4),
          [arg5] "{r7}" (arg5),
        : .{ .memory = true, .cr0 = true, .r0 = true, .r4 = true, .r5 = true, .r6 = true, .r7 = true, .r8 = true, .r9 = true, .r10 = true, .r11 = true, .r12 = true });
}

pub fn syscall6(
    number: SYS,
    arg1: usize,
    arg2: usize,
    arg3: usize,
    arg4: usize,
    arg5: usize,
    arg6: usize,
) usize {
    return asm volatile (
        \\ sc
        \\ bns+ 1f
        \\ neg 3, 3
        \\ 1:
        : [ret] "={r3}" (-> usize),
        : [number] "{r0}" (@intFromEnum(number)),
          [arg1] "{r3}" (arg1),
          [arg2] "{r4}" (arg2),
          [arg3] "{r5}" (arg3),
          [arg4] "{r6}" (arg4),
          [arg5] "{r7}" (arg5),
          [arg6] "{r8}" (arg6),
        : .{ .memory = true, .cr0 = true, .r0 = true, .r4 = true, .r5 = true, .r6 = true, .r7 = true, .r8 = true, .r9 = true, .r10 = true, .r11 = true, .r12 = true });
}

pub fn clone() callconv(.naked) usize {
    // __clone(func, stack, flags, arg, ptid, tls, ctid)
    //         3,    4,     5,     6,   7,    8,   9
    //
    // syscall(SYS_clone, flags, stack, ptid, tls, ctid)
    //         0          3,     4,     5,    6,   7
    asm volatile (
        \\ # store non-volatile regs r29, r30 on stack in order to put our
        \\ # start func and its arg there
        \\ stwu 29, -16(1)
        \\ stw 30, 4(1)
        \\
        \\ # save r3 (func) into r29, and r6(arg) into r30
        \\ mr 29, 3
        \\ mr 30, 6
        \\
        \\ # create initial stack frame for new thread
        \\ clrrwi 4, 4, 4
        \\ li 0, 0
        \\ stwu 0, -16(4)
        \\
        \\ #move c into first arg
        \\ mr 3, 5
        \\ #mr 4, 4
        \\ mr 5, 7
        \\ mr 6, 8
        \\ mr 7, 9
        \\
        \\ # move syscall number into r0
        \\ li 0, 120 # SYS_clone
        \\
        \\ sc
        \\
        \\ # check for syscall error
        \\ bns+ 1f # jump to label 1 if no summary overflow.
        \\ #else
        \\ neg 3, 3 #negate the result (errno)
        \\ 1:
        \\ # compare sc result with 0
        \\ cmpwi cr7, 3, 0
        \\
        \\ # if not 0, restore stack and return
        \\ beq cr7, 2f
        \\ lwz 29, 0(1)
        \\ lwz 30, 4(1)
        \\ addi 1, 1, 16
        \\ blr
        \\
        \\ #else: we're the child
        \\ 2:
    );
    if (builtin.unwind_tables != .none or !builtin.strip_debug_info) asm volatile (
        \\ .cfi_undefined lr
    );
    asm volatile (
        \\ li 31, 0
        \\ mtlr 0
        \\
        \\ #call funcptr: move arg (d) into r3
        \\ mr 3, 30
        \\ #move r29 (funcptr) into CTR reg
        \\ mtctr 29
        \\ # call CTR reg
        \\ bctrl
        \\ # mov SYS_exit into r0 (the exit param is already in r3)
        \\ li 0, 1
        \\ sc
    );
}

pub const restore = restore_rt;

pub fn restore_rt() callconv(.naked) noreturn {
    asm volatile (
        \\ sc
        :
        : [number] "{r0}" (@intFromEnum(SYS.rt_sigreturn)),
        : .{ .memory = true, .cr0 = true, .r4 = true, .r5 = true, .r6 = true, .r7 = true, .r8 = true, .r9 = true, .r10 = true, .r11 = true, .r12 = true });
}

pub const F = struct {
    pub const DUPFD = 0;
    pub const GETFD = 1;
    pub const SETFD = 2;
    pub const GETFL = 3;
    pub const SETFL = 4;

    pub const SETOWN = 8;
    pub const GETOWN = 9;
    pub const SETSIG = 10;
    pub const GETSIG = 11;

    pub const GETLK = 12;
    pub const SETLK = 13;
    pub const SETLKW = 14;

    pub const SETOWN_EX = 15;
    pub const GETOWN_EX = 16;

    pub const GETOWNER_UIDS = 17;

    pub const RDLCK = 0;
    pub const WRLCK = 1;
    pub const UNLCK = 2;
};

pub const VDSO = struct {
    pub const CGT_SYM = "__kernel_clock_gettime";
    pub const CGT_VER = "LINUX_2.6.15";
};

pub const Flock = extern struct {
    type: i16,
    whence: i16,
    start: off_t,
    len: off_t,
    pid: pid_t,
};

pub const blksize_t = i32;
pub const nlink_t = u32;
pub const time_t = isize;
pub const mode_t = u32;
pub const off_t = i64;
pub const ino_t = u64;
pub const dev_t = u64;
pub const blkcnt_t = i64;

// The `stat` definition used by the Linux kernel.
pub const Stat = extern struct {
    dev: dev_t,
    ino: ino_t,
    mode: mode_t,
    nlink: nlink_t,
    uid: uid_t,
    gid: gid_t,
    rdev: dev_t,
    __rdev_padding: i16,
    size: off_t,
    blksize: blksize_t,
    blocks: blkcnt_t,
    atim: timespec,
    mtim: timespec,
    ctim: timespec,
    __unused: [2]u32,

    pub fn atime(self: @This()) timespec {
        return self.atim;
    }

    pub fn mtime(self: @This()) timespec {
        return self.mtim;
    }

    pub fn ctime(self: @This()) timespec {
        return self.ctim;
    }
};

pub const timeval = extern struct {
    sec: time_t,
    usec: isize,
};

pub const timezone = extern struct {
    minuteswest: i32,
    dsttime: i32,
};

pub const greg_t = u32;
pub const gregset_t = [48]greg_t;
pub const fpregset_t = [33]f64;

pub const vrregset = extern struct {
    vrregs: [32][4]u32,
    vrsave: u32,
    _pad: [2]u32,
    vscr: u32,
};
pub const vrregset_t = vrregset;

pub const mcontext_t = extern struct {
    gp_regs: gregset_t,
    fp_regs: fpregset_t,
    v_regs: vrregset_t align(16),
};

pub const ucontext_t = extern struct {
    flags: u32,
    link: ?*ucontext_t,
    stack: stack_t,
    pad: [7]i32,
    regs: *mcontext_t,
    sigmask: [1024 / @bitSizeOf(c_ulong)]c_ulong, // Currently a libc-compatible (1024-bit) sigmask
    pad2: [3]i32,
    mcontext: mcontext_t,
};

pub const Elf_Symndx = u32;

/// TODO
pub const getcontext = {};
