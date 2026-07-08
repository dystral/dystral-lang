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
    if (cond_type.* != .Bool) {
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
    if (cond_type.* != .Bool) {
        self.reportError(node.line, node.column, "TypeError: while condition must be Bool, found {}.", .{cond_type.*});
        return error.TypeError;
    }
    _ = try self.inferNode(w.body, scope);
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
