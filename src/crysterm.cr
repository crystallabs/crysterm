require "toka"
require "i18n"

require "event_handler"
require "term_colors"
require "crystallabs-helpers"
require "tput"

require "./version"
require "./macros"
require "./colors"
require "./helpers"

require "./application"
require "./methods"

require "./widget/*"

module Crysterm
  include Tput::Namespace
  include Widget

  def self.app
    Application.global
  end
end
