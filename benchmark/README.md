# benchmark/

`ractor-sharing` のベンチマーク。Ractor / M:N そのものを測る汎用ベンチは
`~/ruby/src/rlgc/benchmark/` にあり、このディレクトリはそこの `apps.tsv` に
登録してある。

規約は汎用側と同じ: **1 ワークロードにつき harness は 1 本、その 1 本が
wall / 呼び手 CPU / プロセス CPU / RSS / GC を全部出す**（`lib/bench.rb` の
`bmeasure`）。パラメータは env、`BENCH_SCALE=%` で仕事量、`BENCH_C` で並行度。

拡張のビルドが要ります（`rake compile`）。ruby を切り替えたら必ずビルドし直すこと。

## 族の比較

| ファイル | 問い |
|---|---|
| `family.rb` | 同じ仕事（カウンタの increment）を全クラスにやらせて値段を並べる。**競合の有無 × Ractor 数**の 2 軸 |

```
ruby family.rb                  # C = 1,2,4,8,16 を掃く
BENCH_C=8 ruby family.rb        # 8 だけ
BENCH_CS=1,16 ruby family.rb    # 指定した並行度だけ
BENCH_SCALE=10 ruby family.rb   # 仕事量を 1/10 に（動作確認用）
```

指標は **全 Ractor 合計での 1 操作あたり ns**（wall / (C × 反復数)）。Ractor を
倍にして値が半分になればスケールしている。conflict 側は原理的にスケールしない
ので、そこで読むのは「1 個の対象をどれだけ速く通せるか」。

2 つ、測定に含めないもの:

* **Ractor の起動コスト** — 全員を作って `receive` で待たせてから時計を始める
* **送りっぱなしの取りこぼし** — async な対象は、測定窓の中で読み戻して未処理を確定させる

1 操作の値段が対象ごとに 100 倍違うので、**反復数は対象ごとに変えてある**
（速い順に 50000 / 3000）。`PER=n` で全対象を揃えられる。

## クラス個別

| ディレクトリ | 中身 |
|---|---|
| `tvar/` | `txn_cost` トランザクション 1 回の値段 / `contention` 同じ TVar の奪い合い / `scaling` 別々の TVar |
| `active_object/` | `call_cost` 公開メソッド 1 回の値段 / `contention` 1 オブジェクトへの同時呼び出し / `objects` オブジェクト数 / `payload` 引数の大きさ |

`LockVar` / `LockHash` / `ActorHash` の個別 harness はまだ無い。`family.rb` が
その役を兼ねている。
