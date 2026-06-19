class ::String
  # SGR Attribute of a String
  #
  # XXX Needed because `CLines` stores plain `String` elements and attaches an
  # SGR attribute to each one. If `CLines` used a richer element type, this
  # extension to the built-in `String` could be avoided.
  property attr = [] of Int32
end
