require "toka"
require "i18n"
require "event_handler"

module Crysterm

  abstract class CoreApplication
    include EventHandler
    include I18n

    # Name of this application. If unset, defaults to the path of the currently running program.
    property application_name : String = Process.executable_path || PROGRAM_NAME

    # Application version. If unset, defaults to Crystal's usual VERSION string.
    property application_version : String = VERSION

    # Internet domain of the organization that wrote this application.
    property organization_domain : String = ""

    # Name of the organization that wrote this application. If unset, defaults to organization's internet domain.
    property organization_name : String { @organization_domain }


    # Parsed command line arguments and application-wide defaults
    property options : Options { Options.new unparsed_arguments }


    # Returns true if the application objects are being destroyed; otherwise returns false.
    property? exiting : Bool = false
    # XXX alias with closing_down?

    # Event emitted when the application begins the exit process.
    #event AboutToQuitEvent # Replace Exiting with this

    # Save/restore all state here
    def quit
      @exiting = true
      #emit AboutToQuitEvent
    end

    # Enters the main event loop.
    def exec
      sleep
    end


    # Do we want to implement events via queue/channel?


    # Returns unparsed command line arguments as string. Useful to override if arguments are to be read from a different place.
    def unparsed_arguments
      ARGV
    end

    def parse_arguments
      @arguments.merge Arguments.new unparsed_arguments
    end

    class Options
      Toka.mapping({
        setuid_allowed: {
          type: Bool,
          default: false,
          description: "Is the application allowed to run setuid on UNIX platforms?"
        }
      })
    end

  end
end
