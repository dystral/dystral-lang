const std = @import("std");
const ast = @import("../../core/ast.zig");
const lexer = @import("../lexer.zig");

pub const Lexer = lexer.Lexer;
pub const Token = ast.Token;
pub const TokenType = ast.TokenType;
pub const ASTNode = ast.ASTNode;
pub const ASTNodeType = ast.ASTNodeType;
pub const Param = ast.Param;

pub const ParsedType = struct {
    name: ?[]const u8,
    is_nullable: bool,
};

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

    pub const expression = expression_mod.expression;
    pub const assignment = expression_mod.assignment;
    pub const elvis = expression_mod.elvis;
    pub const logicOr = expression_mod.logicOr;
    pub const logicAnd = expression_mod.logicAnd;
    pub const equality = expression_mod.equality;
    pub const ofOperator = expression_mod.ofOperator;
    pub const comparison = expression_mod.comparison;
    pub const term = expression_mod.term;
    pub const factor = expression_mod.factor;
    pub const unary = expression_mod.unary;
    pub const call = expression_mod.call;
    pub const finishCall = expression_mod.finishCall;
    pub const primary = expression_mod.primary;

    pub const whileStatement = statement_mod.whileStatement;
    pub const forStatement = statement_mod.forStatement;
    pub const returnStatement = statement_mod.returnStatement;

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

fn core_parseTypeAnnotation(self: *Parser) anyerror!ParsedType {
    if (self.match(.colon)) {
        return try core_parseType(self);
    }
    return ParsedType{ .name = null, .is_nullable = false };
}

fn core_parseType(self: *Parser) anyerror!ParsedType {
    var name: []const u8 = undefined;
    if (self.match(.l_bracket)) {
        const inner = try core_parseType(self);
        try self.consume(.r_bracket, "Expected ']' after array type.");
        
        var inner_str = inner.name.?;
        if (inner.is_nullable) {
            inner_str = try std.fmt.allocPrint(self.allocator, "{s}?", .{inner.name.?});
        }
        
        name = try std.fmt.allocPrint(self.allocator, "[{s}]", .{inner_str});
    } else {
        try self.consume(.identifier, "Expected type name.");
        name = self.previous.lexeme;
        
        if (self.match(.less)) {
            const generic_arg1 = try core_parseType(self);
            
            var gen_str = generic_arg1.name.?;
            if (generic_arg1.is_nullable) {
                gen_str = try std.fmt.allocPrint(self.allocator, "{s}?", .{generic_arg1.name.?});
            }
            
            if (self.match(.comma)) {
                const generic_arg2 = try core_parseType(self);
                var gen_str2 = generic_arg2.name.?;
                if (generic_arg2.is_nullable) {
                    gen_str2 = try std.fmt.allocPrint(self.allocator, "{s}?", .{generic_arg2.name.?});
                }
                
                try self.consume(.greater, "Expected '>' after generic type arguments.");
                name = try std.fmt.allocPrint(self.allocator, "{s}<{s}, {s}>", .{name, gen_str, gen_str2});
            } else {
                try self.consume(.greater, "Expected '>' after generic type argument.");
                name = try std.fmt.allocPrint(self.allocator, "{s}<{s}>", .{name, gen_str});
            }
        }
    }
    
    var is_nullable = false;
    if (self.match(.question)) {
        is_nullable = true;
    } else if (self.match(.pipe)) {
        if (self.match(.kw_null)) {
            is_nullable = true;
        } else if (self.match(.identifier)) {
            if (std.mem.eql(u8, self.previous.lexeme, "Null")) {
                is_nullable = true;
            } else {
                self.errorAtCurrent("Expected 'null' or 'Null' after '|'.");
                return error.ParseError;
            }
        } else {
            self.errorAtCurrent("Expected 'null' or 'Null' after '|'.");
            return error.ParseError;
        }
    }
    return ParsedType{ .name = name, .is_nullable = is_nullable };
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
        if (self.current.token_type != .eof) break; 
        break;
    }
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
