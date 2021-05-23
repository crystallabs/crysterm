require "./namespace"

# Main Crysterm module and namespace.
module Crysterm
  include Namespace

  # Helper to create or return the main `App`
  def self.app
    App.global true
  end
end

require "./app"

#    class Position
#      @left : Int32
#      @right : Int32
#      @top : Int32
#      @bottom : Int32
#      @width : Int32
#      @height : Int32
#
#      def initialize(
#        @left=0,
#        @right=0,
#        @top=0,
#        @bottom=0,
#        @width=1,
#        @height=1,
#      )
#      end
#    end
