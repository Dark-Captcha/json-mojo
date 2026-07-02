# Roadmap

> **Version:** 1.1.0 | **Updated:** 2026-07-03

Direction after v1.1.0, ordered by leverage. PERF.md's weakness table is the performance source of truth; ARCHITECTURE.md's extension tiers are the scope source of truth.

---

## Near — performance (attack the simdjson gap: 14–19% of ceiling on structural corpora)

| Item                                       | Why                                                                                                                                       |
| ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------ |
| Stage-1 atom hints                         | Stop stage 2 re-scanning whitespace gaps stage 1 already saw                                                                              |
| Tape-append fast path                      | Capacity is exact-bounded already; the growth-check branch remains on every append                                                        |
| String/key machinery vs the ceiling        | simdjson holds 5.9–6.0 GB/s on twitter/citm same-machine (PERF.md); the structural-corpora gap is the Performance Promise's open frontier |
| Digit-run hints from validation to access  | canada at 58% of ceiling: stage 2 validates digits, access re-parses them — emit spans the Eisel-Lemire path can reuse                    |

## Near — capability

| Item                                        | Why                                                                                                                                                                                                   |
| ------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Container deserialization (`List` / `Dict`) | The ownership wall FELL (finding 36; working mechanism retained in `.probe/probe_container_walls.mojo`) — blocked only by a compiler ICE on cross-module conformance queries; re-attempt each nightly |
| Publish the conda package                   | Source-only today. v1.1.0 sorts above the retired prototype's `json` v1.0.0 recipe, so the versioning conflict is resolved — the remaining decision is the package name                               |

## Mid — extension tier 1 (ARCHITECTURE.md)

| Item                                              | Why                                                                                                                                                                                                                                                                                                              |
| ------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `Dialect.JSON5` on the reserved options parameter | Comments / trailing commas / unquoted keys as a typed, zero-cost-when-off opt-in. Spec-exact bar: the FULL JSON5 grammar (ES5.1 IdentifierName keys included), gated on the json5-tests conformance corpus; the JSON5 specialization may use a simpler stage 1 — the Performance Promise stays on `Dialect.JSON` |
| `parse_view` borrowed zero-copy variant           | For arena/buffer-reuse experts, behind an origin-ergonomics probe                                                                                                                                                                                                                                                |

## Far — ecosystem (extension tiers 2–3, separate libraries)

| Item                                                    | Form                                                                                                                                                                                                                                                                                  |
| ------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Binary front-ends (MessagePack first, then CBOR / BSON) | Sibling decoders emitting this library's stable tape — one decoder inherits cursor, serde, and JSON transcoding. `FLAG_ARENA` is reserved for their number text (tape contract, 1.1.0); foreign types (bin/ext/dates) map-or-reject per sibling README — the six tape tags never grow |
| JSONPath (RFC 9535), Patch (RFC 6902), Schema           | Consumers of the public `Value` surface                                                                                                                                                                                                                                               |
| NUMA/CCD-aware parallel helpers                         | The 8-worker scaling knee is topology; explore pinning post-v1                                                                                                                                                                                                                        |
