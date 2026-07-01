module Crysterm
  # Loads a *layout DOM* (see `dom.cr`) back into a live widget tree.
  #
  # The reverse of `Widget#to_layout_html`: parse the HTML with the same
  # `html5` engine the cascade uses, resolve each element's tag to a widget
  # class via `REGISTRY`, instantiate it, replay its attributes through
  # `Widget#dom_apply`, and recurse into element children.
  #
  # Crystal has no runtime reflection, so the tag -> class map must be built at
  # compile time. Rather than a hand-maintained list, the registry is populated
  # by a `macro finished` sweep that auto-discovers widgets *by namespace*:
  # every concrete `Crysterm::Widget::*` is loadable (minus the `SKIP`
  # exclusions). The leaf type name (lowercased) is the key, matching the
  # `w-<leaf>` tag `#to_layout_html` emits. A new widget under `Widget::` is
  # loadable with no extra wiring.
  #
  #     window = Window.new
  #     window.load_layout_file "ui.html"
  #     window.find_by_id("ok").try &.on(Event::Click) { ... }
  #     window.exec
  module DOM
    # Builds a widget already bound to the window it will live on. The widget is
    # created detached; the loader appends it into the tree afterwards.
    alias Factory = Proc(::Crysterm::Window, ::Crysterm::Widget)

    # `Crysterm::Widget::*` widgets that namespace-based opt-in would otherwise
    # register, but must NOT be: each builds its own internal child subtree in
    # its constructor, so re-appending serialized children on load would
    # double the subtree. The round-trip invariant spec
    # (`spec/dom_registry_spec.cr`) fails loudly if a new self-populating
    # widget slips through.
    SKIP = %w[
      canvas colordialog compose dockwidget donut headerbar linechart
      listtable loading map prompt question splashscreen statusbar
      tabwidget wizard
    ]

    # Tag (leaf type name, lowercased) -> widget factory, built lazily on first
    # use. The population sweep (`#fill_registry`, defined by a top-level
    # `macro finished` at the bottom of this file) runs once all subclasses
    # are known; building lazily (rather than at program-start) means
    # top-level callers see a full registry too.
    @@registry : Hash(String, Factory)?

    def self.registry : Hash(String, Factory)
      @@registry ||= begin
        reg = {} of String => Factory
        fill_registry reg
        reg
      end
    end

    # Parses `html` and builds its top-level widgets onto `window` (or, when
    # `parent` is given, as children of `parent`). Returns the widgets created
    # at the top level. Unknown tags (not in the registry) are skipped, so a
    # CSS-document dump or an enriched file still loads what it can.
    def self.load(html : String, window : ::Crysterm::Window, parent : ::Crysterm::Widget? = nil) : Array(::Crysterm::Widget)
      doc = HTML5.parse(html)
      # Self-contained layouts: any inline `<style>` is handed to the
      # stylesheet parser. Only on a top-level load — appended fragments keep
      # the page's existing styles.
      if parent.nil?
        css = String.build { |io| collect_style_css doc, io }
        window.add_inline_stylesheet css unless css.blank?
      end
      # The parser wraps content in <html><body>...; prefer our own `w-window`
      # root, else fall back to the synthesized `body` so a bare fragment (no
      # `w-window` wrapper) still yields its top-level widgets.
      root = find_element(doc, "w-window") || find_element(doc, "body") || doc
      built = [] of ::Crysterm::Widget
      each_element_child(root) do |node|
        next unless widget = build(node, window)
        (parent || window).append widget
        built << widget
      end
      built
    end

    # Concatenates the text of every `<style>` element in the document (the
    # parser keeps a `<style>`'s body as a raw text child).
    private def self.collect_style_css(node : HTML5::Node, io : IO) : Nil
      if node.element? && node.data == "style"
        child = node.first_child
        while child
          io << child.data << '\n' if child.text?
          child = child.next_sibling
        end
        return
      end
      child = node.first_child
      while child
        collect_style_css child, io
        child = child.next_sibling
      end
    end

    # Recursively constructs the widget for one element node and its subtree.
    private def self.build(node : HTML5::Node, window : ::Crysterm::Window) : ::Crysterm::Widget?
      type = node.data.lchop("w-")
      return nil unless factory = registry[type]?
      widget = factory.call(window)
      node.attr.each { |a| widget.dom_apply(a.key, a.val) }
      each_element_child(node) do |child|
        build(child, window).try { |c| widget.append c }
      end
      widget
    end

    # Depth-first search for the first element node named `name`.
    private def self.find_element(node : HTML5::Node, name : String) : HTML5::Node?
      return node if node.element? && node.data == name
      child = node.first_child
      while child
        if found = find_element(child, name)
          return found
        end
        child = child.next_sibling
      end
      nil
    end

    # Yields each element (non-text, non-comment) child of `node` in order.
    private def self.each_element_child(node : HTML5::Node, & : HTML5::Node ->) : Nil
      child = node.first_child
      while child
        yield child if child.element?
        child = child.next_sibling
      end
    end
  end

  class Window
    # Builds the widgets described by the layout-DOM `html` onto this window.
    # Returns the top-level widgets created. See `DOM.load`.
    def load_layout(html : String) : Array(Widget)
      DOM.load(html, self)
    end

    # Loads a layout-DOM file (see `#load_layout`) by path.
    def load_layout_file(path : String) : Array(Widget)
      load_layout File.read(path)
    end
  end
end

# Defines `DOM.fill_registry` once the whole program is parsed (so
# `all_subclasses` is complete). Must be at the top level — a `macro finished`
# nested in a module is not honored. Only *defines* the populating method;
# `DOM.registry` calls it lazily.
macro finished
  def Crysterm::DOM.fill_registry(reg) : Nil
    {% for t in Crysterm::Widget.all_subclasses %}
      {% leaf = t.name.split("::").last.downcase %}
      # Opt-in is by namespace: every concrete `Crysterm::Widget::*` is
      # loadable, except the `SKIP` exclusions (self-populating composites).
      {% if t.name.starts_with?("Crysterm::Widget::") && !t.abstract? && !Crysterm::DOM::SKIP.includes?(leaf) %}
        reg[{{ leaf }}] = ->(window : ::Crysterm::Window) { {{ t }}.new(window: window).as(::Crysterm::Widget) }
      {% end %}
    {% end %}
  end
end
