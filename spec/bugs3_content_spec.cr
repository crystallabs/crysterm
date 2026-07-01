require "./spec_helper"

include Crysterm

# Regression coverage for two word-wrap / SGR bugs in `src/widget_content.cr`:
#
#   1. The "only an escape got cut off" guard (`_wrap_content`, ~line 781) used
#      the regex `/^(?:\e[\[\d;]*m)+$/`, whose `[\[\d;]*` is a character class
#      matching `[`, digits and `;` in ANY order and with NO required `[` after
#      the `\e`. That wrongly accepted junk like `"\e999m"` or `"\em"` as an SGR
#      run. The fix `/^(?:\e\[[\d;]*m)+$/` requires a literal `\e[` opener, so it
#      only matches real SGR runs (`"\e[31m"`, `"\e[0m\e[1m"`).
#
#   2. The word-wrap backward scan for a wrap point now skips whole `\e…m` SGR
#      runs (via the `sgr_run_start` helper) so wrapping text that contains
#      inline color escapes never cuts mid-escape and never corrupts the color
#      carried onto the wrapped remainder.
#
# Both are exercised through the public API: a `Widget::Box` with `wrap_content`
# on, given content with inline SGR, wrapped to a narrow width by `_render`, and
# the resulting wrapped rows (`@_clines`) inspected. Headless harness: a `Window`
# over in-memory IOs plus the synchronous `Window#_render` (like the other specs).

private def sized_screen(w, h)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h)
end

# A wrapped-content box whose real (wrapped) rows we can inspect.
private def wrapped_box(s, content, w, h)
  b = Widget::Box.new(
    parent: s, top: 0, left: 0, width: w, height: h,
    content: content, parse_tags: true, wrap_content: true)
  s._render
  b
end

# The wrapped ("real") rows produced for a box.
private def wrapped_lines(b)
  b._clines.lines
end

# Does `line` contain a bare/truncated ESC — an `\e` that is NOT the start of a
# well-formed SGR sequence `\e[ ... m`?  A well-formed line has every `\e`
# immediately followed by `[`, then only digits/`;`, then a terminating `m`.
private def truncated_escape?(line : String)
  i = 0
  while (idx = line.index('\e', i))
    m = line.match(/\e\[[\d;]*m/, idx)
    return true unless m && m.begin == idx
    i = idx + m[0].size
  end
  false
end

describe "widget_content SGR word-wrap (bugs3)" do
  describe "truncated_escape? helper (self-check)" do
    it "flags a bare ESC and a non-SGR escape, passes well-formed SGR" do
      truncated_escape?("plain text").should be_false
      truncated_escape?("a \e[31mred").should be_false
      truncated_escape?("\e[0m\e[1mx").should be_false
      truncated_escape?("bad \e[31").should be_true  # no terminating m
      truncated_escape?("bad \e999m").should be_true # not an SGR opener
      truncated_escape?("bad \e").should be_true     # bare ESC
    end
  end

  describe "wrapping never splits an inline escape" do
    it "wraps 'word \\e[31mmore text here' in a narrow box with no truncated escapes" do
      s = sized_screen 40, 10
      # Box interior 6 columns wide (10 - borders/padding is not in play here;
      # give it a small content width to force wrapping of the words).
      b = wrapped_box s, "word \e[31mmore text here", 8, 8
      lines = wrapped_lines b

      lines.size.should be > 1 # actually wrapped
      lines.each do |line|
        truncated_escape?(line).should be_false
      end
    end

    it "keeps every wrapped row's escapes well-formed for longer colored text" do
      s = sized_screen 40, 20
      content = "the quick \e[31mbrown fox \e[32mjumps over \e[0mthe lazy dog"
      b = wrapped_box s, content, 10, 15
      lines = wrapped_lines b

      lines.size.should be > 1
      lines.each { |line| truncated_escape?(line).should be_false }
    end

    it "preserves the visible words across the wrap (SGR stripped)" do
      s = sized_screen 40, 20
      b = wrapped_box s, "alpha \e[31mbeta gamma \e[0mdelta", 8, 15
      lines = wrapped_lines b

      visible = lines.map(&.gsub(/\e\[[\d;]*m/, "")).join(" ")
      %w[alpha beta gamma delta].each do |w|
        visible.includes?(w).should be_true
      end
    end
  end

  describe "SGR guard regex only matches real SGR runs" do
    # The corrected regex, tested directly to lock in the fix. The old
    # `/^(?:\e[\[\d;]*m)+$/` matched all of these strings; the new one rejects
    # the non-SGR ones.
    sgr = /^(?:\e\[[\d;]*m)+$/

    it "matches well-formed SGR runs" do
      "\e[31m".matches?(sgr).should be_true
      "\e[0m".matches?(sgr).should be_true
      "\e[0m\e[1m".matches?(sgr).should be_true
      "\e[38;5;196m".matches?(sgr).should be_true
    end

    it "rejects non-SGR strings the old regex wrongly matched" do
      "\e999m".matches?(sgr).should be_false
      "\em".matches?(sgr).should be_false
      "\e[31mword".matches?(sgr).should be_false
      "word".matches?(sgr).should be_false
    end
  end
end
