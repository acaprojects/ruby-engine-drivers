$:.push File.expand_path("../lib", __FILE__)

# Maintain your gem's version:
require "aca-device-modules/version"

# Describe your gem and declare its dependencies:
Gem::Specification.new do |s|
  s.name        = "aca-device-modules"
  s.version     = AcaDeviceModules::VERSION
  s.authors     = ["ACA Projects"]
  s.email       = ["developer@acaprojects.com"]
  s.homepage    = "https://www.acaprojects.com"
  s.summary     = "Open source modules for ACAEngine"
  s.description = "Building automation and IoT control modules"
  s.license     = "LGPL3"

  s.files = Dir[
    "{modules,lib}/**/*.rb",
    "aca-device-modules.gemspec",
    "LICENSE",
    "README.md"
  ]

  s.add_dependency "rails"
  s.add_dependency "orchestrator"
end
