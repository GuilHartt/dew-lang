package vm

import "core:fmt"

Value :: distinct f32

print_value :: proc(value: Value) {
    fmt.printf("%g", value)
}