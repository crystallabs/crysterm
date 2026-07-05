module Crysterm
  class Window
    # Resolves a CSS selector string to the live widgets it matches — the
    # runtime, query-anything counterpart to `#find_by_id`.
    #
    # Reuses the cascade's machinery: the widget tree is rendered to a CSS
    # document (`#to_html`, stamping each node with `data-uid`), the selector is
    # lowered with `CSS::Selectors.expand_types` (so bare type names like
    # `Button` match), compiled by the `html5` engine, and matched nodes are
    # mapped back to widgets by `data-uid`. Full Selectors-Level-3 grammar
    # applies — `#id`, `.class`, `Type`, combinators, `:nth-child`, attribute
    # selectors. An unparseable selector yields an empty array.
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
      widget.self_and_each_descendant { |w| index[w.uid.to_s] = w }
    end
  end
end
