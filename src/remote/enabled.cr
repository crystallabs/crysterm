module Crysterm
  # Runtime gate for the remote-control HTTP server.
  #
  # Compiling with `-Dremote` includes the remote subsystem, but the network
  # server still doesn't open until enabled at runtime, so a `-Dremote` binary
  # exposes no port by default. Enable via `CRYSTERM_REMOTE` env var or:
  #
  #     Crysterm::Remote.enabled = true
  #
  # Local layout-DOM features (`#load_layout`, `#to_layout_html`, declarative
  # actions) are unaffected — only `HTTPBridge#start` honors this gate.
  module Remote
    @@enabled : Bool? = nil

    # Forces the gate on/off, overriding the environment. `nil` restores
    # environment detection.
    def self.enabled=(value : Bool?)
      @@enabled = value
    end

    # Whether the HTTP server may start: an explicit `#enabled=` wins, otherwise
    # the presence of a non-empty `CRYSTERM_REMOTE` environment variable.
    def self.enabled? : Bool
      forced = @@enabled
      return forced unless forced.nil?
      !Crysterm::Config.remote_enabled.presence.nil?
    end
  end
end
