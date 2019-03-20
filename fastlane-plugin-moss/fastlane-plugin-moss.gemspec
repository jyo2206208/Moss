# coding: utf-8

lib = File.expand_path("../lib", __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'fastlane/plugin/moss/version'

Gem::Specification.new do |spec|
  spec.name          = 'fastlane-plugin-moss'
  spec.version       = Fastlane::Moss::VERSION
  spec.author        = 'Shaggon du'
  spec.email         = 'shaggon.du@farfetch.com'

  spec.summary       = 'Moss is a tool that allows developers on Apple platforms to use any frameworks as a shared cache for frameworks built with Carthage.'
  spec.homepage      = "https://github.com/jyo2206208/moss"
  spec.license       = "MIT"

  spec.files         = Dir["lib/**/*"] + %w(README.md LICENSE)
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ['lib']

  spec.add_development_dependency('pry')
  spec.add_development_dependency('bundler')
  spec.add_development_dependency('rspec')
  spec.add_development_dependency('rspec_junit_formatter')
  spec.add_development_dependency('rake')
  spec.add_development_dependency('rubocop', '0.49.1')
  spec.add_development_dependency('rubocop-require_tools')
  spec.add_development_dependency('simplecov')
  spec.add_development_dependency('fastlane', '>= 2.112.0')
end
