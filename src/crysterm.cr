require "./namespace"

# Main Crysterm module and namespace.
module Crysterm
  include Namespace

  # Creates and/or returns main `App`
  def self.app
    App.global true
  end

  # Creates and/or returns main `Widget::Screen`
  def self.screen
    Widget::Screen.global true
  end

end

require "./app"
