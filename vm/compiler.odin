package vm

import "core:fmt"

compile :: proc(source: string) {
    scanner: Scanner
    scanner_init(&scanner, source)

    line := i32(-1)
    for {
        token := scan_token(&scanner)
        if token.line != line {
            fmt.printf("%4d ", token.line)
            line = token.line
        } else {
            fmt.print("   | ")
        }

        fmt.printfln("%v '%s'", token.type, token.lexeme)

        if token.type == .Eof do break
    }
}