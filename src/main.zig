const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const io = std.io;
const fs = std.fs;
const mem = std.mem;
const process = std.process;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const Ast = std.zig.Ast;
const Color = std.zig.Color;
const warn = std.log.warn;
const ThreadPool = std.Thread.Pool;
const cleanExit = std.process.cleanExit;
const native_os = builtin.os.tag;
const Cache = std.Build.Cache;
const Path = std.Build.Cache.Path;
const Directory = std.Build.Cache.Directory;
const EnvVar = std.zig.EnvVar;
const LibCInstallation = std.zig.LibCInstallation;
const AstGen = std.zig.AstGen;
const ZonGen = std.zig.ZonGen;
const Server = std.zig.Server;

const tracy = @import("tracy.zig");
const Compilation = @import("Compilation.zig");
const link = @import("link.zig");
const Package = @import("Package.zig");
const build_options = @import("build_options");
const introspect = @import("introspect.zig");
const wasi_libc = @import("libs/wasi_libc.zig");
const target_util = @import("target.zig");
const crash_report = @import("crash_report.zig");
const Zcu = @import("Zcu.zig");
const mingw = @import("libs/mingw.zig");
const dev = @import("dev.zig");

test {
    _ = Package;
    _ = @import("codegen.zig");
}

const thread_stack_size = 60 << 20;

pub const std_options: std.Options = .{
    .wasiCwd = wasi_cwd,
    .logFn = log,
    .enable_segfault_handler = false,

    .log_level = switch (builtin.mode) {
        .Debug => .debug,
        .ReleaseSafe, .ReleaseFast => .info,
        .ReleaseSmall => .err,
    },
};

pub const panic = crash_report.panic;

var wasi_preopens: fs.wasi.Preopens = undefined;
pub fn wasi_cwd() std.os.wasi.fd_t {
    // Expect the first preopen to be current working directory.
    const cwd_fd: std.posix.fd_t = 3;
    assert(mem.eql(u8, wasi_preopens.names[cwd_fd], "."));
    return cwd_fd;
}

const fatal = std.process.fatal;

/// This can be global since stdin is a singleton.
var stdin_buffer: [4096]u8 align(std.heap.page_size_min) = undefined;
/// This can be global since stdout is a singleton.
var stdout_buffer: [4096]u8 align(std.heap.page_size_min) = undefined;

/// Shaming all the locations that inappropriately use an O(N) search algorithm.
/// Please delete this and fix the compilation errors!
pub const @"bad O(N)" = void;

const normal_usage =
    \\Usage: zig [command] [options]
    \\
    \\Commands:
    \\
    \\  build            Build project from build.zig
    \\  fetch            Copy a package into global cache and print its hash
    \\  init             Initialize a Zig package in the current directory
    \\
    \\  build-exe        Create executable from source or object files
    \\  build-lib        Create library from source or object files
    \\  build-obj        Create object from source or object files
    \\  test             Perform unit testing
    \\  run              Create executable and run immediately
    \\
    \\  ast-check        Look for simple compile errors in any set of files
    \\  fmt              Reformat Zig source into canonical form
    \\  reduce           Minimize a bug report
    \\  translate-c      Convert C code to Zig code
    \\
    \\  ar               Use Zig as a drop-in archiver
    \\  cc               Use Zig as a drop-in C compiler
    \\  c++              Use Zig as a drop-in C++ compiler
    \\  dlltool          Use Zig as a drop-in dlltool.exe
    \\  lib              Use Zig as a drop-in lib.exe
    \\  ranlib           Use Zig as a drop-in ranlib
    \\  objcopy          Use Zig as a drop-in objcopy
    \\  rc               Use Zig as a drop-in rc.exe
    \\
    \\  env              Print lib path, std path, cache directory, and version
    \\  help             Print this help and exit
    \\  std              View standard library documentation in a browser
    \\  libc             Display native libc paths file or validate one
    \\  targets          List available compilation targets
    \\  version          Print version number and exit
    \\  zen              Print Zen of Zig and exit
    \\
    \\General Options:
    \\
    \\  -h, --help       Print command-specific usage
    \\
;

const debug_usage = normal_usage ++
    \\
    \\Debug Commands:
    \\
    \\  changelist       Compute mappings from old ZIR to new ZIR
    \\  dump-zir         Dump a file containing cached ZIR
    \\  detect-cpu       Compare Zig's CPU feature detection vs LLVM
    \\  llvm-ints        Dump a list of LLVMABIAlignmentOfType for all integers
    \\
;

const usage = if (build_options.enable_debug_extensions) debug_usage else normal_usage;

var log_scopes: std.ArrayListUnmanaged([]const u8) = .empty;

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    // Hide debug messages unless:
    // * logging enabled with `-Dlog`.
    // * the --debug-log arg for the scope has been provided
    if (@intFromEnum(level) > @intFromEnum(std.options.log_level) or
        @intFromEnum(level) > @intFromEnum(std.log.Level.info))
    {
        if (!build_options.enable_logging) return;

        const scope_name = @tagName(scope);
        for (log_scopes.items) |log_scope| {
            if (mem.eql(u8, log_scope, scope_name))
                break;
        } else return;
    }

    const prefix1 = comptime level.asText();
    const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";

    // Print the message to stderr, silently ignoring any errors
    std.debug.print(prefix1 ++ prefix2 ++ format ++ "\n", args);
}

var debug_allocator: std.heap.DebugAllocator(.{
    .stack_trace_frames = build_options.mem_leak_frames,
}) = .init;

pub fn main() anyerror!void {
    crash_report.initialize();

    const gpa, const is_debug = gpa: {
        if (build_options.debug_gpa) break :gpa .{ debug_allocator.allocator(), true };
        if (native_os == .wasi) break :gpa .{ std.heap.wasm_allocator, false };
        if (builtin.link_libc) {
            // We would prefer to use raw libc allocator here, but cannot use
            // it if it won't support the alignment we need.
            if (@alignOf(std.c.max_align_t) < @max(@alignOf(i128), std.atomic.cache_line)) {
                break :gpa .{ std.heap.c_allocator, false };
            }
            break :gpa .{ std.heap.raw_c_allocator, false };
        }
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };
    var arena_instance = std.heap.ArenaAllocator.init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const args = try process.argsAlloc(arena);

    if (tracy.enable_allocation) {
        var gpa_tracy = tracy.tracyAllocator(gpa);
        return mainArgs(gpa_tracy.allocator(), arena, args);
    }

    if (native_os == .wasi) {
        wasi_preopens = try fs.wasi.preopensAlloc(arena);
    }

    return mainArgs(gpa, arena, args);
}

/// Check that LLVM and Clang have been linked properly so that they are using the same
/// libc++ and can safely share objects with pointers to static variables in libc++
fn verifyLibcxxCorrectlyLinked() void {
    if (build_options.have_llvm and ZigClangIsLLVMUsingSeparateLibcxx()) {
        fatal(
            \\Zig was built/linked incorrectly: LLVM and Clang have separate copies of libc++
            \\       If you are dynamically linking LLVM, make sure you dynamically link libc++ too
        , .{});
    }
}

fn mainArgs(gpa: Allocator, arena: Allocator, args: []const []const u8) !void {
    const tr = tracy.trace(@src());
    defer tr.end();

    if (args.len <= 1) {
        std.log.info("{s}", .{usage});
        fatal("expected command argument", .{});
    }

    if (process.can_execv and std.posix.getenvZ("ZIG_IS_DETECTING_LIBC_PATHS") != null) {
        dev.check(.cc_command);
        // In this case we have accidentally invoked ourselves as "the system C compiler"
        // to figure out where libc is installed. This is essentially infinite recursion
        // via child process execution due to the CC environment variable pointing to Zig.
        // Here we ignore the CC environment variable and exec `cc` as a child process.
        // However it's possible Zig is installed as *that* C compiler as well, which is
        // why we have this additional environment variable here to check.
        var env_map = try process.getEnvMap(arena);

        const inf_loop_env_key = "ZIG_IS_TRYING_TO_NOT_CALL_ITSELF";
        if (env_map.get(inf_loop_env_key) != null) {
            fatal("The compilation links against libc, but Zig is unable to provide a libc " ++
                "for this operating system, and no --libc " ++
                "parameter was provided, so Zig attempted to invoke the system C compiler " ++
                "in order to determine where libc is installed. However the system C " ++
                "compiler is `zig cc`, so no libc installation was found.", .{});
        }
        try env_map.put(inf_loop_env_key, "1");

        // Some programs such as CMake will strip the `cc` and subsequent args from the
        // CC environment variable. We detect and support this scenario here because of
        // the ZIG_IS_DETECTING_LIBC_PATHS environment variable.
        if (mem.eql(u8, args[1], "cc")) {
            return process.execve(arena, args[1..], &env_map);
        } else {
            const modified_args = try arena.dupe([]const u8, args);
            modified_args[0] = "cc";
            return process.execve(arena, modified_args, &env_map);
        }
    }

    const cmd = args[1];
    const cmd_args = args[2..];
    if (mem.eql(u8, cmd, "build-exe")) {
        dev.check(.build_exe_command);
        return buildOutputType(gpa, arena, args, .{ .build = .Exe });
    } else if (mem.eql(u8, cmd, "build-lib")) {
        dev.check(.build_lib_command);
        return buildOutputType(gpa, arena, args, .{ .build = .Lib });
    } else if (mem.eql(u8, cmd, "build-obj")) {
        dev.check(.build_obj_command);
        return buildOutputType(gpa, arena, args, .{ .build = .Obj });
    } else if (mem.eql(u8, cmd, "test")) {
        dev.check(.test_command);
        return buildOutputType(gpa, arena, args, .zig_test);
    } else if (mem.eql(u8, cmd, "test-obj")) {
        dev.check(.test_command);
        return buildOutputType(gpa, arena, args, .zig_test_obj);
    } else if (mem.eql(u8, cmd, "run")) {
        dev.check(.run_command);
        return buildOutputType(gpa, arena, args, .run);
    } else if (mem.eql(u8, cmd, "dlltool") or
        mem.eql(u8, cmd, "ranlib") or
        mem.eql(u8, cmd, "lib") or
        mem.eql(u8, cmd, "ar"))
    {
        dev.check(.ar_command);
        return process.exit(try llvmArMain(arena, args));
    } else if (mem.eql(u8, cmd, "build")) {
        dev.check(.build_command);
        return cmdBuild(gpa, arena, cmd_args);
    } else if (mem.eql(u8, cmd, "clang") or
        mem.eql(u8, cmd, "-cc1") or mem.eql(u8, cmd, "-cc1as"))
    {
        dev.check(.clang_command);
        return process.exit(try clangMain(arena, args));
    } else if (mem.eql(u8, cmd, "ld.lld") or
        mem.eql(u8, cmd, "lld-link") or
        mem.eql(u8, cmd, "wasm-ld"))
    {
        dev.check(.lld_linker);
        return process.exit(try lldMain(arena, args, true));
    } else if (mem.eql(u8, cmd, "cc")) {
        dev.check(.cc_command);
        return buildOutputType(gpa, arena, args, .cc);
    } else if (mem.eql(u8, cmd, "c++")) {
        dev.check(.cc_command);
        return buildOutputType(gpa, arena, args, .cpp);
    } else if (mem.eql(u8, cmd, "translate-c")) {
        dev.check(.translate_c_command);
        return buildOutputType(gpa, arena, args, .translate_c);
    } else if (mem.eql(u8, cmd, "rc")) {
        const use_server = cmd_args.len > 0 and std.mem.eql(u8, cmd_args[0], "--zig-integration");
        return jitCmd(gpa, arena, cmd_args, .{
            .cmd_name = "resinator",
            .root_src_path = "resinator/main.zig",
            .windows_libs = &.{"advapi32"},
            .depend_on_aro = true,
            .prepend_zig_lib_dir_path = true,
            .server = use_server,
        });
    } else if (mem.eql(u8, cmd, "fmt")) {
        dev.check(.fmt_command);
        return @import("fmt.zig").run(gpa, arena, cmd_args);
    } else if (mem.eql(u8, cmd, "objcopy")) {
        return jitCmd(gpa, arena, cmd_args, .{
            .cmd_name = "objcopy",
            .root_src_path = "objcopy.zig",
        });
    } else if (mem.eql(u8, cmd, "fetch")) {
        return cmdFetch(gpa, arena, cmd_args);
    } else if (mem.eql(u8, cmd, "libc")) {
        return jitCmd(gpa, arena, cmd_args, .{
            .cmd_name = "libc",
            .root_src_path = "libc.zig",
            .prepend_zig_lib_dir_path = true,
        });
    } else if (mem.eql(u8, cmd, "std")) {
        return jitCmd(gpa, arena, cmd_args, .{
            .cmd_name = "std",
            .root_src_path = "std-docs.zig",
            .windows_libs = &.{"ws2_32"},
            .prepend_zig_lib_dir_path = true,
            .prepend_zig_exe_path = true,
            .prepend_global_cache_path = true,
        });
    } else if (mem.eql(u8, cmd, "init")) {
        return cmdInit(gpa, arena, cmd_args);
    } else if (mem.eql(u8, cmd, "targets")) {
        dev.check(.targets_command);
        const host = std.zig.resolveTargetQueryOrFatal(.{});
        var stdout_writer = fs.File.stdout().writer(&stdout_buffer);
        try @import("print_targets.zig").cmdTargets(arena, cmd_args, &stdout_writer.interface, &host);
        return stdout_writer.interface.flush();
    } else if (mem.eql(u8, cmd, "version")) {
        dev.check(.version_command);
        try fs.File.stdout().writeAll(build_options.version ++ "\n");
        // Check libc++ linkage to make sure Zig was built correctly, but only
        // for "env" and "version" to avoid affecting the startup time for
        // build-critical commands (check takes about ~10 μs)
        return verifyLibcxxCorrectlyLinked();
    } else if (mem.eql(u8, cmd, "env")) {
        dev.check(.env_command);
        verifyLibcxxCorrectlyLinked();
        var stdout_writer = fs.File.stdout().writer(&stdout_buffer);
        try @import("print_env.zig").cmdEnv(
            arena,
            &stdout_writer.interface,
            args,
            if (native_os == .wasi) wasi_preopens,
        );
        return stdout_writer.interface.flush();
    } else if (mem.eql(u8, cmd, "reduce")) {
        return jitCmd(gpa, arena, cmd_args, .{
            .cmd_name = "reduce",
            .root_src_path = "reduce.zig",
        });
    } else if (mem.eql(u8, cmd, "zen")) {
        dev.check(.zen_command);
        return fs.File.stdout().writeAll(info_zen);
    } else if (mem.eql(u8, cmd, "help") or mem.eql(u8, cmd, "-h") or mem.eql(u8, cmd, "--help")) {
        dev.check(.help_command);
        return fs.File.stdout().writeAll(usage);
    } else if (mem.eql(u8, cmd, "ast-check")) {
        return cmdAstCheck(arena, cmd_args);
    } else if (mem.eql(u8, cmd, "detect-cpu")) {
        return cmdDetectCpu(cmd_args);
    } else if (build_options.enable_debug_extensions and mem.eql(u8, cmd, "changelist")) {
        return cmdChangelist(arena, cmd_args);
    } else if (build_options.enable_debug_extensions and mem.eql(u8, cmd, "dump-zir")) {
        return cmdDumpZir(arena, cmd_args);
    } else if (build_options.enable_debug_extensions and mem.eql(u8, cmd, "llvm-ints")) {
        return cmdDumpLlvmInts(gpa, arena, cmd_args);
    } else {
        std.log.info("{s}", .{usage});
        fatal("unknown command: {s}", .{args[1]});
    }
}

const usage_build_generic =
    \\Usage: zig build-exe   [options] [files]
    \\       zig build-lib   [options] [files]
    \\       zig build-obj   [options] [files]
    \\       zig test        [options] [files]
    \\       zig run         [options] [files] [-- [args]]
    \\       zig translate-c [options] [file]
    \\
    \\Supported file types:
    \\                         .zig    Zig source code
    \\                           .o    ELF object file
    \\                           .o    Mach-O (macOS) object file
    \\                           .o    WebAssembly object file
    \\                         .obj    COFF (Windows) object file
    \\                         .lib    COFF (Windows) static library
    \\                           .a    ELF static library
    \\                           .a    Mach-O (macOS) static library
    \\                           .a    WebAssembly static library
    \\                          .so    ELF shared object (dynamic link)
    \\                         .dll    Windows Dynamic Link Library
    \\                       .dylib    Mach-O (macOS) dynamic library
    \\                         .tbd    (macOS) text-based dylib definition
    \\                           .s    Target-specific assembly source code
    \\                           .S    Assembly with C preprocessor (requires LLVM extensions)
    \\                           .c    C source code (requires LLVM extensions)
    \\        .cxx .cc .C .cpp .c++    C++ source code (requires LLVM extensions)
    \\                           .m    Objective-C source code (requires LLVM extensions)
    \\                          .mm    Objective-C++ source code (requires LLVM extensions)
    \\                          .bc    LLVM IR Module (requires LLVM extensions)
    \\
    \\General Options:
    \\  -h, --help                Print this help and exit
    \\  --color [auto|off|on]     Enable or disable colored error messages
    \\  -j<N>                     Limit concurrent jobs (default is to use all CPU cores)
    \\  -fincremental             Enable incremental compilation
    \\  -fno-incremental          Disable incremental compilation
    \\  -femit-bin[=path]         (default) Output machine code
    \\  -fno-emit-bin             Do not output machine code
    \\  -femit-asm[=path]         Output .s (assembly code)
    \\  -fno-emit-asm             (default) Do not output .s (assembly code)
    \\  -femit-llvm-ir[=path]     Produce a .ll file with optimized LLVM IR (requires LLVM extensions)
    \\  -fno-emit-llvm-ir         (default) Do not produce a .ll file with optimized LLVM IR
    \\  -femit-llvm-bc[=path]     Produce an optimized LLVM module as a .bc file (requires LLVM extensions)
    \\  -fno-emit-llvm-bc         (default) Do not produce an optimized LLVM module as a .bc file
    \\  -femit-h[=path]           Generate a C header file (.h)
    \\  -fno-emit-h               (default) Do not generate a C header file (.h)
    \\  -femit-docs[=path]        Create a docs/ dir with html documentation
    \\  -fno-emit-docs            (default) Do not produce docs/ dir with html documentation
    \\  -femit-implib[=path]      (default) Produce an import .lib when building a Windows DLL
    \\  -fno-emit-implib          Do not produce an import .lib when building a Windows DLL
    \\  --show-builtin            Output the source of @import("builtin") then exit
    \\  --cache-dir [path]        Override the local cache directory
    \\  --global-cache-dir [path] Override the global cache directory
    \\  --zig-lib-dir [path]      Override path to Zig installation lib directory
    \\
    \\Global Compile Options:
    \\  --name [name]             Compilation unit name (not a file path)
    \\  --libc [file]             Provide a file which specifies libc paths
    \\  -x language               Treat subsequent input files as having type <language>
    \\  --dep [[import=]name]     Add an entry to the next module's import table
    \\  -M[name][=src]            Create a module based on the current per-module settings.
    \\                            The first module is the main module.
    \\                            "std" can be configured by omitting src
    \\                            After a -M argument, per-module settings are reset.
    \\  --error-limit [num]       Set the maximum amount of distinct error values
    \\  -fllvm                    Force using LLVM as the codegen backend
    \\  -fno-llvm                 Prevent using LLVM as the codegen backend
    \\  -flibllvm                 Force using the LLVM API in the codegen backend
    \\  -fno-libllvm              Prevent using the LLVM API in the codegen backend
    \\  -fclang                   Force using Clang as the C/C++ compilation backend
    \\  -fno-clang                Prevent using Clang as the C/C++ compilation backend
    \\  -fPIE                     Force-enable Position Independent Executable
    \\  -fno-PIE                  Force-disable Position Independent Executable
    \\  -flto                     Force-enable Link Time Optimization (requires LLVM extensions)
    \\  -fno-lto                  Force-disable Link Time Optimization
    \\  -fdll-export-fns          Mark exported functions as DLL exports (Windows)
    \\  -fno-dll-export-fns       Force-disable marking exported functions as DLL exports
    \\  -freference-trace[=num]   Show num lines of reference trace per compile error
    \\  -fno-reference-trace      Disable reference trace
    \\  -ffunction-sections       Places each function in a separate section
    \\  -fno-function-sections    All functions go into same section
    \\  -fdata-sections           Places each data in a separate section
    \\  -fno-data-sections        All data go into same section
    \\  -fformatted-panics        Enable formatted safety panics
    \\  -fno-formatted-panics     Disable formatted safety panics
    \\  -fstructured-cfg          (SPIR-V) force SPIR-V kernels to use structured control flow
    \\  -fno-structured-cfg       (SPIR-V) force SPIR-V kernels to not use structured control flow
    \\  -mexec-model=[value]      (WASI) Execution model
    \\  -municode                 (Windows) Use wmain/wWinMain as entry point
    \\  --time-report             Send timing diagnostics to '--listen' clients
    \\
    \\Per-Module Compile Options:
    \\  -target [name]            <arch><sub>-<os>-<abi> see the targets command
    \\  -O [mode]                 Choose what to optimize for
    \\    Debug                   (default) Optimizations off, safety on
    \\    ReleaseFast             Optimize for performance, safety off
    \\    ReleaseSafe             Optimize for performance, safety on
    \\    ReleaseSmall            Optimize for small binary, safety off
    \\  -ofmt=[fmt]               Override target object format
    \\    elf                     Executable and Linking Format
    \\    c                       C source code
    \\    wasm                    WebAssembly
    \\    coff                    Common Object File Format (Windows)
    \\    macho                   macOS relocatables
    \\    spirv                   Standard, Portable Intermediate Representation V (SPIR-V)
    \\    plan9                   Plan 9 from Bell Labs object format
    \\    hex  (planned feature)  Intel IHEX
    \\    raw  (planned feature)  Dump machine code directly
    \\  -mcpu [cpu]               Specify target CPU and feature set
    \\  -mcmodel=[model]          Limit range of code and data virtual addresses
    \\    default
    \\    extreme
    \\    kernel
    \\    large
    \\    medany
    \\    medium
    \\    medlow
    \\    medmid
    \\    normal
    \\    small
    \\    tiny
    \\  -mred-zone                Force-enable the "red-zone"
    \\  -mno-red-zone             Force-disable the "red-zone"
    \\  -fomit-frame-pointer      Omit the stack frame pointer
    \\  -fno-omit-frame-pointer   Store the stack frame pointer
    \\  -fPIC                     Force-enable Position Independent Code
    \\  -fno-PIC                  Force-disable Position Independent Code
    \\  -fstack-check             Enable stack probing in unsafe builds
    \\  -fno-stack-check          Disable stack probing in safe builds
    \\  -fstack-protector         Enable stack protection in unsafe builds
    \\  -fno-stack-protector      Disable stack protection in safe builds
    \\  -fvalgrind                Include valgrind client requests in release builds
    \\  -fno-valgrind             Omit valgrind client requests in debug builds
    \\  -fsanitize-c[=mode]       Enable C undefined behavior detection in unsafe builds
    \\    trap                    Insert trap instructions on undefined behavior
    \\    full                    (Default) Insert runtime calls on undefined behavior
    \\  -fno-sanitize-c           Disable C undefined behavior detection in safe builds
    \\  -fsanitize-thread         Enable Thread Sanitizer
    \\  -fno-sanitize-thread      Disable Thread Sanitizer
    \\  -ffuzz                    Enable fuzz testing instrumentation
    \\  -fno-fuzz                 Disable fuzz testing instrumentation
    \\  -fbuiltin                 Enable implicit builtin knowledge of functions
    \\  -fno-builtin              Disable implicit builtin knowledge of functions
    \\  -funwind-tables           Always produce unwind table entries for all functions
    \\  -fasync-unwind-tables     Always produce asynchronous unwind table entries for all functions
    \\  -fno-unwind-tables        Never produce unwind table entries
    \\  -ferror-tracing           Enable error tracing in ReleaseFast mode
    \\  -fno-error-tracing        Disable error tracing in Debug and ReleaseSafe mode
    \\  -fsingle-threaded         Code assumes there is only one thread
    \\  -fno-single-threaded      Code may not assume there is only one thread
    \\  -fstrip                   Omit debug symbols
    \\  -fno-strip                Keep debug symbols
    \\  -idirafter [dir]          Add directory to AFTER include search path
    \\  -isystem  [dir]           Add directory to SYSTEM include search path
    \\  -I[dir]                   Add directory to include search path
    \\  --embed-dir=[dir]         Add directory to embed search path
    \\  -D[macro]=[value]         Define C [macro] to [value] (1 if [value] omitted)
    \\  -cflags [flags] --        Set extra flags for the next positional C source files
    \\  -rcflags [flags] --       Set extra flags for the next positional .rc source files
    \\  -rcincludes=[type]        Set the type of includes to use when compiling .rc source files
    \\    any                     (default) Use msvc if available, fall back to gnu
    \\    msvc                    Use msvc include paths (must be present on the system)
    \\    gnu                     Use mingw include paths (distributed with Zig)
    \\    none                    Do not use any autodetected include paths
    \\
    \\Global Link Options:
    \\  -T[script], --script [script]  Use a custom linker script
    \\  --version-script [path]        Provide a version .map file
    \\  --undefined-version            Allow version scripts to refer to undefined symbols
    \\  --no-undefined-version         (default) Disallow version scripts from referring to undefined symbols
    \\  --enable-new-dtags             Use the new behavior for dynamic tags (RUNPATH)
    \\  --disable-new-dtags            Use the old behavior for dynamic tags (RPATH)
    \\  --dynamic-linker [path]        Set the dynamic interpreter path (usually ld.so)
    \\  --sysroot [path]               Set the system root directory (usually /)
    \\  --version [ver]                Dynamic library semver
    \\  -fentry                        Enable entry point with default symbol name
    \\  -fentry=[name]                 Override the entry point symbol name
    \\  -fno-entry                     Do not output any entry point
    \\  --force_undefined [name]       Specify the symbol must be defined for the link to succeed
    \\  -fsoname[=name]                Override the default SONAME value
    \\  -fno-soname                    Disable emitting a SONAME
    \\  -flld                          Force using LLD as the linker
    \\  -fno-lld                       Prevent using LLD as the linker
    \\  -fcompiler-rt                  Always include compiler-rt symbols in output
    \\  -fno-compiler-rt               Prevent including compiler-rt symbols in output
    \\  -fubsan-rt                     Always include ubsan-rt symbols in the output
    \\  -fno-ubsan-rt                  Prevent including ubsan-rt symbols in the output
    \\  -rdynamic                      Add all symbols to the dynamic symbol table
    \\  -feach-lib-rpath               Ensure adding rpath for each used dynamic library
    \\  -fno-each-lib-rpath            Prevent adding rpath for each used dynamic library
    \\  -fallow-shlib-undefined        Allows undefined symbols in shared libraries
    \\  -fno-allow-shlib-undefined     Disallows undefined symbols in shared libraries
    \\  -fallow-so-scripts             Allows .so files to be GNU ld scripts
    \\  -fno-allow-so-scripts          (default) .so files must be ELF files
    \\  --build-id[=style]             At a minor link-time expense, embeds a build ID in binaries
    \\      fast                       8-byte non-cryptographic hash (COFF, ELF, WASM)
    \\      sha1, tree                 20-byte cryptographic hash (ELF, WASM)
    \\      md5                        16-byte cryptographic hash (ELF)
    \\      uuid                       16-byte random UUID (ELF, WASM)
    \\      0x[hexstring]              Constant ID, maximum 32 bytes (ELF, WASM)
    \\      none                     (default) No build ID
    \\  --eh-frame-hdr                 Enable C++ exception handling by passing --eh-frame-hdr to linker
    \\  --no-eh-frame-hdr              Disable C++ exception handling by passing --no-eh-frame-hdr to linker
    \\  --emit-relocs                  Enable output of relocation sections for post build tools
    \\  -z [arg]                       Set linker extension flags
    \\    nodelete                     Indicate that the object cannot be deleted from a process
    \\    notext                       Permit read-only relocations in read-only segments
    \\    defs                         Force a fatal error if any undefined symbols remain
    \\    undefs                       Reverse of -z defs
    \\    origin                       Indicate that the object must have its origin processed
    \\    nocopyreloc                  Disable the creation of copy relocations
    \\    now                          (default) Force all relocations to be processed on load
    \\    lazy                         Don't force all relocations to be processed on load
    \\    relro                        (default) Force all relocations to be read-only after processing
    \\    norelro                      Don't force all relocations to be read-only after processing
    \\    common-page-size=[bytes]     Set the common page size for ELF binaries
    \\    max-page-size=[bytes]        Set the max page size for ELF binaries
    \\  -dynamic                       Force output to be dynamically linked
    \\  -static                        Force output to be statically linked
    \\  -Bsymbolic                     Bind global references locally
    \\  --compress-debug-sections=[e]  Debug section compression settings
    \\      none                       No compression
    \\      zlib                       Compression with deflate/inflate
    \\      zstd                       Compression with zstandard
    \\  --gc-sections                  Force removal of functions and data that are unreachable by the entry point or exported symbols
    \\  --no-gc-sections               Don't force removal of unreachable functions and data
    \\  --sort-section=[value]         Sort wildcard section patterns by 'name' or 'alignment'
    \\  --subsystem [subsystem]        (Windows) /SUBSYSTEM:<subsystem> to the linker
    \\  --stack [size]                 Override default stack size
    \\  --image-base [addr]            Set base address for executable image
    \\  -install_name=[value]          (Darwin) add dylib's install name
    \\  --entitlements [path]          (Darwin) add path to entitlements file for embedding in code signature
    \\  -pagezero_size [value]         (Darwin) size of the __PAGEZERO segment in hexadecimal notation
    \\  -headerpad [value]             (Darwin) set minimum space for future expansion of the load commands in hexadecimal notation
    \\  -headerpad_max_install_names   (Darwin) set enough space as if all paths were MAXPATHLEN
    \\  -dead_strip                    (Darwin) remove functions and data that are unreachable by the entry point or exported symbols
    \\  -dead_strip_dylibs             (Darwin) remove dylibs that are unreachable by the entry point or exported symbols
    \\  -ObjC                          (Darwin) force load all members of static archives that implement an Objective-C class or category
    \\  --import-memory                (WebAssembly) import memory from the environment
    \\  --export-memory                (WebAssembly) export memory to the host (Default unless --import-memory used)
    \\  --import-symbols               (WebAssembly) import missing symbols from the host environment
    \\  --import-table                 (WebAssembly) import function table from the host environment
    \\  --export-table                 (WebAssembly) export function table to the host environment
    \\  --initial-memory=[bytes]       (WebAssembly) initial size of the linear memory
    \\  --max-memory=[bytes]           (WebAssembly) maximum size of the linear memory
    \\  --shared-memory                (WebAssembly) use shared linear memory
    \\  --global-base=[addr]           (WebAssembly) where to start to place global data
    \\
    \\Per-Module Link Options:
    \\  -l[lib], --library [lib]       Link against system library (only if actually used)
    \\  -needed-l[lib],                Link against system library (even if unused)
    \\    --needed-library [lib]
    \\  -weak-l[lib]                   link against system library marking it and all
    \\    -weak_library [lib]          referenced symbols as weak
    \\  -L[d], --library-directory [d] Add a directory to the library search path
    \\  -search_paths_first            For each library search path, check for dynamic
    \\                                 lib then static lib before proceeding to next path.
    \\  -search_paths_first_static     For each library search path, check for static
    \\                                 lib then dynamic lib before proceeding to next path.
    \\  -search_dylibs_first           Search for dynamic libs in all library search
    \\                                 paths, then static libs.
    \\  -search_static_first           Search for static libs in all library search
    \\                                 paths, then dynamic libs.
    \\  -search_dylibs_only            Only search for dynamic libs.
    \\  -search_static_only            Only search for static libs.
    \\  -rpath [path]                  Add directory to the runtime library search path
    \\  -framework [name]              (Darwin) link against framework
    \\  -needed_framework [name]       (Darwin) link against framework (even if unused)
    \\  -needed_library [lib]          (Darwin) link against system library (even if unused)
    \\  -weak_framework [name]         (Darwin) link against framework and mark it and all referenced symbols as weak
    \\  -F[dir]                        (Darwin) add search path for frameworks
    \\  --export=[value]               (WebAssembly) Force a symbol to be exported
    \\
    \\Test Options:
    \\  --test-filter [text]           Skip tests that do not match any filter
    \\  --test-name-prefix [text]      Add prefix to all tests
    \\  --test-cmd [arg]               Specify test execution command one arg at a time
    \\  --test-cmd-bin                 Appends test binary path to test cmd args
    \\  --test-evented-io              Runs the test in evented I/O mode
    \\  --test-no-exec                 Compiles test binary without running it
    \\  --test-runner [path]           Specify a custom test runner
    \\
    \\Debug Options (Zig Compiler Development):
    \\  -fopt-bisect-limit=[limit]   Only run [limit] first LLVM optimization passes
    \\  -fstack-report               Print stack size diagnostics
    \\  --verbose-link               Display linker invocations
    \\  --verbose-cc                 Display C compiler invocations
    \\  --verbose-air                Enable compiler debug output for Zig AIR
    \\  --verbose-intern-pool        Enable compiler debug output for InternPool
    \\  --verbose-generic-instances  Enable compiler debug output for generic instance generation
    \\  --verbose-llvm-ir[=path]     Enable compiler debug output for unoptimized LLVM IR
    \\  --verbose-llvm-bc=[path]     Enable compiler debug output for unoptimized LLVM BC
    \\  --verbose-cimport            Enable compiler debug output for C imports
    \\  --verbose-llvm-cpu-features  Enable compiler debug output for LLVM CPU features
    \\  --debug-log [scope]          Enable printing debug/info log messages for scope
    \\  --debug-compile-errors       Crash with helpful diagnostics at the first compile error
    \\  --debug-link-snapshot        Enable dumping of the linker's state in JSON format
    \\  --debug-rt                   Debug compiler runtime libraries
    \\  --debug-incremental          Enable incremental compilation debug features
    \\
;

const SOName = union(enum) {
    no,
    yes_default_value,
    yes: []const u8,
};

const EmitBin = union(enum) {
    no,
    yes_default_path,
    yes: []const u8,
    yes_a_out,
};

const Emit = union(enum) {
    no,
    yes_default_path,
    yes: []const u8,

    const OutputToCacheReason = enum { listen, @"zig run", @"zig test" };
    fn resolve(emit: Emit, default_basename: []const u8, output_to_cache: ?OutputToCacheReason) Compilation.CreateOptions.Emit {
        return switch (emit) {
            .no => .no,
            .yes_default_path => if (output_to_cache != null) .yes_cache else .{ .yes_path = default_basename },
            .yes => |path| if (output_to_cache) |reason| {
                switch (reason) {
                    .listen => fatal("--listen incompatible with explicit output path '{s}'", .{path}),
                    .@"zig run", .@"zig test" => fatal(
                        "'{s}' with explicit output path '{s}' requires explicit '-femit-bin=path' or '-fno-emit-bin'",
                        .{ @tagName(reason), path },
                    ),
                }
            } else e: {
                // If there's a dirname, check that dir exists. This will give a more descriptive error than `Compilation` otherwise would.
                if (fs.path.dirname(path)) |dir_path| {
                    var dir = fs.cwd().openDir(dir_path, .{}) catch |err| {
                        fatal("unable to open output directory '{s}': {s}", .{ dir_path, @errorName(err) });
                    };
                    dir.close();
                }
                break :e .{ .yes_path = path };
            },
        };
    }
};

const ArgMode = union(enum) {
    build: std.builtin.OutputMode,
    cc,
    cpp,
    translate_c,
    zig_test,
    zig_test_obj,
    run,
};

const Listen = union(enum) {
    none,
    stdio: if (dev.env.supports(.stdio_listen)) void else noreturn,
    ip4: if (dev.env.supports(.network_listen)) std.net.Ip4Address else noreturn,
};

const ArgsIterator = struct {
    resp_file: ?ArgIteratorResponseFile = null,
    args: []const []const u8,
    i: usize = 0,
    fn next(it: *@This()) ?[]const u8 {
        if (it.i >= it.args.len) {
            if (it.resp_file) |*resp| return resp.next();
            return null;
        }
        defer it.i += 1;
        return it.args[it.i];
    }
    fn nextOrFatal(it: *@This()) []const u8 {
        if (it.i >= it.args.len) {
            if (it.resp_file) |*resp| if (resp.next()) |ret| return ret;
            fatal("expected parameter after {s}", .{it.args[it.i - 1]});
        }
        defer it.i += 1;
        return it.args[it.i];
    }
};

/// Similar to `link.Framework` except it doesn't store yet unresolved
/// path to the framework.
const Framework = struct {
    needed: bool = false,
    weak: bool = false,
};

const CliModule = struct {
    root_path: []const u8,
    root_src_path: []const u8,
    cc_argv: []const []const u8,
    inherited: Package.Module.CreateOptions.Inherited,
    target_arch_os_abi: ?[]const u8,
    target_mcpu: ?[]const u8,

    deps: []const Dep,
    resolved: ?*Package.Module,

    c_source_files_start: usize,
    c_source_files_end: usize,
    rc_source_files_start: usize,
    rc_source_files_end: usize,

    const Dep = struct {
        key: []const u8,
        value: []const u8,
    };
};

fn buildOutputType(
    gpa: Allocator,
    arena: Allocator,
    all_args: []const []const u8,
    arg_mode: ArgMode,
) !void {
    var provided_name: ?[]const u8 = null;
    var root_src_file: ?[]const u8 = null;
    var version: std.SemanticVersion = .{ .major = 0, .minor = 0, .patch = 0 };
    var have_version = false;
    var compatibility_version: ?std.SemanticVersion = null;
    var function_sections = false;
    var data_sections = false;
    var listen: Listen = .none;
    var debug_compile_errors = false;
    var debug_incremental = false;
    var verbose_link = (native_os != .wasi or builtin.link_libc) and
        EnvVar.ZIG_VERBOSE_LINK.isSet();
    var verbose_cc = (native_os != .wasi or builtin.link_libc) and
        EnvVar.ZIG_VERBOSE_CC.isSet();
    var verbose_air = false;
    var verbose_intern_pool = false;
    var verbose_generic_instances = false;
    var verbose_llvm_ir: ?[]const u8 = null;
    var verbose_llvm_bc: ?[]const u8 = null;
    var verbose_cimport = false;
    var verbose_llvm_cpu_features = false;
    var time_report = false;
    var stack_report = false;
    var show_builtin = false;
    var emit_bin: EmitBin = .yes_default_path;
    var emit_asm: Emit = .no;
    var emit_llvm_ir: Emit = .no;
    var emit_llvm_bc: Emit = .no;
    var emit_docs: Emit = .no;
    var emit_implib: Emit = .yes_default_path;
    var emit_implib_arg_provided = false;
    var target_arch_os_abi: ?[]const u8 = null;
    var target_mcpu: ?[]const u8 = null;
    var emit_h: Emit = .no;
    var soname: SOName = undefined;
    var want_compiler_rt: ?bool = null;
    var want_ubsan_rt: ?bool = null;
    var linker_script: ?[]const u8 = null;
    var version_script: ?[]const u8 = null;
    var linker_repro: ?bool = null;
    var linker_allow_undefined_version: bool = false;
    var linker_enable_new_dtags: ?bool = null;
    var disable_c_depfile = false;
    var linker_sort_section: ?link.File.Lld.Elf.SortSection = null;
    var linker_gc_sections: ?bool = null;
    var linker_compress_debug_sections: ?link.File.Lld.Elf.CompressDebugSections = null;
    var linker_allow_shlib_undefined: ?bool = null;
    var allow_so_scripts: bool = false;
    var linker_bind_global_refs_locally: ?bool = null;
    var linker_import_symbols: bool = false;
    var linker_import_table: bool = false;
    var linker_export_table: bool = false;
    var linker_initial_memory: ?u64 = null;
    var linker_max_memory: ?u64 = null;
    var linker_global_base: ?u64 = null;
    var linker_print_gc_sections: bool = false;
    var linker_print_icf_sections: bool = false;
    var linker_print_map: bool = false;
    var llvm_opt_bisect_limit: c_int = -1;
    var linker_z_nocopyreloc = false;
    var linker_z_nodelete = false;
    var linker_z_notext = false;
    var linker_z_defs = false;
    var linker_z_origin = false;
    var linker_z_now = true;
    var linker_z_relro = true;
    var linker_z_common_page_size: ?u64 = null;
    var linker_z_max_page_size: ?u64 = null;
    var linker_tsaware = false;
    var linker_nxcompat = false;
    var linker_dynamicbase = true;
    var linker_optimization: ?[]const u8 = null;
    var linker_module_definition_file: ?[]const u8 = null;
    var test_no_exec = false;
    var entry: Compilation.CreateOptions.Entry = .default;
    var force_undefined_symbols: std.StringArrayHashMapUnmanaged(void) = .empty;
    var stack_size: ?u64 = null;
    var image_base: ?u64 = null;
    var link_eh_frame_hdr = false;
    var link_emit_relocs = false;
    var build_id: ?std.zig.BuildId = null;
    var runtime_args_start: ?usize = null;
    var test_filters: std.ArrayListUnmanaged([]const u8) = .empty;
    var test_name_prefix: ?[]const u8 = null;
    var test_runner_path: ?[]const u8 = null;
    var override_local_cache_dir: ?[]const u8 = try EnvVar.ZIG_LOCAL_CACHE_DIR.get(arena);
    var override_global_cache_dir: ?[]const u8 = try EnvVar.ZIG_GLOBAL_CACHE_DIR.get(arena);
    var override_lib_dir: ?[]const u8 = try EnvVar.ZIG_LIB_DIR.get(arena);
    var clang_preprocessor_mode: Compilation.ClangPreprocessorMode = .no;
    var subsystem: ?std.Target.SubSystem = null;
    var major_subsystem_version: ?u16 = null;
    var minor_subsystem_version: ?u16 = null;
    var mingw_unicode_entry_point: bool = false;
    var enable_link_snapshots: bool = false;
    var debug_compiler_runtime_libs = false;
    var opt_incremental: ?bool = null;
    var install_name: ?[]const u8 = null;
    var hash_style: link.File.Lld.Elf.HashStyle = .both;
    var entitlements: ?[]const u8 = null;
    var pagezero_size: ?u64 = null;
    var lib_search_strategy: link.UnresolvedInput.SearchStrategy = .paths_first;
    var lib_preferred_mode: std.builtin.LinkMode = .dynamic;
    var headerpad_size: ?u32 = null;
    var headerpad_max_install_names: bool = false;
    var dead_strip_dylibs: bool = false;
    var force_load_objc: bool = false;
    var discard_local_symbols: bool = false;
    var contains_res_file: bool = false;
    var reference_trace: ?u32 = null;
    var pdb_out_path: ?[]const u8 = null;
    var error_limit: ?Zcu.ErrorInt = null;
    // These are before resolving sysroot.
    var extra_cflags: std.ArrayListUnmanaged([]const u8) = .empty;
    var extra_rcflags: std.ArrayListUnmanaged([]const u8) = .empty;
    var symbol_wrap_set: std.StringArrayHashMapUnmanaged(void) = .empty;
    var rc_includes: Compilation.RcIncludes = .any;
    var manifest_file: ?[]const u8 = null;
    var linker_export_symbol_names: std.ArrayListUnmanaged([]const u8) = .empty;

    // Tracks the position in c_source_files which have already their owner populated.
    var c_source_files_owner_index: usize = 0;
    // Tracks the position in rc_source_files which have already their owner populated.
    var rc_source_files_owner_index: usize = 0;

    // null means replace with the test executable binary
    var test_exec_args: std.ArrayListUnmanaged(?[]const u8) = .empty;

    // These get set by CLI flags and then snapshotted when a `-M` flag is
    // encountered.
    var mod_opts: Package.Module.CreateOptions.Inherited = .{};

    // These get appended to by CLI flags and then slurped when a `-M` flag
    // is encountered.
    var cssan: ClangSearchSanitizer = .{};
    var cc_argv: std.ArrayListUnmanaged([]const u8) = .empty;
    var deps: std.ArrayListUnmanaged(CliModule.Dep) = .empty;

    // Contains every module specified via -M. The dependencies are added
    // after argument parsing is completed. We use a StringArrayHashMap to make
    // error output consistent. "root" is special.
    var create_module: CreateModule = .{
        // Populated just before the call to `createModule`.
        .dirs = undefined,
        .object_format = null,
        .dynamic_linker = null,
        .modules = .{},
        .opts = .{
            .is_test = switch (arg_mode) {
                .zig_test, .zig_test_obj => true,
                .build, .cc, .cpp, .translate_c, .run => false,
            },
            // Populated while parsing CLI args.
            .output_mode = undefined,
            // Populated in the call to `createModule` for the root module.
            .resolved_target = undefined,
            .have_zcu = false,
            // Populated just before the call to `createModule`.
            .emit_llvm_ir = undefined,
            // Populated just before the call to `createModule`.
            .emit_llvm_bc = undefined,
            // Populated just before the call to `createModule`.
            .emit_bin = undefined,
            // Populated just before the call to `createModule`.
            .any_c_source_files = undefined,
        },
        // Populated in the call to `createModule` for the root module.
        .resolved_options = undefined,

        .cli_link_inputs = .empty,
        .windows_libs = .empty,
        .link_inputs = .empty,

        .c_source_files = .{},
        .rc_source_files = .{},

        .llvm_m_args = .{},
        .sysroot = null,
        .lib_directories = .{}, // populated by createModule()
        .lib_dir_args = .{}, // populated from CLI arg parsing
        .libc_installation = null,
        .want_native_include_dirs = false,
        .frameworks = .{},
        .framework_dirs = .{},
        .rpath_list = .{},
        .each_lib_rpath = null,
        .libc_paths_file = try EnvVar.ZIG_LIBC.get(arena),
        .native_system_include_paths = &.{},
    };
    defer create_module.link_inputs.deinit(gpa);

    // before arg parsing, check for the NO_COLOR and CLICOLOR_FORCE environment variables
    // if set, default the color setting to .off or .on, respectively
    // explicit --color arguments will still override this setting.
    // Disable color on WASI per https://github.com/WebAssembly/WASI/issues/162
    var color: Color = if (native_os == .wasi or EnvVar.NO_COLOR.isSet())
        .off
    else if (EnvVar.CLICOLOR_FORCE.isSet())
        .on
    else
        .auto;
    var n_jobs: ?u32 = null;

    switch (arg_mode) {
        .build, .translate_c, .zig_test, .zig_test_obj, .run => {
            switch (arg_mode) {
                .build => |m| {
                    create_module.opts.output_mode = m;
                },
                .translate_c => {
                    emit_bin = .no;
                    create_module.opts.output_mode = .Obj;
                },
                .zig_test, .run => {
                    create_module.opts.output_mode = .Exe;
                },
                .zig_test_obj => {
                    create_module.opts.output_mode = .Obj;
                },
                else => unreachable,
            }

            soname = .yes_default_value;

            var args_iter = ArgsIterator{
                .args = all_args[2..],
            };

            var file_ext: ?Compilation.FileExt = null;
            args_loop: while (args_iter.next()) |arg| {
                if (mem.startsWith(u8, arg, "@")) {
                    // This is a "compiler response file". We must parse the file and treat its
                    // contents as command line parameters.
                    const resp_file_path = arg[1..];
                    args_iter.resp_file = initArgIteratorResponseFile(arena, resp_file_path) catch |err| {
                        fatal("unable to read response file '{s}': {s}", .{ resp_file_path, @errorName(err) });
                    };
                } else if (mem.startsWith(u8, arg, "-")) {
                    if (mem.eql(u8, arg, "-h") or mem.eql(u8, arg, "--help")) {
                        try fs.File.stdout().writeAll(usage_build_generic);
                        return cleanExit();
                    } else if (mem.eql(u8, arg, "--")) {
                        if (arg_mode == .run) {
                            // args_iter.i is 1, referring the next arg after "--" in ["--", ...]
                            // Add +2 to the index so it is relative to all_args
                            runtime_args_start = args_iter.i + 2;
                            break :args_loop;
                        } else {
                            fatal("unexpected end-of-parameter mark: --", .{});
                        }
                    } else if (mem.eql(u8, arg, "--dep")) {
                        var it = mem.splitScalar(u8, args_iter.nextOrFatal(), '=');
                        const key = it.next().?;
                        const value = it.next() orelse key;
                        if (mem.eql(u8, key, "std") and !mem.eql(u8, value, "std")) {
                            fatal("unable to import as '{s}': conflicts with builtin module", .{
                                key,
                            });
                        }
                        for ([_][]const u8{ "root", "builtin" }) |name| {
                            if (mem.eql(u8, key, name)) {
                                fatal("unable to import as '{s}': conflicts with builtin module", .{
                                    key,
                                });
                            }
                        }
                        try deps.append(arena, .{
                            .key = key,
                            .value = value,
                        });
                    } else if (mem.startsWith(u8, arg, "-M")) {
                        var it = mem.splitScalar(u8, arg["-M".len..], '=');
                        const mod_name = it.next().?;
                        const root_src_orig = it.next();
                        try handleModArg(
                            arena,
                            mod_name,
                            root_src_orig,
                            &create_module,
                            &mod_opts,
                            &cc_argv,
                            &target_arch_os_abi,
                            &target_mcpu,
                            &deps,
                            &c_source_files_owner_index,
                            &rc_source_files_owner_index,
                            &cssan,
                        );
                    } else if (mem.eql(u8, arg, "--error-limit")) {
                        const next_arg = args_iter.nextOrFatal();
                        error_limit = std.fmt.parseUnsigned(Zcu.ErrorInt, next_arg, 0) catch |err| {
                            fatal("unable to parse error limit '{s}': {s}", .{ next_arg, @errorName(err) });
                        };
                    } else if (mem.eql(u8, arg, "-cflags")) {
                        extra_cflags.shrinkRetainingCapacity(0);
                        while (true) {
                            const next_arg = args_iter.next() orelse {
                                fatal("expected -- after -cflags", .{});
                            };
                            if (mem.eql(u8, next_arg, "--")) break;
                            try extra_cflags.append(arena, next_arg);
                        }
                    } else if (mem.eql(u8, arg, "-rcincludes")) {
                        rc_includes = parseRcIncludes(args_iter.nextOrFatal());
                    } else if (mem.startsWith(u8, arg, "-rcincludes=")) {
                        rc_includes = parseRcIncludes(arg["-rcincludes=".len..]);
                    } else if (mem.eql(u8, arg, "-rcflags")) {
                        extra_rcflags.shrinkRetainingCapacity(0);
                        while (true) {
                            const next_arg = args_iter.next() orelse {
                                fatal("expected -- after -rcflags", .{});
                            };
                            if (mem.eql(u8, next_arg, "--")) break;
                            try extra_rcflags.append(arena, next_arg);
                        }
                    } else if (mem.startsWith(u8, arg, "-fstructured-cfg")) {
                        mod_opts.structured_cfg = true;
                    } else if (mem.startsWith(u8, arg, "-fno-structured-cfg")) {
                        mod_opts.structured_cfg = false;
                    } else if (mem.eql(u8, arg, "--color")) {
                        const next_arg = args_iter.next() orelse {
                            fatal("expected [auto|on|off] after --color", .{});
                        };
                        color = std.meta.stringToEnum(Color, next_arg) orelse {
                            fatal("expected [auto|on|off] after --color, found '{s}'", .{next_arg});
                        };
                    } else if (mem.startsWith(u8, arg, "-j")) {
                        const str = arg["-j".len..];
                        const num = std.fmt.parseUnsigned(u32, str, 10) catch |err| {
                            fatal("unable to parse jobs count '{s}': {s}", .{
                                str, @errorName(err),
                            });
                        };
                        if (num < 1) {
                            fatal("number of jobs must be at least 1\n", .{});
                        }
                        n_jobs = num;
                    } else if (mem.eql(u8, arg, "--subsystem")) {
                        subsystem = try parseSubSystem(args_iter.nextOrFatal());
                    } else if (mem.eql(u8, arg, "-O")) {
                        mod_opts.optimize_mode = parseOptimizeMode(args_iter.nextOrFatal());
                    } else if (mem.startsWith(u8, arg, "-fentry=")) {
                        entry = .{ .named = arg["-fentry=".len..] };
                    } else if (mem.eql(u8, arg, "--force_undefined")) {
                        try force_undefined_symbols.put(arena, args_iter.nextOrFatal(), {});
                    } else if (mem.eql(u8, arg, "--discard-all")) {
                        discard_local_symbols = true;
                    } else if (mem.eql(u8, arg, "--stack")) {
                        stack_size = parseStackSize(args_iter.nextOrFatal());
                    } else if (mem.eql(u8, arg, "--image-base")) {
                        image_base = parseImageBase(args_iter.nextOrFatal());
                    } else if (mem.eql(u8, arg, "--name")) {
                        provided_name = args_iter.nextOrFatal();
                        if (!mem.eql(u8, provided_name.?, fs.path.basename(provided_name.?)))
                            fatal("invalid package name '{s}': cannot contain folder separators", .{provided_name.?});
                    } else if (mem.eql(u8, arg, "-rpath")) {
                        try create_module.rpath_list.append(arena, args_iter.nextOrFatal());
                    } else if (mem.eql(u8, arg, "--library-directory") or mem.eql(u8, arg, "-L")) {
                        try create_module.lib_dir_args.append(arena, args_iter.nextOrFatal());
                    } else if (mem.eql(u8, arg, "-F")) {
                        try create_module.framework_dirs.append(arena, args_iter.nextOrFatal());
                    } else if (mem.eql(u8, arg, "-framework")) {
                        try create_module.frameworks.put(arena, args_iter.nextOrFatal(), .{});
                    } else if (mem.eql(u8, arg, "-weak_framework")) {
                        try create_module.frameworks.put(arena, args_iter.nextOrFatal(), .{ .weak = true });
                    } else if (mem.eql(u8, arg, "-needed_framework")) {
                        try create_module.frameworks.put(arena, args_iter.nextOrFatal(), .{ .needed = true });
                    } else if (mem.eql(u8, arg, "-install_name")) {
                        install_name = args_iter.nextOrFatal();
                    } else if (mem.startsWith(u8, arg, "--compress-debug-sections=")) {
                        const param = arg["--compress-debug-sections=".len..];
                        linker_compress_debug_sections = std.meta.stringToEnum(link.File.Lld.Elf.CompressDebugSections, param) orelse {
                            fatal("expected --compress-debug-sections=[none|zlib|zstd], found '{s}'", .{param});
                        };
                    } else if (mem.eql(u8, arg, "--compress-debug-sections")) {
                        linker_compress_debug_sections = link.File.Lld.Elf.CompressDebugSections.zlib;
                    } else if (mem.eql(u8, arg, "-pagezero_size")) {
                        const next_arg = args_iter.nextOrFatal();
                        pagezero_size = std.fmt.parseUnsigned(u64, eatIntPrefix(next_arg, 16), 16) catch |err| {
                            fatal("unable to parse pagezero size'{s}': {s}", .{ next_arg, @errorName(err) });
                        };
                    } else if (mem.eql(u8, arg, "-search_paths_first")) {
                        lib_search_strategy = .paths_first;
                        lib_preferred_mode = .dynamic;
                    } else if (mem.eql(u8, arg, "-search_paths_first_static")) {
                        lib_search_strategy = .paths_first;
                        lib_preferred_mode = .static;
                    } else if (mem.eql(u8, arg, "-search_dylibs_first")) {
                        lib_search_strategy = .mode_first;
                        lib_preferred_mode = .dynamic;
                    } else if (mem.eql(u8, arg, "-search_static_first")) {
                        lib_search_strategy = .mode_first;
                        lib_preferred_mode = .static;
                    } else if (mem.eql(u8, arg, "-search_dylibs_only")) {
                        lib_search_strategy = .no_fallback;
                        lib_preferred_mode = .dynamic;
                    } else if (mem.eql(u8, arg, "-search_static_only")) {
                        lib_search_strategy = .no_fallback;
                        lib_preferred_mode = .static;
                    } else if (mem.eql(u8, arg, "-headerpad")) {
                        const next_arg = args_iter.nextOrFatal();
                        headerpad_size = std.fmt.parseUnsigned(u32, eatIntPrefix(next_arg, 16), 16) catch |err| {
                            fatal("unable to parse headerpad size '{s}': {s}", .{ next_arg, @errorName(err) });
                        };
                    } else if (mem.eql(u8, arg, "-headerpad_max_install_names")) {
                        headerpad_max_install_names = true;
                    } else if (mem.eql(u8, arg, "-dead_strip")) {
                        linker_gc_sections = true;
                    } else if (mem.eql(u8, arg, "-dead_strip_dylibs")) {
                        dead_strip_dylibs = true;
                    } else if (mem.eql(u8, arg, "-ObjC")) {
                        force_load_objc = true;
                    } else if (mem.eql(u8, arg, "-T") or mem.eql(u8, arg, "--script")) {
                        linker_script = args_iter.nextOrFatal();
                    } else if (mem.eql(u8, arg, "-version-script") or mem.eql(u8, arg, "--version-script")) {
                        version_script = args_iter.nextOrFatal();
                    } else if (mem.eql(u8, arg, "--undefined-version")) {
                        linker_allow_undefined_version = true;
                    } else if (mem.eql(u8, arg, "--no-undefined-version")) {
                        linker_allow_undefined_version = false;
                    } else if (mem.eql(u8, arg, "--enable-new-dtags")) {
                        linker_enable_new_dtags = true;
                    } else if (mem.eql(u8, arg, "--disable-new-dtags")) {
                        linker_enable_new_dtags = false;
                    } else if (mem.eql(u8, arg, "--library") or mem.eql(u8, arg, "-l")) {
                        // We don't know whether this library is part of libc
                        // or libc++ until we resolve the target, so we append
                        // to the list for now.
                        try create_module.cli_link_inputs.append(arena, .{ .name_query = .{
                            .name = args_iter.nextOrFatal(),
                            .query = .{
                                .needed = false,
                                .weak = false,
                                .preferred_mode = lib_preferred_mode,
                                .search_strategy = lib_search_strategy,
                                .allow_so_scripts = allow_so_scripts,
                            },
                        } });
                    } else if (mem.eql(u8, arg, "--needed-library") or
                        mem.eql(u8, arg, "-needed-l") or
                        mem.eql(u8, arg, "-needed_library"))
                    {
                        const next_arg = args_iter.nextOrFatal();
                        try create_module.cli_link_inputs.append(arena, .{ .name_query = .{
                            .name = next_arg,
                            .query = .{
                                .needed = true,
                                .weak = false,
                                .preferred_mode = lib_preferred_mode,
                                .search_strategy = lib_search_strategy,
                                .allow_so_scripts = allow_so_scripts,
                            },
                        } });
                    } else if (mem.eql(u8, arg, "-weak_library") or mem.eql(u8, arg, "-weak-l")) {
                        try create_module.cli_link_inputs.append(arena, .{ .name_query = .{
                            .name = args_iter.nextOrFatal(),
                            .query = .{
                                .needed = false,
                                .weak = true,
                                .preferred_mode = lib_preferred_mode,
                                .search_strategy = lib_search_strategy,
                                .allow_so_scripts = allow_so_scripts,
                            },
                        } });
                    } else if (mem.eql(u8, arg, "-D")) {
                        try cc_argv.appendSlice(arena, &.{ arg, args_iter.nextOrFatal() });
                    } else if (mem.eql(u8, arg, "-I")) {
                        try cssan.addIncludePath(arena, &cc_argv, .I, arg, args_iter.nextOrFatal(), false);
                    } else if (mem.startsWith(u8, arg, "--embed-dir=")) {
                        try cssan.addIncludePath(arena, &cc_argv, .embed_dir, arg, arg["--embed-dir=".len..], true);
                    } else if (mem.eql(u8, arg, "-isystem")) {
                        try cssan.addIncludePath(arena, &cc_argv, .isystem, arg, args_iter.nextOrFatal(), false);
                    } else if (mem.eql(u8, arg, "-iwithsysroot")) {
                        try cssan.addIncludePath(arena, &cc_argv, .iwithsysroot, arg, args_iter.nextOrFatal(), false);
                    } else if (mem.eql(u8, arg, "-idirafter")) {
                        try cssan.addIncludePath(arena, &cc_argv, .idirafter, arg, args_iter.nextOrFatal(), false);
                    } else if (mem.eql(u8, arg, "-iframework")) {
                        const path = args_iter.nextOrFatal();
                        try cssan.addIncludePath(arena, &cc_argv, .iframework, arg, path, false);
                        try create_module.framework_dirs.append(arena, path); // Forward to the backend as -F
                    } else if (mem.eql(u8, arg, "-iframeworkwithsysroot")) {
                        const path = args_iter.nextOrFatal();
                        try cssan.addIncludePath(arena, &cc_argv, .iframeworkwithsysroot, arg, path, false);
                        try create_module.framework_dirs.append(arena, path); // Forward to the backend as -F
                    } else if (mem.eql(u8, arg, "--version")) {
                        const next_arg = args_iter.nextOrFatal();
                        version = std.SemanticVersion.parse(next_arg) catch |err| {
                            fatal("unable to parse --version '{s}': {s}", .{ next_arg, @errorName(err) });
                        };
                        have_version = true;
                    } else if (mem.eql(u8, arg, "-target")) {
                        target_arch_os_abi = args_iter.nextOrFatal();
                    } else if (mem.eql(u8, arg, "-mcpu")) {
                        target_mcpu = args_iter.nextOrFatal();
                    } else if (mem.eql(u8, arg, "-mcmodel")) {
                        mod_opts.code_model = parseCodeModel(args_iter.nextOrFatal());
                    } else if (mem.startsWith(u8, arg, "-mcmodel=")) {
                        mod_opts.code_model = parseCodeModel(arg["-mcmodel=".len..]);
                    } else if (mem.startsWith(u8, arg, "-ofmt=")) {
                        create_module.object_format = arg["-ofmt=".len..];
                    } else if (mem.startsWith(u8, arg, "-mcpu=")) {
                        target_mcpu = arg["-mcpu=".len..];
                    } else if (mem.startsWith(u8, arg, "-O")) {
                        mod_opts.optimize_mode = parseOptimizeMode(arg["-O".len..]);
                    } else if (mem.eql(u8, arg, "--dynamic-linker")) {
                        create_module.dynamic_linker = args_iter.nextOrFatal();
                    } else if (mem.eql(u8, arg, "--sysroot")) {
                        const next_arg = args_iter.nextOrFatal();
                        create_module.sysroot = next_arg;
                        try cc_argv.appendSlice(arena, &.{ "-isysroot", next_arg });
                    } else if (mem.eql(u8, arg, "--libc")) {
                        create_module.libc_paths_file = args_iter.nextOrFatal();
                    } else if (mem.eql(u8, arg, "--test-filter")) {
                        try test_filters.append(arena, args_iter.nextOrFatal());
                    } else if (mem.eql(u8, arg, "--test-name-prefix")) {
                        test_name_prefix = args_iter.nextOrFatal();
                    } else if (mem.eql(u8, arg, "--test-runner")) {
                        test_runner_path = args_iter.nextOrFatal();
                    } else if (mem.eql(u8, arg, "--test-cmd")) {
                        try test_exec_args.append(arena, args_iter.nextOrFatal());
                    } else if (mem.eql(u8, arg, "--cache-dir")) {
                        override_local_cache_dir = args_iter.nextOrFatal();
                    } else if (mem.eql(u8, arg, "--global-cache-dir")) {
                        override_global_cache_dir = args_iter.nextOrFatal();
                    } else if (mem.eql(u8, arg, "--zig-lib-dir")) {
                        override_lib_dir = args_iter.nextOrFatal();
                    } else if (mem.eql(u8, arg, "--debug-log")) {
                        if (!build_options.enable_logging) {
                            warn("Zig was compiled without logging enabled (-Dlog). --debug-log has no effect.", .{});
                            _ = args_iter.nextOrFatal();
                        } else {
                            try log_scopes.append(arena, args_iter.nextOrFatal());
                        }
                    } else if (mem.eql(u8, arg, "--listen")) {
                        const next_arg = args_iter.nextOrFatal();
                        if (mem.eql(u8, next_arg, "-")) {
                            dev.check(.stdio_listen);
                            listen = .stdio;
                        } else {
                            dev.check(.network_listen);
                            // example: --listen 127.0.0.1:9000
                            var it = std.mem.splitScalar(u8, next_arg, ':');
                            const host = it.next().?;
                            const port_text = it.next() orelse "14735";
                            const port = std.fmt.parseInt(u16, port_text, 10) catch |err|
                                fatal("invalid port number: '{s}': {s}", .{ port_text, @errorName(err) });
                            listen = .{ .ip4 = std.net.Ip4Address.parse(host, port) catch |err|
                                fatal("invalid host: '{s}': {s}", .{ host, @errorName(err) }) };
                        }
                    } else if (mem.eql(u8, arg, "--listen=-")) {
                        dev.check(.stdio_listen);
                        listen = .stdio;
                    } else if (mem.eql(u8, arg, "--debug-link-snapshot")) {
                        if (!build_options.enable_link_snapshots) {
                            warn("Zig was compiled without linker snapshots enabled (-Dlink-snapshot). --debug-link-snapshot has no effect.", .{});
                        } else {
                            enable_link_snapshots = true;
                        }
                    } else if (mem.eql(u8, arg, "--debug-rt")) {
                        debug_compiler_runtime_libs = true;
                    } else if (mem.eql(u8, arg, "--debug-incremental")) {
                        if (build_options.enable_debug_extensions) {
                            debug_incremental = true;
                        } else {
                            warn("Zig was compiled without debug extensions. --debug-incremental has no effect.", .{});
                        }
                    } else if (mem.eql(u8, arg, "-fincremental")) {
                        dev.check(.incremental);
                        opt_incremental = true;
                    } else if (mem.eql(u8, arg, "-fno-incremental")) {
                        opt_incremental = false;
                    } else if (mem.eql(u8, arg, "--entitlements")) {
                        entitlements = args_iter.nextOrFatal();
                    } else if (mem.eql(u8, arg, "-fcompiler-rt")) {
                        want_compiler_rt = true;
                    } else if (mem.eql(u8, arg, "-fno-compiler-rt")) {
                        want_compiler_rt = false;
                    } else if (mem.eql(u8, arg, "-fubsan-rt")) {
                        want_ubsan_rt = true;
                    } else if (mem.eql(u8, arg, "-fno-ubsan-rt")) {
                        want_ubsan_rt = false;
                    } else if (mem.eql(u8, arg, "-feach-lib-rpath")) {
                        create_module.each_lib_rpath = true;
                    } else if (mem.eql(u8, arg, "-fno-each-lib-rpath")) {
                        create_module.each_lib_rpath = false;
                    } else if (mem.eql(u8, arg, "--test-cmd-bin")) {
                        try test_exec_args.append(arena, null);
                    } else if (mem.eql(u8, arg, "--test-no-exec")) {
                        test_no_exec = true;
                    } else if (mem.eql(u8, arg, "--time-report")) {
                        time_report = true;
                    } else if (mem.eql(u8, arg, "-fstack-report")) {
                        stack_report = true;
                    } else if (mem.eql(u8, arg, "-fPIC")) {
                        mod_opts.pic = true;
                    } else if (mem.eql(u8, arg, "-fno-PIC")) {
                        mod_opts.pic = false;
                    } else if (mem.eql(u8, arg, "-fPIE")) {
                        create_module.opts.pie = true;
                    } else if (mem.eql(u8, arg, "-fno-PIE")) {
                        create_module.opts.pie = false;
                    } else if (mem.eql(u8, arg, "-flto")) {
                        create_module.opts.lto = .full;
                    } else if (mem.startsWith(u8, arg, "-flto=")) {
                        const mode = arg["-flto=".len..];
                        if (mem.eql(u8, mode, "full")) {
                            create_module.opts.lto = .full;
                        } else if (mem.eql(u8, mode, "thin")) {
                            create_module.opts.lto = .thin;
                        } else {
                            fatal("Invalid -flto mode: '{s}'. Must be 'full'or 'thin'.", .{mode});
                        }
                    } else if (mem.eql(u8, arg, "-fno-lto")) {
                        create_module.opts.lto = .none;
                    } else if (mem.eql(u8, arg, "-funwind-tables")) {
                        mod_opts.unwind_tables = .sync;
                    } else if (mem.eql(u8, arg, "-fasync-unwind-tables")) {
                        mod_opts.unwind_tables = .async;
                    } else if (mem.eql(u8, arg, "-fno-unwind-tables")) {
                        mod_opts.unwind_tables = .none;
                    } else if (mem.eql(u8, arg, "-fstack-check")) {
                        mod_opts.stack_check = true;
                    } else if (mem.eql(u8, arg, "-fno-stack-check")) {
                        mod_opts.stack_check = false;
                    } else if (mem.eql(u8, arg, "-fstack-protector")) {
                        mod_opts.stack_protector = Compilation.default_stack_protector_buffer_size;
                    } else if (mem.eql(u8, arg, "-fno-stack-protector")) {
                        mod_opts.stack_protector = 0;
                    } else if (mem.eql(u8, arg, "-mred-zone")) {
                        mod_opts.red_zone = true;
                    } else if (mem.eql(u8, arg, "-mno-red-zone")) {
                        mod_opts.red_zone = false;
                    } else if (mem.eql(u8, arg, "-fomit-frame-pointer")) {
                        mod_opts.omit_frame_pointer = true;
                    } else if (mem.eql(u8, arg, "-fno-omit-frame-pointer")) {
                        mod_opts.omit_frame_pointer = false;
                    } else if (mem.eql(u8, arg, "-fsanitize-c")) {
                        mod_opts.sanitize_c = .full;
                    } else if (mem.startsWith(u8, arg, "-fsanitize-c=")) {
                        const mode = arg["-fsanitize-c=".len..];
                        if (mem.eql(u8, mode, "trap")) {
                            mod_opts.sanitize_c = .trap;
                        } else if (mem.eql(u8, mode, "full")) {
                            mod_opts.sanitize_c = .full;
                        } else {
                            fatal("Invalid -fsanitize-c mode: '{s}'. Must be 'trap' or 'full'.", .{mode});
                        }
                    } else if (mem.eql(u8, arg, "-fno-sanitize-c")) {
                        mod_opts.sanitize_c = .off;
                    } else if (mem.eql(u8, arg, "-fvalgrind")) {
                        mod_opts.valgrind = true;
                    } else if (mem.eql(u8, arg, "-fno-valgrind")) {
                        mod_opts.valgrind = false;
                    } else if (mem.eql(u8, arg, "-fsanitize-thread")) {
                        mod_opts.sanitize_thread = true;
                    } else if (mem.eql(u8, arg, "-fno-sanitize-thread")) {
                        mod_opts.sanitize_thread = false;
                    } else if (mem.eql(u8, arg, "-ffuzz")) {
                        mod_opts.fuzz = true;
                    } else if (mem.eql(u8, arg, "-fno-fuzz")) {
                        mod_opts.fuzz = false;
                    } else if (mem.eql(u8, arg, "-fllvm")) {
                        create_module.opts.use_llvm = true;
                    } else if (mem.eql(u8, arg, "-fno-llvm")) {
                        create_module.opts.use_llvm = false;
                    } else if (mem.eql(u8, arg, "-flibllvm")) {
                        create_module.opts.use_lib_llvm = true;
                    } else if (mem.eql(u8, arg, "-fno-libllvm")) {
                        create_module.opts.use_lib_llvm = false;
                    } else if (mem.eql(u8, arg, "-flld")) {
                        create_module.opts.use_lld = true;
                    } else if (mem.eql(u8, arg, "-fno-lld")) {
                        create_module.opts.use_lld = false;
                    } else if (mem.eql(u8, arg, "-fclang")) {
                        create_module.opts.use_clang = true;
                    } else if (mem.eql(u8, arg, "-fno-clang")) {
                        create_module.opts.use_clang = false;
                    } else if (mem.eql(u8, arg, "-fsanitize-coverage-trace-pc-guard")) {
                        create_module.opts.san_cov_trace_pc_guard = true;
                    } else if (mem.eql(u8, arg, "-fno-sanitize-coverage-trace-pc-guard")) {
                        create_module.opts.san_cov_trace_pc_guard = false;
                    } else if (mem.eql(u8, arg, "-freference-trace")) {
                        reference_trace = 256;
                    } else if (mem.startsWith(u8, arg, "-freference-trace=")) {
                        const num = arg["-freference-trace=".len..];
                        reference_trace = std.fmt.parseUnsigned(u32, num, 10) catch |err| {
                            fatal("unable to parse reference_trace count '{s}': {s}", .{ num, @errorName(err) });
                        };
                    } else if (mem.eql(u8, arg, "-fno-reference-trace")) {
                        reference_trace = null;
                    } else if (mem.eql(u8, arg, "-ferror-tracing")) {
                        mod_opts.error_tracing = true;
                    } else if (mem.eql(u8, arg, "-fno-error-tracing")) {
                        mod_opts.error_tracing = false;
                    } else if (mem.eql(u8, arg, "-rdynamic")) {
                        create_module.opts.rdynamic = true;
                    } else if (mem.eql(u8, arg, "-fsoname")) {
                        soname = .yes_default_value;
                    } else if (mem.startsWith(u8, arg, "-fsoname=")) {
                        soname = .{ .yes = arg["-fsoname=".len..] };
                    } else if (mem.eql(u8, arg, "-fno-soname")) {
                        soname = .no;
                    } else if (mem.eql(u8, arg, "-femit-bin")) {
                        emit_bin = .yes_default_path;
                    } else if (mem.startsWith(u8, arg, "-femit-bin=")) {
                        emit_bin = .{ .yes = arg["-femit-bin=".len..] };
                    } else if (mem.eql(u8, arg, "-fno-emit-bin")) {
                        emit_bin = .no;
                    } else if (mem.eql(u8, arg, "-femit-h")) {
                        emit_h = .yes_default_path;
                    } else if (mem.startsWith(u8, arg, "-femit-h=")) {
                        emit_h = .{ .yes = arg["-femit-h=".len..] };
                    } else if (mem.eql(u8, arg, "-fno-emit-h")) {
                        emit_h = .no;
                    } else if (mem.eql(u8, arg, "-femit-asm")) {
                        emit_asm = .yes_default_path;
                    } else if (mem.startsWith(u8, arg, "-femit-asm=")) {
                        emit_asm = .{ .yes = arg["-femit-asm=".len..] };
                    } else if (mem.eql(u8, arg, "-fno-emit-asm")) {
                        emit_asm = .no;
                    } else if (mem.eql(u8, arg, "-femit-llvm-ir")) {
                        emit_llvm_ir = .yes_default_path;
                    } else if (mem.startsWith(u8, arg, "-femit-llvm-ir=")) {
                        emit_llvm_ir = .{ .yes = arg["-femit-llvm-ir=".len..] };
                    } else if (mem.eql(u8, arg, "-fno-emit-llvm-ir")) {
                        emit_llvm_ir = .no;
                    } else if (mem.eql(u8, arg, "-femit-llvm-bc")) {
                        emit_llvm_bc = .yes_default_path;
                    } else if (mem.startsWith(u8, arg, "-femit-llvm-bc=")) {
                        emit_llvm_bc = .{ .yes = arg["-femit-llvm-bc=".len..] };
                    } else if (mem.eql(u8, arg, "-fno-emit-llvm-bc")) {
                        emit_llvm_bc = .no;
                    } else if (mem.eql(u8, arg, "-femit-docs")) {
                        emit_docs = .yes_default_path;
                    } else if (mem.startsWith(u8, arg, "-femit-docs=")) {
                        emit_docs = .{ .yes = arg["-femit-docs=".len..] };
                    } else if (mem.eql(u8, arg, "-fno-emit-docs")) {
                        emit_docs = .no;
                    } else if (mem.eql(u8, arg, "-femit-implib")) {
                        emit_implib = .yes_default_path;
                        emit_implib_arg_provided = true;
                    } else if (mem.startsWith(u8, arg, "-femit-implib=")) {
                        emit_implib = .{ .yes = arg["-femit-implib=".len..] };
                        emit_implib_arg_provided = true;
                    } else if (mem.eql(u8, arg, "-fno-emit-implib")) {
                        emit_implib = .no;
                        emit_implib_arg_provided = true;
                    } else if (mem.eql(u8, arg, "-dynamic")) {
                        create_module.opts.link_mode = .dynamic;
                        lib_preferred_mode = .dynamic;
                        lib_search_strategy = .mode_first;
                    } else if (mem.eql(u8, arg, "-static")) {
                        create_module.opts.link_mode = .static;
                        lib_preferred_mode = .static;
                        lib_search_strategy = .no_fallback;
                    } else if (mem.eql(u8, arg, "-fdll-export-fns")) {
                        create_module.opts.dll_export_fns = true;
                    } else if (mem.eql(u8, arg, "-fno-dll-export-fns")) {
                        create_module.opts.dll_export_fns = false;
                    } else if (mem.eql(u8, arg, "--show-builtin")) {
                        show_builtin = true;
                        emit_bin = .no;
                    } else if (mem.eql(u8, arg, "-fstrip")) {
                        mod_opts.strip = true;
                    } else if (mem.eql(u8, arg, "-fno-strip")) {
                        mod_opts.strip = false;
                    } else if (mem.eql(u8, arg, "-gdwarf32")) {
                        create_module.opts.debug_format = .{ .dwarf = .@"32" };
                    } else if (mem.eql(u8, arg, "-gdwarf64")) {
                        create_module.opts.debug_format = .{ .dwarf = .@"64" };
                    } else if (mem.eql(u8, arg, "-fformatted-panics")) {
                        // Remove this after 0.15.0 is tagged.
                        warn("-fformatted-panics is deprecated and does nothing", .{});
                    } else if (mem.eql(u8, arg, "-fno-formatted-panics")) {
                        // Remove this after 0.15.0 is tagged.
                        warn("-fno-formatted-panics is deprecated and does nothing", .{});
                    } else if (mem.eql(u8, arg, "-fsingle-threaded")) {
                        mod_opts.single_threaded = true;
                    } else if (mem.eql(u8, arg, "-fno-single-threaded")) {
                        mod_opts.single_threaded = false;
                    } else if (mem.eql(u8, arg, "-ffunction-sections")) {
                        function_sections = true;
                    } else if (mem.eql(u8, arg, "-fno-function-sections")) {
                        function_sections = false;
                    } else if (mem.eql(u8, arg, "-fdata-sections")) {
                        data_sections = true;
                    } else if (mem.eql(u8, arg, "-fno-data-sections")) {
                        data_sections = false;
                    } else if (mem.eql(u8, arg, "-fbuiltin")) {
                        mod_opts.no_builtin = false;
                    } else if (mem.eql(u8, arg, "-fno-builtin")) {
                        mod_opts.no_builtin = true;
                    } else if (mem.startsWith(u8, arg, "-fopt-bisect-limit=")) {
                        const next_arg = arg["-fopt-bisect-limit=".len..];
                        llvm_opt_bisect_limit = std.fmt.parseInt(c_int, next_arg, 0) catch |err|
                            fatal("unable to parse '{s}': {s}", .{ arg, @errorName(err) });
                    } else if (mem.eql(u8, arg, "--eh-frame-hdr")) {
                        link_eh_frame_hdr = true;
                    } else if (mem.eql(u8, arg, "--no-eh-frame-hdr")) {
                        link_eh_frame_hdr = false;
                    } else if (mem.eql(u8, arg, "--dynamicbase")) {
                        linker_dynamicbase = true;
                    } else if (mem.eql(u8, arg, "--no-dynamicbase")) {
                        linker_dynamicbase = false;
                    } else if (mem.eql(u8, arg, "--emit-relocs")) {
                        link_emit_relocs = true;
                    } else if (mem.eql(u8, arg, "-fallow-shlib-undefined")) {
                        linker_allow_shlib_undefined = true;
                    } else if (mem.eql(u8, arg, "-fno-allow-shlib-undefined")) {
                        linker_allow_shlib_undefined = false;
                    } else if (mem.eql(u8, arg, "-fallow-so-scripts")) {
                        allow_so_scripts = true;
                    } else if (mem.eql(u8, arg, "-fno-allow-so-scripts")) {
                        allow_so_scripts = false;
                    } else if (mem.eql(u8, arg, "-z")) {
                        const z_arg = args_iter.nextOrFatal();
                        if (mem.eql(u8, z_arg, "nodelete")) {
                            linker_z_nodelete = true;
                        } else if (mem.eql(u8, z_arg, "notext")) {
                            linker_z_notext = true;
                        } else if (mem.eql(u8, z_arg, "defs")) {
                            linker_z_defs = true;
                        } else if (mem.eql(u8, z_arg, "undefs")) {
                            linker_z_defs = false;
                        } else if (mem.eql(u8, z_arg, "origin")) {
                            linker_z_origin = true;
                        } else if (mem.eql(u8, z_arg, "nocopyreloc")) {
                            linker_z_nocopyreloc = true;
                        } else if (mem.eql(u8, z_arg, "now")) {
                            linker_z_now = true;
                        } else if (mem.eql(u8, z_arg, "lazy")) {
                            linker_z_now = false;
                        } else if (mem.eql(u8, z_arg, "relro")) {
                            linker_z_relro = true;
                        } else if (mem.eql(u8, z_arg, "norelro")) {
                            linker_z_relro = false;
                        } else if (mem.startsWith(u8, z_arg, "common-page-size=")) {
                            linker_z_common_page_size = parseIntSuffix(z_arg, "common-page-size=".len);
                        } else if (mem.startsWith(u8, z_arg, "max-page-size=")) {
                            linker_z_max_page_size = parseIntSuffix(z_arg, "max-page-size=".len);
                        } else {
                            fatal("unsupported linker extension flag: -z {s}", .{z_arg});
                        }
                    } else if (mem.eql(u8, arg, "--import-memory")) {
                        create_module.opts.import_memory = true;
                    } else if (mem.eql(u8, arg, "-fentry")) {
                        switch (entry) {
                            .default, .disabled => entry = .enabled,
                            .enabled, .named => {},
                        }
                    } else if (mem.eql(u8, arg, "-fno-entry")) {
                        entry = .disabled;
                    } else if (mem.eql(u8, arg, "--export-memory")) {
                        create_module.opts.export_memory = true;
                    } else if (mem.eql(u8, arg, "--import-symbols")) {
                        linker_import_symbols = true;
                    } else if (mem.eql(u8, arg, "--import-table")) {
                        linker_import_table = true;
                    } else if (mem.eql(u8, arg, "--export-table")) {
                        linker_export_table = true;
                    } else if (mem.startsWith(u8, arg, "--initial-memory=")) {
                        linker_initial_memory = parseIntSuffix(arg, "--initial-memory=".len);
                    } else if (mem.startsWith(u8, arg, "--max-memory=")) {
                        linker_max_memory = parseIntSuffix(arg, "--max-memory=".len);
                    } else if (mem.eql(u8, arg, "--shared-memory")) {
                        create_module.opts.shared_memory = true;
                    } else if (mem.startsWith(u8, arg, "--global-base=")) {
                        linker_global_base = parseIntSuffix(arg, "--global-base=".len);
                    } else if (mem.startsWith(u8, arg, "--export=")) {
                        try linker_export_symbol_names.append(arena, arg["--export=".len..]);
                    } else if (mem.eql(u8, arg, "-Bsymbolic")) {
                        linker_bind_global_refs_locally = true;
                    } else if (mem.eql(u8, arg, "--gc-sections")) {
                        linker_gc_sections = true;
                    } else if (mem.eql(u8, arg, "--no-gc-sections")) {
                        linker_gc_sections = false;
                    } else if (mem.eql(u8, arg, "--build-id")) {
                        build_id = .fast;
                    } else if (mem.startsWith(u8, arg, "--build-id=")) {
                        const style = arg["--build-id=".len..];
                        build_id = std.zig.BuildId.parse(style) catch |err| {
                            fatal("unable to parse --build-id style '{s}': {s}", .{
                                style, @errorName(err),
                            });
                        };
                    } else if (mem.eql(u8, arg, "--debug-compile-errors")) {
                        if (build_options.enable_debug_extensions) {
                            debug_compile_errors = true;
                        } else {
                            warn("Zig was compiled without debug extensions. --debug-compile-errors has no effect.", .{});
                        }
                    } else if (mem.eql(u8, arg, "--verbose-link")) {
                        verbose_link = true;
                    } else if (mem.eql(u8, arg, "--verbose-cc")) {
                        verbose_cc = true;
                    } else if (mem.eql(u8, arg, "--verbose-air")) {
                        verbose_air = true;
                    } else if (mem.eql(u8, arg, "--verbose-intern-pool")) {
                        verbose_intern_pool = true;
                    } else if (mem.eql(u8, arg, "--verbose-generic-instances")) {
                        verbose_generic_instances = true;
                    } else if (mem.eql(u8, arg, "--verbose-llvm-ir")) {
                        verbose_llvm_ir = "-";
                    } else if (mem.startsWith(u8, arg, "--verbose-llvm-ir=")) {
                        verbose_llvm_ir = arg["--verbose-llvm-ir=".len..];
                    } else if (mem.startsWith(u8, arg, "--verbose-llvm-bc=")) {
                        verbose_llvm_bc = arg["--verbose-llvm-bc=".len..];
                    } else if (mem.eql(u8, arg, "--verbose-cimport")) {
                        verbose_cimport = true;
                    } else if (mem.eql(u8, arg, "--verbose-llvm-cpu-features")) {
                        verbose_llvm_cpu_features = true;
                    } else if (mem.startsWith(u8, arg, "-T")) {
                        linker_script = arg[2..];
                    } else if (mem.startsWith(u8, arg, "-L")) {
                        try create_module.lib_dir_args.append(arena, arg[2..]);
                    } else if (mem.startsWith(u8, arg, "-F")) {
                        try create_module.framework_dirs.append(arena, arg[2..]);
                    } else if (mem.startsWith(u8, arg, "-l")) {
                        // We don't know whether this library is part of libc
                        // or libc++ until we resolve the target, so we append
                        // to the list for now.
                        try create_module.cli_link_inputs.append(arena, .{ .name_query = .{
                            .name = arg["-l".len..],
                            .query = .{
                                .needed = false,
                                .weak = false,
                                .preferred_mode = lib_preferred_mode,
                                .search_strategy = lib_search_strategy,
                                .allow_so_scripts = allow_so_scripts,
                            },
                        } });
                    } else if (mem.startsWith(u8, arg, "-needed-l")) {
                        try create_module.cli_link_inputs.append(arena, .{ .name_query = .{
                            .name = arg["-needed-l".len..],
                            .query = .{
                                .needed = true,
                                .weak = false,
                                .preferred_mode = lib_preferred_mode,
                                .search_strategy = lib_search_strategy,
                                .allow_so_scripts = allow_so_scripts,
                            },
                        } });
                    } else if (mem.startsWith(u8, arg, "-weak-l")) {
                        try create_module.cli_link_inputs.append(arena, .{ .name_query = .{
                            .name = arg["-weak-l".len..],
                            .query = .{
                                .needed = false,
                                .weak = true,
                                .preferred_mode = lib_preferred_mode,
                                .search_strategy = lib_search_strategy,
                                .allow_so_scripts = allow_so_scripts,
                            },
                        } });
                    } else if (mem.startsWith(u8, arg, "-D")) {
                        try cc_argv.append(arena, arg);
                    } else if (mem.startsWith(u8, arg, "-I")) {
                        try cssan.addIncludePath(arena, &cc_argv, .I, arg, arg[2..], true);
                    } else if (mem.startsWith(u8, arg, "-x")) {
                        const lang = if (arg.len == "-x".len)
                            args_iter.nextOrFatal()
                        else
                            arg["-x".len..];
                        if (mem.eql(u8, lang, "none")) {
                            file_ext = null;
                        } else if (Compilation.LangToExt.get(lang)) |got_ext| {
                            file_ext = got_ext;
                        } else {
                            fatal("language not recognized: '{s}'", .{lang});
                        }
                    } else if (mem.startsWith(u8, arg, "-mexec-model=")) {
                        create_module.opts.wasi_exec_model = parseWasiExecModel(arg["-mexec-model=".len..]);
                    } else if (mem.eql(u8, arg, "-municode")) {
                        mingw_unicode_entry_point = true;
                    } else {
                        fatal("unrecognized parameter: '{s}'", .{arg});
                    }
                } else switch (file_ext orelse Compilation.classifyFileExt(arg)) {
                    .shared_library, .object, .static_library => {
                        try create_module.cli_link_inputs.append(arena, .{ .path_query = .{
                            .path = Path.initCwd(arg),
                            .query = .{
                                .preferred_mode = lib_preferred_mode,
                                .search_strategy = lib_search_strategy,
                                .allow_so_scripts = allow_so_scripts,
                            },
                        } });
                        // We do not set `any_dyn_libs` yet because a .so file
                        // may actually resolve to a GNU ld script which ends
                        // up being a static library.
                    },
                    .res => {
                        try create_module.cli_link_inputs.append(arena, .{ .path_query = .{
                            .path = Path.initCwd(arg),
                            .query = .{
                                .preferred_mode = lib_preferred_mode,
                                .search_strategy = lib_search_strategy,
                                .allow_so_scripts = allow_so_scripts,
                            },
                        } });
                        contains_res_file = true;
                    },
                    .manifest => {
                        if (manifest_file) |other| {
                            fatal("only one manifest file can be specified, found '{s}' after '{s}'", .{ arg, other });
                        } else manifest_file = arg;
                    },
                    .assembly, .assembly_with_cpp, .c, .cpp, .h, .hpp, .hm, .hmm, .ll, .bc, .m, .mm => {
                        dev.check(.c_compiler);
                        try create_module.c_source_files.append(arena, .{
                            // Populated after module creation.
                            .owner = undefined,
                            .src_path = arg,
                            .extra_flags = try arena.dupe([]const u8, extra_cflags.items),
                            // duped when parsing the args.
                            .ext = file_ext,
                        });
                    },
                    .rc => {
                        dev.check(.win32_resource);
                        try create_module.rc_source_files.append(arena, .{
                            // Populated after module creation.
                            .owner = undefined,
                            .src_path = arg,
                            .extra_flags = try arena.dupe([]const u8, extra_rcflags.items),
                        });
                    },
                    .zig => {
                        if (root_src_file) |other| {
                            fatal("found another zig file '{s}' after root source file '{s}'", .{ arg, other });
                        } else root_src_file = arg;
                    },
                    .def, .unknown => {
                        if (std.ascii.eqlIgnoreCase(".xml", fs.path.extension(arg))) {
                            warn("embedded manifest files must have the extension '.manifest'", .{});
                        }
                        fatal("unrecognized file extension of parameter '{s}'", .{arg});
                    },
                }
            }
        },
        .cc, .cpp => {
            dev.check(.cc_command);

            emit_h = .no;
            soname = .no;
            create_module.opts.ensure_libc_on_non_freestanding = true;
            create_module.opts.ensure_libcpp_on_non_freestanding = arg_mode == .cpp;
            create_module.want_native_include_dirs = true;
            // Clang's driver enables this switch unconditionally.
            // Disabling the emission of .eh_frame_hdr can unexpectedly break
            // some functionality that depend on it, such as C++ exceptions and
            // DWARF-based stack traces.
            link_eh_frame_hdr = true;
            allow_so_scripts = true;

            const COutMode = enum {
                link,
                object,
                assembly,
                preprocessor,
            };
            var c_out_mode: ?COutMode = null;
            var out_path: ?[]const u8 = null;
            var is_shared_lib = false;
            var preprocessor_args = std.ArrayList([]const u8).init(arena);
            var linker_args = std.ArrayList([]const u8).init(arena);
            var it = ClangArgIterator.init(arena, all_args);
            var emit_llvm = false;
            var needed = false;
            var must_link = false;
            var file_ext: ?Compilation.FileExt = null;
            while (it.has_next) {
                it.next() catch |err| {
                    fatal("unable to parse command line parameters: {s}", .{@errorName(err)});
                };
                switch (it.zig_equivalent) {
                    .target => target_arch_os_abi = it.only_arg, // example: -target riscv64-linux-unknown
                    .o => {
                        // We handle -o /dev/null equivalent to -fno-emit-bin because
                        // otherwise our atomic rename into place will fail. This also
                        // makes Zig do less work, avoiding pointless file system operations.
                        if (mem.eql(u8, it.only_arg, "/dev/null")) {
                            emit_bin = .no;
                        } else {
                            out_path = it.only_arg;
                        }
                    },
                    .c, .r => c_out_mode = .object, // -c or -r
                    .asm_only => c_out_mode = .assembly, // -S
                    .preprocess_only => c_out_mode = .preprocessor, // -E
                    .emit_llvm => emit_llvm = true,
                    .x => {
                        const lang = mem.sliceTo(it.only_arg, 0);
                        if (mem.eql(u8, lang, "none")) {
                            file_ext = null;
                        } else if (Compilation.LangToExt.get(lang)) |got_ext| {
                            file_ext = got_ext;
                        } else {
                            fatal("language not recognized: '{s}'", .{lang});
                        }
                    },
                    .other => {
                        try cc_argv.appendSlice(arena, it.other_args);
                    },
                    .positional => switch (file_ext orelse Compilation.classifyFileExt(mem.sliceTo(it.only_arg, 0))) {
                        .assembly, .assembly_with_cpp, .c, .cpp, .ll, .bc, .h, .hpp, .hm, .hmm, .m, .mm => {
                            try create_module.c_source_files.append(arena, .{
                                // Populated after module creation.
                                .owner = undefined,
                                .src_path = it.only_arg,
                                .ext = file_ext, // duped while parsing the args.
                            });
                        },
                        .unknown, .object, .static_library, .shared_library => {
                            try create_module.cli_link_inputs.append(arena, .{ .path_query = .{
                                .path = Path.initCwd(it.only_arg),
                                .query = .{
                                    .must_link = must_link,
                                    .needed = needed,
                                    .preferred_mode = lib_preferred_mode,
                                    .search_strategy = lib_search_strategy,
                                    .allow_so_scripts = allow_so_scripts,
                                },
                            } });
                            // We do not set `any_dyn_libs` yet because a .so file
                            // may actually resolve to a GNU ld script which ends
                            // up being a static library.
                        },
                        .res => {
                            try create_module.cli_link_inputs.append(arena, .{ .path_query = .{
                                .path = Path.initCwd(it.only_arg),
                                .query = .{
                                    .must_link = must_link,
                                    .needed = needed,
                                    .preferred_mode = lib_preferred_mode,
                                    .search_strategy = lib_search_strategy,
                                    .allow_so_scripts = allow_so_scripts,
                                },
                            } });
                            contains_res_file = true;
                        },
                        .manifest => {
                            if (manifest_file) |other| {
                                fatal("only one manifest file can be specified, found '{s}' after previously specified manifest '{s}'", .{ it.only_arg, other });
                            } else manifest_file = it.only_arg;
                        },
                        .def => {
                            linker_module_definition_file = it.only_arg;
                        },
                        .rc => {
                            try create_module.rc_source_files.append(arena, .{
                                // Populated after module creation.
                                .owner = undefined,
                                .src_path = it.only_arg,
                            });
                        },
                        .zig => {
                            if (root_src_file) |other| {
                                fatal("found another zig file '{s}' after root source file '{s}'", .{ it.only_arg, other });
                            } else root_src_file = it.only_arg;
                        },
                    },
                    .l => {
                        // -l
                        // We don't know whether this library is part of libc or libc++ until
                        // we resolve the target, so we simply append to the list for now.
                        if (mem.startsWith(u8, it.only_arg, ":")) {
                            // -l :path/to/filename is used when callers need
                            // more control over what's in the resulting
                            // binary: no extra rpaths and DSO filename exactly
                            // as provided. CGo compilation depends on this.
                            try create_module.cli_link_inputs.append(arena, .{ .dso_exact = .{
                                .name = it.only_arg,
                            } });
                        } else {
                            try create_module.cli_link_inputs.append(arena, .{ .name_query = .{
                                .name = it.only_arg,
                                .query = .{
                                    .must_link = must_link,
                                    .needed = needed,
                                    .weak = false,
                                    .preferred_mode = lib_preferred_mode,
                                    .search_strategy = lib_search_strategy,
                                    .allow_so_scripts = allow_so_scripts,
                                },
                            } });
                        }
                    },
                    .ignore => {},
                    .driver_punt => {
                        // Never mind what we're doing, just pass the args directly. For example --help.
                        return process.exit(try clangMain(arena, all_args));
                    },
                    .pic => mod_opts.pic = true,
                    .no_pic => mod_opts.pic = false,
                    .pie => create_module.opts.pie = true,
                    .no_pie => create_module.opts.pie = false,
                    .lto => {
                        if (mem.eql(u8, it.only_arg, "flto") or
                            mem.eql(u8, it.only_arg, "auto") or
                            mem.eql(u8, it.only_arg, "full") or
                            mem.eql(u8, it.only_arg, "jobserver"))
                        {
                            create_module.opts.lto = .full;
                        } else if (mem.eql(u8, it.only_arg, "thin")) {
                            create_module.opts.lto = .thin;
                        } else {
                            fatal("Invalid -flto mode: '{s}'. Must be 'auto', 'full', 'thin', or 'jobserver'.", .{it.only_arg});
                        }
                    },
                    .no_lto => create_module.opts.lto = .none,
                    .red_zone => mod_opts.red_zone = true,
                    .no_red_zone => mod_opts.red_zone = false,
                    .omit_frame_pointer => mod_opts.omit_frame_pointer = true,
                    .no_omit_frame_pointer => mod_opts.omit_frame_pointer = false,
                    .function_sections => function_sections = true,
                    .no_function_sections => function_sections = false,
                    .data_sections => data_sections = true,
                    .no_data_sections => data_sections = false,
                    .builtin => mod_opts.no_builtin = false,
                    .no_builtin => mod_opts.no_builtin = true,
                    .color_diagnostics => color = .on,
                    .no_color_diagnostics => color = .off,
                    .stack_check => mod_opts.stack_check = true,
                    .no_stack_check => mod_opts.stack_check = false,
                    .stack_protector => {
                        if (mod_opts.stack_protector == null) {
                            mod_opts.stack_protector = Compilation.default_stack_protector_buffer_size;
                        }
                    },
                    .no_stack_protector => mod_opts.stack_protector = 0,
                    // The way these unwind table options are processed in GCC and Clang is crazy
                    // convoluted, and we also don't know the target triple here, so this is all
                    // best-effort.
                    .unwind_tables => if (mod_opts.unwind_tables) |uwt| switch (uwt) {
                        .none => {
                            mod_opts.unwind_tables = .sync;
                        },
                        .sync, .async => {},
                    } else {
                        mod_opts.unwind_tables = .sync;
                    },
                    .no_unwind_tables => mod_opts.unwind_tables = .none,
                    .asynchronous_unwind_tables => mod_opts.unwind_tables = .async,
                    .no_asynchronous_unwind_tables => if (mod_opts.unwind_tables) |uwt| switch (uwt) {
                        .none, .sync => {},
                        .async => {
                            mod_opts.unwind_tables = .sync;
                        },
                    } else {
                        mod_opts.unwind_tables = .sync;
                    },
                    .nostdlib => {
                        create_module.opts.ensure_libc_on_non_freestanding = false;
                        create_module.opts.ensure_libcpp_on_non_freestanding = false;
                    },
                    .nostdlib_cpp => create_module.opts.ensure_libcpp_on_non_freestanding = false,
                    .shared => {
                        create_module.opts.link_mode = .dynamic;
                        is_shared_lib = true;
                    },
                    .rdynamic => create_module.opts.rdynamic = true,
                    .wp => {
                        var split_it = mem.splitScalar(u8, it.only_arg, ',');
                        while (split_it.next()) |preprocessor_arg| {
                            if (preprocessor_arg.len >= 3 and
                                preprocessor_arg[0] == '-' and
                                preprocessor_arg[2] != '-')
                            {
                                if (mem.indexOfScalar(u8, preprocessor_arg, '=')) |equals_pos| {
                                    const key = preprocessor_arg[0..equals_pos];
                                    const value = preprocessor_arg[equals_pos + 1 ..];
                                    try preprocessor_args.append(key);
                                    try preprocessor_args.append(value);
                                    continue;
                                }
                            }
                            try preprocessor_args.append(preprocessor_arg);
                        }
                    },
                    .wl => {
                        var split_it = mem.splitScalar(u8, it.only_arg, ',');
                        while (split_it.next()) |linker_arg| {
                            // Handle nested-joined args like `-Wl,-rpath=foo`.
                            // Must be prefixed with 1 or 2 dashes.
                            if (linker_arg.len >= 3 and
                                linker_arg[0] == '-' and
                                linker_arg[2] != '-')
                            {
                                if (mem.indexOfScalar(u8, linker_arg, '=')) |equals_pos| {
                                    const key = linker_arg[0..equals_pos];
                                    const value = linker_arg[equals_pos + 1 ..];
                                    if (mem.eql(u8, key, "--build-id")) {
                                        build_id = std.zig.BuildId.parse(value) catch |err| {
                                            fatal("unable to parse --build-id style '{s}': {s}", .{
                                                value, @errorName(err),
                                            });
                                        };
                                        continue;
                                    } else if (mem.eql(u8, key, "--sort-common")) {
                                        // this ignores --sort=common=<anything>; ignoring plain --sort-common
                                        // is done below.
                                        continue;
                                    }
                                    try linker_args.append(key);
                                    try linker_args.append(value);
                                    continue;
                                }
                            }
                            if (mem.eql(u8, linker_arg, "--build-id")) {
                                build_id = .fast;
                            } else if (mem.eql(u8, linker_arg, "--as-needed")) {
                                needed = false;
                            } else if (mem.eql(u8, linker_arg, "--no-as-needed")) {
                                needed = true;
                            } else if (mem.eql(u8, linker_arg, "-no-pie")) {
                                create_module.opts.pie = false;
                            } else if (mem.eql(u8, linker_arg, "--sort-common")) {
                                // from ld.lld(1): --sort-common is ignored for GNU compatibility,
                                // this ignores plain --sort-common
                            } else if (mem.eql(u8, linker_arg, "--whole-archive") or
                                mem.eql(u8, linker_arg, "-whole-archive"))
                            {
                                must_link = true;
                            } else if (mem.eql(u8, linker_arg, "--no-whole-archive") or
                                mem.eql(u8, linker_arg, "-no-whole-archive"))
                            {
                                must_link = false;
                            } else if (mem.eql(u8, linker_arg, "-Bdynamic") or
                                mem.eql(u8, linker_arg, "-dy") or
                                mem.eql(u8, linker_arg, "-call_shared"))
                            {
                                lib_search_strategy = .no_fallback;
                                lib_preferred_mode = .dynamic;
                            } else if (mem.eql(u8, linker_arg, "-Bstatic") or
                                mem.eql(u8, linker_arg, "-dn") or
                                mem.eql(u8, linker_arg, "-non_shared") or
                                mem.eql(u8, linker_arg, "-static"))
                            {
                                lib_search_strategy = .no_fallback;
                                lib_preferred_mode = .static;
                            } else if (mem.eql(u8, linker_arg, "-search_paths_first")) {
                                lib_search_strategy = .paths_first;
                                lib_preferred_mode = .dynamic;
                            } else if (mem.eql(u8, linker_arg, "-search_dylibs_first")) {
                                lib_search_strategy = .mode_first;
                                lib_preferred_mode = .dynamic;
                            } else {
                                try linker_args.append(linker_arg);
                            }
                        }
                    },
                    .san_cov_trace_pc_guard => create_module.opts.san_cov_trace_pc_guard = true,
                    .san_cov => {
                        var split_it = mem.splitScalar(u8, it.only_arg, ',');
                        while (split_it.next()) |san_arg| {
                            if (std.mem.eql(u8, san_arg, "trace-pc-guard")) {
                                create_module.opts.san_cov_trace_pc_guard = true;
                            }
                        }
                        try cc_argv.appendSlice(arena, it.other_args);
                    },
                    .no_san_cov => {
                        var split_it = mem.splitScalar(u8, it.only_arg, ',');
                        while (split_it.next()) |san_arg| {
                            if (std.mem.eql(u8, san_arg, "trace-pc-guard")) {
                                create_module.opts.san_cov_trace_pc_guard = false;
                            }
                        }
                        try cc_argv.appendSlice(arena, it.other_args);
                    },
                    .optimize => {
                        // Alright, what release mode do they want?
                        const level = if (it.only_arg.len >= 1 and it.only_arg[0] == 'O') it.only_arg[1..] else it.only_arg;
                        if (mem.eql(u8, level, "s") or
                            mem.eql(u8, level, "z"))
                        {
                            mod_opts.optimize_mode = .ReleaseSmall;
                        } else if (mem.eql(u8, level, "1") or
                            mem.eql(u8, level, "2") or
                            mem.eql(u8, level, "3") or
                            mem.eql(u8, level, "4") or
                            mem.eql(u8, level, "fast"))
                        {
                            mod_opts.optimize_mode = .ReleaseFast;
                        } else if (mem.eql(u8, level, "g") or
                            mem.eql(u8, level, "0"))
                        {
                            mod_opts.optimize_mode = .Debug;
                        } else {
                            try cc_argv.appendSlice(arena, it.other_args);
                        }
                    },
                    .debug => {
                        mod_opts.strip = false;
                        if (mem.eql(u8, it.only_arg, "g")) {
                            // We handled with strip = false above.
                        } else if (mem.eql(u8, it.only_arg, "g1") or
                            mem.eql(u8, it.only_arg, "gline-tables-only"))
                        {
                            // We handled with strip = false above. but we also want reduced debug info.
                            try cc_argv.append(arena, "-gline-tables-only");
                        } else {
                            try cc_argv.appendSlice(arena, it.other_args);
                        }
                    },
                    .gdwarf32 => {
                        mod_opts.strip = false;
                        create_module.opts.debug_format = .{ .dwarf = .@"32" };
                    },
                    .gdwarf64 => {
                        mod_opts.strip = false;
                        create_module.opts.debug_format = .{ .dwarf = .@"64" };
                    },
                    .sanitize, .no_sanitize => |t| {
                        const enable = t == .sanitize;
                        var san_it = std.mem.splitScalar(u8, it.only_arg, ',');
                        var recognized_any = false;
                        while (san_it.next()) |sub_arg| {
                            if (mem.eql(u8, sub_arg, "undefined")) {
                                mod_opts.sanitize_c = if (enable) .full else .off;
                                recognized_any = true;
                            } else if (mem.eql(u8, sub_arg, "thread")) {
                                mod_opts.sanitize_thread = enable;
                                recognized_any = true;
                            } else if (mem.eql(u8, sub_arg, "fuzzer") or mem.eql(u8, sub_arg, "fuzzer-no-link")) {
                                mod_opts.fuzz = enable;
                                recognized_any = true;
                            }
                        }
                        if (!recognized_any) {
                            try cc_argv.appendSlice(arena, it.other_args);
                        }
                    },
                    .sanitize_trap, .no_sanitize_trap => |t| {
                        const enable = t == .sanitize_trap;
                        var san_it = std.mem.splitScalar(u8, it.only_arg, ',');
                        var recognized_any = false;
                        while (san_it.next()) |sub_arg| {
                            // This logic doesn't match Clang 1:1, but it's probably good enough, and avoids
                            // significantly complicating the resolution of the options.
                            if (mem.eql(u8, sub_arg, "undefined")) {
                                if (mod_opts.sanitize_c) |sc| switch (sc) {
                                    .off => if (enable) {
                                        mod_opts.sanitize_c = .trap;
                                    },
                                    .trap => if (!enable) {
                                        mod_opts.sanitize_c = .full;
                                    },
                                    .full => if (enable) {
                                        mod_opts.sanitize_c = .trap;
                                    },
                                } else {
                                    if (enable) {
                                        mod_opts.sanitize_c = .trap;
                                    } else {
                                        // This means we were passed `-fno-sanitize-trap=undefined` and nothing else. In
                                        // this case, ideally, we should use whatever value `sanitize_c` resolves to by
                                        // default, except change `trap` to `full`. However, we don't yet know what
                                        // `sanitize_c` will resolve to! So we either have to pick `off` or `full`.
                                        //
                                        // `full` has the potential to be problematic if `optimize_mode` turns out to
                                        // be `ReleaseFast`/`ReleaseSmall` because the user will get a slower and larger
                                        // binary than expected. On the other hand, if `optimize_mode` turns out to be
                                        // `Debug`/`ReleaseSafe`, `off` would mean UBSan would unexpectedly be disabled.
                                        //
                                        // `off` seems very slightly less bad, so let's go with that.
                                        mod_opts.sanitize_c = .off;
                                    }
                                }
                                recognized_any = true;
                            }
                        }
                        if (!recognized_any) {
                            try cc_argv.appendSlice(arena, it.other_args);
                        }
                    },
                    .linker_script => linker_script = it.only_arg,
                    .verbose => {
                        verbose_link = true;
                        // Have Clang print more infos, some tools such as CMake
                        // parse this to discover any implicit include and
                        // library dir to look-up into.
                        try cc_argv.append(arena, "-v");
                    },
                    .dry_run => {
                        // This flag means "dry run". Clang will not actually output anything
                        // to the file system.
                        verbose_link = true;
                        disable_c_depfile = true;
                        try cc_argv.append(arena, "-###");
                    },
                    .for_linker => try linker_args.append(it.only_arg),
                    .linker_input_z => {
                        try linker_args.append("-z");
                        try linker_args.append(it.only_arg);
                    },
                    .lib_dir => try create_module.lib_dir_args.append(arena, it.only_arg),
                    .mcpu => target_mcpu = it.only_arg,
                    .m => try create_module.llvm_m_args.append(arena, it.only_arg),
                    .dep_file => {
                        disable_c_depfile = true;
                        try cc_argv.appendSlice(arena, it.other_args);
                    },
                    .dep_file_to_stdout => { // -M, -MM
                        // "Like -MD, but also implies -E and writes to stdout by default"
                        // "Like -MMD, but also implies -E and writes to stdout by default"
                        c_out_mode = .preprocessor;
                        disable_c_depfile = true;
                        try cc_argv.appendSlice(arena, it.other_args);
                    },
                    .framework_dir => try create_module.framework_dirs.append(arena, it.only_arg),
                    .framework => try create_module.frameworks.put(arena, it.only_arg, .{}),
                    .nostdlibinc => create_module.want_native_include_dirs = false,
                    .strip => mod_opts.strip = true,
                    .exec_model => {
                        create_module.opts.wasi_exec_model = parseWasiExecModel(it.only_arg);
                    },
                    .sysroot => {
                        create_module.sysroot = it.only_arg;
                    },
                    .entry => {
                        entry = .{ .named = it.only_arg };
                    },
                    .force_undefined_symbol => {
                        try force_undefined_symbols.put(arena, it.only_arg, {});
                    },
                    .force_load_objc => force_load_objc = true,
                    .mingw_unicode_entry_point => mingw_unicode_entry_point = true,
                    .weak_library => try create_module.cli_link_inputs.append(arena, .{ .name_query = .{
                        .name = it.only_arg,
                        .query = .{
                            .needed = false,
                            .weak = true,
                            .preferred_mode = lib_preferred_mode,
                            .search_strategy = lib_search_strategy,
                            .allow_so_scripts = allow_so_scripts,
                        },
                    } }),
                    .weak_framework => try create_module.frameworks.put(arena, it.only_arg, .{ .weak = true }),
                    .headerpad_max_install_names => headerpad_max_install_names = true,
                    .compress_debug_sections => {
                        if (it.only_arg.len == 0) {
                            linker_compress_debug_sections = .zlib;
                        } else {
                            linker_compress_debug_sections = std.meta.stringToEnum(link.File.Lld.Elf.CompressDebugSections, it.only_arg) orelse {
                                fatal("expected [none|zlib|zstd] after --compress-debug-sections, found '{s}'", .{it.only_arg});
                            };
                        }
                    },
                    .install_name => {
                        install_name = it.only_arg;
                    },
                    .undefined => {
                        if (mem.eql(u8, "dynamic_lookup", it.only_arg)) {
                            linker_allow_shlib_undefined = true;
                        } else if (mem.eql(u8, "error", it.only_arg)) {
                            linker_allow_shlib_undefined = false;
                        } else {
                            fatal("unsupported -undefined option '{s}'", .{it.only_arg});
                        }
                    },
                    .rtlib => {
                        // Unlike Clang, we support `none` for explicitly omitting compiler-rt.
                        if (mem.eql(u8, "none", it.only_arg)) {
                            want_compiler_rt = false;
                        } else if (mem.eql(u8, "compiler-rt", it.only_arg) or
                            mem.eql(u8, "libgcc", it.only_arg))
                        {
                            want_compiler_rt = true;
                        } else {
                            // Note that we don't support `platform`.
                            fatal("unsupported -rtlib option '{s}'", .{it.only_arg});
                        }
                    },
                    .static => {
                        create_module.opts.link_mode = .static;
                        lib_preferred_mode = .static;
                        lib_search_strategy = .no_fallback;
                    },
                    .dynamic => {
                        create_module.opts.link_mode = .dynamic;
                        lib_preferred_mode = .dynamic;
                        lib_search_strategy = .mode_first;
                    },
                }
            }
            // Parse linker args.
            var linker_args_it = ArgsIterator{
                .args = linker_args.items,
            };
            while (linker_args_it.next()) |arg| {
                if (mem.eql(u8, arg, "-soname") or
                    mem.eql(u8, arg, "--soname"))
                {
                    const name = linker_args_it.nextOrFatal();
                    soname = .{ .yes = name };
                    // Use it as --name.
                    // Example: libsoundio.so.2
                    var prefix: usize = 0;
                    if (mem.startsWith(u8, name, "lib")) {
                        prefix = 3;
                    }
                    var end: usize = name.len;
                    if (mem.endsWith(u8, name, ".so")) {
                        end -= 3;
                    } else {
                        var found_digit = false;
                        while (end > 0 and std.ascii.isDigit(name[end - 1])) {
                            found_digit = true;
                            end -= 1;
                        }
                        if (found_digit and end > 0 and name[end - 1] == '.') {
                            end -= 1;
                        } else {
                            end = name.len;
                        }
                        if (mem.endsWith(u8, name[prefix..end], ".so")) {
                            end -= 3;
                        }
                    }
                    provided_name = name[prefix..end];
                } else if (mem.eql(u8, arg, "-rpath") or mem.eql(u8, arg, "--rpath") or mem.eql(u8, arg, "-R")) {
                    try create_module.rpath_list.append(arena, linker_args_it.nextOrFatal());
                } else if (mem.eql(u8, arg, "--subsystem")) {
                    subsystem = try parseSubSystem(linker_args_it.nextOrFatal());
                } else if (mem.eql(u8, arg, "-I") or
                    mem.eql(u8, arg, "--dynamic-linker") or
                    mem.eql(u8, arg, "-dynamic-linker"))
                {
                    create_module.dynamic_linker = linker_args_it.nextOrFatal();
                } else if (mem.eql(u8, arg, "-E") or
                    mem.eql(u8, arg, "--export-dynamic") or
                    mem.eql(u8, arg, "-export-dynamic"))
                {
                    create_module.opts.rdynamic = true;
                } else if (mem.eql(u8, arg, "-version-script") or mem.eql(u8, arg, "--version-script")) {
                    version_script = linker_args_it.nextOrFatal();
                } else if (mem.eql(u8, arg, "--undefined-version")) {
                    linker_allow_undefined_version = true;
                } else if (mem.eql(u8, arg, "--no-undefined-version")) {
                    linker_allow_undefined_version = false;
                } else if (mem.eql(u8, arg, "--enable-new-dtags")) {
                    linker_enable_new_dtags = true;
                } else if (mem.eql(u8, arg, "--disable-new-dtags")) {
                    linker_enable_new_dtags = false;
                } else if (mem.eql(u8, arg, "-O")) {
                    linker_optimization = linker_args_it.nextOrFatal();
                } else if (mem.startsWith(u8, arg, "-O")) {
                    linker_optimization = arg["-O".len..];
                } else if (mem.eql(u8, arg, "-pagezero_size")) {
                    const next_arg = linker_args_it.nextOrFatal();
                    pagezero_size = std.fmt.parseUnsigned(u64, eatIntPrefix(next_arg, 16), 16) catch |err| {
                        fatal("unable to parse pagezero size '{s}': {s}", .{ next_arg, @errorName(err) });
                    };
                } else if (mem.eql(u8, arg, "-headerpad")) {
                    const next_arg = linker_args_it.nextOrFatal();
                    headerpad_size = std.fmt.parseUnsigned(u32, eatIntPrefix(next_arg, 16), 16) catch |err| {
                        fatal("unable to parse  headerpad size '{s}': {s}", .{ next_arg, @errorName(err) });
                    };
                } else if (mem.eql(u8, arg, "-headerpad_max_install_names")) {
                    headerpad_max_install_names = true;
                } else if (mem.eql(u8, arg, "-dead_strip")) {
                    linker_gc_sections = true;
                } else if (mem.eql(u8, arg, "-dead_strip_dylibs")) {
                    dead_strip_dylibs = true;
                } else if (mem.eql(u8, arg, "-ObjC")) {
                    force_load_objc = true;
                } else if (mem.eql(u8, arg, "--no-undefined")) {
                    linker_z_defs = true;
                } else if (mem.eql(u8, arg, "--gc-sections")) {
                    linker_gc_sections = true;
                } else if (mem.eql(u8, arg, "--no-gc-sections")) {
                    linker_gc_sections = false;
                } else if (mem.eql(u8, arg, "--print-gc-sections")) {
                    linker_print_gc_sections = true;
                } else if (mem.eql(u8, arg, "--print-icf-sections")) {
                    linker_print_icf_sections = true;
                } else if (mem.eql(u8, arg, "--print-map")) {
                    linker_print_map = true;
                } else if (mem.eql(u8, arg, "--sort-section")) {
                    const arg1 = linker_args_it.nextOrFatal();
                    linker_sort_section = std.meta.stringToEnum(link.File.Lld.Elf.SortSection, arg1) orelse {
                        fatal("expected [name|alignment] after --sort-section, found '{s}'", .{arg1});
                    };
                } else if (mem.eql(u8, arg, "--allow-shlib-undefined") or
                    mem.eql(u8, arg, "-allow-shlib-undefined"))
                {
                    linker_allow_shlib_undefined = true;
                } else if (mem.eql(u8, arg, "--no-allow-shlib-undefined") or
                    mem.eql(u8, arg, "-no-allow-shlib-undefined"))
                {
                    linker_allow_shlib_undefined = false;
                } else if (mem.eql(u8, arg, "-Bsymbolic")) {
                    linker_bind_global_refs_locally = true;
                } else if (mem.eql(u8, arg, "--import-memory")) {
                    create_module.opts.import_memory = true;
                } else if (mem.eql(u8, arg, "--export-memory")) {
                    create_module.opts.export_memory = true;
                } else if (mem.eql(u8, arg, "--import-symbols")) {
                    linker_import_symbols = true;
                } else if (mem.eql(u8, arg, "--import-table")) {
                    linker_import_table = true;
                } else if (mem.eql(u8, arg, "--export-table")) {
                    linker_export_table = true;
                } else if (mem.eql(u8, arg, "--no-entry")) {
                    entry = .disabled;
                } else if (mem.eql(u8, arg, "--initial-memory")) {
                    const next_arg = linker_args_it.nextOrFatal();
                    linker_initial_memory = std.fmt.parseUnsigned(u32, next_arg, 10) catch |err| {
                        fatal("unable to parse initial memory size '{s}': {s}", .{ next_arg, @errorName(err) });
                    };
                } else if (mem.eql(u8, arg, "--max-memory")) {
                    const next_arg = linker_args_it.nextOrFatal();
                    linker_max_memory = std.fmt.parseUnsigned(u32, next_arg, 10) catch |err| {
                        fatal("unable to parse max memory size '{s}': {s}", .{ next_arg, @errorName(err) });
                    };
                } else if (mem.eql(u8, arg, "--shared-memory")) {
                    create_module.opts.shared_memory = true;
                } else if (mem.eql(u8, arg, "--global-base")) {
                    const next_arg = linker_args_it.nextOrFatal();
                    linker_global_base = std.fmt.parseUnsigned(u32, next_arg, 10) catch |err| {
                        fatal("unable to parse global base '{s}': {s}", .{ next_arg, @errorName(err) });
                    };
                } else if (mem.eql(u8, arg, "--export")) {
                    try linker_export_symbol_names.append(arena, linker_args_it.nextOrFatal());
                } else if (mem.eql(u8, arg, "--compress-debug-sections")) {
                    const arg1 = linker_args_it.nextOrFatal();
                    linker_compress_debug_sections = std.meta.stringToEnum(link.File.Lld.Elf.CompressDebugSections, arg1) orelse {
                        fatal("expected [none|zlib|zstd] after --compress-debug-sections, found '{s}'", .{arg1});
                    };
                } else if (mem.startsWith(u8, arg, "-z")) {
                    var z_arg = arg[2..];
                    if (z_arg.len == 0) {
                        z_arg = linker_args_it.nextOrFatal();
                    }
                    if (mem.eql(u8, z_arg, "nodelete")) {
                        linker_z_nodelete = true;
                    } else if (mem.eql(u8, z_arg, "notext")) {
                        linker_z_notext = true;
                    } else if (mem.eql(u8, z_arg, "defs")) {
                        linker_z_defs = true;
                    } else if (mem.eql(u8, z_arg, "undefs")) {
                        linker_z_defs = false;
                    } else if (mem.eql(u8, z_arg, "origin")) {
                        linker_z_origin = true;
                    } else if (mem.eql(u8, z_arg, "nocopyreloc")) {
                        linker_z_nocopyreloc = true;
                    } else if (mem.eql(u8, z_arg, "noexecstack")) {
                        // noexecstack is the default when linking with LLD
                    } else if (mem.eql(u8, z_arg, "now")) {
                        linker_z_now = true;
                    } else if (mem.eql(u8, z_arg, "lazy")) {
                        linker_z_now = false;
                    } else if (mem.eql(u8, z_arg, "relro")) {
                        linker_z_relro = true;
                    } else if (mem.eql(u8, z_arg, "norelro")) {
                        linker_z_relro = false;
                    } else if (mem.startsWith(u8, z_arg, "stack-size=")) {
                        stack_size = parseStackSize(z_arg["stack-size=".len..]);
                    } else if (mem.startsWith(u8, z_arg, "common-page-size=")) {
                        linker_z_common_page_size = parseIntSuffix(z_arg, "common-page-size=".len);
                    } else if (mem.startsWith(u8, z_arg, "max-page-size=")) {
                        linker_z_max_page_size = parseIntSuffix(z_arg, "max-page-size=".len);
                    } else {
                        fatal("unsupported linker extension flag: -z {s}", .{z_arg});
                    }
                } else if (mem.eql(u8, arg, "--major-image-version")) {
                    const major = linker_args_it.nextOrFatal();
                    version.major = std.fmt.parseUnsigned(u32, major, 10) catch |err| {
                        fatal("unable to parse major image version '{s}': {s}", .{ major, @errorName(err) });
                    };
                    have_version = true;
                } else if (mem.eql(u8, arg, "--minor-image-version")) {
                    const minor = linker_args_it.nextOrFatal();
                    version.minor = std.fmt.parseUnsigned(u32, minor, 10) catch |err| {
                        fatal("unable to parse minor image version '{s}': {s}", .{ minor, @errorName(err) });
                    };
                    have_version = true;
                } else if (mem.eql(u8, arg, "-e") or mem.eql(u8, arg, "--entry")) {
                    entry = .{ .named = linker_args_it.nextOrFatal() };
                } else if (mem.eql(u8, arg, "-u")) {
                    try force_undefined_symbols.put(arena, linker_args_it.nextOrFatal(), {});
                } else if (mem.eql(u8, arg, "-x") or mem.eql(u8, arg, "--discard-all")) {
                    discard_local_symbols = true;
                } else if (mem.eql(u8, arg, "--stack") or mem.eql(u8, arg, "-stack_size")) {
                    stack_size = parseStackSize(linker_args_it.nextOrFatal());
                } else if (mem.eql(u8, arg, "--image-base")) {
                    image_base = parseImageBase(linker_args_it.nextOrFatal());
                } else if (mem.eql(u8, arg, "--enable-auto-image-base") or
                    mem.eql(u8, arg, "--disable-auto-image-base"))
                {
                    // `--enable-auto-image-base` is a flag that binutils added in ~2000 for MinGW.
                    // It does a hash of the file and uses that as part of the image base value.
                    // Presumably the idea was to avoid DLLs needing to be relocated when loaded.
                    // This is practically irrelevant today as all PEs produced since Windows Vista
                    // have ASLR enabled by default anyway, and Windows 10+ has Mandatory ASLR which
                    // doesn't even care what the PE file wants and relocates it anyway.
                    //
                    // Unfortunately, Libtool hardcodes usage of this archaic flag when targeting
                    // MinGW, so to make `zig cc` for that use case work, accept and ignore the
                    // flag, and warn the user that it has no effect.
                    warn("auto-image-base options are unimplemented and ignored", .{});
                } else if (mem.eql(u8, arg, "-T") or mem.eql(u8, arg, "--script")) {
                    linker_script = linker_args_it.nextOrFatal();
                } else if (mem.eql(u8, arg, "--eh-frame-hdr")) {
                    link_eh_frame_hdr = true;
                } else if (mem.eql(u8, arg, "--no-eh-frame-hdr")) {
                    link_eh_frame_hdr = false;
                } else if (mem.eql(u8, arg, "--tsaware")) {
                    linker_tsaware = true;
                } else if (mem.eql(u8, arg, "--nxcompat")) {
                    linker_nxcompat = true;
                } else if (mem.eql(u8, arg, "--dynamicbase")) {
                    linker_dynamicbase = true;
                } else if (mem.eql(u8, arg, "--no-dynamicbase")) {
                    linker_dynamicbase = false;
                } else if (mem.eql(u8, arg, "--high-entropy-va")) {
                    // This option does not do anything.
                } else if (mem.eql(u8, arg, "--export-all-symbols")) {
                    create_module.opts.rdynamic = true;
                } else if (mem.eql(u8, arg, "--color-diagnostics") or
                    mem.eql(u8, arg, "--color-diagnostics=always"))
                {
                    color = .on;
                } else if (mem.eql(u8, arg, "--no-color-diagnostics") or
                    mem.eql(u8, arg, "--color-diagnostics=never"))
                {
                    color = .off;
                } else if (mem.eql(u8, arg, "-s") or mem.eql(u8, arg, "--strip-all") or
                    mem.eql(u8, arg, "-S") or mem.eql(u8, arg, "--strip-debug"))
                {
                    // -s, --strip-all             Strip all symbols
                    // -S, --strip-debug           Strip debugging symbols
                    mod_opts.strip = true;
                } else if (mem.eql(u8, arg, "--start-group") or
                    mem.eql(u8, arg, "--end-group"))
                {
                    // We don't need to care about these because these args are
                    // for resolving circular dependencies but our linker takes
                    // care of this without explicit args.
                } else if (mem.eql(u8, arg, "--major-os-version") or
                    mem.eql(u8, arg, "--minor-os-version"))
                {
                    // This option does not do anything.
                    _ = linker_args_it.nextOrFatal();
                } else if (mem.eql(u8, arg, "--major-subsystem-version")) {
                    const major = linker_args_it.nextOrFatal();
                    major_subsystem_version = std.fmt.parseUnsigned(u16, major, 10) catch |err| {
                        fatal("unable to parse major subsystem version '{s}': {s}", .{
                            major, @errorName(err),
                        });
                    };
                } else if (mem.eql(u8, arg, "--minor-subsystem-version")) {
                    const minor = linker_args_it.nextOrFatal();
                    minor_subsystem_version = std.fmt.parseUnsigned(u16, minor, 10) catch |err| {
                        fatal("unable to parse minor subsystem version '{s}': {s}", .{
                            minor, @errorName(err),
                        });
                    };
                } else if (mem.eql(u8, arg, "-framework")) {
                    try create_module.frameworks.put(arena, linker_args_it.nextOrFatal(), .{});
                } else if (mem.eql(u8, arg, "-weak_framework")) {
                    try create_module.frameworks.put(arena, linker_args_it.nextOrFatal(), .{ .weak = true });
                } else if (mem.eql(u8, arg, "-needed_framework")) {
                    try create_module.frameworks.put(arena, linker_args_it.nextOrFatal(), .{ .needed = true });
                } else if (mem.eql(u8, arg, "-needed_library")) {
                    try create_module.cli_link_inputs.append(arena, .{ .name_query = .{
                        .name = linker_args_it.nextOrFatal(),
                        .query = .{
                            .weak = false,
                            .needed = true,
                            .preferred_mode = lib_preferred_mode,
                            .search_strategy = lib_search_strategy,
                            .allow_so_scripts = allow_so_scripts,
                        },
                    } });
                } else if (mem.startsWith(u8, arg, "-weak-l")) {
                    try create_module.cli_link_inputs.append(arena, .{ .name_query = .{
                        .name = arg["-weak-l".len..],
                        .query = .{
                            .weak = true,
                            .needed = false,
                            .preferred_mode = lib_preferred_mode,
                            .search_strategy = lib_search_strategy,
                            .allow_so_scripts = allow_so_scripts,
                        },
                    } });
                } else if (mem.eql(u8, arg, "-weak_library")) {
                    try create_module.cli_link_inputs.append(arena, .{ .name_query = .{
                        .name = linker_args_it.nextOrFatal(),
                        .query = .{
                            .weak = true,
                            .needed = false,
                            .preferred_mode = lib_preferred_mode,
                            .search_strategy = lib_search_strategy,
                            .allow_so_scripts = allow_so_scripts,
                        },
                    } });
                } else if (mem.eql(u8, arg, "-compatibility_version")) {
                    const compat_version = linker_args_it.nextOrFatal();
                    compatibility_version = std.SemanticVersion.parse(compat_version) catch |err| {
                        fatal("unable to parse -compatibility_version '{s}': {s}", .{ compat_version, @errorName(err) });
                    };
                } else if (mem.eql(u8, arg, "-current_version")) {
                    const curr_version = linker_args_it.nextOrFatal();
                    version = std.SemanticVersion.parse(curr_version) catch |err| {
                        fatal("unable to parse -current_version '{s}': {s}", .{ curr_version, @errorName(err) });
                    };
                    have_version = true;
                } else if (mem.eql(u8, arg, "--out-implib") or
                    mem.eql(u8, arg, "-implib"))
                {
                    emit_implib = .{ .yes = linker_args_it.nextOrFatal() };
                    emit_implib_arg_provided = true;
                } else if (mem.eql(u8, arg, "-Brepro") or mem.eql(u8, arg, "/Brepro")) {
                    linker_repro = true;
                } else if (mem.eql(u8, arg, "-undefined")) {
                    const lookup_type = linker_args_it.nextOrFatal();
                    if (mem.eql(u8, "dynamic_lookup", lookup_type)) {
                        linker_allow_shlib_undefined = true;
                    } else if (mem.eql(u8, "error", lookup_type)) {
                        linker_allow_shlib_undefined = false;
                    } else {
                        fatal("unsupported -undefined option '{s}'", .{lookup_type});
                    }
                } else if (mem.eql(u8, arg, "-install_name")) {
                    install_name = linker_args_it.nextOrFatal();
                } else if (mem.eql(u8, arg, "-force_load")) {
                    try create_module.cli_link_inputs.append(arena, .{ .path_query = .{
                        .path = Path.initCwd(linker_args_it.nextOrFatal()),
                        .query = .{
                            .must_link = true,
                            .preferred_mode = .static,
                            .search_strategy = .no_fallback,
                        },
                    } });
                } else if (mem.eql(u8, arg, "-hash-style") or
                    mem.eql(u8, arg, "--hash-style"))
                {
                    const next_arg = linker_args_it.nextOrFatal();
                    hash_style = std.meta.stringToEnum(link.File.Lld.Elf.HashStyle, next_arg) orelse {
                        fatal("expected [sysv|gnu|both] after --hash-style, found '{s}'", .{
                            next_arg,
                        });
                    };
                } else if (mem.eql(u8, arg, "-wrap")) {
                    const next_arg = linker_args_it.nextOrFatal();
                    try symbol_wrap_set.put(arena, next_arg, {});
                } else if (mem.startsWith(u8, arg, "/subsystem:")) {
                    var split_it = mem.splitBackwardsScalar(u8, arg, ':');
                    subsystem = try parseSubSystem(split_it.first());
                } else if (mem.startsWith(u8, arg, "/implib:")) {
                    var split_it = mem.splitBackwardsScalar(u8, arg, ':');
                    emit_implib = .{ .yes = split_it.first() };
                    emit_implib_arg_provided = true;
                } else if (mem.startsWith(u8, arg, "/pdb:")) {
                    var split_it = mem.splitBackwardsScalar(u8, arg, ':');
                    pdb_out_path = split_it.first();
                } else if (mem.startsWith(u8, arg, "/version:")) {
                    var split_it = mem.splitBackwardsScalar(u8, arg, ':');
                    const version_arg = split_it.first();
                    version = std.SemanticVersion.parse(version_arg) catch |err| {
                        fatal("unable to parse /version '{s}': {s}", .{ arg, @errorName(err) });
                    };
                    have_version = true;
                } else if (mem.eql(u8, arg, "-V")) {
                    warn("ignoring request for supported emulations: unimplemented", .{});
                } else if (mem.eql(u8, arg, "-v")) {
                    try fs.File.stdout().writeAll("zig ld " ++ build_options.version ++ "\n");
                } else if (mem.eql(u8, arg, "--version")) {
                    try fs.File.stdout().writeAll("zig ld " ++ build_options.version ++ "\n");
                    process.exit(0);
                } else {
                    fatal("unsupported linker arg: {s}", .{arg});
                }
            }

            // Parse preprocessor args.
            var preprocessor_args_it = ArgsIterator{
                .args = preprocessor_args.items,
            };
            while (preprocessor_args_it.next()) |arg| {
                if (mem.eql(u8, arg, "-MD") or mem.eql(u8, arg, "-MMD") or mem.eql(u8, arg, "-MT")) {
                    disable_c_depfile = true;
                    const cc_arg = try std.fmt.allocPrint(arena, "-Wp,{s},{s}", .{ arg, preprocessor_args_it.nextOrFatal() });
                    try cc_argv.append(arena, cc_arg);
                } else {
                    fatal("unsupported preprocessor arg: {s}", .{arg});
                }
            }

            if (mod_opts.sanitize_c) |wsc| {
                if (wsc != .off and mod_opts.optimize_mode == .ReleaseFast) {
                    mod_opts.optimize_mode = .ReleaseSafe;
                }
            }

            // precompiled header syntax: "zig cc -x c-header test.h -o test.pch"
            const emit_pch = ((file_ext == .h or file_ext == .hpp or file_ext == .hm or file_ext == .hmm) and c_out_mode == null);
            if (emit_pch)
                c_out_mode = .preprocessor;

            switch (c_out_mode orelse .link) {
                .link => {
                    create_module.opts.output_mode = if (is_shared_lib) .Lib else .Exe;
                    if (emit_bin != .no) {
                        emit_bin = if (out_path) |p| .{ .yes = p } else .yes_a_out;
                    }
                    if (emit_llvm) {
                        fatal("-emit-llvm cannot be used when linking", .{});
                    }
                },
                .object => {
                    create_module.opts.output_mode = .Obj;
                    if (emit_llvm) {
                        emit_bin = .no;
                        if (out_path) |p| {
                            emit_llvm_bc = .{ .yes = p };
                        } else {
                            emit_llvm_bc = .yes_default_path;
                        }
                    } else {
                        if (out_path) |p| {
                            emit_bin = .{ .yes = p };
                        } else {
                            emit_bin = .yes_default_path;
                        }
                    }
                },
                .assembly => {
                    create_module.opts.output_mode = .Obj;
                    emit_bin = .no;
                    if (emit_llvm) {
                        if (out_path) |p| {
                            emit_llvm_ir = .{ .yes = p };
                        } else {
                            emit_llvm_ir = .yes_default_path;
                        }
                    } else {
                        if (out_path) |p| {
                            emit_asm = .{ .yes = p };
                        } else {
                            emit_asm = .yes_default_path;
                        }
                    }
                },
                .preprocessor => {
                    create_module.opts.output_mode = .Obj;
                    // An error message is generated when there is more than 1 C source file.
                    if (create_module.c_source_files.items.len != 1) {
                        // For example `zig cc` and no args should print the "no input files" message.
                        return process.exit(try clangMain(arena, all_args));
                    }
                    if (emit_pch) {
                        emit_bin = if (out_path) |p| .{ .yes = p } else .yes_default_path;
                        clang_preprocessor_mode = .pch;
                    } else {
                        // If the output path is "-" (stdout), then we need to emit the preprocessed output to stdout
                        // like "clang -E main.c -o -" does.
                        if (out_path != null and !mem.eql(u8, out_path.?, "-")) {
                            emit_bin = .{ .yes = out_path.? };
                            clang_preprocessor_mode = .yes;
                        } else {
                            emit_bin = .no;
                            clang_preprocessor_mode = .stdout;
                        }
                    }
                },
            }
            if (create_module.c_source_files.items.len == 0 and
                !anyObjectLinkInputs(create_module.cli_link_inputs.items) and
                root_src_file == null)
            {
                // For example `zig cc` and no args should print the "no input files" message.
                // There could be other reasons to punt to clang, for example, --help.
                return process.exit(try clangMain(arena, all_args));
            }
        },
    }

    if (arg_mode == .zig_test_obj and !test_no_exec and listen == .none) {
        fatal("test-obj requires --test-no-exec", .{});
    }

    if (time_report and listen == .none) {
        fatal("--time-report requires --listen", .{});
    }

    if (arg_mode == .translate_c and create_module.c_source_files.items.len != 1) {
        fatal("translate-c expects exactly 1 source file (found {d})", .{create_module.c_source_files.items.len});
    }

    if (show_builtin and root_src_file == null) {
        // Without this, there will be no main module created and no zig
        // compilation unit, and therefore also no builtin.zig contents
        // created.
        root_src_file = "builtin.zig";
    }

    implicit_root_mod: {
        const src_path = b: {
            if (root_src_file) |src_path| {
                if (create_module.modules.count() != 0) {
                    fatal("main module provided both by '-M{s}={s}{c}{s}' and by positional argument '{s}'", .{
                        create_module.modules.keys()[0],
                        create_module.modules.values()[0].root_path,
                        fs.path.sep,
                        create_module.modules.values()[0].root_src_path,
                        src_path,
                    });
                }
                create_module.opts.have_zcu = true;
                break :b src_path;
            }

            if (create_module.modules.count() != 0)
                break :implicit_root_mod;

            if (create_module.c_source_files.items.len >= 1)
                break :b create_module.c_source_files.items[0].src_path;

            for (create_module.cli_link_inputs.items) |unresolved_link_input| switch (unresolved_link_input) {
                // Intentionally includes dynamic libraries provided by file path.
                .path_query => |pq| break :b pq.path.sub_path,
                else => continue,
            };

            if (emit_bin == .yes)
                break :b emit_bin.yes;

            if (create_module.rc_source_files.items.len >= 1)
                break :b create_module.rc_source_files.items[0].src_path;

            if (arg_mode == .run)
                fatal("`zig run` expects at least one positional argument", .{});

            fatal("expected a positional argument, -femit-bin=[path], --show-builtin, or --name [name]", .{});

            break :implicit_root_mod;
        };

        // See duplicate logic: ModCreationGlobalFlags
        if (mod_opts.single_threaded == false)
            create_module.opts.any_non_single_threaded = true;
        if (mod_opts.sanitize_thread == true)
            create_module.opts.any_sanitize_thread = true;
        if (mod_opts.sanitize_c) |sc| switch (sc) {
            .off => {},
            .trap => if (create_module.opts.any_sanitize_c == .off) {
                create_module.opts.any_sanitize_c = .trap;
            },
            .full => create_module.opts.any_sanitize_c = .full,
        };
        if (mod_opts.fuzz == true)
            create_module.opts.any_fuzz = true;
        if (mod_opts.unwind_tables) |uwt| switch (uwt) {
            .none => {},
            .sync, .async => create_module.opts.any_unwind_tables = true,
        };
        if (mod_opts.strip == false)
            create_module.opts.any_non_stripped = true;
        if (mod_opts.error_tracing == true)
            create_module.opts.any_error_tracing = true;

        const name = switch (arg_mode) {
            .zig_test => "test",
            .build, .cc, .cpp, .translate_c, .zig_test_obj, .run => fs.path.stem(fs.path.basename(src_path)),
        };

        try create_module.modules.put(arena, name, .{
            .root_path = fs.path.dirname(src_path) orelse ".",
            .root_src_path = fs.path.basename(src_path),
            .cc_argv = try cc_argv.toOwnedSlice(arena),
            .inherited = mod_opts,
            .target_arch_os_abi = target_arch_os_abi,
            .target_mcpu = target_mcpu,
            .deps = try deps.toOwnedSlice(arena),
            .resolved = null,
            .c_source_files_start = c_source_files_owner_index,
            .c_source_files_end = create_module.c_source_files.items.len,
            .rc_source_files_start = rc_source_files_owner_index,
            .rc_source_files_end = create_module.rc_source_files.items.len,
        });
        cssan.reset();
        mod_opts = .{};
        target_arch_os_abi = null;
        target_mcpu = null;
        c_source_files_owner_index = create_module.c_source_files.items.len;
        rc_source_files_owner_index = create_module.rc_source_files.items.len;
    }

    if (!create_module.opts.have_zcu and create_module.opts.is_test) {
        fatal("`zig test` expects a zig source file argument", .{});
    }

    if (c_source_files_owner_index != create_module.c_source_files.items.len) {
        fatal("C source file '{s}' has no parent module", .{
            create_module.c_source_files.items[c_source_files_owner_index].src_path,
        });
    }

    if (rc_source_files_owner_index != create_module.rc_source_files.items.len) {
        fatal("resource file '{s}' has no parent module", .{
            create_module.rc_source_files.items[rc_source_files_owner_index].src_path,
        });
    }

    const self_exe_path = switch (native_os) {
        .wasi => {},
        else => fs.selfExePathAlloc(arena) catch |err| {
            fatal("unable to find zig self exe path: {s}", .{@errorName(err)});
        },
    };

    // This `init` calls `fatal` on error.
    var dirs: Compilation.Directories = .init(
        arena,
        override_lib_dir,
        override_global_cache_dir,
        s: {
            if (override_local_cache_dir) |p| break :s .{ .override = p };
            break :s switch (arg_mode) {
                .run => .global,
                else => .search,
            };
        },
        if (native_os == .wasi) wasi_preopens,
        self_exe_path,
    );
    defer dirs.deinit();

    if (linker_optimization) |o| {
        warn("ignoring deprecated linker optimization setting '{s}'", .{o});
    }

    create_module.dirs = dirs;
    create_module.opts.emit_llvm_ir = emit_llvm_ir != .no;
    create_module.opts.emit_llvm_bc = emit_llvm_bc != .no;
    create_module.opts.emit_bin = emit_bin != .no;
    create_module.opts.any_c_source_files = create_module.c_source_files.items.len != 0;

    const main_mod = try createModule(gpa, arena, &create_module, 0, null, color);
    for (create_module.modules.keys(), create_module.modules.values()) |key, cli_mod| {
        if (cli_mod.resolved == null)
            fatal("module '{s}' declared but not used", .{key});
    }

    // When you're testing std, the main module is std, and we need to avoid duplicating the module.
    const main_mod_is_std = main_mod.root.root == .zig_lib and
        mem.eql(u8, main_mod.root.sub_path, "std") and
        mem.eql(u8, main_mod.root_src_path, "std.zig");

    const std_mod = m: {
        if (main_mod_is_std) break :m main_mod;
        if (create_module.modules.get("std")) |cli_mod| break :m cli_mod.resolved.?;
        break :m null;
    };

    const root_mod = switch (arg_mode) {
        .zig_test, .zig_test_obj => root_mod: {
            const test_mod = if (test_runner_path) |test_runner| test_mod: {
                const test_mod = try Package.Module.create(arena, .{
                    .paths = .{
                        .root = try .fromUnresolved(arena, dirs, &.{fs.path.dirname(test_runner) orelse "."}),
                        .root_src_path = fs.path.basename(test_runner),
                    },
                    .fully_qualified_name = "root",
                    .cc_argv = &.{},
                    .inherited = .{},
                    .global = create_module.resolved_options,
                    .parent = main_mod,
                });
                test_mod.deps = try main_mod.deps.clone(arena);
                break :test_mod test_mod;
            } else try Package.Module.create(arena, .{
                .paths = .{
                    .root = try .fromRoot(arena, dirs, .zig_lib, "compiler"),
                    .root_src_path = "test_runner.zig",
                },
                .fully_qualified_name = "root",
                .cc_argv = &.{},
                .inherited = .{},
                .global = create_module.resolved_options,
                .parent = main_mod,
            });

            break :root_mod test_mod;
        },
        else => main_mod,
    };

    const target = &main_mod.resolved_target.result;

    if (target.cpu.arch == .arc or target.cpu.arch.isNvptx()) {
        if (emit_bin != .no and create_module.resolved_options.use_llvm) {
            fatal("cannot emit {s} binary with the LLVM backend; only '-femit-asm' is supported", .{
                @tagName(target.cpu.arch),
            });
        }
    }

    if (target.os.tag == .windows and major_subsystem_version == null and minor_subsystem_version == null) {
        major_subsystem_version, minor_subsystem_version = switch (target.os.version_range.windows.min) {
            .nt4 => .{ 4, 0 },
            .win2k => .{ 5, 0 },
            .xp => if (target.cpu.arch == .x86_64) .{ 5, 2 } else .{ 5, 1 },
            .ws2003 => .{ 5, 2 },
            else => .{ null, null },
        };
    }

    if (target.ofmt != .coff) {
        if (manifest_file != null) {
            fatal("manifest file is not allowed unless the target object format is coff (Windows/UEFI)", .{});
        }
        if (create_module.rc_source_files.items.len != 0) {
            fatal("rc files are not allowed unless the target object format is coff (Windows/UEFI)", .{});
        }
        if (contains_res_file) {
            fatal("res files are not allowed unless the target object format is coff (Windows/UEFI)", .{});
        }
    }

    var resolved_frameworks = std.ArrayList(Compilation.Framework).init(arena);

    if (create_module.frameworks.keys().len > 0) {
        var test_path = std.ArrayList(u8).init(gpa);
        defer test_path.deinit();

        var checked_paths = std.ArrayList(u8).init(gpa);
        defer checked_paths.deinit();

        var failed_frameworks = std.ArrayList(struct {
            name: []const u8,
            checked_paths: []const u8,
        }).init(arena);

        framework: for (create_module.frameworks.keys(), create_module.frameworks.values()) |framework_name, info| {
            checked_paths.clearRetainingCapacity();

            for (create_module.framework_dirs.items) |framework_dir_path| {
                if (try accessFrameworkPath(
                    &test_path,
                    &checked_paths,
                    framework_dir_path,
                    framework_name,
                )) {
                    const path = Path.initCwd(try arena.dupe(u8, test_path.items));
                    try resolved_frameworks.append(.{
                        .needed = info.needed,
                        .weak = info.weak,
                        .path = path,
                    });
                    continue :framework;
                }
            }

            try failed_frameworks.append(.{
                .name = framework_name,
                .checked_paths = try arena.dupe(u8, checked_paths.items),
            });
        }

        if (failed_frameworks.items.len > 0) {
            for (failed_frameworks.items) |f| {
                const searched_paths = if (f.checked_paths.len == 0) " none" else f.checked_paths;
                std.log.err("unable to find framework '{s}'. searched paths: {s}", .{
                    f.name, searched_paths,
                });
            }
            process.exit(1);
        }
    }
    // After this point, resolved_frameworks is used instead of frameworks.

    if (create_module.resolved_options.output_mode == .Obj and target.ofmt == .coff) {
        const total_obj_count = create_module.c_source_files.items.len +
            @intFromBool(root_src_file != null) +
            create_module.rc_source_files.items.len +
            link.countObjectInputs(create_module.link_inputs.items);
        if (total_obj_count > 1) {
            fatal("{s} does not support linking multiple objects into one", .{@tagName(target.ofmt)});
        }
    }

    var cleanup_emit_bin_dir: ?fs.Dir = null;
    defer if (cleanup_emit_bin_dir) |*dir| dir.close();

    // For `zig run` and `zig test`, we don't want to put the binary in the cwd by default. So, if
    // the binary is requested with no explicit path (as is the default), we emit to the cache.
    const output_to_cache: ?Emit.OutputToCacheReason = switch (listen) {
        .stdio, .ip4 => .listen,
        .none => if (arg_mode == .run and emit_bin == .yes_default_path)
            .@"zig run"
        else if (arg_mode == .zig_test and emit_bin == .yes_default_path)
            .@"zig test"
        else
            null,
    };
    const optional_version = if (have_version) version else null;

    const root_name = if (provided_name) |n| n else main_mod.fully_qualified_name;

    const resolved_soname: ?[]const u8 = switch (soname) {
        .yes => |explicit| explicit,
        .no => null,
        .yes_default_value => switch (target.ofmt) {
            .elf => if (have_version)
                try std.fmt.allocPrint(arena, "lib{s}.so.{d}", .{ root_name, version.major })
            else
                try std.fmt.allocPrint(arena, "lib{s}.so", .{root_name}),
            else => null,
        },
    };

    const emit_bin_resolved: Compilation.CreateOptions.Emit = switch (emit_bin) {
        .no => .no,
        .yes_default_path => emit: {
            if (output_to_cache != null) break :emit .yes_cache;
            const name = switch (clang_preprocessor_mode) {
                .pch => try std.fmt.allocPrint(arena, "{s}.pch", .{root_name}),
                else => try std.zig.binNameAlloc(arena, .{
                    .root_name = root_name,
                    .target = target,
                    .output_mode = create_module.resolved_options.output_mode,
                    .link_mode = create_module.resolved_options.link_mode,
                    .version = optional_version,
                }),
            };
            break :emit .{ .yes_path = name };
        },
        .yes => |path| if (output_to_cache != null) {
            assert(output_to_cache == .listen); // there was an explicit bin path
            fatal("--listen incompatible with explicit output path '{s}'", .{path});
        } else emit: {
            // If there's a dirname, check that dir exists. This will give a more descriptive error than `Compilation` otherwise would.
            if (fs.path.dirname(path)) |dir_path| {
                var dir = fs.cwd().openDir(dir_path, .{}) catch |err| {
                    fatal("unable to open output directory '{s}': {s}", .{ dir_path, @errorName(err) });
                };
                dir.close();
            }
            break :emit .{ .yes_path = path };
        },
        .yes_a_out => emit: {
            assert(output_to_cache == null);
            break :emit .{ .yes_path = switch (target.ofmt) {
                .coff => "a.exe",
                else => "a.out",
            } };
        },
    };

    const default_h_basename = try std.fmt.allocPrint(arena, "{s}.h", .{root_name});
    const emit_h_resolved = emit_h.resolve(default_h_basename, output_to_cache);

    const default_asm_basename = try std.fmt.allocPrint(arena, "{s}.s", .{root_name});
    const emit_asm_resolved = emit_asm.resolve(default_asm_basename, output_to_cache);

    const default_llvm_ir_basename = try std.fmt.allocPrint(arena, "{s}.ll", .{root_name});
    const emit_llvm_ir_resolved = emit_llvm_ir.resolve(default_llvm_ir_basename, output_to_cache);

    const default_llvm_bc_basename = try std.fmt.allocPrint(arena, "{s}.bc", .{root_name});
    const emit_llvm_bc_resolved = emit_llvm_bc.resolve(default_llvm_bc_basename, output_to_cache);

    const emit_docs_resolved = emit_docs.resolve("docs", output_to_cache);

    const is_exe_or_dyn_lib = switch (create_module.resolved_options.output_mode) {
        .Obj => false,
        .Lib => create_module.resolved_options.link_mode == .dynamic,
        .Exe => true,
    };
    // Note that cmake when targeting Windows will try to execute
    // zig cc to make an executable and output an implib too.
    const implib_eligible = is_exe_or_dyn_lib and
        emit_bin_resolved != .no and target.os.tag == .windows;
    if (!implib_eligible) {
        if (!emit_implib_arg_provided) {
            emit_implib = .no;
        } else if (emit_implib != .no) {
            fatal("the argument -femit-implib is allowed only when building a Windows DLL", .{});
        }
    }
    const default_implib_basename = try std.fmt.allocPrint(arena, "{s}.lib", .{root_name});
    const emit_implib_resolved: Compilation.CreateOptions.Emit = switch (emit_implib) {
        .no => .no,
        .yes => emit_implib.resolve(default_implib_basename, output_to_cache),
        .yes_default_path => emit: {
            if (output_to_cache != null) break :emit .yes_cache;
            const p = try fs.path.join(arena, &.{
                fs.path.dirname(emit_bin_resolved.yes_path) orelse ".",
                default_implib_basename,
            });
            break :emit .{ .yes_path = p };
        },
    };

    var thread_pool: ThreadPool = undefined;
    try thread_pool.init(.{
        .allocator = gpa,
        .n_jobs = @min(@max(n_jobs orelse std.Thread.getCpuCount() catch 1, 1), std.math.maxInt(Zcu.PerThread.IdBacking)),
        .track_ids = true,
        .stack_size = thread_stack_size,
    });
    defer thread_pool.deinit();

    for (create_module.c_source_files.items) |*src| {
        dev.check(.c_compiler);
        if (!mem.eql(u8, src.src_path, "-")) continue;

        const ext = src.ext orelse
            fatal("-E or -x is required when reading from a non-regular file", .{});

        // "-" is stdin. Dump it to a real file.
        const sep = fs.path.sep_str;
        const dump_path = try std.fmt.allocPrint(arena, "tmp" ++ sep ++ "{x}-dump-stdin{s}", .{
            std.crypto.random.int(u64), ext.canonicalName(target),
        });
        try dirs.local_cache.handle.makePath("tmp");

        // Note that in one of the happy paths, execve() is used to switch to
        // clang in which case any cleanup logic that exists for this temporary
        // file will not run and this temp file will be leaked. The filename
        // will be a hash of its contents — so multiple invocations of
        // `zig cc -` will result in the same temp file name.
        var f = try dirs.local_cache.handle.createFile(dump_path, .{});
        defer f.close();

        // Re-using the hasher from Cache, since the functional requirements
        // for the hashing algorithm here and in the cache are the same.
        // We are providing our own cache key, because this file has nothing
        // to do with the cache manifest.
        var file_writer = f.writer(&.{});
        var buffer: [1000]u8 = undefined;
        var hasher = file_writer.interface.hashed(Cache.Hasher.init("0123456789abcdef"), &buffer);
        var stdin_reader = fs.File.stdin().readerStreaming(&.{});
        _ = hasher.writer.sendFileAll(&stdin_reader, .unlimited) catch |err| switch (err) {
            error.WriteFailed => fatal("failed to write {s}: {t}", .{ dump_path, file_writer.err.? }),
            else => fatal("failed to pipe stdin to {s}: {t}", .{ dump_path, err }),
        };
        try hasher.writer.flush();

        const bin_digest: Cache.BinDigest = hasher.hasher.finalResult();

        const sub_path = try std.fmt.allocPrint(arena, "tmp" ++ sep ++ "{x}-stdin{s}", .{
            &bin_digest, ext.canonicalName(target),
        });
        try dirs.local_cache.handle.rename(dump_path, sub_path);

        // Convert `sub_path` to be relative to current working directory.
        src.src_path = try dirs.local_cache.join(arena, &.{sub_path});
    }

    if (build_options.have_llvm and emit_asm_resolved != .no) {
        // LLVM has no way to set this non-globally.
        const argv = [_][*:0]const u8{ "zig (LLVM option parsing)", "--x86-asm-syntax=intel" };
        @import("codegen/llvm/bindings.zig").ParseCommandLineOptions(argv.len, &argv);
    }

    const clang_passthrough_mode = switch (arg_mode) {
        .cc, .cpp, .translate_c => true,
        else => false,
    };

    const incremental = opt_incremental orelse false;
    if (debug_incremental and !incremental) {
        fatal("--debug-incremental requires -fincremental", .{});
    }

    const cache_mode: Compilation.CacheMode = b: {
        // Once incremental compilation is the default, we'll want some smarter logic here,
        // considering things like the backend in use and whether there's a ZCU.
        if (output_to_cache == null) break :b .none;
        if (incremental) break :b .incremental;
        break :b .whole;
    };

    process.raiseFileDescriptorLimit();

    var file_system_inputs: std.ArrayListUnmanaged(u8) = .empty;
    defer file_system_inputs.deinit(gpa);

    const comp = Compilation.create(gpa, arena, .{
        .dirs = dirs,
        .thread_pool = &thread_pool,
        .self_exe_path = switch (native_os) {
            .wasi => null,
            else => self_exe_path,
        },
        .config = create_module.resolved_options,
        .root_name = root_name,
        .sysroot = create_module.sysroot,
        .main_mod = main_mod,
        .root_mod = root_mod,
        .std_mod = std_mod,
        .emit_bin = emit_bin_resolved,
        .emit_h = emit_h_resolved,
        .emit_asm = emit_asm_resolved,
        .emit_llvm_ir = emit_llvm_ir_resolved,
        .emit_llvm_bc = emit_llvm_bc_resolved,
        .emit_docs = emit_docs_resolved,
        .emit_implib = emit_implib_resolved,
        .lib_directories = create_module.lib_directories.items,
        .rpath_list = create_module.rpath_list.items,
        .symbol_wrap_set = symbol_wrap_set,
        .c_source_files = create_module.c_source_files.items,
        .rc_source_files = create_module.rc_source_files.items,
        .manifest_file = manifest_file,
        .rc_includes = rc_includes,
        .mingw_unicode_entry_point = mingw_unicode_entry_point,
        .link_inputs = create_module.link_inputs.items,
        .framework_dirs = create_module.framework_dirs.items,
        .frameworks = resolved_frameworks.items,
        .windows_lib_names = create_module.windows_libs.keys(),
        .want_compiler_rt = want_compiler_rt,
        .want_ubsan_rt = want_ubsan_rt,
        .hash_style = hash_style,
        .linker_script = linker_script,
        .version_script = version_script,
        .linker_allow_undefined_version = linker_allow_undefined_version,
        .linker_enable_new_dtags = linker_enable_new_dtags,
        .disable_c_depfile = disable_c_depfile,
        .soname = resolved_soname,
        .linker_sort_section = linker_sort_section,
        .linker_gc_sections = linker_gc_sections,
        .linker_repro = linker_repro,
        .linker_allow_shlib_undefined = linker_allow_shlib_undefined,
        .linker_bind_global_refs_locally = linker_bind_global_refs_locally,
        .linker_import_symbols = linker_import_symbols,
        .linker_import_table = linker_import_table,
        .linker_export_table = linker_export_table,
        .linker_initial_memory = linker_initial_memory,
        .linker_max_memory = linker_max_memory,
        .linker_print_gc_sections = linker_print_gc_sections,
        .linker_print_icf_sections = linker_print_icf_sections,
        .linker_print_map = linker_print_map,
        .llvm_opt_bisect_limit = llvm_opt_bisect_limit,
        .linker_global_base = linker_global_base,
        .linker_export_symbol_names = linker_export_symbol_names.items,
        .linker_z_nocopyreloc = linker_z_nocopyreloc,
        .linker_z_nodelete = linker_z_nodelete,
        .linker_z_notext = linker_z_notext,
        .linker_z_defs = linker_z_defs,
        .linker_z_origin = linker_z_origin,
        .linker_z_now = linker_z_now,
        .linker_z_relro = linker_z_relro,
        .linker_z_common_page_size = linker_z_common_page_size,
        .linker_z_max_page_size = linker_z_max_page_size,
        .linker_tsaware = linker_tsaware,
        .linker_nxcompat = linker_nxcompat,
        .linker_dynamicbase = linker_dynamicbase,
        .linker_compress_debug_sections = linker_compress_debug_sections,
        .linker_module_definition_file = linker_module_definition_file,
        .major_subsystem_version = major_subsystem_version,
        .minor_subsystem_version = minor_subsystem_version,
        .link_eh_frame_hdr = link_eh_frame_hdr,
        .link_emit_relocs = link_emit_relocs,
        .entry = entry,
        .force_undefined_symbols = force_undefined_symbols,
        .stack_size = stack_size,
        .image_base = image_base,
        .function_sections = function_sections,
        .data_sections = data_sections,
        .clang_passthrough_mode = clang_passthrough_mode,
        .clang_preprocessor_mode = clang_preprocessor_mode,
        .version = optional_version,
        .compatibility_version = compatibility_version,
        .libc_installation = if (create_module.libc_installation) |*lci| lci else null,
        .verbose_cc = verbose_cc,
        .verbose_link = verbose_link,
        .verbose_air = verbose_air,
        .verbose_intern_pool = verbose_intern_pool,
        .verbose_generic_instances = verbose_generic_instances,
        .verbose_llvm_ir = verbose_llvm_ir,
        .verbose_llvm_bc = verbose_llvm_bc,
        .verbose_cimport = verbose_cimport,
        .verbose_llvm_cpu_features = verbose_llvm_cpu_features,
        .time_report = time_report,
        .stack_report = stack_report,
        .build_id = build_id,
        .test_filters = test_filters.items,
        .test_name_prefix = test_name_prefix,
        .test_runner_path = test_runner_path,
        .cache_mode = cache_mode,
        .subsystem = subsystem,
        .debug_compile_errors = debug_compile_errors,
        .debug_incremental = debug_incremental,
        .incremental = incremental,
        .enable_link_snapshots = enable_link_snapshots,
        .install_name = install_name,
        .entitlements = entitlements,
        .pagezero_size = pagezero_size,
        .headerpad_size = headerpad_size,
        .headerpad_max_install_names = headerpad_max_install_names,
        .dead_strip_dylibs = dead_strip_dylibs,
        .force_load_objc = force_load_objc,
        .discard_local_symbols = discard_local_symbols,
        .reference_trace = reference_trace,
        .pdb_out_path = pdb_out_path,
        .error_limit = error_limit,
        .native_system_include_paths = create_module.native_system_include_paths,
        // Any leftover C compilation args (such as -I) apply globally rather
        // than to any particular module. This feature can greatly reduce CLI
        // noise when --search-prefix and -M are combined.
        .global_cc_argv = try cc_argv.toOwnedSlice(arena),
        .file_system_inputs = &file_system_inputs,
        .debug_compiler_runtime_libs = debug_compiler_runtime_libs,
    }) catch |err| switch (err) {
        error.LibCUnavailable => {
            const triple_name = try target.zigTriple(arena);
            std.log.err("unable to find or provide libc for target '{s}'", .{triple_name});

            for (std.zig.target.available_libcs) |t| {
                if (t.arch == target.cpu.arch and t.os == target.os.tag) {
                    // If there's a `glibc_min`, there's also an `os_ver`.
                    if (t.glibc_min) |glibc_min| {
                        std.log.info("zig can provide libc for related target {s}-{s}.{f}-{s}.{d}.{d}", .{
                            @tagName(t.arch),
                            @tagName(t.os),
                            t.os_ver.?,
                            @tagName(t.abi),
                            glibc_min.major,
                            glibc_min.minor,
                        });
                    } else if (t.os_ver) |os_ver| {
                        std.log.info("zig can provide libc for related target {s}-{s}.{f}-{s}", .{
                            @tagName(t.arch),
                            @tagName(t.os),
                            os_ver,
                            @tagName(t.abi),
                        });
                    } else {
                        std.log.info("zig can provide libc for related target {s}-{s}-{s}", .{
                            @tagName(t.arch),
                            @tagName(t.os),
                            @tagName(t.abi),
                        });
                    }
                }
            }
            process.exit(1);
        },
        error.ExportTableAndImportTableConflict => {
            fatal("--import-table and --export-table may not be used together", .{});
        },
        error.IllegalZigImport => {
            fatal("this compiler implementation does not support importing the root source file of a provided module", .{});
        },
        else => fatal("unable to create compilation: {s}", .{@errorName(err)}),
    };
    var comp_destroyed = false;
    defer if (!comp_destroyed) comp.destroy();

    if (show_builtin) {
        const builtin_opts = comp.root_mod.getBuiltinOptions(comp.config);
        const source = try builtin_opts.generate(arena);
        return fs.File.stdout().writeAll(source);
    }
    switch (listen) {
        .none => {},
        .stdio => {
            var stdin_reader = fs.File.stdin().reader(&stdin_buffer);
            var stdout_writer = fs.File.stdout().writer(&stdout_buffer);
            try serve(
                comp,
                &stdin_reader.interface,
                &stdout_writer.interface,
                test_exec_args.items,
                self_exe_path,
                arg_mode,
                all_args,
                runtime_args_start,
            );
            return cleanExit();
        },
        .ip4 => |ip4_addr| {
            const addr: std.net.Address = .{ .in = ip4_addr };

            var server = try addr.listen(.{
                .reuse_address = true,
            });
            defer server.deinit();

            const conn = try server.accept();
            defer conn.stream.close();

            var input = conn.stream.reader(&stdin_buffer);
            var output = conn.stream.writer(&stdout_buffer);

            try serve(
                comp,
                input.interface(),
                &output.interface,
                test_exec_args.items,
                self_exe_path,
                arg_mode,
                all_args,
                runtime_args_start,
            );
            return cleanExit();
        },
    }

    {
        const root_prog_node = std.Progress.start(.{
            .disable_printing = (color == .off),
        });
        defer root_prog_node.end();

        if (arg_mode == .translate_c) {
            return cmdTranslateC(comp, arena, null, null, root_prog_node);
        }

        updateModule(comp, color, root_prog_node) catch |err| switch (err) {
            error.SemanticAnalyzeFail => {
                assert(listen == .none);
                saveState(comp, incremental);
                process.exit(1);
            },
            else => |e| return e,
        };
    }
    try comp.makeBinFileExecutable();
    saveState(comp, incremental);

    if (switch (arg_mode) {
        .run => true,
        .zig_test => !test_no_exec,
        else => false,
    }) {
        dev.checkAny(&.{ .run_command, .test_command });

        if (test_exec_args.items.len == 0 and target.ofmt == .c and emit_bin_resolved != .no) {
            // Default to using `zig run` to execute the produced .c code from `zig test`.
            try test_exec_args.appendSlice(arena, &.{ self_exe_path, "run" });
            if (dirs.zig_lib.path) |p| {
                try test_exec_args.appendSlice(arena, &.{ "-I", p });
            }

            if (create_module.resolved_options.link_libc) {
                try test_exec_args.append(arena, "-lc");
            } else if (target.os.tag == .windows) {
                try test_exec_args.appendSlice(arena, &.{
                    "--subsystem", "console",
                });
            }

            const first_cli_mod = create_module.modules.values()[0];
            if (first_cli_mod.target_arch_os_abi) |triple| {
                try test_exec_args.appendSlice(arena, &.{ "-target", triple });
            }
            if (first_cli_mod.target_mcpu) |mcpu| {
                try test_exec_args.append(arena, try std.fmt.allocPrint(arena, "-mcpu={s}", .{mcpu}));
            }
            if (create_module.dynamic_linker) |dl| {
                try test_exec_args.appendSlice(arena, &.{ "--dynamic-linker", dl });
            }
            try test_exec_args.append(arena, null); // placeholder for the path of the emitted C source file
        }

        try runOrTest(
            comp,
            gpa,
            arena,
            test_exec_args.items,
            self_exe_path,
            arg_mode,
            target,
            &comp_destroyed,
            all_args,
            runtime_args_start,
            create_module.resolved_options.link_libc,
        );
    }

    // Skip resource deallocation in release builds; let the OS do it.
    return cleanExit();
}

const CreateModule = struct {
    dirs: Compilation.Directories,
    modules: std.StringArrayHashMapUnmanaged(CliModule),
    opts: Compilation.Config.Options,
    dynamic_linker: ?[]const u8,
    object_format: ?[]const u8,
    /// undefined until createModule() for the root module is called.
    resolved_options: Compilation.Config,

    /// This one is used while collecting CLI options. The set of libs is used
    /// directly after computing the target and used to compute link_libc,
    /// link_libcpp, and then the libraries are filtered into
    /// `unresolved_link_inputs` and `windows_libs`.
    cli_link_inputs: std.ArrayListUnmanaged(link.UnresolvedInput),
    windows_libs: std.StringArrayHashMapUnmanaged(void),
    /// The local variable `unresolved_link_inputs` is fed into library
    /// resolution, mutating the input array, and producing this data as
    /// output. Allocated with gpa.
    link_inputs: std.ArrayListUnmanaged(link.Input),

    c_source_files: std.ArrayListUnmanaged(Compilation.CSourceFile),
    rc_source_files: std.ArrayListUnmanaged(Compilation.RcSourceFile),

    /// e.g. -m3dnow or -mno-outline-atomics. They correspond to std.Target llvm cpu feature names.
    /// This array is populated by zig cc frontend and then has to be converted to zig-style
    /// CPU features.
    llvm_m_args: std.ArrayListUnmanaged([]const u8),
    sysroot: ?[]const u8,
    lib_directories: std.ArrayListUnmanaged(Directory),
    lib_dir_args: std.ArrayListUnmanaged([]const u8),
    libc_installation: ?LibCInstallation,
    want_native_include_dirs: bool,
    frameworks: std.StringArrayHashMapUnmanaged(Framework),
    native_system_include_paths: []const []const u8,
    framework_dirs: std.ArrayListUnmanaged([]const u8),
    rpath_list: std.ArrayListUnmanaged([]const u8),
    each_lib_rpath: ?bool,
    libc_paths_file: ?[]const u8,
};

fn createModule(
    gpa: Allocator,
    arena: Allocator,
    create_module: *CreateModule,
    index: usize,
    parent: ?*Package.Module,
    color: std.zig.Color,
) Allocator.Error!*Package.Module {
    const cli_mod = &create_module.modules.values()[index];
    if (cli_mod.resolved) |m| return m;

    const name = create_module.modules.keys()[index];

    cli_mod.inherited.resolved_target = t: {
        // If the target is not overridden, use the parent's target. Of course,
        // if this is the root module then we need to proceed to resolve the
        // target.
        if (cli_mod.target_arch_os_abi == null and cli_mod.target_mcpu == null) {
            if (parent) |p| break :t p.resolved_target;
        }

        var target_parse_options: std.Target.Query.ParseOptions = .{
            .arch_os_abi = cli_mod.target_arch_os_abi orelse "native",
            .cpu_features = cli_mod.target_mcpu,
            .dynamic_linker = create_module.dynamic_linker,
            .object_format = create_module.object_format,
        };

        // Before passing the mcpu string in for parsing, we convert any -m flags that were
        // passed in via zig cc to zig-style.
        if (create_module.llvm_m_args.items.len != 0) {
            // If this returns null, we let it fall through to the case below which will
            // run the full parse function and do proper error handling.
            if (std.Target.Query.parseCpuArch(target_parse_options)) |cpu_arch| {
                var llvm_to_zig_name = std.StringHashMap([]const u8).init(gpa);
                defer llvm_to_zig_name.deinit();

                for (cpu_arch.allFeaturesList()) |feature| {
                    const llvm_name = feature.llvm_name orelse continue;
                    try llvm_to_zig_name.put(llvm_name, feature.name);
                }

                var mcpu_buffer = std.ArrayList(u8).init(gpa);
                defer mcpu_buffer.deinit();

                try mcpu_buffer.appendSlice(cli_mod.target_mcpu orelse "baseline");

                for (create_module.llvm_m_args.items) |llvm_m_arg| {
                    if (mem.startsWith(u8, llvm_m_arg, "mno-")) {
                        const llvm_name = llvm_m_arg["mno-".len..];
                        const zig_name = llvm_to_zig_name.get(llvm_name) orelse {
                            fatal("target architecture {s} has no LLVM CPU feature named '{s}'", .{
                                @tagName(cpu_arch), llvm_name,
                            });
                        };
                        try mcpu_buffer.append('-');
                        try mcpu_buffer.appendSlice(zig_name);
                    } else if (mem.startsWith(u8, llvm_m_arg, "m")) {
                        const llvm_name = llvm_m_arg["m".len..];
                        const zig_name = llvm_to_zig_name.get(llvm_name) orelse {
                            fatal("target architecture {s} has no LLVM CPU feature named '{s}'", .{
                                @tagName(cpu_arch), llvm_name,
                            });
                        };
                        try mcpu_buffer.append('+');
                        try mcpu_buffer.appendSlice(zig_name);
                    } else {
                        unreachable;
                    }
                }

                const adjusted_target_mcpu = try arena.dupe(u8, mcpu_buffer.items);
                std.log.debug("adjusted target_mcpu: {s}", .{adjusted_target_mcpu});
                target_parse_options.cpu_features = adjusted_target_mcpu;
            }
        }

        const target_query = std.zig.parseTargetQueryOrReportFatalError(arena, target_parse_options);
        const target = std.zig.resolveTargetQueryOrFatal(target_query);
        break :t .{
            .result = target,
            .is_native_os = target_query.isNativeOs(),
            .is_native_abi = target_query.isNativeAbi(),
            .is_explicit_dynamic_linker = !target_query.dynamic_linker.eql(.none),
        };
    };

    if (parent == null) {
        // This block is for initializing the fields of
        // `Compilation.Config.Options` that require knowledge of the
        // target (which was just now resolved for the root module above).
        const resolved_target = &cli_mod.inherited.resolved_target.?;
        create_module.opts.resolved_target = resolved_target.*;
        create_module.opts.root_optimize_mode = cli_mod.inherited.optimize_mode;
        create_module.opts.root_strip = cli_mod.inherited.strip;
        create_module.opts.root_error_tracing = cli_mod.inherited.error_tracing;
        const target = &resolved_target.result;

        // First, remove libc, libc++, and compiler_rt libraries from the system libraries list.
        // We need to know whether the set of system libraries contains anything besides these
        // to decide whether to trigger native path detection logic.
        // Preserves linker input order.
        var unresolved_link_inputs: std.ArrayListUnmanaged(link.UnresolvedInput) = .empty;
        defer unresolved_link_inputs.deinit(gpa);
        try unresolved_link_inputs.ensureUnusedCapacity(gpa, create_module.cli_link_inputs.items.len);
        var any_name_queries_remaining = false;
        for (create_module.cli_link_inputs.items) |cli_link_input| switch (cli_link_input) {
            .name_query => |nq| {
                const lib_name = nq.name;

                if (std.zig.target.isLibCLibName(target, lib_name)) {
                    create_module.opts.link_libc = true;
                    continue;
                }
                if (std.zig.target.isLibCxxLibName(target, lib_name)) {
                    create_module.opts.link_libcpp = true;
                    continue;
                }

                switch (target_util.classifyCompilerRtLibName(lib_name)) {
                    .none => {},
                    .only_libunwind, .both => {
                        create_module.opts.link_libunwind = true;
                        continue;
                    },
                    .only_compiler_rt => continue,
                }

                // We currently prefer import libraries provided by MinGW-w64 even for MSVC.
                if (target.os.tag == .windows) {
                    const exists = mingw.libExists(arena, target, create_module.dirs.zig_lib, lib_name) catch |err| {
                        fatal("failed to check zig installation for DLL import libs: {s}", .{
                            @errorName(err),
                        });
                    };
                    if (exists) {
                        try create_module.windows_libs.put(arena, lib_name, {});
                        continue;
                    }
                }

                if (fs.path.isAbsolute(lib_name)) {
                    fatal("cannot use absolute path as a system library: {s}", .{lib_name});
                }

                unresolved_link_inputs.appendAssumeCapacity(cli_link_input);
                any_name_queries_remaining = true;
            },
            else => {
                unresolved_link_inputs.appendAssumeCapacity(cli_link_input);
            },
        }; // After this point, unresolved_link_inputs is used instead of cli_link_inputs.

        if (any_name_queries_remaining) create_module.want_native_include_dirs = true;

        // Resolve the library path arguments with respect to sysroot.
        try create_module.lib_directories.ensureUnusedCapacity(arena, create_module.lib_dir_args.items.len);
        if (create_module.sysroot) |root| {
            for (create_module.lib_dir_args.items) |lib_dir_arg| {
                if (fs.path.isAbsolute(lib_dir_arg)) {
                    const stripped_dir = lib_dir_arg[fs.path.diskDesignator(lib_dir_arg).len..];
                    const full_path = try fs.path.join(arena, &[_][]const u8{ root, stripped_dir });
                    addLibDirectoryWarn(&create_module.lib_directories, full_path);
                } else {
                    addLibDirectoryWarn(&create_module.lib_directories, lib_dir_arg);
                }
            }
        } else {
            for (create_module.lib_dir_args.items) |lib_dir_arg| {
                addLibDirectoryWarn(&create_module.lib_directories, lib_dir_arg);
            }
        }
        create_module.lib_dir_args = undefined; // From here we use lib_directories instead.

        if (resolved_target.is_native_os and target.os.tag.isDarwin()) {
            // If we want to link against frameworks, we need system headers.
            if (create_module.frameworks.count() > 0)
                create_module.want_native_include_dirs = true;
        }

        if (create_module.each_lib_rpath orelse resolved_target.is_native_os) {
            try create_module.rpath_list.ensureUnusedCapacity(arena, create_module.lib_directories.items.len);
            for (create_module.lib_directories.items) |lib_directory| {
                create_module.rpath_list.appendAssumeCapacity(lib_directory.path.?);
            }
        }

        // Trigger native system library path detection if necessary.
        if (create_module.sysroot == null and
            resolved_target.is_native_os and resolved_target.is_native_abi and
            create_module.want_native_include_dirs)
        {
            var paths = std.zig.system.NativePaths.detect(arena, target) catch |err| {
                fatal("unable to detect native system paths: {s}", .{@errorName(err)});
            };
            for (paths.warnings.items) |warning| {
                warn("{s}", .{warning});
            }

            create_module.native_system_include_paths = try paths.include_dirs.toOwnedSlice(arena);

            try create_module.framework_dirs.appendSlice(arena, paths.framework_dirs.items);
            try create_module.rpath_list.appendSlice(arena, paths.rpaths.items);

            try create_module.lib_directories.ensureUnusedCapacity(arena, paths.lib_dirs.items.len);
            for (paths.lib_dirs.items) |path| addLibDirectoryWarn2(&create_module.lib_directories, path, true);
        }

        if (create_module.libc_paths_file) |paths_file| {
            create_module.libc_installation = LibCInstallation.parse(arena, paths_file, target) catch |err| {
                fatal("unable to parse libc paths file at path {s}: {s}", .{
                    paths_file, @errorName(err),
                });
            };
        }

        if (target.os.tag == .windows and (target.abi == .msvc or target.abi == .itanium) and
            any_name_queries_remaining)
        {
            if (create_module.libc_installation == null) {
                create_module.libc_installation = LibCInstallation.findNative(.{
                    .allocator = arena,
                    .verbose = true,
                    .target = target,
                }) catch |err| {
                    fatal("unable to find native libc installation: {s}", .{@errorName(err)});
                };
            }
            try create_module.lib_directories.ensureUnusedCapacity(arena, 2);
            addLibDirectoryWarn(&create_module.lib_directories, create_module.libc_installation.?.msvc_lib_dir.?);
            addLibDirectoryWarn(&create_module.lib_directories, create_module.libc_installation.?.kernel32_lib_dir.?);
        }

        // Destructively mutates but does not transfer ownership of `unresolved_link_inputs`.
        link.resolveInputs(
            gpa,
            arena,
            target,
            &unresolved_link_inputs,
            &create_module.link_inputs,
            create_module.lib_directories.items,
            color,
        ) catch |err| fatal("failed to resolve link inputs: {s}", .{@errorName(err)});

        if (!create_module.opts.any_dyn_libs) for (create_module.link_inputs.items) |item| switch (item) {
            .dso, .dso_exact => {
                create_module.opts.any_dyn_libs = true;
                break;
            },
            else => {},
        };

        create_module.resolved_options = Compilation.Config.resolve(create_module.opts) catch |err| switch (err) {
            error.WasiExecModelRequiresWasi => fatal("only WASI OS targets support execution model", .{}),
            error.SharedMemoryIsWasmOnly => fatal("only WebAssembly CPU targets support shared memory", .{}),
            error.ObjectFilesCannotShareMemory => fatal("object files cannot share memory", .{}),
            error.SharedMemoryRequiresAtomicsAndBulkMemory => fatal("shared memory requires atomics and bulk_memory CPU features", .{}),
            error.ThreadsRequireSharedMemory => fatal("threads require shared memory", .{}),
            error.EmittingLlvmModuleRequiresLlvmBackend => fatal("emitting an LLVM module requires using the LLVM backend", .{}),
            error.LlvmLacksTargetSupport => fatal("LLVM lacks support for the specified target", .{}),
            error.ZigLacksTargetSupport => fatal("compiler backend unavailable for the specified target", .{}),
            error.EmittingBinaryRequiresLlvmLibrary => fatal("producing machine code via LLVM requires using the LLVM library", .{}),
            error.LldIncompatibleObjectFormat => fatal("using LLD to link {s} files is unsupported", .{@tagName(target.ofmt)}),
            error.LldCannotIncrementallyLink => fatal("self-hosted backends do not support linking with LLD", .{}),
            error.LtoRequiresLld => fatal("LTO requires using LLD", .{}),
            error.SanitizeThreadRequiresLibCpp => fatal("thread sanitization is (for now) implemented in C++, so it requires linking libc++", .{}),
            error.LibCRequiresLibUnwind => fatal("libc of the specified target requires linking libunwind", .{}),
            error.LibCppRequiresLibUnwind => fatal("libc++ requires linking libunwind", .{}),
            error.OsRequiresLibC => fatal("the target OS requires using libc as the stable syscall interface", .{}),
            error.LibCppRequiresLibC => fatal("libc++ requires linking libc", .{}),
            error.LibUnwindRequiresLibC => fatal("libunwind requires linking libc", .{}),
            error.TargetCannotDynamicLink => fatal("dynamic linking unavailable on the specified target", .{}),
            error.TargetCannotStaticLinkExecutables => fatal("static linking of executables unavailable on the specified target", .{}),
            error.LibCRequiresDynamicLinking => fatal("libc of the specified target requires dynamic linking", .{}),
            error.SharedLibrariesRequireDynamicLinking => fatal("using shared libraries requires dynamic linking", .{}),
            error.ExportMemoryAndDynamicIncompatible => fatal("exporting memory is incompatible with dynamic linking", .{}),
            error.DynamicLibraryPrecludesPie => fatal("dynamic libraries cannot be position independent executables", .{}),
            error.TargetRequiresPie => fatal("the specified target requires position independent executables", .{}),
            error.SanitizeThreadRequiresPie => fatal("thread sanitization requires position independent executables", .{}),
            error.BackendLacksErrorTracing => fatal("the selected backend has not yet implemented error return tracing", .{}),
            error.LlvmLibraryUnavailable => fatal("zig was compiled without LLVM libraries", .{}),
            error.LldUnavailable => fatal("zig was compiled without LLD libraries", .{}),
            error.ClangUnavailable => fatal("zig was compiled without Clang libraries", .{}),
            error.DllExportFnsRequiresWindows => fatal("only Windows OS targets support DLLs", .{}),
        };
    }

    const root: Compilation.Path = try .fromUnresolved(arena, create_module.dirs, &.{cli_mod.root_path});

    const mod = Package.Module.create(arena, .{
        .paths = .{
            .root = root,
            .root_src_path = cli_mod.root_src_path,
        },
        .fully_qualified_name = name,

        .cc_argv = cli_mod.cc_argv,
        .inherited = cli_mod.inherited,
        .global = create_module.resolved_options,
        .parent = parent,
    }) catch |err| switch (err) {
        error.ValgrindUnsupportedOnTarget => fatal("unable to create module '{s}': valgrind does not support the selected target CPU architecture", .{name}),
        error.TargetRequiresSingleThreaded => fatal("unable to create module '{s}': the selected target does not support multithreading", .{name}),
        error.BackendRequiresSingleThreaded => fatal("unable to create module '{s}': the selected machine code backend is limited to single-threaded applications", .{name}),
        error.TargetRequiresPic => fatal("unable to create module '{s}': the selected target requires position independent code", .{name}),
        error.PieRequiresPic => fatal("unable to create module '{s}': making a Position Independent Executable requires enabling Position Independent Code", .{name}),
        error.DynamicLinkingRequiresPic => fatal("unable to create module '{s}': dynamic linking requires enabling Position Independent Code", .{name}),
        error.TargetHasNoRedZone => fatal("unable to create module '{s}': the selected target does not have a red zone", .{name}),
        error.StackCheckUnsupportedByTarget => fatal("unable to create module '{s}': the selected target does not support stack checking", .{name}),
        error.StackProtectorUnsupportedByTarget => fatal("unable to create module '{s}': the selected target does not support stack protection", .{name}),
        error.StackProtectorUnavailableWithoutLibC => fatal("unable to create module '{s}': enabling stack protection requires libc", .{name}),
        error.OutOfMemory => return error.OutOfMemory,
    };
    cli_mod.resolved = mod;

    for (create_module.c_source_files.items[cli_mod.c_source_files_start..cli_mod.c_source_files_end]) |*item| item.owner = mod;

    for (create_module.rc_source_files.items[cli_mod.rc_source_files_start..cli_mod.rc_source_files_end]) |*item| item.owner = mod;

    for (cli_mod.deps) |dep| {
        const dep_index = create_module.modules.getIndex(dep.value) orelse
            fatal("module '{s}' depends on non-existent module '{s}'", .{ name, dep.key });
        const dep_mod = try createModule(gpa, arena, create_module, dep_index, mod, color);
        try mod.deps.put(arena, dep.key, dep_mod);
    }

    return mod;
}

fn saveState(comp: *Compilation, incremental: bool) void {
    if (incremental) {
        comp.saveState() catch |err| {
            warn("unable to save incremental compilation state: {s}", .{@errorName(err)});
        };
    }
}

fn serve(
    comp: *Compilation,
    in: *std.Io.Reader,
    out: *std.Io.Writer,
    test_exec_args: []const ?[]const u8,
    self_exe_path: ?[]const u8,
    arg_mode: ArgMode,
    all_args: []const []const u8,
    runtime_args_start: ?usize,
) !void {
    const gpa = comp.gpa;

    var server = try Server.init(.{
        .in = in,
        .out = out,
        .zig_version = build_options.version,
    });

    var child_pid: ?std.process.Child.Id = null;

    const main_progress_node = std.Progress.start(.{});
    const file_system_inputs = comp.file_system_inputs.?;

    const IncrementalDebugServer = if (build_options.enable_debug_extensions and !builtin.single_threaded)
        @import("IncrementalDebugServer.zig")
    else
        void;

    var ids: IncrementalDebugServer = if (comp.debugIncremental()) ids: {
        break :ids .init(comp.zcu orelse @panic("--debug-incremental requires a ZCU"));
    } else undefined;
    defer if (comp.debugIncremental()) ids.deinit();

    if (comp.debugIncremental()) ids.spawn();

    while (true) {
        const hdr = try server.receiveMessage();

        // Lock the debug server while hanling the message.
        if (comp.debugIncremental()) ids.mutex.lock();
        defer if (comp.debugIncremental()) ids.mutex.unlock();

        switch (hdr.tag) {
            .exit => return cleanExit(),
            .update => {
                tracy.frameMark();
                file_system_inputs.clearRetainingCapacity();

                if (arg_mode == .translate_c) {
                    var arena_instance = std.heap.ArenaAllocator.init(gpa);
                    defer arena_instance.deinit();
                    const arena = arena_instance.allocator();
                    var output: Compilation.CImportResult = undefined;
                    try cmdTranslateC(comp, arena, &output, file_system_inputs, main_progress_node);
                    defer output.deinit(gpa);
                    try server.serveStringMessage(.file_system_inputs, file_system_inputs.items);
                    if (output.errors.errorMessageCount() != 0) {
                        try server.serveErrorBundle(output.errors);
                    } else {
                        try server.serveEmitDigest(&output.digest, .{
                            .flags = .{ .cache_hit = output.cache_hit },
                        });
                    }
                    continue;
                }

                if (comp.config.output_mode == .Exe) {
                    try comp.makeBinFileWritable();
                }

                try comp.update(main_progress_node);

                try comp.makeBinFileExecutable();
                try serveUpdateResults(&server, comp);
            },
            .run => {
                if (child_pid != null) {
                    @panic("TODO block until the child exits");
                }
                @panic("TODO call runOrTest");
                //try runOrTest(
                //    comp,
                //    gpa,
                //    arena,
                //    test_exec_args,
                //    self_exe_path.?,
                //    arg_mode,
                //    target,
                //    true,
                //    &comp_destroyed,
                //    all_args,
                //    runtime_args_start,
                //    link_libc,
                //);
            },
            .hot_update => {
                tracy.frameMark();
                file_system_inputs.clearRetainingCapacity();
                if (child_pid) |pid| {
                    try comp.hotCodeSwap(main_progress_node, pid);
                    try serveUpdateResults(&server, comp);
                } else {
                    if (comp.config.output_mode == .Exe) {
                        try comp.makeBinFileWritable();
                    }
                    try comp.update(main_progress_node);
                    try comp.makeBinFileExecutable();
                    try serveUpdateResults(&server, comp);

                    child_pid = try runOrTestHotSwap(
                        comp,
                        gpa,
                        test_exec_args,
                        self_exe_path.?,
                        arg_mode,
                        all_args,
                        runtime_args_start,
                    );
                }
            },
            else => {
                fatal("unrecognized message from client: 0x{x}", .{@intFromEnum(hdr.tag)});
            },
        }
    }
}

fn serveUpdateResults(s: *Server, comp: *Compilation) !void {
    const gpa = comp.gpa;

    var error_bundle = try comp.getAllErrorsAlloc();
    defer error_bundle.deinit(gpa);

    if (comp.file_system_inputs) |file_system_inputs| {
        if (file_system_inputs.items.len == 0) {
            assert(error_bundle.errorMessageCount() > 0);
        } else {
            try s.serveStringMessage(.file_system_inputs, file_system_inputs.items);
        }
    }

    if (comp.time_report) |*tr| {
        var decls_len: u32 = 0;

        var file_name_bytes: std.ArrayListUnmanaged(u8) = .empty;
        defer file_name_bytes.deinit(gpa);
        var files: std.AutoArrayHashMapUnmanaged(Zcu.File.Index, void) = .empty;
        defer files.deinit(gpa);
        var decl_data: std.ArrayListUnmanaged(u8) = .empty;
        defer decl_data.deinit(gpa);

        // Each decl needs at least 34 bytes:
        // * 2 for 1-byte name plus null terminator
        // * 4 for `file`
        // * 4 for `sema_count`
        // * 8 for `sema_ns`
        // * 8 for `codegen_ns`
        // * 8 for `link_ns`
        // Most, if not all, decls in `tr.decl_sema_ns` are valid, so we have a good size estimate.
        try decl_data.ensureUnusedCapacity(gpa, tr.decl_sema_info.count() * 34);

        for (tr.decl_sema_info.keys(), tr.decl_sema_info.values()) |tracked_inst, sema_info| {
            const resolved = tracked_inst.resolveFull(&comp.zcu.?.intern_pool) orelse continue;
            const file = comp.zcu.?.fileByIndex(resolved.file);
            const zir = file.zir orelse continue;
            const decl_name = zir.nullTerminatedString(zir.getDeclaration(resolved.inst).name);

            const gop = try files.getOrPut(gpa, resolved.file);
            if (!gop.found_existing) try file_name_bytes.writer(gpa).print("{f}\x00", .{file.path.fmt(comp)});

            const codegen_ns = tr.decl_codegen_ns.get(tracked_inst) orelse 0;
            const link_ns = tr.decl_link_ns.get(tracked_inst) orelse 0;

            decls_len += 1;

            try decl_data.ensureUnusedCapacity(gpa, 33 + decl_name.len);
            decl_data.appendSliceAssumeCapacity(decl_name);
            decl_data.appendAssumeCapacity(0);

            const out_file = decl_data.addManyAsArrayAssumeCapacity(4);
            const out_sema_count = decl_data.addManyAsArrayAssumeCapacity(4);
            const out_sema_ns = decl_data.addManyAsArrayAssumeCapacity(8);
            const out_codegen_ns = decl_data.addManyAsArrayAssumeCapacity(8);
            const out_link_ns = decl_data.addManyAsArrayAssumeCapacity(8);
            std.mem.writeInt(u32, out_file, @intCast(gop.index), .little);
            std.mem.writeInt(u32, out_sema_count, sema_info.count, .little);
            std.mem.writeInt(u64, out_sema_ns, sema_info.ns, .little);
            std.mem.writeInt(u64, out_codegen_ns, codegen_ns, .little);
            std.mem.writeInt(u64, out_link_ns, link_ns, .little);
        }

        const header: std.zig.Server.Message.TimeReport = .{
            .stats = tr.stats,
            .llvm_pass_timings_len = @intCast(tr.llvm_pass_timings.len),
            .files_len = @intCast(files.count()),
            .decls_len = decls_len,
            .flags = .{
                .use_llvm = comp.zcu != null and comp.zcu.?.llvm_object != null,
            },
        };

        var slices: [4][]const u8 = .{
            @ptrCast(&header),
            tr.llvm_pass_timings,
            file_name_bytes.items,
            decl_data.items,
        };
        try s.serveMessageHeader(.{
            .tag = .time_report,
            .bytes_len = len: {
                var len: u32 = 0;
                for (slices) |slice| len += @intCast(slice.len);
                break :len len;
            },
        });
        try s.out.writeVecAll(&slices);
        try s.out.flush();
    }

    if (error_bundle.errorMessageCount() > 0) {
        try s.serveErrorBundle(error_bundle);
        return;
    }

    if (comp.digest) |digest| {
        try s.serveEmitDigest(&digest, .{
            .flags = .{ .cache_hit = comp.last_update_was_cache_hit },
        });
    }

    // Serve empty error bundle to indicate the update is done.
    try s.serveErrorBundle(std.zig.ErrorBundle.empty);
}

fn runOrTest(
    comp: *Compilation,
    gpa: Allocator,
    arena: Allocator,
    test_exec_args: []const ?[]const u8,
    self_exe_path: []const u8,
    arg_mode: ArgMode,
    target: *const std.Target,
    comp_destroyed: *bool,
    all_args: []const []const u8,
    runtime_args_start: ?usize,
    link_libc: bool,
) !void {
    const raw_emit_bin = comp.emit_bin orelse return;
    const exe_path = switch (comp.cache_use) {
        .none => p: {
            if (fs.path.isAbsolute(raw_emit_bin)) break :p raw_emit_bin;
            // Use `fs.path.join` to make a file in the cwd is still executed properly.
            break :p try fs.path.join(arena, &.{
                ".",
                raw_emit_bin,
            });
        },
        .whole, .incremental => try comp.dirs.local_cache.join(arena, &.{
            "o",
            &Cache.binToHex(comp.digest.?),
            raw_emit_bin,
        }),
    };

    var argv = std.ArrayList([]const u8).init(gpa);
    defer argv.deinit();

    if (test_exec_args.len == 0) {
        try argv.append(exe_path);
        if (arg_mode == .zig_test) {
            try argv.append(
                try std.fmt.allocPrint(arena, "--seed=0x{x}", .{std.crypto.random.int(u32)}),
            );
        }
    } else {
        for (test_exec_args) |arg| {
            try argv.append(arg orelse exe_path);
        }
    }
    if (runtime_args_start) |i| {
        try argv.appendSlice(all_args[i..]);
    }
    var env_map = try process.getEnvMap(arena);
    try env_map.put("ZIG_EXE", self_exe_path);

    // We do not execve for tests because if the test fails we want to print
    // the error message and invocation below.
    if (process.can_execv and arg_mode == .run) {
        // execv releases the locks; no need to destroy the Compilation here.
        std.debug.lockStdErr();
        const err = process.execve(gpa, argv.items, &env_map);
        std.debug.unlockStdErr();
        try warnAboutForeignBinaries(arena, arg_mode, target, link_libc);
        const cmd = try std.mem.join(arena, " ", argv.items);
        fatal("the following command failed to execve with '{s}':\n{s}", .{ @errorName(err), cmd });
    } else if (process.can_spawn) {
        var child = std.process.Child.init(argv.items, gpa);
        child.env_map = &env_map;
        child.stdin_behavior = .Inherit;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;

        // Here we release all the locks associated with the Compilation so
        // that whatever this child process wants to do won't deadlock.
        comp.destroy();
        comp_destroyed.* = true;

        const term_result = t: {
            std.debug.lockStdErr();
            defer std.debug.unlockStdErr();
            break :t child.spawnAndWait();
        };
        const term = term_result catch |err| {
            try warnAboutForeignBinaries(arena, arg_mode, target, link_libc);
            const cmd = try std.mem.join(arena, " ", argv.items);
            fatal("the following command failed with '{s}':\n{s}", .{ @errorName(err), cmd });
        };
        switch (arg_mode) {
            .run, .build => {
                switch (term) {
                    .Exited => |code| {
                        if (code == 0) {
                            return cleanExit();
                        } else {
                            process.exit(code);
                        }
                    },
                    else => {
                        process.exit(1);
                    },
                }
            },
            .zig_test => {
                switch (term) {
                    .Exited => |code| {
                        if (code == 0) {
                            return cleanExit();
                        } else {
                            const cmd = try std.mem.join(arena, " ", argv.items);
                            fatal("the following test command failed with exit code {d}:\n{s}", .{ code, cmd });
                        }
                    },
                    else => {
                        const cmd = try std.mem.join(arena, " ", argv.items);
                        fatal("the following test command crashed:\n{s}", .{cmd});
                    },
                }
            },
            else => unreachable,
        }
    } else {
        const cmd = try std.mem.join(arena, " ", argv.items);
        fatal("the following command cannot be executed ({s} does not support spawning a child process):\n{s}", .{ @tagName(native_os), cmd });
    }
}

fn runOrTestHotSwap(
    comp: *Compilation,
    gpa: Allocator,
    test_exec_args: []const ?[]const u8,
    self_exe_path: []const u8,
    arg_mode: ArgMode,
    all_args: []const []const u8,
    runtime_args_start: ?usize,
) !std.process.Child.Id {
    const lf = comp.bin_file.?;

    const exe_path = switch (builtin.target.os.tag) {
        // On Windows it seems impossible to perform an atomic rename of a file that is currently
        // running in a process. Therefore, we do the opposite. We create a copy of the file in
        // tmp zig-cache and use it to spawn the child process. This way we are free to update
        // the binary with each requested hot update.
        .windows => blk: {
            try lf.emit.root_dir.handle.copyFile(lf.emit.sub_path, comp.dirs.local_cache.handle, lf.emit.sub_path, .{});
            break :blk try fs.path.join(gpa, &.{ comp.dirs.local_cache.path orelse ".", lf.emit.sub_path });
        },

        // A naive `directory.join` here will indeed get the correct path to the binary,
        // however, in the case of cwd, we actually want `./foo` so that the path can be executed.
        else => try fs.path.join(gpa, &.{
            lf.emit.root_dir.path orelse ".", lf.emit.sub_path,
        }),
    };
    defer gpa.free(exe_path);

    var argv = std.ArrayList([]const u8).init(gpa);
    defer argv.deinit();

    if (test_exec_args.len == 0) {
        // when testing pass the zig_exe_path to argv
        if (arg_mode == .zig_test)
            try argv.appendSlice(&[_][]const u8{
                exe_path, self_exe_path,
            })
            // when running just pass the current exe
        else
            try argv.appendSlice(&[_][]const u8{
                exe_path,
            });
    } else {
        for (test_exec_args) |arg| {
            if (arg) |a| {
                try argv.append(a);
            } else {
                try argv.appendSlice(&[_][]const u8{
                    exe_path, self_exe_path,
                });
            }
        }
    }
    if (runtime_args_start) |i| {
        try argv.appendSlice(all_args[i..]);
    }

    switch (builtin.target.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => {
            const PosixSpawn = @import("DarwinPosixSpawn.zig");

            var attr = try PosixSpawn.Attr.init();
            defer attr.deinit();

            // ASLR is probably a good default for better debugging experience/programming
            // with hot-code updates in mind. However, we can also make it work with ASLR on.
            const flags: u16 = std.c.POSIX_SPAWN.SETSIGDEF |
                std.c.POSIX_SPAWN.SETSIGMASK |
                std.c.POSIX_SPAWN.DISABLE_ASLR;
            try attr.set(flags);

            var arena_allocator = std.heap.ArenaAllocator.init(gpa);
            defer arena_allocator.deinit();
            const arena = arena_allocator.allocator();

            const argv_buf = try arena.allocSentinel(?[*:0]u8, argv.items.len, null);
            for (argv.items, 0..) |arg, i| argv_buf[i] = (try arena.dupeZ(u8, arg)).ptr;

            const pid = try PosixSpawn.spawn(argv.items[0], null, attr, argv_buf, std.c.environ);
            return pid;
        },
        else => {
            var child = std.process.Child.init(argv.items, gpa);

            child.stdin_behavior = .Inherit;
            child.stdout_behavior = .Inherit;
            child.stderr_behavior = .Inherit;

            try child.spawn();

            return child.id;
        },
    }
}

fn updateModule(comp: *Compilation, color: Color, prog_node: std.Progress.Node) !void {
    try comp.update(prog_node);

    var errors = try comp.getAllErrorsAlloc();
    defer errors.deinit(comp.gpa);

    if (errors.errorMessageCount() > 0) {
        errors.renderToStdErr(color.renderOptions());
        return error.SemanticAnalyzeFail;
    }
}

fn cmdTranslateC(
    comp: *Compilation,
    arena: Allocator,
    fancy_output: ?*Compilation.CImportResult,
    file_system_inputs: ?*std.ArrayListUnmanaged(u8),
    prog_node: std.Progress.Node,
) !void {
    dev.check(.translate_c_command);

    const color: Color = .auto;
    assert(comp.c_source_files.len == 1);
    const c_source_file = comp.c_source_files[0];

    const translated_zig_basename = try std.fmt.allocPrint(arena, "{s}.zig", .{comp.root_name});

    var man: Cache.Manifest = comp.obtainCObjectCacheManifest(comp.root_mod);
    man.want_shared_lock = false;
    defer man.deinit();

    man.hash.add(@as(u16, 0xb945)); // Random number to distinguish translate-c from compiling C objects
    man.hash.add(comp.config.c_frontend);
    Compilation.cache_helpers.hashCSource(&man, c_source_file) catch |err| {
        fatal("unable to process '{s}': {s}", .{ c_source_file.src_path, @errorName(err) });
    };

    if (fancy_output) |p| p.cache_hit = true;
    const bin_digest, const hex_digest = if (try man.hit()) digest: {
        if (file_system_inputs) |buf| try man.populateFileSystemInputs(buf);
        const bin_digest = man.finalBin();
        const hex_digest = Cache.binToHex(bin_digest);
        break :digest .{ bin_digest, hex_digest };
    } else digest: {
        if (fancy_output) |p| p.cache_hit = false;
        var argv = std.ArrayList([]const u8).init(arena);
        switch (comp.config.c_frontend) {
            .aro => {},
            .clang => {
                // argv[0] is program name, actual args start at [1]
                try argv.append(@tagName(comp.config.c_frontend));
            },
        }

        var zig_cache_tmp_dir = try comp.dirs.local_cache.handle.makeOpenPath("tmp", .{});
        defer zig_cache_tmp_dir.close();

        const ext = Compilation.classifyFileExt(c_source_file.src_path);
        const out_dep_path: ?[]const u8 = blk: {
            if (comp.config.c_frontend == .aro or comp.disable_c_depfile or !ext.clangSupportsDepFile())
                break :blk null;

            const c_src_basename = fs.path.basename(c_source_file.src_path);
            const dep_basename = try std.fmt.allocPrint(arena, "{s}.d", .{c_src_basename});
            const out_dep_path = try comp.tmpFilePath(arena, dep_basename);
            break :blk out_dep_path;
        };

        // TODO
        if (comp.config.c_frontend != .aro)
            try comp.addTranslateCCArgs(arena, &argv, ext, out_dep_path, comp.root_mod);
        try argv.append(c_source_file.src_path);

        if (comp.verbose_cc) {
            Compilation.dump_argv(argv.items);
        }

        const Result = union(enum) {
            success: []const u8,
            error_bundle: std.zig.ErrorBundle,
        };

        const result: Result = switch (comp.config.c_frontend) {
            .aro => f: {
                var stdout: []u8 = undefined;
                try jitCmd(comp.gpa, arena, argv.items, .{
                    .cmd_name = "aro_translate_c",
                    .root_src_path = "aro_translate_c.zig",
                    .depend_on_aro = true,
                    .capture = &stdout,
                    .progress_node = prog_node,
                });
                break :f .{ .success = stdout };
            },
            .clang => f: {
                if (!build_options.have_llvm) unreachable;
                const translate_c = @import("translate_c.zig");

                // Convert to null terminated args.
                const clang_args_len = argv.items.len + c_source_file.extra_flags.len;
                const new_argv_with_sentinel = try arena.alloc(?[*:0]const u8, clang_args_len + 1);
                new_argv_with_sentinel[clang_args_len] = null;
                const new_argv = new_argv_with_sentinel[0..clang_args_len :null];
                for (argv.items, 0..) |arg, i| {
                    new_argv[i] = try arena.dupeZ(u8, arg);
                }
                for (c_source_file.extra_flags, 0..) |arg, i| {
                    new_argv[argv.items.len + i] = try arena.dupeZ(u8, arg);
                }

                const c_headers_dir_path_z = try comp.dirs.zig_lib.joinZ(arena, &.{"include"});
                var errors = std.zig.ErrorBundle.empty;
                var tree = translate_c.translate(
                    comp.gpa,
                    new_argv.ptr,
                    new_argv.ptr + new_argv.len,
                    &errors,
                    c_headers_dir_path_z,
                ) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.SemanticAnalyzeFail => break :f .{ .error_bundle = errors },
                };
                defer tree.deinit(comp.gpa);
                break :f .{ .success = try tree.renderAlloc(arena) };
            },
        };

        if (out_dep_path) |dep_file_path| add_deps: {
            const dep_basename = fs.path.basename(dep_file_path);
            // Add the files depended on to the cache system.
            man.addDepFilePost(zig_cache_tmp_dir, dep_basename) catch |err| switch (err) {
                error.FileNotFound => {
                    // Clang didn't emit the dep file; nothing to add to the manifest.
                    break :add_deps;
                },
                else => |e| return e,
            };
            // Just to save disk space, we delete the file because it is never needed again.
            zig_cache_tmp_dir.deleteFile(dep_basename) catch |err| {
                warn("failed to delete '{s}': {s}", .{ dep_file_path, @errorName(err) });
            };
        }

        const formatted = switch (result) {
            .success => |formatted| formatted,
            .error_bundle => |eb| {
                if (file_system_inputs) |buf| try man.populateFileSystemInputs(buf);
                if (fancy_output) |p| {
                    p.errors = eb;
                    return;
                } else {
                    eb.renderToStdErr(color.renderOptions());
                    process.exit(1);
                }
            },
        };

        const bin_digest = man.finalBin();
        const hex_digest = Cache.binToHex(bin_digest);

        const o_sub_path = try fs.path.join(arena, &[_][]const u8{ "o", &hex_digest });

        var o_dir = try comp.dirs.local_cache.handle.makeOpenPath(o_sub_path, .{});
        defer o_dir.close();

        var zig_file = try o_dir.createFile(translated_zig_basename, .{});
        defer zig_file.close();

        try zig_file.writeAll(formatted);

        man.writeManifest() catch |err| warn("failed to write cache manifest: {s}", .{
            @errorName(err),
        });

        if (file_system_inputs) |buf| try man.populateFileSystemInputs(buf);

        break :digest .{ bin_digest, hex_digest };
    };

    if (fancy_output) |p| {
        p.digest = bin_digest;
        p.errors = std.zig.ErrorBundle.empty;
    } else {
        const out_zig_path = try fs.path.join(arena, &.{ "o", &hex_digest, translated_zig_basename });
        const zig_file = comp.dirs.local_cache.handle.openFile(out_zig_path, .{}) catch |err| {
            const path = comp.dirs.local_cache.path orelse ".";
            fatal("unable to open cached translated zig file '{s}{s}{s}': {s}", .{ path, fs.path.sep_str, out_zig_path, @errorName(err) });
        };
        defer zig_file.close();
        var stdout_writer = fs.File.stdout().writer(&stdout_buffer);
        var file_reader = zig_file.reader(&.{});
        _ = try stdout_writer.interface.sendFileAll(&file_reader, .unlimited);
        return cleanExit();
    }
}

const usage_init =
    \\Usage: zig init
    \\
    \\   Initializes a `zig build` project in the current working
    \\   directory.
    \\
    \\Options:
    \\  -m, --minimal          Use minimal init template
    \\  -h, --help             Print this help and exit
    \\
    \\
;

fn cmdInit(gpa: Allocator, arena: Allocator, args: []const []const u8) !void {
    dev.check(.init_command);

    var template: enum { example, minimal } = .example;
    {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (mem.startsWith(u8, arg, "-")) {
                if (mem.eql(u8, arg, "-m") or mem.eql(u8, arg, "--minimal")) {
                    template = .minimal;
                } else if (mem.eql(u8, arg, "-h") or mem.eql(u8, arg, "--help")) {
                    try fs.File.stdout().writeAll(usage_init);
                    return cleanExit();
                } else {
                    fatal("unrecognized parameter: '{s}'", .{arg});
                }
            } else {
                fatal("unexpected extra parameter: '{s}'", .{arg});
            }
        }
    }

    const cwd_path = try introspect.getResolvedCwd(arena);
    const cwd_basename = fs.path.basename(cwd_path);
    const sanitized_root_name = try sanitizeExampleName(arena, cwd_basename);

    const fingerprint: Package.Fingerprint = .generate(sanitized_root_name);

    switch (template) {
        .example => {
            var templates = findTemplates(gpa, arena);
            defer templates.deinit();

            const s = fs.path.sep_str;
            const template_paths = [_][]const u8{
                Package.build_zig_basename,
                Package.Manifest.basename,
                "src" ++ s ++ "main.zig",
                "src" ++ s ++ "root.zig",
            };
            var ok_count: usize = 0;

            for (template_paths) |template_path| {
                if (templates.write(arena, fs.cwd(), sanitized_root_name, template_path, fingerprint)) |_| {
                    std.log.info("created {s}", .{template_path});
                    ok_count += 1;
                } else |err| switch (err) {
                    error.PathAlreadyExists => std.log.info("preserving already existing file: {s}", .{
                        template_path,
                    }),
                    else => std.log.err("unable to write {s}: {s}\n", .{ template_path, @errorName(err) }),
                }
            }

            if (ok_count == template_paths.len) {
                std.log.info("see `zig build --help` for a menu of options", .{});
            }
            return cleanExit();
        },
        .minimal => {
            writeSimpleTemplateFile(Package.Manifest.basename,
                \\.{{
                \\    .name = .{s},
                \\    .version = "{s}",
                \\    .paths = .{{""}},
                \\    .fingerprint = 0x{x},
                \\}}
                \\
            , .{
                sanitized_root_name,
                build_options.version,
                fingerprint.int(),
            }) catch |err| switch (err) {
                else => fatal("failed to create '{s}': {s}", .{ Package.Manifest.basename, @errorName(err) }),
                error.PathAlreadyExists => fatal("refusing to overwrite '{s}'", .{Package.Manifest.basename}),
            };
            writeSimpleTemplateFile(Package.build_zig_basename,
                \\const std = @import("std");
                \\pub fn build(b: *std.Build) void {{
                \\    _ = b; // stub
                \\}}
                \\
            , .{}) catch |err| switch (err) {
                else => fatal("failed to create '{s}': {s}", .{ Package.build_zig_basename, @errorName(err) }),
                // `build.zig` already existing is okay: the user has just used `zig init` to set up
                // their `build.zig.zon` *after* writing their `build.zig`. So this one isn't fatal.
                error.PathAlreadyExists => {
                    std.log.info("successfully populated '{s}', preserving existing '{s}'", .{ Package.Manifest.basename, Package.build_zig_basename });
                    return cleanExit();
                },
            };
            std.log.info("successfully populated '{s}' and '{s}'", .{ Package.Manifest.basename, Package.build_zig_basename });
            return cleanExit();
        },
    }
}

fn sanitizeExampleName(arena: Allocator, bytes: []const u8) error{OutOfMemory}![]const u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    for (bytes, 0..) |byte, i| switch (byte) {
        '0'...'9' => {
            if (i == 0) try result.append(arena, '_');
            try result.append(arena, byte);
        },
        '_', 'a'...'z', 'A'...'Z' => try result.append(arena, byte),
        '-', '.', ' ' => try result.append(arena, '_'),
        else => continue,
    };
    if (!std.zig.isValidId(result.items)) return "foo";
    if (result.items.len > Package.Manifest.max_name_len)
        result.shrinkRetainingCapacity(Package.Manifest.max_name_len);

    return result.toOwnedSlice(arena);
}

test sanitizeExampleName {
    var arena_instance = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    try std.testing.expectEqualStrings("foo_bar", try sanitizeExampleName(arena, "foo bar+"));
    try std.testing.expectEqualStrings("foo", try sanitizeExampleName(arena, ""));
    try std.testing.expectEqualStrings("foo", try sanitizeExampleName(arena, "!"));
    try std.testing.expectEqualStrings("a", try sanitizeExampleName(arena, "!a"));
    try std.testing.expectEqualStrings("a_b", try sanitizeExampleName(arena, "a.b!"));
    try std.testing.expectEqualStrings("_01234", try sanitizeExampleName(arena, "01234"));
    try std.testing.expectEqualStrings("foo", try sanitizeExampleName(arena, "error"));
    try std.testing.expectEqualStrings("foo", try sanitizeExampleName(arena, "test"));
    try std.testing.expectEqualStrings("tests", try sanitizeExampleName(arena, "tests"));
    try std.testing.expectEqualStrings("test_project", try sanitizeExampleName(arena, "test project"));
}

fn cmdBuild(gpa: Allocator, arena: Allocator, args: []const []const u8) !void {
    dev.check(.build_command);

    var build_file: ?[]const u8 = null;
    var override_lib_dir: ?[]const u8 = try EnvVar.ZIG_LIB_DIR.get(arena);
    var override_global_cache_dir: ?[]const u8 = try EnvVar.ZIG_GLOBAL_CACHE_DIR.get(arena);
    var override_local_cache_dir: ?[]const u8 = try EnvVar.ZIG_LOCAL_CACHE_DIR.get(arena);
    var override_build_runner: ?[]const u8 = try EnvVar.ZIG_BUILD_RUNNER.get(arena);
    var child_argv = std.ArrayList([]const u8).init(arena);
    var reference_trace: ?u32 = null;
    var debug_compile_errors = false;
    var verbose_link = (native_os != .wasi or builtin.link_libc) and
        EnvVar.ZIG_VERBOSE_LINK.isSet();
    var verbose_cc = (native_os != .wasi or builtin.link_libc) and
        EnvVar.ZIG_VERBOSE_CC.isSet();
    var verbose_air = false;
    var verbose_intern_pool = false;
    var verbose_generic_instances = false;
    var verbose_llvm_ir: ?[]const u8 = null;
    var verbose_llvm_bc: ?[]const u8 = null;
    var verbose_cimport = false;
    var verbose_llvm_cpu_features = false;
    var fetch_only = false;
    var fetch_mode: Package.Fetch.JobQueue.Mode = .needed;
    var system_pkg_dir_path: ?[]const u8 = null;
    var debug_target: ?[]const u8 = null;

    const argv_index_exe = child_argv.items.len;
    _ = try child_argv.addOne();

    const self_exe_path = try fs.selfExePathAlloc(arena);
    try child_argv.append(self_exe_path);

    const argv_index_zig_lib_dir = child_argv.items.len;
    _ = try child_argv.addOne();

    const argv_index_build_file = child_argv.items.len;
    _ = try child_argv.addOne();

    const argv_index_cache_dir = child_argv.items.len;
    _ = try child_argv.addOne();

    const argv_index_global_cache_dir = child_argv.items.len;
    _ = try child_argv.addOne();

    try child_argv.appendSlice(&.{
        "--seed",
        try std.fmt.allocPrint(arena, "0x{x}", .{std.crypto.random.int(u32)}),
    });
    const argv_index_seed = child_argv.items.len - 1;

    // This parent process needs a way to obtain results from the configuration
    // phase of the child process. In the future, the make phase will be
    // executed in a separate process than the configure phase, and we can then
    // use stdout from the configuration phase for this purpose.
    //
    // However, currently, both phases are in the same process, and Run Step
    // provides API for making the runned subprocesses inherit stdout and stderr
    // which means these streams are not available for passing metadata back
    // to the parent.
    //
    // Until make and configure phases are separated into different processes,
    // the strategy is to choose a temporary file name ahead of time, and then
    // read this file in the parent to obtain the results, in the case the child
    // exits with code 3.
    const results_tmp_file_nonce = std.fmt.hex(std.crypto.random.int(u64));
    try child_argv.append("-Z" ++ results_tmp_file_nonce);

    var color: Color = .auto;
    var n_jobs: ?u32 = null;

    {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (mem.startsWith(u8, arg, "-")) {
                if (mem.eql(u8, arg, "--build-file")) {
                    if (i + 1 >= args.len) fatal("expected argument after '{s}'", .{arg});
                    i += 1;
                    build_file = args[i];
                    continue;
                } else if (mem.eql(u8, arg, "--zig-lib-dir")) {
                    if (i + 1 >= args.len) fatal("expected argument after '{s}'", .{arg});
                    i += 1;
                    override_lib_dir = args[i];
                    continue;
                } else if (mem.eql(u8, arg, "--build-runner")) {
                    if (i + 1 >= args.len) fatal("expected argument after '{s}'", .{arg});
                    i += 1;
                    override_build_runner = args[i];
                    continue;
                } else if (mem.eql(u8, arg, "--cache-dir")) {
                    if (i + 1 >= args.len) fatal("expected argument after '{s}'", .{arg});
                    i += 1;
                    override_local_cache_dir = args[i];
                    continue;
                } else if (mem.eql(u8, arg, "--global-cache-dir")) {
                    if (i + 1 >= args.len) fatal("expected argument after '{s}'", .{arg});
                    i += 1;
                    override_global_cache_dir = args[i];
                    continue;
                } else if (mem.eql(u8, arg, "-freference-trace")) {
                    reference_trace = 256;
                } else if (mem.eql(u8, arg, "--fetch")) {
                    fetch_only = true;
                } else if (mem.startsWith(u8, arg, "--fetch=")) {
                    fetch_only = true;
                    const sub_arg = arg["--fetch=".len..];
                    fetch_mode = std.meta.stringToEnum(Package.Fetch.JobQueue.Mode, sub_arg) orelse
                        fatal("expected [needed|all] after '--fetch=', found '{s}'", .{
                            sub_arg,
                        });
                } else if (mem.eql(u8, arg, "--system")) {
                    if (i + 1 >= args.len) fatal("expected argument after '{s}'", .{arg});
                    i += 1;
                    system_pkg_dir_path = args[i];
                    try child_argv.append("--system");
                    continue;
                } else if (mem.startsWith(u8, arg, "-freference-trace=")) {
                    const num = arg["-freference-trace=".len..];
                    reference_trace = std.fmt.parseUnsigned(u32, num, 10) catch |err| {
                        fatal("unable to parse reference_trace count '{s}': {s}", .{ num, @errorName(err) });
                    };
                } else if (mem.eql(u8, arg, "-fno-reference-trace")) {
                    reference_trace = null;
                } else if (mem.eql(u8, arg, "--debug-log")) {
                    if (i + 1 >= args.len) fatal("expected argument after '{s}'", .{arg});
                    try child_argv.appendSlice(args[i .. i + 2]);
                    i += 1;
                    if (!build_options.enable_logging) {
                        warn("Zig was compiled without logging enabled (-Dlog). --debug-log has no effect.", .{});
                    } else {
                        try log_scopes.append(arena, args[i]);
                    }
                    continue;
                } else if (mem.eql(u8, arg, "--debug-compile-errors")) {
                    if (build_options.enable_debug_extensions) {
                        debug_compile_errors = true;
                    } else {
                        warn("Zig was compiled without debug extensions. --debug-compile-errors has no effect.", .{});
                    }
                } else if (mem.eql(u8, arg, "--debug-target")) {
                    if (i + 1 >= args.len) fatal("expected argument after '{s}'", .{arg});
                    i += 1;
                    if (build_options.enable_debug_extensions) {
                        debug_target = args[i];
                    } else {
                        warn("Zig was compiled without debug extensions. --debug-target has no effect.", .{});
                    }
                } else if (mem.eql(u8, arg, "--verbose-link")) {
                    verbose_link = true;
                } else if (mem.eql(u8, arg, "--verbose-cc")) {
                    verbose_cc = true;
                } else if (mem.eql(u8, arg, "--verbose-air")) {
                    verbose_air = true;
                } else if (mem.eql(u8, arg, "--verbose-intern-pool")) {
                    verbose_intern_pool = true;
                } else if (mem.eql(u8, arg, "--verbose-generic-instances")) {
                    verbose_generic_instances = true;
                } else if (mem.eql(u8, arg, "--verbose-llvm-ir")) {
                    verbose_llvm_ir = "-";
                } else if (mem.startsWith(u8, arg, "--verbose-llvm-ir=")) {
                    verbose_llvm_ir = arg["--verbose-llvm-ir=".len..];
                } else if (mem.startsWith(u8, arg, "--verbose-llvm-bc=")) {
                    verbose_llvm_bc = arg["--verbose-llvm-bc=".len..];
                } else if (mem.eql(u8, arg, "--verbose-cimport")) {
                    verbose_cimport = true;
                } else if (mem.eql(u8, arg, "--verbose-llvm-cpu-features")) {
                    verbose_llvm_cpu_features = true;
                } else if (mem.eql(u8, arg, "--color")) {
                    if (i + 1 >= args.len) fatal("expected [auto|on|off] after {s}", .{arg});
                    i += 1;
                    color = std.meta.stringToEnum(Color, args[i]) orelse {
                        fatal("expected [auto|on|off] after {s}, found '{s}'", .{ arg, args[i] });
                    };
                    try child_argv.appendSlice(&.{ arg, args[i] });
                    continue;
                } else if (mem.startsWith(u8, arg, "-j")) {
                    const str = arg["-j".len..];
                    const num = std.fmt.parseUnsigned(u32, str, 10) catch |err| {
                        fatal("unable to parse jobs count '{s}': {s}", .{
                            str, @errorName(err),
                        });
                    };
                    if (num < 1) {
                        fatal("number of jobs must be at least 1\n", .{});
                    }
                    n_jobs = num;
                } else if (mem.eql(u8, arg, "--seed")) {
                    if (i + 1 >= args.len) fatal("expected argument after '{s}'", .{arg});
                    i += 1;
                    child_argv.items[argv_index_seed] = args[i];
                    continue;
                } else if (mem.eql(u8, arg, "--")) {
                    // The rest of the args are supposed to get passed onto
                    // build runner's `build.args`
                    try child_argv.appendSlice(args[i..]);
                    break;
                }
            }
            try child_argv.append(arg);
        }
    }

    const work_around_btrfs_bug = native_os == .linux and
        EnvVar.ZIG_BTRFS_WORKAROUND.isSet();
    const root_prog_node = std.Progress.start(.{
        .disable_printing = (color == .off),
        .root_name = "Compile Build Script",
    });
    defer root_prog_node.end();

    // Normally the build runner is compiled for the host target but here is
    // some code to help when debugging edits to the build runner so that you
    // can make sure it compiles successfully on other targets.
    const resolved_target: Package.Module.ResolvedTarget = t: {
        if (build_options.enable_debug_extensions) {
            if (debug_target) |triple| {
                const target_query = try std.Target.Query.parse(.{
                    .arch_os_abi = triple,
                });
                break :t .{
                    .result = std.zig.resolveTargetQueryOrFatal(target_query),
                    .is_native_os = false,
                    .is_native_abi = false,
                    .is_explicit_dynamic_linker = false,
                };
            }
        }
        break :t .{
            .result = std.zig.resolveTargetQueryOrFatal(.{}),
            .is_native_os = true,
            .is_native_abi = true,
            .is_explicit_dynamic_linker = false,
        };
    };

    process.raiseFileDescriptorLimit();

    const cwd_path = try introspect.getResolvedCwd(arena);
    const build_root = try findBuildRoot(arena, .{
        .cwd_path = cwd_path,
        .build_file = build_file,
    });

    // This `init` calls `fatal` on error.
    var dirs: Compilation.Directories = .init(
        arena,
        override_lib_dir,
        override_global_cache_dir,
        .{ .override = path: {
            if (override_local_cache_dir) |d| break :path d;
            break :path try build_root.directory.join(arena, &.{introspect.default_local_zig_cache_basename});
        } },
        {},
        self_exe_path,
    );
    defer dirs.deinit();

    child_argv.items[argv_index_zig_lib_dir] = dirs.zig_lib.path orelse cwd_path;
    child_argv.items[argv_index_build_file] = build_root.directory.path orelse cwd_path;
    child_argv.items[argv_index_global_cache_dir] = dirs.global_cache.path orelse cwd_path;
    child_argv.items[argv_index_cache_dir] = dirs.local_cache.path orelse cwd_path;

    var thread_pool: ThreadPool = undefined;
    try thread_pool.init(.{
        .allocator = gpa,
        .n_jobs = @min(@max(n_jobs orelse std.Thread.getCpuCount() catch 1, 1), std.math.maxInt(Zcu.PerThread.IdBacking)),
        .track_ids = true,
        .stack_size = thread_stack_size,
    });
    defer thread_pool.deinit();

    // Dummy http client that is not actually used when fetch_command is unsupported.
    // Prevents bootstrap from depending on a bunch of unnecessary stuff.
    var http_client: if (dev.env.supports(.fetch_command)) std.http.Client else struct {
        allocator: Allocator,
        fn deinit(_: @This()) void {}
    } = .{ .allocator = gpa };
    defer http_client.deinit();

    var unlazy_set: Package.Fetch.JobQueue.UnlazySet = .{};

    // This loop is re-evaluated when the build script exits with an indication that it
    // could not continue due to missing lazy dependencies.
    while (true) {
        // We want to release all the locks before executing the child process, so we make a nice
        // big block here to ensure the cleanup gets run when we extract out our argv.
        {
            const main_mod_paths: Package.Module.CreateOptions.Paths = if (override_build_runner) |runner| .{
                .root = try .fromUnresolved(arena, dirs, &.{fs.path.dirname(runner) orelse "."}),
                .root_src_path = fs.path.basename(runner),
            } else .{
                .root = try .fromRoot(arena, dirs, .zig_lib, "compiler"),
                .root_src_path = "build_runner.zig",
            };

            const config = try Compilation.Config.resolve(.{
                .output_mode = .Exe,
                .resolved_target = resolved_target,
                .have_zcu = true,
                .emit_bin = true,
                .is_test = false,
            });

            const root_mod = try Package.Module.create(arena, .{
                .paths = main_mod_paths,
                .fully_qualified_name = "root",
                .cc_argv = &.{},
                .inherited = .{
                    .resolved_target = resolved_target,
                },
                .global = config,
                .parent = null,
            });

            const build_mod = try Package.Module.create(arena, .{
                .paths = .{
                    .root = try .fromUnresolved(arena, dirs, &.{build_root.directory.path orelse "."}),
                    .root_src_path = build_root.build_zig_basename,
                },
                .fully_qualified_name = "root.@build",
                .cc_argv = &.{},
                .inherited = .{},
                .global = config,
                .parent = root_mod,
            });

            var cleanup_build_dir: ?fs.Dir = null;
            defer if (cleanup_build_dir) |*dir| dir.close();

            if (dev.env.supports(.fetch_command)) {
                const fetch_prog_node = root_prog_node.start("Fetch Packages", 0);
                defer fetch_prog_node.end();

                var job_queue: Package.Fetch.JobQueue = .{
                    .http_client = &http_client,
                    .thread_pool = &thread_pool,
                    .global_cache = dirs.global_cache,
                    .read_only = false,
                    .recursive = true,
                    .debug_hash = false,
                    .work_around_btrfs_bug = work_around_btrfs_bug,
                    .unlazy_set = unlazy_set,
                    .mode = fetch_mode,
                };
                defer job_queue.deinit();

                if (system_pkg_dir_path) |p| {
                    job_queue.global_cache = .{
                        .path = p,
                        .handle = fs.cwd().openDir(p, .{}) catch |err| {
                            fatal("unable to open system package directory '{s}': {s}", .{
                                p, @errorName(err),
                            });
                        },
                    };
                    job_queue.read_only = true;
                    cleanup_build_dir = job_queue.global_cache.handle;
                } else {
                    try http_client.initDefaultProxies(arena);
                }

                try job_queue.all_fetches.ensureUnusedCapacity(gpa, 1);
                try job_queue.table.ensureUnusedCapacity(gpa, 1);

                const phantom_package_root: Cache.Path = .{ .root_dir = build_root.directory };

                var fetch: Package.Fetch = .{
                    .arena = std.heap.ArenaAllocator.init(gpa),
                    .location = .{ .relative_path = phantom_package_root },
                    .location_tok = 0,
                    .hash_tok = .none,
                    .name_tok = 0,
                    .lazy_status = .eager,
                    .parent_package_root = phantom_package_root,
                    .parent_manifest_ast = null,
                    .prog_node = fetch_prog_node,
                    .job_queue = &job_queue,
                    .omit_missing_hash_error = true,
                    .allow_missing_paths_field = false,
                    .allow_missing_fingerprint = false,
                    .allow_name_string = false,
                    .use_latest_commit = false,

                    .package_root = undefined,
                    .error_bundle = undefined,
                    .manifest = null,
                    .manifest_ast = undefined,
                    .computed_hash = undefined,
                    .has_build_zig = true,
                    .oom_flag = false,
                    .latest_commit = null,

                    .module = build_mod,
                };
                job_queue.all_fetches.appendAssumeCapacity(&fetch);

                job_queue.table.putAssumeCapacityNoClobber(
                    Package.Fetch.relativePathDigest(phantom_package_root, dirs.global_cache),
                    &fetch,
                );

                job_queue.thread_pool.spawnWg(&job_queue.wait_group, Package.Fetch.workerRun, .{
                    &fetch, "root",
                });
                job_queue.wait_group.wait();

                try job_queue.consolidateErrors();

                if (fetch.error_bundle.root_list.items.len > 0) {
                    var errors = try fetch.error_bundle.toOwnedBundle("");
                    errors.renderToStdErr(color.renderOptions());
                    process.exit(1);
                }

                if (fetch_only) return cleanExit();

                var source_buf = std.ArrayList(u8).init(gpa);
                defer source_buf.deinit();
                try job_queue.createDependenciesSource(&source_buf);
                const deps_mod = try createDependenciesModule(
                    arena,
                    source_buf.items,
                    root_mod,
                    dirs,
                    config,
                );

                {
                    // We need a Module for each package's build.zig.
                    const hashes = job_queue.table.keys();
                    const fetches = job_queue.table.values();
                    try deps_mod.deps.ensureUnusedCapacity(arena, @intCast(hashes.len));
                    for (hashes, fetches) |*hash, f| {
                        if (f == &fetch) {
                            // The first one is a dummy package for the current project.
                            continue;
                        }
                        if (!f.has_build_zig)
                            continue;
                        const hash_slice = hash.toSlice();
                        const mod_root_path = try f.package_root.toString(arena);
                        const m = try Package.Module.create(arena, .{
                            .paths = .{
                                .root = try .fromUnresolved(arena, dirs, &.{mod_root_path}),
                                .root_src_path = Package.build_zig_basename,
                            },
                            .fully_qualified_name = try std.fmt.allocPrint(
                                arena,
                                "root.@dependencies.{s}",
                                .{hash_slice},
                            ),
                            .cc_argv = &.{},
                            .inherited = .{},
                            .global = config,
                            .parent = root_mod,
                        });
                        const hash_cloned = try arena.dupe(u8, hash_slice);
                        deps_mod.deps.putAssumeCapacityNoClobber(hash_cloned, m);
                        f.module = m;
                    }

                    // Each build.zig module needs access to each of its
                    // dependencies' build.zig modules by name.
                    for (fetches) |f| {
                        const mod = f.module orelse continue;
                        const man = f.manifest orelse continue;
                        const dep_names = man.dependencies.keys();
                        try mod.deps.ensureUnusedCapacity(arena, @intCast(dep_names.len));
                        for (dep_names, man.dependencies.values()) |name, dep| {
                            const dep_digest = Package.Fetch.depDigest(
                                f.package_root,
                                dirs.global_cache,
                                dep,
                            ) orelse continue;
                            const dep_mod = job_queue.table.get(dep_digest).?.module orelse continue;
                            const name_cloned = try arena.dupe(u8, name);
                            mod.deps.putAssumeCapacityNoClobber(name_cloned, dep_mod);
                        }
                    }
                }
            } else try createEmptyDependenciesModule(
                arena,
                root_mod,
                dirs,
                config,
            );

            try root_mod.deps.put(arena, "@build", build_mod);

            var windows_libs: std.StringArrayHashMapUnmanaged(void) = .empty;

            if (resolved_target.result.os.tag == .windows) {
                try windows_libs.ensureUnusedCapacity(arena, 2);
                windows_libs.putAssumeCapacity("advapi32", {});
                windows_libs.putAssumeCapacity("ws2_32", {}); // for `--listen` (web interface)
            }

            const comp = Compilation.create(gpa, arena, .{
                .dirs = dirs,
                .root_name = "build",
                .config = config,
                .root_mod = root_mod,
                .main_mod = build_mod,
                .emit_bin = .yes_cache,
                .self_exe_path = self_exe_path,
                .thread_pool = &thread_pool,
                .verbose_cc = verbose_cc,
                .verbose_link = verbose_link,
                .verbose_air = verbose_air,
                .verbose_intern_pool = verbose_intern_pool,
                .verbose_generic_instances = verbose_generic_instances,
                .verbose_llvm_ir = verbose_llvm_ir,
                .verbose_llvm_bc = verbose_llvm_bc,
                .verbose_cimport = verbose_cimport,
                .verbose_llvm_cpu_features = verbose_llvm_cpu_features,
                .cache_mode = .whole,
                .reference_trace = reference_trace,
                .debug_compile_errors = debug_compile_errors,
                .windows_lib_names = windows_libs.keys(),
            }) catch |err| {
                fatal("unable to create compilation: {s}", .{@errorName(err)});
            };
            defer comp.destroy();

            updateModule(comp, color, root_prog_node) catch |err| switch (err) {
                error.SemanticAnalyzeFail => process.exit(2),
                else => |e| return e,
            };

            // Since incremental compilation isn't done yet, we use cache_mode = whole
            // above, and thus the output file is already closed.
            //try comp.makeBinFileExecutable();
            child_argv.items[argv_index_exe] = try dirs.local_cache.join(arena, &.{
                "o",
                &Cache.binToHex(comp.digest.?),
                comp.emit_bin.?,
            });
        }

        if (process.can_spawn) {
            var child = std.process.Child.init(child_argv.items, gpa);
            child.stdin_behavior = .Inherit;
            child.stdout_behavior = .Inherit;
            child.stderr_behavior = .Inherit;

            const term = t: {
                std.debug.lockStdErr();
                defer std.debug.unlockStdErr();
                break :t child.spawnAndWait() catch |err| {
                    fatal("failed to spawn build runner {s}: {s}", .{ child_argv.items[0], @errorName(err) });
                };
            };

            switch (term) {
                .Exited => |code| {
                    if (code == 0) return cleanExit();
                    // Indicates that the build runner has reported compile errors
                    // and this parent process does not need to report any further
                    // diagnostics.
                    if (code == 2) process.exit(2);

                    if (code == 3) {
                        if (!dev.env.supports(.fetch_command)) process.exit(3);
                        // Indicates the configure phase failed due to missing lazy
                        // dependencies and stdout contains the hashes of the ones
                        // that are missing.
                        const s = fs.path.sep_str;
                        const tmp_sub_path = "tmp" ++ s ++ results_tmp_file_nonce;
                        const stdout = dirs.local_cache.handle.readFileAlloc(arena, tmp_sub_path, 50 * 1024 * 1024) catch |err| {
                            fatal("unable to read results of configure phase from '{f}{s}': {s}", .{
                                dirs.local_cache, tmp_sub_path, @errorName(err),
                            });
                        };
                        dirs.local_cache.handle.deleteFile(tmp_sub_path) catch {};

                        var it = mem.splitScalar(u8, stdout, '\n');
                        var any_errors = false;
                        while (it.next()) |hash| {
                            if (hash.len == 0) continue;
                            if (hash.len > Package.Hash.max_len) {
                                std.log.err("invalid digest (length {d} exceeds maximum): '{s}'", .{
                                    hash.len, hash,
                                });
                                any_errors = true;
                                continue;
                            }
                            try unlazy_set.put(arena, .fromSlice(hash), {});
                        }
                        if (any_errors) process.exit(3);
                        if (system_pkg_dir_path) |p| {
                            // In this mode, the system needs to provide these packages; they
                            // cannot be fetched by Zig.
                            for (unlazy_set.keys()) |*hash| {
                                std.log.err("lazy dependency package not found: {s}" ++ s ++ "{s}", .{
                                    p, hash.toSlice(),
                                });
                            }
                            std.log.info("remote package fetching disabled due to --system mode", .{});
                            std.log.info("dependencies might be avoidable depending on build configuration", .{});
                            process.exit(3);
                        }
                        continue;
                    }

                    const cmd = try std.mem.join(arena, " ", child_argv.items);
                    fatal("the following build command failed with exit code {d}:\n{s}", .{ code, cmd });
                },
                else => {
                    const cmd = try std.mem.join(arena, " ", child_argv.items);
                    fatal("the following build command crashed:\n{s}", .{cmd});
                },
            }
        } else {
            const cmd = try std.mem.join(arena, " ", child_argv.items);
            fatal("the following command cannot be executed ({s} does not support spawning a child process):\n{s}", .{ @tagName(native_os), cmd });
        }
    }
}

const JitCmdOptions = struct {
    cmd_name: []const u8,
    root_src_path: []const u8,
    windows_libs: []const []const u8 = &.{},
    prepend_zig_lib_dir_path: bool = false,
    prepend_global_cache_path: bool = false,
    prepend_zig_exe_path: bool = false,
    depend_on_aro: bool = false,
    capture: ?*[]u8 = null,
    /// Send error bundles via std.zig.Server over stdout
    server: bool = false,
    progress_node: ?std.Progress.Node = null,
};

fn jitCmd(
    gpa: Allocator,
    arena: Allocator,
    args: []const []const u8,
    options: JitCmdOptions,
) !void {
    dev.check(.jit_command);

    const color: Color = .auto;
    const root_prog_node = if (options.progress_node) |node| node else std.Progress.start(.{
        .disable_printing = (color == .off),
    });

    const target_query: std.Target.Query = .{};
    const resolved_target: Package.Module.ResolvedTarget = .{
        .result = std.zig.resolveTargetQueryOrFatal(target_query),
        .is_native_os = true,
        .is_native_abi = true,
        .is_explicit_dynamic_linker = false,
    };

    const self_exe_path = fs.selfExePathAlloc(arena) catch |err| {
        fatal("unable to find self exe path: {s}", .{@errorName(err)});
    };

    const optimize_mode: std.builtin.OptimizeMode = if (EnvVar.ZIG_DEBUG_CMD.isSet())
        .Debug
    else
        .ReleaseFast;
    const strip = optimize_mode != .Debug;
    const override_lib_dir: ?[]const u8 = try EnvVar.ZIG_LIB_DIR.get(arena);
    const override_global_cache_dir: ?[]const u8 = try EnvVar.ZIG_GLOBAL_CACHE_DIR.get(arena);

    // This `init` calls `fatal` on error.
    var dirs: Compilation.Directories = .init(
        arena,
        override_lib_dir,
        override_global_cache_dir,
        .global,
        if (native_os == .wasi) wasi_preopens,
        self_exe_path,
    );
    defer dirs.deinit();

    var thread_pool: ThreadPool = undefined;
    try thread_pool.init(.{
        .allocator = gpa,
        .n_jobs = @min(@max(std.Thread.getCpuCount() catch 1, 1), std.math.maxInt(Zcu.PerThread.IdBacking)),
        .track_ids = true,
        .stack_size = thread_stack_size,
    });
    defer thread_pool.deinit();

    var child_argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try child_argv.ensureUnusedCapacity(arena, args.len + 4);

    // We want to release all the locks before executing the child process, so we make a nice
    // big block here to ensure the cleanup gets run when we extract out our argv.
    {
        const main_mod_paths: Package.Module.CreateOptions.Paths = .{
            .root = try .fromRoot(arena, dirs, .zig_lib, "compiler"),
            .root_src_path = options.root_src_path,
        };

        const config = try Compilation.Config.resolve(.{
            .output_mode = .Exe,
            .root_strip = strip,
            .root_optimize_mode = optimize_mode,
            .resolved_target = resolved_target,
            .have_zcu = true,
            .emit_bin = true,
            .is_test = false,
        });

        const root_mod = try Package.Module.create(arena, .{
            .paths = main_mod_paths,
            .fully_qualified_name = "root",
            .cc_argv = &.{},
            .inherited = .{
                .resolved_target = resolved_target,
                .optimize_mode = optimize_mode,
                .strip = strip,
            },
            .global = config,
            .parent = null,
        });

        if (options.depend_on_aro) {
            const aro_mod = try Package.Module.create(arena, .{
                .paths = .{
                    .root = try .fromRoot(arena, dirs, .zig_lib, "compiler/aro"),
                    .root_src_path = "aro.zig",
                },
                .fully_qualified_name = "aro",
                .cc_argv = &.{},
                .inherited = .{
                    .resolved_target = resolved_target,
                    .optimize_mode = optimize_mode,
                    .strip = strip,
                },
                .global = config,
                .parent = null,
            });
            try root_mod.deps.put(arena, "aro", aro_mod);
        }

        var windows_libs: std.StringArrayHashMapUnmanaged(void) = .empty;

        if (resolved_target.result.os.tag == .windows) {
            try windows_libs.ensureUnusedCapacity(arena, options.windows_libs.len);
            for (options.windows_libs) |lib| windows_libs.putAssumeCapacity(lib, {});
        }

        const comp = Compilation.create(gpa, arena, .{
            .dirs = dirs,
            .root_name = options.cmd_name,
            .config = config,
            .root_mod = root_mod,
            .main_mod = root_mod,
            .emit_bin = .yes_cache,
            .self_exe_path = self_exe_path,
            .thread_pool = &thread_pool,
            .cache_mode = .whole,
            .windows_lib_names = windows_libs.keys(),
        }) catch |err| {
            fatal("unable to create compilation: {s}", .{@errorName(err)});
        };
        defer comp.destroy();

        if (options.server) {
            var stdout_writer = fs.File.stdout().writer(&stdout_buffer);
            var server: std.zig.Server = .{
                .out = &stdout_writer.interface,
                .in = undefined, // won't be receiving messages
            };

            try comp.update(root_prog_node);

            var error_bundle = try comp.getAllErrorsAlloc();
            defer error_bundle.deinit(comp.gpa);
            if (error_bundle.errorMessageCount() > 0) {
                try server.serveErrorBundle(error_bundle);
                process.exit(2);
            }
        } else {
            updateModule(comp, color, root_prog_node) catch |err| switch (err) {
                error.SemanticAnalyzeFail => process.exit(2),
                else => |e| return e,
            };
        }

        const exe_path = try dirs.global_cache.join(arena, &.{
            "o",
            &Cache.binToHex(comp.digest.?),
            comp.emit_bin.?,
        });
        child_argv.appendAssumeCapacity(exe_path);
    }

    if (options.prepend_zig_lib_dir_path)
        child_argv.appendAssumeCapacity(dirs.zig_lib.path.?);
    if (options.prepend_zig_exe_path)
        child_argv.appendAssumeCapacity(self_exe_path);
    if (options.prepend_global_cache_path)
        child_argv.appendAssumeCapacity(dirs.global_cache.path.?);

    child_argv.appendSliceAssumeCapacity(args);

    if (process.can_execv and options.capture == null) {
        const err = process.execv(gpa, child_argv.items);
        const cmd = try std.mem.join(arena, " ", child_argv.items);
        fatal("the following command failed to execve with '{s}':\n{s}", .{
            @errorName(err),
            cmd,
        });
    }

    if (!process.can_spawn) {
        const cmd = try std.mem.join(arena, " ", child_argv.items);
        fatal("the following command cannot be executed ({s} does not support spawning a child process):\n{s}", .{
            @tagName(native_os), cmd,
        });
    }

    var child = std.process.Child.init(child_argv.items, gpa);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = if (options.capture == null) .Inherit else .Pipe;
    child.stderr_behavior = .Inherit;

    try child.spawn();

    if (options.capture) |ptr| {
        ptr.* = try child.stdout.?.readToEndAlloc(arena, std.math.maxInt(u32));
    }

    const term = try child.wait();
    switch (term) {
        .Exited => |code| {
            if (code == 0) {
                if (options.capture != null) return;
                return cleanExit();
            }
            const cmd = try std.mem.join(arena, " ", child_argv.items);
            fatal("the following build command failed with exit code {d}:\n{s}", .{ code, cmd });
        },
        else => {
            const cmd = try std.mem.join(arena, " ", child_argv.items);
            fatal("the following build command crashed:\n{s}", .{cmd});
        },
    }
}

const info_zen =
    \\
    \\ * Communicate intent precisely.
    \\ * Edge cases matter.
    \\ * Favor reading code over writing code.
    \\ * Only one obvious way to do things.
    \\ * Runtime crashes are better than bugs.
    \\ * Compile errors are better than runtime crashes.
    \\ * Incremental improvements.
    \\ * Avoid local maximums.
    \\ * Reduce the amount one must remember.
    \\ * Focus on code rather than style.
    \\ * Resource allocation may fail; resource deallocation must succeed.
    \\ * Memory is a resource.
    \\ * Together we serve the users.
    \\
    \\
;

extern fn ZigClangIsLLVMUsingSeparateLibcxx() bool;

extern "c" fn ZigClang_main(argc: c_int, argv: [*:null]?[*:0]u8) c_int;
extern "c" fn ZigLlvmAr_main(argc: c_int, argv: [*:null]?[*:0]u8) c_int;

fn argsCopyZ(alloc: Allocator, args: []const []const u8) ![:null]?[*:0]u8 {
    var argv = try alloc.allocSentinel(?[*:0]u8, args.len, null);
    for (args, 0..) |arg, i| {
        argv[i] = try alloc.dupeZ(u8, arg); // TODO If there was an argsAllocZ we could avoid this allocation.
    }
    return argv;
}

pub fn clangMain(alloc: Allocator, args: []const []const u8) error{OutOfMemory}!u8 {
    if (!build_options.have_llvm)
        fatal("`zig cc` and `zig c++` unavailable: compiler built without LLVM extensions", .{});

    var arena_instance = std.heap.ArenaAllocator.init(alloc);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    // Convert the args to the null-terminated format Clang expects.
    const argv = try argsCopyZ(arena, args);
    const exit_code = ZigClang_main(@as(c_int, @intCast(argv.len)), argv.ptr);
    return @as(u8, @bitCast(@as(i8, @truncate(exit_code))));
}

pub fn llvmArMain(alloc: Allocator, args: []const []const u8) error{OutOfMemory}!u8 {
    if (!build_options.have_llvm)
        fatal("`zig ar`, `zig dlltool`, `zig ranlib', and `zig lib` unavailable: compiler built without LLVM extensions", .{});

    var arena_instance = std.heap.ArenaAllocator.init(alloc);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    // Convert the args to the format llvm-ar expects.
    // We intentionally shave off the zig binary at args[0].
    const argv = try argsCopyZ(arena, args[1..]);
    const exit_code = ZigLlvmAr_main(@as(c_int, @intCast(argv.len)), argv.ptr);
    return @as(u8, @bitCast(@as(i8, @truncate(exit_code))));
}

/// The first argument determines which backend is invoked. The options are:
/// * `ld.lld` - ELF
/// * `lld-link` - COFF
/// * `wasm-ld` - WebAssembly
pub fn lldMain(
    alloc: Allocator,
    args: []const []const u8,
    can_exit_early: bool,
) error{OutOfMemory}!u8 {
    if (!build_options.have_llvm)
        fatal("`zig {s}` unavailable: compiler built without LLVM extensions", .{args[0]});

    // Print a warning if lld is called multiple times in the same process,
    // since it may misbehave
    // https://github.com/ziglang/zig/issues/3825
    const CallCounter = struct {
        var count: usize = 0;
    };
    if (CallCounter.count == 1) { // Issue the warning on the first repeat call
        warn("invoking LLD for the second time within the same process because the host OS ({s}) does not support spawning child processes. This sometimes activates LLD bugs", .{@tagName(native_os)});
    }
    CallCounter.count += 1;

    var arena_instance = std.heap.ArenaAllocator.init(alloc);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    // Convert the args to the format LLD expects.
    // We intentionally shave off the zig binary at args[0].
    const argv = try argsCopyZ(arena, args[1..]);
    // "If an error occurs, false will be returned."
    const ok = rc: {
        const llvm = @import("codegen/llvm/bindings.zig");
        const argc = @as(c_int, @intCast(argv.len));
        if (mem.eql(u8, args[1], "ld.lld")) {
            break :rc llvm.LinkELF(argc, argv.ptr, can_exit_early, false);
        } else if (mem.eql(u8, args[1], "lld-link")) {
            break :rc llvm.LinkCOFF(argc, argv.ptr, can_exit_early, false);
        } else if (mem.eql(u8, args[1], "wasm-ld")) {
            break :rc llvm.LinkWasm(argc, argv.ptr, can_exit_early, false);
        } else {
            unreachable;
        }
    };
    return @intFromBool(!ok);
}

const ArgIteratorResponseFile = process.ArgIteratorGeneral(.{ .comments = true, .single_quotes = true });

/// Initialize the arguments from a Response File. "*.rsp"
fn initArgIteratorResponseFile(allocator: Allocator, resp_file_path: []const u8) !ArgIteratorResponseFile {
    const max_bytes = 10 * 1024 * 1024; // 10 MiB of command line arguments is a reasonable limit
    const cmd_line = try fs.cwd().readFileAlloc(allocator, resp_file_path, max_bytes);
    errdefer allocator.free(cmd_line);

    return ArgIteratorResponseFile.initTakeOwnership(allocator, cmd_line);
}

const clang_args = @import("clang_options.zig").list;

pub const ClangArgIterator = struct {
    has_next: bool,
    zig_equivalent: ZigEquivalent,
    only_arg: []const u8,
    second_arg: []const u8,
    other_args: []const []const u8,
    argv: []const []const u8,
    next_index: usize,
    root_args: ?*Args,
    arg_iterator_response_file: ArgIteratorResponseFile,
    arena: Allocator,

    pub const ZigEquivalent = enum {
        target,
        o,
        c,
        r,
        m,
        x,
        other,
        positional,
        l,
        ignore,
        driver_punt,
        pic,
        no_pic,
        pie,
        no_pie,
        lto,
        no_lto,
        unwind_tables,
        no_unwind_tables,
        asynchronous_unwind_tables,
        no_asynchronous_unwind_tables,
        nostdlib,
        nostdlib_cpp,
        shared,
        rdynamic,
        wl,
        wp,
        preprocess_only,
        asm_only,
        optimize,
        debug,
        gdwarf32,
        gdwarf64,
        sanitize,
        no_sanitize,
        sanitize_trap,
        no_sanitize_trap,
        linker_script,
        dry_run,
        verbose,
        for_linker,
        linker_input_z,
        lib_dir,
        mcpu,
        dep_file,
        dep_file_to_stdout,
        framework_dir,
        framework,
        nostdlibinc,
        red_zone,
        no_red_zone,
        omit_frame_pointer,
        no_omit_frame_pointer,
        function_sections,
        no_function_sections,
        data_sections,
        no_data_sections,
        builtin,
        no_builtin,
        color_diagnostics,
        no_color_diagnostics,
        stack_check,
        no_stack_check,
        stack_protector,
        no_stack_protector,
        strip,
        exec_model,
        emit_llvm,
        sysroot,
        entry,
        force_undefined_symbol,
        weak_library,
        weak_framework,
        headerpad_max_install_names,
        compress_debug_sections,
        install_name,
        undefined,
        force_load_objc,
        mingw_unicode_entry_point,
        san_cov_trace_pc_guard,
        san_cov,
        no_san_cov,
        rtlib,
        static,
        dynamic,
    };

    const Args = struct {
        next_index: usize,
        argv: []const []const u8,
    };

    fn init(arena: Allocator, argv: []const []const u8) ClangArgIterator {
        return .{
            .next_index = 2, // `zig cc foo` this points to `foo`
            .has_next = argv.len > 2,
            .zig_equivalent = undefined,
            .only_arg = undefined,
            .second_arg = undefined,
            .other_args = undefined,
            .argv = argv,
            .root_args = null,
            .arg_iterator_response_file = undefined,
            .arena = arena,
        };
    }

    fn next(self: *ClangArgIterator) !void {
        assert(self.has_next);
        assert(self.next_index < self.argv.len);
        // In this state we know that the parameter we are looking at is a root parameter
        // rather than an argument to a parameter.
        // We adjust the len below when necessary.
        self.other_args = (self.argv.ptr + self.next_index)[0..1];
        var arg = self.argv[self.next_index];
        self.incrementArgIndex();

        if (mem.startsWith(u8, arg, "@")) {
            if (self.root_args != null) return error.NestedResponseFile;

            // This is a "compiler response file". We must parse the file and treat its
            // contents as command line parameters.
            const arena = self.arena;
            const resp_file_path = arg[1..];

            self.arg_iterator_response_file =
                initArgIteratorResponseFile(arena, resp_file_path) catch |err| {
                    fatal("unable to read response file '{s}': {s}", .{ resp_file_path, @errorName(err) });
                };
            // NOTE: The ArgIteratorResponseFile returns tokens from next() that are slices of an
            // internal buffer. This internal buffer is arena allocated, so it is not cleaned up here.

            var resp_arg_list = std.ArrayList([]const u8).init(arena);
            defer resp_arg_list.deinit();
            {
                while (self.arg_iterator_response_file.next()) |token| {
                    try resp_arg_list.append(token);
                }

                const args = try arena.create(Args);
                errdefer arena.destroy(args);
                args.* = .{
                    .next_index = self.next_index,
                    .argv = self.argv,
                };
                self.root_args = args;
            }
            const resp_arg_slice = try resp_arg_list.toOwnedSlice();
            self.next_index = 0;
            self.argv = resp_arg_slice;

            if (resp_arg_slice.len == 0) {
                self.resolveRespFileArgs();
                return;
            }

            self.has_next = true;
            self.other_args = (self.argv.ptr + self.next_index)[0..1]; // We adjust len below when necessary.
            arg = self.argv[self.next_index];
            self.incrementArgIndex();
        }

        if (mem.eql(u8, arg, "-") or !mem.startsWith(u8, arg, "-")) {
            self.zig_equivalent = .positional;
            self.only_arg = arg;
            return;
        }

        find_clang_arg: for (clang_args) |clang_arg| switch (clang_arg.syntax) {
            .flag => {
                const prefix_len = clang_arg.matchEql(arg);
                if (prefix_len > 0) {
                    self.zig_equivalent = clang_arg.zig_equivalent;
                    self.only_arg = arg[prefix_len..];

                    break :find_clang_arg;
                }
            },
            .joined, .comma_joined => {
                // joined example: --target=foo
                // comma_joined example: -Wl,-soname,libsoundio.so.2
                const prefix_len = clang_arg.matchStartsWith(arg);
                if (prefix_len != 0) {
                    self.zig_equivalent = clang_arg.zig_equivalent;
                    self.only_arg = arg[prefix_len..]; // This will skip over the "--target=" part.

                    break :find_clang_arg;
                }
            },
            .joined_or_separate => {
                // Examples: `-lfoo`, `-l foo`
                const prefix_len = clang_arg.matchStartsWith(arg);
                if (prefix_len == arg.len) {
                    if (self.next_index >= self.argv.len) {
                        fatal("Expected parameter after '{s}'", .{arg});
                    }
                    self.only_arg = self.argv[self.next_index];
                    self.incrementArgIndex();
                    self.other_args.len += 1;
                    self.zig_equivalent = clang_arg.zig_equivalent;

                    break :find_clang_arg;
                } else if (prefix_len != 0) {
                    self.zig_equivalent = clang_arg.zig_equivalent;
                    self.only_arg = arg[prefix_len..];

                    break :find_clang_arg;
                }
            },
            .joined_and_separate => {
                // Example: `-Xopenmp-target=riscv64-linux-unknown foo`
                const prefix_len = clang_arg.matchStartsWith(arg);
                if (prefix_len != 0) {
                    self.only_arg = arg[prefix_len..];
                    if (self.next_index >= self.argv.len) {
                        fatal("Expected parameter after '{s}'", .{arg});
                    }
                    self.second_arg = self.argv[self.next_index];
                    self.incrementArgIndex();
                    self.other_args.len += 1;
                    self.zig_equivalent = clang_arg.zig_equivalent;
                    break :find_clang_arg;
                }
            },
            .separate => if (clang_arg.matchEql(arg) > 0) {
                if (self.next_index >= self.argv.len) {
                    fatal("Expected parameter after '{s}'", .{arg});
                }
                self.only_arg = self.argv[self.next_index];
                self.incrementArgIndex();
                self.other_args.len += 1;
                self.zig_equivalent = clang_arg.zig_equivalent;
                break :find_clang_arg;
            },
            .remaining_args_joined => {
                const prefix_len = clang_arg.matchStartsWith(arg);
                if (prefix_len != 0) {
                    @panic("TODO");
                }
            },
            .multi_arg => |num_args| if (clang_arg.matchEql(arg) > 0) {
                // Example `-sectcreate <arg1> <arg2> <arg3>`.
                var i: usize = 0;
                while (i < num_args) : (i += 1) {
                    self.incrementArgIndex();
                    self.other_args.len += 1;
                }
                self.zig_equivalent = clang_arg.zig_equivalent;
                break :find_clang_arg;
            },
        } else {
            fatal("Unknown Clang option: '{s}'", .{arg});
        }
    }

    fn incrementArgIndex(self: *ClangArgIterator) void {
        self.next_index += 1;
        self.resolveRespFileArgs();
    }

    fn resolveRespFileArgs(self: *ClangArgIterator) void {
        const arena = self.arena;
        if (self.next_index >= self.argv.len) {
            if (self.root_args) |root_args| {
                self.next_index = root_args.next_index;
                self.argv = root_args.argv;

                arena.destroy(root_args);
                self.root_args = null;
            }
            if (self.next_index >= self.argv.len) {
                self.has_next = false;
            }
        }
    }
};

fn parseCodeModel(arg: []const u8) std.builtin.CodeModel {
    return std.meta.stringToEnum(std.builtin.CodeModel, arg) orelse
        fatal("unsupported machine code model: '{s}'", .{arg});
}

const usage_ast_check =
    \\Usage: zig ast-check [file]
    \\
    \\    Given a .zig source file or .zon file, reports any compile errors
    \\    that can be ascertained on the basis of the source code alone,
    \\    without target information or type checking.
    \\
    \\    If [file] is omitted, stdin is used.
    \\
    \\Options:
    \\  -h, --help            Print this help and exit
    \\  --color [auto|off|on] Enable or disable colored error messages
    \\  --zon                 Treat the input file as ZON, regardless of file extension
    \\  -t                    (debug option) Output ZIR in text form to stdout
    \\
    \\
;

fn cmdAstCheck(
    arena: Allocator,
    args: []const []const u8,
) !void {
    dev.check(.ast_check_command);

    const Zir = std.zig.Zir;

    var color: Color = .auto;
    var want_output_text = false;
    var force_zon = false;
    var zig_source_path: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (mem.startsWith(u8, arg, "-")) {
            if (mem.eql(u8, arg, "-h") or mem.eql(u8, arg, "--help")) {
                try fs.File.stdout().writeAll(usage_ast_check);
                return cleanExit();
            } else if (mem.eql(u8, arg, "-t")) {
                want_output_text = true;
            } else if (mem.eql(u8, arg, "--zon")) {
                force_zon = true;
            } else if (mem.eql(u8, arg, "--color")) {
                if (i + 1 >= args.len) {
                    fatal("expected [auto|on|off] after --color", .{});
                }
                i += 1;
                const next_arg = args[i];
                color = std.meta.stringToEnum(Color, next_arg) orelse {
                    fatal("expected [auto|on|off] after --color, found '{s}'", .{next_arg});
                };
            } else {
                fatal("unrecognized parameter: '{s}'", .{arg});
            }
        } else if (zig_source_path == null) {
            zig_source_path = arg;
        } else {
            fatal("extra positional parameter: '{s}'", .{arg});
        }
    }

    const display_path = zig_source_path orelse "<stdin>";
    const source: [:0]const u8 = s: {
        var f = if (zig_source_path) |p| file: {
            break :file fs.cwd().openFile(p, .{}) catch |err| {
                fatal("unable to open file '{s}' for ast-check: {s}", .{ display_path, @errorName(err) });
            };
        } else fs.File.stdin();
        defer if (zig_source_path != null) f.close();
        var file_reader: fs.File.Reader = f.reader(&stdin_buffer);
        break :s std.zig.readSourceFileToEndAlloc(arena, &file_reader) catch |err| {
            fatal("unable to load file '{s}' for ast-check: {s}", .{ display_path, @errorName(err) });
        };
    };

    const mode: Ast.Mode = mode: {
        if (force_zon) break :mode .zon;
        if (zig_source_path) |path| {
            if (mem.endsWith(u8, path, ".zon")) {
                break :mode .zon;
            }
        }
        break :mode .zig;
    };

    const tree = try Ast.parse(arena, source, mode);

    var stdout_writer = fs.File.stdout().writerStreaming(&stdout_buffer);
    const stdout_bw = &stdout_writer.interface;
    switch (mode) {
        .zig => {
            const zir = try AstGen.generate(arena, tree);

            if (zir.hasCompileErrors()) {
                var wip_errors: std.zig.ErrorBundle.Wip = undefined;
                try wip_errors.init(arena);
                try wip_errors.addZirErrorMessages(zir, tree, source, display_path);
                var error_bundle = try wip_errors.toOwnedBundle("");
                error_bundle.renderToStdErr(color.renderOptions());
                if (zir.loweringFailed()) {
                    process.exit(1);
                }
            }

            if (!want_output_text) {
                if (zir.hasCompileErrors()) {
                    process.exit(1);
                } else {
                    return cleanExit();
                }
            }
            if (!build_options.enable_debug_extensions) {
                fatal("-t option only available in builds of zig with debug extensions", .{});
            }

            {
                const token_bytes = @sizeOf(Ast.TokenList) +
                    tree.tokens.len * (@sizeOf(std.zig.Token.Tag) + @sizeOf(Ast.ByteOffset));
                const tree_bytes = @sizeOf(Ast) + tree.nodes.len *
                    (@sizeOf(Ast.Node.Tag) +
                        @sizeOf(Ast.TokenIndex) +
                        // Here we don't use @sizeOf(Ast.Node.Data) because it would include
                        // the debug safety tag but we want to measure release size.
                        8);
                const instruction_bytes = zir.instructions.len *
                    // Here we don't use @sizeOf(Zir.Inst.Data) because it would include
                    // the debug safety tag but we want to measure release size.
                    (@sizeOf(Zir.Inst.Tag) + 8);
                const extra_bytes = zir.extra.len * @sizeOf(u32);
                const total_bytes = @sizeOf(Zir) + instruction_bytes + extra_bytes +
                    zir.string_bytes.len * @sizeOf(u8);
                // zig fmt: off
                try stdout_bw.print(
                    \\# Source bytes:       {Bi}
                    \\# Tokens:             {} ({Bi})
                    \\# AST Nodes:          {} ({Bi})
                    \\# Total ZIR bytes:    {Bi}
                    \\# Instructions:       {d} ({Bi})
                    \\# String Table Bytes: {}
                    \\# Extra Data Items:   {d} ({Bi})
                    \\
                , .{
                    source.len,
                    tree.tokens.len, token_bytes,
                    tree.nodes.len, tree_bytes,
                    total_bytes,
                    zir.instructions.len, instruction_bytes,
                    zir.string_bytes.len,
                    zir.extra.len, extra_bytes,
                });
                // zig fmt: on
            }

            try @import("print_zir.zig").renderAsText(arena, tree, zir, stdout_bw);
            try stdout_bw.flush();

            if (zir.hasCompileErrors()) {
                process.exit(1);
            } else {
                return cleanExit();
            }
        },
        .zon => {
            const zoir = try ZonGen.generate(arena, tree, .{});
            if (zoir.hasCompileErrors()) {
                var wip_errors: std.zig.ErrorBundle.Wip = undefined;
                try wip_errors.init(arena);
                try wip_errors.addZoirErrorMessages(zoir, tree, source, display_path);
                var error_bundle = try wip_errors.toOwnedBundle("");
                error_bundle.renderToStdErr(color.renderOptions());
                process.exit(1);
            }

            if (!want_output_text) {
                return cleanExit();
            }

            if (!build_options.enable_debug_extensions) {
                fatal("-t option only available in builds of zig with debug extensions", .{});
            }

            try @import("print_zoir.zig").renderToWriter(zoir, arena, stdout_bw);
            try stdout_bw.flush();
            return cleanExit();
        },
    }
}

fn cmdDetectCpu(args: []const []const u8) !void {
    dev.check(.detect_cpu_command);

    const detect_cpu_usage =
        \\Usage: zig detect-cpu [--llvm]
        \\
        \\    Print the host CPU name and feature set to stdout.
        \\
        \\Options:
        \\  -h, --help                    Print this help and exit
        \\  --llvm                        Detect using LLVM API
        \\
    ;

    var use_llvm = false;

    {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (mem.startsWith(u8, arg, "-")) {
                if (mem.eql(u8, arg, "-h") or mem.eql(u8, arg, "--help")) {
                    try fs.File.stdout().writeAll(detect_cpu_usage);
                    return cleanExit();
                } else if (mem.eql(u8, arg, "--llvm")) {
                    use_llvm = true;
                } else {
                    fatal("unrecognized parameter: '{s}'", .{arg});
                }
            } else {
                fatal("unexpected extra parameter: '{s}'", .{arg});
            }
        }
    }

    if (use_llvm) {
        if (!build_options.have_llvm)
            fatal("compiler does not use LLVM; cannot compare CPU features with LLVM", .{});

        const llvm = @import("codegen/llvm/bindings.zig");
        const name = llvm.GetHostCPUName() orelse fatal("LLVM could not figure out the host cpu name", .{});
        const features = llvm.GetHostCPUFeatures() orelse fatal("LLVM could not figure out the host cpu feature set", .{});
        const cpu = try detectNativeCpuWithLLVM(builtin.cpu.arch, name, features);
        try printCpu(cpu);
    } else {
        const host_target = std.zig.resolveTargetQueryOrFatal(.{});
        try printCpu(host_target.cpu);
    }
}

fn detectNativeCpuWithLLVM(
    arch: std.Target.Cpu.Arch,
    llvm_cpu_name_z: ?[*:0]const u8,
    llvm_cpu_features_opt: ?[*:0]const u8,
) !std.Target.Cpu {
    var result = std.Target.Cpu.baseline(arch, builtin.os);

    if (llvm_cpu_name_z) |cpu_name_z| {
        const llvm_cpu_name = mem.span(cpu_name_z);

        for (arch.allCpuModels()) |model| {
            const this_llvm_name = model.llvm_name orelse continue;
            if (mem.eql(u8, this_llvm_name, llvm_cpu_name)) {
                // Here we use the non-dependencies-populated set,
                // so that subtracting features later in this function
                // affect the prepopulated set.
                result = std.Target.Cpu{
                    .arch = arch,
                    .model = model,
                    .features = model.features,
                };
                break;
            }
        }
    }

    const all_features = arch.allFeaturesList();

    if (llvm_cpu_features_opt) |llvm_cpu_features| {
        var it = mem.tokenizeScalar(u8, mem.span(llvm_cpu_features), ',');
        while (it.next()) |decorated_llvm_feat| {
            var op: enum {
                add,
                sub,
            } = undefined;
            var llvm_feat: []const u8 = undefined;
            if (mem.startsWith(u8, decorated_llvm_feat, "+")) {
                op = .add;
                llvm_feat = decorated_llvm_feat[1..];
            } else if (mem.startsWith(u8, decorated_llvm_feat, "-")) {
                op = .sub;
                llvm_feat = decorated_llvm_feat[1..];
            } else {
                return error.InvalidLlvmCpuFeaturesFormat;
            }
            for (all_features, 0..) |feature, index_usize| {
                const this_llvm_name = feature.llvm_name orelse continue;
                if (mem.eql(u8, llvm_feat, this_llvm_name)) {
                    const index: std.Target.Cpu.Feature.Set.Index = @intCast(index_usize);
                    switch (op) {
                        .add => result.features.addFeature(index),
                        .sub => result.features.removeFeature(index),
                    }
                    break;
                }
            }
        }
    }

    result.features.populateDependencies(all_features);
    return result;
}

fn printCpu(cpu: std.Target.Cpu) !void {
    var stdout_writer = fs.File.stdout().writerStreaming(&stdout_buffer);
    const stdout_bw = &stdout_writer.interface;

    if (cpu.model.llvm_name) |llvm_name| {
        try stdout_bw.print("{s}\n", .{llvm_name});
    }

    const all_features = cpu.arch.allFeaturesList();
    for (all_features, 0..) |feature, index_usize| {
        const llvm_name = feature.llvm_name orelse continue;
        const index: std.Target.Cpu.Feature.Set.Index = @intCast(index_usize);
        const is_enabled = cpu.features.isEnabled(index);
        const plus_or_minus = "-+"[@intFromBool(is_enabled)];
        try stdout_bw.print("{c}{s}\n", .{ plus_or_minus, llvm_name });
    }

    try stdout_bw.flush();
}

fn cmdDumpLlvmInts(
    gpa: Allocator,
    arena: Allocator,
    args: []const []const u8,
) !void {
    dev.check(.llvm_ints_command);

    _ = gpa;

    if (!build_options.have_llvm)
        fatal("compiler does not use LLVM; cannot dump LLVM integer sizes", .{});

    const triple = try arena.dupeZ(u8, args[0]);

    const llvm = @import("codegen/llvm/bindings.zig");

    for ([_]std.Target.Cpu.Arch{ .aarch64, .x86 }) |arch| {
        @import("codegen/llvm.zig").initializeLLVMTarget(arch);
    }

    const target: *llvm.Target = t: {
        var target: *llvm.Target = undefined;
        var error_message: [*:0]const u8 = undefined;
        if (llvm.Target.getFromTriple(triple, &target, &error_message) != .False) @panic("bad");
        break :t target;
    };
    const tm = llvm.TargetMachine.create(target, triple, null, null, .None, .Default, .Default, false, false, .Default, null, false);
    const dl = tm.createTargetDataLayout();
    const context = llvm.Context.create();

    var stdout_writer = fs.File.stdout().writerStreaming(&stdout_buffer);
    const stdout_bw = &stdout_writer.interface;
    for ([_]u16{ 1, 8, 16, 32, 64, 128, 256 }) |bits| {
        const int_type = context.intType(bits);
        const alignment = dl.abiAlignmentOfType(int_type);
        try stdout_bw.print("LLVMABIAlignmentOfType(i{d}) == {d}\n", .{ bits, alignment });
    }
    try stdout_bw.flush();

    return cleanExit();
}

/// This is only enabled for debug builds.
fn cmdDumpZir(
    arena: Allocator,
    args: []const []const u8,
) !void {
    dev.check(.dump_zir_command);

    const Zir = std.zig.Zir;

    const cache_file = args[0];

    var f = fs.cwd().openFile(cache_file, .{}) catch |err| {
        fatal("unable to open zir cache file for dumping '{s}': {s}", .{ cache_file, @errorName(err) });
    };
    defer f.close();

    const zir = try Zcu.loadZirCache(arena, f);
    var stdout_writer = fs.File.stdout().writerStreaming(&stdout_buffer);
    const stdout_bw = &stdout_writer.interface;
    {
        const instruction_bytes = zir.instructions.len *
            // Here we don't use @sizeOf(Zir.Inst.Data) because it would include
            // the debug safety tag but we want to measure release size.
            (@sizeOf(Zir.Inst.Tag) + 8);
        const extra_bytes = zir.extra.len * @sizeOf(u32);
        const total_bytes = @sizeOf(Zir) + instruction_bytes + extra_bytes +
            zir.string_bytes.len * @sizeOf(u8);
        // zig fmt: off
        try stdout_bw.print(
            \\# Total ZIR bytes:    {Bi}
            \\# Instructions:       {d} ({Bi})
            \\# String Table Bytes: {Bi}
            \\# Extra Data Items:   {d} ({Bi})
            \\
        , .{
            total_bytes,
            zir.instructions.len, instruction_bytes,
            zir.string_bytes.len,
            zir.extra.len, extra_bytes,
        });
        // zig fmt: on
    }

    try @import("print_zir.zig").renderAsText(arena, null, zir, stdout_bw);
    try stdout_bw.flush();
}

/// This is only enabled for debug builds.
fn cmdChangelist(
    arena: Allocator,
    args: []const []const u8,
) !void {
    dev.check(.changelist_command);

    const color: Color = .auto;
    const Zir = std.zig.Zir;

    const old_source_path = args[0];
    const new_source_path = args[1];

    const old_source = source: {
        var f = fs.cwd().openFile(old_source_path, .{}) catch |err|
            fatal("unable to open old source file '{s}': {s}", .{ old_source_path, @errorName(err) });
        defer f.close();
        var file_reader: fs.File.Reader = f.reader(&stdin_buffer);
        break :source std.zig.readSourceFileToEndAlloc(arena, &file_reader) catch |err|
            fatal("unable to read old source file '{s}': {s}", .{ old_source_path, @errorName(err) });
    };
    const new_source = source: {
        var f = fs.cwd().openFile(new_source_path, .{}) catch |err|
            fatal("unable to open new source file '{s}': {s}", .{ new_source_path, @errorName(err) });
        defer f.close();
        var file_reader: fs.File.Reader = f.reader(&stdin_buffer);
        break :source std.zig.readSourceFileToEndAlloc(arena, &file_reader) catch |err|
            fatal("unable to read new source file '{s}': {s}", .{ new_source_path, @errorName(err) });
    };

    const old_tree = try Ast.parse(arena, old_source, .zig);
    const old_zir = try AstGen.generate(arena, old_tree);

    if (old_zir.loweringFailed()) {
        var wip_errors: std.zig.ErrorBundle.Wip = undefined;
        try wip_errors.init(arena);
        try wip_errors.addZirErrorMessages(old_zir, old_tree, old_source, old_source_path);
        var error_bundle = try wip_errors.toOwnedBundle("");
        error_bundle.renderToStdErr(color.renderOptions());
        process.exit(1);
    }

    const new_tree = try Ast.parse(arena, new_source, .zig);
    const new_zir = try AstGen.generate(arena, new_tree);

    if (new_zir.loweringFailed()) {
        var wip_errors: std.zig.ErrorBundle.Wip = undefined;
        try wip_errors.init(arena);
        try wip_errors.addZirErrorMessages(new_zir, new_tree, new_source, new_source_path);
        var error_bundle = try wip_errors.toOwnedBundle("");
        error_bundle.renderToStdErr(color.renderOptions());
        process.exit(1);
    }

    var inst_map: std.AutoHashMapUnmanaged(Zir.Inst.Index, Zir.Inst.Index) = .empty;
    try Zcu.mapOldZirToNew(arena, old_zir, new_zir, &inst_map);

    var stdout_writer = fs.File.stdout().writerStreaming(&stdout_buffer);
    const stdout_bw = &stdout_writer.interface;
    {
        try stdout_bw.print("Instruction mappings:\n", .{});
        var it = inst_map.iterator();
        while (it.next()) |entry| {
            try stdout_bw.print(" %{d} => %{d}\n", .{
                @intFromEnum(entry.key_ptr.*),
                @intFromEnum(entry.value_ptr.*),
            });
        }
    }
    try stdout_bw.flush();
}

fn eatIntPrefix(arg: []const u8, base: u8) []const u8 {
    if (arg.len > 2 and arg[0] == '0') {
        switch (std.ascii.toLower(arg[1])) {
            'b' => if (base == 2) return arg[2..],
            'o' => if (base == 8) return arg[2..],
            'x' => if (base == 16) return arg[2..],
            else => {},
        }
    }
    return arg;
}

fn parseIntSuffix(arg: []const u8, prefix_len: usize) u64 {
    return std.fmt.parseUnsigned(u64, arg[prefix_len..], 0) catch |err| {
        fatal("unable to parse '{s}': {s}", .{ arg, @errorName(err) });
    };
}

fn warnAboutForeignBinaries(
    arena: Allocator,
    arg_mode: ArgMode,
    target: *const std.Target,
    link_libc: bool,
) !void {
    const host_query: std.Target.Query = .{};
    const host_target = std.zig.resolveTargetQueryOrFatal(host_query);

    switch (std.zig.system.getExternalExecutor(&host_target, target, .{ .link_libc = link_libc })) {
        .native => return,
        .rosetta => {
            const host_name = try host_target.zigTriple(arena);
            const foreign_name = try target.zigTriple(arena);
            warn("the host system ({s}) does not appear to be capable of executing binaries from the target ({s}). Consider installing Rosetta.", .{
                host_name, foreign_name,
            });
        },
        .qemu => |qemu| {
            const host_name = try host_target.zigTriple(arena);
            const foreign_name = try target.zigTriple(arena);
            switch (arg_mode) {
                .zig_test => warn(
                    "the host system ({s}) does not appear to be capable of executing binaries " ++
                        "from the target ({s}). Consider using '--test-cmd {s} --test-cmd-bin' " ++
                        "to run the tests",
                    .{ host_name, foreign_name, qemu },
                ),
                else => warn(
                    "the host system ({s}) does not appear to be capable of executing binaries " ++
                        "from the target ({s}). Consider using '{s}' to run the binary",
                    .{ host_name, foreign_name, qemu },
                ),
            }
        },
        .wine => |wine| {
            const host_name = try host_target.zigTriple(arena);
            const foreign_name = try target.zigTriple(arena);
            switch (arg_mode) {
                .zig_test => warn(
                    "the host system ({s}) does not appear to be capable of executing binaries " ++
                        "from the target ({s}). Consider using '--test-cmd {s} --test-cmd-bin' " ++
                        "to run the tests",
                    .{ host_name, foreign_name, wine },
                ),
                else => warn(
                    "the host system ({s}) does not appear to be capable of executing binaries " ++
                        "from the target ({s}). Consider using '{s}' to run the binary",
                    .{ host_name, foreign_name, wine },
                ),
            }
        },
        .wasmtime => |wasmtime| {
            const host_name = try host_target.zigTriple(arena);
            const foreign_name = try target.zigTriple(arena);
            switch (arg_mode) {
                .zig_test => warn(
                    "the host system ({s}) does not appear to be capable of executing binaries " ++
                        "from the target ({s}). Consider using '--test-cmd {s} --test-cmd-bin' " ++
                        "to run the tests",
                    .{ host_name, foreign_name, wasmtime },
                ),
                else => warn(
                    "the host system ({s}) does not appear to be capable of executing binaries " ++
                        "from the target ({s}). Consider using '{s}' to run the binary",
                    .{ host_name, foreign_name, wasmtime },
                ),
            }
        },
        .darling => |darling| {
            const host_name = try host_target.zigTriple(arena);
            const foreign_name = try target.zigTriple(arena);
            switch (arg_mode) {
                .zig_test => warn(
                    "the host system ({s}) does not appear to be capable of executing binaries " ++
                        "from the target ({s}). Consider using '--test-cmd {s} --test-cmd-bin' " ++
                        "to run the tests",
                    .{ host_name, foreign_name, darling },
                ),
                else => warn(
                    "the host system ({s}) does not appear to be capable of executing binaries " ++
                        "from the target ({s}). Consider using '{s}' to run the binary",
                    .{ host_name, foreign_name, darling },
                ),
            }
        },
        .bad_dl => |foreign_dl| {
            const host_dl = host_target.dynamic_linker.get() orelse "(none)";
            const tip_suffix = switch (arg_mode) {
                .zig_test => ", '--test-no-exec', or '--test-cmd'",
                else => "",
            };
            warn("the host system does not appear to be capable of executing binaries from the target because the host dynamic linker is '{s}', while the target dynamic linker is '{s}'. Consider using '--dynamic-linker'{s}", .{
                host_dl, foreign_dl, tip_suffix,
            });
        },
        .bad_os_or_cpu => {
            const host_name = try host_target.zigTriple(arena);
            const foreign_name = try target.zigTriple(arena);
            const tip_suffix = switch (arg_mode) {
                .zig_test => ". Consider using '--test-no-exec' or '--test-cmd'",
                else => "",
            };
            warn("the host system ({s}) does not appear to be capable of executing binaries from the target ({s}){s}", .{
                host_name, foreign_name, tip_suffix,
            });
        },
    }
}

fn parseSubSystem(next_arg: []const u8) !std.Target.SubSystem {
    if (mem.eql(u8, next_arg, "console")) {
        return .Console;
    } else if (mem.eql(u8, next_arg, "windows")) {
        return .Windows;
    } else if (mem.eql(u8, next_arg, "posix")) {
        return .Posix;
    } else if (mem.eql(u8, next_arg, "native")) {
        return .Native;
    } else if (mem.eql(u8, next_arg, "efi_application")) {
        return .EfiApplication;
    } else if (mem.eql(u8, next_arg, "efi_boot_service_driver")) {
        return .EfiBootServiceDriver;
    } else if (mem.eql(u8, next_arg, "efi_rom")) {
        return .EfiRom;
    } else if (mem.eql(u8, next_arg, "efi_runtime_driver")) {
        return .EfiRuntimeDriver;
    } else {
        fatal("invalid: --subsystem: '{s}'. Options are:\n{s}", .{
            next_arg,
            \\  console
            \\  windows
            \\  posix
            \\  native
            \\  efi_application
            \\  efi_boot_service_driver
            \\  efi_rom
            \\  efi_runtime_driver
            \\
        });
    }
}

/// Model a header searchlist as a group.
/// Silently ignore superfluous search dirs.
/// Warn when a dir is added to multiple searchlists.
const ClangSearchSanitizer = struct {
    map: std.StringHashMapUnmanaged(Membership) = .empty,

    fn reset(self: *@This()) void {
        self.map.clearRetainingCapacity();
    }

    fn addIncludePath(
        self: *@This(),
        ally: Allocator,
        argv: *std.ArrayListUnmanaged([]const u8),
        group: Group,
        arg: []const u8,
        dir: []const u8,
        joined: bool,
    ) !void {
        const gopr = try self.map.getOrPut(ally, dir);
        const m = gopr.value_ptr;
        if (!gopr.found_existing) {
            // init empty membership
            m.* = .{};
        }
        const wtxt = "add '{s}' to header searchlist '-{s}' conflicts with '-{s}'";
        switch (group) {
            .I => {
                if (m.I) return;
                m.I = true;
                if (m.isystem) warn(wtxt, .{ dir, "I", "isystem" });
                if (m.idirafter) warn(wtxt, .{ dir, "I", "idirafter" });
                if (m.iframework) warn(wtxt, .{ dir, "I", "iframework" });
            },
            .isystem => {
                if (m.isystem) return;
                m.isystem = true;
                if (m.I) warn(wtxt, .{ dir, "isystem", "I" });
                if (m.idirafter) warn(wtxt, .{ dir, "isystem", "idirafter" });
                if (m.iframework) warn(wtxt, .{ dir, "isystem", "iframework" });
            },
            .iwithsysroot => {
                if (m.iwithsysroot) return;
                m.iwithsysroot = true;
                if (m.iframeworkwithsysroot) warn(wtxt, .{ dir, "iwithsysroot", "iframeworkwithsysroot" });
            },
            .idirafter => {
                if (m.idirafter) return;
                m.idirafter = true;
                if (m.I) warn(wtxt, .{ dir, "idirafter", "I" });
                if (m.isystem) warn(wtxt, .{ dir, "idirafter", "isystem" });
                if (m.iframework) warn(wtxt, .{ dir, "idirafter", "iframework" });
            },
            .iframework => {
                if (m.iframework) return;
                m.iframework = true;
                if (m.I) warn(wtxt, .{ dir, "iframework", "I" });
                if (m.isystem) warn(wtxt, .{ dir, "iframework", "isystem" });
                if (m.idirafter) warn(wtxt, .{ dir, "iframework", "idirafter" });
            },
            .iframeworkwithsysroot => {
                if (m.iframeworkwithsysroot) return;
                m.iframeworkwithsysroot = true;
                if (m.iwithsysroot) warn(wtxt, .{ dir, "iframeworkwithsysroot", "iwithsysroot" });
            },
            .embed_dir => {
                if (m.embed_dir) return;
                m.embed_dir = true;
            },
        }
        try argv.ensureUnusedCapacity(ally, 2);
        argv.appendAssumeCapacity(arg);
        if (!joined) argv.appendAssumeCapacity(dir);
    }

    const Group = enum { I, isystem, iwithsysroot, idirafter, iframework, iframeworkwithsysroot, embed_dir };

    const Membership = packed struct {
        I: bool = false,
        isystem: bool = false,
        iwithsysroot: bool = false,
        idirafter: bool = false,
        iframework: bool = false,
        iframeworkwithsysroot: bool = false,
        embed_dir: bool = false,
    };
};

fn accessFrameworkPath(
    test_path: *std.ArrayList(u8),
    checked_paths: *std.ArrayList(u8),
    framework_dir_path: []const u8,
    framework_name: []const u8,
) !bool {
    const sep = fs.path.sep_str;

    for (&[_][]const u8{ ".tbd", ".dylib", "" }) |ext| {
        test_path.clearRetainingCapacity();
        try test_path.print("{s}" ++ sep ++ "{s}.framework" ++ sep ++ "{s}{s}", .{
            framework_dir_path, framework_name, framework_name, ext,
        });
        try checked_paths.print("\n {s}", .{test_path.items});
        fs.cwd().access(test_path.items, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => |e| fatal("unable to search for {s} framework '{s}': {s}", .{
                ext, test_path.items, @errorName(e),
            }),
        };
        return true;
    }

    return false;
}

fn parseRcIncludes(arg: []const u8) Compilation.RcIncludes {
    return std.meta.stringToEnum(Compilation.RcIncludes, arg) orelse
        fatal("unsupported rc includes type: '{s}'", .{arg});
}

const usage_fetch =
    \\Usage: zig fetch [options] <url>
    \\Usage: zig fetch [options] <path>
    \\
    \\    Copy a package into the global cache and print its hash.
    \\    <url> must point to one of the following:
    \\      - A git+http / git+https server for the package
    \\      - A tarball file (with or without compression) containing
    \\        package source
    \\      - A git bundle file containing package source
    \\
    \\Examples:
    \\
    \\  zig fetch --save git+https://example.com/andrewrk/fun-example-tool.git
    \\  zig fetch --save https://example.com/andrewrk/fun-example-tool/archive/refs/heads/master.tar.gz
    \\
    \\Options:
    \\  -h, --help                    Print this help and exit
    \\  --global-cache-dir [path]     Override path to global Zig cache directory
    \\  --debug-hash                  Print verbose hash information to stdout
    \\  --save                        Add the fetched package to build.zig.zon
    \\  --save=[name]                 Add the fetched package to build.zig.zon as name
    \\  --save-exact                  Add the fetched package to build.zig.zon, storing the URL verbatim
    \\  --save-exact=[name]           Add the fetched package to build.zig.zon as name, storing the URL verbatim
    \\
;

fn cmdFetch(
    gpa: Allocator,
    arena: Allocator,
    args: []const []const u8,
) !void {
    dev.check(.fetch_command);

    const color: Color = .auto;
    const work_around_btrfs_bug = native_os == .linux and
        EnvVar.ZIG_BTRFS_WORKAROUND.isSet();
    var opt_path_or_url: ?[]const u8 = null;
    var override_global_cache_dir: ?[]const u8 = try EnvVar.ZIG_GLOBAL_CACHE_DIR.get(arena);
    var debug_hash: bool = false;
    var save: union(enum) {
        no,
        yes: ?[]const u8,
        exact: ?[]const u8,
    } = .no;

    {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (mem.startsWith(u8, arg, "-")) {
                if (mem.eql(u8, arg, "-h") or mem.eql(u8, arg, "--help")) {
                    try fs.File.stdout().writeAll(usage_fetch);
                    return cleanExit();
                } else if (mem.eql(u8, arg, "--global-cache-dir")) {
                    if (i + 1 >= args.len) fatal("expected argument after '{s}'", .{arg});
                    i += 1;
                    override_global_cache_dir = args[i];
                } else if (mem.eql(u8, arg, "--debug-hash")) {
                    debug_hash = true;
                } else if (mem.eql(u8, arg, "--save")) {
                    save = .{ .yes = null };
                } else if (mem.startsWith(u8, arg, "--save=")) {
                    save = .{ .yes = arg["--save=".len..] };
                } else if (mem.eql(u8, arg, "--save-exact")) {
                    save = .{ .exact = null };
                } else if (mem.startsWith(u8, arg, "--save-exact=")) {
                    save = .{ .exact = arg["--save-exact=".len..] };
                } else {
                    fatal("unrecognized parameter: '{s}'", .{arg});
                }
            } else if (opt_path_or_url != null) {
                fatal("unexpected extra parameter: '{s}'", .{arg});
            } else {
                opt_path_or_url = arg;
            }
        }
    }

    const path_or_url = opt_path_or_url orelse fatal("missing url or path parameter", .{});

    var thread_pool: ThreadPool = undefined;
    try thread_pool.init(.{ .allocator = gpa });
    defer thread_pool.deinit();

    var http_client: std.http.Client = .{ .allocator = gpa };
    defer http_client.deinit();

    try http_client.initDefaultProxies(arena);

    var root_prog_node = std.Progress.start(.{
        .root_name = "Fetch",
    });
    defer root_prog_node.end();

    var global_cache_directory: Directory = l: {
        const p = override_global_cache_dir orelse try introspect.resolveGlobalCacheDir(arena);
        break :l .{
            .handle = try fs.cwd().makeOpenPath(p, .{}),
            .path = p,
        };
    };
    defer global_cache_directory.handle.close();

    var job_queue: Package.Fetch.JobQueue = .{
        .http_client = &http_client,
        .thread_pool = &thread_pool,
        .global_cache = global_cache_directory,
        .recursive = false,
        .read_only = false,
        .debug_hash = debug_hash,
        .work_around_btrfs_bug = work_around_btrfs_bug,
        .mode = .all,
    };
    defer job_queue.deinit();

    var fetch: Package.Fetch = .{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .location = .{ .path_or_url = path_or_url },
        .location_tok = 0,
        .hash_tok = .none,
        .name_tok = 0,
        .lazy_status = .eager,
        .parent_package_root = undefined,
        .parent_manifest_ast = null,
        .prog_node = root_prog_node,
        .job_queue = &job_queue,
        .omit_missing_hash_error = true,
        .allow_missing_paths_field = false,
        .allow_missing_fingerprint = true,
        .allow_name_string = true,
        .use_latest_commit = true,

        .package_root = undefined,
        .error_bundle = undefined,
        .manifest = null,
        .manifest_ast = undefined,
        .computed_hash = undefined,
        .has_build_zig = false,
        .oom_flag = false,
        .latest_commit = null,

        .module = null,
    };
    defer fetch.deinit();

    fetch.run() catch |err| switch (err) {
        error.OutOfMemory => fatal("out of memory", .{}),
        error.FetchFailed => {}, // error bundle checked below
    };

    if (fetch.error_bundle.root_list.items.len > 0) {
        var errors = try fetch.error_bundle.toOwnedBundle("");
        errors.renderToStdErr(color.renderOptions());
        process.exit(1);
    }

    const package_hash = fetch.computedPackageHash();
    const package_hash_slice = package_hash.toSlice();

    root_prog_node.end();
    root_prog_node = .{ .index = .none };

    const name = switch (save) {
        .no => {
            var stdout = fs.File.stdout().writerStreaming(&stdout_buffer);
            try stdout.interface.print("{s}\n", .{package_hash_slice});
            try stdout.interface.flush();
            return cleanExit();
        },
        .yes, .exact => |name| name: {
            if (name) |n| break :name n;
            const fetched_manifest = fetch.manifest orelse
                fatal("unable to determine name; fetched package has no build.zig.zon file", .{});
            break :name fetched_manifest.name;
        },
    };

    const cwd_path = try introspect.getResolvedCwd(arena);

    var build_root = try findBuildRoot(arena, .{
        .cwd_path = cwd_path,
    });
    defer build_root.deinit();

    // The name to use in case the manifest file needs to be created now.
    const init_root_name = fs.path.basename(build_root.directory.path orelse cwd_path);
    var manifest, var ast = try loadManifest(gpa, arena, .{
        .root_name = try sanitizeExampleName(arena, init_root_name),
        .dir = build_root.directory.handle,
        .color = color,
    });
    defer {
        manifest.deinit(gpa);
        ast.deinit(gpa);
    }

    var fixups: Ast.Render.Fixups = .{};
    defer fixups.deinit(gpa);

    var saved_path_or_url = path_or_url;

    if (fetch.latest_commit) |latest_commit| resolved: {
        const latest_commit_hex = try std.fmt.allocPrint(arena, "{f}", .{latest_commit});

        var uri = try std.Uri.parse(path_or_url);

        if (uri.fragment) |fragment| {
            const target_ref = try fragment.toRawMaybeAlloc(arena);

            // the refspec may already be fully resolved
            if (std.mem.eql(u8, target_ref, latest_commit_hex)) break :resolved;

            std.log.info("resolved ref '{s}' to commit {s}", .{ target_ref, latest_commit_hex });

            // include the original refspec in a query parameter, could be used to check for updates
            uri.query = .{ .percent_encoded = try std.fmt.allocPrint(arena, "ref={f}", .{
                std.fmt.alt(fragment, .formatEscaped),
            }) };
        } else {
            std.log.info("resolved to commit {s}", .{latest_commit_hex});
        }

        // replace the refspec with the resolved commit SHA
        uri.fragment = .{ .raw = latest_commit_hex };

        switch (save) {
            .yes => saved_path_or_url = try std.fmt.allocPrint(arena, "{f}", .{uri}),
            .no, .exact => {}, // keep the original URL
        }
    }

    const new_node_init = try std.fmt.allocPrint(arena,
        \\.{{
        \\            .url = "{f}",
        \\            .hash = "{f}",
        \\        }}
    , .{
        std.zig.fmtString(saved_path_or_url),
        std.zig.fmtString(package_hash_slice),
    });

    const new_node_text = try std.fmt.allocPrint(arena, ".{f} = {s},\n", .{
        std.zig.fmtIdPU(name), new_node_init,
    });

    const dependencies_init = try std.fmt.allocPrint(arena, ".{{\n        {s}    }}", .{
        new_node_text,
    });

    const dependencies_text = try std.fmt.allocPrint(arena, ".dependencies = {s},\n", .{
        dependencies_init,
    });

    if (manifest.dependencies.get(name)) |dep| {
        if (dep.hash) |h| {
            switch (dep.location) {
                .url => |u| {
                    if (mem.eql(u8, h, package_hash_slice) and mem.eql(u8, u, saved_path_or_url)) {
                        std.log.info("existing dependency named '{s}' is up-to-date", .{name});
                        process.exit(0);
                    }
                },
                .path => {},
            }
        }

        const location_replace = try std.fmt.allocPrint(
            arena,
            "\"{f}\"",
            .{std.zig.fmtString(saved_path_or_url)},
        );
        const hash_replace = try std.fmt.allocPrint(
            arena,
            "\"{f}\"",
            .{std.zig.fmtString(package_hash_slice)},
        );

        warn("overwriting existing dependency named '{s}'", .{name});
        try fixups.replace_nodes_with_string.put(gpa, dep.location_node, location_replace);
        if (dep.hash_node.unwrap()) |hash_node| {
            try fixups.replace_nodes_with_string.put(gpa, hash_node, hash_replace);
        } else {
            // https://github.com/ziglang/zig/issues/21690
        }
    } else if (manifest.dependencies.count() > 0) {
        // Add fixup for adding another dependency.
        const deps = manifest.dependencies.values();
        const last_dep_node = deps[deps.len - 1].node;
        try fixups.append_string_after_node.put(gpa, last_dep_node, new_node_text);
    } else if (manifest.dependencies_node.unwrap()) |dependencies_node| {
        // Add fixup for replacing the entire dependencies struct.
        try fixups.replace_nodes_with_string.put(gpa, dependencies_node, dependencies_init);
    } else {
        // Add fixup for adding dependencies struct.
        try fixups.append_string_after_node.put(gpa, manifest.version_node, dependencies_text);
    }

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try ast.render(gpa, &aw.writer, fixups);
    const rendered = aw.getWritten();

    build_root.directory.handle.writeFile(.{ .sub_path = Package.Manifest.basename, .data = rendered }) catch |err| {
        fatal("unable to write {s} file: {t}", .{ Package.Manifest.basename, err });
    };

    return cleanExit();
}

fn createEmptyDependenciesModule(
    arena: Allocator,
    main_mod: *Package.Module,
    dirs: Compilation.Directories,
    global_options: Compilation.Config,
) !void {
    var source = std.ArrayList(u8).init(arena);
    try Package.Fetch.JobQueue.createEmptyDependenciesSource(&source);
    _ = try createDependenciesModule(
        arena,
        source.items,
        main_mod,
        dirs,
        global_options,
    );
}

/// Creates the dependencies.zig file and corresponding `Package.Module` for the
/// build runner to obtain via `@import("@dependencies")`.
fn createDependenciesModule(
    arena: Allocator,
    source: []const u8,
    main_mod: *Package.Module,
    dirs: Compilation.Directories,
    global_options: Compilation.Config,
) !*Package.Module {
    // Atomically create the file in a directory named after the hash of its contents.
    const basename = "dependencies.zig";
    const rand_int = std.crypto.random.int(u64);
    const tmp_dir_sub_path = "tmp" ++ fs.path.sep_str ++ std.fmt.hex(rand_int);
    {
        var tmp_dir = try dirs.local_cache.handle.makeOpenPath(tmp_dir_sub_path, .{});
        defer tmp_dir.close();
        try tmp_dir.writeFile(.{ .sub_path = basename, .data = source });
    }

    var hh: Cache.HashHelper = .{};
    hh.addBytes(build_options.version);
    hh.addBytes(source);
    const hex_digest = hh.final();

    const o_dir_sub_path = try arena.dupe(u8, "o" ++ fs.path.sep_str ++ hex_digest);
    try Package.Fetch.renameTmpIntoCache(
        dirs.local_cache.handle,
        tmp_dir_sub_path,
        o_dir_sub_path,
    );

    const deps_mod = try Package.Module.create(arena, .{
        .paths = .{
            .root = try .fromRoot(arena, dirs, .local_cache, o_dir_sub_path),
            .root_src_path = basename,
        },
        .fully_qualified_name = "root.@dependencies",
        .parent = main_mod,
        .cc_argv = &.{},
        .inherited = .{},
        .global = global_options,
    });
    try main_mod.deps.put(arena, "@dependencies", deps_mod);
    return deps_mod;
}

const BuildRoot = struct {
    directory: Cache.Directory,
    build_zig_basename: []const u8,
    cleanup_build_dir: ?fs.Dir,

    fn deinit(br: *BuildRoot) void {
        if (br.cleanup_build_dir) |*dir| dir.close();
        br.* = undefined;
    }
};

const FindBuildRootOptions = struct {
    build_file: ?[]const u8 = null,
    cwd_path: ?[]const u8 = null,
};

fn findBuildRoot(arena: Allocator, options: FindBuildRootOptions) !BuildRoot {
    const cwd_path = options.cwd_path orelse try introspect.getResolvedCwd(arena);
    const build_zig_basename = if (options.build_file) |bf|
        fs.path.basename(bf)
    else
        Package.build_zig_basename;

    if (options.build_file) |bf| {
        if (fs.path.dirname(bf)) |dirname| {
            const dir = fs.cwd().openDir(dirname, .{}) catch |err| {
                fatal("unable to open directory to build file from argument 'build-file', '{s}': {s}", .{ dirname, @errorName(err) });
            };
            return .{
                .build_zig_basename = build_zig_basename,
                .directory = .{ .path = dirname, .handle = dir },
                .cleanup_build_dir = dir,
            };
        }

        return .{
            .build_zig_basename = build_zig_basename,
            .directory = .{ .path = null, .handle = fs.cwd() },
            .cleanup_build_dir = null,
        };
    }
    // Search up parent directories until we find build.zig.
    var dirname: []const u8 = cwd_path;
    while (true) {
        const joined_path = try fs.path.join(arena, &[_][]const u8{ dirname, build_zig_basename });
        if (fs.cwd().access(joined_path, .{})) |_| {
            const dir = fs.cwd().openDir(dirname, .{}) catch |err| {
                fatal("unable to open directory while searching for build.zig file, '{s}': {s}", .{ dirname, @errorName(err) });
            };
            return .{
                .build_zig_basename = build_zig_basename,
                .directory = .{
                    .path = dirname,
                    .handle = dir,
                },
                .cleanup_build_dir = dir,
            };
        } else |err| switch (err) {
            error.FileNotFound => {
                dirname = fs.path.dirname(dirname) orelse {
                    std.log.info("initialize {s} template file with 'zig init'", .{
                        Package.build_zig_basename,
                    });
                    std.log.info("see 'zig --help' for more options", .{});
                    fatal("no build.zig file found, in the current directory or any parent directories", .{});
                };
                continue;
            },
            else => |e| return e,
        }
    }
}

const LoadManifestOptions = struct {
    root_name: []const u8,
    dir: fs.Dir,
    color: Color,
};

fn loadManifest(
    gpa: Allocator,
    arena: Allocator,
    options: LoadManifestOptions,
) !struct { Package.Manifest, Ast } {
    const manifest_bytes = while (true) {
        break options.dir.readFileAllocOptions(
            arena,
            Package.Manifest.basename,
            Package.Manifest.max_bytes,
            null,
            .@"1",
            0,
        ) catch |err| switch (err) {
            error.FileNotFound => {
                writeSimpleTemplateFile(Package.Manifest.basename,
                    \\.{{
                    \\    .name = .{s},
                    \\    .version = "{s}",
                    \\    .paths = .{{""}},
                    \\    .fingerprint = 0x{x},
                    \\}}
                    \\
                , .{
                    options.root_name,
                    build_options.version,
                    Package.Fingerprint.generate(options.root_name).int(),
                }) catch |e| {
                    fatal("unable to write {s}: {s}", .{ Package.Manifest.basename, @errorName(e) });
                };
                continue;
            },
            else => |e| fatal("unable to load {s}: {s}", .{
                Package.Manifest.basename, @errorName(e),
            }),
        };
    };
    var ast = try Ast.parse(gpa, manifest_bytes, .zon);
    errdefer ast.deinit(gpa);

    if (ast.errors.len > 0) {
        try std.zig.printAstErrorsToStderr(gpa, ast, Package.Manifest.basename, options.color);
        process.exit(2);
    }

    var manifest = try Package.Manifest.parse(gpa, ast, .{});
    errdefer manifest.deinit(gpa);

    if (manifest.errors.len > 0) {
        var wip_errors: std.zig.ErrorBundle.Wip = undefined;
        try wip_errors.init(gpa);
        defer wip_errors.deinit();

        const src_path = try wip_errors.addString(Package.Manifest.basename);
        try manifest.copyErrorsIntoBundle(ast, src_path, &wip_errors);

        var error_bundle = try wip_errors.toOwnedBundle("");
        defer error_bundle.deinit(gpa);
        error_bundle.renderToStdErr(options.color.renderOptions());

        process.exit(2);
    }
    return .{ manifest, ast };
}

const Templates = struct {
    zig_lib_directory: Cache.Directory,
    dir: fs.Dir,
    buffer: std.ArrayList(u8),

    fn deinit(templates: *Templates) void {
        templates.zig_lib_directory.handle.close();
        templates.dir.close();
        templates.buffer.deinit();
        templates.* = undefined;
    }

    fn write(
        templates: *Templates,
        arena: Allocator,
        out_dir: fs.Dir,
        root_name: []const u8,
        template_path: []const u8,
        fingerprint: Package.Fingerprint,
    ) !void {
        if (fs.path.dirname(template_path)) |dirname| {
            out_dir.makePath(dirname) catch |err| {
                fatal("unable to make path '{s}': {s}", .{ dirname, @errorName(err) });
            };
        }

        const max_bytes = 10 * 1024 * 1024;
        const contents = templates.dir.readFileAlloc(arena, template_path, max_bytes) catch |err| {
            fatal("unable to read template file '{s}': {s}", .{ template_path, @errorName(err) });
        };
        templates.buffer.clearRetainingCapacity();
        try templates.buffer.ensureUnusedCapacity(contents.len);
        var i: usize = 0;
        while (i < contents.len) {
            if (contents[i] == '_' or contents[i] == '.') {
                // Both '_' and '.' are allowed because depending on the context
                // one prefix will be valid, while the other might not.
                if (std.mem.startsWith(u8, contents[i + 1 ..], "NAME")) {
                    try templates.buffer.appendSlice(root_name);
                    i += "_NAME".len;
                    continue;
                } else if (std.mem.startsWith(u8, contents[i + 1 ..], "FINGERPRINT")) {
                    try templates.buffer.writer().print("0x{x}", .{fingerprint.int()});
                    i += "_FINGERPRINT".len;
                    continue;
                } else if (std.mem.startsWith(u8, contents[i + 1 ..], "ZIGVER")) {
                    try templates.buffer.appendSlice(build_options.version);
                    i += "_ZIGVER".len;
                    continue;
                }
            }

            try templates.buffer.append(contents[i]);
            i += 1;
        }

        return out_dir.writeFile(.{
            .sub_path = template_path,
            .data = templates.buffer.items,
            .flags = .{ .exclusive = true },
        });
    }
};
fn writeSimpleTemplateFile(file_name: []const u8, comptime fmt: []const u8, args: anytype) !void {
    const f = try fs.cwd().createFile(file_name, .{ .exclusive = true });
    defer f.close();
    var buf: [4096]u8 = undefined;
    var fw = f.writer(&buf);
    try fw.interface.print(fmt, args);
    try fw.interface.flush();
}

fn findTemplates(gpa: Allocator, arena: Allocator) Templates {
    const cwd_path = introspect.getResolvedCwd(arena) catch |err| {
        fatal("unable to get cwd: {s}", .{@errorName(err)});
    };
    const self_exe_path = fs.selfExePathAlloc(arena) catch |err| {
        fatal("unable to find self exe path: {s}", .{@errorName(err)});
    };
    var zig_lib_directory = introspect.findZigLibDirFromSelfExe(arena, cwd_path, self_exe_path) catch |err| {
        fatal("unable to find zig installation directory '{s}': {s}", .{ self_exe_path, @errorName(err) });
    };

    const s = fs.path.sep_str;
    const template_sub_path = "init";
    const template_dir = zig_lib_directory.handle.openDir(template_sub_path, .{}) catch |err| {
        const path = zig_lib_directory.path orelse ".";
        fatal("unable to open zig project template directory '{s}{s}{s}': {s}", .{
            path, s, template_sub_path, @errorName(err),
        });
    };

    return .{
        .zig_lib_directory = zig_lib_directory,
        .dir = template_dir,
        .buffer = std.ArrayList(u8).init(gpa),
    };
}

fn parseOptimizeMode(s: []const u8) std.builtin.OptimizeMode {
    return std.meta.stringToEnum(std.builtin.OptimizeMode, s) orelse
        fatal("unrecognized optimization mode: '{s}'", .{s});
}

fn parseWasiExecModel(s: []const u8) std.builtin.WasiExecModel {
    return std.meta.stringToEnum(std.builtin.WasiExecModel, s) orelse
        fatal("expected [command|reactor] for -mexec-mode=[value], found '{s}'", .{s});
}

fn parseStackSize(s: []const u8) u64 {
    return std.fmt.parseUnsigned(u64, s, 0) catch |err|
        fatal("unable to parse stack size '{s}': {s}", .{ s, @errorName(err) });
}

fn parseImageBase(s: []const u8) u64 {
    return std.fmt.parseUnsigned(u64, s, 0) catch |err|
        fatal("unable to parse image base '{s}': {s}", .{ s, @errorName(err) });
}

fn handleModArg(
    arena: Allocator,
    mod_name: []const u8,
    opt_root_src_orig: ?[]const u8,
    create_module: *CreateModule,
    mod_opts: *Package.Module.CreateOptions.Inherited,
    cc_argv: *std.ArrayListUnmanaged([]const u8),
    target_arch_os_abi: *?[]const u8,
    target_mcpu: *?[]const u8,
    deps: *std.ArrayListUnmanaged(CliModule.Dep),
    c_source_files_owner_index: *usize,
    rc_source_files_owner_index: *usize,
    cssan: *ClangSearchSanitizer,
) !void {
    const gop = try create_module.modules.getOrPut(arena, mod_name);

    if (gop.found_existing) {
        fatal("unable to add module '{s}': already exists as '{s}{c}{s}'", .{
            mod_name, gop.value_ptr.root_path, fs.path.sep, gop.value_ptr.root_src_path,
        });
    }

    // See duplicate logic: ModCreationGlobalFlags
    if (mod_opts.single_threaded == false)
        create_module.opts.any_non_single_threaded = true;
    if (mod_opts.sanitize_thread == true)
        create_module.opts.any_sanitize_thread = true;
    if (mod_opts.sanitize_c) |sc| switch (sc) {
        .off => {},
        .trap => if (create_module.opts.any_sanitize_c == .off) {
            create_module.opts.any_sanitize_c = .trap;
        },
        .full => create_module.opts.any_sanitize_c = .full,
    };
    if (mod_opts.fuzz == true)
        create_module.opts.any_fuzz = true;
    if (mod_opts.unwind_tables) |uwt| switch (uwt) {
        .none => {},
        .sync, .async => create_module.opts.any_unwind_tables = true,
    };
    if (mod_opts.strip == false)
        create_module.opts.any_non_stripped = true;
    if (mod_opts.error_tracing == true)
        create_module.opts.any_error_tracing = true;

    const root_path: []const u8, const root_src_path: []const u8 = if (opt_root_src_orig) |path| root: {
        create_module.opts.have_zcu = true;
        break :root .{ fs.path.dirname(path) orelse ".", fs.path.basename(path) };
    } else .{ ".", "" };

    gop.value_ptr.* = .{
        .root_path = root_path,
        .root_src_path = root_src_path,
        .cc_argv = try cc_argv.toOwnedSlice(arena),
        .inherited = mod_opts.*,
        .target_arch_os_abi = target_arch_os_abi.*,
        .target_mcpu = target_mcpu.*,
        .deps = try deps.toOwnedSlice(arena),
        .resolved = null,
        .c_source_files_start = c_source_files_owner_index.*,
        .c_source_files_end = create_module.c_source_files.items.len,
        .rc_source_files_start = rc_source_files_owner_index.*,
        .rc_source_files_end = create_module.rc_source_files.items.len,
    };
    cssan.reset();
    mod_opts.* = .{};
    target_arch_os_abi.* = null;
    target_mcpu.* = null;
    c_source_files_owner_index.* = create_module.c_source_files.items.len;
    rc_source_files_owner_index.* = create_module.rc_source_files.items.len;
}

fn anyObjectLinkInputs(link_inputs: []const link.UnresolvedInput) bool {
    for (link_inputs) |link_input| switch (link_input) {
        .path_query => |pq| switch (Compilation.classifyFileExt(pq.path.sub_path)) {
            .object, .static_library, .res => return true,
            else => continue,
        },
        else => continue,
    };
    return false;
}

fn addLibDirectoryWarn(lib_directories: *std.ArrayListUnmanaged(Directory), path: []const u8) void {
    return addLibDirectoryWarn2(lib_directories, path, false);
}

fn addLibDirectoryWarn2(
    lib_directories: *std.ArrayListUnmanaged(Directory),
    path: []const u8,
    ignore_not_found: bool,
) void {
    lib_directories.appendAssumeCapacity(.{
        .handle = fs.cwd().openDir(path, .{}) catch |err| {
            if (err == error.FileNotFound and ignore_not_found) return;
            warn("unable to open library directory '{s}': {s}", .{ path, @errorName(err) });
            return;
        },
        .path = path,
    });
}
