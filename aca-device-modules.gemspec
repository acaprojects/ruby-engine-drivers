# frozen_string_literal: true

$LOAD_PATH.push File.expand_path('../lib', __FILE__)

require 'aca-device-modules/version'

Gem::Specification.new do |s|
    s.name        = 'aca-device-modules'
    s.version     = AcaDeviceModules::VERSION
    s.authors     = ['ACA Projects']
    s.email       = ['developer@acaprojects.com']
    s.homepage    = 'https://www.acaprojects.com'
    s.summary     = 'Open source modules for ACAEngine'
    s.description = 'Building automation and IoT control modules'
    s.license     = 'LGPL3'

    s.files = Dir[
      '{modules,lib}/**/*.rb',
      'aca-device-modules.gemspec',
      'LICENSE',
      'README.md'
    ]

    s.add_dependency 'rails'
    s.add_dependency 'orchestrator'

    s.required_ruby_version = '>= 2.3.0'
end
