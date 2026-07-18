require "./buffer"

module Crysterm
  module Mixin
    module TextEditing
      # Flat-`String` implementation of the `Buffer` protocol: the whole
      # document is one `String` (`@value`); positions are codepoint indices
      # into it. Include it alongside `Mixin::TextEditing` for plain-text
      # storage; rich text wants a `TextDocument`-backed adapter instead.
      module FlatBuffer
        include Buffer

        # `getter` (not `property`): a generated `value=(String)` setter would be
        # more specific than the custom `value=` below and win overload
        # resolution for String args, bypassing set_content/_update_cursor.
        getter value : String = ""
        @_value = ""

        def buf_text : String
          @value
        end

        def buf_size : Int32
          @value.size
        end

        def buf_char(i : Int32) : Char
          @value[i]
        end

        def buf_slice(from : Int32, to : Int32) : String
          @value[from...to]
        end

        def buf_insert(pos : Int32, str : String) : Nil
          @value = @value[0...pos] + str + @value[pos..]
        end

        def buf_delete(from : Int32, to : Int32) : Nil
          @value = @value[0...from] + @value[to..]
        end

        def buf_index(ch : Char, from : Int32) : Int32?
          @value.index(ch, from)
        end

        def buf_rindex(ch : Char, from : Int32) : Int32?
          @value.rindex(ch, from)
        end

        # Seeds the text buffer from the constructor args, parking the cursor at the
        # end. Call from `initialize` *before* `super` — value must exist before
        # the base lays out its content.
        private def setup_text_buffer(content : String, max_length, read_only) : Nil
          @max_length = max_length
          @read_only = read_only
          @value = content
          @cursor_pos = @value.size
        end

        # Cached logical-line-start offsets into `@value`, plus the exact `@value`
        # object they were computed for. `@_line_offsets[k]` is the codepoint index
        # where fake line *k* begins: `[0, first_nl+1, second_nl+1, …]`, always at
        # least `[0]`. Rebuilt lazily by `#line_offsets`.
        @_line_offsets = [0]
        @_line_offsets_value : String? = nil

        # Line-start offsets for the current `@value`, rebuilding the cache only
        # when `@value` is a different object than last time. Keyed on String
        # *identity* (`same?`), not `@_content_version`: Strings are immutable and
        # every edit reassigns `@value`, so a fresh object always means fresh
        # newlines. `@_content_version` would be stale here — it only bumps on the
        # later `set_content` at render time, after a keystroke has already mutated
        # `@value` and callers like `#pos_from_rowcol` may have run.
        private def line_offsets : Array(Int32)
          cached = @_line_offsets_value
          return @_line_offsets if cached && cached.same?(@value)
          offsets = [0]
          @value.each_char_with_index do |ch, i|
            offsets << i + 1 if ch == '\n'
          end
          @_line_offsets = offsets
          @_line_offsets_value = @value
          offsets
        end

        # `@_clines.fake` is TAB-expanded, so its codepoint sizes can't index raw
        # `@value`; this reads the cached newline offsets instead. `base` is the
        # line's start, `line_end` the following `\n` (or `@value.size` for the
        # last line).
        def buf_line_bounds(fake_line : Int32) : Tuple(Int32, Int32)
          starts = line_offsets
          k = fake_line.clamp(0, starts.size - 1)
          base = starts[k]
          line_end = k + 1 < starts.size ? starts[k + 1] - 1 : @value.size
          {base, line_end}
        end

        # Records `value` as the authoritative content and repositions the caret.
        # A non-nil `value` is an external set: record it, cursor to the end, and
        # drop any selection the new content invalidates. `nil` is a redisplay
        # (e.g. from `render`): keep the cursor where it is, clamped in case the
        # content changed underneath. The block normalizes the resolved value
        # before storing it — the multi-line editor keeps newlines, `LineEdit`
        # strips them. Returns whether this was an external set.
        #
        # Stores the authoritative value *before* the caller's display dedup
        # guard, so an external set (e.g. clearing) is never lost when the
        # last-displayed cache is stale.
        protected def assign_value(value : String?, & : String -> String) : Bool
          external = !value.nil?
          before = @value
          @value = yield(value || @value)
          @cursor_pos = external ? @value.size : @cursor_pos.clamp(0, @value.size)
          clear_selection if external
          # An external set moves the caret to the end; drop the vertical goal
          # column so the next Up/Down tracks the caret's actual column. The
          # redisplay path (`nil` value) must leave `@goal_col` intact so an
          # in-progress Up/Down sequence survives a `render`.
          @goal_col = nil if external

          # A programmatic set notifies too, like Qt's `QLineEdit::textChanged`
          # firing on `setText`. Only the external branch emits: interactive edits
          # emit from `#_listener`, and the `nil` redisplay path isn't a change at
          # all — the guard short-circuits before the `String` compare on that hot
          # path. Emitted last, so handlers observe the settled caret and
          # selection.
          emit ::Crysterm::Event::TextChanged, @value if external && @value != before

          external
        end

        # External set: records *value* and parks the caret at the end.
        def value=(value : String)
          apply_value value
        end

        # Once-per-frame redisplay (from `#render`): re-syncs the display with the
        # caret preserved, without treating it as an external set.
        def refresh_value : Nil
          apply_value nil
        end

        # Shared body for `#value=`/`#refresh_value`.
        private def apply_value(value : String?) : Nil
          external = assign_value(value) { |v| v }
          if @_value == @value
            # A same-string external set still moved the caret (`assign_value`
            # parked it at the end and dropped the selection): follow it on
            # screen even though the displayed content needs no update.
            if external
              _type_scroll
              _update_cursor
            end
            return
          end

          @_value = @value
          set_content @value
          _type_scroll
          _update_cursor
        end
      end
    end
  end
end
