package vm

import "core:fmt"

disassemble_function :: proc(fn: ^Function, name: string) {
    fmt.printfln("== %s ==", name)

    offset := 0
    for offset < len(fn.instructions) {
        offset = disassemble_instruction(fn, offset)
    }
}

disassemble_instruction :: proc(fn: ^Function, offset: int) -> int {
    fmt.printf("%04d ", offset)

    if line := function_get_line(fn, offset); offset > 0 && line == function_get_line(fn, offset - 1) {
        fmt.print("   | ")
    } else {
        fmt.printf("%4d ", line)
    }

    instruction := Opcode(fn.instructions[offset])
    switch instruction {
        case .Constant, .GetGlobal, .DefineGlobal, .SetGlobal:
            return constant_instruction(instruction, fn, offset)
        case .Nil, .True, .False, .Pop, .Equal, .Greater, .Less, .Add, .Sub, .Mul, .Div, .Not, .Negate, .Print, .Return:
            return simple_instruction(instruction, offset)
        case .SetLocal, .GetLocal:
            return byte_instruction(instruction, fn, offset)
        case .Loop:
            return jump_instruction(instruction, -1, fn, offset)
        case .Jump, .JumpIfFalse:
            return jump_instruction(instruction, 1, fn, offset)
        case:
            fmt.printfln("Unknown opcode %v", instruction)
            return offset + 1
    }
}

@(private="file")
constant_instruction :: proc(op: Opcode, fn: ^Function, offset: int) -> int {
    constant := u16(fn.instructions[offset + 1]) | (u16(fn.instructions[offset + 2]) << 8)
    fmt.printf("%-16v %4d '", op, constant)
    print_value(fn.constants[constant])
    fmt.println("'")
    return offset + 3
}

@(private="file")
simple_instruction :: proc(op: Opcode, offset: int) -> int {
    fmt.printfln("%v", op)
    return offset + 1
}

@(private="file")
byte_instruction :: proc(op: Opcode, fn: ^Function, offset: int) -> int {
    slot := fn.instructions[offset + 1]
    fmt.printfln("%-16v %4d", op, slot)
    return offset + 2
}

@(private="file")
jump_instruction :: proc(op: Opcode, sign: int, fn: ^Function, offset: int) -> int {
    jump := u16(fn.instructions[offset + 1]) | (u16(fn.instructions[offset + 2]) << 8)
    target := offset + 3 + sign * int(jump)
    fmt.printfln("%-16v %4d -> %d", op, offset, target)
    return offset + 3
}