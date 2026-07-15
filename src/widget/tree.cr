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

        # Whether this node's children are currently shown.
        getter? expanded : Bool = false

        # Expands or collapses this node (Qt's `QTreeWidgetItem#setExpanded`).
        # Routes through the owning tree, so the flattened view is rebuilt and
        # `Event::Expand`/`Event::Collapse` is emitted; a no-op for a leaf or an
        # unchanged state. Detached nodes (no `#tree` yet) just record the flag,
        # which the first `Tree#add` then honors.
        #
        # It used to be a bare `property?`, whose setter did neither — so
        # `node.expanded = true` left the rows stale and every listener unaware,
        # while the equivalent `Tree#expand` did the right thing.
        def expanded=(value : Bool) : Bool
          if t = @tree
            t.set_expanded self, value
          else
            @expanded = value
          end
          value
        end

        # Assigns the raw flag with no rebuild/notification. For the owning
        # `Tree`, which batches the single rebuild and the per-node emit around a
        # run of these (`#set_expanded`, `#expand_all`/`#collapse_all`).
        protected def expanded_flag=(value : Bool) : Nil
          @expanded = value
        end

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

        # Removes *node* from this node's children and refreshes the owning tree.
        # Returns the detached node, or `nil` when it was not a child of this one
        # (Qt's `QTreeWidgetItem#removeChild`).
        def remove_child(node : Node) : Node?
          return nil unless @children.delete node
          node.parent = nil
          node.tree = nil
          @tree.try &.rebuild
          node
        end

        # Removes every child of this node (Qt's `QTreeWidgetItem#takeChildren`).
        def clear : Nil
          return if @children.empty?
          @children.each do |c|
            c.parent = nil
            c.tree = nil
          end
          @children.clear
          @tree.try &.rebuild
        end

        # The child at *index*, or `nil` when out of range (Qt's
        # `QTreeWidgetItem#child`).
        def child(index : Int) : Node?
          @children[index]?
        end

        # Number of direct children (Qt's `QTreeWidgetItem#childCount`).
        def child_count : Int32
          @children.size
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
      getter indent : Int32 = 2

      # Re-flattens the rows at the new width. Dropping the memoized indent
      # strings alone left every already-built row at the old spacing until the
      # next unrelated structural change.
      def indent=(v : Int32) : Int32
        return v if v == @indent
        @indent = v
        @indent_cache.clear
        rebuild
        v
      end

      # Memoized leading-space strings per depth (`depth * @indent` spaces),
      # grown on demand so a bulk rebuild reuses them instead of `" " * n` per row.
      # Cleared when `#indent` changes.
      @indent_cache = [] of String

      private def indent_str(depth : Int32) : String
        while @indent_cache.size <= depth
          @indent_cache << " " * (@indent_cache.size * @indent)
        end
        @indent_cache[depth]
      end

      # Markers drawn before a node's text. Unset (`nil`) resolves from the
      # `Glyphs` registry at the effective tier; assigning a `Char` pins it.
      setter expanded_char : Char? = nil
      setter collapsed_char : Char? = nil
      setter leaf_char : Char? = nil

      # :ditto:
      def expanded_char : Char
        @expanded_char || glyph(Glyphs::Role::TreeExpanded)
      end

      # :ditto:
      def collapsed_char : Char
        @collapsed_char || glyph(Glyphs::Role::TreeCollapsed)
      end

      # :ditto:
      def leaf_char : Char
        @leaf_char || glyph(Glyphs::Role::TreeLeaf)
      end

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
      # refreshes the view. Returns the node — which is why the tree keeps `add`
      # rather than the family's `#add_item` (that returns a row box, and it is
      # the returned `Node` you go on to build the hierarchy with:
      # `tree.add("src").add "widget"`). Everything else in the vocabulary —
      # `#remove_node`/`#clear`/`#count`/`#current_index` — reads the same here
      # as on every sibling.
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

      # Removes *node* from the hierarchy — wherever it sits — and returns it, or
      # `nil` when it is not in this tree (Qt's `QTreeWidget#takeTopLevelItem` /
      # `QTreeWidgetItem#removeChild`, which the tree had no equivalent of at
      # all). Named `remove_node`, not `remove`: `Widget#remove` already means
      # "detach a child widget", and one name for two unrelated removals reads as
      # a trap.
      def remove_node(node : Node) : Node?
        if p = node.parent
          return p.remove_child node
        end
        return nil unless @roots.delete node
        node.tree = nil
        rebuild
        node
      end

      # Removes every node (Qt's `QTreeWidget#clear`). Overrides
      # `Mixin::ItemView#clear`, which would drop the rendered rows while leaving
      # the hierarchy behind to be re-flattened by the next `#rebuild`.
      def clear : Nil
        return if @roots.empty?
        @roots.each(&.tree=(nil))
        @roots.clear
        rebuild
      end

      # Number of top-level nodes (Qt's `QTreeWidget#topLevelItemCount`).
      # `#count`, inherited from `Mixin::ItemView`, is the number of *visible
      # rows* — the unit `#item`/`#current_index`/`#selected_node` all work in.
      def top_level_count : Int32
        @roots.size
      end

      # The top-level node at *index*, or `nil` when out of range (Qt's
      # `QTreeWidget#topLevelItem`).
      def top_level_node(index : Int) : Node?
        @roots[index]?
      end

      # The node under the cursor, or `nil` when the tree is empty.
      def selected_node : Node?
        @nodes[@selected]?
      end

      # Re-flattens the visible node hierarchy into the underlying list rows,
      # preserving the cursor on the same node when it is still visible.
      #
      # Protected: every mutator here (`#add`, `Node#add`/`#remove_child`,
      # `#indent=`, the expand/collapse family) refreshes the view itself, so
      # this is the tree's own plumbing rather than something a caller drives.
      protected def rebuild : Nil
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
        self.items = rows
        if prev
          if i = @nodes.index prev
            select_index i
          elsif (anc = nearest_visible_ancestor prev) && (j = @nodes.index anc)
            # Previously-selected node was hidden by a collapse; follow selection
            # up to its nearest still-visible ancestor, as Qt does, rather than
            # stranding it on row 0.
            select_index j
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
        marker = node.leaf? ? leaf_char : (node.expanded? ? expanded_char : collapsed_char)
        "#{indent_str(depth)}#{marker} #{node.text}"
      end

      # Expands *node* (a no-op for a leaf or an already-expanded node), refreshes
      # the view, and emits `Event::Expand`.
      def expand(node : Node) : Nil
        set_expanded node, true
      end

      # Collapses *node*, refreshes the view, and emits `Event::Collapse`.
      def collapse(node : Node) : Nil
        set_expanded node, false
      end

      # Sets *node*'s expanded state, rebuilds the flattened view, and emits
      # `Event::Expand`/`Event::Collapse`. A no-op for a leaf or an unchanged
      # state. The single funnel every path goes through — `#expand`/`#collapse`,
      # `#toggle`, and `Node#expanded=`.
      def set_expanded(node : Node, expanded : Bool) : Nil
        return if node.leaf? || node.expanded? == expanded
        if expanded
          apply_expanded node, true, Crysterm::Event::Expand
        else
          apply_expanded node, false, Crysterm::Event::Collapse
        end
      end

      # Shared body of `#set_expanded`'s two branches, which differ only in the
      # flag and the event. *event* carries the node's pre-rebuild row index.
      private def apply_expanded(node : Node, expanded : Bool, event) : Nil
        i = @nodes.index node
        node.expanded_flag = expanded
        rebuild
        emit event, (i || 0)
      end

      # Flips *node*'s expanded state.
      def toggle(node : Node) : Nil
        node.expanded? ? collapse(node) : expand(node)
      end

      # Expands every node in the whole hierarchy.
      def expand_all : Nil
        set_expanded_all true, Crysterm::Event::Expand
      end

      # Collapses every node in the whole hierarchy.
      def collapse_all : Nil
        set_expanded_all false, Crysterm::Event::Collapse
      end

      # Expands or collapses every non-leaf node: one `#rebuild` for the whole
      # batch (not one per node), then *event* per node that actually changed —
      # Qt's `expandAll`/`collapseAll` still emit `expanded()`/`collapsed()` for
      # each item. Both used to poke `node.expanded` directly and emit nothing at
      # all. The row index carried is the node's *post*-rebuild row, since a
      # subtree revealed by this very call has no pre-rebuild row to name.
      private def set_expanded_all(expanded : Bool, event) : Nil
        changed = [] of Node
        each_node do |n|
          next if n.leaf? || n.expanded? == expanded
          n.expanded_flag = expanded
          changed << n
        end
        return if changed.empty?
        rebuild
        changed.each { |n| emit event, (@nodes.index(n) || 0) }
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
              select_index i
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
