require "./spec_helper"

include Crysterm

# `MainWindow#report_handler_errors`: an error that escapes an event
# handler is logged and shown in the status bar, and the app goes on.

private def stage
  s = headless_screen(60, 10)
  main = Widget::MainWindow.new parent: s
  messages = [] of String
  main.status_bar.on(Event::MessageChanged) { |e| messages << e.message }
  s.repaint
  {s, main, messages}
end

describe "MainWindow#report_handler_errors" do
  it "shows the error and where its backtrace went, with the default message" do
    s, main, messages = stage
    main.report_handler_error RuntimeError.new("boom")
    messages.last.should start_with "Internal error: boom (see "
    s.destroy
  end

  it "names the log file when the option is set, else stderr" do
    saved = Config.log_file
    begin
      Config.set "log.file", ""
      Widget::MainWindow.handler_error_message(RuntimeError.new("x")).should eq "Internal error: x (see stderr)"
      Config.set "log.file", "/tmp/app.log"
      Widget::MainWindow.handler_error_message(RuntimeError.new("x")).should eq "Internal error: x (see /tmp/app.log)"
    ensure
      Config.set "log.file", saved
    end
  end

  it "takes a message of the app's own" do
    s, main, messages = stage
    main.report_handler_error(RuntimeError.new("boom")) { |e| "Oops: #{e.message}" }
    messages.last.should eq "Oops: boom"
    s.destroy
  end

  it "subscribes once, a later call replacing the earlier subscription" do
    s, main, messages = stage
    app = s.exec_application
    main.report_handler_errors { |e| "First: #{e.message}" }
    main.report_handler_errors { |e| "Second: #{e.message}" }
    app.handlers(Event::HandlerError).size.should eq 1
    app.handler_raised RuntimeError.new("x")
    messages.should eq ["Second: x"]
    s.destroy
  end

  it "subscribes to the application's HandlerError, opting into continuing" do
    s, main, messages = stage
    app = s.application || Application.global
    app.has_handlers?(Event::HandlerError).should be_false
    main.report_handler_errors { |e| "Caught: #{e.message}" }
    app.has_handlers?(Event::HandlerError).should be_true
    app.handler_raised RuntimeError.new("late")
    messages.last.should eq "Caught: late"
    s.destroy
  end
end
