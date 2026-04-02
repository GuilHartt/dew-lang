package vm

import "core:fmt"
import "core:hash"
import "core:strings"

ObjectType :: enum u8 {
	Closure,
	Function,
	Native,
	String,
	Upvalue,
}

Object :: struct {
	type:      ObjectType,
	is_marked: bool,
	next:      ^Object,
}

ObjectFunction :: struct {
	using obj:     Object,
	arity:         int,
	upvalue_count: int,
	chunk:         Chunk,
	name:          ^ObjectString,
}

NativeFn :: #type proc(vm: ^VM, args: []Value) -> (Value, bool)

ObjectNative :: struct {
	using obj: Object,
	function:  NativeFn,
	name:      ^ObjectString,
}

ObjectString :: struct {
	using obj: Object,
	hash:      u32,
	chars:     string,
}

ObjectUpvalue :: struct {
	using obj:    Object,
	location:     ^Value,
	closed:       Value,
	next_upvalue: ^ObjectUpvalue,
}

ObjectClosure :: struct {
	using obj: Object,
	function:  ^ObjectFunction,
	upvalues:  []^ObjectUpvalue,
}

@(private = "file")
allocate_object :: proc(vm: ^VM, $T: typeid, type: ObjectType) -> ^T {
	vm.bytes_allocated += size_of(T)

	when DEW_DEBUG_STRESS_GC {
		collect_garbage(vm)
	} else {
		if vm.bytes_allocated > vm.next_gc {
			collect_garbage(vm)
		}
	}

	obj := new(T)
	obj.type = type
	obj.next = vm.objects
	vm.objects = obj

	when DEW_DEBUG_LOG_GC {
		fmt.printfln("%p allocate %d for %v", obj, size_of(T), type)
	}

	return obj
}

@(private)
allocate_string :: proc(vm: ^VM, chars: string, hash: u32) -> ^ObjectString {
	str := allocate_object(vm, ObjectString, .String)
	str.chars = chars
	str.hash = hash

	stack_push(vm, val_obj(str))
	table_set(&vm.strings, str, val_nil())
	stack_drop(vm)

	return str
}

@(private)
copy_string :: proc(vm: ^VM, chars: string) -> ^ObjectString {
	hash := hash.fnv32a(transmute([]u8)chars)
	interned := table_find_string(&vm.strings, chars, hash)
	if interned != nil do return interned
	return allocate_string(vm, strings.clone(chars), hash)
}

@(private)
take_string :: proc(vm: ^VM, chars: string) -> ^ObjectString {
	hash := hash.fnv32a(transmute([]u8)chars)
	interned := table_find_string(&vm.strings, chars, hash)
	if interned != nil {
		delete(chars)
		return interned
	}
	return allocate_string(vm, chars, hash)
}

@(private)
print_object :: proc(object: ^Object) {
	switch object.type {
	case .Closure:
		print_function((cast(^ObjectClosure)object).function)
	case .Function:
		print_function(cast(^ObjectFunction)object)
	case .Native:
		fmt.print((cast(^ObjectNative)object).name.chars)
	case .String:
		fmt.print((cast(^ObjectString)object).chars)
	case .Upvalue:
		fmt.print("upvalue")
	}
}

@(private)
print_function :: proc(function: ^ObjectFunction) {
	if function.name == nil {
		fmt.print("<script>")
		return
	}
	fmt.printf("<fn %s>", function.name.chars)
}

new_function :: proc(vm: ^VM) -> ^ObjectFunction {
	function := allocate_object(vm, ObjectFunction, .Function)
	return function
}

new_native :: proc(vm: ^VM, function: NativeFn, name: ^ObjectString) -> ^ObjectNative {
	native := allocate_object(vm, ObjectNative, .Native)
	native.function = function
	native.name = name
	return native
}

new_upvalue :: proc(vm: ^VM, slot: ^Value) -> ^ObjectUpvalue {
	upvalue := allocate_object(vm, ObjectUpvalue, .Upvalue)
	upvalue.closed = val_nil()
	upvalue.location = slot
	return upvalue
}

new_closure :: proc(vm: ^VM, function: ^ObjectFunction) -> ^ObjectClosure {
	upvalues := make([]^ObjectUpvalue, function.upvalue_count)
	closure := allocate_object(vm, ObjectClosure, .Closure)
	closure.function = function
	closure.upvalues = upvalues
	return closure
}
