require "tput"

module Crysterm
  class App
    # Tput-related part of an App's instance.
    module Tput
      # Tput object. XXX Any way to succeed turning this into `getter` without `!`?
      getter! tput : ::Tput

      # Force Unicode (UTF-8) even if auto-detection did not discover terminal support for it?
      property force_unicode = false

      # Amount of time to wait before redrawing the screen, after the terminal resize event is received.
      property resize_timeout : Time::Span

      @_listened_keys : Bool = false

      def setup_tput(input : IO, output : IO, terminfo : Bool | Unibilium::Terminfo = true)
        @terminfo = case terminfo
                    when true
                      Unibilium::Terminfo.from_env
                    when false
                      nil
                    when Unibilium::Terminfo
                      terminfo.as Unibilium::Terminfo
                    end

        @tput = ::Tput.new(
          terminfo: @terminfo,
          input: input,
          output: output,
          # TODO these options
          # term: @term,
          # padding: @padding,
          # extended: @extended,
          # termcap: @termcap,
          use_buffer: @use_buffer,
          force_unicode: @force_unicode
        )

        # TODO tput stuff till end of function

        @tput
      end

      def listen
        # Potentially reset window title on exit:
        # if !rxvt?
        #  if !vte?
        #    set_title_mode_feature 3
        #  end
        #  manipulate_window(21) { |err, data|
        #    return if err
        #    @_original_title = data.text
        #  }
        # end

        # Listen for keys/mouse on input
        # if (@tput.input._our_input == 0)
        #  @tput.input._out_input = 1
        _listen_keys
        # _listen_mouse
        # else
        #  @tput.input._our_input += 1
        # end

        # on(AddHandlerEvent) do |wrapper|
        #  if wrapper.event.is_a?(Event::KeyPress) # or Event::Mouse
        #    # remove self...
        #    if (@tput.input.set_raw_mode && !@tput.input.raw?)
        #      @tput.input.set_raw_mode true
        #      @tput.input.resume
        #    end
        #  end
        # end
        # on(AddHandlerEvent) do |wrapper|
        #  if (wrapper.is_a? Event::Mouse)
        #    off(AddHandlerEvent, self)
        #    bind_mouse
        #  end
        # end
        # Listen for resize on output
        # if (@output._our_output==0)
        #  @output._our_output = 1
        #  _listen_output
        # else
        #  @output._our_output += 1
        # end
      end

      def _listen_keys
        return if @_listened_keys
        @_listened_keys = true
        spawn do
          tput.listen do |char, key, sequence|
            @@instances.each do |app|
              # XXX What to do here -- i/o has been removed from this class.
              # It only exists in tput, so how to check/compare?
              # Do we need to add it back in?
              # next if app.input != @tput.input

              emit Crysterm::Event::KeyPress.new char, key, sequence
            end
          end
        end
      end

      # We can't name the function 'out'. But it is here for reference only.
      # To print to a temporary buffer rather than @output, initialize
      # @tput.ret to an IO. Then all writes will go there instead of to @output.
      # While @tput.ret is nil, output goes to output as usual.
      # NOTE Check how does this affect behavior with the local @_buf element.
      # def out
      # end

    end
  end
end
