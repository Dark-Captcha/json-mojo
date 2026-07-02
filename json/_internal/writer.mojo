# ChunkWriter — the serializer's output sink. Owns the output `String` plus a
# fixed stack buffer; small writes (structural bytes, keys, numbers) batch into
# the buffer and flush to the String in bulk, while large spans (long string
# bodies) append directly. This is EmberJson's `_WriteBufferStack` technique:
# it gives cheap per-byte writes (no `String +=` overhead each time) AND a
# single copy of each byte into the output (the String only ever sees bulk
# appends), so a clean string dumps near memory bandwidth.
#
# Why not write through a raw pointer into a pre-sized String? Mojo's String
# uses small-string optimization (bytes inline in the struct for small values),
# so a held `unsafe_ptr_mut()` dangles when the struct moves — verified to crash
# intermittently. The chunk buffer is the safe equivalent.

from std.memory import memcpy


comptime _CHUNK: Int = 4096

# Spans at least this long bypass the buffer and append straight to the String
# (one bulk copy); shorter ones are batched.
comptime _DIRECT_MIN: Int = 1024


struct ChunkWriter(Movable, Writer):
    var out: String
    var buf: InlineArray[UInt8, _CHUNK]
    var n: Int  # bytes currently staged in buf

    @always_inline
    def __init__(out self, capacity_hint: Int):
        self.out = String(capacity=capacity_hint)
        # Uninitialized — we only ever read back the bytes we wrote. Avoids a
        # 4 KB zero-fill on every dumps() call (which dominated small docs).
        self.buf = InlineArray[UInt8, _CHUNK](uninitialized=True)
        self.n = 0

    @always_inline
    def _flush(mut self):
        if self.n == 0:
            return
        self.out += StringSlice(
            unsafe_from_utf8=Span(ptr=self.buf.unsafe_ptr(), length=self.n)
        )
        self.n = 0

    @always_inline
    def byte(mut self, b: UInt8):
        if self.n == _CHUNK:
            self._flush()
        self.buf[self.n] = b
        self.n += 1

    @always_inline
    def span(mut self, src: Span[UInt8, _]):
        var k = len(src)
        if k == 0:
            return
        if k >= _DIRECT_MIN:
            self._flush()
            self.out += StringSlice(unsafe_from_utf8=src)
            return
        if self.n + k > _CHUNK:
            self._flush()
        var dst = self.buf.unsafe_ptr() + self.n
        memcpy(dest=dst, src=src.unsafe_ptr(), count=k)
        self.n += k

    @always_inline
    def lit(mut self, l: StaticString):
        var b = l.as_bytes()
        self.span(Span(ptr=b.unsafe_ptr(), length=len(b)))

    # --- Writer conformance --------------------------------------------------
    # Lets `Writable` values (notably `Float64`) format their shortest-round-trip
    # text directly into the buffer via `value.write_to(self)` — no temporary
    # heap String per value.

    @always_inline
    def write_bytes(mut self, bytes: Span[UInt8, _]):
        self.span(bytes)

    @always_inline
    def write_string(mut self, s: StringSlice):
        self.span(s.as_bytes())

    def finish(deinit self) -> String:
        if self.n > 0:
            self.out += StringSlice(
                unsafe_from_utf8=Span(ptr=self.buf.unsafe_ptr(), length=self.n)
            )
        return self.out^
