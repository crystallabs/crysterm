require "./box"

module Crysterm
  class Widget
    # Column of collapsible sections, modeled after Qt's `QToolBox`.
    #
    # Each item is a one-row clickable header plus a content widget. Exactly one
    # item is expanded at a time (`#current_index`): its content fills the space
    # between its header and the next, while every other item shows only its
    # header. Selecting a header — by click, or via `#current=` — expands that
    # item and collapses the rest. Emits `Event::SelectItem` (the header box and
    # its index) on a change.
    #
    # ```
    # tb = Widget::ToolBox.new parent: window, width: 30, height: 16, style: Style.new(border: true)
    # tb.add_item "General", Widget::Box.new(content: "...")
    # tb.add_item "Advanced", Widget::Form.new
    # ```
    #
    # <!-- widget-examples:capture v1 -->
    # ![ToolBox screenshot](../../examples/widget/toolbox/toolbox-capture5s.apng)
    # <!-- /widget-examples:capture -->
    class ToolBox < Box
      # One section of a `ToolBox`.
      class Item
        property title : String
        property widget : Widget
        property header : Widget::Box

        def initialize(@title, @widget, @header)
        end
      end

      getter sections = [] of Item

      # Index of the expanded item (`-1` until the first item is added).
      getter current_index : Int32 = -1

      # Markers drawn before a header's title.
      property expanded_char : Char = '▾'
      property collapsed_char : Char = '▸'

      def initialize(**box)
        super **box
      end

      # Relayout on every paint: the section heights depend on the widget's
      # resolved inner size, which is only known once coordinates are computed
      # (so doing it here also fixes up the very first frame and any resize).
      def render(with_children = true)
        relayout
        super
      end

      # Appends a section titled *title* with body *widget*. The first item added
      # becomes current. Returns its index.
      def add_item(title : String, widget : Widget) : Int32
        header = Widget::Box.new(
          parent: self,
          left: 0, right: 0, height: 1,
          content: header_text(title, false),
          focus_on_click: false,
          style: style.dup,
        )

        index = @sections.size
        header.on(::Crysterm::Event::Click) { self.current = index }

        append widget

        @sections << Item.new(title, widget, header)

        if @current_index < 0
          self.current = 0
        else
          widget.hide
          relayout
        end

        index
      end

      private def header_text(title : String, expanded : Bool) : String
        "#{expanded ? @expanded_char : @collapsed_char} #{title}"
      end

      # The currently expanded item's content widget, or `nil` when empty.
      def current_widget : Widget?
        @sections[@current_index]?.try &.widget
      end

      # Expands the item at *index*, collapsing the others.
      def current=(index : Int) : Nil
        return unless 0 <= index < @sections.size
        return if index == @current_index

        @current_index = index.to_i
        refresh_headers
        relayout
        emit ::Crysterm::Event::SelectItem, @sections[@current_index].header, @current_index
        request_render
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

        inner = (aheight - iheight) rescue (height.as?(Int) || n)
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
