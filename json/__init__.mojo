"""Provides parsing, serialization, typed serde, and JSON transformations."""

# json — the public surface. Import from `json` directly
# (`from json import loads, parse, Document`); the internal layout may move.
# The set is ARCHITECTURE.md's Public Surface: sixteen functions, eleven types.
# 0.1.0 froze eight functions (`loads_bytes` joined as a recorded freeze
# amendment — network bodies are bytes, and invalid UTF-8 must reach our
# validator, not a decoding layer); 1.1.0 added six additively: JSON Lines,
# RFC 7464 text sequences, and file sugar (ROADMAP "Near — capability").
# Re-exports only — no logic lives here.

from json.document import Document, loads, loads_bytes, parse, try_parse
from json.io import dump, dumps_lines, dumps_seq, load, loads_lines, loads_seq
from json.patch import apply_patch, merge_patch
from json.options import (
    Dialect,
    DuplicatePolicy,
    ParseMode,
    ParseOptions,
    SerializeOptions,
)
from json.serde import ToJson, deserialize, serialize, try_deserialize
from json.serializer import Serializer, dumps
from json.value import FromJson, Value, ValueKind
