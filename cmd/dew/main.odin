package main

import "../../vm"

main :: proc() {

    function := vm.Function{}
    constant := vm.function_add_constant(&function, 1.2)

    vm.function_write(&function, u8(vm.Opcode.Constant), 123)
    vm.function_write(&function, u8(constant), 123)
    vm.function_write(&function, u8(vm.Opcode.Return), 123)

    vm.disassemble_function(&function, "test function")
    
}