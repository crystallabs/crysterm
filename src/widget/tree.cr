require "./abstract_item_view"
require "../mixin/item_view"

module Crysterm
  class Widget
    # Hierarchical item view, modeled after Qt's `QTreeWidget`/`QTreeView`.
    #
    # A `Tree` is an `AbstractItemView` (a sibling of `List`, as Qt makes
    # `QTreeWidget` a sibling of `QListWidget` under `QAbstractItemView`) whose
    # rows are the *visible* nodes of a node hierarchy, flattened depth-first with
    # each node indented by its depth and prefixed with an expand marker (`▸`
    # collapsed, `▾` expanded, blank for a leaf). Collapsing a node hides its
    # subtree; expanding brings it back. All of `Mixin::ItemView`'s navigation
    # (arrow keys, Home/End, PageUp/Down, incremental search, mouse) works
    # unchanged.
    #
    # On top of that the tree adds: Right to expand (or descend into an already-
    # expanded node), Left to collapse (or jump to the parent), and Space/Enter to
    # toggle a node. It emits `Event::Expand`/`Event::Collapse` (carrying the
    # node's row) alongside the usual item events.
    #
    # ```
    # tree = Widget::Tree.new parent: window, width: 30, height: 12, style: Style.new(border: true)
    # src = tree.add "src"
    # src.add "widget"
    # src.add "layout"
    # tree.add "README.md"
    # tree.expand_all
    # ```
    #
    # <!-- widget-examples:capture v1 -->
    # ![Tree screenshot](../../tests/widget/tree/tree.5s.apng)
    # <!-- /widget-examples:capture -->
    class Tree < AbstractItemView
      include Mixin::ItemView

      # A single node in a `Tree`. Holds its `#text`, optional user `#data`, and
      # its `#children`; whether it is currently `#expanded?`; and back-references
      # to its `#parent` node and owning `#tree` (so structural edits can refresh
      # the view).
      class Node
        property text : String

        # Arbitrary user-associated string (Qt's item data role); not displayed.
        property data : String?

        getter children = [] of Node

        # The parent node, or `nil` for a top-level node.
        property parent : Node?

        # The owning tree, set when the node is attached. Used to refresh the
        # flattened view after a structural change.
        getter tree : Tree?

        # Setting the owning tree adopts the whole subtree, not just this node: a
        # detached `Node` built with children keeps those children's `#tree` nil
        # otherwise, so a later `grandchild.add "x"` would skip `rebuild` and
        # leave the view stale.
        def tree=(@tree : Tree?) : Tree?
          @children.each(&.tree=(@tree))
          @tree
        end

        property? expanded : Bool = false

        def initialize(@text, @data = nil)
        end

        # Appends a child (given as text, or an existing `Node`) and refreshes the
        # owning tree. Returns the child node.
        def add(text : String, data : String? = nil) : Node
          add Node.new(text, data)
        end

        # :ditto:
        def add(node : Node) : Node
          node.parent = self
          node.tree = @tree
          @children << node
          @tree.try &.rebuild
          node
        end

        # Whether this node has no children (rendered without an expand marker).
        def leaf? : Bool
          @children.empty?
        end

        # Number of ancestors (top-level nodes are at depth 0), i.e. the
        # indentation level.
        def depth : Int32
          d = 0
          p = @parent
          while p
            d += 1
            p = p.parent
          end
          d
        end
      end

      # The top-level nodes.
      getter roots = [] of Node

      # The node shown on each visible row, parallel to the item view's
      # `#items`/`#ritems`.
      getter nodes = [] of Node

      # Spaces of indentation added per depth level.
      property indent : Int32 = 2

      # Markers drawn before a node's text.
      property expanded_char : Char = MARKER_EXPANDED
      property collapsed_char : Char = MARKER_COLLAPSED
      property leaf_char : Char = ' '

      # `initialize` is inherited from `Mixin::ItemView` unchanged.

      # Depth of the active `begin_update`/`end_update` batch (nestable), and
      # whether a `rebuild` was requested while batching.
      @update_depth : Int32 = 0
      @rebuild_pending : Bool = false

      # Suspends view rebuilds until the matching `#end_update`. Structural edits
      # (`#add`, `Node#add`, expand/collapse) made in between coalesce into a
      # single re-flatten, turning an O(N²) bulk load (one rebuild per `add`)
      # into O(N). Nestable; a lone `add` outside a batch rebuilds immediately as
      # before.
      def begin_update : Nil
        @update_depth += 1
      end

      # Ends a `#begin_update` batch, running the single deferred rebuild once the
      # outermost batch closes (and only if something requested one).
      def end_update : Nil
        @update_depth -= 1 if @update_depth > 0
        if @update_depth == 0 && @rebuild_pending
          @rebuild_pending = false
          rebuild
        end
      end

      # Runs *block* inside a `#begin_update`/`#end_update` batch, flushing even if
      # it raises.
      def update(&) : Nil
        begin_update
        begin
          yield
        ensure
          end_update
        end
      end

      # Appends a top-level node (given as text, or an existing `Node`) and
      # refreshes the view. Returns the node.
      def add(text : String, data : String? = nil) : Node
        add Node.new(text, data)
      end

      # :ditto:
      def add(node : Node) : Node
        node.parent = nil
        node.tree = self
        @roots << node
        rebuild
        node
      end

      # The node under the cursor, or `nil` when the tree is empty.
      def selected_node : Node?
        @nodes[@selected]?
      end

      # Re-flattens the visible node hierarchy into the underlying list rows,
      # preserving the cursor on the same node when it is still visible.
      def rebuild : Nil
        # Inside a `begin_update` batch, defer the (potentially repeated) work to
        # the single flush in `end_update`.
        if @update_depth > 0
          @rebuild_pending = true
          return
        end

        prev = selected_node
        @nodes.clear
        rows = [] of String
        @roots.each { |n| flatten n, rows, 0 }
        set_items rows
        if prev
          if i = @nodes.index prev
            selekt i
          elsif (anc = nearest_visible_ancestor prev) && (j = @nodes.index anc)
            # Previously-selected node was hidden by a collapse; follow selection
            # up to its nearest still-visible ancestor, as Qt does, rather than
            # stranding it on row 0.
            selekt j
          end
        end
        request_render
      end

      # Nearest ancestor of *node* that is currently a visible row, or `nil`.
      private def nearest_visible_ancestor(node : Node) : Node?
        p = node.parent
        while p
          return p if @nodes.includes? p
          p = p.parent
        end
        nil
      end

      # *depth* is threaded down the recursion (top-level nodes at 0) rather than
      # recomputed per node via `Node#depth` (an O(depth) parent-chain walk).
      private def flatten(node : Node, rows : Array(String), depth : Int32) : Nil
        @nodes << node
        rows << row_text node, depth
        if node.expanded?
          node.children.each { |c| flatten c, rows, depth + 1 }
        end
      end

      private def row_text(node : Node, depth : Int32) : String
        marker = node.leaf? ? @leaf_char : (node.expanded? ? @expanded_char : @collapsed_char)
        "#{" " * (depth * @indent)}#{marker} #{node.text}"
      end

      # Expands *node* (a no-op for a leaf or an already-expanded node), refreshes
      # the view, and emits `Event::Expand`.
      def expand(node : Node) : Nil
        return if node.leaf? || node.expanded?
        set_expanded node, true, Crysterm::Event::Expand
      end

      # Collapses *node*, refreshes the view, and emits `Event::Collapse`.
      def collapse(node : Node) : Nil
        return if node.leaf? || !node.expanded?
        set_expanded node, false, Crysterm::Event::Collapse
      end

      # Sets *node*'s expanded state, rebuilds the flattened view, and emits
      # *event* carrying the node's (pre-rebuild) row index. Shared body of
      # `#expand`/`#collapse`, which differ only in the flag and the event.
      private def set_expanded(node : Node, expanded : Bool, event) : Nil
        i = @nodes.index node
        node.expanded = expanded
        rebuild
        emit event, (i || 0)
      end

      # Flips *node*'s expanded state.
      def toggle(node : Node) : Nil
        node.expanded? ? collapse(node) : expand(node)
      end

      # Expands every node in the whole hierarchy.
      def expand_all : Nil
        each_node { |n| n.expanded = true unless n.leaf? }
        rebuild
      end

      # Collapses every node in the whole hierarchy.
      def collapse_all : Nil
        each_node(&.expanded=(false))
        rebuild
      end

      # Yields every node in the hierarchy (not just the visible ones),
      # depth-first.
      def each_node(&block : Node ->) : Nil
        @roots.each { |n| walk n, block }
      end

      private def walk(node : Node, block : Node ->) : Nil
        block.call node
        node.children.each { |c| walk c, block }
      end

      # Toggling a node (Enter, or a click on the already-selected row) expands or
      # collapses it; leaves fall through to the normal item activation.
      def enter_selected : Nil
        if (node = selected_node) && !node.leaf?
          toggle node
        end
        super
      end

      def on_keypress(e)
        node = selected_node

        case
        when e.key == Tput::Key::Right
          if node && !node.leaf?
            node.expanded? ? down : expand(node)
            e.accept
            request_render
            return
          end
        when e.key == Tput::Key::Left
          if node
            if !node.leaf? && node.expanded?
              collapse node
            elsif (p = node.parent) && (i = @nodes.index p)
              selekt i
            end
            e.accept
            request_render
            return
          end
        when e.char == ' '
          if node && !node.leaf?
            toggle node
            e.accept
            request_render
            return
          end
        end

        super e
      end
    end
  end
end
