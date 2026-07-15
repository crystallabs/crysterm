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
      # effective tier; assigning a `String` pins it. A wide or multi-codepoint
      # grapheme (`"⚠️"`) is kept whole — the grip is a single-placement site,
      # so `#render` grows the grip to the glyph's measured width.
      setter glyph : String? = nil

      # :ditto:
      def glyph : String
        @glyph || glyph_str(Glyphs::Role::SizeGrip, style)
      end

      # Refreshes the handle before drawing — the resolved glyph can change
      # after construction (a stylesheet's `glyph`, `Glyphs.set`, a tier switch),
      # and a wide upgrade must reserve its columns. `set_content`/`width=` both
      # no-op while unchanged, so an unstyled `◢` grip stays byte-identical.
      def render
        g = self.glyph
        # Reserve the glyph's measured width: grow (never shrink) so a 2-column
        # emoji isn't clipped by a `width: 1` grip. `◢` measures 1 → no change.
        w = Unicode.width(g)
        self.width = w if awidth < w
        set_content g unless content == g
        super
      end

      def initialize(target : Widget? = nil, glyph : String? = nil, min_drag_width = 3, min_drag_height = 3, **box)
        @target = target
        @glyph = glyph
        @min_drag_width = min_drag_width
        @min_drag_height = min_drag_height

        super **box

        set_content self.glyph

        # A drag source that stays put (no self-reposition); its motion resizes
        # the target instead.
        enable_drag reposition: false
        on(::Crysterm::Event::Drag) do |e|
          if t = (@target || parent)
            begin
              # Fold in the grip's own offset from the target's outer edge so the
              # math is placement-agnostic: `e.x - t.aleft + 1` alone assumes the
              # grip sits on the target's outer-right column, but a documented
              # inner-corner placement (`bottom: 0, right: 0`) lands it
              # `iright`/`ibottom` cells inside. `edge_x`/`edge_y` are ~0 for an
              # outer-corner grip (e.g. DockWidget) and equal the border/padding
              # inset for an inner-corner one, so the target's outer edge tracks
              # the pointer in both cases.
              edge_x = (t.aleft + t.awidth) - (self.aleft + self.awidth)
              edge_y = (t.atop + t.aheight) - (self.atop + self.aheight)
              t.width = Math.max(@min_drag_width, e.x - t.aleft + 1 + edge_x)
              t.height = Math.max(@min_drag_height, e.y - t.atop + 1 + edge_y)
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
