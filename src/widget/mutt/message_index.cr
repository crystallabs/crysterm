require "../record_list"

module Crysterm
  class Widget
    module Mutt
      # A single message row in the `MessageIndex`.
      class Message
        # Sender display name.
        property from : String

        # Subject line.
        property subject : String

        # Short date string (e.g. `"Jun 20"`).
        property date : String

        # Size, in bytes.
        property size : Int32

        # Status flags shown in the `%Z` column, e.g. `"N"` (new), `"D"`
        # (deleted), `"r"` (replied), `"*"` (flagged), `"!"` (important).
        property status : String

        # Threading depth: 0 for a thread root, 1 for a direct reply, etc. Drives
        # the tree glyphs drawn before the subject.
        property depth : Int32

        # Whether the message is unread.
        property? unread : Bool

        # Action invoked when the message is activated (Enter / click).
        property callback : Proc(Nil)?

        def initialize(@from, @subject, *, @date = "", @size = 0, @status = "", @depth = 0, @unread = false, @callback = nil)
        end

        # Block form: `Message.new(from, subject, ...) { ... }`.
        def initialize(from, subject, *, date = "", size = 0, status = "", depth = 0, unread = false, &callback : ->)
          initialize(from, subject, date: date, size: size, status: status, depth: depth, unread: unread, callback: callback)
        end
      end

      # Mutt's **message index**, the threaded counterpart to Pine's flat
      # `MessageIndex`. It draws the ASCII/Unicode **thread tree** before each
      # subject, computed from each message's `depth`:
      #
      # ```
      #    1 N Jun 18  Alpine Team        (1.2K) Welcome to Mutt!
      #    2   Jun 19  John Smith         (5.5K) Project update
      #    3 r Jun 19  Jane Doe           ( 842) ├─>Re: Project update
      #    4   Jun 20  John Smith         (1.1K) │ └─>Re: Project update
      #    5   Jun 21  Crystal Weekly     (8.7K) └─>Macros deep-dive
      # ```
      #
      # The selected row is drawn reverse. Navigate with the arrow keys; Enter
      # activates the message (runs its `callback` and emits `Event::ItemActivated`).
      class MessageIndex < ::Crysterm::Widget::Pine::SelectableList(Message)
        # Nested-name alias for the record type.
        alias Message = ::Crysterm::Widget::Mutt::Message

        # Thread-tree glyphs (Mutt's `$ascii_chars` off), declared with `Macros`'
        # `pinnable_registry_glyph`: each falls back to the central `Glyphs`
        # registry at this widget's `#glyph_tier` unless explicitly set, so
        # `Glyphs.set`/an ASCII glyph tier retunes the tree toolkit-wide while an
        # assignment pins one for a custom look, e.g.
        # `tree_vline = "| "; tree_tee = "|-"; tree_corner = "\`-"`.
        #
        # This one is the continuation line before an ancestor column that still
        # has a later sibling, plus the one-column gap after it (registry
        # `LineVertical`).
        pinnable_registry_glyph tree_vline, type: String,
          fallback: "#{glyph(Glyphs::Role::LineVertical)} "

        # Blank ancestor column (no further sibling at that level below).
        pinnable_registry_glyph tree_gap, type: String, fallback: "  "

        # A reply with a later sibling at the same depth (registry
        # `JunctionTeeLeft` + `LineHorizontal`).
        pinnable_registry_glyph tree_tee, type: String,
          fallback: "#{glyph(Glyphs::Role::JunctionTeeLeft)}#{glyph(Glyphs::Role::LineHorizontal)}"

        # The last reply at its depth (registry `BorderLineBL` — the same
        # square-corner glyph a `Solid` border draws — + `LineHorizontal`).
        pinnable_registry_glyph tree_corner, type: String,
          fallback: "#{glyph(Glyphs::Role::BorderLineBL)}#{glyph(Glyphs::Role::LineHorizontal)}"

        # Points from the tee/corner at the reply's subject (registry `ArrowRight`).
        pinnable_registry_glyph tree_arrow, ArrowRight, type: String

        def initialize(
          messages : Array(Message) = [] of Message,
          **list,
        )
          super messages, **list
        end

        record_accessors messages, message, Message

        # Formats one message into a fixed-column row with a thread-tree prefix.
        def format_row(item : Message, index : Int32) : String
          String.build do |s|
            s << (index + 1).to_s.rjust(4)
            s << ' '
            s << (item.status.presence || (item.unread? ? "N" : " ")).ljust(2)
            s << ' '
            s << item.date.ljust(6)
            s << "  "
            s << Mutt.truncate(item.from, 16).ljust(16)
            s << " ("
            s << Mutt.human_size(item.size).rjust(5)
            s << ") "
            s << thread_prefix(index)
            s << item.subject
          end
        end

        # The thread-tree prefix of every row, precomputed by `#rows` in one
        # reverse pass and reused by `#thread_prefix` (which would otherwise scan
        # forward to the end of the list once per ancestor level of every row).
        # Rebuilt — hence invalidated — on each `#records=`, which is the only
        # thing that (re)builds the rows.
        @thread_prefixes : Array(String)? = nil

        # Precomputes the thread-tree prefixes for *data* before the per-row
        # `#format_row` pass reads them back.
        protected def rows(data : Array(Message)) : Array(String)
          @thread_prefixes = build_thread_prefixes data
          super
        end

        # Builds every row's thread prefix in a single pass from the *last* message
        # backwards, replacing the two forward scans `#thread_prefix` used to run
        # per ancestor level (O(n²·depth) for the whole list, O(n + depth changes)
        # here).
        #
        # Both scans answer the same question — "is the first later message at a
        # depth ≤ *L* exactly at depth *L*?" — with opposite polarity:
        # `#ancestor_continues?` returns that predicate, `#last_at_level?` returns
        # its negation. So one `active` bitmap suffices: walking `j` downwards,
        # `active[L]` holds that predicate for row `j`, i.e. it is computed over
        # rows `j+1..n-1` only. Stepping from `j` to `j-1` folds row `j` (at depth
        # `dj`) in: for `L < dj` row `j` is skipped by both scans, so the entry is
        # unchanged; for `L == dj` the scan now stops there with `dj == L`, so it
        # becomes true; for `L > dj` it stops there with `dj < L`, so it becomes
        # false. `top` bounds the clearing loop (everything above it is already
        # false), so the whole pass stays amortized rather than O(n·max_depth).
        private def build_thread_prefixes(data : Array(Message)) : Array(String)
          prefixes = Array(String).new(data.size, "")
          # Hoisted: the glyphs can't change mid-pass, and each getter is a
          # registry lookup plus (for the composed ones) a string build.
          vline, gap, tee, corner, arrow = tree_vline, tree_gap, tree_tee, tree_corner, tree_arrow

          active = [] of Bool
          top = -1 # highest level index that may still be true

          (data.size - 1).downto 0 do |j|
            dj = data[j].depth

            if dj > 0
              prefixes[j] = String.build do |s|
                # Ancestor columns: depth 1 .. dj-1.
                (1...dj).each do |level|
                  s << (active[level]? ? vline : gap)
                end
                # A later sibling at this depth draws a tee, else the corner that
                # closes the branch.
                s << (active[dj]? ? tee : corner)
                s << arrow
              end
            end

            ((dj + 1)..top).each { |l| active[l] = false }
            top = dj
            while active.size <= dj
              active << false
            end
            active[dj] = true
          end

          prefixes
        end

        # Builds the thread-tree prefix for the message at *index* from the depths
        # of the surrounding messages: a tee (`├─`), or a corner (`└─`) when it is
        # the last reply at its level, preceded by one continuation line (`│`) or
        # gap per ancestor level.
        #
        # Answered from the precomputed table when `#rows` filled one for the
        # current record set; the forward-scanning fallback below covers a direct
        # `#format_row` call outside a `#rows` pass.
        private def thread_prefix(index : Int32) : String
          if (p = @thread_prefixes) && p.size == records.size && (cached = p[index]?)
            return cached
          end
          d = records[index].depth
          return "" if d <= 0
          String.build do |s|
            # Ancestor columns: depth 1 .. d-1.
            (1...d).each do |level|
              s << (ancestor_continues?(index, level) ? tree_vline : tree_gap)
            end
            s << (last_at_level?(index, d) ? tree_corner : tree_tee)
            s << tree_arrow
          end
        end

        # Whether the message at *index* is the last one in its sibling group at
        # *depth*, i.e. no later message sits at `depth` before the thread pops
        # back out to a shallower level.
        private def last_at_level?(index : Int32, depth : Int32) : Bool
          (index + 1...records.size).each do |j|
            dj = records[j].depth
            return true if dj < depth
            return false if dj == depth
          end
          true
        end

        # Whether the ancestor branch at *level* has a further sibling below
        # *index*, so its vertical connector continues.
        private def ancestor_continues?(index : Int32, level : Int32) : Bool
          (index + 1...records.size).each do |j|
            dj = records[j].depth
            return false if dj < level
            return true if dj == level
          end
          false
        end
      end
    end
  end
end
