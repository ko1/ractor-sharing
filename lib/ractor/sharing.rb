# frozen_string_literal: true

require_relative "sharing/version"
require_relative "lockvar"
require_relative "lockhash"
require_relative "keylockhash"
require_relative "tvar"
require_relative "active_object"
require_relative "actor_hash"

class Ractor
  # Ways for Ractors to share mutable state.  Each one is shareable itself and
  # keeps state that any Ractor may read and change; they differ in how much
  # state moves at once:
  #
  #   Ractor::TVar          one or more variables, changed together -- start here
  #   Ractor::LockVar       one variable, and a block that runs exactly once
  #   Ractor::LockHash      a hash of those, atomic across its own keys
  #   Ractor::KeyLockHash   a hash with one lock per key: parallel across keys
  #   Ractor::ActiveObject  an object of your own, owned by one Ractor
  #   Ractor::ActorHash     the same, with the interface already chosen: a hash
  #
  # Require this file for all of them, or one at a time:
  #
  #   require "ractor/tvar"
  #   require "ractor/lockvar"
  #   require "ractor/lockhash"
  #   require "ractor/keylockhash"
  #   require "ractor/active_object"
  #   require "ractor/actor_hash"
  module Sharing
  end
end
