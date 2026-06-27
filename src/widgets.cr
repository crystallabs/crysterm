module Crysterm
  # Convenience namespace for widgets
  #
  #    include Widgets
  #    t = Text.new
  module Widgets
    # Blessed-like
    Box   = Widget::Box
    Input = Widget::Input

    # The concrete backends live under `Media` (e.g. `Media::Ansi`, `Media::Kitty`).
    Media       = Widget::Media
    Video       = Widget::Video
    Gradient    = Widget::Gradient
    ProgressBar = Widget::ProgressBar
    Loading     = Widget::Loading
    Question    = Widget::Question
    Line        = Widget::Line
    HLine       = Widget::HLine
    VLine       = Widget::VLine
    ListTable   = Widget::ListTable
    ListBar     = Widget::ListBar
    List        = Widget::List
    Tree        = Widget::Tree
    Table       = Widget::Table
    Form        = Widget::Form
    FileManager = Widget::FileManager

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
    Painter         = Widget::Graph::Painter
    Gauge           = Widget::Gauge
    GaugeList       = Widget::GaugeList

    # A one-row `Graph::Bar` is a sparkline.
    SparkLine = Widget::Graph::Bar

    # Effects
    EffectMatrix       = Widget::Effect::Matrix
    EffectSpray        = Widget::Effect::Spray
    EffectFire         = Widget::Effect::Fire
    EffectPlasma       = Widget::Effect::Plasma
    EffectSineScroller = Widget::Effect::SineScroller
    EffectCopperBar    = Widget::Effect::CopperBar

    RadioSet    = Widget::RadioSet
    RadioButton = Widget::RadioButton
    Checkbox    = Widget::Checkbox

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
    HBoxLayout        = Crysterm::Layout::HBox
    VBoxLayout        = Crysterm::Layout::VBox
    BorderLayout      = Crysterm::Layout::Border
    StackLayout       = Crysterm::Layout::Stack
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
  end
end
