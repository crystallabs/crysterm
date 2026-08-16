module Crysterm
  class Widget
    # Whether the last `expand_tags` call ended with tag state still open (a
    # non-empty fg/bg/flag stack, or an unterminated `{escape}`). Scratch output
    # slot, meaningful only immediately after a call.
    @expand_tags_left_open = false

    # Convert `{red-fg}foo{/red-fg}` to `\e[31mfoo\e[39m`.
    #
    # The lexical layer is `TextTags.each_token` — the ONE tag tokenizer,
    # shared with the document importer (`TextTags::Parser`) so the two
    # grammars cannot drift; this method owns only the SGR emission state
    # machine over its tokens. Tokens with no SGR rendering degrade cleanly:
    # `{link=…}`/`{/link}` drop (keeping the link text), unknown names drop,
    # `{|}` and the alignment tags pass through verbatim for the
    # aligner/wrapper to consume afterwards.
    #
    # :nodoc: the tag->SGR expander (ex-`_parse_tags`); an internal stage of
    # `#process_content`, public only because the tag specs drive it directly.
    def expand_tags(text)
      @expand_tags_left_open = false
      return text unless @parse_tags
      # Attribute tags resolve through `window.tput`, so a detached widget can't
      # parse — return the text literal, mirroring `process_content`'s guard.
      # The raw line lands in `fake`; the `Event::Attached` reparse expands it.
      return text unless window?
      # Enter the parser whenever a brace is present (not only on a valid tag):
      # under the drop-malformed policy a stray `{`/`}` must be stripped too.
      return text unless text.includes?('{') || text.includes?('}')

      # Keep this O(n): `outbuf += ...` would rebuild the whole result per tag,
      # so a `String::Builder` (seeded near the input size, since tags expand
      # to SGR of comparable length) collects the output as the shared
      # tokenizer walks the input.
      outbuf = String::Builder.new text.bytesize
      bg = [] of String
      fg = [] of String
      flag = [] of String

      esc_open = TextTags.each_token(text) do |kind, value, slash|
        case kind
        in .text?
          outbuf << value
        in .bar?
          # `{|}` is Blessed's right-align separator, not an attribute tag:
          # text after it is pushed to the line's right edge. Must survive
          # parsing verbatim for the aligner to act on it.
          outbuf << "{|}"
        in .link?
          # `{link=…}` carries no SGR rendering; drop the tag so the link
          # text degrades to plain content (the matching `{/link}` closer is
          # an unrecognized attribute name and drops below).
        in .tag?
          if value == "left" || value == "center" || value == "right"
            # `{left}`/`{center}`/`{right}` (and `{/...}` closers) are line-
            # alignment tags, not attribute tags — no SGR, so the recognized-
            # attribute path below would drop them as unknown, silently
            # disabling `{center}…{/center}` alignment. They must survive
            # parsing verbatim (like `{|}` above) for the wrapper to consume
            # afterwards, opener and closer both.
            outbuf << '{'
            outbuf << '/' if slash
            outbuf << value
            outbuf << '}'
          else
            # A recognized `{tag}` / `{/tag}`: a known attribute name emits
            # its SGR (tracking nesting so a close restores the previous
            # state); an unrecognized tag is dropped (drop-malformed policy).
            # `Tput#_attr` returns "" for an unknown name, non-empty for
            # every known one, so `empty?` is the test.
            #
            # Tags are written dash-delimited (`{light-blue-fg}`) but the
            # downstream color/attribute name lookup keys on the
            # space-delimited form (`light blue fg`), so a dash is normalized
            # to a space here. Removable only if that resolver learned the
            # dash forms directly. Only `gsub` when a dash is present —
            # dash-free tags (`bold`, `red`) reuse the token's name with no
            # scan or allocation.
            param = value
            param = param.gsub('-', ' ') if param.includes?('-')

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
                if state.same?(flag)
                  # Attribute flags ACCUMULATE (bold+underline are active at
                  # once), so closing one must emit its OFF code — blessed's
                  # "restore prior" (re-emit the previous flag's ON code) leaves
                  # the closed flag set forever, leaking it into the rest of the
                  # content. The remaining open flags are then re-asserted: a
                  # no-op for unrelated ones, but it restores a same-flag outer
                  # nesting (`{bold}a{bold}b{/bold}c`) the OFF code just cleared.
                  outbuf << window.tput._attr(param, false)
                  state.each { |p| outbuf << window.tput._attr(p) }
                else
                  # Colors REPLACE rather than accumulate, so the previous stack
                  # entry (or the tag's off/default code on an empty stack) is
                  # the right restore target.
                  outbuf << (state.size > 0 ? window.tput._attr(state[-1]) : window.tput._attr(param, false))
                end
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
          end
        end
      end

      # Report whether the parse ended with tag state still open. `esc_open` is
      # true on the tokenizer's unterminated-`{escape}` bail — parser state a
      # continuation of this text would inherit, just like a non-empty stack.
      @expand_tags_left_open = esc_open || !(bg.empty? && fg.empty? && flag.empty?)

      outbuf.to_s
    end

    # Base attribute after scanning `line`'s inline SGR sequences starting from
    # `attr` — how SGR state carries line-to-line, so a `{red-fg}` left open on an
    # earlier line colors later ones too. `default_attr` is `style_to_attr(style)`, passed
    # in so callers compute it once.
    private def _attr_after(line : String, attr : Int64, default_attr : Int64) : Int64
      # Byte scan rather than an anchored `SGR_REGEX.match(line, i)` per `\e`:
      # that allocated a `Regex::MatchData` plus a substring per escape, and its
      # `pos` is a *char* index, re-walked from the string start on every call
      # for a non-ASCII line (O(n·k) for k escapes). `\e`, `[`, `;`, `m` and the
      # digits are all ASCII, so none can appear as a byte of a multi-byte
      # codepoint — the byte scan recognizes exactly `SGR_REGEX`'s
      # `\e\[[\d;]*m` (grammar held by `SGR.terminator`, shared with
      # `base_render`) and, like the regex form, silently skips an `\e` that
      # does not open a valid run.
      bytes = line.to_slice
      size = bytes.size
      i = 0
      while i < size
        if bytes.unsafe_fetch(i) == 0x1b_u8 && i + 1 < size && bytes.unsafe_fetch(i + 1) == 0x5b_u8
          if m = SGR.terminator(bytes, i + 2)
            # Parameters read straight out of the line's bytes as a zero-copy
            # sub-slice, so no bridging `"\e[…m"` `String` per sequence. The
            # conversion is pure (`Window` merely forwards to this class
            # method), so it needs no attached window.
            attr = SGR.params_to_attr(bytes[i + 2, m - i - 2], attr, default_attr)
            i = m + 1
            next
          end
        end
        i += 1
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

    # Escapes text for tag-enabled elements where one does not want the tags enclosed in {...} to be treated specially, but literally.
    #
    # Example to print literal "{bold}{/bold}":
    # '''
    # box.set_content("escaped content: " + Widget.escape_tags("{bold}{/bold}"))
    # '''
    def self.escape_tags(text : String) : String
      Crysterm::Formatting.escape_braces text
    end

    # Strips text of "{...}" tags and SGR sequences and removes leading/trailing whitespaces
    def strip_tags(text : String)
      clean_tags(text).strip
    end

    # Combined {...}-tag + SGR-sequence regex. Held as a constant so it compiles
    # once rather than on every `clean_tags` call: an interpolated `#{...}` regex,
    # unlike a regex literal, recompiles on each evaluation.
    CLEAN_TAGS_REGEX = /(?:#{Crysterm::Widget::TAG_REGEX.source})|(?:#{Crysterm::Widget::SGR_REGEX.source})/

    # Strips text of {...} tags and SGR sequences
    def clean_tags(text : String)
      text.gsub(CLEAN_TAGS_REGEX) do |_, _|
        # No replacement needed, just removing matches
      end
    end
  end
end
