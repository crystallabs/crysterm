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

        # The header's "click → select this section" subscription. A re-armable
        # slot (rather than a bare `header.on`) so `#repoint_headers` can swap in
        # a handler capturing the section's new index after a removal shifts it,
        # without stacking a second handler or clobbering unrelated ones — the
        # `Subscription` twin of `TabWidget`'s per-command `callback=`.
        getter click = Subscription.new

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
        # `#strip_frame!` clears any border/padding the toolbox's own style
        # carries: a height-1 header with a border has a negative content
        # interior, so the title would never paint (only border glyphs would
        # show on the single row).
        st = style.stripped_frame(visible: true)
        header = Widget::Box.new(
          parent: self,
          left: 0, right: 0, height: 1,
          content: header_text(title, false),
          focus_on_click: false,
          style: st,
        )

        index = @sections.size
        item = Item.new(title, widget, header)
        item.click.on(header, ::Crysterm::Event::Click) { self.current_index = index }

        append widget

        @sections << item
        @pages << widget

        # `#register_page` raises the first item added and hides every later one;
        # `#relayout` then gives the expanded one its rows.
        register_page widget
        relayout

        self
      end

      # Removes the section at *index*, detaching (not destroying) its content
      # widget and returning it — Qt's `QToolBox#removeItem`. Its header row is
      # dropped, the surviving headers re-point at their new indices, and a valid
      # section is kept current. Out of range is a no-op. Thin like
      # `Splitter#remove_widget`: the bookkeeping lives in the `#remove` override
      # so every detach path shares it.
      def remove_item(index : Int) : Widget?
        return unless 0 <= index < @pages.size
        page = @pages[index]
        remove page
        page
      end

      # :ditto:, addressing the section by *title* (the first match). No section
      # with that title is a no-op.
      def remove_item(title : String) : Widget?
        if i = @sections.index { |it| it.title == title }
          remove_item i
        end
      end

      # Catches a section's content widget detached by any path — `#remove_item`,
      # a direct `widget.destroy` or `#detach_from_tree` (both land here via
      # `parent.remove(self)`), a bare `#remove` — and tears the section down so
      # `@sections`/`@pages`/the selection and the header row never outlive it.
      # Header rows and any other non-section child pass straight through (the
      # `remove item.header` below re-enters here and is a no-op for them).
      def remove(element)
        idx = @pages.index element
        # Snapshot the current section before the delete so the reclamp can keep
        # it current when it wasn't the one removed.
        cur = current_widget
        super
        if idx
          item = @sections.delete_at idx
          @pages.delete_at idx
          item.click.off # drop the header's captured-index click handler
          remove item.header
          # Surviving headers capture an absolute index; re-point after the shift.
          repoint_headers
          # Reclamp — its `current_index=` runs `#after_show_index`, which
          # re-marks and re-stacks the headers (relayout) for free.
          reclamp_after_removal idx, cur
          emit ::Crysterm::Event::ItemRemoved
        end
      end

      # Re-points every header's click handler at its current index: the handlers
      # capture an absolute index when the section is added, which goes stale
      # after a removal shifts the sections. Twin of
      # `TabWidget#repoint_tab_callbacks`.
      private def repoint_headers : Nil
        @sections.each_with_index do |item, i|
          item.click.on(item.header, ::Crysterm::Event::Click) { self.current_index = i }
        end
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
