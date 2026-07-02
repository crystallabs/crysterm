module Crysterm
  # The CSS styling subsystem.
  #
  # Styling is resolved by rendering the live widget tree into a tiny HTML
  # document (`#to_html`), handing it to the `html5` shard's Selectors-Level-3
  # engine for matching, then folding matched rules' declarations into the
  # `Style`/`Styles` the renderer consumes. Cheap to regenerate, so it's
  # rebuilt on demand rather than kept in sync incrementally.
  #
  # This file defines only the document builder; selector matching, the
  # stylesheet model, and the cascade live alongside it.
  module CSS
    # Escapes a value for safe inclusion inside a double-quoted HTML attribute.
    # Fast path: skips the allocating `gsub`s when none of the special chars appear.
    def self.escape_attr(value : String) : String
      return value unless value.includes?('&') || value.includes?('"') || value.includes?('<')
      value.gsub('&', "&amp;").gsub('"', "&quot;").gsub('<', "&lt;")
    end
  end

  class Widget
    # Marks the owning window's styling dirty so the cascade re-runs on the next
    # render. Called whenever something selector-relevant changes — the tree
    # shape (via `Mixin::Children`), a widget's classes/id (`Mixin::Css`), or an
    # intrinsic attribute (e.g. a checkbox's `checked`). A no-op while the widget
    # is detached; it will be styled when its subtree next attaches and renders.
    protected def invalidate_css : Nil
      window?.try &.restyle_subtree(self)
    end

    # Structural-change variant (children added/removed): forces a document
    # re-parse in addition to recomputing the affected subtree.
    protected def invalidate_css_tree : Nil
      window?.try &.restyle_structural(self)
    end

    # Serializes this widget and its subtree into the CSS document.
    #
    # Each widget becomes one element whose tag is its leaf type class (e.g.
    # `w-button`), carrying:
    #
    # * `data-uid` — the stable writeback key mapping the node back to this
    #   widget (see `Mixin::Css`);
    # * `id` — the optional user-facing `#css_id`, when set;
    # * `class` — the full type chain plus user classes (`#css_all_classes`);
    # * any intrinsic attributes from `#css_attributes`, enabling attribute
    #   selectors such as `.w-checkbox[checked]`.
    #
    # Child widgets are emitted recursively to preserve descendant/child
    # combinator semantics. No text content is emitted: CSS Level 3 has no
    # text-matching selectors.
    #
    # When *structural* is true, the sub-element/extra pseudo-nodes are omitted,
    # yielding a document whose direct children are only real child widgets. The
    # cascade matches backward/only structural pseudo-classes (`:last-child`,
    # `:nth-last-child`, `:only-child`, `:last-of-type`) against this variant so
    # those pseudos count real children only — a trailing `<w-scrollbar>` or a
    # `Menu`'s `<w-separator>` must not occupy a real child's last-child slot.
    def to_html(io : IO, structural : Bool = false) : Nil
      # Matching is by class (the type chain is emitted as classes, and the
      # parser rewrites type selectors to class selectors), so the tag name is
      # cosmetic. Use the lowercased leaf type for a valid, readable tag.
      classes = css_all_classes
      # Tag is internal (matching is by class); `#css_tag` is a hyphenated custom
      # element to avoid HTML5's special parsing of real names like `table`/`select`,
      # which would foster-parent or drop the children we emit.
      tag = css_tag
      io << '<' << tag
      io << " data-uid=\"" << uid << '"'
      if id = css_id
        io << " id=\"" << CSS.escape_attr(id) << '"'
      end
      # Widget state is stamped as a `state-*` class so ancestor state selectors
      # (e.g. `Form:focus Button`, lowered to `.state-focused`) match the live tree.
      # Streamed directly (no `join`) since this runs per widget per cascade.
      io << " class=\""
      classes.each_with_index do |cls, i|
        io << ' ' if i > 0
        io << CSS.escape_attr(cls)
      end
      io << ' ' << state.css_class << '"'
      css_attributes.each do |key, value|
        io << ' ' << key
        value.try { |v| io << "=\"" << CSS.escape_attr(v) << '"' }
      end
      io << '>'
      # Child widgets first, so they occupy clean `:nth-child` positions
      # (1..N) — important for list items / table rows styled positionally.
      children.each &.to_html(io, structural)
      unless structural
        # Sub-element pseudo-nodes (scrollbar, track, ...) come after the children.
        # Each carries a `uid::slot` writeback key routing computed style back into
        # the matching sub-`Style`, classed with the capitalized slot name (e.g.
        # `Scrollbar`) so `Scrollbar { ... }` / `Box Scrollbar { ... }` styles it.
        css_sub_elements.each do |slot|
          io << "<w-" << slot << " data-uid=\"" << uid << "::" << slot << '"'
          io << " class=\"" << slot.capitalize << "\"></w-" << slot << '>'
        end
        # Extra widget-specific nodes (e.g. a table's per-cell grid).
        css_render_extra io
      end
      io << "</" << tag << '>'
    end

    # Extra DOM nodes a widget contributes beyond its sub-elements — e.g. a
    # `Table`'s `Row`/`Cell` grid. Default: nothing.
    def css_render_extra(io : IO) : Nil
    end

    # Shared empty slot list for widgets with no sub-element/extra slots, so the
    # common case costs no per-node allocation. Overrides build a new list
    # (`super + [...]`) rather than mutating this.
    EMPTY_CSS_SLOTS = [] of String

    # Extra writeback slots (paired with `#css_render_extra`) so the cascade can
    # route each extra node's computed style back. A `Table` returns its cell
    # slots (`"cell:0:1"`, ...). Default: none.
    def css_extra_slots : Array(String)
      EMPTY_CSS_SLOTS
    end

    # Base style for an extra *slot* (cascade applies rules onto this) and the
    # writeback for the computed result. Default: the widget's style / no-op.
    # `Table` overrides these to map cell slots to its per-cell map.
    def css_extra_base_style(slot : String) : Style
      style
    end

    # :ditto:
    def css_set_extra_style(slot : String, computed : Style) : Nil
    end

    # Clears any extra computed state (e.g. a `Table`'s per-cell styles) when the
    # cascade resets the widget. Default: nothing.
    def css_reset_extra : Nil
    end

    # :ditto:
    def to_html(structural : Bool = false) : String
      String.build { |io| to_html io, structural }
    end

    # This widget's current attributes as parsed-node `HTML5::Attribute`s, matching
    # what `#to_html` serializes. Used to patch a cached parsed node in place
    # instead of re-parsing the whole document on an attribute-only change.
    def css_node_attributes : Array(HTML5::Attribute)
      attrs = [HTML5::Attribute.new("", "data-uid", uid_s)]
      if id = css_id
        attrs << HTML5::Attribute.new("", "id", id)
      end
      attrs << HTML5::Attribute.new("", "class", "#{css_all_classes.join(' ')} #{state.css_class}")
      css_attributes.each do |key, value|
        attrs << HTML5::Attribute.new("", key, value || "")
      end
      attrs
    end

    # Intrinsic widget properties exposed as HTML attributes so they can be
    # targeted by attribute selectors (e.g. `[checked]`, `[disabled]`). A `nil`
    # value emits a bare boolean attribute; a string emits `key="value"`.
    #
    # The base widget exposes none; subclasses override to surface their own
    # state (e.g. `Button` exposes `checked`).
    #
    # Returns a shared empty hash so the common attribute-less widget (a plain
    # `Box`) costs no per-node allocation. Subclasses must not mutate a `super`
    # result (it may be this shared constant); build a fresh hash or `#merge`.
    EMPTY_CSS_ATTRIBUTES = {} of String => String?

    def css_attributes : Hash(String, String?)
      EMPTY_CSS_ATTRIBUTES
    end

    # The named sub-`Style` slots this widget exposes as pseudo-element nodes in
    # the CSS document (matched by their capitalized name, written back into the
    # corresponding `Style` sub-style). Base widget exposes scrollbar/track (while
    # scrolling is enabled) and `label` (when set); others override (e.g. a
    # table's `cell`/`header`).
    def css_sub_elements : Array(String)
      # Common case (no scrollbar, no label) reuses the shared empty list.
      return EMPTY_CSS_SLOTS unless scrollbar? || @_label
      slots = [] of String
      slots << "scrollbar" << "track" if scrollbar?
      slots << "label" if @_label
      slots
    end
  end

  class Window
    # Serializes the window as the root of the CSS document: a `w-window`
    # element wrapping every top-level widget's subtree.
    def to_html(io : IO, structural : Bool = false) : Nil
      io << "<w-window>"
      children.each &.to_html(io, structural)
      io << "</w-window>"
    end

    # :ditto:
    def to_html(structural : Bool = false) : String
      String.build { |io| to_html io, structural }
    end
  end
end
