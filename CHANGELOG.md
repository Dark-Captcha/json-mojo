# Changelog

All notable changes to json-mojo. Format follows Keep a Changelog; versions follow SemVer once past 1.0.

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
