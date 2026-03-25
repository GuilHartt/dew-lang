package vm

Scanner :: struct {
    source:  string,
    start:   int,
    current: int,
    line:    i32,
}

scanner_init :: proc(scanner: ^Scanner, source: string) {
    scanner.source  = source
    scanner.start   = 0
    scanner.current = 0
    scanner.line    = 1
}

@(private="file")
is_digit :: #force_inline proc(c: u8) -> bool {
    return c >= '0' && c <= '9'
}

@(private="file")
is_alpha :: #force_inline proc(c: u8) -> bool {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'
}

@(private)
scan_token :: proc(scanner: ^Scanner) -> Token {
    skip_whitespace(scanner)

    scanner.start =  scanner.current

    if is_at_end(scanner) do return make_token(scanner, .Eof)

    c := advance(scanner)
    if is_alpha(c) do return identifier(scanner)
    if is_digit(c) do return number_literal(scanner)

    switch c {
        case '(': return make_token(scanner, .LeftParen)
        case ')': return make_token(scanner, .RightParen)
        case '{': return make_token(scanner, .LeftBrace)
        case '}': return make_token(scanner, .RightBrace)
        case ';': return make_token(scanner, .Semicolon)
        case ',': return make_token(scanner, .Comma)
        case '.': return make_token(scanner, .Dot)
        case '-': return make_token(scanner, .Minus)
        case '+': return make_token(scanner, .Plus)
        case '/': return make_token(scanner, .Slash)
        case '*': return make_token(scanner, .Star)
        case '!': return make_token(scanner, match(scanner, '=') ? .BangEqual : .Bang)
        case '=': return make_token(scanner, match(scanner, '=') ? .EqualEqual : .Equal)
        case '<': return make_token(scanner, match(scanner, '=') ? .LessEqual : .Less)
        case '>': return make_token(scanner, match(scanner, '=') ? .GreaterEqual : .Greater)
        case '"': return string_literal(scanner)
    }

    return error_token(scanner, "Unexpected character.")
}

@(private="file")
is_at_end :: #force_inline proc(scanner: ^Scanner) -> bool  {
    return scanner.current >= len(scanner.source)
}

@(private="file")
advance :: #force_inline proc(scanner: ^Scanner) -> u8 {
    c := scanner.source[scanner.current]
    scanner.current += 1
    return c
}

@(private="file")
peek :: #force_inline proc(scanner: ^Scanner) -> u8 {
    if is_at_end(scanner) do return 0
    return scanner.source[scanner.current]
}

@(private="file")
peek_next :: #force_inline proc(scanner: ^Scanner) -> u8 {
    if scanner.current + 1 >= len(scanner.source) do return 0
    return scanner.source[scanner.current + 1]
}

@(private="file")
match :: #force_inline proc(scanner: ^Scanner, expected: u8) -> bool {
    if is_at_end(scanner) do return false
    if scanner.source[scanner.current] != expected do return false
    scanner.current += 1
    return true
}

@(private="file")
make_token :: proc(scanner: ^Scanner, type: TokenType) -> Token {
    return {type, scanner.source[scanner.start : scanner.current], scanner.line}
}

@(private="file")
error_token :: proc(scanner: ^Scanner, message: string) -> Token {
    return {.Error, message, scanner.line}
}

@(private="file")
skip_whitespace :: proc(scanner: ^Scanner) {
    for {
        c := peek(scanner)
        switch c {
            case ' ', '\r', '\t': advance(scanner)
            case '\n':
                scanner.line += 1
                advance(scanner)
            case '/':
                if peek_next(scanner) == '/' {
                    for peek(scanner) != '\n' && !is_at_end(scanner) do advance(scanner)
                } else {
                    return
                }
            case: return
        }
    }
}

@(private="file")
identifier_type :: proc(scanner: ^Scanner) -> TokenType {
    switch scanner.source[scanner.start : scanner.current] {
        case "and":    return .And
        case "class":  return .Class
        case "else":   return .Else
        case "false":  return .False
        case "for":    return .For
        case "chunk":     return .chunk
        case "if":     return .If 
        case "nil":    return .Nil
        case "or":     return .Or
        case "print":  return .Print
        case "return": return .Return
        case "super":  return .Super
        case "true":   return .True
        case "self":   return .Self
        case "var":    return .Var
        case "while":  return .While
        case:          return .Identifier
    }
}

@(private="file")
identifier :: proc(scanner: ^Scanner) -> Token {
    for is_alpha(peek(scanner)) || is_digit(peek(scanner)) do advance(scanner)
    return make_token(scanner, identifier_type(scanner))
}

@(private="file")
number_literal :: proc(scanner: ^Scanner) -> Token {
    for is_digit(peek(scanner)) do advance(scanner)

    if peek(scanner) == '.' && is_digit(peek_next(scanner)) {
        advance(scanner)
        for is_digit(peek(scanner)) do advance(scanner)
    }

    return make_token(scanner, .Number)
}

@(private="file")
string_literal :: proc(scanner: ^Scanner) -> Token {
    for peek(scanner) != '"' && !is_at_end(scanner) {
        if peek(scanner) == '\n' do scanner.line += 1
        advance(scanner)
    }

    if is_at_end(scanner) do return error_token(scanner, "Unterminated string.")

    advance(scanner)
    return make_token(scanner, .String)
}   