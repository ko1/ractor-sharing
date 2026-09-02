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

Two of them are small applications rather than single tricks:

| file | classes | the application |
|---|---|---|
| [11_webshop.rb](11_webshop.rb) | `TVar` + `LockHash` + `ActiveObject` | a shop: carts reserved all-or-nothing, a mid-run sale, books that always balance, an audit log |
| [12_kvstore_wal.rb](12_kvstore_wal.rb) | `ActiveObject` | a crash-safe KV store: write-ahead log on disk, crash, replay, identical state |
| [13_buffered_logger.rb](13_buffered_logger.rb) | `ActiveObject` | a batching file logger: buffer, high-water mark and flush clock are just ivars |
| [14_api_gateway.rb](14_api_gateway.rb) | `LockHash` + `LockVar` + `ActiveObject` | an API gateway: token buckets, idempotency keys, a circuit breaker that announces each transition exactly once |
| [15_cache_backend.rb](15_cache_backend.rb) | `KeyLockHash` | a cache backend: get-or-create per key, dog-piles absorbed by the key lock itself |
| [16_session_store.rb](16_session_store.rb) | `LockHash` | a session store with "log out everywhere": token and index move together, or a revoked token still authenticates |
| [17_pubsub.rb](17_pubsub.rb) | `KeyLockHash` + `Ractor::Port` | pub/sub in thirty lines: the book is state, delivery is ports, and that is why the gem ships no broker |
| [18_pubsub_ordered.rb](18_pubsub_ordered.rb) | `ActiveObject` | the other pub/sub: one owner serializes every publish, and buys every subscriber the identical order |
| [19_prime_memo.rb](19_prime_memo.rb) | `KeyLockHash` + `ActiveObject` | two memoizations: a per-value prime cache, and one growing sieve behind an owner |

The [test suite](../test/examples_test.rb) runs every one of them, so they
cannot rot.
