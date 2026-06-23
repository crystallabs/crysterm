require "option_parser"
require "../../crysterm"

# `crysterm` CLI — run a terminal GUI defined entirely in HTML + CSS, with
# behavior supplied by a handler process in any language over the HTTP bridge.
# This is the entry point that makes the framework usable without writing Crystal.
#
#   crystal build src/bin/crysterm.cr -Dremote -o crysterm
#   crysterm run app.html --css app.css --handler "python3 app.py" --watch
#
# Requires `-Dremote` (the remote subsystem). Structure + geometry + named
# actions live in the .html; appearance in the .css; behavior in the handler
# (or, for simple apps, in declarative `on*` actions needing no handler at all).
{% if flag?(:remote) %}

module Crysterm::CLI
  extend self

  def run(argv = ARGV)
    layout_path = nil.as(String?)
    css_path = nil.as(String?)
    handler_cmd = nil.as(String?)
    host = "127.0.0.1"
    port = 7000
    token = nil.as(String?)
    watch = false

    parser = OptionParser.new do |o|
      o.banner = "Usage: crysterm run <app.html> [options]"
      o.on("--css PATH", "Stylesheet to apply") { |v| css_path = v }
      o.on("--handler CMD", "Handler process to spawn (any language)") { |v| handler_cmd = v }
      o.on("--host HOST", "Bind host (default 127.0.0.1)") { |v| host = v }
      o.on("--port PORT", "Bind port (default 7000)") { |v| port = v.to_i }
      o.on("--token TOKEN", "Require this bearer token on /rpc and /events") { |v| token = v }
      o.on("--watch", "Hot-reload the .html/.css on change") { watch = true }
      o.on("-h", "--help", "Show help") { puts o; exit 0 }
      o.unknown_args do |args|
        # Accept `crysterm run app.html` and `crysterm app.html`.
        args = args[1..] if args.first? == "run"
        layout_path = args.first?
      end
    end
    parser.parse argv

    unless (lp = layout_path) && File.exists?(lp)
      STDERR.puts layout_path ? "No such file: #{layout_path}" : parser
      exit 1
    end

    # Running the server command *is* the runtime opt-in.
    Crysterm::Remote.enabled = true

    screen = Screen.new
    if cp = css_path
      # `load_stylesheet` records the external source and (unless disabled)
      # hot-reloads the file itself; inline `<style>` from the layout composes
      # with it. The layout's own fswatch handles structure reload below.
      screen.auto_reload_stylesheet = false unless watch
      screen.load_stylesheet cp
    end
    screen.load_layout File.read lp

    bridge = HTTPBridge.new screen, host: host, port: port, token: token

    if watch
      CSS::FileWatcher.watch(lp) { bridge.reload_layout File.read(lp) rescue nil }
    end

    handler = spawn_handler handler_cmd, host, port, token

    begin
      bridge.run
    ensure
      handler.try { |h| h.terminate rescue nil }
    end
  end

  # Spawns the user's handler, passing connection details via env so the handler
  # needs no hardcoded host/port.
  private def spawn_handler(cmd : String?, host : String, port : Int32, token : String?) : Process?
    return nil unless cmd
    env = {"CRYSTERM_HOST" => "http://#{host}:#{port}"}
    env["CRYSTERM_TOKEN"] = token if token
    Process.new cmd, shell: true, env: env, input: Process::Redirect::Close,
      output: Process::Redirect::Inherit, error: Process::Redirect::Inherit
  end
end

Crysterm::CLI.run

{% else %}
  STDERR.puts "crysterm: built without remote control. Rebuild with -Dremote to use the CLI."
  exit 1
{% end %}
