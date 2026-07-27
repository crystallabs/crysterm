module Crysterm
  # A wrapper around indexable objects that returns nil on [-idx] rather than
  # [idx] counted from the back.
  #
  # It is needed in drawing routines where index is often offset by a certain
  # value and expected that all indexes < 0 will return nil.
  struct StringIndex
    getter object : String
    # Non-ASCII path: codepoints materialized once. nil for ASCII content.
    @chars : Array(Char)?
    # ASCII fast path: a zero-copy byte view of `@object`. For ASCII a byte is
    # its codepoint, so indexing bytes directly avoids `String#[]?(Int)`
    # (recomputes size, decodes a char per call — this dominated the render CPU
    # profile per cell). nil for non-ASCII content (uses `@chars`).
    @bytes : Bytes?
    # Codepoint count, cached so `#size` and the per-cell bounds check are field
    # reads, not `String#size` calls.
    @size : Int32

    def initialize(@object : String)
      if @object.ascii_only?
        @chars = nil
        @bytes = @object.to_slice
        @size = @object.bytesize # == codepoint count for ASCII
      else
        # Materialize chars once (O(n)) so per-cell indexing is O(1) instead of
        # `String#[](Int)`'s O(n) walk (which made drawing Unicode lines O(n²)).
        chars = @object.chars
        @chars = chars
        @bytes = nil
        @size = chars.size
      end
    end

    # Whether this index was built from `s` (the same `String` object). The
    # render loop builds one `StringIndex` per widget per frame from
    # `@_pcontent`; lets callers reuse a cached index across frames instead of
    # rebuilding `chars` every frame.
    def built_from?(s : String) : Bool
      @object.same? s
    end

    # Per-cell hot path: a negative or out-of-range index yields nil; otherwise
    # an ASCII byte fetch (the common case) or an `unsafe_fetch` into the cached
    # `chars` array — neither calls `String#[]?`/`String#size`.
    @[AlwaysInline]
    def []?(i : Int) : Char?
      return if i < 0 || i >= @size
      if bytes = @bytes
        bytes.unsafe_fetch(i).unsafe_chr
      else
        @chars.not_nil!.unsafe_fetch(i) # ameba:disable Lint/NotNil
      end
    end

    def [](i : Int) : Char?
      return if i < 0
      raise IndexError.new if i >= @size
      if bytes = @bytes
        bytes.unsafe_fetch(i).unsafe_chr
      else
        @chars.not_nil!.unsafe_fetch(i) # ameba:disable Lint/NotNil
      end
    end

    def [](range : Range)
      @object[range]
    end

    def size
      @size
    end
  end
end
