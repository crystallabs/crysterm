module Crysterm
  class Widget
    # Convenience regex for matching Crysterm tags and their content (i.e. '{bold}This text is bold{/bold}').
    # An alias of the canonical `TextTags::TAG_REGEX` (the document framework
    # owns it, so `text/` can stand alone; widgets already require text/) —
    # referenced, not duplicated, so the two cannot drift (R-75).
    TAG_REGEX = TextTags::TAG_REGEX

    # Convenience regex for matching line-alignment tags (`{center}`, `{/right}`, ...).
    ALIGN_TAG_REGEX = /\{\/?(?:left|center|right)\}/

    # Convenience regex for matching SGR sequences — an alias of the canonical
    # grammar constant in `Crysterm::SGR` (kept here because the name is
    # long-standing public Widget API).
    SGR_REGEX = ::Crysterm::SGR::REGEX

    # :ditto:
    SGR_REGEX_AT_BEGINNING = /^#{SGR_REGEX}/

    # Logical-line boundaries of RAW content: the same separators
    # `clean_content_chars` normalizes to `\n` (`\r\n` and bare `\r` included),
    # so splitting raw text on this stays index-for-index aligned with the
    # parsed `@_clines.fake` lines. See `#raw_fake_lines`.
    RAW_LINE_REGEX = /\r\n|\r|\n/

    # Can element's content be word-wrapped?
    property? wrap_content = true

    # Is element's content to be parsed for tags?
    property? parse_tags = false

    # Alignment of contained text. (The `align`-consuming reads live in
    # `widget_content_wrap.cr`, after the content-file split.)
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
      # describing the PREVIOUS content. The line editors
      # (`insert_line`/`delete_line`/`replace_line`/... and their index math)
      # trust `fake` unconditionally, so a stale copy would desync them from the
      # raw lines they splice (see `#raw_fake_lines`) and resurrect the old
      # text. Resync `fake` to the new raw lines (split at the same boundaries
      # `raw_fake_lines` uses, so the two stay index-aligned) and drop the line
      # maps — the "content seeded before attach" shape the editors already
      # handle. `content_version` is deliberately left stale so the
      # `Event::Attached` reparse still fires. During a line editor's
      # `rebuild_content_from_raw` this is an identity resync (fake is
      # re-derived from the raw lines the editor just spliced).
      if window?.nil?
        @_clines.fake.clear
        @_clines.fake.concat(content.split(RAW_LINE_REGEX)) unless content.empty?
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
  end
end
