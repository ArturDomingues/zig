const builtin = @import("builtin");
const std = @import("../../std.zig");
const linux = std.os.linux;
const SYS = linux.SYS;
const iovec = std.posix.iovec;
const iovec_const = std.posix.iovec_const;
const uid_t = linux.uid_t;
const gid_t = linux.gid_t;
const stack_t = linux.stack_t;
const sigset_t = linux.sigset_t;
const sockaddr = linux.sockaddr;
const socklen_t = linux.socklen_t;
const timespec = linux.timespec;

pub fn syscall0(number: SYS) usize {
    return asm volatile (
        \\ syscall 0
        : [ret] "={$r4}" (-> usize),
        : [number] "{$r11}" (@intFromEnum(number)),
        : .{ .r12 = true, .r13 = true, .r14 = true, .r15 = true, .r16 = true, .r17 = true, .r18 = true, .r19 = true, .r20 = true, .memory = true });
}

pub fn syscall1(number: SYS, arg1: usize) usize {
    return asm volatile (
        \\ syscall 0
        : [ret] "={$r4}" (-> usize),
        : [number] "{$r11}" (@intFromEnum(number)),
          [arg1] "{$r4}" (arg1),
        : .{ .r12 = true, .r13 = true, .r14 = true, .r15 = true, .r16 = true, .r17 = true, .r18 = true, .r19 = true, .r20 = true, .memory = true });
}

pub fn syscall2(number: SYS, arg1: usize, arg2: usize) usize {
    return asm volatile (
        \\ syscall 0
        : [ret] "={$r4}" (-> usize),
        : [number] "{$r11}" (@intFromEnum(number)),
          [arg1] "{$r4}" (arg1),
          [arg2] "{$r5}" (arg2),
        : .{ .r12 = true, .r13 = true, .r14 = true, .r15 = true, .r16 = true, .r17 = true, .r18 = true, .r19 = true, .r20 = true, .memory = true });
}

pub fn syscall3(number: SYS, arg1: usize, arg2: usize, arg3: usize) usize {
    return asm volatile (
        \\ syscall 0
        : [ret] "={$r4}" (-> usize),
        : [number] "{$r11}" (@intFromEnum(number)),
          [arg1] "{$r4}" (arg1),
          [arg2] "{$r5}" (arg2),
          [arg3] "{$r6}" (arg3),
        : .{ .r12 = true, .r13 = true, .r14 = true, .r15 = true, .r16 = true, .r17 = true, .r18 = true, .r19 = true, .r20 = true, .memory = true });
}

pub fn syscall4(number: SYS, arg1: usize, arg2: usize, arg3: usize, arg4: usize) usize {
    return asm volatile (
        \\ syscall 0
        : [ret] "={$r4}" (-> usize),
        : [number] "{$r11}" (@intFromEnum(number)),
          [arg1] "{$r4}" (arg1),
          [arg2] "{$r5}" (arg2),
          [arg3] "{$r6}" (arg3),
          [arg4] "{$r7}" (arg4),
        : .{ .r12 = true, .r13 = true, .r14 = true, .r15 = true, .r16 = true, .r17 = true, .r18 = true, .r19 = true, .r20 = true, .memory = true });
}

pub fn syscall5(number: SYS, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) usize {
    return asm volatile (
        \\ syscall 0
        : [ret] "={$r4}" (-> usize),
        : [number] "{$r11}" (@intFromEnum(number)),
          [arg1] "{$r4}" (arg1),
          [arg2] "{$r5}" (arg2),
          [arg3] "{$r6}" (arg3),
          [arg4] "{$r7}" (arg4),
          [arg5] "{$r8}" (arg5),
        : .{ .r12 = true, .r13 = true, .r14 = true, .r15 = true, .r16 = true, .r17 = true, .r18 = true, .r19 = true, .r20 = true, .memory = true });
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
        \\ syscall 0
        : [ret] "={$r4}" (-> usize),
        : [number] "{$r11}" (@intFromEnum(number)),
          [arg1] "{$r4}" (arg1),
          [arg2] "{$r5}" (arg2),
          [arg3] "{$r6}" (arg3),
          [arg4] "{$r7}" (arg4),
          [arg5] "{$r8}" (arg5),
          [arg6] "{$r9}" (arg6),
        : .{ .r12 = true, .r13 = true, .r14 = true, .r15 = true, .r16 = true, .r17 = true, .r18 = true, .r19 = true, .r20 = true, .memory = true });
}

pub fn clone() callconv(.naked) usize {
    // __clone(func, stack, flags, arg, ptid, tls, ctid)
    //           a0,    a1,    a2,  a3,   a4,  a5,   a6
    // sys_clone(flags, stack, ptid, ctid, tls)
    //              a0,    a1,   a2,   a3,  a4
    asm volatile (
        \\ bstrins.d $a1, $zero, 3, 0   # stack to 16 align
        \\
        \\ # Save function pointer and argument pointer on new thread stack
        \\ addi.d  $a1, $a1, -16
        \\ st.d    $a0, $a1, 0     # save function pointer
        \\ st.d    $a3, $a1, 8     # save argument pointer
        \\ or      $a0, $a2, $zero
        \\ or      $a2, $a4, $zero
        \\ or      $a3, $a6, $zero
        \\ or      $a4, $a5, $zero
        \\ ori     $a7, $zero, 220 # SYS_clone
        \\ syscall 0               # call clone
        \\
        \\ beqz    $a0, 1f         # whether child process
        \\ jirl    $zero, $ra, 0   # parent process return
        \\1:
    );
    if (builtin.unwind_tables != .none or !builtin.strip_debug_info) asm volatile (
        \\ .cfi_undefined 1
    );
    asm volatile (
        \\ move    $fp, $zero
        \\ move    $ra, $zero
        \\
        \\ ld.d    $t8, $sp, 0     # function pointer
        \\ ld.d    $a0, $sp, 8     # argument pointer
        \\ jirl    $ra, $t8, 0     # call the user's function
        \\ ori     $a7, $zero, 93  # SYS_exit
        \\ syscall 0               # child process exit
    );
}

pub const restore = restore_rt;

pub fn restore_rt() callconv(.naked) noreturn {
    asm volatile (
        \\ or $a7, $zero, %[number]
        \\ syscall 0
        :
        : [number] "r" (@intFromEnum(SYS.rt_sigreturn)),
        : .{ .r12 = true, .r13 = true, .r14 = true, .r15 = true, .r16 = true, .r17 = true, .r18 = true, .r19 = true, .r20 = true, .memory = true });
}

pub const msghdr = extern struct {
    name: ?*sockaddr,
    namelen: socklen_t,
    iov: [*]iovec,
    iovlen: i32,
    __pad1: i32 = 0,
    control: ?*anyopaque,
    controllen: socklen_t,
    __pad2: socklen_t = 0,
    flags: i32,
};

pub const msghdr_const = extern struct {
    name: ?*const sockaddr,
    namelen: socklen_t,
    iov: [*]const iovec_const,
    iovlen: i32,
    __pad1: i32 = 0,
    control: ?*const anyopaque,
    controllen: socklen_t,
    __pad2: socklen_t = 0,
    flags: i32,
};

pub const blksize_t = i32;
pub const nlink_t = u32;
pub const time_t = i64;
pub const mode_t = u32;
pub const off_t = i64;
pub const ino_t = u64;
pub const dev_t = u32;
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
    _pad1: u64,
    size: off_t,
    blksize: blksize_t,
    _pad2: i32,
    blocks: blkcnt_t,
    atim: timespec,
    mtim: timespec,
    ctim: timespec,
    _pad3: [2]u32,

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
    tv_sec: time_t,
    tv_usec: i64,
};

pub const F = struct {
    pub const DUPFD = 0;
    pub const GETFD = 1;
    pub const SETFD = 2;
    pub const GETFL = 3;
    pub const SETFL = 4;
    pub const GETLK = 5;
    pub const SETLK = 6;
    pub const SETLKW = 7;
    pub const SETOWN = 8;
    pub const GETOWN = 9;
    pub const SETSIG = 10;
    pub const GETSIG = 11;

    pub const RDLCK = 0;
    pub const WRLCK = 1;
    pub const UNLCK = 2;

    pub const SETOWN_EX = 15;
    pub const GETOWN_EX = 16;

    pub const GETOWNER_UIDS = 17;
};

pub const VDSO = struct {
    pub const CGT_SYM = "__vdso_clock_gettime";
    pub const CGT_VER = "LINUX_5.10";
};

pub const mcontext_t = extern struct {
    pc: u64,
    regs: [32]u64,
    flags: u32,
    extcontext: [0]u64 align(16),
};

pub const ucontext_t = extern struct {
    flags: c_ulong,
    link: ?*ucontext_t,
    stack: stack_t,
    sigmask: [1024 / @bitSizeOf(c_ulong)]c_ulong, // Currently a libc-compatible (1024-bit) sigmask
    mcontext: mcontext_t,
};

pub const Elf_Symndx = u32;

/// TODO
pub const getcontext = {};
