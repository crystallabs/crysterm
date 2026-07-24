module Crysterm
  module Mixin
    module Children
      # Widget's children `Widget`s.
      getter children = [] of Widget

      # O(1) membership index for `@children`, kept in sync by `insert`/`remove`;
      # without it a batch of N appends would be O(N²) on the duplicate guard.
      # Any other direct mutator of `@children` must keep this in sync.
      @children_set = Set(Widget).new

      # Adds `element` to list of children. Convenience method identical to `append`
      def <<(widget : Widget)
        append widget
      end

      # O(1) direct-child membership test. Prefer over `children.includes?` (a
      # linear scan) on hot paths that repeatedly probe membership.
      def child?(element : Widget) : Bool
        @children_set.includes? element
      end

      # Appends `element` to list of children
      def append(element : Widget)
        insert element
      end

      # Appends `element`s to list of children in the order given (first listed is first added)
      def append(*elements : Widget)
        elements.each do |el|
          insert el
        end
      end

      # Prepends node to the list of children
      def prepend(element : Widget)
        insert element, 0
      end

      # Adds node to the list of children before the specified `other` element
      def insert_before(element : Widget, other)
        if i = @children.index other
          insert element, i
        end
      end

      # Adds node to the list of children after the specified `other` element
      def insert_after(element : Widget, other)
        if i = @children.index other
          insert element, i + 1
        end
      end

      # Low-level list primitive: inserts `element` into the children list at `i`.
      #
      # This bare form is a no-op (returns nil) if `element` is already present,
      # so on its own it cannot reposition an existing child. Overriders detach
      # `element` from its current parent before calling `super`, which is what
      # makes `append`/`prepend`/`insert_before`/`insert_after` reposition.
      def insert(element : Widget, i = -1)
        return unless @children_set.add? element
        @children.insert i, element
        mark_structure_changed
        element
      end

      # Removes `element` from list of children widgets
      def remove(element : Widget)
        return unless @children_set.delete element
        return unless i = @children.index(element)
        # No need to erase the removed element's old footprint: the cell buffer
        # is cleared each frame, so it simply stops being repainted.
        @children.delete_at i
        mark_structure_changed
        element
      end

      # Propagates a structural change to the children list (an add/remove) to the
      # subsystems that depend on it: the CSS tree and damage tracking.
      private def mark_structure_changed : Nil
        invalidate_css_tree
        _damage_invalidate_structure
      end

      # Hook invoked after a structural children-list change. Overridden to mark
      # styling dirty and force a re-parse, since structure can alter which
      # selectors match. No-op by default.
      protected def invalidate_css_tree : Nil
      end

      # Structural-change hook for damage tracking. Overridden to force a full
      # re-composite next frame. No-op by default.
      protected def _damage_invalidate_structure : Nil
      end

      # Returns true if `other` is found in the list of parents, recursively.
      def descendant_of?(other : Widget?) : Bool
        el = self
        while el = el.parent
          return true if el.same? other
        end
        false
      end

      # Returns true if `other` is found in the list of children, recursively
      # (Qt's `QWidget#isAncestorOf`). Strict: `self` is not its own ancestor —
      # see `#covers?` for the self-inclusive form.
      def ancestor_of?(other : Widget?) : Bool
        @children.each do |el|
          return true if el.same? other
          return true if el.ancestor_of? other
        end
        false
      end

      # Self-inclusive `#ancestor_of?`: true if `other` *is* `self` or sits
      # somewhere in `self`'s subtree. Nil-safe — a nil *other* is "not found".
      def covers?(other : Widget?) : Bool
        same?(other) || ancestor_of?(other)
      end

      # Runs a particular block for self and all descendants, recursively
      def self_and_each_descendant(&block : Proc(Widget, Nil)) : Nil
        block.call self
        each_descendant &block
      end

      # Runs a particular block for all descendants, recursively
      def each_descendant(&block : Proc(Widget, Nil)) : Nil
        # Pass the captured `block` down rather than building a fresh
        # self-referential closure per call on this hot traversal.
        @children.each do |el|
          _each_descendant el, block
        end
      end

      private def _each_descendant(el : Widget, block : Proc(Widget, Nil)) : Nil
        block.call el
        el.children.each do |c|
          _each_descendant c, block
        end
      end

      # Runs a particular block for self and all ancestors, recursively
      def self_and_each_ancestor(&block : Proc(Widget, Nil)) : Nil
        block.call self
        each_ancestor &block
      end

      # Runs a particular block for all ancestors, recursively
      def each_ancestor(&block : Proc(Widget, Nil)) : Nil
        @parent.try { |el| _each_ancestor el, block }
      end

      private def _each_ancestor(el : Widget, block : Proc(Widget, Nil)) : Nil
        block.call el
        el.parent.try { |el2| _each_ancestor el2, block }
      end

      # Returns the first of self-or-ancestors (walking up via `parent`) for
      # which the block is truthy, or `nil` if none match. The walk stops on the
      # first truthy result.
      #
      # Yield-based on purpose: the hit-test/focus/scroll hot paths call this per
      # event and must not allocate the `Proc` that `each_ancestor` would.
      def first_self_or_ancestor(&) : Widget?
        el : Widget? = self
        while el
          return el if yield el
          el = el.parent
        end
        nil
      end

      # Memoized result of `#top_level_ancestor`. Invalidated for the whole
      # subtree on every reparent via the `#window?` cache path (`reset_window_cache`).
      @top_level_ancestor_cache : Widget?

      # The top-most ancestor of the tree self sits in (self if parentless).
      # Non-allocating parent-chain walk to the root. Memoized: `damage_mark_dirty`
      # calls this on every state-changing setter, once per mutation while damage
      # tracking is on, so a deep tree pays O(depth) per mark without the memo.
      def top_level_ancestor : Widget
        if cached = @top_level_ancestor_cache
          return cached
        end
        root = self
        while p = root.parent
          root = p
        end
        @top_level_ancestor_cache = root
      end

      # The first descendant named *name*, searched depth-first, or `nil` when
      # none matches (Qt's `QObject#findChild`). Searches the whole subtree, not
      # just direct children.
      def find_child(name : String) : Widget?
        @children.each do |el|
          return el if el.name == name
          if found = el.find_child name
            return found
          end
        end
        nil
      end

      # Every descendant named *name*, in depth-first order (Qt's
      # `QObject#findChildren`). Empty when none matches.
      def find_children(name : String) : Array(Widget)
        found = [] of Widget
        each_descendant { |el| found << el if el.name == name }
        found
      end

      # Returns a flat list of all children widgets, recursively
      def descendants : Array(Widget)
        children = [] of Widget
        each_descendant { |e| children << e }
        children
      end

      # Returns a flat list of all parent widgets, recursively
      def ancestors : Array(Widget)
        parents = [] of Widget
        each_ancestor { |e| parents << e }
        parents
      end

      # Emits `ev` on all children nodes, recursively.
      def emit_descendants(ev : EventHandler::Event | EventHandler::Event.class) : Nil
        each_descendant(&.emit(ev))
      end

      # Emits `ev` on all parent nodes.
      def emit_ancestors(ev : EventHandler::Event | EventHandler::Event.class) : Nil
        each_ancestor(&.emit(ev))
      end
    end
  end
end
