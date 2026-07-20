module Crysterm
  # Convenience namespace for widgets
  #
  #    include Widgets
  #    t = Text.new
  module Widgets
    # Blessed-like
    alias Box = Widget::Box
    alias Input = Widget::Input

    # `Media` is the factory (`Media.new` auto-picks a backend). Each concrete
    # backend is also registered for explicit construction.
    alias Media = Widget::Media
    alias MediaAnsi = Widget::Media::Ansi
    alias MediaAnsiTrueColor = Widget::Media::Ascii::TrueColor
    alias MediaAnsiC256 = Widget::Media::Ascii::C256
    alias MediaAnsiC16 = Widget::Media::Ascii::C16
    alias MediaAnsiC8 = Widget::Media::Ascii::C8
    alias MediaGlyph = Widget::Media::Glyph
    alias MediaAsciiTrueColor = Widget::Media::Ascii::TrueColor
    alias MediaAsciiC256 = Widget::Media::Ascii::C256
    alias MediaAsciiC16 = Widget::Media::Ascii::C16
    alias MediaAsciiC8 = Widget::Media::Ascii::C8
    alias MediaAsciiEdge = Widget::Media::Ascii::Edge
    alias MediaAsciiArtTrueColor = Widget::Media::Ascii::Art::TrueColor
    alias MediaAsciiArtC256 = Widget::Media::Ascii::Art::C256
    alias MediaAsciiArtC16 = Widget::Media::Ascii::Art::C16
    alias MediaAsciiArtC8 = Widget::Media::Ascii::Art::C8
    alias MediaUnicodeHalf = Widget::Media::Unicode::Half
    alias MediaUnicodeQuadrant = Widget::Media::Unicode::Quadrant
    alias MediaUnicodeSextant = Widget::Media::Unicode::Sextant
    alias MediaUnicodeOctant = Widget::Media::Unicode::Octant
    alias MediaUnicodeBraille = Widget::Media::Unicode::Braille
    alias MediaSixel = Widget::Media::Sixel
    alias MediaKitty = Widget::Media::Kitty
    alias MediaIterm = Widget::Media::Iterm
    alias MediaRegis = Widget::Media::Regis
    alias MediaTek = Widget::Media::Tek
    alias MediaOverlay = Widget::Media::Overlay
    alias MediaUeberzug = Widget::Media::Ueberzug
    alias Video = Widget::Video
    alias Gradient = Widget::Gradient
    alias ProgressBar = Widget::ProgressBar
    alias Loading = Widget::Loading
    alias Question = Widget::Question
    alias Line = Widget::Line
    alias HLine = Widget::HLine
    alias VLine = Widget::VLine
    alias ListTable = Widget::ListTable
    alias ListBar = Widget::ListBar
    alias List = Widget::List
    alias Tree = Widget::Tree
    alias Table = Widget::Table
    alias Form = Widget::Form
    alias FileManager = Widget::FileManager

    alias Label = Widget::Label
    alias Text = Widget::Text
    alias ScrollableBox = Widget::ScrollableBox
    alias ScrollableText = Widget::ScrollableText
    alias Marquee = Widget::Marquee
    alias LineEdit = Widget::LineEdit
    alias PlainTextEdit = Widget::PlainTextEdit

    alias BigText = Widget::BigText

    # Graphs
    alias GraphBar = Widget::Graph::Bar
    alias GraphStackedBar = Widget::Graph::StackedBar
    alias GraphCanvas = Widget::Graph::Canvas
    alias GraphLineChart = Widget::Graph::LineChart
    alias GraphMap = Widget::Graph::Map
    alias GraphDonut = Widget::Graph::Donut
    alias GraphPieChart = Widget::Graph::PieChart
    alias GraphHeatMap = Widget::Graph::HeatMap
    alias Painter = Widget::Graph::Painter
    alias Gauge = Widget::Gauge
    alias GaugeList = Widget::GaugeList

    # A one-row `Graph::Bar` is a sparkline.
    alias SparkLine = Widget::Graph::Bar

    # Short names for the categorical pie chart.
    alias PieChart = Widget::Graph::PieChart
    alias Pie = Widget::Graph::PieChart

    # Short name for the 2D heatmap.
    alias HeatMap = Widget::Graph::HeatMap

    # Effects
    alias EffectMatrix = Widget::Effect::Matrix
    alias EffectSpray = Widget::Effect::Spray
    alias EffectFire = Widget::Effect::Fire
    alias EffectPlasma = Widget::Effect::Plasma
    alias EffectSineScroller = Widget::Effect::SineScroller
    alias EffectCopperBar = Widget::Effect::CopperBar

    alias RadioSet = Widget::RadioSet
    alias RadioButton = Widget::RadioButton
    alias CheckBox = Widget::CheckBox

    alias Button = Widget::Button
    alias ToolButton = Widget::ToolButton
    alias Prompt = Widget::Prompt
    alias Message = Widget::Message
    alias Log = Widget::Log
    alias Markdown = Widget::Markdown # deprecated — use TextBrowser + `#markdown=`

    # Non-visual button manager (logical grouping / exclusivity).
    alias ButtonGroup = Crysterm::ButtonGroup

    alias DialogButtonBox = Widget::DialogButtonBox
    alias ColorDialog = Widget::ColorDialog

    # Non-visual autocompletion helper attached to a text input.
    alias Completer = Crysterm::Completer

    alias Slider = Widget::Slider
    alias SpinBox = Widget::SpinBox
    alias DoubleSpinBox = Widget::DoubleSpinBox
    alias TabWidget = Widget::TabWidget
    # A `TabWidget` with `auto_advance:` set is a carousel.
    alias Carousel = Widget::TabWidget
    alias ComboBox = Widget::ComboBox
    alias GroupBox = Widget::GroupBox
    alias Splitter = Widget::Splitter
    alias StackedWidget = Widget::StackedWidget
    alias ToolBox = Widget::ToolBox
    alias Wizard = Widget::Wizard
    alias ScrollBar = Widget::ScrollBar
    alias Dial = Widget::Dial

    alias Calendar = Widget::Calendar
    alias DateEdit = Widget::DateEdit
    alias TimeEdit = Widget::TimeEdit
    alias DateTimeEdit = Widget::DateTimeEdit

    alias ToolTip = Widget::ToolTip
    alias StatusBar = Widget::StatusBar
    alias MainWindow = Widget::MainWindow
    alias DockWidget = Widget::DockWidget
    alias ToolBar = Widget::ToolBar
    alias SizeGrip = Widget::SizeGrip
    alias LCDNumber = Widget::LCDNumber
    alias SplashScreen = Widget::SplashScreen

    alias Terminal = Widget::Terminal

    # Debug overlay showing render/draw/FPS rates and terminal byte throughput.
    alias Fps = Widget::Fps

    # Qt-like
    alias Action = Crysterm::Action
    alias Menu = Widget::Menu
    alias MenuBar = Widget::MenuBar

    # Layout engines (not widgets; install on a container via `widget.layout = ...`)
    alias ManualLayout = Crysterm::Layout::Manual
    alias GridLayout = Crysterm::Layout::Grid
    alias UniformGridLayout = Crysterm::Layout::UniformGrid
    alias MasonryLayout = Crysterm::Layout::Masonry
    alias WrapLayout = Crysterm::Layout::Wrap
    alias BoxLayout = Crysterm::Layout::Box
    alias HBoxLayout = Crysterm::Layout::HBox
    alias VBoxLayout = Crysterm::Layout::VBox
    alias BorderLayout = Crysterm::Layout::Border
    alias StackLayout = Crysterm::Layout::Stack
    alias StackedLayout = Crysterm::Layout::Stack
    alias FormLayout = Crysterm::Layout::Form

    # Pine-like
    alias PineHeaderBar = Widget::Pine::HeaderBar
    alias PineStatusBar = Widget::Pine::StatusBar
    alias PineKeyMenu = Widget::Pine::KeyMenu
    alias PineMainMenu = Widget::Pine::MainMenu
    alias PineMessageIndex = Widget::Pine::MessageIndex
    alias PineMessageView = Widget::Pine::MessageView
    alias PineCompose = Widget::Pine::Compose
    alias PineSetup = Widget::Pine::Setup
    alias PineFolderList = Widget::Pine::FolderList
    alias PineAddressBook = Widget::Pine::AddressBook
    alias PineKeyPrompt = Widget::Pine::KeyPrompt
    alias PineListSelect = Widget::Pine::ListSelect
    alias PineOptionList = Widget::Pine::OptionList
    alias PineFileBrowser = Widget::Pine::FileBrowser
    alias PineTextView = Widget::Pine::TextView
    alias PineProgressBar = Widget::Pine::ProgressBar
  end
end
