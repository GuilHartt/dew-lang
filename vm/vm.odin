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
	init_string:     ^ObjectString,
	open_upvalues:   ^ObjectUpvalue,
	alloc:           runtime.Allocator,
	gc_state:        GcState,
	bytes_allocated: int,
	next_gc:         int,
	objects:         ^Object,
	compiler:        ^Compiler,
	current_class:   ^ClassCompiler,
	gray_stack:      [dynamic]^Object,
}

init :: proc(vm: ^VM) {
	vm.alloc = {nil, nil}
	vm.gc_state = {runtime.heap_allocator(), vm, false}
	vm.alloc = {gc_allocator_proc, &vm.gc_state}
	context.allocator = vm.alloc

	vm_reset_stack(vm)
	vm.objects = nil
	vm.bytes_allocated = 0
	vm.next_gc = 1024 * 1024

	vm.gray_stack.allocator = vm.gc_state.backing

	init_table(&vm.globals)
	init_table(&vm.strings)

	vm.init_string = nil
	vm.init_string = copy_string(vm, "init")

	register_native(vm, "clock", 0, clock_native)
}

@(private = "file")
clock_native :: proc(call: ^NativeCall) -> (Value, bool) {
	nanos := time.to_unix_nanoseconds(time.now())
	return val_number(f64(nanos) / 1e9), true
}

destroy :: proc(vm: ^VM) {
	context.allocator = vm.alloc
	free_table(&vm.globals)
	free_table(&vm.strings)
	vm.init_string = nil
	free_objects(vm)
	assert(vm.bytes_allocated == 0, "gc: bytes_allocated leaked")
}

@(private)
vm_reset_stack :: proc(vm: ^VM) {
	vm.sp = 0
	vm.fp = 0
	vm.open_upvalues = nil
}

@(private, cold)
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

register_native :: proc(vm: ^VM, name: string, arity: int, function: NativeFn) {
	context.allocator = vm.alloc
	name_object := copy_string(vm, name)
	stack_push(vm, val_obj(name_object))
	stack_push(vm, val_obj(new_native(vm, function, name_object, arity)))
	table_set(&vm.globals, name_object, peek(vm, 0))
	stack_drop(vm, 2)
}

interpret :: proc(vm: ^VM, source: string) -> InterpretResult {
	context.allocator = vm.alloc
	function := compile(vm, source)
	if function == nil do return .CompileError

	stack_push(vm, val_obj(function))
	closure := new_closure(vm, function)
	stack_drop(vm)
	stack_push(vm, val_obj(closure))
	call(vm, closure, 0)

	return vm_run(vm)
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
call :: #force_inline proc "contextless" (vm: ^VM, closure: ^ObjectClosure, arg_count: int) -> bool {
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
call_value :: #force_inline proc (vm: ^VM, callee: Value, arg_count: int) -> bool {
	if is_obj(callee) {
		#partial switch obj_type(callee) {

		case .BoundMethod: {
			bound := as_bound_method(callee)
			vm.stack[vm.sp -arg_count - 1] = bound.receiver
			return call(vm, bound.method, arg_count)
		}
		
		case .Class: {
			class := as_class(callee)
			vm.stack[vm.sp -arg_count - 1] = val_obj(new_instance(vm, class))

			initializer, ok := table_get(&class.methods, vm.init_string)
			if ok {
				return call(vm, as_closure(initializer), arg_count)
			} else if arg_count != 0 {
				runtime_error(vm, "Expected 0 arguments but got %d.", arg_count)
				return false
			}

			return true
		}
			
		case .Closure: {
			return call(vm, as_closure(callee), arg_count)
		}
			
		case .Native: {
			native := as_native(callee)

			if arg_count != native.arity {
				runtime_error(vm, "Expected %d arguments but got %d.", native.arity, arg_count)
				return false
			}

			if result, ok := native.function(&NativeCall{vm, native.name.chars, vm.stack[vm.sp - arg_count:vm.sp],}); ok {
				vm.sp -= arg_count + 1
				stack_push(vm, result)
				return true
			}


			return false
		}
		}
	}
	runtime_error(vm, "Can only call functions and classes.")
	return false
}

@(private = "file")
invoke_from_class :: proc (vm: ^VM, class: ^ObjectClass, name: ^ObjectString, arg_count: int) -> bool {
	method, ok := table_get(&class.methods, name)
	if !ok {
		runtime_error(vm, "Undefined property '%s'.", name.chars)
		return false
	}
	return call(vm, as_closure(method), arg_count)
}

@(private = "file")
invoke :: proc (vm: ^VM, name: ^ObjectString, arg_count: int) -> bool {
	receiver := peek(vm, arg_count)

	if !is_instance(receiver) {
		runtime_error(vm, "Only instances have methods.")
		return false
	}

	instance := as_instance(receiver)

	value, ok := table_get(&instance.fields, name)
	if ok {
		vm.stack[vm.sp -arg_count - 1] = value
		return call_value(vm, value, arg_count)
	}
	return invoke_from_class(vm, instance.class, name, arg_count)
}

@(private = "file")
bind_method :: proc (vm: ^VM, class: ^ObjectClass, name: ^ObjectString) -> bool {
	method, ok := table_get(&class.methods, name)
	if !ok {
		runtime_error(vm, "Undefined property '%s'.", name.chars)
		return false
	}

	bound := new_bound_method(vm, peek(vm, 0), as_closure(method))

	stack_pop(vm)
	stack_push(vm, val_obj(bound))
	return true
}

@(private)
capture_upvalue :: proc(vm: ^VM, local: ^Value) -> ^ObjectUpvalue {
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
define_method :: proc (vm: ^VM, name: ^ObjectString) {
	method := peek(vm, 0)
	class := as_class(peek(vm, 1))
	table_set(&class.methods, name, method)
	stack_pop(vm)
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
concatenate :: #force_inline proc (vm: ^VM, lhs, rhs: ^ObjectString) {
	result := take_string(vm, strings.concatenate({lhs.chars, rhs.chars}))

	stack_drop(vm, 2)
	stack_push(vm, val_obj(result))
}

@(private = "file")
trace_instruction :: proc "contextless" (vm: ^VM, chunk: ^Chunk, ip: int) {
	context = runtime.default_context()

	fmt.print("          ")
	for i in 0 ..< vm.sp {
		fmt.print("[ ")
		print_value(vm.stack[i])
		fmt.print(" ]")
	}
	fmt.println()

	disassemble_instruction(chunk, ip)
}

@(private = "file")
read_byte :: #force_inline proc "contextless" (instructions: []u8, ip: ^int) -> u8 {
	byte := instructions[ip^]
	ip^ += 1
	return byte
}

@(private = "file")
read_short :: #force_inline proc "contextless" (instructions: []u8, ip: ^int) -> u16 {
	low  := read_byte(instructions, ip)
	high := read_byte(instructions, ip)
	return u16(low) | (u16(high) << 8)
}

@(private = "file")
read_constant :: #force_inline proc "contextless" (constants: []Value, instructions: []u8, ip: ^int) -> Value {
	return constants[read_short(instructions, ip)]
}

@(private = "file")
read_string :: #force_inline proc "contextless" (constants: []Value, instructions: []u8, ip: ^int) -> ^ObjectString {
	return as_string(read_constant(constants, instructions, ip))
}

@(private = "file")
load_frame :: #force_inline proc "contextless" (vm: ^VM) -> (
	frame: ^CallFrame,
	instructions: []u8,
	constants: []Value,
	ip: int,
	slots: int,
) {
	frame = &vm.frames[vm.fp - 1]
	instructions = frame.closure.function.chunk.instructions[:]
	constants = frame.closure.function.chunk.constants[:]
	ip = frame.ip
	slots = frame.slots
	return
}

@(private)
vm_run :: proc(vm: ^VM) -> InterpretResult {
	frame, instructions, constants, ip, slots := load_frame(vm)

	for {
		when DEW_DEBUG_TRACE {
			trace_instruction(vm, &frame.closure.function.chunk, ip)
		}

		op := Opcode(instructions[ip])
		ip += 1

		switch op {
		case .Constant: {
			stack_push(vm, read_constant(constants, instructions, &ip))
		}

		case .Nil: {
			stack_push(vm, val_nil())
		}

		case .True: {
			stack_push(vm, val_bool(true))
		}

		case .False: {
			stack_push(vm, val_bool(false))
		}

		case .Pop: {
			stack_drop(vm)
		}

		case .GetLocal: {
			slot := read_byte(instructions, &ip)
			stack_push(vm, vm.stack[slots + int(slot)])
		}

		case .SetLocal: {
			slot := read_byte(instructions, &ip)
			vm.stack[slots + int(slot)] = peek(vm, 0)
		}

		case .GetUpvalue: {
			slot := read_byte(instructions, &ip)
			stack_push(vm, frame.closure.upvalues[slot].location^)
		}

		case .SetUpvalue: {
			slot := read_byte(instructions, &ip)
			frame.closure.upvalues[slot].location^ = peek(vm, 0)
		}

		case .GetGlobal: {
			name := read_string(constants, instructions, &ip)
			value, exists := table_get(&vm.globals, name)
			if !exists {
				frame.ip = ip
				runtime_error(vm, "Undefined variable '%s'.", name.chars)
				return .RuntimeError
			}
			stack_push(vm, value)
		}

		case .DefineGlobal: {
			name := read_string(constants, instructions, &ip)
			table_set(&vm.globals, name, peek(vm, 0))
			stack_drop(vm)
		}

		case .SetGlobal: {
			name := read_string(constants, instructions, &ip)
			if table_set(&vm.globals, name, peek(vm, 0)) {
				table_delete(&vm.globals, name)
				frame.ip = ip
				runtime_error(vm, "Undefined variable '%s'.", name.chars)
				return .RuntimeError
			}
		}

		case .GetProperty: {
			if !is_instance(peek(vm, 0)) {
				frame.ip = ip
				runtime_error(vm, "Only instances have properties.")
				return .RuntimeError
			}

			instance := as_instance(peek(vm, 0))
			name := read_string(constants, instructions, &ip)

			value, exists := table_get(&instance.fields, name)
			if exists {
				stack_pop(vm)
				stack_push(vm, value)
			} else {
				frame.ip = ip
				if !bind_method(vm, instance.class, name) {
					return .RuntimeError
				}
			}
		}

		case .SetProperty: {
			if !is_instance(peek(vm, 1)) {
				frame.ip = ip
				runtime_error(vm, "Only instances have fields.")
				return .RuntimeError
			}

			instance := as_instance(peek(vm, 1))
			table_set(&instance.fields, read_string(constants, instructions, &ip), peek(vm, 0))

			value := stack_pop(vm)
			stack_pop(vm)
			stack_push(vm, value)
		}

		case .GetSuper: {
			name := read_string(constants, instructions, &ip)
			superclass := as_class(stack_pop(vm))
			frame.ip = ip
			if !bind_method(vm, superclass, name) {
				return .RuntimeError
			}
		}

		case .Equal: {
			rhs := stack_pop(vm)
			lhs := stack_pop(vm)
			stack_push(vm, val_bool(lhs == rhs))
		}

		case .Greater: {
			rhs_num, rhs_is_num := check_number(peek(vm, 0))
			lhs_num, lhs_is_num := check_number(peek(vm, 1))
			if !lhs_is_num || !rhs_is_num {
				frame.ip = ip
				runtime_error(vm, "Operands must be numbers.")
				return .RuntimeError
			}
			stack_drop(vm, 2)
			stack_push(vm, val_bool(lhs_num > rhs_num))
		}

		case .Less: {
			rhs_num, rhs_is_num := check_number(peek(vm, 0))
			lhs_num, lhs_is_num := check_number(peek(vm, 1))
			if !lhs_is_num || !rhs_is_num {
				frame.ip = ip
				runtime_error(vm, "Operands must be numbers.")
				return .RuntimeError
			}
			stack_drop(vm, 2)
			stack_push(vm, val_bool(lhs_num < rhs_num))
		}

		case .Add: {
			rhs_num, rhs_is_num := check_number(peek(vm, 0))
			lhs_num, lhs_is_num := check_number(peek(vm, 1))

			if lhs_is_num && rhs_is_num {
				stack_drop(vm, 2)
				stack_push(vm, val_number(lhs_num + rhs_num))
			} else {
				rhs_str, rhs_is_str := check_string(peek(vm, 0))
				lhs_str, lhs_is_str := check_string(peek(vm, 1))

				if lhs_is_str && rhs_is_str {
					concatenate(vm, lhs_str, rhs_str)
				} else {
					frame.ip = ip
					runtime_error(vm, "Operands must be two numbers or two strings.")
					return .RuntimeError
				}
			}
		}

		case .Sub: {
			rhs_num, rhs_is_num := check_number(peek(vm, 0))
			lhs_num, lhs_is_num := check_number(peek(vm, 1))
			if !lhs_is_num || !rhs_is_num {
				frame.ip = ip
				runtime_error(vm, "Operands must be numbers.")
				return .RuntimeError
			}
			stack_drop(vm, 2)
			stack_push(vm, val_number(lhs_num - rhs_num))
		}

		case .Mul: {
			rhs_num, rhs_is_num := check_number(peek(vm, 0))
			lhs_num, lhs_is_num := check_number(peek(vm, 1))
			if !lhs_is_num || !rhs_is_num {
				frame.ip = ip
				runtime_error(vm, "Operands must be numbers.")
				return .RuntimeError
			}
			stack_drop(vm, 2)
			stack_push(vm, val_number(lhs_num * rhs_num))
		}

		case .Div: {
			rhs_num, rhs_is_num := check_number(peek(vm, 0))
			lhs_num, lhs_is_num := check_number(peek(vm, 1))
			if !lhs_is_num || !rhs_is_num {
				frame.ip = ip
				runtime_error(vm, "Operands must be numbers.")
				return .RuntimeError
			}
			stack_drop(vm, 2)
			stack_push(vm, val_number(lhs_num / rhs_num))
		}

		case .Negate: {
			num, is_num := check_number(peek(vm, 0))
			if !is_num {
				frame.ip = ip
				runtime_error(vm, "Operand must be a number.")
				return .RuntimeError
			}

			stack_pop(vm)
			stack_push(vm, -num)
		}

		case .Not: {
			stack_push(vm, Value(is_falsey(stack_pop(vm))))
		}

		case .Print: {
			print_value(stack_pop(vm))
			fmt.println()
		}

		case .Jump: {
			offset := read_short(instructions, &ip)
			ip += int(offset)
		}

		case .JumpIfFalse: {
			offset := read_short(instructions, &ip)
			if is_falsey(peek(vm, 0)) {
				ip += int(offset)
			}
		}

		case .Loop: {
			offset := read_short(instructions, &ip)
			ip -= int(offset)
		}

		case .Call: {
			arg_count := int(read_byte(instructions, &ip))
			frame.ip = ip
			if !call_value(vm, peek(vm, arg_count), arg_count) {
				return .RuntimeError
			}
			frame, instructions, constants, ip, slots = load_frame(vm)
		}

		case .Invoke: {
			name := read_string(constants, instructions, &ip)
			arg_count := int(read_byte(instructions, &ip))
			frame.ip = ip
			if !invoke(vm, name, arg_count) {
				return .RuntimeError
			}
			frame, instructions, constants, ip, slots = load_frame(vm)
		}

		case .SuperInvoke: {
			name := read_string(constants, instructions, &ip)
			arg_count := int(read_byte(instructions, &ip))
			superclass := as_class(stack_pop(vm))
			frame.ip = ip
			if !invoke_from_class(vm, superclass, name, arg_count) {
				return .RuntimeError
			}
			frame, instructions, constants, ip, slots = load_frame(vm)
		}

		case .Closure: {
			function := as_function(read_constant(constants, instructions, &ip))
			closure := new_closure(vm, function)
			stack_push(vm, val_obj(closure))

			for i in 0 ..< len(closure.upvalues) {
				is_local := read_byte(instructions, &ip)
				index := int(read_byte(instructions, &ip))
				if is_local == 1 {
					closure.upvalues[i] = capture_upvalue(vm, &vm.stack[slots + index])
				} else {
					closure.upvalues[i] = frame.closure.upvalues[index]
				}
			}
		}

		case .CloseUpvalue: {
			close_upvalues(vm, &vm.stack[vm.sp - 1])
			stack_drop(vm)
		}

		case .Return: {
			result := stack_pop(vm)
			close_upvalues(vm, &vm.stack[slots])
			vm.fp -= 1

			if vm.fp == 0 {
				stack_drop(vm)
				return .Ok
			}

			vm.sp = slots
			stack_push(vm, result)
			frame, instructions, constants, ip, slots = load_frame(vm)
		}

		case .Class: {
			stack_push(vm, val_obj(new_class(vm, read_string(constants, instructions, &ip))))
		}

		case .Inherit: {
			superclass := peek(vm, 1)
			if !is_class(superclass) {
				frame.ip = ip
				runtime_error(vm, "Superclass must be a class.")
				return .RuntimeError
			}

			subclass := as_class(peek(vm, 0))
			table_add_all(&as_class(superclass).methods, &subclass.methods)
			stack_pop(vm)
		}

		case .Method: {
			define_method(vm, read_string(constants, instructions, &ip))
		}
		}
	}
}
