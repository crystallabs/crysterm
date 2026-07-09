require "./textedit"

module Crysterm
  class Widget
    # A read-only rich-text viewer with link navigation (Qt `QTextBrowser <
    # QTextEdit`; TEXTEDIT.md Phase 4).
    #
    # Anchors in the document are enumerable via `#links`. While reading
    # (focused input), `Tab`/`Shift-Tab` cycle link focus (rendered inverse,
    # scrolled into view), `Enter` activates the focused link, and a mouse
    # click on a link activates it directly. Activation emits
    # `Event::AnchorClick` — and, when a `#loader` is set and `#open_links?`
    # is true, follows the link through `#source=`.
    #
    # Navigation history: `#source=` records every successful load;
    # `Backspace` / `#back` and `#forward` move through it (Qt's
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

        # Pointer activation: a plain click on an anchor follows it. Runs
        # after the shared caret/selection mouse handler; not `#accept`ed, so
        # click-to-focus still works.
        on(Crysterm::Event::Mouse) do |e|
          if e.action.down? && (window?.try(&.click_count) || 1) == 1
            if url = anchor_at(position_at(e.x, e.y))
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
      # document, records history and emits `Event::SourceChange`. A URL the
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

      def back_available? : Bool
        !@history.empty?
      end

      def forward_available? : Bool
        !@future.empty?
      end

      # Navigates one step back in the visited-source history (Qt
      # `backward()`; the `Backspace` key). Returns whether it moved.
      def back : Bool
        url = @history.pop? || return false
        doc = @loader.try(&.call(url)) || return false
        @source.try { |s| @future << s }
        show_document(doc, url)
        true
      end

      # Inverse of `#back`. Returns whether it moved.
      def forward : Bool
        url = @future.pop? || return false
        doc = @loader.try(&.call(url)) || return false
        @source.try { |s| @history << s }
        show_document(doc, url)
        true
      end

      # Moves keyboard link focus by *dir* (±1), wrapping, highlighting the
      # link and scrolling it into view. False when the document has no links.
      def focus_link(dir : Int32) : Bool
        ls = links
        return false if ls.empty?
        @focused_link = (@focused_link + dir) % ls.size
        l = ls[@focused_link]
        @cursor_pos = l.from
        clear_selection
        ensure_cursor_visible
        update_link_highlight
        true
      end

      # Browser keys on top of the shared (read-only) editing keys:
      # `Tab`/`Shift-Tab` cycle links, `Enter` activates the focused one,
      # `Backspace` goes back.
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
            if l = links[@focused_link]?
              e.accept
              return activate_link(l.url)
            end
          when Tput::Key::Backspace, Tput::Key::CtrlH
            e.accept
            return back
          end
        end
        super
      end

      def document=(doc : TextDocument)
        drop_link_focus
        super
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
        emit Crysterm::Event::SourceChange, url
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
