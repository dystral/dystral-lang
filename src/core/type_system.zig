const std = @import("std");

pub const AetherType = union(enum) {
    Int,
    String,
    Bool,
    Void,
    Null,
    Unknown,
    Custom: []const u8,
    Union: struct {
        left: *const AetherType,
        right: *const AetherType,
    },

    pub fn format(self: AetherType, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        switch (self) {
            .Int => try writer.writeAll("Int"),
            .String => try writer.writeAll("String"),
            .Bool => try writer.writeAll("Bool"),
            .Void => try writer.writeAll("Void"),
            .Null => try writer.writeAll("null"),
            .Unknown => try writer.writeAll("Unknown"),
            .Custom => |name| try writer.writeAll(name),
            .Union => |u| {
                try u.left.format("", options, writer);
                try writer.writeAll(" | ");
                try u.right.format("", options, writer);
            },
        }
    }
};

pub const Scope = struct {
    allocator: std.mem.Allocator,
    parent: ?*Scope,
    variables: std.StringHashMap(*const AetherType),

    pub fn init(allocator: std.mem.Allocator, parent: ?*Scope) Scope {
        return Scope{
            .allocator = allocator,
            .parent = parent,
            .variables = std.StringHashMap(*const AetherType).init(allocator),
        };
    }

    pub fn deinit(self: *Scope) void {
        self.variables.deinit();
    }

    pub fn define(self: *Scope, name: []const u8, t: *const AetherType) !void {
        try self.variables.put(name, t);
    }

    pub fn lookup(self: *Scope, name: []const u8) ?*const AetherType {
        if (self.variables.get(name)) |t| {
            return t;
        }
        if (self.parent) |p| {
            return p.lookup(name);
        }
        return null;
    }
};

pub fn isNullable(t: *const AetherType) bool {
    return switch (t.*) {
        .Null => true,
        .Union => |u| isNullable(u.left) or isNullable(u.right),
        else => false,
    };
}

pub fn extractBaseType(t: *const AetherType) *const AetherType {
    return switch (t.*) {
        .Union => |u| if (u.right.* == .Null) extractBaseType(u.left) else t,
        else => t,
    };
}

pub fn isCompatible(expected: *const AetherType, actual: *const AetherType) bool {
    if (expected.* == .Unknown or actual.* == .Unknown) return true;
    if (isNullable(expected) and actual.* == .Null) return true;
    if (isNullable(actual) and !isNullable(expected)) return false;

    const exp_base = extractBaseType(expected);
    const act_base = extractBaseType(actual);

    if (std.meta.activeTag(exp_base.*) == std.meta.activeTag(act_base.*)) {
        switch (exp_base.*) {
            .Custom => |name| {
                if (act_base.* == .Custom) {
                    return std.mem.eql(u8, name, act_base.Custom);
                }
                return false;
            },
            else => return true,
        }
    }
    return false;
}
