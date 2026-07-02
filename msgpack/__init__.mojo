# msgpack — a MessagePack front-end for json-mojo (extension tier 2, the
# reference sibling): `decode` turns MessagePack bytes into a `json.Document`,
# inheriting the entire consumer surface — cursor, serde, `dumps` (which
# makes msgpack → JSON transcoding one call). Import from `msgpack` directly.

from msgpack.decoder import decode
