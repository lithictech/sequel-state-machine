# frozen_string_literal: true

require_relative "lib/state_machines/sequel/version"

Gem::Specification.new do |s|
  s.name = "sequel-state-machine"
  s.version = StateMachines::Sequel::VERSION
  s.platform = Gem::Platform::RUBY
  s.summary = "Hook together the excellent Ruby Sequel ORM to the state-machines library, " \
              "with auditing and other tools."
  s.author = "Lithic Tech"
  s.email = "hello@lithic.tech"
  s.homepage = "https://github.com/lithictech/sequel-state-machine"
  s.licenses = "MIT"
  s.required_ruby_version = ">= 2.7.0"
  s.description = <<~DESC
    sequel-state-machine hooks together the excellent Ruby Sequel ORM to
    the state-machines library, with auditing and other tools.
  DESC
  s.metadata["rubygems_mfa_required"] = "true"
  s.files = Dir["lib/**/*.rb"]
  s.add_development_dependency("rspec", "~> 3.10")
  s.add_development_dependency("rspec-core", "~> 3.10")
  s.add_development_dependency("rubocop", "~> 1.11")
  s.add_development_dependency("rubocop-performance", "~> 1.10")
  s.add_development_dependency("rubocop-sequel", "~> 0.2")
  s.add_development_dependency("sequel", "~> 5.0")
  s.add_development_dependency("sqlite3", "~> 1")
  s.add_development_dependency("state_machines", "~> 0")
end
