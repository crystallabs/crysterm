module Crysterm
  # Convenience namespace for widgets
  #
  #    include Widgets
  #    t = Text.new
  module Widgets
    # Blessed-like
    Box   = Widget::Box
    Input = Widget::Input

    # `Media` is the factory (`Media.new` auto-picks a backend). Each concrete
    # backend is also registered for explicit construction.
    Media                  = Widget::Media
    MediaAnsi              = Widget::Media::Ansi
    MediaAnsiTrueColor     = Widget::Media::Ascii::TrueColor
    MediaAnsiC256          = Widget::Media::Ascii::C256
    MediaAnsiC16           = Widget::Media::Ascii::C16
    MediaAnsiC8            = Widget::Media::Ascii::C8
    MediaGlyph             = Widget::Media::Glyph
    MediaAsciiTrueColor    = Widget::Media::Ascii::TrueColor
    MediaAsciiC256         = Widget::Media::Ascii::C256
    MediaAsciiC16          = Widget::Media::Ascii::C16
    MediaAsciiC8           = Widget::Media::Ascii::C8
    MediaAsciiEdge         = Widget::Media::Ascii::Edge
    MediaAsciiArtTrueColor = Widget::Media::Ascii::Art::TrueColor
    MediaAsciiArtC256      = Widget::Media::Ascii::Art::C256
    MediaAsciiArtC16       = Widget::Media::Ascii::Art::C16
    MediaAsciiArtC8        = Widget::Media::Ascii::Art::C8
    MediaUnicodeHalf       = Widget::Media::Unicode::Half
    MediaUnicodeQuadrant   = Widget::Media::Unicode::Quadrant
    MediaUnicodeSextant    = Widget::Media::Unicode::Sextant
    MediaUnicodeOctant     = Widget::Media::Unicode::Octant
    MediaUnicodeBraille    = Widget::Media::Unicode::Braille
    MediaSixel             = Widget::Media::Sixel
    MediaKitty             = Widget::Media::Kitty
    MediaIterm             = Widget::Media::Iterm
    MediaRegis             = Widget::Media::Regis
    MediaTek               = Widget::Media::Tek
    MediaOverlay           = Widget::Media::Overlay
    MediaUeberzug          = Widget::Media::Ueberzug
    Video                  = Widget::Video
    Gradient               = Widget::Gradient
    ProgressBar            = Widget::ProgressBar
    Loading                = Widget::Loading
    Question               = Widget::Question
    Line                   = Widget::Line
    HLine                  = Widget::HLine
    VLine                  = Widget::VLine
    ListTable              = Widget::ListTable
    ListBar                = Widget::ListBar
    List                   = Widget::List
    Tree                   = Widget::Tree
    Table                  = Widget::Table
    Form                   = Widget::Form
    FileManager            = Widget::FileManager

    Label          = Widget::Label
    Text           = Widget::Text
    ScrollableBox  = Widget::ScrollableBox
    ScrollableText = Widget::ScrollableText
    Marquee        = Widget::Marquee
    LineEdit       = Widget::LineEdit
    PlainTextEdit  = Widget::PlainTextEdit

    BigText = Widget::BigText

    # Graphs
    GraphBar        = Widget::Graph::Bar
    GraphStackedBar = Widget::Graph::StackedBar
    GraphCanvas     = Widget::Graph::Canvas
    GraphLineChart  = Widget::Graph::LineChart
    GraphMap        = Widget::Graph::Map
    GraphDonut      = Widget::Graph::Donut
    GraphPieChart   = Widget::Graph::PieChart
    GraphHeatMap    = Widget::Graph::HeatMap
    Painter         = Widget::Graph::Painter
    Gauge           = Widget::Gauge
    GaugeList       = Widget::GaugeList

    # A one-row `Graph::Bar` is a sparkline.
    SparkLine = Widget::Graph::Bar

    # Short names for the categorical pie chart.
    PieChart = Widget::Graph::PieChart
    Pie      = Widget::Graph::PieChart

    # Short name for the 2D heatmap.
    HeatMap = Widget::Graph::HeatMap

    # Effects
    EffectMatrix       = Widget::Effect::Matrix
    EffectSpray        = Widget::Effect::Spray
    EffectFire         = Widget::Effect::Fire
    EffectPlasma       = Widget::Effect::Plasma
    EffectSineScroller = Widget::Effect::SineScroller
    EffectCopperBar    = Widget::Effect::CopperBar

    RadioSet    = Widget::RadioSet
    RadioButton = Widget::RadioButton
    CheckBox    = Widget::CheckBox

    Button     = Widget::Button
    ToolButton = Widget::ToolButton
    Prompt     = Widget::Prompt
    Message    = Widget::Message
    Log        = Widget::Log
    Markdown   = Widget::Markdown

    # Non-visual button manager (logical grouping / exclusivity).
    ButtonGroup = Crysterm::ButtonGroup

    DialogButtonBox = Widget::DialogButtonBox
    ColorDialog     = Widget::ColorDialog

    # Non-visual autocompletion helper attached to a text input.
    Completer = Crysterm::Completer

    Slider        = Widget::Slider
    SpinBox       = Widget::SpinBox
    DoubleSpinBox = Widget::DoubleSpinBox
    TabWidget     = Widget::TabWidget
    # A `TabWidget` with `auto_advance:` set is a carousel.
    Carousel      = Widget::TabWidget
    ComboBox      = Widget::ComboBox
    GroupBox      = Widget::GroupBox
    Splitter      = Widget::Splitter
    StackedWidget = Widget::StackedWidget
    ToolBox       = Widget::ToolBox
    Wizard        = Widget::Wizard
    ScrollBar     = Widget::ScrollBar
    Dial          = Widget::Dial

    Calendar     = Widget::Calendar
    DateEdit     = Widget::DateEdit
    TimeEdit     = Widget::TimeEdit
    DateTimeEdit = Widget::DateTimeEdit

    ToolTip      = Widget::ToolTip
    StatusBar    = Widget::StatusBar
    MainWindow   = Widget::MainWindow
    DockWidget   = Widget::DockWidget
    ToolBar      = Widget::ToolBar
    SizeGrip     = Widget::SizeGrip
    LCDNumber    = Widget::LCDNumber
    SplashScreen = Widget::SplashScreen

    Terminal = Widget::Terminal

    # Debug overlay showing render/draw/FPS rates and terminal byte throughput.
    Fps = Widget::Fps

    # Qt-like
    Action  = Crysterm::Action
    Menu    = Widget::Menu
    MenuBar = Widget::MenuBar

    # Layout engines (not widgets; install on a container via `widget.layout = ...`)
    ManualLayout      = Crysterm::Layout::Manual
    GridLayout        = Crysterm::Layout::Grid
    UniformGridLayout = Crysterm::Layout::UniformGrid
    MasonryLayout     = Crysterm::Layout::Masonry
    WrapLayout        = Crysterm::Layout::Wrap
    BoxLayout         = Crysterm::Layout::Box
    HBoxLayout        = Crysterm::Layout::HBox
    VBoxLayout        = Crysterm::Layout::VBox
    BorderLayout      = Crysterm::Layout::Border
    StackLayout       = Crysterm::Layout::Stack
    StackedLayout     = Crysterm::Layout::Stack
    FormLayout        = Crysterm::Layout::Form

    # Pine-like
    PineHeaderBar    = Widget::Pine::HeaderBar
    PineStatusBar    = Widget::Pine::StatusBar
    PineKeyMenu      = Widget::Pine::KeyMenu
    PineMainMenu     = Widget::Pine::MainMenu
    PineMessageIndex = Widget::Pine::MessageIndex
    PineMessageView  = Widget::Pine::MessageView
    PineCompose      = Widget::Pine::Compose
    PineSetup        = Widget::Pine::Setup
    PineFolderList   = Widget::Pine::FolderList
    PineAddressBook  = Widget::Pine::AddressBook
    PineKeyPrompt    = Widget::Pine::KeyPrompt
    PineListSelect   = Widget::Pine::ListSelect
    PineOptionList   = Widget::Pine::OptionList
    PineFileBrowser  = Widget::Pine::FileBrowser
    PineTextView     = Widget::Pine::TextView
    PineProgressBar  = Widget::Pine::ProgressBar
  end
end
