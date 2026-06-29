module Crysterm
  # Runtime gate for the remote-control HTTP server.
  #
  # Compiling with `-Dremote` *includes* the remote subsystem (HTML layout DOM +
  # the HTTP bridge), but the network server still does not open until it is
  # enabled at runtime — so a binary that ships with `-Dremote` exposes no port
  # by default. Enable it either by setting `CRYSTERM_REMOTE` in the environment
  # or programmatically:
  #
  #     Crysterm::Remote.enabled = true
  #
  # The local layout-DOM features (`#load_layout`, `#to_layout_html`, declarative
  # actions, …) are unaffected by this gate — only `HTTPBridge#start` honors it.
  module Remote
    @@enabled : Bool? = nil

    # Forces the gate on/off, overriding the environment. `nil` restores
    # environment-based detection.
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
