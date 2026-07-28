require "../text/html_node_util"

module Crysterm
  # Loads a *layout DOM* back into a live widget tree.
  #
  # The reverse of `Widget#to_layout_html`: parse the HTML with the same `html5`
  # engine the cascade uses, resolve each element's tag to a widget class via
  # `REGISTRY`, instantiate it, replay its attributes through `Widget#dom_apply`,
  # and recurse into element children.
  #
  # Crystal has no runtime reflection, so the tag -> class map must be built at
  # compile time. Rather than a hand-maintained list, the registry is populated
  # by a `macro finished` sweep that auto-discovers widgets *by namespace*:
  # every concrete `Crysterm::Widget::*` is loadable (minus classes annotated
  # `@[Crysterm::DOM::Skip]` — see the annotation's doc in `widget.cr`). The
  # leaf type name (lowercased) is the key, matching the `w-<leaf>` tag
  # `#to_layout_html` emits. A new widget under `Widget::` is loadable with no
  # extra wiring.
  #
  #     window = Window.new
  #     window.load_layout_file "ui.html"
  #     window.find_by_id("ok").try &.on(Event::Click) { ... }
  #     window.exec
  module DOM
    # Node traversal / attribute access (`each_child`, `each_element_child`,
    # `find_element`, ...) shared with `TextHtml`'s importer. `extend`, since
    # the loader is all module-level methods.
    extend ::Crysterm::HtmlNodeUtil

    # Builds a widget already bound to the window it will live on. The widget is
    # created detached; the loader appends it into the tree afterwards.
    alias Factory = Proc(::Crysterm::Window, ::Crysterm::Widget)

    # Widgets that namespace-based opt-in would otherwise register but must NOT
    # be are excluded per class, via the `@[Crysterm::DOM::Skip]` annotation on
    # the widget itself (declared in `widget.cr`; see its doc for the exclusion
    # reasons) — self-maintaining, unlike the hand-kept central list it
    # replaced (R-89). The `dom_registry_spec` round-trip invariant fails
    # loudly if a new self-populating widget slips through unannotated.

    # Tag (leaf type name, lowercased) -> widget factory, built lazily on first
    # use so that top-level callers also see a full registry.
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
    def self.load(html : String, window : ::Crysterm::Window, parent : ::Crysterm::Widget? = nil, *, replace_styles : Bool = false) : Array(::Crysterm::Widget)
      doc = HTML5.parse(html)
      # Self-contained layouts: any inline `<style>` is handed to the
      # stylesheet parser. Only when building at the top level (`parent.nil?`) —
      # a nested append keeps the page's existing styles untouched.
      #
      # Two distinct top-level modes, chosen by `replace_styles`:
      #  * whole-layout load / hot-reload (`load_layout`, `reload_layout` pass
      #    `replace_styles: true`) — the new layout *owns* the page, so its
      #    inline `<style>` replaces the previous one. Applied even when empty so
      #    a reload to a `<style>`-less layout drops the old rules (rather than
      #    leaving them stale) — `add_inline_stylesheet` clears via `css.presence`.
      #  * top-level append (bridge's selector-less `append`, default) — the
      #    fragment is added *onto* the existing page, so its `<style>` (if any)
      #    is merged in; a `<style>`-less fragment must NOT wipe the page's CSS.
      if parent.nil?
        css = String.build { |io| collect_style_css doc, io }
        if replace_styles
          window.add_inline_stylesheet css
        else
          window.merge_inline_stylesheet css
        end
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
        each_child(node) { |child| io << child.data << '\n' if child.text? }
        return
      end
      each_child(node) { |child| collect_style_css child, io }
    end

    # Recursively constructs the widget for one element node and its subtree.
    private def self.build(node : HTML5::Node, window : ::Crysterm::Window) : ::Crysterm::Widget?
      type = node.data.lchop("w-")
      return unless factory = registry[type]?
      widget = factory.call(window)
      # Attribute replay order is load-bearing, since `dom_apply` routes through
      # real setters:
      #   * `content` applies *last*. A widget whose value/format setter refreshes
      #     its own displayed text would otherwise clobber a serialized `content`,
      #     breaking the serialize -> load -> serialize round-trip.
      #   * `value` applies after all other attrs but before `content`. Attrs
      #     replay in initializer-arg order, and the ranged widgets declare `value`
      #     before `minimum`/`maximum`, so replaying it first would clamp it
      #     against the *default* range: `value=500 maximum=1000` would load as 100.
      content_attr = nil
      value_attr = nil
      node.attr.each do |a|
        case a.key
        when "content"
          content_attr = a
        when "value"
          value_attr = a
        else
          widget.dom_apply(a.key, a.val)
        end
      end
      value_attr.try { |a| widget.dom_apply(a.key, a.val) }
      content_attr.try { |a| widget.dom_apply(a.key, a.val) }
      # Hand-written markup can carry content as inner text (`<w-box>hi</w-box>`)
      # instead of the `content` attribute the serializer emits. Apply it with
      # attribute-`content` semantics (last, so it survives value/format
      # setters), attribute winning over inner text when both are present.
      if content_attr.nil?
        text = String.build do |io|
          each_child(node) { |child| io << child.data if child.text? }
        end
        # Whitespace-only inner text is the serializer's own pretty-printing
        # (newlines + indentation around element children), not content —
        # applying it would break the serialize -> load -> serialize
        # round-trip. Deliberate whitespace content survives as the `content`
        # attribute the serializer emits.
        widget.dom_apply("content", text) unless text.blank?
      end
      # Model-owned widgets (item views, action bars) rebuild their rows/
      # commands from replayed state, so their children are *not* reconstructable
      # box nodes: re-appending serialized `<w-box>` children would double the
      # rows — or, for a bar, attach dead ghost boxes bypassing the command
      # model. Mirrors the save-side skip; also gracefully drops the ghost
      # children present in snapshots taken before bars serialized `items`.
      unless widget.dom_owns_children?
        each_element_child(node) do |child|
          build(child, window).try { |c| widget.append c }
        end
      end
      widget
    end
  end

  class Window
    # Builds the widgets described by the layout-DOM `html` onto this window.
    # Returns the top-level widgets created. See `DOM.load`.
    def load_layout(html : String) : Array(Widget)
      # Whole-layout load: this markup owns the page, so its inline `<style>`
      # replaces any previously installed inline rules.
      DOM.load(html, self, replace_styles: true)
    end

    # Merges additional inline `<style>` CSS (from a top-level appended fragment)
    # into the page's existing inline rules, instead of replacing them. A no-op
    # for an empty fragment, so a selector-less `append` of `<style>`-less markup
    # leaves the page's CSS intact.
    def merge_inline_stylesheet(css : String) : Nil
      return if css.empty?
      existing = @css_inline_source
      add_inline_stylesheet(existing ? "#{existing}\n#{css}" : css)
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
    # The tag key is the widget's lowercased *leaf* type name (matching the
    # `w-<leaf>` tag `#css_tag`/`#to_layout_html` emit). Two widgets with the
    # same leaf under different namespaces (e.g. `Widget::ProgressBar` and
    # `Widget::Pine::ProgressBar`) therefore collide on one key. Rather than let
    # `all_subclasses` order decide non-deterministically (silently shadowing the
    # standard widget with a styled subclass, or vice versa), resolve the
    # collision at compile time: the *shallowest* namespace wins — the top-level
    # `Crysterm::Widget::ProgressBar` beats the nested `Pine` one, so a plain
    # `<w-progressbar>` always loads the standard widget.
    #
    # No namespaced load key (e.g. `pine-progressbar`) is added: `#css_tag` emits
    # only the leaf for the nested widget too, so a namespaced key could never be
    # produced by serialization and would break the `to_layout_html -> load`
    # round-trip invariant.
    {% chosen = {} of Nil => Nil %}
    {% for t in Crysterm::Widget.all_subclasses %}
      {% parts = t.name.split("::") %}
      {% leaf = parts.last.downcase %}
      # Opt-in is by namespace: every concrete `Crysterm::Widget::*` is
      # loadable, except classes annotated `@[Crysterm::DOM::Skip]`
      # (self-populating composites / no window-only constructor) and
      # generic widgets (e.g. `ListSelect(T)`), which can't be instantiated
      # without a type argument and have no stable tag name anyway.
      {% if t.name.starts_with?("Crysterm::Widget::") && !t.abstract? && t.type_vars.empty? && !t.annotation(Crysterm::DOM::Skip) %}
        # `parts.size` is the namespace depth (e.g. 3 for `Crysterm::Widget::X`,
        # 4 for `Crysterm::Widget::Pine::X`); keep the shallowest per leaf. Ties
        # (same depth, different module) keep the first seen — still deterministic.
        {% if !chosen[leaf] || parts.size < chosen[leaf][1] %}
          {% chosen[leaf] = {t, parts.size} %}
        {% end %}
      {% end %}
    {% end %}
    {% for leaf, info in chosen %}
      reg[{{ leaf }}] = ->(window : ::Crysterm::Window) { {{ info[0] }}.new(window: window).as(::Crysterm::Widget) }
    {% end %}
  end
end
