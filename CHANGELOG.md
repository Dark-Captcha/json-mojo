# Changelog

All notable changes to json-mojo. Format follows Keep a Changelog; versions follow SemVer once past 1.0.

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
