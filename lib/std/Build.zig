const std = @import("std.zig");
const builtin = @import("builtin");
const io = std.io;
const fs = std.fs;
const mem = std.mem;
const debug = std.debug;
const panic = std.debug.panic;
const assert = debug.assert;
const log = std.log;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;
const Allocator = mem.Allocator;
const Target = std.Target;
const process = std.process;
const EnvMap = std.process.EnvMap;
const File = fs.File;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Build = @This();

pub const Cache = @import("Build/Cache.zig");
pub const Step = @import("Build/Step.zig");
pub const Module = @import("Build/Module.zig");
pub const Watch = @import("Build/Watch.zig");
pub const Fuzz = @import("Build/Fuzz.zig");
pub const WebServer = @import("Build/WebServer.zig");
pub const abi = @import("Build/abi.zig");

/// Shared state among all Build instances.
graph: *Graph,
install_tls: TopLevelStep,
uninstall_tls: TopLevelStep,
allocator: Allocator,
user_input_options: UserInputOptionsMap,
available_options_map: AvailableOptionsMap,
available_options_list: ArrayList(AvailableOption),
verbose: bool,
verbose_link: bool,
verbose_cc: bool,
verbose_air: bool,
verbose_llvm_ir: ?[]const u8,
verbose_llvm_bc: ?[]const u8,
verbose_cimport: bool,
verbose_llvm_cpu_features: bool,
reference_trace: ?u32 = null,
invalid_user_input: bool,
default_step: *Step,
top_level_steps: std.StringArrayHashMapUnmanaged(*TopLevelStep),
install_prefix: []const u8,
dest_dir: ?[]const u8,
lib_dir: []const u8,
exe_dir: []const u8,
h_dir: []const u8,
install_path: []const u8,
sysroot: ?[]const u8 = null,
search_prefixes: std.ArrayListUnmanaged([]const u8),
libc_file: ?[]const u8 = null,
/// Path to the directory containing build.zig.
build_root: Cache.Directory,
cache_root: Cache.Directory,
pkg_config_pkg_list: ?(PkgConfigError![]const PkgConfigPkg) = null,
args: ?[]const []const u8 = null,
debug_log_scopes: []const []const u8 = &.{},
debug_compile_errors: bool = false,
debug_incremental: bool = false,
debug_pkg_config: bool = false,
/// Number of stack frames captured when a `StackTrace` is recorded for debug purposes,
/// in particular at `Step` creation.
/// Set to 0 to disable stack collection.
debug_stack_frames_count: u8 = 8,

/// Experimental. Use system Darling installation to run cross compiled macOS build artifacts.
enable_darling: bool = false,
/// Use system QEMU installation to run cross compiled foreign architecture build artifacts.
enable_qemu: bool = false,
/// Darwin. Use Rosetta to run x86_64 macOS build artifacts on arm64 macOS.
enable_rosetta: bool = false,
/// Use system Wasmtime installation to run cross compiled wasm/wasi build artifacts.
enable_wasmtime: bool = false,
/// Use system Wine installation to run cross compiled Windows build artifacts.
enable_wine: bool = false,
/// After following the steps in https://github.com/ziglang/zig/wiki/Updating-libc#glibc,
/// this will be the directory $glibc-build-dir/install/glibcs
/// Given the example of the aarch64 target, this is the directory
/// that contains the path `aarch64-linux-gnu/lib/ld-linux-aarch64.so.1`.
/// Also works for dynamic musl.
libc_runtimes_dir: ?[]const u8 = null,

dep_prefix: []const u8 = "",

modules: std.StringArrayHashMap(*Module),

named_writefiles: std.StringArrayHashMap(*Step.WriteFile),
named_lazy_paths: std.StringArrayHashMap(LazyPath),
/// The hash of this instance's package. `""` means that this is the root package.
pkg_hash: []const u8,
/// A mapping from dependency names to package hashes.
available_deps: AvailableDeps,

release_mode: ReleaseMode,

build_id: ?std.zig.BuildId = null,

pub const ReleaseMode = enum {
    off,
    any,
    fast,
    safe,
    small,
};

/// Shared state among all Build instances.
/// Settings that are here rather than in Build are not configurable per-package.
pub const Graph = struct {
    arena: Allocator,
    system_library_options: std.StringArrayHashMapUnmanaged(SystemLibraryMode) = .empty,
    system_package_mode: bool = false,
    debug_compiler_runtime_libs: bool = false,
    cache: Cache,
    zig_exe: [:0]const u8,
    env_map: EnvMap,
    global_cache_root: Cache.Directory,
    zig_lib_directory: Cache.Directory,
    needed_lazy_dependencies: std.StringArrayHashMapUnmanaged(void) = .empty,
    /// Information about the native target. Computed before build() is invoked.
    host: ResolvedTarget,
    incremental: ?bool = null,
    random_seed: u32 = 0,
    dependency_cache: InitializedDepMap = .empty,
    allow_so_scripts: ?bool = null,
    time_report: bool,
};

const AvailableDeps = []const struct { []const u8, []const u8 };

const SystemLibraryMode = enum {
    /// User asked for the library to be disabled.
    /// The build runner has not confirmed whether the setting is recognized yet.
    user_disabled,
    /// User asked for the library to be enabled.
    /// The build runner has not confirmed whether the setting is recognized yet.
    user_enabled,
    /// The build runner has confirmed that this setting is recognized.
    /// System integration with this library has been resolved to off.
    declared_disabled,
    /// The build runner has confirmed that this setting is recognized.
    /// System integration with this library has been resolved to on.
    declared_enabled,
};

const InitializedDepMap = std.HashMapUnmanaged(InitializedDepKey, *Dependency, InitializedDepContext, std.hash_map.default_max_load_percentage);
const InitializedDepKey = struct {
    build_root_string: []const u8,
    user_input_options: UserInputOptionsMap,
};

const InitializedDepContext = struct {
    allocator: Allocator,

    pub fn hash(ctx: @This(), k: InitializedDepKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(k.build_root_string);
        hashUserInputOptionsMap(ctx.allocator, k.user_input_options, &hasher);
        return hasher.final();
    }

    pub fn eql(_: @This(), lhs: InitializedDepKey, rhs: InitializedDepKey) bool {
        if (!std.mem.eql(u8, lhs.build_root_string, rhs.build_root_string))
            return false;

        if (lhs.user_input_options.count() != rhs.user_input_options.count())
            return false;

        var it = lhs.user_input_options.iterator();
        while (it.next()) |lhs_entry| {
            const rhs_value = rhs.user_input_options.get(lhs_entry.key_ptr.*) orelse return false;
            if (!userValuesAreSame(lhs_entry.value_ptr.*.value, rhs_value.value))
                return false;
        }

        return true;
    }
};

pub const RunError = error{
    ReadFailure,
    ExitCodeFailure,
    ProcessTerminated,
    ExecNotSupported,
} || std.process.Child.SpawnError;

pub const PkgConfigError = error{
    PkgConfigCrashed,
    PkgConfigFailed,
    PkgConfigNotInstalled,
    PkgConfigInvalidOutput,
};

pub const PkgConfigPkg = struct {
    name: []const u8,
    desc: []const u8,
};

const UserInputOptionsMap = StringHashMap(UserInputOption);
const AvailableOptionsMap = StringHashMap(AvailableOption);

const AvailableOption = struct {
    name: []const u8,
    type_id: TypeId,
    description: []const u8,
    /// If the `type_id` is `enum` or `enum_list` this provides the list of enum options
    enum_options: ?[]const []const u8,
};

const UserInputOption = struct {
    name: []const u8,
    value: UserValue,
    used: bool,
};

const UserValue = union(enum) {
    flag: void,
    scalar: []const u8,
    list: ArrayList([]const u8),
    map: StringHashMap(*const UserValue),
    lazy_path: LazyPath,
    lazy_path_list: ArrayList(LazyPath),
};

const TypeId = enum {
    bool,
    int,
    float,
    @"enum",
    enum_list,
    string,
    list,
    build_id,
    lazy_path,
    lazy_path_list,
};

const TopLevelStep = struct {
    pub const base_id: Step.Id = .top_level;

    step: Step,
    description: []const u8,
};

pub const DirList = struct {
    lib_dir: ?[]const u8 = null,
    exe_dir: ?[]const u8 = null,
    include_dir: ?[]const u8 = null,
};

pub fn create(
    graph: *Graph,
    build_root: Cache.Directory,
    cache_root: Cache.Directory,
    available_deps: AvailableDeps,
) error{OutOfMemory}!*Build {
    const arena = graph.arena;

    const b = try arena.create(Build);
    b.* = .{
        .graph = graph,
        .build_root = build_root,
        .cache_root = cache_root,
        .verbose = false,
        .verbose_link = false,
        .verbose_cc = false,
        .verbose_air = false,
        .verbose_llvm_ir = null,
        .verbose_llvm_bc = null,
        .verbose_cimport = false,
        .verbose_llvm_cpu_features = false,
        .invalid_user_input = false,
        .allocator = arena,
        .user_input_options = UserInputOptionsMap.init(arena),
        .available_options_map = AvailableOptionsMap.init(arena),
        .available_options_list = ArrayList(AvailableOption).init(arena),
        .top_level_steps = .{},
        .default_step = undefined,
        .search_prefixes = .{},
        .install_prefix = undefined,
        .lib_dir = undefined,
        .exe_dir = undefined,
        .h_dir = undefined,
        .dest_dir = graph.env_map.get("DESTDIR"),
        .install_tls = .{
            .step = .init(.{
                .id = TopLevelStep.base_id,
                .name = "install",
                .owner = b,
            }),
            .description = "Copy build artifacts to prefix path",
        },
        .uninstall_tls = .{
            .step = .init(.{
                .id = TopLevelStep.base_id,
                .name = "uninstall",
                .owner = b,
                .makeFn = makeUninstall,
            }),
            .description = "Remove build artifacts from prefix path",
        },
        .install_path = undefined,
        .args = null,
        .modules = .init(arena),
        .named_writefiles = .init(arena),
        .named_lazy_paths = .init(arena),
        .pkg_hash = "",
        .available_deps = available_deps,
        .release_mode = .off,
    };
    try b.top_level_steps.put(arena, b.install_tls.step.name, &b.install_tls);
    try b.top_level_steps.put(arena, b.uninstall_tls.step.name, &b.uninstall_tls);
    b.default_step = &b.install_tls.step;
    return b;
}

fn createChild(
    parent: *Build,
    dep_name: []const u8,
    build_root: Cache.Directory,
    pkg_hash: []const u8,
    pkg_deps: AvailableDeps,
    user_input_options: UserInputOptionsMap,
) error{OutOfMemory}!*Build {
    const child = try createChildOnly(parent, dep_name, build_root, pkg_hash, pkg_deps, user_input_options);
    try determineAndApplyInstallPrefix(child);
    return child;
}

fn createChildOnly(
    parent: *Build,
    dep_name: []const u8,
    build_root: Cache.Directory,
    pkg_hash: []const u8,
    pkg_deps: AvailableDeps,
    user_input_options: UserInputOptionsMap,
) error{OutOfMemory}!*Build {
    const allocator = parent.allocator;
    const child = try allocator.create(Build);
    child.* = .{
        .graph = parent.graph,
        .allocator = allocator,
        .install_tls = .{
            .step = .init(.{
                .id = TopLevelStep.base_id,
                .name = "install",
                .owner = child,
            }),
            .description = "Copy build artifacts to prefix path",
        },
        .uninstall_tls = .{
            .step = .init(.{
                .id = TopLevelStep.base_id,
                .name = "uninstall",
                .owner = child,
                .makeFn = makeUninstall,
            }),
            .description = "Remove build artifacts from prefix path",
        },
        .user_input_options = user_input_options,
        .available_options_map = AvailableOptionsMap.init(allocator),
        .available_options_list = ArrayList(AvailableOption).init(allocator),
        .verbose = parent.verbose,
        .verbose_link = parent.verbose_link,
        .verbose_cc = parent.verbose_cc,
        .verbose_air = parent.verbose_air,
        .verbose_llvm_ir = parent.verbose_llvm_ir,
        .verbose_llvm_bc = parent.verbose_llvm_bc,
        .verbose_cimport = parent.verbose_cimport,
        .verbose_llvm_cpu_features = parent.verbose_llvm_cpu_features,
        .reference_trace = parent.reference_trace,
        .invalid_user_input = false,
        .default_step = undefined,
        .top_level_steps = .{},
        .install_prefix = undefined,
        .dest_dir = parent.dest_dir,
        .lib_dir = parent.lib_dir,
        .exe_dir = parent.exe_dir,
        .h_dir = parent.h_dir,
        .install_path = parent.install_path,
        .sysroot = parent.sysroot,
        .search_prefixes = parent.search_prefixes,
        .libc_file = parent.libc_file,
        .build_root = build_root,
        .cache_root = parent.cache_root,
        .debug_log_scopes = parent.debug_log_scopes,
        .debug_compile_errors = parent.debug_compile_errors,
        .debug_incremental = parent.debug_incremental,
        .debug_pkg_config = parent.debug_pkg_config,
        .enable_darling = parent.enable_darling,
        .enable_qemu = parent.enable_qemu,
        .enable_rosetta = parent.enable_rosetta,
        .enable_wasmtime = parent.enable_wasmtime,
        .enable_wine = parent.enable_wine,
        .libc_runtimes_dir = parent.libc_runtimes_dir,
        .dep_prefix = parent.fmt("{s}{s}.", .{ parent.dep_prefix, dep_name }),
        .modules = .init(allocator),
        .named_writefiles = .init(allocator),
        .named_lazy_paths = .init(allocator),
        .pkg_hash = pkg_hash,
        .available_deps = pkg_deps,
        .release_mode = parent.release_mode,
    };
    try child.top_level_steps.put(allocator, child.install_tls.step.name, &child.install_tls);
    try child.top_level_steps.put(allocator, child.uninstall_tls.step.name, &child.uninstall_tls);
    child.default_step = &child.install_tls.step;
    return child;
}

fn userInputOptionsFromArgs(arena: Allocator, args: anytype) UserInputOptionsMap {
    var map = UserInputOptionsMap.init(arena);
    inline for (@typeInfo(@TypeOf(args)).@"struct".fields) |field| {
        if (field.type == @Type(.null)) continue;
        addUserInputOptionFromArg(arena, &map, field, field.type, @field(args, field.name));
    }
    return map;
}

fn addUserInputOptionFromArg(
    arena: Allocator,
    map: *UserInputOptionsMap,
    field: std.builtin.Type.StructField,
    comptime T: type,
    /// If null, the value won't be added, but `T` will still be type-checked.
    maybe_value: ?T,
) void {
    switch (T) {
        Target.Query => return if (maybe_value) |v| {
            map.put(field.name, .{
                .name = field.name,
                .value = .{ .scalar = v.zigTriple(arena) catch @panic("OOM") },
                .used = false,
            }) catch @panic("OOM");
            map.put("cpu", .{
                .name = "cpu",
                .value = .{ .scalar = v.serializeCpuAlloc(arena) catch @panic("OOM") },
                .used = false,
            }) catch @panic("OOM");
        },
        ResolvedTarget => return if (maybe_value) |v| {
            map.put(field.name, .{
                .name = field.name,
                .value = .{ .scalar = v.query.zigTriple(arena) catch @panic("OOM") },
                .used = false,
            }) catch @panic("OOM");
            map.put("cpu", .{
                .name = "cpu",
                .value = .{ .scalar = v.query.serializeCpuAlloc(arena) catch @panic("OOM") },
                .used = false,
            }) catch @panic("OOM");
        },
        std.zig.BuildId => return if (maybe_value) |v| {
            map.put(field.name, .{
                .name = field.name,
                .value = .{ .scalar = std.fmt.allocPrint(arena, "{f}", .{v}) catch @panic("OOM") },
                .used = false,
            }) catch @panic("OOM");
        },
        LazyPath => return if (maybe_value) |v| {
            map.put(field.name, .{
                .name = field.name,
                .value = .{ .lazy_path = v.dupeInner(arena) },
                .used = false,
            }) catch @panic("OOM");
        },
        []const LazyPath => return if (maybe_value) |v| {
            var list = ArrayList(LazyPath).initCapacity(arena, v.len) catch @panic("OOM");
            for (v) |lp| list.appendAssumeCapacity(lp.dupeInner(arena));
            map.put(field.name, .{
                .name = field.name,
                .value = .{ .lazy_path_list = list },
                .used = false,
            }) catch @panic("OOM");
        },
        []const u8 => return if (maybe_value) |v| {
            map.put(field.name, .{
                .name = field.name,
                .value = .{ .scalar = arena.dupe(u8, v) catch @panic("OOM") },
                .used = false,
            }) catch @panic("OOM");
        },
        []const []const u8 => return if (maybe_value) |v| {
            var list = ArrayList([]const u8).initCapacity(arena, v.len) catch @panic("OOM");
            for (v) |s| list.appendAssumeCapacity(arena.dupe(u8, s) catch @panic("OOM"));
            map.put(field.name, .{
                .name = field.name,
                .value = .{ .list = list },
                .used = false,
            }) catch @panic("OOM");
        },
        else => switch (@typeInfo(T)) {
            .bool => return if (maybe_value) |v| {
                map.put(field.name, .{
                    .name = field.name,
                    .value = .{ .scalar = if (v) "true" else "false" },
                    .used = false,
                }) catch @panic("OOM");
            },
            .@"enum", .enum_literal => return if (maybe_value) |v| {
                map.put(field.name, .{
                    .name = field.name,
                    .value = .{ .scalar = @tagName(v) },
                    .used = false,
                }) catch @panic("OOM");
            },
            .comptime_int, .int => return if (maybe_value) |v| {
                map.put(field.name, .{
                    .name = field.name,
                    .value = .{ .scalar = std.fmt.allocPrint(arena, "{d}", .{v}) catch @panic("OOM") },
                    .used = false,
                }) catch @panic("OOM");
            },
            .comptime_float, .float => return if (maybe_value) |v| {
                map.put(field.name, .{
                    .name = field.name,
                    .value = .{ .scalar = std.fmt.allocPrint(arena, "{x}", .{v}) catch @panic("OOM") },
                    .used = false,
                }) catch @panic("OOM");
            },
            .pointer => |ptr_info| switch (ptr_info.size) {
                .one => switch (@typeInfo(ptr_info.child)) {
                    .array => |array_info| {
                        comptime var slice_info = ptr_info;
                        slice_info.size = .slice;
                        slice_info.is_const = true;
                        slice_info.child = array_info.child;
                        slice_info.sentinel_ptr = null;
                        addUserInputOptionFromArg(
                            arena,
                            map,
                            field,
                            @Type(.{ .pointer = slice_info }),
                            maybe_value orelse null,
                        );
                        return;
                    },
                    else => {},
                },
                .slice => switch (@typeInfo(ptr_info.child)) {
                    .@"enum" => return if (maybe_value) |v| {
                        var list = ArrayList([]const u8).initCapacity(arena, v.len) catch @panic("OOM");
                        for (v) |tag| list.appendAssumeCapacity(@tagName(tag));
                        map.put(field.name, .{
                            .name = field.name,
                            .value = .{ .list = list },
                            .used = false,
                        }) catch @panic("OOM");
                    },
                    else => {
                        comptime var slice_info = ptr_info;
                        slice_info.is_const = true;
                        slice_info.sentinel_ptr = null;
                        addUserInputOptionFromArg(
                            arena,
                            map,
                            field,
                            @Type(.{ .pointer = slice_info }),
                            maybe_value orelse null,
                        );
                        return;
                    },
                },
                else => {},
            },
            .null => unreachable,
            .optional => |info| switch (@typeInfo(info.child)) {
                .optional => {},
                else => {
                    addUserInputOptionFromArg(
                        arena,
                        map,
                        field,
                        info.child,
                        maybe_value orelse null,
                    );
                    return;
                },
            },
            else => {},
        },
    }
    @compileError("option '" ++ field.name ++ "' has unsupported type: " ++ @typeName(field.type));
}

const OrderedUserValue = union(enum) {
    flag: void,
    scalar: []const u8,
    list: ArrayList([]const u8),
    map: ArrayList(Pair),
    lazy_path: LazyPath,
    lazy_path_list: ArrayList(LazyPath),

    const Pair = struct {
        name: []const u8,
        value: OrderedUserValue,
        fn lessThan(_: void, lhs: Pair, rhs: Pair) bool {
            return std.ascii.lessThanIgnoreCase(lhs.name, rhs.name);
        }
    };

    fn hash(val: OrderedUserValue, hasher: *std.hash.Wyhash) void {
        hasher.update(&std.mem.toBytes(std.meta.activeTag(val)));
        switch (val) {
            .flag => {},
            .scalar => |scalar| hasher.update(scalar),
            // lists are already ordered
            .list => |list| for (list.items) |list_entry|
                hasher.update(list_entry),
            .map => |map| for (map.items) |map_entry| {
                hasher.update(map_entry.name);
                map_entry.value.hash(hasher);
            },
            .lazy_path => |lp| hashLazyPath(lp, hasher),
            .lazy_path_list => |lp_list| for (lp_list.items) |lp| {
                hashLazyPath(lp, hasher);
            },
        }
    }

    fn hashLazyPath(lp: LazyPath, hasher: *std.hash.Wyhash) void {
        switch (lp) {
            .src_path => |sp| {
                hasher.update(sp.owner.pkg_hash);
                hasher.update(sp.sub_path);
            },
            .generated => |gen| {
                hasher.update(gen.file.step.owner.pkg_hash);
                hasher.update(std.mem.asBytes(&gen.up));
                hasher.update(gen.sub_path);
            },
            .cwd_relative => |rel_path| {
                hasher.update(rel_path);
            },
            .dependency => |dep| {
                hasher.update(dep.dependency.builder.pkg_hash);
                hasher.update(dep.sub_path);
            },
        }
    }

    fn mapFromUnordered(allocator: Allocator, unordered: std.StringHashMap(*const UserValue)) ArrayList(Pair) {
        var ordered = ArrayList(Pair).init(allocator);
        var it = unordered.iterator();
        while (it.next()) |entry| {
            ordered.append(.{
                .name = entry.key_ptr.*,
                .value = OrderedUserValue.fromUnordered(allocator, entry.value_ptr.*.*),
            }) catch @panic("OOM");
        }

        std.mem.sortUnstable(Pair, ordered.items, {}, Pair.lessThan);
        return ordered;
    }

    fn fromUnordered(allocator: Allocator, unordered: UserValue) OrderedUserValue {
        return switch (unordered) {
            .flag => .{ .flag = {} },
            .scalar => |scalar| .{ .scalar = scalar },
            .list => |list| .{ .list = list },
            .map => |map| .{ .map = OrderedUserValue.mapFromUnordered(allocator, map) },
            .lazy_path => |lp| .{ .lazy_path = lp },
            .lazy_path_list => |list| .{ .lazy_path_list = list },
        };
    }
};

const OrderedUserInputOption = struct {
    name: []const u8,
    value: OrderedUserValue,
    used: bool,

    fn hash(opt: OrderedUserInputOption, hasher: *std.hash.Wyhash) void {
        hasher.update(opt.name);
        opt.value.hash(hasher);
    }

    fn fromUnordered(allocator: Allocator, user_input_option: UserInputOption) OrderedUserInputOption {
        return OrderedUserInputOption{
            .name = user_input_option.name,
            .used = user_input_option.used,
            .value = OrderedUserValue.fromUnordered(allocator, user_input_option.value),
        };
    }

    fn lessThan(_: void, lhs: OrderedUserInputOption, rhs: OrderedUserInputOption) bool {
        return std.ascii.lessThanIgnoreCase(lhs.name, rhs.name);
    }
};

// The hash should be consistent with the same values given a different order.
// This function takes a user input map, orders it, then hashes the contents.
fn hashUserInputOptionsMap(allocator: Allocator, user_input_options: UserInputOptionsMap, hasher: *std.hash.Wyhash) void {
    var ordered = ArrayList(OrderedUserInputOption).init(allocator);
    var it = user_input_options.iterator();
    while (it.next()) |entry|
        ordered.append(OrderedUserInputOption.fromUnordered(allocator, entry.value_ptr.*)) catch @panic("OOM");

    std.mem.sortUnstable(OrderedUserInputOption, ordered.items, {}, OrderedUserInputOption.lessThan);

    // juice it
    for (ordered.items) |user_option|
        user_option.hash(hasher);
}

fn determineAndApplyInstallPrefix(b: *Build) error{OutOfMemory}!void {
    // Create an installation directory local to this package. This will be used when
    // dependant packages require a standard prefix, such as include directories for C headers.
    var hash = b.graph.cache.hash;
    // Random bytes to make unique. Refresh this with new random bytes when
    // implementation is modified in a non-backwards-compatible way.
    hash.add(@as(u32, 0xd8cb0055));
    hash.addBytes(b.dep_prefix);

    var wyhash = std.hash.Wyhash.init(0);
    hashUserInputOptionsMap(b.allocator, b.user_input_options, &wyhash);
    hash.add(wyhash.final());

    const digest = hash.final();
    const install_prefix = try b.cache_root.join(b.allocator, &.{ "i", &digest });
    b.resolveInstallPrefix(install_prefix, .{});
}

/// This function is intended to be called by lib/build_runner.zig, not a build.zig file.
pub fn resolveInstallPrefix(b: *Build, install_prefix: ?[]const u8, dir_list: DirList) void {
    if (b.dest_dir) |dest_dir| {
        b.install_prefix = install_prefix orelse "/usr";
        b.install_path = b.pathJoin(&.{ dest_dir, b.install_prefix });
    } else {
        b.install_prefix = install_prefix orelse
            (b.build_root.join(b.allocator, &.{"zig-out"}) catch @panic("unhandled error"));
        b.install_path = b.install_prefix;
    }

    var lib_list = [_][]const u8{ b.install_path, "lib" };
    var exe_list = [_][]const u8{ b.install_path, "bin" };
    var h_list = [_][]const u8{ b.install_path, "include" };

    if (dir_list.lib_dir) |dir| {
        if (fs.path.isAbsolute(dir)) lib_list[0] = b.dest_dir orelse "";
        lib_list[1] = dir;
    }

    if (dir_list.exe_dir) |dir| {
        if (fs.path.isAbsolute(dir)) exe_list[0] = b.dest_dir orelse "";
        exe_list[1] = dir;
    }

    if (dir_list.include_dir) |dir| {
        if (fs.path.isAbsolute(dir)) h_list[0] = b.dest_dir orelse "";
        h_list[1] = dir;
    }

    b.lib_dir = b.pathJoin(&lib_list);
    b.exe_dir = b.pathJoin(&exe_list);
    b.h_dir = b.pathJoin(&h_list);
}

/// Create a set of key-value pairs that can be converted into a Zig source
/// file and then inserted into a Zig compilation's module table for importing.
/// In other words, this provides a way to expose build.zig values to Zig
/// source code with `@import`.
/// Related: `Module.addOptions`.
pub fn addOptions(b: *Build) *Step.Options {
    return Step.Options.create(b);
}

pub const ExecutableOptions = struct {
    name: []const u8,
    root_module: *Module,
    version: ?std.SemanticVersion = null,
    linkage: ?std.builtin.LinkMode = null,
    max_rss: usize = 0,
    use_llvm: ?bool = null,
    use_lld: ?bool = null,
    zig_lib_dir: ?LazyPath = null,
    /// Embed a `.manifest` file in the compilation if the object format supports it.
    /// https://learn.microsoft.com/en-us/windows/win32/sbscs/manifest-files-reference
    /// Manifest files must have the extension `.manifest`.
    /// Can be set regardless of target. The `.manifest` file will be ignored
    /// if the target object format does not support embedded manifests.
    win32_manifest: ?LazyPath = null,
};

pub fn addExecutable(b: *Build, options: ExecutableOptions) *Step.Compile {
    return .create(b, .{
        .name = options.name,
        .root_module = options.root_module,
        .version = options.version,
        .kind = .exe,
        .linkage = options.linkage,
        .max_rss = options.max_rss,
        .use_llvm = options.use_llvm,
        .use_lld = options.use_lld,
        .zig_lib_dir = options.zig_lib_dir,
        .win32_manifest = options.win32_manifest,
    });
}

pub const ObjectOptions = struct {
    name: []const u8,
    root_module: *Module,
    max_rss: usize = 0,
    use_llvm: ?bool = null,
    use_lld: ?bool = null,
    zig_lib_dir: ?LazyPath = null,
};

pub fn addObject(b: *Build, options: ObjectOptions) *Step.Compile {
    return .create(b, .{
        .name = options.name,
        .root_module = options.root_module,
        .kind = .obj,
        .max_rss = options.max_rss,
        .use_llvm = options.use_llvm,
        .use_lld = options.use_lld,
        .zig_lib_dir = options.zig_lib_dir,
    });
}

pub const LibraryOptions = struct {
    linkage: std.builtin.LinkMode = .static,
    name: []const u8,
    root_module: *Module,
    version: ?std.SemanticVersion = null,
    max_rss: usize = 0,
    use_llvm: ?bool = null,
    use_lld: ?bool = null,
    zig_lib_dir: ?LazyPath = null,
    /// Embed a `.manifest` file in the compilation if the object format supports it.
    /// https://learn.microsoft.com/en-us/windows/win32/sbscs/manifest-files-reference
    /// Manifest files must have the extension `.manifest`.
    /// Can be set regardless of target. The `.manifest` file will be ignored
    /// if the target object format does not support embedded manifests.
    win32_manifest: ?LazyPath = null,
};

pub fn addLibrary(b: *Build, options: LibraryOptions) *Step.Compile {
    return .create(b, .{
        .name = options.name,
        .root_module = options.root_module,
        .kind = .lib,
        .linkage = options.linkage,
        .version = options.version,
        .max_rss = options.max_rss,
        .use_llvm = options.use_llvm,
        .use_lld = options.use_lld,
        .zig_lib_dir = options.zig_lib_dir,
        .win32_manifest = options.win32_manifest,
    });
}

pub const TestOptions = struct {
    name: []const u8 = "test",
    root_module: *Module,
    max_rss: usize = 0,
    filters: []const []const u8 = &.{},
    test_runner: ?Step.Compile.TestRunner = null,
    use_llvm: ?bool = null,
    use_lld: ?bool = null,
    zig_lib_dir: ?LazyPath = null,
    /// Emits an object file instead of a test binary.
    /// The object must be linked separately.
    /// Usually used in conjunction with a custom `test_runner`.
    emit_object: bool = false,
};

/// Creates an executable containing unit tests.
///
/// Equivalent to running the command `zig test --test-no-exec ...`.
///
/// **This step does not run the unit tests**. Typically, the result of this
/// function will be passed to `addRunArtifact`, creating a `Step.Run`. These
/// two steps are separated because they are independently configured and
/// cached.
pub fn addTest(b: *Build, options: TestOptions) *Step.Compile {
    return .create(b, .{
        .name = options.name,
        .kind = if (options.emit_object) .test_obj else .@"test",
        .root_module = options.root_module,
        .max_rss = options.max_rss,
        .filters = b.dupeStrings(options.filters),
        .test_runner = options.test_runner,
        .use_llvm = options.use_llvm,
        .use_lld = options.use_lld,
        .zig_lib_dir = options.zig_lib_dir,
    });
}

pub const AssemblyOptions = struct {
    name: []const u8,
    source_file: LazyPath,
    /// To choose the same computer as the one building the package, pass the
    /// `host` field of the package's `Build` instance.
    target: ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    max_rss: usize = 0,
    zig_lib_dir: ?LazyPath = null,
};

/// This function creates a module and adds it to the package's module set, making
/// it available to other packages which depend on this one.
/// `createModule` can be used instead to create a private module.
pub fn addModule(b: *Build, name: []const u8, options: Module.CreateOptions) *Module {
    const module = Module.create(b, options);
    b.modules.put(b.dupe(name), module) catch @panic("OOM");
    return module;
}

/// This function creates a private module, to be used by the current package,
/// but not exposed to other packages depending on this one.
/// `addModule` can be used instead to create a public module.
pub fn createModule(b: *Build, options: Module.CreateOptions) *Module {
    return Module.create(b, options);
}

/// Initializes a `Step.Run` with argv, which must at least have the path to the
/// executable. More command line arguments can be added with `addArg`,
/// `addArgs`, and `addArtifactArg`.
/// Be careful using this function, as it introduces a system dependency.
/// To run an executable built with zig build, see `Step.Compile.run`.
pub fn addSystemCommand(b: *Build, argv: []const []const u8) *Step.Run {
    assert(argv.len >= 1);
    const run_step = Step.Run.create(b, b.fmt("run {s}", .{argv[0]}));
    run_step.addArgs(argv);
    return run_step;
}

/// Creates a `Step.Run` with an executable built with `addExecutable`.
/// Add command line arguments with methods of `Step.Run`.
pub fn addRunArtifact(b: *Build, exe: *Step.Compile) *Step.Run {
    // It doesn't have to be native. We catch that if you actually try to run it.
    // Consider that this is declarative; the run step may not be run unless a user
    // option is supplied.

    // Avoid the common case of the step name looking like "run test test".
    const step_name = if (exe.kind.isTest() and mem.eql(u8, exe.name, "test"))
        b.fmt("run {s}", .{@tagName(exe.kind)})
    else
        b.fmt("run {s} {s}", .{ @tagName(exe.kind), exe.name });

    const run_step = Step.Run.create(b, step_name);
    run_step.producer = exe;
    if (exe.kind == .@"test") {
        if (exe.exec_cmd_args) |exec_cmd_args| {
            for (exec_cmd_args) |cmd_arg| {
                if (cmd_arg) |arg| {
                    run_step.addArg(arg);
                } else {
                    run_step.addArtifactArg(exe);
                }
            }
        } else {
            run_step.addArtifactArg(exe);
        }

        const test_server_mode = if (exe.test_runner) |r| r.mode == .server else true;
        if (test_server_mode) run_step.enableTestRunnerMode();
    } else {
        run_step.addArtifactArg(exe);
    }

    return run_step;
}

/// Using the `values` provided, produces a C header file, possibly based on a
/// template input file (e.g. config.h.in).
/// When an input template file is provided, this function will fail the build
/// when an option not found in the input file is provided in `values`, and
/// when an option found in the input file is missing from `values`.
pub fn addConfigHeader(
    b: *Build,
    options: Step.ConfigHeader.Options,
    values: anytype,
) *Step.ConfigHeader {
    var options_copy = options;
    if (options_copy.first_ret_addr == null)
        options_copy.first_ret_addr = @returnAddress();

    const config_header_step = Step.ConfigHeader.create(b, options_copy);
    config_header_step.addValues(values);
    return config_header_step;
}

/// Allocator.dupe without the need to handle out of memory.
pub fn dupe(b: *Build, bytes: []const u8) []u8 {
    return dupeInner(b.allocator, bytes);
}

pub fn dupeInner(allocator: std.mem.Allocator, bytes: []const u8) []u8 {
    return allocator.dupe(u8, bytes) catch @panic("OOM");
}

/// Duplicates an array of strings without the need to handle out of memory.
pub fn dupeStrings(b: *Build, strings: []const []const u8) [][]u8 {
    const array = b.allocator.alloc([]u8, strings.len) catch @panic("OOM");
    for (array, strings) |*dest, source| dest.* = b.dupe(source);
    return array;
}

/// Duplicates a path and converts all slashes to the OS's canonical path separator.
pub fn dupePath(b: *Build, bytes: []const u8) []u8 {
    return dupePathInner(b.allocator, bytes);
}

fn dupePathInner(allocator: std.mem.Allocator, bytes: []const u8) []u8 {
    const the_copy = dupeInner(allocator, bytes);
    for (the_copy) |*byte| {
        switch (byte.*) {
            '/', '\\' => byte.* = fs.path.sep,
            else => {},
        }
    }
    return the_copy;
}

pub fn addWriteFile(b: *Build, file_path: []const u8, data: []const u8) *Step.WriteFile {
    const write_file_step = b.addWriteFiles();
    _ = write_file_step.add(file_path, data);
    return write_file_step;
}

pub fn addNamedWriteFiles(b: *Build, name: []const u8) *Step.WriteFile {
    const wf = Step.WriteFile.create(b);
    b.named_writefiles.put(b.dupe(name), wf) catch @panic("OOM");
    return wf;
}

pub fn addNamedLazyPath(b: *Build, name: []const u8, lp: LazyPath) void {
    b.named_lazy_paths.put(b.dupe(name), lp.dupe(b)) catch @panic("OOM");
}

pub fn addWriteFiles(b: *Build) *Step.WriteFile {
    return Step.WriteFile.create(b);
}

pub fn addUpdateSourceFiles(b: *Build) *Step.UpdateSourceFiles {
    return Step.UpdateSourceFiles.create(b);
}

pub fn addRemoveDirTree(b: *Build, dir_path: LazyPath) *Step.RemoveDir {
    return Step.RemoveDir.create(b, dir_path);
}

pub fn addFail(b: *Build, error_msg: []const u8) *Step.Fail {
    return Step.Fail.create(b, error_msg);
}

pub fn addFmt(b: *Build, options: Step.Fmt.Options) *Step.Fmt {
    return Step.Fmt.create(b, options);
}

pub fn addTranslateC(b: *Build, options: Step.TranslateC.Options) *Step.TranslateC {
    return Step.TranslateC.create(b, options);
}

pub fn getInstallStep(b: *Build) *Step {
    return &b.install_tls.step;
}

pub fn getUninstallStep(b: *Build) *Step {
    return &b.uninstall_tls.step;
}

fn makeUninstall(uninstall_step: *Step, options: Step.MakeOptions) anyerror!void {
    _ = options;
    const uninstall_tls: *TopLevelStep = @fieldParentPtr("step", uninstall_step);
    const b: *Build = @fieldParentPtr("uninstall_tls", uninstall_tls);

    _ = b;
    @panic("TODO implement https://github.com/ziglang/zig/issues/14943");
}

/// Creates a configuration option to be passed to the build.zig script.
/// When a user directly runs `zig build`, they can set these options with `-D` arguments.
/// When a project depends on a Zig package as a dependency, it programmatically sets
/// these options when calling the dependency's build.zig script as a function.
/// `null` is returned when an option is left to default.
pub fn option(b: *Build, comptime T: type, name_raw: []const u8, description_raw: []const u8) ?T {
    const name = b.dupe(name_raw);
    const description = b.dupe(description_raw);
    const type_id = comptime typeToEnum(T);
    const enum_options = if (type_id == .@"enum" or type_id == .enum_list) blk: {
        const EnumType = if (type_id == .enum_list) @typeInfo(T).pointer.child else T;
        const fields = comptime std.meta.fields(EnumType);
        var options = ArrayList([]const u8).initCapacity(b.allocator, fields.len) catch @panic("OOM");

        inline for (fields) |field| {
            options.appendAssumeCapacity(field.name);
        }

        break :blk options.toOwnedSlice() catch @panic("OOM");
    } else null;
    const available_option = AvailableOption{
        .name = name,
        .type_id = type_id,
        .description = description,
        .enum_options = enum_options,
    };
    if ((b.available_options_map.fetchPut(name, available_option) catch @panic("OOM")) != null) {
        panic("Option '{s}' declared twice", .{name});
    }
    b.available_options_list.append(available_option) catch @panic("OOM");

    const option_ptr = b.user_input_options.getPtr(name) orelse return null;
    option_ptr.used = true;
    switch (type_id) {
        .bool => switch (option_ptr.value) {
            .flag => return true,
            .scalar => |s| {
                if (mem.eql(u8, s, "true")) {
                    return true;
                } else if (mem.eql(u8, s, "false")) {
                    return false;
                } else {
                    log.err("Expected -D{s} to be a boolean, but received '{s}'", .{ name, s });
                    b.markInvalidUserInput();
                    return null;
                }
            },
            .list, .map, .lazy_path, .lazy_path_list => {
                log.err("Expected -D{s} to be a boolean, but received a {s}.", .{
                    name, @tagName(option_ptr.value),
                });
                b.markInvalidUserInput();
                return null;
            },
        },
        .int => switch (option_ptr.value) {
            .flag, .list, .map, .lazy_path, .lazy_path_list => {
                log.err("Expected -D{s} to be an integer, but received a {s}.", .{
                    name, @tagName(option_ptr.value),
                });
                b.markInvalidUserInput();
                return null;
            },
            .scalar => |s| {
                const n = std.fmt.parseInt(T, s, 10) catch |err| switch (err) {
                    error.Overflow => {
                        log.err("-D{s} value {s} cannot fit into type {s}.", .{ name, s, @typeName(T) });
                        b.markInvalidUserInput();
                        return null;
                    },
                    else => {
                        log.err("Expected -D{s} to be an integer of type {s}.", .{ name, @typeName(T) });
                        b.markInvalidUserInput();
                        return null;
                    },
                };
                return n;
            },
        },
        .float => switch (option_ptr.value) {
            .flag, .map, .list, .lazy_path, .lazy_path_list => {
                log.err("Expected -D{s} to be a float, but received a {s}.", .{
                    name, @tagName(option_ptr.value),
                });
                b.markInvalidUserInput();
                return null;
            },
            .scalar => |s| {
                const n = std.fmt.parseFloat(T, s) catch {
                    log.err("Expected -D{s} to be a float of type {s}.", .{ name, @typeName(T) });
                    b.markInvalidUserInput();
                    return null;
                };
                return n;
            },
        },
        .@"enum" => switch (option_ptr.value) {
            .flag, .map, .list, .lazy_path, .lazy_path_list => {
                log.err("Expected -D{s} to be an enum, but received a {s}.", .{
                    name, @tagName(option_ptr.value),
                });
                b.markInvalidUserInput();
                return null;
            },
            .scalar => |s| {
                if (std.meta.stringToEnum(T, s)) |enum_lit| {
                    return enum_lit;
                } else {
                    log.err("Expected -D{s} to be of type {s}.", .{ name, @typeName(T) });
                    b.markInvalidUserInput();
                    return null;
                }
            },
        },
        .string => switch (option_ptr.value) {
            .flag, .list, .map, .lazy_path, .lazy_path_list => {
                log.err("Expected -D{s} to be a string, but received a {s}.", .{
                    name, @tagName(option_ptr.value),
                });
                b.markInvalidUserInput();
                return null;
            },
            .scalar => |s| return s,
        },
        .build_id => switch (option_ptr.value) {
            .flag, .map, .list, .lazy_path, .lazy_path_list => {
                log.err("Expected -D{s} to be an enum, but received a {s}.", .{
                    name, @tagName(option_ptr.value),
                });
                b.markInvalidUserInput();
                return null;
            },
            .scalar => |s| {
                if (std.zig.BuildId.parse(s)) |build_id| {
                    return build_id;
                } else |err| {
                    log.err("unable to parse option '-D{s}': {s}", .{ name, @errorName(err) });
                    b.markInvalidUserInput();
                    return null;
                }
            },
        },
        .list => switch (option_ptr.value) {
            .flag, .map, .lazy_path, .lazy_path_list => {
                log.err("Expected -D{s} to be a list, but received a {s}.", .{
                    name, @tagName(option_ptr.value),
                });
                b.markInvalidUserInput();
                return null;
            },
            .scalar => |s| {
                return b.allocator.dupe([]const u8, &[_][]const u8{s}) catch @panic("OOM");
            },
            .list => |lst| return lst.items,
        },
        .enum_list => switch (option_ptr.value) {
            .flag, .map, .lazy_path, .lazy_path_list => {
                log.err("Expected -D{s} to be a list, but received a {s}.", .{
                    name, @tagName(option_ptr.value),
                });
                b.markInvalidUserInput();
                return null;
            },
            .scalar => |s| {
                const Child = @typeInfo(T).pointer.child;
                const value = std.meta.stringToEnum(Child, s) orelse {
                    log.err("Expected -D{s} to be of type {s}.", .{ name, @typeName(Child) });
                    b.markInvalidUserInput();
                    return null;
                };
                return b.allocator.dupe(Child, &[_]Child{value}) catch @panic("OOM");
            },
            .list => |lst| {
                const Child = @typeInfo(T).pointer.child;
                const new_list = b.allocator.alloc(Child, lst.items.len) catch @panic("OOM");
                for (new_list, lst.items) |*new_item, str| {
                    new_item.* = std.meta.stringToEnum(Child, str) orelse {
                        log.err("Expected -D{s} to be of type {s}.", .{ name, @typeName(Child) });
                        b.markInvalidUserInput();
                        b.allocator.free(new_list);
                        return null;
                    };
                }
                return new_list;
            },
        },
        .lazy_path => switch (option_ptr.value) {
            .scalar => |s| return .{ .cwd_relative = s },
            .lazy_path => |lp| return lp,
            .flag, .map, .list, .lazy_path_list => {
                log.err("Expected -D{s} to be a path, but received a {s}.", .{
                    name, @tagName(option_ptr.value),
                });
                b.markInvalidUserInput();
                return null;
            },
        },
        .lazy_path_list => switch (option_ptr.value) {
            .scalar => |s| return b.allocator.dupe(LazyPath, &[_]LazyPath{.{ .cwd_relative = s }}) catch @panic("OOM"),
            .lazy_path => |lp| return b.allocator.dupe(LazyPath, &[_]LazyPath{lp}) catch @panic("OOM"),
            .list => |lst| {
                const new_list = b.allocator.alloc(LazyPath, lst.items.len) catch @panic("OOM");
                for (new_list, lst.items) |*new_item, str| {
                    new_item.* = .{ .cwd_relative = str };
                }
                return new_list;
            },
            .lazy_path_list => |lp_list| return lp_list.items,
            .flag, .map => {
                log.err("Expected -D{s} to be a path, but received a {s}.", .{
                    name, @tagName(option_ptr.value),
                });
                b.markInvalidUserInput();
                return null;
            },
        },
    }
}

pub fn step(b: *Build, name: []const u8, description: []const u8) *Step {
    const step_info = b.allocator.create(TopLevelStep) catch @panic("OOM");
    step_info.* = .{
        .step = .init(.{
            .id = TopLevelStep.base_id,
            .name = name,
            .owner = b,
        }),
        .description = b.dupe(description),
    };
    const gop = b.top_level_steps.getOrPut(b.allocator, name) catch @panic("OOM");
    if (gop.found_existing) std.debug.panic("A top-level step with name \"{s}\" already exists", .{name});

    gop.key_ptr.* = step_info.step.name;
    gop.value_ptr.* = step_info;

    return &step_info.step;
}

pub const StandardOptimizeOptionOptions = struct {
    preferred_optimize_mode: ?std.builtin.OptimizeMode = null,
};

pub fn standardOptimizeOption(b: *Build, options: StandardOptimizeOptionOptions) std.builtin.OptimizeMode {
    if (options.preferred_optimize_mode) |mode| {
        if (b.option(bool, "release", "optimize for end users") orelse (b.release_mode != .off)) {
            return mode;
        } else {
            return .Debug;
        }
    }

    if (b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size",
    )) |mode| {
        return mode;
    }

    return switch (b.release_mode) {
        .off => .Debug,
        .any => {
            std.debug.print("the project does not declare a preferred optimization mode. choose: --release=fast, --release=safe, or --release=small\n", .{});
            process.exit(1);
        },
        .fast => .ReleaseFast,
        .safe => .ReleaseSafe,
        .small => .ReleaseSmall,
    };
}

pub const StandardTargetOptionsArgs = struct {
    whitelist: ?[]const Target.Query = null,
    default_target: Target.Query = .{},
};

/// Exposes standard `zig build` options for choosing a target and additionally
/// resolves the target query.
pub fn standardTargetOptions(b: *Build, args: StandardTargetOptionsArgs) ResolvedTarget {
    const query = b.standardTargetOptionsQueryOnly(args);
    return b.resolveTargetQuery(query);
}

/// Obtain a target query from a string, reporting diagnostics to stderr if the
/// parsing failed.
/// Asserts that the `diagnostics` field of `options` is `null`. This use case
/// is handled instead by calling `std.Target.Query.parse` directly.
pub fn parseTargetQuery(options: std.Target.Query.ParseOptions) error{ParseFailed}!std.Target.Query {
    assert(options.diagnostics == null);
    var diags: Target.Query.ParseOptions.Diagnostics = .{};
    var opts_copy = options;
    opts_copy.diagnostics = &diags;
    return std.Target.Query.parse(opts_copy) catch |err| switch (err) {
        error.UnknownCpuModel => {
            std.debug.print("unknown CPU: '{s}'\navailable CPUs for architecture '{s}':\n", .{
                diags.cpu_name.?, @tagName(diags.arch.?),
            });
            for (diags.arch.?.allCpuModels()) |cpu| {
                std.debug.print(" {s}\n", .{cpu.name});
            }
            return error.ParseFailed;
        },
        error.UnknownCpuFeature => {
            std.debug.print(
                \\unknown CPU feature: '{s}'
                \\available CPU features for architecture '{s}':
                \\
            , .{
                diags.unknown_feature_name.?,
                @tagName(diags.arch.?),
            });
            for (diags.arch.?.allFeaturesList()) |feature| {
                std.debug.print(" {s}: {s}\n", .{ feature.name, feature.description });
            }
            return error.ParseFailed;
        },
        error.UnknownOperatingSystem => {
            std.debug.print(
                \\unknown OS: '{s}'
                \\available operating systems:
                \\
            , .{diags.os_name.?});
            inline for (std.meta.fields(Target.Os.Tag)) |field| {
                std.debug.print(" {s}\n", .{field.name});
            }
            return error.ParseFailed;
        },
        else => |e| {
            std.debug.print("unable to parse target '{s}': {s}\n", .{
                options.arch_os_abi, @errorName(e),
            });
            return error.ParseFailed;
        },
    };
}

/// Exposes standard `zig build` options for choosing a target.
pub fn standardTargetOptionsQueryOnly(b: *Build, args: StandardTargetOptionsArgs) Target.Query {
    const maybe_triple = b.option(
        []const u8,
        "target",
        "The CPU architecture, OS, and ABI to build for",
    );
    const mcpu = b.option(
        []const u8,
        "cpu",
        "Target CPU features to add or subtract",
    );
    const ofmt = b.option(
        []const u8,
        "ofmt",
        "Target object format",
    );
    const dynamic_linker = b.option(
        []const u8,
        "dynamic-linker",
        "Path to interpreter on the target system",
    );

    if (maybe_triple == null and mcpu == null and ofmt == null and dynamic_linker == null)
        return args.default_target;

    const triple = maybe_triple orelse "native";

    const selected_target = parseTargetQuery(.{
        .arch_os_abi = triple,
        .cpu_features = mcpu,
        .object_format = ofmt,
        .dynamic_linker = dynamic_linker,
    }) catch |err| switch (err) {
        error.ParseFailed => {
            b.markInvalidUserInput();
            return args.default_target;
        },
    };

    const whitelist = args.whitelist orelse return selected_target;

    // Make sure it's a match of one of the list.
    for (whitelist) |q| {
        if (q.eql(selected_target))
            return selected_target;
    }

    for (whitelist) |q| {
        log.info("allowed target: -Dtarget={s} -Dcpu={s}", .{
            q.zigTriple(b.allocator) catch @panic("OOM"),
            q.serializeCpuAlloc(b.allocator) catch @panic("OOM"),
        });
    }
    log.err("chosen target '{s}' does not match one of the allowed targets", .{
        selected_target.zigTriple(b.allocator) catch @panic("OOM"),
    });
    b.markInvalidUserInput();
    return args.default_target;
}

pub fn addUserInputOption(b: *Build, name_raw: []const u8, value_raw: []const u8) error{OutOfMemory}!bool {
    const name = b.dupe(name_raw);
    const value = b.dupe(value_raw);
    const gop = try b.user_input_options.getOrPut(name);
    if (!gop.found_existing) {
        gop.value_ptr.* = UserInputOption{
            .name = name,
            .value = .{ .scalar = value },
            .used = false,
        };
        return false;
    }

    // option already exists
    switch (gop.value_ptr.value) {
        .scalar => |s| {
            // turn it into a list
            var list = ArrayList([]const u8).init(b.allocator);
            try list.append(s);
            try list.append(value);
            try b.user_input_options.put(name, .{
                .name = name,
                .value = .{ .list = list },
                .used = false,
            });
        },
        .list => |*list| {
            // append to the list
            try list.append(value);
            try b.user_input_options.put(name, .{
                .name = name,
                .value = .{ .list = list.* },
                .used = false,
            });
        },
        .flag => {
            log.warn("option '-D{s}={s}' conflicts with flag '-D{s}'.", .{ name, value, name });
            return true;
        },
        .map => |*map| {
            _ = map;
            log.warn("TODO maps as command line arguments is not implemented yet.", .{});
            return true;
        },
        .lazy_path, .lazy_path_list => {
            log.warn("the lazy path value type isn't added from the CLI, but somehow '{s}' is a .{f}", .{ name, std.zig.fmtId(@tagName(gop.value_ptr.value)) });
            return true;
        },
    }
    return false;
}

pub fn addUserInputFlag(b: *Build, name_raw: []const u8) error{OutOfMemory}!bool {
    const name = b.dupe(name_raw);
    const gop = try b.user_input_options.getOrPut(name);
    if (!gop.found_existing) {
        gop.value_ptr.* = .{
            .name = name,
            .value = .{ .flag = {} },
            .used = false,
        };
        return false;
    }

    // option already exists
    switch (gop.value_ptr.value) {
        .scalar => |s| {
            log.err("Flag '-D{s}' conflicts with option '-D{s}={s}'.", .{ name, name, s });
            return true;
        },
        .list, .map, .lazy_path_list => {
            log.err("Flag '-D{s}' conflicts with multiple options of the same name.", .{name});
            return true;
        },
        .lazy_path => |lp| {
            log.err("Flag '-D{s}' conflicts with option '-D{s}={s}'.", .{ name, name, lp.getDisplayName() });
            return true;
        },

        .flag => {},
    }
    return false;
}

fn typeToEnum(comptime T: type) TypeId {
    return switch (T) {
        std.zig.BuildId => .build_id,
        LazyPath => .lazy_path,
        else => return switch (@typeInfo(T)) {
            .int => .int,
            .float => .float,
            .bool => .bool,
            .@"enum" => .@"enum",
            .pointer => |pointer| switch (pointer.child) {
                u8 => .string,
                []const u8 => .list,
                LazyPath => .lazy_path_list,
                else => switch (@typeInfo(pointer.child)) {
                    .@"enum" => .enum_list,
                    else => @compileError("Unsupported type: " ++ @typeName(T)),
                },
            },
            else => @compileError("Unsupported type: " ++ @typeName(T)),
        },
    };
}

fn markInvalidUserInput(b: *Build) void {
    b.invalid_user_input = true;
}

pub fn validateUserInputDidItFail(b: *Build) bool {
    // Make sure all args are used.
    var it = b.user_input_options.iterator();
    while (it.next()) |entry| {
        if (!entry.value_ptr.used) {
            log.err("invalid option: -D{s}", .{entry.key_ptr.*});
            b.markInvalidUserInput();
        }
    }

    return b.invalid_user_input;
}

fn allocPrintCmd(gpa: Allocator, opt_cwd: ?[]const u8, argv: []const []const u8) error{OutOfMemory}![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    if (opt_cwd) |cwd| try buf.print(gpa, "cd {s} && ", .{cwd});
    for (argv) |arg| {
        try buf.print(gpa, "{s} ", .{arg});
    }
    return buf.toOwnedSlice(gpa);
}

fn printCmd(ally: Allocator, cwd: ?[]const u8, argv: []const []const u8) void {
    const text = allocPrintCmd(ally, cwd, argv) catch @panic("OOM");
    std.debug.print("{s}\n", .{text});
}

/// This creates the install step and adds it to the dependencies of the
/// top-level install step, using all the default options.
/// See `addInstallArtifact` for a more flexible function.
pub fn installArtifact(b: *Build, artifact: *Step.Compile) void {
    b.getInstallStep().dependOn(&b.addInstallArtifact(artifact, .{}).step);
}

/// This merely creates the step; it does not add it to the dependencies of the
/// top-level install step.
pub fn addInstallArtifact(
    b: *Build,
    artifact: *Step.Compile,
    options: Step.InstallArtifact.Options,
) *Step.InstallArtifact {
    return Step.InstallArtifact.create(b, artifact, options);
}

///`dest_rel_path` is relative to prefix path
pub fn installFile(b: *Build, src_path: []const u8, dest_rel_path: []const u8) void {
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(b.path(src_path), .prefix, dest_rel_path).step);
}

pub fn installDirectory(b: *Build, options: Step.InstallDir.Options) void {
    b.getInstallStep().dependOn(&b.addInstallDirectory(options).step);
}

///`dest_rel_path` is relative to bin path
pub fn installBinFile(b: *Build, src_path: []const u8, dest_rel_path: []const u8) void {
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(b.path(src_path), .bin, dest_rel_path).step);
}

///`dest_rel_path` is relative to lib path
pub fn installLibFile(b: *Build, src_path: []const u8, dest_rel_path: []const u8) void {
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(b.path(src_path), .lib, dest_rel_path).step);
}

pub fn addObjCopy(b: *Build, source: LazyPath, options: Step.ObjCopy.Options) *Step.ObjCopy {
    return Step.ObjCopy.create(b, source, options);
}

/// `dest_rel_path` is relative to install prefix path
pub fn addInstallFile(b: *Build, source: LazyPath, dest_rel_path: []const u8) *Step.InstallFile {
    return b.addInstallFileWithDir(source, .prefix, dest_rel_path);
}

/// `dest_rel_path` is relative to bin path
pub fn addInstallBinFile(b: *Build, source: LazyPath, dest_rel_path: []const u8) *Step.InstallFile {
    return b.addInstallFileWithDir(source, .bin, dest_rel_path);
}

/// `dest_rel_path` is relative to lib path
pub fn addInstallLibFile(b: *Build, source: LazyPath, dest_rel_path: []const u8) *Step.InstallFile {
    return b.addInstallFileWithDir(source, .lib, dest_rel_path);
}

/// `dest_rel_path` is relative to header path
pub fn addInstallHeaderFile(b: *Build, source: LazyPath, dest_rel_path: []const u8) *Step.InstallFile {
    return b.addInstallFileWithDir(source, .header, dest_rel_path);
}

pub fn addInstallFileWithDir(
    b: *Build,
    source: LazyPath,
    install_dir: InstallDir,
    dest_rel_path: []const u8,
) *Step.InstallFile {
    return Step.InstallFile.create(b, source, install_dir, dest_rel_path);
}

pub fn addInstallDirectory(b: *Build, options: Step.InstallDir.Options) *Step.InstallDir {
    return Step.InstallDir.create(b, options);
}

pub fn addCheckFile(
    b: *Build,
    file_source: LazyPath,
    options: Step.CheckFile.Options,
) *Step.CheckFile {
    return Step.CheckFile.create(b, file_source, options);
}

pub fn truncateFile(b: *Build, dest_path: []const u8) (fs.Dir.MakeError || fs.Dir.StatFileError)!void {
    if (b.verbose) {
        log.info("truncate {s}", .{dest_path});
    }
    const cwd = fs.cwd();
    var src_file = cwd.createFile(dest_path, .{}) catch |err| switch (err) {
        error.FileNotFound => blk: {
            if (fs.path.dirname(dest_path)) |dirname| {
                try cwd.makePath(dirname);
            }
            break :blk try cwd.createFile(dest_path, .{});
        },
        else => |e| return e,
    };
    src_file.close();
}

/// References a file or directory relative to the source root.
pub fn path(b: *Build, sub_path: []const u8) LazyPath {
    if (fs.path.isAbsolute(sub_path)) {
        std.debug.panic("sub_path is expected to be relative to the build root, but was this absolute path: '{s}'. It is best avoid absolute paths, but if you must, it is supported by LazyPath.cwd_relative", .{
            sub_path,
        });
    }
    return .{ .src_path = .{
        .owner = b,
        .sub_path = sub_path,
    } };
}

/// This is low-level implementation details of the build system, not meant to
/// be called by users' build scripts. Even in the build system itself it is a
/// code smell to call this function.
pub fn pathFromRoot(b: *Build, sub_path: []const u8) []u8 {
    return b.pathResolve(&.{ b.build_root.path orelse ".", sub_path });
}

fn pathFromCwd(b: *Build, sub_path: []const u8) []u8 {
    const cwd = process.getCwdAlloc(b.allocator) catch @panic("OOM");
    return b.pathResolve(&.{ cwd, sub_path });
}

pub fn pathJoin(b: *Build, paths: []const []const u8) []u8 {
    return fs.path.join(b.allocator, paths) catch @panic("OOM");
}

pub fn pathResolve(b: *Build, paths: []const []const u8) []u8 {
    return fs.path.resolve(b.allocator, paths) catch @panic("OOM");
}

pub fn fmt(b: *Build, comptime format: []const u8, args: anytype) []u8 {
    return std.fmt.allocPrint(b.allocator, format, args) catch @panic("OOM");
}

fn supportedWindowsProgramExtension(ext: []const u8) bool {
    inline for (@typeInfo(std.process.Child.WindowsExtension).@"enum".fields) |field| {
        if (std.ascii.eqlIgnoreCase(ext, "." ++ field.name)) return true;
    }
    return false;
}

fn tryFindProgram(b: *Build, full_path: []const u8) ?[]const u8 {
    if (fs.realpathAlloc(b.allocator, full_path)) |p| {
        return p;
    } else |err| switch (err) {
        error.OutOfMemory => @panic("OOM"),
        else => {},
    }

    if (builtin.os.tag == .windows) {
        if (b.graph.env_map.get("PATHEXT")) |PATHEXT| {
            var it = mem.tokenizeScalar(u8, PATHEXT, fs.path.delimiter);

            while (it.next()) |ext| {
                if (!supportedWindowsProgramExtension(ext)) continue;

                return fs.realpathAlloc(b.allocator, b.fmt("{s}{s}", .{ full_path, ext })) catch |err| switch (err) {
                    error.OutOfMemory => @panic("OOM"),
                    else => continue,
                };
            }
        }
    }

    return null;
}

pub fn findProgram(b: *Build, names: []const []const u8, paths: []const []const u8) error{FileNotFound}![]const u8 {
    // TODO report error for ambiguous situations
    for (b.search_prefixes.items) |search_prefix| {
        for (names) |name| {
            if (fs.path.isAbsolute(name)) {
                return name;
            }
            return tryFindProgram(b, b.pathJoin(&.{ search_prefix, "bin", name })) orelse continue;
        }
    }
    if (b.graph.env_map.get("PATH")) |PATH| {
        for (names) |name| {
            if (fs.path.isAbsolute(name)) {
                return name;
            }
            var it = mem.tokenizeScalar(u8, PATH, fs.path.delimiter);
            while (it.next()) |p| {
                return tryFindProgram(b, b.pathJoin(&.{ p, name })) orelse continue;
            }
        }
    }
    for (names) |name| {
        if (fs.path.isAbsolute(name)) {
            return name;
        }
        for (paths) |p| {
            return tryFindProgram(b, b.pathJoin(&.{ p, name })) orelse continue;
        }
    }
    return error.FileNotFound;
}

pub fn runAllowFail(
    b: *Build,
    argv: []const []const u8,
    out_code: *u8,
    stderr_behavior: std.process.Child.StdIo,
) RunError![]u8 {
    assert(argv.len != 0);

    if (!process.can_spawn)
        return error.ExecNotSupported;

    const max_output_size = 400 * 1024;
    var child = std.process.Child.init(argv, b.allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = stderr_behavior;
    child.env_map = &b.graph.env_map;

    try Step.handleVerbose2(b, null, child.env_map, argv);
    try child.spawn();

    const stdout = child.stdout.?.deprecatedReader().readAllAlloc(b.allocator, max_output_size) catch {
        return error.ReadFailure;
    };
    errdefer b.allocator.free(stdout);

    const term = try child.wait();
    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                out_code.* = @as(u8, @truncate(code));
                return error.ExitCodeFailure;
            }
            return stdout;
        },
        .Signal, .Stopped, .Unknown => |code| {
            out_code.* = @as(u8, @truncate(code));
            return error.ProcessTerminated;
        },
    }
}

/// This is a helper function to be called from build.zig scripts, *not* from
/// inside step make() functions. If any errors occur, it fails the build with
/// a helpful message.
pub fn run(b: *Build, argv: []const []const u8) []u8 {
    if (!process.can_spawn) {
        std.debug.print("unable to spawn the following command: cannot spawn child process\n{s}\n", .{
            try allocPrintCmd(b.allocator, null, argv),
        });
        process.exit(1);
    }

    var code: u8 = undefined;
    return b.runAllowFail(argv, &code, .Inherit) catch |err| {
        const printed_cmd = allocPrintCmd(b.allocator, null, argv) catch @panic("OOM");
        std.debug.print("unable to spawn the following command: {s}\n{s}\n", .{
            @errorName(err), printed_cmd,
        });
        process.exit(1);
    };
}

pub fn addSearchPrefix(b: *Build, search_prefix: []const u8) void {
    b.search_prefixes.append(b.allocator, b.dupePath(search_prefix)) catch @panic("OOM");
}

pub fn getInstallPath(b: *Build, dir: InstallDir, dest_rel_path: []const u8) []const u8 {
    assert(!fs.path.isAbsolute(dest_rel_path)); // Install paths must be relative to the prefix
    const base_dir = switch (dir) {
        .prefix => b.install_path,
        .bin => b.exe_dir,
        .lib => b.lib_dir,
        .header => b.h_dir,
        .custom => |p| b.pathJoin(&.{ b.install_path, p }),
    };
    return b.pathResolve(&.{ base_dir, dest_rel_path });
}

pub const Dependency = struct {
    builder: *Build,

    pub fn artifact(d: *Dependency, name: []const u8) *Step.Compile {
        var found: ?*Step.Compile = null;
        for (d.builder.install_tls.step.dependencies.items) |dep_step| {
            const inst = dep_step.cast(Step.InstallArtifact) orelse continue;
            if (mem.eql(u8, inst.artifact.name, name)) {
                if (found != null) panic("artifact name '{s}' is ambiguous", .{name});
                found = inst.artifact;
            }
        }
        return found orelse {
            for (d.builder.install_tls.step.dependencies.items) |dep_step| {
                const inst = dep_step.cast(Step.InstallArtifact) orelse continue;
                log.info("available artifact: '{s}'", .{inst.artifact.name});
            }
            panic("unable to find artifact '{s}'", .{name});
        };
    }

    pub fn module(d: *Dependency, name: []const u8) *Module {
        return d.builder.modules.get(name) orelse {
            panic("unable to find module '{s}'", .{name});
        };
    }

    pub fn namedWriteFiles(d: *Dependency, name: []const u8) *Step.WriteFile {
        return d.builder.named_writefiles.get(name) orelse {
            panic("unable to find named writefiles '{s}'", .{name});
        };
    }

    pub fn namedLazyPath(d: *Dependency, name: []const u8) LazyPath {
        return d.builder.named_lazy_paths.get(name) orelse {
            panic("unable to find named lazypath '{s}'", .{name});
        };
    }

    pub fn path(d: *Dependency, sub_path: []const u8) LazyPath {
        return .{
            .dependency = .{
                .dependency = d,
                .sub_path = sub_path,
            },
        };
    }
};

fn findPkgHashOrFatal(b: *Build, name: []const u8) []const u8 {
    for (b.available_deps) |dep| {
        if (mem.eql(u8, dep[0], name)) return dep[1];
    }

    const full_path = b.pathFromRoot("build.zig.zon");
    std.debug.panic("no dependency named '{s}' in '{s}'. All packages used in build.zig must be declared in this file", .{ name, full_path });
}

inline fn findImportPkgHashOrFatal(b: *Build, comptime asking_build_zig: type, comptime dep_name: []const u8) []const u8 {
    const build_runner = @import("root");
    const deps = build_runner.dependencies;

    const b_pkg_hash, const b_pkg_deps = comptime for (@typeInfo(deps.packages).@"struct".decls) |decl| {
        const pkg_hash = decl.name;
        const pkg = @field(deps.packages, pkg_hash);
        if (@hasDecl(pkg, "build_zig") and pkg.build_zig == asking_build_zig) break .{ pkg_hash, pkg.deps };
    } else .{ "", deps.root_deps };
    if (!std.mem.eql(u8, b_pkg_hash, b.pkg_hash)) {
        std.debug.panic("'{}' is not the struct that corresponds to '{s}'", .{ asking_build_zig, b.pathFromRoot("build.zig") });
    }
    comptime for (b_pkg_deps) |dep| {
        if (std.mem.eql(u8, dep[0], dep_name)) return dep[1];
    };

    const full_path = b.pathFromRoot("build.zig.zon");
    std.debug.panic("no dependency named '{s}' in '{s}'. All packages used in build.zig must be declared in this file", .{ dep_name, full_path });
}

fn markNeededLazyDep(b: *Build, pkg_hash: []const u8) void {
    b.graph.needed_lazy_dependencies.put(b.graph.arena, pkg_hash, {}) catch @panic("OOM");
}

/// When this function is called, it means that the current build does, in
/// fact, require this dependency. If the dependency is already fetched, it
/// proceeds in the same manner as `dependency`. However if the dependency was
/// not fetched, then when the build script is finished running, the build will
/// not proceed to the make phase. Instead, the parent process will
/// additionally fetch all the lazy dependencies that were actually required by
/// running the build script, rebuild the build script, and then run it again.
/// In other words, if this function returns `null` it means that the only
/// purpose of completing the configure phase is to find out all the other lazy
/// dependencies that are also required.
/// It is allowed to use this function for non-lazy dependencies, in which case
/// it will never return `null`. This allows toggling laziness via
/// build.zig.zon without changing build.zig logic.
pub fn lazyDependency(b: *Build, name: []const u8, args: anytype) ?*Dependency {
    const build_runner = @import("root");
    const deps = build_runner.dependencies;
    const pkg_hash = findPkgHashOrFatal(b, name);

    inline for (@typeInfo(deps.packages).@"struct".decls) |decl| {
        if (mem.eql(u8, decl.name, pkg_hash)) {
            const pkg = @field(deps.packages, decl.name);
            const available = !@hasDecl(pkg, "available") or pkg.available;
            if (!available) {
                markNeededLazyDep(b, pkg_hash);
                return null;
            }
            return dependencyInner(b, name, pkg.build_root, if (@hasDecl(pkg, "build_zig")) pkg.build_zig else null, pkg_hash, pkg.deps, args);
        }
    }

    unreachable; // Bad @dependencies source
}

pub fn dependency(b: *Build, name: []const u8, args: anytype) *Dependency {
    const build_runner = @import("root");
    const deps = build_runner.dependencies;
    const pkg_hash = findPkgHashOrFatal(b, name);

    inline for (@typeInfo(deps.packages).@"struct".decls) |decl| {
        if (mem.eql(u8, decl.name, pkg_hash)) {
            const pkg = @field(deps.packages, decl.name);
            if (@hasDecl(pkg, "available")) {
                std.debug.panic("dependency '{s}{s}' is marked as lazy in build.zig.zon which means it must use the lazyDependency function instead", .{ b.dep_prefix, name });
            }
            return dependencyInner(b, name, pkg.build_root, if (@hasDecl(pkg, "build_zig")) pkg.build_zig else null, pkg_hash, pkg.deps, args);
        }
    }

    unreachable; // Bad @dependencies source
}

/// In a build.zig file, this function is to `@import` what `lazyDependency` is to `dependency`.
/// If the dependency is lazy and has not yet been fetched, it instructs the parent process to fetch
/// that dependency after the build script has finished running, then returns `null`.
/// If the dependency is lazy but has already been fetched, or if it is eager, it returns
/// the build.zig struct of that dependency, just like a regular `@import`.
pub inline fn lazyImport(
    b: *Build,
    /// The build.zig struct of the package importing the dependency.
    /// When calling this function from the `build` function of a build.zig file's, you normally
    /// pass `@This()`.
    comptime asking_build_zig: type,
    comptime dep_name: []const u8,
) ?type {
    const build_runner = @import("root");
    const deps = build_runner.dependencies;
    const pkg_hash = findImportPkgHashOrFatal(b, asking_build_zig, dep_name);

    inline for (@typeInfo(deps.packages).@"struct".decls) |decl| {
        if (comptime mem.eql(u8, decl.name, pkg_hash)) {
            const pkg = @field(deps.packages, decl.name);
            const available = !@hasDecl(pkg, "available") or pkg.available;
            if (!available) {
                markNeededLazyDep(b, pkg_hash);
                return null;
            }
            return if (@hasDecl(pkg, "build_zig"))
                pkg.build_zig
            else
                @compileError("dependency '" ++ dep_name ++ "' does not have a build.zig");
        }
    }

    comptime unreachable; // Bad @dependencies source
}

pub fn dependencyFromBuildZig(
    b: *Build,
    /// The build.zig struct of the dependency, normally obtained by `@import` of the dependency.
    /// If called from the build.zig file itself, use `@This` to obtain a reference to the struct.
    comptime build_zig: type,
    args: anytype,
) *Dependency {
    const build_runner = @import("root");
    const deps = build_runner.dependencies;

    find_dep: {
        const pkg, const pkg_hash = inline for (@typeInfo(deps.packages).@"struct".decls) |decl| {
            const pkg_hash = decl.name;
            const pkg = @field(deps.packages, pkg_hash);
            if (@hasDecl(pkg, "build_zig") and pkg.build_zig == build_zig) break .{ pkg, pkg_hash };
        } else break :find_dep;
        const dep_name = for (b.available_deps) |dep| {
            if (mem.eql(u8, dep[1], pkg_hash)) break dep[1];
        } else break :find_dep;
        return dependencyInner(b, dep_name, pkg.build_root, pkg.build_zig, pkg_hash, pkg.deps, args);
    }

    const full_path = b.pathFromRoot("build.zig.zon");
    debug.panic("'{}' is not a build.zig struct of a dependency in '{s}'", .{ build_zig, full_path });
}

fn userValuesAreSame(lhs: UserValue, rhs: UserValue) bool {
    if (std.meta.activeTag(lhs) != rhs) return false;
    switch (lhs) {
        .flag => {},
        .scalar => |lhs_scalar| {
            const rhs_scalar = rhs.scalar;

            if (!std.mem.eql(u8, lhs_scalar, rhs_scalar))
                return false;
        },
        .list => |lhs_list| {
            const rhs_list = rhs.list;

            if (lhs_list.items.len != rhs_list.items.len)
                return false;

            for (lhs_list.items, rhs_list.items) |lhs_list_entry, rhs_list_entry| {
                if (!std.mem.eql(u8, lhs_list_entry, rhs_list_entry))
                    return false;
            }
        },
        .map => |lhs_map| {
            const rhs_map = rhs.map;

            if (lhs_map.count() != rhs_map.count())
                return false;

            var lhs_it = lhs_map.iterator();
            while (lhs_it.next()) |lhs_entry| {
                const rhs_value = rhs_map.get(lhs_entry.key_ptr.*) orelse return false;
                if (!userValuesAreSame(lhs_entry.value_ptr.*.*, rhs_value.*))
                    return false;
            }
        },
        .lazy_path => |lhs_lp| {
            const rhs_lp = rhs.lazy_path;
            return userLazyPathsAreTheSame(lhs_lp, rhs_lp);
        },
        .lazy_path_list => |lhs_lp_list| {
            const rhs_lp_list = rhs.lazy_path_list;
            if (lhs_lp_list.items.len != rhs_lp_list.items.len) return false;
            for (lhs_lp_list.items, rhs_lp_list.items) |lhs_lp, rhs_lp| {
                if (!userLazyPathsAreTheSame(lhs_lp, rhs_lp)) return false;
            }
            return true;
        },
    }

    return true;
}

fn userLazyPathsAreTheSame(lhs_lp: LazyPath, rhs_lp: LazyPath) bool {
    if (std.meta.activeTag(lhs_lp) != rhs_lp) return false;
    switch (lhs_lp) {
        .src_path => |lhs_sp| {
            const rhs_sp = rhs_lp.src_path;

            if (lhs_sp.owner != rhs_sp.owner) return false;
            if (std.mem.eql(u8, lhs_sp.sub_path, rhs_sp.sub_path)) return false;
        },
        .generated => |lhs_gen| {
            const rhs_gen = rhs_lp.generated;

            if (lhs_gen.file != rhs_gen.file) return false;
            if (lhs_gen.up != rhs_gen.up) return false;
            if (std.mem.eql(u8, lhs_gen.sub_path, rhs_gen.sub_path)) return false;
        },
        .cwd_relative => |lhs_rel_path| {
            const rhs_rel_path = rhs_lp.cwd_relative;

            if (!std.mem.eql(u8, lhs_rel_path, rhs_rel_path)) return false;
        },
        .dependency => |lhs_dep| {
            const rhs_dep = rhs_lp.dependency;

            if (lhs_dep.dependency != rhs_dep.dependency) return false;
            if (!std.mem.eql(u8, lhs_dep.sub_path, rhs_dep.sub_path)) return false;
        },
    }
    return true;
}

fn dependencyInner(
    b: *Build,
    name: []const u8,
    build_root_string: []const u8,
    comptime build_zig: ?type,
    pkg_hash: []const u8,
    pkg_deps: AvailableDeps,
    args: anytype,
) *Dependency {
    const user_input_options = userInputOptionsFromArgs(b.allocator, args);
    if (b.graph.dependency_cache.getContext(.{
        .build_root_string = build_root_string,
        .user_input_options = user_input_options,
    }, .{ .allocator = b.graph.arena })) |dep|
        return dep;

    const build_root: std.Build.Cache.Directory = .{
        .path = build_root_string,
        .handle = fs.cwd().openDir(build_root_string, .{}) catch |err| {
            std.debug.print("unable to open '{s}': {s}\n", .{
                build_root_string, @errorName(err),
            });
            process.exit(1);
        },
    };

    const sub_builder = b.createChild(name, build_root, pkg_hash, pkg_deps, user_input_options) catch @panic("unhandled error");
    if (build_zig) |bz| {
        sub_builder.runBuild(bz) catch @panic("unhandled error");

        if (sub_builder.validateUserInputDidItFail()) {
            std.debug.dumpCurrentStackTrace(@returnAddress());
        }
    }

    const dep = b.allocator.create(Dependency) catch @panic("OOM");
    dep.* = .{ .builder = sub_builder };

    b.graph.dependency_cache.putContext(b.graph.arena, .{
        .build_root_string = build_root_string,
        .user_input_options = user_input_options,
    }, dep, .{ .allocator = b.graph.arena }) catch @panic("OOM");
    return dep;
}

pub fn runBuild(b: *Build, build_zig: anytype) anyerror!void {
    switch (@typeInfo(@typeInfo(@TypeOf(build_zig.build)).@"fn".return_type.?)) {
        .void => build_zig.build(b),
        .error_union => try build_zig.build(b),
        else => @compileError("expected return type of build to be 'void' or '!void'"),
    }
}

/// A file that is generated by a build step.
/// This struct is an interface that is meant to be used with `@fieldParentPtr` to implement the actual path logic.
pub const GeneratedFile = struct {
    /// The step that generates the file
    step: *Step,

    /// The path to the generated file. Must be either absolute or relative to the build runner cwd.
    /// This value must be set in the `fn make()` of the `step` and must not be `null` afterwards.
    path: ?[]const u8 = null,

    /// Deprecated, see `getPath2`.
    pub fn getPath(gen: GeneratedFile) []const u8 {
        return gen.step.owner.pathFromCwd(gen.path orelse std.debug.panic(
            "getPath() was called on a GeneratedFile that wasn't built yet. Is there a missing Step dependency on step '{s}'?",
            .{gen.step.name},
        ));
    }

    pub fn getPath2(gen: GeneratedFile, src_builder: *Build, asking_step: ?*Step) []const u8 {
        return gen.path orelse {
            const w = debug.lockStderrWriter(&.{});
            dumpBadGetPathHelp(gen.step, w, .detect(.stderr()), src_builder, asking_step) catch {};
            debug.unlockStderrWriter();
            @panic("misconfigured build script");
        };
    }
};

// dirnameAllowEmpty is a variant of fs.path.dirname
// that allows "" to refer to the root for relative paths.
//
// For context, dirname("foo") and dirname("") are both null.
// However, for relative paths, we want dirname("foo") to be ""
// so that we can join it with another path (e.g. build root, cache root, etc.)
//
// dirname("") should still be null, because we can't go up any further.
fn dirnameAllowEmpty(full_path: []const u8) ?[]const u8 {
    return fs.path.dirname(full_path) orelse {
        if (fs.path.isAbsolute(full_path) or full_path.len == 0) return null;

        return "";
    };
}

test dirnameAllowEmpty {
    try std.testing.expectEqualStrings(
        "foo",
        dirnameAllowEmpty("foo" ++ fs.path.sep_str ++ "bar") orelse @panic("unexpected null"),
    );

    try std.testing.expectEqualStrings(
        "",
        dirnameAllowEmpty("foo") orelse @panic("unexpected null"),
    );

    try std.testing.expect(dirnameAllowEmpty("") == null);
}

/// A reference to an existing or future path.
pub const LazyPath = union(enum) {
    /// A source file path relative to build root.
    src_path: struct {
        owner: *std.Build,
        sub_path: []const u8,
    },

    generated: struct {
        file: *const GeneratedFile,

        /// The number of parent directories to go up.
        /// 0 means the generated file itself.
        /// 1 means the directory of the generated file.
        /// 2 means the parent of that directory, and so on.
        up: usize = 0,

        /// Applied after `up`.
        sub_path: []const u8 = "",
    },

    /// An absolute path or a path relative to the current working directory of
    /// the build runner process.
    /// This is uncommon but used for system environment paths such as `--zig-lib-dir` which
    /// ignore the file system path of build.zig and instead are relative to the directory from
    /// which `zig build` was invoked.
    /// Use of this tag indicates a dependency on the host system.
    cwd_relative: []const u8,

    dependency: struct {
        dependency: *Dependency,
        sub_path: []const u8,
    },

    /// Returns a lazy path referring to the directory containing this path.
    ///
    /// The dirname is not allowed to escape the logical root for underlying path.
    /// For example, if the path is relative to the build root,
    /// the dirname is not allowed to traverse outside of the build root.
    /// Similarly, if the path is a generated file inside zig-cache,
    /// the dirname is not allowed to traverse outside of zig-cache.
    pub fn dirname(lazy_path: LazyPath) LazyPath {
        return switch (lazy_path) {
            .src_path => |sp| .{ .src_path = .{
                .owner = sp.owner,
                .sub_path = dirnameAllowEmpty(sp.sub_path) orelse {
                    dumpBadDirnameHelp(null, null, "dirname() attempted to traverse outside the build root\n", .{}) catch {};
                    @panic("misconfigured build script");
                },
            } },
            .generated => |generated| .{ .generated = if (dirnameAllowEmpty(generated.sub_path)) |sub_dirname| .{
                .file = generated.file,
                .up = generated.up,
                .sub_path = sub_dirname,
            } else .{
                .file = generated.file,
                .up = generated.up + 1,
                .sub_path = "",
            } },
            .cwd_relative => |rel_path| .{
                .cwd_relative = dirnameAllowEmpty(rel_path) orelse {
                    // If we get null, it means one of two things:
                    // - rel_path was absolute, and is now root
                    // - rel_path was relative, and is now ""
                    // In either case, the build script tried to go too far
                    // and we should panic.
                    if (fs.path.isAbsolute(rel_path)) {
                        dumpBadDirnameHelp(null, null,
                            \\dirname() attempted to traverse outside the root.
                            \\No more directories left to go up.
                            \\
                        , .{}) catch {};
                        @panic("misconfigured build script");
                    } else {
                        dumpBadDirnameHelp(null, null,
                            \\dirname() attempted to traverse outside the current working directory.
                            \\
                        , .{}) catch {};
                        @panic("misconfigured build script");
                    }
                },
            },
            .dependency => |dep| .{ .dependency = .{
                .dependency = dep.dependency,
                .sub_path = dirnameAllowEmpty(dep.sub_path) orelse {
                    dumpBadDirnameHelp(null, null,
                        \\dirname() attempted to traverse outside the dependency root.
                        \\
                    , .{}) catch {};
                    @panic("misconfigured build script");
                },
            } },
        };
    }

    pub fn path(lazy_path: LazyPath, b: *Build, sub_path: []const u8) LazyPath {
        return lazy_path.join(b.allocator, sub_path) catch @panic("OOM");
    }

    pub fn join(lazy_path: LazyPath, arena: Allocator, sub_path: []const u8) Allocator.Error!LazyPath {
        return switch (lazy_path) {
            .src_path => |src| .{ .src_path = .{
                .owner = src.owner,
                .sub_path = try fs.path.resolve(arena, &.{ src.sub_path, sub_path }),
            } },
            .generated => |gen| .{ .generated = .{
                .file = gen.file,
                .up = gen.up,
                .sub_path = try fs.path.resolve(arena, &.{ gen.sub_path, sub_path }),
            } },
            .cwd_relative => |cwd_relative| .{
                .cwd_relative = try fs.path.resolve(arena, &.{ cwd_relative, sub_path }),
            },
            .dependency => |dep| .{ .dependency = .{
                .dependency = dep.dependency,
                .sub_path = try fs.path.resolve(arena, &.{ dep.sub_path, sub_path }),
            } },
        };
    }

    /// Returns a string that can be shown to represent the file source.
    /// Either returns the path, `"generated"`, or `"dependency"`.
    pub fn getDisplayName(lazy_path: LazyPath) []const u8 {
        return switch (lazy_path) {
            .src_path => |sp| sp.sub_path,
            .cwd_relative => |p| p,
            .generated => "generated",
            .dependency => "dependency",
        };
    }

    /// Adds dependencies this file source implies to the given step.
    pub fn addStepDependencies(lazy_path: LazyPath, other_step: *Step) void {
        switch (lazy_path) {
            .src_path, .cwd_relative, .dependency => {},
            .generated => |gen| other_step.dependOn(gen.file.step),
        }
    }

    /// Deprecated, see `getPath3`.
    pub fn getPath(lazy_path: LazyPath, src_builder: *Build) []const u8 {
        return getPath2(lazy_path, src_builder, null);
    }

    /// Deprecated, see `getPath3`.
    pub fn getPath2(lazy_path: LazyPath, src_builder: *Build, asking_step: ?*Step) []const u8 {
        const p = getPath3(lazy_path, src_builder, asking_step);
        return src_builder.pathResolve(&.{ p.root_dir.path orelse ".", p.sub_path });
    }

    /// Intended to be used during the make phase only.
    ///
    /// `asking_step` is only used for debugging purposes; it's the step being
    /// run that is asking for the path.
    pub fn getPath3(lazy_path: LazyPath, src_builder: *Build, asking_step: ?*Step) Cache.Path {
        switch (lazy_path) {
            .src_path => |sp| return .{
                .root_dir = sp.owner.build_root,
                .sub_path = sp.sub_path,
            },
            .cwd_relative => |sub_path| return .{
                .root_dir = Cache.Directory.cwd(),
                .sub_path = sub_path,
            },
            .generated => |gen| {
                // TODO make gen.file.path not be absolute and use that as the
                // basis for not traversing up too many directories.

                var file_path: Cache.Path = .{
                    .root_dir = Cache.Directory.cwd(),
                    .sub_path = gen.file.path orelse {
                        const w = debug.lockStderrWriter(&.{});
                        dumpBadGetPathHelp(gen.file.step, w, .detect(.stderr()), src_builder, asking_step) catch {};
                        debug.unlockStderrWriter();
                        @panic("misconfigured build script");
                    },
                };

                if (gen.up > 0) {
                    const cache_root_path = src_builder.cache_root.path orelse
                        (src_builder.cache_root.join(src_builder.allocator, &.{"."}) catch @panic("OOM"));

                    for (0..gen.up) |_| {
                        if (mem.eql(u8, file_path.sub_path, cache_root_path)) {
                            // If we hit the cache root and there's still more to go,
                            // the script attempted to go too far.
                            dumpBadDirnameHelp(gen.file.step, asking_step,
                                \\dirname() attempted to traverse outside the cache root.
                                \\This is not allowed.
                                \\
                            , .{}) catch {};
                            @panic("misconfigured build script");
                        }

                        // path is absolute.
                        // dirname will return null only if we're at root.
                        // Typically, we'll stop well before that at the cache root.
                        file_path.sub_path = fs.path.dirname(file_path.sub_path) orelse {
                            dumpBadDirnameHelp(gen.file.step, asking_step,
                                \\dirname() reached root.
                                \\No more directories left to go up.
                                \\
                            , .{}) catch {};
                            @panic("misconfigured build script");
                        };
                    }
                }

                return file_path.join(src_builder.allocator, gen.sub_path) catch @panic("OOM");
            },
            .dependency => |dep| return .{
                .root_dir = dep.dependency.builder.build_root,
                .sub_path = dep.sub_path,
            },
        }
    }

    pub fn basename(lazy_path: LazyPath, src_builder: *Build, asking_step: ?*Step) []const u8 {
        return fs.path.basename(switch (lazy_path) {
            .src_path => |sp| sp.sub_path,
            .cwd_relative => |sub_path| sub_path,
            .generated => |gen| if (gen.sub_path.len > 0)
                gen.sub_path
            else
                gen.file.getPath2(src_builder, asking_step),
            .dependency => |dep| dep.sub_path,
        });
    }

    /// Copies the internal strings.
    ///
    /// The `b` parameter is only used for its allocator. All *Build instances
    /// share the same allocator.
    pub fn dupe(lazy_path: LazyPath, b: *Build) LazyPath {
        return lazy_path.dupeInner(b.allocator);
    }

    fn dupeInner(lazy_path: LazyPath, allocator: std.mem.Allocator) LazyPath {
        return switch (lazy_path) {
            .src_path => |sp| .{ .src_path = .{
                .owner = sp.owner,
                .sub_path = sp.owner.dupePath(sp.sub_path),
            } },
            .cwd_relative => |p| .{ .cwd_relative = dupePathInner(allocator, p) },
            .generated => |gen| .{ .generated = .{
                .file = gen.file,
                .up = gen.up,
                .sub_path = dupePathInner(allocator, gen.sub_path),
            } },
            .dependency => |dep| .{ .dependency = dep },
        };
    }
};

fn dumpBadDirnameHelp(
    fail_step: ?*Step,
    asking_step: ?*Step,
    comptime msg: []const u8,
    args: anytype,
) anyerror!void {
    const w = debug.lockStderrWriter(&.{});
    defer debug.unlockStderrWriter();

    try w.print(msg, args);

    const tty_config = std.io.tty.detectConfig(.stderr());

    if (fail_step) |s| {
        tty_config.setColor(w, .red) catch {};
        try w.writeAll("    The step was created by this stack trace:\n");
        tty_config.setColor(w, .reset) catch {};

        s.dump(w, tty_config);
    }

    if (asking_step) |as| {
        tty_config.setColor(w, .red) catch {};
        try w.print("    The step '{s}' that is missing a dependency on the above step was created by this stack trace:\n", .{as.name});
        tty_config.setColor(w, .reset) catch {};

        as.dump(w, tty_config);
    }

    tty_config.setColor(w, .red) catch {};
    try w.writeAll("    Hope that helps. Proceeding to panic.\n");
    tty_config.setColor(w, .reset) catch {};
}

/// In this function the stderr mutex has already been locked.
pub fn dumpBadGetPathHelp(
    s: *Step,
    w: *std.io.Writer,
    tty_config: std.io.tty.Config,
    src_builder: *Build,
    asking_step: ?*Step,
) anyerror!void {
    try w.print(
        \\getPath() was called on a GeneratedFile that wasn't built yet.
        \\  source package path: {s}
        \\  Is there a missing Step dependency on step '{s}'?
        \\
    , .{
        src_builder.build_root.path orelse ".",
        s.name,
    });

    tty_config.setColor(w, .red) catch {};
    try w.writeAll("    The step was created by this stack trace:\n");
    tty_config.setColor(w, .reset) catch {};

    s.dump(w, tty_config);
    if (asking_step) |as| {
        tty_config.setColor(w, .red) catch {};
        try w.print("    The step '{s}' that is missing a dependency on the above step was created by this stack trace:\n", .{as.name});
        tty_config.setColor(w, .reset) catch {};

        as.dump(w, tty_config);
    }
    tty_config.setColor(w, .red) catch {};
    try w.writeAll("    Hope that helps. Proceeding to panic.\n");
    tty_config.setColor(w, .reset) catch {};
}

pub const InstallDir = union(enum) {
    prefix: void,
    lib: void,
    bin: void,
    header: void,
    /// A path relative to the prefix
    custom: []const u8,

    /// Duplicates the install directory including the path if set to custom.
    pub fn dupe(dir: InstallDir, builder: *Build) InstallDir {
        if (dir == .custom) {
            return .{ .custom = builder.dupe(dir.custom) };
        } else {
            return dir;
        }
    }
};

/// This function is intended to be called in the `configure` phase only.
/// It returns an absolute directory path, which is potentially going to be a
/// source of API breakage in the future, so keep that in mind when using this
/// function.
pub fn makeTempPath(b: *Build) []const u8 {
    const rand_int = std.crypto.random.int(u64);
    const tmp_dir_sub_path = "tmp" ++ fs.path.sep_str ++ std.fmt.hex(rand_int);
    const result_path = b.cache_root.join(b.allocator, &.{tmp_dir_sub_path}) catch @panic("OOM");
    b.cache_root.handle.makePath(tmp_dir_sub_path) catch |err| {
        std.debug.print("unable to make tmp path '{s}': {s}\n", .{
            result_path, @errorName(err),
        });
    };
    return result_path;
}

/// A pair of target query and fully resolved target.
/// This type is generally required by build system API that need to be given a
/// target. The query is kept because the Zig toolchain needs to know which parts
/// of the target are "native". This can apply to the CPU, the OS, or even the ABI.
pub const ResolvedTarget = struct {
    query: Target.Query,
    result: Target,
};

/// Converts a target query into a fully resolved target that can be passed to
/// various parts of the API.
pub fn resolveTargetQuery(b: *Build, query: Target.Query) ResolvedTarget {
    if (query.isNative()) {
        // Hot path. This is faster than querying the native CPU and OS again.
        return b.graph.host;
    }
    return .{
        .query = query,
        .result = std.zig.system.resolveTargetQuery(query) catch
            @panic("unable to resolve target query"),
    };
}

pub fn wantSharedLibSymLinks(target: Target) bool {
    return target.os.tag != .windows;
}

pub const SystemIntegrationOptionConfig = struct {
    /// If left as null, then the default will depend on system_package_mode.
    default: ?bool = null,
};

pub fn systemIntegrationOption(
    b: *Build,
    name: []const u8,
    config: SystemIntegrationOptionConfig,
) bool {
    const gop = b.graph.system_library_options.getOrPut(b.allocator, name) catch @panic("OOM");
    if (gop.found_existing) switch (gop.value_ptr.*) {
        .user_disabled => {
            gop.value_ptr.* = .declared_disabled;
            return false;
        },
        .user_enabled => {
            gop.value_ptr.* = .declared_enabled;
            return true;
        },
        .declared_disabled => return false,
        .declared_enabled => return true,
    } else {
        gop.key_ptr.* = b.dupe(name);
        if (config.default orelse b.graph.system_package_mode) {
            gop.value_ptr.* = .declared_enabled;
            return true;
        } else {
            gop.value_ptr.* = .declared_disabled;
            return false;
        }
    }
}

test {
    _ = Cache;
    _ = Step;
}
