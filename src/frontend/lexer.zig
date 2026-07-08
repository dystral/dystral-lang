const std = @import("std");
const ast = @import("../core/ast.zig");
const Token = ast.Token;
const TokenType = ast.TokenType;

/// The Lexer is responsible for tokenizing the source code.
/// It reads raw characters and converts them into a stream of structured Tokens.
pub const Lexer = struct {
    source: []const u8,
    start: usize,
    current: usize,
    line: usize,
    column: usize,

    /// Initializes a new Lexer instance.
    /// Does not allocate memory directly; uses slices of the provided source.
    pub fn init(source: []const u8) Lexer {
        return Lexer{
            .source = source,
            .start = 0,
            .current = 0,
            .line = 1,
            .column = 1,
        };
    }

    /// Reads and returns the next token from the source code.
    /// Handles skipping whitespace and advancing pointers automatically.
    pub fn scanToken(self: *Lexer) Token {
        self.skipWhitespace();

        self.start = self.current;

        if (self.isAtEnd()) return self.makeToken(.eof);

        const c = self.advance();

        if (isAlpha(c)) return self.identifier();
        if (isDigit(c)) return self.number();

        return switch (c) {
            '(' => self.makeToken(.l_paren),
            ')' => self.makeToken(.r_paren),
            '{' => self.makeToken(.l_brace),
            '}' => self.makeToken(.r_brace),
            ',' => self.makeToken(.comma),
            '.' => self.makeToken(.dot),
            ':' => self.makeToken(.colon),
            '+' => self.makeToken(.plus),
            '-' => self.makeToken(.minus),
            '*' => self.makeToken(.star),
            '/' => self.makeToken(.slash),
            '=' => self.makeToken(if (self.match('=')) .eq_eq else .eq),
            '!' => self.makeToken(if (self.match('=')) .bang_eq else if (self.match('!')) .bang_bang else .eof),
            '<' => self.makeToken(if (self.match('=')) .less_eq else .less),
            '>' => self.makeToken(if (self.match('=')) .greater_eq else .greater),
            '&' => self.makeToken(if (self.match('&')) .and_and else .eof),
            '|' => self.makeToken(if (self.match('|')) .or_or else .pipe),
            '?' => self.makeToken(if (self.match('.')) .question_dot else if (self.match(':')) .elvis else .question),
            '"' => self.string(),
            else => self.makeToken(.eof), // Simple error, in practice we should have an error token
        };
    }

    fn identifier(self: *Lexer) Token {
        while (!self.isAtEnd() and (isAlpha(self.peek()) or isDigit(self.peek()))) {
            _ = self.advance();
        }

        const text = self.source[self.start..self.current];
        const token_type = self.identifierType(text);
        return self.makeToken(token_type);
    }

    fn identifierType(_: *Lexer, text: []const u8) TokenType {
        if (std.mem.eql(u8, text, "val")) return .kw_val;
        if (std.mem.eql(u8, text, "var")) return .kw_var;
        if (std.mem.eql(u8, text, "fun")) return .kw_fun;
        if (std.mem.eql(u8, text, "class")) return .kw_class;
        if (std.mem.eql(u8, text, "override")) return .kw_override;
        if (std.mem.eql(u8, text, "operator")) return .kw_operator;
        if (std.mem.eql(u8, text, "null")) return .kw_null;
        if (std.mem.eql(u8, text, "if")) return .kw_if;
        if (std.mem.eql(u8, text, "else")) return .kw_else;
        if (std.mem.eql(u8, text, "return")) return .kw_return;
        if (std.mem.eql(u8, text, "while")) return .kw_while;
        if (std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "false")) return .bool_literal;
        return .identifier;
    }

    fn number(self: *Lexer) Token {
        while (!self.isAtEnd() and isDigit(self.peek())) {
            _ = self.advance();
        }
        return self.makeToken(.int_literal);
    }

    fn string(self: *Lexer) Token {
        while (!self.isAtEnd() and self.peek() != '"') {
            if (self.peek() == '\n') {
                self.line += 1;
                self.column = 1;
            }
            _ = self.advance();
        }

        if (self.isAtEnd()) return self.makeToken(.eof); // Unterminated string error

        // Closing quote.
        _ = self.advance();
        return self.makeToken(.string_literal);
    }

    fn skipWhitespace(self: *Lexer) void {
        while (!self.isAtEnd()) {
            const c = self.peek();
            switch (c) {
                ' ', '\r', '\t' => {
                    _ = self.advance();
                },
                '\n' => {
                    self.line += 1;
                    self.column = 1;
                    _ = self.advance();
                },
                '/' => {
                    if (self.peekNext() == '/') {
                        while (!self.isAtEnd() and self.peek() != '\n') {
                            _ = self.advance();
                        }
                    } else {
                        return;
                    }
                },
                else => return,
            }
        }
    }

    fn isAtEnd(self: *Lexer) bool {
        return self.current >= self.source.len;
    }

    fn advance(self: *Lexer) u8 {
        self.current += 1;
        self.column += 1;
        return self.source[self.current - 1];
    }

    fn peek(self: *Lexer) u8 {
        if (self.isAtEnd()) return 0;
        return self.source[self.current];
    }

    fn peekNext(self: *Lexer) u8 {
        if (self.current + 1 >= self.source.len) return 0;
        return self.source[self.current + 1];
    }

    fn match(self: *Lexer, expected: u8) bool {
        if (self.isAtEnd()) return false;
        if (self.source[self.current] != expected) return false;
        self.current += 1;
        self.column += 1;
        return true;
    }

    fn makeToken(self: *Lexer, token_type: TokenType) Token {
        return Token{
            .token_type = token_type,
            .lexeme = self.source[self.start..self.current],
            .line = self.line,
            .column = if (self.column > (self.current - self.start)) 
                self.column - (self.current - self.start) 
            else 
                1,
        };
    }
};

fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

test "Lexer base cases" {
    const source = 
        \\val nome = "Leo"
        \\fun somar(a, b) = a + b
    ;
    
    var lexer = Lexer.init(source);
    
    try std.testing.expectEqual(TokenType.kw_val, lexer.scanToken().token_type);
    try std.testing.expectEqual(TokenType.identifier, lexer.scanToken().token_type);
    try std.testing.expectEqual(TokenType.eq, lexer.scanToken().token_type);
    try std.testing.expectEqual(TokenType.string_literal, lexer.scanToken().token_type);
    
    try std.testing.expectEqual(TokenType.kw_fun, lexer.scanToken().token_type);
    try std.testing.expectEqual(TokenType.identifier, lexer.scanToken().token_type);
    try std.testing.expectEqual(TokenType.l_paren, lexer.scanToken().token_type);
    try std.testing.expectEqual(TokenType.identifier, lexer.scanToken().token_type);
    try std.testing.expectEqual(TokenType.comma, lexer.scanToken().token_type);
    try std.testing.expectEqual(TokenType.identifier, lexer.scanToken().token_type);
    try std.testing.expectEqual(TokenType.r_paren, lexer.scanToken().token_type);
    try std.testing.expectEqual(TokenType.eq, lexer.scanToken().token_type);
    try std.testing.expectEqual(TokenType.identifier, lexer.scanToken().token_type);
    try std.testing.expectEqual(TokenType.plus, lexer.scanToken().token_type);
    try std.testing.expectEqual(TokenType.identifier, lexer.scanToken().token_type);
    
    try std.testing.expectEqual(TokenType.eof, lexer.scanToken().token_type);
}
