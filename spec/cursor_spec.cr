require "./spec_helper"

include Crysterm

# Artificial cursor rendering: `Screen#_artificial_cursor_attr` is the Crysterm
# equivalent of blessed's `Screen.prototype._cursorAttr`
# (blessed `lib/widgets/screen.js`). It computes the cell attribute (and an
# optional override glyph) used when `cursor.artificial?` is true and the cursor
# is painted into the rendered buffer by `Screen#draw`.
#
# A white-ish foreground (palette index 7) is forced for the predefined shapes,
# matching blessed (`attr |= 7 << 9`).
WHITE_FG = Attr.pack_color(Colors.palette_to_rgb(7))

# Computes {attr, ch} for the given shape against a zeroed base attribute, so
# the assertions below only see bits that the cursor logic itself sets.
#
# A fresh `Screen` is built inside each example on purpose: constructing one at
# file-load (top) level interferes with the spec runner's at_exit teardown (the
# same reason `width_layout_spec.cr` avoids real screens). We never call `exec`,
# so no terminal I/O loop is started.
def cursor_attr(shape, &)
  screen = Crysterm::Screen.new
  cursor = screen.cursor
  cursor.shape = shape
  yield cursor
  screen._artificial_cursor_attr cursor, 0_i64
end

def cursor_attr(shape)
  cursor_attr(shape) { }
end

describe "Screen#_artificial_cursor_attr" do
  describe "line shape" do
    it "overrides the glyph with a vertical bar and forces a white foreground" do
      attr, ch = cursor_attr Tput::Namespace::CursorShape::Line
      ch.should eq '│'
      Attr.fg(attr).should eq WHITE_FG
      # No flags are added for the line cursor.
      (Attr.flags(attr) & Attr::UNDERLINE).should eq 0
      (Attr.flags(attr) & Attr::INVERSE).should eq 0
    end
  end

  describe "underline shape" do
    it "sets the underline flag, white foreground, and no glyph override" do
      attr, ch = cursor_attr Tput::Namespace::CursorShape::Underline
      ch.should be_nil
      Attr.fg(attr).should eq WHITE_FG
      (Attr.flags(attr) & Attr::UNDERLINE).should_not eq 0
    end
  end

  describe "block shape" do
    it "sets the inverse flag, white foreground, and no glyph override" do
      attr, ch = cursor_attr Tput::Namespace::CursorShape::Block
      ch.should be_nil
      Attr.fg(attr).should eq WHITE_FG
      (Attr.flags(attr) & Attr::INVERSE).should_not eq 0
    end
  end

  describe "color overrides" do
    # blessed's `cursor.color` recolors the glyph (the foreground) for every
    # shape; the forced white is only a default. Here a line cursor is recolored.
    it "applies cursor.style.fg into the foreground field, overriding the default white" do
      attr, ch = cursor_attr(Tput::Namespace::CursorShape::Line) do |c|
        c.style.fg = "#ff0000"
      end
      ch.should eq '│'
      Attr.fg(attr).should eq Attr.pack_color(Colors.convert("#ff0000"))
      Attr.fg(attr).should_not eq WHITE_FG
    end

    it "applies cursor.style.bg into the background field for any shape" do
      attr, _ = cursor_attr(Tput::Namespace::CursorShape::Block) do |c|
        c.style.bg = "#0000ff"
      end
      Attr.bg(attr).should eq Attr.pack_color(Colors.convert("#0000ff"))
    end
  end

  describe "#cursor_color" do
    it "stores the color as the cursor's style.fg" do
      screen = Crysterm::Screen.new
      screen.cursor.artificial = true # avoid hardware terminal I/O
      screen.cursor_color "red"
      screen.cursor.style.fg.should eq "red"
    end
  end

  # `Screen#apply_cursor` is the single decision point: it routes a cursor
  # request to either the hardware cursor or the artificial (Crysterm-drawn) one,
  # based on the terminal's probed/static capabilities
  # (`Tput::Features#cursor_style?`). One screen is reused across the cases (and
  # `cursor.artificial` reset between them) to keep the number of constructed
  # `Screen`s — and the at_exit teardown they entail — to a minimum.
  describe "#apply_cursor hardware vs artificial decision" do
    it "chooses hardware or artificial based on shape and terminal support" do
      screen = Crysterm::Screen.new

      reset = ->(supported : Bool, shape : Tput::Namespace::CursorShape, blink : Bool) do
        screen.tput.features.cursor_style = supported
        screen.cursor.artificial = false
        screen.cursor.shape = shape
        screen.cursor.blink = blink
        screen.apply_cursor
        screen.cursor.artificial?
      end

      # The custom (None) shape has no hardware equivalent: always artificial,
      # even when the terminal can style its hardware cursor.
      reset.call(true, Tput::Namespace::CursorShape::None, false).should be_true

      # A styled shape stays on the hardware cursor when supported...
      reset.call(true, Tput::Namespace::CursorShape::Line, false).should be_false
      # ...and falls back to the artificial cursor when not.
      reset.call(false, Tput::Namespace::CursorShape::Line, false).should be_true

      # The default steady block needs no styling, so it stays on the hardware
      # cursor regardless of support.
      reset.call(false, Tput::Namespace::CursorShape::Block, false).should be_false
    end
  end

  # `None` is the custom cursor (blessed's "object shape"): the cursor is drawn
  # from its own `style` rather than as a predefined shape. This used to be
  # unreachable: `CursorShape` was a `@[Flags]` enum with `Block = 0`, so the
  # auto-generated `None` was also `0` (`Block == None`) and `shape.block?` was
  # always true, swallowing the custom branch. `None` and `Block` now have
  # distinct values, so the branch is reachable.
  describe "None / custom shape" do
    it "is distinct from Block" do
      Tput::Namespace::CursorShape::None.should_not eq Tput::Namespace::CursorShape::Block
    end

    it "honors style.char and style.fg for a custom cursor" do
      attr, ch = cursor_attr(Tput::Namespace::CursorShape::None) do |c|
        c.style.char = 'X'
        c.style.fg = "#00ff00"
      end
      ch.should eq 'X'
      Attr.fg(attr).should eq Attr.pack_color(Colors.convert("#00ff00"))
    end
  end
end
