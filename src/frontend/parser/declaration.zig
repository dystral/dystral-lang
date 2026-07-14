const std = @import("std");
const ast = @import("../../core/ast.zig");
const ASTNode = ast.ASTNode;
const TokenType = ast.TokenType;
const Param = ast.Param;
const Parser = @import("core.zig").Parser;

pub fn declaration(self: *Parser) anyerror!*ASTNode {
    const annotations = try self.parseAnnotations();
    var modifiers = std.ArrayList(TokenType).init(self.allocator);
    
    while (self.match(.kw_override) or self.match(.kw_operator) or self.match(.kw_open)) {
        try modifiers.append(self.previous.token_type);
    }
    
    if (self.match(.kw_lib)) return try self.libDeclaration(annotations);
    
    if (self.match(.kw_val)) {
        if (modifiers.items.len > 0) { self.errorAtCurrent("Modifiers not allowed on val"); return error.ParseError; }
        return try self.varDeclaration(false);
    }
    if (self.match(.kw_var)) {
        if (modifiers.items.len > 0) { self.errorAtCurrent("Modifiers not allowed on var"); return error.ParseError; }
        return try self.varDeclaration(true);
    }
    if (self.match(.kw_fun)) {
        return try self.funDeclaration(annotations, try modifiers.toOwnedSlice(), false);
    }
    if (self.match(.kw_class)) {
        var is_open = false;
        for (modifiers.items) |mod| {
            if (mod == .kw_open) {
                is_open = true;
            } else {
                self.errorAtCurrent("Modifier not allowed on class");
                return error.ParseError;
            }
        }
        return try self.classDeclaration(annotations, is_open);
    }
    
    if (modifiers.items.len > 0) {
        self.errorAtCurrent("Modifiers must precede a function declaration");
        return error.ParseError;
    }

    if (self.match(.kw_import)) return try self.importDeclaration();
    if (self.match(.kw_test)) return try self.testDeclaration();
    if (self.match(.kw_while)) return try self.whileStatement();
    if (self.match(.kw_for)) return try self.forStatement();
    if (self.match(.kw_return)) return try self.returnStatement();
    if (self.match(.kw_try)) return try self.tryStatement();
    if (self.match(.kw_throw)) return try self.throwStatement();
    return try self.expression();
}

pub fn parseAnnotations(self: *Parser) anyerror![]ast.Annotation {
    var annotations = std.ArrayList(ast.Annotation).init(self.allocator);
    while (self.match(.at)) {
        try self.consume(.identifier, "Expected annotation name after '@'.");
        const name = self.previous.lexeme;
        
        var arguments = std.ArrayList([]const u8).init(self.allocator);
        if (self.match(.l_paren)) {
            if (!self.check(.r_paren)) {
                while (true) {
                    try self.consume(.string_literal, "Expected string literal as annotation argument.");
                    const str_with_quotes = self.previous.lexeme;
                    const str = str_with_quotes[1 .. str_with_quotes.len - 1];
                    try arguments.append(str);
                    if (!self.match(.comma)) break;
                }
            }
            try self.consume(.r_paren, "Expected ')' after annotation arguments.");
        }
        try annotations.append(.{
            .name = name,
            .arguments = try arguments.toOwnedSlice(),
        });
    }
    return try annotations.toOwnedSlice();
}

pub fn libDeclaration(self: *Parser, annotations: []ast.Annotation) anyerror!*ASTNode {
    const line = self.previous.line;
    const col = self.previous.column;
    
    try self.consume(.identifier, "Expected lib name.");
    const name = self.previous.lexeme;
    
    try self.consume(.l_brace, "Expected '{' before lib body.");
    var functions = std.ArrayList(*ASTNode).init(self.allocator);
    while (!self.check(.r_brace) and !self.check(.eof)) {
        const fun_annotations = try self.parseAnnotations();
        if (self.match(.kw_fun)) {
            const func = try self.funDeclaration(fun_annotations, &[_]TokenType{}, true);
            try functions.append(func);
        } else {
            self.errorAtCurrent("Only functions are allowed inside 'lib' blocks.");
            return error.ParseError;
        }
    }
    try self.consume(.r_brace, "Expected '}' after lib body.");
    
    return try self.createNodeAt(.{ .lib_decl = .{
        .annotations = annotations,
        .name = name,
        .functions = try functions.toOwnedSlice(),
    } }, line, col);
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
        .type_ref = parsed_type,
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

pub fn funDeclaration(self: *Parser, annotations: []const ast.Annotation, modifiers: []const TokenType, allow_no_body: bool) anyerror!*ASTNode {
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
            
            var initializer: ?*ASTNode = null;
            if (self.match(.eq)) {
                initializer = try self.expression();
            }

            try params.append(.{ 
                .name = param_name, 
                .type_ref = parsed_type,
                .initializer = initializer,
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
    } else if (allow_no_body) {
        body = try self.createNode(.{ .block = .{ .statements = &[_]*ASTNode{} } });
    } else {
        self.errorAtCurrent("Invalid function body.");
        return error.ParseError;
    }

    return try self.createNodeAt(.{ .fun_decl = .{
        .annotations = annotations,
        .modifiers = modifiers,
        .name = name,
        .params = try params.toOwnedSlice(),
        .type_ref = parsed_ret,
        .body = body,
        .is_expr_body = is_expr,
        .resolved_c_name = null,
    }}, line, col);
}

pub fn classDeclaration(self: *Parser, annotations: []ast.Annotation, is_open: bool) anyerror!*ASTNode {
    const line = self.previous.line;
    const col = self.previous.column;
    
    try self.consume(.identifier, "Expected class name.");
    const name = self.previous.lexeme;
    
    var generic_params = std.ArrayList([]const u8).init(self.allocator);
    if (self.match(.less)) {
        if (!self.check(.greater)) {
            while (true) {
                try self.consume(.identifier, "Expected generic parameter name.");
                try generic_params.append(self.previous.lexeme);
                if (!self.match(.comma)) break;
            }
        }
        try self.consume(.greater, "Expected '>' after generic parameters.");
    }
    
    var props = std.ArrayList(ast.ClassProp).init(self.allocator);
    if (self.match(.l_paren)) {
        if (!self.check(.r_paren)) {
            while (true) {
                var is_property = true;
                var is_mut = false;
                if (self.match(.kw_var)) {
                    is_mut = true;
                } else if (self.match(.kw_val)) {
                    is_mut = false;
                } else {
                    is_property = false;
                }
                
                try self.consume(.identifier, "Expected parameter or property name.");
                const prop_name = self.previous.lexeme;
                
                const parsed_type = try self.parseTypeAnnotation() orelse {
                    self.errorAtCurrent("Expected parameter or property type.");
                    return error.ParseError;
                };
                
                var initializer: ?*ASTNode = null;
                if (self.match(.eq)) {
                    initializer = try self.expression();
                }

                try props.append(.{
                    .is_mut = is_mut,
                    .name = prop_name,
                    .type_ref = parsed_type,
                    .is_property = is_property,
                    .initializer = initializer,
                });
                
                if (!self.match(.comma)) break;
            }
        }
        try self.consume(.r_paren, "Expected ')' after class primary constructor.");
    }
    
    var superclass_name: ?[]const u8 = null;
    var superclass_args = std.ArrayList(*ASTNode).init(self.allocator);
    if (self.match(.colon)) {
        try self.consume(.identifier, "Expected superclass name after ':'.");
        superclass_name = self.previous.lexeme;
        
        try self.consume(.l_paren, "Expected '(' for superclass constructor arguments.");
        if (!self.check(.r_paren)) {
            while (true) {
                try superclass_args.append(try self.expression());
                if (!self.match(.comma)) break;
            }
        }
        try self.consume(.r_paren, "Expected ')' after superclass arguments.");
    }
    
    var methods = std.ArrayList(*ASTNode).init(self.allocator);
    if (self.match(.l_brace)) {
        while (!self.check(.r_brace) and !self.check(.eof)) {
            var modifiers = std.ArrayList(TokenType).init(self.allocator);
            while (self.match(.kw_override) or self.match(.kw_operator) or self.match(.kw_open)) {
                try modifiers.append(self.previous.token_type);
            }
            
            if (self.match(.kw_fun)) {
                try methods.append(try self.funDeclaration(&[_]ast.Annotation{}, try modifiers.toOwnedSlice(), false));
            } else {
                self.errorAtCurrent("Only methods are currently supported inside classes.");
                return error.ParseError;
            }
        }
        try self.consume(.r_brace, "Expected '}' after class body.");
    }
    
    return try self.createNodeAt(.{ .class_decl = .{
        .annotations = annotations,
        .name = name,
        .generic_params = try generic_params.toOwnedSlice(),
        .primary_constructor = try props.toOwnedSlice(),
        .methods = try methods.toOwnedSlice(),
        .resolved_c_name = null,
        .is_open = is_open,
        .superclass_name = superclass_name,
        .superclass_args = try superclass_args.toOwnedSlice(),
    } }, line, col);
}
