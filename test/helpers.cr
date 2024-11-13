require "../src/crysterm"

module Crysterm
  extend Helpers

  puts parse_tags "{red-fg}This should be red.{/red-fg}"
  puts parse_tags "{green-bg}This should have a green background.{/green-bg}"

  sleep 2.seconds

  exit
end
