require "./spec_helper"
require "file_utils"

include Crysterm

# Regression coverage for a batch of BUGS-F2 findings owned by this agent:
#
#  16 (combo_box.cr)      changing `options=` while the drop-down is open left the
#                         popup showing the old rows, so a click committed a value
#                         the user never saw.
#  17 (date_edit.cr)      the calendar popup was placed raw ("below the field") with
#                         no on-window clamp / above-flip / inset conversion.
#  20 (window_children.cr) `Window#insert` bailed on the duplicate guard before the
#                         detach logic, so reordering an existing top-level child was
#                         a silent no-op.
#  21 (widget_content.cr) a single-line refresh skip left the per-line attr cache
#                         stale after a base-style change.
#  28 (widget_content.cr) `set_content`'s unchanged-content short-circuit ignored a
#                         `no_tags` mode change.
#  29 (item_view.cr)      content rows vs item indices were conflated when
#                         `item_spacing > 0` (half/page navigation moved 2x too far).
#  31 (calendar.cr)       `NoSelection` disabled only mouse selection; the keyboard
#                         still moved the selection and emitted `DateChange`.
#  32 (calendar.cr)       opening one nav dropdown while the other was open left both
#                         open (two stacked modal grabs).
#  36 (filemanager.cr)    entering an unreadable dir left `@cwd`/label at the new dir
#                         while the rows still showed the old one.
#  37 (spinbox_editing.cr) a mouse wheel during an active edit changed the committed
#                         value invisibly.
#  38 (color_dialog.cr)   a wheel anywhere on the dialog surface changed the value
#                         component.
#  39 (bigtext.cr)        shrink-to-content width from codepoint count clipped
#                         CJK/emoji.
#  40 (form.cr)           submit/reset matched `List` but not the other item views.
#  41 (checkbox.cr)       `#partial` on a checked box dropped `checked?` with no
#                         `Event::UnCheck`.
#  42 (group_box.cr / dock_widget.cr) runtime `title=` never updated the rendered
#                         title.

private def f2_screen(w = 80, h = 24)
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: w, height: h,
    default_quit_keys: false)
end

private def f2_mouse(action, x, y, button = ::Tput::Mouse::Button::Left)
  Crysterm::Event::Mouse.new(::Tput::Mouse::Event.new(action, button, x, y, source: :test))
end

private def f2_key(char : Char, key : ::Tput::Key? = nil)
  Crysterm::Event::KeyPress.new(char, key)
end

# ── 16 ──────────────────────────────────────────────────────────────────────
describe "BUGS-F2 16: ComboBox options= refreshes the open drop-down" do
  it "re-fills the open popup so a click commits a value the user can see" do
    s = f2_screen
    cb = Crysterm::Widget::ComboBox.new parent: s, top: 3, left: 5, width: 16, height: 1,
      options: ["Apple", "Banana"]
    cb.focus
    s.render
    cb.open
    pop = cb.popup_widget.not_nil!
    s.render

    cb.options = ["Cherry", "Date", "Elder"]

    # The open popup must now display the NEW rows, not the stale ones — otherwise
    # `commit(index)` resolves the clicked row against the new `@filtered` and picks
    # a value that was never on screen.
    pop.ritems.should eq ["Cherry", "Date", "Elder"]
  end
end

# ── 17 ──────────────────────────────────────────────────────────────────────
describe "BUGS-F2 17: DateEdit calendar popup placement" do
  it "flips the calendar above the field when it would overflow off the bottom" do
    s = f2_screen 80, 14
    de = Crysterm::Widget::DateEdit.new parent: s, top: 11, left: 5, width: 12, height: 1,
      date: Time.utc(2024, 6, 15)
    de.focus
    s.render
    de.open
    pop = de.popup_widget.not_nil!
    s.render

    pop.atop.should be < de.atop                    # opened above, not below
    pop.atop.should be >= 0                         # not clipped at the top
    (pop.atop + pop.aheight).should be <= s.aheight # nor off the bottom
  end

  it "opens the calendar directly below the field when there is room" do
    s = f2_screen 80, 24
    de = Crysterm::Widget::DateEdit.new parent: s, top: 3, left: 5, width: 12, height: 1,
      date: Time.utc(2024, 6, 15)
    de.focus
    s.render
    de.open
    pop = de.popup_widget.not_nil!
    s.render

    pop.atop.should eq de.atop + de.aheight
  end
end

# ── 20 ──────────────────────────────────────────────────────────────────────
describe "BUGS-F2 20: Window#insert reorders an existing top-level child" do
  it "insert_before moves an existing child before another" do
    s = f2_screen
    b1 = Widget::Box.new width: 4, height: 2
    b2 = Widget::Box.new width: 4, height: 2
    s << b1
    s << b2
    s.children.index(b1).should eq 0
    s.children.index(b2).should eq 1

    s.insert_before(b2, b1) # move b2 ahead of b1

    s.children.index(b2).should eq 0
    s.children.index(b1).should eq 1
    s.children.size.should eq 2 # not duplicated
  end

  it "insert_after moves an existing child after another" do
    s = f2_screen
    b1 = Widget::Box.new width: 4, height: 2
    b2 = Widget::Box.new width: 4, height: 2
    s << b2
    s << b1 # order [b2, b1]

    s.insert_after(b2, b1) # b2 after b1 -> [b1, b2]

    s.children.index(b1).should eq 0
    s.children.index(b2).should eq 1
    s.children.size.should eq 2
  end

  it "keeps focus on a reordered child (no rewind churn)" do
    s = f2_screen
    b1 = Widget::Box.new width: 4, height: 2, keys: true
    b2 = Widget::Box.new width: 4, height: 2, keys: true
    s << b1
    s << b2
    b1.focus
    s.focused.should eq b1

    s.insert(b1, -1) # move b1 to the end

    s.children.index(b1).should eq 1
    s.focused.should eq b1 # focus preserved, not rewound
  end
end

# ── 21 ──────────────────────────────────────────────────────────────────────
describe "BUGS-F2 21: per-line attr cache refreshes on a single-line base-style change" do
  it "recomputes the packed attr array when the default style changes" do
    s = f2_screen
    box = Widget::Box.new parent: s, scrollable: true, scrollbar: false,
      width: 10, height: 3, content: "hi"
    s.render
    before = box._clines.attr.not_nil![0]

    box.style.fg = "#ff0000"
    # Reparse directly (a full `s.render` would re-run the CSS cascade and replace
    # `style` wholesale, dropping the inline fg). Even though the widget is
    # single-line and unscrolled, the cache-hit path must refresh the packed attr —
    # leaving it stale used to bleed the old color into later appended/scrolled
    # lines forever.
    box.process_content

    box._clines.attr.not_nil![0].should_not eq before
  end
end

# ── 28 ──────────────────────────────────────────────────────────────────────
describe "BUGS-F2 28: set_content honors a no_tags mode change on identical content" do
  it "reparses literal when re-set with no_tags after being parsed" do
    box = Widget::Box.new parent: f2_screen, width: 20, height: 3
    box.parse_tags = true
    box.set_content("{bold}hi{/bold}")
    box.pcontent.should contain "\e[" # parsed

    box.set_text("{bold}hi{/bold}") # same string, no_tags: true
    box.pcontent.should contain "{bold}"
    box.pcontent.should_not contain "\e["
  end

  it "reparses parsed when re-set without no_tags after being literal" do
    box = Widget::Box.new parent: f2_screen, width: 20, height: 3
    box.parse_tags = true
    box.set_text("{bold}hi{/bold}") # literal
    box.pcontent.should contain "{bold}"

    box.set_content("{bold}hi{/bold}") # same string, no_tags: false
    box.pcontent.should contain "\e["  # now parsed
  end
end

# ── 29 ──────────────────────────────────────────────────────────────────────
describe "BUGS-F2 29: ItemView page navigation counts items, not rows, when spaced" do
  it "moves fewer items per page with item_spacing than without" do
    s = f2_screen

    plain = Widget::List.new parent: s, top: 0, left: 0, width: 20, height: 20,
      items: (0...60).map(&.to_s)
    spaced = Widget::List.new parent: s, top: 0, left: 30, width: 20, height: 20,
      items: (0...60).map(&.to_s)
    spaced.item_spacing = 1
    s.render

    plain.selekt 0
    spaced.selekt 0
    plain.on_keypress(f2_key('\0', ::Tput::Key::PageDown))
    spaced.on_keypress(f2_key('\0', ::Tput::Key::PageDown))

    # A page of rows holds only half as many items when every item has a 1-row gap.
    spaced.selected.should be > 0
    spaced.selected.should be < plain.selected
  end
end

# ── 31 ──────────────────────────────────────────────────────────────────────
describe "BUGS-F2 31: Calendar NoSelection ignores selection-moving keys" do
  it "does not move the date or emit DateChange on an arrow key" do
    s = f2_screen
    cal = Widget::Calendar.new parent: s, top: 0, left: 0, width: 24, height: 12,
      date: Time.utc(2024, 6, 15)
    cal.selection_mode = Widget::Calendar::SelectionMode::NoSelection
    s.render

    changed = false
    cal.on(Crysterm::Event::DateChange) { changed = true }
    before = cal.date

    cal.on_keypress(f2_key('\0', ::Tput::Key::Down))

    cal.date.should eq before
    changed.should be_false
  end

  it "still moves the date under SingleSelection (control)" do
    s = f2_screen
    cal = Widget::Calendar.new parent: s, top: 0, left: 0, width: 24, height: 12,
      date: Time.utc(2024, 6, 15)
    s.render
    before = cal.date

    cal.on_keypress(f2_key('\0', ::Tput::Key::Down))

    cal.date.should_not eq before
  end
end

# ── 32 ──────────────────────────────────────────────────────────────────────
describe "BUGS-F2 32: Calendar closes one nav dropdown before opening the other" do
  it "hides the month menu when the year menu opens" do
    s = f2_screen
    cal = Widget::Calendar.new parent: s, top: 0, left: 0, width: 24, height: 12,
      date: Time.utc(2024, 6, 15)
    cal.focus
    # Synchronous: the clicks below are mapped through layout-assigned geometry,
    # which only exists once a frame has actually run. `render` merely schedules
    # one, leaving `handle_mouse`'s `_get_coords` nil — and its blanket `rescue`
    # then swallows the click, so no menu ever opens.
    s._render

    ox = cal.aleft + cal.ileft
    oy = cal.atop + cal.itop

    # Column 2 lands on the month field, column 12 on the year field (nav layout
    # "‹ <9-wide month> <year> ›").
    cal.emit Crysterm::Event::Mouse, f2_mouse(::Tput::Mouse::Action::Down, ox + 2, oy).mouse
    cal.month_menu.not_nil!.visible?.should be_true

    cal.emit Crysterm::Event::Mouse, f2_mouse(::Tput::Mouse::Action::Down, ox + 12, oy).mouse
    cal.year_menu.not_nil!.visible?.should be_true
    cal.month_menu.not_nil!.visible?.should be_false # sibling was closed
  end
end

# ── 36 ──────────────────────────────────────────────────────────────────────
describe "BUGS-F2 36: FileManager rolls back entering an unreadable directory" do
  it "keeps @cwd on the last good dir and emits no ChangeDir" do
    base = File.tempname("crysterm-fm2")
    locked = File.join(base, "locked")
    Dir.mkdir_p locked
    File.chmod(locked, 0o000)

    # Running as root can still read a 0o000 dir; only assert the rollback when the
    # OS actually denies access.
    readable = begin
      Dir.children(locked)
      true
    rescue
      false
    end

    begin
      s = f2_screen
      fm = Crysterm::Widget::FileManager.new parent: s, cwd: base, keys: true
      fm.refresh
      fm.cwd.should eq base

      idx = fm.ritems.index(&.includes?("locked"))
      idx.should_not be_nil
      fm.selected = idx.not_nil!

      changed = false
      fm.on(Crysterm::Event::ChangeDir) { changed = true }
      fm.enter_selected

      if readable
        # Can't reproduce the failure as root; just ensure no crash.
        fm.cwd.chomp('/').should eq locked
      else
        fm.cwd.should eq base   # rolled back
        changed.should be_false # no spurious ChangeDir for a move that didn't happen
      end
    ensure
      File.chmod(locked, 0o755) rescue nil
      FileUtils.rm_rf base
    end
  end
end

# ── 37 ──────────────────────────────────────────────────────────────────────
describe "BUGS-F2 37: SpinBox wheel cancels an active edit first" do
  it "does not commit the typed buffer when the wheel steps the value" do
    s = f2_screen
    sb = Crysterm::Widget::SpinBox.new parent: s, top: 0, left: 0, width: 10, height: 1,
      minimum: 0, maximum: 100
    sb.focus
    s.render

    sb.on_keypress(f2_key('5')) # start editing: buffer "5"
    sb.editing?.should be_true

    sb.emit Crysterm::Event::Mouse, f2_mouse(::Tput::Mouse::Action::WheelUp, sb.aleft, sb.atop, ::Tput::Mouse::Button::None).mouse

    sb.editing?.should be_false    # buffer discarded, not left hidden
    sb.value.should eq 1           # stepped from the committed 0, not the typed 5
    sb.text.should_not contain "5" # display reflects the value, not the stale buffer
  end
end

# ── 38 ──────────────────────────────────────────────────────────────────────
describe "BUGS-F2 38: ColorDialog wheel only acts over the field/hue" do
  it "ignores a wheel on empty dialog chrome but nudges value over the field" do
    s = f2_screen
    cd = Crysterm::Widget::ColorDialog.new parent: s
    cd.show # the dialog starts hidden; must be laid out for on_mouse to hit-test
    s.render
    cd.render # sets @lpos (the window loop doesn't lay the dialog out on its own)

    ox = cd.aleft + cd.ileft
    oy = cd.atop + cd.itop
    before = cd.value_v

    # The 1-column gap between the 2-D field and the hue strip is dialog chrome.
    cd.emit Crysterm::Event::Mouse, f2_mouse(::Tput::Mouse::Action::WheelDown, ox + Widget::ColorDialog::FIELD_W, oy + 2, ::Tput::Mouse::Button::None).mouse
    cd.value_v.should eq before # unchanged

    # A wheel over the 2-D field does nudge the value component.
    cd.emit Crysterm::Event::Mouse, f2_mouse(::Tput::Mouse::Action::WheelDown, ox + 5, oy + 5, ::Tput::Mouse::Button::None).mouse
    cd.value_v.should be < before
  end
end

# ── 39 ──────────────────────────────────────────────────────────────────────
describe "BUGS-F2 39: BigText auto-width sums per-glyph widths" do
  it "sizes a CJK string by its full-width glyphs, not codepoint count" do
    s = f2_screen
    bt = Crysterm::Widget::BigText.new parent: s, content: "日本語"
    s.render
    bt.render # BigText#render (0-arg) is what runs the shrink-to-content width

    # Each CJK glyph is full-width (2x the half-width cell), so 3 graphemes need
    # 6 cell-widths, not the 3 the old codepoint-count formula produced.
    bt.width.should eq bt.ratio.width * 6
  end
end

# ── 40 ──────────────────────────────────────────────────────────────────────
describe "BUGS-F2 40: Form submits and resets every item view, not just List" do
  it "collects a ListTable value and resets its selection" do
    s = f2_screen
    form = Crysterm::Widget::Form.new parent: s, width: 40, height: 12
    lt = Crysterm::Widget::ListTable.new parent: form, name: "grid", width: 20, height: 8
    lt.set_rows([["H"], ["r1"], ["r2"], ["r3"]]) # row 0 is the header
    lt.selekt 3

    data = form.submit
    data.has_key?("grid").should be_true # contributed a value (was dropped by `when List`)

    form.reset
    # Reset selects the first row (`selekt 0`, clamped past the header spacer);
    # before the fix a `ListTable` was never reset and stayed on row 3.
    lt.selected.should eq 1
  end
end

# ── 41 ──────────────────────────────────────────────────────────────────────
describe "BUGS-F2 41: CheckBox#partial emits UnCheck when leaving a checked box" do
  it "announces the dropped checked state" do
    s = f2_screen
    cb = Crysterm::Widget::CheckBox.new parent: s, tristate: true, checked: true
    cb.checked?.should be_true

    unchecked = false
    cb.on(Crysterm::Event::UnCheck) { unchecked = true }
    partial = false
    cb.on(Crysterm::Event::PartialCheck) { partial = true }

    cb.partial

    cb.checked?.should be_false
    cb.partial?.should be_true
    unchecked.should be_true # listeners mirroring checked? are told it dropped
    partial.should be_true
  end

  it "does not emit UnCheck when partial is called on an unchecked box" do
    s = f2_screen
    cb = Crysterm::Widget::CheckBox.new parent: s, tristate: true, checked: false

    unchecked = false
    cb.on(Crysterm::Event::UnCheck) { unchecked = true }

    cb.partial

    cb.partial?.should be_true
    unchecked.should be_false
  end
end

# ── 42 ──────────────────────────────────────────────────────────────────────
describe "BUGS-F2 42: runtime title= updates the rendered title" do
  it "GroupBox#title= re-labels the border" do
    s = f2_screen
    gb = Crysterm::Widget::GroupBox.new parent: s, title: "Old", width: 30, height: 8
    s.render

    gb.title = "New"
    gb.title.should eq "New"
    gb._label.not_nil!.get_content.should contain "New"
  end

  it "GroupBox#checkable= adds the marker and click handling post-construction" do
    s = f2_screen
    gb = Crysterm::Widget::GroupBox.new parent: s, title: "Opt", checkable: false,
      top: 0, left: 0, width: 30, height: 8
    s.render

    gb.checkable = true
    gb._label.not_nil!.get_content.should contain "[x]" # marker now shown

    # A click on the title row now toggles it.
    gb.emit Crysterm::Event::Mouse, f2_mouse(::Tput::Mouse::Action::Down, gb.aleft + 1, gb.atop).mouse
    gb.checked?.should be_false
  end

  it "DockWidget#title= re-labels the title bar" do
    s = f2_screen
    dock = Crysterm::Widget::DockWidget.new parent: s, title: "Old", dock_size: 20
    s.render

    dock.title = "Files"
    dock.title.should eq "Files"
    dock.titlebar.get_content.should contain "Files"
  end
end
