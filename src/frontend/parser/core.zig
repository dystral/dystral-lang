const std = @import("std");
const ast = @import("../../core/ast.zig");
const lexer = @import("../lexer.zig");

pub const Lexer = lexer.Lexer;
pub const Token = ast.Token;
pub const TokenType = ast.TokenType;
pub const ASTNode = ast.ASTNode;
pub const ASTNodeType = ast.ASTNodeType;
pub const Param = ast.Param;


pub const Parser = struct {
    allocator: std.mem.Allocator,
    lexer: Lexer,
    current: Token,
    previous: Token,
    had_error: bool,

    const expression_mod = @import("expression.zig");
    const statement_mod = @import("statement.zig");
    const declaration_mod = @import("declaration.zig");

    // Mixins
    pub const parse = core_parse;
    pub const createNode = core_createNode;
    pub const createNodeAt = core_createNodeAt;
    pub const advance = core_advance;
    pub const match = core_match;
    pub const check = core_check;
    pub const consume = core_consume;
    pub const errorAtCurrent = core_errorAtCurrent;
    pub const parseTypeAnnotation = core_parseTypeAnnotation;
    pub const parseType = core_parseType;
    pub const reportLexerError = core_reportLexerError;

    pub const expression = expression_mod.expression;
    pub const assignment = expression_mod.assignment;
    pub const ternary = expression_mod.ternary;
    pub const elvis = expression_mod.elvis;
    pub const logicOr = expression_mod.logicOr;
    pub const logicAnd = expression_mod.logicAnd;
    pub const equality = expression_mod.equality;
    pub const ofOperator = expression_mod.ofOperator;
    pub const comparison = expression_mod.comparison;
    pub const typeCheckOrCast = expression_mod.typeCheckOrCast;
    pub const term = expression_mod.term;
    pub const factor = expression_mod.factor;
    pub const unary = expression_mod.unary;
    pub const call = expression_mod.call;
    pub const finishCall = expression_mod.finishCall;
    pub const primary = expression_mod.primary;

    pub const whileStatement = statement_mod.whileStatement;
    pub const forStatement = statement_mod.forStatement;
    pub const returnStatement = statement_mod.returnStatement;
    pub const tryStatement = statement_mod.tryStatement;
    pub const throwStatement = statement_mod.throwStatement;

    pub const declaration = declaration_mod.declaration;
    pub const varDeclaration = declaration_mod.varDeclaration;
    pub const testDeclaration = declaration_mod.testDeclaration;
    pub const importDeclaration = declaration_mod.importDeclaration;
    pub const funDeclaration = declaration_mod.funDeclaration;
    pub const classDeclaration = declaration_mod.classDeclaration;
    pub const libDeclaration = declaration_mod.libDeclaration;
    pub const parseAnnotations = declaration_mod.parseAnnotations;

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
};

fn core_parseTypeAnnotation(self: *Parser) anyerror!?*const ast.ASTTypeRef {
    if (self.match(.colon)) {
        return try self.parseType();
    }
    return null;
}

fn core_parseType(self: *Parser) anyerror!*const ast.ASTTypeRef {
    var ref = try self.allocator.create(ast.ASTTypeRef);
    if (self.match(.l_bracket)) {
        const inner = try self.parseType();
        try self.consume(.r_bracket, "Expected ']' after array type.");
        
        ref.* = .{
            .name = "",
            .generic_args = &.{ inner },
            .is_array = true,
            .is_nullable = false,
        };
    } else {
        try self.consume(.identifier, "Expected type name.");
        const name = self.previous.lexeme;
        var generic_args = std.ArrayList(*const ast.ASTTypeRef).init(self.allocator);
        
        if (self.match(.less)) {
            while (true) {
                const arg = try self.parseType();
                try generic_args.append(arg);
                if (!self.match(.comma)) break;
            }
            try self.consume(.greater, "Expected '>' after generic type arguments.");
        }
        
        ref.* = .{
            .name = name,
            .generic_args = try generic_args.toOwnedSlice(),
            .is_array = false,
            .is_nullable = false,
        };
    }
    
    var is_nullable = false;
    if (self.match(.question)) {
        is_nullable = true;
    } else if (self.check(.pipe)) {
        var temp_lexer = self.lexer;
        const next_tok = temp_lexer.scanToken();
        const is_null_ref = next_tok.token_type == .kw_null or 
            (next_tok.token_type == .identifier and std.mem.eql(u8, next_tok.lexeme, "Null"));
        
        if (is_null_ref) {
            _ = self.match(.pipe);
            self.advance();
            is_nullable = true;
        }
    }
    
    ref.is_nullable = is_nullable;
    return ref;
}

fn core_createNode(self: *Parser, data: ASTNodeType) !*ASTNode {
    const node = try self.allocator.create(ASTNode);
    node.* = .{
        .line = self.previous.line,
        .column = self.previous.column,
        .data = data,
    };
    return node;
}

fn core_createNodeAt(self: *Parser, data: ASTNodeType, line: usize, col: usize) !*ASTNode {
    const node = try self.allocator.create(ASTNode);
    node.* = .{
        .line = line,
        .column = col,
        .data = data,
    };
    return node;
}

fn core_parse(self: *Parser) anyerror!*ASTNode {
    var statements = std.ArrayList(*ASTNode).init(self.allocator);
    defer statements.deinit();

    while (!self.check(.eof)) {
        const stmt = try self.declaration();
        try statements.append(stmt);
    }

    return try self.createNode(.{ .program = .{ .statements = try statements.toOwnedSlice() } });
}

fn core_advance(self: *Parser) void {
    self.previous = self.current;
    while (true) {
        self.current = self.lexer.scanToken();
        if (self.current.token_type == .invalid) {
            self.reportLexerError(self.current.line, self.current.column, "Syntax Error: Invalid or unrecognized character '{s}'", .{self.current.lexeme});
            self.current.token_type = .eof; // Force parser to stop parsing
            break;
        }
        if (self.current.token_type != .eof) break; 
        break;
    }
}

fn core_reportLexerError(self: *Parser, line: usize, column: usize, comptime message: []const u8, args: anytype) void {
    std.debug.print("\n\x1b[31mError\x1b[0m at line {}, column {}:\n", .{ line, column });

    var current_line: usize = 1;
    var start_idx: usize = 0;
    var end_idx: usize = 0;
    const src = self.lexer.source;

    while (end_idx < src.len) : (end_idx += 1) {
        if (src[end_idx] == '\n') {
            if (current_line == line) break;
            current_line += 1;
            start_idx = end_idx + 1;
        }
    }
    if (end_idx > src.len) end_idx = src.len;

    const line_str = src[start_idx..end_idx];
    std.debug.print("    {s}\n", .{line_str});

    std.debug.print("    ", .{});
    var i: usize = 1;
    while (i < column) : (i += 1) {
        std.debug.print(" ", .{});
    }
    std.debug.print("\x1b[31m^-- ", .{});
    std.debug.print(message, args);
    std.debug.print("\x1b[0m\n\n", .{});
    self.had_error = true;
}

fn core_match(self: *Parser, token_type: TokenType) bool {
    if (self.check(token_type)) {
        self.advance();
        return true;
    }
    return false;
}

fn core_check(self: *Parser, token_type: TokenType) bool {
    return self.current.token_type == token_type;
}

fn core_consume(self: *Parser, token_type: TokenType, message: []const u8) anyerror!void {
    if (self.check(token_type)) {
        self.advance();
        return;
    }
    self.errorAtCurrent(message);
    return error.ParseError;
}

fn core_errorAtCurrent(self: *Parser, message: []const u8) void {
    std.debug.print("Error at line {}, column {}: {s}\n", .{self.current.line, self.current.column, message});
    self.had_error = true;
}
