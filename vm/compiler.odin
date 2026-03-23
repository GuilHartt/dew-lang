package vm

import "core:strconv"
import "core:fmt"

Parser :: struct {
    scanner:            Scanner,
    compiling_function: ^Function,
    current:            Token,
    previous:           Token,
    had_error:          bool,
    panic_mode:         bool,
}

Precedence :: enum u8 {
    None,
    Assignment,
    Or,
    And,
    Equality,
    Comparison,
    Term,
    Factor,
    Unary,
    Call,
    Primary,
}

ParseProc :: #type proc(parser: ^Parser)

ParseRule :: struct {
    prefix: ParseProc,
    infix: ParseProc,
    precedence: Precedence,
}

compile :: proc(source: string, fn: ^Function) -> bool {
    parser: Parser
    scanner_init(&parser.scanner, source)

    parser.compiling_function = fn

    advance(&parser)
    expression(&parser)
    consume(&parser, .Eof, "Expect end of expression.")

    end_compiler(&parser)
    return !parser.had_error
}

@(private="file")
advance :: proc(parser: ^Parser) {
    parser.previous = parser.current

    for {
        parser.current = scan_token(&parser.scanner)
        if parser.current.type != .Error do break
        error_at_current(parser, parser.current.lexeme)
    }
}

@(private="file")
consume :: proc(parser: ^Parser, type: TokenType, message: string) {
    if parser.current.type == type {
        advance(parser)
        return
    }

    error_at_current(parser, message)
}

@(private="file")
emit_byte :: proc(parser: ^Parser , byte: u8) {
    function_write(parser.compiling_function, byte, parser.previous.line)
}

@(private="file")
emit_bytes :: proc(parser: ^Parser, byte1, byte2: u8) {
    emit_byte(parser, byte1)
    emit_byte(parser, byte2)
}

@(private="file")
emit_short :: proc(parser: ^Parser, opcode: Opcode, operand: u16) {
    emit_byte(parser, u8(opcode))
    emit_bytes(parser, u8(operand & 0xFF), u8((operand >> 8) & 0xFF))
}

@(private="file")
emit_return :: proc(parser: ^Parser) {
    emit_byte(parser, u8(Opcode.Return))
}

@(private="file")
make_constant :: proc(parser: ^Parser, value: Value) -> u16 {
    constant := function_add_constant(parser.compiling_function, value)

    if constant > int(max(u16)) {
        error(parser, "Too many constants in one chunk.")
        return 0
    }

    return u16(constant)
}

@(private="file")
emit_constant :: proc(parser: ^Parser, value: Value) {
    emit_short(parser, .Constant, make_constant(parser, value))
}

@(private="file")
end_compiler :: proc(parser: ^Parser) {
    emit_return(parser)
    when DEW_DEBUG_PRINT_CODE {
        if !parser.had_error {
            disassemble_function(parser.compiling_function, "code")
        }
    }
}

@(private="file")
binary :: proc(parser: ^Parser) {
    operator_type := parser.previous.type
    rule := &rules[operator_type]
    parse_precedence(parser, Precedence(int(rule.precedence) + 1))

    #partial switch operator_type {
        case .BangEqual:    emit_bytes(parser, u8(Opcode.Equal), u8(Opcode.Not))
        case .EqualEqual:   emit_byte(parser, u8(Opcode.Equal))
        case .Greater:      emit_byte(parser, u8(Opcode.Greater))
        case .GreaterEqual: emit_bytes(parser, u8(Opcode.Less), u8(Opcode.Not))
        case .Less:         emit_byte(parser, u8(Opcode.Less))
        case .LessEqual:    emit_bytes(parser, u8(Opcode.Greater), u8(Opcode.Not))
        case .Plus:         emit_byte(parser, u8(Opcode.Add))
        case .Minus:        emit_byte(parser, u8(Opcode.Sub))
        case .Star:         emit_byte(parser, u8(Opcode.Mul))
        case .Slash:        emit_byte(parser, u8(Opcode.Div))
    }
}

@(private="file")
parse_literal :: proc(parser: ^Parser) {
    #partial switch parser.previous.type {
        case .False: emit_byte(parser, u8(Opcode.False))
        case .Nil:   emit_byte(parser, u8(Opcode.Nil))
        case .True:  emit_byte(parser, u8(Opcode.True))
    }
}

@(private="file")
grouping :: proc(parser: ^Parser) {
    expression(parser)
    consume(parser, .RightParen, "Expect ')' after expression.")
}

@(private="file")
parse_number :: proc(parser: ^Parser) {
    value, _ := strconv.parse_f64(parser.previous.lexeme)
    emit_constant(parser, Value(value))
}

@(private="file")
unary :: proc(parser: ^Parser) {
    operator_type := parser.previous.type

    parse_precedence(parser, .Unary)

    #partial switch operator_type {
        case .Bang:  emit_byte(parser, u8(Opcode.Not))
        case .Minus: emit_byte(parser, u8(Opcode.Negate))
    }
}

@(private="file", rodata)
rules := #partial [TokenType]ParseRule{
    .LeftParen    = {grouping, nil, .None},
    .Minus        = {unary, binary, .Term},
    .Plus         = {nil, binary, .Term},
    .Slash        = {nil, binary, .Factor},
    .Star         = {nil, binary, .Factor},
    .Bang         = {unary, nil, .None},
    .BangEqual    = {nil, binary, .Equality},
    .EqualEqual   = {nil, binary, .Equality},
    .Greater      = {nil, binary, .Comparison},
    .GreaterEqual = {nil, binary, .Comparison},
    .Less         = {nil, binary, .Comparison},
    .LessEqual    = {nil, binary, .Comparison},
    .Number       = {parse_number, nil, .None},
    .False        = {parse_literal, nil, .None},
    .Nil          = {parse_literal, nil, .None},
    .True         = {parse_literal, nil, .None},
}

@(private="file")
parse_precedence :: proc(parser: ^Parser, precedence: Precedence) {
    advance(parser)

    prefix_rule := rules[parser.previous.type].prefix
    if prefix_rule == nil {
        error(parser, "Expect expression.")
        return
    }

    prefix_rule(parser)

    for precedence <= rules[parser.current.type].precedence {
        advance(parser)
        infix_rule := rules[parser.previous.type].infix
        infix_rule(parser)
    }
}

@(private="file")
expression :: proc(parser: ^Parser) {
    parse_precedence(parser, .Assignment)
}

@(private="file")
error_at :: proc(parser: ^Parser, token: ^Token, message: string) {
    if parser.panic_mode do return
    parser.panic_mode = true

    fmt.eprintf("[line %d] Error", token.line)

    if token.type == .Eof do fmt.eprintf(" at end")
    else if token.type != .Error {
        fmt.eprintf(" at '%s'", token.lexeme)
    }

    fmt.eprintfln(": %s", message)
    parser.had_error = true
}

@(private="file")
error :: proc(parser: ^Parser, message: string) {
    error_at(parser, &parser.previous, message)
}

@(private="file")
error_at_current :: proc(parser: ^Parser, message: string) {
    error_at(parser, &parser.current, message)
}