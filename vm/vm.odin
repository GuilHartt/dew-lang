package vm

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:time"

FRAMES_MAX :: 64
STACK_MAX :: FRAMES_MAX * (int(max(u8)) + 1)

CallFrame :: struct {
	closure: ^ObjectClosure,
	ip:      int,
	slots:   int,
}

InterpretResult :: enum u8 {
	Ok,
	CompileError,
	RuntimeError,
}

VM :: struct {
	frames:          [FRAMES_MAX]CallFrame,
	fp:              int,
	stack:           [STACK_MAX]Value,
	sp:              int,
	globals:         Table,
	strings:         Table,
	open_upvalues:   ^ObjectUpvalue,
	bytes_allocated: int,
	next_gc:         int,
	objects:         ^Object,
	compiler:        ^Compiler,
	gray_stack:      [dynamic]^Object,
}

init :: proc(vm: ^VM) {
	vm_reset_stack(vm)
	vm.objects = nil
	vm.bytes_allocated = 0
	vm.next_gc = 1024 * 1024

	init_table(&vm.globals)
	init_table(&vm.strings)

	define_native(vm, "clock", proc(vm: ^VM, args: []Value) -> (Value, bool) {
		nanos := time.to_unix_nanoseconds(time.now())
		return val_number(f64(nanos) / 1e9), true
	})
}

destroy :: proc(vm: ^VM) {
	free_table(&vm.globals)
	free_table(&vm.strings)
	free_objects(vm)
}

@(private)
vm_reset_stack :: proc(vm: ^VM) {
	vm.sp = 0
	vm.fp = 0
	vm.open_upvalues = nil
}

@(private = "file", cold)
runtime_error :: proc "contextless" (vm: ^VM, format: string, args: ..any) {
	context = runtime.default_context()
	fmt.eprintfln(format, ..args)

	for i := vm.fp - 1; i >= 0; i -= 1 {
		frame := &vm.frames[i]
		function := frame.closure.function

		instruction := frame.ip - 1
		fmt.eprintf("line [%d] in ", chunk_get_line(&function.chunk, instruction))
		if function.name == nil {
			fmt.eprintln("script")
		} else {
			fmt.eprintln(function.name.chars)
		}
	}

	vm_reset_stack(vm)
}

define_native :: proc(vm: ^VM, name: string, function: NativeFn) {
	name_object := copy_string(vm, name)
	stack_push(vm, val_obj(name_object))
	stack_push(vm, val_obj(new_native(vm, function, name_object)))
	table_set(&vm.globals, as_string(peek(vm, 1)), peek(vm, 0))
	stack_drop(vm, 2)
}

interpret :: proc(vm: ^VM, source: string) -> InterpretResult {
	function := compile(vm, source)
	if function == nil do return .CompileError

	stack_push(vm, val_obj(function))
	closure := new_closure(vm, function)
	stack_drop(vm)
	stack_push(vm, val_obj(closure))
	call(vm, closure, 0)

	return vm_run(vm, &vm.frames[vm.fp - 1])
}

@(private)
stack_push :: #force_inline proc "contextless" (vm: ^VM, value: Value) {
	vm.stack[vm.sp] = value
	vm.sp += 1
}

@(private)
stack_pop :: #force_inline proc "contextless" (vm: ^VM) -> Value {
	vm.sp -= 1
	return vm.stack[vm.sp]
}

@(private)
stack_drop :: #force_inline proc "contextless" (vm: ^VM, count: int = 1) {
	vm.sp -= count
}

@(private)
peek :: #force_inline proc "contextless" (vm: ^VM, distance: int) -> Value {
	return vm.stack[vm.sp - 1 - distance]
}

@(private)
call :: #force_inline proc "contextless" (
	vm: ^VM,
	closure: ^ObjectClosure,
	arg_count: int,
) -> bool {
	if arg_count != closure.function.arity {
		runtime_error(vm, "Expected %d arguments but got %d.", closure.function.arity, arg_count)
		return false
	}

	if vm.fp == FRAMES_MAX {
		runtime_error(vm, "Stack overflow.")
		return false
	}

	frame := &vm.frames[vm.fp]
	vm.fp += 1
	frame.closure = closure
	frame.ip = 0
	frame.slots = vm.sp - arg_count - 1
	return true
}

@(private)
call_value :: #force_inline proc "contextless" (vm: ^VM, callee: Value, arg_count: int) -> bool {
	if is_obj(callee) {
		#partial switch obj_type(callee) {
		case .Closure:
			return call(vm, as_closure(callee), arg_count)
		case .Native:
			context = runtime.default_context()
			native := as_native(callee)

			if result, ok := native(vm, vm.stack[vm.sp - arg_count:vm.sp]); ok {
				vm.sp -= arg_count + 1
				stack_push(vm, result)
				return true
			}

			return false
		}
	}
	runtime_error(vm, "Can only call functions and classes.")
	return false
}

@(private)
capture_upvalue :: proc "contextless" (vm: ^VM, local: ^Value) -> ^ObjectUpvalue {
	context = runtime.default_context()

	prev_upvalue: ^ObjectUpvalue
	upvalue := vm.open_upvalues
	for upvalue != nil && upvalue.location > local {
		prev_upvalue = upvalue
		upvalue = upvalue.next_upvalue
	}

	if upvalue != nil && upvalue.location == local {
		return upvalue
	}

	created_upvalue := new_upvalue(vm, local)
	created_upvalue.next_upvalue = upvalue

	if prev_upvalue == nil {
		vm.open_upvalues = created_upvalue
	} else {
		prev_upvalue.next_upvalue = created_upvalue
	}

	return created_upvalue
}

@(private = "file")
close_upvalues :: proc "contextless" (vm: ^VM, last: ^Value) {
	for vm.open_upvalues != nil && vm.open_upvalues.location >= last {
		upvalue := vm.open_upvalues
		upvalue.closed = upvalue.location^
		upvalue.location = &upvalue.closed
		vm.open_upvalues = upvalue.next_upvalue
	}
}

@(private = "file")
is_falsey :: #force_inline proc "contextless" (value: Value) -> bool {
	#partial switch v in value {
	case Nil:
		return true
	case bool:
		return !v
	case:
		return false
	}
}

@(private = "file")
concatenate :: #force_inline proc "contextless" (vm: ^VM, lhs, rhs: ^ObjectString) {
	context = runtime.default_context()

	result := take_string(vm, strings.concatenate({lhs.chars, rhs.chars}))

	stack_drop(vm, 2)
	stack_push(vm, val_obj(result))
}

@(private = "file")
read_byte :: #force_inline proc "contextless" (frame: ^CallFrame) -> u8 {
	b := frame.closure.function.chunk.instructions[frame.ip]
	frame.ip += 1
	return b
}

@(private = "file")
read_short :: #force_inline proc "contextless" (frame: ^CallFrame) -> u16 {
	return u16(read_byte(frame)) | (u16(read_byte(frame)) << 8)
}

@(private = "file")
read_constant :: #force_inline proc "contextless" (frame: ^CallFrame) -> Value {
	index := read_short(frame)
	return frame.closure.function.chunk.constants[index]
}

@(private = "file")
read_string :: #force_inline proc "contextless" (frame: ^CallFrame) -> ^ObjectString {
	return as_string(read_constant(frame))
}

@(private = "file")
check_numbers :: #force_inline proc "contextless" (
	vm: ^VM,
	frame: ^CallFrame,
) -> (
	f64,
	f64,
	InterpretResult,
) {
	rhs_num, rhs_is_num := check_number(peek(vm, 0))
	lhs_num, lhs_is_num := check_number(peek(vm, 1))

	if !lhs_is_num || !rhs_is_num {
		runtime_error(vm, "Operands must be numbers.")
		return 0, 0, .RuntimeError
	}

	stack_drop(vm, 2)
	return lhs_num, rhs_num, .Ok
}

OpcodeProc :: #type proc "preserve/none" (vm: ^VM, frame: ^CallFrame) -> InterpretResult

@(private, rodata)
LUT := [Opcode]OpcodeProc {
	.Constant     = do_constant,
	.Nil          = do_nil,
	.True         = do_true,
	.False        = do_false,
	.Pop          = do_pop,
	.GetLocal     = do_get_local,
	.SetLocal     = do_set_local,
	.GetGlobal    = do_get_global,
	.DefineGlobal = do_define_global,
	.SetGlobal    = do_set_global,
	.GetUpvalue   = do_get_upvalue,
	.SetUpvalue   = do_set_upvalue,
	.Equal        = do_equal,
	.Greater      = do_greater,
	.Less         = do_less,
	.Add          = do_add,
	.Sub          = do_sub,
	.Mul          = do_mul,
	.Div          = do_div,
	.Not          = do_not,
	.Negate       = do_negate,
	.Print        = do_print,
	.Jump         = do_jump,
	.JumpIfFalse  = do_jump_if_false,
	.Loop         = do_loop,
	.Call         = do_call,
	.Closure      = do_closure,
	.CloseUpvalue = do_close_upvalue,
	.Return       = do_return,
}

@(private)
vm_run :: proc "preserve/none" (vm: ^VM, frame: ^CallFrame) -> InterpretResult {

	if frame.ip >= len(frame.closure.function.chunk.instructions) {
		return .Ok
	}

	when DEW_DEBUG_TRACE {
		context = runtime.default_context()

		fmt.print("          ")
		for i in 0 ..< vm.sp {
			fmt.print("[ ")
			print_value(vm.stack[i])
			fmt.print(" ]")
		}
		fmt.println()

		disassemble_instruction(&frame.function.chunk, frame.ip)
	}

	return #must_tail LUT[Opcode(read_byte(frame))](vm, frame)
}

@(private = "file")
do_constant :: proc "preserve/none" (vm: ^VM, frame: ^CallFrame) -> InterpretResult {
	constant := read_constant(frame)
	stack_push(vm, constant)
	return #must_tail vm_run(vm, frame)
}

@(private = "file")
do_nil :: proc "preserve/none" (vm: ^VM, frame: ^CallFrame) -> InterpretResult {
	stack_push(vm, val_nil())
	return #must_tail vm_run(vm, frame)
}

@(private = "file")
do_true :: proc "preserve/none" (vm: ^VM, frame: ^CallFrame) -> InterpretResult {
	stack_push(vm, val_bool(true))
	return #must_tail vm_run(vm, frame)
}

@(private = "file")
do_false :: proc "preserve/none" (vm: ^VM, frame: ^CallFrame) -> InterpretResult {
	stack_push(vm, val_bool(false))
	return #must_tail vm_run(vm, frame)
}

@(private = "file")
do_pop :: proc "preserve/none" (vm: ^VM, frame: ^CallFrame) -> InterpretResult {
	stack_drop(vm)
	return #must_tail vm_run(vm, frame)
}

@(private = "file")
do_get_local :: proc "preserve/none" (vm: ^VM, frame: ^CallFrame) -> InterpretResult {
	slot := read_byte(frame)
	stack_push(vm, vm.stack[frame.slots + int(slot)])
	return #must_tail vm_run(vm, frame)
}

@(private = "file")
do_set_local :: proc "preserve/none" (vm: ^VM, frame: ^CallFrame) -> InterpretResult {
	slot := read_byte(frame)
	vm.stack[frame.slots + int(slot)] = peek(vm, 0)
	return #must_tail vm_run(vm, frame)
}

@(private = "file")
do_get_global :: proc "preserve/none" (vm: ^VM, frame: ^CallFrame) -> InterpretResult {
	name := read_string(frame)
	value, exists := table_get(&vm.globals, name)
	if !exists {
		runtime_error(vm, "Undefined variable '%s'.", name.chars)
		return .RuntimeError
	}
	stack_push(vm, value)
	return #must_tail vm_run(vm, frame)
}

@(private = "file")
do_define_global :: proc "preserve/none" (vm: ^VM, frame: ^CallFrame) -> InterpretResult {
	name := read_string(frame)
	table_set(&vm.globals, name, peek(vm, 0))
	stack_drop(vm)
	return #must_tail vm_run(vm, frame)
}

@(private = "file")
do_set_global :: proc "preserve/none" (vm: ^VM, frame: ^CallFrame) -> InterpretResult {
	name := read_string(frame)
	if table_set(&vm.globals, name, peek(vm, 0)) {
		table_delete(&vm.globals, name)
		runtime_error(vm, "Undefined variable '%s'.", name.chars)
		return .RuntimeError
	}
	return #must_tail vm_run(vm, frame)
}

@(private = "file")
do_get_upvalue :: proc "preserve/none" (vm: ^VM, frame: ^CallFrame) -> InterpretResult {
	slot := read_byte(frame)
	stack_push(vm, frame.closure.upvalues[slot].location^)
	return #must_tail vm_run(vm, frame)
}

@(private = "file")
do_set_upvalue :: proc "preserve/none" (vm: ^VM, frame: ^CallFrame) -> InterpretResult {
	slot := read_byte(frame)
	frame.closure.upvalues[slot].location^ = peek(vm, 0)
	return #must_tail vm_run(vm, frame)
}

@(private = "file")
do_equal :: proc "preserve/none" (vm: ^VM, frame: ^CallFrame) -> InterpretResult {
	rhs := stack_pop(vm)
	lhs := stack_pop(vm)
	stack_push(vm, val_bool(lhs == rhs))
	return #must_tail vm_run(vm, frame)
}

@(private = "file")
do_negate :: proc "preserve/none" (vm: ^VM, frame: ^CallFrame) -> InterpretResult {
	num, is_num := check_number(peek(vm, 0))
	if !is_num {
		runtime_error(vm, "Operand must be a number.")
		return .RuntimeError
	}

	stack_pop(vm)
	stack_push(vm, -num)

	return #must_tail vm_run(vm, frame)
}

@(private = "file")
do_greater :: proc "preserve/none" (vm: ^VM, frame: ^CallFrame) -> InterpretResult {
	lhs, rhs := check_numbers(vm, frame) or_return
	stack_push(vm, val_bool(lhs > rhs))
	return #must_tail vm_run(vm, frame)
}

@(private = "file")
do_less :: proc "preserve/none" (vm: ^VM, frame: ^CallFrame) -> InterpretResult {
	lhs, rhs := check_numbers(vm, frame) or_return
	stack_push(vm, val_bool(lhs < rhs))
	return #must_tail vm_run(vm, frame)
}

@(private = "file")
do_add :: proc "preserve/none" (vm: ^VM, frame: ^CallFrame) -> InterpretResult {
	rhs_num, rhs_is_num := check_number(peek(vm, 0))
	lhs_num, lhs_is_num := check_number(peek(vm, 1))

	if lhs_is_num && rhs_is_num {
		stack_drop(vm, 2)
		stack_push(vm, val_number(lhs_num + rhs_num))
		return #must_tail vm_run(vm, frame)
	}

	rhs_str, rhs_is_str := check_string(peek(vm, 0))
	lhs_str, lhs_is_str := check_string(peek(vm, 1))

	if lhs_is_str && rhs_is_str {
		concatenate(vm, lhs_str, rhs_str)
		return #must_tail vm_run(vm, frame)
	}

	runtime_error(vm, "Operands must be two numbers or two strings.")
	return .RuntimeError
}

@(private = "file")
do_sub :: proc "preserve/none" (vm: ^VM, frame: ^CallFrame) -> InterpretResult {
	lhs, rhs := check_numbers(vm, frame) or_return
	stack_push(vm, val_number(lhs - rhs))
	return #must_tail vm_run(vm, frame)
}

@(private = "file")
do_mul :: proc "preserve/none" (vm: ^VM, frame: ^CallFrame) -> InterpretResult {
	lhs, rhs := check_numbers(vm, frame) or_return
	stack_push(vm, val_number(lhs * rhs))
	return #must_tail vm_run(vm, frame)
}

@(private = "file")
do_div :: proc "preserve/none" (vm: ^VM, frame: ^CallFrame) -> InterpretResult {
	lhs, rhs := check_numbers(vm, frame) or_return
	stack_push(vm, val_number(lhs / rhs))
	return #must_tail vm_run(vm, frame)
}

@(private = "file")
do_not :: proc "preserve/none" (vm: ^VM, frame: ^CallFrame) -> InterpretResult {
	stack_push(vm, Value(is_falsey(stack_pop(vm))))
	return #must_tail vm_run(vm, frame)
}

@(private = "file")
do_print :: proc "preserve/none" (vm: ^VM, frame: ^CallFrame) -> InterpretResult {
	context = runtime.default_context()
	print_value(stack_pop(vm))
	fmt.println()
	return #must_tail vm_run(vm, frame)
}

@(private = "file")
do_jump :: proc "preserve/none" (vm: ^VM, frame: ^CallFrame) -> InterpretResult {
	offset := read_short(frame)
	frame.ip += int(offset)
	return #must_tail vm_run(vm, frame)
}

@(private = "file")
do_jump_if_false :: proc "preserve/none" (vm: ^VM, frame: ^CallFrame) -> InterpretResult {
	offset := read_short(frame)
	if is_falsey(peek(vm, 0)) do frame.ip += int(offset)
	return #must_tail vm_run(vm, frame)
}

@(private = "file")
do_loop :: proc "preserve/none" (vm: ^VM, frame: ^CallFrame) -> InterpretResult {
	offset := read_short(frame)
	frame.ip -= int(offset)
	return #must_tail vm_run(vm, frame)
}

@(private = "file")
do_call :: proc "preserve/none" (vm: ^VM, frame: ^CallFrame) -> InterpretResult {
	arg_count := int(read_byte(frame))
	if !call_value(vm, peek(vm, arg_count), arg_count) {
		return .RuntimeError
	}
	return #must_tail vm_run(vm, &vm.frames[vm.fp - 1])
}

@(private = "file")
do_closure :: proc "preserve/none" (vm: ^VM, frame: ^CallFrame) -> InterpretResult {
	context = runtime.default_context()
	function := as_function(read_constant(frame))
	closure := new_closure(vm, function)
	stack_push(vm, val_obj(closure))

	for i in 0 ..< len(closure.upvalues) {
		is_local := read_byte(frame)
		index := int(read_byte(frame))
		if is_local == 1 {
			closure.upvalues[i] = capture_upvalue(vm, &vm.stack[frame.slots + index])
		} else {
			closure.upvalues[i] = frame.closure.upvalues[index]
		}
	}

	return #must_tail vm_run(vm, frame)
}

@(private = "file")
do_close_upvalue :: proc "preserve/none" (vm: ^VM, frame: ^CallFrame) -> InterpretResult {
	close_upvalues(vm, &vm.stack[vm.sp - 1])
	stack_drop(vm)
	return #must_tail vm_run(vm, frame)
}

@(private = "file")
do_return :: proc "preserve/none" (vm: ^VM, frame: ^CallFrame) -> InterpretResult {
	result := stack_pop(vm)
	close_upvalues(vm, &vm.stack[frame.slots])
	vm.fp -= 1

	if vm.fp == 0 {
		stack_drop(vm)
		return .Ok
	}

	vm.sp = frame.slots
	stack_push(vm, result)

	return #must_tail vm_run(vm, &vm.frames[vm.fp - 1])
}
