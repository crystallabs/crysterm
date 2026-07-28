require "html5"

module Crysterm
  # Shared traversal/attribute helpers over parsed `html5`-shard nodes
  # (`HTML5::Node`), used by both HTML consumers — `TextHtml`'s rich-text
  # importer and the layout-DOM loader (`Crysterm::DOM`). `include` it for
  # instance-method access, `extend` it for module-level access.
  module HtmlNodeUtil
    # Yields each direct child of *node* — element, text or comment — in
    # document order.
    def each_child(node : HTML5::Node, & : HTML5::Node ->) : Nil
      child = node.first_child
      while child
        yield child
        child = child.next_sibling
      end
    end

    # Yields each element (non-text, non-comment) child of *node* in order.
    def each_element_child(node : HTML5::Node, & : HTML5::Node ->) : Nil
      each_child(node) { |child| yield child if child.element? }
    end

    # Depth-first (pre-order) search for the first element node named *name*,
    # starting at (and including) *node* itself.
    def find_element(node : HTML5::Node, name : String) : HTML5::Node?
      return node if node.element? && node.data == name
      each_child(node) do |child|
        if found = find_element(child, name)
          return found
        end
      end
      nil
    end

    # The value of *node*'s attribute *key*, or nil when absent.
    def attr_val(node : HTML5::Node, key : String) : String?
      node.attr.each do |a|
        return a.val if a.key == key
      end
      nil
    end
  end
end
