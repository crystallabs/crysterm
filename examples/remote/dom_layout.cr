require "../../src/crysterm"

# Demonstrates defining a GUI's *layout* in an HTML file and wiring up its
# *behavior* in code — the same split as the web (HTML structure, CSS styling,
# code for behavior).
#
# The layout DOM is part of the remote subsystem, so build with `-Dremote`:
#     crystal run -Dremote examples/remote/dom_layout.cr
# (No HTTP server is opened here — only local layout loading is used.)
#
# The structure + geometry come from `to_layout_html`/`DOM.load`; appearance
# comes from the stylesheet; the button's handler is attached after loading by
# looking the widget up via its `id`.
class MyProg
  include Crysterm

  s = Screen.new title: "DOM layout demo"

  s.stylesheet = <<-CSS
    Box {
      color: white;
      background-color: #222244;
    }
    #hello {
      color: yellow;
      background-color: blue;
      border: solid cyan;
    }
    Button {
      color: black;
      background-color: gray;
      border: solid white;
    }
    Button:focus {
      background-color: green;
      font-weight: bold;
    }
  CSS

  # The layout — normally `s.load_layout_file "ui.html"`; inlined here so the
  # example is self-contained.
  s.load_layout <<-HTML
    <w-screen>
      <w-box id="hello" top="center" left="center" width="30" height="7"
             parse-tags="true"
             content="{center}Loaded from {bold}HTML{/bold}!\nPress Tab, then q.{/center}"></w-box>
      <w-button id="ok" top="center+5" left="center" width="14" height="3"
                parse-tags="true" content="{center}OK{/center}"></w-button>
    </w-screen>
  HTML

  # Wire behavior to the loaded widgets by id.
  s.find_by_id("ok").try &.focus
  s.find_by_id("ok").try &.on(Crysterm::Event::Click) do
    s.find_by_id("hello").try &.set_content("{center}Clicked!{/center}")
    s.render
  end

  s.on(Event::KeyPress) do |e|
    if e.char == 'q' || e.key == Tput::Key::CtrlQ
      s.destroy
      exit
    end
    s.focus_next if e.key == Tput::Key::Tab
  end

  s.exec
end
