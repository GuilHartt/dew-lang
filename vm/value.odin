package vm

import "core:fmt"

Nil :: struct {}

Value :: union {
    Nil,
    bool,
    f64,
    ^Object,
}

print_value :: proc(value: Value) {
    switch v in value {
        case bool: fmt.print(v ? "true" : "false")
        case Nil:  fmt.print("nil")
        case f64:  fmt.printf("%g", v)
        case ^Object: print_object(v)
    }
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

is_nil :: #force_inline proc "contextless" (v: Value) -> bool {
    _, ok := v.(Nil)
    return ok
}

as_string :: #force_inline proc "contextless" (v: Value) -> ^ObjectString {
    if obj, ok := v.(^Object); ok {
        return cast(^ObjectString)obj
    }
    return nil
}

check_number :: #force_inline proc "contextless" (v: Value) -> (f64, bool) {
    return v.(f64)
}

check_bool :: #force_inline proc "contextless" (v: Value) -> (bool, bool) {
    return v.(bool)
}

check_string :: #force_inline proc "contextless" (v: Value) -> (^ObjectString, bool) {
    if obj, ok := v.(^Object); ok {
        return cast(^ObjectString)obj, true
    }
    return nil, false
}