module Crysterm
  # Mixin containing helper functions
  module Helpers
    # Sorts array numerically by property 'render_index'
    def hsort(obj)
      obj.sort_by! { |item| -item.render_index }
    end

    # Finds a file with name 'target' inside toplevel directory 'start'.
    # XXX Possibly replace with github: mlobl/finder
    def find_file(start, target)
      return nil if %w(/dev /sys /proc /net).includes?(start)

      files = begin
        # https://github.com/crystal-lang/crystal/issues/4807
        Dir.children start
      rescue e : Exception
        [] of String
      end

      files.each do |file|
        full = File.join start, file

        return full if file == target

        stat = begin
          File.info full, follow_symlinks: false
        rescue e : Exception
          nil
        end

        # `stat` is `File::Info?` — the `rescue` above yields `nil` for a dangling
        # symlink, a races-away entry, or EACCES — so it must be guarded before
        # `directory?`/`symlink?`.
        if stat && stat.directory? && !stat.symlink?
          found = find_file full, target
          return found if found
        end
      end

      nil
    end

    # NOTE The content-related functions below belong here rather than on Widget:
    # they are generic functions, not instance methods.

    # Drops any >U+FFFF characters in the text.
    def drop_unicode(text)
      return "" if text.nil? || text.size == 0
      text.gsub(::Crysterm::Unicode::AllRegex, "??")
    end

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

    # :ditto:
    def escape(text)
      Crysterm::Helpers.escape(text)
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
    def clean_tags(text)
      text.gsub(CLEAN_TAGS_REGEX) do |_, _|
        # No replacement needed, just removing matches
      end
    end
  end
end
