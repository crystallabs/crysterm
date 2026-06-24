require "../src/crysterm"

# Demo of the single capture entry point, `Screen#capture`.
#
# It runs a small Crysterm TUI whose content is continuously generated, and uses
# the *same* function for both outputs:
#
#   * STILL image — `screen.capture(path: "/tmp/crysterm_demo.png")` is called
#     once per second. PNG is encoded in-process (no external tools). The file is
#     opened once in a viewer that reloads on change (macOS Preview / ristretto),
#     so it animates as the file is rewritten.
#   * VIDEO — press `r` to record a few seconds with
#     `screen.capture(path: "/tmp/crysterm_demo.mp4", duration: …)`, which pipes
#     raw RGBA frames to ffmpeg. When done it opens the file in the default player.
#
# So: 1 still call = in-process PNG; a duration call = ffmpeg-encoded video. Any
# format ffmpeg knows works by changing the extension (mp4/gif/webm/apng/…).
#
# Press `r` to record, `q` to quit.  Run: crystal run examples/capture_demo.cr
class CaptureDemo
  include Crysterm

  PNG_PATH    = "/tmp/crysterm_demo.png"
  MP4_PATH    = "/tmp/crysterm_demo.mp4"
  REC_SECONDS = 6

  @cols : Int32
  @rows : Int32
  @counter : Int32 = 0
  @log : Array(String)
  @recording : Bool = false
  @still_opened : Bool = false
  @status : Widget::Box?
  @clock : Widget::Box?
  @logbox : Widget::Box?

  def initialize
    @screen = Screen.new title: "Crysterm capture demo"
    @cols = @screen.awidth.to_i
    @rows = @screen.aheight.to_i
    @log = [] of String
    build_ui
  end

  # Platform command to open a file in its default app / viewer.
  private def open_cmd(file : String) : Array(String)
    {% if flag?(:darwin) %}
      ["open", file]
    {% else %}
      ["xdg-open", file]
    {% end %}
  end

  private def launch(cmd : Array(String))
    Process.new(cmd.first, cmd[1..],
      input: Process::Redirect::Close,
      output: Process::Redirect::Close,
      error: Process::Redirect::Close)
  rescue
    nil
  end

  # ---- UI -------------------------------------------------------------------

  private def build_ui
    Widget::Box.new \
      parent: @screen, top: 0, left: 0, width: "100%", height: 3,
      content: "{center}{bold}CRYSTERM CAPTURE DEMO{/bold}\nScreen#capture -> still PNG (in-process) + video (ffmpeg){/center}",
      parse_tags: true, style: Style.new(fg: "black", bg: "cyan", border: true)

    @status = Widget::Box.new \
      parent: @screen, top: 3, left: 0, width: "50%", height: 8,
      label: " Status ", parse_tags: true,
      style: Style.new(fg: "white", bg: "blue", border: true)

    @clock = Widget::Box.new \
      parent: @screen, top: 3, left: "50%", width: "50%", height: 8,
      label: " Generated content ", parse_tags: true,
      style: Style.new(fg: "yellow", border: true)

    @logbox = Widget::Box.new \
      parent: @screen, top: 11, left: 0, width: "100%", bottom: 1,
      label: " Activity log ", parse_tags: true,
      style: Style.new(fg: "green", border: true)

    Widget::Box.new \
      parent: @screen, bottom: 0, left: 0, width: "100%", height: 1,
      content: " r: record #{REC_SECONDS}s video   ·   q: quit   ·   still: #{PNG_PATH} (1s)",
      style: Style.new(fg: "black", bg: "white")

    @screen.on(Event::KeyPress) do |e|
      case e.char
      when 'q' then quit
      when 'r' then start_recording
      end
      quit if e.key == Tput::Key::CtrlQ
    end
  end

  # ---- content generation ---------------------------------------------------

  private def tick
    @counter += 1
    now = Time.local.to_s("%H:%M:%S")
    pos = @counter % 20
    bar = ("=" * pos) + ">" + ("-" * (20 - pos))
    @clock.not_nil!.content = "{center}#{now}{/center}\n\nframe ##{@counter}\n[#{bar}]\n\nvalue: #{(Math.sin(@counter / 5.0) * 100).to_i}"

    @status.not_nil!.content =
      "still : #{PNG_PATH}\n" \
      "        in-process PNG, every 1s\n" \
      "video : #{@recording ? "RECORDING -> #{MP4_PATH}" : "press r (#{REC_SECONDS}s via ffmpeg)"}\n" \
      "size  : #{@cols * 8}x#{@rows * 14}px   renders: #{@counter}"
  end

  private def log_line(msg)
    @log << "#{Time.local.to_s("%H:%M:%S")}  #{msg}"
    @log.shift if @log.size > 10
    @logbox.not_nil!.content = @log.join("\n")
  end

  # ---- capture (the single function) ----------------------------------------

  # Still PNG via Screen#capture (in-process). Opens the viewer the first time.
  private def write_still
    @screen.capture(0, @cols, 0, @rows, path: PNG_PATH)
    unless @still_opened
      @still_opened = true
      launch open_cmd(PNG_PATH)
    end
  rescue
  end

  # Record a video via Screen#capture(duration:) — runs in its own fiber so the
  # UI keeps rendering (which is what supplies the frames). Opens it when done.
  private def start_recording
    return if @recording
    @recording = true
    log_line "recording #{REC_SECONDS}s video..."
    spawn do
      begin
        @screen.capture(0, @cols, 0, @rows, path: MP4_PATH, duration: REC_SECONDS.seconds, fps: 12)
        log_line "saved #{MP4_PATH}"
        launch open_cmd(MP4_PATH)
      rescue ex
        log_line "video failed: #{ex.message}"
      ensure
        @recording = false
      end
    end
  end

  # ---- run ------------------------------------------------------------------

  def run
    @screen.every(100.milliseconds) { tick }
    @screen.every(1.second) do
      log_line "generated item #{@counter}"
      write_still
    end
    @screen.exec
  end

  private def quit
    @screen.destroy
    exit
  end
end

CaptureDemo.new.run
