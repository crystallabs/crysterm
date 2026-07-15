module Crysterm
  module Mixin
    module Children
      # Widget's children `Widget`s.
      getter children = [] of Widget

      # O(1) membership index for `@children`, kept in sync by `insert`/`remove`.
      # Without it, `insert`'s "already a child?" guard would be a linear
      # `@children.includes?` scan, making a batch of N appends O(N²). The only
      # other direct mutator of `@children` is the reorder in
      # `widget_children.cr`, which removes and re-adds the same element so
      # membership is unchanged.
      @children_set = Set(Widget).new

      # Adds `element` to list of children. Convenience method identical to `append`
      def <<(widget : Widget)
        append widget
      end

      # O(1) direct-child membership test, backed by `@children_set`. Use in
      # place of `children.includes? element` (a linear `@children` scan) on hot
      # paths that repeatedly probe membership.
      def child?(element) : Bool
        @children_set.includes? element
      end

      # Appends `element` to list of children
      def append(element)
        insert element
      end

      # Appends `element`s to list of children in the order given (first listed is first added)
      def append(*elements)
        elements.each do |el|
          insert el
        end
      end

      # Prepends node to the list of children
      def prepend(element)
        insert element, 0
      end

      # Adds node to the list of children before the specified `other` element
      def insert_before(element, other)
        if i = @children.index other
          insert element, i
        end
      end

      # Adds node to the list of children after the specified `other` element
      def insert_after(element, other)
        if i = @children.index other
          insert element, i + 1
        end
      end

      # Low-level list primitive: inserts `element` into the children list at `i`.
      #
      # This bare form is a no-op (returns nil) if `element` is already present —
      # the `@children_set` guard rejects the duplicate before any list mutation,
      # so on its own it can't reposition an existing child. Real widgets never
      # hit that path for a re-insert: `Widget#insert`/`Window#insert` override
      # this to first detach `element` from its current parent and then call
      # `super`, which is how `append`/`prepend`/`insert_before`/`insert_after`
      # *do* reposition an existing child (remove-then-add). `#stack_index=`
      # (`widget_children.cr`) is the other reorder path.
      def insert(element, i = -1)
        return unless @children_set.add? element
        @children.insert i, element
        mark_structure_changed
        element
      end

      # Removes `element` from list of children widgets
      def remove(element)
        return unless @children_set.delete element
        return unless i = @children.index(element)
        # No need to erase the removed element's old footprint: `Window#_render`
        # clears the whole cell buffer each frame, so it just stops being repainted.
        @children.delete_at i
        mark_structure_changed
        element
      end

      # Propagates a structural change to the children list (an add/remove) to the
      # subsystems that depend on it: the CSS tree and damage tracking. Shared by
      # `#insert` and `#remove`, which both invalidate exactly this pair.
      private def mark_structure_changed : Nil
        invalidate_css_tree
        _damage_invalidate_structure
      end

      # Hook invoked after a structural children-list change. CSS overrides this
      # (on `Widget`/`Window`) to mark styling dirty and force a re-parse, since
      # structure can alter which selectors match. No-op by default.
      protected def invalidate_css_tree : Nil
      end

      # Structural-change hook for damage tracking. Overridden on `Widget`
      # (forwards to its window) and `Window` (forces full re-composite next
      # frame). No-op by default. See `OptimizationFlag::DamageTracking`.
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
      # somewhere in `self`'s subtree — i.e. whether `self` "covers" `other`.
      # Nil-safe: `other` may be a possibly-absent widget reference (a captured
      # focus/hover/drag/grab pointer), and `same?`/`#ancestor_of?` already treat
      # `nil` as "not found" (`Reference#same?(other : Nil)` is `false`).
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
      # which the block is truthy, or `nil` if none match. Yield-based on
      # purpose: the window hit-test/focus/scroll hot paths call this per event
      # and must not allocate the `Proc` that `each_ancestor` would (block is
      # inlined, early-returns on the match). Block may return any value; the
      # walk stops on the first truthy result, matching the hand-rolled
      # `while el && !pred; el = el.parent` loops it replaces.
      def first_self_or_ancestor(&) : Widget?
        el : Widget? = self
        while el
          return el if yield el
          el = el.parent
        end
        nil
      end

      # The top-most ancestor of the tree self sits in (self if parentless).
      # Non-allocating parent-chain walk to the root.
      def top_level_ancestor : Widget
        root = self
        while p = root.parent
          root = p
        end
        root
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
      def collect_descendants : Array(Widget)
        children = [] of Widget
        each_descendant { |e| children << e }
        children
      end

      # Returns a flat list of all parent widgets, recursively
      def collect_ancestors : Array(Widget)
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
