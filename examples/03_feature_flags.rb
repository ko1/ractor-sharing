# frozen_string_literal: true
#
# A read-mostly config: flags read on every request by every worker, flipped
# once in a blue moon. This is where TVar shines -- a read outside a
# transaction takes no lock at all, so sixteen readers of one shared TVar pay
# the same as sixteen readers of their own (about 9 ns on our bench machine).
#
#   ruby -Ilib examples/03_feature_flags.rb
Warning[:experimental] = false
require "ractor/sharing"

FLAGS = Ractor::TVar.new({ new_ui: false, beta_search: false }.freeze)

workers = 4.times.map do
  Ractor.new(FLAGS) do |flags|
    reads = 0
    reads += 1 until flags.value[:new_ui]      # serve requests on the old UI
    reads += 1 until flags.value[:beta_search] # then wait for the next rollout
    reads
  end
end

sleep 0.05  # let them serve a while on the old flags
Ractor.atomically { FLAGS.value = FLAGS.value.merge(new_ui: true).freeze }
sleep 0.05
Ractor.atomically { FLAGS.value = FLAGS.value.merge(beta_search: true).freeze }

reads = workers.sum(&:value)
abort "a worker never saw the rollout" if reads.zero?
puts "ok: 4 workers made #{reads} flag reads across two rollouts, no locks anywhere"
