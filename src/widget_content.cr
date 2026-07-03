module Crysterm
  class Widget
    include Helpers

    # module Content

    # Convenience regex for matching Crysterm tags and their content (i.e. '{bold}This text is bold{/bold}').
    TAG_REGEX = /\{(\/?)([\w\-,;!#]*)\}/

    # Convenience regex for matching line-alignment tags (`{center}`, `{/right}`,
    # ...). Used to decide whether `append_content`'s fast path could drop
    # alignment state carried across lines (finding 33).
    ALIGN_TAG_REGEX = /\{\/?(?:left|center|right)\}/

    # Convenience regex for matching SGR sequences.
    SGR_REGEX = /\e\[[\d;]*m/

    # :ditto:
    SGR_REGEX_AT_BEGINNING = /^#{SGR_REGEX}/

    # Can element's content be word-wrapped?
    property? wrap_content = true

    # Is element's content to be parsed for tags?
    property? parse_tags = false

    # Alignment of contained text
    Crystallabs::Helpers::Enums.enum_property align : Tput::AlignFlag = Tput::AlignFlag::Top | Tput::AlignFlag::Left

    # `wrap_content`/`parse_tags`/`align` all change wrap output, but the plain
    # macro-generated setters neither bump `@_content_version` nor `mark_dirty`,
    # so a change on an attached, already-rendered widget had no effect until an
    # unrelated reparse (finding 35). Redefine the setters to no-op on an equal
    # value, then invalidate the wrap cache and mark dirty — matching
    # `set_content`/`width=`.
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

    # Shorthand form (`:center`, `"right"`, `{:vcenter, :right}`) mirroring the
    # `enum_property` macro; delegates to the typed setter above so the
    # cache-invalidation logic runs once.
    def align=(value : ::Crystallabs::Helpers::Enums::Shorthands)
      self.align = ::Crystallabs::Helpers::Enums.from(Tput::AlignFlag, value)
    end

    # Widget's user-set content in original form. Includes any attributes and tags.
    # Materialized lazily: `append_content` defers the O(total) string concat by
    # stashing the raw appended chunks in `@_content_tail` and folding them into
    # `@content` only when the content is actually read (see `#content`). This is
    # what makes a stream of appends O(1) amortized instead of O(n) each.
    @content : String = ""

    # Raw appended chunks not yet folded into `@content` (see `#content` /
    # `#fold_content_tail`). Empty in the common (non-appended) case.
    @_content_tail = [] of String

    # `@content` with pending appends folded in. O(total) on first read after
    # appends, then cached until the next append. Most readers (`get_content`,
    # list items, `content=`) go through here.
    def content : String
      fold_content_tail
      @content
    end

    # Folds `@_content_tail` into `@content`. No-op when nothing is pending, so
    # it's cheap to call defensively before reading the `@content` ivar directly.
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

    # No content at all, materialized or pending. O(1) (does not fold), for the
    # hot `append_content`/`push_line` guards.
    private def content_blank?
      @content.empty? && @_content_tail.empty?
    end

    # Printable, word-wrapped content, ready for rendering. `nil` means "stale" —
    # `append_content` sets it nil rather than rebuilding the joined string per
    # append; `#pcontent` rebuilds it on demand (once per render, not per append).
    # `@_clines.ci` offsets stay valid since they derive from line lengths, not
    # this string.
    property _pcontent : String?

    # Printable content string, rebuilt from wrapped lines if stale. Consumers
    # must go through this (not `@_pcontent` directly) so a deferred append is
    # materialized before use.
    def pcontent : String
      @_pcontent ||= clines_joined
    end

    # Wrapped lines as one `"\n"`-joined string. For the common single-line case
    # (`Label`, `Fps`, per-cell boxes), `join` would allocate a `String` that just
    # duplicates the sole line; returning that line directly avoids a per-widget,
    # per-frame allocation. Safe since `String`s are immutable; `@_pcontent` is
    # replaced wholesale on the next reparse.
    private def clines_joined : String
      cl = @_clines
      case cl.size
      when 0 then ""
      when 1 then cl[0]
      else        cl.join("\n")
      end
    end

    # Cached codepoint index over `@_pcontent`, reused across frames. `_render`
    # indexes content per cell; for non-ASCII content this materializes a `chars`
    # array, so it's rebuilt only when `@_pcontent` becomes a different `String`
    # (see `StringIndex#built_from?`).
    @_content_index : StringIndex? = nil

    property _clines = CLines.new

    # Bumped on every `@content` change (see `set_content`). `process_content`
    # compares this against the version baked into `@_clines` to decide whether a
    # reparse is needed, avoiding an O(n) `String` comparison on every render.
    @_content_version = 0

    # The `no_tags` mode the cached content was processed with, so a repeated
    # `set_content` of the same string but a different tag mode still reparses
    # (see the unchanged-content short-circuit in `#set_content`).
    @_content_no_tags = false

    # Whether `@content` contains any Crysterm tags (`{...}` / `{/...}`), decided
    # once in `#set_content`. When false, `process_content` skips `_parse_tags`
    # (and its whole-string regex scan) entirely, since most content is plain
    # text. Defaults false.
    @_content_has_tags = false

    # Whether `@content` contains any inline SGR escape (raw `\e`), decided once
    # in `#set_content`/`#append_content`. Together with `@_content_has_tags`
    # (tags expand to SGR via `_parse_tags`), tells `_parse_attr` whether any line
    # can carry an inline attribute change. When neither is set, every wrapped
    # line has the same base attr, so `_parse_attr` fills the attr array directly
    # and skips the per-line `_attr_after` scan — the common case for plain text.
    # Conservative: a stray `\e` later stripped, or unexpanded tags under
    # `no_tags`, only force the (correct) slow path. Defaults false.
    @_content_has_sgr = false

    # Whether `@content` contains any line-alignment tag (`{center}` etc.),
    # decided in `#set_content`. `append_content`'s fast path wraps the appended
    # segment standalone from the widget's default `@align`, so an unclosed
    # alignment opener in existing content — whose carried `default_state` a full
    # reparse would propagate to later lines — must force the slow path (finding
    # 33). Defaults false.
    @_content_has_align_tag = false

    # The `sattr(style)` value the cached `@_clines.attr` was computed against.
    # `_parse_attr` depends only on content (unchanged on the cached path) and
    # this base attribute, so it's skipped when the style's packed attr is
    # unchanged frame-to-frame. `nil` forces the first computation.
    @_parse_attr_default : Int64? = nil

    # Sets widget content without extra options; use `#set_content` for those.
    def content=(content)
      set_content content
    end

    def set_content(content = "", no_clear = false, no_tags = false)
      # Fold deferred appends so the comparison below sees current content, and
      # drop the tail since this call replaces content wholesale.
      fold_content_tail
      # Idempotent no-op for re-setting identical content (common in per-cell
      # animations re-assigning a box's character every frame even when
      # unchanged): no version bump, no reparse, no `request_render`, no
      # `SetContent`. Style changes flow through the separate
      # `@_parse_attr_default` path in `process_content`, unaffected by this.
      # The first parse still happens regardless via the CLines/version mismatch
      # in `process_content` (CLines starts at version -1).
      #
      # A repeated set of the *same* string but a different `no_tags` mode must
      # still reparse (`@_content_no_tags`'s own contract): otherwise the widget
      # stays stuck in the old tag mode permanently, since `process_content`'s
      # cache key also omits the mode. So gate on both content and mode.
      return if content == @content && no_tags == @_content_no_tags

      # Previously this erased the widget's last-rendered footprint (unless
      # `no_clear`) to avoid stale cells when content shrank. Now handled
      # centrally by `Window#_render` clearing the whole cell buffer per frame.
      # `no_clear` is kept for call compatibility.

      # XXX make it possible to have `update_context`, which only updates
      # internal structures, not @content (for rendering purposes, where
      # original content should not be modified).
      @content = content
      @_content_no_tags = no_tags
      # Decide once per content change whether it contains any tags, so
      # `process_content` can skip `_parse_tags` (and its regex scan) when not.
      # The `{` check short-circuits the PCRE2 match for the common tag-free case.
      @_content_has_tags = content.includes?('{') && content.matches?(TAG_REGEX)
      # Cheap byte search: records whether inline SGR is present so `_parse_attr`
      # can skip its per-line scan for plain text.
      @_content_has_sgr = content.includes? '\e'
      # Records whether alignment tags are present so `append_content` can bail to
      # the slow path rather than dropping carried alignment state (finding 33).
      @_content_has_align_tag = content.includes?('{') && content.matches?(ALIGN_TAG_REGEX)
      @_content_version += 1

      process_content(no_tags)
      mark_dirty
      emit(Crysterm::Event::SetContent)
    end

    def get_content
      return "" if @_clines.empty?
      @_clines.fake.join "\n"
    end

    def set_text(content = "", no_clear = false)
      content = content.gsub SGR_REGEX, ""
      set_content content, no_clear, true
    end

    def get_text
      get_content.gsub SGR_REGEX, ""
    end

    # Word-wrapped, ready-to-render content lines plus the bookkeeping needed
    # to map between the original ("fake") and wrapped ("real") line numbers.
    #
    # This used to subclass `Array(String)`. Subclassing a stdlib generic is
    # deprecated, and promotes every `Array(String)` in the program (including
    # unrelated shards) to the virtual type `Array(String)+`, causing confusing
    # compile errors elsewhere (see issue #30). It now wraps an array and
    # forwards the array API via `forward_missing_to`.
    class CLines
      property string = ""
      property max_width = 0
      property width = 0

      # Right-edge columns (`Widget#content_margin_x`) these lines were wrapped to
      # avoid — the vertical scroll bar's reservation at wrap time. Part of the
      # convergence check in `Widget#process_content`: an `AsNeeded` bar's
      # presence is only known after wrapping, so if its reserved column now
      # differs, content is re-wrapped once.
      property margin = 0

      # Horizontal scroll offset (display columns) these lines were sliced for —
      # part of the wrap cache key, so scrolling forces a reparse like a width
      # change does. Only meaningful when `wrap_content` is off.
      property base_x = 0

      # Widest unclipped line in display columns (before horizontal viewport
      # slice). Drives `Widget#get_scroll_width` and the horizontal scroll bar's
      # range. `0` for wrapped content.
      property full_width = 0

      property content : String = ""

      # Version of the owning widget's `@content` that produced these wrapped
      # lines. Defaults to -1 so a fresh `CLines` never matches a real (>= 0)
      # version, forcing the first parse. See `Widget#process_content`.
      property content_version : Int32 = -1

      property real : CLines? = nil

      property fake = [] of String

      property ftor = [] of Array(Int32)
      property rtof = [] of Int32
      property ci = [] of Int32

      # Pool of recycled `ftor` sub-arrays. `#reset` drains old per-line `ftor`
      # rows here (cleared); `#take_ftor_row` hands them back out, so steady-state
      # reparsing reuses the same `Array(Int32)` objects instead of allocating
      # one per line every frame.
      @ftor_pool = [] of Array(Int32)

      # Defaults to `nil`, not an empty array: `process_content` always replaces
      # this with `_parse_attr`'s result on reparse, so pre-allocating would be
      # waste. Readers go through `attr.try(...)`.
      property attr : Array(Int64)? = nil

      # Backing store of wrapped lines. Array API (`push`, `[]`, `size`, `each`,
      # `join`, `reduce`, ...) is forwarded to it below.
      getter lines : Array(String)

      def initialize(@lines = [] of String)
      end

      # Clears arrays a reparse refills in place (`#lines`, `rtof`, `ftor`, `ci`)
      # so this `CLines` is reused by the next `_wrap_content` instead of
      # allocating fresh. `clear` keeps each array's backing buffer, so
      # steady-state reparsing reallocates nothing here. `fake`/`attr`/`real` and
      # scalar fields are overwritten wholesale by the reparse, so untouched.
      def reset : Nil
        @lines.clear
        @rtof.clear
        # Recycle per-line `ftor` sub-arrays into the pool instead of dropping
        # them, for reuse via `#take_ftor_row`.
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

      # Matches old `Array#dup` behavior: a fresh, independent copy without the
      # extra bookkeeping. Defined explicitly since `dup` exists on `Object` and
      # isn't forwarded.
      def dup
        @lines.dup
      end

      forward_missing_to @lines
    end

    # Single-pass content sanitization shared by `process_content` (whole
    # content) and `append_content` (appended segment only): strips control
    # characters and a stray ESC (not starting an SGR sequence), normalizes
    # CR/CRLF to LF, and expands TAB to `tab_char * tab_size`. One alternation
    # with a dispatching block replaces four chained `gsub`s. Allocation-free on
    # tab-free, match-free input: `gsub` returns the receiver unchanged, and the
    # `tab` string is only built when a TAB is present.
    private def clean_content_chars(text : String) : String
      tab = text.includes?('\t') ? style.tab_char * style.tab_size : ""
      text.gsub(/[\x00-\x08\x0b-\x0c\x0e-\x1a\x1c-\x1f\x7f]|\e(?!\[[\d;]*m)|\r\n|\r|\t/) do |m|
        case m
        when "\r\n", "\r" then "\n"
        when "\t"         then tab
        else                   "" # control char or stray ESC
        end
      end
    end

    # `awidth_hint`, when given, is this widget's already-resolved absolute width
    # for the current frame — the render path knows it cheaply (`awidth(true)` is
    # an O(1) `lpos` read once the parent has rendered) and passes it in to skip
    # the default `awidth` ancestor-chain walk. Off-render callers (resize/
    # attach/scroll) omit it and resolve the width as before.
    def process_content(no_tags = false, awidth_hint : Int32? = nil)
      # Content layout needs the owning window's dimensions, so nothing to do
      # until the widget is attached.
      return false unless window?

      ::Log.trace { "Parsing widget content: #{@content.inspect}" }

      colwidth = (awidth_hint || awidth) - iwidth
      # `@_clines.margin` is part of the wrap cache key too: an `AsNeeded` scroll
      # bar's presence (and thus `content_margin_x`) can flip from a height-only
      # change (resize, `widget.height=`) that leaves the other cache-key fields
      # unchanged. Without this check the lines stay wrapped for the stale
      # margin and the now-shown bar overpaints the last content column (the
      # `widget-csr` bug) until the next content edit. The convergence loop below
      # leaves `@_clines.margin == content_margin_x` after a reparse, so this
      # doesn't re-fire in steady state.
      if @_clines.nil? || @_clines.empty? || @_clines.width != colwidth || @_clines.content_version != @_content_version || @_clines.base_x != @child_base_x || @_clines.margin != content_margin_x
        # A reparse reads raw `@content`, so fold deferred appends first (the
        # cache-hit path below never reaches here).
        fold_content_tail
        # Single pass instead of four chained `gsub`s — see `#clean_content_chars`.
        # Allocation-free on the common tab-free reparse since `gsub` returns the
        # receiver unchanged when nothing matches.
        content = clean_content_chars @content

        ::Log.trace { "Internal content is #{content.inspect}" }

        # No content-level Unicode munging here: wide-char layout, grapheme
        # clusters, and combining marks are handled at the cell level in the
        # renderer (keyed off `window.full_unicode?`). See FIX-UNICODE.md for why
        # the blessed content-string approach doesn't apply here.

        # Parse tags only when not disabled and content actually has tags
        # (decided in `#set_content`); skips `_parse_tags`'s regex scan for
        # plain text. `@_content_no_tags` records the mode content was set with
        # (e.g. via `#set_text`), so a later cache-miss reparse (width change,
        # resize, scroll, attach — all calling with default `no_tags = false`)
        # keeps tags literal instead of parsing what `set_text` asked to
        # preserve.
        if !no_tags && !@_content_no_tags && @_content_has_tags
          content = _parse_tags content
        end
        ::Log.trace { "After _parse_tags: #{content.inspect}" }

        # Reuse the existing `@_clines` object (refill in place) instead of
        # allocating a new one each reparse.
        #
        # Wrap, then converge the scroll-bar reservation. An `AsNeeded` bar's
        # presence depends on the wrapped line count, known only after wrapping,
        # yet the wrap width depends on the bar reserving its column. On the
        # first wrap `@_clines` is empty, so `content_margin_x` reserves nothing
        # and content wraps one column too wide, letting the bar overpaint the
        # last content column (the `widget-csr` bug). So if the produced lines
        # flip the reservation, re-wrap once. Monotonic: reserving a column only
        # narrows width and adds lines, so the bar can't then disappear — two
        # passes always suffice.
        2.times do
          @_clines = _wrap_content(content, colwidth, into: @_clines)
          # Break test keys off line count, which `_wrap_content` already set;
          # cache-key fields below don't affect it, so set them once after.
          break if @_clines.margin == content_margin_x
        end
        @_clines.width = colwidth
        @_clines.base_x = @child_base_x
        @_clines.content = @content
        @_clines.content_version = @_content_version
        # `_parse_attr` already computes `sattr(style)` and records it in
        # `@_parse_attr_default`, so no separate recompute needed here.
        @_clines.attr = _parse_attr @_clines
        # Reuse the `CLines`' own `ci` array by clearing and refilling, instead
        # of allocating a fresh replacement every reparse.
        ci = @_clines.ci
        ci.clear
        @_clines.reduce(0) do |total, line|
          ci.push(total)
          total + line.size + 1
        end

        @_pcontent = clines_joined
        emit Crysterm::Event::ParsedContent

        return true
      end

      # Refresh the cached base attribute only when it actually changed (default
      # fg/bg/flags); on a frame where nothing changed this skips all the work
      # below. `@_parse_attr_default` MUST stay current regardless of content
      # shape: `_render` reads it unconditionally as the widget's fill/background
      # attr (`default_attr`), so freezing it would freeze the background of any
      # widget that only ever changes `style.bg` — e.g. an empty single-line
      # `Effect::CopperBar` that recolors every frame would stop animating.
      da = sattr(style)
      if da != @_parse_attr_default
        @_parse_attr_default = da
        # Recompute whenever a packed attr array already exists: leaving it
        # populated-but-stale (the old size gate skipped a ≤1-line unscrolled
        # widget) let `append_content`'s fast path seed every appended line's
        # starting attr from the stale `attrs[0]`, and — since `da` then equalled
        # `@_parse_attr_default` forever after — the refresh never fired again, so
        # a later `scroll` painted with the old default attr permanently. The
        # skipped case has ≤1 line, so the recompute is negligible. When no array
        # exists yet (`nil`) `_render` never reads it, so nothing to refresh.
        @_clines.attr = _parse_attr(@_clines) unless @_clines.attr.nil?
      end

      false
    end

    # Convert `{red-fg}foo{/red-fg}` to `\e[31mfoo\e[39m`.
    def _parse_tags(text)
      return text unless @parse_tags
      # Enter the parser whenever a brace is present (not only on a valid tag):
      # under the drop-malformed policy a stray `{`/`}` must be stripped too.
      return text unless text.includes?('{') || text.includes?('}')

      # `String::Builder` instead of `outbuf += ...`, which would rebuild the
      # whole result on every tag (O(n^2) for heavily-tagged content). The
      # cursor is an integer offset advanced via ANCHORED matches rather than
      # reslicing `text` each step (the old approach allocated a fresh tail
      # `String` per tag, a second O(n^2)).
      outbuf = String::Builder.new
      bg = [] of String
      fg = [] of String
      flag = [] of String

      esc = false
      pos = 0
      size = text.size
      anchored = Regex::MatchOptions::ANCHORED

      # `{escape}` and `{|}` are rare; decide once up front whether either is
      # present so the per-iteration path skips the `{escape}` regex match and
      # the `text[pos, 3]` substring allocation otherwise paid per token.
      has_escape = text.includes?("{escape}")
      has_bar = text.includes?("{|}")

      while pos < size
        if has_escape
          if !esc && (cap = /{escape}/.match(text, pos, options: anchored))
            pos += cap[0].size
            esc = true
            next
          end

          if esc && (cap = /([\s\S]+?){\/escape}/.match(text, pos, options: anchored))
            pos += cap[0].size
            outbuf << cap[1]
            esc = false
            next
          end

          if esc
            # raise "Unterminated escape tag."
            outbuf << text[pos..]
            break
          end
        end

        # `{|}` is Blessed's right-align separator, not an attribute tag: text
        # after it is pushed to the line's right edge. Must survive parsing
        # verbatim so `#_align` can act on it; otherwise it falls through to the
        # drop-malformed branch and renders as a bare `|`.
        if has_bar && text[pos, 3]? == "{|}"
          outbuf << "{|}"
          pos += 3
          next
        end

        # A recognized `{tag}` / `{/tag}`. `{open}`/`{close}` emit literal
        # braces; a known attribute name emits its SGR (tracking nesting so a
        # close restores the previous state); an unrecognized tag is dropped
        # (drop-malformed policy, todoc Q6). `Tput#_attr` returns "" for an
        # unknown name, non-empty for every known one, so `empty?` is the test.
        if cap = TAG_REGEX.match(text, pos, options: anchored)
          pos += cap[0].size
          slash = cap[1] == "/"
          # XXX Tags must be specified such as {light-blue-fg}, but are then
          # parsed here with - being ' '. See why? Can we work with - and skip
          # this replacement part?
          # Char-`gsub`, only when a dash is present — dash-free tags (`bold`,
          # `red`) reuse the captured name with no scan or allocation.
          param = cap[2]
          param = param.gsub('-', ' ') if param.includes?('-')

          if param == "open"
            outbuf << '{'
            next
          elsif param == "close"
            outbuf << '}'
            next
          elsif param == "left" || param == "center" || param == "right"
            # `{left}`/`{center}`/`{right}` (and `{/...}` closers) are line-
            # alignment tags, not attribute tags — no SGR, so the recognized-
            # attribute path below would drop them as unknown, silently
            # disabling `{center}…{/center}` alignment. `#_wrap_content` consumes
            # them (matches `^{(left|center|right)}` / `{/(…)}$` per line) after
            # `_parse_tags` runs, so they must survive parsing verbatim, like
            # `{|}` above. `cap[0]` includes the slash, so opener and closer both
            # pass through.
            outbuf << cap[0]
            next
          end

          state = if param.ends_with?(" bg")
                    bg
                  elsif param.ends_with?(" fg")
                    fg
                  else
                    flag
                  end

          if slash
            if param.blank?
              # `{/}` resets everything.
              outbuf << window.tput._attr("normal")
              bg.clear
              fg.clear
              flag.clear
            elsif !window.tput._attr(param).empty? # recognized -> restore prior
              # D O:
              # if (param !== state[state.size - 1])
              #   throw new Error('Misnested tags.')
              # }
              # `pop?` (not `pop`): a recognized closing tag with no matching open
              # leaves the stack empty. Crystal's `Array#pop` raises on empty,
              # which would crash the parse on unbalanced-but-recognized input.
              # Blessed's JS `array.pop()` returns `undefined` and falls through
              # to emit the tag's "off" SGR; `pop?` reproduces that.
              state.pop?
              outbuf << (state.size > 0 ? window.tput._attr(state[-1]) : window.tput._attr(param, false))
            end
            # else: unrecognized closing tag -> dropped
          else
            attr = window.tput._attr(param)
            unless attr.empty? # recognized opening tag
              state.push(param)
              outbuf << attr
            end
            # else: unrecognized opening tag -> dropped
          end

          next
        end

        # A run of plain (brace-free) text passes through verbatim. Find the next
        # brace by index instead of an anchored regex match, avoiding a per-run
        # `MatchData`/capture allocation.
        b1 = text.index('{', pos)
        b2 = text.index('}', pos)
        nb = b1 ? (b2 ? Math.min(b1, b2) : b1) : (b2 || size)
        if nb > pos
          outbuf << text[pos...nb]
          pos = nb
          next
        end

        # A lone `{`/`}` that did not begin a recognized tag is malformed and
        # dropped (use `{open}`/`{close}`/`{escape}` to emit real braces).
        pos += 1
      end

      outbuf.to_s
    end

    # Base attribute after scanning `line`'s inline SGR sequences starting from
    # `attr`. Shared by `_parse_attr` (advances the running attr line-to-line)
    # and `append_content` (carries SGR state across the append boundary, so a
    # `{red-fg}` left open on an earlier line colors appended lines too).
    # `default_attr` is `sattr(style)`, passed in so callers compute it once.
    private def _attr_after(line : String, attr : Int64, default_attr : Int64) : Int64
      line.each_char_with_index do |char, i|
        if char == '\e'
          if c = SGR_REGEX.match(line, i, options: Regex::MatchOptions::ANCHORED)
            attr = window.attr2code(c[0], attr, default_attr)
          end
        end
      end
      attr
    end

    def _parse_attr(lines : CLines)
      default_attr = sattr(style)
      # Record the base attribute this parse was built against, so callers don't
      # recompute `sattr(style)` separately.
      @_parse_attr_default = default_attr
      attr = default_attr
      # Reuse the `CLines`' own `attr` array (clear + refill) instead of
      # allocating a fresh `Array(Int64)` each reparse.
      attrs = (lines.attr ||= [] of Int64)
      attrs.clear

      # Fast path: with no inline SGR at all (no raw `\e`, no tags expanding into
      # one — see `@_content_has_sgr`/`@_content_has_tags`), every line carries
      # the same base attr, so fill directly and skip the per-line `_attr_after`
      # scan. Covers the common case (plain-text labels/list-items/per-cell
      # boxes).
      if !@_content_has_sgr && !@_content_has_tags
        lines.size.times { attrs.push default_attr }
        return attrs
      end

      lines.each do |line|
        attrs.push attr
        # Advance the running attr through this line's inline SGRs. `_attr_after`
        # walks codepoints with `each_char_with_index` (no `line.chars` array) and
        # matches each SGR anchored in place (no `line[i..]` slice), so a colored
        # line is scanned with no per-line/per-escape `String` allocation.
        attr = _attr_after(line, attr, default_attr)
      end

      attrs
    end

    # Appends one finished wrapped (real) line and records the fake↔real
    # mapping: `line` becomes a new real row of `outbuf`, fake line `no` gains
    # that real index in `ftor`, and `rtof` gains `no`. The shared three-line
    # tail of the three line-emitting branches in `#_wrap_content` (no-wrap
    # slice, mid-line wrap cut, and final remainder), which differ only in how
    # `line` was produced.
    private def push_real_line(outbuf : CLines, ftor, rtof, no : Int32, line : String) : Nil
      outbuf.push line
      ftor[no].push(outbuf.size - 1)
      rtof.push(no)
    end

    # Wraps content based on available widget width.
    #
    # `into`, when given, is an existing `CLines` to refill in place rather than
    # allocating a fresh one — `process_content` passes the widget's own
    # `@_clines`, so steady-state reparsing reuses the same object and its array
    # buffers (see `CLines#reset`). When nil a new `CLines` is built.
    def _wrap_content(content, colwidth, into : CLines? = nil)
      default_state = @align
      # Capture the right-edge reservation before `outbuf.reset` below: `reset`
      # clears `@_clines` when `into` is the widget's own, and
      # `content_margin_x` reads `@_clines.size` to size an `AsNeeded` bar — read
      # post-reset it would see zero lines and think the bar unneeded mid-wrap.
      # Reading pre-reset lets `process_content`'s convergence pass see the first
      # pass's line count instead of re-zeroing and oscillating.
      margin = content_margin_x
      outbuf = into || CLines.new
      # Record the reservation this wrap is built against, so `process_content`
      # can tell when an `AsNeeded` bar's presence (only known post-wrap) flips
      # it and a re-wrap is needed.
      outbuf.margin = margin
      # Clear in-place arrays so a reused `CLines` starts empty (no-op when
      # freshly built). `rtof`/`ftor` aliases below fill the `CLines`' own
      # arrays directly. (The empty-content branch returns before these are used.)
      outbuf.reset
      outbuf.full_width = 0
      rtof = outbuf.rtof
      ftor = outbuf.ftor

      if !content || content.empty?
        outbuf.push(content)
        outbuf.rtof = [0]
        outbuf.ftor = [[0]]
        outbuf.fake = [] of String
        outbuf.real = outbuf
        outbuf.max_width = 0
        return outbuf
      end

      # Reuse the `fake` array for common single-line content (label, list item,
      # panel title): refill in place instead of letting `String#split` allocate
      # a fresh `Array(String)` every reparse. Multi-line content still splits,
      # since its substrings must be allocated anyway.
      if content.includes?('\n')
        lines = content.split('\n')
      else
        lines = outbuf.fake
        lines.clear
        lines << content
      end

      # Subtract the right-edge reservation so content wraps clear of the scroll
      # bar (and any per-widget reservation, e.g. `PlainTextEdit`'s caret
      # column). `#content_margin_x` is shared with the horizontal-scroll math
      # (`#content_width`).
      colwidth -= margin if colwidth > margin

      lines.each_with_index do |line, no|
        align = default_state
        align_left_too = false

        ftor.push outbuf.take_ftor_row

        # Handle alignment tags. The opener may be preceded — and the closer
        # followed — by inline SGR, which happens when an alignment tag nests
        # inside an attribute tag: `{bold}{center}Hi{/center}{/bold}` becomes
        # `\e[1m{center}Hi{/center}\e[22m` after `_parse_tags`. Matching the
        # alignment tag only at the absolute string edge missed that SGR-wrapped
        # form, silently dropping the alignment and leaking literal
        # `{center}`/`{/center}` text into output. Allow surrounding SGR in the
        # match and re-prepend/-append it so only the alignment tag is consumed.
        if @parse_tags
          if cap = line.match /^((?:\e\[[\d;]*m)*){(left|center|right)}/
            align_left_too = true
            # Drop the tag, keep any leading SGR that preceded it.
            line = cap[1] + line[cap[0].size..]
            align = default_state = case cap[2]
                                    when "center"
                                      Tput::AlignFlag::Center
                                    when "left"
                                      Tput::AlignFlag::Left
                                    else
                                      Tput::AlignFlag::Right
                                    end
          end
          if cap = line.match /{\/(left|center|right)}((?:\e\[[\d;]*m)*)$/
            # Drop the closing tag, keep any trailing SGR that followed it.
            line = line[0...(line.size - cap[0].size)] + cap[2]
            # Reset default_state to whatever alignment the widget has by default.
            default_state = @align
          end
        end

        # Without wrapping, the line is one full row: record its true width for
        # the horizontal scroll range, then slice to the visible column window
        # `[child_base_x, child_base_x + colwidth)`. At `child_base_x == 0` this
        # is the old "keep what fits, cut the rest" truncation (see `#_hslice`).
        unless @wrap_content
          outbuf.full_width = Math.max(outbuf.full_width, str_width(line))
          push_real_line outbuf, ftor, rtof, no, _align(_hslice(line, @child_base_x, colwidth), colwidth, align, align_left_too)
          next
        end

        # If the string could be too long, check it in more detail and wrap it if needed.
        # NOTE Done with loop+break due to https://github.com/crystal-lang/crystal/issues/1277
        loop_ret = loop do
          break unless str_width(line) > colwidth

          # Character index at which to cut so the kept prefix fits `colwidth`
          # columns. SGR consumes no width; under `full_unicode?` widths are
          # grapheme/East-Asian and clusters are never split.
          i = wrap_cut_index(line, colwidth)

          # Word wrap: back up from the column-fit cut `i` to the most recent
          # space within the previous ~10 chars and cut just after it, so a word
          # isn't split mid-way. Falls back to character-wrap `i` if no space
          # found. Mirrors blessed's `while (j > i-10 && j > 0)` scan.
          #
          # The scan works on raw codepoints, which include inline SGR bytes
          # (`\e[…m`). Skip over any escape run encountered so its `\e`/`[`/digit/
          # `;`/`m` bytes neither consume the ~10-char lookback budget nor let the
          # cut land inside an escape (`m`/digits are not spaces, but a preceding
          # `\e` must stay attached to its sequence). When a run's terminating `m`
          # is met walking backwards, jump `j` back to the opening `\e`.
          if i != line.size
            j = i
            while (j > i - 10) && (j > 0)
              j -= 1
              if line[j] == 'm' && (esc = sgr_run_start(line, j))
                # Land `j` on the `\e` so the next `j -= 1` steps past the run.
                j = esc
                next
              end
              if line[j] == ' '
                i = j + 1
                break
              end
            end
          end

          part = line[0...i]
          line = line[i..]

          push_real_line outbuf, ftor, rtof, no, _align(part, colwidth, align, align_left_too)

          # Make sure we didn't wrap the line at the very end, otherwise
          # we'd get an extra empty line after a newline.
          if line == ""
            break :main
          end

          # If only an escape code got cut off, add it to `part`.
          if line.matches? /^(?:\e\[[\d;]*m)+$/ # SGR
            outbuf[outbuf.size - 1] += line
            break :main
          end
        end

        # `each_with_index` rebinds `no` each iteration, so mutating it here is
        # dead — `next`/falling through both advance to the next fake line.
        next if loop_ret == :main

        push_real_line outbuf, ftor, rtof, no, _align(line, colwidth, align, align_left_too)
      end

      # `rtof`/`ftor` already alias `outbuf`'s own arrays (filled in place above).
      outbuf.fake = lines
      outbuf.real = outbuf

      # Saves the longest line's length to outbuf.max_width. If text was
      # aligned, padding spaces lengthen it, so max_width then reflects the
      # surrounding box's width rather than the actual longest line.
      outbuf.max_width = outbuf.reduce(0) do |current, line|
        Math.max str_width(line), current
      end

      outbuf
    end

    # Aligns content
    def _align(line, width, align = Tput::AlignFlag::None, align_left_too = false)
      # Right-align separator `{|}` (Blessed): text after it is pushed to the
      # right edge. Distributes content within the line independent of the
      # line's own alignment, so handle before the align-direction early-returns
      # below — otherwise it would never fire for default Left alignment.
      if @parse_tags && line.includes?("{|}")
        cl = line.includes?('\e') ? line.gsub(SGR_REGEX, "") : line
        if res = split_right_align(line, cl, width)
          return res
        end
      end

      return line if align.none?

      # Plain left alignment pads nothing — only HCenter/Right (or a forced
      # `{left}` via `align_left_too`) add spaces. Bail before measuring width: a
      # widget's default `@align` carries `Left`, the common case, skipping a
      # `str_width` call on every aligned line.
      if !align_left_too && (align & (Tput::AlignFlag::HCenter | Tput::AlignFlag::Right)).none?
        return line
      end

      # Only run the SGR-stripping `gsub` when the line actually contains an
      # escape; most aligned lines carry no color, so a cheap `includes?` check
      # lets them reuse `line` with no allocation.
      cline = line.includes?('\e') ? line.gsub(SGR_REGEX, "") : line
      # `cline` is already SGR-stripped (or had none); `str_width cline` skips
      # the regex scan `str_width line` would otherwise repeat.
      len = str_width cline

      # XXX In blessed's code (and here) it was done only with this commented
      # line below. But after/around the May 28 2021 changes, this stopped
      # centering texts. Upon investigation, it was found this is because a
      # Layout sets all its children to #resizable=true (shrink=true in blessed),
      # so the free width (s) results being 0 here. But why this code worked
      # up to May is unexplained, since no obvious changes were done in this
      # code. Or, cn this be a bug we unintentionally fixed?
      # s = @resizable ? 0 : width - len
      # NOTE: `width` is an Int, so the old `!width` was always false (only
      # `nil`/`false` are falsy in Crystal), making the resizable branch dead.
      # The intent is to skip alignment padding for a resizable widget that has
      # no usable width yet, i.e. `width == 0`.
      s = (@resizable && width == 0) ? 0 : width - len

      return line if len == 0
      return line if s < 0

      # The empty space produced by alignment is filled with the widget's
      # `Style#fill_char` (default `' '`), so a non-space fill (e.g. a dotted
      # leader) lines up with how the render loop fills trailing cells.
      fc = style.fill_char.to_s

      if (align & Tput::AlignFlag::HCenter) != Tput::AlignFlag::None
        # Split free space across both sides; the odd extra cell goes right
        # (Blessed's convention), so a centered line still fills `width` exactly
        # instead of falling one cell short on odd free space.
        left = fc * (s // 2)
        right = fc * (s - s // 2)
        return left + line + right
      elsif align.right?
        s = fc * s
        return s + line
      elsif align_left_too && align.left?
        # Left align is visually the same as no align, but center/right padding
        # affects widget size, so pad {left} for uniformity too — only when
        # "{left}" is explicitly in content with parse_tags on, not for a
        # widget's default `align = AlignFlag::Left` (which affects cursor
        # position in text widgets undesirably). Ensures {left|center|right}
        # behave identically re. row width. To see old behavior, comment this
        # elseif and check test/widget-list.cr's first list element.
        s = fc * s
        return line + s
      elsif @parse_tags && (line.includes?('{') || line.includes?('}'))
        # XXX This is basically Tput::AlignFlag::Spread, but not sure
        # how to put that as a flag yet. Maybe this (or another)
        # widget flag could mean to spread words to fill up the whole
        # line, increasing spaces between them?
        if res = split_right_align(line, cline, width)
          return res
        end
        # Otherwise (lone `{` or `}`): falls through to `return line` below.
      end

      line
    end

    # Right-aligns text after a `{...}` split: the segment before the first
    # delimiter stays put, the segment after the second is pushed flush right
    # within `width`, gap filled by `Style#fill_char`. Backs both the `{|}`
    # right-align separator and the generic `{left}…{right}` spread.
    #
    # `line` is the raw (possibly SGR-carrying) line; `cline` is its SGR-stripped
    # form for width measurement. Returns `nil` when there's no usable two-sided
    # split (e.g. a lone `{` or `}`), and the caller leaves `line` unchanged.
    private def split_right_align(line, cline, width) : String?
      parts = line.split(/\{|\}/)
      cparts = cline.split(/\{|\}/)
      if cparts[0]? && cparts[2]?
        pad = style.fill_char.to_s * Math.max(width - str_width(cparts[0]) - str_width(cparts[2]), 0)
        "#{parts[0]}#{pad}#{parts[2]}"
      end
    end

    # Rebuilds widget content from the in-place-mutated `@_clines.fake` lines
    # (re-joining and reparsing). `no_clear` is set so `@_clines` is refreshed
    # rather than wiped. Used by line-level editors (`insert_line`/
    # `delete_line`/`set_line`) after they splice `fake`.
    private def rebuild_content_from_fake
      set_content(@_clines.fake.join("\n"), true)
    end

    # Scratch `CLines` reused across `append_content` calls so wrapping just the
    # appended line never allocates a fresh bookkeeping object.
    @_append_scratch : CLines? = nil

    # Appends `text` (one or more `\n`-separated logical lines) without reparsing
    # existing content. Only the new text is cleaned, tag-parsed, wrapped and
    # attr-scanned, then spliced onto `@_clines`'s tail — turning `set_content`'s
    # O(total) per-append cost into O(appended).
    #
    # Returns `true` if the fast path handled it, `false` if it bailed (caller
    # falls back to `set_content`/`push_line`): empty content, stale parse cache,
    # or a width change requiring re-wrap.
    #
    # Byte-identical to a full reparse because:
    # * `_wrap_content` wraps each `\n`-split segment independently, so appending
    #   never re-wraps earlier lines.
    # * `@_clines.fake` stores already-parsed (SGR) content for earlier lines, so
    #   a full reparse's tag stacks start empty at the new segment's boundary —
    #   parsing it standalone matches that exactly.
    # * Attributes do carry: an SGR left open on an earlier line (e.g. unclosed
    #   `{red-fg}`) colors appended lines too; `_attr_after` recreates that carry.
    def append_content(text : String) : Bool
      return false unless window?
      # Cache must be current: if a reparse is pending, splicing onto stale
      # `@_clines` would corrupt it. Let the normal path run first.
      return false unless @_clines.content_version == @_content_version
      return false if content_blank?
      colwidth = @_clines.width
      return false if colwidth <= 0
      # Bail if width changed since the cache was built — the slow path reparses
      # at the new width; the fast path can only splice when existing wrapped
      # lines are still valid for the current width.
      return false if (awidth - iwidth) != colwidth
      # Degenerate state: content cleaned to nothing leaves `_wrap_content` in
      # its empty-content shape (`fake` empty, one blank real line). Splicing
      # there would desync `fake` from `lines`; let the full path handle it.
      return false if @_clines.fake.empty?

      # An unclosed `{center}`/`{right}` alignment opener mutates `_wrap_content`'s
      # carried `default_state` for all following lines in a full reparse, but the
      # fast path wraps the appended segment standalone from the widget's default
      # `@align`, dropping that carry (finding 33). Conservatively bail whenever
      # tag parsing is on and alignment tags are present in existing content or the
      # appended text, so the slow path keeps the result byte-identical to a full
      # reparse.
      if @parse_tags && (@_content_has_align_tag || (text.includes?('{') && text.matches?(ALIGN_TAG_REGEX)))
        return false
      end

      # Clean control chars on just the appended text (same rule as
      # `process_content`, via `#clean_content_chars`), then tag-parse only the
      # new segment.
      seg = clean_content_chars text
      # An append that cleans away to nothing would drive `_wrap_content` down
      # its empty-content branch, desyncing `fake` from `lines`; let the full
      # path produce the blank line `push_line` wants.
      return false if seg.empty?

      # Honor the content's `no_tags` mode: content set via `#set_text` keeps
      # tags literal, so an appended segment must not be tag-parsed either, or
      # the fast path would diverge from a full reparse.
      seg_has_tags = @parse_tags && !@_content_no_tags && seg.includes?('{') && seg.matches?(TAG_REGEX)
      if seg_has_tags
        # Standalone tag parse is correct here since earlier `fake` lines are
        # already SGR (tagless), so a full reparse's tag stacks are likewise
        # empty at this boundary.
        seg = _parse_tags seg
      end

      # Wrap only the appended segment into a scratch CLines.
      scratch = (@_append_scratch ||= CLines.new)
      _wrap_content(seg, colwidth, into: scratch)

      cl = @_clines
      base_real = cl.lines.size
      base_fake = cl.fake.size

      # Splice the scratch's real lines, fake lines and mappings onto the tail,
      # offsetting the indices by where the existing content ends. `lines`/`fake`
      # need no offset (bulk `concat`); `ftor`/`rtof` are renumbered.
      cl.lines.concat scratch.lines
      cl.fake.concat scratch.fake
      scratch.ftor.each do |row|
        cl.ftor << row.map { |r| r + base_real }
      end
      scratch.rtof.each { |f| cl.rtof << (f + base_fake) }

      # Extend `ci` (char offset of each real line in the joined pcontent),
      # derived from existing offsets, not `@_pcontent` (lazily built, may be
      # stale/nil here). First new line starts one past the last existing line's
      # end: `ci[last] + len(last) + 1` (the +1 is the joining "\n"). `base_real
      # >= 1` since content is non-blank. Use the safe `[]?` for `ci` (mirroring
      # the defensive access in `#insert_line`): if it's somehow short, fall back
      # to `0` rather than raising, so the offsets stay monotonic.
      running = (cl.ci[base_real - 1]? || 0) + cl.lines[base_real - 1].size + 1
      scratch.lines.each do |ln|
        cl.ci << running
        running += ln.size + 1
      end

      # Per-line starting attrs for new lines, carrying SGR state across the
      # boundary: first new line starts from the attr the existing content ended
      # on, each subsequent line continues from the previous — matching
      # `_parse_attr`'s line-to-line carry.
      if attrs = cl.attr
        da = sattr(style)
        # `base_real >= 1` (content non-blank); degrade to default if `attrs` is
        # somehow short.
        carry = base_real <= attrs.size ? _attr_after(cl.lines[base_real - 1], attrs[base_real - 1], da) : da
        scratch.lines.each do |ln|
          attrs << carry
          carry = _attr_after(ln, carry, da)
        end
      end

      cl.max_width = Math.max(cl.max_width, scratch.max_width)
      # Carry widest unclipped line forward too (non-wrapped content only;
      # `full_width` is 0 when wrapping). Drives `get_scroll_width` / horizontal
      # scroll range — without merging, a wider appended line would leave the
      # extent stale.
      cl.full_width = Math.max(cl.full_width, scratch.full_width)

      # Defer the two O(total) string builds instead of doing them per append —
      # this makes a run of appends O(1) amortized rather than O(n) each:
      #   * `@_pcontent` is marked stale (nil); `#pcontent` rebuilds it on demand.
      #     A fresh String also makes render's `built_from?` check rebuild the
      #     codepoint index.
      #   * the raw appended `text` is stashed in `@_content_tail`; `#content`
      #     folds it in only when read.
      @_pcontent = nil
      @_content_tail << text
      @_content_has_tags ||= seg_has_tags
      # Keep inline-SGR flag current across deferred appends (cleaned `seg`
      # retains valid SGR; stray ESC already stripped above).
      @_content_has_sgr ||= seg.includes? '\e'
      @_content_version += 1
      cl.content_version = @_content_version

      # If the appended lines crossed the viewport-overflow threshold, an
      # `AsNeeded` vertical scroll bar just flipped on (or off), so
      # `content_margin_x` changed. The existing lines *and* the just-wrapped
      # segment were wrapped against the pre-flip margin (`@_clines.margin`,
      # which the splice above leaves untouched), but a full reparse would
      # re-wrap every line at the new width. Reconcile now with one full reparse
      # so we never leave stale-margin lines behind — otherwise they survive
      # until the next `process_content`, desyncing readers (`get_scroll_height`,
      # `Log` auto-scroll) that run off the events emitted just below. Rare: only
      # the single append that crosses the threshold pays this; once the bar's
      # presence is stable, subsequent appends stay on the O(appended) fast path.
      if cl.margin != content_margin_x
        process_content
      end

      # Mirror the full path: mark for repaint, emit the same events —
      # `ParsedContent` (scrollable widgets' `_recalculate_index`) and
      # `SetContent` (e.g. `Log` auto-scroll).
      mark_dirty
      emit Crysterm::Event::ParsedContent
      emit Crysterm::Event::SetContent
      true
    end

    def insert_line(i = nil, line = "")
      if line.is_a? String
        line = line.split("\n")
      end

      if i.nil?
        i = @_clines.ftor.size
      end

      i = Math.max(i, 0)

      while @_clines.fake.size < i
        @_clines.fake.push("")
        @_clines.ftor.push([@_clines.push("").size - 1])
        # Discarded read kept only for parity with the port; use the safe `[]?`
        # so it cannot raise `IndexError` when `rtof` is shorter than `fake`.
        @_clines.rtof[@_clines.fake.size - 1]?
      end

      # NOTE: Could possibly compare the first and last ftor line numbers to see
      # if they're the same, or if they fit in the visible region entirely.
      start = @_clines.size
      # diff
      # real

      if i >= @_clines.ftor.size
        # `ftor` is empty before the first wrap (freshly built widget, or content
        # cleared to empty). `ftor[-1]` would then raise `IndexError`, crashing
        # `insert_line`/`unshift_line`/`insert_top`. Default the insert point to
        # the first real line, mirroring the empty-content guards in
        # `#get_line`/`#rtof_index`.
        if last_row = @_clines.ftor.last?
          real = last_row[-1] + 1
        else
          real = 0
        end
      else
        real = @_clines.ftor[i][0]
      end

      line.size.times do |j|
        @_clines.fake.insert(i + j, line[j])
      end

      rebuild_content_from_fake

      diff = @_clines.size - start

      render_line_shift(diff, real) do |d, y, top, bottom|
        window.insert_line(d, y, top, bottom)
      end
    end

    # Drives the terminal-side `window.insert_line`/`delete_line` optimization
    # shared by `#insert_line` and `#delete_line` (which differ only in *which*
    # window op they run). *diff* is the change in wrapped-line count (only acts
    # when positive) and *real* the affected real (wrapped) line index. Computes
    # the on-window coordinates and, when the affected row is visible and the
    # sides are clean, yields `(diff, y, top, bottom)` for the caller's window
    # op. A no-op (no yield) when the widget isn't laid out or the row is off
    # the viewport.
    private def render_line_shift(diff, real, &)
      return unless diff > 0
      pos = _get_coords
      return if !pos || pos == 0

      height = pos.yl - pos.yi - iheight
      base = @child_base
      visible = real >= base && real - base < height

      if visible && window.clean_sides(self)
        yield diff, pos.yi + itop + real - base, pos.yi, pos.yl - ibottom - 1
      end
    end

    def delete_line(i = nil, n = 1)
      # Nothing to delete when there are no logical lines yet (`@_clines.fake`
      # empty: freshly built widget, or content cleared to empty). Without this
      # guard, `delete_top`/`delete_bottom`/`shift_line`/`pop_line`/`delete_line`
      # would raise `IndexError` on such a widget. Mirrors the empty-content
      # guard in `#insert_line`/`#get_line`; Blessed's `deleteLine` is a no-op here.
      return if @_clines.fake.empty?
      if i.nil?
        i = @_clines.ftor.size - 1
      end

      i = i.clamp(0, @_clines.ftor.size - 1)

      # Clamp count to lines actually available from `i`: deleting more than
      # remain (`pop_line 2`, `shift_line n` past the line count, etc.) would
      # otherwise run `delete_at` off the end of `fake`. JS `splice(i, n)`
      # clamps, so this matches the ported Blessed semantics.
      n = Math.min(n, @_clines.fake.size - i)
      return if n <= 0

      # NOTE: Could possibly compare the first and last ftor line numbers to see
      # if they're the same, or if they fit in the visible region entirely.
      start = @_clines.size
      # diff
      # `ftor` is empty when content was seeded before attach (`push_line`/
      # `set_line` fill `fake` but `process_content` bails until `window?`), so
      # `ftor[i]` would raise `IndexError` despite `fake` being non-empty (finding
      # 32). Fall back to real line 0; the fake splice + rebuild below still works.
      real = @_clines.ftor[i]?.try(&.[0]?) || 0

      n.times { @_clines.fake.delete_at i }

      rebuild_content_from_fake

      diff = start - @_clines.size

      # XXX clear_last_rendered_position() without diff statement?
      render_line_shift(diff, real) do |d, y, top, bottom|
        window.delete_line(d, y, top, bottom)
      end

      # When content shrank this used to erase the leftover footprint via
      # `clear_last_rendered_position`; the whole-buffer clear in `Window#_render`
      # now takes care of that, so the explicit clear is no longer needed.
    end

    # Maps a real (wrapped) line index to its fake (logical) line index via
    # `@_clines.rtof`, guarding out-of-range access (e.g. before content is
    # wrapped). Returns 0 when `rtof` is empty, clamps otherwise.
    private def rtof_index(i)
      rtof = @_clines.rtof
      return 0 if rtof.empty?
      rtof[i.clamp(0, rtof.size - 1)]
    end

    def insert_top(line)
      fake = rtof_index(@child_base)
      insert_line(fake, line)
    end

    def insert_bottom(line)
      # Use the centralized viewport-height helper (which subtracts the horizontal
      # scroll bar's reserved row) instead of the pre-hscrollbar `aheight - iheight`
      # so we don't insert after a line hidden under the bar (finding 34).
      h = @child_base + visible_content_rows
      i = Math.min(h, @_clines.size)
      fake = rtof_index(i - 1) + 1

      insert_line(fake, line)
    end

    def delete_top(n = 1)
      fake = rtof_index(@child_base)
      delete_line(fake, n)
    end

    def delete_bottom(n)
      # Mirror `insert_bottom`: use `visible_content_rows` (accounts for the
      # horizontal scroll bar's reserved row) so we delete the visible bottom row,
      # not one hidden below the bar (finding 34).
      h = @child_base + visible_content_rows - 1
      i = Math.min(h, @_clines.size - 1)
      fake = rtof_index(i)

      n = 1 if !n || n == 0

      delete_line(fake - (n - 1), n)
    end

    def set_line(i, line)
      i = Math.max(i, 0)
      # Pad up to and including index `i` (`<=`, not `<`). Blessed relies on JS
      # auto-extending arrays; Crystal's `fake[i] = line` raises when `i ==
      # fake.size`, so the slot must exist first.
      while @_clines.fake.size <= i
        @_clines.fake.push("")
      end
      @_clines.fake[i] = line
      rebuild_content_from_fake
    end

    def set_baseline(i, line)
      fake = rtof_index(@child_base)
      set_line(fake + i, line)
    end

    def get_line(i)
      # Empty content leaves `@_clines.fake` empty. `i.clamp(0, fake.size - 1)`
      # then clamps to `-1` (Crystal's two-arg clamp yields `max` even when `min
      # > max`), so `fake[-1]` would raise on the empty array. Return a blank
      # line instead, matching Blessed's `getLine` for a missing line. Guards
      # `get_baseline` too.
      return "" if @_clines.fake.empty?
      i = i.clamp(0, @_clines.fake.size - 1)
      @_clines.fake[i]
    end

    def get_baseline(i)
      fake = rtof_index(@child_base)
      get_line(fake + i)
    end

    def clear_line(i)
      i = Math.min(i, @_clines.fake.size - 1)
      set_line(i, "")
    end

    def clear_base_line(i)
      fake = rtof_index(@child_base)
      clear_line(fake + i)
    end

    def unshift_line(line)
      insert_line(0, line)
    end

    def shift_line(n)
      delete_line(0, n)
    end

    def push_line(line)
      # Seed line 0 when there is no content yet (counting deferred appends
      # without materializing them).
      if content_blank?
        return set_line(0, line)
      end
      # Appending at the end is the common case (logs, transcripts, streaming
      # output). `append_content` splices just the new line onto `@_clines`
      # instead of reparsing everything — O(appended) rather than O(total). It
      # bails (returns false) when it can't guarantee an identical result (stale
      # cache or width change), falling through to the general insert.
      #
      # NOTE: there is deliberately no `Widget#<<` text alias — `<<` already means
      # "append a child widget" (`Mixin::Children#<<`).
      return if append_content(line)
      insert_line(@_clines.fake.size, line)
    end

    def pop_line(n)
      delete_line(@_clines.fake.size - 1, n)
    end

    def get_lines
      @_clines.fake.dup
    end

    def get_screen_lines
      @_clines.dup
    end

    # Whether grapheme / column-width-aware layout is in effect for this widget;
    # delegates to the owning window's effective gate (`Window#full_unicode?` =
    # option AND terminal capability). False when unattached.
    def full_unicode?
      window?.try(&.full_unicode?) || false
    end

    # Width, in terminal COLUMNS, of `text`'s visible content. SGR sequences are
    # stripped (they occupy no columns); whitespace is preserved. With
    # `#full_unicode?` this is grapheme / East-Asian width (`Unicode`), otherwise
    # the codepoint count (legacy behavior).
    #
    # This is the single width hook layout should use; previously most call sites
    # inlined `.size`, which miscounts wide / combining characters.
    def str_width(text)
      # Most strings have no SGR sequences; skip the regex (and the new String
      # it builds) unless an ESC is actually present. The `includes?` scan is a
      # cheap allocation-free byte check.
      text = text.gsub SGR_REGEX, "" if text.includes? '\e'
      full_unicode? ? Unicode.display_width(text) : text.size
    end

    # Longest *suffix* of `text` whose display width fits within `cols` columns,
    # measured by grapheme cluster (wide characters count as 2; clusters are
    # never split). Used by single-line inputs to show the tail of an over-long
    # value under `#full_unicode?`.
    def tail_within(text : String, cols : Int) : String
      return "" if cols <= 0
      return text if str_width(text) <= cols

      kept = [] of String
      width = 0
      text.each_grapheme.to_a.reverse_each do |g|
        gw = Unicode.width g
        break if width + gw > cols
        width += gw
        kept << g.to_s
      end
      kept.reverse!
      kept.join
    end

    # Longest *prefix* of `text` whose display width fits within `cols` columns,
    # measured by grapheme cluster (wide characters count as 2; clusters are
    # never split). The head-side mirror of `#tail_within`, for truncating an
    # over-long line to fit an inner width without splitting a wide glyph.
    def head_within(text : String, cols : Int) : String
      return "" if cols <= 0
      return text if str_width(text) <= cols

      kept = String::Builder.new
      width = 0
      text.each_grapheme do |g|
        gw = Unicode.width g
        break if width + gw > cols
        width += gw
        kept << g.to_s
      end
      kept.to_s
    end

    # Returns `text` with its last grapheme cluster removed (e.g. a base +
    # combining mark, or a wide emoji, comes off as one unit). Used for
    # grapheme-aware backspace in text inputs. Empty in, empty out.
    def chop_grapheme(text : String) : String
      return text if text.empty?
      # Track the final cluster's byte length while scanning (no per-cluster
      # allocation) and slice it off the end.
      last_bytes = 0
      text.each_grapheme { |g| last_bytes = g.bytesize }
      text.byte_slice 0, text.bytesize - last_bytes
    end

    # Whether *base* begins a multi-codepoint grapheme cluster, given successor
    # *nxt* — i.e. whether `#extend_grapheme` would assemble anything beyond
    # `base` alone. Cheap pre-check letting the renderer skip cluster assembly
    # for the common lone-codepoint cell. Mirrors `#extend_grapheme`'s start
    # conditions exactly.
    def needs_cluster?(base : Char, nxt : Char?) : Bool
      # Fast rejection for the dominant plain-text path: every cluster-relevant
      # `base` is ≥ U+0300 (combining marks; regional indicators sit higher) and
      # every cluster-relevant `nxt` is ≥ U+200D (ZWJ — the lowest of ZWJ,
      # marks, variation selectors, skin tones). Two integer compares replace
      # the `mark?` Unicode-category binary searches per ASCII/Latin cell.
      return false if base.ord < 0x300 && (nxt.nil? || nxt.ord < 0x200D)
      return true if base.mark? # a leading combining mark (zero-width; merges back)
      bp = base.ord
      return true if 0x1F1E6 <= bp <= 0x1F1FF # regional indicator (flag pair)
      return false unless nxt
      np = nxt.ord
      # A following combining mark, ZWJ, variation selector, or skin-tone modifier
      # extends the cluster.
      nxt.mark? || np == 0x200D || (0xFE00 <= np <= 0xFE0F) || (0x1F3FB <= np <= 0x1F3FF)
    end

    # Assembles the grapheme cluster beginning with `base` (codepoint at
    # `content[ci - 1]`) by consuming following extending codepoints from
    # `content` starting at `ci`: combining marks, ZWJ (and the codepoint it
    # joins), variation selectors, emoji skin-tone modifiers, and a second
    # regional indicator for flags. Returns `{cluster, new_ci}`.
    #
    # A pragmatic subset of UAX-#29 covering cases that occur in terminal text;
    # `content` is anything indexable by codepoint (`#[]?` returning `Char?`).
    def extend_grapheme(content, ci : Int32, base : Char) : Tuple(String, Int32)
      g = String::Builder.new
      g << base

      # A flag is a pair of regional indicators.
      if 0x1F1E6 <= base.ord <= 0x1F1FF
        if (c = content[ci]?) && (0x1F1E6 <= c.ord <= 0x1F1FF)
          g << c
          ci += 1
        end
        return {g.to_s, ci}
      end

      while c = content[ci]?
        cp = c.ord
        if c.mark? || cp == 0x200D || (0xFE00 <= cp <= 0xFE0F) || (0x1F3FB <= cp <= 0x1F3FF)
          g << c
          ci += 1
          # A ZWJ also pulls in the codepoint it joins (e.g. the next emoji).
          if cp == 0x200D && (c2 = content[ci]?)
            g << c2
            ci += 1
          end
        else
          break
        end
      end

      {g.to_s, ci}
    end

    # Given a codepoint index `mi` in `line` pointing at an `'m'`, returns the
    # codepoint index of the `\e` that opens the SGR sequence it terminates, or
    # `nil` if the bytes back to the `\e` aren't a valid `\e[[\d;]*m` run. Used by
    # the word-wrap back-scan to step over inline SGR runs. `line[k]` is O(k) for
    # multibyte content, but the run is short and this only fires when a candidate
    # `'m'` is seen within the ~10-char lookback window.
    def sgr_run_start(line : String, mi : Int32) : Int32?
      k = mi - 1
      while k >= 0
        c = line[k]
        case c
        when '\e'
          # Need the `[` immediately after the `\e` (i.e. at `k + 1`).
          return k if k + 1 < mi && line[k + 1] == '['
          return nil
        when '[', ';', '0'..'9'
          k -= 1
        else
          return nil
        end
      end
      nil
    end

    # Character index in `line` (which may contain inline SGR) at which to cut so
    # the kept prefix fits within `colwidth` columns. SGR sequences consume no
    # columns. Under `#full_unicode?` widths are grapheme/East-Asian and
    # clusters are never split; otherwise one column per codepoint (legacy).
    # Returns `line.size` when the whole line fits; a single grapheme wider than
    # `colwidth` is kept whole rather than looping forever.
    def wrap_cut_index(line : String, colwidth : Int) : Int32
      full = full_unicode?
      total = 0
      # Single forward walk via `Char::Reader` instead of the old char-by-char
      # scan (O(n²), since `String#[](Int)` is O(index) for multibyte content).
      # `cp` tracks the codepoint index of the reader's current char (what
      # callers slice by); `reader.pos` is the byte offset, used for grapheme
      # segmentation.
      bytesize = line.bytesize
      reader = Char::Reader.new line
      cp = 0
      while reader.pos < bytesize
        if reader.current_char == '\e'
          reader.next_char; cp += 1
          while reader.pos < bytesize && reader.current_char != 'm'
            reader.next_char; cp += 1
          end
          if reader.pos < bytesize # consume the terminating 'm'
            reader.next_char; cp += 1
          end
          next
        end

        # Contiguous run of visible text up to the next SGR (or end of line).
        run_byte_start = reader.pos
        run_cp_start = cp
        while reader.pos < bytesize && reader.current_char != '\e'
          reader.next_char; cp += 1
        end

        if full
          pos = run_cp_start
          line.byte_slice(run_byte_start, reader.pos - run_byte_start).each_grapheme do |g|
            gs = g.to_s
            w = Unicode.width gs
            # Cut before this cluster once we already have content placed.
            return pos if total + w > colwidth && total > 0
            total += w
            pos += gs.size
          end
        else
          (run_cp_start...cp).each do |k|
            total += 1
            return k + 1 if total == colwidth
          end
        end
      end
      cp
    end

    # Slices *line* to the display-column window `[from_col, from_col + width)`,
    # preserving SGR colors: the active escape state at the cut is re-emitted as
    # a prefix, and escapes past the window carried as a zero-width suffix, so a
    # clipped line still starts and ends in the right color. Column math is
    # grapheme/East-Asian-aware via `#wrap_cut_index`. With `from_col == 0` this
    # reduces to the original no-wrap truncation. Used by `_wrap_content` for
    # horizontal scrolling of non-wrapped content.
    def _hslice(line : String, from_col : Int32, width : Int32) : String
      # Fast path for the common SGR-free line: plain column-window substring,
      # no escape scanning.
      unless line.includes? '\e'
        from = from_col > 0 ? wrap_cut_index(line, from_col) : 0
        rest = line[from..]
        return rest[0...wrap_cut_index(rest, width)]
      end

      if from_col > 0
        cut = wrap_cut_index(line, from_col)
        prefix_sgr = line[0...cut].scan(/\e\[[^m]*m/).join # SGR active at the cut
        rest = line[cut..]
      else
        prefix_sgr = ""
        rest = line
      end
      keep = wrap_cut_index(rest, width)
      trailing_sgr = rest[keep..].scan(/\e\[[^m]*m/).join
      prefix_sgr + rest[0...keep] + trailing_sgr
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
      return nil if i < 0 || i >= @size
      if bytes = @bytes
        bytes.unsafe_fetch(i).unsafe_chr
      else
        @chars.not_nil!.unsafe_fetch(i) # ameba:disable Lint/NotNil
      end
    end

    def [](i : Int) : Char?
      return nil if i < 0
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
