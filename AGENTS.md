# Repository Instructions

## Scope

- Keep the parser, serializers, and binary format front-ends dependency-free and pure Mojo.
- Preserve the package-root API and the stable `json.tape` extension contract unless a release explicitly changes them.
- Keep `json._internal` private; sibling formats may import only public `json` modules.
- Preserve RFC-defined behavior, hostile-input limits, and byte/path context in errors.

## Toolchain

- Use the Pixi environment and locked Mojo nightly from `pixi.toml`.
- Run `pixi run format` after editing Mojo files.
- Run `pixi run test`, `pixi run verify`, `pixi run example`, and the benchmark smoke gate before releases.
- Validate public documentation with `pixi run doc`.

## Engineering Rules

- Follow `mojo format` output and existing module naming.
- Explicitly import every used symbol; avoid wildcard and transitive imports.
- Public modules, types, fields, and functions require Mojo docstrings.
- Preserve ownership on every raising path; consume partially initialized containers before propagating errors.
- Add focused tests for success, malformed input, limits, recursive composition, and cleanup paths.
- Performance claims require same-machine measurements and cannot weaken conformance.
- Keep the core synchronous and CPU-bound. Async belongs at the caller-owned I/O boundary; do not add hidden task spawning, global worker pools, or unbounded queues.
- Do not add platform claims that CI and the Pixi lock do not exercise.

## Contributions

- Keep commits atomic and use imperative titles.
- Never commit credentials, generated environments, or externally cloned corpora.
- Upstream Modular contributions require prior maintainer agreement for non-trivial work, signed commits, and an `Assisted-by: AI` disclosure when applicable.
