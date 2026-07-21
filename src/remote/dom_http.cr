require "http/server"
require "json"
require "crypto/subtle"

module Crysterm
  # HTTP/JSON-RPC bridge — "a browser for the terminal".
  #
  # Crysterm owns the TTY and renders; an out-of-process handler in any
  # language drives the UI over HTTP:
  #
  # * `GET /events` — a Server-Sent-Events stream. Each UI event is pushed as a
  #   JSON-RPC notification (`{"jsonrpc":"2.0","method":"event","params":...}`).
  #   A `: ping` comment is sent periodically as a keep-alive/disconnect probe.
  # * `POST /rpc` — a JSON-RPC request: a command (`setContent`, `addClass`,
  #   `focus`, `append`, `remove`, `quit`, ...) or a getter (`getContent`,
  #   `query`, `snapshot`). HTTP request/response pairing makes getters synchronous.
  #
  # Selectors are full CSS, so commands act on every match. Declarative `on*`
  # actions in the HTML run in-process; only *named* actions reach the handler.
  # An optional bearer token gates `/rpc` and `/events` for non-local binds.
  #
  # Concurrency: all widget mutation/reads marshal onto Crysterm's render fiber
  # via `Window#post` (`#on_ui`); events fan out with a non-blocking send so a
  # slow handler can't stall the UI.
  class HTTPBridge
    getter? running = false
    @on_quit : Proc(Nil)
    # The listening server, kept so `quit` can close it and its listener fibers.
    @server : HTTP::Server?

    def initialize(@window : Window, @host : String = "127.0.0.1", @port : Int32 = 7000, @token : String? = nil)
      @subscribers = [] of Channel(String)
      # Signals `run` to unblock and unwind. `quit` *closes* this rather than
      # sending: closing is idempotent and never blocks, so multiple `quit` calls
      # (RPC, declarative verb, embedder) can't fill a capacity-1 buffer and wedge
      # a fiber forever. `run` waits with `receive?`, which returns nil on close.
      @shutdown = Channel(Nil).new
      @wired = false
      # Runtime event subscriptions requested by a handler (selector, event),
      # re-applied across hot-reloads; `@event_wired` dedups per widget+event.
      @subscriptions = [] of Tuple(String, String)
      @event_wired = Set(String).new
      # Detachers for the live forwarders installed by `forward_event`, keyed by
      # "uid:event", so `unsubscribe` can stop delivery.
      @forwarders = {} of String => Proc(Nil)
      # The forwarder keys ("uid:event") wired for each `{selector, event}`
      # runtime subscription, captured at wire time. `unsubscribe` detaches by
      # this recorded set rather than re-resolving the selector: a widget that
      # stopped matching in the meantime would otherwise keep its forwarder
      # firing forever.
      @wired_keys = {} of Tuple(String, String) => Set(String)
      # Each declarative `on*` binding's current action plus its detacher, keyed
      # by "uid:event", so a repeated `rewire` can *replace* a changed action.
      # A flat "already wired" set couldn't tell a changed action from an
      # unchanged one.
      @declarative_wired = {} of String => Tuple(String, Proc(Nil))
      @on_quit = -> { quit; nil }
    end

    # Starts the HTTP server in a background fiber and wires the current tree's
    # events. Idempotent. Use `#run` for the full blocking lifecycle.
    #
    # No-op unless remote control is enabled at runtime: a `-Dremote` build opens
    # no port until enabled via `CRYSTERM_REMOTE` or `Crysterm::Remote.enabled =
    # true`.
    def start : Nil
      return if @running
      return unless Crysterm::Remote.enabled?
      rewire
      server = HTTP::Server.new { |context| handle context }
      # Bind BEFORE latching `@running`: if the bind raises (port in use),
      # `@running` must stay false so a later `start` can retry — otherwise the
      # bridge could never come up in this process.
      server.bind_tcp @host, @port
      @server = server
      @running = true
      # `listen` blocks until the server is closed. The rescue guards a race: a
      # very early `quit` can close the server before this fiber schedules, and
      # `listen` on a closed server raises — a benign shutdown, not a failure to
      # surface.
      spawn do
        server.listen
      rescue ex
        raise ex unless server.closed?
      end
    end

    # Full blocking lifecycle: start the server, paint, take over input, and
    # block until `#quit`. Replaces `Window#exec` for bridge-hosted apps so
    # shutdown unwinds cleanly (no `exit`).
    def run : Nil
      start
      @window.render
      @window.start_input
      # `receive?` returns nil when `quit` closes the channel — either way we fall
      # through and unwind cleanly.
      @shutdown.receive?
    end

    # Tears the app down cleanly: restores the terminal and unblocks `#run`.
    def quit : Nil
      @window.destroy rescue nil
      @server.try &.close rescue nil
      @server = nil
      @running = false
      # Close (don't send): idempotent and non-blocking, so repeated `quit` calls
      # can never wedge on a full buffer. Unblocks the `receive?` in `run`.
      @shutdown.close
    end

    # Replaces the whole layout from new HTML (hot-reload): clears the top-level
    # widgets, rebuilds from `html`, re-wires events, and repaints.
    #
    # Mutates directly and rings `render` (rather than marshalling via `#on_ui`):
    # the fswatch callback runs outside the render fiber, so a blocking
    # cross-fiber `receive` here would deadlock.
    def reload_layout(html : String) : Nil
      # `#destroy`, not `#remove`: a plain `Window#remove` only detaches the
      # subtree, leaking the previous layout's animation fibers and PTY child
      # processes on every hot-reload. `#destroy` recurses the subtree, stops
      # animations, kills PTYs, and unlinks from the window.
      @window.children.dup.each(&.destroy)
      @event_wired.clear       # old widgets are gone; re-wire subscriptions for the new tree
      @forwarders.clear        # their forwarders died with them (widgets destroyed)
      @wired_keys.clear        # ...and the forwarder keys we recorded for them are stale
      @declarative_wired.clear # ...and their declarative on* bindings
      # Hot-reload replaces the whole layout, so the new markup's inline `<style>`
      # replaces the previous one. A selector-less `append` instead merges, so it
      # never wipes the page's CSS.
      DOM.load html, @window, replace_styles: true
      rewire
      @window.render
    end

    # ---- event wiring -------------------------------------------------------

    private def rewire : Nil
      # Re-subscribe declarative + named action bindings for the current tree.
      # A failing binding is reported to handlers as an `error` event rather
      # than crashing the render/input fiber it fired on.
      DOM.each_binding(@window, @declarative_wired) do |widget, type, action, value|
        # A built-in declarative verb runs in-process; everything else is
        # forwarded to the handler. `declarative?` is true for any colon-bearing
        # action but `run` only handles a recognized verb, so an unrecognized
        # one (e.g. `navigate:home`) must still reach the handler — hence
        # checking `run`'s return, not just `declarative?`.
        unless DOM::Actions.declarative?(action) && DOM::Actions.run(action, widget, @window, @on_quit)
          publish_event type, widget, action, value: value
        end
      rescue ex
        publish_error "action #{action.inspect}: #{ex.message}"
      end
      # Re-apply any handler-requested runtime subscriptions to the new tree.
      @subscriptions.each { |selector, event| wire_subscription selector, event }
      # Forward raw keystrokes once (observation only; never `accept`ed).
      unless @wired
        @wired = true
        @window.on(Crysterm::Event::KeyPress) do |e|
          publish_event "keypress", char: e.char, key: e.key.try(&.to_s)
        end
      end
    end

    # Subscribes the widgets matching `selector` to `event`, forwarding each as
    # a plain `event` notification (no action). Deduped per widget+event so
    # it's safe to call repeatedly (e.g. on re-wire). Returns the match count.
    private def wire_subscription(selector : String, event : String) : Int32
      # An unknown event name wires nothing (`on_widget_event` no-ops), so report
      # 0 rather than the match count — otherwise `subscribe` claims N live
      # subscriptions while none can ever fire.
      return 0 unless DOM.known_event? event
      matches = match selector
      # Record every forwarder key we wire (or already have wired) for this
      # subscription so `unsubscribe` can detach by this set — not by re-running
      # the selector, which misses widgets that stopped matching since subscribe.
      keys = (@wired_keys[{selector, event}] ||= Set(String).new)
      matches.each do |widget|
        key = "#{widget.uid}:#{event}"
        keys << key
        next if @event_wired.includes? key
        @event_wired << key
        forward_event widget, event
      end
      matches.size
    end

    private def forward_event(widget : Widget, event : String) : Nil
      detacher = DOM.on_widget_event(widget, event) do |type, value|
        publish_event type, widget, value: value
      end
      @forwarders["#{widget.uid}:#{event}"] = detacher if detacher
    end

    # Drops every wiring entry belonging to a removed widget (keys are
    # `"uid:event"`), detaching live subscriptions as it goes, so a destroyed
    # subtree leaves no dangling declarative bindings or runtime forwarders
    # behind. `uids` is the set of removed widget uids (subtree included).
    private def prune_wiring(uids : Set(Int32)) : Nil
      removed = ->(key : String) { uids.includes? key.split(':', 2).first.to_i }
      @declarative_wired.reject! do |key, entry|
        next false unless removed.call key
        entry[1].call # detach the stale declarative binding
        true
      end
      @forwarders.reject! do |key, detacher|
        next false unless removed.call key
        detacher.call # detach the live forwarder
        true
      end
      @event_wired.select { |key| removed.call key }.each { |key| @event_wired.delete key }
      @wired_keys.each_value do |keys|
        keys.select { |key| removed.call key }.each { |key| keys.delete key }
      end
    end

    # ---- HTTP routing -------------------------------------------------------

    private def handle(context : HTTP::Server::Context) : Nil
      unless authorized? context
        context.response.status_code = 401
        context.response.print "unauthorized"
        return
      end
      case {context.request.method, context.request.path}
      when {"GET", "/events"} then handle_events context
      when {"POST", "/rpc"}   then handle_rpc context
      else
        context.response.status_code = 404
        context.response.print "not found"
      end
    end

    private def authorized?(context : HTTP::Server::Context) : Bool
      return true unless token = @token
      # Only the `X-Crysterm-Token` header is honored: a query-param token lands
      # in access logs, proxy logs and browser history. Compared in constant time
      # so a caller can't probe the secret byte-by-byte via response timing.
      presented = context.request.headers["X-Crysterm-Token"]? || ""
      Crypto::Subtle.constant_time_compare presented, token
    end

    private def handle_events(context : HTTP::Server::Context) : Nil
      channel = Channel(String).new(256)
      @subscribers << channel
      response = context.response
      response.content_type = "text/event-stream"
      response.headers["Cache-Control"] = "no-cache"
      # The status line, headers and a comment line are flushed immediately.
      # `HTTP::Server` sends headers lazily on first write, so an EventSource
      # client waiting for the stream to *open* before issuing RPCs would
      # otherwise stall until the first event or the 15 s ping.
      response.print ": connected\n\n"
      response.flush
      begin
        loop do
          select
          when message = channel.receive
            response.print "data: "
            response.print message
            response.print "\n\n"
          when timeout(15.seconds)
            response.print ": ping\n\n" # keep-alive + disconnect probe
          end
          response.flush
        end
      rescue IO::Error
        # handler disconnected
      ensure
        @subscribers.delete channel
      end
    end

    private def handle_rpc(context : HTTP::Server::Context) : Nil
      body = context.request.body.try(&.gets_to_end) || "{}"
      # The parse and shape extraction live *inside* the rescue: malformed JSON,
      # or valid-but-non-object JSON (`5`, `"x"`, `[]`), must come back as a
      # structured JSON-RPC error rather than an uncaught 500 / broken socket.
      id = nil
      begin
        request = JSON.parse body
        # A JSON-RPC request is an object; a bare scalar/array carries no
        # `id`/`method` and indexing it would raise, so reject it as -32600.
        raise InvalidRequest.new "request must be a JSON object" unless request.as_h?
        id = request["id"]?
        method = request["method"]?.try(&.as_s) || ""
        params = request["params"]?
        result = dispatch method, params
        respond context, id, result: result
      rescue JSON::ParseException
        respond_error context, id, -32_700, "parse error"
      rescue ex : InvalidRequest
        respond_error context, id, -32_600, ex.message
      rescue ex : UnknownMethod
        respond_error context, id, -32_601, ex.message
      rescue ex : BadParams
        respond_error context, id, -32_602, ex.message
      rescue ex
        respond_error context, id, -32_603, ex.message
      end
    end

    # Writes a JSON-RPC response envelope (`jsonrpc`/`id` header) to *context*,
    # yielding the open object builder so the caller adds `result`/`error`.
    # Shared by `#respond` and `#respond_error`.
    private def respond_envelope(context, id, &) : Nil
      context.response.content_type = "application/json"
      JSON.build(context.response) do |json|
        json.object do
          json.field "jsonrpc", "2.0"
          # JSON-RPC 2.0 requires `id` in every response; when the request id
          # couldn't be determined (parse error / invalid request) it must be
          # `null`, not omitted, so a conforming client can still match/validate
          # the error envelope instead of timing out.
          json.field("id") { id ? id.to_json(json) : json.null }
          yield json
        end
      end
    end

    private def respond(context, id, *, result : Int32 | String | Array(String)?) : Nil
      respond_envelope(context, id) { |json| json.field "result", result }
    end

    private def respond_error(context, id, code : Int32, message : String?) : Nil
      respond_envelope(context, id) do |json|
        json.field "error" do
          json.object do
            json.field "code", code
            json.field "message", message || "error"
          end
        end
      end
    end

    # ---- command dispatch ---------------------------------------------------

    class UnknownMethod < Exception; end

    class BadParams < Exception; end

    class InvalidRequest < Exception; end

    # Mutating commands return the number of widgets affected (so a handler can
    # tell "matched nothing" from "done"); getters return their value.
    private def dispatch(method : String, params : JSON::Any?) : Int32 | String | Array(String)?
      selector = params.try(&.["selector"]?).try(&.as_s)
      case method
      when "setContent"
        text = string_param params, "value"
        each_match(selector, &.set_content(text))
      when "getContent"
        on_ui { match(selector).first?.try(&.content) }
      when "setAttribute"
        name = string_param params, "name"
        attr_value = params.try(&.["value"]?).try(&.as_s)
        n = each_match(selector) { |w| set_attribute w, name, attr_value }
        # An `on*` change only updates `widget.dom_events`; the binding itself is
        # wired by `rewire`, so without this a new `onclick` would stay dormant
        # and a changed one keep firing the old action.
        on_ui { rewire } if name.starts_with?("on")
        n
      when "addClass"
        klass = string_param params, "class"
        each_match(selector, &.add_css_class(klass))
      when "removeClass"
        klass = string_param params, "class"
        each_match(selector, &.remove_css_class(klass))
      when "toggleClass"
        klass = string_param params, "class"
        each_match(selector, &.toggle_css_class(klass))
      when "focus"
        each_match(selector, &.focus)
      when "remove"
        # `#destroy`, not `detach_from_tree`: a bare detach only unlinks the
        # subtree, leaking its animation fibers and PTY child processes (the same
        # reason `reload_layout` uses `#destroy`). Destroy recurses, stops
        # animations, kills PTYs, and unlinks. The removed widgets are then
        # unreachable, so their wiring entries (keyed by uid, about to be dead)
        # are pruned first — collect the uids before destroying.
        n = 0
        on_ui do
          matches = match selector
          uids = Set(Int32).new
          matches.each { |w| w.self_and_each_descendant { |d| uids << d.uid } }
          prune_wiring uids
          matches.each &.destroy
          n = matches.size
          nil
        end
        on_ui { rewire } # re-wire on the render fiber, like every other mutation
        @window.render
        n
      when "append"
        html = string_param params, "html"
        built = on_ui do
          # A selector matching nothing returns 0 rather than falling back to a
          # top-level append, so a handler can tell "parent not found" from
          # "appended". No selector at all *is* a top-level append.
          if selector
            if parent = match(selector).first?
              n = DOM.load(html, @window, parent).size
              rewire # load + re-wire atomically on the render fiber
              n
            else
              0
            end
          else
            n = DOM.load(html, @window).size
            rewire
            n
          end
        end
        @window.render
        built
      when "subscribe"
        event = string_param params, "event"
        sel = selector || raise BadParams.new(%(missing param "selector"))
        # An unknown event is rejected up front; otherwise it would be recorded
        # and re-attempted — always a no-op — on every future `rewire`, with no
        # client error.
        raise BadParams.new(%(unknown event "#{event}")) unless DOM.known_event? event
        @subscriptions << {sel, event} unless @subscriptions.includes?({sel, event})
        on_ui { wire_subscription sel, event }
      when "unsubscribe"
        event = string_param params, "event"
        sel = selector || raise BadParams.new(%(missing param "selector"))
        @subscriptions.reject! { |s| s == {sel, event} }
        # Detach the live forwarders by the uids recorded at wire time, not by
        # re-resolving the selector: a widget that stopped matching between
        # subscribe and unsubscribe would otherwise keep its forwarder firing
        # forever.
        on_ui do
          if keys = @wired_keys.delete({sel, event})
            keys.each do |key|
              # Forwarders are deduped per widget+event, so two subscriptions
              # whose selectors overlap share one forwarder. Detach only when no
              # surviving subscription still records the key — its entry was
              # deleted above, so any remaining reference belongs to another one.
              next if @wired_keys.each_value.any? &.includes?(key)
              @event_wired.delete key
              @forwarders.delete(key).try &.call
            end
          end
        end
        0
      when "query"
        on_ui { match(selector).compact_map { |w| w.css_id.try { |id| "##{id}" } } }
      when "snapshot"
        on_ui { @window.to_layout_html }
      when "render"
        @window.render
        nil
      when "quit"
        spawn { quit }
        nil
      else
        raise UnknownMethod.new "unknown method: #{method}"
      end
    end

    # Applies one attribute with DOM `setAttribute` *replace* semantics. `class`
    # is special-cased to replace the whole user class list, matching a browser's
    # `setAttribute("class", …)`: `dom_apply`'s `class` handler is additive, built
    # for load-time replay, so routing through it here would only grow the list.
    private def set_attribute(widget : Widget, name : String, value : String?) : Nil
      if name == "class"
        widget.css_classes.dup.each { |c| widget.remove_css_class c }
        value.try &.split.each { |c| widget.add_css_class c unless c.empty? }
      else
        widget.dom_apply name, value
        # Backstop for the generated `dom_apply`: a runtime `setAttribute` must
        # repaint and re-match CSS even for keys whose setter is a plain ivar
        # write, so `:checked`/`[value]`-style selectors and damage tracking stay
        # correct.
        widget.invalidate_css
        widget.mark_dirty
      end
    end

    private def string_param(params : JSON::Any?, key : String) : String
      params.try(&.[key]?).try(&.as_s) || raise BadParams.new(%(missing param "#{key}"))
    end

    # ---- widget access (render-fiber-safe) ----------------------------------

    private def match(selector : String?) : Array(Widget)
      return [] of Widget unless selector
      @window.resolve_selector selector
    end

    private def each_match(selector : String?, &block : Widget ->) : Int32
      count = 0
      on_ui do
        matches = match selector
        matches.each { |w| block.call w }
        count = matches.size
        nil
      end
      @window.render
      count
    end

    private def on_ui(&block : -> T) : T forall T
      # Runs `block` on the render fiber and blocks until it produces a value. The
      # block's exception is *captured* and shipped back over the channel, then
      # re-raised on this (HTTP) fiber, avoiding two failures: a raise without a
      # send would hang this `receive` forever, and an unhandled raise on the
      # render fiber would kill it and freeze the UI.
      #
      # A destroyed window fails fast: its render loop has exited, so a `post`ed
      # block would never execute and the `receive` below would wedge this fiber
      # and every subsequent request.
      raise InvalidRequest.new "window is destroyed" if @window.destroyed?
      result = Channel(T | Exception).new(1)
      @window.post do
        begin
          result.send block.call
        rescue ex
          result.send ex
        end
        nil
      end
      value = result.receive
      raise value if value.is_a?(Exception)
      value
    end

    # ---- event fan-out ------------------------------------------------------

    # Surfaces an asynchronous engine-side failure to handlers as an `error`
    # event; synchronous command failures go back as JSON-RPC errors instead.
    private def publish_error(message : String?) : Nil
      publish_event "error", value: message
    end

    private def publish_event(type : String, widget : Widget? = nil, action : String? = nil,
                              *, value : String? = nil, char : Char? = nil, key : String? = nil) : Nil
      # No `/events` client connected: skip building the JSON and duping the list.
      return if @subscribers.empty?
      message = JSON.build do |json|
        json.object do
          json.field "jsonrpc", "2.0"
          json.field "method", "event"
          json.field "params" do
            json.object do
              json.field "type", type
              widget.try(&.css_id).try { |id| json.field "target", "##{id}" }
              action.try { |a| json.field "action", a }
              value.try { |v| json.field "value", v }
              char.try { |c| json.field "char", c.to_s }
              key.try { |k| json.field "key", k }
            end
          end
        end
      end
      @subscribers.dup.each do |channel|
        select
        when channel.send(message)
        else
          # subscriber buffer full — drop this event for them
        end
      end
    end
  end
end
