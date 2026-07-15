module Crysterm
  module Mixin
    module TextEditing
      # The buffer protocol `Mixin::TextEditing`'s shared logic (navigation,
      # selection, kill ops, mouse mapping, caret math) runs against.
      # Positions are flat `Int32` codepoint indices into the buffer text,
      # `0..buf_size`, regardless of how the text is actually stored:
      # `FlatBuffer` keeps one `String`, while a document adapter maps flat
      # positions to `TextDocument` (block, offset) pairs and routes mutations
      # through a `TextCursor`, so formats survive edits and undo records them.
      #
      # Mutations (`buf_insert`/`buf_delete`) only change the text:
      # `Mixin::TextEditing` owns `@cursor_pos`/`@selection_anchor` and adjusts
      # them itself.
      #
      # An adapter must also provide the widget-facing `value=(String?)`
      # (external set / `nil` redisplay semantics — see `FlatBuffer#value=`),
      # which stays outside this protocol because its display half
      # (`set_content` vs. a document layout) is adapter-specific.
      module Buffer
        # The whole buffer as one flat `String` (logical lines joined with
        # `\n`). May be O(document) for a non-flat adapter — prefer the
        # finer-grained accessors below in per-keystroke paths.
        abstract def buf_text : String

        # Total codepoint count of the buffer text.
        abstract def buf_size : Int32

        # The codepoint at index *i* (`0 <= i < buf_size`).
        abstract def buf_char(i : Int32) : Char

        # The half-open codepoint range `[from, to)` as a `String`.
        abstract def buf_slice(from : Int32, to : Int32) : String

        # Inserts *str* before position *pos*, shifting the tail right.
        abstract def buf_insert(pos : Int32, str : String) : Nil

        # Removes the half-open codepoint range `[from, to)`.
        abstract def buf_delete(from : Int32, to : Int32) : Nil

        # Index of the first occurrence of *ch* at or after *from*, or `nil`.
        abstract def buf_index(ch : Char, from : Int32) : Int32?

        # Index of the last occurrence of *ch* at or before *from*, or `nil`.
        abstract def buf_rindex(ch : Char, from : Int32) : Int32?

        # The `{start, end}` positions (half-open) of fake (logical,
        # `\n`-delimited) line *fake_line*: `start` is the line's first
        # codepoint, `end` sits on the terminating `\n` (or `buf_size` for the
        # last line). A *fake_line* past the last line clamps to it.
        abstract def buf_line_bounds(fake_line : Int32) : Tuple(Int32, Int32)

        # The widget's authoritative text. Equal to `buf_text` in content; kept
        # separate because it is widget API, not buffer geometry.
        abstract def value : String

        # Groups the mutations made inside the block into one undoable step
        # (Qt edit-block semantics) — so typing over a selection
        # (delete + insert) undoes as a single action. Default pass-through:
        # a buffer without undo has nothing to group.
        def buf_edit_group(&)
          yield
        end

        # Copies `[from, to)` to *clipboard*. Default: plain text; a rich buffer
        # overrides to carry formats alongside. *window* routes the OSC-52 device
        # write to the copying widget's own terminal rather than the app-active
        # window's.
        def buf_copy_to_clipboard(clipboard : Application::Clipboard, from : Int32, to : Int32, window : Window? = nil) : Nil
          clipboard.set_text buf_slice(from, to), window
        end

        # Attempts to paste *clipboard*'s rich payload at the cursor,
        # replacing any selection. Returns false to make the caller fall back
        # to the plain-text paste path — the default for buffers that store
        # no formats (pasting into them degrades to `Clipboard#text`).
        def buf_paste_rich(clipboard : Application::Clipboard) : Bool
          false
        end
      end
    end
  end
end
