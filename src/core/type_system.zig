const std = @import("std");

pub const AetherType = union(enum) {
    Int,
    String,
    Bool,
    Pointer,
    Void,
    Null,
    Unknown,
    Array: *const AetherType,
    Custom: []const u8,
    Function: struct {
        params: []const *const AetherType,
        return_type: *const AetherType,
        c_name: []const u8,
    },
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
            .Pointer => try writer.writeAll("Pointer"),
            .Void => try writer.writeAll("Void"),
            .Null => try writer.writeAll("null"),
            .Unknown => try writer.writeAll("Unknown"),
            .Array => |elem| {
                try writer.writeAll("[");
                try elem.format("", options, writer);
                try writer.writeAll("]");
            },
            .Custom => |name| try writer.writeAll(name),
            .Function => |f| {
                try writer.writeAll("fun(");
                for (f.params, 0..) |p, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try p.format("", options, writer);
                }
                try writer.writeAll("): ");
                try f.return_type.format("", options, writer);
            },
            .Union => |u| {
                try u.left.format("", options, writer);
                try writer.writeAll(" | ");
                try u.right.format("", options, writer);
            },
        }
    }
};

pub const Symbol = union(enum) {
    Variable: *const AetherType,
    Overloads: std.ArrayList(*const AetherType),
};

pub const Scope = struct {
    allocator: std.mem.Allocator,
    parent: ?*Scope,
    symbols: std.StringHashMap(*Symbol),

    pub fn init(allocator: std.mem.Allocator, parent: ?*Scope) Scope {
        return Scope{
            .allocator = allocator,
            .parent = parent,
            .symbols = std.StringHashMap(*Symbol).init(allocator),
        };
    }

    pub fn deinit(self: *Scope) void {
        self.symbols.deinit();
    }

    pub fn define(self: *Scope, name: []const u8, t: *const AetherType) !void {
        if (self.symbols.get(name)) |existing| {
            if (t.* == .Function) {
                if (existing.* == .Overloads) {
                    try existing.Overloads.append(t);
                    return;
                } else {
                    std.debug.print("SymbolAlreadyDefined: {s} is not Overloads\n", .{name});
                    return error.SymbolAlreadyDefined;
                }
            } else {
                std.debug.print("SymbolAlreadyDefined: {s} is not Function\n", .{name});
                return error.SymbolAlreadyDefined;
            }
        }

        const sym = try self.allocator.create(Symbol);
        if (t.* == .Function) {
            var list = std.ArrayList(*const AetherType).init(self.allocator);
            try list.append(t);
            sym.* = .{ .Overloads = list };
        } else {
            sym.* = .{ .Variable = t };
        }
        try self.symbols.put(name, sym);
    }

    pub fn lookupVariable(self: *Scope, name: []const u8) ?*const AetherType {
        if (self.symbols.get(name)) |sym| {
            if (sym.* == .Variable) return sym.Variable;
        }
        if (self.parent) |p| {
            return p.lookupVariable(name);
        }
        return null;
    }

    pub fn lookupFunctions(self: *Scope, name: []const u8) ?[]const *const AetherType {
        if (self.symbols.get(name)) |sym| {
            if (sym.* == .Overloads) return sym.Overloads.items;
        }
        if (self.parent) |p| {
            return p.lookupFunctions(name);
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

pub fn isBool(t: *const AetherType) bool {
    const base = extractBaseType(t);
    switch (base.*) {
        .Bool => return true,
        .Custom => |name| {
            return std.mem.eql(u8, name, "Bool") or std.mem.eql(u8, name, "core_Bool");
        },
        else => return false,
    }
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
            .Array => |elem| {
                if (act_base.* == .Array) {
                    return isCompatible(elem, act_base.Array);
                }
                return false;
            },
            else => return true,
        }
    }
    return false;
}
