require "./list"

module Crysterm
  class Widget
    # Hierarchical item view, modeled after Qt's `QTreeWidget`/`QTreeView`.
    #
    # A `Tree` is a `List` whose rows are the *visible* nodes of a node
    # hierarchy, flattened depth-first with each node indented by its depth and
    # prefixed with an expand marker (`▸` collapsed, `▾` expanded, blank for a
    # leaf). Collapsing a node hides its whole subtree; expanding it brings the
    # subtree back. All of `List`'s navigation (arrow keys, Home/End, PageUp/Down,
    # incremental search, the mouse) therefore works unchanged.
    #
    # On top of that the tree adds: Right to expand (or descend into an already-
    # expanded node), Left to collapse (or jump to the parent), and Space/Enter to
    # toggle a node. It emits `Event::Expand`/`Event::Collapse` (carrying the
    # node's row) alongside the usual `List` item events.
    #
    # ```
    # tree = Widget::Tree.new parent: screen, width: 30, height: 12, style: Style.new(border: true)
    # src = tree.add "src"
    # src.add "widget"
    # src.add "layout"
    # tree.add "README.md"
    # tree.expand_all
    # ```
    #
    # <!-- widget-examples:capture v1 -->
    # ![Tree screenshot](../../examples/widget/tree/tree-capture5s.apng)
    # <!-- /widget-examples:capture -->
    class Tree < List
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
        property tree : Tree?

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

      # The node shown on each visible row, parallel to the underlying `List`'s
      # `#items`/`#ritems`.
      getter nodes = [] of Node

      # Spaces of indentation added per depth level.
      property indent : Int32 = 2

      # Markers drawn before a node's text.
      property expanded_char : Char = '▾'
      property collapsed_char : Char = '▸'
      property leaf_char : Char = ' '

      # `initialize` is inherited from `List` unchanged.

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
        prev = selected_node
        @nodes.clear
        rows = [] of String
        @roots.each { |n| flatten n, rows }
        set_items rows
        if prev && (i = @nodes.index prev)
          selekt i
        end
        request_render
      end

      private def flatten(node : Node, rows : Array(String)) : Nil
        @nodes << node
        rows << row_text node
        if node.expanded?
          node.children.each { |c| flatten c, rows }
        end
      end

      private def row_text(node : Node) : String
        marker = node.leaf? ? @leaf_char : (node.expanded? ? @expanded_char : @collapsed_char)
        "#{" " * (node.depth * @indent)}#{marker} #{node.text}"
      end

      # Expands *node* (a no-op for a leaf or an already-expanded node), refreshes
      # the view, and emits `Event::Expand`.
      def expand(node : Node) : Nil
        return if node.leaf? || node.expanded?
        i = @nodes.index node
        node.expanded = true
        rebuild
        emit Crysterm::Event::Expand, (i || 0)
      end

      # Collapses *node*, refreshes the view, and emits `Event::Collapse`.
      def collapse(node : Node) : Nil
        return if node.leaf? || !node.expanded?
        i = @nodes.index node
        node.expanded = false
        rebuild
        emit Crysterm::Event::Collapse, (i || 0)
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
      # collapses it; leaves fall through to the normal `List` activation.
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
