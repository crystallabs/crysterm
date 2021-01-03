module Crysterm
  module Widget
    class Element < Node
      module Keys
        include Crystallabs::Helpers::Alias_Methods

        # Just aliases for listening to keys

        #def key(*args)
        #  #program.key(*args)
        #end

        #def once_key(*args)
        #  #program.once_key(*args)
        #end
        #alias_previous once

        #def remove_key(*args)
        #  #program.unkey(*args)
        #end
        #alias_previous unkey

      end
    end
  end
end
