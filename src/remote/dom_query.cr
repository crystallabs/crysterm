module Crysterm
  class Screen
    # Resolves a CSS selector string to the live widgets it matches — the
    # runtime, query-anything counterpart to `#find_by_id`.
    #
    # Reuses the exact machinery the cascade uses for styling: the widget tree
    # is rendered to the CSS document (`#to_html`, which stamps each node with a
    # `data-uid`), the selector is lowered with `CSS::Selectors.expand_types`
    # (so bare type names like `Button` match), compiled by the `html5` engine,
    # and each matched node is mapped back to its widget by `data-uid`. So the
    # full Selectors-Level-3 grammar the stylesheet supports — `#id`, `.class`,
    # `Type`, descendant/child combinators, `:nth-child`, attribute selectors —
    # works here too. An unparseable selector yields an empty array.
    def resolve_selector(selector : String) : Array(Widget)
      compiled = ::CSS.compile(CSS::Selectors.expand_types(selector)) rescue nil
      return [] of Widget unless compiled

      doc = HTML5.parse(to_html)
      nodes = (compiled.select(doc) rescue [] of HTML5::Node)
      return [] of Widget if nodes.empty?

      index = {} of String => Widget
      children.each { |child| dom_index_subtree child, index }

      result = [] of Widget
      seen = Set(String).new
      nodes.each do |node|
        uid = node["data-uid"]?.try(&.val)
        next unless uid
        next unless seen.add?(uid)
        index[uid]?.try { |w| result << w }
      end
      result
    end

    private def dom_index_subtree(widget : Widget, index : Hash(String, Widget)) : Nil
      index[widget.uid.to_s] = widget
      widget.children.each { |child| dom_index_subtree child, index }
    end
  end
end
