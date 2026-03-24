package vm

import "core:hash"
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
    hash:      u32,
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
allocate_string :: proc(vm: ^VM, chars: string, hash: u32) -> ^ObjectString {
    str := allocate_object(vm, ObjectString, .String)
    str.chars = chars
    str.hash = hash
    table_set(&vm.strings, str, val_nil())
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
        case .String:
            fmt.print(( cast(^ObjectString)object).chars)
    }
}