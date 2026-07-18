const std = @import("std");
const ast = @import("../ast.zig");
const core = @import("core.zig");
const type_system = @import("../type_system.zig");

const ASTNode = core.ASTNode;
const TypeChecker = core.TypeChecker;
const Scope = core.Scope;
const AetherType = core.AetherType;

pub fn inferArrayLiteral(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *AetherType) anyerror!void {
    const a = node.data.array_literal;
    if (a.elements.len == 0) {
        if (node.expected_type) |expected| {
            const expected_base = type_system.extractBaseType(expected);
            if (expected_base.* == .Array or expected_base.* == .Custom) {
                t.* = expected_base.*;
                return;
            }
        }
        self.reportError(node.line, node.column, "TypeError: Cannot infer type of empty array literal.", .{});
        return error.TypeError;
    }
    
    const first_type = try self.inferNode(a.elements[0], scope);
    for (a.elements[1..]) |elem| {
        const elem_type = try self.inferNode(elem, scope);
        if (!self.isCompatible(first_type, elem_type)) {
            self.reportError(node.line, node.column, "TypeError: Incompatible types in array literal. Expected {} but found {}.", .{ first_type.*, elem_type.* });
            return error.TypeError;
        }
    }
    const array_type = try self.allocator.create(AetherType);
    array_type.* = .{ .Array = first_type };
    
    // Simulate List<T> instantiation
    const list_c_name = self.alias_map.get("List") orelse "List";
    const class_node = self.classes_ast.get(list_c_name);
    if (class_node == null) {
        self.reportError(node.line, node.column, "TypeError: Class 'List' not found for array literal.", .{});
        return error.TypeError;
    }
    const class_decl = class_node.?.data.class_decl;
    var type_args = try self.allocator.alloc(*const AetherType, 1);
    type_args[0] = first_type;
    
    // O mangled name deve ser baseado no nome importado (list_c_name), nao string "List"
    var mangled = std.ArrayList(u8).init(self.allocator);
    try mangled.appendSlice(list_c_name);
    try mangled.appendSlice("_");
    try first_type.formatSafe(mangled.writer());
    const mangled_name = try mangled.toOwnedSlice();
    try self.monomorphizeClass(class_decl.name, type_args, mangled_name);
    
    t.* = .{ .Custom = self.alias_map.get(mangled_name) orelse mangled_name };
}

pub fn inferMapLiteral(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *AetherType) anyerror!void {
    const m = node.data.map_literal;
    if (m.elements.len == 0) {
        self.reportError(node.line, node.column, "TypeError: Cannot infer type of empty map literal.", .{});
        return error.TypeError;
    }
    
    // Evaluate the first pair
    var first_key_type: *const AetherType = undefined;
    var first_value_type: *const AetherType = undefined;
    
    for (m.elements, 0..) |elem, i| {
        // Element is a `.kw_of` binary expression. Let's infer it, which transforms it into a Node constructor.
        _ = try self.inferNode(elem, scope);
        
        // At this point elem is a call_expr to Node<K, V>
        if (elem.data != .call_expr) {
            self.reportError(elem.line, elem.column, "TypeError: Map literal elements must be 'of' pairs.", .{});
            return error.TypeError;
        }
        
        const k_type = elem.data.call_expr.arguments[0].resolved_type.?;
        const v_type = elem.data.call_expr.arguments[1].resolved_type.?;
        
        if (i == 0) {
            first_key_type = k_type;
            first_value_type = v_type;
        } else {
            if (!self.isCompatible(first_key_type, k_type) or !self.isCompatible(first_value_type, v_type)) {
                self.reportError(elem.line, elem.column, "TypeError: Incompatible types in map literal.", .{});
                return error.TypeError;
            }
        }
    }
    
    // Simulate Map instantiation
    const node_base = self.alias_map.get("Node") orelse "Node";
    const mmap_base = self.alias_map.get("MutableMap") orelse "MutableMap";
    const map_base = self.alias_map.get("Map") orelse "Map";

    var map_mangled_str = std.ArrayList(u8).init(self.allocator);
    try map_mangled_str.appendSlice(map_base);
    try map_mangled_str.appendSlice("_");
    try first_key_type.formatSafe(map_mangled_str.writer());
    try map_mangled_str.appendSlice("_");
    try first_value_type.formatSafe(map_mangled_str.writer());
    const mangled_name = try map_mangled_str.toOwnedSlice();
    
    var node_mangled_str = std.ArrayList(u8).init(self.allocator);
    try node_mangled_str.appendSlice(node_base);
    try node_mangled_str.appendSlice("_");
    try first_key_type.formatSafe(node_mangled_str.writer());
    try node_mangled_str.appendSlice("_");
    try first_value_type.formatSafe(node_mangled_str.writer());
    const node_mangled = try node_mangled_str.toOwnedSlice();
    
    var mmap_mangled_str = std.ArrayList(u8).init(self.allocator);
    try mmap_mangled_str.appendSlice(mmap_base);
    try mmap_mangled_str.appendSlice("_");
    try first_key_type.formatSafe(mmap_mangled_str.writer());
    try mmap_mangled_str.appendSlice("_");
    try first_value_type.formatSafe(mmap_mangled_str.writer());
    const mmap_mangled = try mmap_mangled_str.toOwnedSlice();
    
    var type_args = try self.allocator.alloc(*const AetherType, 2);
    type_args[0] = first_key_type;
    type_args[1] = first_value_type;
    
    if (self.classes_ast.get(node_base) == null or self.classes_ast.get(mmap_base) == null or self.classes_ast.get(map_base) == null) {
        self.reportError(node.line, node.column, "TypeError: Required Map classes not found.", .{});
        return error.TypeError;
    }
    
    try self.monomorphizeClass(node_base, type_args, node_mangled);
    try self.monomorphizeClass(mmap_base, type_args, mmap_mangled);
    try self.monomorphizeClass(map_base, type_args, mangled_name);
    
    t.* = .{ .Custom = self.alias_map.get(mangled_name) orelse mangled_name };
}
