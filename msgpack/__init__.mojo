"""Provides MessagePack decoding and encoding over the JSON tape model."""

# msgpack — a MessagePack front-end for json-mojo (extension tier 2, the
# reference sibling): `decode` turns MessagePack bytes into a `json.Document`
# (inheriting the entire consumer surface — cursor, serde, `json.dumps` for
# msgpack → JSON transcoding), and `dumps` encodes any document or cursor
# back to MessagePack bytes. Import from `msgpack` directly.

from msgpack.decoder import decode
from msgpack.encoder import dumps
