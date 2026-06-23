require "../../src/crysterm"

# Engine host for the HTTP/JSON-RPC bridge proof-of-concept.
#
# This is the only Crystal a deployment needs — in a real product it would be a
# generic `crysterm run app.html --css app.css` binary. It:
#   1. loads the layout from an HTML file (structure + geometry + actions),
#   2. applies the stylesheet (appearance),
#   3. starts the HTTP bridge,
#   4. hands the terminal to the render loop.
#
# Behavior lives entirely in an out-of-process handler in any language. Run:
#
#     crystal run -Dremote examples/remote/dom_http.cr   # terminal 1 (the UI)
#     examples/remote/dom_http.sh                         # terminal 2 (the logic, bash)
#
# Then press the buttons (Tab to move focus, Enter to activate).
class DomHttpDemo
  include Crysterm

  # Runtime opt-in to actually open the port (also settable via CRYSTERM_REMOTE).
  Crysterm::Remote.enabled = true

  here = __DIR__
  s = Screen.new title: "Crysterm over HTTP"
  s.stylesheet = File.read File.join(here, "dom_http.css")
  s.load_layout File.read File.join(here, "dom_http.html")

  s.find_by_id("save").try &.focus

  # `run` starts the HTTP server, wires events (declarative `on*` run in-process,
  # named ones go to the handler), takes over input, and blocks until a clean
  # `quit` (e.g. the Quit button's declarative `onclick="quit"`).
  Crysterm::HTTPBridge.new(s, port: 7000).run
end
