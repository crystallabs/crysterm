module Crysterm
  class Widget
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
      # Attribute tags resolve through `window.tput`, so a detached widget can't
      # parse — return the text literal, mirroring `process_content`'s guard.
      # The raw line lands in `fake`; the `Event::Attached` reparse expands it.
      return text unless window?
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
            # Tags are written dash-delimited (`{light-blue-fg}`) but the
            # downstream color/attribute name lookup keys on the space-delimited
            # form (`light blue fg`), so a dash is normalized to a space here.
            # Removable only if that resolver learned the dash forms directly.
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
    def self.escape_tags(text)
      text.gsub(/[{}]/) do |ch|
        case ch
        when "{" then "{open}"
        when "}" then "{close}"
        end
      end
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
