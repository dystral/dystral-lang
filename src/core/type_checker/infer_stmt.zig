const std = @import("std");
const ast = @import("../ast.zig");
const core = @import("core.zig");

const ASTNode = core.ASTNode;
const TypeChecker = core.TypeChecker;
const Scope = core.Scope;
const AetherType = core.AetherType;

pub fn inferIfExpr(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *AetherType) anyerror!void {
    const i = node.data.if_expr;
    const cond_type = try self.inferNode(i.condition, scope);
    if (!core.isBool(cond_type)) {
        self.reportError(node.line, node.column, "TypeError: if condition must be Bool, found {}.", .{cond_type.*});
        return error.TypeError;
    }
    const then_type = try self.inferNode(i.then_branch, scope);
    if (i.else_branch) |else_b| {
        const else_type = try self.inferNode(else_b, scope);
        if (!core.isCompatible(then_type, else_type) and !core.isCompatible(else_type, then_type)) {
            self.reportError(node.line, node.column, "TypeError: if branches have incompatible types: {} and {}.", .{ then_type.*, else_type.* });
            return error.TypeError;
        }
        t.* = then_type.*;
    } else {
        t.* = .Void;
    }
}

pub fn inferWhileStmt(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *AetherType) anyerror!void {
    const w = node.data.while_stmt;
    const cond_type = try self.inferNode(w.condition, scope);
    if (!core.isBool(cond_type)) {
        self.reportError(node.line, node.column, "TypeError: while condition must be Bool, found {}.", .{cond_type.*});
        return error.TypeError;
    }
    _ = try self.inferNode(w.body, scope);
    t.* = .Void;
}

pub fn inferForStmt(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *AetherType) anyerror!void {
    const f = node.data.for_stmt;
    var iter_type = try self.inferNode(f.iterable, scope);
    
    var is_list = false;
    if (iter_type.* == .GenericInstance and (std.mem.eql(u8, iter_type.GenericInstance.base_name, "List") or std.mem.eql(u8, iter_type.GenericInstance.base_name, "MutableList"))) {
        is_list = true;
    } else if (iter_type.* == .Custom) {
        if (std.mem.indexOf(u8, iter_type.Custom, "List") != null) {
            is_list = true;
        }
    }
    
    if (is_list) {
        const get_expr = try self.allocator.create(ASTNode);
        get_expr.* = .{ .line = node.line, .column = node.column, .resolved_type = null, .data = .{ .get_expr = .{ .object = f.iterable, .name = "items", .is_safe = false } } };
        
        _ = try self.inferNode(get_expr, scope);
        
        node.data.for_stmt.iterable = get_expr;
        iter_type = get_expr.resolved_type.?;
    }
    
    if (iter_type.* != .Array) {
        self.reportError(node.line, node.column, "TypeError: for loop iterable must be an Array or List, found {}.", .{iter_type.*});
        return error.TypeError;
    }
    
    var for_scope = Scope.init(self.allocator, scope);
    defer for_scope.deinit();
    
    try for_scope.define(f.item_name, iter_type.Array);
    
    _ = try self.inferNode(f.body, &for_scope);
    t.* = .Void;
}

pub fn inferReturnStmt(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *AetherType) anyerror!void {
    const r = node.data.return_stmt;
    if (r.value) |v| {
        const ret_type = try self.inferNode(v, scope);
        t.* = ret_type.*;
        return;
    }
    t.* = .Void;
}

pub fn checkBlock(self: *TypeChecker, block: []const *ASTNode, parent_scope: *Scope) anyerror!*const AetherType {
    var local_scope = Scope.init(self.allocator, parent_scope);
    defer local_scope.deinit();

    for (block) |stmt| {
        _ = try self.inferNode(stmt, &local_scope);
    }

    const t = try self.allocator.create(AetherType);
    t.* = .Void;
    return t;
}
