module Crysterm
  # Mixin containing helper functions
  module Helpers
    # (Generic filesystem search moved to the crystallabs-helpers shard:
    # `Crystallabs::Helpers::Files.find_file`.)

    # NOTE The content-related functions below belong here rather than on Widget:
    # they are generic functions, not instance methods.

    # Escapes text for tag-enabled elements where one does not want the tags enclosed in {...} to be treated specially, but literally.
    #
    # Example to print literal "{bold}{/bold}":
    # '''
    # box.set_content("escaped content: " + escape("{bold}{/bold}"))
    # '''
    def self.escape(text)
      text.gsub(/[{}]/) do |ch|
        case ch
        when "{" then "{open}"
        when "}" then "{close}"
        end
      end
    end

    # Strips text of "{...}" tags and SGR sequences and removes leading/trailing whitespaces
    def strip_tags(text : String)
      clean_tags(text).strip
    end

    # Combined {...}-tag + SGR-sequence regex. Held as a constant so it compiles
    # once rather than on every `clean_tags` call: an interpolated `#{...}` regex,
    # unlike a regex literal, recompiles on each evaluation.
    CLEAN_TAGS_REGEX = /(?:#{Crysterm::Widget::TAG_REGEX.source})|(?:#{Crysterm::Widget::SGR_REGEX.source})/

    # Strips text of {...} tags and SGR sequences
    def clean_tags(text : String)
      text.gsub(CLEAN_TAGS_REGEX) do |_, _|
        # No replacement needed, just removing matches
      end
    end
  end
end
