require "term_colors"
require "crystallabs-helpers"
require "tput"

require "./macros"
require "./colors"
require "./helpers"

require "./application"
require "./methods"

require "./widget/*"

module Crysterm
  include Tput::Namespace

  def self.app
    Application.global
  end
end
