module Crysterm
  # Convenience namespace for widgets
  #
  #    include Widgets
  #    t = Text.new
  module Widgets
    # Blessed-like
    Box   = Widget::Box
    Input = Widget::Input

    OverlayImage = Widget::OverlayImage
    ProgressBar  = Widget::ProgressBar
    Loading      = Widget::Loading
    Layout       = Widget::Layout
    Question     = Widget::Question
    Line         = Widget::Line
    HLine        = Widget::HLine
    VLine        = Widget::VLine
    ListTable    = Widget::ListTable
    List         = Widget::List

    Label          = Widget::Label
    Text           = Widget::Text
    ScrollableBox  = Widget::ScrollableBox
    ScrollableText = Widget::ScrollableText
    TextBox        = Widget::TextBox
    TextArea       = Widget::TextArea

    BigText = Widget::BigText

    RadioSet    = Widget::RadioSet
    RadioButton = Widget::RadioButton
    Checkbox    = Widget::Checkbox

    Button  = Widget::Button
    Prompt  = Widget::Prompt
    Message = Widget::Message
    Log     = Widget::Log

    # Qt-like
    Action = Widget::Action
    Menu   = Widget::Menu

    # Pine-like
    PineHeaderBar = Widget::Pine::HeaderBar
    PineStatusBar = Widget::Pine::StatusBar
  end
end
