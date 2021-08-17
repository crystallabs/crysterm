class ::String
  # SGR Attribute of a String
  property attr = [] of Int32
  # NOTE Needed only because of `CLines < Array(String)`. If `CLines` used
  # a different type of elements in its array, this extension to built-in
  # type could be avoided.
end
