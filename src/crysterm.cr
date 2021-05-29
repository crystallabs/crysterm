require "json"
require "event_handler"

require "./ext"
require "./version"
require "./macros"
require "./namespace"
require "./event"
require "./app"
require "./helpers"
require "./colors"
require "./window"

require "./widget/*"

# Main Crysterm module and namespace.
module Crysterm
  include Namespace

  # Creates and/or returns main `App`
  def self.app
    App.global true
  end

  # Creates and/or returns main `Window`
  def self.window
    Window.global true
  end

  # TODO install WINCH handler

end
