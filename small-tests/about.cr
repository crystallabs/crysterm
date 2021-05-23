require "../src/crysterm"

app = Crysterm::App.new #( app_name: "appname", app_version: "2.0", organization_domain: "myDomain.com", organization_name: "My Org Name")
p app.about
p app.class.about
