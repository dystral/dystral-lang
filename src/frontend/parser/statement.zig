const std = @import("std");
const ast = @import("../../core/ast.zig");
const ASTNode = ast.ASTNode;
const TokenType = ast.TokenType;
const Parser = @import("core.zig").Parser;

pub fn whileStatement(self: *Parser) anyerror!*ASTNode {
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

pub fn returnStatement(self: *Parser) anyerror!*ASTNode {
    const line = self.previous.line;
    const col = self.previous.column;
    var value: ?*ASTNode = null;
    if (!self.check(.r_brace) and !self.check(.eof)) {
        value = try self.expression();
    }
    
    return try self.createNodeAt(.{ .return_stmt = .{ .value = value } }, line, col);
}
