# Roadmap

> **Version:** 1.3.0 | **Updated:** 2026-07-03

Direction after v1.3.0, ordered by leverage. PERF.md's weakness table is the performance source of truth; ARCHITECTURE.md's extension tiers are the scope source of truth. As of 1.3.0 every shipped format is BIDIRECTIONAL: JSON and JSON5 in, JSON out (JSON5 normalizes); MessagePack, BSON, and CBOR decode AND encode over the stable tape contract.

---

## Near — performance (attack the simdjson gap: 14–19% of ceiling on structural corpora)

| Item                                      | Why                                                                                                                                       |
| ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| Stage-1 atom hints                        | Stop stage 2 re-scanning whitespace gaps stage 1 already saw                                                                              |
| Tape-append fast path                     | Capacity is exact-bounded already; the growth-check branch remains on every append                                                        |
| String/key machinery vs the ceiling       | simdjson holds 5.9–6.0 GB/s on twitter/citm same-machine (PERF.md); the structural-corpora gap is the Performance Promise's open frontier |
| Digit-run hints from validation to access | canada at 58% of ceiling: stage 2 validates digits, access re-parses them — emit spans the Eisel-Lemire path can reuse                    |
| SIMD pass for the JSON5 scanner           | The JSON5 path is scalar by design (configs, not firehoses); lift stage-1 techniques if JSON5 workloads ever demand it                    |

## Near — capability

| Item                                        | Why                                                                                                                                                                                                   |
| ------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Container deserialization (`List` / `Dict`) | The ownership wall FELL (finding 36; working mechanism retained in `.probe/probe_container_walls.mojo`) — blocked only by a compiler ICE on cross-module conformance queries; re-attempt each nightly |
| Publish the conda packages                  | Source-only today (`json` + `msgpack` + `bson` + `cbor` ride one repo). Versioning sorts above the retired prototype's recipe; the remaining decision is the package name(s)                          |
| `parse_view` borrowed zero-copy variant     | For arena/buffer-reuse experts, behind an origin-ergonomics probe (tier 1)                                                                                                                            |

## Far — ecosystem

| Item                            | Form                                                                                                                                                     |
| ------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Canonical/deterministic modes   | RFC 8785 (JCS) for JSON; RFC 8949 §4.2 shortest-float selection for CBOR encode (integers and lengths are already shortest-form)                          |
| Binary decode policies as knobs | Optional comptime mappings for the rejected foreign types (bin/ext → base64 strings, datetimes → ISO text) — opt-in, never silent; the six tags never grow |
| JSONPath (RFC 9535), Schema     | Consumers of the public `Value` surface, like the shipped RFC 6902/7396 patches — JSONPath is 62 pages of spec and earns its own library                 |
| NUMA/CCD-aware parallel helpers | The 8-worker scaling knee is topology; explore pinning post-v1                                                                                           |
