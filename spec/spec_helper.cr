require "spec"
require "../src/crysterm"
require "../src/helpers"

# When built with -Dremote, let the bridge specs actually open their ports.
{% if flag?(:remote) %}
  Crysterm::Remote.enabled = true
{% end %}
