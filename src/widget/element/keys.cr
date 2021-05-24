module Crysterm
  class Element < Node
    module Keys
      include Crystallabs::Helpers::Alias_Methods

      # Just aliases for listening to keys

      # def key(*args)
      #  #app.key(*args)
      # end

      # def once_key(*args)
      #  #app.once_key(*args)
      # end
      # alias_previous once

      # def remove_key(*args)
      #  #app.unkey(*args)
      # end
      # alias_previous unkey

    end
  end
end
