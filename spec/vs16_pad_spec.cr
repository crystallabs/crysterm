require "./spec_helper"

include Crysterm

# On a terminal that advances one column for a VS16 emoji-presentation
# cluster (Apple Terminal), the drawer pads the cluster with a space so the
# cursor stays in step with the cell index; elsewhere the cluster is emitted
# alone, as the terminal advances two columns for it.
describe "VS16 cluster padding" do
  it "pads a widened cluster only on a terminal that does not widen it" do
    {true, false}.each do |widens|
      s = headless_screen(12, 1)
      s.screen.vs16_widens = widens
      Widget::Label.new parent: s, left: 0, top: 0, width: 12, height: 1, content: "a⚠️b 💾c"
      s.repaint
      out = s.screen.output.as(IO::Memory).to_s
      if widens
        out.should contain "a⚠️b"
      else
        out.should contain "a⚠️ b"
      end
      # An emoji-presentation character is wide on its own: never padded.
      out.should contain "💾c"
      s.destroy
    end
  end

  it "follows the emulator identity unless overridden" do
    s = headless_screen(12, 1)
    from_identity = s.screen.tput.emulator?.try(&.vs16_widens?) != false
    s.vs16_widens?.should eq from_identity
    s.screen.vs16_widens = false
    s.vs16_widens?.should be_false
    s.screen.vs16_widens = true
    s.vs16_widens?.should be_true
    s.screen.vs16_widens = nil
    s.vs16_widens?.should eq from_identity
    s.destroy
  end
end
