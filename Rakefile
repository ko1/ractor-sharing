# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"
require "rake/extensiontask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test" << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
end

Rake::ExtensionTask.new("ractor/tvar")
Rake::ExtensionTask.new("ractor/lock")

task test: :compile
task default: :test

desc "Run the extended KeyLockHash concurrency, resize, and GC stress test"
task "stress:keylockhash" => :compile do
  ruby "-Ilib", "test/keylockhash_stress.rb"
end
