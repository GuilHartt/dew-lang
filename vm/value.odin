package vm

import "core:fmt"

Nil :: struct {}

Value :: union {
    Nil,
    bool,
    f64,
}

print_value :: proc(value: Value) {
    switch v in value {
        case bool: fmt.print(v ? "true" : "false")
        case Nil:  fmt.print("nil")
        case f64:  fmt.printf("%g", v)
    }
}