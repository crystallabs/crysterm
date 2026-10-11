require "./spec_helper"

# The per-frame box readers (`Style#border_view` & co.) hand out shared frozen
# zero boxes for a style with no box of its own, so rendering never
# materializes a `Border`/`Padding`/`Margin`/`Shadow` per style; the plain
# getters still materialize a mutable box for writers.
describe "Style box views" do
  it "renders a plain box without materializing any box sub-object" do
    s = headless_screen(40, 10)
    box = Crysterm::Widget::Box.new parent: s, width: 10, height: 3, content: "hi"
    3.times { s.repaint }
    st = box.style
    st.@border.should be_nil
    st.@padding.should be_nil
    st.@margin.should be_nil
    st.@shadow.should be_nil
    st.border_view.same?(Crysterm::Border::ZERO).should be_true
    st.padding_view.same?(Crysterm::Padding::ZERO).should be_true
    st.margin_view.same?(Crysterm::Margin::ZERO).should be_true
    st.shadow_view.same?(Crysterm::Shadow::ZERO).should be_true
    box.ileft.should eq 0
    box.mleft.should eq 0
  ensure
    s.try &.destroy
  end

  it "views follow a box once it is set or materialized" do
    st = Crysterm::Style.new
    st.padding.left = 2
    st.padding_view.same?(st.padding).should be_true
    st.padding_view.left.should eq 2
    st.border = true
    st.border_view.same?(st.border).should be_true
    st.border_view.any?.should be_true
    st.margin = {1, 2}
    st.margin_view.top.should eq 1
    st.shadow = true
    st.shadow_view.same?(st.shadow).should be_true
  end

  it "refuses side writes to the shared zero boxes" do
    expect_raises(Crysterm::SidedGeometry::FrozenError) { Crysterm::Padding::ZERO.left = 1 }
    expect_raises(Crysterm::SidedGeometry::FrozenError) { Crysterm::Margin::ZERO.top = 1 }
    expect_raises(Crysterm::SidedGeometry::FrozenError) { Crysterm::Border::ZERO.right = 1 }
    expect_raises(Crysterm::SidedGeometry::FrozenError) { Crysterm::Shadow::ZERO.bottom = 1 }
    Crysterm::Padding::ZERO.any?.should be_false
    Crysterm::Border::ZERO.any?.should be_false
    Crysterm::Shadow::ZERO.any?.should be_false
  end

  it "a dup of a style with no boxes keeps them unset" do
    st = Crysterm::Style.new(fg: "red")
    copy = st.dup
    copy.@border.should be_nil
    copy.@padding.should be_nil
    copy.border_view.same?(Crysterm::Border::ZERO).should be_true
  end

  it "paints a bordered and padded box exactly as before" do
    s = headless_screen(20, 5)
    box = Crysterm::Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 3, content: "hi",
      style: Crysterm::Style.new(border: true, padding: {0, 1})
    s.repaint
    (0...10).map { |x| s.cell_rows[0][x].char }.join.should eq "┌────────┐"
    (0...10).map { |x| s.cell_rows[1][x].char }.join.should eq "│ hi     │"
    box.ileft.should eq 2
  ensure
    s.try &.destroy
  end
end
