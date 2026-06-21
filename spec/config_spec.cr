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
    Crysterm::Config.set "image.backend", "kitty"
    Crysterm::Widget::Image.default_type.should eq Crysterm::Widget::Image::Type::Kitty

    # 'auto' picks Kitty under Kitty...
    Crysterm::Config.set "image.backend", "auto"
    saved = ENV["KITTY_WINDOW_ID"]?
    ENV["KITTY_WINDOW_ID"] = "1"
    Crysterm::Widget::Image.default_type.should eq Crysterm::Widget::Image::Type::Kitty

    # ...and falls back to Ansi with no kitty/iTerm signal in the environment.
    ENV.delete "KITTY_WINDOW_ID"
    Crysterm::Widget::Image.detect_backend.should eq Crysterm::Widget::Image::Type::Ansi
  ensure
    saved ? (ENV["KITTY_WINDOW_ID"] = saved) : ENV.delete("KITTY_WINDOW_ID")
    Crysterm::Config.set "image.backend", "ansi" # restore (Runtime)
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
