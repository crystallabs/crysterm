require "./core_application"
require "./tui_application"
require "./application"

module Crysterm
  #include Tput::Namespace
  include Namespace
  include Widget

  def self.app
    Application.global true
  end
end
