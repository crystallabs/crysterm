require "./tree"

module Crysterm
  class Widget
    # A document's heading outline as a navigable sidebar — the out-of-band
    # counterpart to `TextToc`, which renders the same `TextDocument#outline`
    # *inside* the document.
    #
    # Being a separate widget is what makes this one **live**: rebuilding it
    # reflows nothing in the document, moves no reading position, touches no
    # undo stack and invalidates no block layouts, so it can follow a document
    # as it changes — including one being streamed into — where the inline TOC
    # deliberately waits to be asked (`TextDocument#refresh_tocs`).
    #
    # Selecting an entry emits `Event::AnchorClick` carrying `"#anchor"`, the
    # same event `TextBrowser` follows, so wiring the two together is one line:
    #
    # ```
    # tv = Widget::TocView.new parent: s, width: 24, height: 20, document: doc
    # tv.on(Crysterm::Event::AnchorClick) { |e| tb.activate_link e.url }
    # ```
    #
    # Headings that skip a level (an `h1` straight to an `h3`) get a filler
    # node named for the level they skipped, so the tree keeps its shape
    # instead of flattening or dropping the entry.
    class TocView < Tree
      # Anchors, not row indexes, identify entries across a rebuild: block
      # indexes move whenever the document above them changes, anchors do not.
      @signature = [] of {Int32, String}

      @ev_contents_change : ::EventHandler::Subscription?

      getter document : TextDocument?

      def initialize(document : TextDocument? = nil, **input)
        super(**input)
        self.document = document
      end

      # Attaches to *doc* (detaching from any previous one) and rebuilds.
      # `nil` detaches and empties the view.
      def document=(doc : TextDocument?) : TextDocument?
        if @document
          @ev_contents_change.try &.off
          @ev_contents_change = nil
        end
        @document = doc
        if doc
          @ev_contents_change = doc.on(Crysterm::Event::ContentsChanged) do
            refresh
          end
        end
        refresh force: true
        doc
      end

      # Rebuilds the tree from the document's outline, returning whether it
      # changed.
      #
      # Cheap to call on every document edit: `TextDocument#outline` keeps
      # returning its cached array while no heading's level, text or block
      # index has changed — the overwhelmingly common case while text is being
      # typed or streamed between headings — and an outline whose levels and
      # anchors match the last build is recognized by comparing against
      # `@signature` in place, so the no-change path allocates nothing and
      # rebuilds nothing.
      def refresh(force : Bool = false) : Bool
        entries = @document.try(&.outline) || [] of TextOutline::Entry
        return false if !force && signature_matches?(entries)
        @signature = entries.map { |e| {e.level, e.anchor} }

        # Preserve what the reader did to the tree, keyed by anchor so it
        # survives entries appearing above or below.
        collapsed = collapsed_anchors
        selected = selected_node.try(&.data)

        batch_update do
          clear
          build entries
          each_node do |n|
            next if n.leaf?
            d = n.data
            n.expanded = !(d && collapsed.includes?(d))
          end
        end

        if selected && (row = nodes.index { |n| n.data == selected })
          self.current_index = row
        end
        true
      end

      # Jumping is the point of this widget, so a selected entry emits its
      # anchor before `Tree`'s own activation (which also toggles a node that
      # has children).
      def activate_current : Nil
        if (node = selected_node) && (anchor = node.data)
          emit Crysterm::Event::AnchorClick, "##{anchor}"
        end
        super
      end

      # Whether *entries* still matches `@signature`, entry for entry —
      # compared in place rather than materializing a fresh signature array,
      # since this runs on every `Event::ContentsChanged`.
      private def signature_matches?(entries : Array(TextOutline::Entry)) : Bool
        return false unless entries.size == @signature.size
        @signature.each_with_index do |sig, i|
          e = entries[i]
          return false unless sig[0] == e.level && sig[1] == e.anchor
        end
        true
      end

      # Builds the node hierarchy from a flat, level-tagged outline.
      #
      # Depth is measured from the *shallowest heading present* rather than
      # from `h1`, so a document whose top heading is an `h2` is not pushed a
      # level down under an empty placeholder.
      private def build(entries : Array(TextOutline::Entry)) : Nil
        return if entries.empty?
        base = entries.min_of(&.level)
        entries.each do |e|
          parent = nil.as(Node?)
          (e.level - base).times do |d|
            kids = parent.try(&.children) || roots
            parent =
              if last = kids.last?
                last
              else
                filler = Node.new("#" * (base + d))
                (p = parent) ? p.add(filler) : add(filler)
              end
          end
          leaf = Node.new(e.text, e.anchor)
          (p = parent) ? p.add(leaf) : add(leaf)
        end
      end

      # Anchors of the entries the reader has collapsed. Filler nodes carry no
      # anchor and so always come back expanded — there is nothing stable to
      # remember them by.
      private def collapsed_anchors : Set(String)
        res = Set(String).new
        each_node do |n|
          d = n.data
          res << d if d && !n.leaf? && !n.expanded?
        end
        res
      end
    end
  end
end
