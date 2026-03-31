package vm

@(private)
free_object :: proc(object: ^Object) {
    switch object.type {
        case .Function:
            function := cast(^ObjectFunction)object
            chunk_free(&function.chunk)
            free(function)
        case .String:
            string := cast(^ObjectString)object
            delete(string.chars)
            free(string)
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