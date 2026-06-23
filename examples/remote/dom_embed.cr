require "../../src/crysterm"

# A NORMAL hand-coded Crysterm app that *additionally* opens the HTTP bridge so
# external handlers (any language) can receive events and drive the UI — without
# the `crysterm` CLI or loading from HTML.
#
# Build with the remote subsystem:  crystal run -Dremote examples/remote/dom_embed.cr
#
# The key is `HTTPBridge#start`: it opens the port and wires events but does NOT
# block, so the app continues to its usual `Screen#exec`. (`HTTPBridge#run` is
# just `start` + `exec` + clean shutdown bundled together.)
class DomEmbedDemo
  include Crysterm

  # Runtime opt-in to actually open the port (also settable via CRYSTERM_REMOTE).
  Crysterm::Remote.enabled = true

  s = Screen.new title: "Embedded HTTP bridge"

  status = Widget::Box.new \
    parent: s, top: 2, left: "center", width: 40, height: 3,
    content: "Drive me over http://127.0.0.1:7000"
  status.css_id = "status" # addressable by an external handler

  button = Widget::Button.new \
    parent: s, top: 6, left: "center", width: 14, height: 3,
    parse_tags: true, content: "{center}OK{/center}"
  button.css_id = "ok"
  button.focus

  # Open the bridge — non-blocking. Hand-built widgets already exist, so their
  # events can be subscribed to (e.g. POST /rpc subscribe {selector:"#ok",
  # event:"press"}), and commands like setContent target them by id.
  Crysterm::HTTPBridge.new(s, port: 7000).start

  # The app keeps full control of its own behavior in Crystal, as usual...
  button.on(Crysterm::Event::Press) do
    status.set_content "Pressed locally at #{Time.local}"
    s.render
  end
  s.on(Event::KeyPress) do |e|
    if e.char == 'q' || e.key == Tput::Key::CtrlQ
      s.destroy
      exit
    end
  end

  # ...and runs its normal loop. The HTTP server runs concurrently in a fiber.
  s.exec
end
