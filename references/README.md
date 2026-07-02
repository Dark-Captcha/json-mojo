# References — Standards Governing json-mojo

> **Version:** 0.1.0 | **Updated:** 2026-07-02

Vendored and linked specifications for every byte this library parses or emits, with the constraints each imposes. Entries marked _candidate_ await the design discussion; the spec facts themselves are settled.

---

| #   | Section                                             |
| --- | --------------------------------------------------- |
| 1   | [Overview](#overview)                               |
| 2   | [Vendored RFCs](#vendored-rfcs)                     |
| 3   | [External Specifications](#external-specifications) |
| 4   | [Design Constraints](#design-constraints)           |
| 5   | [Provenance](#provenance)                           |

---

## Overview

This folder holds the primary sources behind json-mojo's design decisions.

| Source class            | Policy               | Rationale                                        |
| ----------------------- | -------------------- | ------------------------------------------------ |
| IETF RFC texts          | Vendored verbatim    | Small, immutable, license permits redistribution |
| Non-IETF specifications | Linked, not vendored | Heavyweight documents, separate licensing        |

Cite entries from this index in module headers rather than restating spec text.

---

## Vendored RFCs

| File          | Specification                      | Status            | Governs in json-mojo                                                                    |
| ------------- | ---------------------------------- | ----------------- | --------------------------------------------------------------------------------------- |
| `rfc8259.txt` | The JSON Data Interchange Format   | Internet Standard | The grammar itself: values, objects, arrays, numbers, strings, whitespace, escapes      |
| `rfc7493.txt` | The I-JSON Message Format          | Proposed Std      | The interoperable strict profile: UTF-8 only, no duplicate names, IEEE-754-safe numbers |
| `rfc6901.txt` | JSON Pointer                       | Proposed Std      | The standard path syntax (`/a/b/0`, `~0`/`~1` escaping) for addressing into a document  |
| `rfc8785.txt` | JSON Canonicalization Scheme (JCS) | Informational     | Canonical serialization: I-JSON subset, ECMAScript number formatting, sorted keys       |
| `rfc3629.txt` | UTF-8, a Transformation Format     | STD 63            | Byte-level validity of every string this library accepts or produces                    |

---

## External Specifications

| Specification           | Authority          | Governs                                                                                                                                                     | Link                                                                            |
| ----------------------- | ------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| ECMA-404, 2nd edition   | Ecma International | The same grammar as RFC 8259, without interoperability guidance — 8259 is the operative citation here                                                       | <https://ecma-international.org/publications-and-standards/standards/ecma-404/> |
| IEEE 754-2019           | IEEE               | The number model interoperable JSON is limited to (binary64)                                                                                                | <https://standards.ieee.org/ieee/754/6210/>                                     |
| JSONTestSuite           | Nicolas Seriot     | The de-facto parser conformance corpus (y/n/i cases) — clone into `references/JSONTestSuite` to run `tests/run_suite.sh` (gitignored, like all clones here) | <https://github.com/nst/JSONTestSuite>                                          |
| RFC 9535 JSONPath       | IETF               | Query expressions over JSON — linked for scope discussion, not vendored (62 pages)                                                                          | <https://www.rfc-editor.org/rfc/rfc9535.txt>                                    |
| RFC 6902 / RFC 7396     | IETF               | JSON Patch and Merge Patch — document mutation formats, likely out of core scope                                                                            | <https://www.rfc-editor.org/rfc/rfc6902.txt>                                    |
| RFC 7464 Text Sequences | IETF               | RS-delimited JSON streams (`application/json-seq`) — candidate streaming surface                                                                            | <https://www.rfc-editor.org/rfc/rfc7464.txt>                                    |
| RFC 4627                | IETF (obsoleted)   | Lineage only: the original media-type registration, obsoleted through RFC 7159 into 8259                                                                    | <https://www.rfc-editor.org/rfc/rfc4627.txt>                                    |

---

## Design Constraints

Spec-imposed facts the design must answer to. Where the spec leaves a choice, the row names the decision rather than presuming it.

| #   | Finding                                                                                                  | Source            | Constraint on json-mojo                                                                                                                                |
| --- | -------------------------------------------------------------------------------------------------------- | ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 1   | Interchanged JSON MUST be encoded in UTF-8; a BOM MUST NOT be added                                      | RFC 8259 §8.1     | The parser is UTF-8-only; BOM tolerance on input is a design decision to make explicitly                                                               |
| 2   | Invalid UTF-8 MUST be rejected — overlong forms and surrogate encodings are attacks, not data            | RFC 3629 §10      | Byte-level validation at the boundary is security-mandatory, not optional                                                                              |
| 3   | Object member names SHOULD be unique; software behavior on duplicates is unpredictable                   | RFC 8259 §4       | Duplicate-name policy is a required design decision — decided: `DuplicatePolicy` ships first-wins (default), last-wins, and reject (the I-JSON stance) |
| 4   | I-JSON: UTF-8 only, no duplicates, numbers within IEEE 754 binary64                                      | RFC 7493          | The candidate "strict mode" contract, already standardized — no need to invent one                                                                     |
| 5   | Numbers beyond IEEE 754 binary64 precision lose interoperability; NaN and Infinity are not JSON          | RFC 8259 §6       | The number model (binary64, integer preservation, bignum policy) is a load-bearing design choice                                                       |
| 6   | Parsers MAY set limits on nesting depth, range, and text size                                            | RFC 8259 §9       | A depth limit is a stack-safety requirement; its value and configurability are design decisions                                                        |
| 7   | Strings carry `\uXXXX` escapes including surrogate pairs; unpaired surrogates are I-JSON-forbidden       | RFC 8259 §7, 7493 | Escape decoding must handle pair recombination; unpaired-surrogate policy must be explicit                                                             |
| 8   | A standard path syntax into documents exists: JSON Pointer                                               | RFC 6901          | Adopted — shipped as `Value.at("/path")` in v0.1.0 rather than inventing a path syntax                                                                 |
| 9   | Canonical form exists: I-JSON constraints, ECMAScript shortest-round-trip numbers, code-unit-sorted keys | RFC 8785          | Candidate serializer mode; requires shortest-round-trip float formatting (a Ryu-class algorithm)                                                       |
| 10  | ECMA-404 defines the same grammar without interop or security guidance                                   | ECMA-404 vs 8259  | RFC 8259 is the operative spec citation throughout this library                                                                                        |

---

## Provenance

| Item       | Detail                                           |
| ---------- | ------------------------------------------------ |
| Source     | RFC Editor's canonical plain-text archive        |
| Downloaded | 2026-07-02                                       |
| License    | IETF Trust license permits verbatim reproduction |

Re-fetch at any time:

```bash
for n in 8259 7493 6901 8785 3629; do
    curl -fsSL "https://www.rfc-editor.org/rfc/rfc${n}.txt" -o "rfc${n}.txt"
done
```
