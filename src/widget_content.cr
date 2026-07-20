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

    # Alignment of contained text
    Crystallabs::Helpers::Enums.enum_property align : Tput::AlignFlag = Tput::AlignFlag::Top | Tput::AlignFlag::Left

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

    # Single-pass content sanitization shared by `process_content` (whole
    # content) and `append_content` (appended segment only): strips control
    # characters and a stray ESC (not starting an SGR sequence), normalizes
    # CR/CRLF to LF, and expands TAB to `tab_char * tab_size`. Allocation-free on
    # tab-free, match-free input.
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
    # attach/scroll) omit it and resolve the width themselves.
    def process_content(no_tags = false, awidth_hint : Int32? = nil)
      # Content layout needs the owning window's dimensions, so nothing to do
      # until the widget is attached.
      return false unless window?

      ::Log.trace { "Parsing widget content: #{@content.inspect}" }

      colwidth = (awidth_hint || awidth) - ihorizontal
      # `@_clines.margin` is part of the wrap cache key: an `AsNeeded` scroll bar's
      # presence (and thus `content_margin_x`) can flip from a height-only change
      # (resize, `widget.height=`) that leaves the other cache-key fields
      # unchanged, and the stale-margin lines would let the bar overpaint the last
      # content column. The convergence loop below leaves
      # `@_clines.margin == content_margin_x`, so this doesn't re-fire in steady state.
      if @_clines.nil? || @_clines.empty? || @_clines.width != colwidth || @_clines.content_version != @_content_version || @_clines.base_x != @child_base_x || @_clines.margin != content_margin_x
        # A reparse reads raw `@content`, so fold deferred appends first (the
        # cache-hit path below never reaches here).
        fold_content_tail
        content = clean_content_chars @content

        ::Log.trace { "Internal content is #{content.inspect}" }

        # No content-level Unicode munging here: wide-char layout, grapheme
        # clusters, and combining marks are handled at the cell level in the
        # renderer (keyed off `window.full_unicode?`).

        # Parse tags only when not disabled and content actually has tags; skips
        # `_parse_tags`'s regex scan for plain text. `@_content_no_tags` records
        # the mode content was set with (e.g. via `#set_text`), so a later
        # cache-miss reparse (width change, resize, scroll, attach — all calling
        # with the default `no_tags = false`) keeps tags literal.
        if !no_tags && !@_content_no_tags && !@_rebuilding_from_fake && @_content_has_tags
          content = _parse_tags content
          # This parse consumed the whole raw content, so its end state IS the
          # boundary state a future append would splice at.
          @_content_open_tags_at_end = @_parse_tags_left_open
        else
          # Tags stay literal (none present, or `no_tags` mode), so no tag state
          # can be open at the end.
          @_content_open_tags_at_end = false
        end
        ::Log.trace { "After _parse_tags: #{content.inspect}" }

        # Wrap, then converge the scroll-bar reservation: an `AsNeeded` bar's
        # presence depends on the wrapped line count, known only after wrapping,
        # yet the wrap width depends on the bar reserving its column. Pass 1 must
        # seed from the margin an *empty* widget would reserve, NOT the previous
        # wrap's line count — seeding from history latches bistable content into
        # the with-bar layout forever. Monotonic: reserving a column only narrows
        # width and adds lines, so the bar can't then disappear — two passes always
        # suffice, and the no-bar fixed point wins whenever it exists.
        margin = content_margin_x_empty
        2.times do
          @_clines = _wrap_content(content, colwidth, into: @_clines, margin: margin)
          # Break test keys off line count, which `_wrap_content` already set;
          # cache-key fields below don't affect it, so set them once after.
          needed = content_margin_x
          break if needed == margin
          margin = needed
        end
        @_clines.width = colwidth
        @_clines.base_x = @child_base_x
        @_clines.content = @content
        @_clines.content_version = @_content_version
        # `_parse_attr` also records `style_to_attr(style)` in `@_parse_attr_default`, so
        # no separate recompute is needed here.
        @_clines.attr = _parse_attr @_clines
        # Reuse the `CLines`' own `ci` array (clear + refill) instead of
        # allocating a fresh replacement every reparse.
        ci = @_clines.ci
        ci.clear
        @_clines.reduce(0) do |total, line|
          ci.push(total)
          total + line.size + 1
        end

        @_pcontent = clines_joined
        emit Crysterm::Event::ContentParsed

        return true
      end

      # Refresh the cached base attribute only when it actually changed.
      # `@_parse_attr_default` MUST stay current regardless of content shape: it
      # is read unconditionally as the widget's fill/background attr, so freezing
      # it freezes the background of any widget that only changes `style.bg`
      # (e.g. an empty single-line `Effect::CopperBar` stops animating).
      da = style_to_attr(style)
      if da != @_parse_attr_default
        @_parse_attr_default = da
        # Recompute whenever a packed attr array already exists — never gate this
        # on line count. A populated-but-stale array is latched forever (`da` now
        # equals `@_parse_attr_default`, so the refresh never fires again) and
        # appended/scrolled lines paint with the old default attr permanently.
        # `nil` means no reader can see it, so nothing to refresh.
        @_clines.attr = _parse_attr(@_clines) unless @_clines.attr.nil?
      end

      false
    end

    # Whether the last `_parse_tags` call ended with tag state still open (a
    # non-empty fg/bg/flag stack, or an unterminated `{escape}`). Scratch output
    # slot, meaningful only immediately after a call.
    @_parse_tags_left_open = false

    # Whether `c` may appear in a tag name — the character class `[\w\-,;!#]`
    # of `TAG_REGEX`, where `\w` (PCRE2 default, non-UCP) is ASCII
    # `[A-Za-z0-9_]`. Lets `#_parse_tags` scan a `{tag}` by index instead of an
    # allocating anchored regex match.
    private def tag_name_char?(c : Char) : Bool
      c.ascii_letter? || c.ascii_number? ||
        c == '_' || c == '-' || c == ',' || c == ';' || c == '!' || c == '#'
    end

    # Convert `{red-fg}foo{/red-fg}` to `\e[31mfoo\e[39m`.
    # ameba:disable Metrics/CyclomaticComplexity
    def _parse_tags(text)
      @_parse_tags_left_open = false
      return text unless @parse_tags
      # Enter the parser whenever a brace is present (not only on a valid tag):
      # under the drop-malformed policy a stray `{`/`}` must be stripped too.
      return text unless text.includes?('{') || text.includes?('}')

      # Keep this O(n): `outbuf += ...` would rebuild the whole result per tag,
      # and reslicing `text` each step would allocate a fresh tail `String` per
      # tag — both O(n^2) on heavily-tagged content. Hence a `String::Builder`
      # (seeded near the input size, since tags expand to SGR of comparable
      # length) plus an integer cursor advanced via ANCHORED matches.
      outbuf = String::Builder.new text.bytesize
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

          # Body group is `*?`, not `+?`: an EMPTY `{escape}{/escape}` pair — the
          # natural `"{escape}#{untrusted}{/escape}"` idiom with an empty string —
          # must still match, else it takes the unterminated-escape bail below and
          # dumps the remainder verbatim.
          if esc && (cap = /([\s\S]*?){\/escape}/.match(text, pos, options: anchored))
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
        # verbatim for the aligner to act on it; otherwise it falls through to the
        # drop-malformed branch and renders as a bare `|`.
        if has_bar && text[pos, 3]? == "{|}"
          outbuf << "{|}"
          pos += 3
          next
        end

        # A recognized `{tag}` / `{/tag}`. `{open}`/`{close}` emit literal
        # braces; a known attribute name emits its SGR (tracking nesting so a
        # close restores the previous state); an unrecognized tag is dropped
        # (drop-malformed policy). `Tput#_attr` returns "" for an unknown name,
        # non-empty for every known one, so `empty?` is the test.
        #
        # Scanned by index rather than with an anchored `TAG_REGEX` match, whose
        # `MatchData` and captures allocated per tag — the dominant allocation of
        # heavily-tagged content. Mirrors `/\{(\/?)([\w\-,;!#]*)\}/` exactly: a
        # `{`, an optional leading `/`, a run of tag-name chars, then a closing
        # `}`. Any deviation falls through to the plain-run / drop-malformed
        # handling below, just as a failed regex match did.
        if text[pos]? == '{'
          slash = text[pos + 1]? == '/'
          name_start = slash ? pos + 2 : pos + 1
          k = name_start
          while (nc = text[k]?) && tag_name_char?(nc)
            k += 1
          end
          if text[k]? == '}'
            tag_start = pos
            pos = k + 1
            # XXX Tags must be specified such as {light-blue-fg}, but are then
            # parsed here with - being ' '. See why? Can we work with - and skip
            # this replacement part?
            # Only `gsub` when a dash is present — dash-free tags (`bold`, `red`)
            # reuse the name slice with no scan or allocation.
            param = text[name_start...k]
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
              # disabling `{center}…{/center}` alignment. They must survive parsing
              # verbatim (like `{|}` above) for the wrapper to consume afterwards.
              # The slice includes the slash, so opener and closer both pass through.
              outbuf << text[tag_start...pos]
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
                # `pop?` (not `pop`): a recognized closing tag with no matching
                # open leaves the stack empty, and `Array#pop` would raise, taking
                # down the parse on unbalanced-but-recognized input. Blessed's JS
                # `array.pop()` returns `undefined` and falls through to the tag's
                # "off" SGR; `pop?` reproduces that.
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
        end

        # A run of plain (brace-free) text passes through verbatim. Find the next
        # brace by index, not an anchored regex match, to avoid a per-run
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

      # Report whether the parse ended with tag state still open. `esc` stays true
      # on the unterminated-`{escape}` bail above — parser state a continuation of
      # this text would inherit, just like a non-empty stack.
      @_parse_tags_left_open = esc || !(bg.empty? && fg.empty? && flag.empty?)

      outbuf.to_s
    end

    # Base attribute after scanning `line`'s inline SGR sequences starting from
    # `attr` — how SGR state carries line-to-line, so a `{red-fg}` left open on an
    # earlier line colors later ones too. `default_attr` is `style_to_attr(style)`, passed
    # in so callers compute it once.
    private def _attr_after(line : String, attr : Int64, default_attr : Int64) : Int64
      line.each_char_with_index do |char, i|
        if char == '\e'
          if c = SGR_REGEX.match(line, i, options: Regex::MatchOptions::ANCHORED)
            attr = window.sgr_to_attr(c[0], attr, default_attr)
          end
        end
      end
      attr
    end

    protected def _parse_attr(lines : CLines)
      default_attr = style_to_attr(style)
      # Record the base attribute this parse was built against, so callers don't
      # recompute `style_to_attr(style)` separately.
      @_parse_attr_default = default_attr
      attr = default_attr
      # Reuse the `CLines`' own `attr` array (clear + refill) instead of
      # allocating a fresh `Array(Int64)` each reparse.
      attrs = (lines.attr ||= [] of Int64)
      attrs.clear

      # Fast path for the common plain-text case: with no inline SGR at all (no
      # raw `\e`, no tags expanding into one) every line carries the same base
      # attr, so fill directly and skip the per-line `_attr_after` scan.
      if !@_content_has_sgr && !@_content_has_tags
        lines.size.times { attrs.push default_attr }
        return attrs
      end

      lines.each do |line|
        attrs.push attr
        attr = _attr_after(line, attr, default_attr)
      end

      attrs
    end

    # Appends one finished wrapped (real) line and records the fake↔real
    # mapping: `line` becomes a new real row of `outbuf`, fake line `no` gains
    # that real index in `ftor`, and `rtof` gains `no`.
    #
    # `width`, when given, is the aligned line's already-known display width,
    # sparing a re-`str_width` (and thus a re-strip of the line's SGR).
    private def push_real_line(outbuf : CLines, ftor, rtof, no : Int32, line : String, width : Int32? = nil) : Nil
      outbuf.push line
      ftor[no].push(outbuf.size - 1)
      rtof.push(no)
      # Accumulate the widest real line as lines are emitted, rather than in a
      # second pass re-measuring every one. Safe: the one later in-place mutation
      # of a pushed line appends only zero-width SGR.
      w = width || str_width(line)
      outbuf.max_width = w if w > outbuf.max_width
    end

    # Wraps content based on available widget width.
    #
    # `into`, when given, is an existing `CLines` to refill in place rather than
    # allocating a fresh one, so steady-state reparsing reuses the same object and
    # its array buffers. When nil a new `CLines` is built.
    def _wrap_content(content, colwidth, into : CLines? = nil, margin : Int32? = nil)
      default_state = @align
      # The right-edge reservation this wrap subtracts. When not passed in it must
      # be captured HERE, before `outbuf.reset` clears `@_clines`: `content_margin_x`
      # reads `@_clines.size` to size an `AsNeeded` bar and post-reset would see
      # zero lines mid-wrap.
      margin ||= content_margin_x
      outbuf = into || CLines.new
      # Record the reservation this wrap is built against, so a caller can tell
      # when an `AsNeeded` bar's presence (only known post-wrap) flips it and a
      # re-wrap is needed.
      outbuf.margin = margin
      # Clear in-place arrays so a reused `CLines` starts empty (no-op when freshly
      # built). The `rtof`/`ftor` aliases below fill the `CLines`' own arrays
      # directly. (The empty-content branch returns before these are used.)
      outbuf.reset
      outbuf.full_width = 0
      # `reset` doesn't touch scalar `max_width`; zero it so `push_real_line` can
      # accumulate the widest real line as they're emitted.
      outbuf.max_width = 0
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
      # panel title): refill in place instead of letting `String#split` allocate a
      # fresh `Array(String)` every reparse. Multi-line content still splits, since
      # its substrings must be allocated anyway.
      if content.includes?('\n')
        lines = content.split('\n')
      else
        lines = outbuf.fake
        lines.clear
        lines << content
      end

      # Subtract the right-edge reservation so content wraps clear of the scroll
      # bar (and any per-widget reservation, e.g. a caret column).
      colwidth -= margin if colwidth > margin

      lines.each_with_index do |line, no|
        align = default_state
        align_left_too = false

        ftor.push outbuf.take_ftor_row

        # Handle alignment tags. The opener may be preceded — and the closer
        # followed — by inline SGR, which happens when an alignment tag nests
        # inside an attribute tag: `{bold}{center}Hi{/center}{/bold}` becomes
        # `\e[1m{center}Hi{/center}\e[22m` after `_parse_tags`. So the match must
        # allow surrounding SGR (and re-prepend/-append it, consuming only the
        # alignment tag); anchoring at the absolute string edge instead silently
        # drops the alignment and leaks the literal tag into output.
        if @parse_tags && !@_content_no_tags && line.includes?('{')
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
        # is plain "keep what fits, cut the rest" truncation.
        unless @wrap_content
          outbuf.full_width = Math.max(outbuf.full_width, str_width(line))
          push_real_line outbuf, ftor, rtof, no, _align(_hslice(line, @child_base_x, colwidth), colwidth, align, align_left_too)
          next
        end

        # If the string could be too long, check it in more detail and wrap it if needed.
        # NOTE Done with loop+break due to https://github.com/crystal-lang/crystal/issues/1277
        #
        # Track the remaining line's visible width incrementally rather than
        # re-measuring the whole tail every iteration (O(L²) for one long line).
        # Valid because each cut lands on a grapheme/codepoint boundary and never
        # inside an SGR run, so width is additive across the split.
        remaining_width = str_width(line)
        loop_ret = loop do
          break unless remaining_width > colwidth

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
          # (`\e[…m`), so escape runs must be skipped: their bytes must neither
          # consume the ~10-char lookback budget nor let the cut land inside a
          # sequence. Meeting a run's terminating `m` walking backwards jumps `j`
          # back to the opening `\e`.
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
          # `part`'s width is bounded by ~`colwidth`, so this measures O(colwidth)
          # rather than the O(remaining) a `str_width(line)` gate would.
          remaining_width -= str_width(part)

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

      # NOTE `outbuf.max_width` is the widest real line *including* alignment
      # padding, so for aligned text it reflects the surrounding box's width
      # rather than the actual longest line.

      outbuf
    end

    # Aligns content, returning just the aligned string. `#aligned_with_width`
    # additionally hands back the result's display width, sparing a re-measure.
    def _align(line, width, align = Tput::AlignFlag::None, align_left_too = false)
      aligned_with_width(line, width, align, align_left_too)[0]
    end

    # Aligns `line` and returns `{result, width}` where `width` is the result's
    # display columns when cheaply known here, else `nil` — the caller then falls
    # back to `str_width`. Sparing that re-measure avoids a duplicate SGR-strip on
    # every aligned line carrying color.
    private def aligned_with_width(line, width, align = Tput::AlignFlag::None, align_left_too = false) : Tuple(String, Int32?)
      # Right-align separator `{|}` (Blessed): text after it is pushed to the
      # right edge. It distributes content within the line independent of the
      # line's own alignment, so it MUST be handled before the align-direction
      # early-returns below — otherwise it never fires for default Left alignment.
      if @parse_tags && !@_content_no_tags && line.includes?("{|}")
        cl = line.includes?('\e') ? line.gsub(SGR_REGEX, "") : line
        if res = split_right_align(line, cl, width)
          # Result width isn't cheaply `width` here (a too-wide split leaves the
          # pad at 0), so leave it unknown and let the caller measure.
          return {res, nil}
        end
      end

      return {line, nil} if align.none?

      # Plain left alignment pads nothing — only HCenter/Right (or a forced
      # `{left}` via `align_left_too`) add spaces. Bailing before measuring skips
      # a `str_width` on every line of the common default-`Left` case.
      if !align_left_too && (align & (Tput::AlignFlag::HCenter | Tput::AlignFlag::Right)).none?
        return {line, nil}
      end

      # Only run the SGR-stripping `gsub` when an escape is actually present, so
      # the uncolored majority reuses `line` with no allocation.
      cline = line.includes?('\e') ? line.gsub(SGR_REGEX, "") : line
      # `cline` is already SGR-stripped, so this skips the regex scan
      # `str_width line` would repeat.
      len = str_width cline

      # A `Layout` sets all its children to `#shrink_to_fit = true` (shrink in
      # blessed), so a shrink-to-content widget with no usable width yet has free
      # width `s == 0` and must skip alignment padding. Gates on `width == 0`
      # because `width` is an Int, so blessed's falsy `!width` test can't port.
      s = (@shrink_to_fit && width == 0) ? 0 : width - len

      # Nothing to pad: return `line` unchanged, but pass on its now-known width
      # (`0` when all-SGR; `len` otherwise) so the caller skips a re-measure.
      return {line, 0} if len == 0
      return {line, len} if s < 0

      # Alignment's empty space is filled with the widget's `Style#fill_char`
      # (default `' '`), so a non-space fill (e.g. a dotted leader) lines up with
      # how the render loop fills trailing cells.
      fc = style.fill_char
      # The padded width is `len + s` only when each fill cell is one column (the
      # ASCII common case); for a wide fill char leave it unknown to be re-measured.
      padded_width = fc.ascii? ? len + s : nil

      if (align & Tput::AlignFlag::HCenter) != Tput::AlignFlag::None
        # Split free space across both sides; the odd extra cell goes right
        # (Blessed's convention), so a centered line fills `width` exactly instead
        # of falling one cell short on odd free space.
        lpad = s // 2
        rpad = s - lpad
        res = String.build(line.bytesize + s) do |io|
          lpad.times { io << fc }
          io << line
          rpad.times { io << fc }
        end
        return {res, padded_width}
      elsif align.right?
        res = String.build(line.bytesize + s) do |io|
          s.times { io << fc }
          io << line
        end
        return {res, padded_width}
      elsif align_left_too && align.left?
        # Left align is visually the same as no align, but center/right padding
        # affects widget size, so pad `{left}` too — making `{left|center|right}`
        # behave identically re. row width. Only when `{left}` is explicitly in
        # content with parse_tags on, never for a widget's default
        # `align = AlignFlag::Left` (which would disturb cursor position in text
        # widgets).
        res = String.build(line.bytesize + s) do |io|
          io << line
          s.times { io << fc }
        end
        return {res, padded_width}
      elsif @parse_tags && !@_content_no_tags && (line.includes?('{') || line.includes?('}'))
        # XXX This is basically Tput::AlignFlag::Spread, but not sure
        # how to put that as a flag yet. Maybe this (or another)
        # widget flag could mean to spread words to fill up the whole
        # line, increasing spaces between them?
        if res = split_right_align(line, cline, width)
          return {res, nil}
        end
        # Otherwise (lone `{` or `}`): falls through to `return line` below.
      end

      {line, len}
    end

    # Index of the first `{` or `}` in `s` at or after `from`, or `nil` if none.
    # The delimiter set of `split(/\{|\}/)`, located by `#index` (no regex, no
    # MatchData) so `#split_right_align` can pick out just the segments it needs.
    private def brace_after(s : String, from : Int32) : Int32?
      i = s.index('{', from)
      j = s.index('}', from)
      return j unless i
      return i unless j
      Math.min(i, j)
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
      # Reproduce `split(/\{|\}/)`'s parts[0] (before the first brace) and
      # parts[2] (between the second and third brace, or to the string's end) via
      # index math, slicing only the two needed segments instead of materializing
      # two full split arrays. Braces never occur inside SGR runs, so `line` and
      # `cline` carry the same delimiters (at different indices); widths are
      # measured on the SGR-stripped `cline`, output taken from `line`.
      cb1 = brace_after(cline, 0)
      return nil unless cb1
      cb2 = brace_after(cline, cb1 + 1)
      # No second brace -> `split` yields no parts[2].
      return nil unless cb2
      cb3 = brace_after(cline, cb2 + 1)
      cpart0 = cline[0...cb1]
      cpart2 = cline[(cb2 + 1)...(cb3 || cline.size)]

      lb1 = brace_after(line, 0)
      lb2 = lb1 ? brace_after(line, lb1 + 1) : nil
      # `line` shares `cline`'s brace count, so both are present here.
      return nil unless lb1 && lb2
      lb3 = brace_after(line, lb2 + 1)
      lpart0 = line[0...lb1]
      lpart2 = line[(lb2 + 1)...(lb3 || line.size)]

      pad = style.fill_char.to_s * Math.max(width - str_width(cpart0) - str_width(cpart2), 0)
      "#{lpart0}#{pad}#{lpart2}"
    end

    # Rebuilds widget content from the in-place-mutated `@_clines.fake` lines
    # (re-joining and reparsing). `no_clear` is set so `@_clines` is refreshed
    # rather than wiped.
    private def rebuild_content_from_fake
      # The third positional arg MUST carry the widget's tag mode: letting
      # `no_tags` default to false permanently flips a literal-tags widget back
      # into tag-parsing mode.
      #
      # `fake` holds POST-parse text, so the reparse `set_content` triggers would
      # corrupt it (escaped braces dropped, literal tags re-interpreted). Suppress
      # just this reparse via the transient flag rather than flipping the
      # persistent `@_content_no_tags`; freshly edited lines are already parsed at
      # their entry points. `ensure` so a raise can't leave the guard latched,
      # silently disabling tag parsing for the widget.
      @_rebuilding_from_fake = true
      begin
        set_content(@_clines.fake.join("\n"), true, @_content_no_tags)
      ensure
        @_rebuilding_from_fake = false
      end
    end

    # Brings a caller-supplied line into the POST-parse form `@_clines.fake`
    # stores, so a freshly inserted/set line is spliced in the same shape a full
    # reparse would produce (`clean_content_chars` then `_parse_tags`) — a tag in
    # the new line still expands, while the reparse-suppressing rebuild leaves the
    # rest of `fake` untouched. A no-op for tag-disabled widgets / `no_tags`
    # content, matching their literal storage.
    private def parse_fake_line(line : String) : String
      return line unless @parse_tags && !@_content_no_tags
      _parse_tags clean_content_chars line
    end

    # Scratch `CLines` reused across `append_content` calls so wrapping just the
    # appended line never allocates a fresh bookkeeping object.
    @_append_scratch : CLines? = nil

    # Appends `text` (one or more `\n`-separated logical lines) without reparsing
    # existing content. Only the new text is cleaned, tag-parsed, wrapped and
    # attr-scanned, then spliced onto `@_clines`'s tail — turning `set_content`'s
    # O(total) per-append cost into O(appended).
    #
    # Returns `true` if the fast path handled it, `false` if it bailed and the
    # caller must fall back to `set_content`/`append_line`.
    #
    # Byte-identical to a full reparse because:
    # * `_wrap_content` wraps each `\n`-split segment independently, so appending
    #   never re-wraps earlier lines.
    # * The segment is tag-parsed standalone only when the full reparse's tag
    #   stacks would be empty at the boundary anyway; otherwise it bails.
    # * Attributes do carry: an SGR left open on an earlier line (e.g. unclosed
    #   `{red-fg}`) colors appended lines too; `_attr_after` recreates that carry.
    def append_content(text : String) : Bool
      return false unless window?
      # Cache must be current: with a reparse pending, splicing onto stale
      # `@_clines` would corrupt it. Let the normal path run first.
      return false unless @_clines.content_version == @_content_version
      return false if content_blank?
      colwidth = @_clines.width
      return false if colwidth <= 0
      # A width change since the cache was built invalidates the existing wrapped
      # lines, so only the reparsing slow path can serve it.
      return false if (awidth - ihorizontal) != colwidth
      # Degenerate state: content cleaned to nothing leaves `_wrap_content` in its
      # empty-content shape (`fake` empty, one blank real line). Splicing there
      # would desync `fake` from `lines`.
      return false if @_clines.fake.empty?

      # An unclosed `{center}`/`{right}` opener mutates `_wrap_content`'s carried
      # `default_state` for all following lines in a full reparse, but the fast
      # path wraps the segment standalone from the widget's default `@align`,
      # dropping that carry. Bail conservatively whenever tag parsing is on and
      # alignment tags appear in existing content or the appended text.
      seg_has_align_tag = text.includes?('{') && text.matches?(ALIGN_TAG_REGEX)
      if @parse_tags && (@_content_has_align_tag || seg_has_align_tag)
        return false
      end

      # Clean control chars on just the appended text (same rule as
      # `process_content`), then tag-parse only the new segment.
      seg = clean_content_chars text
      # An append that cleans away to nothing would drive `_wrap_content` down its
      # empty-content branch, desyncing `fake` from `lines`.
      return false if seg.empty?

      # Decided on the raw `text`, NOT the cleaned `seg`, mirroring how
      # `set_content` derives `@_content_has_tags`: a full reparse's `_parse_tags`
      # gate keys off the raw string, so this decision must too (a control char
      # inside a would-be tag makes the raw string tagless even though cleaning
      # would form a tag).
      seg_has_tags = text.includes?('{') && text.matches?(TAG_REGEX)

      # Tag-parse the new segment iff a full reparse of (existing + appended)
      # content would run `_parse_tags` — the same gate as `process_content`, with
      # the appended text folded into the tag flag.
      if @parse_tags && !@_content_no_tags && (@_content_has_tags || seg_has_tags) &&
         (seg.includes?('{') || seg.includes?('}'))
        # This append switches the reparse gate on over content that was never
        # tag-parsed. That only matters if existing raw content has a brace: kept
        # literal so far, it would now be dropped by the drop-malformed policy,
        # changing already-rendered lines. Brace-free existing content is
        # unaffected by the flip, so it stays on the fast path. Testing
        # `@_content_has_tags` alone would bail here forever rather than once: the
        # rebuild re-derives that flag from POST-parse text, where tags have
        # already become SGR, so it lands back on false after every fallback.
        return false if !@_content_has_tags && @_content_has_braces
        # A full reparse carries raw `@content`'s tag stacks (and `{escape}` mode)
        # across the append boundary; the fast path parses the segment standalone,
        # from empty state. Opening tags emit the same SGR either way, but a
        # closing tag pops the carried stack (restoring e.g. a still-open
        # `{red-fg}` rather than emitting the off-SGR), and an open escape
        # swallows the segment verbatim.
        return false if @_content_open_tags_at_end
        # Boundary state is empty (just checked), so the standalone parse matches
        # a full reparse exactly — including dropping stray braces and unknown
        # tags — and its end state is the new boundary state.
        seg = _parse_tags seg
        @_content_open_tags_at_end = @_parse_tags_left_open
        # A segment that parses away to nothing (e.g. a lone unknown tag) hits the
        # same `fake`/`lines` desync as the cleaned-to-empty case above.
        return false if seg.empty?
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

      # Extend `ci` (char offset of each real line in the joined pcontent). Must
      # derive from the existing offsets, not `@_pcontent`, which is lazily built
      # and may be stale/nil here. The first new line starts one past the last
      # existing line's end (the +1 is the joining "\n"); `base_real >= 1` since
      # content is non-blank. The safe `[]?` keeps offsets monotonic rather than
      # raising should `ci` somehow be short.
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
        da = style_to_attr(style)
        # `base_real >= 1` (content non-blank); degrade to default if `attrs` is
        # somehow short.
        carry = base_real <= attrs.size ? _attr_after(cl.lines[base_real - 1], attrs[base_real - 1], da) : da
        scratch.lines.each do |ln|
          attrs << carry
          carry = _attr_after(ln, carry, da)
        end
      end

      cl.max_width = Math.max(cl.max_width, scratch.max_width)
      # Carry the widest unclipped line forward too (non-wrapped content only;
      # `full_width` is 0 when wrapping), or a wider appended line would leave the
      # horizontal scroll extent stale.
      cl.full_width = Math.max(cl.full_width, scratch.full_width)

      # Defer the two O(total) string builds, making a run of appends O(1)
      # amortized rather than O(n) each: `@_pcontent` is marked stale and rebuilt
      # on demand (a fresh String also makes render's `built_from?` check rebuild
      # the codepoint index), and the raw `text` is folded into `@content` only
      # when read.
      @_pcontent = nil
      @_content_tail << text
      # Content-shape flags accumulate from the raw appended text under the same
      # conditions `set_content` uses — independent of `@parse_tags`/`no_tags`
      # mode. Tags appended while parsing is off (kept literal above) must still
      # set the flags, or a later `parse_tags = true` flip reparses with a
      # stale-false gate and the tags stay literal permanently.
      @_content_has_tags ||= seg_has_tags
      @_content_has_braces ||= text.includes?('{') || text.includes?('}')
      @_content_has_align_tag ||= seg_has_align_tag
      # Cleaned `seg` retains valid SGR (stray ESC was stripped above);
      # tag-expanded SGR is covered by `@_content_has_tags`, as in `set_content`.
      @_content_has_sgr ||= seg.includes? '\e'
      @_content_version += 1
      cl.content_version = @_content_version

      # If the appended lines crossed the viewport-overflow threshold, an
      # `AsNeeded` vertical scroll bar just flipped on (or off) and
      # `content_margin_x` changed, leaving every line wrapped against the
      # pre-flip margin. Reconcile immediately with one full reparse: stale-margin
      # lines otherwise survive until the next `process_content` and desync readers
      # running off the events emitted just below. Rare — only the append that
      # crosses the threshold pays this; once the bar's presence is stable,
      # subsequent appends stay on the O(appended) fast path.
      if cl.margin != content_margin_x
        process_content
      end

      # Mirror the full path: mark for repaint and emit the same events.
      mark_dirty
      emit Crysterm::Event::ContentParsed
      emit Crysterm::Event::ContentChanged
      true
    end

    # Appends *line* after the last logical line. Splits on `\n` for multi-line
    # input.
    def insert_line(line : String) : Nil
      insert_line(@_clines.fake.size, line)
    end

    def insert_line(index : Int32, line : String) : Nil
      lines = line.split("\n")

      i = Math.max(index, 0)

      while @_clines.fake.size < i
        @_clines.fake.push("")
        @_clines.ftor.push([@_clines.push("").size - 1])
        # Discarded read kept only for parity with the port; the safe `[]?` so it
        # cannot raise when `rtof` is shorter than `fake`.
        @_clines.rtof[@_clines.fake.size - 1]?
      end

      # NOTE: Could possibly compare the first and last ftor line numbers to see
      # if they're the same, or if they fit in the visible region entirely.
      start = @_clines.size
      # diff
      # real

      if i >= @_clines.ftor.size
        # `ftor` is empty before the first wrap (freshly built widget, or content
        # cleared to empty), where `ftor[-1]` would raise. Default the insert point
        # to the first real line.
        if last_row = @_clines.ftor.last?
          real = last_row[-1] + 1
        else
          real = 0
        end
      else
        real = @_clines.ftor[i][0]
      end

      lines.size.times do |j|
        # Pre-parse each incoming line into the POST-parse form `fake` holds, so
        # the reparse-suppressed rebuild below still expands this line's tags
        # without re-running (and corrupting) the other lines.
        @_clines.fake.insert(i + j, parse_fake_line(lines[j]))
      end

      rebuild_content_from_fake

      diff = @_clines.size - start

      render_line_shift(diff, real) do |d, y, top, bottom|
        window.insert_line(d, y, top, bottom)
      end
    end

    # Drives the terminal-side line insert/delete optimization. *diff* is the
    # change in wrapped-line count (only acts when positive) and *real* the
    # affected real (wrapped) line index. Computes the on-window coordinates and,
    # when the affected row is visible and the sides are clean, yields
    # `(diff, y, top, bottom)` for the caller's window op. A no-op (no yield) when
    # the widget isn't laid out or the row is off the viewport.
    private def render_line_shift(diff, real, &)
      return unless diff > 0
      pos = coords
      return if !pos || pos == 0

      height = pos.yl - pos.yi - ivertical
      base = @child_base
      visible = real >= base && real - base < height

      top = pos.yi
      bottom = pos.yl - ibottom - 1
      # The vertical bounds check is load-bearing: `sides_uniform?`'s full-width
      # shortcut skips vertical bounds, but the window line ops mutate buffer rows
      # `top..bottom` directly, so out-of-buffer bounds raise mid-mutation (or wrap
      # negative indices), corrupting the line buffers. A widget extending past the
      # screen edge falls back to the normal repaint.
      if visible && top >= 0 && bottom <= window.aheight - 1 && window.sides_uniform?(self)
        yield diff, pos.yi + itop + real - base, top, bottom
      end
    end

    # Deletes the last logical line (Blessed's `deleteLine()` no-argument
    # behavior). A zero-arg def, not `(n : Int32 = 1)`: that signature would be
    # merged with the `(index, n)` overload below and replace it.
    def delete_line : Nil
      return if @_clines.fake.empty?
      delete_line(@_clines.fake.size - 1, 1)
    end

    def delete_line(index : Int32, n : Int32 = 1) : Nil
      # Nothing to delete when there are no logical lines yet (freshly built
      # widget, or content cleared to empty); without this guard the deletes below
      # raise on such a widget. Blessed's `deleteLine` is a no-op here.
      return if @_clines.fake.empty?

      # Clamp against the array actually spliced below (`fake`), NOT `ftor`: with
      # content seeded before attach, `fake` is non-empty while `ftor` is still
      # empty, so `ftor.size - 1 == -1` and Crystal's two-arg `clamp` (which
      # returns `max` when `min > max`) would make `i` be `-1`, deleting the LAST
      # line.
      i = index.clamp(0, @_clines.fake.size - 1)

      # Clamp count to lines actually available from `i`, or deleting more than
      # remain runs `delete_at` off the end of `fake`. JS `splice(i, n)` clamps,
      # so this matches the ported Blessed semantics.
      n = Math.min(n, @_clines.fake.size - i)
      return if n <= 0

      # NOTE: Could possibly compare the first and last ftor line numbers to see
      # if they're the same, or if they fit in the visible region entirely.
      start = @_clines.size
      # `ftor` is empty when content was seeded before attach (`fake` gets filled
      # but `process_content` bails until the widget has a window), so `ftor[i]`
      # would raise despite `fake` being non-empty. Fall back to real line 0; the
      # fake splice + rebuild below still works.
      real = @_clines.ftor[i]?.try(&.[0]?) || 0

      n.times { @_clines.fake.delete_at i }

      rebuild_content_from_fake

      diff = start - @_clines.size

      # XXX clear_last_rendered_position() without diff statement?
      render_line_shift(diff, real) do |d, y, top, bottom|
        window.delete_line(d, y, top, bottom)
      end
    end

    # Maps a real (wrapped) line index to its fake (logical) line index,
    # guarding out-of-range access (e.g. before content is wrapped). Returns 0
    # when `rtof` is empty, clamps otherwise.
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
      # `visible_content_rows`, not `aheight - ivertical`: it subtracts the
      # horizontal scroll bar's reserved row, so we don't insert after a line
      # hidden under the bar.
      h = @child_base + visible_content_rows
      i = Math.min(h, @_clines.size)
      fake = rtof_index(i - 1) + 1

      insert_line(fake, line)
    end

    def delete_top(n = 1)
      fake = rtof_index(@child_base)
      delete_line(fake, n)
    end

    def delete_bottom(n : Int32 = 1)
      # `visible_content_rows` accounts for the horizontal scroll bar's reserved
      # row, so we delete the visible bottom row, not one hidden below the bar.
      h = @child_base + visible_content_rows - 1
      i = Math.min(h, @_clines.size - 1)
      fake = rtof_index(i)

      delete_line(fake - (n - 1), n)
    end

    def replace_line(i, line)
      i = Math.max(i, 0)
      # Pad up to and including index `i` (`<=`, not `<`). Blessed relies on JS
      # auto-extending arrays; Crystal's `fake[i] = line` raises when `i ==
      # fake.size`, so the slot must exist first.
      while @_clines.fake.size <= i
        @_clines.fake.push("")
      end
      # Pre-parse into `fake`'s POST-parse form so the reparse-suppressed rebuild
      # keeps the other lines intact.
      @_clines.fake[i] = parse_fake_line(line)
      rebuild_content_from_fake
    end

    def replace_base_line(i, line)
      fake = rtof_index(@child_base)
      replace_line(fake + i, line)
    end

    # Original ("fake") line *i*, as rendered (see `#rendered_content`).
    def line(i)
      # Empty content leaves `@_clines.fake` empty, where `i.clamp(0, fake.size - 1)`
      # clamps to `-1` (Crystal's two-arg clamp yields `max` even when `min > max`)
      # and `fake[-1]` would raise. A blank line matches Blessed's `getLine` for a
      # missing line.
      return "" if @_clines.fake.empty?
      i = i.clamp(0, @_clines.fake.size - 1)
      @_clines.fake[i]
    end

    # `#line`, but *i* counts from the current scroll base rather than from the
    # top of the content.
    def base_line(i)
      fake = rtof_index(@child_base)
      line(fake + i)
    end

    def clear_line(i)
      i = Math.min(i, @_clines.fake.size - 1)
      replace_line(i, "")
    end

    def clear_base_line(i)
      fake = rtof_index(@child_base)
      clear_line(fake + i)
    end

    def prepend_line(line)
      insert_line(0, line)
    end

    def remove_first_line(n)
      delete_line(0, n)
    end

    def append_line(line)
      # Seed line 0 when there is no content yet (counting deferred appends
      # without materializing them).
      if content_blank?
        return replace_line(0, line)
      end
      # Appending at the end is the common case (logs, transcripts, streaming
      # output), so try the O(appended) splice first; it returns false and falls
      # through to the general insert when it can't guarantee an identical result.
      #
      # NOTE: there is deliberately no `Widget#<<` text alias — `<<` already means
      # "append a child widget".
      return if append_content(line)
      insert_line(@_clines.fake.size, line)
    end

    def remove_last_line(n)
      delete_line(@_clines.fake.size - 1, n)
    end

    # All original ("fake") lines, as rendered. A copy; mutating it does not
    # touch the widget.
    def lines
      @_clines.fake.dup
    end

    # All *wrapped* ("real") lines — one entry per screen row rather than per
    # original line. A copy; see `#lines` for the unwrapped view.
    def screen_lines
      @_clines.dup
    end

    # Whether grapheme / column-width-aware layout is in effect for this widget:
    # the owning window's effective gate (option AND terminal capability). False
    # when unattached.
    def full_unicode?
      window?.try(&.full_unicode_effective?) || false
    end

    # The glyph tier in effect for this widget (the owning window's screen
    # setting; `Unicode` when unattached — the registry's byte-identical
    # default).
    def glyph_tier : Glyphs::Tier
      window?.try(&.glyph_tier) || Glyphs::Tier::Unicode
    end

    # The registry character for *role* at this widget's effective tier. The
    # single hook widget renders use instead of hardcoded chrome literals.
    @[AlwaysInline]
    def glyph(role : Glyphs::Role) : Char
      Glyphs[role, glyph_tier]
    end

    # The registry *grapheme* (String) for a *run* role at this widget's effective
    # tier — the String companion to `#glyph`. A run-role site (an inline, measured
    # text run) uses this so a multi-codepoint upgrade like `⚠️` renders whole,
    # instead of the reject-to-fallback single `Char` `#glyph` yields for fixed
    # 1-column cell roles.
    @[AlwaysInline]
    def glyph_str(role : Glyphs::Role) : String
      Glyphs.str(role, glyph_tier)
    end

    # Like the above, but resolving a CSS-styled site first: the *slot* style's
    # `glyph` family at the effective tier, else the registry. *slot* is the
    # sub-`Style` the CSS property lands on — pass `style.raw_sub_style(...)` for a
    # sub-control site (only an explicitly cascaded/assigned sub-style answers, so
    # a widget-wide `glyph` can't bleed into every part of a multi-part widget), or
    # `style` itself for a single-glyph widget (`SizeGrip { glyph: "◢" }`).
    #
    # A CSS `glyph: none` — and, on a *cell* role, any value that isn't exactly one
    # column — is unusable here and falls back to the registry. Run-role callers
    # that want the whole grapheme use `#glyph_str`/`#glyph_str?`; ones that honor
    # `none` by omitting a single-`Char` glyph use `#glyph?`.
    def glyph(role : Glyphs::Role, slot : ::Crysterm::Style?) : Char
      tier = glyph_tier
      if slot && (s = slot.glyph_for(tier)) && (c = usable_cell_glyph(s, role))
        return c
      end
      Glyphs[role, tier]
    end

    # Run-role variant of `#glyph(role, slot)` honoring CSS `glyph: none`: returns
    # `nil` when the style says to omit the glyph entirely (zero cells).
    # `Char`-typed for callers that draw a single-cell affordance; a
    # multi-codepoint CSS override can't fit here and falls back to the registry
    # (use `#glyph_str?` for the whole grapheme). Not for cell roles, which must
    # always paint.
    def glyph?(role : Glyphs::Role, slot : ::Crysterm::Style?) : Char?
      tier = glyph_tier
      if slot && (s = slot.glyph_for(tier))
        return nil if s == Glyphs::NONE_STR
        return s[0] if s.size == 1
        # Multi-codepoint override: not representable as a lone cell `Char`.
      end
      Glyphs[role, tier]
    end

    # Run-role, grapheme-returning companion to `#glyph(role, slot)`: the
    # slot's CSS glyph *whole* (a multi-codepoint `⚠️` survives) when set and
    # not `none`, else the registry grapheme. For measured inline runs where a
    # wide/emoji override should render as-is rather than reduce to a `Char`.
    def glyph_str(role : Glyphs::Role, slot : ::Crysterm::Style?) : String
      tier = glyph_tier
      if slot && (s = slot.glyph_for(tier)) && s != Glyphs::NONE_STR
        return s
      end
      Glyphs.str(role, tier)
    end

    # `#glyph_str` honoring CSS `glyph: none` — returns `nil` to omit the glyph
    # entirely (zero cells). The grapheme-returning analogue of `#glyph?`.
    def glyph_str?(role : Glyphs::Role, slot : ::Crysterm::Style?) : String?
      tier = glyph_tier
      if slot && (s = slot.glyph_for(tier))
        return nil if s == Glyphs::NONE_STR
        return s
      end
      Glyphs.str(role, tier)
    end

    # The "always-measure" path for a *single-placement* affordance role — the
    # non-`cell?` roles a widget paints once into a box it can size: the resolved
    # glyph as the whole grapheme *and* the terminal COLUMNS it occupies. Unlike
    # `#glyph(role, slot)`, which reduces to a lone 1-column `Char`, this keeps a
    # wide CSS/registry upgrade (`⚠️`) whole and reports its measured width so the
    # caller reserves that many columns (the box grows to fit rather than
    # clipping). Fixed-cell, fill-region roles stay on `#glyph`: a wide glyph makes
    # no sense in a 1-cell run replicated across the cross axis.
    #
    # `none` is not honored here (a placed affordance always paints) — it falls
    # back to the registry, exactly like `#glyph`.
    def glyph_measured(role : Glyphs::Role, slot : ::Crysterm::Style?) : {String, Int32}
      s = glyph_str(role, slot)
      {s, Unicode.width(s)}
    end

    # Reduces a CSS-specified glyph *s* to the lone `Char` usable for *role* as
    # a fixed cell, or `nil` when it can't stand in: `none`, a multi-codepoint
    # grapheme (no lone code point), or — on a *cell* role — a wide char that
    # would corrupt the grid. A run role tolerates a single wide char (an emoji
    # affordance). Width is checked only on this rare styled path.
    private def usable_cell_glyph(s : String, role : Glyphs::Role) : Char?
      return nil if s == Glyphs::NONE_STR
      return nil unless s.size == 1
      c = s[0]
      return nil if role.cell? && Unicode.width(c) != 1
      c
    end

    # The sequence steps for *role* (spinner frames, dial pointer ring, fill
    # ramps): the CSS `glyphs` string on *slot* when set (its characters are the
    # steps), else the registry sequence at the effective tier. With `cells: true`
    # (fill ramps — each step paints one grid cell) a CSS sequence containing any
    # non-1-column character is rejected wholesale, falling back to the registry.
    #
    # The CSS path allocates a fresh array per call (`String#chars`); the registry
    # path returns the stored array. Per-frame callers should therefore memoize
    # against `#glyph_key`; per-content-build callers use it directly.
    def glyph_seq(role : Glyphs::SeqRole, slot : ::Crysterm::Style = style, cells : Bool = false) : Array(Char)
      if (s = slot.glyphs) && !s.empty?
        chars = s.chars
        return chars unless cells && chars.any? { |c| Unicode.width(c) != 1 }
      end
      Glyphs.chars(role, glyph_tier)
    end

    # The identity key of the currently-resolved chrome glyphs for *slot*: its raw
    # glyph string, the active tier, and the global glyph generation. Widgets that
    # memoize glyph-derived content compare against this and rebuild only when it
    # changes.
    def glyph_key(slot : ::Crysterm::Style = style) : {String?, Glyphs::Tier, UInt64}
      {slot.glyphs, glyph_tier, Glyphs.generation}
    end

    # Width, in terminal COLUMNS, of `text`'s visible content. SGR sequences are
    # stripped (they occupy no columns); whitespace is preserved. With
    # `#full_unicode?` this is grapheme / East-Asian width (`Unicode`), otherwise
    # the codepoint count (legacy behavior).
    #
    # This is the single width hook layout should use; a raw `.size` miscounts
    # wide / combining characters.
    def str_width(text)
      # Most strings have no SGR; the cheap `includes?` byte scan skips the regex
      # (and the String it builds) unless an ESC is actually present.
      text = text.gsub SGR_REGEX, "" if text.includes? '\e'
      full_unicode? ? Unicode.display_width(text) : text.size
    end

    # Longest *suffix* of `text` whose display width fits within `cols` columns,
    # measured by grapheme cluster (wide characters count as 2; clusters are
    # never split).
    def tail_within(text : String, cols : Int) : String
      return "" if cols <= 0
      return text if str_width(text) <= cols
      text.byte_slice Unicode.trailing_byte_len(text, cols.to_i, true)
    end

    # Longest *prefix* of `text` whose display width fits within `cols` columns,
    # measured by grapheme cluster (wide characters count as 2; clusters are
    # never split). The head-side mirror of `#tail_within`, for truncating an
    # over-long line to fit an inner width without splitting a wide glyph.
    def head_within(text : String, cols : Int) : String
      return "" if cols <= 0
      return text if str_width(text) <= cols
      text.byte_slice 0, Unicode.leading_byte_len(text, cols.to_i, true)
    end

    # Returns `text` with its last grapheme cluster removed (e.g. a base +
    # combining mark, or a wide emoji, comes off as one unit) — grapheme-aware
    # backspace. Empty in, empty out.
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
    # `base` alone. Cheap pre-check letting the renderer skip cluster assembly for
    # the common lone-codepoint cell. Mirrors `#extend_grapheme`'s start
    # conditions exactly.
    def needs_cluster?(base : Char, nxt : Char?) : Bool
      # Fast rejection for the dominant plain-text path: every cluster-relevant
      # `base` *and* `nxt` is ≥ U+0300 — combining marks (the lowest cluster
      # extender) begin there, and ZWJ/variation selectors/skin tones/regional
      # indicators sit higher still. Two integer compares replace the `mark?`
      # Unicode-category binary searches per ASCII/Latin cell.
      #
      # The threshold on `nxt` must be U+0300, NOT U+200D (ZWJ): a base such as
      # `'e'` followed by a combining mark (e.g. U+0301, NFD "é") has
      # `nxt.ord == 0x301` — above 0x300 but far below 0x200D — so a 0x200D cut
      # fast-rejects that common base+mark cluster and the mark renders detached.
      return false if base.ord < 0x300 && (nxt.nil? || nxt.ord < 0x300)
      return true if base.mark?                        # a leading combining mark (zero-width; merges back)
      return true if Unicode.regional_indicator?(base) # regional indicator (flag pair)
      return false unless nxt
      # A following combining mark, ZWJ, variation selector, or skin-tone modifier
      # extends the cluster.
      Unicode.grapheme_extender?(nxt)
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
      if Unicode.regional_indicator?(base)
        if (c = content[ci]?) && Unicode.regional_indicator?(c)
          g << c
          ci += 1
        end
        return {g.to_s, ci}
      end

      while c = content[ci]?
        cp = c.ord
        if Unicode.grapheme_extender?(c)
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
    # `nil` if the bytes back to the `\e` aren't a valid `\e[[\d;]*m` run. `line[k]`
    # is O(k) for multibyte content, but the run is short and this only fires on a
    # candidate `'m'` within the ~10-char word-wrap lookback window.
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
      # Single forward walk via `Char::Reader`; a char-by-char scan would be O(n²),
      # since `String#[](Int)` is O(index) for multibyte content. `cp` tracks the
      # codepoint index of the reader's current char (what callers slice by);
      # `reader.pos` is the byte offset, used for grapheme segmentation.
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
        if full
          # Grapheme/East-Asian widths: segment the run's bytes as clusters. This
          # path must measure the whole run — presentation selectors like VS16/VS15
          # can flip a cluster's width, so a bounded window is not provably
          # byte-identical.
          run_byte_start = reader.pos
          run_cp_start = cp
          while reader.pos < bytesize && reader.current_char != '\e'
            reader.next_char; cp += 1
          end
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
          # One column per visible codepoint (legacy). Walk only until the column
          # budget is met rather than to the end of the run. Before reading the
          # char at codepoint index `c`, `cp == c`; after advancing, `cp == c + 1`.
          while reader.pos < bytesize && reader.current_char != '\e'
            reader.next_char
            cp += 1
            total += 1
            return cp if total == colwidth
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
    # reduces to the original no-wrap truncation. Used for horizontal scrolling
    # of non-wrapped content.
    protected def _hslice(line : String, from_col : Int32, width : Int32) : String
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
