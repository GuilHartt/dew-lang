package vm

@(private) Run :: struct {
    count: int,
    line:  i32,
}

Function :: struct {
    instructions: [dynamic]u8,
    lines: [dynamic]Run,
    constants: [dynamic]Value,
}

function_write :: proc(fn: ^Function, byte: u8, line: i32) {
    append(&fn.instructions, byte)
    
    if n := len(fn.lines); n > 0 && fn.lines[n - 1].line == line {
        fn.lines[n - 1].count += 1
    } else {
        append(&fn.lines, Run{count = 1, line = line})
    }
}

function_free :: proc(fn: ^Function) {
    delete(fn.instructions)
    delete(fn.lines)
    delete(fn.constants)
}

function_add_constant :: proc(fn: ^Function, value: Value) -> int {
    append(&fn.constants, value)
    return len(fn.constants) - 1
}

function_write_constant :: proc(fn: ^Function, value: Value, line: i32) {
    index := function_add_constant(fn, value)
    assert(index <= int(max(u16)), "Too many constants in one chunk.")

    function_write(fn, u8(Opcode.Constant), line)
    function_write(fn, u8(index & 0xFF), line)
    function_write(fn, u8((index >> 8) & 0xFF), line)
}

function_get_line :: proc(fn: ^Function, offset: int) -> i32 {
    if offset < 0 || offset >= len(fn.instructions) do return -1

    current := 0
    for run in fn.lines {
        current += run.count
        if offset < current do return run.line
    }

    return -1
}