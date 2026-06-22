module Crysterm
  # Convenience namespace for widgets
  #
  #    include Widgets
  #    t = Text.new
  module Widgets
    # Blessed-like
    Box   = Widget::Box
    Input = Widget::Input

    # The concrete backends live under `Image` (e.g. `Image::Ansi`, `Image::Kitty`).
    Image       = Widget::Image
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
    TextBox        = Widget::TextBox
    TextArea       = Widget::TextArea

    BigText = Widget::BigText

    # Graphs
    GraphBlockBar = Widget::Graph::BlockBar

    # Effects
    EffectMatrix = Widget::Effect::Matrix
    EffectSpray  = Widget::Effect::Spray

    RadioSet    = Widget::RadioSet
    RadioButton = Widget::RadioButton
    Checkbox    = Widget::Checkbox

    Button  = Widget::Button
    Prompt  = Widget::Prompt
    Message = Widget::Message
    Log     = Widget::Log

    Slider        = Widget::Slider
    SpinBox       = Widget::SpinBox
    DoubleSpinBox = Widget::DoubleSpinBox
    TabWidget     = Widget::TabWidget
    ComboBox      = Widget::ComboBox
    GroupBox      = Widget::GroupBox
    Splitter      = Widget::Splitter
    StackedWidget = Widget::StackedWidget
    ToolBox       = Widget::ToolBox
    Wizard        = Widget::Wizard
    ScrollBar     = Widget::ScrollBar
    Dial          = Widget::Dial

    Calendar = Widget::Calendar
    DateEdit = Widget::DateEdit
    TimeEdit = Widget::TimeEdit

    Terminal = Widget::Terminal

    # Debug overlay showing render/draw/FPS rates and terminal byte throughput.
    Fps = Widget::Fps

    # Qt-like
    Action = Widget::Action
    Menu   = Widget::Menu

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
