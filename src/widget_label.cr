module Crysterm
  class Widget
    # Label: object title/text appearing in the first line, similar to a
    # label/title in Qt's QFrame. Usually wants the widget to have padding or a
    # border, so the label renders over the border/padding instead of the
    # widget content.

    # Widget implementing the label. If asked for and no specific widget is
    # set, a LineEdit with the chosen content is created; can also be set
    # manually for a custom label.
    property _label : Widget?

    def _label!
      @_label.not_nil! # ameba:disable Lint/NotNil
    end

    # Fires on resize, to adjust the label
    @ev_label_resize : Crysterm::Event::Resize::Wrapper?

    # The side ("left"/"right") the label was placed on, remembered so
    # `sync_label_position` can re-run `place_label_side` when a border cascades
    # in after construction and shifts the horizontal inset.
    @label_side : String = "left"

    # Sets or clears label text
    def label=(text : String?)
      text ? set_label(text) : remove_label
    end

    # Sets widget label. Can be positioned "left" (default) or "right"
    def set_label(text : String, side = "left")
      @label_side = side
      # If label widget exists, update it and return
      @_label.try do |_label|
        _label.set_content(text)
        place_label_side(_label, side)
        return
      end

      # Otherwise create it
      @_label = _label = Widget::Box.new(
        parent: self,
        content: text,
        top: -itop,
        parse_tags: @parse_tags,
        style: style.label,
        shrink_to_fit: true,
      )
      # Mark the box as a label so `coords`' scrollable-ancestor clip
      # exempts it from border compensation (blessed's `_isLabel`).
      _label._is_label = true
      # Chrome: glued to the border row, never arranged as a content slot by an
      # installed layout engine (see `Widget#layout_chrome?`). Otherwise a
      # `GroupBox` under a VBox would tear the title off the border into a flex
      # slot, and `sync_label_position` would fight the engine every frame.
      _label.layout_chrome = true

      place_label_side(_label, side)

      @ev_label_scroll = on Crysterm::Event::Scroll, ->reposition_label(Crysterm::Event::Scroll)
      @ev_label_resize = on Crysterm::Event::Resize, ->reposition_label(Crysterm::Event::Resize)
    end

    # Positions the label on `side` ("right" pins to the right inset, anything
    # else to the left), clearing the opposite edge so re-calls don't leave a
    # stale offset. `2 - ileft`/`2 - iright` compensates border *and* padding;
    # a border-only form like `2 + (-border)` ignores padding, so re-calling
    # `set_label` would shift the label `padding.left` cells right on a padded
    # widget.
    private def place_label_side(lbl, side)
      if side != "right"
        lbl.left = 2 - ileft
        lbl.right = nil
      else
        lbl.right = 2 - iright
        lbl.left = nil
      end
    end

    # Moves the label to `top` only when it isn't already there. Returns whether
    # it actually moved, so callers re-render on demand.
    private def move_label_top(lbl, top) : Bool
      return false if lbl.top == top
      lbl.top = top
      true
    end

    # Re-glues the label to its horizontal inset for the current frame, but only
    # when it has drifted — change-detected like `move_label_top`. `place_label_side`
    # bakes the construction-time inset (`2 - ileft` / `2 - iright`) into the
    # position, so a border cascading in after construction leaves the title one
    # cell off; re-running `place_label_side` compensates. Returns whether it moved.
    private def move_label_side(lbl) : Bool
      if @label_side == "right"
        return false if lbl.right == 2 - iright
      else
        return false if lbl.left == 2 - ileft
      end
      place_label_side(lbl, @label_side)
      true
    end

    # Repositions label to the right place. Usually called from resize event
    def reposition_label(event = nil)
      @_label.try do |_label|
        # Only re-render when the label actually moves: fires on every Scroll
        # and Resize, and resize jitter would otherwise trigger no-op renders.
        request_render if move_label_top(_label, @child_base - itop)
      end
    end

    # Re-glues the label to the top inset for the current frame. `set_label`
    # positions the label at construction time, but a CSS-cascade border lands
    # only at render time, so a stylesheet-styled border (e.g. `GroupBox`) would
    # otherwise leave the label one row inside the box. Called from `_render`
    # once styles are resolved; cheap for label-less widgets.
    protected def sync_label_position : Nil
      @_label.try do |_label|
        move_label_top(_label, @child_base - itop)
        move_label_side(_label)
      end
    end

    # Removes widget label
    def remove_label
      return unless @_label
      # The wrapper ivars are nilable and the event_handler shard has no `off`
      # overload for `Nil`; passing a nil wrapper would fall through to the
      # catch-all `off(type)` = `remove_all_handlers`, wiping *every* Scroll and
      # Resize handler on the widget. Only detach the specific wrappers we own.
      @ev_label_scroll.try { |w| off ::Crysterm::Event::Scroll, w }
      @ev_label_resize.try { |w| off ::Crysterm::Event::Resize, w }
      @_label.try &.remove_from_parent
      @ev_label_scroll = nil
      @ev_label_resize = nil
      @_label = nil
    end
  end
end
