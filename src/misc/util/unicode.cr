module Crysterm
  # Unicode display-width support for terminal cells — the implementation
  # lives in the tput shard now (`Tput::Unicode`): terminal column-width is a
  # terminal-domain concern shared by anything driving a tty, not toolkit
  # logic. The alias keeps every `Crysterm::Unicode.…` call site working.
  #
  # (The `@cluster`-layout pinning spec for `width(String::Grapheme)` /
  # `cluster_size` lives with the module's specs.)
  #
  # A real `alias` (not a constant assignment), so nested constants
  # (`Unicode::WIDE`) resolve through it too.
  alias Unicode = ::Tput::Unicode
end
