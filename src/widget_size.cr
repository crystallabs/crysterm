require "./macros"

module Crysterm
  class Widget
    include Macros

    # Widget's size

    # User-defined width (setter is defined below). Accepts a cell count
    # (`Int32`), a `Dim` (`Dim.percent(50)`), `:half`, or the string micro-DSL
    # (`"50%"`, `"half-3"`, `"50vw"`) — strings/symbols parse to a `Dim` once,
    # at assignment (malformed raises `ArgumentError` there); `nil` stretches.
    #
    # NOTE Returns the **unresolved spec**, not a cell count — by design, so
    # `Widget.new(width: "50%")` round-trips through `#width`. For the
    # resolved size in cells see `#awidth` (and the `#size` bundle below).
    getter width : Dim | Int32 | String?

    # User-defined height (setter is defined below); forms as for `#width`.
    #
    # NOTE Same caveat as `#width`: unresolved spec, not cells. See `#aheight`
    # (and `#size`).
    getter height : Dim | Int32 | String?

    # Whether the widget sizes itself to its content and children rather than to
    # its slot — roughly CSS `width: fit-content`. Only the dimensions the user
    # left unset (`nil` `width`/`height`) shrink.
    #
    # NOTE This has nothing to do with the *user* being able to resize the widget
    # (Qt's size policies, CSS `resize:`) — for a draggable resize handle see
    # `Widget::SizeGrip`.
    property? shrink_to_fit = false

    # `width=`/`height=`: change-guarded setters that normalize through
    # `Dim.from` (parse-at-assignment, size context), mark dirty and emit
    # `Resize`. The assign lands *before* the emit so in-tree Resize listeners
    # observe the new size, not the old one.
    {% for dim in %w[width height] %}
      # Sets widget's total {{ dim.id }}
      def {{ dim.id }}=(val : Dim | Int32 | String | Symbol | Nil)
        val = Dim.from val, size: true
        return if @{{ dim.id }} == val
        @{{ dim.id }} = val
        update
        emit ::Crysterm::Event::Resize
      end
    {% end %}

    # Which box a declared `#width`/`#height` measures — CSS `box-sizing`.
    enum BoxSizing
      # The declared size is the widget's whole on-screen extent; border and
      # padding are drawn *inside* it, shrinking the content area.
      BorderBox
      # The declared size is the content area; border and padding are added
      # *outside* it, growing the widget's on-screen extent.
      ContentBox
    end

    # Which box `#width`/`#height` measure (CSS `box-sizing`).
    #
    # Crysterm defaults to `BorderBox`, unlike CSS and Qt stylesheets, which
    # default to `content-box`. In a terminal a size is a count of cells you can
    # see, so `height: 3` meaning three rows on screen — border included — is
    # what TUI code is written against; content-box would silently make every
    # bordered widget in an existing layout two rows taller and two columns wider.
    #
    # `ContentBox` opts one widget (or, via a stylesheet, a whole class of them)
    # into the CSS/Qt reading. Its main use is the case where a border cannot
    # fit the box it was declared on — a one-row widget with `border: solid` has
    # no room for a top and a bottom edge, so `#effective_insets` drops that
    # axis' border. Under `ContentBox` the row is the *content*, the frame is
    # added around it, and the widget simply becomes three rows tall with a
    # complete border.
    #
    # Only an explicitly sized axis is affected: an `auto` (`nil`) size fills its
    # slot and a `#shrink_to_fit?` size is derived from content that is already
    # measured inside the insets, so on both the distinction has nothing to act on.
    property box_sizing : BoxSizing = BoxSizing::BorderBox

    # :ditto: — accepts the CSS spellings (`"content-box"`, `:border_box`, ...).
    def box_sizing=(value : String | Symbol) : BoxSizing
      self.box_sizing = BoxSizing.parse(value.to_s.gsub('-', '_'))
    end

    # Cells to add to an explicitly declared extent on this axis: the frame
    # insets under `ContentBox` (which measures the content area), nothing under
    # `BorderBox` (which already measures the whole widget). `AlwaysInline` so
    # the default-`BorderBox` case folds to a compare against the enum, keeping
    # the per-frame `awidth`/`aheight` fixed-size path call-free.
    @[AlwaysInline]
    private def box_sizing_pad_width : Int32
      @box_sizing.content_box? ? ihorizontal : 0
    end

    # :ditto: for the vertical axis.
    @[AlwaysInline]
    private def box_sizing_pad_height : Int32
      @box_sizing.content_box? ? ivertical : 0
    end

    # CSS `min-width`/`max-width`/`min-height`/`max-height` constraints
    # (`nil` = unconstrained). `awidth`/`aheight` clamp the *used* size to
    # `[min, max]`, with `min` winning when it exceeds `max`, like CSS. Set from a
    # stylesheet by `CSS::Geometry`; settable directly too.
    #
    # Takes the same forms as `#width`/`#height`: a cell count, or a `Dim`/
    # percentage `String` (`min_width: "50%"`) resolved against the parent's
    # content area at clamp time, exactly like a percentage `width`. The raw
    # form is what's stored and read back; `#resolved_min_width` & co. report
    # the cell value.
    getter min_width : Dim | Int32 | String? = nil
    getter max_width : Dim | Int32 | String? = nil
    getter min_height : Dim | Int32 | String? = nil
    getter max_height : Dim | Int32 | String? = nil

    # Whether any of the four `min-*`/`max-*` constraints is set. One boolean so
    # the `clamp_awidth`/`clamp_aheight` fast path — taken by every
    # `awidth`/`aheight` call on the (overwhelmingly common) unconstrained
    # widget, several times per widget per frame — is a single flag test instead
    # of two union-typed ivar reads per axis. Maintained by the four setters
    # below, the only writers of those ivars.
    @size_constrained = false

    # `min_*=`/`max_*=` alter effective `awidth`/`aheight` like `width=`/`height=`,
    # so they emit `Resize` too, or its listeners go stale. Assign-before-emit, so
    # those listeners see the new constraint. A `String`/`Symbol` is normalized
    # through `Dim.from` up front (as `#width=` does), so the clamp path never
    # re-parses and an unparseable value fails at assignment, not mid-render.
    {% for dim in %w[min_width max_width min_height max_height] %}
      def {{ dim.id }}=(val : Dim | Int32 | String | Symbol | Nil)
        val = Dim.from val, size: true unless val.nil? || val.is_a?(Int32)
        return if @{{ dim.id }} == val
        @{{ dim.id }} = val
        @size_constrained = !(@min_width.nil? && @max_width.nil? &&
                              @min_height.nil? && @max_height.nil?)
        update
        emit ::Crysterm::Event::Resize
      end
    {% end %}

    # `#min_width`/`#max_width`/`#min_height`/`#max_height` resolved to cells
    # against the parent's content area — the value the clamp actually applies.
    # `nil` when the constraint is unset.
    {% for dim in %w[width height] %}
      {% for bound in %w[min max] %}
        def resolved_{{ bound.id }}_{{ dim.id }}(rendered = false) : Int32?
          c = @{{ bound.id }}_{{ dim.id }}
          # Plain cell count (or unset) resolves without the ancestor walk.
          return c.as(Int32?) unless relative_constraint?(c)
          resolve_constraint c, constraint_base_{{ dim.id }}(rendered)
        end
      {% end %}
    {% end %}

    # Resolves one stored constraint against *base* (the parent content extent).
    # A plain cell count short-circuits, so the common case never touches the
    # base — which is why callers pass it lazily.
    private def resolve_constraint(c : Dim | Int32 | String?, base : Int32?) : Int32?
      case c
      in Nil    then nil
      in Int32  then c
      in Dim    then resolve_dim c, base || 0
      in String then resolve_dim c, base || 0, size: true
      end
    end

    # Whether *c* needs the parent's extent to resolve (i.e. is not a plain
    # cell count). Gates the ancestor walk in `#clamp_awidth`/`#clamp_aheight`.
    private def relative_constraint?(c) : Bool
      !(c.nil? || c.is_a?(Int32))
    end

    # Bundled `(#min_width, #min_height)` — Qt's `QWidget::minimumSize`, in
    # resolved cells. `nil` when either constraint is unset (a *partial* pair
    # has no single `Size` to report), not just when both are — a reader that
    # returned a zero-filled `Size` for the unset half would be
    # indistinguishable from an explicit `min_width: 0`.
    def minimum_size : Size?
      return unless (w = resolved_min_width) && (h = resolved_min_height)
      Size.new w, h
    end

    # Sets `#min_width`/`#min_height` together; `nil` clears both. Mechanical —
    # each half goes through its own change-guarded setter, so this emits
    # `Resize` per axis that actually changed, same as setting them separately.
    def minimum_size=(size : Size?) : Nil
      self.min_width = size.try &.width
      self.min_height = size.try &.height
    end

    # Bundled `(#max_width, #max_height)` — Qt's `QWidget::maximumSize`, in
    # resolved cells. See `#minimum_size` for the nil-when-partial rule.
    def maximum_size : Size?
      return unless (w = resolved_max_width) && (h = resolved_max_height)
      Size.new w, h
    end

    # :ditto: setter — see `#minimum_size=`.
    def maximum_size=(size : Size?) : Nil
      self.max_width = size.try &.width
      self.max_height = size.try &.height
    end

    # Clamps a computed dimension to `[min, max]`. `max` is applied before `min`
    # so `min` wins a `min > max` conflict, per CSS.
    private def clamp_dim(v : Int32, min : Int32?, max : Int32?) : Int32
      v = Math.min(v, max) if max
      v = Math.max(v, min) if min
      v
    end

    # The extent a percentage `min-*`/`max-*` resolves against: the parent's
    # content area on that axis, the same base a percentage `#width`/`#height`
    # uses, so `min_width: "50%"` and `width: "50%"` agree. Only called when a
    # constraint actually is relative — the plain-cell path must not pay for the
    # ancestor walk.
    {% for axis in [
                     {dim: "width", near: "left", far: "right"},
                     {dim: "height", near: "top", far: "bottom"},
                   ] %}
      private def constraint_base_{{ axis[:dim].id }}(rendered = false) : Int32
        parent = rendered ? parent_or_window.last_rendered_position : parent_or_window
        (parent.a{{ axis[:dim].id }} || 0) - parent.i{{ axis[:near].id }} - parent.i{{ axis[:far].id }}
      end

      # Clamps a computed {{ axis[:dim].id }} to the
      # `[min_{{ axis[:dim].id }}, max_{{ axis[:dim].id }}]` constraints.
      # `AlwaysInline` so the unconstrained case — the `@size_constrained` flag
      # test — folds into every `a{{ axis[:dim].id }}` call with no call
      # overhead; the constrained remainder stays outlined below.
      @[AlwaysInline]
      private def clamp_a{{ axis[:dim].id }}(v : Int32, rendered = false) : Int32
        return v unless @size_constrained
        clamp_a{{ axis[:dim].id }}_constrained v, rendered
      end

      # The constrained arm of `#clamp_a{{ axis[:dim].id }}`.
      private def clamp_a{{ axis[:dim].id }}_constrained(v : Int32, rendered) : Int32
        mn = @min_{{ axis[:dim].id }}
        mx = @max_{{ axis[:dim].id }}
        # Fast path: both constraints are plain cell counts (or unset), so the
        # parent's extent is never needed.
        if !relative_constraint?(mn) && !relative_constraint?(mx)
          return clamp_dim v, mn.as(Int32?), mx.as(Int32?)
        end
        base = constraint_base_{{ axis[:dim].id }}(rendered)
        clamp_dim v, resolve_constraint(mn, base), resolve_constraint(mx, base)
      end
    {% end %}

    # `eff_width`/`eff_height`: the size value geometry resolution consumes —
    # the layout-assigned cells when a parent engine manages this widget's
    # size (`@layout_width`/`@layout_height`), else the user's spec. The size
    # half of the substitution point described at `eff_left`
    # (widget_position.cr); a layout-assigned size then flows through the
    # `Int32` arm below exactly as the engine-written specs used to —
    # `min-*`/`max-*` clamps and `box_sizing` padding included.
    {% for dim in %w[width height] %}
      @[AlwaysInline]
      protected def eff_{{ dim.id }}
        @layout_{{ dim.id }} || @{{ dim.id }}
      end
    {% end %}

    # Size-context variant of `#resolve_dim`: a stored `Dim` resolves as
    # parsed; the cold raw-`String` arm parses with the `"half"` alias.
    private def resolve_size_dim(o : Dim | String, against : Int32) : Int32
      o.is_a?(Dim) ? resolve_dim(o, against) : resolve_dim(o, against, size: true)
    end

    # `awidth`/`aheight`: computed used size in cells, the mechanical axis mirror
    # of each other (width→height, left→top, right→bottom, ileft→itop,
    # iright→ibottom). Generated from one body — as `aleft`/`atop` and
    # `aright`/`abottom` are in widget_position.cr — so the auto/percentage/margin
    # handling can never drift between the two axes. Each axis map lists only the
    # tokens that differ: `dim` (the size word, driving the method name
    # `a{{ dim }}` and the `clamp_a{{ dim }}`/`min_{{ dim }}` family), and the
    # `near`/`far` edge names.
    #
    # *rendered* resolves against the parent's **last-rendered** position instead
    # of its live geometry — what the render path wants, since the parent has
    # already been placed for this frame.
    {% for axis in [
                     {dim: "width", near: "left", far: "right"},
                     {dim: "height", near: "top", far: "bottom"},
                   ] %}
      # Returns computed {{ axis[:dim].id }}, in cells. See *rendered* above.
      def a{{ axis[:dim].id }}(rendered = false) : Int32
        # Layout-assigned values when managed, else the user's specs (see
        # `eff_*`); the far edge is never layout-managed.
        o{{ axis[:near].id }} = eff_{{ axis[:near].id }}
        o{{ axis[:far].id }} = @{{ axis[:far].id }}
        {{ axis[:dim].id }} = eff_{{ axis[:dim].id }}

        # Parent's rendered position is only needed by the Dim/String/`nil` branches;
        # a fixed `Int32` {{ axis[:dim].id }} (common case) ignores it, so it's resolved
        # lazily to avoid walking the ancestor chain every frame.
        case {{ axis[:dim].id }}
        when Dim, String
          parent = rendered ? parent_or_window.last_rendered_position : parent_or_window
          # Percentage of the parent's content area (inside border/padding), like
          # CSS `{{ axis[:dim].id }}: 100%`. Matching `#a{{ axis[:near].id }}` adds the
          # parent's near inset, so a `{{ axis[:near].id }}: 0` child sits inside the
          # border and `"100%"` reaches the far inset. A specified size keeps its
          # full extent — an outward margin *shifts* it (see `coords`), it does not
          # shrink it.
          # `box_sizing_pad_*` is 0 under the default `BorderBox`; under
          # `ContentBox` the resolved value is the content extent and the frame
          # is added around it. Added after the clamp, so `min-*`/`max-*` apply
          # to the same box the size does, per CSS.
          return clamp_a{{ axis[:dim].id }}(resolve_size_dim({{ axis[:dim].id }}, (parent.a{{ axis[:dim].id }} || 0) - parent.i{{ axis[:near].id }} - parent.i{{ axis[:far].id }}), rendered) +
            box_sizing_pad_{{ axis[:dim].id }}
        end

        # Stretched or shrunken element: shrunken sizes are computed in the render
        # function from content size, seeded by the element's own {{ axis[:dim].id }},
        # so it's calculated here too.
        if {{ axis[:dim].id }}.nil?
          parent = rendered ? parent_or_window.last_rendered_position : parent_or_window
          # `parent.a{{ axis[:dim].id }}` climbs the whole ancestor chain. It's needed
          # twice here (string base + size subtraction); computing it once collapses
          # O(2^depth) to O(depth) for a chain of nil-{{ axis[:dim].id }} + string-{{ axis[:near].id }} widgets.
          psize = parent.a{{ axis[:dim].id }} || 0
          {{ axis[:near].id }} = o{{ axis[:near].id }} || 0
          unless {{ axis[:near].id }}.is_a? Int32
            {{ axis[:near].id }} = resolve_dim({{ axis[:near].id }}, psize)
          end
          # `psize` is already resolved here, so the symmetric `String` {{ axis[:far].id }}
          # (`{{ axis[:far].id }}: "50%"`) costs nothing extra — see `#resolve_edge`.
          {{ axis[:dim].id }} = psize - resolve_edge(o{{ axis[:far].id }}, psize) - {{ axis[:near].id }}

          if applies_near_offset?(o{{ axis[:near].id }}, o{{ axis[:far].id }})
            {{ axis[:dim].id }} -= parent.i{{ axis[:near].id }}
          end
          {{ axis[:dim].id }} -= parent.i{{ axis[:far].id }}

          # `{{ axis[:dim].id }}: auto` fills the slot, so the element's *own* margins
          # eat into the filled content (CSS: a stretched box shrinks by its margins);
          # a fixed size keeps its extent and shifts instead, so only this branch
          # folds the margin in. Subtract before clamping, so
          # `[min_{{ axis[:dim].id }}, max_{{ axis[:dim].id }}]` applies to the
          # post-margin (used) size, per CSS min/max semantics.
          msum = (mg = style.margin).any? ? mg.{{ axis[:near].id }} + mg.{{ axis[:far].id }} : 0
          return clamp_a{{ axis[:dim].id }}({{ axis[:dim].id }} - msum, rendered)
        end

        # Every `Dim`/`String` returned above and every `nil` in the branch above
        # it, so only an `Int32` reaches here; the `as` states that for the return
        # type.
        clamp_a{{ axis[:dim].id }}({{ axis[:dim].id }}.as(Int32), rendered) + box_sizing_pad_{{ axis[:dim].id }}
      end
    {% end %}

    # `(#awidth, #aheight)` bundled as a `Size` — Qt's `QWidget::size()`.
    def size : Size
      Size.new awidth, aheight
    end

    # The resolved width in cells — a discoverable alias of `#awidth` for
    # readers who don't know the `a*` prefix convention. `#width` returns the
    # size *spec* (`Dim | Int32 | String?` — possibly `"50%"` or `nil`); this
    # returns the cells actually used.
    def width_cells : Int32
      awidth
    end

    # :ditto: — alias of `#aheight`.
    def height_cells : Int32
      aheight
    end

    # `Size` overload of `#resize` — Qt's `QWidget::resize(QSize)`. Pure
    # delegation to the `Int32` form.
    def resize(size : Size) : Nil
      resize size.width, size.height
    end

    # `size WRITE resize` — Qt property-idiom setter delegating to `#resize`.
    def size=(size : Size) : Nil
      resize size.width, size.height
    end

    # This widget's own rectangle in local coordinates, i.e. always
    # `(0, 0, #awidth, #aheight)` — Qt's `QWidget::rect()`. Unlike `#geometry`
    # (absolute window coordinates), `#rect` is where the widget sees itself:
    # the frame passed to content/paint math that doesn't care where on the
    # window it ultimately lands.
    def rect : Rectangle
      Rectangle.new 0, 0, awidth, aheight
    end

    # Whether the x axis shrinks to its content: no explicit width, and at least
    # one horizontal edge left unanchored (both anchored pins the width instead).
    #
    # `#minimal_children_rectangle` and `#minimal_content_rectangle` must agree on
    # what "shrinks on this axis" means, or the children-derived and
    # content-derived rectangles silently disagree — hence the single definition.
    private def shrink_width? : Bool
      eff_width.nil? && (eff_left.nil? || @right.nil?)
    end

    # Whether the y axis shrinks to its content — the `#shrink_width?` mirror,
    # plus the non-obvious `(!@scrollable || item_view?)` term: a scrollable
    # widget keeps its given height (its content is meant to overflow and
    # scroll), *except* an item view, whose height is derived from its item
    # count.
    private def shrink_height? : Bool
      eff_height.nil? && (eff_top.nil? || @bottom.nil?) && (!@scrollable || item_view?)
    end

    # Returns minimum widget size based on bounding box
    private def minimal_children_rectangle(xi, xl, yi, yl, rendered)
      if @children.empty?
        return Rectangle.of_edges left: xi, top: yi, right: xi + 1, bottom: yi + 1
      end

      # Neither axis shrinks (both width and height are pinned/anchored), so the
      # loop below can't change `xi/xl/yi/yl`: those locals are mutated only
      # inside the `shrink_width?`/`shrink_height?` blocks further down. Skip
      # walking every child's full `coords` — a full-subtree layout pass — for a
      # result that's already known.
      unless shrink_width? || shrink_height?
        return Rectangle.of_edges left: xi, top: yi, right: xl, bottom: yl
      end

      mxi = xi
      mxl = xi + 1
      myi = yi
      myl = yi + 1

      # Chicken-and-egg: determining this element's render needs the children's
      # render, but the children need to know their parent's render — so give
      # them what we have so far.
      if rendered
        _lpos = @lpos
        # A reused per-widget scratch — children only read it transiently via
        # `parent.lpos` during this pass — NOT `@lpos` itself: provisional and
        # final coords differ.
        @lpos = (@_shrink_lpos ||= RenderedGeometry.new).reset(
          xi: xi, xl: xl, yi: yi, yl: yl, base: 0,
          no_left: false, no_right: false, no_top: false, no_bottom: false,
          renders: 0)
      end

      # One reused scratch for every child's coordinate result: it's read (and for
      # anchored children adjusted) within the iteration only, so a heap
      # `RenderedGeometry` per child per frame would be pure garbage. Distinct
      # from `@_shrink_lpos` above, which is exposed via `@lpos` for the same pass.
      scratch = (@_shrink_child_lpos ||= RenderedGeometry.new)
      @children.each do |el|
        # Skip layout-excluded chrome, exactly as the layout engines do: the
        # background-image `Media` layer is pinned 0/0/0/0 (spanning the whole
        # current slot), so measuring it would lock a shrink-to-content widget at
        # whatever size the previous frame stretched the layer to — the widget
        # balloons to its parent's full size and never shrinks again.
        next if el.layout_excluded?
        ret = el.coords(rendered, into: scratch)

        if !ret
          next
        end

        # A shrunk parent's children assume max available space, so a
        # right/bottom-anchored child would inflate the parent's shrunken size;
        # use just the element's own height/width instead.
        if el.eff_left.nil? && !el.right.nil?
          ret.xl = xi + (ret.xl - ret.xi)
          ret.xi = xi
          ret.xl += ileft
          ret.xi += ileft
        end
        if el.eff_top.nil? && !el.bottom.nil?
          ret.yl = yi + (ret.yl - ret.yi)
          ret.yi = yi
          ret.yl += itop
          ret.yi += itop
        end

        mxi = Math.min(mxi, ret.xi)
        mxl = Math.max(mxl, ret.xl)
        myi = Math.min(myi, ret.yi)
        myl = Math.max(myl, ret.yl)
      end

      if rendered
        @lpos = _lpos
      end

      if shrink_width?
        if far_anchored?(eff_left, @right)
          xi = xl - (mxl - mxi)
          # `mxl - mxi` already bakes in the *near* (left) inset: children sit at
          # `parent.ileft` while `mxi` is seeded to the parent's own left edge, so
          # the span is `ileft + content`. Pull the left edge back by the *far*
          # (right) inset to size the box to `content + ihorizontal` — matching
          # the left-anchored branch's `xl += iright`. Using `ileft` here would
          # double-count the near inset and over-size an asymmetrically-inset box.
          xi -= iright
        else
          xl = mxl
          xl += iright
        end
      end
      if shrink_height?
        # Shrunken lists assume all items should be showing; height can be
        # calculated from item count.
        if item_view?
          # Anchor the extent at the widget's own top: `myi`/`myl` are absolute
          # window coordinates, and the top-anchored placement below uses `myl`
          # absolutely. A 0-based `myi` is correct only at `yi == 0`; anywhere else
          # the rectangle comes out inverted/truncated and the span comparison in
          # `minimal_rectangle_uncached` collapses the box to its content rect.
          myi = yi
          # `#item_box_count` counts only content rows, and the top-anchored
          # placement below (`yl = myl; yl += ibottom`) adds only the bottom inset
          # — so fold the *top* inset in here, or a bordered shrink-to-content list
          # comes out `itop` rows short and clips its last item. `itop` (not
          # `ibottom`), or the error inverts; `myi = yi` keeps the bottom-anchored
          # branch's span (`myl - myi == items + itop`) unchanged.
          myl = yi + item_box_count + itop
        end
        if far_anchored?(eff_top, @bottom)
          yi = yl - (myl - myi)
          # `myl - myi` already bakes in the *near* (top) inset (see the x-axis
          # branch above), so pull the top edge back by the *far* (bottom) inset to
          # size the box to `content + ivertical`, matching the top-anchored
          # branch's `yl += ibottom`.
          yi -= ibottom
        else
          yl = myl
          yl += ibottom
        end
      end

      Rectangle.of_edges left: xi, top: yi, right: xl, bottom: yl
    end

    # Returns minimum widget size based on content.
    #
    # NOTE: the widget must not have `#align=` set, or the alignment padding
    # will make the "minimal" size come out as the surrounding box's full size.
    private def minimal_content_rectangle(xi, xl, yi, yl)
      h = @_clines.size
      # `max_width` is `property max_width = 0` (Int32, never nil), so no `|| 0`.
      w = @_clines.max_width

      # The border box is sized to exactly the content (`w`/`h` + inner insets);
      # an outward margin shifts this box rather than shrinking it (see
      # `coords`), so no margin room is reserved here.
      if shrink_width?
        if far_anchored?(eff_left, @right)
          xi = xl - w - ihorizontal
        else
          xl = xi + w + ihorizontal
        end
      end

      if shrink_height?
        if far_anchored?(eff_top, @bottom)
          yi = yl - h - ivertical
        else
          yl = yi + h + ivertical
        end
      end

      Rectangle.of_edges left: xi, top: yi, right: xl, bottom: yl
    end

    # Frame memo for `minimal_rectangle`: without it, nested shrink_to_fit widgets
    # re-derive the same subtree rectangle once per ancestor shrink pass plus
    # their own render — O(depth × subtree) per frame. Keyed on the exact
    # arguments plus `Window#renders`, so a moved/resized caller or a new frame
    # recomputes; `#update` clears it eagerly.
    @_minrect : Rectangle?
    @_minrect_key : Tuple(Int32, Int32, Int32, Int32, Bool, Int32)?

    # Drops the frame-memoized `minimal_rectangle` result.
    protected def invalidate_minimal_rectangle : Nil
      @_minrect = nil
    end

    # Returns minimum widget size
    private def minimal_rectangle(xi, xl, yi, yl, rendered)
      key = {xi, xl, yi, yl, rendered, window?.try(&.renders) || -1}
      if (r = @_minrect) && @_minrect_key == key
        return r
      end
      r = minimal_rectangle_uncached(xi, xl, yi, yl, rendered)
      @_minrect = r
      @_minrect_key = key
      r
    end

    # :ditto: — the uncached computation.
    private def minimal_rectangle_uncached(xi, xl, yi, yl, rendered)
      children_rect = minimal_children_rectangle(xi, xl, yi, yl, rendered)
      content_rect = minimal_content_rectangle(xi, xl, yi, yl)
      xll = xl
      yll = yl

      # Figure out which one is bigger and use it.
      if children_rect.width > content_rect.width
        xi = children_rect.xi
        xl = children_rect.xl
      else
        xi = content_rect.xi
        xl = content_rect.xl
      end

      if children_rect.height > content_rect.height
        yi = children_rect.yi
        yl = children_rect.yl
      else
        yi = content_rect.yi
        yl = content_rect.yl
      end

      # Recenter shrunken elements (`center`/`center±N`): a shrunk widget pulled
      # its origin back by half its full width in `aleft`, so recentering by half
      # the freed space keeps an offset-centered widget from landing far off.
      if xl < xll && center_expr?(eff_left)
        xll = (xll - xl) // 2
        xi += xll
        xl += xll
      end

      if yl < yll && center_expr?(eff_top)
        yll = (yll - yl) // 2
        yi += yll
        yl += yll
      end

      Rectangle.of_edges left: xi, top: yi, right: xl, bottom: yl
    end
  end
end
