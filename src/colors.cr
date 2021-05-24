require "term_colors"

module Crysterm
  # Color-related functionality.
  #
  # At the moment this is just a wrapper around `TermColors` shard.
  module Colors
    extend ::TermColors
  end
end
