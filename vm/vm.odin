package vm

import "base:runtime"
import "core:fmt"

STACK_MAX :: max(u8)

InterpretResult :: enum u8 {
    Ok, CompileError, RuntimeError
}

VM :: struct {
    function: ^Function,
    ip: int,
    stack: [STACK_MAX]Value,
    stack_top: int,
}

init :: proc(vm: ^VM) {
    vm_reset_stack(vm)
}

destroy :: proc(vm: ^VM) {
}

interpret :: proc(vm: ^VM, source: string) -> InterpretResult {
    function: Function

    if !compile(source, &function) {
        function_free(&function)
        return .CompileError
    }

    vm.function = &function
    vm.ip = 0

    result := vm_run(vm)
    function_free(&function)

    return result
}

@(private)
vm_reset_stack :: proc(vm: ^VM) {
    vm.stack_top = 0
}

@(private)
push :: #force_inline proc "contextless" (vm: ^VM, value: Value) {
    vm.stack[vm.stack_top] = value
    vm.stack_top += 1
}

@(private)
pop :: #force_inline proc "contextless" (vm: ^VM) -> Value {
    vm.stack_top -= 1
    return vm.stack[vm.stack_top]
}

@(private="file")
read_byte :: #force_inline proc "contextless" (vm: ^VM) -> u8 {
    b := vm.function.instructions[vm.ip]
    vm.ip += 1
    return b
}

@(private="file")
read_short :: #force_inline proc "contextless" (vm: ^VM) -> u16 {
    low  := u16(vm.function.instructions[vm.ip])
    high := u16(vm.function.instructions[vm.ip + 1])
    vm.ip += 2
    return low | (high << 8)
}

@(private="file")
read_constant :: #force_inline proc "contextless" (vm: ^VM) -> Value {
    index := read_short(vm)
    return vm.function.constants[index]
}

@(private, rodata)
LUT := [Opcode](proc "preserve/none" (^VM) -> InterpretResult) {
    .Constant = do_constant,
    .Add      = do_add,
    .Sub      = do_sub,
    .Mul      = do_mul,
    .Div      = do_div,
    .Negate   = do_negate,
    .Return   = do_return,
}

@(private)
vm_run :: proc "preserve/none" (vm: ^VM) -> InterpretResult {
    if vm.ip >= len(vm.function.instructions) {
        return .Ok
    }

    when DEW_DEBUG_TRACE {
        context = runtime.default_context()

        fmt.print("          ")
        for i in 0..< vm.stack_top {
            fmt.print("[ ")
            print_value(vm.stack[i])
            fmt.print(" ]")
        }
        fmt.println()

        disassemble_instruction(vm.function, vm.ip)
    }

    return #must_tail LUT[Opcode(read_byte(vm))](vm)
}

@(private="file")
do_constant :: proc "preserve/none" (vm: ^VM) -> InterpretResult {
    constant := read_constant(vm)
    push(vm, constant)
    return #must_tail vm_run(vm)
}

@(private="file")
do_negate :: proc "preserve/none" (vm: ^VM) -> InterpretResult {
    push(vm, -pop(vm))
    return #must_tail vm_run(vm)
}

@(private="file")
do_add :: proc "preserve/none" (vm: ^VM) -> InterpretResult {
    b := pop(vm)
    a := pop(vm)
    push(vm, a + b)
    return #must_tail vm_run(vm)
}

@(private="file")
do_sub :: proc "preserve/none" (vm: ^VM) -> InterpretResult {
    b := pop(vm)
    a := pop(vm)
    push(vm, a - b)
    return #must_tail vm_run(vm)
}

@(private="file")
do_mul :: proc "preserve/none" (vm: ^VM) -> InterpretResult {
    b := pop(vm)
    a := pop(vm)
    push(vm, a * b)
    return #must_tail vm_run(vm)
}

@(private="file")
do_div :: proc "preserve/none" (vm: ^VM) -> InterpretResult {
    b := pop(vm)
    a := pop(vm)
    push(vm, a / b)
    return #must_tail vm_run(vm)
}

@(private="file")
do_return :: proc "preserve/none" (vm: ^VM) -> InterpretResult {
    context = runtime.default_context()
    print_value(pop(vm))
    fmt.println()
    return .Ok
}