require "./spec_helper"

include Crysterm

# A `hide`/`show` (or fade) of a CSS-styled widget persists the change onto
# an inline style made for it (`Mixin::Style#inline_style_carrier?`), so the
# next cascade keeps it. Once the theme is switched off, that made-up style
# must not stand in for the widget's own styles: an overlay keeps its floor
# border, and the shown or hidden state stays as it was.

private def with_theme(theme : Crysterm::CSS::Theme?, &)
  saved = Crysterm::CSS.theme
  Crysterm::CSS.theme = theme
  yield
ensure
  Crysterm::CSS.theme = saved
end

private def build(s)
  main = Widget::MainWindow.new parent: s
  view = main.menu_bar.add_menu "&View"
  view.add_action("&Rendered") { }
  view.add_submenu "&More", [Action.new("&One"), Action.new("&Two")]
  s.repaint
  {main, view}
end

describe "Mixin::Style inline style carrier" do
  it "keeps a menu's floor border once a theme without one is switched off" do
    s = headless_screen(80, 24)
    main, view = build(s)
    with_theme(Crysterm::CSS.resolve_theme(Crysterm::CSS::Theme::Choice::QdarkstyleDark, s)) do
      main.menu_bar.open_menu 0
      s.repaint
      view.style.border_view.left.should eq 0
      view.inline_style_carrier?.should be_true
      view.assigned_inline_style.should be_nil
      main.menu_bar.close
      s.repaint
    end
    with_theme(nil) do
      s.repaint
      main.menu_bar.open_menu 0
      s.repaint
      view.css_styled?.should be_false
      bv = view.style.border_view
      {bv.left, bv.top, bv.right, bv.bottom}.should eq({1, 1, 1, 1})
      # A submenu takes the menu's own inline style, not the carrier.
      view.select_first_action
      view.handle_key_press Crysterm::Event::KeyPress.new('\0', Tput::Key::Down)
      view.handle_key_press Crysterm::Event::KeyPress.new('\0', Tput::Key::Right)
      s.repaint
      sub = s.descendants.select(Widget::Menu).find! { |m| m.visible? && m.parent_menu == view }
      sub.style.border_view.left.should eq 1
      main.menu_bar.close
      s.repaint
      view.visible?.should be_false
    end
  end

  it "keeps the shown or hidden state across the theme going and coming back" do
    s = headless_screen(80, 24)
    box = Widget::Box.new parent: s, width: 10, height: 3
    s.repaint
    with_theme(Crysterm::CSS.resolve_theme(Crysterm::CSS::Theme::Choice::Dark, s)) do
      s.repaint
      box.hide
      s.repaint
    end
    with_theme(nil) do
      s.repaint
      box.visible?.should be_false
      box.show
      s.repaint
      box.visible?.should be_true
    end
    with_theme(Crysterm::CSS.resolve_theme(Crysterm::CSS::Theme::Choice::Dark, s)) do
      s.repaint
      box.visible?.should be_true
    end
  end

  it "leaves an inline style the program set in charge" do
    s = headless_screen(80, 24)
    m = Widget::Menu.new parent: s, style: Style.new(border: false)
    m.add_action "&One"
    s.repaint
    with_theme(Crysterm::CSS.resolve_theme(Crysterm::CSS::Theme::Choice::Dark, s)) do
      s.repaint
      m.hide
      m.show
      s.repaint
      m.inline_style_carrier?.should be_false
    end
    with_theme(nil) do
      s.repaint
      m.style.border_view.left.should eq 0
      m.style.should be(m.inline_style)
    end
  end
end
