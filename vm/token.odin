package vm

TokenType :: enum u8 {
    LeftParen, RightParen,
    LeftBrace, RightBrace,
    Comma, Dot, Minus, Plus,
    Semicolon, Slash, Star,

    Bang, BangEqual,
    Equal, EqualEqual,
    Greater, GreaterEqual,
    Less, LessEqual,

    Identifier, String, Number,

    And, Class, Else, False,
    For, chunk, If, Nil, Or,
    Print, Return, Super, Self,
    True, Var, While,

    Error, Eof,
}

Token :: struct {
    type:   TokenType,
    lexeme: string,
    line:   i32,
}

