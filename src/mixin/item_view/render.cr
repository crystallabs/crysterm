module Crysterm
  module Mixin
    module ItemView
      # Memo for `#selection_fallback`'s reverse-video copy, keyed by source style
      # identity plus its attribute fingerprint. The cascade replaces the backing
      # per-state style, so a `same?` hit means the copy is still valid — and the
      # fingerprint catches programmatic *in-place* mutations of the same object;
      # only rebuilt on a changed source instead of a `Style#dup` per call.
      @_sel_reverse_fallback_src : ::Crysterm::Style?
      @_sel_reverse_fallback_copy : ::Crysterm::Style?
      @_sel_reverse_fallback_fp : ::Crysterm::Style::AttrFingerprint?

      # Returns the `::Crysterm::Style` an item box should render with, given whether it is
      # the selected item.
      #
      # The list draws its own border around the whole widget, so individual items
      # must never carry one: the non-selected branch of `::Crysterm::Style#item`
      # falls back to the list's own style (`@item || self`), which would
      # otherwise make every item draw a nested border. The selected branch
      # (`styles.selected`) is already border-less but runs through the same guard
      # for symmetry.
      def item_render_style(selected : Bool) : ::Crysterm::Style
        return without_border(style.item) unless selected
        # Fuse the selected style's two transforms (strip border, force
        # reverse-video at the unstyled floor) into a single `#dup`.
        # `styles.selected` itself is never mutated in place, and nothing is
        # cached across frames.
        base = styles.selected
        strip = base.border.any?
        reverse = !selection_visibly_styled?
        return base unless strip || reverse
        out = base.dup
        out.border = false if strip
        out.reverse = true if reverse
        out
      end

      # Whether the selection state carries its own visible distinction (a color
      # or reverse video). When it does not — the unstyled floor, where
      # `styles.selected` falls back to `normal` with no selection colors —
      # selection falls back to reverse-video instead (see `#selection_fallback`),
      # which needs no color and reads on any terminal background. Only reached
      # for non-CSS-styled items; themed selections (`Box:selected`) are never
      # touched.
      private def selection_visibly_styled? : Bool
        return false unless styles.own_selected?
        styles.selected.visibly_styled?
      end

      # Returns *st* with reverse-video forced on when the selection has no
      # visible styling of its own, so the cursor row stays distinguishable with
      # no theme active. Returns *st* untouched when already visibly styled.
      #
      # The memo pair `@_sel_reverse_fallback_{src,copy}` is kept separate from
      # the focus-highlight fallback's, so a `List` can run both in one frame.
      private def selection_fallback(st : ::Crysterm::Style) : ::Crysterm::Style
        result, @_sel_reverse_fallback_src, @_sel_reverse_fallback_copy, @_sel_reverse_fallback_fp =
          reverse_fallback_memo st, selection_visibly_styled?, @_sel_reverse_fallback_src,
            @_sel_reverse_fallback_copy, @_sel_reverse_fallback_fp
        result
      end

      # Returns *base* with any border stripped: *base* untouched when borderless
      # (no allocation), else a borderless `#dup`. Items must never carry the
      # list's border — it would nest stray line-drawing chars and reserve
      # `ihorizontal`, shrinking the item's content area.
      protected def without_border(base : ::Crysterm::Style) : ::Crysterm::Style
        return base unless base.border.any?
        borderless = base.dup
        borderless.border = false
        borderless
      end

      # Resolves the `::Crysterm::Style` an item box should render with. Single
      # entry point called from `Widget#base_render`; overridable (e.g. for
      # alternating rows).
      #
      # The cursor item gets the full `selected` highlight. In `#multi_select?`
      # mode the *other* checked items are underlined so they read as selected
      # without being confused with the cursor (Qt's distinct current-item vs.
      # selected-set display).
      def render_style_for(item : Widget) : ::Crysterm::Style
        # CSS-styled item (e.g. `List Box`, `Item:nth-child(even)`): use the
        # item's own cascade-computed style, reflecting selection through its
        # widget state so `:selected` rules apply.
        if item.css_styled?
          # Multi-select: cursor item gets the full `:selected` highlight, other
          # checked items stay normal but underlined.
          if multi_select?
            i = item_index_of item
            item.state = (i == @selected) ? WidgetState::Selected : WidgetState::Normal
            style = item.style
            if i == @selected
              style = selection_overlay(style)
            elsif i && @selected_indices.includes?(i)
              style = style.dup
              style.underline = true
            end
            return style
          end

          selected = item_selected?(item)
          item.state = selected ? WidgetState::Selected : WidgetState::Normal
          base = item.style
          return selected ? selection_overlay(base) : base
        end

        # Fast path: no multi-selection, so the only "selected" item is the
        # cursor — O(1) array compare, no scan.
        unless multi_select?
          return item_render_style(@item_boxes[@selected]? == item)
        end

        i = item_index_of item
        return item_render_style(true) if i == @selected

        if i && @selected_indices.includes?(i)
          marked = item_render_style(false).dup
          marked.underline = true
          return marked
        end

        item_render_style false
      end

      # Overlays the list-level selected style's colors onto a selected item's
      # CSS-computed *style* (from `selection-color`/`selection-background-color`,
      # or a `List:selected` rule). They live on `styles.selected`, not the item's
      # style, so without this they never reach the window. No-op unless a
      # distinct selected style was set.
      private def selection_overlay(style : ::Crysterm::Style) : ::Crysterm::Style
        return style unless styles.own_selected?
        overlay_colors style, styles.selected
      end

      # Returns *base* with *source*'s explicitly-set fg/bg laid over it: *base*
      # itself when neither color is specified, else a `#dup` carrying the
      # overlaid colors. Bridges list-level `selection-*`/`alternate-background-color`
      # onto per-item CSS styles without touching other properties.
      private def overlay_colors(base : ::Crysterm::Style, source : ::Crysterm::Style) : ::Crysterm::Style
        fg = source.specified?(:fg)
        bg = source.specified?(:bg)
        return base unless fg || bg
        out = base.dup
        out.fg = source.fg if fg
        out.bg = source.bg if bg
        out
      end

      # Whether *item* should render in the selected style: it is the cursor
      # item, or (in `#multi_select?` mode) it is part of `#selected_indices`.
      def item_selected?(item : Widget) : Bool
        # Fast path: single-selection only needs an O(1) compare against the
        # cursor item (runs once per item per frame from `Widget#base_render`).
        return @item_boxes[@selected]? == item unless multi_select?

        i = item_index_of item
        return false unless i
        i == @selected || @selected_indices.includes?(i)
      end

      # An item view has a fixed viewport, so "scrollable right now" must be a real
      # content-vs-height overflow test, not the `@shrink_to_fit`
      # always-scrollable short-circuit it would otherwise inherit — which shows
      # an `AsNeeded` scroll bar even when every item fits.
      def overflows_y?
        content_overflows_height?
      end

      # Minimum thumb (handle) length, in cells, for a list-like scroll bar.
      # Floors the otherwise purely proportional handle so it renders the same
      # whether the list has a dozen rows or a couple hundred, instead of decaying
      # to a lone 1-cell nub.
      ITEM_VIEW_MIN_THUMB = 3

      # Gives the bound vertical scroll bar the shared list-view minimum handle
      # length on top of the base setup. Idempotent, like the base.
      protected def ensure_scrollbar_widget : Widget::ScrollBar
        sb = super
        sb.min_thumb = ITEM_VIEW_MIN_THUMB
        sb
      end

      # Keeps every item's right-edge reservation in lock-step with the vertical
      # scroll bar's *current* presence, each frame. Items bake `right` at
      # creation, but whether the bar shows can change later (list grows past
      # viewport, `#items=` reuses old item widgets, resize). A stale `right: 0`
      # lets a shown bar overpaint the last content column; a stale reservation
      # wastes a column the bar no longer needs. `right=` is a no-op when
      # unchanged. Shrink-to-content items carry `right: nil` and are left alone.
      def render(with_children = true)
        # Only scrollable lists reserve a bar column; for a plain list/menu
        # `content_margin_x` is always 0, so skip the per-frame item walk.
        if scrollable?
          reserve = content_margin_x
          @item_boxes.each { |item| item.right = reserve unless item.right.nil? }
        end
        super
      end
    end
  end
end
