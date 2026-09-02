# frozen_string_literal: true

require_relative "test_helper"

# Every example is self-checking: it prints one "ok:" line or aborts. Running
# them here keeps them honest the same way docs_test keeps the docs honest.
class ExamplesTest < Test::Unit::TestCase
  ROOT = File.expand_path("..", __dir__)

  Dir[File.join(ROOT, "examples", "*.rb")].sort.each do |path|
    define_method("test_#{File.basename(path, '.rb')}") do
      out = IO.popen([RbConfig.ruby, "-I#{File.join(ROOT, 'lib')}", path],
                     err: %i[child out], &:read)
      assert_true $?.success?, "#{File.basename(path)} failed:\n#{out}"
      assert_match(/^ok:/, out, "#{File.basename(path)} printed no ok line:\n#{out}")
    end
  end
end
