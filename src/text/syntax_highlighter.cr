module Crysterm
  # Per-block syntax highlighting engine (Qt `QSyntaxHighlighter`). Subclass
  # and implement `#highlight_block`, calling `#set_format` for each span to
  # color; attach to a document via the constructor or `#document=`.
  #
  # Formats land in the block's `additional_formats` overlay — presentation
  # only, invisible to undo, plain-text and interchange output. The
  # highlighter re-runs for the blocks a document edit touches and cascades to
  # following blocks while their `#current_block_state` keeps changing (the
  # multi-line-construct protocol: store a state like "still inside a comment"
  # and read the previous block's via `#previous_block_state`).
  #
  # ```
  # class TodoHighlighter < Crysterm::SyntaxHighlighter
  #   def highlight_block(text)
  #     if i = text.index("TODO")
  #       set_format(i, 4, Crysterm::TextCharFormat.new(fg: "yellow", bold: true))
  #     end
  #   end
  # end
  #
  # TodoHighlighter.new(edit.document)
  # ```
  abstract class SyntaxHighlighter
    getter document : TextDocument?

    @ev_contents_change : ::EventHandler::Subscription?
    # Reentrancy guard: `#rehighlight` pokes the document's `ContentsChanged`
    # so views repaint — which must not re-enter the highlighter itself.
    @highlighting = false

    # Set during a `#highlight_block` call.
    @current_block : TextBlock?
    @current_index = 0
    @pending : Array({Int32, Int32, TextCharFormat})?

    def initialize(document : TextDocument? = nil)
      self.document = document if document
    end

    # Analyses one block's *text* and calls `#set_format` for the spans to
    # color. Called with the format state cleared; whatever it sets becomes
    # the block's whole overlay.
    abstract def highlight_block(text : String)

    # Attaches to *doc* (detaching from any previous document) and
    # highlights it whole. `nil` detaches.
    def document=(doc : TextDocument?) : TextDocument?
      if old = @document
        @ev_contents_change.try &.off
        @ev_contents_change = nil
        # Drop this highlighter's overlays and user states so the old document
        # renders plain again and a later highlighter starts from clean
        # `previous_block_state`s. The setters are change-guarded and poke the
        # document themselves (`TextDocument#note_overlay_change`), so views
        # repaint without an extra emission here.
        old.blocks.each do |b|
          b.additional_formats = nil
          b.user_state = -1
        end
      end
      @document = doc
      if doc
        @ev_contents_change = doc.on(Crysterm::Event::ContentsChanged) do |e|
          on_contents_change(e.position, e.chars_removed, e.chars_added)
        end
        rehighlight
      end
      doc
    end

    # Re-highlights the whole document.
    def rehighlight : Nil
      doc = @document || return
      run_highlight { doc.blocks.each_with_index { |b, i| highlight_one(b, i) } }
    end

    # Re-highlights one block, cascading to following blocks while their
    # state keeps changing — Qt's `QSyntaxHighlighter::rehighlightBlock`
    # semantics, matching the cascade `#on_contents_change` already applies
    # to edits.
    def rehighlight_block(block : TextBlock) : Nil
      doc = @document || return
      i = doc.blocks.index(&.same?(block)) || return
      run_highlight { highlight_from(i, i) }
    end

    # === The `#highlight_block` toolkit ===

    # Overlays *format* on `[start, start + count)` of the current block
    # (Qt merge semantics: only what the patch specifies changes).
    def set_format(start : Int32, count : Int32, format : TextCharFormat) : Nil
      return if count <= 0
      (@pending ||= [] of {Int32, Int32, TextCharFormat}) << {start, start + count, format}
    end

    # :ditto: — foreground color shorthand.
    def set_format(start : Int32, count : Int32, color : Int32 | String) : Nil
      set_format(start, count, TextCharFormat.new(fg: color))
    end

    # The block being highlighted.
    def current_block : TextBlock?
      @current_block
    end

    # The `user_state` of the block before the current one, -1 for the first
    # block (or an unset state) — the multi-line-construct input.
    def previous_block_state : Int32
      doc = @document || return -1
      @current_index > 0 ? doc.blocks[@current_index - 1].user_state : -1
    end

    def current_block_state : Int32
      @current_block.try(&.user_state) || -1
    end

    # Stores the multi-line-construct output state on the current block; a
    # change cascades the re-highlight to the following block.
    def current_block_state=(state : Int32)
      @current_block.try(&.user_state=(state))
    end

    private def on_contents_change(pos : Int32, removed : Int32, added : Int32) : Nil
      return if @highlighting
      # Ignore the zero-length repaint pokes emitted purely so views refresh
      # (real edits always carry removed > 0 || added > 0). Re-running analysis
      # in response to another highlighter's overlay-write poke would recurse
      # unboundedly between two highlighters attached to one document. Note that
      # highlighters still overwrite each other's `additional_formats` — an
      # inherent limitation of the single overlay slot per block.
      return if removed == 0 && added == 0
      doc = @document || return
      b1 = doc.block_at(pos).index
      # A removal ending exactly at a block boundary changes the *following*
      # block's `previous_block_state` without touching its own text, so the
      # window extends one block whenever anything was removed.
      b2 = doc.block_at(pos + added + (removed > 0 ? 1 : 0)).index
      run_highlight { highlight_from(b1, b2) }
    end

    # Highlights blocks `[b1, b2]` and keeps cascading past `b2` while each
    # successive block's `user_state` keeps changing — the shared cascade
    # used by both the edit path (`#on_contents_change`) and
    # `#rehighlight_block`.
    private def highlight_from(b1 : Int32, b2 : Int32) : Nil
      doc = @document || return
      blocks = doc.blocks
      i = b1
      while b = blocks[i]?
        before = b.user_state
        highlight_one(b, i)
        i += 1
        # Beyond the edited range, keep cascading only while the block
        # states keep changing.
        break if i > b2 && b.user_state == before
      end
    end

    # Wraps a highlight batch in the reentrancy guard. Repaint notification
    # is the overlay setters' job: `TextBlock#additional_formats=`/
    # `#user_state=` are change-guarded and poke the document with a
    # zero-length `ContentsChanged` (`TextDocument#note_overlay_change`) only
    # on real change — which is also what keeps two highlighters on one
    # document from re-triggering each other forever (they ignore
    # zero-length pokes).
    private def run_highlight(&) : Nil
      return unless @document
      @highlighting = true
      begin
        yield
      ensure
        @highlighting = false
      end
    end

    private def highlight_one(block : TextBlock, index : Int32) : Nil
      @current_block = block
      @current_index = index
      @pending = nil
      highlight_block(block.text)
      block.additional_formats = @pending
      @current_block = nil
    end
  end
end
