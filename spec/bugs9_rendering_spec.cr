require "./spec_helper"

include Crysterm

# Regression specs for the BUGS9 Rendering & Screen fixes. Headless harness,
# same shape as `bugs8_layout_spec.cr`.

private def headless_screen(w = 20, h = 6)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

# A custom (`shape = None`) cursor renders "from the cursor's own style". Its
# `_artificial_cursor_attr` adopts the cursor's style *flags* whenever the style
# declares one — but the flag-adoption test omitted `italic` and `strike`, so a
# custom cursor styled with only italic (or only strikethrough) silently lost
# that flag while bold/underline/blink/reverse worked. Fixed to check all flags.
describe "BUGS9 artificial custom cursor keeps italic/strike style flags" do
  it "applies an italic-only custom cursor's italic flag" do
    s = headless_screen
    cur = Crysterm::Cursor.new
    cur.shape = Tput::CursorShape::None
    cur.style.italic = true
    attr, _ = s._artificial_cursor_attr(cur, Crysterm::Window::DEFAULT_ATTR)
    (Attr.flags(attr) & Attr::ITALIC).should_not eq(0)
  end

  it "applies a strike-only custom cursor's strikethrough flag" do
    s = headless_screen
    cur = Crysterm::Cursor.new
    cur.shape = Tput::CursorShape::None
    cur.style.strike = true
    attr, _ = s._artificial_cursor_attr(cur, Crysterm::Window::DEFAULT_ATTR)
    (Attr.flags(attr) & Attr::STRIKE).should_not eq(0)
  end

  it "still applies a bold-only custom cursor's bold flag (unregressed)" do
    s = headless_screen
    cur = Crysterm::Cursor.new
    cur.shape = Tput::CursorShape::None
    cur.style.bold = true
    attr, _ = s._artificial_cursor_attr(cur, Crysterm::Window::DEFAULT_ATTR)
    (Attr.flags(attr) & Attr::BOLD).should_not eq(0)
  end

  it "keeps the underlying cell flags when the custom cursor declares no flag" do
    s = headless_screen
    cur = Crysterm::Cursor.new
    cur.shape = Tput::CursorShape::None
    # Base cell carries UNDERLINE; a flagless custom cursor must not clear it.
    base = Attr.pack(Attr::UNDERLINE, Attr::COLOR_DEFAULT, Attr::COLOR_DEFAULT)
    attr, _ = s._artificial_cursor_attr(cur, base)
    (Attr.flags(attr) & Attr::UNDERLINE).should_not eq(0)
  end
end
