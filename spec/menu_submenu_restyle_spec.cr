require "./spec_helper"

include Crysterm

# An open submenu follows its parent when a theme switch re-sizes the parent
# in place (`Menu#place_submenu`, re-run from the submenu's `#paint`): it
# stays against the parent's right edge, neither over its ▶ column nor
# leaving a gap.

private def with_theme(theme : Crysterm::CSS::Theme?, &)
  saved = Crysterm::CSS.theme
  Crysterm::CSS.theme = theme
  yield
ensure
  Crysterm::CSS.theme = saved
end

private def msr_open(s)
  m = Widget::Menu.new(parent: s)
  m.add_action("New") { }
  m.add_submenu "Recent", [Action.new("old-1"), Action.new("old-2")]
  m.popup 6, 2
  s.repaint
  m.current_index = 1
  m.hover_item 1
  s.repaint
  {m, m.@submenu_open.not_nil!}
end

private def msr_adjacent(m, sub)
  border = m.style.border_view.any? ? 1 : 0
  sub.aleft.should eq(m.aleft + m.awidth - border)
  sub.atop.should eq(m.atop + m.itop + 1)
end

describe "Menu submenu placement across a theme switch" do
  it "re-places an open submenu when the parent's width changes" do
    s = headless_screen(80, 24)
    with_theme(nil) do
      m, sub = msr_open s
      msr_adjacent m, sub
      before = m.awidth
      changed = false
      [Crysterm::CSS::Theme::Choice::BreezeDark, Crysterm::CSS::Theme::Choice::QdarkstyleDark,
       Crysterm::CSS::Theme::Choice::None].each do |choice|
        Crysterm::CSS.theme = Crysterm::CSS.resolve_theme(choice, s)
        s.repaint
        s.repaint
        m.@submenu_open.should be(sub)
        changed ||= m.awidth != before
        msr_adjacent m, sub
      end
      changed.should be_true
    end
  end
end
