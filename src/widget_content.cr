module Crysterm
  class Widget
    include Helpers

    # module Content

    # Convenience regex for matching Crysterm tags and their content (i.e. '{bold}This text is bold{/bold}').
    TAG_REGEX = /\{(\/?)([\w\-,;!#]*)\}/

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

    # Widget's user-set content in original form. Includes any attributes and tags.
    # Materialized lazily: `append_content` defers the O(total) string concat by
    # stashing the raw appended chunks in `@_content_tail` and folding them into
    # `@content` only when the content is actually read (see `#content`). This is
    # what makes a stream of appends O(1) amortized instead of O(n) each.
    @content : String = ""

    # Raw appended chunks not yet folded into `@content` (see `#content` /
    # `#fold_content_tail`). Empty in the common (non-appended) case.
    @_content_tail = [] of String

    # Widget's user-set content in original form, with any pending appends folded
    # in. O(total) on the first read after appends, then cached until the next
    # append. Most readers (`get_content`, list items, `content=`) go through here.
    def content : String
      fold_content_tail
      @content
    end

    # Folds the deferred raw appends (`@_content_tail`) into `@content`. No-op when
    # nothing is pending, so it is cheap to call defensively before any code that
    # reads the `@content` ivar directly.
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

    # Whether there is no content at all — neither materialized nor pending. O(1)
    # (does not fold), for the hot `append_content`/`push_line` guards.
    private def content_blank?
      @content.empty? && @_content_tail.empty?
    end

    # Printable, word-wrapped content, ready for rendering into the element.
    # `nil` means "stale" — `append_content` sets it nil rather than rebuilding the
    # O(total) joined string per line; `#pcontent` rebuilds it on demand (once per
    # render after a change, not once per append). The incremental `@_clines.ci`
    # offsets stay valid because they are derived from line lengths, not from this
    # string.
    property _pcontent : String?

    # The printable content string, rebuilt from the wrapped lines if stale. The
    # render path and any other consumer must go through this (not the `@_pcontent`
    # ivar) so a deferred append is materialized before use.
    def pcontent : String
      @_pcontent ||= clines_joined
    end

    # The wrapped lines as one `"\n"`-joined string. For the overwhelmingly common
    # single-line content (every `Label`, `Fps`, and per-cell box) `join` would
    # allocate a fresh `String` that merely duplicates the sole line; returning
    # that line directly avoids a per-widget, per-frame allocation (and the GC
    # pressure it creates across thousands of widgets). `String`s are immutable, so
    # aliasing the line is safe; `@_pcontent` is replaced wholesale on the next
    # reparse. The empty case returns the shared empty string, also alloc-free.
    private def clines_joined : String
      cl = @_clines
      case cl.size
      when 0 then ""
      when 1 then cl[0]
      else        cl.join("\n")
      end
    end

    # Cached codepoint index over `@_pcontent`, reused across frames. `_render`
    # indexes content per cell, so for non-ASCII content the index materializes a
    # `chars` array; rebuilding it every frame is pure per-frame garbage. It is
    # rebuilt only when `@_pcontent` becomes a different `String` (i.e. on a
    # content reparse — see `StringIndex#built_from?`).
    @_content_index : StringIndex? = nil

    property _clines = CLines.new

    # Bumped every time `@content` changes (see `set_content`). `process_content`
    # compares this integer against the version baked into `@_clines` to decide
    # whether a reparse is needed, instead of doing an O(n) `String` comparison
    # of the full content on every render.
    @_content_version = 0

    # The `no_tags` mode the cached content was processed with, so a repeated
    # `set_content` of the same string but a *different* tag mode still reparses
    # (see the unchanged-content short-circuit in `#set_content`).
    @_content_no_tags = false

    # Whether the current `@content` contains any Crysterm tags (`{...}` /
    # `{/...}`), decided once in `#set_content` by matching against the tag
    # syntax. When false, `process_content` skips the `_parse_tags` call (and the
    # whole-string regex scan inside it) entirely — most content is plain text,
    # so this avoids re-scanning it for tags on every reparse. Defaults to false:
    # empty default content has no tags.
    @_content_has_tags = false

    # Whether the current `@content` contains any inline SGR escape (a raw `\e`),
    # decided once in `#set_content`/`#append_content`. Together with
    # `@_content_has_tags` (tags expand to SGR via `_parse_tags`) this tells
    # `_parse_attr` whether ANY line can carry an inline attribute change. When
    # neither is set, every wrapped line has the same base attr, so `_parse_attr`
    # fills the attr array directly and skips the per-line `_attr_after` codepoint
    # scan (a `Char::Reader` decode loop) entirely — the common case for plain
    # text (labels, list items, per-cell boxes). Conservative: a stray `\e` that
    # `process_content` later strips, or unexpanded tags under `no_tags`, only make
    # it take the (correct) slow path. Defaults false: empty content has no SGR.
    @_content_has_sgr = false

    # The `sattr(style)` value that the currently-cached `@_clines.attr` was
    # computed against. `_parse_attr` only depends on the content (unchanged on
    # the cached path) and this base attribute, so it can be skipped whenever the
    # style's packed attr is unchanged frame-to-frame (the common case). `nil`
    # forces the first computation.
    @_parse_attr_default : Int64? = nil

    # Processes and sets widget content. Does not allow extra options re.
    # how content is to be processed; use `#set_content` if you need to provide
    # extra options.
    def content=(content)
      set_content content
    end

    def set_content(content = "", no_clear = false, no_tags = false)
      # Fold any deferred appends so the unchanged-content comparisons below see
      # the real current content (and so the tail is dropped — this call replaces
      # the content wholesale).
      fold_content_tail
      # Idempotent: setting the content to its current value changes nothing, so
      # the widget does no work and propagates no repaint — no version bump, no
      # (expensive) reparse, no `request_render`, no `SetContent`. This is the
      # widget itself deciding it didn't change, rather than a central flag
      # detecting it after the fact. The first parse still happens regardless:
      # `process_content` reparses on the CLines/version mismatch (CLines starts
      # at version -1), independent of whether this setter ran. (A bare
      # `no_tags` toggle with identical content is not re-applied; that combo
      # does not occur in practice.)
      # Idempotent no-op for re-setting identical content (the common case in
      # per-cell animations that re-assign a box's character every frame even
      # when it did not change): nothing to reparse, no `SetContent` to emit.
      # Style (fg/bg) changes flow through the separate `@_parse_attr_default`
      # path in `process_content`, not here, so they are unaffected. (A bare
      # `no_tags` toggle with otherwise-identical content does not occur in
      # practice, so it is not separately handled.)
      return if content == @content

      # Previously this erased the widget's last-rendered footprint (unless
      # `no_clear`) so that shrinking content wouldn't leave stale cells behind.
      # That is now handled centrally: `Screen#_render` clears the whole cell
      # buffer before each frame. `no_clear` is kept for call compatibility.

      # XXX make it possible to have `update_context`, which only updates
      # internal structures, not @content (for rendering purposes, where
      # original content should not be modified).
      @content = content
      @_content_no_tags = no_tags
      # Decide here, once per content change, whether the content even contains
      # any tags, using the same syntax `_parse_tags` recognizes. If it does not,
      # `process_content` won't bother calling `_parse_tags` at all — see the
      # guarded call below. A tag needs a `{`, so the cheap byte scan short-
      # circuits the PCRE2 match for the common (tag-free) text.
      @_content_has_tags = content.includes?('{') && content.matches?(TAG_REGEX)
      # Cheap byte search (`\e` is ASCII): records whether any inline SGR is
      # present so `_parse_attr` can skip its per-line scan for plain text.
      @_content_has_sgr = content.includes? '\e'
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
    # deprecated, and—more importantly—it promotes every `Array(String)` in the
    # whole program (including in unrelated shards) to the virtual type
    # `Array(String)+`, which produces confusing compile errors far away from
    # here (see issue #30). It now *wraps* an array and forwards the array API
    # to it via `forward_missing_to`, so no `Array(String)` is ever subclassed.
    class CLines
      property string = ""
      property max_width = 0
      property width = 0

      # Right-edge columns (`Widget#content_margin_x`) these lines were wrapped to
      # avoid — the vertical scroll bar's reservation in force at wrap time. Part
      # of the convergence check in `Widget#process_content`: an `AsNeeded` bar's
      # presence is only known *after* wrapping, so if reserving its column now
      # differs from what was applied here, the content is re-wrapped once.
      property margin = 0

      # Horizontal scroll offset (in display columns) these lines were sliced for
      # — part of the wrap cache key, so a horizontal scroll forces a reparse the
      # same way a width change does. Only meaningful when `wrap_content` is off.
      property base_x = 0

      # Widest *unclipped* line, in display columns (the longest content row
      # before the horizontal viewport slice). Drives `Widget#get_scroll_width`
      # and thus the horizontal scroll bar's range. `0` for wrapped content.
      property full_width = 0

      property content : String = ""

      # Version of the owning widget's `@content` that produced these wrapped
      # lines. Defaults to -1 so a freshly-built `CLines` never matches a real
      # (>= 0) widget content version, forcing the first parse. See
      # `Widget#process_content`.
      property content_version : Int32 = -1

      property real : CLines? = nil

      property fake = [] of String

      property ftor = [] of Array(Int32)
      property rtof = [] of Int32
      property ci = [] of Int32

      # Pool of recycled `ftor` sub-arrays. `#reset` drains the old per-line
      # `ftor` rows into here (cleared) and `#take_ftor_row` hands them back out,
      # so a steady-state reparse of same-shaped content reuses the very same
      # `Array(Int32)` objects instead of allocating one per line every frame.
      @ftor_pool = [] of Array(Int32)

      # Defaults to `nil` (not an empty array): `process_content` always replaces
      # this with `_parse_attr`'s result on a reparse before the lines are used,
      # so pre-allocating an array here is pure per-reparse waste. All readers go
      # through `attr.try(...)`, so `nil` is handled.
      property attr : Array(Int64)? = nil

      # Backing store of wrapped lines. The array API (`push`, `[]`, `size`,
      # `each`, `join`, `reduce`, ...) is forwarded to it below.
      getter lines : Array(String)

      def initialize(@lines = [] of String)
      end

      # Clears the arrays a reparse refills in place (`#lines`, `rtof`, `ftor`,
      # `ci`) so this same `CLines` can be reused by the next `_wrap_content`
      # instead of allocating a fresh object + arrays every reparse. `clear`
      # keeps each array's backing buffer, so steady-state reparsing of
      # same-shaped content reallocates nothing here. `fake`/`attr`/`real` and
      # the scalar fields are overwritten wholesale by the reparse, so they are
      # not touched. (`ftor`'s per-line sub-arrays are dropped and rebuilt; only
      # the outer array's buffer is retained.)
      def reset : Nil
        @lines.clear
        @rtof.clear
        # Recycle the per-line `ftor` sub-arrays into the pool (cleared) instead
        # of dropping them, so the next wrap reuses them via `#take_ftor_row`.
        @ftor.each do |row|
          row.clear
          @ftor_pool << row
        end
        @ftor.clear
        @ci.clear
      end

      # A cleared per-line `ftor` sub-array: a recycled one from the pool (see
      # `#reset`) when available, otherwise a fresh allocation.
      def take_ftor_row : Array(Int32)
        @ftor_pool.pop? || [] of Int32
      end

      # Match the old `Array#dup` behavior: a fresh, independent `Array(String)`
      # copy (without the extra bookkeeping). Defined explicitly because
      # `dup` already exists on `Object` and so is not forwarded.
      def dup
        @lines.dup
      end

      forward_missing_to @lines
    end

    # `awidth_hint`, when given, is this widget's already-resolved absolute width
    # for the current frame — the render path knows it cheaply (the parent has
    # rendered, so `awidth(true)` is an O(1) `lpos` read) and passes it in so the
    # default `awidth` (`get: false`) ancestor-chain walk — which runs here every
    # frame, before the parse cache is even consulted — is skipped. Off-render
    # callers (resize/attach/scroll) omit it and resolve the width as before.
    def process_content(no_tags = false, awidth_hint : Int32? = nil)
      # Content layout (wrapping/alignment) needs the owning screen's
      # dimensions, so there is nothing to do until the widget is attached.
      return false unless screen?

      ::Log.trace { "Parsing widget content: #{@content.inspect}" }

      colwidth = (awidth_hint || awidth) - iwidth
      if @_clines.nil? || @_clines.empty? || @_clines.width != colwidth || @_clines.content_version != @_content_version || @_clines.base_x != @child_base_x
        # A reparse reads the raw `@content`, so fold in any deferred appends
        # first. (The common cache-hit path below never enters here, so deferred
        # content is not materialized just to render an unchanged frame.)
        fold_content_tail
        # Single pass over the content instead of four chained `gsub`s (each of
        # which scanned the whole string and built an intermediate copy). The
        # four rules act on disjoint characters — control chars, a stray ESC
        # (not starting an SGR sequence), CR/CRLF, and TAB — so collapsing them
        # into one alternation with a dispatching block is equivalent. `tab` is
        # hoisted so the replacement string is built once, not per match — and
        # only when the content actually contains a tab, since `style.tab_char *
        # style.tab_size` allocates a `String` and the `"\t"` branch is otherwise
        # never reached (the `""` fallback is a constant, no allocation). On the
        # common tab-free reparse the whole `gsub` also returns `@content`
        # unchanged (Crystal's `gsub` returns the receiver when nothing matches),
        # so this branch is then allocation-free.
        tab = @content.includes?('\t') ? style.tab_char * style.tab_size : ""
        content = @content.gsub(/[\x00-\x08\x0b-\x0c\x0e-\x1a\x1c-\x1f\x7f]|\e(?!\[[\d;]*m)|\r\n|\r|\t/) do |m|
          case m
          when "\r\n", "\r" then "\n"
          when "\t"         then tab
          else                   "" # control char or stray ESC
          end
        end

        ::Log.trace { "Internal content is #{content.inspect}" }

        # No content-level Unicode munging here: wide-char layout, grapheme
        # clusters, and combining marks are all handled at the cell level in the
        # renderer (keyed off `screen.full_unicode?`). See FIX-UNICODE.md for why
        # the blessed content-string approach (the `\x03` wide-char sentinel,
        # surrogate-pair repair) does not apply, and for the two optional, still-
        # open behaviors (non-Unicode-terminal degradation; the iTerm2 combining
        # quirk) if a real need ever appears.

        # Only parse tags when this call hasn't disabled them *and* the content
        # actually contains tags (decided in `#set_content`). For plain-text
        # content this skips `_parse_tags` and its whole-string regex scan.
        if !no_tags && @_content_has_tags
          content = _parse_tags content
        end
        ::Log.trace { "After _parse_tags: #{content.inspect}" }

        # Reuse the existing `@_clines` object (refill in place) instead of
        # allocating a new one each reparse — `@_clines` is non-nilable (defaults
        # to an empty `CLines`), so it is always a valid reuse target.
        #
        # Wrap, then *converge* the scroll-bar reservation. An `AsNeeded` bar's
        # presence depends on whether the content overflows the viewport, which
        # is only known from the wrapped line count — i.e. *after* wrapping — yet
        # the wrap width itself depends on the bar reserving its column. On the
        # first wrap `@_clines` is empty, so `content_margin_x` sees
        # `get_scroll_height == 0`, reserves nothing, and the content wraps one
        # column too wide; the bar then overpaints the last content column (the
        # `widget-csr` bug). So if the freshly-produced lines flip the reservation
        # `content_margin_x` returns, re-wrap once with it. Monotonic: reserving a
        # column only narrows the width, which only adds lines, so the bar cannot
        # then disappear — two passes always suffice (the loop is bounded anyway).
        2.times do
          @_clines = _wrap_content(content, colwidth, into: @_clines)
          # The break test keys off line count (`content_margin_x` →
          # `get_scroll_height` → `@_clines.size`), which `_wrap_content` already
          # set; the cache-key fields below don't affect it, so set them once after.
          break if @_clines.margin == content_margin_x
        end
        @_clines.width = colwidth
        @_clines.base_x = @child_base_x
        @_clines.content = @content
        @_clines.content_version = @_content_version
        # `_parse_attr` already computes `sattr(style)` and records it in
        # `@_parse_attr_default`, so no separate recompute is needed here.
        @_clines.attr = _parse_attr @_clines
        # Reuse the `CLines`' own (empty) `ci` array — `_wrap_content` never
        # touches it — by clearing and refilling, instead of allocating a fresh
        # replacement every reparse.
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
        # The per-line attrs array (`@_clines.attr`), in contrast, is read back by
        # the render loop ONLY on a non-first wrapped/scrolled line — `_render`
        # consults `@_clines.attr[base]` exclusively under `if ci > 0`, which
        # requires multi-line content or a non-zero vertical scroll base. For the
        # common single-line, unscrolled widget the array is never read, so the
        # `O(content)` `_parse_attr` scan is pure waste there; gate it on the
        # array actually being reachable. (A content change that alters the line
        # count goes through the full reparse above, which always rebuilds it.)
        @_clines.attr = _parse_attr(@_clines) if @_clines.size > 1 || @child_base > 0
      end

      false
    end

    # Convert `{red-fg}foo{/red-fg}` to `\e[31mfoo\e[39m`.
    def _parse_tags(text)
      return text unless @parse_tags
      # Enter the parser whenever a brace is present (not only on a *valid* tag):
      # under the drop-malformed policy a stray `{`/`}` must be stripped too, and
      # brace-free text is returned untouched by this fast byte scan.
      return text unless text.includes?('{') || text.includes?('}')

      # Accumulate into a `String::Builder` rather than `outbuf += ...`: repeated
      # `String` concatenation rebuilds the whole (growing) result on every tag,
      # which is O(n^2) for heavily-tagged content. The cursor is an integer
      # offset (`pos`) advanced through `text` with ANCHORED matches at that
      # offset, instead of re-slicing `text = text[cap[0].size..]` each step —
      # the old reslicing allocated a fresh tail `String` per tag/segment, a
      # second O(n^2). (Anchored matching at an offset is the same technique
      # `_parse_attr` already uses to scan SGR sequences without slicing.) This
      # path is cold — content-change only — but the quadratic blowup made
      # heavily-tagged content disproportionately expensive to (re)parse.
      outbuf = String::Builder.new
      bg = [] of String
      fg = [] of String
      flag = [] of String

      esc = false
      pos = 0
      size = text.size
      anchored = Regex::MatchOptions::ANCHORED

      # Both the `{escape}` block and the `{|}` separator are rare. Decide once,
      # up front, whether the text contains either, so the hot per-iteration path
      # skips the `{escape}` regex match *and* the `text[pos, 3]` substring
      # allocation it otherwise paid on every token. (Absent the substring/token
      # the gated checks could never have matched, so this is equivalent.)
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

        # `{|}` is Blessed's right-align *separator*, not an attribute tag: text
        # after it is pushed to the right edge of the line. It must survive
        # parsing verbatim so `#_align` (which splits the line on the braces and
        # right-justifies the trailing part) can act on it; without this it would
        # fall through to the drop-malformed branch below and render as a bare `|`.
        if has_bar && text[pos, 3]? == "{|}"
          outbuf << "{|}"
          pos += 3
          next
        end

        # A recognized `{tag}` / `{/tag}`. `{open}`/`{close}` emit literal
        # braces; a known attribute name emits its SGR (tracking nesting so a
        # close restores the previous state); an UNRECOGNIZED tag is malformed
        # and dropped (drop-malformed policy, todoc Q6). `Tput#_attr` returns ""
        # for an unknown name and a non-empty SGR for every known one (in the
        # opening sense), so `empty?` is the recognition test.
        if cap = TAG_REGEX.match(text, pos, options: anchored)
          pos += cap[0].size
          slash = cap[1] == "/"
          # XXX Tags must be specified such as {light-blue-fg}, but are then
          # parsed here with - being ' '. See why? Can we work with - and skip
          # this replacement part?
          # Char-`gsub` (not the `/-/` regex) and only when a dash is actually
          # present — dash-free tags (`bold`, `red`) then reuse the captured
          # name with no scan and no allocation.
          param = cap[2]
          param = param.gsub('-', ' ') if param.includes?('-')

          if param == "open"
            outbuf << '{'
            next
          elsif param == "close"
            outbuf << '}'
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
              outbuf << screen.tput._attr("normal")
              bg.clear
              fg.clear
              flag.clear
            elsif !screen.tput._attr(param).empty? # recognized -> restore prior
              # D O:
              # if (param !== state[state.size - 1])
              #   throw new Error('Misnested tags.')
              # }
              # `pop?` (not `pop`): a recognized closing tag with NO matching open
              # (e.g. `{/bold}` or `{/red-fg}` on its own, or more closes than
              # opens) leaves the fg/bg/flag stack empty here. Crystal's `Array#pop`
              # raises `IndexError` on an empty array — so the bare `pop` crashed
              # the whole parse on such unbalanced-but-recognized input. Blessed's
              # JS `array.pop()` returns `undefined` (no throw) and falls through to
              # emit the tag's "off" SGR; `pop?` reproduces that: it returns nil on
              # empty, `state.size` stays 0, and we emit `_attr(param, false)`.
              state.pop?
              outbuf << (state.size > 0 ? screen.tput._attr(state[-1]) : screen.tput._attr(param, false))
            end
            # else: unrecognized closing tag -> dropped
          else
            attr = screen.tput._attr(param)
            unless attr.empty? # recognized opening tag
              state.push(param)
              outbuf << attr
            end
            # else: unrecognized opening tag -> dropped
          end

          next
        end

        # A run of plain (brace-free) text passes through verbatim. Find the next
        # brace by index instead of an anchored `/[^{}]+/` match, so a plain run
        # costs no per-run `MatchData`/capture allocation — only the substring
        # that has to be emitted anyway.
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
    # `attr`. The shared per-line attr step: `_parse_attr` uses it to advance the
    # running attr line-to-line, and `append_content` uses it to carry the SGR
    # state across the append boundary (a `{red-fg}` left open on an earlier line
    # colors the appended lines too, exactly as a full reparse would).
    # `default_attr` is `sattr(style)`, passed in so callers compute it once rather
    # than per line.
    private def _attr_after(line : String, attr : Int64, default_attr : Int64) : Int64
      line.each_char_with_index do |char, i|
        if char == '\e'
          if c = SGR_REGEX.match(line, i, options: Regex::MatchOptions::ANCHORED)
            attr = screen.attr2code(c[0], attr, default_attr)
          end
        end
      end
      attr
    end

    def _parse_attr(lines : CLines)
      default_attr = sattr(style)
      # Record the base attribute this parse was built against, so callers don't
      # recompute `sattr(style)` separately (it is the same value, several style
      # field reads + a pack). Both `process_content` call sites previously did so.
      @_parse_attr_default = default_attr
      attr = default_attr
      # Reuse the `CLines`' own `attr` array (clear + refill) so a reparse does
      # not allocate a fresh `Array(Int64)` each time; allocated once on first
      # use. The caller assigns the result back to `lines.attr`, which is this
      # same array, so that assignment is a no-op.
      attrs = (lines.attr ||= [] of Int64)
      attrs.clear

      # Fast path: when the content has no inline SGR at all — no raw `\e` and no
      # tags that expand into one (see `@_content_has_sgr`/`@_content_has_tags`) —
      # every line carries the same base attr, so fill the array directly and skip
      # the per-line `_attr_after` codepoint scan (and its `Char::Reader`). This is
      # the overwhelmingly common case (plain-text labels/list-items/per-cell
      # boxes) and avoids a decode loop per line per widget per frame.
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

    # Wraps content based on available widget width.
    #
    # `into`, when given, is an existing `CLines` to refill in place rather than
    # allocating a fresh one — `process_content` passes the widget's own
    # `@_clines`, so steady-state reparsing reuses the same object and its array
    # buffers (see `CLines#reset`). When nil a new `CLines` is built.
    def _wrap_content(content, colwidth, into : CLines? = nil)
      default_state = @align
      # Capture the right-edge reservation BEFORE `outbuf.reset` below. When
      # `into` is the widget's own `@_clines`, `reset` clears it — and
      # `content_margin_x` → `show_scrollbar?` → `really_scrollable?` →
      # `get_scroll_height` *reads* `@_clines`. Read post-reset, the just-emptied
      # lines make `get_scroll_height == 0`, so an `AsNeeded` bar looks un-needed
      # mid-wrap. Reading it here, pre-reset, sees the lines still in place — which
      # is exactly what `process_content`'s convergence pass relies on: its second
      # `_wrap_content` call must see the *first* pass's line count to keep the
      # reservation, not re-zero it and oscillate.
      margin = content_margin_x
      outbuf = into || CLines.new
      # Record the reservation this wrap is built against, so `process_content`
      # can tell when an `AsNeeded` bar's presence (only known post-wrap) flips
      # it and a re-wrap is needed.
      outbuf.margin = margin
      # Clear the in-place arrays so a reused `CLines` starts empty (a no-op on a
      # freshly built one). After this, fill the `CLines`' own `rtof`/`ftor`
      # arrays directly via these aliases — no throwaway locals reassigned at the
      # end. (The empty-content branch below returns before these are used and
      # sets its own literals.)
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

      # Reuse the `fake` array for the common single-line content (a label, list
      # item, panel title, …): refill it in place instead of letting
      # `String#split` allocate a fresh `Array(String)` every reparse. Multi-line
      # content still splits — its sub-strings have to be allocated anyway — and
      # the final `outbuf.fake = lines` below records whichever array we used.
      if content.includes?('\n')
        lines = content.split('\n')
      else
        lines = outbuf.fake
        lines.clear
        lines << content
      end

      # Subtract the right-edge reservation captured above so content wraps clear
      # of the scroll bar (and any per-widget reservation, e.g. `PlainTextEdit`'s
      # caret column). `#content_margin_x` is the single source of truth, shared
      # with the horizontal-scroll math (`#content_width`).
      colwidth -= margin if colwidth > margin

      lines.each_with_index do |line, no|
        align = default_state
        align_left_too = false

        ftor.push outbuf.take_ftor_row

        # Handle alignment tags.
        if @parse_tags
          if cap = line.match /^{(left|center|right)}/
            align_left_too = true
            line = line[cap[0].size..]
            align = default_state = case cap[1]
                                    when "center"
                                      Tput::AlignFlag::Center
                                    when "left"
                                      Tput::AlignFlag::Left
                                    else
                                      Tput::AlignFlag::Right
                                    end
          end
          if cap = line.match /{\/(left|center|right)}$/
            line = line[0...(line.size - cap[0].size)]
            # Reset default_state to whatever alignment the widget has by default.
            default_state = @align
          end
        end

        # Without wrapping the line is one full (unwrapped) row: record its true
        # width for the horizontal scroll range, then slice it to the visible
        # column window `[child_base_x, child_base_x + colwidth)`. At
        # `child_base_x == 0` this is exactly the old "keep what fits, cut the
        # rest off" truncation (see `#_hslice`).
        unless @wrap_content
          outbuf.full_width = Math.max(outbuf.full_width, str_width(line))
          outbuf.push _align(_hslice(line, @child_base_x, colwidth), colwidth, align, align_left_too)
          ftor[no].push(outbuf.size - 1)
          rtof.push(no)
          next
        end

        # If the string could be too long, check it in more detail and wrap it if needed.
        # NOTE Done with loop+break due to https://github.com/crystal-lang/crystal/issues/1277
        loop_ret = loop do
          break unless str_width(line) > colwidth

          # Character index at which to cut so the kept prefix fits `colwidth`
          # columns. SGR sequences consume no width; under `full_unicode?` widths
          # are grapheme / East-Asian and clusters are never split.
          i = wrap_cut_index(line, colwidth)

          # Try to break on a space within the last few columns (word wrap):
          # back up from the column-fit cut `i` to the most recent space within
          # the previous ~10 chars and cut just after it, so a word isn't split
          # mid-way. If no space is found in that window, keep `i` (character
          # wrap fallback). Mirrors blessed's `while (j > i-10 && j > 0)` scan.
          if i != line.size
            j = i
            while (j > i - 10) && (j > 0)
              j -= 1
              if line[j] == ' '
                i = j + 1
                break
              end
            end
          end

          part = line[0...i]
          line = line[i..]

          outbuf.push _align(part, colwidth, align, align_left_too)
          ftor[no].push(outbuf.size - 1)
          rtof.push(no)

          # Make sure we didn't wrap the line at the very end, otherwise
          # we'd get an extra empty line after a newline.
          if line == ""
            break :main
          end

          # If only an escape code got cut off, add it to `part`.
          if line.matches? /^(?:\e[\[\d;]*m)+$/ # SGR
            outbuf[outbuf.size - 1] += line
            break :main
          end
        end

        # `each_with_index` rebinds `no` each iteration, so mutating it here is
        # dead — `next`/falling through both advance to the next fake line.
        next if loop_ret == :main

        outbuf.push(_align(line, colwidth, align, align_left_too))
        ftor[no].push(outbuf.size - 1)
        rtof.push(no)
      end

      # `rtof`/`ftor` already alias `outbuf`'s own arrays (filled in place above),
      # so no reassignment is needed here.
      outbuf.fake = lines
      outbuf.real = outbuf

      # Note that this is intended to save the length of the longest line to
      # outbuf.max_width. In the case that the text was aligned, the alignment
      # has padded it with spaces, effectively lengthening it. So, in that case
      # the max_width value won't be actual max. length of longest line, but it
      # will be the full width of the surrounding box, to which it was aligned.
      outbuf.max_width = outbuf.reduce(0) do |current, line|
        Math.max str_width(line), current
      end

      outbuf
    end

    # Aligns content
    def _align(line, width, align = Tput::AlignFlag::None, align_left_too = false)
      # Right-align separator `{|}` (Blessed): text after `{|}` is pushed to the
      # right edge of the line. It distributes content *within* the line, so it is
      # independent of the line's own alignment — handle it before the
      # align-direction early-returns below so it also works for the default Left
      # alignment (the common case; `_parse_tags` passes `{|}` through verbatim
      # for exactly this). The general `{|}` branch further down is only reachable
      # for HCenter/Right, so this is what makes it fire for left-aligned content.
      if @parse_tags && line.includes?("{|}")
        cl = line.includes?('\e') ? line.gsub(SGR_REGEX, "") : line
        if res = split_right_align(line, cl, width)
          return res
        end
      end

      return line if align.none?

      # Plain left alignment pads nothing — only HCenter/Right (or a forced
      # `{left}` via `align_left_too`) add spaces — so it returns `line` unchanged
      # anyway. Bail before measuring width: a widget's default `@align` carries
      # `Left` (plus a vertical flag), so this is the overwhelmingly common case
      # and skips a `str_width` (and the ESC scan) on every aligned line.
      if !align_left_too && (align & (Tput::AlignFlag::HCenter | Tput::AlignFlag::Right)).none?
        return line
      end

      # Only run the SGR-stripping `gsub` (which allocates a fresh `String`) when
      # the line actually contains an escape; the vast majority of aligned lines
      # carry no color, so a cheap `includes?` byte scan lets them reuse `line`
      # with no allocation. When there is no ESC, `cline == line` and everything
      # below (width, splits) behaves identically.
      cline = line.includes?('\e') ? line.gsub(SGR_REGEX, "") : line
      # `cline` is already SGR-stripped (or had none), so measure it directly.
      # `str_width line` would strip the SGR sequences a second time; `str_width
      # cline` skips the regex (no ESC present) and yields the identical width.
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
        # Split the free space across both sides; the odd extra cell goes to the
        # right (Blessed's convention) so a centered line still fills the full
        # `width` (`s//2 + (s - s//2) == s`) instead of being one cell short for
        # odd free space — which would otherwise also under-report `max_width`.
        left = fc * (s // 2)
        right = fc * (s - s // 2)
        return left + line + right
      elsif align.right?
        s = fc * s
        return s + line
      elsif align_left_too && align.left?
        # Technically, left align is visually the same as no align at all.
        # But when text is aligned to center or right, all the available empty space is padded
        # with spaces (around the text in center align, and in front of text in right align).
        # So, because of this padding with spaces, which affects the size of the widget, we
        # want to pad {left} align for uniformity as well.
        #
        # But, because aligning left affects almost everything in undesired ways (a lot
        # more chars are present, and cursor in text widgets is wrong), we do not want to do
        # this when Widget's `align = AlignFlag::Left`. We only want to do it when there is
        # "{left}" in content, and parse_tags is true.
        #
        # This should ensure that {left|center|right} behave 100% identical re. the effect
        # it has on row width. To see the old behavior without this, comment this elseif,
        # run test/widget-list.cr, and observe the look of the first element in the list
        # vs. the other elements when they are selected.
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
        # Otherwise (just a lone `{` or `}`): falls through to `return line` below.
      end

      line
    end

    # Right-aligns the text after a `{...}` split: the segment before the first
    # delimiter stays put and the segment after the second delimiter is pushed
    # flush against the right edge of `width`, with the gap filled by
    # `Style#fill_char`. This backs both the `{|}` right-align separator (handled
    # up front, independent of the line's own alignment) and the generic
    # `{left}…{right}` spread reachable through the HCenter/Right align path.
    #
    # `line` is the raw (possibly SGR-carrying) line; `cline` is its SGR-stripped
    # form, used for width measurement. Returns the padded line, or `nil` when
    # there is no usable two-sided split (e.g. just a lone `{` or `}`), in which
    # case the caller leaves `line` unchanged.
    private def split_right_align(line, cline, width) : String?
      parts = line.split(/\{|\}/)
      cparts = cline.split(/\{|\}/)
      if cparts[0]? && cparts[2]?
        pad = style.fill_char.to_s * Math.max(width - str_width(cparts[0]) - str_width(cparts[2]), 0)
        "#{parts[0]}#{pad}#{parts[2]}"
      end
    end

    # Rebuilds the widget's content from the in-place-mutated `@_clines.fake`
    # lines (re-joining them and reparsing). The `no_clear` flag is set so the
    # existing `@_clines` machinery is refreshed rather than wiped. Used by the
    # line-level editors (`insert_line`/`delete_line`/`set_line`) after they
    # splice `fake`.
    private def rebuild_content_from_fake
      set_content(@_clines.fake.join("\n"), true)
    end

    # Scratch `CLines` reused across `append_content` calls so wrapping just the
    # appended line never allocates a fresh bookkeeping object.
    @_append_scratch : CLines? = nil

    # Append `text` (one or more `\n`-separated logical lines) to the end of the
    # content WITHOUT reparsing everything already there. The existing wrapped
    # lines, their tag parse, and their per-line attributes are all left
    # untouched; only the newly appended text is cleaned, tag-parsed, wrapped and
    # attr-scanned, then spliced onto the tail of `@_clines`. This turns the
    # O(total) work that `set_content` does per append into O(appended).
    #
    # Returns `true` if the fast path handled it, `false` if it bailed (caller
    # should fall back to `set_content`/`push_line`). It bails when the content
    # is empty (let the normal path seed line 0), the parse cache is stale, or the
    # width changed (the existing wrapped lines would need re-wrapping).
    #
    # Why it is byte-identical to a full reparse:
    # * Per-fake-line wrapping is independent in `_wrap_content` (each `\n`-split
    #   segment wraps on its own), so appending never re-wraps earlier lines.
    # * Tags: `@_clines.fake` stores already-*parsed* (SGR) content for earlier
    #   lines, so a full reparse's `_parse_tags` sees no tag tokens before the new
    #   segment — the fg/bg/flag stacks always start empty at the boundary. Parsing
    #   the new segment standalone is therefore exactly what a full reparse does.
    # * Attributes DO carry: an SGR left open on an earlier line (e.g. an unclosed
    #   `{red-fg}`) colors the appended lines too. `_attr_after` recreates that
    #   carry so the spliced per-line attrs match a full reparse.
    def append_content(text : String) : Bool
      return false unless screen?
      # Cache must be current: if a reparse is pending, splicing onto stale
      # `@_clines` would corrupt it. Let the normal path run first.
      return false unless @_clines.content_version == @_content_version
      return false if content_blank?
      colwidth = @_clines.width
      return false if colwidth <= 0
      # Bail if the widget's width changed since the cache was built — the slow
      # path reparses everything at the new width (the `width != colwidth` check
      # in `process_content`); the fast path can only splice when the existing
      # wrapped lines are still valid for the current width.
      return false if (awidth - iwidth) != colwidth
      # Degenerate state: content that cleaned away to nothing leaves `_wrap_content`
      # in its empty-content shape (`fake` empty, one blank real line). Splicing
      # onto that would desync `fake` from `lines`; let the full path handle it.
      return false if @_clines.fake.empty?

      # Clean control chars on JUST the appended text (same single-pass rule as
      # `process_content`), then tag-parse only the new segment.
      tab = text.includes?('\t') ? style.tab_char * style.tab_size : ""
      seg = text.gsub(/[\x00-\x08\x0b-\x0c\x0e-\x1a\x1c-\x1f\x7f]|\e(?!\[[\d;]*m)|\r\n|\r|\t/) do |m|
        case m
        when "\r\n", "\r" then "\n"
        when "\t"         then tab
        else                   ""
        end
      end
      # Appending nothing (empty text, or text that cleaned away) would drive
      # `_wrap_content` down its empty-content branch, which desyncs `fake` from
      # `lines`. Such an append is a no-op for content but `push_line` still wants
      # the blank line; let the full path produce it.
      return false if seg.empty?

      seg_has_tags = @parse_tags && seg.includes?('{') && seg.matches?(TAG_REGEX)
      if seg_has_tags
        # Standalone tag parse of the new segment. Correct because earlier `fake`
        # lines are already SGR (tagless), so a full reparse's tag stacks are
        # likewise empty at this boundary (see the method doc).
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

      # Extend `ci` (char offset of each real line within the joined pcontent),
      # derived from the existing offsets — NOT from `@_pcontent`, which is now
      # built lazily and may be stale/nil here. The first new line starts one past
      # the end of the last existing line: `ci[last] + len(last) + 1` (the +1 is
      # the joining "\n"). `base_real >= 1` because content is non-blank.
      running = cl.ci[base_real - 1] + cl.lines[base_real - 1].size + 1
      scratch.lines.each do |ln|
        cl.ci << running
        running += ln.size + 1
      end

      # Per-line starting attrs for the new lines, carrying the SGR state across
      # the boundary: the first new line starts from the attr the existing
      # content ended on (its last line's start attr advanced through that line's
      # SGRs), and each subsequent new line continues from the previous. This
      # matches `_parse_attr`'s line-to-line carry exactly.
      if attrs = cl.attr
        da = sattr(style)
        # `base_real >= 1` (content non-blank), so the boundary attr comes from the
        # last existing line unless `attrs` is somehow short (degrade to default).
        carry = base_real <= attrs.size ? _attr_after(cl.lines[base_real - 1], attrs[base_real - 1], da) : da
        scratch.lines.each do |ln|
          attrs << carry
          carry = _attr_after(ln, carry, da)
        end
      end

      cl.max_width = Math.max(cl.max_width, scratch.max_width)
      # Carry the widest *unclipped* line forward too (non-wrapped content only;
      # `full_width` is 0 when wrapping, so this is a no-op there). It drives
      # `get_scroll_width` / the horizontal scroll range — without merging it,
      # appending a wider line to a non-wrapping widget would leave the extent
      # stale, deviating from the byte-identical-to-a-full-reparse contract.
      cl.full_width = Math.max(cl.full_width, scratch.full_width)

      # Defer the two O(total) string builds instead of doing them per append —
      # this is what makes a run of appends O(1) amortized rather than O(n) each:
      #   * `@_pcontent` is marked stale (nil); `#pcontent` rebuilds it from the
      #     wrapped lines on demand — once per render after a change, not per line.
      #     A fresh String also makes the render's `built_from?` check rebuild the
      #     codepoint index on its own.
      #   * the raw appended `text` is stashed in `@_content_tail`; `#content`
      #     folds it in only when the raw content is actually read.
      # `cl.content` (write-only bookkeeping) is left as-is rather than forcing a
      # materialization here.
      @_pcontent = nil
      @_content_tail << text
      @_content_has_tags ||= seg_has_tags
      # Keep the inline-SGR flag current across deferred appends (the cleaned
      # `seg` retains valid SGR; stray ESC was already stripped above).
      @_content_has_sgr ||= seg.includes? '\e'
      @_content_version += 1
      cl.content_version = @_content_version

      # Mirror the full path: mark the widget for repaint and emit the same event
      # contract — `ParsedContent` (scrollable widgets' `_recalculate_index`) and
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
        real = @_clines.ftor[@_clines.ftor.size - 1]
        real = real[-1] + 1
      else
        real = @_clines.ftor[i][0]
      end

      line.size.times do |j|
        @_clines.fake.insert(i + j, line[j])
      end

      rebuild_content_from_fake

      diff = @_clines.size - start

      if diff > 0
        pos = _get_coords
        if !pos || pos == 0
          return
        end

        height = pos.yl - pos.yi - iheight
        base = @child_base
        visible = real >= base && real - base < height

        if pos && visible && screen.clean_sides(self)
          screen.insert_line(diff,
            pos.yi + itop + real - base,
            pos.yi,
            pos.yl - ibottom - 1)
        end
      end
    end

    def delete_line(i = nil, n = 1)
      if i.nil?
        i = @_clines.ftor.size - 1
      end

      i = i.clamp(0, @_clines.ftor.size - 1)

      # NOTE: Could possibly compare the first and last ftor line numbers to see
      # if they're the same, or if they fit in the visible region entirely.
      start = @_clines.size
      # diff
      real = @_clines.ftor[i][0]

      n.times { @_clines.fake.delete_at i }

      rebuild_content_from_fake

      diff = start - @_clines.size

      # XXX clear_last_rendered_position() without diff statement?
      height = 0

      if diff > 0
        pos = _get_coords
        if !pos || pos == 0
          return
        end

        height = pos.yl - pos.yi - iheight

        base = @child_base
        visible = real >= base && real - base < height

        if pos && visible && screen.clean_sides(self)
          screen.delete_line(diff,
            pos.yi + itop + real - base,
            pos.yi,
            pos.yl - ibottom - 1)
        end
      end

      # When content shrank this used to erase the leftover footprint via
      # `clear_last_rendered_position`; the whole-buffer clear in `Screen#_render`
      # now takes care of that, so the explicit clear is no longer needed.
    end

    # Maps a real (wrapped) line index to its fake (logical) line index via
    # `@_clines.rtof`, guarding against out-of-range access. `rtof` has one
    # entry per wrapped line, so indices such as `@child_base` are normally in
    # range, but for empty/short content (e.g. before content is wrapped) a raw
    # `rtof[i]` would raise `IndexError`. Returns 0 when `rtof` is empty and
    # clamps otherwise.
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
      h = (@child_base) + aheight - iheight
      i = Math.min(h, @_clines.size)
      fake = rtof_index(i - 1) + 1

      insert_line(fake, line)
    end

    def delete_top(n = 1)
      fake = rtof_index(@child_base)
      delete_line(fake, n)
    end

    def delete_bottom(n)
      h = (@child_base) + aheight - 1 - iheight
      i = Math.min(h, @_clines.size - 1)
      fake = rtof_index(i)

      n = 1 if !n || n == 0

      delete_line(fake - (n - 1), n)
    end

    def set_line(i, line)
      i = Math.max(i, 0)
      # Pad up to AND including index `i` (`<=`, not `<`). Blessed relies on JS
      # auto-extending arrays so `fake[i] = line` can create the slot; in Crystal
      # `fake[i] = line` raises when `i == fake.size` (e.g. `set_line(0, …)` on an
      # empty `fake`, as `push_line` does for empty content), so the slot must
      # exist first.
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
      # Seed line 0 when there is no content yet (counting any deferred appends,
      # without materializing them).
      if content_blank?
        return set_line(0, line)
      end
      # Appending at the end is the common case (logs, transcripts, streaming
      # output). `append_content` splices just the new line onto `@_clines`
      # instead of re-joining and reparsing all existing content — O(appended)
      # rather than O(total). It bails (returns false) when it cannot guarantee
      # an identical result (stale cache or width change), in which case fall
      # through to the general insert.
      #
      # NOTE: there is deliberately no `Widget#<<` text alias — `<<` already means
      # "append a child widget" (`Mixin::Children#<<`), so appending text goes
      # through `push_line` / `append_content` to avoid overloading it.
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
    # delegates to the owning screen's effective gate (`Screen#full_unicode?` =
    # option AND terminal capability). False when unattached.
    def full_unicode?
      screen?.try(&.full_unicode?) || false
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

    # Returns `text` with its last **grapheme cluster** removed (e.g. a base +
    # combining mark, or a wide emoji, comes off as one unit). Used for
    # grapheme-aware backspace in text inputs. Empty in, empty out.
    def chop_grapheme(text : String) : String
      return text if text.empty?
      # Drop only the final grapheme cluster: track its byte length while scanning
      # (no per-cluster String, array, or join allocation) and slice it off the
      # end. Byte-identical to re-joining all-but-last clusters, since clusters
      # partition the string into contiguous byte spans.
      last_bytes = 0
      text.each_grapheme { |g| last_bytes = g.bytesize }
      text.byte_slice 0, text.bytesize - last_bytes
    end

    # Whether *base* begins a multi-codepoint grapheme cluster, given its
    # successor *nxt* — i.e. whether `#extend_grapheme` would assemble anything
    # beyond `base` alone. This is the cheap pre-check that lets the renderer skip
    # the (String-allocating) cluster assembly for the lone codepoint that the
    # overwhelming majority of cells are. It exactly mirrors `#extend_grapheme`'s
    # own start conditions, so `needs_cluster? == false` ⟺ the cluster is just
    # `base`.
    def needs_cluster?(base : Char, nxt : Char?) : Bool
      return true if base.mark? # a leading combining mark (zero-width; merges back)
      bp = base.ord
      return true if 0x1F1E6 <= bp <= 0x1F1FF # regional indicator (flag pair)
      return false unless nxt
      np = nxt.ord
      # A following combining mark, ZWJ, variation selector, or skin-tone modifier
      # extends the cluster.
      nxt.mark? || np == 0x200D || (0xFE00 <= np <= 0xFE0F) || (0x1F3FB <= np <= 0x1F3FF)
    end

    # Assembles the grapheme cluster that begins with `base` (the codepoint at
    # `content[ci - 1]`) by consuming any following *extending* codepoints from
    # `content` starting at `ci`: combining marks, ZWJ (and the codepoint it
    # joins), variation selectors, emoji skin-tone modifiers, and — for a flag —
    # a second regional indicator. Returns `{cluster, new_ci}`.
    #
    # This is a pragmatic subset of UAX-#29 that covers the cases that actually
    # occur in terminal text; `content` is anything indexable by codepoint
    # (`#[]?` returning `Char?`).
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

    # Character index in `line` (which may contain inline SGR) at which to cut so
    # the kept prefix fits within `colwidth` columns. SGR sequences (`\e[…m`)
    # consume no columns. Under `#full_unicode?` widths are grapheme /
    # East-Asian and grapheme clusters are never split; otherwise it is one
    # column per codepoint (legacy). Returns `line.size` when the whole line
    # fits, and always makes progress — a single grapheme wider than `colwidth`
    # is kept whole (overflowing) rather than looping forever.
    def wrap_cut_index(line : String, colwidth : Int) : Int32
      full = full_unicode?
      total = 0
      # Single forward walk. `String#[](Int)` is O(index) for multibyte content,
      # so the old char-by-char run/escape scan was O(n²) per line; a `Char::Reader`
      # decodes left-to-right in one pass. `cp` tracks the codepoint index of the
      # reader's current char (the value callers slice by); `reader.pos` is its
      # byte offset, used to slice runs cheaply for grapheme segmentation.
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
    # a prefix, and any escapes past the window are carried as a (zero-width)
    # suffix — so a clipped line still starts and ends in the right color. Column
    # math is grapheme/East-Asian-aware (via `#wrap_cut_index`) and never splits a
    # cluster. With `from_col == 0` this reduces to the original no-wrap
    # truncation (keep what fits, append trailing SGR). Used by `_wrap_content`
    # for horizontal scrolling of non-wrapped content.
    def _hslice(line : String, from_col : Int32, width : Int32) : String
      # Fast path for the common SGR-free line: a plain column-window substring,
      # no escape scanning (mirrors `#str_width`'s `includes?('\e')` guard).
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
    # ASCII fast path: a zero-copy byte view of `@object`. For an ASCII string a
    # byte *is* its codepoint, so indexing the bytes directly avoids
    # `String#[]?(Int)` — which recomputes `size` and decodes a char on every
    # call. Per cell that call dominated the render CPU profile; a byte view is
    # allocation-free (a slice over the string's buffer) and indexes in one
    # bounds-checked fetch. nil for non-ASCII content (which uses `@chars`).
    @bytes : Bytes?
    # Codepoint count, cached so `#size` and the per-cell bounds check below are
    # field reads, not `String#size` calls.
    @size : Int32

    def initialize(@object : String)
      if @object.ascii_only?
        @chars = nil
        @bytes = @object.to_slice
        @size = @object.bytesize # == codepoint count for ASCII
      else
        # Materialize the chars once (O(n)) so per-cell indexing is O(1) instead
        # of `String#[](Int)`'s O(n) codepoint walk (which made drawing a line of
        # Unicode content O(n²)).
        chars = @object.chars
        @chars = chars
        @bytes = nil
        @size = chars.size
      end
    end

    # Whether this index was built from `s` (the *same* `String` object). The
    # render loop builds one `StringIndex` per widget per frame from
    # `@_pcontent`, which only changes when content is reparsed; this lets the
    # caller reuse a cached index across frames instead of rebuilding the
    # `chars` array (and re-running the `ascii_only?` scan) every frame.
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
        @chars.not_nil!.unsafe_fetch(i)
      end
    end

    def [](i : Int) : Char?
      return nil if i < 0
      raise IndexError.new if i >= @size
      if bytes = @bytes
        bytes.unsafe_fetch(i).unsafe_chr
      else
        @chars.not_nil!.unsafe_fetch(i)
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
