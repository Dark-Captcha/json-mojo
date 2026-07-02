# tests/run_tests.mojo — single-binary test runner. Each test is a `def` that
# raises on failure; `main` runs every test in an explicit try/except block
# and reports PASS/FAIL. Explicit blocks are a probed decision: named
# functions do not coerce to function-type parameters on this toolchain
# (.probe/SYNTAX.md, finding 8).

from json._internal.number import parse_float, write_int_i64
from json._internal.stage_one import build_structural_index
from json._internal.tape import (
    TAG_ARRAY,
    TAG_BOOLEAN,
    TAG_NULL,
    TAG_NUMBER,
    TAG_OBJECT,
    TAG_STRING,
    build_tape,
    entry_a,
    entry_tag,
)
from json._internal.unicode import validate_utf8_span
from json._internal.writer import ChunkWriter

# The serde battery imports through the package surface — it doubles as the
# __init__ re-export test.
from json import deserialize, serialize, try_deserialize, FromJson, ToJson
from json.document import loads, parse, try_parse
from json.options import (
    DuplicatePolicy,
    ParseMode,
    ParseOptions,
    SerializeOptions,
)
from json.serializer import Serializer, dumps
from json.value import ValueKind


def _assert(condition: Bool, message: String) raises:
    if not condition:
        raise Error("assertion failed: " + message)


def _bytes(text: String) -> List[UInt8]:
    var out = List[UInt8](capacity=text.byte_length())
    out.extend(text.as_bytes())
    return out^


# --- _internal/number: Eisel-Lemire float parsing ------------------------------


def test_parse_float_exact_values() raises:
    var cases_in = List[String]()
    var cases_want = List[Float64]()
    cases_in.append("0")
    cases_want.append(0.0)
    cases_in.append("1.5")
    cases_want.append(1.5)
    cases_in.append("-2.75")
    cases_want.append(-2.75)
    cases_in.append("3.141592653589793")
    cases_want.append(3.141592653589793)
    cases_in.append("1e10")
    cases_want.append(1e10)
    cases_in.append("2.2250738585072014e-308")
    cases_want.append(2.2250738585072014e-308)
    cases_in.append("1.7976931348623157e308")
    cases_want.append(1.7976931348623157e308)
    cases_in.append("6.022e23")
    cases_want.append(6.022e23)

    for i in range(len(cases_in)):
        var raw = _bytes(cases_in[i])
        var got = parse_float(raw, 0, len(raw))
        _assert(Bool(got), "parses: " + cases_in[i])
        _assert(got.value() == cases_want[i], "bit-exact value: " + cases_in[i])


def test_parse_float_contract_edges() raises:
    # Contract: the span is grammar-validated by the caller; None means
    # magnitude overflow only (the caller keeps the raw text — the lossless
    # big-number path); underflow rounds to 0.0.
    var overflow = _bytes("1e999")
    _assert(
        not Bool(parse_float(overflow, 0, len(overflow))),
        "overflow returns None so raw digits survive",
    )
    var underflow = _bytes("1e-999")
    var got = parse_float(underflow, 0, len(underflow))
    _assert(Bool(got), "underflow parses")
    _assert(got.value() == 0.0, "underflow rounds to zero")


# --- _internal/number: integer writing ------------------------------------------


def test_write_int_covers_boundaries() raises:
    var writer = ChunkWriter(capacity_hint=64)
    write_int_i64(writer, 0)
    writer.byte(UInt8(ord(" ")))
    write_int_i64(writer, -1)
    writer.byte(UInt8(ord(" ")))
    write_int_i64(writer, 9223372036854775807)
    writer.byte(UInt8(ord(" ")))
    write_int_i64(writer, -9223372036854775808)
    var got = writer^.finish()
    _assert(
        got == "0 -1 9223372036854775807 -9223372036854775808",
        "boundary integers render exactly, got: " + got,
    )


# --- _internal/unicode: UTF-8 validation -----------------------------------------


def test_utf8_accepts_valid_multibyte() raises:
    var raw = _bytes("héllo 🎨 日本")
    validate_utf8_span(raw, 0, len(raw))  # must not raise


def test_utf8_rejects_attack_bytes() raises:
    var rejected = 0

    var overlong = List[UInt8]()
    overlong.append(UInt8(0xC0))
    overlong.append(UInt8(0x80))
    try:
        validate_utf8_span(overlong, 0, len(overlong))
    except error:
        rejected += 1

    var surrogate = List[UInt8]()
    surrogate.append(UInt8(0xED))
    surrogate.append(UInt8(0xA0))
    surrogate.append(UInt8(0x80))
    try:
        validate_utf8_span(surrogate, 0, len(surrogate))
    except error:
        rejected += 1

    var truncated = List[UInt8]()
    truncated.append(UInt8(0xE2))
    truncated.append(UInt8(0x82))
    try:
        validate_utf8_span(truncated, 0, len(truncated))
    except error:
        rejected += 1

    _assert(rejected == 3, "overlong, surrogate, truncated all rejected")


# --- _internal/stage_one: differential vs a scalar mirror ----------------------
#
# The scalar mirror below implements the same emit semantics one byte at a
# time: structurals outside strings plus unescaped quotes; escape state is
# context-free (as in the SIMD math). Any divergence is a stage-1 bug.


def _is_structural_byte(byte: UInt8) -> Bool:
    return (
        byte == UInt8(ord("{"))
        or byte == UInt8(ord("}"))
        or byte == UInt8(ord("["))
        or byte == UInt8(ord("]"))
        or byte == UInt8(ord(","))
        or byte == UInt8(ord(":"))
    )


def _scalar_structural_index(text: String) -> List[UInt32]:
    var bytes_view = text.as_bytes()
    var positions = List[UInt32]()
    var in_string = False
    var escaped = False
    for i in range(len(bytes_view)):
        var byte = bytes_view[i]
        var this_escaped = escaped
        if not this_escaped and byte == UInt8(ord("\\")):
            escaped = True
        else:
            escaped = False
        if byte == UInt8(ord('"')) and not this_escaped:
            in_string = not in_string
            positions.append(UInt32(i))
        elif _is_structural_byte(byte) and not in_string:
            positions.append(UInt32(i))
    return positions^


def _padded(text: String) -> String:
    # The stage-1 padding contract, as Document will provide it.
    var out = text.copy()
    out.reserve(out.byte_length() + 64)
    return out^


def _differential_case(text: String) raises:
    var padded = _padded(text)
    var simd_index = build_structural_index(padded)
    var scalar = _scalar_structural_index(padded)
    _assert(
        len(simd_index.positions) == len(scalar),
        "position count matches scalar mirror for: " + text,
    )
    for i in range(len(scalar)):
        _assert(
            simd_index.positions[i] == scalar[i],
            "position " + String(i) + " matches for: " + text,
        )


def test_stage_one_matches_scalar_mirror() raises:
    _differential_case('{"a":[1,2,"x,y"]}')
    _differential_case("")
    _differential_case("   ")
    _differential_case("[[[[]]]]")
    _differential_case('{"k":"a\\"b","n":-1.5e2}')
    _differential_case('"\\\\"')  # escaped backslash then closing quote
    _differential_case('"\\\\\\""')  # backslash, escaped quote, close
    _differential_case('{"long":"' + "a" * 200 + '","after":[3,4]}')


def test_stage_one_cross_block_boundaries() raises:
    # Backslash as byte 63, its escaped quote as byte 64 — the carry case.
    var prefix = '{"s":"' + "a" * 57  # next byte lands at offset 63
    _differential_case(prefix + '\\"tail"}')
    # Backslash run straddling the boundary with both parities.
    _differential_case(prefix + '\\\\",  "t":1}')
    _differential_case('{"p":"' + "b" * 56 + '\\\\\\"x"}')
    # A string that spans multiple whole blocks.
    _differential_case('{"big":"' + "c" * 150 + '", "z": [true]}')


# --- _internal/tape: stage-2 grammar + tape shape -------------------------------


def _tape_of(text: String) raises -> List[UInt64]:
    var padded = _padded(text)
    var index = build_structural_index(padded)
    return build_tape(padded, index)


def test_tape_shape_of_nested_document() raises:
    var tape = _tape_of('{"a":[1,true,null],"b":"x"}')
    # Entries: 0 object, 1 key "a", 2 array, 3 number, 4 true, 5 null,
    #          6 key "b", 7 string "x" — object skips to 8, array to 6.
    _assert(len(tape) == 16, "eight two-word entries")
    _assert(entry_tag(tape[0]) == TAG_OBJECT, "root is an object")
    _assert(entry_a(tape[0]) == 2, "object has two members")
    _assert(Int(tape[1]) == 8, "object skip-link past the subtree")
    _assert(entry_tag(tape[2 * 2]) == TAG_ARRAY, "first member value is array")
    _assert(entry_a(tape[2 * 2]) == 3, "array has three elements")
    _assert(Int(tape[2 * 2 + 1]) == 6, "array skip-link")
    _assert(entry_tag(tape[3 * 2]) == TAG_NUMBER, "array[0] is a number")
    _assert(entry_tag(tape[4 * 2]) == TAG_BOOLEAN, "array[1] is a boolean")
    _assert(entry_a(tape[4 * 2]) == 1, "array[1] is true")
    _assert(entry_tag(tape[5 * 2]) == TAG_NULL, "array[2] is null")
    _assert(entry_tag(tape[7 * 2]) == TAG_STRING, "second member is a string")


def test_tape_root_atoms() raises:
    var number = _tape_of("  -12.5e3  ")
    _assert(entry_tag(number[0]) == TAG_NUMBER, "bare number root")
    var literal = _tape_of("true")
    _assert(entry_tag(literal[0]) == TAG_BOOLEAN, "bare literal root")
    var text = _tape_of('"hi"')
    _assert(entry_tag(text[0]) == TAG_STRING, "bare string root")


def _expect_reject(text: String, why: String) raises:
    var rejected = False
    try:
        _ = _tape_of(text)
    except error:
        rejected = True
        _assert(
            String(error).find("json.parse:") >= 0,
            "error is prefixed for: " + why,
        )
    _assert(rejected, "rejected: " + why)


def test_tape_rejects_invalid_documents() raises:
    _expect_reject("{", "unterminated object")
    _expect_reject("[1,]", "trailing comma")
    _expect_reject('{"a"1}', "missing colon")
    _expect_reject('{"a":}', "missing member value")
    _expect_reject("tru", "misspelled literal")
    _expect_reject("01", "leading zero")
    _expect_reject("1.", "bare decimal point")
    _expect_reject("-", "bare minus")
    _expect_reject("1e", "empty exponent")
    _expect_reject('"\\q"', "invalid escape")
    _expect_reject('"\\ud800"', "unpaired high surrogate")
    _expect_reject('"\\udc00"', "lone low surrogate")
    _expect_reject('"\\u12g4"', "bad hex in escape")
    _expect_reject("[1]2", "trailing content")
    _expect_reject("", "empty document")
    _expect_reject("   ", "whitespace-only document")
    _expect_reject("{,}", "comma before any member")
    _expect_reject("[:1]", "colon in array")
    _expect_reject('{"a":1,}', "trailing comma in object")
    _expect_reject("]", "close with no open")


def test_parse_errors_carry_path_context() raises:
    var caught = False
    try:
        _ = _tape_of('{"a":{"b":[1,{"c":tru}]}}')
    except error:
        caught = True
        _assert(
            String(error).find("/a/b/1/c") >= 0,
            "error names the RFC 6901 path, got: " + String(error),
        )
        _assert(String(error).find("at byte") >= 0, "and keeps the offset")
    _assert(caught, "invalid literal rejected")


def test_tape_rejects_raw_control_in_string() raises:
    var bad = String('"a')
    bad += String(chr(1))
    bad += String('b"')
    _expect_reject(bad, "raw control character")


def test_tape_depth_limit_stops_nesting_bombs() raises:
    var bomb = String("[") * 1025
    _expect_reject(bomb, "depth bomb")
    # And a legal depth well under the limit still parses.
    var fine = String("[") * 100 + "1" + String("]") * 100
    var tape = _tape_of(fine)
    _assert(entry_tag(tape[0]) == TAG_ARRAY, "deep-but-legal nesting parses")


def test_tape_duplicate_policies() raises:
    var doc = String('{"k":1,"k":2}')
    # Default first_wins: parses without detection cost.
    var tape = _tape_of(doc)
    _assert(entry_a(tape[0]) == 2, "both members recorded under first_wins")
    # REJECT policy refuses.
    var padded = _padded(doc)
    var index = build_structural_index(padded)
    var rejected = False
    try:
        _ = build_tape[ParseOptions(duplicates=DuplicatePolicy.REJECT)](
            padded, index
        )
    except error:
        rejected = True
    _assert(rejected, "REJECT policy refuses duplicate names")

    # Duplicate detection is by CHARACTER (RFC 7493 §2.3): an escaped
    # spelling of the same name must not evade REJECT or I-JSON.
    var escaped = String('{"a":1,"\\u0061":2}')
    var escaped_padded = _padded(escaped)
    var escaped_index = build_structural_index(escaped_padded)
    var escaped_rejected = False
    try:
        _ = build_tape[ParseOptions(duplicates=DuplicatePolicy.REJECT)](
            escaped_padded, escaped_index
        )
    except error:
        escaped_rejected = True
    _assert(escaped_rejected, "REJECT sees through escaped spellings")
    var ijson_rejected = False
    try:
        _ = parse[ParseOptions(mode=ParseMode.I_JSON)](escaped.copy())
    except error:
        ijson_rejected = True
    _assert(ijson_rejected, "I-JSON sees through escaped spellings")


def test_last_wins_shadows_duplicates() raises:
    comptime lw = ParseOptions(duplicates=DuplicatePolicy.LAST_WINS)
    var doc = parse[lw](String('{"a":1,"b":2,"a":3}'))
    _assert(doc["a"].to[Int64]() == 3, "last occurrence wins the lookup")
    _assert(doc["b"].to[Int64]() == 2, "unrelated members unaffected")
    _assert(doc.__len__() == 2, "len counts surviving members")
    _assert(dumps(doc) == '{"b":2,"a":3}', "dumps emits survivors only")

    var names = String("")
    for member in doc.members():
        names += member.key()
    _assert(names == "ba", "iteration skips shadowed members")

    # Each duplicate shadows the previous survivor.
    var tripled = parse[lw](String('{"k":1,"k":2,"k":3}'))
    _assert(tripled["k"].to[Int64]() == 3, "triple duplicate resolves to last")
    _assert(tripled.__len__() == 1, "triple duplicate leaves one member")
    _assert(dumps(tripled) == '{"k":3}', "dumps emits the one survivor")

    # Escaped spelling is the same name here too.
    var escaped = parse[lw](String('{"a":1,"\\u0061":2}'))
    _assert(
        escaped["a"].to[Int64]() == 2, "escaped duplicate shadows by character"
    )

    # Nesting shadows independently; siblings and the default are untouched.
    var nested = parse[lw](String('{"o":{"x":1,"x":2},"x":9}'))
    _assert(nested["o"]["x"].to[Int64]() == 2, "inner object last-wins")
    _assert(nested["x"].to[Int64]() == 9, "outer member untouched")
    var default_doc = loads('{"k":1,"k":2}')
    _assert(default_doc["k"].to[Int64]() == 1, "default remains first-wins")


def test_dumps_survives_extreme_nesting() raises:
    # The parser is iterative and depth-capped; dumps must be symmetric — a
    # document legally parsed under a raised max_depth serializes without
    # native stack growth (this depth crashed the recursive walker).
    comptime deep = ParseOptions(max_depth=200_000)
    var depth = 150_000
    var text = String("[") * depth + String("]") * depth
    var doc = parse[deep](text.copy())
    var out = dumps(doc)
    _assert(out == text, "extreme-depth dumps round-trips byte-exactly")


# --- document + value: the frozen public API ------------------------------------


def test_minute_one_scene() raises:
    var data = loads('{"name": "Alice", "scores": [95, 87, 92]}')
    _assert(data["name"].to[String]() == "Alice", "string member reads")
    _assert(data["scores"][0].to[Int]() == 95, "indexed number reads")
    _assert(data.kind() == ValueKind.OBJECT, "document forwards kind")
    _assert(data.__len__() == 2, "document forwards len")
    _assert(data["scores"].__len__() == 3, "array len")
    _assert(data["scores"].kind() == ValueKind.ARRAY, "member kind")


def test_value_conversions_and_kinds() raises:
    var doc = loads(
        '{"i":-42,"f":2.5,"b":true,"n":null,"u":18446744073709551615}'
    )
    _assert(doc["i"].to[Int64]() == -42, "to Int64")
    _assert(doc["f"].to[Float64]() == 2.5, "to Float64")
    _assert(doc["b"].to[Bool](), "to Bool")
    _assert(doc["n"].kind() == ValueKind.NULL, "null kind")
    _assert(doc["u"].to[UInt64]() == UInt64(18446744073709551615), "to UInt64")
    _assert(doc["i"].to[Float64]() == -42.0, "integer reads as Float64 too")


def test_string_decoding_lazy_paths() raises:
    var doc = loads('{"plain":"hello","fancy":"a\\nb\\u00e9\\ud83d\\ude00"}')
    _assert(doc["plain"].to[String]() == "hello", "zero-copy plain string")
    var fancy = doc["fancy"].to[String]()
    var expected = String("a\nbé😀")
    _assert(fancy == expected, "escapes, accents, surrogate pair decode")


def test_number_introspection_trio() raises:
    var doc = loads("[9223372036854775807, 9223372036854775808, 1.5, 1e999]")
    _assert(doc[0].fits_int64(), "Int64 max fits")
    _assert(not doc[1].fits_int64(), "Int64 max + 1 does not fit Int64")
    _assert(doc[1].fits_uint64(), "but fits UInt64")
    _assert(not doc[2].fits_int64(), "float form is not an integer")
    _assert(doc[2].fits_float64(), "1.5 fits Float64")
    _assert(not doc[3].fits_float64(), "1e999 overflows Float64")
    _assert(doc[3].kind() == ValueKind.NUMBER, "raw digits survive lossless")


def test_access_errors_are_precise() raises:
    var doc = loads('{"a":1}')
    var caught = 0
    try:
        _ = doc["missing"]
    except error:
        caught += 1
        _assert(
            String(error).find("member not found") >= 0, "missing-key message"
        )
    try:
        _ = doc["a"].to[String]()
    except error:
        caught += 1
    try:
        _ = doc["a"][0]
    except error:
        caught += 1
    _assert(caught == 3, "missing key, kind mismatch, non-array index")


def test_bom_policy() raises:
    var bom_bytes = List[UInt8]()
    bom_bytes.append(UInt8(0xEF))
    bom_bytes.append(UInt8(0xBB))
    bom_bytes.append(UInt8(0xBF))
    bom_bytes.extend(String('{"k":1}').as_bytes())
    var with_bom = String(unsafe_from_utf8=bom_bytes)

    var doc = loads(with_bom.copy())
    _assert(doc["k"].to[Int]() == 1, "standard mode skips the BOM zero-copy")

    var rejected = False
    try:
        _ = parse[ParseOptions(mode=ParseMode.I_JSON)](with_bom.copy())
    except error:
        rejected = True
    _assert(rejected, "I-JSON mode rejects the BOM")


def test_try_parse_twins() raises:
    var good = try_parse(String('{"ok":true}'))
    _assert(Bool(good), "valid document parses")
    _assert(good.value()["ok"].to[Bool](), "and reads")
    var bad = try_parse(String("{nope"))
    _assert(not Bool(bad), "invalid document returns None")


# --- value iteration + JSON Pointer ----------------------------------------------


def test_value_iteration() raises:
    var doc = loads('{"a":1,"b":[10,20,30],"c":"x"}')

    var total = Int64(0)
    for element in doc["b"].elements():
        total += element.to[Int64]()
    _assert(total == 60, "elements() walks the array")

    var names = String("")
    var seen = 0
    for member in doc.members():
        names += member.key()
        seen += 1
    _assert(names == "abc", "members() yields keys in document order")
    _assert(seen == 3, "members() count")

    for member in doc.members():
        if member.key() == "b":
            _assert(
                member.value().__len__() == 3, "member.value() is a live cursor"
            )

    var empty_walks = 0
    for _ in loads("[]").elements():
        empty_walks += 1
    _assert(empty_walks == 0, "empty array iterates zero times")


def test_json_pointer_at() raises:
    var doc = loads('{"a":{"b":[1,{"c~d":2,"e/f":3}]},"":9}')
    _assert(doc.at("/a/b/0").to[Int]() == 1, "path walk")
    _assert(doc.at("/a/b/1/c~0d").to[Int]() == 2, "~0 unescapes to ~")
    _assert(doc.at("/a/b/1/e~1f").to[Int]() == 3, "~1 unescapes to /")
    _assert(doc.at("").kind() == ValueKind.OBJECT, "empty pointer is the root")
    _assert(
        doc.at("/").to[Int]() == 9, 'pointer "/" addresses the ""-named member'
    )

    var caught = 0
    try:
        _ = doc.at("/missing")
    except error:
        caught += 1
    try:
        _ = doc.at("/a/b/9")
    except error:
        caught += 1
    try:
        _ = doc.at("a")
    except error:
        caught += 1
    try:
        _ = doc.at("/a/b/01")
    except error:
        caught += 1
    _assert(caught == 4, "bad pointers are refused")


# --- serializer: dumps + Serializer ----------------------------------------------


def test_dumps_round_trips_compact() raises:
    var source = String('{"a":[1,true,null],"b":"x"}')
    var doc = loads(source.copy())
    _assert(
        dumps(doc) == source, "compact document round-trips byte-identically"
    )


def test_dumps_normalizes_whitespace() raises:
    var doc = loads(' { "a" : [ 1 , 2 ] } ')
    _assert(dumps(doc) == '{"a":[1,2]}', "whitespace collapses to compact form")


def test_dumps_preserves_escapes_and_numbers() raises:
    # Raw-span re-emission: escapes stay escaped, number text stays exact —
    # including a 22-digit integer no binary type could hold (lossless).
    var source = String(
        '{"k":"a\\nb\\u00e9","n":-1.5e-3,"big":9999999999999999999999}'
    )
    var doc = loads(source.copy())
    _assert(dumps(doc) == source, "escapes and raw numbers re-emit verbatim")


def test_dumps_subtree_and_pretty() raises:
    var doc = loads('{"a":{"b":[1,2]}}')
    _assert(dumps(doc["a"]) == '{"b":[1,2]}', "subtree dump")
    var pretty = dumps[options=SerializeOptions(pretty=True)](doc)
    var expected = String(
        '{\n  "a": {\n    "b": [\n      1,\n      2\n    ]\n  }\n}'
    )
    _assert(pretty == expected, "pretty two-space form, got: " + pretty)


def test_serializer_escapes_new_text() raises:
    var s = Serializer()
    s.begin_object()
    s.key('quote"back\\slash')
    s.write_string(String("line\nend") + String(chr(1)))
    s.separator()
    s.key("n")
    s.write_float(2.5)
    s.end_object()
    var got = s^.finish()
    _assert(
        got == '{"quote\\"back\\\\slash":"line\\nend\\u0001","n":2.5}',
        "escaping via Serializer, got: " + got,
    )


def test_serializer_rejects_non_finite() raises:
    var rejected = 0
    var s = Serializer()
    try:
        s.write_float(Float64(0.0) / Float64(0.0))  # NaN
    except error:
        rejected += 1
    try:
        s.write_float(Float64(1.0) / Float64(0.0))  # +inf
    except error:
        rejected += 1
    _assert(rejected == 2, "NaN and infinity are refused per RFC 8259")
    _ = s^.finish()


# --- serde: typed serialize/deserialize, reflection-derived --------------------------
#
# ToolCall declares NEITHER trait — plain structs derive both directions
# through the reflection walks automatically; conforming is only for custom
# control. This zero-ceremony derivation is the contract under test.


struct ToolCall(Copyable, Defaultable, Movable):
    var name: String
    var count: Int64
    var enabled: Bool
    var note: Optional[String]

    def __init__(out self):
        self.name = ""
        self.count = 0
        self.enabled = False
        self.note = None


def test_serde_struct_derivation() raises:
    var call = deserialize[ToolCall](
        '{"name":"search","count":3,"enabled":true,"note":"hi"}'
    )
    _assert(call.name == "search", "string field fills")
    _assert(call.count == 3, "integer field fills")
    _assert(call.enabled, "boolean field fills")
    _assert(call.note.value() == "hi", "optional field fills when present")

    var missing = deserialize[ToolCall](
        '{"name":"x","count":1,"enabled":false}'
    )
    _assert(not Bool(missing.note), "missing member reads as None")

    var text = serialize(call)
    _assert(
        text == '{"name":"search","count":3,"enabled":true,"note":"hi"}',
        "reflection serialize, got: " + text,
    )
    var text_none = serialize(missing)
    _assert(
        text_none == '{"name":"x","count":1,"enabled":false,"note":null}',
        "None serializes as null, got: " + text_none,
    )

    var back = deserialize[ToolCall](serialize(call))
    _assert(
        back.name == call.name
        and back.count == call.count
        and back.enabled == call.enabled
        and back.note.value() == "hi",
        "struct round-trips",
    )


def test_serde_containers() raises:
    # Container SERIALIZATION — List, Dict, Optional through their ToJson
    # extensions, composing recursively.
    var numbers = List[Int64]()
    numbers.append(1)
    numbers.append(2)
    numbers.append(3)
    _assert(serialize(numbers) == "[1,2,3]", "List serializes")

    var scores = Dict[String, Int64]()
    scores["a"] = 1
    scores["b"] = 2
    _assert(
        serialize(scores) == '{"a":1,"b":2}',
        "Dict serializes in insertion order",
    )

    var absent = Optional[Int64](None)
    _assert(serialize(absent) == "null", "None serializes as null")

    var nested = List[List[Int64]]()
    var inner = List[Int64]()
    inner.append(7)
    nested.append(inner^)
    _assert(serialize(nested) == "[[7]]", "containers compose recursively")

    # Container DESERIALIZATION is a documented v1 limitation on this
    # toolchain (three probed walls — see serde.mojo header). The supported
    # read path is the cursor: elements()/members() walks stay fully typed.
    var doc = loads("[1,2,3]")
    var total = Int64(0)
    for element in doc.elements():
        total += element.to[Int64]()
    _assert(total == 6, "cursor walk is the container read path")

    var bad = try_deserialize[ToolCall]('{"name":')
    _assert(not Bool(bad), "try_deserialize returns None on parse failure")


struct AllOptional(Copyable, Defaultable, Movable):
    var x: Optional[Int64]
    var y: Optional[String]

    def __init__(out self):
        self.x = None
        self.y = None


def test_serde_rejects_non_object_values() raises:
    # A scalar or array can never fill struct fields — it must raise, not
    # default-fill. The all-Optional struct is the trap: every field would
    # silently read as None if the walk swallowed the kind mismatch.
    var scalar_raised = False
    try:
        _ = deserialize[AllOptional]("42")
    except error:
        scalar_raised = True
    _assert(scalar_raised, "scalar into struct raises")

    var array_raised = False
    try:
        _ = deserialize[ToolCall]("[1,2]")
    except error:
        array_raised = True
    _assert(array_raised, "array into struct raises")

    # A PRESENT Optional member of the wrong kind still raises — the probe
    # try covers the lookup only, never the conversion.
    var kind_raised = False
    try:
        _ = deserialize[ToolCall](
            '{"name":"x","count":1,"enabled":false,"note":42}'
        )
    except error:
        kind_raised = True
    _assert(kind_raised, "wrong-kind Optional member raises")

    # And the legitimate paths still work.
    var ok = deserialize[AllOptional]('{"x":5}')
    _assert(ok.x.value() == 5, "present Optional fills")
    _assert(not Bool(ok.y), "missing Optional reads as None")


# --- runner ------------------------------------------------------------------


def main() raises:
    print("json-mojo tests")
    var failures = 0

    try:
        test_parse_float_exact_values()
        print("  PASS test_parse_float_exact_values")
    except error:
        print("  FAIL test_parse_float_exact_values:", String(error))
        failures += 1

    try:
        test_parse_float_contract_edges()
        print("  PASS test_parse_float_contract_edges")
    except error:
        print("  FAIL test_parse_float_contract_edges:", String(error))
        failures += 1

    try:
        test_write_int_covers_boundaries()
        print("  PASS test_write_int_covers_boundaries")
    except error:
        print("  FAIL test_write_int_covers_boundaries:", String(error))
        failures += 1

    try:
        test_utf8_accepts_valid_multibyte()
        print("  PASS test_utf8_accepts_valid_multibyte")
    except error:
        print("  FAIL test_utf8_accepts_valid_multibyte:", String(error))
        failures += 1

    try:
        test_utf8_rejects_attack_bytes()
        print("  PASS test_utf8_rejects_attack_bytes")
    except error:
        print("  FAIL test_utf8_rejects_attack_bytes:", String(error))
        failures += 1

    try:
        test_stage_one_matches_scalar_mirror()
        print("  PASS test_stage_one_matches_scalar_mirror")
    except error:
        print("  FAIL test_stage_one_matches_scalar_mirror:", String(error))
        failures += 1

    try:
        test_stage_one_cross_block_boundaries()
        print("  PASS test_stage_one_cross_block_boundaries")
    except error:
        print("  FAIL test_stage_one_cross_block_boundaries:", String(error))
        failures += 1

    try:
        test_tape_shape_of_nested_document()
        print("  PASS test_tape_shape_of_nested_document")
    except error:
        print("  FAIL test_tape_shape_of_nested_document:", String(error))
        failures += 1

    try:
        test_tape_root_atoms()
        print("  PASS test_tape_root_atoms")
    except error:
        print("  FAIL test_tape_root_atoms:", String(error))
        failures += 1

    try:
        test_tape_rejects_invalid_documents()
        print("  PASS test_tape_rejects_invalid_documents")
    except error:
        print("  FAIL test_tape_rejects_invalid_documents:", String(error))
        failures += 1

    try:
        test_parse_errors_carry_path_context()
        print("  PASS test_parse_errors_carry_path_context")
    except error:
        print("  FAIL test_parse_errors_carry_path_context:", String(error))
        failures += 1

    try:
        test_tape_rejects_raw_control_in_string()
        print("  PASS test_tape_rejects_raw_control_in_string")
    except error:
        print("  FAIL test_tape_rejects_raw_control_in_string:", String(error))
        failures += 1

    try:
        test_tape_depth_limit_stops_nesting_bombs()
        print("  PASS test_tape_depth_limit_stops_nesting_bombs")
    except error:
        print(
            "  FAIL test_tape_depth_limit_stops_nesting_bombs:", String(error)
        )
        failures += 1

    try:
        test_tape_duplicate_policies()
        print("  PASS test_tape_duplicate_policies")
    except error:
        print("  FAIL test_tape_duplicate_policies:", String(error))
        failures += 1

    try:
        test_last_wins_shadows_duplicates()
        print("  PASS test_last_wins_shadows_duplicates")
    except error:
        print("  FAIL test_last_wins_shadows_duplicates:", String(error))
        failures += 1

    try:
        test_dumps_survives_extreme_nesting()
        print("  PASS test_dumps_survives_extreme_nesting")
    except error:
        print("  FAIL test_dumps_survives_extreme_nesting:", String(error))
        failures += 1

    try:
        test_minute_one_scene()
        print("  PASS test_minute_one_scene")
    except error:
        print("  FAIL test_minute_one_scene:", String(error))
        failures += 1

    try:
        test_value_conversions_and_kinds()
        print("  PASS test_value_conversions_and_kinds")
    except error:
        print("  FAIL test_value_conversions_and_kinds:", String(error))
        failures += 1

    try:
        test_string_decoding_lazy_paths()
        print("  PASS test_string_decoding_lazy_paths")
    except error:
        print("  FAIL test_string_decoding_lazy_paths:", String(error))
        failures += 1

    try:
        test_number_introspection_trio()
        print("  PASS test_number_introspection_trio")
    except error:
        print("  FAIL test_number_introspection_trio:", String(error))
        failures += 1

    try:
        test_access_errors_are_precise()
        print("  PASS test_access_errors_are_precise")
    except error:
        print("  FAIL test_access_errors_are_precise:", String(error))
        failures += 1

    try:
        test_bom_policy()
        print("  PASS test_bom_policy")
    except error:
        print("  FAIL test_bom_policy:", String(error))
        failures += 1

    try:
        test_try_parse_twins()
        print("  PASS test_try_parse_twins")
    except error:
        print("  FAIL test_try_parse_twins:", String(error))
        failures += 1

    try:
        test_value_iteration()
        print("  PASS test_value_iteration")
    except error:
        print("  FAIL test_value_iteration:", String(error))
        failures += 1

    try:
        test_json_pointer_at()
        print("  PASS test_json_pointer_at")
    except error:
        print("  FAIL test_json_pointer_at:", String(error))
        failures += 1

    try:
        test_dumps_round_trips_compact()
        print("  PASS test_dumps_round_trips_compact")
    except error:
        print("  FAIL test_dumps_round_trips_compact:", String(error))
        failures += 1

    try:
        test_dumps_normalizes_whitespace()
        print("  PASS test_dumps_normalizes_whitespace")
    except error:
        print("  FAIL test_dumps_normalizes_whitespace:", String(error))
        failures += 1

    try:
        test_dumps_preserves_escapes_and_numbers()
        print("  PASS test_dumps_preserves_escapes_and_numbers")
    except error:
        print("  FAIL test_dumps_preserves_escapes_and_numbers:", String(error))
        failures += 1

    try:
        test_dumps_subtree_and_pretty()
        print("  PASS test_dumps_subtree_and_pretty")
    except error:
        print("  FAIL test_dumps_subtree_and_pretty:", String(error))
        failures += 1

    try:
        test_serializer_escapes_new_text()
        print("  PASS test_serializer_escapes_new_text")
    except error:
        print("  FAIL test_serializer_escapes_new_text:", String(error))
        failures += 1

    try:
        test_serializer_rejects_non_finite()
        print("  PASS test_serializer_rejects_non_finite")
    except error:
        print("  FAIL test_serializer_rejects_non_finite:", String(error))
        failures += 1

    try:
        test_serde_struct_derivation()
        print("  PASS test_serde_struct_derivation")
    except error:
        print("  FAIL test_serde_struct_derivation:", String(error))
        failures += 1

    try:
        test_serde_containers()
        print("  PASS test_serde_containers")
    except error:
        print("  FAIL test_serde_containers:", String(error))
        failures += 1

    try:
        test_serde_rejects_non_object_values()
        print("  PASS test_serde_rejects_non_object_values")
    except error:
        print("  FAIL test_serde_rejects_non_object_values:", String(error))
        failures += 1

    if failures == 0:
        print("all tests passed")
    else:
        print(String(failures) + " test(s) failed")
        raise Error("test failures")
