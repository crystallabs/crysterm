require "http/server"
require "json"

module Crysterm
  # HTTP/JSON-RPC bridge — "a browser for the terminal".
  #
  # Crysterm owns the TTY and renders; an out-of-process handler in *any*
  # language drives the UI over HTTP. The bridge is the engine side:
  #
  # * `GET /events` — a Server-Sent-Events stream. Each UI event is pushed as a
  #   JSON-RPC notification (`{"jsonrpc":"2.0","method":"event","params":...}`),
  #   read line by line (e.g. `curl -sN .../events`). A `: ping` comment is sent
  #   periodically as a keep-alive / disconnect probe.
  # * `POST /rpc` — a JSON-RPC request: a command (`setContent`, `addClass`,
  #   `focus`, `append`, `remove`, `quit`, ...) or a getter (`getContent`,
  #   `query`, `snapshot`). HTTP request/response pairing gives correlation, so
  #   getters are synchronous.
  #
  # Selectors are full CSS (via `Screen#resolve_selector`), so commands act on
  # every match. Declarative `on*` actions in the HTML run in-process (see
  # `DOM::Actions`); only *named* actions reach the handler. Optional bearer
  # token gates `/rpc` and `/events` for non-local binds.
  #
  # Concurrency: all widget mutation/reads marshal onto Crysterm's render fiber
  # via `Screen#post` (`#on_ui`); events fan out with a non-blocking send so a
  # slow handler can't stall the UI.
  class HTTPBridge
    getter? running = false
    @on_quit : Proc(Nil)

    def initialize(@screen : Screen, @host : String = "127.0.0.1", @port : Int32 = 7000, @token : String? = nil)
      @subscribers = [] of Channel(String)
      @shutdown = Channel(Nil).new(1)
      @wired = false
      # Runtime event subscriptions requested by a handler (selector, event),
      # re-applied across hot-reloads; `@event_wired` dedups per widget+event.
      @subscriptions = [] of Tuple(String, String)
      @event_wired = Set(String).new
      # Dedups the declarative `on*` bindings across repeated `rewire`s (each
      # `append`/`remove` re-runs it), so a binding is subscribed exactly once.
      @declarative_wired = Set(String).new
      @on_quit = -> { quit; nil }
    end

    # Starts the HTTP server in a background fiber and wires the current tree's
    # events. Idempotent. Use `#run` for the full blocking lifecycle.
    #
    # No-op unless remote control is enabled at runtime (see `Crysterm::Remote`)
    # — so an app/binary built with `-Dremote` opens no port until explicitly
    # enabled via `CRYSTERM_REMOTE` or `Crysterm::Remote.enabled = true`.
    def start : Nil
      return if @running
      return unless Crysterm::Remote.enabled?
      @running = true
      rewire
      server = HTTP::Server.new { |context| handle context }
      server.bind_tcp @host, @port
      spawn { server.listen }
    end

    # Full blocking lifecycle: start the server, paint, take over input, and
    # block until `#quit`. Replaces `Screen#exec` for bridge-hosted apps so
    # shutdown unwinds cleanly (no `exit`).
    def run : Nil
      start
      @screen.render
      @screen.listen
      @shutdown.receive
    end

    # Tears the app down cleanly: restores the terminal and unblocks `#run`.
    def quit : Nil
      @screen.destroy rescue nil
      @shutdown.send(nil) rescue nil
    end

    # Replaces the whole layout from new HTML (hot-reload): clears the top-level
    # widgets, rebuilds from `html`, re-wires events, and repaints.
    #
    # Mutates directly and rings `render` (rather than marshalling via `#on_ui`),
    # mirroring the stylesheet hot-reload path: the fswatch callback runs outside
    # the render fiber, so a blocking cross-fiber `receive` here would deadlock.
    def reload_layout(html : String) : Nil
      @screen.children.dup.each { |child| @screen.remove child }
      @event_wired.clear       # old widgets are gone; re-wire subscriptions for the new tree
      @declarative_wired.clear # ...and their declarative `on*` bindings
      DOM.load html, @screen
      rewire
      @screen.render
    end

    # ---- event wiring -------------------------------------------------------

    private def rewire : Nil
      # Re-subscribe declarative + named action bindings for the current tree.
      # A failing binding is reported to handlers as an `error` event rather than
      # crashing the render/input fiber it fired on.
      DOM.each_binding(@screen, @declarative_wired) do |widget, type, action, value|
        begin
          # A built-in declarative verb runs in-process; everything else is a
          # named action forwarded to the handler. `declarative?` is true for any
          # colon-bearing action, but `run` only *handles* a recognized verb (and
          # reports so via its return) — so a colon-bearing action whose verb is
          # NOT built-in (e.g. `navigate:home`, `open:file.txt`) must still reach
          # the handler. Without the `run` result check it was classified
          # declarative, matched no verb, and was silently dropped.
          unless DOM::Actions.declarative?(action) && DOM::Actions.run(action, widget, @screen, @on_quit)
            publish_event type, widget, action, value: value
          end
        rescue ex
          publish_error "action #{action.inspect}: #{ex.message}"
        end
      end
      # Re-apply any handler-requested runtime subscriptions to the new tree.
      @subscriptions.each { |selector, event| wire_subscription selector, event }
      # Forward raw keystrokes once (observation only; never `accept`ed).
      unless @wired
        @wired = true
        @screen.on(Crysterm::Event::KeyPress) do |e|
          publish_event "keypress", char: e.char, key: e.key.try(&.to_s)
        end
      end
    end

    # Subscribes the widgets matching `selector` to `event`, forwarding each as a
    # plain `event` notification (no action). Deduped per widget+event so it is
    # safe to call repeatedly (e.g. on re-wire). Returns the match count.
    private def wire_subscription(selector : String, event : String) : Int32
      matches = match selector
      matches.each do |widget|
        key = "#{widget.uid}:#{event}"
        next if @event_wired.includes? key
        @event_wired << key
        forward_event widget, event
      end
      matches.size
    end

    private def forward_event(widget : Widget, event : String) : Nil
      DOM.on_widget_event(widget, event) do |type, value|
        publish_event type, widget, value: value
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
      context.request.headers["X-Crysterm-Token"]? == token ||
        context.request.query_params["token"]? == token
    end

    private def handle_events(context : HTTP::Server::Context) : Nil
      channel = Channel(String).new(256)
      @subscribers << channel
      response = context.response
      response.content_type = "text/event-stream"
      response.headers["Cache-Control"] = "no-cache"
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
      request = JSON.parse body
      id = request["id"]?
      method = request["method"]?.try(&.as_s) || ""
      params = request["params"]?

      begin
        result = dispatch method, params
        respond context, id, result: result
      rescue ex : UnknownMethod
        respond_error context, id, -32_601, ex.message
      rescue ex : BadParams
        respond_error context, id, -32_602, ex.message
      rescue ex
        respond_error context, id, -32_603, ex.message
      end
    end

    private def respond(context, id, *, result : Int32 | String | Array(String) | Nil) : Nil
      context.response.content_type = "application/json"
      JSON.build(context.response) do |json|
        json.object do
          json.field "jsonrpc", "2.0"
          id.try { |v| json.field "id", v }
          json.field "result", result
        end
      end
    end

    private def respond_error(context, id, code : Int32, message : String?) : Nil
      context.response.content_type = "application/json"
      JSON.build(context.response) do |json|
        json.object do
          json.field "jsonrpc", "2.0"
          id.try { |v| json.field "id", v }
          json.field "error" do
            json.object do
              json.field "code", code
              json.field "message", message || "error"
            end
          end
        end
      end
    end

    # ---- command dispatch ---------------------------------------------------

    class UnknownMethod < Exception; end

    class BadParams < Exception; end

    # Returns a structured result. Mutating commands return the number of
    # widgets they affected (so a handler can tell "matched nothing" from
    # "done"); getters return their value.
    private def dispatch(method : String, params : JSON::Any?) : Int32 | String | Array(String) | Nil
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
        each_match(selector) { |w| w.dom_apply name, attr_value }
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
        n = each_match(selector, &.remove_from_parent)
        on_ui { rewire } # re-wire on the render fiber, like every other mutation
        n
      when "append"
        html = string_param params, "html"
        built = on_ui do
          parent = selector ? match(selector).first? : nil
          n = (parent ? DOM.load(html, @screen, parent) : DOM.load(html, @screen)).size
          rewire # load + re-wire atomically on the render fiber
          n
        end
        @screen.render
        built
      when "subscribe"
        event = string_param params, "event"
        sel = selector || raise BadParams.new(%(missing param "selector"))
        @subscriptions << {sel, event} unless @subscriptions.includes?({sel, event})
        on_ui { wire_subscription sel, event }
      when "unsubscribe"
        event = string_param params, "event"
        sel = selector || raise BadParams.new(%(missing param "selector"))
        @subscriptions.reject! { |s| s == {sel, event} }
        0 # already-attached handlers detach on the next reload
      when "query"
        on_ui { match(selector).compact_map { |w| w.css_id.try { |id| "##{id}" } } }
      when "snapshot"
        on_ui { @screen.to_layout_html }
      when "render"
        @screen.render
        nil
      when "quit"
        spawn { quit }
        nil
      else
        raise UnknownMethod.new "unknown method: #{method}"
      end
    end

    private def string_param(params : JSON::Any?, key : String) : String
      params.try(&.[key]?).try(&.as_s) || raise BadParams.new(%(missing param "#{key}"))
    end

    # ---- widget access (render-fiber-safe) ----------------------------------

    private def match(selector : String?) : Array(Widget)
      return [] of Widget unless selector
      @screen.resolve_selector selector
    end

    private def each_match(selector : String?, &block : Widget ->) : Int32
      count = 0
      on_ui do
        matches = match selector
        matches.each { |w| block.call w }
        count = matches.size
        nil
      end
      @screen.render
      count
    end

    private def on_ui(&block : -> T) : T forall T
      result = Channel(T).new(1)
      @screen.post do
        result.send block.call
        nil
      end
      result.receive
    end

    # ---- event fan-out ------------------------------------------------------

    # Surfaces an asynchronous engine-side failure to handlers as an `error`
    # event (synchronous command failures go back as JSON-RPC errors instead).
    private def publish_error(message : String?) : Nil
      publish_event "error", value: message
    end

    private def publish_event(type : String, widget : Widget? = nil, action : String? = nil,
                              *, value : String? = nil, char : Char? = nil, key : String? = nil) : Nil
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
