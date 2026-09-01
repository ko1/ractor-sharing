# benchmark/

`ractor-sharing` のベンチマーク。

規約は **1 ワークロードにつき harness は 1 本、その 1 本が
wall / 呼び手 CPU / プロセス CPU / RSS / GC を全部出す**（`lib/bench.rb` の
`bmeasure`）。パラメータは env、`BENCH_SCALE=%` で仕事量、`BENCH_C` で並行度。

拡張のビルドが要ります（`rake compile`）。ruby を切り替えたら必ずビルドし直すこと。

## 族の比較

| ファイル | 問い |
|---|---|
| `family.rb` | 同じ仕事（共有された 1 個のレコードの読み書き）を全クラスにやらせて値段を並べる。**read/write の別 × 競合の有無 × Ractor 数**の 3 軸 |

```
ruby family.rb                  # C = 1,2,4,8,16 を掃く
BENCH_C=8 ruby family.rb        # 8 だけ
BENCH_CS=1,16 ruby family.rb    # 指定した並行度だけ
BENCH_SCALE=10 ruby family.rb   # 仕事量を 1/10 に（動作確認用）
```

仕事は **共有された 1 個のレコードの読み書き**。値は凍った Hash
`{status:, seq:}` で、write はそれを新しい凍った Hash に差し替える、read はそれ
を取り出す。3 通り測る:

| 列 | 中身 |
|---|---|
| `read` | 取り出すだけ。実アプリではこちらが多い |
| `write` | 差し替える |
| `mix 9:1` | 10 回に 1 回だけ write |

**increment を仕事にしない。** `TVar#increment` も `LockVar#increment` も
Fixnum 専用の近道を持っていて、その 1 行だけが速く見える。近道どうしの比較は
意味があるので、最後に別の表として出してある。

所有者 Ractor を持つ対象（`ActorHash` / `ActiveObject`）は write を **sync と
async の両方**で出す。async は返事を待たない分だけ安い。

指標は **全 Ractor 合計での 1 操作あたり ns**（wall / (C × 反復数)）。Ractor を
倍にして値が半分になればスケールしている。conflict 側は原理的にスケールしない
ので、そこで読むのは「1 個の対象をどれだけ速く通せるか」。

3 つ、測定の作り:

* **Ractor の起動コストは含めない**: 全員を作って `receive` で待たせてから時計を始める
* **送りっぱなしを取りこぼさない**: async な対象は、測定窓の中で読み戻して未処理を確定させる
* **毎回検算する**: write / mix は最後の `seq` が投入した write 数と一致することを、
  read は読めた値の合計を確認して、合わなければその場で落とす。取りこぼしや no-op が
  「速い」に化けるのがこの手の harness で一番たちが悪い

1 操作の値段が対象ごとに 100 倍違うので、**反復数は対象ごとに変えてある**
（速い順に 30000 / 2000）。`PER=n` で全対象を揃えられる。

## クラス個別

| ディレクトリ | 中身 |
|---|---|
| `tvar/` | `txn_cost` トランザクション 1 回の値段 / `contention` 同じ TVar の奪い合い / `scaling` 別々の TVar |
| `active_object/` | `call_cost` 公開メソッド 1 回の値段 / `contention` 1 オブジェクトへの同時呼び出し / `objects` オブジェクト数 / `payload` 引数の大きさ |

`LockVar` / `LockHash` / `ActorHash` の個別 harness はまだ無い。`family.rb` が
その役を兼ねている。
