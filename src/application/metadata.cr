module Crysterm
  class Application
    # Meta data about the application.
    module Metadata
      # Name of this application. If unset, defaults to the path of the currently running program.
      property application_name : String = Process.executable_path || PROGRAM_NAME

      # Application version. If unset, defaults to Crystal app's VERSION string.
      property application_version : String = VERSION

      # Internet domain of the organization that wrote this application.
      property organization_domain : String = ""

      # Name of the organization that wrote this application. If unset, defaults to organization's internet domain.
      property organization_name : String { @organization_domain }
    end
  end
end
