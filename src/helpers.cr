module Crysterm
  # Mixin containing helper functions
  module Helpers
    # Sorts array alphabetically by first letter of property 'name'.
    def asort(obj)
      obj.stable_sort! do |a, b|
        a_name = a.not_nil!.name.not_nil!.downcase
        b_name = b.not_nil!.name.not_nil!.downcase

        a_first_char = (a_name[0] == '.') ? a_name[1] : a_name[0]
        b_first_char = (b_name[0] == '.') ? b_name[1] : b_name[0]

        a_first_char <=> b_first_char
      end
    end

    # Sorts array numerically by property 'index'
    def hsort(obj)
      obj.sort_by! { |item| -item.index }
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
        full = String.build do |str|
          str << start << File::SEPARATOR << file
        end

        return full if file == target

        stat = begin
          File.info full, follow_symlinks: false
        rescue e : Exception
          nil
        end

        if stat.directory? && !stat.symlink?
          found = find_file full, target
          return found if found
        end
      end

      nil
    end

    private def find(prefix, word)
      w0 = word[0].to_s

      file = String.build do |str|
        str << prefix << File::SEPARATOR << w0
      end

      return file if File.exists?(file)

      ch = w0.char_at(0).to_s.rjust(2, '0')

      file = String.build do |str|
        str << prefix << File::SEPARATOR << ch
      end

      return file if File.exists?(file)

      nil
    end

    #
    # NOTE Content-related functions below should stay here (instead of go to src/widget_content.cr)
    # since they're generic functions, not instance methods on Widget.
    #

    # Drops any >U+FFFF characters in the text.
    def drop_unicode(text)
      return "" if text.nil? || text.size == 0
      # TODO possibly find ready-made crystal method for this
      text.gsub(::Crysterm::Unicode::AllRegex, "??") # .gsub(@unicode.chars["combining"], "").gsub(@unicode.chars["surrogate"], "?");
    end

    # Escapes text for tag-enabled elements where one does not want the tags enclosed in {...} to be treated specially, but literally.
    #
    # Example to print literal "{bold}{/bold}":
    # '''
    # box.set_content("escaped content: " + escape("{bold}{/bold}"))
    # '''
    def escape(text)
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

    # Strips text of {...} tags and SGR sequences
    def clean_tags(text)
      combined_regex = /(?:#{Crysterm::Widget::TAG_REGEX.source})|(?:#{Crysterm::Widget::SGR_REGEX.source})/
      text.gsub(combined_regex) do |_, _|
        # No replacement needed, just removing matches
      end
    end

    # # Generates text tags based on the given style definition.
    # # Don't use unless you need to.
    # # ```
    # # obj.generate_tags({"fg" => "lightblack"}, "text") # => "{light-black-fg}text{/light-black-fg}"
    # # ```
    # def generate_tags(style : Hash(String, String | Bool) = {} of String => String | Bool)
    #  open = ""
    #  close = ""

    #  (style).each do |key, val|
    #    if (val.is_a? String)
    #      val = val.sub(/^light(?!-)/, "light-")
    #      val = val.sub(/^bright(?!-)/, "bright-")
    #      open = "{" + val + "-" + key + "}" + open
    #      close += "{/" + val + "-" + key + "}"
    #    else
    #      if val
    #        open = "{" + key + "}" + open
    #        close += "{/" + key + "}"
    #      end
    #    end
    #  end

    #  {
    #    open:  open,
    #    close: close,
    #  }
    # end

    # # :ditto:
    # def generate_tags(style : Hash(String, String | Bool), text : String)
    #  v = generate_tags style
    #  v[:open] + text + v[:close]
    # end
  end
end
