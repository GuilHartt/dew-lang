package vm

import "core:fmt"
import "core:strings"
ObjectType :: enum u8 {
    String,
}

Object :: struct {
    type: ObjectType,
    next: ^Object,
}

ObjectString :: struct {
    using obj: Object,
    chars:     string,
}

@(private="file")
allocate_object :: proc(vm: ^VM, $T: typeid, type: ObjectType) -> ^T {
    obj := new(T)
    obj.type = type
    obj.next = vm.objects
    vm.objects = obj
    return obj
}

@(private)
allocate_string :: proc(vm: ^VM, chars: string) -> ^ObjectString {
    object_string := allocate_object(vm, ObjectString, .String)
    object_string.chars = chars
    return object_string
}

@(private)
copy_string :: proc(vm: ^VM, chars: string) -> ^ObjectString {
    return allocate_string(vm, strings.clone(chars))
}

@(private)
print_object :: proc(object: ^Object) {
    switch object.type {
        case .String:
            fmt.print(( cast(^ObjectString)object).chars)
    }
}