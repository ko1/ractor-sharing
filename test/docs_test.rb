# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# Every example in the documentation is run, so it cannot drift from the code.
# Blocks under an "API" heading are left out: those are signatures, not code.
class DocsTest < Test::Unit::TestCase
  ROOT = File.expand_path("..", __dir__)

  def self.doc_files
    [File.join(ROOT, "README.md")] +
      Dir[File.join(ROOT, "docs", "*.md")].reject { |f| f.include?("design") }.sort
  end

  # Ruby blocks that are meant to run: not signature listings, not the examples
  # written to show what is refused.
  def runnable_blocks(path)
    section = ""   # nearest "## " heading
    blocks = []
    code = nil
    File.foreach(path) do |line|
      if code
        if line.start_with?("```")
          blocks << code unless skip?(section, code)
          code = nil
        else
          code << line
        end
      elsif line.start_with?("```ruby")
        code = +""
      elsif line.start_with?("## ")
        section = line
      end
    end
    blocks
  end

  # API sections list signatures and Performance sections show what was
  # measured; neither is code to run. Nor is an example written to be refused.
  def skip?(section, code)
    section =~ /\bAPI\b|Performance/i ||
      code.include?("...") ||
      code =~ /#\s*=>.*Error/ ||
      code =~ /^\s*#\s*(WRONG|refused)/
  end

  doc_files.each do |path|
    name = File.basename(path, ".md")
    define_method("test_examples_in_#{name}") do
      blocks = runnable_blocks(path)
      omit "no runnable examples" if blocks.empty?

      script = <<~RB + blocks.join("\n")
        Warning[:experimental] = false
        $LOAD_PATH.unshift #{File.join(ROOT, "lib").inspect}
        require "ractor/sharing"
      RB
      file = File.join(Dir.tmpdir, "ractor_sharing_doc_#{name}_#{Process.pid}.rb")
      File.write(file, script)
      begin
        out = IO.popen([RbConfig.ruby, file], err: %i[child out], &:read)
        assert_true $?.success?,
                    "#{File.basename(path)}: an example does not run\n#{script}\n--- output ---\n#{out}"
      ensure
        File.unlink(file) if File.exist?(file)
      end
    end
  end
end
