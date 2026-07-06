"""Provides BSON decoding and encoding over the JSON tape model."""

# bson — a BSON front-end for json-mojo (extension tier 2, following the
# msgpack sibling's shape): `decode` turns a BSON document into a
# `json.Document` over the stable tape contract, and `dumps` encodes a
# JSON object document back to BSON bytes. Import from `bson` directly.

from bson.decoder import decode
from bson.encoder import dumps
