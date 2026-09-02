# frozen_string_literal: true

require_relative "lib/ractor/sharing/version"

Gem::Specification.new do |spec|
  spec.name = "ractor-sharing"
  spec.version = Ractor::Sharing::VERSION
  spec.authors = ["Koichi Sasada"]
  spec.email = ["ko1@atdot.net"]

  spec.summary = "Ways for Ractors to share mutable state"
  spec.description = "Ractor::LockVar, Ractor::TVar and Ractor::ActiveObject: " \
                     "shareable objects that hold state any Ractor may read and change."
  spec.homepage = "https://github.com/ko1/ractor-sharing"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0"
  spec.extensions = %w[ext/ractor/tvar/extconf.rb ext/ractor/lock/extconf.rb]

  spec.metadata["source_code_uri"] = spec.homepage
  spec.files = Dir["lib/**/*.rb", "ext/**/*.{c,h,rb}", "docs/*.md",
                   "examples/*.rb", "examples/README.md", "README.md", "LICENSE.txt"]
  spec.require_paths = ["lib"]
end
