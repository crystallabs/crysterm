require "term_colors"

module Crysterm
  # Color-related functionality.
  #
  # At the moment this just imports methods from TermColors as this module's methods.
  module Colors
    extend ::TermColors
  end
end
