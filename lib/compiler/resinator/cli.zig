const std = @import("std");
const code_pages = @import("code_pages.zig");
const SupportedCodePage = code_pages.SupportedCodePage;
const lang = @import("lang.zig");
const res = @import("res.zig");
const Allocator = std.mem.Allocator;
const lex = @import("lex.zig");
const cvtres = @import("cvtres.zig");

/// This is what /SL 100 will set the maximum string literal length to
pub const max_string_literal_length_100_percent = 8192;

pub const usage_string_after_command_name =
    \\ [options] [--] <INPUT> [<OUTPUT>]
    \\
    \\The sequence -- can be used to signify when to stop parsing options.
    \\This is necessary when the input path begins with a forward slash.
    \\
    \\Supported option prefixes are /, -, and --, so e.g. /h, -h, and --h all work.
    \\Drop-in compatible with the Microsoft Resource Compiler.
    \\
    \\Supported Win32 RC Options:
    \\  /?, /h                  Print this help and exit.
    \\  /v                      Verbose (print progress messages).
    \\  /d <name>[=<value>]     Define a symbol (during preprocessing).
    \\  /u <name>               Undefine a symbol (during preprocessing).
    \\  /fo <value>             Specify output file path.
    \\  /l <value>              Set default language using hexadecimal id (ex: 409).
    \\  /ln <value>             Set default language using language name (ex: en-us).
    \\  /i <value>              Add an include path.
    \\  /x                      Ignore INCLUDE environment variable.
    \\  /c <value>              Set default code page (ex: 65001).
    \\  /w                      Warn on invalid code page in .rc (instead of error).
    \\  /y                      Suppress warnings for duplicate control IDs.
    \\  /n                      Null-terminate all strings in string tables.
    \\  /sl <value>             Specify string literal length limit in percentage (1-100)
    \\                          where 100 corresponds to a limit of 8192. If the /sl
    \\                          option is not specified, the default limit is 4097.
    \\  /p                      Only run the preprocessor and output a .rcpp file.
    \\
    \\No-op Win32 RC Options:
    \\  /nologo, /a, /r         Options that are recognized but do nothing.
    \\
    \\Unsupported Win32 RC Options:
    \\  /fm, /q, /g, /gn, /g1, /g2     Unsupported MUI-related options.
    \\  /?c, /hc, /t, /tp:<prefix>,    Unsupported LCX/LCE-related options.
    \\     /tn, /tm, /tc, /tw, /te,
    \\                    /ti, /ta
    \\  /z                             Unsupported font-substitution-related option.
    \\  /s                             Unsupported HWB-related option.
    \\
    \\Custom Options (resinator-specific):
    \\  /:no-preprocess           Do not run the preprocessor.
    \\  /:debug                   Output the preprocessed .rc file and the parsed AST.
    \\  /:auto-includes <value>   Set the automatic include path detection behavior.
    \\    any                     (default) Use MSVC if available, fall back to MinGW
    \\    msvc                    Use MSVC include paths (must be present on the system)
    \\    gnu                     Use MinGW include paths
    \\    none                    Do not use any autodetected include paths
    \\  /:depfile <path>          Output a file containing a list of all the files that
    \\                            the .rc includes or otherwise depends on.
    \\  /:depfile-fmt <value>     Output format of the depfile, if /:depfile is set.
    \\    json                    (default) A top-level JSON array of paths
    \\  /:input-format <value>    If not specified, the input format is inferred.
    \\    rc                      (default if input format cannot be inferred)
    \\    res                     Compiled .rc file, implies /:output-format coff
    \\    rcpp                    Preprocessed .rc file, implies /:no-preprocess
    \\  /:output-format <value>   If not specified, the output format is inferred.
    \\    res                     (default if output format cannot be inferred)
    \\    coff                    COFF object file (extension: .obj or .o)
    \\    rcpp                    Preprocessed .rc file, implies /p
    \\  /:target <arch>           Set the target machine for COFF object files.
    \\                            Can be specified either as PE/COFF machine constant
    \\                            name (X64, ARM64, etc) or Zig/LLVM CPU name (x86_64,
    \\                            aarch64, etc). The default is X64 (aka x86_64).
    \\                            Also accepts a full Zig/LLVM triple, but everything
    \\                            except the architecture is ignored.
    \\
    \\Note: For compatibility reasons, all custom options start with :
    \\
;

pub fn writeUsage(writer: anytype, command_name: []const u8) !void {
    try writer.writeAll("Usage: ");
    try writer.writeAll(command_name);
    try writer.writeAll(usage_string_after_command_name);
}

pub const Diagnostics = struct {
    errors: std.ArrayListUnmanaged(ErrorDetails) = .empty,
    allocator: Allocator,

    pub const ErrorDetails = struct {
        arg_index: usize,
        arg_span: ArgSpan = .{},
        msg: std.ArrayListUnmanaged(u8) = .empty,
        type: Type = .err,
        print_args: bool = true,

        pub const Type = enum { err, warning, note };
        pub const ArgSpan = struct {
            point_at_next_arg: bool = false,
            name_offset: usize = 0,
            prefix_len: usize = 0,
            value_offset: usize = 0,
            name_len: usize = 0,
        };
    };

    pub fn init(allocator: Allocator) Diagnostics {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Diagnostics) void {
        for (self.errors.items) |*details| {
            details.msg.deinit(self.allocator);
        }
        self.errors.deinit(self.allocator);
    }

    pub fn append(self: *Diagnostics, error_details: ErrorDetails) !void {
        try self.errors.append(self.allocator, error_details);
    }

    pub fn renderToStdErr(self: *Diagnostics, args: []const []const u8, config: std.io.tty.Config) void {
        const stderr = std.debug.lockStderrWriter(&.{});
        defer std.debug.unlockStderrWriter();
        self.renderToWriter(args, stderr, config) catch return;
    }

    pub fn renderToWriter(self: *Diagnostics, args: []const []const u8, writer: *std.io.Writer, config: std.io.tty.Config) !void {
        for (self.errors.items) |err_details| {
            try renderErrorMessage(writer, config, err_details, args);
        }
    }

    pub fn hasError(self: *const Diagnostics) bool {
        for (self.errors.items) |err| {
            if (err.type == .err) return true;
        }
        return false;
    }
};

pub const Options = struct {
    allocator: Allocator,
    input_source: IoSource = .{ .filename = &[_]u8{} },
    output_source: IoSource = .{ .filename = &[_]u8{} },
    extra_include_paths: std.ArrayListUnmanaged([]const u8) = .empty,
    ignore_include_env_var: bool = false,
    preprocess: Preprocess = .yes,
    default_language_id: ?u16 = null,
    default_code_page: ?SupportedCodePage = null,
    verbose: bool = false,
    symbols: std.StringArrayHashMapUnmanaged(SymbolValue) = .empty,
    null_terminate_string_table_strings: bool = false,
    max_string_literal_codepoints: u15 = lex.default_max_string_literal_codepoints,
    silent_duplicate_control_ids: bool = false,
    warn_instead_of_error_on_invalid_code_page: bool = false,
    debug: bool = false,
    print_help_and_exit: bool = false,
    auto_includes: AutoIncludes = .any,
    depfile_path: ?[]const u8 = null,
    depfile_fmt: DepfileFormat = .json,
    input_format: InputFormat = .rc,
    output_format: OutputFormat = .res,
    coff_options: cvtres.CoffOptions = .{},

    pub const IoSource = union(enum) {
        stdio: std.fs.File,
        filename: []const u8,
    };
    pub const AutoIncludes = enum { any, msvc, gnu, none };
    pub const DepfileFormat = enum { json };
    pub const InputFormat = enum { rc, res, rcpp };
    pub const OutputFormat = enum {
        res,
        coff,
        rcpp,

        pub fn extension(format: OutputFormat) []const u8 {
            return switch (format) {
                .rcpp => ".rcpp",
                .coff => ".obj",
                .res => ".res",
            };
        }
    };
    pub const Preprocess = enum { no, yes, only };
    pub const SymbolAction = enum { define, undefine };
    pub const SymbolValue = union(SymbolAction) {
        define: []const u8,
        undefine: void,

        pub fn deinit(self: SymbolValue, allocator: Allocator) void {
            switch (self) {
                .define => |value| allocator.free(value),
                .undefine => {},
            }
        }
    };

    /// Does not check that identifier contains only valid characters
    pub fn define(self: *Options, identifier: []const u8, value: []const u8) !void {
        if (self.symbols.getPtr(identifier)) |val_ptr| {
            // If the symbol is undefined, then that always takes precedence so
            // we shouldn't change anything.
            if (val_ptr.* == .undefine) return;
            // Otherwise, the new value takes precedence.
            const duped_value = try self.allocator.dupe(u8, value);
            errdefer self.allocator.free(duped_value);
            val_ptr.deinit(self.allocator);
            val_ptr.* = .{ .define = duped_value };
            return;
        }
        const duped_key = try self.allocator.dupe(u8, identifier);
        errdefer self.allocator.free(duped_key);
        const duped_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(duped_value);
        try self.symbols.put(self.allocator, duped_key, .{ .define = duped_value });
    }

    /// Does not check that identifier contains only valid characters
    pub fn undefine(self: *Options, identifier: []const u8) !void {
        if (self.symbols.getPtr(identifier)) |action| {
            action.deinit(self.allocator);
            action.* = .{ .undefine = {} };
            return;
        }
        const duped_key = try self.allocator.dupe(u8, identifier);
        errdefer self.allocator.free(duped_key);
        try self.symbols.put(self.allocator, duped_key, .{ .undefine = {} });
    }

    /// If the current input filename:
    /// - does not have an extension, and
    /// - does not exist in the cwd, and
    /// - the input format is .rc
    /// then this function will append `.rc` to the input filename
    ///
    /// Note: This behavior is different from the Win32 compiler.
    ///       It always appends .RC if the filename does not have
    ///       a `.` in it and it does not even try the verbatim name
    ///       in that scenario.
    ///
    /// The approach taken here is meant to give us a 'best of both
    /// worlds' situation where we'll be compatible with most use-cases
    /// of the .rc extension being omitted from the CLI args, but still
    /// work fine if the file itself does not have an extension.
    pub fn maybeAppendRC(options: *Options, cwd: std.fs.Dir) !void {
        switch (options.input_source) {
            .stdio => return,
            .filename => {},
        }
        if (options.input_format == .rc and std.fs.path.extension(options.input_source.filename).len == 0) {
            cwd.access(options.input_source.filename, .{}) catch |err| switch (err) {
                error.FileNotFound => {
                    var filename_bytes = try options.allocator.alloc(u8, options.input_source.filename.len + 3);
                    @memcpy(filename_bytes[0..options.input_source.filename.len], options.input_source.filename);
                    @memcpy(filename_bytes[filename_bytes.len - 3 ..], ".rc");
                    options.allocator.free(options.input_source.filename);
                    options.input_source = .{ .filename = filename_bytes };
                },
                else => {},
            };
        }
    }

    pub fn deinit(self: *Options) void {
        for (self.extra_include_paths.items) |extra_include_path| {
            self.allocator.free(extra_include_path);
        }
        self.extra_include_paths.deinit(self.allocator);
        switch (self.input_source) {
            .stdio => {},
            .filename => |filename| self.allocator.free(filename),
        }
        switch (self.output_source) {
            .stdio => {},
            .filename => |filename| self.allocator.free(filename),
        }
        var symbol_it = self.symbols.iterator();
        while (symbol_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.symbols.deinit(self.allocator);
        if (self.depfile_path) |depfile_path| {
            self.allocator.free(depfile_path);
        }
        if (self.coff_options.define_external_symbol) |symbol_name| {
            self.allocator.free(symbol_name);
        }
    }

    pub fn dumpVerbose(self: *const Options, writer: anytype) !void {
        const input_source_name = switch (self.input_source) {
            .stdio => "<stdin>",
            .filename => |filename| filename,
        };
        const output_source_name = switch (self.output_source) {
            .stdio => "<stdout>",
            .filename => |filename| filename,
        };
        try writer.print("Input filename: {s} (format={s})\n", .{ input_source_name, @tagName(self.input_format) });
        try writer.print("Output filename: {s} (format={s})\n", .{ output_source_name, @tagName(self.output_format) });
        if (self.output_format == .coff) {
            try writer.print(" Target machine type for COFF: {s}\n", .{@tagName(self.coff_options.target)});
        }

        if (self.extra_include_paths.items.len > 0) {
            try writer.writeAll(" Extra include paths:\n");
            for (self.extra_include_paths.items) |extra_include_path| {
                try writer.print("  \"{s}\"\n", .{extra_include_path});
            }
        }
        if (self.ignore_include_env_var) {
            try writer.writeAll(" The INCLUDE environment variable will be ignored\n");
        }
        if (self.preprocess == .no) {
            try writer.writeAll(" The preprocessor will not be invoked\n");
        } else if (self.preprocess == .only) {
            try writer.writeAll(" Only the preprocessor will be invoked\n");
        }
        if (self.symbols.count() > 0) {
            try writer.writeAll(" Symbols:\n");
            var it = self.symbols.iterator();
            while (it.next()) |symbol| {
                try writer.print("  {s} {s}", .{ switch (symbol.value_ptr.*) {
                    .define => "#define",
                    .undefine => "#undef",
                }, symbol.key_ptr.* });
                if (symbol.value_ptr.* == .define) {
                    try writer.print(" {s}", .{symbol.value_ptr.define});
                }
                try writer.writeAll("\n");
            }
        }
        if (self.null_terminate_string_table_strings) {
            try writer.writeAll(" Strings in string tables will be null-terminated\n");
        }
        if (self.max_string_literal_codepoints != lex.default_max_string_literal_codepoints) {
            try writer.print(" Max string literal length: {}\n", .{self.max_string_literal_codepoints});
        }
        if (self.silent_duplicate_control_ids) {
            try writer.writeAll(" Duplicate control IDs will not emit warnings\n");
        }
        if (self.silent_duplicate_control_ids) {
            try writer.writeAll(" Invalid code page in .rc will produce a warning (instead of an error)\n");
        }

        const language_id = self.default_language_id orelse res.Language.default;
        const language_name = language_name: {
            if (std.enums.fromInt(lang.LanguageId, language_id)) |lang_enum_val| {
                break :language_name @tagName(lang_enum_val);
            }
            if (language_id == lang.LOCALE_CUSTOM_UNSPECIFIED) {
                break :language_name "LOCALE_CUSTOM_UNSPECIFIED";
            }
            break :language_name "<UNKNOWN>";
        };
        try writer.print("Default language: {s} (id=0x{x})\n", .{ language_name, language_id });

        const code_page = self.default_code_page orelse .windows1252;
        try writer.print("Default codepage: {s} (id={})\n", .{ @tagName(code_page), @intFromEnum(code_page) });
    }
};

pub const Arg = struct {
    prefix: enum { long, short, slash },
    name_offset: usize,
    full: []const u8,

    pub fn fromString(str: []const u8) ?@This() {
        if (std.mem.startsWith(u8, str, "--")) {
            return .{ .prefix = .long, .name_offset = 2, .full = str };
        } else if (std.mem.startsWith(u8, str, "-")) {
            return .{ .prefix = .short, .name_offset = 1, .full = str };
        } else if (std.mem.startsWith(u8, str, "/")) {
            return .{ .prefix = .slash, .name_offset = 1, .full = str };
        }
        return null;
    }

    pub fn prefixSlice(self: Arg) []const u8 {
        return self.full[0..(if (self.prefix == .long) 2 else 1)];
    }

    pub fn name(self: Arg) []const u8 {
        return self.full[self.name_offset..];
    }

    pub fn optionWithoutPrefix(self: Arg, option_len: usize) []const u8 {
        if (option_len == 0) return self.name();
        return self.name()[0..option_len];
    }

    pub fn missingSpan(self: Arg) Diagnostics.ErrorDetails.ArgSpan {
        return .{
            .point_at_next_arg = true,
            .value_offset = 0,
            .name_offset = self.name_offset,
            .prefix_len = self.prefixSlice().len,
        };
    }

    pub fn optionAndAfterSpan(self: Arg) Diagnostics.ErrorDetails.ArgSpan {
        return self.optionSpan(0);
    }

    pub fn optionSpan(self: Arg, option_len: usize) Diagnostics.ErrorDetails.ArgSpan {
        return .{
            .name_offset = self.name_offset,
            .prefix_len = self.prefixSlice().len,
            .name_len = option_len,
        };
    }

    pub fn looksLikeFilepath(self: Arg) bool {
        const meets_min_requirements = self.prefix == .slash and isSupportedInputExtension(std.fs.path.extension(self.full));
        if (!meets_min_requirements) return false;

        const could_be_fo_option = could_be_fo_option: {
            var window_it = std.mem.window(u8, self.full[1..], 2, 1);
            while (window_it.next()) |window| {
                if (std.ascii.eqlIgnoreCase(window, "fo")) break :could_be_fo_option true;
                // If we see '/' before "fo", then it's not possible for this to be a valid
                // `/fo` option.
                if (window[0] == '/') break;
            }
            break :could_be_fo_option false;
        };
        if (!could_be_fo_option) return true;

        // It's still possible for a file path to look like a /fo option but not actually
        // be one, e.g. `/foo/bar.rc`. As a last ditch effort to reduce false negatives,
        // check if the file path exists and, if so, then we ignore the 'could be /fo option'-ness
        std.fs.accessAbsolute(self.full, .{}) catch return false;
        return true;
    }

    pub const Value = struct {
        slice: []const u8,
        /// Amount to increment the arg index to skip over both the option and the value arg(s)
        /// e.g. 1 if /<option><value>, 2 if /<option> <value>
        index_increment: u2 = 1,

        pub fn argSpan(self: Value, arg: Arg) Diagnostics.ErrorDetails.ArgSpan {
            const prefix_len = arg.prefixSlice().len;
            switch (self.index_increment) {
                1 => return .{
                    .value_offset = @intFromPtr(self.slice.ptr) - @intFromPtr(arg.full.ptr),
                    .prefix_len = prefix_len,
                    .name_offset = arg.name_offset,
                },
                2 => return .{
                    .point_at_next_arg = true,
                    .prefix_len = prefix_len,
                    .name_offset = arg.name_offset,
                },
                else => unreachable,
            }
        }

        pub fn index(self: Value, arg_index: usize) usize {
            if (self.index_increment == 2) return arg_index + 1;
            return arg_index;
        }
    };

    pub fn value(self: Arg, option_len: usize, index: usize, args: []const []const u8) error{MissingValue}!Value {
        const rest = self.full[self.name_offset + option_len ..];
        if (rest.len > 0) return .{ .slice = rest };
        if (index + 1 >= args.len) return error.MissingValue;
        return .{ .slice = args[index + 1], .index_increment = 2 };
    }

    pub const Context = struct {
        index: usize,
        option_len: usize,
        arg: Arg,
        value: Value,
    };
};

pub const ParseError = error{ParseError} || Allocator.Error;

/// Note: Does not run `Options.maybeAppendRC` automatically. If that behavior is desired,
///       it must be called separately.
pub fn parse(allocator: Allocator, args: []const []const u8, diagnostics: *Diagnostics) ParseError!Options {
    var options = Options{ .allocator = allocator };
    errdefer options.deinit();

    var output_filename: ?[]const u8 = null;
    var output_filename_context: union(enum) {
        unspecified: void,
        positional: usize,
        arg: Arg.Context,
    } = .{ .unspecified = {} };
    var output_format: ?Options.OutputFormat = null;
    var output_format_context: Arg.Context = undefined;
    var input_format: ?Options.InputFormat = null;
    var input_format_context: Arg.Context = undefined;
    var input_filename_arg_i: usize = undefined;
    var preprocess_only_context: Arg.Context = undefined;
    var depfile_context: Arg.Context = undefined;

    var arg_i: usize = 0;
    next_arg: while (arg_i < args.len) {
        var arg = Arg.fromString(args[arg_i]) orelse break;
        if (arg.name().len == 0) {
            switch (arg.prefix) {
                // -- on its own ends arg parsing
                .long => {
                    arg_i += 1;
                    break;
                },
                // - or / on its own is an error
                else => {
                    var err_details = Diagnostics.ErrorDetails{ .arg_index = arg_i, .arg_span = arg.optionAndAfterSpan() };
                    var msg_writer = err_details.msg.writer(allocator);
                    try msg_writer.print("invalid option: {s}", .{arg.prefixSlice()});
                    try diagnostics.append(err_details);
                    arg_i += 1;
                    continue :next_arg;
                },
            }
        }

        const args_remaining = args.len - arg_i;
        if (args_remaining <= 2 and arg.looksLikeFilepath()) {
            var err_details = Diagnostics.ErrorDetails{ .type = .note, .print_args = true, .arg_index = arg_i };
            var msg_writer = err_details.msg.writer(allocator);
            try msg_writer.writeAll("this argument was inferred to be a filepath, so argument parsing was terminated");
            try diagnostics.append(err_details);

            break;
        }

        while (arg.name().len > 0) {
            const arg_name = arg.name();
            // Note: These cases should be in order from longest to shortest, since
            //       shorter options that are a substring of a longer one could make
            //       the longer option's branch unreachable.
            if (std.ascii.startsWithIgnoreCase(arg_name, ":no-preprocess")) {
                options.preprocess = .no;
                arg.name_offset += ":no-preprocess".len;
            } else if (std.ascii.startsWithIgnoreCase(arg_name, ":output-format")) {
                const value = arg.value(":output-format".len, arg_i, args) catch {
                    var err_details = Diagnostics.ErrorDetails{ .arg_index = arg_i, .arg_span = arg.missingSpan() };
                    var msg_writer = err_details.msg.writer(allocator);
                    try msg_writer.print("missing value after {s}{s} option", .{ arg.prefixSlice(), arg.optionWithoutPrefix(":output-format".len) });
                    try diagnostics.append(err_details);
                    arg_i += 1;
                    break :next_arg;
                };
                output_format = std.meta.stringToEnum(Options.OutputFormat, value.slice) orelse blk: {
                    var err_details = Diagnostics.ErrorDetails{ .arg_index = arg_i, .arg_span = value.argSpan(arg) };
                    var msg_writer = err_details.msg.writer(allocator);
                    try msg_writer.print("invalid output format setting: {s} ", .{value.slice});
                    try diagnostics.append(err_details);
                    break :blk output_format;
                };
                output_format_context = .{ .index = arg_i, .option_len = ":output-format".len, .arg = arg, .value = value };
                arg_i += value.index_increment;
                continue :next_arg;
            } else if (std.ascii.startsWithIgnoreCase(arg_name, ":auto-includes")) {
                const value = arg.value(":auto-includes".len, arg_i, args) catch {
                    var err_details = Diagnostics.ErrorDetails{ .arg_index = arg_i, .arg_span = arg.missingSpan() };
                    var msg_writer = err_details.msg.writer(allocator);
                    try msg_writer.print("missing value after {s}{s} option", .{ arg.prefixSlice(), arg.optionWithoutPrefix(":auto-includes".len) });
                    try diagnostics.append(err_details);
                    arg_i += 1;
                    break :next_arg;
                };
                options.auto_includes = std.meta.stringToEnum(Options.AutoIncludes, value.slice) orelse blk: {
                    var err_details = Diagnostics.ErrorDetails{ .arg_index = arg_i, .arg_span = value.argSpan(arg) };
                    var msg_writer = err_details.msg.writer(allocator);
                    try msg_writer.print("invalid auto includes setting: {s} ", .{value.slice});
                    try diagnostics.append(err_details);
                    break :blk options.auto_includes;
                };
                arg_i += value.index_increment;
                continue :next_arg;
            } else if (std.ascii.startsWithIgnoreCase(arg_name, ":input-format")) {
                const value = arg.value(":input-format".len, arg_i, args) catch {
                    var err_details = Diagnostics.ErrorDetails{ .arg_index = arg_i, .arg_span = arg.missingSpan() };
                    var msg_writer = err_details.msg.writer(allocator);
                    try msg_writer.print("missing value after {s}{s} option", .{ arg.prefixSlice(), arg.optionWithoutPrefix(":input-format".len) });
                    try diagnostics.append(err_details);
                    arg_i += 1;
                    break :next_arg;
                };
                input_format = std.meta.stringToEnum(Options.InputFormat, value.slice) orelse blk: {
                    var err_details = Diagnostics.ErrorDetails{ .arg_index = arg_i, .arg_span = value.argSpan(arg) };
                    var msg_writer = err_details.msg.writer(allocator);
                    try msg_writer.print("invalid input format setting: {s} ", .{value.slice});
                    try diagnostics.append(err_details);
                    break :blk input_format;
                };
                input_format_context = .{ .index = arg_i, .option_len = ":input-format".len, .arg = arg, .value = value };
                arg_i += value.index_increment;
                continue :next_arg;
            } else if (std.ascii.startsWithIgnoreCase(arg_name, ":depfile-fmt")) {
                const value = arg.value(":depfile-fmt".len, arg_i, args) catch {
                    var err_details = Diagnostics.ErrorDetails{ .arg_index = arg_i, .arg_span = arg.missingSpan() };
                    var msg_writer = err_details.msg.writer(allocator);
                    try msg_writer.print("missing value after {s}{s} option", .{ arg.prefixSlice(), arg.optionWithoutPrefix(":depfile-fmt".len) });
                    try diagnostics.append(err_details);
                    arg_i += 1;
                    break :next_arg;
                };
                options.depfile_fmt = std.meta.stringToEnum(Options.DepfileFormat, value.slice) orelse blk: {
                    var err_details = Diagnostics.ErrorDetails{ .arg_index = arg_i, .arg_span = value.argSpan(arg) };
                    var msg_writer = err_details.msg.writer(allocator);
                    try msg_writer.print("invalid depfile format setting: {s} ", .{value.slice});
                    try diagnostics.append(err_details);
                    break :blk options.depfile_fmt;
                };
                arg_i += value.index_increment;
                continue :next_arg;
            } else if (std.ascii.startsWithIgnoreCase(arg_name, ":depfile")) {
                const value = arg.value(":depfile".len, arg_i, args) catch {
                    var err_details = Diagnostics.ErrorDetails{ .arg_index = arg_i, .arg_span = arg.missingSpan() };
                    var msg_writer = err_details.msg.writer(allocator);
                    try msg_writer.print("missing value after {s}{s} option", .{ arg.prefixSlice(), arg.optionWithoutPrefix(":depfile".len) });
                    try diagnostics.append(err_details);
                    arg_i += 1;
                    break :next_arg;
                };
                if (options.depfile_path) |overwritten_path| {
                    allocator.free(overwritten_path);
                    options.depfile_path = null;
                }
                const path = try allocator.dupe(u8, value.slice);
                errdefer allocator.free(path);
                options.depfile_path = path;
                depfile_context = .{ .index = arg_i, .option_len = ":depfile".len, .arg = arg, .value = value };
                arg_i += value.index_increment;
                continue :next_arg;
            } else if (std.ascii.startsWithIgnoreCase(arg_name, ":target")) {
                const value = arg.value(":target".len, arg_i, args) catch {
                    var err_details = Diagnostics.ErrorDetails{ .arg_index = arg_i, .arg_span = arg.missingSpan() };
                    var msg_writer = err_details.msg.writer(allocator);
                    try msg_writer.print("missing value after {s}{s} option", .{ arg.prefixSlice(), arg.optionWithoutPrefix(":target".len) });
                    try diagnostics.append(err_details);
                    arg_i += 1;
                    break :next_arg;
                };
                // Take the substring up to the first dash so that a full target triple
                // can be used, e.g. x86_64-windows-gnu becomes x86_64
                var target_it = std.mem.splitScalar(u8, value.slice, '-');
                const arch_str = target_it.first();
                const arch = cvtres.supported_targets.Arch.fromStringIgnoreCase(arch_str) orelse {
                    var err_details = Diagnostics.ErrorDetails{ .arg_index = arg_i, .arg_span = value.argSpan(arg) };
                    var msg_writer = err_details.msg.writer(allocator);
                    try msg_writer.print("invalid or unsupported target architecture: {s}", .{arch_str});
                    try diagnostics.append(err_details);
                    arg_i += value.index_increment;
                    continue :next_arg;
                };
                options.coff_options.target = arch.toCoffMachineType();
                arg_i += value.index_increment;
                continue :next_arg;
            } else if (std.ascii.startsWithIgnoreCase(arg_name, "nologo")) {
                // No-op, we don't display any 'logo' to suppress
                arg.name_offset += "nologo".len;
            } else if (std.ascii.startsWithIgnoreCase(arg_name, ":debug")) {
                options.debug = true;
                arg.name_offset += ":debug".len;
            }
            // Unsupported LCX/LCE options that need a value (within the same arg only)
            else if (std.ascii.startsWithIgnoreCase(arg_name, "tp:")) {
                const rest = arg.full[arg.name_offset + 3 ..];
                if (rest.len == 0) {
                    var err_details = Diagnostics.ErrorDetails{ .arg_index = arg_i, .arg_span = .{
                        .name_offset = arg.name_offset,
                        .prefix_len = arg.prefixSlice().len,
                        .value_offset = arg.name_offset + 3,
                    } };
                    var msg_writer = err_details.msg.writer(allocator);
                    try msg_writer.print("missing value for {s}{s} option", .{ arg.prefixSlice(), arg.optionWithoutPrefix(3) });
                    try diagnostics.append(err_details);
                }
                var err_details = Diagnostics.ErrorDetails{ .type = .err, .arg_index = arg_i, .arg_span = arg.optionAndAfterSpan() };
                var msg_writer = err_details.msg.writer(allocator);
                try msg_writer.print("the {s}{s} option is unsupported", .{ arg.prefixSlice(), arg.optionWithoutPrefix(3) });
                try diagnostics.append(err_details);
                arg_i += 1;
                continue :next_arg;
            }
            // Unsupported LCX/LCE options that need a value
            else if (std.ascii.startsWithIgnoreCase(arg_name, "tn")) {
                const value = arg.value(2, arg_i, args) catch no_value: {
                    var err_details = Diagnostics.ErrorDetails{ .arg_index = arg_i, .arg_span = arg.missingSpan() };
                    var msg_writer = err_details.msg.writer(allocator);
                    try msg_writer.print("missing value after {s}{s} option", .{ arg.prefixSlice(), arg.optionWithoutPrefix(2) });
                    try diagnostics.append(err_details);
                    // dummy zero-length slice starting where the value would have been
                    const value_start = arg.name_offset + 2;
                    break :no_value Arg.Value{ .slice = arg.full[value_start..value_start] };
                };
                var err_details = Diagnostics.ErrorDetails{ .type = .err, .arg_index = arg_i, .arg_span = arg.optionAndAfterSpan() };
                var msg_writer = err_details.msg.writer(allocator);
                try msg_writer.print("the {s}{s} option is unsupported", .{ arg.prefixSlice(), arg.optionWithoutPrefix(2) });
                try diagnostics.append(err_details);
                arg_i += value.index_increment;
                continue :next_arg;
            }
            // Unsupported MUI options that need a value
            else if (std.ascii.startsWithIgnoreCase(arg_name, "fm") or
                std.ascii.startsWithIgnoreCase(arg_name, "gn") or
                std.ascii.startsWithIgnoreCase(arg_name, "g2"))
            {
                const value = arg.value(2, arg_i, args) catch no_value: {
                    var err_details = Diagnostics.ErrorDetails{ .arg_index = arg_i, .arg_span = arg.missingSpan() };
                    var msg_writer = err_details.msg.writer(allocator);
                    try msg_writer.print("missing value after {s}{s} option", .{ arg.prefixSlice(), arg.optionWithoutPrefix(2) });
                    try diagnostics.append(err_details);
                    // dummy zero-length slice starting where the value would have been
                    const value_start = arg.name_offset + 2;
                    break :no_value Arg.Value{ .slice = arg.full[value_start..value_start] };
                };
                var err_details = Diagnostics.ErrorDetails{ .type = .err, .arg_index = arg_i, .arg_span = arg.optionAndAfterSpan() };
                var msg_writer = err_details.msg.writer(allocator);
                try msg_writer.print("the {s}{s} option is unsupported", .{ arg.prefixSlice(), arg.optionWithoutPrefix(2) });
                try diagnostics.append(err_details);
                arg_i += value.index_increment;
                continue :next_arg;
            }
            // Unsupported MUI options that do not need a value
            else if (std.ascii.startsWithIgnoreCase(arg_name, "g1")) {
                var err_details = Diagnostics.ErrorDetails{ .type = .err, .arg_index = arg_i, .arg_span = arg.optionSpan(2) };
                var msg_writer = err_details.msg.writer(allocator);
                try msg_writer.print("the {s}{s} option is unsupported", .{ arg.prefixSlice(), arg.optionWithoutPrefix(2) });
                try diagnostics.append(err_details);
                arg.name_offset += 2;
            }
            // Unsupported LCX/LCE options that do not need a value
            else if (std.ascii.startsWithIgnoreCase(arg_name, "tm") or
                std.ascii.startsWithIgnoreCase(arg_name, "tc") or
                std.ascii.startsWithIgnoreCase(arg_name, "tw") or
                std.ascii.startsWithIgnoreCase(arg_name, "te") or
                std.ascii.startsWithIgnoreCase(arg_name, "ti") or
                std.ascii.startsWithIgnoreCase(arg_name, "ta"))
            {
                var err_details = Diagnostics.ErrorDetails{ .type = .err, .arg_index = arg_i, .arg_span = arg.optionSpan(2) };
                var msg_writer = err_details.msg.writer(allocator);
                try msg_writer.print("the {s}{s} option is unsupported", .{ arg.prefixSlice(), arg.optionWithoutPrefix(2) });
                try diagnostics.append(err_details);
                arg.name_offset += 2;
            } else if (std.ascii.startsWithIgnoreCase(arg_name, "fo")) {
                const value = arg.value(2, arg_i, args) catch {
                    var err_details = Diagnostics.ErrorDetails{ .arg_index = arg_i, .arg_span = arg.missingSpan() };
                    var msg_writer = err_details.msg.writer(allocator);
                    try msg_writer.print("missing output path after {s}{s} option", .{ arg.prefixSlice(), arg.optionWithoutPrefix(2) });
                    try diagnostics.append(err_details);
                    arg_i += 1;
                    break :next_arg;
                };
                output_filename_context = .{ .arg = .{ .index = arg_i, .option_len = "fo".len, .arg = arg, .value = value } };
                output_filename = value.slice;
                arg_i += value.index_increment;
                continue :next_arg;
            } else if (std.ascii.startsWithIgnoreCase(arg_name, "sl")) {
                const value = arg.value(2, arg_i, args) catch {
                    var err_details = Diagnostics.ErrorDetails{ .arg_index = arg_i, .arg_span = arg.missingSpan() };
                    var msg_writer = err_details.msg.writer(allocator);
                    try msg_writer.print("missing language tag after {s}{s} option", .{ arg.prefixSlice(), arg.optionWithoutPrefix(2) });
                    try diagnostics.append(err_details);
                    arg_i += 1;
                    break :next_arg;
                };
                const percent_str = value.slice;
                const percent: u32 = parsePercent(percent_str) catch {
                    var err_details = Diagnostics.ErrorDetails{ .arg_index = arg_i, .arg_span = value.argSpan(arg) };
                    var msg_writer = err_details.msg.writer(allocator);
                    try msg_writer.print("invalid percent format '{s}'", .{percent_str});
                    try diagnostics.append(err_details);
                    var note_details = Diagnostics.ErrorDetails{ .type = .note, .print_args = false, .arg_index = arg_i };
                    var note_writer = note_details.msg.writer(allocator);
                    try note_writer.writeAll("string length percent must be an integer between 1 and 100 (inclusive)");
                    try diagnostics.append(note_details);
                    arg_i += value.index_increment;
                    continue :next_arg;
                };
                if (percent == 0 or percent > 100) {
                    var err_details = Diagnostics.ErrorDetails{ .arg_index = arg_i, .arg_span = value.argSpan(arg) };
                    var msg_writer = err_details.msg.writer(allocator);
                    try msg_writer.print("percent out of range: {} (parsed from '{s}')", .{ percent, percent_str });
                    try diagnostics.append(err_details);
                    var note_details = Diagnostics.ErrorDetails{ .type = .note, .print_args = false, .arg_index = arg_i };
                    var note_writer = note_details.msg.writer(allocator);
                    try note_writer.writeAll("string length percent must be an integer between 1 and 100 (inclusive)");
                    try diagnostics.append(note_details);
                    arg_i += value.index_increment;
                    continue :next_arg;
                }
                const percent_float = @as(f32, @floatFromInt(percent)) / 100;
                options.max_string_literal_codepoints = @intFromFloat(percent_float * max_string_literal_length_100_percent);
                arg_i += value.index_increment;
                continue :next_arg;
            } else if (std.ascii.startsWithIgnoreCase(arg_name, "ln")) {
                const value = arg.value(2, arg_i, args) catch {
                    var err_details = Diagnostics.ErrorDetails{ .arg_index = arg_i, .arg_span = arg.missingSpan() };
                    var msg_writer = err_details.msg.writer(allocator);
                    try msg_writer.print("missing language tag after {s}{s} option", .{ arg.prefixSlice(), arg.optionWithoutPrefix(2) });
                    try diagnostics.append(err_details);
                    arg_i += 1;
                    break :next_arg;
                };
                const tag = value.slice;
                options.default_language_id = lang.tagToInt(tag) catch {
                    var err_details = Diagnostics.ErrorDetails{ .arg_index = arg_i, .arg_span = value.argSpan(arg) };
                    var msg_writer = err_details.msg.writer(allocator);
                    try msg_writer.print("invalid language tag: {s}", .{tag});
                    try diagnostics.append(err_details);
                    arg_i += value.index_increment;
                    continue :next_arg;
                };
                if (options.default_language_id.? == lang.LOCALE_CUSTOM_UNSPECIFIED) {
                    var err_details = Diagnostics.ErrorDetails{ .type = .warning, .arg_index = arg_i, .arg_span = value.argSpan(arg) };
                    var msg_writer = err_details.msg.writer(allocator);
                    try msg_writer.print("language tag '{s}' does not have an assigned ID so it will be resolved to LOCALE_CUSTOM_UNSPECIFIED (id=0x{x})", .{ tag, lang.LOCALE_CUSTOM_UNSPECIFIED });
                    try diagnostics.append(err_details);
                }
                arg_i += value.index_increment;
                continue :next_arg;
            } else if (std.ascii.startsWithIgnoreCase(arg_name, "l")) {
                const value = arg.value(1, arg_i, args) catch {
                    var err_details = Diagnostics.ErrorDetails{ .arg_index = arg_i, .arg_span = arg.missingSpan() };
                    var msg_writer = err_details.msg.writer(allocator);
                    try msg_writer.print("missing language ID after {s}{s} option", .{ arg.prefixSlice(), arg.optionWithoutPrefix(1) });
                    try diagnostics.append(err_details);
                    arg_i += 1;
                    break :next_arg;
                };
                const num_str = value.slice;
                options.default_language_id = lang.parseInt(num_str) catch {
                    var err_details = Diagnostics.ErrorDetails{ .arg_index = arg_i, .arg_span = value.argSpan(arg) };
                    var msg_writer = err_details.msg.writer(allocator);
                    try msg_writer.print("invalid language ID: {s}", .{num_str});
                    try diagnostics.append(err_details);
                    arg_i += value.index_increment;
                    continue :next_arg;
                };
                arg_i += value.index_increment;
                continue :next_arg;
            } else if (std.ascii.startsWithIgnoreCase(arg_name, "h") or std.mem.startsWith(u8, arg_name, "?")) {
                options.print_help_and_exit = true;
                // If there's been an error to this point, then we still want to fail
                if (diagnostics.hasError()) return error.ParseError;
                return options;
            }
            // 1 char unsupported MUI options that need a value
            else if (std.ascii.startsWithIgnoreCase(arg_name, "q") or
                std.ascii.startsWithIgnoreCase(arg_name, "g"))
            {
                const value = arg.value(1, arg_i, args) catch no_value: {
                    var err_details = Diagnostics.ErrorDetails{ .arg_index = arg_i, .arg_span = arg.missingSpan() };
                    var msg_writer = err_details.msg.writer(allocator);
                    try msg_writer.print("missing value after {s}{s} option", .{ arg.prefixSlice(), arg.optionWithoutPrefix(1) });
                    try diagnostics.append(err_details);
                    // dummy zero-length slice starting where the value would have been
                    const value_start = arg.name_offset + 1;
                    break :no_value Arg.Value{ .slice = arg.full[value_start..value_start] };
                };
                var err_details = Diagnostics.ErrorDetails{ .type = .err, .arg_index = arg_i, .arg_span = arg.optionAndAfterSpan() };
                var msg_writer = err_details.msg.writer(allocator);
                try msg_writer.print("the {s}{s} option is unsupported", .{ arg.prefixSlice(), arg.optionWithoutPrefix(1) });
                try diagnostics.append(err_details);
                arg_i += value.index_increment;
                continue :next_arg;
            }
            // Undocumented (and unsupported) options that need a value
            //  /z has to do something with font substitution
            //  /s has something to do with HWB resources being inserted into the .res
            else if (std.ascii.startsWithIgnoreCase(arg_name, "z") or
                std.ascii.startsWithIgnoreCase(arg_name, "s"))
            {
                const value = arg.value(1, arg_i, args) catch no_value: {
                    var err_details = Diagnostics.ErrorDetails{ .arg_index = arg_i, .arg_span = arg.missingSpan() };
                    var msg_writer = err_details.msg.writer(allocator);
                    try msg_writer.print("missing value after {s}{s} option", .{ arg.prefixSlice(), arg.optionWithoutPrefix(1) });
                    try diagnostics.append(err_details);
                    // dummy zero-length slice starting where the value would have been
                    const value_start = arg.name_offset + 1;
                    break :no_value Arg.Value{ .slice = arg.full[value_start..value_start] };
                };
                var err_details = Diagnostics.ErrorDetails{ .type = .err, .arg_index = arg_i, .arg_span = arg.optionAndAfterSpan() };
                var msg_writer = err_details.msg.writer(allocator);
                try msg_writer.print("the {s}{s} option is unsupported", .{ arg.prefixSlice(), arg.optionWithoutPrefix(1) });
                try diagnostics.append(err_details);
                arg_i += value.index_increment;
                continue :next_arg;
            }
            // 1 char unsupported LCX/LCE options that do not need a value
            else if (std.ascii.startsWithIgnoreCase(arg_name, "t")) {
                var err_details = Diagnostics.ErrorDetails{ .type = .err, .arg_index = arg_i, .arg_span = arg.optionSpan(1) };
                var msg_writer = err_details.msg.writer(allocator);
                try msg_writer.print("the {s}{s} option is unsupported", .{ arg.prefixSlice(), arg.optionWithoutPrefix(1) });
                try diagnostics.append(err_details);
                arg.name_offset += 1;
            } else if (std.ascii.startsWithIgnoreCase(arg_name, "c")) {
                const value = arg.value(1, arg_i, args) catch {
                    var err_details = Diagnostics.ErrorDetails{ .arg_index = arg_i, .arg_span = arg.missingSpan() };
                    var msg_writer = err_details.msg.writer(allocator);
                    try msg_writer.print("missing code page ID after {s}{s} option", .{ arg.prefixSlice(), arg.optionWithoutPrefix(1) });
                    try diagnostics.append(err_details);
                    arg_i += 1;
                    break :next_arg;
                };
                const num_str = value.slice;
                const code_page_id = std.fmt.parseUnsigned(u16, num_str, 10) catch {
                    var err_details = Diagnostics.ErrorDetails{ .arg_index = arg_i, .arg_span = value.argSpan(arg) };
                    var msg_writer = err_details.msg.writer(allocator);
                    try msg_writer.print("invalid code page ID: {s}", .{num_str});
                    try diagnostics.append(err_details);
                    arg_i += value.index_increment;
                    continue :next_arg;
                };
                options.default_code_page = code_pages.getByIdentifierEnsureSupported(code_page_id) catch |err| switch (err) {
                    error.InvalidCodePage => {
                        var err_details = Diagnostics.ErrorDetails{ .arg_index = arg_i, .arg_span = value.argSpan(arg) };
                        var msg_writer = err_details.msg.writer(allocator);
                        try msg_writer.print("invalid or unknown code page ID: {}", .{code_page_id});
                        try diagnostics.append(err_details);
                        arg_i += value.index_increment;
                        continue :next_arg;
                    },
                    error.UnsupportedCodePage => {
                        var err_details = Diagnostics.ErrorDetails{ .arg_index = arg_i, .arg_span = value.argSpan(arg) };
                        var msg_writer = err_details.msg.writer(allocator);
                        try msg_writer.print("unsupported code page: {s} (id={})", .{
                            @tagName(code_pages.getByIdentifier(code_page_id) catch unreachable),
                            code_page_id,
                        });
                        try diagnostics.append(err_details);
                        arg_i += value.index_increment;
                        continue :next_arg;
                    },
                };
                arg_i += value.index_increment;
                continue :next_arg;
            } else if (std.ascii.startsWithIgnoreCase(arg_name, "v")) {
                options.verbose = true;
                arg.name_offset += 1;
            } else if (std.ascii.startsWithIgnoreCase(arg_name, "x")) {
                options.ignore_include_env_var = true;
                arg.name_offset += 1;
            } else if (std.ascii.startsWithIgnoreCase(arg_name, "p")) {
                options.preprocess = .only;
                preprocess_only_context = .{ .index = arg_i, .option_len = "p".len, .arg = arg, .value = undefined };
                arg.name_offset += 1;
            } else if (std.ascii.startsWithIgnoreCase(arg_name, "i")) {
                const value = arg.value(1, arg_i, args) catch {
                    var err_details = Diagnostics.ErrorDetails{ .arg_index = arg_i, .arg_span = arg.missingSpan() };
                    var msg_writer = err_details.msg.writer(allocator);
                    try msg_writer.print("missing include path after {s}{s} option", .{ arg.prefixSlice(), arg.optionWithoutPrefix(1) });
                    try diagnostics.append(err_details);
                    arg_i += 1;
                    break :next_arg;
                };
                const path = value.slice;
                const duped = try allocator.dupe(u8, path);
                errdefer allocator.free(duped);
                try options.extra_include_paths.append(options.allocator, duped);
                arg_i += value.index_increment;
                continue :next_arg;
            } else if (std.ascii.startsWithIgnoreCase(arg_name, "r")) {
                // From https://learn.microsoft.com/en-us/windows/win32/menurc/using-rc-the-rc-command-line-
                // "Ignored. Provided for compatibility with existing makefiles."
                arg.name_offset += 1;
            } else if (std.ascii.startsWithIgnoreCase(arg_name, "n")) {
                options.null_terminate_string_table_strings = true;
                arg.name_offset += 1;
            } else if (std.ascii.startsWithIgnoreCase(arg_name, "y")) {
                options.silent_duplicate_control_ids = true;
                arg.name_offset += 1;
            } else if (std.ascii.startsWithIgnoreCase(arg_name, "w")) {
                options.warn_instead_of_error_on_invalid_code_page = true;
                arg.name_offset += 1;
            } else if (std.ascii.startsWithIgnoreCase(arg_name, "a")) {
                // Undocumented option with unknown function
                // TODO: More investigation to figure out what it does (if anything)
                var err_details = Diagnostics.ErrorDetails{ .type = .warning, .arg_index = arg_i, .arg_span = arg.optionSpan(1) };
                var msg_writer = err_details.msg.writer(allocator);
                try msg_writer.print("option {s}{s} has no effect (it is undocumented and its function is unknown in the Win32 RC compiler)", .{ arg.prefixSlice(), arg.optionWithoutPrefix(1) });
                try diagnostics.append(err_details);
                arg.name_offset += 1;
            } else if (std.ascii.startsWithIgnoreCase(arg_name, "d")) {
                const value = arg.value(1, arg_i, args) catch {
                    var err_details = Diagnostics.ErrorDetails{ .arg_index = arg_i, .arg_span = arg.missingSpan() };
                    var msg_writer = err_details.msg.writer(allocator);
                    try msg_writer.print("missing symbol to define after {s}{s} option", .{ arg.prefixSlice(), arg.optionWithoutPrefix(1) });
                    try diagnostics.append(err_details);
                    arg_i += 1;
                    break :next_arg;
                };
                var tokenizer = std.mem.tokenizeScalar(u8, value.slice, '=');
                // guaranteed to exist since an empty value.slice would invoke
                // the 'missing symbol to define' branch above
                const symbol = tokenizer.next().?;
                const symbol_value = tokenizer.next() orelse "1";

                if (isValidIdentifier(symbol)) {
                    try options.define(symbol, symbol_value);
                } else {
                    var err_details = Diagnostics.ErrorDetails{ .type = .warning, .arg_index = arg_i, .arg_span = value.argSpan(arg) };
                    var msg_writer = err_details.msg.writer(allocator);
                    try msg_writer.print("symbol \"{s}\" is not a valid identifier and therefore cannot be defined", .{symbol});
                    try diagnostics.append(err_details);
                }
                arg_i += value.index_increment;
                continue :next_arg;
            } else if (std.ascii.startsWithIgnoreCase(arg_name, "u")) {
                const value = arg.value(1, arg_i, args) catch {
                    var err_details = Diagnostics.ErrorDetails{ .arg_index = arg_i, .arg_span = arg.missingSpan() };
                    var msg_writer = err_details.msg.writer(allocator);
                    try msg_writer.print("missing symbol to undefine after {s}{s} option", .{ arg.prefixSlice(), arg.optionWithoutPrefix(1) });
                    try diagnostics.append(err_details);
                    arg_i += 1;
                    break :next_arg;
                };
                const symbol = value.slice;
                if (isValidIdentifier(symbol)) {
                    try options.undefine(symbol);
                } else {
                    var err_details = Diagnostics.ErrorDetails{ .type = .warning, .arg_index = arg_i, .arg_span = value.argSpan(arg) };
                    var msg_writer = err_details.msg.writer(allocator);
                    try msg_writer.print("symbol \"{s}\" is not a valid identifier and therefore cannot be undefined", .{symbol});
                    try diagnostics.append(err_details);
                }
                arg_i += value.index_increment;
                continue :next_arg;
            } else {
                var err_details = Diagnostics.ErrorDetails{ .arg_index = arg_i, .arg_span = arg.optionAndAfterSpan() };
                var msg_writer = err_details.msg.writer(allocator);
                try msg_writer.print("invalid option: {s}{s}", .{ arg.prefixSlice(), arg.name() });
                try diagnostics.append(err_details);
                arg_i += 1;
                continue :next_arg;
            }
        } else {
            // The while loop exited via its conditional, meaning we are done with
            // the current arg and can move on the the next
            arg_i += 1;
            continue;
        }
    }

    const positionals = args[arg_i..];

    if (positionals.len == 0) {
        var err_details = Diagnostics.ErrorDetails{ .print_args = false, .arg_index = arg_i };
        var msg_writer = err_details.msg.writer(allocator);
        try msg_writer.writeAll("missing input filename");
        try diagnostics.append(err_details);

        if (args.len > 0) {
            const last_arg = args[args.len - 1];
            if (arg_i > 0 and last_arg.len > 0 and last_arg[0] == '/' and isSupportedInputExtension(std.fs.path.extension(last_arg))) {
                var note_details = Diagnostics.ErrorDetails{ .type = .note, .print_args = true, .arg_index = arg_i - 1 };
                var note_writer = note_details.msg.writer(allocator);
                try note_writer.writeAll("if this argument was intended to be the input filename, adding -- in front of it will exclude it from option parsing");
                try diagnostics.append(note_details);
            }
        }

        // This is a fatal enough problem to justify an early return, since
        // things after this rely on the value of the input filename.
        return error.ParseError;
    }
    options.input_source = .{ .filename = try allocator.dupe(u8, positionals[0]) };
    input_filename_arg_i = arg_i;

    const InputFormatSource = enum {
        inferred_from_input_filename,
        input_format_arg,
    };

    var input_format_source: InputFormatSource = undefined;
    if (input_format == null) {
        const ext = std.fs.path.extension(options.input_source.filename);
        if (std.ascii.eqlIgnoreCase(ext, ".res")) {
            input_format = .res;
        } else if (std.ascii.eqlIgnoreCase(ext, ".rcpp")) {
            input_format = .rcpp;
        } else {
            input_format = .rc;
        }
        input_format_source = .inferred_from_input_filename;
    } else {
        input_format_source = .input_format_arg;
    }

    if (positionals.len > 1) {
        if (output_filename != null) {
            var err_details = Diagnostics.ErrorDetails{ .arg_index = arg_i + 1 };
            var msg_writer = err_details.msg.writer(allocator);
            try msg_writer.writeAll("output filename already specified");
            try diagnostics.append(err_details);
            var note_details = Diagnostics.ErrorDetails{
                .type = .note,
                .arg_index = output_filename_context.arg.index,
                .arg_span = output_filename_context.arg.value.argSpan(output_filename_context.arg.arg),
            };
            var note_writer = note_details.msg.writer(allocator);
            try note_writer.writeAll("output filename previously specified here");
            try diagnostics.append(note_details);
        } else {
            output_filename = positionals[1];
            output_filename_context = .{ .positional = arg_i + 1 };
        }
    }

    const OutputFormatSource = enum {
        inferred_from_input_filename,
        inferred_from_output_filename,
        output_format_arg,
        unable_to_infer_from_input_filename,
        unable_to_infer_from_output_filename,
        inferred_from_preprocess_only,
    };

    var output_format_source: OutputFormatSource = undefined;
    if (output_filename == null) {
        if (output_format == null) {
            output_format_source = .inferred_from_input_filename;
            const input_ext = std.fs.path.extension(options.input_source.filename);
            if (std.ascii.eqlIgnoreCase(input_ext, ".res")) {
                output_format = .coff;
            } else if (options.preprocess == .only and (input_format.? == .rc or std.ascii.eqlIgnoreCase(input_ext, ".rc"))) {
                output_format = .rcpp;
                output_format_source = .inferred_from_preprocess_only;
            } else {
                if (!std.ascii.eqlIgnoreCase(input_ext, ".res")) {
                    output_format_source = .unable_to_infer_from_input_filename;
                }
                output_format = .res;
            }
        }
        options.output_source = .{ .filename = try filepathWithExtension(allocator, options.input_source.filename, output_format.?.extension()) };
    } else {
        options.output_source = .{ .filename = try allocator.dupe(u8, output_filename.?) };
        if (output_format == null) {
            output_format_source = .inferred_from_output_filename;
            const ext = std.fs.path.extension(options.output_source.filename);
            if (std.ascii.eqlIgnoreCase(ext, ".obj") or std.ascii.eqlIgnoreCase(ext, ".o")) {
                output_format = .coff;
            } else if (std.ascii.eqlIgnoreCase(ext, ".rcpp")) {
                output_format = .rcpp;
            } else {
                if (!std.ascii.eqlIgnoreCase(ext, ".res")) {
                    output_format_source = .unable_to_infer_from_output_filename;
                }
                output_format = .res;
            }
        } else {
            output_format_source = .output_format_arg;
        }
    }

    options.input_format = input_format.?;
    options.output_format = output_format.?;

    // Check for incompatible options
    var print_input_format_source_note: bool = false;
    var print_output_format_source_note: bool = false;
    if (options.depfile_path != null and (options.input_format == .res or options.output_format == .rcpp)) {
        var err_details = Diagnostics.ErrorDetails{ .type = .warning, .arg_index = depfile_context.index, .arg_span = depfile_context.value.argSpan(depfile_context.arg) };
        var msg_writer = err_details.msg.writer(allocator);
        if (options.input_format == .res) {
            try msg_writer.print("the {s}{s} option was ignored because the input format is '{s}'", .{
                depfile_context.arg.prefixSlice(),
                depfile_context.arg.optionWithoutPrefix(depfile_context.option_len),
                @tagName(options.input_format),
            });
            print_input_format_source_note = true;
        } else if (options.output_format == .rcpp) {
            try msg_writer.print("the {s}{s} option was ignored because the output format is '{s}'", .{
                depfile_context.arg.prefixSlice(),
                depfile_context.arg.optionWithoutPrefix(depfile_context.option_len),
                @tagName(options.output_format),
            });
            print_output_format_source_note = true;
        }
        try diagnostics.append(err_details);
    }
    if (!isSupportedTransformation(options.input_format, options.output_format)) {
        var err_details = Diagnostics.ErrorDetails{ .arg_index = input_filename_arg_i, .print_args = false };
        var msg_writer = err_details.msg.writer(allocator);
        try msg_writer.print("input format '{s}' cannot be converted to output format '{s}'", .{ @tagName(options.input_format), @tagName(options.output_format) });
        try diagnostics.append(err_details);
        print_input_format_source_note = true;
        print_output_format_source_note = true;
    }
    if (options.preprocess == .only and options.output_format != .rcpp) {
        var err_details = Diagnostics.ErrorDetails{ .arg_index = preprocess_only_context.index };
        var msg_writer = err_details.msg.writer(allocator);
        try msg_writer.print("the {s}{s} option cannot be used with output format '{s}'", .{
            preprocess_only_context.arg.prefixSlice(),
            preprocess_only_context.arg.optionWithoutPrefix(preprocess_only_context.option_len),
            @tagName(options.output_format),
        });
        try diagnostics.append(err_details);
        print_output_format_source_note = true;
    }
    if (print_input_format_source_note) {
        switch (input_format_source) {
            .inferred_from_input_filename => {
                var err_details = Diagnostics.ErrorDetails{ .type = .note, .arg_index = input_filename_arg_i };
                var msg_writer = err_details.msg.writer(allocator);
                try msg_writer.writeAll("the input format was inferred from the input filename");
                try diagnostics.append(err_details);
            },
            .input_format_arg => {
                var err_details = Diagnostics.ErrorDetails{
                    .type = .note,
                    .arg_index = input_format_context.index,
                    .arg_span = input_format_context.value.argSpan(input_format_context.arg),
                };
                var msg_writer = err_details.msg.writer(allocator);
                try msg_writer.writeAll("the input format was specified here");
                try diagnostics.append(err_details);
            },
        }
    }
    if (print_output_format_source_note) {
        switch (output_format_source) {
            .inferred_from_input_filename, .unable_to_infer_from_input_filename => {
                var err_details = Diagnostics.ErrorDetails{ .type = .note, .arg_index = input_filename_arg_i };
                var msg_writer = err_details.msg.writer(allocator);
                if (output_format_source == .inferred_from_input_filename) {
                    try msg_writer.writeAll("the output format was inferred from the input filename");
                } else {
                    try msg_writer.writeAll("the output format was unable to be inferred from the input filename, so the default was used");
                }
                try diagnostics.append(err_details);
            },
            .inferred_from_output_filename, .unable_to_infer_from_output_filename => {
                var err_details: Diagnostics.ErrorDetails = switch (output_filename_context) {
                    .positional => |i| .{ .type = .note, .arg_index = i },
                    .arg => |ctx| .{ .type = .note, .arg_index = ctx.index, .arg_span = ctx.value.argSpan(ctx.arg) },
                    .unspecified => unreachable,
                };
                var msg_writer = err_details.msg.writer(allocator);
                if (output_format_source == .inferred_from_output_filename) {
                    try msg_writer.writeAll("the output format was inferred from the output filename");
                } else {
                    try msg_writer.writeAll("the output format was unable to be inferred from the output filename, so the default was used");
                }
                try diagnostics.append(err_details);
            },
            .output_format_arg => {
                var err_details = Diagnostics.ErrorDetails{
                    .type = .note,
                    .arg_index = output_format_context.index,
                    .arg_span = output_format_context.value.argSpan(output_format_context.arg),
                };
                var msg_writer = err_details.msg.writer(allocator);
                try msg_writer.writeAll("the output format was specified here");
                try diagnostics.append(err_details);
            },
            .inferred_from_preprocess_only => {
                var err_details = Diagnostics.ErrorDetails{ .type = .note, .arg_index = preprocess_only_context.index };
                var msg_writer = err_details.msg.writer(allocator);
                try msg_writer.print("the output format was inferred from the usage of the {s}{s} option", .{
                    preprocess_only_context.arg.prefixSlice(),
                    preprocess_only_context.arg.optionWithoutPrefix(preprocess_only_context.option_len),
                });
                try diagnostics.append(err_details);
            },
        }
    }

    if (diagnostics.hasError()) {
        return error.ParseError;
    }

    // Implied settings from input/output formats
    if (options.output_format == .rcpp) options.preprocess = .only;
    if (options.input_format == .res) options.output_format = .coff;
    if (options.input_format == .rcpp) options.preprocess = .no;

    return options;
}

pub fn filepathWithExtension(allocator: Allocator, path: []const u8, ext: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    if (std.fs.path.dirname(path)) |dirname| {
        var end_pos = dirname.len;
        // We want to ensure that we write a path separator at the end, so if the dirname
        // doesn't end with a path sep then include the char after the dirname
        // which must be a path sep.
        if (!std.fs.path.isSep(dirname[dirname.len - 1])) end_pos += 1;
        try buf.appendSlice(path[0..end_pos]);
    }
    try buf.appendSlice(std.fs.path.stem(path));
    try buf.appendSlice(ext);
    return try buf.toOwnedSlice();
}

pub fn isSupportedInputExtension(ext: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(ext, ".rc")) return true;
    if (std.ascii.eqlIgnoreCase(ext, ".res")) return true;
    if (std.ascii.eqlIgnoreCase(ext, ".rcpp")) return true;
    return false;
}

pub fn isSupportedTransformation(input: Options.InputFormat, output: Options.OutputFormat) bool {
    return switch (input) {
        .rc => switch (output) {
            .res => true,
            .coff => true,
            .rcpp => true,
        },
        .res => switch (output) {
            .res => false,
            .coff => true,
            .rcpp => false,
        },
        .rcpp => switch (output) {
            .res => true,
            .coff => true,
            .rcpp => false,
        },
    };
}

/// Returns true if the str is a valid C identifier for use in a #define/#undef macro
pub fn isValidIdentifier(str: []const u8) bool {
    for (str, 0..) |c, i| switch (c) {
        '0'...'9' => if (i == 0) return false,
        'a'...'z', 'A'...'Z', '_' => {},
        else => return false,
    };
    return true;
}

/// This function is specific to how the Win32 RC command line interprets
/// max string literal length percent.
/// - Wraps on overflow of u32
/// - Stops parsing on any invalid hexadecimal digits
/// - Errors if a digit is not the first char
/// - `-` (negative) prefix is allowed
pub fn parsePercent(str: []const u8) error{InvalidFormat}!u32 {
    var result: u32 = 0;
    const radix: u8 = 10;
    var buf = str;

    const Prefix = enum { none, minus };
    var prefix: Prefix = .none;
    switch (buf[0]) {
        '-' => {
            prefix = .minus;
            buf = buf[1..];
        },
        else => {},
    }

    for (buf, 0..) |c, i| {
        const digit = switch (c) {
            // On invalid digit for the radix, just stop parsing but don't fail
            '0'...'9' => std.fmt.charToDigit(c, radix) catch break,
            else => {
                // First digit must be valid
                if (i == 0) {
                    return error.InvalidFormat;
                }
                break;
            },
        };

        if (result != 0) {
            result *%= radix;
        }
        result +%= digit;
    }

    switch (prefix) {
        .none => {},
        .minus => result = 0 -% result,
    }

    return result;
}

test parsePercent {
    try std.testing.expectEqual(@as(u32, 16), try parsePercent("16"));
    try std.testing.expectEqual(@as(u32, 0), try parsePercent("0x1A"));
    try std.testing.expectEqual(@as(u32, 0x1), try parsePercent("1zzzz"));
    try std.testing.expectEqual(@as(u32, 0xffffffff), try parsePercent("-1"));
    try std.testing.expectEqual(@as(u32, 0xfffffff0), try parsePercent("-16"));
    try std.testing.expectEqual(@as(u32, 1), try parsePercent("4294967297"));
    try std.testing.expectError(error.InvalidFormat, parsePercent("--1"));
    try std.testing.expectError(error.InvalidFormat, parsePercent("ha"));
    try std.testing.expectError(error.InvalidFormat, parsePercent("¹"));
    try std.testing.expectError(error.InvalidFormat, parsePercent("~1"));
}

pub fn renderErrorMessage(writer: *std.io.Writer, config: std.io.tty.Config, err_details: Diagnostics.ErrorDetails, args: []const []const u8) !void {
    try config.setColor(writer, .dim);
    try writer.writeAll("<cli>");
    try config.setColor(writer, .reset);
    try config.setColor(writer, .bold);
    try writer.writeAll(": ");
    switch (err_details.type) {
        .err => {
            try config.setColor(writer, .red);
            try writer.writeAll("error: ");
        },
        .warning => {
            try config.setColor(writer, .yellow);
            try writer.writeAll("warning: ");
        },
        .note => {
            try config.setColor(writer, .cyan);
            try writer.writeAll("note: ");
        },
    }
    try config.setColor(writer, .reset);
    try config.setColor(writer, .bold);
    try writer.writeAll(err_details.msg.items);
    try writer.writeByte('\n');
    try config.setColor(writer, .reset);

    if (!err_details.print_args) {
        try writer.writeByte('\n');
        return;
    }

    try config.setColor(writer, .dim);
    const prefix = " ... ";
    try writer.writeAll(prefix);
    try config.setColor(writer, .reset);

    const arg_with_name = args[err_details.arg_index];
    const prefix_slice = arg_with_name[0..err_details.arg_span.prefix_len];
    const before_name_slice = arg_with_name[err_details.arg_span.prefix_len..err_details.arg_span.name_offset];
    var name_slice = arg_with_name[err_details.arg_span.name_offset..];
    if (err_details.arg_span.name_len > 0) name_slice.len = err_details.arg_span.name_len;
    const after_name_slice = arg_with_name[err_details.arg_span.name_offset + name_slice.len ..];

    try writer.writeAll(prefix_slice);
    if (before_name_slice.len > 0) {
        try config.setColor(writer, .dim);
        try writer.writeAll(before_name_slice);
        try config.setColor(writer, .reset);
    }
    try writer.writeAll(name_slice);
    if (after_name_slice.len > 0) {
        try config.setColor(writer, .dim);
        try writer.writeAll(after_name_slice);
        try config.setColor(writer, .reset);
    }

    var next_arg_len: usize = 0;
    if (err_details.arg_span.point_at_next_arg and err_details.arg_index + 1 < args.len) {
        const next_arg = args[err_details.arg_index + 1];
        try writer.writeByte(' ');
        try writer.writeAll(next_arg);
        next_arg_len = next_arg.len;
    }

    const last_shown_arg_index = if (err_details.arg_span.point_at_next_arg) err_details.arg_index + 1 else err_details.arg_index;
    if (last_shown_arg_index + 1 < args.len) {
        // special case for when pointing to a missing value within the same arg
        // as the name
        if (err_details.arg_span.value_offset >= arg_with_name.len) {
            try writer.writeByte(' ');
        }
        try config.setColor(writer, .dim);
        try writer.writeAll(" ...");
        try config.setColor(writer, .reset);
    }
    try writer.writeByte('\n');

    try config.setColor(writer, .green);
    try writer.splatByteAll(' ', prefix.len);
    // Special case for when the option is *only* a prefix (e.g. invalid option: -)
    if (err_details.arg_span.prefix_len == arg_with_name.len) {
        try writer.splatByteAll('^', err_details.arg_span.prefix_len);
    } else {
        try writer.splatByteAll('~', err_details.arg_span.prefix_len);
        try writer.splatByteAll(' ', err_details.arg_span.name_offset - err_details.arg_span.prefix_len);
        if (!err_details.arg_span.point_at_next_arg and err_details.arg_span.value_offset == 0) {
            try writer.writeByte('^');
            try writer.splatByteAll('~', name_slice.len - 1);
        } else if (err_details.arg_span.value_offset > 0) {
            try writer.splatByteAll('~', err_details.arg_span.value_offset - err_details.arg_span.name_offset);
            try writer.writeByte('^');
            if (err_details.arg_span.value_offset < arg_with_name.len) {
                try writer.splatByteAll('~', arg_with_name.len - err_details.arg_span.value_offset - 1);
            }
        } else if (err_details.arg_span.point_at_next_arg) {
            try writer.splatByteAll('~', arg_with_name.len - err_details.arg_span.name_offset + 1);
            try writer.writeByte('^');
            if (next_arg_len > 0) {
                try writer.splatByteAll('~', next_arg_len - 1);
            }
        }
    }
    try writer.writeByte('\n');
    try config.setColor(writer, .reset);
}

fn testParse(args: []const []const u8) !Options {
    return (try testParseOutput(args, "")).?;
}

fn testParseWarning(args: []const []const u8, expected_output: []const u8) !Options {
    return (try testParseOutput(args, expected_output)).?;
}

fn testParseError(args: []const []const u8, expected_output: []const u8) !void {
    var maybe_options = try testParseOutput(args, expected_output);
    if (maybe_options != null) {
        std.debug.print("expected error, got options: {}\n", .{maybe_options.?});
        maybe_options.?.deinit();
        return error.TestExpectedError;
    }
}

fn testParseOutput(args: []const []const u8, expected_output: []const u8) !?Options {
    var diagnostics = Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();

    var output = std.ArrayList(u8).init(std.testing.allocator);
    defer output.deinit();

    var options = parse(std.testing.allocator, args, &diagnostics) catch |err| switch (err) {
        error.ParseError => {
            try diagnostics.renderToWriter(args, output.writer(), .no_color);
            try std.testing.expectEqualStrings(expected_output, output.items);
            return null;
        },
        else => |e| return e,
    };
    errdefer options.deinit();

    try diagnostics.renderToWriter(args, output.writer(), .no_color);
    try std.testing.expectEqualStrings(expected_output, output.items);
    return options;
}

test "parse errors: basic" {
    try testParseError(&.{"/"},
        \\<cli>: error: invalid option: /
        \\ ... /
        \\     ^
        \\<cli>: error: missing input filename
        \\
        \\
    );
    try testParseError(&.{"/ln"},
        \\<cli>: error: missing language tag after /ln option
        \\ ... /ln
        \\     ~~~~^
        \\<cli>: error: missing input filename
        \\
        \\
    );
    try testParseError(&.{"-vln"},
        \\<cli>: error: missing language tag after -ln option
        \\ ... -vln
        \\     ~ ~~~^
        \\<cli>: error: missing input filename
        \\
        \\
    );
    try testParseError(&.{"/_not-an-option"},
        \\<cli>: error: invalid option: /_not-an-option
        \\ ... /_not-an-option
        \\     ~^~~~~~~~~~~~~~
        \\<cli>: error: missing input filename
        \\
        \\
    );
    try testParseError(&.{"-_not-an-option"},
        \\<cli>: error: invalid option: -_not-an-option
        \\ ... -_not-an-option
        \\     ~^~~~~~~~~~~~~~
        \\<cli>: error: missing input filename
        \\
        \\
    );
    try testParseError(&.{"--_not-an-option"},
        \\<cli>: error: invalid option: --_not-an-option
        \\ ... --_not-an-option
        \\     ~~^~~~~~~~~~~~~~
        \\<cli>: error: missing input filename
        \\
        \\
    );
    try testParseError(&.{"/v_not-an-option"},
        \\<cli>: error: invalid option: /_not-an-option
        \\ ... /v_not-an-option
        \\     ~ ^~~~~~~~~~~~~~
        \\<cli>: error: missing input filename
        \\
        \\
    );
    try testParseError(&.{"-v_not-an-option"},
        \\<cli>: error: invalid option: -_not-an-option
        \\ ... -v_not-an-option
        \\     ~ ^~~~~~~~~~~~~~
        \\<cli>: error: missing input filename
        \\
        \\
    );
    try testParseError(&.{"--v_not-an-option"},
        \\<cli>: error: invalid option: --_not-an-option
        \\ ... --v_not-an-option
        \\     ~~ ^~~~~~~~~~~~~~
        \\<cli>: error: missing input filename
        \\
        \\
    );
}

test "inferred absolute filepaths" {
    {
        var options = try testParseWarning(&.{ "/fo", "foo.res", "/home/absolute/path.rc" },
            \\<cli>: note: this argument was inferred to be a filepath, so argument parsing was terminated
            \\ ... /home/absolute/path.rc
            \\     ^~~~~~~~~~~~~~~~~~~~~~
            \\
        );
        defer options.deinit();
    }
    {
        var options = try testParseWarning(&.{ "/home/absolute/path.rc", "foo.res" },
            \\<cli>: note: this argument was inferred to be a filepath, so argument parsing was terminated
            \\ ... /home/absolute/path.rc ...
            \\     ^~~~~~~~~~~~~~~~~~~~~~
            \\
        );
        defer options.deinit();
    }
    {
        // Only the last two arguments are checked, so the /h is parsed as an option
        var options = try testParse(&.{ "/home/absolute/path.rc", "foo.rc", "foo.res" });
        defer options.deinit();

        try std.testing.expect(options.print_help_and_exit);
    }
    {
        var options = try testParse(&.{ "/xvFO/some/absolute/path.res", "foo.rc" });
        defer options.deinit();

        try std.testing.expectEqual(true, options.verbose);
        try std.testing.expectEqual(true, options.ignore_include_env_var);
        try std.testing.expectEqualStrings("foo.rc", options.input_source.filename);
        try std.testing.expectEqualStrings("/some/absolute/path.res", options.output_source.filename);
    }
}

test "parse errors: /ln" {
    try testParseError(&.{ "/ln", "invalid", "foo.rc" },
        \\<cli>: error: invalid language tag: invalid
        \\ ... /ln invalid ...
        \\     ~~~~^~~~~~~
        \\
    );
    try testParseError(&.{ "/lninvalid", "foo.rc" },
        \\<cli>: error: invalid language tag: invalid
        \\ ... /lninvalid ...
        \\     ~~~^~~~~~~
        \\
    );
}

test "parse: options" {
    {
        var options = try testParse(&.{ "/v", "foo.rc" });
        defer options.deinit();

        try std.testing.expectEqual(true, options.verbose);
        try std.testing.expectEqualStrings("foo.rc", options.input_source.filename);
        try std.testing.expectEqualStrings("foo.res", options.output_source.filename);
    }
    {
        var options = try testParse(&.{ "/vx", "foo.rc" });
        defer options.deinit();

        try std.testing.expectEqual(true, options.verbose);
        try std.testing.expectEqual(true, options.ignore_include_env_var);
        try std.testing.expectEqualStrings("foo.rc", options.input_source.filename);
        try std.testing.expectEqualStrings("foo.res", options.output_source.filename);
    }
    {
        var options = try testParse(&.{ "/xv", "foo.rc" });
        defer options.deinit();

        try std.testing.expectEqual(true, options.verbose);
        try std.testing.expectEqual(true, options.ignore_include_env_var);
        try std.testing.expectEqualStrings("foo.rc", options.input_source.filename);
        try std.testing.expectEqualStrings("foo.res", options.output_source.filename);
    }
    {
        var options = try testParse(&.{ "/xvFObar.res", "foo.rc" });
        defer options.deinit();

        try std.testing.expectEqual(true, options.verbose);
        try std.testing.expectEqual(true, options.ignore_include_env_var);
        try std.testing.expectEqualStrings("foo.rc", options.input_source.filename);
        try std.testing.expectEqualStrings("bar.res", options.output_source.filename);
    }
}

test "parse: define and undefine" {
    {
        var options = try testParse(&.{ "/dfoo", "foo.rc" });
        defer options.deinit();

        const action = options.symbols.get("foo").?;
        try std.testing.expectEqualStrings("1", action.define);
    }
    {
        var options = try testParse(&.{ "/dfoo=bar", "/dfoo=baz", "foo.rc" });
        defer options.deinit();

        const action = options.symbols.get("foo").?;
        try std.testing.expectEqualStrings("baz", action.define);
    }
    {
        var options = try testParse(&.{ "/ufoo", "foo.rc" });
        defer options.deinit();

        const action = options.symbols.get("foo").?;
        try std.testing.expectEqual(Options.SymbolAction.undefine, action);
    }
    {
        // Once undefined, future defines are ignored
        var options = try testParse(&.{ "/ufoo", "/dfoo", "foo.rc" });
        defer options.deinit();

        const action = options.symbols.get("foo").?;
        try std.testing.expectEqual(Options.SymbolAction.undefine, action);
    }
    {
        // Undefined always takes precedence
        var options = try testParse(&.{ "/dfoo", "/ufoo", "/dfoo", "foo.rc" });
        defer options.deinit();

        const action = options.symbols.get("foo").?;
        try std.testing.expectEqual(Options.SymbolAction.undefine, action);
    }
    {
        // Warn + ignore invalid identifiers
        var options = try testParseWarning(
            &.{ "/dfoo bar", "/u", "0leadingdigit", "foo.rc" },
            \\<cli>: warning: symbol "foo bar" is not a valid identifier and therefore cannot be defined
            \\ ... /dfoo bar ...
            \\     ~~^~~~~~~
            \\<cli>: warning: symbol "0leadingdigit" is not a valid identifier and therefore cannot be undefined
            \\ ... /u 0leadingdigit ...
            \\     ~~~^~~~~~~~~~~~~
            \\
            ,
        );
        defer options.deinit();

        try std.testing.expectEqual(@as(usize, 0), options.symbols.count());
    }
}

test "parse: /sl" {
    try testParseError(&.{ "/sl", "0", "foo.rc" },
        \\<cli>: error: percent out of range: 0 (parsed from '0')
        \\ ... /sl 0 ...
        \\     ~~~~^
        \\<cli>: note: string length percent must be an integer between 1 and 100 (inclusive)
        \\
        \\
    );
    try testParseError(&.{ "/sl", "abcd", "foo.rc" },
        \\<cli>: error: invalid percent format 'abcd'
        \\ ... /sl abcd ...
        \\     ~~~~^~~~
        \\<cli>: note: string length percent must be an integer between 1 and 100 (inclusive)
        \\
        \\
    );
    {
        var options = try testParse(&.{"foo.rc"});
        defer options.deinit();

        try std.testing.expectEqual(@as(u15, lex.default_max_string_literal_codepoints), options.max_string_literal_codepoints);
    }
    {
        var options = try testParse(&.{ "/sl100", "foo.rc" });
        defer options.deinit();

        try std.testing.expectEqual(@as(u15, max_string_literal_length_100_percent), options.max_string_literal_codepoints);
    }
    {
        var options = try testParse(&.{ "-SL33", "foo.rc" });
        defer options.deinit();

        try std.testing.expectEqual(@as(u15, 2703), options.max_string_literal_codepoints);
    }
    {
        var options = try testParse(&.{ "/sl15", "foo.rc" });
        defer options.deinit();

        try std.testing.expectEqual(@as(u15, 1228), options.max_string_literal_codepoints);
    }
}

test "parse: unsupported MUI-related options" {
    try testParseError(&.{ "/q", "blah", "/g1", "-G2", "blah", "/fm", "blah", "/g", "blah", "foo.rc" },
        \\<cli>: error: the /q option is unsupported
        \\ ... /q ...
        \\     ~^
        \\<cli>: error: the /g1 option is unsupported
        \\ ... /g1 ...
        \\     ~^~
        \\<cli>: error: the -G2 option is unsupported
        \\ ... -G2 ...
        \\     ~^~
        \\<cli>: error: the /fm option is unsupported
        \\ ... /fm ...
        \\     ~^~
        \\<cli>: error: the /g option is unsupported
        \\ ... /g ...
        \\     ~^
        \\
    );
}

test "parse: unsupported LCX/LCE-related options" {
    try testParseError(&.{ "/t", "/tp:", "/tp:blah", "/tm", "/tc", "/tw", "-TEti", "/ta", "/tn", "blah", "foo.rc" },
        \\<cli>: error: the /t option is unsupported
        \\ ... /t ...
        \\     ~^
        \\<cli>: error: missing value for /tp: option
        \\ ... /tp:  ...
        \\     ~~~~^
        \\<cli>: error: the /tp: option is unsupported
        \\ ... /tp: ...
        \\     ~^~~
        \\<cli>: error: the /tp: option is unsupported
        \\ ... /tp:blah ...
        \\     ~^~~~~~~
        \\<cli>: error: the /tm option is unsupported
        \\ ... /tm ...
        \\     ~^~
        \\<cli>: error: the /tc option is unsupported
        \\ ... /tc ...
        \\     ~^~
        \\<cli>: error: the /tw option is unsupported
        \\ ... /tw ...
        \\     ~^~
        \\<cli>: error: the -TE option is unsupported
        \\ ... -TEti ...
        \\     ~^~
        \\<cli>: error: the -ti option is unsupported
        \\ ... -TEti ...
        \\     ~  ^~
        \\<cli>: error: the /ta option is unsupported
        \\ ... /ta ...
        \\     ~^~
        \\<cli>: error: the /tn option is unsupported
        \\ ... /tn ...
        \\     ~^~
        \\
    );
}

test "parse: output filename specified twice" {
    try testParseError(&.{ "/fo", "foo.res", "foo.rc", "foo.res" },
        \\<cli>: error: output filename already specified
        \\ ... foo.res
        \\     ^~~~~~~
        \\<cli>: note: output filename previously specified here
        \\ ... /fo foo.res ...
        \\     ~~~~^~~~~~~
        \\
    );
}

test "parse: input and output formats" {
    {
        try testParseError(&.{ "/:output-format", "rcpp", "foo.res" },
            \\<cli>: error: input format 'res' cannot be converted to output format 'rcpp'
            \\
            \\<cli>: note: the input format was inferred from the input filename
            \\ ... foo.res
            \\     ^~~~~~~
            \\<cli>: note: the output format was specified here
            \\ ... /:output-format rcpp ...
            \\     ~~~~~~~~~~~~~~~~^~~~
            \\
        );
    }
    {
        try testParseError(&.{ "foo.res", "foo.rcpp" },
            \\<cli>: error: input format 'res' cannot be converted to output format 'rcpp'
            \\
            \\<cli>: note: the input format was inferred from the input filename
            \\ ... foo.res ...
            \\     ^~~~~~~
            \\<cli>: note: the output format was inferred from the output filename
            \\ ... foo.rcpp
            \\     ^~~~~~~~
            \\
        );
    }
    {
        try testParseError(&.{ "/:input-format", "res", "foo" },
            \\<cli>: error: input format 'res' cannot be converted to output format 'res'
            \\
            \\<cli>: note: the input format was specified here
            \\ ... /:input-format res ...
            \\     ~~~~~~~~~~~~~~~^~~
            \\<cli>: note: the output format was unable to be inferred from the input filename, so the default was used
            \\ ... foo
            \\     ^~~
            \\
        );
    }
    {
        try testParseError(&.{ "/p", "/:input-format", "res", "foo" },
            \\<cli>: error: input format 'res' cannot be converted to output format 'res'
            \\
            \\<cli>: error: the /p option cannot be used with output format 'res'
            \\ ... /p ...
            \\     ^~
            \\<cli>: note: the input format was specified here
            \\ ... /:input-format res ...
            \\     ~~~~~~~~~~~~~~~^~~
            \\<cli>: note: the output format was unable to be inferred from the input filename, so the default was used
            \\ ... foo
            \\     ^~~
            \\
        );
    }
    {
        try testParseError(&.{ "/:output-format", "coff", "/p", "foo.rc" },
            \\<cli>: error: the /p option cannot be used with output format 'coff'
            \\ ... /p ...
            \\     ^~
            \\<cli>: note: the output format was specified here
            \\ ... /:output-format coff ...
            \\     ~~~~~~~~~~~~~~~~^~~~
            \\
        );
    }
    {
        try testParseError(&.{ "/fo", "foo.res", "/p", "foo.rc" },
            \\<cli>: error: the /p option cannot be used with output format 'res'
            \\ ... /p ...
            \\     ^~
            \\<cli>: note: the output format was inferred from the output filename
            \\ ... /fo foo.res ...
            \\     ~~~~^~~~~~~
            \\
        );
    }
    {
        try testParseError(&.{ "/p", "foo.rc", "foo.o" },
            \\<cli>: error: the /p option cannot be used with output format 'coff'
            \\ ... /p ...
            \\     ^~
            \\<cli>: note: the output format was inferred from the output filename
            \\ ... foo.o
            \\     ^~~~~
            \\
        );
    }
    {
        var options = try testParse(&.{"foo.rc"});
        defer options.deinit();

        try std.testing.expectEqual(.rc, options.input_format);
        try std.testing.expectEqual(.res, options.output_format);
    }
    {
        var options = try testParse(&.{"foo.rcpp"});
        defer options.deinit();

        try std.testing.expectEqual(.no, options.preprocess);
        try std.testing.expectEqual(.rcpp, options.input_format);
        try std.testing.expectEqual(.res, options.output_format);
    }
    {
        var options = try testParse(&.{ "foo.rc", "foo.rcpp" });
        defer options.deinit();

        try std.testing.expectEqual(.only, options.preprocess);
        try std.testing.expectEqual(.rc, options.input_format);
        try std.testing.expectEqual(.rcpp, options.output_format);
    }
    {
        var options = try testParse(&.{ "foo.rc", "foo.obj" });
        defer options.deinit();

        try std.testing.expectEqual(.rc, options.input_format);
        try std.testing.expectEqual(.coff, options.output_format);
    }
    {
        var options = try testParse(&.{ "/fo", "foo.o", "foo.rc" });
        defer options.deinit();

        try std.testing.expectEqual(.rc, options.input_format);
        try std.testing.expectEqual(.coff, options.output_format);
    }
    {
        var options = try testParse(&.{"foo.res"});
        defer options.deinit();

        try std.testing.expectEqual(.res, options.input_format);
        try std.testing.expectEqual(.coff, options.output_format);
    }
    {
        var options = try testParseWarning(&.{ "/:depfile", "foo.json", "foo.rc", "foo.rcpp" },
            \\<cli>: warning: the /:depfile option was ignored because the output format is 'rcpp'
            \\ ... /:depfile foo.json ...
            \\     ~~~~~~~~~~^~~~~~~~
            \\<cli>: note: the output format was inferred from the output filename
            \\ ... foo.rcpp
            \\     ^~~~~~~~
            \\
        );
        defer options.deinit();

        try std.testing.expectEqual(.rc, options.input_format);
        try std.testing.expectEqual(.rcpp, options.output_format);
    }
    {
        var options = try testParseWarning(&.{ "/:depfile", "foo.json", "foo.res", "foo.o" },
            \\<cli>: warning: the /:depfile option was ignored because the input format is 'res'
            \\ ... /:depfile foo.json ...
            \\     ~~~~~~~~~~^~~~~~~~
            \\<cli>: note: the input format was inferred from the input filename
            \\ ... foo.res ...
            \\     ^~~~~~~
            \\
        );
        defer options.deinit();

        try std.testing.expectEqual(.res, options.input_format);
        try std.testing.expectEqual(.coff, options.output_format);
    }
}

test "maybeAppendRC" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var options = try testParse(&.{"foo"});
    defer options.deinit();
    try std.testing.expectEqualStrings("foo", options.input_source.filename);

    // Create the file so that it's found. In this scenario, .rc should not get
    // appended.
    var file = try tmp.dir.createFile("foo", .{});
    file.close();
    try options.maybeAppendRC(tmp.dir);
    try std.testing.expectEqualStrings("foo", options.input_source.filename);

    // Now delete the file and try again. But this time change the input format
    // to non-rc.
    try tmp.dir.deleteFile("foo");
    options.input_format = .res;
    try options.maybeAppendRC(tmp.dir);
    try std.testing.expectEqualStrings("foo", options.input_source.filename);

    // Finally, reset the input format to rc. Since the verbatim name is no longer found
    // and the input filename does not have an extension, .rc should get appended.
    options.input_format = .rc;
    try options.maybeAppendRC(tmp.dir);
    try std.testing.expectEqualStrings("foo.rc", options.input_source.filename);
}
