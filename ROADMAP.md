# Roadmap

> **Version:** 0.1.0 | **Updated:** 2026-07-02

Direction after v0.1.0, ordered by leverage. PERF.md's weakness table is the performance source of truth; ARCHITECTURE.md's extension tiers are the scope source of truth.

---

## Near — performance (attack stage 2: 82–94% of parse)

| Item                                               | Why                                                                   |
| -------------------------------------------------- | --------------------------------------------------------------------- |
| SIMD digit-run scanning in `_validate_number`      | canada.json's hottest loop; the single largest remaining win          |
| Exact-size tape reserve + unsafe writes            | Two bounds-checked `List.append`s per value today                     |
| Stage-1 atom hints                                 | Stop stage 2 re-scanning whitespace gaps stage 1 already saw          |
| Measure C++ simdjson on this machine               | The honest ceiling for the Performance Promise                        |
| Re-attempt ehsanmok/json build on future nightlies | Its published 1.06 GB/s twitter claim is the open same-machine target |

## Near — release

| Item                      | Why                                                                                                                                                                                                         |
| ------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Publish the conda package | The Install story is source-only today. Naming/versioning needs a decision first: the retired prototype's recipe already used the name `json` at v1.0.0, which any fresh 0.1.x release would sort **below** |

## Near — capability

| Item                                        | Why                                                                                                                 |
| ------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| Container deserialization (`List` / `Dict`) | Re-land the `__extension` conformances the moment any of the three toolchain walls falls (`.probe/SYNTAX.md` 21–23) |
| JSON Lines + RFC 7464 text sequences        | Engine-neutral sugar (split, then `parse`); both incumbents ship it                                                 |
| `load` / `dump` file sugar                  | Once streaming exists                                                                                               |

## Mid — extension tier 1 (ARCHITECTURE.md)

| Item                                              | Why                                                                                        |
| ------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| `Dialect.JSON5` on the reserved options parameter | Comments / trailing commas as an explicit, typed, zero-cost-when-off opt-in — never silent |
| `parse_view` borrowed zero-copy variant           | For arena/buffer-reuse experts, behind an origin-ergonomics probe                          |

## Far — ecosystem (extension tiers 2–3, separate libraries)

| Item                                          | Form                                                           |
| --------------------------------------------- | -------------------------------------------------------------- |
| JSONPath (RFC 9535), Patch (RFC 6902), Schema | Consumers of the public `Value` surface                        |
| Binary front-ends (BSON, CBOR, MessagePack)   | Sibling decoders emitting this library's stable tape           |
| NUMA/CCD-aware parallel helpers               | The 8-worker scaling knee is topology; explore pinning post-v1 |
