class ::String
  # SGR Attribute of a String
  #
  # XXX Needed only because of `CLines < Array(String)`. If `CLines` used
  # a different type of elements in its array, this extension to built-in
  # type could be avoided.
  property attr = [] of Int32
end
