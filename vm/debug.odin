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
        case .Constant:
            return constant_instruction(instruction, fn, offset)
        case .Return:
            return simple_instruction(instruction, offset)
        case:
            fmt.printfln("Unknown opcode %v", instruction)
            return offset + 1
    }
}

constant_instruction :: proc(op: Opcode, fn: ^Function, offset: int) -> int {
    constant := fn.instructions[offset + 1]
    fmt.printf("%-16v %4d '", op, constant)
    print_value(fn.constants[constant])
    fmt.println("'")
    return offset + 2
}

simple_instruction :: proc(op: Opcode, offset: int) -> int {
    fmt.printfln("%v", op)
    return offset + 1
}