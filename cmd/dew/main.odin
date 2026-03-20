package main

import "../../vm"

main :: proc() {

    dewvm := vm.vm_new()

    function := vm.Function{}

    vm.function_write_constant(&function, 1.2, 123)
    vm.function_write_constant(&function, 3.4, 123)
    vm.function_write(&function, u8(vm.Opcode.Add), 123)

    vm.function_write_constant(&function, 5.6, 123)

    vm.function_write(&function, u8(vm.Opcode.Div), 123)
    vm.function_write(&function, u8(vm.Opcode.Negate), 123)
    
    vm.function_write(&function, u8(vm.Opcode.Return), 123)

    vm.disassemble_function(&function, "test function")
    vm.vm_interpret(dewvm, &function)
    vm.vm_free(dewvm)
    vm.function_free(&function)
}