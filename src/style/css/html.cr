module Crysterm
  # The CSS styling subsystem.
  #
  # Styling is resolved by rendering the live widget tree into a tiny HTML
  # document (`#to_html`), handing that document to the `html5` shard's
  # Selectors-Level-3 engine for matching, and folding the matched rules'
  # declarations into the `Style`/`Styles` the renderer already consumes. The
  # document is cheap to (re)generate, so it is rebuilt on demand rather than
  # kept in sync incrementally.
  #
  # This file defines only the document builder; selector matching, the
  # stylesheet model, and the cascade live alongside it.
  module CSS
    # Escapes a value for safe inclusion inside a double-quoted HTML attribute.
    def self.escape_attr(value : String) : String
      value.gsub('&', "&amp;").gsub('"', "&quot;").gsub('<', "&lt;")
    end
  end

  class Widget
    # Marks the owning screen's styling dirty so the cascade re-runs on the next
    # render. Called whenever something selector-relevant changes — the tree
    # shape (via `Mixin::Children`), a widget's classes/id (`Mixin::Css`), or an
    # intrinsic attribute (e.g. a checkbox's `checked`). A no-op while the widget
    # is detached; it will be styled when its subtree next attaches and renders.
    protected def invalidate_css : Nil
      screen?.try &.restyle_subtree(self)
    end

    # Structural-change variant (children added/removed): forces a document
    # re-parse in addition to recomputing the affected subtree.
    protected def invalidate_css_tree : Nil
      screen?.try &.restyle_structural(self)
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
    # Child widgets are emitted recursively, reproducing the tree structure the
    # descendant/child combinators rely on. No text content is emitted: CSS
    # Level 3 has no text-matching selectors, so it is unneeded (and avoids
    # escaping user content).
    def to_html(io : IO) : Nil
      # Matching is by class (the type chain is emitted as classes, and the
      # parser rewrites type selectors to class selectors), so the tag name is
      # cosmetic. Use the lowercased leaf type for a valid, readable tag.
      classes = css_all_classes
      # Tag is internal (matching is by class). Prefix with `w-` so it is always
      # a hyphenated *custom element*: this avoids HTML5's special parsing for
      # real element names like `table`/`input`/`select`, which would otherwise
      # foster-parent or drop the children we emit.
      tag = "w-" + classes.first.downcase
      io << '<' << tag
      io << " data-uid=\"" << uid << '"'
      if id = css_id
        io << " id=\"" << CSS.escape_attr(id) << '"'
      end
      # The current widget state is stamped as a `state-*` class so ancestor
      # state selectors (e.g. `Form:focus Button`, lowered to `.state-focused`)
      # match against the live tree.
      io << " class=\"" << CSS.escape_attr(classes.join(' ')) << " state-" << state.to_s.downcase << '"'
      css_attributes.each do |key, value|
        io << ' ' << key
        value.try { |v| io << "=\"" << CSS.escape_attr(v) << '"' }
      end
      io << '>'
      # Child widgets first, so they occupy clean `:nth-child` positions
      # (1..N) — important for list items / table rows styled positionally.
      children.each &.to_html(io)
      # Sub-element pseudo-nodes (scrollbar, track, ...) come after the children.
      # Each carries a `uid::slot` writeback key so the cascade can route its
      # computed style into the matching sub-`Style`, and is classed with the
      # capitalized slot name (e.g. `Scrollbar`), so `Scrollbar { ... }` (or
      # `Box Scrollbar { ... }`) styles it.
      css_sub_elements.each do |slot|
        io << "<w-" << slot << " data-uid=\"" << uid << "::" << slot << '"'
        io << " class=\"" << slot.capitalize << "\"></w-" << slot << '>'
      end
      io << "</" << tag << '>'
    end

    # :ditto:
    def to_html : String
      String.build { |io| to_html io }
    end

    # This widget's current attributes as parsed-node `HTML5::Attribute`s
    # (unescaped values, as the parser stores them) — the same set `#to_html`
    # serializes. Used to *patch* a cached parsed node in place instead of
    # re-parsing the whole document on an attribute-only change.
    def css_node_attributes : Array(HTML5::Attribute)
      attrs = [HTML5::Attribute.new("", "data-uid", uid.to_s)]
      if id = css_id
        attrs << HTML5::Attribute.new("", "id", id)
      end
      attrs << HTML5::Attribute.new("", "class", "#{css_all_classes.join(' ')} state-#{state.to_s.downcase}")
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
    def css_attributes : Hash(String, String?)
      {} of String => String?
    end

    # The named sub-`Style` slots this widget exposes as pseudo-element nodes in
    # the CSS document (matched by their capitalized name and written back into
    # the corresponding `Style` sub-style). The base widget exposes its
    # scrollbar/track (while scrolling is enabled) and `label` (when it has a
    # label); other widgets override to add their own (e.g. a table's
    # `cell`/`header`).
    def css_sub_elements : Array(String)
      slots = [] of String
      slots << "scrollbar" << "track" if scrollbar?
      slots << "label" if @_label
      slots
    end
  end

  class Screen
    # Serializes the whole screen as the root of the CSS document: a `w-screen`
    # element wrapping every top-level widget's subtree.
    def to_html(io : IO) : Nil
      io << "<w-screen>"
      children.each &.to_html(io)
      io << "</w-screen>"
    end

    # :ditto:
    def to_html : String
      String.build { |io| to_html io }
    end
  end
end
