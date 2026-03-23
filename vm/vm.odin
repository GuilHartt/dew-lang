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

@(private)
vm_reset_stack :: proc(vm: ^VM) {
    vm.stack_top = 0
}

@(private="file", cold)
runtime_error :: proc "contextless" (vm: ^VM, format: string, args: ..any) {
    context = runtime.default_context()
    fmt.eprintfln(format, ..args)

    instruction := vm.ip - 1
    line := function_get_line(vm.function, instruction)
    fmt.eprintfln("[line %d] in script", line)

    vm_reset_stack(vm)
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
push :: #force_inline proc "contextless" (vm: ^VM, value: Value) {
    vm.stack[vm.stack_top] = value
    vm.stack_top += 1
}

@(private)
pop :: #force_inline proc "contextless" (vm: ^VM) -> Value {
    vm.stack_top -= 1
    return vm.stack[vm.stack_top]
}

@(private)
peek :: #force_inline proc "contextless" (vm: ^VM, distance: int) -> Value {
    return vm.stack[vm.stack_top - 1 - distance]
}

@(private)
is_falsey :: #force_inline proc "contextless" (value: Value) -> bool {
    #partial switch v in value {
        case Nil:  return true
        case bool: return !v
        case:      return false
    }
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

@(private="file")
check_numbers :: #force_inline proc "contextless" (vm: ^VM) -> (f64, f64, InterpretResult) {
    b_val, b_is_num := peek(vm, 0).(f64)
    a_val, a_is_num := peek(vm, 1).(f64)

    if !a_is_num || !b_is_num {
        runtime_error(vm, "Operands must be numbers.")
        return 0, 0, .RuntimeError
    }

    pop(vm)
    pop(vm)
    return a_val, b_val, .Ok
}

@(private, rodata)
LUT := [Opcode](proc "preserve/none" (^VM) -> InterpretResult) {
    .Constant = do_constant,
    .Nil      = do_nil,
    .True     = do_true,
    .False    = do_false,
    .Equal    = do_equal,
    .Greater  = do_greater,
    .Less     = do_less,
    .Add      = do_add,
    .Sub      = do_sub,
    .Mul      = do_mul,
    .Div      = do_div,
    .Not      = do_not,
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
do_nil :: proc "preserve/none" (vm: ^VM) -> InterpretResult {
    push(vm, Nil{})
    return #must_tail vm_run(vm)
}

@(private="file")
do_true :: proc "preserve/none" (vm: ^VM) -> InterpretResult {
    push(vm, true)
    return #must_tail vm_run(vm)
}

@(private="file")
do_false :: proc "preserve/none" (vm: ^VM) -> InterpretResult {
    push(vm, false)
    return #must_tail vm_run(vm)
}

@(private="file")
do_equal :: proc "preserve/none" (vm: ^VM) -> InterpretResult {
    b := pop(vm)
    a := pop(vm)
    push(vm, a == b)
    return #must_tail vm_run(vm)
}

@(private="file")
do_negate :: proc "preserve/none" (vm: ^VM) -> InterpretResult {

    val, is_num := peek(vm, 0).(f64)
    if !is_num {
        runtime_error(vm, "Operand must be a number.")
        return .RuntimeError
    }

    pop(vm)
    push(vm, -val)

    return #must_tail vm_run(vm)
}

@(private="file")
do_greater :: proc "preserve/none" (vm: ^VM) -> InterpretResult {
    a, b := check_numbers(vm) or_return
    push(vm, a > b)
    return #must_tail vm_run(vm)
}

@(private="file")
do_less :: proc "preserve/none" (vm: ^VM) -> InterpretResult {
    a, b := check_numbers(vm) or_return
    push(vm, a < b)
    return #must_tail vm_run(vm)
}

@(private="file")
do_add :: proc "preserve/none" (vm: ^VM) -> InterpretResult {
    a, b := check_numbers(vm) or_return
    push(vm, a + b)
    return #must_tail vm_run(vm)
}

@(private="file")
do_sub :: proc "preserve/none" (vm: ^VM) -> InterpretResult {
    a, b := check_numbers(vm) or_return
    push(vm, a - b)
    return #must_tail vm_run(vm)
}

@(private="file")
do_mul :: proc "preserve/none" (vm: ^VM) -> InterpretResult {
    a, b := check_numbers(vm) or_return
    push(vm, a * b)
    return #must_tail vm_run(vm)
}

@(private="file")
do_div :: proc "preserve/none" (vm: ^VM) -> InterpretResult {
    a, b := check_numbers(vm) or_return
    push(vm, a / b)
    return #must_tail vm_run(vm)
}

@(private="file")
do_not :: proc "preserve/none" (vm: ^VM) -> InterpretResult {
    push(vm, Value(is_falsey(pop(vm))))
    return #must_tail vm_run(vm)
}

@(private="file")
do_return :: proc "preserve/none" (vm: ^VM) -> InterpretResult {
    context = runtime.default_context()
    print_value(pop(vm))
    fmt.println()
    return .Ok
}