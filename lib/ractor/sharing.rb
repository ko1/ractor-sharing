# frozen_string_literal: true

require_relative "sharing/version"
require_relative "lockvar"
require_relative "lockhash"
require_relative "tvar"
require_relative "active_object"
require_relative "actor_hash"

class Ractor
  # Ways for Ractors to share mutable state.  Each one is shareable itself and
  # keeps state that any Ractor may read and change; they differ in how much
  # state moves at once:
  #
  #   Ractor::LockVar       one variable
  #   Ractor::LockHash      a hash, atomic across its own keys
  #   Ractor::TVar          several variables, changed together
  #   Ractor::ActiveObject  an object of your own, owned by one Ractor
  #   Ractor::ActorHash     a hash owned by one Ractor
  #
  # Require this file for all of them, or require them one at a time
  # ("ractor/lockvar", "ractor/tvar", "ractor/active_object").
  module Sharing
  end
end
