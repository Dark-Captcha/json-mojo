# Byte constants for the JSON grammar — declared `comptime` at file scope
# so the compiler folds them at compile time and reuses one register-immediate
# operand across every comparison. Replaces inline `UInt8(ord("{"))` calls,
# which forced the `ord` call into the hot loop in earlier builds and added
# register churn between each comparison.


# Structural characters (RFC 8259 §2)
comptime B_LBRACE: UInt8 = UInt8(0x7B)  # {
comptime B_RBRACE: UInt8 = UInt8(0x7D)  # }
comptime B_LBRACK: UInt8 = UInt8(0x5B)  # [
comptime B_RBRACK: UInt8 = UInt8(0x5D)  # ]
comptime B_COMMA: UInt8 = UInt8(0x2C)  # ,
comptime B_COLON: UInt8 = UInt8(0x3A)  # :
comptime B_QUOTE: UInt8 = UInt8(0x22)  # "
comptime B_BSLASH: UInt8 = UInt8(0x5C)  # \

# Whitespace (RFC 8259 §2)
comptime B_SPACE: UInt8 = UInt8(0x20)
comptime B_TAB: UInt8 = UInt8(0x09)
comptime B_LF: UInt8 = UInt8(0x0A)
comptime B_CR: UInt8 = UInt8(0x0D)

# Literals (RFC 8259 §3)
comptime B_T: UInt8 = UInt8(0x74)  # t
comptime B_F: UInt8 = UInt8(0x66)  # f
comptime B_N: UInt8 = UInt8(0x6E)  # n
comptime B_L: UInt8 = UInt8(0x6C)  # l
comptime B_S: UInt8 = UInt8(0x73)  # s
comptime B_E: UInt8 = UInt8(0x65)  # e (alias of B_E_LOWER)

# JSON Pointer (RFC 6901 §3 — `~0` is `~`, `~1` is `/`)
comptime B_TILDE: UInt8 = UInt8(0x7E)  # ~

# Byte-order mark (RFC 8259 §8.1 — skipped in standard mode, I-JSON error)
comptime B_BOM_0: UInt8 = UInt8(0xEF)
comptime B_BOM_1: UInt8 = UInt8(0xBB)
comptime B_BOM_2: UInt8 = UInt8(0xBF)

# Numbers (RFC 8259 §6)
comptime B_0: UInt8 = UInt8(0x30)  # 0
comptime B_9: UInt8 = UInt8(0x39)  # 9
comptime B_1: UInt8 = UInt8(0x31)  # 1
comptime B_MINUS: UInt8 = UInt8(0x2D)  # -
comptime B_PLUS: UInt8 = UInt8(0x2B)  # +
comptime B_DOT: UInt8 = UInt8(0x2E)  # .
comptime B_E_LOWER: UInt8 = UInt8(0x65)  # e
comptime B_E_UPPER: UInt8 = UInt8(0x45)  # E

# Escape characters (RFC 8259 §7)
comptime B_SLASH: UInt8 = UInt8(0x2F)  # /
comptime B_B: UInt8 = UInt8(0x62)  # b
comptime B_FORM: UInt8 = UInt8(0x66)  # f (alias)
comptime B_NL: UInt8 = UInt8(0x6E)  # n (alias)
comptime B_R: UInt8 = UInt8(0x72)  # r
comptime B_TT: UInt8 = UInt8(0x74)  # t (alias)
comptime B_U: UInt8 = UInt8(0x75)  # u
comptime B_A: UInt8 = UInt8(0x61)  # a
comptime B_F_HEX: UInt8 = UInt8(0x66)  # f hex (alias)
comptime B_A_UPPER: UInt8 = UInt8(0x41)  # A
comptime B_F_UPPER: UInt8 = UInt8(0x46)  # F

# Escape result codepoints
comptime CTRL_BS: UInt8 = UInt8(0x08)  # backspace
comptime CTRL_TAB: UInt8 = UInt8(0x09)
comptime CTRL_LF: UInt8 = UInt8(0x0A)
comptime CTRL_FF: UInt8 = UInt8(0x0C)
comptime CTRL_CR: UInt8 = UInt8(0x0D)

# Boundary
comptime B_CONTROL_MAX: UInt8 = UInt8(0x20)  # bytes < this MUST be escaped
