module Crysterm
  module Mixin
    module TextEditing
      # Static word wrap, after Kate's "Static Word Wrap" (Settings → Editor
      # → Editing, "Wrap words at"): with a column set, a line that grows
      # past it as a character is typed is broken at the last space before
      # the column — or, when a word alone is longer than the column, at the
      # first space after it — and the rest is carried to a new line, which
      # starts with `#hard_wrap_prefix`: the line's indentation by default,
      # or whatever a subclass that knows its syntax hands back (a list
      # item's continuation, a quote's marker). The caret goes with the text
      # it was in; the keystroke and the wrap it caused are one undo step.
      #
      # Only typing wraps — a paste, `#value=` and a programmatic insert
      # leave long lines as they are, as Kate's setting does (its "Apply
      # Word Wrap" is the explicit reflow, which an application builds from
      # `#hard_wrap_prefix` and its own paragraph rules). Qt's text edits
      # have no such mode: their wrapping is visual, and so is
      # `#wrap_content` here. Nil, the default, turns it off.
      #
      # The column is counted in the units the caret's column is: codepoints,
      # with tabs expanded (`#expanded_width`).
      property hard_wrap_column : Int32? = nil

      # What the line carried over by a wrap of *line* starts with, or nil
      # to leave *line* alone (a subclass keeps its verbatim lines — a code
      # block's — unbroken that way). The default is the line's leading
      # whitespace, so an indented block stays indented.
      def hard_wrap_prefix(line : String) : String?
        line[0, line.size - line.lstrip(" \t").size]
      end

      # Whether *line* may be broken at the space at *index*, the text after
      # the spaces there going to the new line. Always, by default; a
      # subclass that knows its syntax declines a break that would give
      # the carried text a meaning of its own at a line's start (a Markdown
      # list marker), and the wrap breaks at an earlier space instead.
      def hard_wrap_breakable?(line : String, index : Int32) : Bool
        true
      end

      # Whether typing *c* on the caret's line may take it past the wrap
      # column — the typing path opens an undo group for the keystroke and
      # its wrap when it may. Cheap when no column is set, which is every
      # keystroke of an editor without one.
      private def hard_wrap_pending?(c : Char) : Bool
        column = @hard_wrap_column || return false
        return false if c == '\n'
        expanded_width(buf_slice(line_start_pos, line_end_pos)) >= column
      end

      # Breaks the caret's line while it runs past the wrap column (see the
      # property): the text from the break on goes to a new line after the
      # prefix, and the spaces around the break go. Returns whether the
      # buffer changed. Nothing happens without a column, on a line
      # `#hard_wrap_prefix` declines, or when no space can be broken at.
      private def hard_wrap_caret_line : Bool
        column = @hard_wrap_column || return false
        changed = false
        loop do
          start = line_start_pos
          line = buf_slice(start, line_end_pos)
          break unless expanded_width(line) > column
          prefix = hard_wrap_prefix(line) || break
          at = hard_wrap_break(line, column, prefix.size) || break
          # The head keeps no trailing spaces, the tail no leading ones; the
          # head is never cut shorter than the prefix.
          head_end = at
          while head_end > prefix.size && line[head_end - 1] == ' '
            head_end -= 1
          end
          tail_start = at
          while tail_start < line.size && line[tail_start] == ' '
            tail_start += 1
          end
          carried = "\n#{prefix}"
          cut_from = start + head_end
          cut_to = start + tail_start
          caret = @cursor_pos
          @goal_col = nil
          buf_delete(cut_from, cut_to)
          buf_insert(cut_from, carried)
          @cursor_pos =
            if caret >= cut_to
              caret - (cut_to - cut_from) + carried.size
            elsif caret > cut_from
              cut_from + carried.size
            else
              caret
            end
          changed = true
          # The carried text may itself be too long (a long prefix); the loop
          # goes on with the new line, which the caret is on when the typed
          # text was carried, and stops as soon as a line fits or cannot
          # break — so it ends.
          break unless caret >= cut_to
        end
        changed
      end

      # The index of the space in *line* to break at, or nil: the last space
      # past *prefix_size* with text before it (not the mere prefix) whose
      # head fits in *column*, else the first such space past the column —
      # of the spaces `#hard_wrap_breakable?` allows.
      private def hard_wrap_break(line : String, column : Int32, prefix_size : Int32) : Int32?
        best = nil
        first_after = nil
        i = prefix_size
        content = false
        line.each_char.skip(prefix_size).each do |ch|
          if ch == ' '
            if content && hard_wrap_breakable?(line, i)
              if expanded_width(line[0, i]) <= column
                best = i
              else
                first_after ||= i
              end
            end
          else
            content = true
          end
          i += 1
        end
        best || first_after
      end
    end
  end
end
