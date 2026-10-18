module Crysterm
  class Widget
    class TextEdit
      # === Editing keys ===

      # Adds undo/redo on top of the shared editing keys: `C-z` undo, `M-z`
      # redo (`C-S-z` is indistinguishable from `C-z` on most terminals, and the
      # emacs default `C-y` stays yank) — plus the standard
      # Qt list-editing behaviors: Enter on an empty list item and Backspace
      # at an item's start take the block out of the list instead of
      # splitting/joining blocks, and typing a list marker auto-formats when
      # `#auto_formatting` enables it.
      def _listener(e)
        return if handle_undo_redo_key(e)

        # Table-aware routing: cell editing/navigation inside a table, and
        # the guards that keep outside edits from tearing the box rendering.
        return if !read_only? && table_guard(e)

        if !read_only? && (k = e.key)
          # Enter on an EMPTY list item exits the list (Qt: a return on an
          # empty item outdents it) rather than opening another empty item;
          # Backspace at the start of an item removes its bullet rather than
          # joining it into the previous block. Both are plain block-format
          # changes — one undo step, text untouched.
          empty_item_exit = k == Tput::Key::Enter && caret_block_empty_list_item?
          if !selection? && (empty_item_exit ||
             ((k == Tput::Key::Backspace || k == Tput::Key::CtrlH) && caret_at_list_item_start?))
            e.accept
            kill_ring.interrupt if Crysterm::Config.input_readline_keys
            clear_caret_list_membership
            _update_cursor
            return
          end
        end
        super
        auto_format_list(e) if !read_only? && !@auto_formatting.none?
      end

      # Whether the caret's block is an empty list item.
      private def caret_block_empty_list_item? : Bool
        loc = document.block_at(@cursor_pos)
        bi = loc.index
        blk = document.blocks[bi]
        blk.size == 0 && !blk.block_format.list_format.nil?
      end

      # Whether the caret sits at the very start of a list item's text.
      private def caret_at_list_item_start? : Bool
        loc = document.block_at(@cursor_pos)
        bi = loc.index
        off = loc.offset
        off == 0 && !document.blocks[bi].block_format.list_format.nil?
      end

      # Takes the caret's block out of its list (undoable); other block
      # formatting stays. The document change drives relayout/repaint.
      private def clear_caret_list_membership : Nil
        loc = document.block_at(@cursor_pos)
        bi = loc.index
        blk = document.blocks[bi]
        pos = document.block_position(bi)
        document.apply_block_format(pos, pos, blk.block_format.with_list_format(nil))
      end

      # The `#auto_formatting` hook, run after the shared key handling
      # inserted the typed character: a space completing a list marker at
      # the start of a plain block converts the block into a fresh
      # single-item list. Marker removal + list format are one edit block,
      # so a single undo restores the typed marker text.
      private def auto_format_list(e) : Nil
        return unless e.char == ' ' && e.key.nil?
        loc = document.block_at(@cursor_pos)
        bi = loc.index
        off = loc.offset
        return if off < 2
        blk = document.blocks[bi]
        bf = blk.block_format
        return if bf.list_format || bf.table_format || bf.horizontal_rule?
        prefix = blk.text[0, off]
        lf =
          if @auto_formatting.bullet_list? && prefix.matches?(/\A[-*+] \z/)
            TextListFormat.new(style: :disc)
          elsif @auto_formatting.numbered_list? && (m = prefix.match(/\A(\d{1,4})([.)]) \z/))
            TextListFormat.new(style: :decimal, start: m[1].to_i, number_suffix: m[2])
          end
        return unless lf
        bp = document.block_position(bi)
        # Removing the marker pulls this view's caret back to the block
        # start via the shared caret follow (`follow_document_change` — a
        # direct document edit, not a `buf_*` self-edit); the change is told
        # of below (`#reporting_edit`).
        reporting_edit do
          document.edit do
            document.remove(bp, off)
            document.apply_block_format(bp, bp, TextBlockFormat.new(list_format: lf), merge: true)
          end
        end
        emit_text_changed
        settle_caret
      end

      # === Table editing. A `TextTable` is pre-rendered box-drawing blocks, so
      # free editing would tear it; instead, editing keys inside a table become
      # cell operations that re-render the padding through the table's
      # undoable API (`TextTable#set_cell_text` & co.). ===

      # The set of keys that edit content (vs. motion/copy) — what the table
      # guards act on. `Tab`/`Enter` get table meanings; the kill/yank/
      # clipboard-write keys have none and are absorbed inside a table.
      private def table_editing_key?(k : Tput::Key) : Bool
        k.in?(Tput::Key::Backspace, Tput::Key::CtrlH, Tput::Key::Delete,
          Tput::Key::Enter, Tput::Key::Tab, Tput::Key::ShiftTab,
          Tput::Key::CtrlX, Tput::Key::CtrlV, Tput::Key::CtrlW,
          Tput::Key::CtrlU, Tput::Key::CtrlK, Tput::Key::AltD,
          Tput::Key::CtrlY)
      end

      # Table-aware key routing. When the caret sits in a table: typing,
      # Backspace and Delete edit the caret's cell (padding re-rendered, one
      # undo step per keystroke); Tab/Shift-Tab move between cells — Tab past
      # the last cell appends a row (Qt behavior); Enter inserts a row below;
      # cut/paste/kill/yank are absorbed. From outside: a selection
      # overlapping table blocks absorbs content edits (a partial-table
      # delete would corrupt the rendering), and Backspace/Delete at a
      # table's edge won't join a neighbor block into a border row. Motion,
      # copy and undo always pass through. Returns whether the key was
      # consumed.
      #
      # One flat guard on purpose: it is the single place the "does this key
      # touch a table?" rule lives, and splitting it would let the in-table and
      # at-the-edge cases drift apart.
      private def table_guard(e) : Bool
        k = e.key
        typing = k.nil? && (c0 = e.char) && !Mixin::TextEditing.control_char?(c0)
        return false unless typing || (k && table_editing_key?(k))

        tbl = caret_table
        if tbl.nil?
          if selection?
            return false unless selection_touches_table?
            e.accept
            kill_ring.interrupt if Crysterm::Config.input_readline_keys
            return true
          end
          # Boundary: joining a neighbor block into a border row is blocked.
          loc = document.block_at(@cursor_pos)
          bi = loc.index
          off = loc.offset
          if (k == Tput::Key::Backspace || k == Tput::Key::CtrlH) && off == 0 && bi > 0 &&
             document.blocks[bi - 1].block_format.table_format
            e.accept
            return true
          end
          if k == Tput::Key::Delete && off == document.blocks[bi].size &&
             document.blocks[bi + 1]?.try(&.block_format.table_format)
            e.accept
            return true
          end
          return false
        end

        e.accept
        kill_ring.interrupt if Crysterm::Config.input_readline_keys
        # A selection inside/into a table: content edits are absorbed (copy
        # via C-c still passes — it is not an editing key).
        return true if selection?

        info = tbl.cell_at(@cursor_pos)
        # The snapshot only gates the emit — the repaint below always runs —
        # so skip both serializations when nothing observes the event.
        before = text_change_observed? ? buf_text : nil
        # The cell edits go through the table, not `buf_*`: told of below.
        reporting_edit do
          case k
          when Tput::Key::Tab      then table_tab(tbl, info, 1)
          when Tput::Key::ShiftTab then table_tab(tbl, info, -1)
          when Tput::Key::Enter    then table_insert_row_below(tbl, info)
          when Tput::Key::Backspace, Tput::Key::CtrlH
            table_delete_char(tbl, info, backward: true)
          when Tput::Key::Delete
            table_delete_char(tbl, info, backward: false)
          when nil
            if c = e.char
              c == '\t' ? table_tab(tbl, info, 1) : table_type_char(tbl, info, c)
            end
          else
            # Kill/yank/cut/paste inside a table: absorbed.
          end
        end
        report_text_change before
        settle_caret
        true
      end

      # The table the caret's block belongs to, or nil.
      private def caret_table : TextTable?
        loc = document.block_at(@cursor_pos)
        bi = loc.index
        tf = document.blocks[bi].block_format.table_format || return
        TextTable.new(document, tf)
      end

      # Whether the live selection overlaps any table block.
      private def selection_touches_table? : Bool
        r = selection_range || return false
        b1 = document.block_at(r.begin).index
        b2 = document.block_at(r.end).index
        (b1..b2).any? { |i| !document.blocks[i].block_format.table_format.nil? }
      end

      # Moves the caret *dir* cells (±1) via `TextTable#next_cell`/
      # `#previous_cell`; Tab past the last cell appends a fresh row (Qt),
      # Shift-Tab before the first stays. From a border row (no cell), lands
      # on the first cell.
      private def table_tab(tbl : TextTable, info : {Int32, Int32}?, dir : Int32) : Nil
        unless info
          place_caret_in_cell(tbl, 0, 0, Int32::MAX)
          return
        end
        row, col = info
        if dir > 0
          if target = tbl.next_cell(row, col)
            row, col = target
          else
            row += 1
            tbl.insert_row(row)
            col = 0
          end
        else
          return unless target = tbl.previous_cell(row, col)
          row, col = target
        end
        place_caret_in_cell(tbl, row, col, Int32::MAX)
      end

      # Enter inside a cell: a fresh row below the caret's (below the header
      # when pressed there), caret to its first cell.
      private def table_insert_row_below(tbl : TextTable, info : {Int32, Int32}?) : Nil
        return unless info
        at = Math.max(info[0] + 1, 1)
        tbl.insert_row(at)
        place_caret_in_cell(tbl, at, 0, 0)
      end

      # Cell (*row*, *column*)'s text in *tbl* and the caret's offset in it,
      # or nil when the cell can't be resolved. A cell is addressed by text
      # offset, not by document range: a wrapped cell's text is spread over
      # the lines of its row (`TextTable#cell_offset`). The offset is always
      # safe to index the text with (see `#table_type_char`,
      # `#table_delete_char`, `#insert_text`).
      private def cell_text_and_offset(tbl : TextTable, row : Int32, col : Int32) : {String, Int32}?
        txt = tbl.cell_text(row, col) || return
        off = tbl.cell_offset(row, col, @cursor_pos) || return
        {txt, off.clamp(0, txt.size)}
      end

      # Types *c* into the caret's cell at the caret's offset.
      private def table_type_char(tbl : TextTable, info : {Int32, Int32}?, c : Char) : Nil
        return unless info
        row, col = info
        txt, off = cell_text_and_offset(tbl, row, col) || return
        tbl.set_cell_text(row, col, txt.insert(off, c))
        place_caret_in_cell(tbl, row, col, off + 1)
      end

      # Backspace/Delete within the caret's cell; a no-op at the cell's
      # start/end (cells never join).
      private def table_delete_char(tbl : TextTable, info : {Int32, Int32}?, backward : Bool) : Nil
        return unless info
        row, col = info
        txt, off = cell_text_and_offset(tbl, row, col) || return
        len = txt.size
        if backward
          return if off <= 0
          tbl.set_cell_text(row, col, txt[0, off - 1] + txt[off..])
          place_caret_in_cell(tbl, row, col, off - 1)
        else
          return if off >= len
          tbl.set_cell_text(row, col, txt[0, off] + txt[off + 1..])
          place_caret_in_cell(tbl, row, col, off)
        end
      end

      # Routes an insert into the caret's table cell through the cell API
      # instead of a free-form document insert, which would tear the
      # pre-rendered row (a paste — `Mixin::TextEditing`'s `Event::Paste`
      # handler calls `#insert_text` directly, bypassing `#table_guard`'s
      # key-only routing). A selection touching the table is absorbed
      # rather than replaced, matching typing's behavior in `#table_guard`.
      # Outside a table, or when the cell can't be resolved, this is the
      # shared insert.
      def insert_text(str : String) : Nil
        return if str.empty? && !selection?
        if tbl = caret_table
          return if selection? && selection_touches_table?
          if (info = tbl.cell_at(@cursor_pos)) && (to = cell_text_and_offset(tbl, *info))
            row, col = info
            txt, off = to
            before = text_change_observed? ? buf_text : nil
            clean = str.gsub(/\r\n?|\n/, ' ')
            reporting_edit { tbl.set_cell_text(row, col, txt.insert(off, clean)) }
            place_caret_in_cell(tbl, row, col, off + clean.size)
            report_text_change before
            settle_caret
            return
          end
        end
        super
      end

      # Parks the caret at *offset* within cell (*row*, *col*)'s text
      # (clamped — pass `Int32::MAX` for "end of cell").
      private def place_caret_in_cell(tbl : TextTable, row : Int32, col : Int32, offset : Int32) : Nil
        if pos = tbl.cell_position(row, col, offset)
          @cursor_pos = pos
        end
        clear_selection
        @goal_col = nil
        ensure_cursor_visible
      end
    end
  end
end
