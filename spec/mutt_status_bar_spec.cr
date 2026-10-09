require "./spec_helper"

include Crysterm

describe "Mutt::StatusBar" do
  it "gives the right zone only the columns its text needs, so a long left text is not cut" do
    s = headless_screen(80, 3)
    bar = Crysterm::Widget::Mutt::StatusBar.new parent: s, top: 0, width: 80
    left = "-*-Mutt: a mailbox with a long name [Msgs:12 New:3 Del:1]"
    bar.set_text left, "-(threads)-"
    s.repaint
    row = (s.dump(0, 80, 0, 1) || "").lines[2]
    row.should contain(left)
    row.should end_with("---(threads)-|")
    bar.right_zone.width.should eq 11

    bar.set_text "-*-Mutt: INBOX", "-(a much longer right zone)-"
    s.repaint
    row = (s.dump(0, 80, 0, 1) || "").lines[2]
    row.should start_with("|-*-Mutt: INBOX---")
    row.should end_with("-(a much longer right zone)-|")
  ensure
    s.try &.destroy
  end
end
