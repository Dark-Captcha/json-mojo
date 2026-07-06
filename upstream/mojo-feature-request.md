# Feature Request: Add an RFC 8259 JSON Module to the Mojo Standard Library

## Review Mojo's Priorities

- [x] I have read the roadmap and priorities and believe this request aligns with standard-library consolidation, regularization, and new capabilities.

## What Is Your Request?

Discuss and approve a proposal for a dependency-free `std.json` module covering the RFC 8259 JSON data model:

- Strict UTF-8 parsing with explicit nesting and duplicate-name policies.
- Owned `Document` storage with lazy `Value` cursors.
- Compact and pretty serialization.
- Typed serialization and deserialization through traits and compile-time reflection.
- File, string, and byte entry points.

The implementation candidate is maintained at <https://github.com/Dark-Captcha/json-mojo>. The requested standard-library scope is smaller than that package: JSON5, JSON Patch, Merge Patch, MessagePack, BSON, and CBOR are excluded.

## What Is Your Motivation for This Change?

JSON is foundational infrastructure for package tooling, HTTP clients, configuration, model-serving APIs, structured logs, and Python interoperability. A standard implementation provides:

- A dependency-free baseline available before third-party package resolution.
- One security and conformance contract for untrusted UTF-8 input.
- Stable shared types for libraries that exchange structured data.
- Python-familiar `load`, `loads`, `dump`, and `dumps` names alongside Mojo-native typed serde.
- A portable implementation for Linux x86-64, Linux ARM64, and Apple Silicon without C or C++ linkage.

The earlier request in issue #478 was closed in 2023 while core data structures and package infrastructure were still prerequisites. Those prerequisites now exist, the standard library accepts external contributions through a proposal process, and a tested implementation is available for evaluation.

## Any Other Details?

The candidate currently provides:

- JSONTestSuite conformance with zero failures in required accept/reject cases.
- Differential float, UTF-8, structural fuzz, and round-trip gates.
- Explicit maximum nesting depth and duplicate-member policy.
- Lazy number and string conversion over an owned tape representation.
- Reflection-derived structs and recursive `List[T]` / `Dict[String, V]` serde.
- CI on Linux x86-64, Linux ARM64, and Apple Silicon.
- Apache-2.0 WITH LLVM-exception licensing and no runtime dependencies.

The attached proposal defines a staged review path, alternatives, compatibility policy, and the intentionally excluded ecosystem features.

Assisted-by: AI
