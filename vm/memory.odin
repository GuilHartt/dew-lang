package vm

import "core:fmt"

GC_HEAP_GROW_FACTOR :: 2

@(private)
free_object :: proc(vm: ^VM, object: ^Object) {
	when DEW_DEBUG_LOG_GC {
		fmt.printfln("%p free type %v", object, object.type)
	}

	switch object.type {
	case .Closure:
		closure := cast(^ObjectClosure)object
		vm.bytes_allocated -= size_of(ObjectClosure)
		delete(closure.upvalues)
		free(closure)
	case .Function:
		function := cast(^ObjectFunction)object
		vm.bytes_allocated -= size_of(ObjectFunction)
		chunk_free(&function.chunk)
		free(function)
	case .Native:
		vm.bytes_allocated -= size_of(ObjectNative)
		free(cast(^ObjectNative)object)
	case .String:
		str := cast(^ObjectString)object
		vm.bytes_allocated -= size_of(ObjectString)
		delete(str.chars)
		free(str)
	case .Upvalue:
		vm.bytes_allocated -= size_of(ObjectUpvalue)
		free(cast(^ObjectUpvalue)object)
	}
}

@(private)
free_objects :: proc(vm: ^VM) {
	object := vm.objects
	for object != nil {
		next := object.next
		free_object(vm, object)
		object = next
	}
	delete(vm.gray_stack)
}

@(private)
collect_garbage :: proc(vm: ^VM) {
	when DEW_DEBUG_LOG_GC {
		fmt.println("--gc begin")
		before := vm.bytes_allocated
		defer {
			fmt.println("--gc end")
			fmt.printfln(
				"   collected %d bytes (from %d to %d) next at %d",
				before - vm.bytes_allocated,
				before,
				vm.bytes_allocated,
				vm.next_gc,
			)
		}
	}

	mark_roots(vm)
	trace_references(vm)
	table_remove_white(&vm.strings)
	sweep(vm)

	vm.next_gc = vm.bytes_allocated * GC_HEAP_GROW_FACTOR
}

@(private)
mark_object :: proc(vm: ^VM, object: ^Object) {
	if object == nil || object.is_marked do return

	when DEW_DEBUG_LOG_GC {
		fmt.printf("%p mark ", object)
		print_value(val_obj(object))
		fmt.println()
	}
	object.is_marked = true

	append(&vm.gray_stack, object)
}

@(private)
mark_value :: proc(vm: ^VM, value: Value) {
	if is_obj(value) do mark_object(vm, as_object(value))
}

@(private = "file")
mark_array :: proc(vm: ^VM, array: []Value) {
	for value in array {
		mark_value(vm, value)
	}
}

@(private = "file")
blacken_object :: proc(vm: ^VM, object: ^Object) {
	when DEW_DEBUG_LOG_GC {
		fmt.printf("%p blacken ", object)
		print_value(val_obj(object))
		fmt.println()
	}

	#partial switch object.type {
	case .Closure:
		closure := cast(^ObjectClosure)object
		mark_object(vm, closure.function)
		for upvalue in closure.upvalues {
			mark_object(vm, upvalue)
		}
	case .Function:
		function := cast(^ObjectFunction)object
		mark_object(vm, function.name)
		mark_array(vm, function.chunk.constants[:])
	case .Upvalue:
		mark_value(vm, (cast(^ObjectUpvalue)object).closed)
	}
}

@(private = "file")
mark_roots :: proc(vm: ^VM) {
	for i in 0 ..< vm.sp {
		mark_value(vm, vm.stack[i])
	}

	for i in 0 ..< vm.fp {
		mark_object(vm, vm.frames[i].closure)
	}

	for upvalue := vm.open_upvalues; upvalue != nil; upvalue = upvalue.next_upvalue {
		mark_object(vm, upvalue)
	}

	mark_table(vm, &vm.globals)
	mark_compiler_roots(vm)
}

@(private = "file")
trace_references :: proc(vm: ^VM) {
	for len(vm.gray_stack) > 0 {
		object := pop(&vm.gray_stack)
		blacken_object(vm, object)
	}
}

@(private = "file")
sweep :: proc(vm: ^VM) {
	previus: ^Object
	object := vm.objects

	for object != nil {
		if object.is_marked {
			object.is_marked = false
			previus = object
			object = object.next
		} else {
			unreached := object
			object = object.next
			if previus != nil {
				previus.next = object
			} else {
				vm.objects = object
			}

			free_object(vm, unreached)
		}
	}
}
