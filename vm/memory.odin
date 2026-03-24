package vm

@(private)
free_object :: proc(object: ^Object) {
    switch object.type {
        case .String:
            str := cast(^ObjectString)object
            delete(str.chars)
            free(str)
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