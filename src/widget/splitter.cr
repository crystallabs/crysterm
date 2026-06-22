require "./box"

module Crysterm
  class Widget
    # Two-pane container with a draggable divider, modeled after Qt's
    # `QSplitter`.
    #
    # Holds two child widgets side by side (`:horizontal`) or stacked
    # (`:vertical`), separated by a one-cell divider. Dragging the divider with
    # the mouse — or moving it with the arrow keys when it is focused — resizes
    # the panes; `#position` (the divider offset, in cells) can also be set
    # programmatically.
    #
    # ```
    # sp = Widget::Splitter.new parent: screen, width: 60, height: 20, position: 20
    # sp.split Widget::Box.new(content: "left"), Widget::Box.new(content: "right")
    # ```
    class Splitter < Box
      property orientation : Tput::Orientation = :horizontal

      getter pane1 : Widget?
      getter pane2 : Widget?

      # The divider widget between the two panes.
      getter! divider : Box

      @position : Int32 = 0

      def initialize(@orientation = @orientation, position = nil, **box)
        @position = position || 0

        super **box

        @divider = Box.new(
          parent: self,
          draggable: true,
          keys: true,
          top: 0,
          left: 0,
          width: 1,
          height: 1,
          style: Style.new(bg: "white"),
        )

        wire_divider

        # Lay out once the real size is known (a headless/just-constructed
        # splitter may not have a usable size yet).
        on(Crysterm::Event::Attach) { relayout }
        on(Crysterm::Event::Resize) { relayout; request_render }
      end

      def horizontal? : Bool
        @orientation.horizontal?
      end

      # Assigns the two panes and lays them out.
      def split(first : Widget, second : Widget) : self
        @pane1 = first
        @pane2 = second
        append first
        append second
        divider.front!
        @position = default_position if @position < 1
        layout
        self
      end

      def position : Int32
        @position
      end

      # Sets the divider offset (clamped to keep both panes at least one cell)
      # and re-lays out.
      def position=(value : Int32) : Int32
        @position = value.clamp(1, max_position)
        layout
        request_render
        @position
      end

      # Total span (width or height) along the split axis, falling back to the
      # configured size when the widget has not been laid out yet.
      private def total_span : Int32
        span = horizontal? ? awidth : aheight
        if span <= 0
          fallback = horizontal? ? @width : @height
          span = fallback.as?(Int32) || 0
        end
        span
      end

      private def max_position : Int32
        Math.max(1, total_span - 2)
      end

      private def default_position : Int32
        Math.max(1, total_span // 2)
      end

      private def relayout
        @position = default_position if @position < 1
        layout
      end

      private def layout
        a = @pane1
        b = @pane2
        return unless a && b

        pos = @position.clamp(1, max_position)
        @position = pos

        if horizontal?
          a.top = 0; a.left = 0; a.bottom = 0; a.width = pos
          divider.top = 0; divider.left = pos; divider.bottom = 0; divider.width = 1; divider.height = nil
          b.top = 0; b.left = pos + 1; b.bottom = 0; b.right = 0; b.width = nil
        else
          a.left = 0; a.top = 0; a.right = 0; a.height = pos
          divider.left = 0; divider.top = pos; divider.right = 0; divider.height = 1; divider.width = nil
          b.left = 0; b.top = pos + 1; b.right = 0; b.bottom = 0; b.height = nil
        end
      end

      private def wire_divider
        # The default `draggable` behavior already moved the divider's left/top to
        # follow the pointer; translate that into a new split position (and pin
        # the cross-axis so the divider can't drift off its track).
        divider.on(Crysterm::Event::Drag) do
          if horizontal?
            divider.top = 0
            self.position = (divider.left.as?(Int32) || @position)
          else
            divider.left = 0
            self.position = (divider.top.as?(Int32) || @position)
          end
        end

        # Arrow keys resize when the divider is focused.
        divider.on(Crysterm::Event::KeyPress) do |e|
          if horizontal?
            if e.key == Tput::Key::Left
              self.position = @position - 1
              e.accept
            elsif e.key == Tput::Key::Right
              self.position = @position + 1
              e.accept
            end
          else
            if e.key == Tput::Key::Up
              self.position = @position - 1
              e.accept
            elsif e.key == Tput::Key::Down
              self.position = @position + 1
              e.accept
            end
          end
        end
      end
    end
  end
end
