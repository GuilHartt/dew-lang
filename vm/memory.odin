package vm

import "base:runtime"
import "core:fmt"
import "core:mem"

GC_HEAP_GROW_FACTOR :: 2

GcState :: struct {
	backing: runtime.Allocator,
	vm:      ^VM,
	in_gc:   bool,
}

@(private)
gc_allocator_proc :: proc(allocator_data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, location := #caller_location) -> (data: []byte, err: runtime.Allocator_Error) {
	state := cast(^GcState)allocator_data
	backing := state.backing
	vm := state.vm

	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		data = backing.procedure(backing.data, mode, size, alignment, nil, 0, location) or_return
		vm.bytes_allocated += size
		maybe_collect_garbage(vm)
		return data, .None
	case .Free:
		assert(old_memory != nil, "gc: free of nil pointer", location)
		assert(old_size > 0, "gc: free without size, use mem.free_with_size", location)
		_, err = backing.procedure(backing.data, .Free, 0, 0, old_memory, old_size, location)
		if err == .None do vm.bytes_allocated -= old_size
		return nil, err
	case .Resize, .Resize_Non_Zeroed:
		if old_memory == nil {
			data = backing.procedure(backing.data, mode, size, alignment, nil, 0, location) or_return
			vm.bytes_allocated += size
			if size > 0 do maybe_collect_garbage(vm)
			return data, .None
		}
		if size == 0 {
			assert(old_size > 0, "gc: resize to zero without size", location)
			_, err = backing.procedure(backing.data, .Free, 0, 0, old_memory, old_size, location)
			if err == .None do vm.bytes_allocated -= old_size
			return nil, err
		}
		if size == old_size {
			return mem.byte_slice(old_memory, size), .None
		}
		data = backing.procedure(backing.data, mode, size, alignment, old_memory, old_size, location) or_return
		vm.bytes_allocated += size - old_size
		if size > old_size do maybe_collect_garbage(vm)
		return data, .None
	case .Query_Features:
		return backing.procedure(backing.data, mode, size, alignment, old_memory, old_size, location)
	case .Query_Info:
		return backing.procedure(backing.data, mode, size, alignment, old_memory, old_size, location)
	}

	return backing.procedure(backing.data, mode, size, alignment, old_memory, old_size, location)
}

@(private = "file")
maybe_collect_garbage :: proc(vm: ^VM) {
	when DEW_DEBUG_STRESS_GC {
		collect_garbage(vm)
	} else {
		if vm.bytes_allocated > vm.next_gc && !vm.gc_state.in_gc {
			collect_garbage(vm)
		}
	}
}

@(private)
free_object :: proc(vm: ^VM, object: ^Object) {
	when DEW_DEBUG_LOG_GC {
		fmt.printfln("%p free type %v", object, object.type)
	}

	context.allocator = vm.alloc

	switch object.type {
	case .Closure:
		closure := cast(^ObjectClosure)object
		delete(closure.upvalues)
		mem.free_with_size(closure, size_of(ObjectClosure))
	case .Function:
		function := cast(^ObjectFunction)object
		chunk_free(&function.chunk)
		mem.free_with_size(function, size_of(ObjectFunction))
	case .Native:
		mem.free_with_size(cast(^ObjectNative)object, size_of(ObjectNative))
	case .String:
		str := cast(^ObjectString)object
		delete(str.chars, vm.alloc)
		mem.free_with_size(str, size_of(ObjectString))
	case .Upvalue:
		mem.free_with_size(cast(^ObjectUpvalue)object, size_of(ObjectUpvalue))
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
	vm.gc_state.in_gc = true
	defer vm.gc_state.in_gc = false

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
	case .Native:
		mark_object(vm, (cast(^ObjectNative)object).name)
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
