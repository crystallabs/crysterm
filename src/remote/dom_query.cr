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

      doc, index = resolve_document
      nodes = (compiled.select(doc) rescue [] of HTML5::Node)
      return [] of Widget if nodes.empty?

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

    # The `#to_html` string the parse cache below was built from. Byte-identity
    # against it is the reuse key: every selector-relevant mutation (tree shape, a
    # widget's id/classes, an intrinsic/state attribute) changes the emitted
    # document, so a differing string re-parses.
    @resolve_doc_string : String?
    # Parsed CSS document, cached alongside the `data-uid -> widget` index built
    # over the same tree.
    @resolve_doc : HTML5::Node?
    @resolve_index : Hash(String, Widget)?

    # Returns the parsed document plus its `data-uid -> widget` index, reusing
    # the cached pair when the current `#to_html` is byte-identical to the one it
    # was built from, else re-parsing and re-indexing and caching both.
    #
    # This lets a burst of commands over an unchanged tree parse and index once
    # rather than per command. An identical `#to_html` string is, by
    # construction, the identical tree of live widgets at identical uids, so the
    # cached index can't return a stale node or a wrong widget.
    #
    # `#to_html` itself is still serialized each call: that tree walk is cheap
    # next to `HTML5.parse`, and skipping it too would need a monotonic
    # per-mutation counter living outside this subsystem.
    private def resolve_document : {HTML5::Node, Hash(String, Widget)}
      html = to_html
      doc = @resolve_doc
      index = @resolve_index
      if doc && index && @resolve_doc_string == html
        return {doc, index}
      end
      doc = HTML5.parse(html)
      index = {} of String => Widget
      children.each { |child| dom_index_subtree child, index }
      @resolve_doc_string = html
      @resolve_doc = doc
      @resolve_index = index
      {doc, index}
    end

    private def dom_index_subtree(widget : Widget, index : Hash(String, Widget)) : Nil
      widget.self_and_each_descendant { |w| index[w.uid.to_s] = w }
    end
  end
end
