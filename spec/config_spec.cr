require "./spec_helper"

# `Crysterm::Config` is a transparent alias of the shared `Superconf` registry.
# The registry mechanics (precedence, parsing, validation, dump, …) are covered
# by superconf's own spec; these specs verify the *integration*: Crysterm's
# options, tput's options, and the alias all work through one combined registry.
describe "Crysterm config integration" do
  it "registers Crysterm's builtin options with typed accessors (via the alias)" do
    Crysterm::Config.screen_resize_interval.should eq 0.2.seconds
    Crysterm::Config.cursor_glyph.should eq '▮'
    Crysterm::Config.render_csr_threshold.should eq 40
  end

  it "includes tput's options in the same registry (the unified list)" do
    Crysterm::Config["tput.read_timeout"]?.should_not be_nil
    Crysterm::Config["tput.use_buffer"]?.should_not be_nil
    Crysterm::Config["screen.resize_interval"]?.should_not be_nil
  end

  it "brands env vars with CRYSTERM_ for both crysterm and tput options" do
    Superconf.env_name(Crysterm::Config["screen.resize_interval"]).should eq "CRYSTERM_SCREEN_RESIZE_INTERVAL"
    Superconf.env_name(Crysterm::Config["tput.read_timeout"]).should eq "CRYSTERM_TPUT_READ_TIMEOUT"
  end

  it "uses crysterm as the default config app name" do
    saved = ENV["XDG_CONFIG_HOME"]?
    ENV.delete "XDG_CONFIG_HOME"
    Crysterm::Config.default_config_path.should eq "#{Path.home}/.config/crysterm/config.yml"
  ensure
    ENV["XDG_CONFIG_HOME"] = saved if saved
  end

  it "dumps crysterm and tput options together" do
    yaml = Crysterm::Config.to_yaml
    yaml.should contain "tput:"
    yaml.should contain "screen:"
  end

  it "resolves image.backend, including 'auto' detection" do
    # Explicit backend is used as-is.
    Crysterm::Config.set "media.backend", "kitty"
    Crysterm::Widget::Media.default_type.should eq Crysterm::Widget::Media::Type::Kitty

    # 'auto' resolves the best backend against the terminal (a constructed Tput,
    # so the test is independent of the host terminal and any global screen).
    Crysterm::Config.set "media.backend", "auto"
    ti = (Unibilium.from_env rescue Unibilium.from_terminal("xterm"))
    tput = Tput.new(terminfo: ti, input: STDIN, output: STDOUT)

    # Picks Kitty when the terminal speaks the kitty graphics protocol...
    tput.emulator.kitty = true
    Crysterm::Widget::Media.resolve(Crysterm::Widget::Media::Content::Image, tput)
      .should eq Crysterm::Widget::Media::Type::Kitty

    # ...the user 'umask' (image.exclude) removes it, so the next-best wins...
    Crysterm::Config.set "media.exclude", "kitty,sixel"
    Crysterm::Widget::Media.resolve(Crysterm::Widget::Media::Content::Image, tput)
      .should_not eq Crysterm::Widget::Media::Type::Kitty
    Crysterm::Config.set "media.exclude", ""

    # ...and with no graphics protocol it falls back to a cell backend.
    tput.emulator.kitty = false
    fallback = Crysterm::Widget::Media.resolve(Crysterm::Widget::Media::Content::Image, tput)
    [Crysterm::Widget::Media::Type::Glyph, Crysterm::Widget::Media::Type::Ansi].should contain fallback
  ensure
    Crysterm::Config.set "media.exclude", ""
    Crysterm::Config.set "media.backend", "auto" # restore (Runtime default)
  end

  it "validates and tracks source through the alias" do
    Crysterm::Config.set "render.fps_window", 60
    Crysterm::Config.render_fps_window.should eq 60
    Crysterm::Config["render.fps_window"].source.should eq Superconf::Source::Runtime
    expect_raises(Superconf::Error) { Crysterm::Config.set "render.fps_window", 0 }
  ensure
    Crysterm::Config.set "render.fps_window", 30
  end
end
