# benchmark/

`Ractor::ActiveObject` の API に依存するベンチマーク。Ractor / M:N そのものを測る
汎用ベンチは `~/ruby/src/rlgc/benchmark/` にあり、このディレクトリはそこの
`apps.tsv` に登録してある（`runner/apps.sh` で一覧が出る）。

規約は汎用側と同じ: **1 ワークロードにつき harness は 1 本、その 1 本が
wall / 呼び手 CPU / プロセス CPU / RSS / GC を全部出す**（`lib/bench.rb` の
`bmeasure`）。パラメータは env、`BENCH_SCALE=%` で仕事量、`BENCH_C` で並行度。

## harness

| ファイル | 問い | パラメータ（既定） |
|---|---|---|
| `call_cost.rb` | policy 別の 1 呼び出しの値段。**看板の数字** | `N=50000` `DEPTH=64` |
| `contention.rb` | 1 オブジェクトを C 個の caller が叩く。owner が直列化点なので、ここで頭打ちになるはず | `CALLERS=8`(BENCH_C) `PER=5000` `POLICY=sync\|async` |
| `objects.rb` | N 個の独立オブジェクト（= N 本の owner Ractor）。コア数まで伸びるか | `OBJECTS=8`(BENCH_C) `PER=5000` |
| `payload.rb` | 引数・戻り値のバイト数に対するコスト。`SHAREABLE=1` との差がコピーの値段 | `BYTES=0` `SHAREABLE` `N=20000` |

## call_cost.rb — 必ず分母と一緒に読む

`sync` の 1 呼び出しが何 µs かだけでは「速いのか」に答えられないので、同じ run の中で
床を 4 つ取ります。

| 行 | 何の床か |
|---|---|
| `plain method` | proxy を通さない素の呼び出し = 言語の床 |
| `mutex + thread` | Mutex で守った同じ更新を別スレッドから = 1:1 の対照 |
| `raw Port round trip` | `Ractor::Port` の生の往復 = ActiveObject が払える下限 |
| `ao sync` / `ao sync (nop)` | 本体。生 Port との差がライブラリの取り分 |
| `ao async (+1 barrier)` | 片道。**呼び手が払う額**であって処理が終わった時刻ではない（最後に sync を 1 回入れてキューを空にしている） |
| `ao future (value)` | 投げてすぐ待つ形。毎回新しい reply port を取る（sync は Ractor-local プールから借りる） |
| `ao future (depth=N)` | 投げてからまとめて回収する形。future の意味はこちら |
| `ao servant self-call` | owner Ractor の中の自己呼び出し。mailbox を通らない経路 |

`async` と `future(depth)` が `sync` より桁で安いのは、往復を待っていないからで、
速さではなく**待ち方の違い**です。行を横に読むときは `caller` 列（呼び手が焼いた CPU）
を見てください。

## contention.rb と objects.rb は対で読む

- `contention.rb` = 1 owner に全員が向かう。owner Ractor が直列化点なので、
  **並行度を上げても owner のスループット以上にはならない**（そうならなければ
  直列化が壊れている）
- `objects.rb` = owner を並べる。ここが伸びないなら天井は ActiveObject ではなく
  スケジューラ側にある

`objects.rb` は `Cell.new`（= Ractor 1 本の生成）の値段も別行で出します。1 オブジェクト
1 Ractor なので、生成コストは設計の一部です。

## 測るときの作法

汎用側 `~/ruby/src/rlgc/benchmark/README.md` の「計測の作法」に従う。中央値 + min-max、
A/B は交互に、専用箱 sp4 は `bench-lease claim/check/release`。
