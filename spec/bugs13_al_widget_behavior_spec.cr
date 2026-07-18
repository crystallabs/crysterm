require "./spec_helper"

include Crysterm

# Regression specs for BUGS13 findings A11–A14.
#
#  A11 (src/widget/dock_widget.cr): float/drag geometry used margin-inclusive
#     `aleft`/`atop`, drifting by the CSS margin per float toggle.
#  A12 (src/widget/filemanager.cr): path label and `Event::DirectoryChanged`
#     desynced on `reset`/`refresh("/dir")` — only `open_selected` kept them
#     in sync.
#  A13 (src/widget/form.cr): keyboard traversal focused disabled widgets,
#     silently wiping their Disabled state.
#  A14 (src/widget/lcd_number.cr): `mode=`/`digit_count=` were inert until the
#     next `display` call.

private def wb_screen(w = 80, h = 24)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

describe "BUGS13 A11: DockWidget float geometry excludes the CSS margin" do
  it "does not drift by the margin across float toggles" do
    s = wb_screen
    dock = Widget::DockWidget.new parent: s, top: 2, left: 4, width: 20, height: 10,
      area: Widget::DockWidget::Area::Floating,
      style: Style.new(margin: Margin.new(left: 2, top: 1, right: 0, bottom: 0))
    s._render

    a0 = dock.aleft
    t0 = dock.atop

    # Dock, then float again (restoring the remembered rectangle).
    dock.toggle_floating
    s._render
    dock.toggle_floating
    s._render

    # Before the fix each cycle re-added the margin: aleft drifted +2, atop +1.
    dock.aleft.should eq a0
    dock.atop.should eq t0
  end
end

describe "BUGS13 A12: FileManager label and DirectoryChanged stay in sync" do
  it "updates the path label and emits DirectoryChanged on refresh(dir) and reset" do
    dir_a = File.join(Dir.tempdir, "crysterm_bugs13_a_#{Process.pid}")
    dir_b = File.join(Dir.tempdir, "crysterm_bugs13_b_#{Process.pid}")
    Dir.mkdir_p dir_a
    Dir.mkdir_p dir_b
    begin
      s = wb_screen
      fm = Widget::FileManager.new parent: s, top: 0, left: 0, width: 40, height: 15,
        cwd: dir_a, label: "dir"

      changes = [] of {String, String}
      fm.on(Crysterm::Event::DirectoryChanged) { |e| changes << {e.path, e.previous} }

      fm.refresh dir_b
      fm.cwd.should eq dir_b
      changes.should eq [{dir_b, dir_a}]
      fm.@label_widget.not_nil!.content.should eq dir_b

      # `reset` returns to the construction-time cwd — before the fix it left
      # the label stale and emitted no DirectoryChanged.
      fm.reset
      fm.cwd.should eq dir_a
      changes.last.should eq({dir_a, dir_b})
      fm.@label_widget.not_nil!.content.should eq dir_a

      # A no-move refresh emits nothing extra.
      n = changes.size
      fm.refresh
      changes.size.should eq n
    ensure
      Dir.delete dir_a rescue nil
      Dir.delete dir_b rescue nil
    end
  end
end

describe "BUGS13 A13: Form traversal skips disabled widgets" do
  it "does not focus a disabled child (which would wipe its Disabled state)" do
    s = wb_screen
    form = Widget::Form.new parent: s, keys: true, width: 30, height: 10
    a = Widget::Box.new parent: form, input: true, top: 0, left: 0, width: 5, height: 1
    b = Widget::Box.new parent: form, input: true, top: 2, left: 0, width: 5, height: 1
    c = Widget::Box.new parent: form, input: true, top: 4, left: 0, width: 5, height: 1
    s._render

    b.state = WidgetState::Disabled

    form.focus_next
    s.focused.should eq a

    # Before the fix this focused `b`, whose single-valued state became
    # :focused — silently re-enabling it.
    form.focus_next
    s.focused.should eq c
    b.disabled?.should be_true

    # Backwards traversal skips it too.
    form.focus_previous
    s.focused.should eq a
    b.disabled?.should be_true
  end

  it "returns no candidate when every focusable child is disabled" do
    s = wb_screen
    form = Widget::Form.new parent: s, keys: true, width: 30, height: 10
    a = Widget::Box.new parent: form, input: true, top: 0, left: 0, width: 5, height: 1
    s._render

    a.state = WidgetState::Disabled
    form.next_focusable.should be_nil
    a.disabled?.should be_true
  end
end

describe "BUGS13 A14: LCDNumber mode=/digit_count= take effect immediately" do
  it "re-formats the retained integer when mode changes" do
    s = wb_screen
    lcd = Widget::LCDNumber.new parent: s, width: 24, height: 3
    lcd.display 255
    lcd.text.should eq "255"

    lcd.mode = Widget::LCDNumber::Mode::Hex
    lcd.text.should eq "FF" # stayed "255" forever before the fix

    lcd.mode = Widget::LCDNumber::Mode::Bin
    lcd.text.should eq "11111111"

    lcd.mode = Widget::LCDNumber::Mode::Dec
    lcd.text.should eq "255"
  end

  it "keeps a Float/String display unchanged on a mode switch (no base applies)" do
    s = wb_screen
    lcd = Widget::LCDNumber.new parent: s, width: 24, height: 3
    lcd.display 1.5
    lcd.mode = Widget::LCDNumber::Mode::Hex
    lcd.text.should eq "1.5"
  end

  it "re-aligns the shown value when digit_count changes" do
    s = wb_screen
    lcd = Widget::LCDNumber.new parent: s, width: 40, height: 3, digit_count: 5
    lcd.display 7
    before = lcd.content
    lcd.digit_count = 2
    lcd.content.should_not eq before # was inert until the next display call
  end
end
