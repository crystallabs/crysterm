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

      # -- Icon palette -----------------------------------------------------------
      # A curated vocabulary of common UI icons (toolbar actions, status marks,
      # media transport, navigation), pre-picked per tier so applications don't
      # browse Unicode tables themselves: `tool_bar.add "#{glyph(Glyphs::Role::IconSave)} Save"`.
      # Not consumed by any widget — pure palette. These are *run* roles
      # (inline text, measured — see GLYPHS.md §4), so the `extended` column
      # may hold double-width emoji; `ascii`/`unicode` stay single-width.

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
      BorderRoundedTL
      BorderRoundedTR
      BorderRoundedBL
      BorderRoundedBR
      BorderRoundedH
      BorderRoundedV

      # Whether this is a *cell* role — one that fills exactly one grid cell
      # by construction (scrollbar/slider parts, rules, junctions, the cursor
      # bar, border positions), so grid math never has to measure it. A CSS
      # `glyph` landing on a cell role must be exactly one column wide;
      # anything else (including `none`) falls back to the registry (see
      # `Widget#glyph`). Everything else is a *run* role: part of an inline
      # text run, measured, where `none` legitimately contributes zero cells
      # (GLYPHS.md §4).
      def cell? : Bool
        case self
        when .scroll_thumb?, .scroll_trough?,
             .arrow_up?, .arrow_down?, .arrow_left?, .arrow_right?,
             .slider_handle?, .slider_track?, .slider_tick?,
             .line_horizontal?, .line_vertical?,
             .junction_cross?, .junction_tee_left?, .junction_tee_right?,
             .junction_tee_top?, .junction_tee_bottom?,
             .cursor_bar?
          true
        else
          # The border families close the enum; keep them last when adding roles.
          self >= Role::BorderLineTL
        end
      end
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
      SEQ_DEFAULTS.each_with_index { |e, i| @@seq_table[i] = e }
      @@generation += 1
    end

    # -- Sequence (multi-char) roles — GLYPHS.md phase 4 ----------------------
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
    end

    # One sequence role's steps per tier: `ascii` is mandatory, higher tiers
    # optional (`nil` falls down a tier). Mirrors `Entry`.
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

    # Built-in sequence defaults. As with `DEFAULTS`, the column holding
    # today's literals keeps the default tier byte-identical with history:
    # the spinner's `| / - \` sits in `ascii` (it always was 7-bit), the
    # dial arrows and eighth-block ramps in `unicode`; `extended` holds
    # opt-in upgrades (the braille spinner).
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
    # back to tier fall-down instead. Mirrors `Glyphs.set`.
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

    # Heuristic tier suggestion: `Extended` when the environment identifies a
    # terminal that ships with (or is overwhelmingly configured with) a
    # modern, well-covered font — kitty, WezTerm, Ghostty, iTerm2 — else
    # `Unicode`. Font coverage itself can't be probed, so this is identity
    # knowledge, not a probe. The env-only overload is a standalone helper;
    # the `Tput` overload below is the one `Screen` consults automatically.
    def self.detected_tier(env = ENV) : Tier
      return Tier::Extended if env.has_key?("KITTY_WINDOW_ID") ||
                               env.has_key?("WEZTERM_EXECUTABLE") ||
                               env.has_key?("GHOSTTY_RESOURCES_DIR")
      program = env["TERM_PROGRAM"]?.try(&.downcase) || ""
      return Tier::Extended if {"kitty", "wezterm", "ghostty", "iterm.app"}.includes?(program)
      term = env["TERM"]?.try(&.downcase) || ""
      return Tier::Extended if term.includes?("kitty") || term.includes?("wezterm") || term.includes?("ghostty")
      Tier::Unicode
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
