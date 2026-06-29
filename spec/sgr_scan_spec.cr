require "./spec_helper"

include Crysterm

# Guards the SGR-scanning optimization (#7 in widget_rendering, #8 in
# widget_content/_parse_attr): matching `SGR_REGEX` anchored *in place* at an
# escape position must find exactly the same sequence, at the same position, as
# the previous "slice the tail, then match the ^-anchored regex" approach —
# without allocating the tail substring. Pure string/regex, so it needs no
# Window (which the spec runner can't tear down cleanly).
describe "SGR in-place anchored scanning" do
  sgr = Crysterm::Widget::SGR_REGEX
  sgr_at = Crysterm::Widget::SGR_REGEX_AT_BEGINNING

  samples = [
    "",
    "plain text, no codes",
    "\e[31mred\e[0m",
    "a\e[1;31mb\e[39mc",
    "\e[38;2;255;136;0mtruecolor\e[0m",
    "héllo\e[1mX\e[0m中\e[32mZ", # multibyte text interleaved with codes
    "trailing\e[0m",
    "\e[m",               # empty params
    "\e[notSGR mletters", # a bare ESC that is not a valid SGR sequence
  ]

  it "anchored match equals slice + ^-match at every escape position" do
    samples.each do |s|
      s.each_char_with_index do |ch, i|
        next unless ch == '\e'
        old = s[i..].match(sgr_at).try &.[0]
        new = sgr.match(s, i, options: Regex::MatchOptions::ANCHORED).try &.[0]
        new.should eq old
      end
    end
  end
end
