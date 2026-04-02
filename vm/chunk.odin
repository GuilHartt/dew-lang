package vm

@(private)
Run :: struct {
	count: int,
	line:  i32,
}

Chunk :: struct {
	instructions: [dynamic]u8,
	lines:        [dynamic]Run,
	constants:    [dynamic]Value,
}

chunk_write :: proc(chunk: ^Chunk, byte: u8, line: i32) {
	append(&chunk.instructions, byte)

	if n := len(chunk.lines); n > 0 && chunk.lines[n - 1].line == line {
		chunk.lines[n - 1].count += 1
	} else {
		append(&chunk.lines, Run{count = 1, line = line})
	}
}

chunk_free :: proc(chunk: ^Chunk) {
	delete(chunk.instructions)
	delete(chunk.lines)
	delete(chunk.constants)
}

chunk_add_constant :: proc(vm: ^VM, chunk: ^Chunk, value: Value) -> int {
	stack_push(vm, value)
	append(&chunk.constants, value)
	stack_drop(vm)
	return len(chunk.constants) - 1
}

chunk_get_line :: proc(chunk: ^Chunk, offset: int) -> i32 {
	if offset < 0 || offset >= len(chunk.instructions) do return -1

	current := 0
	for run in chunk.lines {
		current += run.count
		if offset < current do return run.line
	}

	return -1
}
