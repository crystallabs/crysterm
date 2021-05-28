require "json"
require "event_handler"

require "./version"
require "./macros"
require "./namespace"
require "./event"
require "./app"
require "./helpers"
require "./colors"
require "./screen"

require "./widget/*"

# Main Crysterm module and namespace.
module Crysterm
  include Namespace

  # Creates and/or returns main `App`
  def self.app
    App.global true
  end

  # Creates and/or returns main `Screen`
  def self.screen
    Screen.global true
  end

end
