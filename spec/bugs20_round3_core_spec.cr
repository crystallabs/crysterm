require "./spec_helper"

include Crysterm

# Reachers for the per-arrange scratch state of the layout engines: every
# child widget a layout's own collections still refer to.
abstract class Crysterm::Layout
  class ChildValues
    def spec_widgets : Array(Crysterm::Widget)
      @els.dup
    end
  end

  def spec_held_widgets : Array(Crysterm::Widget)
    [] of Crysterm::Widget
  end

  class Box
    def spec_held_widgets : Array(Crysterm::Widget)
      @measured.spec_widgets
    end
  end

  class Dock
    def spec_held_widgets : Array(Crysterm::Widget)
      @bucket_top + @bucket_bottom + @bucket_left + @bucket_right + @bucket_center
    end
  end

  class Form
    def spec_held_widgets : Array(Crysterm::Widget)
      @row_children.dup
    end
  end

  class Grid
    def spec_held_widgets : Array(Crysterm::Widget)
      @placements.map { |pl| pl[0].as(Crysterm::Widget) }
    end
  end

  class Flow
    def spec_held_widgets : Array(Crysterm::Widget)
      [@prev_el, @last_rendered].compact
    end
  end

  class UniformGrid
    def spec_held_widgets : Array(Crysterm::Widget)
      super + @awidth_cache.spec_widgets
    end
  end
end

private def r3_layouts : Array(Crysterm::Layout)
  [
    Layout::HBox.new, Layout::VBox.new, Layout::Dock.new, Layout::Form.new,
    Layout::Grid.new, Layout::Wrap.new, Layout::Masonry.new,
    Layout::UniformGrid.new, Layout::Stack.new, Layout::Radial.new,
  ] of Crysterm::Layout
end

describe "Layout scratch state" do
  it "holds no child once the arrange has returned" do
    r3_layouts.each do |lay|
      s = headless_screen(40, 12)
      begin
        c = Widget::Box.new parent: s, top: 0, left: 0, width: 40, height: 12, layout: lay
        kids = Array.new(5) { |i| Widget::Box.new parent: c, width: 6, height: 2, content: "k#{i}" }
        s.repaint
        lay.spec_held_widgets.should be_empty

        # A child that leaves is not kept by a container that never arranges
        # again.
        c.remove kids[2]
        lay.spec_held_widgets.any?(&.same?(kids[2])).should be_false

        s.repaint
        lay.spec_held_widgets.should be_empty
      ensure
        s.destroy
      end
    end
  end

  it "arranges a dock and a form the same on every frame" do
    s = headless_screen(40, 12)
    dock = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 12, layout: Layout::Dock.new
    top = Widget::Box.new parent: dock, height: 2, content: "top",
      layout_hint: Layout::Dock::Hint.new(Layout::Dock::Region::Top)
    center = Widget::Box.new parent: dock, content: "center"
    form = Widget::Box.new parent: s, top: 0, left: 20, width: 20, height: 12, layout: Layout::Form.new
    label = Widget::Box.new parent: form, height: 1, content: "name"
    field = Widget::Box.new parent: form, height: 1, content: "value"
    s.repaint
    first = {top, center, label, field}.map { |w| lp = w.lpos.not_nil!; {lp.xi, lp.xl, lp.yi, lp.yl} }
    3.times { s.repaint }
    again = {top, center, label, field}.map { |w| lp = w.lpos.not_nil!; {lp.xi, lp.xl, lp.yi, lp.yl} }
    again.should eq first
    center.lpos.not_nil!.yi.should eq 2
  ensure
    s.try &.destroy
  end
end

describe "Window#destroy with a raising Destroy handler" do
  it "runs the handlers after it and raises once the window is gone" do
    s = headless_screen(20, 5)
    later = 0
    s.on(Crysterm::Event::Destroy) { raise "destroy handler" }
    s.on(Crysterm::Event::Destroy) { later += 1 }
    expect_raises(Exception, "destroy handler") { s.destroy }
    later.should eq 1
    s.destroyed?.should be_true
    Crysterm::Window.instances.any?(&.same?(s)).should be_false
    # The teardown ran once; a second destroy is a no-op.
    s.destroy
    later.should eq 1
  end
end

describe "Application.exec_all with a raising Destroy handler" do
  it "returns once every window is gone, raising the handler's error" do
    a = headless_screen(20, 5)
    b = headless_screen(20, 5)
    a.on(Crysterm::Event::Destroy) { raise "destroy handler" }
    result = Channel(Exception?).new 1
    spawn do
      Crysterm::Application.exec_all [a, b]
      result.send nil
    rescue ex
      result.send ex
    end
    # Mouse reporting goes on at the end of the last window's `start_input`:
    # `exec_all` is waiting from there.
    wait_until { b.mouse_enabled? }

    b.emit Crysterm::Event::KeyPress.new('q')
    error = nil.as(Exception?)
    select
    when error = result.receive
    when timeout(2.seconds)
      fail "exec_all did not return"
    end
    error.try(&.message).should eq "destroy handler"
    a.destroyed?.should be_true
    b.destroyed?.should be_true
  ensure
    a.try &.destroy rescue nil
    b.try &.destroy
  end

  it "returns when a window is destroyed directly and its handler raises" do
    a = headless_screen(20, 5)
    a.on(Crysterm::Event::Destroy) { raise "destroy handler" }
    finished = false
    spawn do
      Crysterm::Application.exec_all [a]
      finished = true
    end
    wait_until { a.mouse_enabled? }
    expect_raises(Exception, "destroy handler") { a.destroy }
    wait_until { finished }
  end
end

describe "Window#prompt and #ask on a window that is destroyed" do
  it "returns a cancellation when the window goes before the dialog is built" do
    s = headless_screen(40, 10)
    answer = Channel(String?).new 1
    asked = Channel(Bool).new 1
    spawn { answer.send s.prompt("Name: ") }
    spawn { asked.send s.ask("Sure?") }
    # Both callers have queued their job and parked.
    Fiber.yield
    s.destroy
    select
    when v = answer.receive
      v.nil?.should be_true
    when timeout(2.seconds)
      fail "prompt never returned"
    end
    select
    when v = asked.receive
      v.should be_false
    when timeout(2.seconds)
      fail "ask never returned"
    end
  ensure
    s.try &.destroy
  end

  it "returns a cancellation when the window goes with the dialog open" do
    s = headless_screen(40, 10)
    answer = Channel(String?).new 1
    spawn { answer.send s.prompt("Name: ") }
    wait_until { s.children.any?(Widget::InputDialog) }
    s.destroy
    select
    when v = answer.receive
      v.nil?.should be_true
    when timeout(2.seconds)
      fail "prompt never returned"
    end
  ensure
    s.try &.destroy
  end
end

describe "Window transient state for a removed subtree" do
  it "drops the multi-click target and the region return focus" do
    s = headless_screen(40, 10)
    panel = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 5
    btn = Widget::Button.new parent: panel, top: 1, left: 1, width: 8, height: 1, content: "ok"
    s.repaint
    lp = btn.lpos.not_nil!
    s.dispatch_mouse ::Tput::Mouse::Event.new(
      ::Tput::Mouse::Action::Down, ::Tput::Mouse::Button::Left, lp.xi, lp.yi, source: :program)
    s.click_count.should eq 1
    s.spec_last_click_target.same?(btn).should be_true
    s.spec_region_return_focus = btn

    s.remove panel
    s.spec_last_click_target.nil?.should be_true
    s.spec_region_return_focus.nil?.should be_true
    s.click_count.should eq 0
  ensure
    s.try &.destroy
  end
end

class Crysterm::Window
  def spec_last_click_target : Crysterm::Widget?
    @_last_click_target
  end

  def spec_region_return_focus : Crysterm::Widget?
    @region_return_focus
  end

  def spec_region_return_focus=(w : Crysterm::Widget?)
    @region_return_focus = w
  end
end

private def r3_csr_window(flags : Crysterm::OptimizationFlag) : Crysterm::Window
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 60, height: 20, optimization: flags)
end

# A coloured side bar (its own top-level widget) left of a narrower scrollable
# box; *marks* gives the side bar a different text on every row.
private def r3_csr_scene(s : Crysterm::Window, marks : Bool) : Crysterm::Widget::Box
  side = Widget::Box.new parent: s, top: 0, left: 0, width: 8, height: 12,
    style: Style.new(bg: "#005500")
  side.set_content((0..11).map { |i| "s#{i}" }.join('\n')) if marks
  box = Widget::Box.new parent: s, top: 0, left: 8, width: 30, height: 6, scrollable: true
  box.set_content((1..40).map { |i| "line #{i}" }.join('\n'))
  box
end

private def r3_same_cells(a : Crysterm::Window, b : Crysterm::Window, ctx : String) : Nil
  a.cell_rows.each_index do |y|
    la = a.cell_rows[y]
    lb = b.cell_rows[y]
    la.size.times do |x|
      ca = la[x]
      cb = lb[x]
      if ca.attr != cb.attr || ca.char != cb.char
        fail "#{ctx}: cell (#{y},#{x}) is #{ca.char.inspect}/#{ca.attr}, expected #{cb.char.inspect}/#{cb.attr}"
      end
    end
  end
end

describe "CSR scrolling of a widget narrower than the window" do
  {
    {"SmartCSR", Crysterm::OptimizationFlag::SmartCSR, false},
    {"FastCSR", Crysterm::OptimizationFlag::FastCSR, true},
  }.each do |(name, csr, marks)|
    it "leaves the widgets beside it intact under #{name} with damage tracking" do
      plain = r3_csr_window Crysterm::OptimizationFlag::None
      tracked = r3_csr_window csr | Crysterm::OptimizationFlag::DamageTracking
      pb = r3_csr_scene plain, marks
      tb = r3_csr_scene tracked, marks
      plain.repaint
      tracked.repaint
      out = tracked.output.as(IO::Memory)

      {1, 2, -1}.each_with_index do |d, step|
        out.clear
        fast = tracked.damage_fast_frames
        pb.scroll d, true
        tb.scroll d, true
        plain.repaint
        tracked.repaint
        # The scroll went through the line ops. The first one is painted by
        # the selective path for certain (later frames may fall back to a
        # full one on the engine's own timing).
        out.to_s.matches?(/\e\[\d+;\d+r/).should be_true
        tracked.damage_fast_frames.should eq fast + 1 if step == 0
        r3_same_cells tracked, plain, "#{name}, scroll #{d}"
        # What the terminal shows is the frame.
        tracked.flushed_lines.each_index do |y|
          tracked.cell_rows[y].size.times do |x|
            f = tracked.flushed_lines[y][x]
            c = tracked.cell_rows[y][x]
            fail "#{name}, scroll #{d}: terminal cell (#{y},#{x}) is stale" if f.attr != c.attr || f.char != c.char
          end
        end
      end
    ensure
      plain.try &.destroy
      tracked.try &.destroy
    end
  end
end

private def r3_link_window : Crysterm::Window
  s = headless_screen(30, 4)
  s.hyperlinks = Crysterm::AutoToggle::On
  s
end

describe "OSC 8 link registry" do
  it "reclaims the ids no cell carries any more" do
    s = r3_link_window
    Widget::Box.new parent: s, top: 0, left: 0, width: 30, height: 4, content: "text"
    s.repaint
    kept = s.link_id "https://kept.example/"
    s.cell_rows[0][0].link = kept
    s.repaint

    # Far more distinct URLs than there are ids, a few per frame.
    70_000.times do |i|
      id = s.link_id "https://example.com/#{i}"
      id.should_not eq 0
      s.cell_rows[1][i % 30].link = id
      s.repaint if i % 50 == 49
    end
    s.link_count.should be < 2 * Crysterm::Window::LINK_SWEEP_MIN + 100
    # The link still on screen kept its id and its target throughout.
    s.cell_rows[0][0].link.should eq kept
    s.link_url(kept).should eq "https://kept.example/"
    s.link_id("https://kept.example/").should eq kept
  ensure
    s.try &.destroy
  end

  it "keeps an id the terminal still shows until the next frame replaced it" do
    s = r3_link_window
    Widget::Box.new parent: s, top: 0, left: 0, width: 30, height: 4, content: "text"
    s.repaint
    old = s.link_id "https://old.example/"
    s.cell_rows[0][0].link = old
    s.repaint
    s.flushed_lines[0][0].link.should eq old

    # The cell drops the link; the frame that would tell the terminal has not
    # run. Fill the registry past its sweep point and sweep.
    s.cell_rows[0][0].link = 0_u16
    (Crysterm::Window::LINK_SWEEP_MIN + 10).times { |i| s.link_id "https://fill.example/#{i}" }
    s.spec_sweep_links
    s.link_url(old).should eq "https://old.example/"
    s.link_count.should eq 1

    # Once the terminal no longer shows it, the id is free and is reused.
    s.repaint
    s.flushed_lines[0][0].link.should eq 0
    s.spec_sweep_links
    s.link_url(old).nil?.should be_true
    s.link_id("https://new.example/").should eq old
    s.link_url(old).should eq "https://new.example/"
  ensure
    s.try &.destroy
  end

  it "emits the right target for a reused id" do
    s = r3_link_window
    Widget::Box.new parent: s, top: 0, left: 0, width: 30, height: 4, content: "text"
    s.repaint
    a = s.link_id "https://a.example/"
    s.cell_rows[0][0].link = a
    s.repaint
    s.cell_rows[0][0].link = 0_u16
    s.repaint
    s.spec_sweep_links

    out = s.output.as(IO::Memory)
    out.clear
    b = s.link_id "https://b.example/"
    b.should eq a
    s.cell_rows[0][1].link = b
    s.repaint
    out.to_s.should contain "https://b.example/"
    out.to_s.should_not contain "https://a.example/"
  ensure
    s.try &.destroy
  end
end

class Crysterm::Window
  def spec_sweep_links : Nil
    sweep_links
  end
end

describe "Window#register_clickable" do
  it "does not touch the terminal's mouse modes" do
    s = headless_screen(40, 10)
    s.enable_mouse
    s.repaint
    seq = s.tput.capture do
      3.times { |i| s.register_clickable Widget::Box.new(parent: s, top: i, left: 0, width: 6, height: 1) }
    end
    seq.should eq ""
    s.mouse_enabled?.should be_true
  ensure
    s.try &.destroy
  end

  it "leaves a pixel request made before the cell size was known to the device" do
    s = headless_screen(40, 10)
    s.enable_mouse pixels: :on
    s.tput.mouse_cell_pixels.nil?.should be_true
    s.screen.spec_apply_cell_pixels 8, 16
    s.tput.mouse_cell_pixels.should eq({8, 16})
  ensure
    s.try &.destroy
    spec_reset_cell_geometry_anchor
  end
end
