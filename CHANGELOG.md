# Changelog

All notable changes to json-mojo. Format follows Keep a Changelog; versions follow SemVer once past 1.0.

## [1.5.0] — 2026-07-03

Stringify parity: `dumps` grows the Python `indent=N` / JS `space=N` knobs as comptime fields — every combination monomorphizes and the compact path never carries a pretty branch.

### Added

- `SerializeOptions.indent` (default 2) and `SerializeOptions.indent_byte` (default space): indent width per depth level under `pretty=True`; `indent=0` emits newlines without indentation (Python's `indent=0`) and `indent_byte=0x09` covers `indent="\t"` / `space="\t"`. Default output is byte-identical to 1.4.0. Deliberately absent, with reasons in the docstring: `sort_keys` (the future RFC 8785 canonical mode owns key ordering), replacer/default callbacks (the `Value`/serde transform layer's job), `allow_nan` (fixed by contract), `check_circular` (the tape is acyclic by construction).
- `examples/formats.mojo` — a runnable tour of the JSON5 dialect, the three binary siblings (MessagePack, BSON, CBOR round-trips through the one tape), and the RFC 6902/7396 patch functions; `pixi run example` now runs both example files.

### Fixed

- `Dialect` is re-exported from the package root as the public surface always documented — `from json import Dialect` works; previously only the internal `json.options` path had it (the new example caught it).

## [1.4.0] — 2026-07-03

### Added

- `json.tape` — the tier-2 contract's public front door: tags, flags, entry accessors, `make_word0`, `skip_past`, the span decoders and number readers, re-exported for format packages. `msgpack`/`bson`/`cbor` now import only this module and the public surfaces — `json._internal` is private to `json` again.
- Regression vectors pairing non-ASCII text with escape-triggering bytes in all three binary gates (`é\n水` family) — the class the previous vectors missed.

### Changed

- **Parse is 1.5× faster on structural corpora and 1.2× on numbers.** Stage 1 emits atom STARTS as pseudo-structural positions (simdjson-style scalar-edge mask with a cross-block carry), so stage 2 dispatches every value from a position and never re-scans whitespace gaps; number validation fuses span discovery with grammar checking — each byte touched once. citm 1.11–1.29 → 1.62–1.73 GB/s; canada 0.86–0.88 → 0.96–1.11 GB/s; twitter flat (string-bound). The scalar mirror gate grew the same pseudo-structural semantics.
- Tape writes go through a raw pointer over a PROVEN exact capacity bound (every entry consumes its own index position) — the per-append growth branch is dead, `debug_assert` re-proves the bound on every input in assertion builds.
- Parse-error paths are now real RFC 6901: member-name tokens are decoded and `~`/`/`-escaped (`{"a/b":{"m~n":…}}` fails `in /a~1b/m~0n/2`, previously the raw, unescaped, byte-mangled spelling).

### Fixed

- **Binary decoders corrupted non-ASCII strings that also needed JSON escaping** (msgpack, BSON, CBOR — one root cause, three sites): the escape re-emitter rebuilt text through per-byte code points, re-encoding every byte ≥ 0x80. Dirty multibyte strings now pass through byte-exact; encoders were already correct.
- `apply_patch`/`Value.at` corrupted non-ASCII JSON Pointer tokens the same way (RFC 6901 §3); tokens now keep their UTF-8 bytes exactly.
- `move` with `from == path` skipped validating that the location exists (RFC 6902 §4.4 MUST); it now resolves the pointer before returning unchanged.
- `test` compares numbers exactly by normalized decimal components — Float64 rounding could equate values differing past 2^53, and magnitudes beyond Float64 fell to raw-text comparison that missed equal spellings (`1e999` vs `1E999`).
- Pointer evaluation into an object with a duplicated member name now fails as RFC 6901 §4 requires (Value's own `[]` stays documented first-wins).
- A BOM abutting a bare atom root (`EF BB BF` then `1`) parses again — the two form one scalar run in the new index, whose only start position lay inside the BOM and was skipped; the builder now dispatches the straddled atom at the ruling boundary. Regression case added (JSONTestSuite has no BOM+bare-atom file).
- Explicit exponents of any length classify correctly: accumulation clamps far past Float64's range instead of wrapping Int64 — `1e9999999999999999999` is overflow (was 0.0), its negative twin underflows to 0.0 (was an overflow error).
- `ParseMode.I_JSON` now enforces RFC 7493 §2.1's noncharacter prohibition (U+FDD0..U+FDEF and the last two code points of every plane), raw or escaped — comptime-gated, so the standard-mode parser is byte-identical to before.
- `references/`: RFC 8949 is now vendored per the repo's IETF-vendoring policy, the provenance re-fetch loop includes every vendored RFC (6902, 7396, and 8949 were missing), and the invalid-UTF-8 mandate is cited to RFC 3629 §3 (the MUST lives there, not §10).

## [1.3.0] — 2026-07-03

Every format, both directions: MessagePack, BSON, and CBOR all decode AND encode over the stable tape contract. (JSON5's encode story is `dumps` itself — JSON output is valid JSON5 by inclusion.)

### Added

- `msgpack.dumps(doc | value) -> List[UInt8]`: smallest-width integers, float64 decimals, decoded strings, count-prefixed containers; JSON5 `Infinity`/`NaN` encode as native float ±inf/nan (the formats hold what RFC 8259 text cannot — stated). Gate grew to 17 exact-byte encode vectors + 36 decode→encode→decode round-trips (0 fails).
- The `bson` sibling package (bsonspec.org v1.1): `bson.decode` (double/string/document/array/bool/null/int32/int64; ObjectId, datetime, binary, regex, decimal128, code, timestamp, min/max keys REJECTED BY NAME; non-finite doubles rejected — JSON cannot hold them) and `bson.dumps` (object roots only — BSON's top level is a document; int32/int64/double width selection; UInt64 beyond Int64.MAX rejected by name — BSON has no unsigned 64-bit type; NUL-bearing keys rejected — names are cstrings). Gate: 15 accept / 10 exact-byte encode / 15 round-trips / 16 rejects.
- The `cbor` sibling package (RFC 8949): `cbor.decode` (full integer ladder to ±64-bit, float16/32/64 — half-precision expanded per Appendix D, definite AND indefinite arrays/maps/text strings; byte strings, tags, `undefined`, simple values, non-finite floats, and negatives below Int64.MIN rejected by name) and `cbor.dumps` (shortest-form heads, definite lengths, float64 decimals). Gate seeded from RFC 8949 Appendix A: 43 accept / 17 exact-byte encode / 43 round-trips / 18 rejects.
- All three binary gates run under `pixi run test` alongside the unit battery and msgpack vectors.

## [1.2.0] — 2026-07-03

All three extension tiers ship their first residents.

### Added — tier 1: `Dialect.JSON5`

- `ParseOptions.dialect` (`Dialect.JSON` default, zero-cost comptime; `Dialect.JSON5` per json5.org over ES5.1): comments, trailing commas, single-quoted strings, unquoted ES5.1 IdentifierName keys (full Unicode tables, generated by `tests/gen_unicode_id.py`), hex numbers, `Infinity`/`NaN`, leading `+`, bare-dot decimals, `\x`/`\v`/`\0`/self-escapes, line continuations, the full JSON5 whitespace set. Gated on the json5-tests conformance suite: **112/0** (`tests/run_json5_suite.sh`).
- JSON5 parses onto the SAME six-kind tape over the original text — cursor, serde, duplicate policies (which see through JSON5 spellings), and `dumps` inherit it. `FLAG_REENCODE` marks lexemes RFC 8259 cannot re-emit verbatim: readers decode them with the JSON5 decoder, and `dumps` NORMALIZES them to standard JSON (hex re-based, `+`/bare dots repaired, strings re-escaped; `Infinity`/`NaN` refuse to serialize per the RFC 8259 contract). The JSON5 scanner is scalar by design; the Performance Promise stays on `Dialect.JSON` (dialect erasure keeps it untouched).

### Added — tier 2: the tape contract, exercised

- `Document(unsafe_buffer=..., unsafe_tape=...)`: the public constructor for binary front-ends — wrap a decoder-built buffer + tape, inherit every consumer. Decoder-rendered text lives past the input in the same buffer (the appended-tail pattern; `FLAG_ARENA` stays reserved for true side-arenas).
- The `msgpack` sibling package (same repo): `msgpack.decode(bytes) -> json.Document` — full integer/float/str/array/map coverage, strings zero-copy where clean and re-escaped into the tail where not, UTF-8 validated, depth-capped. Policy, stated: non-string map keys, `bin`, `ext`, and non-finite floats are rejected by name. `dumps` of a decoded document is msgpack → JSON transcoding. Gated on generated vectors (`tests/gen_msgpack_vectors.py`): 36 accept / 5 float / 14 reject, 0 fails.

### Added — tier 3: the `Value` surface, consumed

- `apply_patch` (RFC 6902: add / remove / replace / move / copy / test, sequential semantics, failures name the operation index) and `merge_patch` (RFC 7396) — built entirely on the public cursor surface plus `dumps`; RFC 6902/7396 texts vendored into `references/`.

### Changed

- The whole project now speaks the named byte alphabet: every inline `UInt8(ord(...))`/hex literal became a `comptime` constant (`bytes.mojo` grew `B_TILDE`, `B_L`, `B_S`, the BOM trio; UTF-8 lead masks and MessagePack format bytes are named where they live). Identical codegen, uniform style.
- `_keys_equal` and the duplicate policies compare by decoded character across ALL spellings (RFC and JSON5 alike).

## [1.1.0] — 2026-07-03

### Added

- JSON Lines (NDJSON): `loads_lines` / `dumps_lines` — one `Document` per record, blank lines skipped, errors carry the 1-based line on top of the engine's byte offset and path.
- RFC 7464 text sequences: `loads_seq` / `dumps_seq` (`RS json LF` framing; non-blank preamble rejected).
- File sugar: `load(path)` / `dump(doc, path)` — bytes reach this library's validator directly.
- `benchmarks/simdjson_bench.cpp`: the C++ simdjson ceiling harness; the same-machine measurement now lives in PERF.md (twitter 5.9–6.0 GB/s, citm 5.8–6.0, canada 1.49–1.53).
- Tape contract: `FLAG_ARENA` reserved for binary front-end side-arena spans (extension tier 2).

### Performance

- SIMD digit-run scanning in number validation: canada.json parse 0.72–0.80 → **0.86–0.88 GB/s** (58% of the measured C++ simdjson ceiling on that corpus), every correctness gate unchanged.

### Findings

- The container-deserialization ownership wall fell (`.probe/SYNTAX.md`, finding 36): an accumulating raising extension body is legal when the raise path consumes the partial container via `destroy_with` — the working `List`/`Dict` implementation is retained in `.probe/probe_container_walls.mojo`. Re-landing is blocked by a compiler ICE on cross-module `conforms_to(List[X], FromJson)` queries on this pin; re-attempted each nightly.
- ehsanmok/json re-attempted on this pin: still fails to compile (stage-1 SIMD width inference), its published claim still unverifiable.

The public surface grew additively to fourteen functions + ten types; everything frozen at 0.1.0 is unchanged.

## [0.1.0] — 2026-07-02

Ground-up rewrite of the retired prototype; nothing was carried forward unverified.

### Added

- Two-stage engine: branchless SIMD structural indexing (64-byte blocks, table-lookup classification, prefix-XOR string state) feeding an iterative RFC 8259 grammar validator that builds a six-kind skip-link tape.
- Lazy everything: numbers and strings live as raw spans — lossless (arbitrary-precision digits survive), converted only when read; per-body UTF-8 validation (ASCII documents pay zero).
- Move-in ownership: `parse(body^)` — zero copies, no lifetime annotations, self-guaranteed SIMD tail padding.
- Public surface: `parse` / `loads` / `loads_bytes` / `try_parse`, `dumps` (compact + pretty), `deserialize[T]` / `try_deserialize[T]` / `serialize`, `Document`, `Value` (`to[T]`, indexing, `elements()` / `members()` iteration, RFC 6901 `at()`, `fits_*` introspection), comptime `ParseOptions` (duplicate policy, depth limit 1024, BOM policy, I-JSON mode), `FromJson` / `ToJson` / `Serializer`.
- All three duplicate policies implemented: `FIRST_WINS` (default — parsing pays nothing), `LAST_WINS` (parse-time tape shadowing: lookup, iteration, `len()`, and `dumps` present the surviving member), `REJECT` (raises; forced by I-JSON mode). Detection compares member names by character (RFC 7493 §2.3) — an escaped spelling cannot evade it.
- Iterative serializer walker: `dumps` keeps depth on a heap frame stack (innermost frame cached in locals), so a document parsed under any `max_depth` serializes without native-stack risk — symmetric with the parser's bomb defense, and measured neutral-to-faster than the recursive emitter it replaced.
- Zero-ceremony serde derivation: plain structs deserialize and serialize via compile-time reflection with no trait declared; `Optional` fields read missing members as `None`; non-object values are refused for struct targets (never silently default-filled).
- Parse errors carry the byte offset and the RFC 6901 path of the failure, under one `json.parse:` prefix.
- Eisel-Lemire float parsing (bit-exact vs C `strtod`, 1,500-case differential) with the exact big-integer slow path; two-digit-table integer writers; SIMD string escaping in the serializer.
- Verification stack: JSONTestSuite harness (283/0, with the 95/95 byte-exact `dumps ∘ loads` round-trip gate folded into its RESULT line), four regenerable differential/fuzz generators with committed suites (regeneration is byte-identical after `pixi run format`), Python acceptance differential.
- Measurement stack: corpus benchmarks, prototype-compatible micro benchmarks, stage breakdown and 1–32 core scaling diagnostics, EmberJson same-machine head-to-head; PERF.md records all of it.
- Documentation: ARCHITECTURE.md (purpose, contracts, type scheme, system map), references/ standards map with five vendored RFCs, `.probe/SYNTAX.md` with 35 verified toolchain findings.

### Known limitations

- `deserialize` into `List` / `Dict` is blocked by probed toolchain walls (`.probe/SYNTAX.md` 21–23); read containers through the typed cursor walk. Container serialization is complete.
- Streaming / JSON Lines deferred to a fast-follow.
