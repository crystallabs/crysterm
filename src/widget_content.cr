module Crysterm
  class Widget
    include Helpers

    # Convenience regex for matching Crysterm tags and their content (i.e. '{bold}This text is bold{/bold}').
    TAG_REGEX = /\{(\/?)([\w\-,;!#]*)\}/

    # Convenience regex for matching line-alignment tags (`{center}`, `{/right}`, ...).
    ALIGN_TAG_REGEX = /\{\/?(?:left|center|right)\}/

    # Convenience regex for matching SGR sequences.
    SGR_REGEX = /\e\[[\d;]*m/

    # :ditto:
    SGR_REGEX_AT_BEGINNING = /^#{SGR_REGEX}/

    # Can element's content be word-wrapped?
    property? wrap_content = true

    # Is element's content to be parsed for tags?
    property? parse_tags = false

    # Alignment of contained text. (The `align`-consuming reads live in
    # `widget_content_tags.cr` after the content-file split, so ameba's per-file
    # `Lint/UselessAssign` heuristic flags this macro's synthesized `align` here.)
    Crystallabs::Helpers::Enums.enum_property align : Tput::AlignFlag = Tput::AlignFlag::Top | Tput::AlignFlag::Left # ameba:disable Lint/UselessAssign

    # `wrap_content`/`parse_tags`/`align` all change wrap output, so their setters
    # must invalidate the wrap cache and mark dirty, like `set_content`/`width=`.
    def wrap_content=(value : Bool)
      return value if value == @wrap_content
      @wrap_content = value
      @_content_version += 1
      mark_dirty
      value
    end

    def parse_tags=(value : Bool)
      return value if value == @parse_tags
      @parse_tags = value
      @_content_version += 1
      mark_dirty
      value
    end

    def align=(value : Tput::AlignFlag)
      return value if value == @align
      @align = value
      @_content_version += 1
      mark_dirty
      value
    end

    # Shorthand form (`:center`, `"right"`, `{:vcenter, :right}`), mirroring the
    # `enum_property` macro.
    def align=(value : ::Crystallabs::Helpers::Enums::Shorthands)
      self.align = ::Crystallabs::Helpers::Enums.from(Tput::AlignFlag, value)
    end

    # Widget's user-set content in original form. Includes any attributes and tags.
    # Materialized lazily: `append_content` stashes raw chunks in `@_content_tail`
    # and they are folded in only when content is read, making a stream of appends
    # O(1) amortized.
    @content : String = ""

    # Raw appended chunks not yet folded into `@content`.
    @_content_tail = [] of String

    # The widget's content exactly as it was set: tags, inline SGR and all.
    # This is the RAW half of the raw/rendered pair — for what ends up on screen
    # (tags expanded, lines word-wrapped) read `#rendered_content` /
    # `#rendered_text`. The two do NOT round-trip: `w.content = x` followed by
    # `w.rendered_content` returns the *processed* form of *x*, not *x*.
    def content : String
      fold_content_tail
      @content
    end

    # Folds `@_content_tail` into `@content`. No-op when nothing is pending.
    private def fold_content_tail : Nil
      return if @_content_tail.empty?
      @content = String.build do |s|
        s << @content
        @_content_tail.each do |t|
          s << '\n'
          s << t
        end
      end
      @_content_tail.clear
    end

    # No content at all, materialized or pending. O(1) (does not fold).
    private def content_blank?
      @content.empty? && @_content_tail.empty?
    end

    # Printable, word-wrapped content, ready for rendering. `nil` means "stale";
    # `#pcontent` rebuilds it on demand.
    #
    # Public getter (specs/benchmarks assert it stays `nil` while an append is
    # deferred); the setter is `protected` — writers go through the pipeline.
    getter _pcontent : String?
    protected setter _pcontent

    # Printable content string, rebuilt from wrapped lines if stale. Consumers
    # must go through this (not `@_pcontent` directly) so a deferred append is
    # materialized before use.
    def pcontent : String
      @_pcontent ||= clines_joined
    end

    # Wrapped lines as one `"\n"`-joined string. Single-line content returns the
    # sole line directly, avoiding a per-widget, per-frame duplicate allocation.
    private def clines_joined : String
      cl = @_clines
      case cl.size
      when 0 then ""
      when 1 then cl[0]
      else        cl.join("\n")
      end
    end

    # Cached codepoint index over `@_pcontent`, reused across frames. Rebuilt only
    # when `@_pcontent` becomes a different `String`.
    @_content_index : StringIndex? = nil

    # Public getter (read widely by specs and subclass render code); the setter
    # is `protected` so external writes can't bypass the wrap/version pipeline.
    getter _clines = CLines.new
    protected setter _clines

    # Bumped on every `@content` change. `process_content` compares this against
    # the version baked into `@_clines` to decide whether a reparse is needed.
    # `Int64` because it increases monotonically for the widget's whole life: a
    # busy `Log` at ~1000 lines/s would overflow an `Int32` in under a month.
    @_content_version = 0_i64

    # The `no_tags` mode the cached content was processed with, so a repeated
    # `set_content` of the same string but a different tag mode still reparses.
    @_content_no_tags = false

    # Transient guard set only for the duration of `rebuild_content_from_fake`'s
    # `set_content` call. `@_clines.fake` holds POST-parse lines, so re-feeding
    # them through `set_content` would run `_parse_tags` a SECOND time — dropping
    # escaped braces or re-interpreting a literal tag-looking token as live SGR.
    # Honored by `process_content` like a one-shot `no_tags = true` WITHOUT
    # flipping the persistent `@_content_no_tags`. Fresh line contents are
    # pre-parsed by the line editors before splicing into `fake`, so tags in newly
    # inserted/set lines still work — see `#insert_line`/`#replace_line`.
    @_rebuilding_from_fake = false

    # Whether `@content` contains any Crysterm tags (`{...}` / `{/...}`), decided
    # from the raw text independent of `@parse_tags`/`no_tags` mode, so a later
    # `parse_tags = true` flip still finds the flag set. When false,
    # `process_content` skips `_parse_tags` entirely.
    @_content_has_tags = false

    # Whether `@content` contains any brace at all. Distinct from
    # `@_content_has_tags`: a brace that matches no tag leaves that flag false
    # while still sitting in raw content, rendered literally because the parse gate
    # is off. Appending a *tagged* segment flips that gate on, so a full reparse
    # would drop such a brace (drop-malformed policy) and change already-rendered
    # lines — which is when `append_content`'s fast path must bail.
    @_content_has_braces = false

    # Whether `@content` contains any inline SGR escape (raw `\e`). Together with
    # `@_content_has_tags` (tags expand to SGR), tells `_parse_attr` whether any
    # line can carry an inline attribute change; when neither is set, every wrapped
    # line has the same base attr and the per-line `_attr_after` scan is skipped.
    # Conservative: a false positive only forces the (correct) slow path.
    @_content_has_sgr = false

    # Whether `@content` contains any line-alignment tag (`{center}` etc.).
    # `append_content`'s fast path wraps the appended segment standalone from the
    # widget's default `@align`, so an unclosed alignment opener in existing
    # content — whose carried `default_state` a full reparse would propagate to
    # later lines — must force the slow path.
    @_content_has_align_tag = false

    # Whether `_parse_tags` over the current content ends with tag state still
    # open: a non-empty fg/bg/flag stack (an unclosed `{red-fg}`/`{bold}`) or an
    # unterminated `{escape}`. This is the parser state a full reparse would carry
    # across an append boundary, so `append_content`'s fast path — which parses the
    # appended segment standalone, from empty state — bails when this is set and
    # the segment contains a brace.
    @_content_open_tags_at_end = false

    # The `style_to_attr(style)` value the cached `@_clines.attr` was computed against.
    # `_parse_attr` depends only on content and this base attribute, so it's
    # skipped when both are unchanged. `nil` forces the first computation.
    @_parse_attr_default : Int64? = nil

    # Sets widget content without extra options; use `#set_content` for those.
    #
    # This is the RAW property's setter: it stores *content* verbatim (tags,
    # inline SGR and all). It is not the inverse of `#rendered_content`, which
    # reports the parsed/wrapped result — see `#content`.
    def content=(content)
      set_content content
    end

    # Replaces the raw content, with the extra knobs `#content=` doesn't expose.
    #
    # * *no_tags* — store the content with tag parsing disabled for this widget
    #   (kept as `@_content_no_tags`, so later reparses stay literal too).
    # * *no_clear* — vestigial (stale cells are cleared centrally by
    #   `Window#repaint`); accepted for call compatibility.
    def set_content(content = "", no_clear = false, no_tags = false)
      # Fold deferred appends so the comparison below sees current content.
      fold_content_tail
      # Idempotent no-op for re-setting identical content. Gates on the tag mode
      # too, since `process_content`'s cache key omits it — otherwise the same
      # string in a different mode would never reparse.
      return if content == @content && no_tags == @_content_no_tags

      # XXX make it possible to have `update_context`, which only updates
      # internal structures, not @content (for rendering purposes, where
      # original content should not be modified).
      @content = content
      @_content_no_tags = no_tags
      # The `{` check short-circuits the PCRE2 match for the common tag-free case.
      @_content_has_tags = content.includes?('{') && content.matches?(TAG_REGEX)
      @_content_has_braces = content.includes?('{') || content.includes?('}')
      @_content_has_sgr = content.includes? '\e'
      @_content_has_align_tag = content.includes?('{') && content.matches?(ALIGN_TAG_REGEX)
      @_content_version += 1

      process_content(no_tags)
      # Detached: `process_content` bailed (no window), leaving `@_clines.fake`
      # describing the PREVIOUS content. The fake-splicing line editors
      # (`insert_line`/`delete_line`/`replace_line`/... and their index math)
      # trust `fake` unconditionally, so a stale copy would resurrect the old
      # text via `rebuild_content_from_fake`. Resync `fake` to the new raw lines
      # and drop the line maps — the "content seeded before attach" shape the
      # editors already handle. `content_version` is deliberately left stale so
      # the `Event::Attached` reparse still fires. Skipped during
      # `rebuild_content_from_fake` (an identity resync of its own source).
      if window?.nil? && !@_rebuilding_from_fake
        @_clines.fake.clear
        @_clines.fake.concat(content.split('\n')) unless content.empty?
        @_clines.ftor.clear
        @_clines.rtof.clear
      end
      mark_dirty
      emit(Crysterm::Event::ContentChanged)
    end

    # The content as *rendered*: the original ("fake") lines after tag parsing,
    # `"\n"`-joined. Tags are already expanded to inline SGR, so this is what the
    # widget draws, not what was set (see `#content` for the raw half). Use
    # `#rendered_text` for the same view with the SGR stripped back out.
    def rendered_content : String
      return "" if @_clines.empty?
      @_clines.fake.join "\n"
    end

    # Replaces the content with *content*'s plain text: inline SGR is stripped
    # out and tags are kept literal (`no_tags`), so nothing in *content* can
    # style the widget. The setter counterpart to `#rendered_text`.
    #
    # *no_clear* is vestigial; see `#set_content`.
    def set_text(content = "", no_clear = false)
      content = content.gsub SGR_REGEX, ""
      set_content content, no_clear, true
    end

    # `#rendered_content` with the inline SGR stripped back out: the plain text
    # a user sees on screen, without the attributes it is drawn with.
    def rendered_text : String
      rendered_content.gsub SGR_REGEX, ""
    end

    # Word-wrapped, ready-to-render content lines plus the bookkeeping needed
    # to map between the original ("fake") and wrapped ("real") line numbers.
    #
    # Wraps rather than subclasses `Array(String)`: subclassing a stdlib generic
    # promotes every `Array(String)` in the program to the virtual type
    # `Array(String)+`, causing confusing compile errors elsewhere (issue #30).
    class CLines
      property string = ""
      property max_width = 0
      property width = 0

      # Right-edge columns (`Widget#content_margin_x`) these lines were wrapped to
      # avoid — the vertical scroll bar's reservation at wrap time. Part of the
      # convergence check in `Widget#process_content`.
      property margin = 0

      # Horizontal scroll offset (display columns) these lines were sliced for —
      # part of the wrap cache key, so scrolling forces a reparse like a width
      # change does. Only meaningful when `wrap_content` is off.
      property base_x = 0

      # Style inputs baked into the wrapped line text — TAB expansion
      # (`tab_char * tab_size`, `clean_content_chars`) and alignment padding
      # (`fill_char`, `_align`/`split_right_align`). Part of the wrap cache key
      # so a style change (direct mutation + `mark_dirty`, or a CSS cascade)
      # forces a rewrap; types match `Style#tab_char` (String) and
      # `Style#fill_char` (Char).
      property tab_size = 4
      property tab_char = " "
      property fill_char = ' '

      # Widest unclipped line in display columns (before horizontal viewport
      # slice). Drives `Widget#scroll_width` and the horizontal scroll bar's
      # range. `0` for wrapped content.
      property full_width = 0

      property content : String = ""

      # Version of the owning widget's `@content` that produced these wrapped
      # lines. Defaults to -1 so a fresh `CLines` never matches a real (>= 0)
      # version, forcing the first parse. `Int64` in lockstep with the widget's
      # `@_content_version`. See `Widget#process_content`.
      property content_version : Int64 = -1

      property real : CLines? = nil

      property fake = [] of String

      property ftor = [] of Array(Int32)
      property rtof = [] of Int32
      property ci = [] of Int32

      # Pool of recycled `ftor` sub-arrays, so steady-state reparsing reuses the
      # same `Array(Int32)` objects instead of allocating one per line per frame.
      # `#reset` drains rows here; `#take_ftor_row` hands them back out.
      @ftor_pool = [] of Array(Int32)

      # Defaults to `nil`, not an empty array: `process_content` always replaces
      # this with `_parse_attr`'s result on reparse. Readers go through
      # `attr.try(...)`.
      property attr : Array(Int64)? = nil

      # Backing store of wrapped lines. Array API (`push`, `[]`, `size`, `each`,
      # `join`, `reduce`, ...) is forwarded to it below.
      getter lines : Array(String)

      def initialize(@lines = [] of String)
      end

      # Clears the arrays a reparse refills in place, so this `CLines` is reused by
      # the next `_wrap_content` instead of allocating fresh. `clear` keeps each
      # array's backing buffer, so steady-state reparsing reallocates nothing here.
      # `fake`/`attr`/`real` and scalar fields are overwritten wholesale by the
      # reparse, so they are untouched.
      def reset : Nil
        @lines.clear
        @rtof.clear
        # Recycle per-line `ftor` sub-arrays instead of dropping them.
        @ftor.each do |row|
          row.clear
          @ftor_pool << row
        end
        @ftor.clear
        @ci.clear
      end

      # A cleared per-line `ftor` sub-array: recycled from the pool (see
      # `#reset`) when available, otherwise a fresh allocation.
      def take_ftor_row : Array(Int32)
        @ftor_pool.pop? || [] of Int32
      end

      # A fresh, independent copy of the lines, without the extra bookkeeping.
      # Defined explicitly since `dup` exists on `Object` and isn't forwarded.
      def dup
        @lines.dup
      end

      forward_missing_to @lines
    end
  end

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
