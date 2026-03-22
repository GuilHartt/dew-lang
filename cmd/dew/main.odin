package main

import "core:bufio"
import "core:fmt"
import "core:os"
import "../../vm"

dewvm: vm.VM

main :: proc() {
    switch len(os.args) {
        case 1: repl()
        case 2: run(os.args[1])
        case:
            fmt.eprintln("Usage: dew [path]")
            os.exit(64)
    }
}

repl :: proc() {
    vm.init(&dewvm)

    reader: bufio.Reader
    bufio.reader_init(&reader, os.to_stream(os.stdin))

    for {
        fmt.print("> ")

        line, err := bufio.reader_read_string(&reader, '\n')
        if err != nil do break

        vm.interpret(&dewvm, line)

        delete(line)
    }
}

run :: proc(path: string) {
    source, err := os.read_entire_file(path, context.allocator)
    if err != nil {
        fmt.eprintfln("Could not open file \"%s\".", path)
        os.exit(74)
    }
    defer delete(source)

    vm.init(&dewvm)

    #partial switch vm.interpret(&dewvm, string(source)) {
        case .CompileError: os.exit(65)
        case .RuntimeError: os.exit(70)
    }
}