//! SQLite registry of tabs and the terminals they hold.
//! A terminal lives on its own (a zmx session); its tab is only a parent pointer,
//! so moving a terminal between tabs is a single UPDATE.
const std = @import("std");
const c = @import("sqlite");

const SCHEMA =
    \\PRAGMA foreign_keys = ON;
    \\PRAGMA journal_mode = WAL;
    \\CREATE TABLE IF NOT EXISTS tabs (
    \\    id INTEGER PRIMARY KEY,
    \\    name TEXT NOT NULL UNIQUE,
    \\    position INTEGER NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS terminals (
    \\    id TEXT PRIMARY KEY,
    \\    tab_id INTEGER NOT NULL REFERENCES tabs(id),
    \\    position INTEGER NOT NULL,
    \\    created_at INTEGER NOT NULL DEFAULT (unixepoch())
    \\);
;

pub const Terminal = struct {
    id: []const u8,
    tab: []const u8,
};

pub const Store = struct {
    db: *c.sqlite3,

    pub fn open(path: [:0]const u8) !Store {
        var db: ?*c.sqlite3 = null;
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE;

        if (c.sqlite3_open_v2(path, &db, flags, null) != c.SQLITE_OK) {
            if (db) |handle| _ = c.sqlite3_close(handle);
            return error.DatabaseOpenFailed;
        }

        const store: Store = .{ .db = db.? };
        errdefer store.close();

        // Several CLI processes may write at once (two panes created together).
        _ = c.sqlite3_busy_timeout(store.db, 2000);
        try store.exec(SCHEMA);

        return store;
    }

    pub fn close(self: Store) void {
        _ = c.sqlite3_close(self.db);
    }

    /// Puts a new terminal at the end of `tab`, creating the tab if needed.
    pub fn addTerminal(self: Store, id: []const u8, tab: []const u8) !void {
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.exec("ROLLBACK") catch {};

        const tab_id = try self.ensureTab(tab);

        try self.run(
            \\INSERT INTO terminals (id, tab_id, position)
            \\VALUES (?1, ?2, (SELECT COALESCE(MAX(position), -1) + 1 FROM terminals WHERE tab_id = ?2))
        , .{ id, tab_id });

        try self.exec("COMMIT");
    }

    /// Re-parents a terminal to the end of `tab`. The session itself is untouched.
    pub fn moveTerminal(self: Store, id: []const u8, tab: []const u8) !void {
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.exec("ROLLBACK") catch {};

        const tab_id = try self.ensureTab(tab);

        try self.run(
            \\UPDATE terminals
            \\SET tab_id = ?2, position = (SELECT COALESCE(MAX(position), -1) + 1 FROM terminals WHERE tab_id = ?2)
            \\WHERE id = ?1
        , .{ id, tab_id });

        if (c.sqlite3_changes(self.db) == 0) return error.TerminalNotFound;

        try self.deleteEmptyTabs();
        try self.exec("COMMIT");
    }

    pub fn removeTerminal(self: Store, id: []const u8) !void {
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.exec("ROLLBACK") catch {};

        try self.run("DELETE FROM terminals WHERE id = ?1", .{id});
        try self.deleteEmptyTabs();
        try self.exec("COMMIT");
    }

    /// All terminals, ordered by tab then by position inside the tab.
    /// Strings are owned by `arena`.
    pub fn listTerminals(self: Store, arena: std.mem.Allocator) ![]Terminal {
        const stmt = try self.prepare(
            \\SELECT terminals.id, tabs.name FROM terminals
            \\JOIN tabs ON tabs.id = terminals.tab_id
            \\ORDER BY tabs.position, terminals.position
        );
        defer _ = c.sqlite3_finalize(stmt);

        var terminals: std.ArrayList(Terminal) = .empty;

        while (try step(stmt)) {
            try terminals.append(arena, .{
                .id = try arena.dupe(u8, columnText(stmt, 0)),
                .tab = try arena.dupe(u8, columnText(stmt, 1)),
            });
        }

        return terminals.toOwnedSlice(arena);
    }

    fn ensureTab(self: Store, name: []const u8) !i64 {
        try self.run(
            \\INSERT INTO tabs (name, position)
            \\VALUES (?1, (SELECT COALESCE(MAX(position), -1) + 1 FROM tabs))
            \\ON CONFLICT (name) DO NOTHING
        , .{name});

        const stmt = try self.prepare("SELECT id FROM tabs WHERE name = ?1");
        defer _ = c.sqlite3_finalize(stmt);

        try bind(stmt, .{name});

        if (!try step(stmt)) return error.TabNotFound;

        return c.sqlite3_column_int64(stmt, 0);
    }

    // A tab exists only while it holds terminals, like a window tab in the client.
    fn deleteEmptyTabs(self: Store) !void {
        try self.exec("DELETE FROM tabs WHERE id NOT IN (SELECT tab_id FROM terminals)");
    }

    fn exec(self: Store, sql: [:0]const u8) !void {
        if (c.sqlite3_exec(self.db, sql, null, null, null) != c.SQLITE_OK) {
            std.log.err("sqlite: {s}", .{c.sqlite3_errmsg(self.db)});
            return error.DatabaseError;
        }
    }

    fn run(self: Store, sql: [:0]const u8, args: anytype) !void {
        const stmt = try self.prepare(sql);
        defer _ = c.sqlite3_finalize(stmt);

        try bind(stmt, args);
        _ = try step(stmt);
    }

    fn prepare(self: Store, sql: [:0]const u8) !*c.sqlite3_stmt {
        var stmt: ?*c.sqlite3_stmt = null;

        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            std.log.err("sqlite: {s}", .{c.sqlite3_errmsg(self.db)});
            return error.DatabaseError;
        }

        return stmt.?;
    }
};

// Statements are always stepped before the bound slices go out of scope, so SQLite need not copy them.
fn bind(stmt: *c.sqlite3_stmt, args: anytype) !void {
    inline for (args, 1..) |arg, index| {
        const result = switch (@TypeOf(arg)) {
            i64 => c.sqlite3_bind_int64(stmt, index, arg),
            else => c.sqlite3_bind_text(stmt, index, arg.ptr, @intCast(arg.len), null),
        };

        if (result != c.SQLITE_OK) return error.DatabaseError;
    }
}

fn step(stmt: *c.sqlite3_stmt) !bool {
    return switch (c.sqlite3_step(stmt)) {
        c.SQLITE_ROW => true,
        c.SQLITE_DONE => false,
        else => error.DatabaseError,
    };
}

fn columnText(stmt: *c.sqlite3_stmt, column: c_int) []const u8 {
    const text = c.sqlite3_column_text(stmt, column) orelse return "";
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, column));

    return text[0..len];
}

test "moving a terminal re-parents it and drops the emptied tab" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const store = try Store.open(":memory:");
    defer store.close();

    try store.addTerminal("aaa", "work");
    try store.addTerminal("bbb", "work");
    try store.addTerminal("ccc", "logs");

    try store.moveTerminal("ccc", "work");

    const terminals = try store.listTerminals(arena);

    try std.testing.expectEqual(3, terminals.len);
    try std.testing.expectEqualStrings("ccc", terminals[2].id);
    try std.testing.expectEqualStrings("work", terminals[2].tab);

    try std.testing.expectError(error.TerminalNotFound, store.moveTerminal("zzz", "work"));
}
