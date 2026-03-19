package vm

Function :: struct {
    instructions: [dynamic]u8,
    lines: [dynamic]i32,
    constants: [dynamic]Value,
}


function_write :: proc(fn: ^Function, byte: u8, line: i32) {
    append(&fn.instructions, byte)
    append(&fn.lines, line)
}

function_free :: proc(fn: ^Function) {
    delete(fn.instructions)
}

function_add_constant :: proc(fn: ^Function, value: Value) -> int {
    append(&fn.constants, value)
    return len(fn.constants) - 1
}