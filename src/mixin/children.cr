module Crysterm
  module Mixin
    module Children
      # Widget's children `Widget`s.
      getter children = [] of Widget

      # O(1) membership index for `@children`, kept in sync by `insert`/`remove`.
      # Without it, `insert`'s "already a child?" guard was a linear
      # `@children.includes?` scan, making a batch of N appends O(N²) — which made
      # building thousands of widgets (e.g. one-per-cell demos on large terminals)
      # stall for seconds before the first frame. The only other place `@children`
      # is mutated directly is the reorder in `widget_index.cr`, which removes and
      # re-adds the same element and so leaves membership unchanged.
      @children_set = Set(Widget).new

      # Adds `element` to list of children. Convenience method identical to `append`
      def <<(widget : Widget)
        append widget
      end

      # Removes `element` from list of children. Convenience method identical to `remove`
      def >>(widget : Widget)
        remove widget
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

      # Inserts `element` into list of children widgets
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
        # No need to erase the removed element's old footprint: `Screen#_render`
        # clears the whole cell buffer before each frame, so once `element` is
        # gone from `@children` it simply stops being repainted.
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

      # Hook invoked after the children list changes (a *structural* change). The
      # CSS subsystem overrides this (on `Widget`/`Screen`) to mark styling dirty
      # and force a document re-parse, since structure can alter which selectors
      # match. No-op by default.
      protected def invalidate_css_tree : Nil
      end

      # Structural-change hook for damage tracking (a child was added/removed).
      # Overridden on `Widget` (forwards to its screen) and `Screen` (forces a
      # full re-composite next frame). No-op by default so the call site compiles
      # on any includer. See `OptimizationFlag::DamageTracking`.
      protected def _damage_invalidate_structure : Nil
      end

      # Returns true if `obj` is found in the list of parents, recursively
      def has_ancestor?(obj)
        el = self
        while el = el.parent
          return true if el.same? obj
        end
        false
      end

      # Returns true if `obj` is found in the list of children, recursively
      def has_descendant?(obj)
        @children.each do |el|
          return true if el.same? obj
          return true if el.has_descendant? obj
        end
        false
      end

      # Runs a particular block for self and all descendants, recursively
      def self_and_each_descendant(&block : Proc(Widget, Nil)) : Nil
        block.call self
        each_descendant &block
      end

      # Runs a particular block for all descendants, recursively
      def each_descendant(&block : Proc(Widget, Nil)) : Nil
        # Recurse by passing the already-captured `block` down, instead of
        # building an extra self-referential closure (`f`) — that closure was
        # allocated afresh on every call to this frequently-used traversal.
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
