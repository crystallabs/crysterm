module Crysterm
  # Mixin containing helper functions
  module Helpers
    # Sorts array alphabetically by property 'name'.
    def asort(obj)
      obj.sort do |a, b|
        a = a.not_nil!.name.not_nil!.downcase
        b = b.not_nil!.name.not_nil!.downcase

        if ((a[0] == '.') && (b[0] == '.'))
          a = a[1]
          b = b[1]
        else
          a = a[0]
          b = b[0]
        end

        a > b ? 1 : (a < b ? -1 : 0)
      end
    end

    # Sorts array numerically by property 'index'
    def hsort(obj)
      obj.sort do |a, b|
        b.index - a.index
      end
    end

    # Escapes text for tag-enabled elements where one does not want the tags enclosed in {...} to be treated specially, but literally.
    #
    # Example to print literal "{bold}{/bold}":
    # '''
    # box.set_content("escaped content: " + escape("{bold}{/bold}"))
    # '''
    def escape(text)
      text.gsub(/[{}]/) { |ch|
        ch == "{" ? "{open}" : "{close}"
      }
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

    # Strips text of "{...}" tags and SGR sequences and removes leading/trailing whitespaces
    def strip_tags(text : String)
      clean_tags(text).strip
    end

    # Strips text of {...} tags and SGR sequences
    def clean_tags(text)
      text.gsub(Crysterm::Widget::TAG_REGEX, "").gsub(Crysterm::Widget::SGR_REGEX, "")
    end

    # Finds a file with name 'target' inside toplevel directory 'start'.
    # XXX Possibly replace with github: mlobl/finder
    def find_file(start, target)
      if start == "/dev" || start == "/sys" || start == "/proc" || start == "/net"
        return nil
      end
      files = begin
        # https://github.com/crystal-lang/crystal/issues/4807
        Dir.children start
      rescue e : Exception
        [] of String
      end
      files.each do |file|
        full = File.join start, file
        if file == target
          return full
        end
        stat = begin
          File.info full, follow_symlinks: false
        rescue e : Exception
          nil
        end
        if stat && stat.directory? && !stat.symlink?
          f = find_file full, target
          if f
            return f
          end
        end
      end
      nil
    end

    private def find(prefix, word)
      w0 = word[0].to_s
      file = File.join(prefix, w0)
      begin
        File.info(file) # Test existence basically. # XXX needs to be replaced with if( -e FILE), in multiple places
        return file
      rescue e : Exception
      end

      ch = w0.char_at(0).to_s
      if (ch.size < 2)
        ch = "0" + ch
      end

      # XXX path.resolve
      file = File.join(prefix, ch)
      begin
        File.info(file)
        return file
      rescue e : Exception
      end

      nil
    end

    # Drops any >U+FFFF characters in the text.
    def drop_unicode(text)
      return "" if text.nil? || text.size == 0
      # TODO possibly find ready-made crystal method for this
      text.gsub(::Crysterm::Unicode::AllRegex, "??") # .gsub(@unicode.chars["combining"], "").gsub(@unicode.chars["surrogate"], "?");
    end
  end
end
