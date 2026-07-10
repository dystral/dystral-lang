const std = @import("std");
const type_system = @import("type_system.zig");

/// Token types supported by the Aether compiler.
pub const TokenType = enum {
    // Keywords
    kw_val,
    kw_var,
    kw_fun,
    kw_class,
    kw_override,
    kw_operator,
    kw_null,
    kw_if,
    kw_else,
    kw_return,
    kw_while,
    kw_import,
    kw_from,
    kw_test,
    kw_lib,
    kw_in,
    kw_for,

    // Symbols and Operators
    eq,         // =
    pipe,       // |
    l_paren,    // (
    r_paren,    // )
    l_brace,    // {
    r_brace,    // }
    l_bracket,  // [
    r_bracket,  // ]
    at,         // @
    colon,      // :
    comma,      // ,
    dot,        // .
    question,   // ?
    question_dot, // ?.
    elvis,      // ?:
    bang_bang,  // !!
    plus,       // +
    minus,      // -
    star,       // *
    slash,      // /
    eq_eq,      // ==
    bang,       // !
    bang_eq,    // !=
    less,       // <
    greater,    // >
    less_eq,    // <=
    greater_eq, // >=
    and_and,    // &&
    or_or,      // ||

    // Identifiers and Literals
    identifier,
    string_literal,
    int_literal,
    bool_literal,

    eof,
};

/// Structure representing an individual token read by the Lexer.
pub const Token = struct {
    token_type: TokenType,
    lexeme: []const u8,
    line: usize,
    column: usize,
};

pub const Annotation = struct {
    name: []const u8,
    arguments: []const []const u8,
};

/// Auxiliary structures for the AST
pub const Param = struct {
    name: []const u8,
    type_name: ?[]const u8,
    type_is_nullable: bool,
};

pub const ClassProp = struct {
    is_mut: bool,
    name: []const u8,
    type_name: []const u8,
    type_is_nullable: bool,
};

pub const ASTNode = struct {
    line: usize,
    column: usize,
    resolved_type: ?*const type_system.AetherType = null,
    data: ASTNodeType,
};

/// Native Zig Union Type (Tagged Union) representing an AST node's data.
pub const ASTNodeType = union(enum) {
    program: struct {
        statements: []const *ASTNode,
    },
    import_stmt: struct {
        module_path: []const u8,
        destructured: []const []const u8,
        module_ast: ?*ASTNode,
    },
    var_decl: struct {
        is_mut: bool,
        name: []const u8,
        type_name: ?[]const u8, // Optional due to inference
        type_is_nullable: bool,
        initializer: ?*ASTNode,
    },
    fun_decl: struct {
        modifiers: []const TokenType,
        name: []const u8,
        params: []Param,
        type_name: ?[]const u8,
        type_is_nullable: bool,
        body: *ASTNode,
        is_expr_body: bool, // true for `= a + b`, false for `{ ... }`
        resolved_c_name: ?[]const u8,
    },
    class_decl: struct {
        annotations: []const Annotation,
        name: []const u8,
        primary_constructor: []ClassProp,
        methods: []const *ASTNode,
        resolved_c_name: ?[]const u8,
    },
    test_decl: struct {
        name: []const u8,
        body: *ASTNode,
    },
    lib_decl: struct {
        annotations: []const Annotation,
        name: []const u8,
        functions: []const *ASTNode,
    },
    
    // Literals
    int_literal: i64,
    string_literal: []const u8,
    bool_literal: bool,
    array_literal: struct {
        elements: []const *ASTNode,
    },
    null_literal: void,
    
    // Identifiers
    identifier: struct {
        name: []const u8,
        resolved_c_name: ?[]const u8,
        is_class_property: bool = false,
    },

    // Expressions
    unary_expr: struct {
        operator: TokenType,
        operand: *ASTNode,
    },
    binary_expr: struct {
        left: *ASTNode,
        op: TokenType,
        right: *ASTNode,
    },
    call_expr: struct {
        callee: *ASTNode,
        arguments: []const *ASTNode,
    },
    if_expr: struct {
        condition: *ASTNode,
        then_branch: *ASTNode,
        else_branch: ?*ASTNode,
    },
    index_expr: struct {
        object: *ASTNode,
        index: *ASTNode,
    },
    assignment: struct {
        name: []const u8,
        value: *ASTNode,
    },
    get_expr: struct {
        object: *ASTNode,
        name: []const u8,
        is_safe: bool,
    },
    set_expr: struct {
        object: *ASTNode,
        name: []const u8,
        value: *ASTNode,
        is_safe: bool,
    },
    block: struct {
        statements: []const *ASTNode,
    },
    while_stmt: struct {
        condition: *ASTNode,
        body: *ASTNode,
    },
    for_stmt: struct {
        item_name: []const u8,
        iterable: *ASTNode,
        body: *ASTNode,
    },
    return_stmt: struct {
        value: ?*ASTNode,
    },
};

test "ASTNode Tagged Union size check" {
    // A simple test to ensure the tagged union works properly
    try std.testing.expect(@sizeOf(ASTNodeType) > 0);
    
    const literal = ASTNodeType{ .int_literal = 42 };
    try std.testing.expect(literal.int_literal == 42);
    
    switch (literal) {
        .int_literal => |val| try std.testing.expect(val == 42),
        else => unreachable,
    }
}
