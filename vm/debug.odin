package vm

import "core:fmt"

disassemble_chunk :: proc(chunk: ^Chunk, name: string) {
    fmt.printfln("== %s ==", name)

    offset := 0
    for offset < len(chunk.instructions) {
        offset = disassemble_instruction(chunk, offset)
    }
}

disassemble_instruction :: proc(chunk: ^Chunk, offset: int) -> int {
    fmt.printf("%04d ", offset)

    if line := chunk_get_line(chunk, offset); offset > 0 && line == chunk_get_line(chunk, offset - 1) {
        fmt.print("   | ")
    } else {
        fmt.printf("%4d ", line)
    }

    instruction := Opcode(chunk.instructions[offset])
    switch instruction {
        case .Constant, .GetGlobal, .DefineGlobal, .SetGlobal:
            return constant_instruction(instruction, chunk, offset)
        case .Nil, .True, .False, .Pop, .Equal, .Greater, .Less, .Add, .Sub, .Mul, .Div, .Not, .Negate, .Print, .Return:
            return simple_instruction(instruction, offset)
        case .SetLocal, .GetLocal, .Call:
            return byte_instruction(instruction, chunk, offset)
        case .Loop:
            return jump_instruction(instruction, -1, chunk, offset)
        case .Jump, .JumpIfFalse:
            return jump_instruction(instruction, 1, chunk, offset)
        case:
            fmt.printfln("Unknown opcode %v", instruction)
            return offset + 1
    }
}

@(private="file")
constant_instruction :: proc(op: Opcode, chunk: ^Chunk, offset: int) -> int {
    constant := u16(chunk.instructions[offset + 1]) | (u16(chunk.instructions[offset + 2]) << 8)
    fmt.printf("%-16v %4d '", op, constant)
    print_value(chunk.constants[constant])
    fmt.println("'")
    return offset + 3
}

@(private="file")
simple_instruction :: proc(op: Opcode, offset: int) -> int {
    fmt.printfln("%v", op)
    return offset + 1
}

@(private="file")
byte_instruction :: proc(op: Opcode, chunk: ^Chunk, offset: int) -> int {
    slot := chunk.instructions[offset + 1]
    fmt.printfln("%-16v %4d", op, slot)
    return offset + 2
}

@(private="file")
jump_instruction :: proc(op: Opcode, sign: int, chunk: ^Chunk, offset: int) -> int {
    jump := u16(chunk.instructions[offset + 1]) | (u16(chunk.instructions[offset + 2]) << 8)
    target := offset + 3 + sign * int(jump)
    fmt.printfln("%-16v %4d -> %d", op, offset, target)
    return offset + 3
}