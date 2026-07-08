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
