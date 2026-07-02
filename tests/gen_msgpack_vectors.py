#!/usr/bin/env python3
# MessagePack differential vectors for the tier-2 sibling decoder. Bytes are
# packed BY HAND here (no msgpack dependency — the packing IS the spec
# reference), and expectations are JSON text for structural vectors or exact
# Float64 values for float vectors (float text rendering is Mojo's
# shortest-round-trip writer, so text comparison would test the writer, not
# the decoder). Regenerate: python3 tests/gen_msgpack_vectors.py && pixi run format
import struct

OUT = "tests/msgpack_generated.mojo"


def h(b: bytes) -> str:
    return b.hex()


def fixstr(s: str) -> bytes:
    raw = s.encode("utf-8")
    assert len(raw) < 32
    return bytes([0xA0 | len(raw)]) + raw


def str8(s: str) -> bytes:
    raw = s.encode("utf-8")
    return bytes([0xD9, len(raw)]) + raw


def str16(s: str) -> bytes:
    raw = s.encode("utf-8")
    return bytes([0xDA]) + struct.pack(">H", len(raw)) + raw


ACCEPT = []  # (hex, expected_json)


def acc(b: bytes, expected: str):
    ACCEPT.append((h(b), expected))


# Scalars at the root.
acc(bytes([0x2A]), "42")
acc(bytes([0x00]), "0")
acc(bytes([0x7F]), "127")
acc(bytes([0xFF]), "-1")
acc(bytes([0xE0]), "-32")
acc(bytes([0xC0]), "null")
acc(bytes([0xC2]), "false")
acc(bytes([0xC3]), "true")
acc(fixstr("hi"), '"hi"')
acc(fixstr(""), '""')
acc(fixstr("héllo"), '"héllo"')
# Dirty strings render escaped into the tail.
acc(fixstr('a"b'), '"a\\"b"')
acc(fixstr("a\\b"), '"a\\\\b"')
acc(fixstr("li\nne\t"), '"li\\nne\\t"')
acc(fixstr("\x01"), '"\\u0001"')
acc(str8("x" * 200), '"' + "x" * 200 + '"')
acc(str16("y" * 300), '"' + "y" * 300 + '"')
# Integer width ladder.
acc(bytes([0xCC, 200]), "200")
acc(bytes([0xCD]) + struct.pack(">H", 65535), "65535")
acc(bytes([0xCE]) + struct.pack(">I", 4294967295), "4294967295")
acc(
    bytes([0xCF]) + struct.pack(">Q", 18446744073709551615),
    "18446744073709551615",
)
acc(bytes([0xD0]) + struct.pack(">b", -100), "-100")
acc(bytes([0xD1]) + struct.pack(">h", -30000), "-30000")
acc(bytes([0xD2]) + struct.pack(">i", -2000000000), "-2000000000")
acc(
    bytes([0xD3]) + struct.pack(">q", -9223372036854775808),
    "-9223372036854775808",
)
acc(
    bytes([0xD3]) + struct.pack(">q", 9223372036854775807),
    "9223372036854775807",
)
# Containers.
acc(bytes([0x90]), "[]")
acc(bytes([0x80]), "{}")
acc(bytes([0x93, 0x01]) + fixstr("x") + bytes([0xC0]), '[1,"x",null]')
acc(
    bytes([0x82])
    + fixstr("a")
    + bytes([0x01])
    + fixstr("b")
    + bytes([0x91, 0xC3]),
    '{"a":1,"b":[true]}',
)
acc(bytes([0x91, 0x91, 0x90]), "[[[]]]")
acc(bytes([0x81]) + fixstr("k") + bytes([0x80]), '{"k":{}}')
# Duplicate keys survive on the tape (lookup stays first-wins).
acc(
    bytes([0x82]) + fixstr("k") + bytes([0x01]) + fixstr("k") + bytes([0x02]),
    '{"k":1,"k":2}',
)
# array16 / map16 above the fix ranges.
arr = bytes([0xDC]) + struct.pack(">H", 20) + bytes([0x07] * 20)
acc(arr, "[" + ",".join(["7"] * 20) + "]")
m = bytes([0xDE]) + struct.pack(">H", 3)
for i in range(3):
    m += fixstr(f"k{i}") + bytes([i])
acc(m, '{"k0":0,"k1":1,"k2":2}')
# Depth exactly 1024 is legal.
acc(bytes([0x91] * 1023 + [0x90]), "[" * 1024 + "]" * 1024)

FLOATS = []  # (hex, python_float_repr)
FLOATS.append((h(bytes([0xCB]) + struct.pack(">d", 1.5)), "1.5"))
FLOATS.append((h(bytes([0xCB]) + struct.pack(">d", -2.75)), "-2.75"))
FLOATS.append(
    (
        h(bytes([0xCB]) + struct.pack(">d", 3.141592653589793)),
        "3.141592653589793",
    )
)
FLOATS.append((h(bytes([0xCA]) + struct.pack(">f", 1.5)), "1.5"))
FLOATS.append((h(bytes([0xCA]) + struct.pack(">f", -0.25)), "-0.25"))

REJECT = []  # (hex, why)
REJECT.append((h(bytes([0xC1])), "0xc1"))
REJECT.append((h(bytes([0xC4, 0x01, 0x00])), "bin8"))
REJECT.append((h(bytes([0xC7, 0x01, 0x01, 0x00])), "ext8"))
REJECT.append((h(bytes([0xD4, 0x01, 0x00])), "fixext1"))
REJECT.append((h(bytes([0x81, 0x01, 0x2A])), "non-string map key"))
REJECT.append((h(bytes([0xA5, 0x68, 0x69])), "truncated fixstr"))
REJECT.append((h(bytes([0xCD, 0x01])), "truncated uint16"))
REJECT.append((h(bytes([0x91])), "unclosed array"))
REJECT.append((h(bytes([0x2A, 0x2A])), "trailing bytes"))
REJECT.append((h(bytes([])), "empty input"))
REJECT.append((h(bytes([0x91] * 1025 + [0x90])), "depth 1025 bomb"))
REJECT.append((h(bytes([0xA2, 0xFF, 0xFE])), "invalid UTF-8 string"))
REJECT.append((h(bytes([0xCB]) + struct.pack(">d", float("nan"))), "NaN"))
REJECT.append(
    (h(bytes([0xCA]) + struct.pack(">f", float("inf"))), "float32 inf")
)


ENCODE = []  # (json_text, expected_hex) — exact smallest-width bytes


def enc(json_text: str, packed: bytes):
    ENCODE.append((json_text, h(packed)))


import struct as _s

enc("127", bytes([0x7F]))
enc("128", bytes([0xCC, 128]))
enc("-32", bytes([0xE0]))
enc("-33", bytes([0xD0]) + _s.pack(">b", -33))
enc("65535", bytes([0xCD]) + _s.pack(">H", 65535))
enc("-300", bytes([0xD1]) + _s.pack(">h", -300))
enc("4294967295", bytes([0xCE]) + _s.pack(">I", 4294967295))
enc("4294967296", bytes([0xD3]) + _s.pack(">q", 4294967296))
enc(
    "18446744073709551615",
    bytes([0xCF]) + _s.pack(">Q", 18446744073709551615),
)
enc(
    "-9223372036854775808",
    bytes([0xD3]) + _s.pack(">q", -9223372036854775808),
)
enc("1.5", bytes([0xCB]) + _s.pack(">d", 1.5))
enc('"hi"', fixstr("hi"))
enc("[]", bytes([0x90]))
enc("{}", bytes([0x80]))
enc("null", bytes([0xC0]))
enc("true", bytes([0xC3]))
enc('{"a":[1,2]}', bytes([0x81]) + fixstr("a") + bytes([0x92, 0x01, 0x02]))


def mojo_str(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


with open(OUT, "w") as f:
    w = f.write
    w("# GENERATED by tests/gen_msgpack_vectors.py — do not edit by hand.\n")
    w("# Regenerate: python3 tests/gen_msgpack_vectors.py && pixi run format\n")
    w("# MessagePack decode vectors: structural cases compare `dumps` text,\n")
    w(
        "# float cases compare exact Float64 values, reject cases must raise.\n\n"
    )
    w("from json import dumps, loads\n")
    w("from msgpack import decode\n")
    w("from msgpack import dumps as mp_dumps\n\n\n")
    w("def _unhex(hex: String) raises -> List[UInt8]:\n")
    w("    var out = List[UInt8](capacity=hex.byte_length() // 2)\n")
    w("    var chars = hex.as_bytes()\n")
    w("    var i = 0\n")
    w("    while i + 1 < len(chars):\n")
    w("        var hi = _nibble(chars[i])\n")
    w("        var lo = _nibble(chars[i + 1])\n")
    w("        out.append(UInt8((hi << 4) | lo))\n")
    w("        i += 2\n")
    w("    return out^\n\n\n")
    w("def _nibble(c: UInt8) raises -> Int:\n")
    w('    if c >= UInt8(ord("0")) and c <= UInt8(ord("9")):\n')
    w('        return Int(c - UInt8(ord("0")))\n')
    w('    return Int(c - UInt8(ord("a"))) + 10\n\n\n')
    w("def _to_hex(data: List[UInt8]) -> String:\n")
    w('    comptime HEX = "0123456789abcdef"\n')
    w("    var hb = HEX.as_bytes()\n")
    w('    var out = String("")\n')
    w("    for i in range(len(data)):\n")
    w("        out += chr(Int(hb[Int((data[i] >> 4) & 15)]))\n")
    w("        out += chr(Int(hb[Int(data[i] & 15)]))\n")
    w("    return out^\n\n\n")
    w("def main() raises:\n")
    w("    var fails = 0\n")
    w("    var accepts = 0\n")
    w("    var floats = 0\n")
    w("    var rejects = 0\n")
    w("    var encodes = 0\n")
    w("    var roundtrips = 0\n\n")
    for hex_bytes, expected in ACCEPT:
        w("    try:\n")
        w(f"        var doc = decode(_unhex({mojo_str(hex_bytes)}))\n")
        w("        var got = dumps(doc)\n")
        w(f"        if got == {mojo_str(expected)}:\n")
        w("            accepts += 1\n")
        w("        else:\n")
        w(
            f"            print(\"FAIL accept:\", {mojo_str(hex_bytes)}, \"got\", got)\n"
        )
        w("            fails += 1\n")
        w("    except error:\n")
        w(
            f"        print(\"FAIL accept raised:\", {mojo_str(hex_bytes)}, String(error))\n"
        )
        w("        fails += 1\n")
    w("\n")
    for hex_bytes, value in FLOATS:
        w("    try:\n")
        w(f"        var fdoc = decode(_unhex({mojo_str(hex_bytes)}))\n")
        w(f"        if fdoc.to[Float64]() == Float64({value}):\n")
        w("            floats += 1\n")
        w("        else:\n")
        w(f"            print(\"FAIL float:\", {mojo_str(hex_bytes)})\n")
        w("            fails += 1\n")
        w("    except error:\n")
        w(
            f"        print(\"FAIL float raised:\", {mojo_str(hex_bytes)}, String(error))\n"
        )
        w("        fails += 1\n")
    w("\n")
    for json_text, expected_hex in ENCODE:
        w("    try:\n")
        w(f"        var edoc = loads(String({mojo_str(json_text)}))\n")
        w("        var packed = mp_dumps(edoc)\n")
        w("        var got_hex = _to_hex(packed)\n")
        w(f"        if got_hex == {mojo_str(expected_hex)}:\n")
        w("            encodes += 1\n")
        w("        else:\n")
        w(
            f"            print(\"FAIL encode:\", {mojo_str(json_text)},"
            ' "got", got_hex)\n'
        )
        w("            fails += 1\n")
        w("    except error:\n")
        w(
            f"        print(\"FAIL encode raised:\", {mojo_str(json_text)},"
            " String(error))\n"
        )
        w("        fails += 1\n")
    w("\n")
    for hex_bytes, expected in ACCEPT:
        w("    try:\n")
        w(f"        var r1 = decode(_unhex({mojo_str(hex_bytes)}))\n")
        w("        var r2 = decode(mp_dumps(r1))\n")
        w(f"        if dumps(r2) == {mojo_str(expected)}:\n")
        w("            roundtrips += 1\n")
        w("        else:\n")
        w(
            f"            print(\"FAIL roundtrip:\", {mojo_str(hex_bytes)},"
            ' "got", dumps(r2))\n'
        )
        w("            fails += 1\n")
        w("    except error:\n")
        w(
            f"        print(\"FAIL roundtrip raised:\","
            f" {mojo_str(hex_bytes)}, String(error))\n"
        )
        w("        fails += 1\n")
    w("\n")
    for hex_bytes, why in REJECT:
        w("    try:\n")
        w(f"        _ = decode(_unhex({mojo_str(hex_bytes)}))\n")
        w(f"        print(\"FAIL reject accepted: {why}\")\n")
        w("        fails += 1\n")
        w("    except error:\n")
        w("        rejects += 1\n")
    w("\n")
    w('    print("msgpack: accepts=", accepts, " floats=", floats,')
    w(' " rejects=", rejects, " encodes=", encodes,')
    w(' " roundtrips=", roundtrips, " fails=", fails)\n')
    w("    if fails > 0:\n")
    w('        raise Error("MSGPACK VECTORS FAILED")\n')
    w('    print("MSGPACK OK")\n')

print(
    f"wrote {OUT}: {len(ACCEPT)} accept, {len(FLOATS)} float, {len(REJECT)} reject"
)
