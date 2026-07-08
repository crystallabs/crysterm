require "./box"

module Crysterm
  class Widget
    # A draggable corner resize handle, modeled after Qt's `QSizeGrip`.
    #
    # Placed in a corner of a resizable frame (typically bottom-right), dragging
    # it resizes its `#target` (defaulting to the parent widget) by setting the
    # target's `width`/`height` from the pointer, clamped to `#min_drag_width`/
    # `#min_drag_height`. Pairs with floating `DockWidget`s, MDI-style sub-windows,
    # or any sized `Box`.
    #
    # ```
    # win = Widget::Box.new parent: window, top: 2, left: 2, width: 30, height: 10, style: Style.new(border: true)
    # Widget::SizeGrip.new parent: win, bottom: 0, right: 0, width: 1, height: 1
    # ```
    #
    # <!-- widget-examples:capture v1 -->
    # ![SizeGrip screenshot](../../tests/widget/size_grip/size_grip.5s.apng)
    # <!-- /widget-examples:capture -->
    class SizeGrip < Box
      # Widget resized by dragging. Defaults to the grip's parent.
      property target : Widget?

      # Smallest size the target may be dragged to. Named `*_drag_*` to avoid
      # colliding with `Widget#min_width`/`#min_height`, this grip's own CSS
      # size constraints.
      property min_drag_width : Int32 = 3
      property min_drag_height : Int32 = 3

      # Glyph drawn for the handle. Unset (`nil`) resolves the CSS `glyph` on
      # the grip's own style (`SizeGrip { glyph: "◢" }` — a single-glyph
      # widget needs no sub-control), then the `Glyphs` registry at the
      # effective tier; assigning a `Char` pins it.
      setter glyph : Char? = nil

      # :ditto:
      def glyph : Char
        @glyph || glyph(Glyphs::Role::SizeGrip, style)
      end

      # Refreshes the handle character before drawing — the resolved glyph can
      # change after construction (a stylesheet's `glyph`, `Glyphs.set`, a
      # tier switch); `set_content` no-ops while it is unchanged.
      def render
        g = self.glyph.to_s
        set_content g unless content == g
        super
      end

      def initialize(target : Widget? = nil, glyph : Char? = nil, min_drag_width = 3, min_drag_height = 3, **box)
        @target = target
        @glyph = glyph
        @min_drag_width = min_drag_width
        @min_drag_height = min_drag_height

        super **box

        set_content self.glyph.to_s

        # A drag source that stays put (no self-reposition); its motion resizes
        # the target instead.
        enable_drag reposition: false
        on(::Crysterm::Event::Drag) do |e|
          if t = (@target || parent)
            begin
              t.width = Math.max(@min_drag_width, e.x - t.aleft + 1)
              t.height = Math.max(@min_drag_height, e.y - t.atop + 1)
              t.request_render
            rescue
              # Target not laid out yet.
            end
          end
        end
      end
    end
  end
end
