require "./spec_helper"

include Crysterm

private def press(s, key : Tput::Key)
  s.emit Crysterm::Event::KeyPress.new('\0', key)
  s.repaint
end

describe "Mutt::Compose navigation and header aside" do
  it "moves the highlight across the divider and reports the row activated" do
    s = headless_screen(80, 24)
    compose = Crysterm::Widget::Mutt::Compose.new parent: s, top: 0, left: 0, width: 80, height: 20
    compose.fields = ["Title", "Due"]
    compose.add_attachment Crysterm::Widget::Mutt::Attachment.new("(main note)", "text/plain", 12)
    compose.add_attachment Crysterm::Widget::Mutt::Attachment.new("memo.txt", "text/plain", 3)
    activated = [] of Int32
    compose.on(Crysterm::Event::ItemActivated) { |e| activated << e.index }
    compose.menu.focus
    s.repaint

    compose.selected_row.should eq({Crysterm::Widget::Mutt::Compose::RowKind::Header, 0})
    press s, Tput::Key::Down
    compose.selected_row.should eq({Crysterm::Widget::Mutt::Compose::RowKind::Header, 1})
    press s, Tput::Key::Down
    compose.selected_row.should eq({Crysterm::Widget::Mutt::Compose::RowKind::Attachment, 0})
    compose.menu.should be compose.attachments_menu
    press s, Tput::Key::Down
    compose.selected_row.should eq({Crysterm::Widget::Mutt::Compose::RowKind::Attachment, 1})
    press s, Tput::Key::Down
    compose.selected_row.should eq({Crysterm::Widget::Mutt::Compose::RowKind::Attachment, 1})
    press s, Tput::Key::Enter
    activated.should eq [4]
    compose.row_at(4).should eq({Crysterm::Widget::Mutt::Compose::RowKind::Attachment, 1})

    press s, Tput::Key::Up
    press s, Tput::Key::Up
    compose.selected_row.should eq({Crysterm::Widget::Mutt::Compose::RowKind::Header, 1})
    compose.menu.should be compose.headers_menu
    press s, Tput::Key::Home
    compose.selected_row.should eq({Crysterm::Widget::Mutt::Compose::RowKind::Header, 0})
    press s, Tput::Key::End
    compose.selected_row.should eq({Crysterm::Widget::Mutt::Compose::RowKind::Attachment, 1})
    press s, Tput::Key::Enter
    activated.should eq [4, 4]
  ensure
    s.try &.destroy
  end

  it "shows a widget appended to the header row beside the headers only" do
    s = headless_screen(80, 24)
    compose = Crysterm::Widget::Mutt::Compose.new parent: s, top: 0, left: 0, width: 80, height: 20
    compose.fields = ["Title", "Due", "Tags"]
    compose.add_attachment Crysterm::Widget::Mutt::Attachment.new("(main note)", "text/plain", 12)
    Crysterm::Widget::Box.new(parent: compose.header_box, width: 30, content: "Help text")
    s.repaint

    text = s.dump(0, 80, 0, 6) || ""
    lines = text.lines.select(&.starts_with?('|'))
    lines[0].should contain("Title:")
    lines[0][50..].should contain("Help text")
    lines[2].should contain("Tags:")
    lines[3].should match(/\A\|-- Attachments \(1\) -{40,}/)
    lines[4].should contain("(main note)")
  ensure
    s.try &.destroy
  end
end
