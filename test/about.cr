require "../src/crysterm"

app = Crysterm::Application.new #( application_name: "appname", application_version: "2.0", organization_domain: "myDomain.com", organization_name: "My Org Name")
p app.about
p app.class.about
