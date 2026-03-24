package vm

import "core:strconv"
import "core:fmt"

LOCAL_MAX :: int(max(u8)) + 1

Parser :: struct {
    current:    Token,
    previous:   Token,
    had_error:  bool,
    panic_mode: bool,
    scanner:    Scanner,
    compiler:   ^Compiler,
    vm:         ^VM,
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

ParseProc :: #type proc(parser: ^Parser, can_assign: bool)

ParseRule :: struct {
    prefix: ParseProc,
    infix: ParseProc,
    precedence: Precedence,
}

Local :: struct {
    name: Token,
    depth: int,
}

Compiler :: struct {
    function: ^Function,
    locals: [LOCAL_MAX]Local,
    local_count: int,
    scope_depth: int,
}

compile :: proc(vm: ^VM, source: string, fn: ^Function) -> bool {
    compiler: Compiler
    compiler.function = fn

    parser: Parser
    scanner_init(&parser.scanner, source)

    parser.vm = vm
    parser.compiler = &compiler

    advance(&parser)
    
    for !match(&parser, .Eof) {
        declaration(&parser)
    }

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
check :: #force_inline proc(parser: ^Parser, type: TokenType) -> bool {
    return parser.current.type == type
}

@(private="file")
match :: proc(parser: ^Parser, type: TokenType) -> bool {
    if !check(parser, type) do return false
    advance(parser)
    return true
}

@(private="file")
emit_byte :: proc(parser: ^Parser , byte: u8) {
    function_write(parser.compiler.function, byte, parser.previous.line)
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
    constant := function_add_constant(parser.compiler.function, value)

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
            disassemble_function(parser.compiler.function, "code")
        }
    }
}

@(private="file")
begin_scope :: proc(parser: ^Parser) {
    parser.compiler.scope_depth += 1
}

@(private="file")
end_scope :: proc(parser: ^Parser) {
    current := parser.compiler

    current.scope_depth -= 1

    for current.local_count > 0 && current.locals[current.local_count - 1].depth > current.scope_depth {
        emit_byte(parser, u8(Opcode.Pop))
        current.local_count -= 1
    }
}

@(private="file")
binary :: proc(parser: ^Parser, can_assign: bool) {
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
parse_literal :: proc(parser: ^Parser, can_assign: bool) {
    #partial switch parser.previous.type {
        case .False: emit_byte(parser, u8(Opcode.False))
        case .Nil:   emit_byte(parser, u8(Opcode.Nil))
        case .True:  emit_byte(parser, u8(Opcode.True))
    }
}

@(private="file")
grouping :: proc(parser: ^Parser, can_assign: bool) {
    expression(parser)
    consume(parser, .RightParen, "Expect ')' after expression.")
}

@(private="file")
parse_number :: proc(parser: ^Parser, can_assign: bool) {
    value, _ := strconv.parse_f64(parser.previous.lexeme)
    emit_constant(parser, Value(value))
}

@(private="file")
parse_string :: proc(parser: ^Parser, can_assign: bool) {
    value := copy_string(parser.vm, parser.previous.lexeme[1 : len(parser.previous.lexeme) - 1])
    emit_constant(parser, Value(cast(^Object)value))
}

named_variable :: proc(parser: ^Parser, name: ^Token, can_assign: bool) {
    arg := resolve_local(parser, name)
    is_local := arg != -1

    if !is_local {
        arg = int(identifier_constant(parser, name))
    }

    if can_assign && match(parser, .Equal) {
        expression(parser)
        if is_local do emit_bytes(parser, u8(Opcode.SetLocal), u8(arg))
        else        do emit_short(parser, .SetGlobal, u16(arg))
    } else {
        if is_local do emit_bytes(parser, u8(Opcode.GetLocal), u8(arg))
        else        do emit_short(parser, .GetGlobal, u16(arg))
    }
}

@(private="file")
variable :: proc(parser: ^Parser, can_assign: bool) {
    named_variable(parser, &parser.previous, can_assign)
}

@(private="file")
unary :: proc(parser: ^Parser, can_assign: bool) {
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
    .Identifier   = {variable, nil, .None},
    .String       = {parse_string, nil, .None},
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

    can_assign := precedence <= .Assignment
    prefix_rule(parser, can_assign)

    for precedence <= rules[parser.current.type].precedence {
        advance(parser)
        infix_rule := rules[parser.previous.type].infix
        infix_rule(parser, can_assign)
    }

    if can_assign && match(parser, .Equal) {
        error(parser, "Invalid assignment target.")
    }
}

@(private="file")
identifier_constant :: proc(parser: ^Parser, name: ^Token) -> u16 {
    return make_constant(parser, val_obj(copy_string(parser.vm, name.lexeme)))
}

@(private="file")
resolve_local :: proc(parser: ^Parser, name: ^Token) -> int {
    for i := parser.compiler.local_count -1; i >= 0; i -= 1 {
        local := &parser.compiler.locals[i]
        if name.lexeme == local.name.lexeme {
            if local.depth == -1 {
                error(parser, "Can't read local variable in its own initializer.")
            }
            return i
        }
    }

    return -1
}

@(private="file")
declare_variable :: proc(parser: ^Parser) {
    if parser.compiler.scope_depth == 0 do return

    name := parser.previous

    for i := parser.compiler.local_count - 1; i >= 0; i -= 1 {
        local := parser.compiler.locals[i]
        if local.depth != -1 && local.depth < parser.compiler.scope_depth {
            break
        }

        if name.lexeme == local.name.lexeme {
            error(parser, "Already a variable with this name in this scope.")
        }
    }

    add_local(parser, name)
}

@(private="file")
add_local :: proc(parser: ^Parser, name: Token) {
    if parser.compiler.local_count == int(max(u8)) {
        error(parser, "Too many local variables in function.")
        return
    }

    local := &parser.compiler.locals[parser.compiler.local_count]
    local.name = name
    local.depth = -1
    parser.compiler.local_count += 1
}

@(private="file")
parse_variable :: proc(parser: ^Parser, error_mesage: string) -> u16 {
    consume(parser, .Identifier, error_mesage)

    declare_variable(parser)
    if parser.compiler.scope_depth > 0 do return 0

    return identifier_constant(parser, &parser.previous)
}

@(private="file")
mark_initialized :: proc(parser: ^Parser) {
    parser.compiler.locals[parser.compiler.local_count - 1].depth = parser.compiler.scope_depth
}

@(private="file")
define_variable :: proc(parser: ^Parser, global: u16) {
    if parser.compiler.scope_depth > 0 {
        mark_initialized(parser)
        return
    }

    emit_short(parser, .DefineGlobal, global)
}

@(private="file")
expression :: proc(parser: ^Parser) {
    parse_precedence(parser, .Assignment)
}

@(private="file")
block :: proc(parser: ^Parser) {
    for !check(parser, .RightBrace) && !check(parser, .Eof) {
        declaration(parser)
    }

    consume(parser, .RightBrace, "Expect '}' after block.")
}

@(private="file")
var_declaration :: proc(parser: ^Parser) {
    global := parse_variable(parser, "Expect variable name.")

    if match(parser, .Equal) {
        expression(parser)
    } else {
        emit_byte(parser, u8(Opcode.Nil))
    }
    consume(parser, .Semicolon, "Expect ';' after variable declaration.")

    define_variable(parser, global)
}

@(private="file")
expression_statement :: proc(parser: ^Parser) {
    expression(parser)
    consume(parser, .Semicolon, "Expect ';' after expression.")
    emit_byte(parser, u8(Opcode.Pop))
}

@(private="file")
print_statement :: proc(parser: ^Parser) {
    expression(parser)
    consume(parser, .Semicolon, "Expect ';' after value.")
    emit_byte(parser, u8(Opcode.Print))
}

@(private="file")
synchronize :: proc(parser: ^Parser) {
    parser.panic_mode = false

    for parser.current.type != .Eof {
        if parser.previous.type == .Semicolon do return

        #partial switch parser.current.type {
            case .Class, .Fn, .Var, .For, .If, .While, .Print, .Return:  return
        }

        advance(parser)
    }
}

@(private="file")
declaration :: proc(parser: ^Parser) {
    if match(parser, .Var) {
        var_declaration(parser)
    } else {
        statement(parser)
    }

    if parser.panic_mode do synchronize(parser)
}

@(private="file")
statement :: proc(parser: ^Parser) {
    if match(parser, .Print) {
        print_statement(parser)
    } else if match(parser, .LeftBrace) {
        begin_scope(parser)
        block(parser)
        end_scope(parser)
    } else {
        expression_statement(parser)
    }
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