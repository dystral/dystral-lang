const std = @import("std");
const ast = @import("../core/ast.zig");
const lexer = @import("lexer.zig");

const Lexer = lexer.Lexer;
const Token = ast.Token;
const TokenType = ast.TokenType;
const ASTNode = ast.ASTNode;
const ASTNodeType = ast.ASTNodeType;
const Param = ast.Param;

/// Recursive Descent Parser for the Aether language.
const ParsedType = struct {
    name: ?[]const u8,
    is_nullable: bool,
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    lexer: Lexer,
    current: Token,
    previous: Token,
    had_error: bool,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Parser {
        var p = Parser{
            .allocator = allocator,
            .lexer = Lexer.init(source),
            .current = undefined,
            .previous = undefined,
            .had_error = false,
        };
        p.advance();
        return p;
    }

    fn parseTypeAnnotation(self: *Parser) anyerror!ParsedType {
        if (self.match(.colon)) {
            try self.consume(.identifier, "Expected type name.");
            const name = self.previous.lexeme;
            var is_nullable = false;
            
            if (self.match(.question)) {
                is_nullable = true;
            } else if (self.match(.pipe)) {
                try self.consume(.kw_null, "Expected 'null' after '|'.");
                is_nullable = true;
            }
            return ParsedType{ .name = name, .is_nullable = is_nullable };
        }
        return ParsedType{ .name = null, .is_nullable = false };
    }

    fn createNode(self: *Parser, data: ASTNodeType) !*ASTNode {
        const node = try self.allocator.create(ASTNode);
        node.* = .{
            .line = self.previous.line,
            .column = self.previous.column,
            .data = data,
        };
        return node;
    }
    
    // For binary/left-associative nodes where previous might be advanced past the start
    // we can still just use `createNode` because line/column precision is mostly for the operator
    // but a better approach is to pass line/col explicitly if needed. For now `previous` (the operator) is fine.
    fn createNodeAt(self: *Parser, data: ASTNodeType, line: usize, col: usize) !*ASTNode {
        const node = try self.allocator.create(ASTNode);
        node.* = .{
            .line = line,
            .column = col,
            .data = data,
        };
        return node;
    }

    pub fn parse(self: *Parser) anyerror!*ASTNode {
        var statements = std.ArrayList(*ASTNode).init(self.allocator);
        defer statements.deinit();

        while (!self.check(.eof)) {
            const stmt = try self.declaration();
            try statements.append(stmt);
        }

        return try self.createNode(.{ .program = .{ .statements = try statements.toOwnedSlice() } });
    }

    fn declaration(self: *Parser) anyerror!*ASTNode {
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
        if (self.match(.kw_while)) return try self.whileStatement();
        if (self.match(.kw_return)) return try self.returnStatement();
        return try self.expression();
    }

    fn varDeclaration(self: *Parser, is_mut: bool) anyerror!*ASTNode {
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

    fn importDeclaration(self: *Parser) anyerror!*ASTNode {
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
        const path = path_with_quotes[1 .. path_with_quotes.len - 1]; // Remove as aspas
        
        return try self.createNodeAt(.{ .import_stmt = .{
            .module_path = path,
            .destructured = try destructured.toOwnedSlice(),
            .module_ast = null,
        } }, line, col);
    }

    fn funDeclaration(self: *Parser, modifiers: []const TokenType) anyerror!*ASTNode {
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

    fn classDeclaration(self: *Parser) anyerror!*ASTNode {
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

    fn expression(self: *Parser) anyerror!*ASTNode {
        return try self.assignment();
    }

    fn assignment(self: *Parser) anyerror!*ASTNode {
        const expr = try self.elvis();

        if (self.match(.eq)) {
            const line = self.previous.line;
            const col = self.previous.column;
            
            const value = try self.assignment();

            if (expr.data == .identifier) {
                const name = expr.data.identifier.name;
                return try self.createNodeAt(.{ .assignment = .{ .name = name, .value = value } }, line, col);
            } else if (expr.data == .get_expr) {
                return try self.createNodeAt(.{ .set_expr = .{ 
                    .object = expr.data.get_expr.object, 
                    .name = expr.data.get_expr.name, 
                    .is_safe = expr.data.get_expr.is_safe,
                    .value = value 
                } }, line, col);
            }

            self.errorAtCurrent("Invalid assignment target.");
        }

        return expr;
    }

    fn elvis(self: *Parser) anyerror!*ASTNode {
        var expr = try self.logicOr();

        while (self.match(.elvis)) {
            const op = self.previous.token_type;
            const line = self.previous.line;
            const col = self.previous.column;
            const right = try self.logicOr();
            expr = try self.createNodeAt(.{ .binary_expr = .{ .left = expr, .op = op, .right = right } }, line, col);
        }
        return expr;
    }

    fn logicOr(self: *Parser) anyerror!*ASTNode {
        var expr = try self.logicAnd();

        while (self.match(.or_or)) {
            const op = self.previous.token_type;
            const line = self.previous.line;
            const col = self.previous.column;
            const right = try self.logicAnd();
            expr = try self.createNodeAt(.{ .binary_expr = .{ .left = expr, .op = op, .right = right } }, line, col);
        }
        return expr;
    }

    fn logicAnd(self: *Parser) anyerror!*ASTNode {
        var expr = try self.equality();

        while (self.match(.and_and)) {
            const op = self.previous.token_type;
            const line = self.previous.line;
            const col = self.previous.column;
            const right = try self.equality();
            expr = try self.createNodeAt(.{ .binary_expr = .{ .left = expr, .op = op, .right = right } }, line, col);
        }
        return expr;
    }

    fn equality(self: *Parser) anyerror!*ASTNode {
        var expr = try self.comparison();

        while (self.match(.eq_eq) or self.match(.bang_eq)) {
            const op = self.previous.token_type;
            const line = self.previous.line;
            const col = self.previous.column;
            const right = try self.comparison();
            expr = try self.createNodeAt(.{ .binary_expr = .{ .left = expr, .op = op, .right = right } }, line, col);
        }
        return expr;
    }

    fn comparison(self: *Parser) anyerror!*ASTNode {
        var expr = try self.term();

        while (self.match(.greater) or self.match(.greater_eq) or self.match(.less) or self.match(.less_eq)) {
            const op = self.previous.token_type;
            const line = self.previous.line;
            const col = self.previous.column;
            const right = try self.term();
            expr = try self.createNodeAt(.{ .binary_expr = .{ .left = expr, .op = op, .right = right } }, line, col);
        }
        return expr;
    }

    fn term(self: *Parser) anyerror!*ASTNode {
        var expr = try self.factor();

        while (self.match(.minus) or self.match(.plus)) {
            const op = self.previous.token_type;
            const line = self.previous.line;
            const col = self.previous.column;
            const right = try self.factor();
            expr = try self.createNodeAt(.{ .binary_expr = .{ .left = expr, .op = op, .right = right } }, line, col);
        }
        return expr;
    }

    fn factor(self: *Parser) anyerror!*ASTNode {
        var expr = try self.call();

        while (self.match(.slash) or self.match(.star)) {
            const op = self.previous.token_type;
            const line = self.previous.line;
            const col = self.previous.column;
            const right = try self.call();
            expr = try self.createNodeAt(.{ .binary_expr = .{ .left = expr, .op = op, .right = right } }, line, col);
        }
        return expr;
    }

    fn call(self: *Parser) anyerror!*ASTNode {
        var expr = try self.primary();

        while (true) {
            if (self.match(.l_paren)) {
                expr = try self.finishCall(expr);
            } else if (self.match(.dot) or self.match(.question_dot)) {
                const is_safe = self.previous.token_type == .question_dot;
                try self.consume(.identifier, "Expected property name.");
                const name = self.previous.lexeme;
                expr = try self.createNode(.{ .get_expr = .{ .object = expr, .name = name, .is_safe = is_safe } });
            } else if (self.match(.bang_bang)) {
                expr = try self.createNode(.{ .unary_expr = .{ .operator = .bang_bang, .operand = expr } });
            } else {
                break;
            }
        }

        return expr;
    }

    fn finishCall(self: *Parser, callee: *ASTNode) anyerror!*ASTNode {
        const line = self.previous.line;
        const col = self.previous.column;
        var args = std.ArrayList(*ASTNode).init(self.allocator);
        if (!self.check(.r_paren)) {
            while (true) {
                try args.append(try self.expression());
                if (!self.match(.comma)) break;
            }
        }
        try self.consume(.r_paren, "Expected ')' after arguments.");
        return try self.createNodeAt(.{ .call_expr = .{ .callee = callee, .arguments = try args.toOwnedSlice() } }, line, col);
    }

    fn whileStatement(self: *Parser) anyerror!*ASTNode {
        const line = self.previous.line;
        const col = self.previous.column;
        try self.consume(.l_paren, "Expected '(' after 'while'.");
        const condition = try self.expression();
        try self.consume(.r_paren, "Expected ')' after condition.");
        
        var body: *ASTNode = undefined;
        if (self.match(.l_brace)) {
            var stmts = std.ArrayList(*ASTNode).init(self.allocator);
            while (!self.check(.r_brace) and !self.check(.eof)) {
                try stmts.append(try self.declaration());
            }
            try self.consume(.r_brace, "Expected '}'.");
            body = try self.createNode(.{ .block = .{ .statements = try stmts.toOwnedSlice() } });
        } else {
            body = try self.expression();
        }

        return try self.createNodeAt(.{ .while_stmt = .{ .condition = condition, .body = body } }, line, col);
    }

    fn returnStatement(self: *Parser) anyerror!*ASTNode {
        const line = self.previous.line;
        const col = self.previous.column;
        var value: ?*ASTNode = null;
        if (!self.check(.r_brace) and !self.check(.eof)) {
            value = try self.expression();
        }
        
        return try self.createNodeAt(.{ .return_stmt = .{ .value = value } }, line, col);
    }

    fn primary(self: *Parser) anyerror!*ASTNode {
        const line = self.current.line;
        const col = self.current.column;
        
        if (self.match(.kw_null)) {
            return try self.createNode(.{ .null_literal = {} });
        }

        if (self.match(.kw_if)) {
            try self.consume(.l_paren, "Expected '(' after 'if'.");
            const condition = try self.expression();
            try self.consume(.r_paren, "Expected ')' after condition.");
            
            var then_branch: *ASTNode = undefined;
            if (self.match(.l_brace)) {
                var stmts = std.ArrayList(*ASTNode).init(self.allocator);
                while (!self.check(.r_brace) and !self.check(.eof)) {
                    try stmts.append(try self.declaration());
                }
                try self.consume(.r_brace, "Expected '}'.");
                then_branch = try self.createNode(.{ .block = .{ .statements = try stmts.toOwnedSlice() } });
            } else {
                then_branch = try self.expression();
            }
            
            var else_branch: ?*ASTNode = null;
            if (self.match(.kw_else)) {
                if (self.match(.l_brace)) {
                    var stmts = std.ArrayList(*ASTNode).init(self.allocator);
                    while (!self.check(.r_brace) and !self.check(.eof)) {
                        try stmts.append(try self.declaration());
                    }
                    try self.consume(.r_brace, "Expected '}'.");
                    else_branch = try self.createNode(.{ .block = .{ .statements = try stmts.toOwnedSlice() } });
                } else {
                    else_branch = try self.expression();
                }
            }
            return try self.createNodeAt(.{ .if_expr = .{ .condition = condition, .then_branch = then_branch, .else_branch = else_branch } }, line, col);
        }
        
        if (self.match(.bool_literal)) {
            return try self.createNodeAt(.{ .bool_literal = std.mem.eql(u8, self.previous.lexeme, "true") }, line, col);
        }
        
        if (self.match(.int_literal)) {
            const value = try std.fmt.parseInt(i64, self.previous.lexeme, 10);
            return try self.createNodeAt(.{ .int_literal = value }, line, col);
        }
        if (self.match(.string_literal)) {
            const lexeme = self.previous.lexeme;
            const value = lexeme[1 .. lexeme.len - 1];
            return try self.createNodeAt(.{ .string_literal = value }, line, col);
        }
        if (self.match(.identifier)) {
            return try self.createNodeAt(.{ .identifier = .{
                .name = self.previous.lexeme,
                .resolved_c_name = null,
            } }, line, col);
        }

        self.errorAtCurrent("Expected expression.");
        return error.ParseError;
    }

    fn advance(self: *Parser) void {
        self.previous = self.current;
        while (true) {
            self.current = self.lexer.scanToken();
            if (self.current.token_type != .eof) break; 
            break;
        }
    }

    fn match(self: *Parser, token_type: TokenType) bool {
        if (self.check(token_type)) {
            self.advance();
            return true;
        }
        return false;
    }

    fn check(self: *Parser, token_type: TokenType) bool {
        return self.current.token_type == token_type;
    }

    fn consume(self: *Parser, token_type: TokenType, message: []const u8) anyerror!void {
        if (self.check(token_type)) {
            self.advance();
            return;
        }
        self.errorAtCurrent(message);
        return error.ParseError;
    }

    fn errorAtCurrent(self: *Parser, message: []const u8) void {
        std.debug.print("Error at line {}, column {}: {s}\n", .{self.current.line, self.current.column, message});
        self.had_error = true;
    }
};

test "Parser base cases" {
    const source = 
        \\val nome = "Leo"
        \\fun somar(a, b) = a + b
    ;
    
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    
    var parser = Parser.init(arena.allocator(), source);
    const ast_root = try parser.parse();
    
    try std.testing.expectEqual(ASTNodeType.program, std.meta.activeTag(ast_root.data));
    try std.testing.expectEqual(@as(usize, 2), ast_root.data.program.statements.len);
    
    const stmt1 = ast_root.data.program.statements[0];
    try std.testing.expectEqual(ASTNodeType.var_decl, std.meta.activeTag(stmt1.data));
    try std.testing.expectEqualStrings("nome", stmt1.data.var_decl.name);
    
    const stmt2 = ast_root.data.program.statements[1];
    try std.testing.expectEqual(ASTNodeType.fun_decl, std.meta.activeTag(stmt2.data));
    try std.testing.expectEqualStrings("somar", stmt2.data.fun_decl.name);
    try std.testing.expectEqual(@as(usize, 2), stmt2.data.fun_decl.params.len);
}
