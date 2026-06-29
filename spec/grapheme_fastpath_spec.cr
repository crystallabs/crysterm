require "./spec_helper"

include Crysterm

# The full_unicode single-codepoint fast path (`Widget#_render`): a lone
# codepoint with no combining/extending successor is stored as a `Char` with no
# `String`/overlay allocation, while a genuine multi-codepoint cluster still
# goes through `extend_grapheme` into the row's grapheme overlay. Verified by
# inspecting the rendered cells.

private def fu_render(content : String, width = 20)
  s = Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: width, height: 3)
  s.full_unicode = true
  pending! "full_unicode unavailable in this environment" unless s.full_unicode?
  Widget::Box.new parent: s, top: 0, left: 0, width: width, height: 3, content: content
  s._render
  s
end

describe "full_unicode single-codepoint fast path" do
  it "stores a plain codepoint as a char, no grapheme overlay (fast path)" do
    s = fu_render "abc"
    s.lines[0][0].char.should eq 'a'
    s.lines[0][0].grapheme_overlay.should be_nil
    s.lines[0][2].char.should eq 'c'
    s.lines[0][2].grapheme_overlay.should be_nil
  end

  it "lays a wide lone codepoint (CJK) across two cells without an overlay" do
    s = fu_render "漢z"
    s.lines[0][0].char.should eq '漢'
    s.lines[0][0].grapheme_overlay.should be_nil # fast path: no String built
    s.lines[0][0].width.should eq 2
    s.lines[0][1].continuation?.should be_true
    s.lines[0][2].char.should eq 'z'
  end

  it "still assembles a real combining cluster into the overlay" do
    s = fu_render "e\u{0301}x" # e + combining acute, then x
    s.lines[0][0].grapheme.should eq "e\u{0301}"
    s.lines[0][0].grapheme_overlay.should eq "e\u{0301}" # cluster path
    s.lines[0][1].char.should eq 'x'
    s.lines[0][1].grapheme_overlay.should be_nil # back to the fast path
  end
end
