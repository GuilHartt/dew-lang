package vm

Opcode :: enum u8 {
    Constant,
    Add, Sub, Mul, Div,
    Negate,
    Return,
}