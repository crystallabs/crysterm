module Crysterm
  # Central registry of the "chrome" glyphs the toolkit draws — indicator
  # marks, scrollbar/slider parts, popup affordances, rules and junctions,
  # border families. One place defines every default, per support *tier*, so
  # widgets never re-type literal characters and an application can retheme
  # or ASCII-fy the whole toolkit at once (`Glyphs.set`, `Screen#glyph_tier`).
  #
  # A tier is a *glyph choice*, not an output encoding: picking `Tier::Ascii`
  # makes widgets ask for `+`/`-`/`|` style characters up front, while the
  # existing draw-time ACS/`ascii_fallback` reduction (see `window_drawing.cr`)
  # remains the reactive safety net for terminals that can't render whatever
  # was chosen.
  module Glyphs
    # Ordered support tiers. Resolution falls *down*: a role with no value at
    # the effective tier answers with the next lower tier's value, ending at
    # the always-present `ascii`.
    enum Tier : UInt8
      # 7-bit printable characters only. For dumb/serial/non-UTF-8 targets.
      Ascii
      # The CP437/WGL4-era repertoire (box drawing, blocks, simple geometric
      # shapes) that effectively every monospace font renders. The default —
      # it matches what the toolkit has always emitted.
      Unicode
      # Glyphs that need a modern font (fancy dingbats, Nerd Font icons,
      # emoji). Never auto-detected — font coverage can't be probed — so this
      # tier is strictly opt-in.
      Extended
    end

    # One role's characters: `ascii` is mandatory, higher tiers optional
    # (`nil` falls down a tier).
    record Entry, ascii : Char, unicode : Char? = nil, extended : Char? = nil do
      # The character to use at *tier*, falling down to lower tiers when this
      # entry defines none for it.
      def for(tier : Tier) : Char
        case tier
        in .extended? then @extended || @unicode || @ascii
        in .unicode?  then @unicode || @ascii
        in .ascii?    then @ascii
        end
      end
    end

    # Every chrome glyph the toolkit draws, by semantic role. Values live in
    # the registry table (`Glyphs[role, tier]`), not here.
    enum Role
      # -- Toggle indicators (CheckBox, RadioButton, Menu's checkable rows) --
      CheckboxOpen      # delimiter before the mark: `[`
      CheckboxClose     # delimiter after the mark: `]`
      CheckboxChecked   # the mark when checked
      CheckboxUnchecked # the mark when unchecked
      CheckboxPartial   # the mark when partially checked
      RadioOpen         # delimiter before the mark: `(`
      RadioClose        # delimiter after the mark: `)`
      RadioChecked      # the mark when selected
      RadioUnchecked    # the mark when not selected

      # -- Disclosure markers (Tree nodes, ToolBox section headers) ----------
      TreeExpanded
      TreeCollapsed
      TreeLeaf

      # -- Scrollbars / sliders ----------------------------------------------
      ScrollThumb
      ScrollTrough
      ArrowUp # scrollbar/spin arrows, also generic directional affordances
      ArrowDown
      ArrowLeft
      ArrowRight
      SliderHandle
      SliderTrack
      SliderTick

      # -- Popup / window-control affordances ---------------------------------
      SubmenuArrow  # Menu row that opens a submenu
      DropdownArrow # ComboBox closed state, ToolButton popup indicator
      CloseButton   # TabWidget closable tab, DockWidget close
      FloatButton   # DockWidget float/dock toggle
      FloatingMark  # DockWidget titlebar mark while floating
      SizeGrip

      # -- Rules and separators ------------------------------------------------
      LineHorizontal # Line/Splitter/Menu separator, horizontal rules
      LineVertical   # Line/Splitter divider, StatusBar/Calendar separators

      # -- Line junctions (table gridlines, border merge results) -------------
      JunctionCross     # `┼`
      JunctionTeeLeft   # `├` — junction on a left edge, opening right
      JunctionTeeRight  # `┤`
      JunctionTeeTop    # `┬`
      JunctionTeeBottom # `┴`

      # -- Cursor ---------------------------------------------------------------
      CursorBar # artificial cursor, `line` shape

      # -- Status icons (Message severities) -----------------------------------
      IconInfo
      IconWarning
      IconCritical
      IconQuestion

      # -- Misc chrome ----------------------------------------------------------
      DragHandle   # drag-ghost fallback label prefix
      LegendSwatch # chart legend color swatch
      MapMarker    # default map/graph point marker

      # -- Border families (see `BorderType#line_glyphs`) ---------------------
      # Four corners + horizontal/vertical runs per line family. The ASCII
      # values collapse every family to `+ - |`.
      BorderLineTL
      BorderLineTR
      BorderLineBL
      BorderLineBR
      BorderLineH
      BorderLineV
      BorderDoubleTL
      BorderDoubleTR
      BorderDoubleBL
      BorderDoubleBR
      BorderDoubleH
      BorderDoubleV
      BorderDashedTL
      BorderDashedTR
      BorderDashedBL
      BorderDashedBR
      BorderDashedH
      BorderDashedV
      BorderDottedTL
      BorderDottedTR
      BorderDottedBL
      BorderDottedBR
      BorderDottedH
      BorderDottedV
    end

    # Built-in defaults. The `unicode` column reproduces exactly what the
    # toolkit hardcoded before the registry existed (so the default tier is
    # byte-identical with history); the `ascii` column is the honest 7-bit
    # rendition; `extended` holds opt-in upgrades only.
    DEFAULTS = begin
      t = Array(Entry).new(Role.values.size, Entry.new(' '))
      set_in t, Role::CheckboxOpen, Entry.new('[')
      set_in t, Role::CheckboxClose, Entry.new(']')
      set_in t, Role::CheckboxChecked, Entry.new('x', nil, '✓')
      set_in t, Role::CheckboxUnchecked, Entry.new(' ')
      set_in t, Role::CheckboxPartial, Entry.new('-', nil, '◪')
      set_in t, Role::RadioOpen, Entry.new('(')
      set_in t, Role::RadioClose, Entry.new(')')
      set_in t, Role::RadioChecked, Entry.new('*', nil, '•')
      set_in t, Role::RadioUnchecked, Entry.new(' ')

      set_in t, Role::TreeExpanded, Entry.new('v', '▾')
      set_in t, Role::TreeCollapsed, Entry.new('>', '▸')
      set_in t, Role::TreeLeaf, Entry.new(' ')

      set_in t, Role::ScrollThumb, Entry.new('#', '█')
      set_in t, Role::ScrollTrough, Entry.new('.', '░')
      set_in t, Role::ArrowUp, Entry.new('^', '▲')
      set_in t, Role::ArrowDown, Entry.new('v', '▼')
      set_in t, Role::ArrowLeft, Entry.new('<', '◀')
      set_in t, Role::ArrowRight, Entry.new('>', '▶')
      set_in t, Role::SliderHandle, Entry.new('#', '█')
      set_in t, Role::SliderTrack, Entry.new('-', '─')
      set_in t, Role::SliderTick, Entry.new('.', '·')

      set_in t, Role::SubmenuArrow, Entry.new('>', '▶')
      set_in t, Role::DropdownArrow, Entry.new('v', '▾')
      set_in t, Role::CloseButton, Entry.new('x', '✕')
      set_in t, Role::FloatButton, Entry.new('^', '⇕')
      set_in t, Role::FloatingMark, Entry.new('#', '▣')
      set_in t, Role::SizeGrip, Entry.new('/', '◢')

      set_in t, Role::LineHorizontal, Entry.new('-', '─')
      set_in t, Role::LineVertical, Entry.new('|', '│')

      set_in t, Role::JunctionCross, Entry.new('+', '┼')
      set_in t, Role::JunctionTeeLeft, Entry.new('+', '├')
      set_in t, Role::JunctionTeeRight, Entry.new('+', '┤')
      set_in t, Role::JunctionTeeTop, Entry.new('+', '┬')
      set_in t, Role::JunctionTeeBottom, Entry.new('+', '┴')

      set_in t, Role::CursorBar, Entry.new('|', '│')

      set_in t, Role::IconInfo, Entry.new('i', 'ℹ')
      set_in t, Role::IconWarning, Entry.new('!', '⚠')
      set_in t, Role::IconCritical, Entry.new('x', '✖')
      set_in t, Role::IconQuestion, Entry.new('?')

      set_in t, Role::DragHandle, Entry.new('#', '⠿')
      set_in t, Role::LegendSwatch, Entry.new('#', '■')
      set_in t, Role::MapMarker, Entry.new('*', '●')

      set_in t, Role::BorderLineTL, Entry.new('+', '┌')
      set_in t, Role::BorderLineTR, Entry.new('+', '┐')
      set_in t, Role::BorderLineBL, Entry.new('+', '└')
      set_in t, Role::BorderLineBR, Entry.new('+', '┘')
      set_in t, Role::BorderLineH, Entry.new('-', '─')
      set_in t, Role::BorderLineV, Entry.new('|', '│')
      set_in t, Role::BorderDoubleTL, Entry.new('+', '╔')
      set_in t, Role::BorderDoubleTR, Entry.new('+', '╗')
      set_in t, Role::BorderDoubleBL, Entry.new('+', '╚')
      set_in t, Role::BorderDoubleBR, Entry.new('+', '╝')
      set_in t, Role::BorderDoubleH, Entry.new('=', '═')
      set_in t, Role::BorderDoubleV, Entry.new('|', '║')
      set_in t, Role::BorderDashedTL, Entry.new('+', '┌')
      set_in t, Role::BorderDashedTR, Entry.new('+', '┐')
      set_in t, Role::BorderDashedBL, Entry.new('+', '└')
      set_in t, Role::BorderDashedBR, Entry.new('+', '┘')
      set_in t, Role::BorderDashedH, Entry.new('-', '┄')
      set_in t, Role::BorderDashedV, Entry.new('|', '┆')
      set_in t, Role::BorderDottedTL, Entry.new('+', '┌')
      set_in t, Role::BorderDottedTR, Entry.new('+', '┐')
      set_in t, Role::BorderDottedBL, Entry.new('+', '└')
      set_in t, Role::BorderDottedBR, Entry.new('+', '┘')
      set_in t, Role::BorderDottedH, Entry.new('-', '┈')
      set_in t, Role::BorderDottedV, Entry.new('|', '┊')
      t
    end

    # (Array#[]= at const-build time; a def keeps `DEFAULTS` readable.)
    private def self.set_in(table : Array(Entry), role : Role, entry : Entry) : Nil
      table[role.value] = entry
    end

    # The live table. Starts as the defaults; `Glyphs.set` retunes it.
    @@table : Array(Entry) = DEFAULTS.dup

    # Bumped by every `Glyphs.set` so cached derivations (composed markers,
    # future frame caches) can notice a retheme. Registry changes are an
    # app-setup-time event; running screens should be asked to re-render after.
    class_getter generation : UInt64 = 0_u64

    # The character for *role* at *tier* (falling down tiers within the
    # entry). Hot-path safe: an array read plus at most two nil checks.
    @[AlwaysInline]
    def self.[](role : Role, tier : Tier) : Char
      @@table.unsafe_fetch(role.value).for(tier)
    end

    # The full entry for *role*.
    def self.entry(role : Role) : Entry
      @@table.unsafe_fetch(role.value)
    end

    # Overrides *role*'s characters. Omitted tiers keep their current value;
    # pass `unset: true` to clear the `unicode`/`extended` overrides back to
    # tier fall-down instead.
    def self.set(role : Role, ascii : Char? = nil, unicode : Char? = nil,
                 extended : Char? = nil, unset : Bool = false) : Nil
      e = @@table[role.value]
      @@table[role.value] = Entry.new(
        ascii || e.ascii,
        unicode || (unset ? nil : e.unicode),
        extended || (unset ? nil : e.extended),
      )
      @@generation += 1
    end

    # Restores every role to the built-in defaults.
    def self.reset : Nil
      DEFAULTS.each_with_index { |e, i| @@table[i] = e }
      @@generation += 1
    end
  end
end
