package vm

Opcode :: enum u8 {
    Constant,
    Nil,
    True,
    False,
    Pop,
    GetGlobal,
    DefineGlobal,
    SetGlobal,
    Equal,
    Greater,
    Less,
    Add,
    Sub,
    Mul,
    Div,
    Not,
    Negate,
    Print,
    Return,
}