package vm

import "core:strings"
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
    sp: int,
    objects: ^Object,
}

init :: proc(vm: ^VM) {
    vm_reset_stack(vm)
}

destroy :: proc(vm: ^VM) {
    free_objects(vm)
}

@(private)
vm_reset_stack :: proc(vm: ^VM) {
    vm.sp = 0
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

    if !compile(vm, source, &function) {
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
    vm.stack[vm.sp] = value
    vm.sp += 1
}

@(private)
pop :: #force_inline proc "contextless" (vm: ^VM) -> Value {
    vm.sp -= 1
    return vm.stack[vm.sp]
}

@(private)
drop :: #force_inline proc "contextless" (vm: ^VM, count: int = 1) {
    vm.sp -= 1
}

@(private)
peek :: #force_inline proc "contextless" (vm: ^VM, distance: int) -> Value {
    return vm.stack[vm.sp - 1 - distance]
}

@(private="file")
is_falsey :: #force_inline proc "contextless" (value: Value) -> bool {
    #partial switch v in value {
        case Nil:  return true
        case bool: return !v
        case:      return false
    }
}

@(private="file")
concatenate :: #force_inline proc "contextless" (vm: ^VM, lhs, rhs: ^ObjectString) {
    context = runtime.default_context()
   
    result := allocate_string(vm,  strings.concatenate({lhs.chars, rhs.chars}))
    drop(vm, 2)

    push(vm, val_obj(result))
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
    rhs_num, rhs_is_num := check_number(peek(vm, 0))
    lhs_num, lhs_is_num := check_number(peek(vm, 1))

    if !lhs_is_num || !rhs_is_num {
        runtime_error(vm, "Operands must be numbers.")
        return 0, 0, .RuntimeError
    }

    drop(vm, 2)
    return lhs_num, rhs_num, .Ok
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
    push(vm, val_bool(true))
    return #must_tail vm_run(vm)
}

@(private="file")
do_false :: proc "preserve/none" (vm: ^VM) -> InterpretResult {
    push(vm, val_bool(false))
    return #must_tail vm_run(vm)
}

@(private="file")
do_equal :: proc "preserve/none" (vm: ^VM) -> InterpretResult {
    rhs := pop(vm)
    lhs := pop(vm)
    push(vm, val_bool(lhs == rhs))
    return #must_tail vm_run(vm)
}

@(private="file")
do_negate :: proc "preserve/none" (vm: ^VM) -> InterpretResult {
    num, is_num := check_number(peek(vm, 0))
    if !is_num {
        runtime_error(vm, "Operand must be a number.")
        return .RuntimeError
    }

    pop(vm)
    push(vm, -num)

    return #must_tail vm_run(vm)
}

@(private="file")
do_greater :: proc "preserve/none" (vm: ^VM) -> InterpretResult {
    lhs, rhs := check_numbers(vm) or_return
    push(vm, val_bool(lhs > rhs))
    return #must_tail vm_run(vm)
}

@(private="file")
do_less :: proc "preserve/none" (vm: ^VM) -> InterpretResult {
    lhs, rhs := check_numbers(vm) or_return
    push(vm, val_bool(lhs < rhs))
    return #must_tail vm_run(vm)
}

@(private="file")
do_add :: proc "preserve/none" (vm: ^VM) -> InterpretResult {
    rhs_num, rhs_is_num := check_number(peek(vm, 0))
    lhs_num, lhs_is_num := check_number(peek(vm, 1))

    if lhs_is_num && rhs_is_num {
        drop(vm, 2)
        push(vm, val_number(lhs_num + rhs_num))
        return #must_tail vm_run(vm)
    }

    rhs_str, rhs_is_str := check_string(peek(vm, 0))
    lhs_str, lhs_is_str := check_string(peek(vm, 1))

    if lhs_is_str && rhs_is_str {
        concatenate(vm, lhs_str, rhs_str)
        return #must_tail vm_run(vm)
    }

    runtime_error(vm, "Operands must be two numbers or two strings.")
    return .RuntimeError
}

@(private="file")
do_sub :: proc "preserve/none" (vm: ^VM) -> InterpretResult {
    lhs, rhs := check_numbers(vm) or_return
    push(vm, val_number(lhs - rhs))
    return #must_tail vm_run(vm)
}

@(private="file")
do_mul :: proc "preserve/none" (vm: ^VM) -> InterpretResult {
    lhs, rhs := check_numbers(vm) or_return
    push(vm, val_number(lhs * rhs))
    return #must_tail vm_run(vm)
}

@(private="file")
do_div :: proc "preserve/none" (vm: ^VM) -> InterpretResult {
    lhs, rhs := check_numbers(vm) or_return
    push(vm, val_number(lhs / rhs))
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