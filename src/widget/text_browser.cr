require "./textedit"

module Crysterm
  class Widget
    # A read-only rich-text viewer with link navigation (Qt `QTextBrowser <
    # QTextEdit`).
    #
    # Anchors in the document are enumerable via `#links`. While reading
    # (focused input), `Tab`/`Shift-Tab` cycle link focus (rendered inverse,
    # scrolled into view), `Enter` activates the focused link, and a mouse
    # click on a link activates it directly. Activation emits
    # `Event::AnchorClick` — and, when a `#loader` is set and `#open_links?`
    # is true, follows the link through `#source=`.
    #
    # Navigation history: `#source=` records every successful load;
    # `Backspace` / `#backward` and `#forward` move through it (Qt's
    # `backward()`/`forward()`). Loading is delegated to `#loader`, a
    # `String -> TextDocument?` — the toolkit has no resource system, so the
    # application decides what a URL means (Qt `loadResource` analog):
    #
    # ```
    # tb = Widget::TextBrowser.new parent: s, width: 60, height: 20
    # tb.loader = ->(url : String) { TextDocument.from_markdown(File.read(url)) }
    # tb.source = "README.md"
    # tb.on(Event::AnchorClick) { |e| Log.info { "followed #{e.url}" } }
    # ```
    class TextBrowser < TextEdit
      # A link found in the document: absolute position range + destination.
      record Link, from : Int32, to : Int32, url : String

      # Resolves a source URL to a document (Qt `loadResource` analog).
      # Without one, `#source=` and link-following do nothing beyond the
      # `AnchorClick` event.
      property loader : Proc(String, TextDocument?)?

      # Whether activating a link follows it via `#source=` (Qt
      # `openLinks`). The `AnchorClick` event is emitted either way.
      property? open_links = true

      getter source : String?

      @history = [] of String
      @future = [] of String
      @links = [] of Link
      @links_revision = -1
      @focused_link = -1
      @link_sel : ExtraSelection?

      def initialize(input_on_focus = false, read_only = true, document : TextDocument? = nil, **input)
        super(**input, input_on_focus: input_on_focus, read_only: read_only, document: document)

        # Pointer activation: a plain click on an anchor follows it. Not
        # `#accept`ed, so click-to-focus still works. `text_hit?` must gate
        # first: `position_at` *clamps* and `anchor_at` resolves a line-end
        # position to the preceding char's format, so without the exact
        # hit-test a click on empty space would activate a trailing link.
        on(Crysterm::Event::Mouse) do |e|
          if e.action.down? && (window?.try(&.click_count) || 1) == 1
            if text_hit?(e.x, e.y) && (url = anchor_at(position_at(e.x, e.y)))
              activate_link url
            end
          end
        end
      end

      # Links of the current document, in document order (anchors spanning
      # several fragments coalesce; per block).
      def links : Array(Link)
        refresh_links if @links_revision != @doc_revision
        @links
      end

      # The 0-based index of the keyboard-focused link, -1 for none.
      getter focused_link : Int32

      # Emits `Event::AnchorClick` for *url* and — with `#open_links?` and a
      # `#loader` — navigates to it.
      def activate_link(url : String) : Nil
        emit Crysterm::Event::AnchorClick, url
        self.source = url if open_links? && @loader
      end

      # Navigates to *url*: loads it through `#loader`, replaces the
      # document, records history and emits `Event::SourceChanged`. A URL the
      # loader declines (nil) leaves everything unchanged.
      def source=(url : String?) : String?
        return @source = nil if url.nil?
        return url if url == @source
        doc = @loader.try(&.call(url)) || return url
        @source.try { |s| @history << s }
        @future.clear
        show_document(doc, url)
        url
      end

      def backward_available? : Bool
        !@history.empty?
      end

      def forward_available? : Bool
        !@future.empty?
      end

      # Navigates one step back in the visited-source history (Qt
      # `backward()`; the `Backspace` key). Returns whether it moved.
      def backward : Bool
        url = @history.last? || return false
        doc = @loader.try(&.call(url)) || return false
        @history.pop
        @source.try { |s| @future << s }
        show_document(doc, url)
        true
      end

      # Inverse of `#backward`. Returns whether it moved.
      def forward : Bool
        url = @future.last? || return false
        doc = @loader.try(&.call(url)) || return false
        @future.pop
        @source.try { |s| @history << s }
        show_document(doc, url)
        true
      end

      # Moves keyboard link focus by *dir* (±1), wrapping, highlighting the
      # link and scrolling it into view. False when the document has no links.
      def focus_link(dir : Int32) : Bool
        ls = links
        return false if ls.empty?
        @focused_link =
          if @focused_link < 0
            dir > 0 ? 0 : ls.size - 1
          else
            (@focused_link + dir) % ls.size
          end
        l = ls[@focused_link]
        @cursor_pos = l.from
        clear_selection
        ensure_cursor_visible
        update_link_highlight
        true
      end

      # Moves keyboard link focus to the next link (wrapping). False when the
      # document has no links.
      def focus_next_link : Bool
        focus_link(1)
      end

      # Moves keyboard link focus to the previous link (wrapping). False when the
      # document has no links.
      def focus_previous_link : Bool
        focus_link(-1)
      end

      # Browser keys: `Tab`/`Shift-Tab` cycle links, `Enter` activates the
      # focused one, `Backspace` goes back.
      def _listener(e)
        if k = e.key
          case k
          when Tput::Key::Tab
            e.accept
            return focus_link(1)
          when Tput::Key::ShiftTab
            e.accept
            return focus_link(-1)
          when Tput::Key::Enter
            if @focused_link >= 0 && (l = links[@focused_link]?)
              e.accept
              return activate_link(l.url)
            end
          when Tput::Key::Backspace, Tput::Key::CtrlH
            e.accept
            return backward
          end
        end
        super
      end

      def document=(doc : TextDocument)
        drop_link_focus
        super
      end

      # Whether the absolute screen point (*x*, *y*) lands exactly on a
      # display row's text — `#position_at`'s coordinate math but *without* its
      # clamping: a click below the last display row, on a margin row, left of
      # the text, or at/past the row's text end is a miss.
      private def text_hit?(x : Int32, y : Int32) : Bool
        lpos = coords
        return false unless lpos

        max_line = max_content_row(lpos)
        row = y - lpos.yi - itop
        return false if row < 0 || row > max_line

        rl = row + @child_base
        return false if rl < 0 || rl >= @_clines.size
        return false if @row_meta[rl]?.try(&.margin)

        col = x - lpos.xi - ileft - row_text_x_offset(rl)
        return false if col < 0

        # `@_clines[rl]` is the painted row text (already tab-expanded, and in
        # non-wrap mode already horizontally sliced to the viewport), so its
        # display width is exactly the painted run the click must fall inside.
        text = @_clines[rl]? || ""
        col < str_width(text)
      end

      # The URL under document position *pos*, or nil. Resolved block-local,
      # so a click past a line's end can't pick up the *next* block's
      # leading anchor.
      private def anchor_at(pos : Int32) : String?
        doc = document
        bi, off = doc.block_at(pos)
        b = doc.blocks[bi]
        if off < b.size
          b.char_format_at(off + 1).anchor_href
        elsif off > 0
          b.char_format_at(off).anchor_href
        end
      end

      private def show_document(doc : TextDocument, url : String) : Nil
        drop_link_focus
        self.document = doc
        @source = url
        emit Crysterm::Event::SourceChanged, url
      end

      private def drop_link_focus : Nil
        @focused_link = -1
        @link_sel.try { |sel| @extra_selections.delete(sel) }
        @link_sel = nil
      end

      # Replaces the internal focused-link `ExtraSelection` (inverse video).
      private def update_link_highlight : Nil
        @link_sel.try { |sel| @extra_selections.delete(sel) }
        @link_sel = nil
        if l = links[@focused_link]?
          c = TextCursor.new(document, l.from)
          c.set_position(l.to, :keep_anchor)
          sel = ExtraSelection.new(c, TextCharFormat.new(inverse: true))
          @link_sel = sel
          @extra_selections << sel
        end
        mark_dirty
        request_render if window?
      end

      private def refresh_links : Nil
        @links_revision = @doc_revision
        @links = [] of Link
        pos = 0
        document.blocks.each do |b|
          open_url = nil
          start = 0
          acc = 0
          b.fragments.each do |f|
            url = f.format.anchor_href
            if url != open_url
              if ou = open_url
                @links << Link.new(pos + start, pos + acc, ou)
              end
              open_url = url
              start = acc
            end
            acc += f.size
          end
          if ou = open_url
            @links << Link.new(pos + start, pos + acc, ou)
          end
          pos += b.size + 1
        end
        @focused_link = -1 if @focused_link >= @links.size
      end
    end
  end
end
