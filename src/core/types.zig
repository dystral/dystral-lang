const std = @import("std");
const ast = @import("ast.zig");
const parser_mod = @import("../frontend/parser.zig");
const ASTNode = ast.ASTNode;

pub const AetherType = union(enum) {
    Int,
    String,
    Bool,
    Void,
    Null,
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

pub const TypeChecker = struct {
    allocator: std.mem.Allocator,
    global_scope: Scope,
    source: []const u8,
    filename: []const u8,

    pub fn init(allocator: std.mem.Allocator, source: []const u8, filename: []const u8) TypeChecker {
        var checker = TypeChecker{
            .allocator = allocator,
            .global_scope = Scope.init(allocator, null),
            .source = source,
            .filename = filename,
        };
        
        // Inject String type into global scope
        const string_t = allocator.create(AetherType) catch unreachable;
        string_t.* = .String;
        checker.global_scope.define("String", string_t) catch unreachable;
        
        return checker;
    }

    pub fn deinit(self: *TypeChecker) void {
        self.global_scope.deinit();
    }

    fn reportError(self: *TypeChecker, line: usize, column: usize, comptime message: []const u8, args: anytype) void {
        std.debug.print("\n\x1b[31mError\x1b[0m in {s}:{}:{}:\n", .{self.filename, line, column});
        
        var current_line: usize = 1;
        var start_idx: usize = 0;
        var end_idx: usize = 0;
        
        while (end_idx < self.source.len) : (end_idx += 1) {
            if (self.source[end_idx] == '\n') {
                if (current_line == line) break;
                current_line += 1;
                start_idx = end_idx + 1;
            }
        }
        if (end_idx > self.source.len) end_idx = self.source.len;
        
        const line_str = self.source[start_idx..end_idx];
        std.debug.print("    {s}\n", .{line_str});
        
        std.debug.print("    ", .{});
        var i: usize = 1;
        while (i < column) : (i += 1) {
            std.debug.print(" ", .{});
        }
        std.debug.print("\x1b[31m^-- ", .{});
        std.debug.print(message, args);
        std.debug.print("\x1b[0m\n\n", .{});
    }

    fn isNullable(t: *const AetherType) bool {
        return switch (t.*) {
            .Null => true,
            .Union => |u| isNullable(u.left) or isNullable(u.right),
            else => false,
        };
    }

    fn extractBaseType(t: *const AetherType) *const AetherType {
        return switch (t.*) {
            .Union => |u| if (u.right.* == .Null) extractBaseType(u.left) else t,
            else => t,
        };
    }

    fn isCompatible(expected: *const AetherType, actual: *const AetherType) bool {
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

    pub fn resolveTypeName(self: *TypeChecker, name: []const u8, is_nullable: bool) !*AetherType {
        var base_type: AetherType = .Void;
        if (std.mem.eql(u8, name, "Int")) {
            base_type = .Int;
        } else if (std.mem.eql(u8, name, "String")) {
            base_type = .String;
        } else if (std.mem.eql(u8, name, "Bool")) {
            base_type = .Bool;
        } else {
            base_type = .{ .Custom = name };
        }
        
        const t = try self.allocator.create(AetherType);
        if (is_nullable) {
            t.* = .{ .Union = .{
                .left = try self.allocator.create(AetherType),
                .right = try self.allocator.create(AetherType),
            } };
            @constCast(t.Union.left).* = base_type;
            @constCast(t.Union.right).* = .Null;
        } else {
            t.* = base_type;
        }
        return t;
    }

    pub fn validate(self: *TypeChecker, node: *ASTNode) anyerror!void {
        _ = try self.inferNode(node, &self.global_scope);
    }
    
    fn checkBlock(self: *TypeChecker, block: []const *ASTNode, parent_scope: *Scope) anyerror!*const AetherType {
        var local_scope = Scope.init(self.allocator, parent_scope);
        defer local_scope.deinit();
        
        for (block) |stmt| {
            _ = try self.inferNode(stmt, &local_scope);
        }
        
        const t = try self.allocator.create(AetherType);
        t.* = .Void;
        return t;
    }

    pub fn inferNode(self: *TypeChecker, node: *ASTNode, scope: *Scope) anyerror!*const AetherType {
        const t = try self.allocator.create(AetherType);
        switch (node.data) {
            .program => |p| {
                for (p.statements) |stmt| {
                    _ = try self.inferNode(stmt, scope);
                }
                t.* = .Void;
            },
            .class_decl => |c| {
                const class_type = try self.allocator.create(AetherType);
                class_type.* = .{ .Custom = c.name };
                try scope.define(c.name, class_type);
                
                var class_scope = Scope.init(self.allocator, scope);
                defer class_scope.deinit();
                try class_scope.define("self", class_type);
                
                // Methods
                for (c.methods) |method| {
                    if (method.data == .fun_decl) {
                        const m_name = method.data.fun_decl.name;
                        const is_operator = std.mem.eql(u8, m_name, "plus") or 
                                            std.mem.eql(u8, m_name, "minus") or 
                                            std.mem.eql(u8, m_name, "star") or 
                                            std.mem.eql(u8, m_name, "slash");
                        if (is_operator) {
                            var has_operator_mod = false;
                            for (method.data.fun_decl.modifiers) |mod| {
                                if (mod == .kw_operator) {
                                    has_operator_mod = true;
                                    break;
                                }
                            }
                            if (!has_operator_mod) {
                                self.reportError(method.line, method.column, "TypeError: Method '{s}' must be marked with the 'operator' modifier.", .{m_name});
                                return error.TypeError;
                            }
                        }
                    }
                    _ = try self.inferNode(method, &class_scope);
                }
                t.* = .Void;
            },
            .fun_decl => |f| {
                var fun_scope = Scope.init(self.allocator, scope);
                defer fun_scope.deinit();
                
                for (f.params) |p| {
                    var param_type: *AetherType = undefined;
                    if (p.type_name) |tn| {
                        param_type = try self.resolveTypeName(tn, p.type_is_nullable);
                    } else {
                        param_type = try self.allocator.create(AetherType);
                        param_type.* = .Void;
                    }
                    try fun_scope.define(p.name, param_type);
                }
                
                _ = try self.inferNode(f.body, &fun_scope);
                t.* = .Void;
            },
            .var_decl => |v| {
                var inferred: ?*const AetherType = null;
                if (v.initializer) |init_node| {
                    inferred = try self.inferNode(init_node, scope);
                }
                
                var declared: ?*const AetherType = null;
                if (v.type_name) |tn| {
                    declared = try self.resolveTypeName(tn, v.type_is_nullable);
                }
                
                if (declared != null and inferred != null) {
                    if (!isCompatible(declared.?, inferred.?)) {
                        self.reportError(node.line, node.column, "TypeError: Expected {} but found {} for variable '{s}'.", .{declared.?.*, inferred.?.*, v.name});
                        return error.TypeError;
                    }
                }
                
                const final_type = declared orelse (inferred orelse blk: {
                    const void_t = try self.allocator.create(AetherType);
                    void_t.* = .Void;
                    break :blk void_t;
                });
                try scope.define(v.name, final_type);
                t.* = .Void;
            },
            .assignment => |a| {
                const assigned_type = try self.inferNode(a.value, scope);
                if (scope.lookup(a.name)) |expected| {
                    if (!isCompatible(expected, assigned_type)) {
                        self.reportError(node.line, node.column, "TypeError: Expected {} but found {} when reassigning variable '{s}'.", .{expected.*, assigned_type.*, a.name});
                        return error.TypeError;
                    }
                } else {
                    self.reportError(node.line, node.column, "TypeError: Undeclared variable '{s}'.", .{a.name});
                    return error.TypeError;
                }
                t.* = assigned_type.*;
            },
            .unary_expr => |u| {
                if (u.operator == .bang_bang) {
                    const op_type = try self.inferNode(u.operand, scope);
                    t.* = extractBaseType(op_type).*;
                }
            },
            .binary_expr => |b| {
                const left_type = try self.inferNode(b.left, scope);
                const right_type = try self.inferNode(b.right, scope);

                if (b.op == .elvis) {
                    const l_base = extractBaseType(left_type);
                    if (!isCompatible(l_base, right_type)) {
                        self.reportError(node.line, node.column, "TypeError: Elvis right-hand side {} is incompatible with left base type {}.", .{right_type.*, l_base.*});
                        return error.TypeError;
                    }
                    t.* = l_base.*;
                    return t;
                }
                
                switch (b.op) {
                    .plus => {
                        if (left_type.* == .Int and right_type.* == .Int) {
                            t.* = .Int;
                        } else {
                            // AST Desugaring! Convert `a + b` to `a.plus(b)`
                            const get_expr_node = try self.allocator.create(ASTNode);
                            get_expr_node.* = .{
                                .line = node.line,
                                .column = node.column,
                                .resolved_type = null, // don't care, transpile only needs the object's resolved_type
                                .data = .{ .get_expr = .{ .object = b.left, .name = "plus", .is_safe = false } }
                            };
                            
                            var args = try self.allocator.alloc(*ASTNode, 1);
                            args[0] = b.right;
                            
                            node.data = .{ .call_expr = .{ .callee = get_expr_node, .arguments = args } };
                            
                            // Assume the method returns the same type for simplicity in v0.1
                            t.* = left_type.*;
                        }
                    },
                    .minus => {
                        if (left_type.* == .Int and right_type.* == .Int) {
                            t.* = .Int;
                        } else {
                            const get_expr_node = try self.allocator.create(ASTNode);
                            get_expr_node.* = .{
                                .line = node.line,
                                .column = node.column,
                                .resolved_type = null,
                                .data = .{ .get_expr = .{ .object = b.left, .name = "minus", .is_safe = false } }
                            };
                            
                            var args = try self.allocator.alloc(*ASTNode, 1);
                            args[0] = b.right;
                            
                            node.data = .{ .call_expr = .{ .callee = get_expr_node, .arguments = args } };
                            t.* = left_type.*;
                        }
                    },
                    .star, .slash => {
                        if (left_type.* != .Int or right_type.* != .Int) {
                            self.reportError(node.line, node.column, "TypeError: Math operations require Int on both sides. Found {} and {}.", .{left_type.*, right_type.*});
                            return error.TypeError;
                        }
                        t.* = .Int;
                    },
                    .eq_eq, .bang_eq, .less, .greater, .less_eq, .greater_eq, .and_and, .or_or => {
                        t.* = .Bool;
                    },
                    else => return error.TypeError,
                }
            },
            .identifier => |i| {
                if (scope.lookup(i)) |found| {
                    t.* = found.*;
                    node.resolved_type = t;
                    return t;
                }
                self.reportError(node.line, node.column, "TypeError: Undeclared variable '{s}'.", .{i});
                return error.TypeError;
            },
            .int_literal => t.* = .Int,
            .string_literal => t.* = .String,
            .bool_literal => t.* = .Bool,
            .null_literal => t.* = .Null,
            .call_expr => |c| {
                // Infer all arguments
                for (c.arguments) |arg| {
                    _ = try self.inferNode(arg, scope);
                }
                
                if (c.callee.data == .identifier) {
                    const name = c.callee.data.identifier;
                    if (std.mem.eql(u8, name, "print")) {
                        t.* = .Void;
                        node.resolved_type = t;
                        return t;
                    }
                    if (scope.lookup(name)) |_| {
                        t.* = .{ .Custom = name };
                        node.resolved_type = t;
                        return t;
                    }
                } else if (c.callee.data == .get_expr) {
                    // Method call return type inference
                    // For now, we assume the method returns the object type or Void
                    // In a complete compiler, we would look up the method signature
                    t.* = .Void;
                    if (c.callee.data.get_expr.object.resolved_type) |rt| {
                        t.* = rt.*;
                    }
                } else {
                    t.* = .Void;
                }
            },
            .block => |b| {
                return try self.checkBlock(b.statements, scope);
            },
            .while_stmt => |w| {
                const cond_type = try self.inferNode(w.condition, scope);
                if (cond_type.* != .Bool) {
                    self.reportError(node.line, node.column, "TypeError: while condition must be Bool, found {}.", .{cond_type.*});
                    return error.TypeError;
                }
                _ = try self.inferNode(w.body, scope);
                t.* = .Void;
            },
            .return_stmt => |r| {
                if (r.value) |v| {
                    return try self.inferNode(v, scope);
                }
                t.* = .Void;
            },
            .get_expr => |g| {
                const obj_type = try self.inferNode(g.object, scope);
                if (isNullable(obj_type) and !g.is_safe) {
                    self.reportError(node.line, node.column, "TypeError: Only safe (?.) or non-null asserted (!!.) calls are allowed on a nullable receiver of type {}.", .{obj_type.*});
                    return error.TypeError;
                }
                
                if (isNullable(obj_type) and g.is_safe) {
                    t.* = .{ .Union = .{
                        .left = try self.allocator.create(AetherType),
                        .right = try self.allocator.create(AetherType),
                    } };
                    @constCast(t.Union.left).* = .String; // Assume String for properties in v0.1
                    @constCast(t.Union.right).* = .Null;
                } else {
                    t.* = .String; // Assume String for properties in v0.1
                }
            },
            .set_expr => |s| {
                const obj_type = try self.inferNode(s.object, scope);
                if (isNullable(obj_type) and !s.is_safe) {
                    self.reportError(node.line, node.column, "TypeError: Only safe (?.) or non-null asserted (!!.) calls are allowed on a nullable receiver of type {}.", .{obj_type.*});
                    return error.TypeError;
                }
                const value_type = try self.inferNode(s.value, scope);
                // In v0.1, properties are assumed to be String
                const prop_type = try self.allocator.create(AetherType);
                prop_type.* = .String;
                if (!isCompatible(prop_type, value_type)) {
                    self.reportError(node.line, node.column, "TypeError: Cannot assign {} to property.", .{value_type.*});
                    return error.TypeError;
                }
                t.* = .Void;
            },
            .if_expr => |i| {
                const cond_type = try self.inferNode(i.condition, scope);
                if (cond_type.* != .Bool) {
                    self.reportError(node.line, node.column, "TypeError: if condition must be Bool, found {}.", .{cond_type.*});
                    return error.TypeError;
                }
                
                const then_type = try self.inferNode(i.then_branch, scope);
                if (i.else_branch) |eb| {
                    const else_type = try self.inferNode(eb, scope);
                    if (isCompatible(then_type, else_type)) {
                        t.* = then_type.*;
                    } else {
                        t.* = .{ .Union = .{ .left = then_type, .right = else_type } };
                    }
                } else {
                    t.* = .Void;
                }
            },
        }
        node.resolved_type = t;
        return t;
    }
};

test "TypeChecker detects type mismatch" {
    const source = 
        \\fun main() {
        \\    var a: Int = "Hello"
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    
    var parser = parser_mod.Parser.init(arena.allocator(), source);
    const ast_root = try parser.parse();
    
    var checker = TypeChecker.init(arena.allocator(), source, "test.kt");
    defer checker.deinit();
    
    const result = checker.validate(ast_root);
    try std.testing.expectError(error.TypeError, result);
}
