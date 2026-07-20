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

    @ev_contents_change : Crysterm::Event::ContentsChanged::Wrapper?
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
        @ev_contents_change.try { |w| old.off(Crysterm::Event::ContentsChanged, w) }
        @ev_contents_change = nil
        # Drop this highlighter's overlays and user states so the old document
        # renders plain again and a later highlighter starts from clean
        # `previous_block_state`s.
        changed = false
        old.blocks.each do |b|
          changed = true if b.additional_formats || b.user_state != -1
          b.additional_formats = nil
          b.user_state = -1
        end
        old.emit Crysterm::Event::ContentsChanged, 0, 0, 0 if changed
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

    # Re-highlights one block.
    def rehighlight_block(block : TextBlock) : Nil
      doc = @document || return
      i = doc.blocks.index(&.same?(block)) || return
      run_highlight { highlight_one(block, i) }
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
      blocks = doc.blocks
      b1 = doc.block_at(pos)[0]
      # A removal ending exactly at a block boundary changes the *following*
      # block's `previous_block_state` without touching its own text, so the
      # window extends one block whenever anything was removed.
      b2 = doc.block_at(pos + added + (removed > 0 ? 1 : 0))[0]
      run_highlight do
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
    end

    # Wraps a highlight batch: sets the reentrancy guard and, only when a
    # block's overlay or state actually changed, pokes the document with a
    # zero-length `ContentsChanged` so attached views repaint. Gating the poke
    # on real change keeps two highlighters on one document from re-triggering
    # each other forever.
    private def run_highlight(&) : Nil
      doc = @document || return
      @batch_changed = false
      @highlighting = true
      begin
        yield
      ensure
        @highlighting = false
      end
      doc.emit Crysterm::Event::ContentsChanged, 0, 0, 0 if @batch_changed
    end

    @batch_changed = false

    private def highlight_one(block : TextBlock, index : Int32) : Nil
      @current_block = block
      @current_index = index
      @pending = nil
      old_formats = block.additional_formats
      old_state = block.user_state
      highlight_block(block.text)
      block.additional_formats = @pending
      @batch_changed = true if block.user_state != old_state || @pending != old_formats
      @current_block = nil
    end
  end
end
