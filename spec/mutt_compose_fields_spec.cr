require "./spec_helper"

include Crysterm

describe "Mutt::Compose#fields" do
  it "defaults to the mail header fields with the classic label column" do
    s = headless_screen(80, 24)
    compose = Crysterm::Widget::Mutt::Compose.new parent: s, top: 0, left: 0, width: 80, height: 20
    compose.fields.should eq Crysterm::Widget::Mutt::Compose::FIELDS
    compose.separator_index.should eq 5
    compose.set_header "To", "a@b"
    s.repaint
    text = s.dump(0, 80, 0, 8) || ""
    text.should contain("|    From: ")
    text.should contain("|      To: a@b")
    text.should contain("-- Attachments (0) ")
  ensure
    s.try &.destroy
  end

  it "takes custom fields and a custom divider label, re-routing rows" do
    s = headless_screen(80, 24)
    compose = Crysterm::Widget::Mutt::Compose.new parent: s, top: 0, left: 0, width: 80, height: 20
    compose.fields = ["Title", "Due", "Priority"]
    compose.separator_label = "Notes"
    compose.set_header "Title", "Pay rent"
    compose.set_header "Priority", "high"
    compose.add_attachment Crysterm::Widget::Mutt::Attachment.new("(main note)", "text/plain", 12)

    compose.separator_index.should eq 3
    compose.row_at(2).should eq({Crysterm::Widget::Mutt::Compose::RowKind::Header, 2})
    compose.row_at(3).should eq({Crysterm::Widget::Mutt::Compose::RowKind::Separator, -1})
    compose.row_at(4).should eq({Crysterm::Widget::Mutt::Compose::RowKind::Attachment, 0})
    compose.headers_menu.current_index.should eq 0
    compose.selected_row.should eq({Crysterm::Widget::Mutt::Compose::RowKind::Header, 0})

    s.repaint
    text = s.dump(0, 80, 0, 8) || ""
    text.should contain("|    Title: Pay rent")
    text.should contain("|      Due: ")
    text.should contain("| Priority: high")
    text.should contain("-- Notes (1) ")
    text.should contain("(main note)")
    text.should_not contain("From:")
  ensure
    s.try &.destroy
  end

  it "hands the keyboard back to the headers when the attachments are cleared under the highlight" do
    s = headless_screen(80, 24)
    compose = Crysterm::Widget::Mutt::Compose.new parent: s, top: 0, left: 0, width: 80, height: 20
    compose.add_attachment Crysterm::Widget::Mutt::Attachment.new("memo.txt", "text/plain", 3)
    compose.attachments_menu.focus
    s.repaint
    compose.selected_row.should eq({Crysterm::Widget::Mutt::Compose::RowKind::Attachment, 0})
    compose.clear_attachments
    compose.menu.should be compose.headers_menu
    compose.headers_menu.focused?.should be_true
    compose.selected_row.should eq({Crysterm::Widget::Mutt::Compose::RowKind::Header, 0})
    # Emptied with the keyboard elsewhere, the highlight moves and the keyboard stays.
    compose.add_attachment Crysterm::Widget::Mutt::Attachment.new("memo.txt", "text/plain", 3)
    compose.attachments_menu.focus
    s.release_focus
    compose.clear_attachments
    compose.menu.should be compose.headers_menu
    compose.headers_menu.focused?.should be_false
  ensure
    s.try &.destroy
  end
end
