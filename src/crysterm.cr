require "term_colors"
require "crystallabs-helpers"

require "./macros"
require "./colors"
require "./helpers"

require "./application"
require "./methods"

require "./widget/*"

module Crysterm
  def self.app
    Application.global
  end
end
