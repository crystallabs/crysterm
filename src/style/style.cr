module Crysterm
  # The complete style of a widget.
  class Style
    include Colorizable

    # Foreground color (color of font/character).
    #
    # The native color form is a `0xRRGGBB` integer (`-1` = terminal default,
    # `nil` = "no color set", so no SGR sequence is emitted and the terminal
    # default applies). The setter also accepts `"#rrggbb"`/named-color strings,
    # parsing them to the native int via `Colors.convert`.
    getter fg : Int32?

    # Background color (color of cell). See `#fg` for the accepted forms.
    getter bg : Int32?

    # SGR text-attribute booleans. The plain `property?` setters this generates
    # are re-wrapped below to track explicit assignment in `specified_mask`,
    # regardless of include order.
    include TextAttributes

    # Whether the widget is visible (CSS `visibility`). Widget-level, not an SGR
    # attribute — deliberately on `Style` itself, not `TextAttributes`, so
    # `Border` (which shares the SGR mixin) doesn't inherit a meaningless
    # `visible?`. The setter is re-wrapped below for `specified_mask`, like the
    # SGR booleans.
    property? visible : Bool = true

    # Opacity (inverse of transparency). 0 == full transparency, 1 == full opacity.
    property opacity : Float64?

    # A color the whole widget region is blended toward, by `tint_alpha`.
    # `nil` = no tint. See `#fg` for the accepted forms.
    getter tint : Int32?

    # Strength of the `tint` overlay: `0.0` = none, `1.0` = fully the tint color.
    property tint_alpha : Float64 = 0.5

    Colorizable.color_setter tint

    # Compositing layer (CSS `z-index`). When set, the widget and its subtree are
    # promoted to their own `Plane` at this z, composited over the base so
    # content from other widgets can show through; `opacity` becomes the plane's
    # opacity. `nil` = the base layer (the ordinary painter's path).
    #
    # Meaningful *relative to the theme's planes*: the built-in theme places
    # chrome on low planes (e.g. scroll bars on plane 5, menus/popups higher),
    # so a floating overlay that must cover them needs a `z_index` above the
    # plane it overlaps — grep the theme for the current numbers.
    property z_index : Int32?

    # How a `background_image` is scaled to fill the widget box.
    enum BackgroundSize
      Cover   # fill the box, preserve aspect, crop overflow (default)
      Contain # fit entirely inside the box, preserve aspect, letterbox remainder
      Stretch # stretch to fill exactly, ignoring aspect (CSS `100% 100%`)
      Auto    # natural size, no scaling (CSS default `auto`)
    end

    # CSS `background-image`: the `url(...)` path/URL of an image painted behind
    # the widget's own content. `nil` = none. Realized lazily as an internal
    # `Widget::Media` background layer, so it only has visible effect where a
    # background-capable backend is available (Kitty for true pixels under the
    # text, or the cell-grid `Glyph`/`Ansi` fallback).
    property background_image : String?

    # CSS `background-size`: how `background_image` fills the box. Defaults to
    # `Cover` rather than the strict CSS `auto`, as the more useful default for a
    # widget backdrop.
    getter background_size : BackgroundSize = BackgroundSize::Cover

    def background_size=(value : BackgroundSize) : BackgroundSize
      @specified_mask |= SPEC_BACKGROUND_SIZE
      @background_size = value
    end

    # CSS `transition`: animatable property name -> `{duration, easing}`. When an
    # animated property's value changes (e.g. on a `:hover`/`:focus` state
    # change) the new value tweens in over its duration rather than snapping.
    property transitions : Hash(String, Tuple(Time::Span, Easing))?

    # A CSS `animation` binding: which `@keyframes` to play and how. `nil` = none.
    record AnimationSpec,
      name : String,
      duration : Time::Span,
      easing : Easing = Easing::Linear,
      iterations : Int32? = nil, # nil = infinite
      alternate : Bool = false   # ping-pong direction each cycle

    # CSS `animation`: a named `@keyframes` sequence to loop.
    property animation : AnimationSpec?

    # Tracks which text-attribute booleans (and struct properties) were
    # explicitly set, vs left at default, so the CSS cascade can tell "set to
    # false" from "unset". Colors and `opacity` carry their own unset signal
    # (`nil`), so they aren't tracked here.
    #
    # Must stay a bitmask rather than a `Set(Symbol)`: the cascade `#dup`s a
    # style per state per recompute (hundreds-thousands per frame on a deep
    # tree), and a `UInt32` is copied for free by the shallow `super` dup, so
    # that path allocates nothing.
    protected property specified_mask : UInt32 = 0_u32

    # Bit per tracked property. Order is arbitrary but must stay stable within a
    # build (the mask is never persisted across builds).
    {% begin %}
      # Split by getter form so one list also drives `#fold_specified_onto`:
      # boolean attributes are read through their `?` getter, the rest through a
      # plain getter. `tracked` is their concatenation and defines the bitmask.
      {% tracked_bool = %w[bold italic underline blink reverse strike visible
           fill draw_over_border] %}
      {% tracked_value = %w[background_size fill_char border padding margin
           shadow tab_size tab_char] %}
      {% tracked = tracked_bool + tracked_value %}
      {% for prop, i in tracked %}
        SPEC_{{ prop.upcase.id }} = 1_u32 << {{ i }}
      {% end %}

      # The mask bit for a tracked property symbol; `0` if untracked, those
      # using a `nil` unset signal answered directly in `#specified?`.
      private def specified_bit(property : Symbol) : UInt32
        case property
        {% for prop in tracked %}
        when :{{ prop.id }} then SPEC_{{ prop.upcase.id }}
        {% end %}
        else 0_u32
        end
      end

      # Folds every explicitly-set *tracked* property of this style onto *other*,
      # copying each only where `specified?` reports it set, so an inline style
      # can switch a value on *or* off over a stylesheet. The assignments go
      # through *other*'s setters, stamping *other*'s `specified_mask` too. The
      # remaining, `nil`-signalled properties (`fg`/`bg`/`opacity`/`tint`/…) carry
      # no mask bit and are folded by hand in the cascade.
      def fold_specified_onto(other : Style) : Nil
        {% for prop in tracked_bool %}
          other.{{ prop.id }} = {{ prop.id }}? if specified?(:{{ prop.id }})
        {% end %}
        {% for prop in tracked_value %}
          {% if %w[border padding margin shadow].includes?(prop) %}
            # Mutable box sub-objects must be copied, not shared by reference:
            # the longhand tiers (`border-left`, `padding-top`, …) mutate the
            # folded object in place, which would permanently corrupt the user's
            # inline `@style`. Mirrors `Style#dup`'s policy. Gated on
            # `box_touched?`, not `specified?`: an in-place `padding.left = 2`
            # through the lazy getter never stamps the mask, but must still
            # survive the fold.
            other.{{ prop.id }} = {{ prop.id }}.dup if box_touched?(:{{ prop.id }})
          {% else %}
            other.{{ prop.id }} = {{ prop.id }} if specified?(:{{ prop.id }})
          {% end %}
        {% end %}
      end
    {% end %}

    # Whether *property* was explicitly set on this style.
    def specified?(property : Symbol) : Bool
      case property
      when :fg               then !@fg.nil?
      when :bg               then !@bg.nil?
      when :opacity          then !@opacity.nil?
      when :tint             then !@tint.nil?
      when :gridline_color   then !@gridline_color.nil?
      when :z_index          then !@z_index.nil?
      when :background_image then !@background_image.nil?
      when :transitions      then !@transitions.nil?
      when :animation        then !@animation.nil?
      when :glyph            then !@glyph.nil?
      when :glyph_ascii      then !@glyph_ascii.nil?
      when :glyph_unicode    then !@glyph_unicode.nil?
      when :glyph_extended   then !@glyph_extended.nil?
      when :glyph_open       then !@glyph_open.nil?
      when :glyph_close      then !@glyph_close.nil?
      when :glyphs           then !@glyphs.nil?
      when :light            then !@light.nil?
      when :look             then !@look.nil?
      else                        (@specified_mask & specified_bit(property)) != 0_u32
      end
    end

    # Whether the *property* box was effectively set by the user: explicitly
    # assigned through its setter (`specified?`), or materialized via the lazy
    # getter and mutated in place to a non-zero side (`style.border.left = 1`
    # never stamps the mask). Compared against the getter-materialization
    # default — an all-zero box — NOT the class resting defaults (`Border`
    # rests at 1,1,1,1; `Shadow` at right 2/bottom 1), so a merely-*read* box
    # stays untouched. Accepted residue: side-less in-place edits (border
    # `fg`/`type`/chars with all sides 0) read as untouched — visually moot,
    # a zero-side box renders nothing — and an in-place reset back to all-zero
    # reads as untouched (use the setter to express "explicitly off").
    def box_touched?(property : Symbol) : Bool
      return true if specified?(property)
      box = case property
            when :border  then @border
            when :padding then @padding
            when :margin  then @margin
            when :shadow  then @shadow
            end
      return false unless box
      box.left != 0 || box.top != 0 || box.right != 0 || box.bottom != 0
    end

    # Monotonic revision of the attr-relevant fields — exactly the set
    # `Widget.style_to_attr` reads: `fg`/`bg`, the six SGR booleans and
    # `visible`. Every setter of one of those fields bumps it, whether or not
    # the value changed (over-invalidation is safe; a missed bump is not), so a
    # consumer can memoize the style→attr derivation on
    # `{style identity, attr_revision}` and still track *in-place* mutation —
    # `Effect::CopperBar` re-assigns `style.bg` every frame without swapping the
    # object, which is why identity gating alone is unsafe (see
    # `process_content`'s cache-hit tail, the one such memo today). Deliberately
    # NOT bumped by anything `style_to_attr` doesn't read: the box sub-objects
    # (`border`/`padding`/`margin`/`shadow`), nested sub-`Style`s, `opacity`/
    # `tint`/glyphs/`tab_*`/`fill`* — their mutations can't change the memoized
    # attr. Only monotonicity is guaranteed (a logical operation may bump
    # several times), so compare for equality — don't count increments.
    getter attr_revision : Int64 = 0_i64

    # Raised on an attribute write to a frozen render-derived `Style` copy
    # (see `Style#freeze!`): the write would land on a transient object and be
    # silently lost. Write via `Widget#restyle`/`#state_style` (the persistent
    # per-state style) or `#inline_style=` instead.
    class FrozenError < Exception
      def initialize
        super "Can't mutate the transient highlight copy Widget#style returns for a focused/selected widget at the unstyled floor; write via #restyle / #state_style (or #inline_style=)"
      end
    end

    # Whether this style is a frozen render-derived copy (see `#freeze!`).
    getter? frozen : Bool = false

    # A `#dup` starts life mutable regardless of the source (the established
    # dup-then-mutate convention must keep working on a frozen copy).
    protected setter frozen : Bool

    # Marks this style as a frozen render-derived copy: the attribute setters
    # (`fg`/`bg`, the SGR booleans, `visible`) raise `FrozenError` instead of
    # accepting a write that would be silently lost when the copy is next
    # re-derived. Applied to the transient focus/selection reverse-video
    # fallback copies that `Widget#style` can return at the unstyled floor —
    # the one object where the natural `w.style.bg = "red"` spelling used to
    # intermittently vanish. A tripwire, not full immutability: only the
    # attribute setters (the fields programmatic styling animates — exactly
    # `attr_revision`'s set) are guarded.
    def freeze! : self
      @frozen = true
      self
    end

    # The frozen-copy tripwire, run by the attribute setters below.
    # `AlwaysInline` so the (default, unfrozen) case folds to one flag test in
    # the hot animation path (`style.bg = …` per frame).
    @[AlwaysInline]
    private def frozen_write_check : Nil
      raise FrozenError.new if @frozen
    end

    # Re-wrap the `property?`-generated boolean setters so each explicit
    # assignment is recorded, making `bold = false` distinguishable from the
    # default `false` — and `attr_revision` advanced (every field here is in
    # `style_to_attr`'s read set).
    {% for attr in %w[bold italic underline blink reverse strike visible] %}
      def {{ attr.id }}=(value : Bool) : Bool
        frozen_write_check
        @specified_mask |= SPEC_{{ attr.upcase.id }}
        @attr_revision &+= 1
        @{{ attr.id }} = value
      end
    {% end %}

    # Re-wrap the `Colorizable`-generated `fg=`/`bg=` overloads so every color
    # assignment advances `attr_revision` too; `super` runs the module's
    # matching overload (native `Int` store / `String` parse / `Nil` clear)
    # unchanged. Kept here rather than inside `Colorizable.color_setter`:
    # `Border` shares that mixin and carries no revision (no consumer memoizes
    # a border-derived attr on one), and `tint`/`gridline_color` are outside
    # `style_to_attr`'s read set.
    {% for color in %w[fg bg] %}
      {% for type in %w[Int String Nil] %}
        def {{ color.id }}=(color : {{ type.id }})
          frozen_write_check
          @attr_revision &+= 1
          super
        end
      {% end %}
    {% end %}

    # A deep-enough copy: the mutable box sub-objects (`border`/`padding`/
    # `margin`/`shadow`, mutated in place by e.g. `border-left`/`padding-top`)
    # get independent instances, so a copy can't be corrupted by later edits to
    # the original. Sub-styles like `scrollbar` are replaced, not mutated, so
    # they stay shared.
    def dup
      copy = super
      # A copy starts mutable even when the source is a frozen render-derived
      # copy — dup-then-mutate (`style.dup.tap(&.underline = true)`) is the
      # sanctioned way to derive from one.
      copy.frozen = false
      @border.try { |border| copy.border = border.dup }
      # The boxes are lazy (nil until first set/read) and read through the ivar,
      # so a style that never touched one costs no dup here. Most widgets set no
      # box geometry, and the cascade dups every recompute candidate per state.
      @padding.try { |padding| copy.padding = padding.dup }
      @margin.try { |margin| copy.margin = margin.dup }
      @shadow.try { |shadow| copy.shadow = shadow.dup }
      # The setters above stamp their bits into the copy's mask, so restore our
      # exact mask; the dup must report precisely what we explicitly set.
      copy.specified_mask = @specified_mask
      copy
    end

    # Clears border and padding on this style in place, for a chrome row that
    # must never carry the container's frame — e.g. a fixed-height-1 header
    # or status row, where the container's border/padding would eat some or
    # all of the row's interior (a 1-row box with a border has a negative
    # content height). Always mutates `self`, so callers that don't already
    # own an independent copy must `#dup` first — matching the existing
    # dup-then-mutate convention (see `ToolBox#add_item`, `Pine::StatusBar`).
    # `Mixin::ItemView#without_border` strips border only, since list items
    # keep their own padding.
    def strip_frame! : self
      self.border = false
      self.padding = 0
      self
    end

    # A copy of this style with its frame stripped (`#strip_frame!`) — the
    # dup-then-mutate convenience (paralleling `#with_reverse_fallback`) for a
    # fixed-height-1 chrome row (a `ToolBox` header, a `Pine::StatusBar` inner
    # box) that must never carry the container's border/padding: a bordered
    # 1-row box has a negative content interior and blanks its own row.
    # *visible* forces the copy's visibility when given; left `nil` (the default)
    # the dup's `visible` flag is untouched — a caller that needs the row shown
    # regardless of the container's hidden state passes `visible: true`.
    def stripped_frame(visible : Bool? = nil) : Style
      dup.tap do |s|
        s.visible = visible unless visible.nil?
        s.strip_frame!
      end
    end

    # A copy of this style with only its `#border` cleared — unlike
    # `#stripped_frame`/`#strip_frame!`, `#padding` is left untouched. For a
    # site that inherits a container's own style via sub-style (a
    # `Widget::GroupBox` title) but must render as inline text with no framing
    # box drawn around it, while keeping any padding/label styling intact.
    def without_border : Style
      dup.tap(&.border=(false))
    end

    # Whether this style carries a visible distinction of its own — an explicit
    # `fg`/`bg` color, or reverse-video — as opposed to being fully unstyled.
    def visibly_styled? : Bool
      specified?(:fg) || specified?(:bg) || reverse?
    end

    # A copy of this style with reverse-video forced on when it is not already
    # `#visibly_styled?`, else `self` untouched. Lets a state (selection, focus)
    # still read against an unstyled floor.
    def with_reverse_fallback : Style
      return self if visibly_styled?
      copy = dup
      copy.reverse = true
      copy
    end

    # Value fingerprint of the attribute fields a composed/derived style copy
    # takes from its source: colors, the `specified_mask`, the SGR booleans and
    # `visible`. Identity-keyed memos of such copies (`#alternate_row`'s
    # composition, the reverse-video fallbacks, `ListTable`'s alternate-row
    # derivation) compare this alongside `same?`, so an *in-place* mutation of
    # the source (`s.fg = ...` with no object swap, as programmatic styling
    # without CSS does) still invalidates them. `visible?` must be included:
    # `visible=` only ORs its mask bit, so a second hide/show flip changes
    # neither the mask nor any other field. Box sub-objects (`border`/
    # `padding`/…), `opacity`, `tint` etc. are deliberately outside the
    # fingerprint: no memoized consumer reads them from the copy (they read
    # attributes only), and a flat stack tuple keeps the per-read compare
    # allocation-free.
    alias AttrFingerprint = Tuple(Int32?, Int32?, UInt32, Bool, Bool, Bool, Bool, Bool, Bool, Bool)

    # :ditto:
    def attr_fingerprint : AttrFingerprint
      {@fg, @bg, @specified_mask, bold?, italic?, underline?, blink?, reverse?, strike?, visible?}
    end

    # Shared core of an identity+fingerprint memo over a derived `Style` copy.
    # Given the current source *src* and the previous memo triple
    # (*prev_src*/*prev_copy*/*prev_fp*), returns the stateless
    # `{result, src, copy, fp}` value tuple that `reverse_fallback_memo` uses:
    # the cached *prev_copy* is reused while the source is unchanged both by
    # identity (`same?` — a cascade swaps the backing object, so a hit means the
    # copy is still current) and by value (*prev_fp*, the source's
    # `#attr_fingerprint` at derivation time, so an in-place `src.fg = ...`
    # recomputes rather than returning a stale copy). On a miss the block
    # produces the fresh copy from *src*. A plain class method, not an instance
    # method: the three callers differ in what `self` is (a widget for the
    # reverse-video and `ListTable` alternate-row memos, the `Style` itself for
    # `#alternate_row`), so the source is passed explicitly. Each caller keeps
    # its own skip/short-circuit conditions and owns its memo triple — one widget
    # may run several of these per frame, so the storage stays separate.
    def self.memo_derive(src : Style, prev_src : Style?, prev_copy : Style?,
                         prev_fp : AttrFingerprint?, & : Style -> Style)
      fp = src.attr_fingerprint
      if prev_src && prev_src.same?(src) && prev_copy && prev_fp == fp
        return {prev_copy, prev_src, prev_copy, prev_fp}
      end
      copy = yield src
      {copy, src, copy, fp}
    end

    # Per-site memo of the `Widget.style_to_attr(style)` derivation for one
    # style slot, gated on {style identity via `same?`, `#attr_revision`}. Both
    # halves are load-bearing (same reasoning as `process_content`'s memo):
    # identity alone misses in-place mutation (an animation re-assigns
    # `style.bg` every frame without swapping the object — the revision bump
    # catches it), and revision alone misses a cascade swap (a different
    # `Style`'s counter is unrelated). No third "stamped default" part is
    # needed here, unlike `process_content`'s triple: this caches only the
    # derived value itself, with no external slot another style could have
    # rewritten in between. Holding the `Style` reference (not an `object_id`)
    # also keeps the style alive, so `same?` can't false-hit on a recycled
    # address.
    #
    # A mutable struct: hold it in an ivar or local and call `#fetch` on that
    # lvalue directly. Reading it through a copying accessor (a plain `getter`,
    # an `Array#[]`, a method return value) would mutate a temporary and
    # memoize nothing.
    struct AttrMemo
      @src : Style?
      @revision : Int64 = 0_i64
      @attr : Int64 = 0_i64

      # The packed attr for *style*: the cached value while *style* is the same
      # object at an unchanged `attr_revision`, else a fresh
      # `Widget.style_to_attr(style)` (restamping the key). Also serves call
      # sites spelled `style_to_attr(style, style.fg, style.bg)` — explicitly
      # passing the style's own colors packs the identical attr.
      def fetch(style : Style) : Int64
        if (src = @src) && src.same?(style) && @revision == style.attr_revision
          return @attr
        end
        @src = style
        @revision = style.attr_revision
        @attr = Widget.style_to_attr(style)
      end
    end

    # Is any transparency defined? Testing `opacity == nil` alone isn't enough:
    # 1.0 (full opacity) also means no transparency is enabled.
    def opacity?
      @opacity.try do |a|
        return a if a != 1.0
      end
    end

    # The active tint as `{color, alpha}`, or `nil` when no tint color is set or
    # the overlay is fully transparent (`tint_alpha == 0`, a no-op).
    def tint?
      @tint.try do |c|
        return {c, @tint_alpha} if @tint_alpha != 0.0
      end
    end

    # Length in number of characters to replace TABs with
    property tab_size = 4

    # Character to replace TABs with, multiplied by tab_size
    property tab_char = " "

    # Re-wrap the TAB-expansion setters so an explicit assignment is recorded as
    # `specified`; otherwise the defaults are indistinguishable from an
    # intentional value and the cascade drops an inline-set tab width/char. Must
    # come after the `property` declarations above to override their setters.
    def tab_size=(value : Int32) : Int32
      @specified_mask |= SPEC_TAB_SIZE
      @tab_size = value
    end

    def tab_char=(value : String) : String
      @specified_mask |= SPEC_TAB_CHAR
      @tab_char = value
    end

    # Character used to fill otherwise-empty cells the widget paints: alignment
    # gaps (`#align_line`), `fill_region`/`clear_pos` backfill, a `Fill`-type
    # `Border`'s fallback char, and the artificial cursor's `none`-shape glyph.
    property fill_char : Char = ' '

    # Re-wrap the fill-character setter so an explicit assignment is recorded as
    # `specified`; otherwise the `' '` default is indistinguishable from an
    # intentional `' '` and the cascade silently drops an inline-set fill char.
    # Must come after the `property` declaration above to override its setter.
    def fill_char=(value : Char) : Char
      @specified_mask |= SPEC_FILL_CHAR
      @fill_char = value
    end

    # -- CSS `glyph` property family ------------------------------------------
    #
    # A chrome-glyph override for the site/slot this style lands on; the one
    # property is addressed at different sites via sub-controls and state pseudos
    # (`CheckBox::indicator:checked { glyph: "x" }`). All fields are
    # `nil`-signalled (unset = ask the `Glyphs` registry), so they cost no
    # `specified_mask` bits. `Glyphs::NONE_STR` (CSS `glyph: none`) means "omit"
    # on run roles and "registry default" on cell roles; the consumer decides by
    # role class.
    #
    # The fields are `String?`, not `Char?`, because a CSS glyph value can be a
    # multi-codepoint grapheme a `Char` can't hold (an emoji-presentation `⚠️` =
    # base + VS16, a regional-indicator flag, any combining sequence). A
    # cell-role consumer reduces it to a lone `Char`; a run-role consumer takes
    # it whole.

    # Universal override: use this grapheme at any tier.
    property glyph : String?

    # Per-tier longhands (CSS `glyph-ascii`/`glyph-unicode`/`glyph-extended`).
    # Resolution falls *down* tiers within this layer, then to `glyph` — never
    # across layers mid-tier.
    property glyph_ascii : String?
    property glyph_unicode : String?
    property glyph_extended : String?

    # Delimiter pair around a composed indicator marker (CSS `glyph-open`/
    # `glyph-close`), e.g. a checkbox's `[`/`]`. `Glyphs::NONE_STR` omits the
    # delimiter entirely, shrinking the marker.
    property glyph_open : String?
    property glyph_close : String?

    # A sequence override (CSS `glyphs`): the string's characters are the ordered
    # steps of the site's sequence role — spinner frames, dial pointer ring, fill
    # ramp. `nil` = unset (ask the `Glyphs` sequence registry).
    property glyphs : String?

    # The CSS-specified glyph for *tier*: the tier longhand, falling down tiers,
    # else the universal `glyph`; `nil` when this style specifies none, so the
    # consumer asks the `Glyphs` registry. May return a full multi-codepoint
    # grapheme, or `Glyphs::NONE_STR` — see the field docs above.
    @[AlwaysInline]
    def glyph_for(tier : Glyphs::Tier) : String?
      case tier
      in .extended? then @glyph_extended || @glyph_unicode || @glyph_ascii || @glyph
      in .unicode?  then @glyph_unicode || @glyph_ascii || @glyph
      in .ascii?    then @glyph_ascii || @glyph
      end
    end

    # Whether the widget paints its background across the interior (the style's
    # fill glyph + attrs). `false` leaves whatever is underneath showing through —
    # e.g. a transparent overlay or a label that draws only its own text. Gated in
    # the render path (`fill && …` before the `fill_region` sweep).
    property? fill = true

    # Whether the widget may paint into its own border band rather than only the
    # interior — lets a `Widget::Scrollbar` sit *on* the frame instead of inset
    # from it. Kept as a plain cascadeable `Style` flag: the name is descriptive
    # and no broader "draw over chrome" abstraction has proven worth the churn, so
    # it stays scrollbar-scoped.
    property? draw_over_border : Bool = false

    # Re-wrap the `fill`/`draw_over_border` setters so an explicit assignment is
    # recorded as `specified`; otherwise the defaults are indistinguishable from
    # an intentional value and the cascade drops an inline-set one. Must come
    # after the `property?` declarations above to override their setters.
    def fill=(value : Bool) : Bool
      @specified_mask |= SPEC_FILL
      @fill = value
    end

    def draw_over_border=(value : Bool) : Bool
      @specified_mask |= SPEC_DRAW_OVER_BORDER
      @draw_over_border = value
    end

    # Color of a table's internal gridlines (Qt's `gridline-color`). `nil` (the
    # default) means the gridlines follow the box `border` color. When set, it
    # overrides just the gridline foreground; other border attributes are kept.
    # See `#fg` for the accepted forms.
    getter gridline_color : Int32?

    Colorizable.color_setter gridline_color

    def border=(value : Bool | BorderType | Border | Side | Symbol | Int32?)
      @specified_mask |= SPEC_BORDER
      @border = Border.from value
    end

    # Border is always a non-nil object. "No border" is a `Border` whose sides
    # are all 0, which renders nothing and expands the widget by nothing.
    getter border : Border { Border.new 0 }

    def padding=(value : Bool | Padding | Side | Symbol | Int32 | Tuple(Int32, Int32) | Tuple(Int32, Int32, Int32, Int32)?)
      @specified_mask |= SPEC_PADDING
      @padding = Padding.from value
    end

    # Element's inner spacing. Lazy: an untouched box stays `nil` so `#dup`
    # copies nothing for it, and is materialized on first access so the per-side
    # longhands (`padding-left`, …) can mutate it in place. Never a shared
    # singleton — each style owns its box.
    getter padding : Padding { Padding.default }

    # Element's outer spacing. Unlike `padding`/`border`, which are inner insets,
    # margin offsets and shrinks the element itself within its allotted slot.
    def margin=(value : Bool | Margin | Side | Symbol | Int32 | Tuple(Int32, Int32) | Tuple(Int32, Int32, Int32, Int32)?)
      @specified_mask |= SPEC_MARGIN
      @margin = Margin.from value
    end

    # :ditto: (lazy, like `#padding`).
    getter margin : Margin { Margin.default }

    # Should element drop shadow?
    def shadow=(value : Bool | Shadow | Side | Symbol | Float64 | Int32?)
      @specified_mask |= SPEC_SHADOW
      @shadow = Shadow.from value
    end

    # :ditto: (lazy, like `#padding`).
    getter shadow : Shadow { Shadow.default }

    # This widget's light override — where the light sits for its border
    # relief shading, weight bevel and shadow placement. Unset (`nil`, the
    # default) the widget follows the window's scene light (`Window#light`,
    # itself defaulting to the classic NW directional). Accepts a `Light`,
    # or a bare direction (`Light::Direction` / its symbol, `:ne`) for a
    # directional light from there. See `Light` and plans/BORDERS.md § 4.
    getter light : Light?

    def light=(value : (Light | Light::Direction | Symbol)?)
      @light = value.nil? ? nil : Light.from(value)
    end

    # Predefined 3D looks: one keyword bundling `Border#relief`,
    # `Border#relief_style` and the shadow into the common combinations, so
    # "make it look raised" is a single assignment instead of hand-assembly
    # (see plans/BORDERS.md § 4.3). Each look only *sets* the underlying
    # options — they stay individually adjustable afterwards.
    enum Look
      Flat     # relief off (border/shadow otherwise untouched)
      Raised   # outset relief, color shading
      Sunken   # inset relief, color shading
      Beveled  # outset relief in glyph weight (the styling.cr bevel)
      Chiseled # inset relief in glyph weight
      Floating # auto-placed thin shadow (sides follow the light)
      Elevated # Raised + Floating
    end

    getter look : Look?

    # Applies *value*'s bundle (see `Look`). A look that shades or weights
    # the frame materializes a default 1-cell solid border when none is
    # visible yet; `Floating`/`Elevated` add an auto-placed `ratio: :half`
    # shadow unless one is already set. `nil` only clears the stored look
    # (the expanded options keep their values — use `Look::Flat` to switch
    # the relief off).
    def look=(value : (Look | Symbol)?)
      if value.nil?
        @look = nil
        return value
      end
      value = Look.parse value.to_s if value.is_a?(Symbol)
      @look = value
      case value
      in .flat?
        @border.try do |b|
          b.relief = Border::Relief::None
          b.relief_style = Border::ReliefStyle::Shade
        end
      in .raised?   then look_relief Border::Relief::Outset, Border::ReliefStyle::Shade
      in .sunken?   then look_relief Border::Relief::Inset, Border::ReliefStyle::Shade
      in .beveled?  then look_relief Border::Relief::Outset, Border::ReliefStyle::Weight
      in .chiseled? then look_relief Border::Relief::Inset, Border::ReliefStyle::Weight
      in .floating? then look_shadow
      in .elevated?
        look_relief Border::Relief::Outset, Border::ReliefStyle::Shade
        look_shadow
      end
      value
    end

    # A look that shades/weights the frame needs a visible frame: an unset
    # or zero-side border materializes as the default 1-cell solid box.
    private def look_relief(relief : Border::Relief, rendition : Border::ReliefStyle) : Nil
      b = @border
      if b.nil? || !b.any?
        self.border = true
      end
      border.relief = relief
      border.relief_style = rendition
    end

    # The floating look's shadow: auto-placed (sides follow the light at
    # render time), thin, added only when the style has none yet.
    private def look_shadow : Nil
      self.shadow = Shadow.new(ratio: :half) unless @shadow.try(&.any?)
    end

    def initialize(
      *,
      border = nil,
      padding = nil,
      margin = nil,
      shadow = nil,
      @scrollbar = @scrollbar,
      @track = @track,
      @sub_line = @sub_line,
      @add_line = @add_line,
      @sub_page = @sub_page,
      @add_page = @add_page,
      @up_arrow = @up_arrow,
      @down_arrow = @down_arrow,
      @left_arrow = @left_arrow,
      @right_arrow = @right_arrow,
      @alternate_row = @alternate_row,
      @indicator = @indicator,
      @item = @item,
      @prefix = @prefix,
      @separator = @separator,
      @tab = @tab,
      @title = @title,
      @pane = @pane,
      @close_button = @close_button,
      @float_button = @float_button,
      @drop_down = @drop_down,
      @header = @header,
      @cell = @cell,
      @label = @label,
      fg = nil,
      bg = nil,
      bold = nil,
      italic = nil,
      underline = nil,
      blink = nil,
      reverse = nil,
      strike = nil,
      visible = nil,
      opacity : Float64? = nil,
      fill_char = nil,
      draw_over_border = nil,
      z_index = nil,
      tint = nil,
      tint_alpha = nil,
      gridline_color = nil,
      background_image = nil,
      background_size = nil,
      transitions = nil,
      animation = nil,
      tab_size = nil,
      tab_char = nil,
      fill = nil,
      @glyph : String? = nil,
      @glyph_ascii : String? = nil,
      @glyph_unicode : String? = nil,
      @glyph_extended : String? = nil,
      @glyph_open : String? = nil,
      @glyph_close : String? = nil,
      @glyphs : String? = nil,
      light = nil,
      look = nil,
    )
      # Route fg/bg through the setters so a native `0xRRGGBB` int is normalized
      # to its `#rrggbb` string (each call type — String, Int, Nil — resolves to
      # the matching `fg=`/`bg=` overload).
      self.fg = fg
      self.bg = bg
      # Route booleans through their setters too, but only when given, so a
      # constructed value is recorded as `specified` while an omitted one stays
      # at the default (unset).
      bold.try { |v| self.bold = v }
      italic.try { |v| self.italic = v }
      underline.try { |v| self.underline = v }
      blink.try { |v| self.blink = v }
      reverse.try { |v| self.reverse = v }
      strike.try { |v| self.strike = v }
      visible.try { |v| self.visible = v }
      opacity.try { |v| self.opacity = self.class.opacity_from(v) }
      # The `border=`/`padding=`/`margin=`/`shadow=` setters already coerce
      # their argument through `X.from` (and record `specified_mask`), so route
      # the raw ctor argument straight to the setter instead of pre-coercing it
      # here.
      border.try { |v| self.border = v }
      padding.try { |v| self.padding = v }
      margin.try { |v| self.margin = v }
      shadow.try { |v| self.shadow = v }
      # Only record an explicitly-passed fill character as `specified`.
      fill_char.try { |v| self.fill_char = v }
      # Only record an explicitly-passed `draw_over_border` as `specified`.
      draw_over_border.try { |v| self.draw_over_border = v }
      # Tint/gridline are colors: route them through their `Colorizable`
      # setters unconditionally, exactly like `fg`/`bg` above, so an
      # `0xRRGGBB` int, a `"#rrggbb"`/named string, and `nil` each pick the
      # matching overload.
      self.tint = tint
      self.gridline_color = gridline_color
      z_index.try { |v| self.z_index = v }
      tint_alpha.try { |v| self.tint_alpha = v }
      background_image.try { |v| self.background_image = v }
      background_size.try { |v| self.background_size = v }
      transitions.try { |v| self.transitions = v }
      animation.try { |v| self.animation = v }
      tab_size.try { |v| self.tab_size = v }
      tab_char.try { |v| self.tab_char = v }
      fill.try { |v| self.fill = v }
      light.try { |v| self.light = v }
      # After `border`/`shadow`, so the look's bundle lands on the
      # constructed objects (and its materialized defaults don't shadow a
      # passed-in border).
      look.try { |v| self.look = v }
    end

    def self.opacity_from(value : Float64?)
      value
    end
  end
end

# The nested sub-`Style` slot machinery (`sub_style_accessor` slots, the
# alternate-row composition, the slot-name mapping methods) reopens the class
# from its own file. Required from here — not from the crysterm.cr manifest —
# so the definition order is pinned wherever `style` itself is required.
require "./style_sub_styles"
