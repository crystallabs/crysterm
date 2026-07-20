module Crysterm
  class Widget
    # Label: object title/text appearing in the first line, similar to a
    # label/title in Qt's QFrame. Usually wants the widget to have padding or a
    # border, so the label renders over the border/padding instead of the
    # widget content.

    # Widget implementing the label. If asked for and no specific widget is
    # set, a LineEdit with the chosen content is created; can also be set
    # manually for a custom label.
    property label_widget : Widget?

    # Fires on resize, to adjust the label
    @ev_label_resize : Crysterm::Event::Resize::Wrapper?

    # Which side of the border a label is anchored to.
    enum LabelSide
      Left
      Right
    end

    # The side the label was placed on, remembered so `sync_label_position` can
    # re-run `place_label_side` when a border cascades in after construction and
    # shifts the horizontal inset.
    @label_side : LabelSide = LabelSide::Left

    # Sets or clears label text. A text-only update keeps the side the label
    # was placed on (`set_label(text, :right)` followed by `label = "..."` must
    # not silently move it back to the left).
    def label=(text : String?)
      text ? set_label(text, @label_side) : remove_label
    end

    # Returns the currently set label text, or `nil` when no label is set.
    def label : String?
      @label_widget.try &.content
    end

    # Sets widget label. Can be positioned `:left` (default) or `:right`
    def set_label(text : String, side : LabelSide = :left)
      @label_side = side
      # If label widget exists, update it and return
      @label_widget.try do |_label|
        _label.set_content(text)
        place_label_side(_label, side)
        return
      end

      # Otherwise create it. An explicitly-set `::label` sub-style is the label's
      # style; otherwise the label gets its own plain `Style` (the raw ivar is
      # read because the public `Style#label` getter falls back to `self`, which
      # would share the parent's whole style object — border included).
      @label_widget = _label = Widget::Box.new(
        parent: self,
        content: text,
        top: -itop,
        parse_tags: @parse_tags,
        style: style.@label || Style.new,
        shrink_to_fit: true,
      )
      # Mark the box as a label so `coords`' scrollable-ancestor clip exempts it
      # from border compensation.
      _label._is_label = true
      # Chrome: glued to the border row, never arranged as a content slot by an
      # installed layout engine. Otherwise a `GroupBox` under a VBox would tear
      # the title off the border into a flex slot, and `sync_label_position` would
      # fight the engine every frame.
      _label.layout_chrome = true

      place_label_side(_label, side)

      @ev_label_scroll = on(Crysterm::Event::Scroll) { reposition_label }
      @ev_label_resize = on(Crysterm::Event::Resize) { reposition_label }
    end

    # Positions the label on `side` (`:right` pins to the right inset, `:left`
    # to the left), clearing the opposite edge so re-calls don't leave a
    # stale offset. `2 - ileft`/`2 - iright` compensates border *and* padding;
    # a border-only form like `2 + (-border)` ignores padding, so re-calling
    # `set_label` would shift the label `padding.left` cells right on a padded
    # widget.
    private def place_label_side(lbl, side : LabelSide)
      case side
      in .left?
        lbl.left = 2 - ileft
        lbl.right = nil
      in .right?
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
    # when it has drifted. `place_label_side` bakes the construction-time inset
    # into the position, so a border cascading in later leaves the title one cell
    # off; re-running it compensates. Returns whether it moved.
    private def move_label_side(lbl) : Bool
      if @label_side.right?
        return false if lbl.right == 2 - iright
      else
        return false if lbl.left == 2 - ileft
      end
      place_label_side(lbl, @label_side)
      true
    end

    # Repositions label to the right place.
    protected def reposition_label
      @label_widget.try do |_label|
        # Only re-render when the label actually moves: fires on every Scroll
        # and Resize, and resize jitter would otherwise trigger no-op renders.
        request_render if move_label_top(_label, @child_base - itop)
      end
    end

    # Re-glues the label to the top inset for the current frame. `set_label`
    # positions the label at construction time, but a CSS-cascade border lands
    # only at render time, so a stylesheet-styled border (e.g. `GroupBox`) would
    # otherwise leave the label one row inside the box. Must run once styles are
    # resolved; cheap for label-less widgets.
    protected def sync_label_position : Nil
      @label_widget.try do |_label|
        # `Widget::label { … }` styles the label — it snapshots its style at
        # creation, so push the computed `label` sub-style onto it whenever the
        # cascade produced one (each recompute replaces the sub-style object, so
        # an identity check suffices). Read the raw ivar: the public getter
        # falls back to `self`. A no-op unless a `::label` rule matched.
        if (ls = style.@label) && !_label.style.same?(ls)
          _label.style = ls
        end
        move_label_top(_label, @child_base - itop)
        move_label_side(_label)
      end
    end

    # Removes widget label
    def remove_label
      return unless @label_widget
      # The wrapper ivars are nilable and `off` has no `Nil` overload: a nil
      # wrapper would fall through to the catch-all `off(type)` and wipe *every*
      # Scroll and Resize handler on the widget. Detach only the wrappers we own.
      @ev_label_scroll.try { |w| off ::Crysterm::Event::Scroll, w }
      @ev_label_resize.try { |w| off ::Crysterm::Event::Resize, w }
      @label_widget.try &.remove_from_parent
      @ev_label_scroll = nil
      @ev_label_resize = nil
      @label_widget = nil
    end
  end
end
