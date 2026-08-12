module Crysterm
  # Central registry of the "chrome" glyphs the toolkit draws — indicator
  # marks, scrollbar/slider parts, popup affordances, rules and junctions,
  # border families. One place defines every default, per support *tier*, so
  # widgets never re-type literal characters and an application can retheme
  # or ASCII-fy the whole toolkit at once (`Glyphs.set`, `Screen#glyph_tier`).
  #
  # A tier is a *glyph choice*, not an output encoding: picking `Tier::Ascii`
  # makes widgets ask for `+`/`-`/`|` style characters up front, while the
  # draw-time ACS/`ascii_fallback` reduction remains the reactive safety net
  # for terminals that can't render whatever was chosen.
  module Glyphs
    # Ordered support tiers. Resolution falls *down*: a role with no value at
    # the effective tier answers with the next lower tier's value, ending at
    # the always-present `ascii`.
    enum Tier : UInt8
      # 7-bit printable characters only. For dumb/serial/non-UTF-8 targets.
      Ascii
      # The CP437/WGL4-era repertoire (box drawing, blocks, simple geometric
      # shapes) that effectively every monospace font renders. The default.
      Unicode
      # Glyphs that need a modern font (fancy dingbats, Nerd Font icons,
      # emoji). Font coverage can't be *probed* (a missing glyph renders as
      # same-width tofu), so this tier is never chosen from a probe; it is
      # enabled by terminal-*identity* detection (`Glyphs.detected_tier`,
      # applied by `Screen` on a real tty when `screen.glyphs` wasn't set
      # explicitly) or by explicit opt-in.
      Extended
    end

    # The explicit "no glyph" sentinel (CSS `glyph: none`), stored in the
    # `Style` glyph fields — never in the registry table. A *run*-role site
    # renders nothing for it (the glyph contributes zero cells); a *cell*-role
    # site treats it as unset (registry default) since a cell must always be
    # painted. See `Role#cell?` and `Widget#glyph`/`Widget#glyph?`.
    NONE = '\0'

    # The `String` form of the "no glyph" sentinel, stored in `Style`'s glyph
    # fields. CSS `glyph: none` stores this; consumers compare against it to
    # mean "omit" (run role) / "registry default" (cell role). The sentinel is
    # a `String` because a CSS glyph value can be a multi-codepoint grapheme
    # (`⚠️`), which a `Char` can't hold.
    NONE_STR = NONE.to_s

    # One role's glyphs. `ascii` is a mandatory single 7-bit character — the
    # guaranteed 1-column fast lane. `unicode`/`extended` are optional
    # *Strings*, so a role can carry a multi-codepoint grapheme a `Char` can't
    # hold: an emoji-presentation `⚠️` (base + VS16), a regional-indicator
    # flag, any combining sequence. `nil` falls down a tier. `Char` arguments
    # are accepted and widened, so the DEFAULTS table reads as character
    # literals.
    #
    # Three accessors, mirroring the cell layer's ascii/grapheme split:
    # `#str` (the full grapheme, for measured *run* roles), `#char?` (the lone
    # codepoint or `nil`, the fast lane), and `#for` (a guaranteed `Char` with
    # reject-to-fallback, for fixed 1-column *cell* roles).
    struct Entry
      getter ascii : Char
      getter unicode : String?
      getter extended : String?

      # `#for(tier).to_s` per tier, precomputed once at construction so the
      # 1-column *cell*-role fast lane (`Glyphs.cell_str`) never allocates a
      # fresh String per call. Order matches `Tier`: {ascii, unicode, extended}.
      @cell_strs : {String, String, String}

      def initialize(@ascii : Char, unicode : Char | String? = nil,
                     extended : Char | String? = nil)
        @unicode = unicode.is_a?(Char) ? unicode.to_s : unicode
        @extended = extended.is_a?(Char) ? extended.to_s : extended
        @cell_strs = {
          for(Tier::Ascii).to_s,
          for(Tier::Unicode).to_s,
          for(Tier::Extended).to_s,
        }
      end

      # The full grapheme to use at *tier* (String), falling down to lower
      # tiers when this entry defines none for it. The *run*-role accessor:
      # returns the stored String reference (allocation-free) except on the
      # Ascii-tier `ascii`-only fallback, where the single char is boxed.
      def str(tier : Tier) : String
        case tier
        in .extended? then @extended || @unicode || @ascii.to_s
        in .unicode?  then @unicode || @ascii.to_s
        in .ascii?    then @ascii.to_s
        end
      end

      # The single Char to use at *tier* when the resolved grapheme is exactly
      # one codepoint, else `nil` — the lone-codepoint fast lane. `nil` tells a
      # caller the glyph is a multi-codepoint cluster it must render via `#str`.
      def char?(tier : Tier) : Char?
        s = str tier
        s.size == 1 ? s[0] : nil
      end

      # The Char to use at *tier* for a fixed 1-column *cell* role:
      # reject-to-fallback to the nearest lower tier that is a lone codepoint,
      # ending at `ascii`, so a multi-codepoint upgrade can never widen the
      # cell. This is the accessor for the fill-region cell roles (scrollbar,
      # slider, rules, junctions, borders — `Role#cell?`), which paint a single
      # char across a cross-axis run and so must stay exactly one column.
      #
      # The *single-placement* affordance roles (`SizeGrip`, `DockWidget`
      # close/float — not `cell?`) instead take the always-measure path via
      # `Entry#str` + `Widget#glyph_measured`: they keep a wide grapheme whole
      # and reserve its measured width. Both paths share this one table.
      def for(tier : Tier) : Char
        case tier
        in .extended? then lone(@extended) || lone(@unicode) || @ascii
        in .unicode?  then lone(@unicode) || @ascii
        in .ascii?    then @ascii
        end
      end

      # `#for(tier).to_s`, precomputed — the allocation-free String form of the
      # cell-role fast lane, for callers that need `#for`'s reject-to-fallback
      # `Char` boxed as a `String` (e.g. a CSS-override site that must return
      # `String?` alongside the registry fallback).
      def cell_str(tier : Tier) : String
        @cell_strs[tier.value]
      end

      private def lone(s : String?) : Char?
        s && s.size == 1 ? s[0] : nil
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
      # ProgressBar filled-portion cell. Drawn fg/bg-inverted, so the default
      # space shows as a solid bar of the fg color.
      ProgressFill
      # BigText "on"-pixel cell. The default space means "draw as reverse-video
      # blocks of the fg color"; any other char is painted literally.
      BigTextPixel

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
      CursorBar   # artificial cursor, `line` shape
      CursorBlock # artificial cursor, `block` shape — a literal glyph for any
      # consumer that needs to *draw* a block cursor (e.g. a custom `none`-shape
      # cursor with no `style.fill_char` of its own). The default steady-block
      # cursor itself never uses this: `Window#_artificial_cursor_attr` draws it
      # by reverse-videoing whatever character already occupies the cell, which
      # correctly keeps the underlying glyph visible (like a real terminal's
      # hardware cursor) rather than painting over it.

      # -- Status icons (Message severities) -----------------------------------
      IconInfo
      IconWarning
      IconCritical
      IconQuestion

      # -- Misc chrome ----------------------------------------------------------
      DragHandle   # drag-ghost fallback label prefix
      LegendSwatch # chart legend color swatch
      MapMarker    # default map/graph point marker

      # -- Icon palette -----------------------------------------------------------
      # A curated vocabulary of common UI icons (toolbar actions, status marks,
      # media transport, navigation), pre-picked per tier so applications don't
      # browse Unicode tables themselves: `tool_bar.add_item "#{glyph(Glyphs::Role::IconSave)} Save"`.
      # Not consumed by any widget — pure palette. These are *run* roles
      # (inline text, measured), so the `extended` column may hold
      # double-width emoji; `ascii`/`unicode` stay single-width.

      # File / document actions
      IconFileNew
      IconFolder
      IconFolderOpen
      IconSave
      IconPrint
      IconTrash
      # Edit actions
      IconCut
      IconCopy
      IconPaste
      IconUndo
      IconRedo
      IconSearch
      IconEdit
      IconSettings
      IconFilter
      # Status / feedback marks
      IconCheck
      IconCross
      IconStar
      IconStarOutline
      IconHeart
      IconFlag
      IconFlagOutline
      IconLock
      IconUnlock
      IconBell
      IconPin
      IconBookmark
      IconLink
      IconAttachment
      IconTag
      IconLightning
      IconFire
      IconBug
      IconRocket
      IconKey
      IconWrench
      # Communication
      IconMail
      IconPhone
      IconChat
      IconUser
      IconUsers
      # Time
      IconClock
      IconCalendar
      IconHourglass
      # Media transport
      IconPlay
      IconPause
      IconStop
      IconRecord
      IconNextTrack
      IconPrevTrack
      IconEject
      IconVolume
      IconMute
      IconMusic
      # Navigation / system
      IconHome
      IconRefresh
      IconDownload
      IconUpload
      IconExternalLink
      IconExit
      IconPower
      IconGlobe
      IconTerminal
      IconCloud
      IconSun
      IconMoon
      IconEye
      IconCamera
      IconImage
      IconChart
      IconGraphUp
      IconGraphDown
      # UI affordances
      IconMenu     # hamburger
      IconEllipsis # more, horizontal
      IconMoreVertical
      IconAdd
      IconRemove
      IconMaximize
      IconMinimize
      # Elemental shapes (handy as custom markers/bullets)
      IconBullet
      IconDiamond
      IconCircle
      IconCircleFilled
      IconSquare
      IconSquareFilled
      # Keyboard keys (help bars, shortcut hints)
      IconEnter
      IconTabKey
      IconBackspace
      IconEscape
      IconShift
      IconCapsLock
      IconControl
      IconAlt
      IconCommand
      IconSpaceKey
      # Currency / typography
      IconDollar
      IconEuro
      IconPound
      IconYen
      IconCent
      IconCopyright
      IconRegistered
      IconTrademark
      IconSection
      IconParagraph
      IconDegree
      IconPlusMinus
      IconInfinity
      IconMicro
      # Card suits / classic CP437 marks
      IconSpade
      IconClub
      IconDiamondSuit
      IconSmiley
      IconSmileyFilled
      IconMale
      IconFemale
      # Weather
      IconRain
      IconSnow
      IconUmbrella
      IconThermometer
      # Tech / status
      IconBan
      IconShield
      IconThumbsUp
      IconThumbsDown
      IconTrophy
      IconGift
      IconBattery
      IconPlug
      IconWifi
      IconLocation
      IconCompass
      IconLightbulb
      IconPuzzle
      IconDatabase
      IconPackage
      IconPalette
      IconBrush
      # Mail / transfer extras
      IconInbox
      IconOutbox
      IconSend
      # Media extras
      IconShuffle
      IconRepeat
      IconFastForward
      IconRewind
      # Warning / hazard / safety marks (the caution triangle and friends)
      IconWarningSign # the "caution" sign — triangle with an exclamation
      IconRadioactive
      IconBiohazard
      IconNoEntry
      IconExclamation
      IconExclamationDouble
      IconQuestionMark
      # Geometric triangles (outline + filled, four directions)
      IconTriangleUp
      IconTriangleDown
      IconTriangleLeft
      IconTriangleRight
      IconTriangleUpFilled
      IconTriangleDownFilled
      # Symbols / emblems
      IconRecycle
      IconSparkles
      IconYinYang
      IconPeace
      IconAtom
      IconAnchor
      IconScales
      IconSwords
      IconHammer
      IconSnowman
      IconComet
      IconDroplet
      IconRainbow
      # Time extras
      IconAlarm
      IconStopwatch
      IconWatch
      IconHourglassFlowing
      # Diagonal / bidirectional arrows (the cardinals live in Arrow* above)
      IconArrowUpDown
      IconArrowLeftRight
      IconArrowUpLeft
      IconArrowUpRight
      IconArrowDownLeft
      IconArrowDownRight
      # Heavy / double-line directional arrows
      IconArrowDoubleUp
      IconArrowDoubleDown
      IconArrowDoubleLeft
      IconArrowDoubleRight
      IconArrowDoubleVertical
      IconArrowDoubleHorizontal
      # Hooked (return / branch) arrows
      IconArrowHookLeft
      IconArrowHookRight
      # Proportion / fill-level marks. Harvey-ball circles (empty →
      # quarter → half → three-quarter → full) for showing a percentage
      # in one cell; the endpoints reuse IconCircle / IconCircleFilled.
      IconCircleQuarter
      IconCircleHalf
      IconCircleThreeQuarter
      # Shade / density blocks (light → medium → dark → full), the other
      # single-cell proportion ramp — matches the ScaleHorizontal sequence.
      IconShadeLight
      IconShadeMedium
      IconShadeDark
      IconBlockFull
      # Currency extras
      IconBitcoin
      IconRupee
      IconWon

      # -- Border families -----------------------------------------------------
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
      BorderRoundedTL
      BorderRoundedTR
      BorderRoundedBL
      BorderRoundedBR
      BorderRoundedH
      BorderRoundedV

      # End caps for a border whose opposite pair of edges did not fit the box:
      # a one-row widget keeps its left/right edges but has no top/bottom to
      # close them, and vice versa. The line-run glyphs (`│`/`─`) belong to a
      # family that implies corners, so two of them alone read as a broken
      # frame; these sit flush against the outer cell edge instead and read as
      # the wall of a trough, which is exactly what survives. See
      # `Border#glyph_octet`.
      BorderCapLeft
      BorderCapRight
      BorderCapTop
      BorderCapBottom

      # Sub-cell corner pieces for the block borders and thin shadows, picked
      # by the spill-minimizing `Glyphs.corner_fit` chooser (gaps beat any
      # large spill, tight covers beat loose ones).
      #
      # Miters: the small ink square hugging the named *cell* corner — an
      # `Inner` border's corner joint. `extended` holds the single sextant
      # (half a cell wide, a third tall); `unicode` the quadrant.
      BorderMiterTL
      BorderMiterTR
      BorderMiterBL
      BorderMiterBR

      # Thin-armed elbows: the `extended`-tier sextant elbows (top/bottom arm
      # a third of the cell, side arm half) — an `Outer` border's corner when
      # its runs are thinner than the quadrant elbow's arms; `unicode` falls
      # back to the three-quadrant block.
      BorderThinElbowTL
      BorderThinElbowTR
      BorderThinElbowBL
      BorderThinElbowBR

      # Thin-shadow corner grounds (`extended`-tier sextant complements whose
      # one empty sextant is the cell corner hugging the widget). Named by
      # the shadow ring corner they serve.
      ShadowCornerTL
      ShadowCornerTR
      ShadowCornerBL
      ShadowCornerBR

      # Octant corner pieces (Unicode 16 Symbols for Legacy Computing
      # Supplement, U+1CD00…): quarter-height corner arms, making the
      # half-width × quarter-height corner geometries pixel-exact where the
      # sextant pieces approximate with thirds. Used only when a screen's
      # `glyph_octants?` is on (identity/version-gated — see
      # `Glyphs.detected_octants`); everything else falls back to the sextant
      # renditions below. Elbows named by the two hugged edges (`Outer`
      # corners), miters by the cell corner the single octant hugs (`Inner`
      # corners, diagonal-mapped), shadow grounds by the ring corner served.
      BorderOctantElbowTL
      BorderOctantElbowTR
      BorderOctantElbowBL
      BorderOctantElbowBR
      BorderOctantMiterTL
      BorderOctantMiterTR
      BorderOctantMiterBL
      BorderOctantMiterBR
      ShadowOctantCornerTL
      ShadowOctantCornerTR
      ShadowOctantCornerBL
      ShadowOctantCornerBR

      # Third-height horizontal runs/strips (`extended`-tier sextant rows).
      # The sextant corner pieces' horizontal arms are a third of the cell
      # tall, while the eighth ramps step in quarters around them — so a
      # 2/8-thick run beside a sextant corner would leave a 1/24-cell step
      # at every joint. When the corner chooser lands on sextant pieces at
      # that step, the runs and shadow strips promote to these matching
      # third-blocks instead: flush joints beat nominal exactness.
      BorderThirdUpper  # ink in the top third (SEXTANT-12)
      BorderThirdLower  # ink in the bottom third (SEXTANT-56)
      ShadowThirdTop    # ground upper two-thirds: shadow strip in the bottom third
      ShadowThirdBottom # ground lower two-thirds: shadow strip in the top third

      # Whether this is a *cell* role — one that fills exactly one grid cell
      # by construction (scrollbar/slider parts, rules, junctions, the cursor
      # bar/block, border positions), so grid math never has to measure it. A
      # CSS `glyph` landing on a cell role must be exactly one column wide;
      # anything else (including `none`) falls back to the registry (see
      # `Widget#glyph`). Everything else is a *run* role: part of an inline
      # text run, measured, where `none` legitimately contributes zero cells.
      def cell? : Bool
        case self
        when .scroll_thumb?, .scroll_trough?,
             .arrow_up?, .arrow_down?, .arrow_left?, .arrow_right?,
             .slider_handle?, .slider_track?, .slider_tick?,
             .line_horizontal?, .line_vertical?,
             .junction_cross?, .junction_tee_left?, .junction_tee_right?,
             .junction_tee_top?, .junction_tee_bottom?,
             .cursor_bar?, .cursor_block?
          true
        else
          # The border families close the enum; keep them last when adding roles.
          self >= Role::BorderLineTL
        end
      end
    end

    # Built-in defaults. The `unicode` column is the toolkit's standard
    # rendition (what the default tier draws); the `ascii` column is the
    # honest 7-bit rendition; `extended` holds opt-in upgrades only.
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
      set_in t, Role::ProgressFill, Entry.new(' ')
      set_in t, Role::BigTextPixel, Entry.new(' ')

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
      set_in t, Role::CursorBlock, Entry.new('#', '█')

      set_in t, Role::IconInfo, Entry.new('i', 'ℹ')
      set_in t, Role::IconWarning, Entry.new('!', '⚠')
      set_in t, Role::IconCritical, Entry.new('x', '✖')
      set_in t, Role::IconQuestion, Entry.new('?')

      set_in t, Role::DragHandle, Entry.new('#', '⠿')
      set_in t, Role::LegendSwatch, Entry.new('#', '■')
      set_in t, Role::MapMarker, Entry.new('*', '●')

      # Icon palette. `ascii` column: a symbol when a natural one exists, else
      # a mnemonic letter (the classic ASCII-UI convention). `unicode` column:
      # single-width glyphs that the common monospace fonts cover. `extended`:
      # modern-font glyphs, incl. double-width emoji (these roles are measured
      # inline, never cell-fills).
      set_in t, Role::IconFileNew, Entry.new('+', nil, '📄')
      set_in t, Role::IconFolder, Entry.new('/', nil, '📁')
      set_in t, Role::IconFolderOpen, Entry.new('/', nil, '📂')
      set_in t, Role::IconSave, Entry.new('s', nil, '💾')
      set_in t, Role::IconPrint, Entry.new('p', nil, '⎙')
      set_in t, Role::IconTrash, Entry.new('x', nil, '🗑')

      set_in t, Role::IconCut, Entry.new('x', nil, '✂')
      set_in t, Role::IconCopy, Entry.new('c', nil, '⧉')
      set_in t, Role::IconPaste, Entry.new('v', nil, '📋')
      set_in t, Role::IconUndo, Entry.new('<', '←', '↶')
      set_in t, Role::IconRedo, Entry.new('>', '→', '↷')
      set_in t, Role::IconSearch, Entry.new('/', nil, '🔍')
      set_in t, Role::IconEdit, Entry.new('e', '✎', '✏')
      set_in t, Role::IconSettings, Entry.new('*', '⚙')
      set_in t, Role::IconFilter, Entry.new('Y', '▽')

      set_in t, Role::IconCheck, Entry.new('v', '✓', '✔')
      set_in t, Role::IconCross, Entry.new('x', '✗', '✘')
      set_in t, Role::IconStar, Entry.new('*', '★')
      set_in t, Role::IconStarOutline, Entry.new('*', '☆')
      set_in t, Role::IconHeart, Entry.new('*', '♥')
      set_in t, Role::IconFlag, Entry.new('>', '⚑')
      set_in t, Role::IconFlagOutline, Entry.new('>', '⚐')
      set_in t, Role::IconLock, Entry.new('L', nil, '🔒')
      set_in t, Role::IconUnlock, Entry.new('U', nil, '🔓')
      set_in t, Role::IconBell, Entry.new('!', nil, '🔔')
      set_in t, Role::IconPin, Entry.new('!', nil, '📌')
      set_in t, Role::IconBookmark, Entry.new('#', nil, '🔖')
      set_in t, Role::IconLink, Entry.new('&', nil, '🔗')
      set_in t, Role::IconAttachment, Entry.new('@', nil, '📎')
      set_in t, Role::IconTag, Entry.new('#', nil, '🏷')
      set_in t, Role::IconLightning, Entry.new('!', '↯', '⚡')
      set_in t, Role::IconFire, Entry.new('~', nil, '🔥')
      set_in t, Role::IconBug, Entry.new('b', nil, '🐛')
      set_in t, Role::IconRocket, Entry.new('^', nil, '🚀')
      set_in t, Role::IconKey, Entry.new('k', nil, '🔑')
      set_in t, Role::IconWrench, Entry.new('t', nil, '🔧')

      set_in t, Role::IconMail, Entry.new('@', '✉', '📧')
      set_in t, Role::IconPhone, Entry.new('#', '☎', '📞')
      set_in t, Role::IconChat, Entry.new('"', nil, '💬')
      set_in t, Role::IconUser, Entry.new('@', nil, '👤')
      set_in t, Role::IconUsers, Entry.new('%', nil, '👥')

      set_in t, Role::IconClock, Entry.new('t', nil, '🕐')
      set_in t, Role::IconCalendar, Entry.new('#', nil, '📅')
      set_in t, Role::IconHourglass, Entry.new('z', nil, '⌛')

      set_in t, Role::IconPlay, Entry.new('>', '►')
      set_in t, Role::IconPause, Entry.new('|', '‖', '⏸')
      set_in t, Role::IconStop, Entry.new('#', '■', '⏹')
      set_in t, Role::IconRecord, Entry.new('*', '●', '⏺')
      set_in t, Role::IconNextTrack, Entry.new('>', '»', '⏭')
      set_in t, Role::IconPrevTrack, Entry.new('<', '«', '⏮')
      set_in t, Role::IconEject, Entry.new('^', nil, '⏏')
      set_in t, Role::IconVolume, Entry.new('%', nil, '🔊')
      set_in t, Role::IconMute, Entry.new('x', nil, '🔇')
      set_in t, Role::IconMusic, Entry.new('n', '♪', '🎵')

      set_in t, Role::IconHome, Entry.new('~', '⌂', '🏠')
      set_in t, Role::IconRefresh, Entry.new('r', '↻', '🔄')
      set_in t, Role::IconDownload, Entry.new('v', '↓', '⇓')
      set_in t, Role::IconUpload, Entry.new('^', '↑', '⇑')
      set_in t, Role::IconExternalLink, Entry.new('>', '↗')
      set_in t, Role::IconExit, Entry.new('q', nil, '🚪')
      set_in t, Role::IconPower, Entry.new('o', nil, '⏻')
      set_in t, Role::IconGlobe, Entry.new('O', nil, '🌐')
      set_in t, Role::IconTerminal, Entry.new('$', nil, '💻')
      set_in t, Role::IconCloud, Entry.new('~', '☁')
      set_in t, Role::IconSun, Entry.new('*', '☼', '☀')
      set_in t, Role::IconMoon, Entry.new('(', '☾', '🌙')
      set_in t, Role::IconEye, Entry.new('o', nil, '👁')
      set_in t, Role::IconCamera, Entry.new('o', nil, '📷')
      set_in t, Role::IconImage, Entry.new('#', nil, '🖼')
      set_in t, Role::IconChart, Entry.new('#', nil, '📊')
      set_in t, Role::IconGraphUp, Entry.new('/', nil, '📈')
      set_in t, Role::IconGraphDown, Entry.new('\\', nil, '📉')

      set_in t, Role::IconMenu, Entry.new('=', '≡', '☰')
      set_in t, Role::IconEllipsis, Entry.new('.', '…', '⋯')
      set_in t, Role::IconMoreVertical, Entry.new(':', '⋮')
      set_in t, Role::IconAdd, Entry.new('+')
      set_in t, Role::IconRemove, Entry.new('-')
      set_in t, Role::IconMaximize, Entry.new('^', '□', '🗖')
      set_in t, Role::IconMinimize, Entry.new('_', '▁', '🗕')

      set_in t, Role::IconBullet, Entry.new('*', '•')
      set_in t, Role::IconDiamond, Entry.new('*', '◆')
      set_in t, Role::IconCircle, Entry.new('o', '○')
      set_in t, Role::IconCircleFilled, Entry.new('*', '●')
      set_in t, Role::IconSquare, Entry.new('#', '□')
      set_in t, Role::IconSquareFilled, Entry.new('#', '■')

      set_in t, Role::IconEnter, Entry.new('<', '↵', '⏎')
      set_in t, Role::IconTabKey, Entry.new('>', nil, '⇥')
      set_in t, Role::IconBackspace, Entry.new('<', nil, '⌫')
      set_in t, Role::IconEscape, Entry.new('E', nil, '⎋')
      set_in t, Role::IconShift, Entry.new('^', nil, '⇧')
      set_in t, Role::IconCapsLock, Entry.new('^', nil, '⇪')
      set_in t, Role::IconControl, Entry.new('^', nil, '⌃')
      set_in t, Role::IconAlt, Entry.new('A', nil, '⌥')
      set_in t, Role::IconCommand, Entry.new('#', nil, '⌘')
      set_in t, Role::IconSpaceKey, Entry.new('_', nil, '␣')

      set_in t, Role::IconDollar, Entry.new('$')
      set_in t, Role::IconEuro, Entry.new('E', '€')
      set_in t, Role::IconPound, Entry.new('L', '£')
      set_in t, Role::IconYen, Entry.new('Y', '¥')
      set_in t, Role::IconCent, Entry.new('c', '¢')
      set_in t, Role::IconCopyright, Entry.new('c', '©')
      set_in t, Role::IconRegistered, Entry.new('r', '®')
      set_in t, Role::IconTrademark, Entry.new('t', '™')
      set_in t, Role::IconSection, Entry.new('S', '§')
      set_in t, Role::IconParagraph, Entry.new('P', '¶')
      set_in t, Role::IconDegree, Entry.new('o', '°')
      set_in t, Role::IconPlusMinus, Entry.new('+', '±')
      set_in t, Role::IconInfinity, Entry.new('8', '∞')
      set_in t, Role::IconMicro, Entry.new('u', 'µ')

      set_in t, Role::IconSpade, Entry.new('S', '♠')
      set_in t, Role::IconClub, Entry.new('C', '♣')
      set_in t, Role::IconDiamondSuit, Entry.new('D', '♦')
      set_in t, Role::IconSmiley, Entry.new(':', '☺')
      set_in t, Role::IconSmileyFilled, Entry.new(':', '☻')
      set_in t, Role::IconMale, Entry.new('M', '♂')
      set_in t, Role::IconFemale, Entry.new('F', '♀')

      set_in t, Role::IconRain, Entry.new('/', nil, '🌧')
      set_in t, Role::IconSnow, Entry.new('*', '❄')
      set_in t, Role::IconUmbrella, Entry.new('U', '☂')
      set_in t, Role::IconThermometer, Entry.new('|', nil, '🌡')

      set_in t, Role::IconBan, Entry.new('0', '∅', '🚫')
      set_in t, Role::IconShield, Entry.new('O', nil, '🛡')
      set_in t, Role::IconThumbsUp, Entry.new('+', nil, '👍')
      set_in t, Role::IconThumbsDown, Entry.new('-', nil, '👎')
      set_in t, Role::IconTrophy, Entry.new('Y', nil, '🏆')
      set_in t, Role::IconGift, Entry.new('%', nil, '🎁')
      set_in t, Role::IconBattery, Entry.new('[', nil, '🔋')
      set_in t, Role::IconPlug, Entry.new('-', nil, '🔌')
      set_in t, Role::IconWifi, Entry.new('(', nil, '📶')
      set_in t, Role::IconLocation, Entry.new('o', nil, '📍')
      set_in t, Role::IconCompass, Entry.new('+', nil, '🧭')
      set_in t, Role::IconLightbulb, Entry.new('!', nil, '💡')
      set_in t, Role::IconPuzzle, Entry.new('+', nil, '🧩')
      set_in t, Role::IconDatabase, Entry.new('#', nil, '🗄')
      set_in t, Role::IconPackage, Entry.new('=', nil, '📦')
      set_in t, Role::IconPalette, Entry.new('P', nil, '🎨')
      set_in t, Role::IconBrush, Entry.new('/', nil, '🖌')

      set_in t, Role::IconInbox, Entry.new('[', nil, '📥')
      set_in t, Role::IconOutbox, Entry.new(']', nil, '📤')
      set_in t, Role::IconSend, Entry.new('>', nil, '➤')

      set_in t, Role::IconShuffle, Entry.new('x', nil, '🔀')
      set_in t, Role::IconRepeat, Entry.new('o', nil, '🔁')
      set_in t, Role::IconFastForward, Entry.new('>', '»', '⏩')
      set_in t, Role::IconRewind, Entry.new('<', '«', '⏪')

      # Warning / hazard / safety. The `unicode` column holds the classic
      # single-width text symbol; `extended` upgrades to its emoji-presentation
      # form — the base codepoint + VS16 (U+FE0F), which only the String column
      # can carry. Cell-role callers reject-to-fallback to the single symbol.
      set_in t, Role::IconWarningSign, Entry.new('!', '⚠', "⚠️")
      set_in t, Role::IconRadioactive, Entry.new('!', '☢', "☢️")
      set_in t, Role::IconBiohazard, Entry.new('!', '☣', "☣️")
      set_in t, Role::IconNoEntry, Entry.new('O', nil, '⛔')
      set_in t, Role::IconExclamation, Entry.new('!', nil, '❗')
      set_in t, Role::IconExclamationDouble, Entry.new('!', '‼')
      set_in t, Role::IconQuestionMark, Entry.new('?', nil, '❓')

      set_in t, Role::IconTriangleUp, Entry.new('^', '△')
      set_in t, Role::IconTriangleDown, Entry.new('v', '▽')
      set_in t, Role::IconTriangleLeft, Entry.new('<', '◁')
      set_in t, Role::IconTriangleRight, Entry.new('>', '▷')
      set_in t, Role::IconTriangleUpFilled, Entry.new('^', '▲')
      set_in t, Role::IconTriangleDownFilled, Entry.new('v', '▼')

      set_in t, Role::IconRecycle, Entry.new('R', '♻')
      set_in t, Role::IconSparkles, Entry.new('*', nil, '✨')
      set_in t, Role::IconYinYang, Entry.new('o', '☯')
      set_in t, Role::IconPeace, Entry.new('O', '☮')
      set_in t, Role::IconAtom, Entry.new('*', '⚛')
      set_in t, Role::IconAnchor, Entry.new('J', nil, "⚓️")
      set_in t, Role::IconScales, Entry.new('T', '⚖', "⚖️")
      set_in t, Role::IconSwords, Entry.new('X', '⚔', "⚔️")
      set_in t, Role::IconHammer, Entry.new('h', '⚒', '🔨')
      set_in t, Role::IconSnowman, Entry.new('S', '☃')
      set_in t, Role::IconComet, Entry.new('*', '☄')
      set_in t, Role::IconDroplet, Entry.new('o', nil, '💧')
      set_in t, Role::IconRainbow, Entry.new('-', nil, '🌈')

      set_in t, Role::IconAlarm, Entry.new('!', nil, '⏰')
      set_in t, Role::IconStopwatch, Entry.new('t', '⏱')
      set_in t, Role::IconWatch, Entry.new('o', nil, '⌚')
      set_in t, Role::IconHourglassFlowing, Entry.new('z', nil, '⏳')

      set_in t, Role::IconArrowUpDown, Entry.new('|', '↕')
      set_in t, Role::IconArrowLeftRight, Entry.new('-', '↔')
      set_in t, Role::IconArrowUpLeft, Entry.new('\\', '↖')
      set_in t, Role::IconArrowUpRight, Entry.new('/', '↗')
      set_in t, Role::IconArrowDownLeft, Entry.new('/', '↙')
      set_in t, Role::IconArrowDownRight, Entry.new('\\', '↘')

      set_in t, Role::IconArrowDoubleUp, Entry.new('^', '⇑')
      set_in t, Role::IconArrowDoubleDown, Entry.new('v', '⇓')
      set_in t, Role::IconArrowDoubleLeft, Entry.new('<', '⇐')
      set_in t, Role::IconArrowDoubleRight, Entry.new('>', '⇒')
      set_in t, Role::IconArrowDoubleVertical, Entry.new('|', '⇕')
      set_in t, Role::IconArrowDoubleHorizontal, Entry.new('-', '⇔')
      set_in t, Role::IconArrowHookLeft, Entry.new('<', '↩')
      set_in t, Role::IconArrowHookRight, Entry.new('>', '↪')

      # Harvey-ball fill states — a one-cell percentage indicator.
      set_in t, Role::IconCircleQuarter, Entry.new('.', '◔')
      set_in t, Role::IconCircleHalf, Entry.new('C', '◐')
      set_in t, Role::IconCircleThreeQuarter, Entry.new('o', '◕')
      # Shade / density ramp.
      set_in t, Role::IconShadeLight, Entry.new('.', '░')
      set_in t, Role::IconShadeMedium, Entry.new(':', '▒')
      set_in t, Role::IconShadeDark, Entry.new('%', '▓')
      set_in t, Role::IconBlockFull, Entry.new('#', '█')

      set_in t, Role::IconBitcoin, Entry.new('B', '₿')
      set_in t, Role::IconRupee, Entry.new('R', '₹')
      set_in t, Role::IconWon, Entry.new('W', '₩')

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
      # Rounded (arc) corners with the light straight runs — the light box
      # family's arc variants (U+256D..U+2570), covered by effectively every
      # contemporary monospace font, so they sit in the unicode column.
      set_in t, Role::BorderRoundedTL, Entry.new('+', '╭')
      set_in t, Role::BorderRoundedTR, Entry.new('+', '╮')
      set_in t, Role::BorderRoundedBL, Entry.new('+', '╰')
      set_in t, Role::BorderRoundedBR, Entry.new('+', '╯')
      set_in t, Role::BorderRoundedH, Entry.new('-', '─')
      set_in t, Role::BorderRoundedV, Entry.new('|', '│')

      # Sub-cell corner pieces (see the `Role` docs and `Glyphs.corner_fit`).
      # The sextants (Symbols for Legacy Computing) sit in the `extended`
      # column; `unicode` falls back to the quadrant renditions.
      set_in t, Role::BorderMiterTL, Entry.new('+', '▘', '\u{1FB00}')     # SEXTANT-1
      set_in t, Role::BorderMiterTR, Entry.new('+', '▝', '\u{1FB01}')     # SEXTANT-2
      set_in t, Role::BorderMiterBL, Entry.new('+', '▖', '\u{1FB0F}')     # SEXTANT-5
      set_in t, Role::BorderMiterBR, Entry.new('+', '▗', '\u{1FB1E}')     # SEXTANT-6
      set_in t, Role::BorderThinElbowTL, Entry.new('+', '▛', '\u{1FB15}') # SEXTANT-1235
      set_in t, Role::BorderThinElbowTR, Entry.new('+', '▜', '\u{1FB28}') # SEXTANT-1246
      set_in t, Role::BorderThinElbowBL, Entry.new('+', '▙', '\u{1FB32}') # SEXTANT-1356
      set_in t, Role::BorderThinElbowBR, Entry.new('+', '▟', '\u{1FB37}') # SEXTANT-2456
      # Shadow grounds: `ascii` space = shadow tone across the whole cell;
      # the chooser never picks these roles below `extended` anyway.
      set_in t, Role::ShadowCornerTL, Entry.new(' ', nil, '\u{1FB1D}') # shadow in the LR sextant
      set_in t, Role::ShadowCornerTR, Entry.new(' ', nil, '\u{1FB2C}') # shadow in the LL sextant
      set_in t, Role::ShadowCornerBL, Entry.new(' ', nil, '\u{1FB3A}') # shadow in the UR sextant
      set_in t, Role::ShadowCornerBR, Entry.new(' ', nil, '\u{1FB3B}') # shadow in the UL sextant
      # Third-height runs/strips, promoted to when sextant corners are in
      # play (their horizontal arms are thirds).
      set_in t, Role::BorderThirdUpper, Entry.new('-', nil, '\u{1FB02}')  # SEXTANT-12
      set_in t, Role::BorderThirdLower, Entry.new('-', nil, '\u{1FB2D}')  # SEXTANT-56
      set_in t, Role::ShadowThirdTop, Entry.new(' ', nil, '\u{1FB0E}')    # SEXTANT-1234
      set_in t, Role::ShadowThirdBottom, Entry.new(' ', nil, '\u{1FB39}') # SEXTANT-3456
      # Octant corner pieces (opt-in, see the Role docs). Codepoints verified
      # against GNU Unifont's bitmaps; octant cells number 1-8, 2 columns ×
      # 4 rows, row-major.
      set_in t, Role::BorderOctantElbowTL, Entry.new('+', nil, '\u{1CD4A}')  # OCTANT-1235-7
      set_in t, Role::BorderOctantElbowTR, Entry.new('+', nil, '\u{1CD98}')  # OCTANT-1246-8
      set_in t, Role::BorderOctantElbowBL, Entry.new('+', nil, '\u{1CDC0}')  # OCTANT-1357-8
      set_in t, Role::BorderOctantElbowBR, Entry.new('+', nil, '\u{1CDD5}')  # OCTANT-2467-8
      set_in t, Role::BorderOctantMiterTL, Entry.new('+', nil, '\u{1CEA8}')  # OCTANT-1
      set_in t, Role::BorderOctantMiterTR, Entry.new('+', nil, '\u{1CEAB}')  # OCTANT-2
      set_in t, Role::BorderOctantMiterBL, Entry.new('+', nil, '\u{1CEA3}')  # OCTANT-7
      set_in t, Role::BorderOctantMiterBR, Entry.new('+', nil, '\u{1CEA0}')  # OCTANT-8
      set_in t, Role::ShadowOctantCornerTL, Entry.new(' ', nil, '\u{1CD70}') # all but octant 8
      set_in t, Role::ShadowOctantCornerTR, Entry.new(' ', nil, '\u{1CDAB}') # all but octant 7
      set_in t, Role::ShadowOctantCornerBL, Entry.new(' ', nil, '\u{1CDE4}') # all but octant 2
      set_in t, Role::ShadowOctantCornerBR, Entry.new(' ', nil, '\u{1CDE5}') # all but octant 1

      # Caps: a full block, so the glyph fills exactly the cell it costs. A
      # thinner rim (`▏`) or a line run (`│`) leaves the rest of its cell showing
      # the border background — which is the widget's own background — putting a
      # visible notch of backdrop between the edge and the content beside it.
      # A block also implies no corner to look for, which is why the run glyphs
      # can't serve here.
      set_in t, Role::BorderCapLeft, Entry.new('#', '█')
      set_in t, Role::BorderCapRight, Entry.new('#', '█')
      set_in t, Role::BorderCapTop, Entry.new('#', '█')
      set_in t, Role::BorderCapBottom, Entry.new('#', '█')
      t
    end

    # (Array#[]= at const-build time; a def keeps `DEFAULTS` readable.)
    private def self.set_in(table : Array(Entry), role : Role, entry : Entry) : Nil
      table[role.value] = entry
    end

    # The live table. Starts as the defaults; `Glyphs.set` retunes it.
    @@table : Array(Entry) = DEFAULTS.dup

    # Bumped by every `Glyphs.set` so cached derivations (composed markers and
    # the like) can notice a retheme. Registry changes are an app-setup-time
    # event; running screens should be asked to re-render after.
    class_getter generation : UInt64 = 0_u64

    # The character for *role* at *tier* (falling down tiers within the
    # entry). Hot-path safe: an array read plus at most two nil checks.
    @[AlwaysInline]
    def self.[](role : Role, tier : Tier) : Char
      @@table.unsafe_fetch(role.value).for(tier)
    end

    # The full grapheme for *role* at *tier* (String) — the *run*-role
    # accessor. A multi-codepoint upgrade (`⚠️`, a flag, a combining sequence)
    # survives here where `#[]` would reject-to-fallback to a lone codepoint.
    @[AlwaysInline]
    def self.str(role : Role, tier : Tier) : String
      @@table.unsafe_fetch(role.value).str(tier)
    end

    # `Glyphs[role, tier].to_s`, allocation-free: the precomputed String form
    # of the cell-role fast lane (`#[]`'s reject-to-fallback `Char`), for
    # callers that need a `String` — e.g. a CSS-override site whose override
    # slot is `String?` — without boxing a fresh String per call.
    @[AlwaysInline]
    def self.cell_str(role : Role, tier : Tier) : String
      @@table.unsafe_fetch(role.value).cell_str(tier)
    end

    # The single Char for *role* at *tier* when the glyph is one codepoint,
    # else `nil` (a multi-codepoint cluster — render it with `#str`). The fast
    # lane for callers that special-case the common single-character glyph.
    @[AlwaysInline]
    def self.char?(role : Role, tier : Tier) : Char?
      @@table.unsafe_fetch(role.value).char?(tier)
    end

    # The full entry for *role*.
    def self.entry(role : Role) : Entry
      @@table.unsafe_fetch(role.value)
    end

    # Overrides *role*'s characters. Omitted tiers keep their current value;
    # pass `unset: true` to clear the `unicode`/`extended` overrides back to
    # tier fall-down instead.
    def self.set(role : Role, ascii : Char? = nil, unicode : Char | String? = nil,
                 extended : Char | String? = nil, unset : Bool = false) : Nil
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
      SEQ_DEFAULTS.each_with_index { |e, i| @@seq_table[i] = e }
      @@generation += 1
    end

    # -- Sequence (multi-char) roles ------------------------------------------
    #
    # Some chrome isn't a single glyph but an ordered *sequence* of steps: a
    # spinner's frames, a dial's pointer ring, the sub-cell fill ramps. These
    # live in their own table with the same tier fall-down; values are
    # `Array(Char)` (one char per step). CSS spelling: the `glyphs` property
    # (`Loading { glyphs: "◐◓◑◒"; }` — the string's characters are the steps).

    # Every sequence role the toolkit draws.
    enum SeqRole
      SpinnerFrames   # `Loading`'s cycling frames
      DialPointers    # `Dial`'s compass ring, clockwise from north
      ScaleHorizontal # sub-cell fill ramp, empty → full, filling rightward
      ScaleVertical   # sub-cell fill ramp, empty → full, filling upward

      # -- Block-ink ramps and corners ---------------------------------------
      # The sub-cell "edge-anchored ink" vocabulary shared by the block border
      # families (`BorderType::Outer`/`Inner`) and the thin (`ratio`) shadows:
      # step *n* (1-based; array index `n - 1`) is a block glyph inking `n/8`
      # of the cell from the named edge. A consumer picks the anchor edge for
      # its semantics — border ink is the glyph's *foreground* over a ground
      # background, a thin shadow inverts that and draws the *ground* as the
      # glyph so the cell background reads as the shadow (see
      # `Window#blend_region`) — while the steps come from these tables.
      #
      # Tier honesty: the lower/left ramps exist at every eighth in the
      # CP437/WGL4-era repertoire, but Unicode's Block Elements only provide
      # the upper/right blocks at 1/8, 4/8 and 8/8 — those two ramps hold the
      # nearest available step at the `unicode` tier and gain the exact
      # missing steps (Symbols for Legacy Computing, U+1FB82…/U+1FB87…) at
      # `extended`.
      BorderRampUpper # ink anchored at the top edge, growing down
      BorderRampLower # ink anchored at the bottom edge, growing up
      BorderRampLeft  # ink anchored at the left edge, growing right
      BorderRampRight # ink anchored at the right edge, growing left

      # Elbow corner cells, named by the *cell corner the ink hugs*: the
      # L-shape along the two named edges — an `Outer` border's corner joint
      # (and, at the quadrant step, a thin shadow's `:quadrant` corner
      # ground). Indexed by eighths like the ramps; exact glyphs exist only
      # at 1/8 (Legacy Computing L-pieces, `extended`), 4/8 (three-quadrant
      # blocks) and 8/8 (full block), so the tables bucket every step to the
      # nearest of those. The sub-cell corner pieces the `Glyphs.corner_fit`
      # chooser picks from (miters, thin-armed elbows, shadow grounds) are
      # separate `Role`s below.
      BorderElbowTL
      BorderElbowTR
      BorderElbowBL
      BorderElbowBR
    end

    # One sequence role's steps per tier: `ascii` is mandatory, higher tiers
    # optional (`nil` falls down a tier).
    record SeqEntry, ascii : Array(Char), unicode : Array(Char)? = nil, extended : Array(Char)? = nil do
      # The steps to use at *tier*, falling down to lower tiers when this
      # entry defines none for it.
      def for(tier : Tier) : Array(Char)
        case tier
        in .extended? then @extended || @unicode || @ascii
        in .unicode?  then @unicode || @ascii
        in .ascii?    then @ascii
        end
      end
    end

    # Built-in sequence defaults. As with `DEFAULTS`, each literal sits in
    # the column matching its repertoire: the spinner's `| / - \` in `ascii`
    # (7-bit), the dial arrows and eighth-block ramps in `unicode`;
    # `extended` holds opt-in upgrades (the braille spinner).
    SEQ_DEFAULTS = begin
      t = Array(SeqEntry).new(SeqRole.values.size) { SeqEntry.new([' ']) }
      t[SeqRole::SpinnerFrames.value] = SeqEntry.new(
        ['|', '/', '-', '\\'], nil,
        ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'])
      # ASCII compass: the four cardinals are honest; the diagonals reuse the
      # slashes (direction reads from context as the pointer sweeps).
      t[SeqRole::DialPointers.value] = SeqEntry.new(
        ['^', '/', '>', '\\', 'v', '/', '<', '\\'],
        ['↑', '↗', '→', '↘', '↓', '↙', '←', '↖'])
      # 9-step fill ramps (empty → full). The ASCII column is a density ramp —
      # 7-bit can't render partial fills, so darkness stands in for fill.
      t[SeqRole::ScaleHorizontal.value] = SeqEntry.new(
        " .:-=+*#@".chars, " ▏▎▍▌▋▊▉█".chars)
      t[SeqRole::ScaleVertical.value] = SeqEntry.new(
        " .:-=+*#@".chars, " ▁▂▃▄▅▆▇█".chars)
      # Block-ink ramps: step n = n/8 of the cell inked from the named edge.
      # 7-bit has no sub-cell ink, so the ascii columns collapse to the line
      # border's `- | +` look whatever the step. The upper/right ramps carry
      # the nearest Block Elements step at `unicode` (only 1/8, 4/8, 8/8
      # exist) and the exact Legacy Computing steps at `extended`; the
      # lower/left ramps are exact at `unicode` already.
      t[SeqRole::BorderRampUpper.value] = SeqEntry.new(
        Array.new(8, '-'),
        ['▔', '▔', '▀', '▀', '▀', '█', '█', '█'],
        ['▔', '\u{1FB82}', '\u{1FB83}', '▀', '\u{1FB84}', '\u{1FB85}', '\u{1FB86}', '█'])
      t[SeqRole::BorderRampLower.value] = SeqEntry.new(
        Array.new(8, '-'), "▁▂▃▄▅▆▇█".chars)
      t[SeqRole::BorderRampLeft.value] = SeqEntry.new(
        Array.new(8, '|'), "▏▎▍▌▋▊▉█".chars)
      t[SeqRole::BorderRampRight.value] = SeqEntry.new(
        Array.new(8, '|'),
        ['▕', '▕', '▐', '▐', '▐', '█', '█', '█'],
        ['▕', '\u{1FB87}', '\u{1FB88}', '▐', '\u{1FB89}', '\u{1FB8A}', '\u{1FB8B}', '█'])
      # Elbows (L-shape hugging the two named edges): the Legacy Computing
      # one-eighth L-pieces when thin, the three-quadrant blocks at middling
      # steps, the full block when either arm is nearly full.
      t[SeqRole::BorderElbowTL.value] = SeqEntry.new(
        Array.new(8, '+'),
        ['▛', '▛', '▛', '▛', '▛', '█', '█', '█'],
        ['\u{1FB7D}', '\u{1FB7D}', '▛', '▛', '▛', '█', '█', '█'])
      t[SeqRole::BorderElbowTR.value] = SeqEntry.new(
        Array.new(8, '+'),
        ['▜', '▜', '▜', '▜', '▜', '█', '█', '█'],
        ['\u{1FB7E}', '\u{1FB7E}', '▜', '▜', '▜', '█', '█', '█'])
      t[SeqRole::BorderElbowBL.value] = SeqEntry.new(
        Array.new(8, '+'),
        ['▙', '▙', '▙', '▙', '▙', '█', '█', '█'],
        ['\u{1FB7C}', '\u{1FB7C}', '▙', '▙', '▙', '█', '█', '█'])
      t[SeqRole::BorderElbowBR.value] = SeqEntry.new(
        Array.new(8, '+'),
        ['▟', '▟', '▟', '▟', '▟', '█', '█', '█'],
        ['\u{1FB7F}', '\u{1FB7F}', '▟', '▟', '▟', '█', '█', '█'])
      t
    end

    # The live sequence table; `Glyphs.set_chars` retunes it.
    @@seq_table : Array(SeqEntry) = SEQ_DEFAULTS.dup

    # The steps for sequence *role* at *tier* (falling down tiers within the
    # entry). Returns the stored array — callers must treat it as read-only.
    @[AlwaysInline]
    def self.chars(role : SeqRole, tier : Tier) : Array(Char)
      @@seq_table.unsafe_fetch(role.value).for(tier)
    end

    # The full sequence entry for *role*.
    def self.seq_entry(role : SeqRole) : SeqEntry
      @@seq_table.unsafe_fetch(role.value)
    end

    # Overrides sequence *role*'s steps. Omitted tiers keep their current
    # value; pass `unset: true` to clear the `unicode`/`extended` overrides
    # back to tier fall-down instead.
    def self.set_chars(role : SeqRole, ascii : Array(Char)? = nil, unicode : Array(Char)? = nil,
                       extended : Array(Char)? = nil, unset : Bool = false) : Nil
      e = @@seq_table[role.value]
      @@seq_table[role.value] = SeqEntry.new(
        ascii || e.ascii,
        unicode || (unset ? nil : e.unicode),
        extended || (unset ? nil : e.extended),
      )
      @@generation += 1
    end

    # -- Block-ink resolution --------------------------------------------------

    # Named block-ink `ratio` presets, shared by `Border#ratio=` and
    # `Shadow#ratio=`: the thickness spellings an author reaches for without
    # thinking in eighths. `:thin` is the finest expressible ink; `:half` a
    # half column; `:full` a whole column (for a shadow: the classic
    # full-cell band).
    # String-keyed so the CSS `border-ratio` keyword lookup shares it; the
    # `ratio=(Symbol)` setters stringify their argument.
    BLOCK_RATIOS = {
      "thin"    => 0.125,
      "quarter" => 0.25,
      "half"    => 0.5,
      "full"    => 1.0,
    }

    # Resolves a block-ink *ratio* — the desired ink thickness as a fraction
    # of the cell *width*, `Border#ratio`'s unit — into per-axis eighth steps
    # `{w8, v8}`: width-eighths for the vertical (left/right) runs, taken
    # directly, and height-eighths for the horizontal (top/bottom) runs,
    # divided by *aspect* (the terminal cell's measured height:width ratio,
    # `CSS::Length.cell_aspect_ratio`) so both axes come out equally thick
    # *on screen* rather than in cell fractions. Each clamps to a visible
    # 1..8.
    def self.block_eighths(ratio : Float64, aspect : Float64 = CSS::Length.cell_aspect_ratio) : {Int32, Int32}
      r = ratio.clamp(0.0, 1.0)
      w8 = (r * 8).round.to_i.clamp(1, 8)
      v8 = (r * 8 / aspect).round.to_i.clamp(1, 8)
      {w8, v8}
    end

    # -- Braille border pieces -------------------------------------------------

    # Base of the Braille Patterns block: `BRAILLE_BASE + mask` is the pattern
    # with exactly the dots of *mask* raised (the U+2800 dot-numbering bits:
    # dots 1..8 are bits 0..7).
    BRAILLE_BASE = 0x2800

    # Dot masks of a `BorderType::Braille` border's runs, 1-based by step like
    # the `BorderRamp*` tables: `BRAILLE_COLS_LEFT[n - 1]` raises the leftmost
    # *n* dot-columns (dots 1237, then all eight), `BRAILLE_ROWS_TOP[n - 1]`
    # the topmost *n* dot-rows (dots 14, 1245, ...), and so on. A braille cell
    # is 2 dot-columns x 4 dot-rows, so vertical runs step in halves and
    # horizontal runs in quarters; a corner cell is simply the union of its
    # two adjoining runs' masks.
    BRAILLE_COLS_LEFT   = [0x47, 0xFF]
    BRAILLE_COLS_RIGHT  = [0xB8, 0xFF]
    BRAILLE_ROWS_TOP    = [0x09, 0x1B, 0x3F, 0xFF]
    BRAILLE_ROWS_BOTTOM = [0xC0, 0xE4, 0xF6, 0xFF]

    # The braille pattern with the dots of *mask* raised.
    @[AlwaysInline]
    def self.braille(mask : Int32) : Char
      (BRAILLE_BASE + mask).chr
    end

    # Resolves a block-ink *ratio* into braille steps `{w2, v4}` — dot-columns
    # for the vertical (left/right) runs, dot-rows for the horizontal
    # (top/bottom) ones — the braille analog of `.block_eighths`: same
    # cell-width unit and aspect compensation, on the coarser 2 x 4 dot grid.
    # Each clamps to a visible 1-step minimum.
    def self.braille_steps(ratio : Float64, aspect : Float64 = CSS::Length.cell_aspect_ratio) : {Int32, Int32}
      r = ratio.clamp(0.0, 1.0)
      w2 = (r * 2).round.to_i.clamp(1, 2)
      v4 = (r * 4 / aspect).round.to_i.clamp(1, 4)
      {w2, v4}
    end

    # Picks the treatment of a sub-cell ring/silhouette corner whose ideal
    # ink is a rectangle *w8* (width-eighths) wide × *v8* (height-eighths)
    # tall tucked into a cell corner — an `Inner` border's corner joint, or a
    # thin shadow's corner (where the "ink" is the shadow tone and the glyph
    # paints its complement). No repertoire has that exact piece, so compare
    # the spill of every candidate that *covers* the rectangle — the
    # full-width horizontal strip (the run continued through the cell), the
    # quadrant miter (half × half), and at `extended` the sextant miter
    # (half × a third) — against simply leaving the cell empty, whose cost is
    # the gap area weighted double (a break in the line is more jarring than
    # the same area of spill, but a thin ring's sub-pixel-scale gap beats any
    # fat corner bead). Areas are compared in px²·3 of a nominal 8×16 cell,
    # keeping the sextant's 16/3 px height integral.
    #
    # Returns `:gap` (leave the corner cell untouched), `:strip` (continue
    # the horizontal run), `:octant`, `:sextant` or `:quadrant` (the miter
    # pieces). *octants* says the terminal renders the Unicode 16 octant
    # range (`Screen#glyph_octants?`).
    def self.corner_fit(w8 : Int32, v8 : Int32, tier : Tier, octants : Bool = false) : Symbol
      want3 = 6 * w8 * v8
      best = :gap
      cost = 2 * want3
      strip3 = 6 * (8 - w8) * v8
      best, cost = :strip, strip3 if strip3 < cost
      if w8 <= 4
        # The octant miter (half a cell × a quarter) is pixel-exact at the
        # aspect-compensated `:half` geometry and needs no stroke
        # re-quantization, so it outranks the sextant wherever available.
        if octants && tier.extended? && v8 <= 2 && (oct3 = 48 - want3) < cost
          best, cost = :octant, oct3
        end
        # The sextant miter serves v8 3 as well as 2: its consumer then
        # *demotes* the strokes to the matching third-blocks (5.33 px for a
        # nominal 6), so piece and stroke join flush — hence the clamp, a
        # nominally-negative spill just means "exact after demotion".
        if tier.extended? && v8 <= 3 && (sext3 = Math.max(64 - want3, 0)) < cost
          best, cost = :sextant, sext3
        end
        best = :quadrant if v8 <= 4 && 96 - want3 < cost
      end
      best
    end

    # Whether a live `Tput`'s emulator identity says the terminal renders the
    # Unicode 16 octant range (U+1CD00…), gating the pixel-exact octant
    # corner pieces. Like `detected_tier`, this is identity knowledge — the
    # range has no escape-sequence probe — and it's version-aware
    # (`Tput::Emulator::OCTANT_SUPPORT`; e.g. kitty ≥ 0.40). Consulted by
    # `Screen` alongside `detected_tier` while `screen.glyphs_octants` /
    # `Screen#glyph_octants=` haven't pinned a choice, on a real tty only.
    def self.detected_octants(tput : ::Tput) : Bool
      tput.features.unicode? && (tput.emulator?.try(&.legacy_computing_octant?) || false)
    end

    # Heuristic tier suggestion: `Extended` when the environment identifies a
    # terminal that ships with (or is overwhelmingly configured with) a
    # modern, well-covered font — kitty, WezTerm, Ghostty, iTerm2 — else
    # `Unicode`. The identity knowledge itself lives in tput
    # (`Tput::Emulator.modern_font_env?`), so this can't drift from the
    # emulator detection; the `Tput` overload below is the sharper form
    # `Screen` consults automatically.
    def self.detected_tier(env = ENV) : Tier
      ::Tput::Emulator.modern_font_env?(env) ? Tier::Extended : Tier::Unicode
    end

    # Tier suggestion from a live `Tput`'s feature/emulator detection:
    # `Extended` when the terminal both renders Unicode
    # (`Tput::Features#unicode?`) and is identified as one shipping a modern,
    # well-covered font (`Tput::Emulator#modern_font?` — kitty, WezTerm,
    # Ghostty, iTerm2); else `Unicode`. Sharper than the env overload: the
    # emulator identity is hardened by `Tput#probe!` (XTVERSION), which both
    # confirms an env-detected identity and revokes a wrong one. Consulted
    # automatically by `Screen` (at construction and after `Screen#probe!`)
    # while `screen.glyphs` / `Screen#glyph_tier=` haven't pinned a tier
    # explicitly, on a real tty only.
    def self.detected_tier(tput : ::Tput) : Tier
      if tput.features.unicode? && tput.emulator?.try(&.modern_font?)
        Tier::Extended
      else
        Tier::Unicode
      end
    end
  end
end
