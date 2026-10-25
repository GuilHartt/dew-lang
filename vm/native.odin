package vm

NativeCall :: struct {
	vm:   ^VM,
	name: string,
	args: []Value,
}

NativeFn :: #type proc(call: ^NativeCall) -> (Value, bool)

raise :: proc(call: ^NativeCall, format: string, args: ..any) -> (Value, bool) {
    runtime_error(call.vm, format, ..args)
    return val_nil(), false
}

expect_number :: proc(call: ^NativeCall, index: int) -> (f64, bool) {
	number, ok := check_number(call.args[index])
	if !ok do return 0, arg_error(call, index, "number")
	return number, true
}

expect_bool :: proc(call: ^NativeCall, index: int) -> (bool, bool) {
	value, ok := check_bool(call.args[index])
	if !ok do return false, arg_error(call, index, "bool")
	return value, true
}

expect_string :: proc(call: ^NativeCall, index: int) -> (string, bool) {
	text, ok := check_string(call.args[index])
	if !ok do return "", arg_error(call, index, "string")
	return text.chars, true
}

@(private = "file", cold)
arg_error :: proc(call: ^NativeCall, index: int, expected: string) -> bool {
	runtime_error(
		call.vm,
		"bad argument #%d to '%s' (%s expected, got %s)",
		index + 1, call.name, expected, value_type_name(call.args[index]),
	)
	return false
}