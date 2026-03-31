package vm

import "core:hash"
import "core:fmt"
import "core:strings"

ObjectType :: enum u8 {
    Function,
    Native,
    String,
}

Object :: struct {
    type: ObjectType,
    next: ^Object,
}

ObjectFunction :: struct {
    using obj: Object,
    arity: int,
    chunk: Chunk,
    name: ^ObjectString,
}

NativeFn :: #type proc(vm: ^VM, args: []Value) -> (Value, bool)

ObjectNative :: struct {
    using obj: Object,
    function: NativeFn,
    name: ^ObjectString,
}

ObjectString :: struct {
    using obj: Object,
    hash: u32,
    chars: string,
    
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
        case .Function:
            print_function(cast(^ObjectFunction)object)
        case .Native:
            fmt.print(( cast(^ObjectNative)object).name.chars)
        case .String:
            fmt.print(( cast(^ObjectString)object).chars)
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