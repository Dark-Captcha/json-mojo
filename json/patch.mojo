# patch — RFC 6902 JSON Patch and RFC 7396 JSON Merge Patch, built ENTIRELY
# on the public `Value` surface plus `dumps` (extension tier 3, landed
# in-core at 1.2.0 as the tier's first consumers — proof the cursor surface
# carries a standards library without touching the engine).
#
# Application is emission: each operation re-emits the document with a splice
# along the target pointer's spine (subtrees copy via `dumps`'s raw-span
# re-emission — byte-exact). Emission recurses along that spine only, so
# depth is bounded by the parsed document's own `max_depth`.
#
# Equality (`test` op, RFC 6902 §4.6) compares strings by decoded value and
# numbers numerically EXACTLY: same-kind 64-bit integers directly; every
# other pairing by normalized decimal components (sign, significant digits,
# exponent) — no rounding step, so no width-dependent false verdicts.

from json.document import Document, loads, parse
from json.serializer import Serializer, dumps
from json.value import Value, ValueKind


def apply_patch(doc: Document, patch: Document) raises -> Document:
    """Apply an RFC 6902 patch (an array of operation objects) and return the
    patched document. Operations apply sequentially — each sees the result of
    the previous — and any failure (including a failed `test`) raises with
    the operation's index; the input documents are never modified."""
    if patch.kind() != ValueKind.ARRAY:
        raise Error("json.patch: a patch document must be an array")
    var current = dumps(doc)
    var index = 0
    for op in patch.root().elements():
        try:
            var snapshot = parse(current.copy())
            current = _apply_one(snapshot.root(), op)
        except error:
            raise Error(
                String(error) + " (patch operation " + String(index) + ")"
            )
        index += 1
    return parse(current^)


def merge_patch(doc: Document, patch: Document) raises -> Document:
    """Apply an RFC 7396 merge patch: objects merge member-wise, `null`
    removes a member, and any non-object patch replaces the target."""
    var out = _merge_emit(doc.root(), patch.root())
    return parse(out^)


# --- RFC 6902 operations ---------------------------------------------------------


def _apply_one[
    o1: ImmutOrigin, o2: ImmutOrigin
](doc: Value[o1], op: Value[o2]) raises -> String:
    if op.kind() != ValueKind.OBJECT:
        raise Error("json.patch: an operation must be an object")
    var name = op["op"].to[String]()
    var path = _tokens(op["path"].to[String]())
    if name == "add":
        return _splice(doc, path, 0, dumps(op["value"]), _MODE_ADD)
    if name == "replace":
        return _splice(doc, path, 0, dumps(op["value"]), _MODE_REPLACE)
    if name == "remove":
        return _splice(doc, path, 0, String(""), _MODE_REMOVE)
    if name == "move":
        var source = _tokens(op["from"].to[String]())
        if _same_tokens(source, path):
            # RFC 6902 §4.4: the "from" location MUST exist even when the
            # move has no effect — resolve it before returning unchanged.
            _ = _resolve(doc, source, 0)
            return dumps(doc)
        if _is_prefix(source, path):
            raise Error("json.patch: cannot move a value into its own child")
        var lifted = dumps(_resolve(doc, source, 0))
        var without = parse(_splice(doc, source, 0, String(""), _MODE_REMOVE))
        return _splice(without.root(), path, 0, lifted^, _MODE_ADD)
    if name == "copy":
        var source_copy = _tokens(op["from"].to[String]())
        var copied = dumps(_resolve(doc, source_copy, 0))
        return _splice(doc, path, 0, copied^, _MODE_ADD)
    if name == "test":
        if not _values_equal(_resolve(doc, path, 0), op["value"]):
            raise Error("json.patch: test failed at " + op["path"].to[String]())
        return dumps(doc)
    raise Error("json.patch: unknown op '" + name + "'")


# RFC 6901 pointer bytes — local on purpose: this module touches no
# json._internal namespace (the tier-3 claim in the header).
comptime _P_SLASH: UInt8 = UInt8(0x2F)  # /
comptime _P_TILDE: UInt8 = UInt8(0x7E)  # ~
comptime _P_0: UInt8 = UInt8(0x30)
comptime _P_1: UInt8 = UInt8(0x31)
comptime _P_9: UInt8 = UInt8(0x39)

comptime _MODE_ADD: Int = 0
comptime _MODE_REPLACE: Int = 1
comptime _MODE_REMOVE: Int = 2


def _tokens(pointer: String) raises -> List[String]:
    """RFC 6901 pointer → reference tokens (`~1` → `/`, `~0` → `~`),
    split and unescaped byte-wise: a pointer is UTF-8 text and a token
    keeps its bytes exactly (RFC 6901 §3 specifies characters — re-encoding
    each byte as its own code point would corrupt every non-ASCII name).
    The empty pointer addresses the whole document (zero tokens)."""
    var out = List[String]()
    if pointer.byte_length() == 0:
        return out^
    var bytes = pointer.as_bytes()
    if bytes[0] != _P_SLASH:
        raise Error("json.patch: a non-empty pointer must start with '/'")
    var token = List[UInt8]()
    var i = 1
    while i <= pointer.byte_length():
        if i == pointer.byte_length() or bytes[i] == _P_SLASH:
            out.append(String(unsafe_from_utf8=token))
            token = List[UInt8]()
        elif bytes[i] == _P_TILDE:
            if i + 1 >= pointer.byte_length():
                raise Error("json.patch: dangling '~' in pointer")
            if bytes[i + 1] == _P_0:
                token.append(_P_TILDE)
            elif bytes[i + 1] == _P_1:
                token.append(_P_SLASH)
            else:
                raise Error("json.patch: invalid '~' escape in pointer")
            i += 1
        else:
            token.append(bytes[i])
        i += 1
    return out^


def _same_tokens(a: List[String], b: List[String]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def _is_prefix(prefix: List[String], path: List[String]) -> Bool:
    if len(prefix) >= len(path):
        return False
    for i in range(len(prefix)):
        if prefix[i] != path[i]:
            return False
    return True


def _array_index(token: String, length: Int, allow_end: Bool) raises -> Int:
    """RFC 6901 §4 array index: digits only, no leading zero except `0`;
    `-` means past-the-end where the operation allows it."""
    if token == "-":
        if allow_end:
            return length
        raise Error("json.patch: '-' is not addressable here")
    var bytes = token.as_bytes()
    if len(bytes) == 0:
        raise Error("json.patch: empty array index")
    if len(bytes) > 1 and bytes[0] == _P_0:
        raise Error("json.patch: array index has a leading zero")
    var value = 0
    for i in range(len(bytes)):
        var b = bytes[i]
        if b < _P_0 or b > _P_9:
            raise Error("json.patch: array index is not a number: " + token)
        value = value * 10 + Int(b - _P_0)
        if value > (1 << 47):
            raise Error("json.patch: array index out of range")
    var limit = length + 1 if allow_end else length
    if value >= limit:
        raise Error("json.patch: array index " + token + " out of bounds")
    return value


def _require_unique[
    origin: ImmutOrigin
](value: Value[origin], token: String) raises:
    """RFC 6901 §4: a pointer whose referenced member name is not unique in
    its object does not resolve — evaluation fails rather than guessing.
    (`Value.__getitem__` itself is documented first-wins; pointer
    evaluation is stricter by specification.)"""
    var seen = 0
    for member in value.members():
        if member.key() == token:
            seen += 1
            if seen > 1:
                raise Error(
                    "json.patch: pointer is ambiguous — duplicate member"
                    " name: " + token
                )


def _resolve[
    origin: ImmutOrigin
](value: Value[origin], path: List[String], depth: Int) raises -> Value[origin]:
    """Walk tokens from `depth` to the addressed value (read-only)."""
    if depth == len(path):
        return value.copy()
    if value.kind() == ValueKind.OBJECT:
        _require_unique(value, path[depth])
        return _resolve(value[path[depth]], path, depth + 1)
    if value.kind() == ValueKind.ARRAY:
        var i = _array_index(path[depth], value.__len__(), False)
        return _resolve(value[i], path, depth + 1)
    raise Error("json.patch: pointer descends into a non-container")


def _quote(text: String) raises -> String:
    var serializer = Serializer(capacity_hint=text.byte_length() + 8)
    serializer.write_string(text)
    return serializer^.finish()


def _splice[
    origin: ImmutOrigin
](
    value: Value[origin],
    path: List[String],
    depth: Int,
    replacement: String,
    mode: Int,
) raises -> String:
    """Re-emit `value` with the operation applied at the pointer's end."""
    if depth == len(path):
        # The whole-document (or fully-descended) target.
        if mode == _MODE_REMOVE:
            raise Error("json.patch: cannot remove the whole document")
        return replacement.copy()
    var token = path[depth].copy()
    var last = depth + 1 == len(path)
    if value.kind() == ValueKind.OBJECT:
        _require_unique(value, token)
        var out = String("{")
        var found = False
        var first = True
        for member in value.members():
            var key = member.key()
            var is_target = key == token
            if is_target and last and mode == _MODE_REMOVE:
                found = True
                continue  # dropped member
            if not first:
                out += ","
            first = False
            out += _quote(key)
            out += ":"
            if is_target:
                found = True
                if last:
                    out += replacement  # add-on-existing and replace both swap
                else:
                    out += _splice(
                        member.value(), path, depth + 1, replacement, mode
                    )
            else:
                out += dumps(member.value())
        if not found:
            if last and mode == _MODE_ADD:
                if not first:
                    out += ","
                out += _quote(token)
                out += ":"
                out += replacement
            else:
                raise Error("json.patch: member not found: " + token)
        out += "}"
        return out^
    if value.kind() == ValueKind.ARRAY:
        var length = value.__len__()
        var insert = last and mode == _MODE_ADD
        var index = _array_index(token, length, insert)
        var out_a = String("[")
        var emitted = 0
        for i in range(length):
            if insert and i == index:
                if emitted > 0:
                    out_a += ","
                out_a += replacement  # inserted BEFORE element i
                emitted += 1
            if last and not insert and i == index:
                if mode == _MODE_REMOVE:
                    continue  # dropped element
                if emitted > 0:
                    out_a += ","
                out_a += replacement  # replaced element
                emitted += 1
                continue
            if not last and i == index:
                if emitted > 0:
                    out_a += ","
                out_a += _splice(value[i], path, depth + 1, replacement, mode)
                emitted += 1
                continue
            if emitted > 0:
                out_a += ","
            out_a += dumps(value[i])
            emitted += 1
        if insert and index == length:
            if emitted > 0:
                out_a += ","
            out_a += replacement
        out_a += "]"
        return out_a^
    raise Error("json.patch: pointer descends into a non-container")


# --- RFC 6902 §4.6 equality --------------------------------------------------------


struct _Decimal(Copyable, Movable):
    """A number spelling normalized for exact comparison: sign, significant
    digits (no leading or trailing zeros), and the decimal exponent scaling
    them. Zero is canonical: positive, empty digits, exponent 0."""

    var negative: Bool
    var digits: String
    var exponent: Int

    def __init__(out self, *, negative: Bool, digits: String, exponent: Int):
        self.negative = negative
        self.digits = digits
        self.exponent = exponent


def _decompose(text: String) raises -> _Decimal:
    """Normalize one RFC 8259 number spelling (`dumps` output — grammar
    already validated) to its exact decimal components."""
    var bytes = text.as_bytes()
    var n = len(bytes)
    var i = 0
    var negative = False
    if i < n and bytes[i] == UInt8(ord("-")):
        negative = True
        i += 1
    var digits = List[UInt8]()
    var fraction_length = 0
    while i < n and bytes[i] >= _P_0 and bytes[i] <= _P_9:
        digits.append(bytes[i])
        i += 1
    if i < n and bytes[i] == UInt8(ord(".")):
        i += 1
        while i < n and bytes[i] >= _P_0 and bytes[i] <= _P_9:
            digits.append(bytes[i])
            fraction_length += 1
            i += 1
    var explicit_exponent = 0
    var exponent_negative = False
    if i < n and (bytes[i] == UInt8(ord("e")) or bytes[i] == UInt8(ord("E"))):
        i += 1
        if i < n and (
            bytes[i] == UInt8(ord("+")) or bytes[i] == UInt8(ord("-"))
        ):
            exponent_negative = bytes[i] == UInt8(ord("-"))
            i += 1
        while i < n and bytes[i] >= _P_0 and bytes[i] <= _P_9:
            explicit_exponent = explicit_exponent * 10 + Int(bytes[i] - _P_0)
            if explicit_exponent > (1 << 40):
                raise Error("json.patch: number exponent out of range")
            i += 1
    if exponent_negative:
        explicit_exponent = -explicit_exponent

    # value = digits × 10^(explicit − fraction_length); strip zeros.
    var exponent = explicit_exponent - fraction_length
    var first = 0
    while first < len(digits) and digits[first] == _P_0:
        first += 1
    var last = len(digits)
    while last > first and digits[last - 1] == _P_0:
        last -= 1
        exponent += 1
    if first == last:
        return _Decimal(negative=False, digits=String(""), exponent=0)
    var significant = List[UInt8]()
    for k in range(first, last):
        significant.append(digits[k])
    return _Decimal(
        negative=negative,
        digits=String(unsafe_from_utf8=significant),
        exponent=exponent,
    )


def _decimal_equal(a: String, b: String) raises -> Bool:
    """Exact decimal equality of two number spellings — no rounding step,
    so no width-dependent false verdicts (RFC 6902 §4.6 "numerically
    equal")."""
    var da = _decompose(a)
    var db = _decompose(b)
    return (
        da.negative == db.negative
        and da.exponent == db.exponent
        and da.digits == db.digits
    )


def _values_equal[
    o1: ImmutOrigin, o2: ImmutOrigin
](a: Value[o1], b: Value[o2]) raises -> Bool:
    var ka = a.kind()
    if ka != b.kind():
        return False
    if ka == ValueKind.NULL:
        return True
    if ka == ValueKind.BOOLEAN:
        return a.to[Bool]() == b.to[Bool]()
    if ka == ValueKind.STRING:
        return a.to[String]() == b.to[String]()
    if ka == ValueKind.NUMBER:
        if a.fits_int64() and b.fits_int64():
            return a.to[Int64]() == b.to[Int64]()
        if a.fits_uint64() and b.fits_uint64():
            return a.to[UInt64]() == b.to[UInt64]()
        # Mixed spellings, fractions, or magnitudes past 64 bits: compare
        # the DECIMAL VALUES exactly — each spelling normalizes to
        # (sign, significant digits, exponent) and the components compare.
        # No rounding step exists, so Float64's 2^53 artifacts and
        # overflow-to-text fallbacks cannot produce a false verdict.
        return _decimal_equal(dumps(a), dumps(b))
    if ka == ValueKind.ARRAY:
        if a.__len__() != b.__len__():
            return False
        for i in range(a.__len__()):
            if not _values_equal(a[i], b[i]):
                return False
        return True
    # Objects: same member set, each equal (first-wins lookup semantics).
    if a.__len__() != b.__len__():
        return False
    for member in a.members():
        var key = member.key()
        try:
            if not _values_equal(member.value(), b[key]):
                return False
        except _:
            return False  # member missing in b
    return True


# --- RFC 7396 merge patch ----------------------------------------------------------


def _merge_emit[
    o1: ImmutOrigin, o2: ImmutOrigin
](target: Value[o1], patch: Value[o2]) raises -> String:
    if patch.kind() != ValueKind.OBJECT:
        return _strip_nulls(patch)
    var base_is_object = target.kind() == ValueKind.OBJECT
    var out = String("{")
    var first = True
    if base_is_object:
        for member in target.members():
            var key = member.key()
            var in_patch = True
            try:
                _ = patch[key]
            except _:
                in_patch = False
            if in_patch:
                continue  # handled below (merged or removed)
            if not first:
                out += ","
            first = False
            out += _quote(key)
            out += ":"
            out += dumps(member.value())
    for member in patch.members():
        var key = member.key()
        if member.value().kind() == ValueKind.NULL:
            continue  # null removes (or never adds)
        if not first:
            out += ","
        first = False
        out += _quote(key)
        out += ":"
        var target_has = False
        if base_is_object:
            try:
                _ = target[key]
                target_has = True
            except _:
                target_has = False
        if target_has:
            out += _merge_emit(target[key], member.value())
        else:
            out += _strip_nulls(member.value())
    out += "}"
    return out^


def _strip_nulls[origin: ImmutOrigin](value: Value[origin]) raises -> String:
    """A merge patch applied to an absent target: object patches recurse with
    an empty target, so their `null` members vanish; everything else copies."""
    if value.kind() != ValueKind.OBJECT:
        return dumps(value)
    var out = String("{")
    var first = True
    for member in value.members():
        if member.value().kind() == ValueKind.NULL:
            continue
        if not first:
            out += ","
        first = False
        out += _quote(member.key())
        out += ":"
        out += _strip_nulls(member.value())
    out += "}"
    return out^
