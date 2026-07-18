require "./box"
require "../mixin/paged_container"

module Crysterm
  class Widget
    # Column of collapsible sections, modeled after Qt's `QToolBox`.
    #
    # Each item is a one-row clickable header plus a content widget. Exactly one
    # item is expanded at a time (`#current_index`): its content fills the space
    # between its header and the next, while every other item shows only its
    # header. Selecting a header — by click, or via `#current_index=` — expands
    # that item and collapses the rest. Emits `Event::CurrentChanged` (the new
    # index) and `Event::ItemSelected` (the header box and its index) on a change.
    #
    # ```
    # tb = Widget::ToolBox.new parent: window, width: 30, height: 16, style: Style.new(border: true)
    # tb.add_item "General", Widget::Box.new(content: "...")
    # tb.add_item "Advanced", Widget::Form.new
    # ```
    #
    # <!-- widget-examples:capture v1 -->
    # ![ToolBox screenshot](../../tests/widget/toolbox/toolbox.5s.apng)
    # <!-- /widget-examples:capture -->
    class ToolBox < Box
      # `#pages` holds each section's content widget; `#sections` carries the
      # extra per-item data (title + header box), parallel to it.
      include Mixin::PagedContainer

      # One section of a `ToolBox`.
      class Item
        property title : String
        property widget : Widget
        property header : Widget::Box

        def initialize(@title, @widget, @header)
        end
      end

      # The sections, in insertion order. Read-only — add via `#add_item`.
      getter sections = [] of Item

      # Markers drawn before a header's title. Unset (`nil`) resolves from the
      # `Glyphs` registry at the effective tier; assigning a `Char` pins it.
      setter expanded_char : Char? = nil
      setter collapsed_char : Char? = nil

      # :ditto:
      def expanded_char : Char
        @expanded_char || glyph(Glyphs::Role::TreeExpanded)
      end

      # :ditto:
      def collapsed_char : Char
        @collapsed_char || glyph(Glyphs::Role::TreeCollapsed)
      end

      def initialize(**box)
        super **box
      end

      # The `glyph_key` the header markers (expand/collapse arrows) were baked
      # from; `#refresh_glyphs` rebuilds them when it moves (a retheme, or the
      # post-probe tier upgrade — widgets are built before the window probes).
      @_glyph_key : {String?, Glyphs::Tier, UInt64}?

      # Relayout on every paint: section heights depend on the widget's resolved
      # inner size, only known once coordinates are computed.
      def render(with_children = true)
        refresh_glyphs
        relayout
        super
      end

      # Rebuilds the header markers when the resolved glyphs changed out from
      # under them; a no-op on the steady-state frame.
      private def refresh_glyphs : Nil
        key = glyph_key
        if @_glyph_key != key
          @_glyph_key = key
          refresh_headers
        end
      end

      # Appends a section titled *title* with body *widget*. Title-first argument
      # order, matching every other container add-verb in the toolkit (a
      # deliberate, uniform deviation from Qt's widget-first `addItem`). The first
      # item added becomes current. Returns `self`.
      def add_item(title : String, widget : Widget) : self
        # The header must start visible regardless of the toolbox's own state:
        # `Widget#hide` persists `visible = false` into `style`, so a header
        # created while the toolbox is hidden would dup that hidden state and
        # never be shown again — `#relayout` only toggles section *content*
        # widgets — leaving a permanently blank, unclickable title row.
        st = style.dup
        st.visible = true
        header = Widget::Box.new(
          parent: self,
          left: 0, right: 0, height: 1,
          content: header_text(title, false),
          focus_on_click: false,
          style: st,
        )

        index = @sections.size
        header.on(::Crysterm::Event::Click) { self.current_index = index }

        append widget

        @sections << Item.new(title, widget, header)
        @pages << widget

        # `#register_page` raises the first item added and hides every later one;
        # `#relayout` then gives the expanded one its rows.
        register_page widget
        relayout

        self
      end

      private def header_text(title : String, expanded : Bool) : String
        "#{expanded ? expanded_char : collapsed_char} #{title}"
      end

      # Re-marks the headers, re-fits the expanded section, and reports the
      # header that was picked via `Event::ItemSelected`, which carries the header
      # box that `Event::CurrentChanged` has no room for.
      protected def after_show_index(index : Int) : Nil
        refresh_headers
        relayout
        emit ::Crysterm::Event::ItemSelected, @sections[index].header, index
      end

      # Refreshes each header's marker to match the current expansion.
      private def refresh_headers : Nil
        @sections.each_with_index do |item, i|
          item.header.set_content header_text(item.title, i == @current_index)
        end
      end

      # Positions every header and the single expanded content widget. Headers
      # stack one row each; the expanded item's content takes the leftover rows
      # between its header and the next.
      private def relayout : Nil
        n = @sections.size
        return if n == 0

        inner = (aheight - ivertical) rescue (height.as?(Int) || n)
        page_height = Math.max(0, inner - n)

        y = 0
        @sections.each_with_index do |item, i|
          item.header.top = y
          y += 1
          if i == @current_index
            item.widget.top = y
            item.widget.left = 0
            item.widget.right = 0
            item.widget.height = page_height
            item.widget.show
            y += page_height
          else
            item.widget.hide
          end
        end
      end
    end
  end
end
