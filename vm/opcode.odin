package vm

Opcode :: enum u8 {
    Constant,
    Nil, True, False,
    Equal, Greater, Less,
    Add, Sub, Mul, Div,
    Not,
    Negate,
    Return,
}