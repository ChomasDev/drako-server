//! drako: native terminal sessions that outlive their tabs.
//! Each terminal is a zmx session (PTY + libghostty-vt); a SQLite registry says which tab holds it.
const std = @import("std");
const zmx = @import("zmx");
const Store = @import("store.zig").Store;

const DEFAULT_TAB = "main";
const SESSION_PREFIX = "dk-";

// zmx logs every session step at info level; keep the CLI output to what the user asked for.
pub const std_options: std.Options = .{ .log_level = .warn };

const USAGE =
    \\Usage: drako <command> [args...]
    \\
    \\Commands:
    \\  new [--tab NAME] [--cwd DIR] [-- COMMAND...]   Start a terminal, print its id
    \\  attach ID                                        Attach this tty to a terminal (ctrl+\ detaches)
    \\  ls [--json]                                      List terminals grouped by tab
    \\  move ID TAB                                      Move a terminal to another tab
    \\  kill ID                                          Stop a terminal
    \\
    \\Works the same locally and remotely: ssh host drako attach ID
    \\
;

pub fn main(init: std.process.Init) !void {
    // zmx's forked session daemon frees what it was handed with libc free(), so everything
    // passed to zmx must come from c_allocator. Short-lived CLI: nothing is freed before exit.
    const gpa = std.heap.c_allocator;
    const io = init.io;

    var args = try init.minimal.args.iterateAllocator(gpa);
    _ = args.next();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buffer);
    defer stdout.interface.flush() catch {};

    const command = args.next() orelse fail(USAGE);

    const app: App = .{
        .gpa = gpa,
        .io = io,
        .out = &stdout.interface,
        .db_path = try dbPath(gpa, io, init.environ_map),
        .shell = init.environ_map.get("SHELL"),
    };

    if (eql(command, "new")) return app.new(&args);

    if (eql(command, "attach")) return app.attach(requireArg(&args));

    if (eql(command, "ls")) return app.list(&args);

    if (eql(command, "move")) return app.move(requireArg(&args), requireArg(&args));

    if (eql(command, "kill")) return app.kill(requireArg(&args));

    fail(USAGE);
}

const LiveTerminal = struct {
    id: []const u8,
    tab: []const u8,
    attached: bool,
    cmd: []const u8,
    cwd: []const u8,
};

const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    db_path: [:0]const u8,
    /// The user's login shell for new terminals; zmx falls back to /bin/sh without it.
    shell: ?[]const u8,

    fn new(self: App, args: *std.process.Args.Iterator) !void {
        var tab: []const u8 = DEFAULT_TAB;
        var cwd: ?[]const u8 = null;
        var command: std.ArrayList([]const u8) = .empty;

        while (args.next()) |arg| {
            if (eql(arg, "--tab")) {
                tab = requireArg(args);
                continue;
            }

            if (eql(arg, "--cwd")) {
                cwd = requireArg(args);
                continue;
            }

            if (eql(arg, "--")) {
                while (args.next()) |part| try command.append(self.gpa, part);
                break;
            }

            fail(USAGE);
        }

        const id = newId(self.io);

        // Spawn first: zmx forks the session daemon from this process, and it must not inherit the db handle.
        _ = try zmx.create(self.gpa, self.io, try sessionName(self.gpa, &id), .{
            .command = if (command.items.len > 0) command.items else null,
            .cwd = cwd,
            .shell = self.shell,
            .quiet = true,
        });

        const store = try Store.open(self.db_path);
        defer store.close();

        store.addTerminal(&id, tab) catch |err| {
            _ = zmx.kill(self.gpa, self.io, try sessionName(self.gpa, &id), .{}) catch {};
            return err;
        };

        try self.out.print("{s}\n", .{id});
    }

    fn attach(self: App, id: []const u8) !void {
        try self.requireTerminal(id);

        return zmx.attach(self.gpa, self.io, try sessionName(self.gpa, id), .{});
    }

    fn list(self: App, args: *std.process.Args.Iterator) !void {
        const format = args.next() orelse "";

        if (format.len > 0 and !eql(format, "--json")) fail(USAGE);

        const terminals = try self.liveTerminals();

        if (format.len > 0) {
            return std.json.Stringify.value(terminals, .{}, self.out);
        }

        var current_tab: []const u8 = "";

        for (terminals) |terminal| {
            if (!eql(terminal.tab, current_tab)) {
                try self.out.print("{s}\n", .{terminal.tab});
                current_tab = terminal.tab;
            }

            try self.out.print("  {s}  {s:<8}  {s}  {s}\n", .{
                terminal.id,
                if (terminal.attached) "attached" else "detached",
                orDash(terminal.cmd),
                orDash(terminal.cwd),
            });
        }
    }

    /// Registry rows joined with their zmx session; rows whose program has exited are forgotten.
    fn liveTerminals(self: App) ![]LiveTerminal {
        const store = try Store.open(self.db_path);
        defer store.close();

        const sessions = try zmx.list(self.gpa, self.io);
        var live: std.ArrayList(LiveTerminal) = .empty;

        for (try store.listTerminals(self.gpa)) |terminal| {
            const session = findSession(sessions, terminal.id) orelse {
                try store.removeTerminal(terminal.id);
                continue;
            };

            try live.append(self.gpa, .{
                .id = terminal.id,
                .tab = terminal.tab,
                .attached = (session.clients_len orelse 0) > 0,
                .cmd = session.cmd orelse "",
                .cwd = displayPath(session.cwd orelse ""),
            });
        }

        return live.toOwnedSlice(self.gpa);
    }

    fn move(self: App, id: []const u8, tab: []const u8) !void {
        const store = try Store.open(self.db_path);
        defer store.close();

        store.moveTerminal(id, tab) catch |err| switch (err) {
            error.TerminalNotFound => fail("unknown terminal\n"),
            else => return err,
        };
    }

    fn kill(self: App, id: []const u8) !void {
        try self.requireTerminal(id);

        _ = try zmx.kill(self.gpa, self.io, try sessionName(self.gpa, id), .{});

        const store = try Store.open(self.db_path);
        defer store.close();

        try store.removeTerminal(id);
    }

    fn requireTerminal(self: App, id: []const u8) !void {
        const store = try Store.open(self.db_path);
        defer store.close();

        for (try store.listTerminals(self.gpa)) |terminal| {
            if (eql(terminal.id, id)) return;
        }

        fail("unknown terminal\n");
    }
};

const ID_BYTES = 3;

fn newId(io: std.Io) [ID_BYTES * 2]u8 {
    var bytes: [ID_BYTES]u8 = undefined;
    io.random(&bytes);

    return std.fmt.bytesToHex(bytes, .lower);
}

fn sessionName(gpa: std.mem.Allocator, id: []const u8) ![]const u8 {
    return std.mem.concat(gpa, u8, &.{ SESSION_PREFIX, id });
}

fn findSession(sessions: []const zmx.SessionEntry, id: []const u8) ?zmx.SessionEntry {
    for (sessions) |session| {
        if (!std.mem.startsWith(u8, session.name, SESSION_PREFIX)) continue;

        if (eql(session.name[SESSION_PREFIX.len..], id) and !session.is_error) return session;
    }

    return null;
}

/// zmx reports the cwd as an OSC 7 url (file://host/path); show just the path.
fn displayPath(cwd: []const u8) []const u8 {
    const FILE_SCHEME = "file://";

    if (!std.mem.startsWith(u8, cwd, FILE_SCHEME)) return cwd;

    const host_and_path = cwd[FILE_SCHEME.len..];
    const path_start = std.mem.indexOfScalar(u8, host_and_path, '/') orelse return cwd;

    return host_and_path[path_start..];
}

/// $DRAKO_DB, else $XDG_DATA_HOME/drako/drako.db, else ~/.local/share/drako/drako.db.
fn dbPath(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) ![:0]const u8 {
    if (env.get("DRAKO_DB")) |path| return gpa.dupeSentinel(u8, path, 0);

    const data_home = env.get("XDG_DATA_HOME") orelse
        try std.fs.path.join(gpa, &.{ env.get("HOME") orelse return error.HomeNotSet, ".local", "share" });

    const dir = try std.fs.path.join(gpa, &.{ data_home, "drako" });
    try std.Io.Dir.cwd().createDirPath(io, dir);

    return std.fs.path.joinZ(gpa, &.{ dir, "drako.db" });
}

fn requireArg(args: *std.process.Args.Iterator) []const u8 {
    return args.next() orelse fail(USAGE);
}

fn fail(message: []const u8) noreturn {
    std.debug.print("{s}", .{message});
    std.process.exit(1);
}

fn orDash(text: []const u8) []const u8 {
    return if (text.len > 0) text else "-";
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

test "displayPath strips the OSC 7 scheme and host" {
    try std.testing.expectEqualStrings("/tmp/x", displayPath("file://box/tmp/x"));
    try std.testing.expectEqualStrings("/tmp/x", displayPath("/tmp/x"));
}

test {
    _ = @import("store.zig");
}
