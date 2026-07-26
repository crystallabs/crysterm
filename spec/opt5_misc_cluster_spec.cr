require "./spec_helper"

include Crysterm

# OPT5 misc cluster: three small DRY consolidations bundled into one spec.
#
# * O5-02 — `Window#screen=` and `Window#disconnect` shared an identical
#   last-window device-teardown sequence (restore_terminal / owns_io close /
#   stop_input / release_cell_geometry_anchor), now extracted into
#   `#teardown_device_if_last` (src/window_connection.cr). Pins that both call
#   sites still emit the identical ordered escape subsequence on the OLD
#   device, and that a live sibling skips teardown entirely at both sites.
# * O5-18 — `BorderType#line_glyphs` (src/style/border.cr) was a 5-way copy of
#   the same 6-glyph tuple shape, now a `border_glyph_tuple` macro. Pins every
#   `BorderType`'s tuple against its pre-refactor literal.
# * O5-35 — `truncate(str, len)` was byte-identical in
#   src/widget/pine/message_index.cr and src/widget/mutt/message_index.cr, now
#   homed once in `Crysterm::Widget::Mutt.truncate`
#   (src/widget/mutt/formatting.cr). Pins the shared helper directly and pins
#   both widgets' rendered rows use it.

private def o5msc_window(output : IO) : Crysterm::Window
  Crysterm::Window.new(
    input: IO::Memory.new, output: output, error: IO::Memory.new,
    width: 80, height: 24, default_quit_keys: false)
end

private def o5msc_screen(w = 80, h = 24) : Crysterm::Screen
  Crysterm::Screen.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h)
end

describe "OPT5 O5-02: #teardown_device_if_last shared by disconnect/screen=" do
  it "disconnect and screen= emit the identical teardown-escape subsequence for a solo window" do
    disc_out = IO::Memory.new
    a = o5msc_window disc_out
    disc_mark = disc_out.to_s.size

    a.disconnect
    disc_seq = disc_out.to_s[disc_mark..]

    swap_out = IO::Memory.new
    b = o5msc_window swap_out
    swap_mark = swap_out.to_s.size

    b.screen = o5msc_screen
    swap_seq = swap_out.to_s[swap_mark..]

    # Both paths ran the extracted helper on the OLD device before either
    # caller's differing tail (disconnect closes+nils `@window` immediately;
    # `screen=` defers the close past the device swap) — so the escapes
    # written to the OLD device's output are byte-identical.
    disc_seq.should contain "\e[?1049l"
    swap_seq.should contain "\e[?1049l"
    disc_seq.should eq swap_seq

    a.destroy
    b.destroy
  end

  it "a live sibling skips teardown entirely on #disconnect" do
    shared_out = IO::Memory.new
    s = Crysterm::Screen.new(
      input: IO::Memory.new, output: shared_out, error: IO::Memory.new,
      width: 80, height: 24)
    a = Crysterm::Window.new(screen: s, default_quit_keys: false)
    b = Crysterm::Window.new(screen: s, default_quit_keys: false)
    begin
      mark = shared_out.to_s.size

      a.disconnect

      shared_out.to_s[mark..].should_not contain "\e[?1049l"
      b.connected?.should be_true
      s.input.as(IO::Memory).closed?.should be_false
    ensure
      a.destroy
      b.destroy
    end
  end

  it "a live sibling skips teardown entirely on #screen=" do
    shared_out = IO::Memory.new
    s = Crysterm::Screen.new(
      input: IO::Memory.new, output: shared_out, error: IO::Memory.new,
      width: 80, height: 24)
    a = Crysterm::Window.new(screen: s, default_quit_keys: false)
    b = Crysterm::Window.new(screen: s, default_quit_keys: false)
    begin
      mark = shared_out.to_s.size

      a.screen = o5msc_screen

      shared_out.to_s[mark..].should_not contain "\e[?1049l"
      b.connected?.should be_true
      s.input.as(IO::Memory).closed?.should be_false
    ensure
      a.destroy
      b.destroy
    end
  end
end

describe "OPT5 O5-18: BorderType#line_glyphs (macro-generated)" do
  it "matches every pre-refactor per-arm literal at the Unicode tier" do
    tier = Crysterm::Glyphs::Tier::Unicode

    BorderType::Solid.line_glyphs(tier).should eq(
      {tl: '┌', tr: '┐', bl: '└', br: '┘', h: '─', v: '│'})
    # `Fill` hits the same defensive `else` arm as `Solid`.
    BorderType::Fill.line_glyphs(tier).should eq(
      {tl: '┌', tr: '┐', bl: '└', br: '┘', h: '─', v: '│'})
    BorderType::Double.line_glyphs(tier).should eq(
      {tl: '╔', tr: '╗', bl: '╚', br: '╝', h: '═', v: '║'})
    BorderType::Dashed.line_glyphs(tier).should eq(
      {tl: '┌', tr: '┐', bl: '└', br: '┘', h: '┄', v: '┆'})
    BorderType::Dotted.line_glyphs(tier).should eq(
      {tl: '┌', tr: '┐', bl: '└', br: '┘', h: '┈', v: '┊'})
    BorderType::Rounded.line_glyphs(tier).should eq(
      {tl: '╭', tr: '╮', bl: '╰', br: '╯', h: '─', v: '│'})
  end
end

describe "OPT5 O5-35: Crysterm::Widget::Mutt.truncate shared by Pine/Mutt message indexes" do
  it "leaves a string at or under the limit unchanged" do
    Crysterm::Widget::Mutt.truncate("short", 20).should eq "short"
    Crysterm::Widget::Mutt.truncate("exact", 5).should eq "exact"
  end

  it "clips a longer string to len-1 chars plus a trailing ~" do
    Crysterm::Widget::Mutt.truncate("a very long sender name here", 10).should eq "a very lo~"
  end

  it "Pine::MessageIndex's rendered sender column is truncated via the shared helper" do
    long_name = "A Very Long Sender Name That Overflows The Column"
    idx = Crysterm::Widget::Pine::MessageIndex.new(
      [Crysterm::Widget::Pine::Message.new(long_name, "Subject")])
    row = idx.format_row(idx.messages[0], 0)
    row.should contain "~"
    row.should_not contain long_name
  end

  it "Mutt::MessageIndex's rendered sender column is truncated via the shared helper" do
    long_name = "A Very Long Sender Name That Overflows The Column"
    idx = Crysterm::Widget::Mutt::MessageIndex.new(
      [Crysterm::Widget::Mutt::Message.new(long_name, "Subject")])
    row = idx.format_row(idx.messages[0], 0)
    row.should contain "~"
    row.should_not contain long_name
  end
end
