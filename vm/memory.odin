package vm

@(private)
free_object :: proc(object: ^Object) {
    switch object.type {
        case .Closure:
            closure := cast(^ObjectClosure)object
            delete(closure.upvalues)
            free(closure)
        case .Function:
            function := cast(^ObjectFunction)object
            chunk_free(&function.chunk)
            free(function)
        case .Native:
            native := cast(^ObjectNative)object
            free(native)
        case .String:
            string := cast(^ObjectString)object
            delete(string.chars)
            free(string)
        case .Upvalue:
            upvalue := cast(^ObjectUpvalue)object
            free(upvalue)
    }
}

@(private)
free_objects :: proc(vm: ^VM) {
    object := vm.objects
    for object != nil {
        next := object.next
        free_object(object)
        object = next
    }
}