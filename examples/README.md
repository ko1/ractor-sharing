# Examples

Each file runs on its own and checks its own result: it prints one `ok:` line
or aborts. From a checkout:

```
ruby -Ilib examples/01_bank_transfer.rb
```

| file | class | the situation |
|---|---|---|
| [01_bank_transfer.rb](01_bank_transfer.rb) | `TVar` | money moves between accounts; an auditor never catches the total wrong |
| [02_seat_booking.rb](02_seat_booking.rb) | `TVar` | booking adjacent seat pairs; the with-locks version of this deadlocks |
| [03_feature_flags.rb](03_feature_flags.rb) | `TVar` | read-mostly config: flags read constantly, flipped rarely, no lock on the read |
| [04_progress.rb](04_progress.rb) | `LockVar` | workers count up, the main Ractor peeks whenever it redraws |
| [05_exactly_once.rb](05_exactly_once.rb) | `LockVar` | the side effect that a TVar retry would repeat, counted both ways |
| [06_metrics_board.rb](06_metrics_board.rb) | `LockHash` | per-endpoint records and a global total that agree in every snapshot |
| [07_word_count.rb](07_word_count.rb) | `ActorHash` | map-reduce whose reduce side mutates tallies in place |
| [08_lru_cache.rb](08_lru_cache.rb) | `ActiveObject` | an LRU cache: a Hash plus an eviction order nobody wants to freeze |
| [09_audit_log.rb](09_audit_log.rb) | `ActiveObject` | fire-and-forget logging with `async`, strictly ordered by the owner |
| [10_price_quotes.rb](10_price_quotes.rb) | `ActiveObject` | fan out `future` calls, gather the answers later |

The [test suite](../test/examples_test.rb) runs every one of them, so they
cannot rot.
