# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
Warning[:experimental] = false
require "ractor/sharing"
require "test/unit"

module RactorHelper
  # Runs the block in a fresh Ractor and returns its value (or re-raises).
  def in_ractor(*args, &blk)
    Ractor.new(*args, &blk).value
  rescue Ractor::RemoteError => e
    raise e.cause, cause: nil
  end
end
