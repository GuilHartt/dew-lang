package vm

import "base:runtime"
import "core:fmt"
import "core:strings"

Nil   :: struct {}
Value :: union {
    Nil,
    bool,
    f64,
    ^Object,
}

print_value :: proc "contextless" (value: Value) {
    context = runtime.default_context()

    switch v in value {
        case bool: fmt.print(v ? "true" : "false")
        case Nil:  fmt.print("nil")
        case f64:  fmt.printf("%g", v)
        case ^Object: print_object(v)
    }
}

@(private)
as_closure :: #force_inline proc "contextless" (v: Value) -> ^ObjectClosure {
    if obj, ok := v.(^Object); ok {
        return cast(^ObjectClosure)obj
    }
    return nil
}

@(private)
as_bound_method :: #force_inline proc "contextless" (v: Value) -> ^ObjectBoundMethod {
    if obj, ok := v.(^Object); ok {
        return cast(^ObjectBoundMethod)obj
    }
    return nil
}

@(private)
as_class :: #force_inline proc "contextless" (v: Value) -> ^ObjectClass {
    if obj, ok := v.(^Object); ok {
        return cast(^ObjectClass)obj
    }
    return nil
}

@(private)
as_function :: #force_inline proc "contextless" (v: Value) -> ^ObjectFunction {
    if obj, ok := v.(^Object); ok {
        return cast(^ObjectFunction)obj
    }
    return nil
}

@(private)
as_instance :: #force_inline proc "contextless" (v: Value) -> ^ObjectInstance {
    if obj, ok := v.(^Object); ok {
        return cast(^ObjectInstance)obj
    }
    return nil
}

@(private)
as_native :: #force_inline proc "contextless" (v: Value) -> ^ObjectNative {
    if obj, ok := v.(^Object); ok {
        return cast(^ObjectNative)obj
    }
    return nil
}

@(private)
as_string :: #force_inline proc "contextless" (v: Value) -> ^ObjectString {
    if obj, ok := v.(^Object); ok {
        return cast(^ObjectString)obj
    }
    return nil
}

@(private)
as_object :: #force_inline proc "contextless" (v: Value) -> ^Object {
    if obj, ok := v.(^Object); ok {
        return obj
    }
    return nil
}

@(private)
obj_type :: #force_inline proc "contextless" (v: Value) -> ObjectType {
    return as_object(v).type
}

val_nil :: #force_inline proc "contextless" () -> Value {
    return Value(Nil{})
}

val_number :: #force_inline proc "contextless" (n: f64) -> Value {
    return Value(n)
}

val_bool :: #force_inline proc "contextless" (b: bool) -> Value {
    return Value(b)
}

val_obj :: #force_inline proc "contextless" (obj: ^Object) -> Value {
    return Value(obj)
}

val_string :: proc(vm: ^VM, chars: string) -> Value {
    return val_obj(copy_string(vm, chars))
}

is_nil :: #force_inline proc "contextless" (v: Value) -> bool {
    _, ok := v.(Nil)
    return ok
}

is_obj :: #force_inline proc "contextless" (v: Value) -> bool {
    _, ok := v.(^Object)
    return ok
}

is_instance :: #force_inline proc "contextless" (v: Value) -> bool {
	obj, ok := v.(^Object)
	return ok && obj.type == .Instance
}

is_bound_method :: #force_inline proc "contextless" (v: Value) -> bool {
	obj, ok := v.(^Object)
	return ok && obj.type == .BoundMethod
}

is_class :: #force_inline proc "contextless" (v: Value) -> bool {
	obj, ok := v.(^Object)
	return ok && obj.type == .Class
}

check_number :: #force_inline proc "contextless" (v: Value) -> (f64, bool) {
    return v.(f64)
}

check_bool :: #force_inline proc "contextless" (v: Value) -> (bool, bool) {
    return v.(bool)
}

check_string :: #force_inline proc "contextless" (v: Value) -> (^ObjectString, bool) {
    if obj, ok := v.(^Object); ok && obj.type == .String {
        return cast(^ObjectString)obj, true
    }
    return nil, false
}

value_type_name :: proc "contextless" (v: Value) -> string {
    context = runtime.default_context()

    @(static, rodata) names := [ObjectType]string {
        .BoundMethod = "method",
        .Class       = "class",
        .Closure     = "function",
        .Function    = "function",
        .Instance    = "instance",
        .Native      = "native",
        .String      = "string",
        .Upvalue     = "upvalue",
    }

    switch value in v {
    case Nil:     return "nil"
    case bool:    return "bool"
    case f64:     return "number"
    case ^Object: return names[value.type]
    }

    return "unknown"
}

@(private)
value_to_string :: proc(vm: ^VM, value: Value) -> ^ObjectString {
    switch v in value {
    case bool:
        return copy_string(vm, v ? "true" : "false")
    case Nil: 
        return copy_string(vm, "nil")
    case f64:
        buf: [64]byte
        return copy_string(vm, fmt.bprintf(buf[:], "%g", v))
    case ^Object:
        switch v.type {
        case .String:
            return cast(^ObjectString)v
        case .Class:
            return (cast(^ObjectClass)v).name
        case .Native:
            return (cast(^ObjectNative)v).name
        case .Instance:
            return take_string(vm, strings.concatenate({(cast(^ObjectInstance)v).class.name.chars, " instance"}, vm.alloc))
        case .Function:
            return function_to_string(vm, cast(^ObjectFunction)v)
        case .Closure:
            return function_to_string(vm, (cast(^ObjectClosure)v).function)
        case .BoundMethod:
            return function_to_string(vm, (cast(^ObjectBoundMethod)v).method.function)
        case .Upvalue:
            return copy_string(vm, "upvalue")
        }
    }

    unreachable()
}

@(private = "file")
function_to_string :: proc(vm: ^VM, function: ^ObjectFunction) -> ^ObjectString {
    if function.name == nil {
        return copy_string(vm, "<script>")
    }
    return take_string(vm, strings.concatenate({"<fn ", function.name.chars, ">"}, vm.alloc))
}
