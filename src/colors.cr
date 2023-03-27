require "term_colors"

module Crysterm
  # Color-related functionality.
  #
  # At the moment this just imports methods from TermColors as this module's methods.
  #
  # Term-colors shard for the moment supports outputting up to 256 colors.
  # Adding TrueColor (16M colors) is on the TODO.
  #
  # In the future, when TrueColor support is added, everything in Crystem will be
  # adjusted to work with 16M colors without any conversion, and colors will be scaled
  # down to 256/16/8/2/1 only when necessary.
  module Colors
    extend ::TermColors
  end
end
