const std = @import("std");
const ast = @import("../../core/ast.zig");
const ASTNode = ast.ASTNode;
const TokenType = ast.TokenType;
const Param = ast.Param;
const Parser = @import("core.zig").Parser;

pub fn declaration(self: *Parser) anyerror!*ASTNode {
    var modifiers = std.ArrayList(TokenType).init(self.allocator);
    
    while (self.match(.kw_override) or self.match(.kw_operator)) {
        try modifiers.append(self.previous.token_type);
    }
    
    if (self.match(.kw_val)) {
        if (modifiers.items.len > 0) { self.errorAtCurrent("Modifiers not allowed on val"); return error.ParseError; }
        return try self.varDeclaration(false);
    }
    if (self.match(.kw_var)) {
        if (modifiers.items.len > 0) { self.errorAtCurrent("Modifiers not allowed on var"); return error.ParseError; }
        return try self.varDeclaration(true);
    }
    if (self.match(.kw_fun)) return try self.funDeclaration(try modifiers.toOwnedSlice());
    if (self.match(.kw_class)) {
        if (modifiers.items.len > 0) { self.errorAtCurrent("Modifiers not allowed on class"); return error.ParseError; }
        return try self.classDeclaration();
    }
    
    if (modifiers.items.len > 0) {
        self.errorAtCurrent("Modifiers must precede a function declaration");
        return error.ParseError;
    }

    if (self.match(.kw_import)) return try self.importDeclaration();
    if (self.match(.kw_test)) return try self.testDeclaration();
    if (self.match(.kw_while)) return try self.whileStatement();
    if (self.match(.kw_return)) return try self.returnStatement();
    return try self.expression();
}

pub fn varDeclaration(self: *Parser, is_mut: bool) anyerror!*ASTNode {
    const line = self.previous.line;
    const col = self.previous.column;
    
    try self.consume(.identifier, "Expected variable name.");
    const name = self.previous.lexeme;

    const parsed_type = try self.parseTypeAnnotation();

    var initializer: ?*ASTNode = null;
    if (self.match(.eq)) {
        initializer = try self.expression();
    }

    return try self.createNodeAt(.{ .var_decl = .{
        .is_mut = is_mut,
        .name = name,
        .type_name = parsed_type.name,
        .type_is_nullable = parsed_type.is_nullable,
        .initializer = initializer,
    } }, line, col);
}

pub fn testDeclaration(self: *Parser) anyerror!*ASTNode {
    const line = self.previous.line;
    const col = self.previous.column;

    try self.consume(.string_literal, "Expected test description string.");
    
    var name = self.previous.lexeme;
    if (name.len >= 2 and name[0] == '"' and name[name.len - 1] == '"') {
        name = name[1 .. name.len - 1];
    }

    try self.consume(.l_brace, "Expected '{' before test body.");
    var stmts = std.ArrayList(*ASTNode).init(self.allocator);
    while (!self.check(.r_brace) and !self.check(.eof)) {
        try stmts.append(try self.declaration());
    }
    try self.consume(.r_brace, "Expected '}' after block.");
    const body = try self.createNode(.{ .block = .{ .statements = try stmts.toOwnedSlice() } });

    return try self.createNodeAt(.{ .test_decl = .{
        .name = name,
        .body = body,
    } }, line, col);
}

pub fn importDeclaration(self: *Parser) anyerror!*ASTNode {
    const line = self.previous.line;
    const col = self.previous.column;
    
    try self.consume(.l_brace, "Expected '{' after import.");
    
    var destructured = std.ArrayList([]const u8).init(self.allocator);
    
    if (!self.check(.r_brace)) {
        while (true) {
            try self.consume(.identifier, "Expected identifier in import list.");
            try destructured.append(self.previous.lexeme);
            if (!self.match(.comma)) break;
        }
    }
    
    try self.consume(.r_brace, "Expected '}' after import list.");
    try self.consume(.kw_from, "Expected 'from' after import list.");
    try self.consume(.string_literal, "Expected module path string.");
    
    const path_with_quotes = self.previous.lexeme;
    const path = path_with_quotes[1 .. path_with_quotes.len - 1];
    
    return try self.createNodeAt(.{ .import_stmt = .{
        .module_path = path,
        .destructured = try destructured.toOwnedSlice(),
        .module_ast = null,
    } }, line, col);
}

pub fn funDeclaration(self: *Parser, modifiers: []const TokenType) anyerror!*ASTNode {
    const line = self.previous.line;
    const col = self.previous.column;
    
    try self.consume(.identifier, "Expected function name.");
    const name = self.previous.lexeme;

    try self.consume(.l_paren, "Expected '(' after function name.");
    var params = std.ArrayList(Param).init(self.allocator);
    
    if (!self.check(.r_paren)) {
        while (true) {
            try self.consume(.identifier, "Expected parameter name.");
            const param_name = self.previous.lexeme;
            const parsed_type = try self.parseTypeAnnotation();
            
            try params.append(.{ 
                .name = param_name, 
                .type_name = parsed_type.name,
                .type_is_nullable = parsed_type.is_nullable,
            });
            
            if (!self.match(.comma)) break;
        }
    }
    try self.consume(.r_paren, "Expected ')' after parameters.");

    const parsed_ret = try self.parseTypeAnnotation();

    var body: *ASTNode = undefined;
    var is_expr = false;

    if (self.match(.eq)) {
        body = try self.expression();
        is_expr = true;
    } else if (self.match(.l_brace)) {
        var stmts = std.ArrayList(*ASTNode).init(self.allocator);
        while (!self.check(.r_brace) and !self.check(.eof)) {
            try stmts.append(try self.declaration());
        }
        try self.consume(.r_brace, "Expected '}' after block.");
        body = try self.createNode(.{ .block = .{ .statements = try stmts.toOwnedSlice() } });
    } else {
        self.errorAtCurrent("Invalid function body.");
        return error.ParseError;
    }

    return try self.createNodeAt(.{ .fun_decl = .{
        .modifiers = modifiers,
        .name = name,
        .params = try params.toOwnedSlice(),
        .type_name = parsed_ret.name,
        .type_is_nullable = parsed_ret.is_nullable,
        .body = body,
        .is_expr_body = is_expr,
        .resolved_c_name = null,
    }}, line, col);
}

pub fn classDeclaration(self: *Parser) anyerror!*ASTNode {
    const line = self.previous.line;
    const col = self.previous.column;
    
    try self.consume(.identifier, "Expected class name.");
    const name = self.previous.lexeme;
    
    var props = std.ArrayList(ast.ClassProp).init(self.allocator);
    if (self.match(.l_paren)) {
        if (!self.check(.r_paren)) {
            while (true) {
                const is_mut = if (self.match(.kw_var)) true else if (self.match(.kw_val)) false else {
                    self.errorAtCurrent("Expected 'val' or 'var' for class property.");
                    return error.ParseError;
                };
                
                try self.consume(.identifier, "Expected property name.");
                const prop_name = self.previous.lexeme;
                
                const parsed_type = try self.parseTypeAnnotation();
                if (parsed_type.name == null) {
                    self.errorAtCurrent("Expected property type.");
                    return error.ParseError;
                }
                
                try props.append(.{
                    .is_mut = is_mut,
                    .name = prop_name,
                    .type_name = parsed_type.name.?,
                    .type_is_nullable = parsed_type.is_nullable,
                });
                
                if (!self.match(.comma)) break;
            }
        }
        try self.consume(.r_paren, "Expected ')' after class primary constructor.");
    }
    
    var methods = std.ArrayList(*ASTNode).init(self.allocator);
    if (self.match(.l_brace)) {
        while (!self.check(.r_brace) and !self.check(.eof)) {
            var modifiers = std.ArrayList(TokenType).init(self.allocator);
            while (self.match(.kw_override) or self.match(.kw_operator)) {
                try modifiers.append(self.previous.token_type);
            }
            
            if (self.match(.kw_fun)) {
                try methods.append(try self.funDeclaration(try modifiers.toOwnedSlice()));
            } else {
                self.errorAtCurrent("Only methods are currently supported inside classes.");
                return error.ParseError;
            }
        }
        try self.consume(.r_brace, "Expected '}' after class body.");
    }
    
    return try self.createNodeAt(.{ .class_decl = .{
        .name = name,
        .primary_constructor = try props.toOwnedSlice(),
        .methods = try methods.toOwnedSlice(),
        .resolved_c_name = null,
    }}, line, col);
}
