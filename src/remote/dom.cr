module Crysterm
  # The *layout DOM* — an "extended", round-trippable sibling of the CSS
  # document (`#to_html`).
  #
  # `#to_html` emits the minimal tree the cascade needs to *match* selectors:
  # classes, id, state, a few intrinsic attributes. It is intentionally lossy —
  # geometry, content and construction options are dropped, and it cannot be
  # parsed back into widgets.
  #
  # The layout DOM (`#to_layout_html`) is a superset that carries enough state
  # to *reconstruct* a widget: its position/size, content, name, and any
  # per-widget reproducible state a subclass chooses to expose. Paired with the
  # `DOM` loader (see `dom_loader.cr`), it lets a GUI's structure live in an
  # `.html` file — structure + geometry in the HTML, appearance in the
  # stylesheet (just like the web), with behavior wired up in code afterwards by
  # looking widgets up via their `#css_id`.
  #
  # Two hooks make this extensible per widget, mirroring `#css_attributes`:
  #
  # * `#dom_attributes` — the construction state to serialize. Subclasses
  #   override and `super.merge(...)` to add their own (see `dom_widgets.cr`).
  # * `#dom_apply` — applies one parsed attribute back onto the widget.
  #   Subclasses override to handle their own keys, then fall through to `super`.
  class Widget
    # Construction state serialized into the layout DOM as element attributes.
    #
    # Only the *inputs* a user would set are emitted (never computed values like
    # `#aleft`/`#awidth`), and only when they differ from the constructor
    # default — so the output stays small and reads like hand-written markup.
    # A `nil`-valued entry emits a bare boolean attribute, as in
    # `#css_attributes`.
    def dom_attributes : Hash(String, String?)
      attrs = {} of String => String?
      (v = @left) && (attrs["left"] = v.to_s)
      (v = @top) && (attrs["top"] = v.to_s)
      (v = @right) && (attrs["right"] = v.to_s)
      (v = @bottom) && (attrs["bottom"] = v.to_s)
      (v = @width) && (attrs["width"] = v.to_s)
      (v = @height) && (attrs["height"] = v.to_s)
      if n = name
        attrs["name"] = n unless n.empty?
      end
      attrs["parse-tags"] = "true" if parse_tags?
      attrs["wrap-content"] = "false" unless wrap_content?
      c = content
      attrs["content"] = c unless c.empty?
      # Named-action bindings (`onclick="save"`), so they survive a round-trip
      # and the HTTP bridge can re-wire them.
      dom_events.each { |event, action| attrs["on#{event}"] = action }
      attrs
    end

    # Maps a UI event name (`"click"`, `"submit"`, ...) to the *named action*
    # declared for it in the layout (`onclick="save"` -> `{"click" => "save"}`).
    # The action name is a language-agnostic handle the HTTP bridge sends to an
    # out-of-process handler; it carries no code of its own.
    getter dom_events = {} of String => String

    # Applies a single parsed layout-DOM attribute back onto this widget.
    # Returns `true` if the key was recognized. Subclasses override to handle
    # their own keys (see `dom_widgets.cr`) and delegate the rest via `super`.
    def dom_apply(key : String, value : String?) : Bool
      case key
      when "left"              then self.left = dom_coerce_dimension(value)
      when "top"               then self.top = dom_coerce_dimension(value)
      when "width"             then self.width = dom_coerce_dimension(value)
      when "height"            then self.height = dom_coerce_dimension(value)
      when "right"             then value.try(&.to_i?).try { |i| self.right = i }
      when "bottom"            then value.try(&.to_i?).try { |i| self.bottom = i }
      when "name"              then self.name = value
      when "parse-tags"        then self.parse_tags = (value == "true")
      when "wrap-content"      then self.wrap_content = (value != "false")
      when "content"           then set_content(value || "")
      when "id"                then self.css_id = value
      when "class"             then value.try &.split.each { |c| add_css_class c unless c.empty? }
      when .starts_with?("on") then dom_events[key.lchop("on")] = value || "" if key.size > 2
        # `data-uid`/`state-*` and friends belong to the CSS document, not here;
        # silently ignore anything unrecognized so an enriched file still loads.
      else
        return false
      end
      true
    end

    # Coerces a position/size attribute string into the `Int32 | String | Nil`
    # the geometry setters accept: a bare integer becomes an `Int32`, anything
    # else (`"center"`, `"50%"`, `"100%-2"`) stays a `String`.
    protected def dom_coerce_dimension(value : String?) : Int32 | String | Nil
      return nil unless value
      value.to_i? || value
    end

    # Serializes this widget and its subtree as layout DOM. Unlike `#to_html`,
    # the sub-element pseudo-nodes (scrollbar, list item, table cells) are *not*
    # emitted: they are styling slots, not reconstructable widgets.
    def to_layout_html(io : IO, indent : Int32 = 0) : Nil
      pad = " " * indent
      tag = "w-" + css_type_classes.first.downcase
      io << pad << '<' << tag
      if id = css_id
        io << " id=\"" << CSS.escape_attr(id) << '"'
      end
      unless css_classes.empty?
        io << " class=\"" << CSS.escape_attr(css_classes.to_a.join(' ')) << '"'
      end
      dom_attributes.each do |key, value|
        io << ' ' << key
        value.try { |v| io << "=\"" << CSS.escape_attr(v) << '"' }
      end
      if children.empty?
        io << "></" << tag << ">\n"
      else
        io << ">\n"
        children.each &.to_layout_html(io, indent + 2)
        io << pad << "</" << tag << ">\n"
      end
    end

    # :ditto:
    def to_layout_html : String
      String.build { |io| to_layout_html io }
    end

    # Finds the first widget in this subtree (self included) whose `#css_id`
    # matches `id`. The intended way to grab a handle on a widget loaded from a
    # layout file in order to attach event handlers.
    def find_by_id(id : String) : Widget?
      return self if css_id == id
      children.each do |child|
        if found = child.find_by_id(id)
          return found
        end
      end
      nil
    end
  end

  class Screen
    # Serializes the whole screen as layout DOM: a `w-screen` root wrapping each
    # top-level widget's reconstructable subtree.
    def to_layout_html(io : IO) : Nil
      io << "<w-screen>\n"
      children.each &.to_layout_html(io, 2)
      io << "</w-screen>\n"
    end

    # :ditto:
    def to_layout_html : String
      String.build { |io| to_layout_html io }
    end

    # Finds the first widget on this screen whose `#css_id` matches `id`.
    def find_by_id(id : String) : Widget?
      children.each do |child|
        if found = child.find_by_id(id)
          return found
        end
      end
      nil
    end
  end
end
