# frozen_string_literal: true

# Read the version without loading the runtime (which requires plumb/fugit) —
# the gemspec is evaluated by bundler before dependencies are installed.
VERSION = File.read(File.expand_path('lib/sourced/message.rb', __dir__))
             .match(/VERSION = ['"](.+?)['"]/)[1]

Gem::Specification.new do |spec|
  spec.name = "sourced-message"
  spec.version = VERSION
  spec.authors = ["Ismael Celis"]
  spec.email = ["ismaelct@gmail.com"]

  spec.summary = "Canonical typed Message class and registry shared by Sourced and Sidereal."
  spec.description = "Provides Sourced::Message — a Plumb-typed message with a " \
                     "shared type registry, payloads, correlation, and scheduling — " \
                     "used as the common base for Sourced and Sidereal messages."
  spec.homepage = "https://github.com/ismasan/sourced-message"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore .rspec spec/])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "plumb", "0.2.0.beta.2"
  spec.add_dependency "fugit"
end
