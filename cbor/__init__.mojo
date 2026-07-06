"""Provides CBOR decoding and encoding over the JSON tape model."""

# cbor — a CBOR front-end for json-mojo (extension tier 2, RFC 8949,
# following the msgpack sibling's shape): `decode` turns CBOR bytes into a
# `json.Document` over the stable tape contract, and `dumps` encodes any
# document or cursor back to CBOR bytes (shortest-form integers, definite
# lengths). Import from `cbor` directly.

from cbor.decoder import decode
from cbor.encoder import dumps
