package vm

import "core:fmt"

@(private)
register_builtins :: proc(vm: ^VM) {
	register_native(vm, "println", 1, println_native)
	register_native(vm, "str", 1, str_native)
	register_native(vm, "len", 1, len_native)
	register_native(vm, "assert", 1, assert_native)
}

@(private = "file")
println_native :: proc(call: ^NativeCall) -> (Value, bool) {
	print_value(call.args[0])
	fmt.println()
	return val_nil(), true
}

@(private = "file")
str_native :: proc(call: ^NativeCall) -> (Value, bool) {
	return val_obj(value_to_string(call.vm, call.args[0])), true
}

@(private = "file")
len_native :: proc(call: ^NativeCall) -> (value: Value, ok: bool) {
	text := expect_string(call, 0) or_return
	return val_number(f64(len(text))), true
}

@(private = "file")
assert_native :: proc(call: ^NativeCall) -> (value: Value, ok: bool) {
	condition := expect_bool(call, 0) or_return
	if !condition do return raise(call, "Assertion failed.")
	return val_nil(), true
}