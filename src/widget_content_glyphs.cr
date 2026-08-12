module Crysterm
  class Widget
    # Whether grapheme / column-width-aware layout is in effect for this widget:
    # the owning window's effective gate (option AND terminal capability). False
    # when unattached.
    def full_unicode?
      window?.try(&.full_unicode_effective?) || false
    end

    # The glyph tier in effect for this widget (the owning window's screen
    # setting; `Unicode` when unattached — the registry's byte-identical
    # default).
    def glyph_tier : Glyphs::Tier
      window?.try(&.glyph_tier) || Glyphs::Tier::Unicode
    end

    # Whether the octant corner pieces are in effect for this widget (the
    # owning window's screen setting; `false` when unattached). See
    # `Screen#glyph_octants?`.
    def glyph_octants? : Bool
      window?.try(&.glyph_octants?) || false
    end

    # The registry character for *role* at this widget's effective tier. The
    # single hook widget renders use instead of hardcoded chrome literals.
    @[AlwaysInline]
    def glyph(role : Glyphs::Role) : Char
      Glyphs[role, glyph_tier]
    end

    # The registry *grapheme* (String) for a *run* role at this widget's effective
    # tier — the String companion to `#glyph`. A run-role site (an inline, measured
    # text run) uses this so a multi-codepoint upgrade like `⚠️` renders whole,
    # instead of the reject-to-fallback single `Char` `#glyph` yields for fixed
    # 1-column cell roles.
    @[AlwaysInline]
    def glyph_str(role : Glyphs::Role) : String
      Glyphs.str(role, glyph_tier)
    end

    # Like the above, but resolving a CSS-styled site first: the *slot* style's
    # `glyph` family at the effective tier, else the registry. *slot* is the
    # sub-`Style` the CSS property lands on — pass `style.raw_sub_style(...)` for a
    # sub-control site (only an explicitly cascaded/assigned sub-style answers, so
    # a widget-wide `glyph` can't bleed into every part of a multi-part widget), or
    # `style` itself for a single-glyph widget (`SizeGrip { glyph: "◢" }`).
    #
    # A CSS `glyph: none` — and, on a *cell* role, any value that isn't exactly one
    # column — is unusable here and falls back to the registry. Run-role callers
    # that want the whole grapheme use `#glyph_str`/`#glyph_str?`; ones that honor
    # `none` by omitting a single-`Char` glyph use `#glyph?`.
    def glyph(role : Glyphs::Role, slot : ::Crysterm::Style?) : Char
      tier = glyph_tier
      if slot && (s = slot.glyph_for(tier)) && (c = usable_cell_glyph(s, role))
        return c
      end
      Glyphs[role, tier]
    end

    # Run-role variant of `#glyph(role, slot)` honoring CSS `glyph: none`: returns
    # `nil` when the style says to omit the glyph entirely (zero cells).
    # `Char`-typed for callers that draw a single-cell affordance; a
    # multi-codepoint CSS override can't fit here and falls back to the registry
    # (use `#glyph_str?` for the whole grapheme). Not for cell roles, which must
    # always paint.
    def glyph?(role : Glyphs::Role, slot : ::Crysterm::Style?) : Char?
      tier = glyph_tier
      if slot && (s = slot.glyph_for(tier))
        return if s == Glyphs::NONE_STR
        return s[0] if s.size == 1
        # Multi-codepoint override: not representable as a lone cell `Char`.
      end
      Glyphs[role, tier]
    end

    # The resolved drop-down arrow affordance: CSS `::drop-down { glyph: … }`,
    # then the registry `DropdownArrow` role; `nil` when the stylesheet says
    # `glyph: none`. Shared by `ComboBox` (which memoizes it for restyle
    # detection) and `ToolButton`'s popup indicator.
    protected def dropdown_arrow : Char?
      glyph?(Glyphs::Role::DropdownArrow, style.raw_sub_style("drop-down"))
    end

    # `#dropdown_arrow` as a leading-space suffix (`" ▾"`), or `""` when the
    # arrow is omitted so its cell collapses.
    protected def dropdown_indicator_suffix : String
      (a = dropdown_arrow) ? " #{a}" : ""
    end

    # Run-role, grapheme-returning companion to `#glyph(role, slot)`: the
    # slot's CSS glyph *whole* (a multi-codepoint `⚠️` survives) when set and
    # not `none`, else the registry grapheme. For measured inline runs where a
    # wide/emoji override should render as-is rather than reduce to a `Char`.
    def glyph_str(role : Glyphs::Role, slot : ::Crysterm::Style?) : String
      tier = glyph_tier
      if slot && (s = slot.glyph_for(tier)) && s != Glyphs::NONE_STR
        return s
      end
      Glyphs.str(role, tier)
    end

    # `#glyph_str` honoring CSS `glyph: none` — returns `nil` to omit the glyph
    # entirely (zero cells). The grapheme-returning analogue of `#glyph?`.
    def glyph_str?(role : Glyphs::Role, slot : ::Crysterm::Style?) : String?
      tier = glyph_tier
      if slot && (s = slot.glyph_for(tier))
        return if s == Glyphs::NONE_STR
        return s
      end
      Glyphs.str(role, tier)
    end

    # The "always-measure" path for a *single-placement* affordance role — the
    # non-`cell?` roles a widget paints once into a box it can size: the resolved
    # glyph as the whole grapheme *and* the terminal COLUMNS it occupies. Unlike
    # `#glyph(role, slot)`, which reduces to a lone 1-column `Char`, this keeps a
    # wide CSS/registry upgrade (`⚠️`) whole and reports its measured width so the
    # caller reserves that many columns (the box grows to fit rather than
    # clipping). Fixed-cell, fill-region roles stay on `#glyph`: a wide glyph makes
    # no sense in a 1-cell run replicated across the cross axis.
    #
    # `none` is not honored here (a placed affordance always paints) — it falls
    # back to the registry, exactly like `#glyph`.
    def glyph_measured(role : Glyphs::Role, slot : ::Crysterm::Style?) : {String, Int32}
      s = glyph_str(role, slot)
      {s, Unicode.width(s)}
    end

    # Reduces a CSS-specified glyph *s* to the lone `Char` usable for *role* as
    # a fixed cell, or `nil` when it can't stand in: `none`, a multi-codepoint
    # grapheme (no lone code point), or — on a *cell* role — a wide char that
    # would corrupt the grid. A run role tolerates a single wide char (an emoji
    # affordance). Width is checked only on this rare styled path.
    private def usable_cell_glyph(s : String, role : Glyphs::Role) : Char?
      return if s == Glyphs::NONE_STR
      return unless s.size == 1
      c = s[0]
      return if role.cell? && Unicode.width(c) != 1
      c
    end

    # The sequence steps for *role* (spinner frames, dial pointer ring, fill
    # ramps): the CSS `glyphs` string on *slot* when set (its characters are the
    # steps), else the registry sequence at the effective tier. With `cells: true`
    # (fill ramps — each step paints one grid cell) a CSS sequence containing any
    # non-1-column character is rejected wholesale, falling back to the registry.
    #
    # The CSS path allocates a fresh array per call (`String#chars`); the registry
    # path returns the stored array. Per-frame callers should therefore memoize
    # against `#glyph_key`; per-content-build callers use it directly.
    def glyph_seq(role : Glyphs::SeqRole, slot : ::Crysterm::Style = style, cells : Bool = false) : Array(Char)
      if (s = slot.glyphs) && !s.empty?
        chars = s.chars
        return chars unless cells && chars.any? { |c| Unicode.width(c) != 1 }
      end
      Glyphs.chars(role, glyph_tier)
    end

    # The identity key of the currently-resolved chrome glyphs for *slot*: its raw
    # glyph string, the active tier, and the global glyph generation. Widgets that
    # memoize glyph-derived content compare against this and rebuild only when it
    # changes.
    def glyph_key(slot : ::Crysterm::Style = style) : {String?, Glyphs::Tier, UInt64}
      {slot.glyphs, glyph_tier, Glyphs.generation}
    end
  end
end
