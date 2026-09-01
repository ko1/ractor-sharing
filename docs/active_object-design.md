# Ractor::ActiveObject 設計指示書

## 1. 目的

`Ractor::ActiveObject` は、ある Ruby オブジェクトとその内部状態を 1 つの Ractor に所有させ、他の Ractor からそのオブジェクトのメソッドを安全に呼び出せるようにするための abstraction である。

基本的な考え方は Active Object pattern に近い。

* オブジェクトの内部状態は owner Ractor のみが直接操作する
* owner 以外からのメソッド呼び出しは owner Ractor に転送する
* owner Ractor 上では通常の Ruby method として実行する
* 同一 ActiveObject に対する remote invocation は逐次実行される
* メソッドごとに remote invocation のデフォルト方式を指定できる

利用者からは可能な限り通常の Ruby object と同じように見えることを目指す。

## 2. 基本例

```ruby
class People < Ractor::ActiveObject
  def initialize
    @db = {}
  end

  async def add(name, age)
    @db[name] = age
  end

  sync def find(name)
    @db[name]
  end
end

PEOPLE = People.new

PEOPLE.add("ko1", 46)

Ractor.new do
  p PEOPLE.find("ko1")
end
```

`People` インスタンスは内部的に owner Ractor を持つ。

owner 以外の Ractor から、

```ruby
PEOPLE.find("ko1")
```

を呼ぶと、`find` の実行要求を owner Ractor に送信し、owner 上で実行した結果を呼び出し元に返す。

一方、

```ruby
PEOPLE.add("ko1", 46)
```

は `async` method なので、実行要求を送信した時点で呼び出し元に戻る。結果は返さない。

## 3. Invocation policy

remote method invocation には以下の 3 種類を用意する。

```text
sync
async
future
```

### sync

```ruby
sync def get(key)
  @cache[key]
end
```

呼び出し元は owner Ractor 上での実行完了を待つ。

メソッド本来の返り値を呼び出し元に返す。

```ruby
value = cache.get(:foo)
```

概念的には、

```text
request
  ↓
owner executes
  ↓
reply
  ↓
caller resumes
```

となる。

### async

```ruby
async def set(key, value)
  @cache[key] = value
end
```

fire-and-forget invocation とする。

呼び出し元は request を送信した時点で戻る。

owner Ractor 上での実行完了を待たない。

メソッド本来の返り値は呼び出し元には返さない。

呼び出し側に reply 用の Port/Future 等を作らないことを基本とする。

返り値は `nil` とする。

```ruby
cache.set(:foo, 1)
# => nil
```

### future

```ruby
future def load(key)
  expensive_load(key)
end
```

request を owner Ractor に送信し、呼び出し元には Future を即座に返す。

```ruby
f = cache.load(:foo)

# other work

value = f.value
```

Future は owner Ractor 上で method execution が終了すると resolve される。

method execution が例外終了した場合、Future から値を取得した時点でその例外を再送出する。

## 4. Method modifier

以下の構文を提供する。

```ruby
sync def foo(...)
  ...
end

async def bar(...)
  ...
end

future def baz(...)
  ...
end
```

Ruby の、

```ruby
private def foo
end
```

と同様に、`sync`、`async`、`future` は直後に定義された method に属性を付与する DSL として実装する。

内部的には各 method に、

```text
:sync
:async
:future
```

の invocation policy を記録する。

## 5. デフォルト policy

modifier を付けない通常の、

```ruby
def foo
end
```

については `sync` をデフォルトとする。

したがって、

```ruby
class Counter < Ractor::ActiveObject
  def value
    @value
  end

  async def increment
    @value += 1
  end
end
```

は、

```ruby
class Counter < Ractor::ActiveObject
  sync def value
    @value
  end

  async def increment
    @value += 1
  end
end
```

と同義とする。

理由は、通常の Ruby method call の semantics に最も近いのが `sync` であるため。

`async` は明示的に指定させる。

## 6. owner Ractor からの呼び出し

owner Ractor 自身から ActiveObject の method を呼び出した場合は、mailbox を経由せず通常の Ruby method invocation として直接実行する。

例えば、

```ruby
class Counter < Ractor::ActiveObject
  async def increment
    @value += 1
  end

  sync def increment_and_get
    increment
    @value
  end
end
```

`increment_and_get` 内の `increment` は async request を enqueue してはならない。

owner 上なので、通常の、

```ruby
increment
```

として即座に実行する。

したがって `sync` / `async` / `future` は、原則として **remote invocation policy** を意味する。

method 自体の通常の Ruby semantics を変更するものではない。

これは再帰呼び出しや method 間呼び出しでも同様とする。

## 7. 呼び出し側から policy を明示する API

method 宣言で指定した policy はデフォルトであり、呼び出し側から override できるようにする。

以下を提供する。

```ruby
obj.sync_send(method_name, *args, **kwargs, &block)
obj.async_send(method_name, *args, **kwargs, &block)
obj.future_send(method_name, *args, **kwargs, &block)
```

対応関係は以下。

```text
method modifier    explicit invocation

sync               sync_send
async              async_send
future             future_send
```

例えば、

```ruby
class Cache < Ractor::ActiveObject
  async def set(key, value)
    @cache[key] = value
  end

  sync def get(key)
    @cache[key]
  end
end
```

通常は、

```ruby
cache.set(:x, 1)       # async
cache.get(:x)          # sync
```

だが、この呼び出しだけ policy を変更できる。

```ruby
cache.sync_send(:set, :x, 1)
```

これは `set` の実行完了を待つ。

```ruby
f = cache.future_send(:get, :x)
```

これは `get` を Future invocation とする。

```ruby
cache.async_send(:get, :x)
```

これは `get` の返り値を捨てて fire-and-forget する。

explicit send API は method declaration の policy より常に優先する。

## 8. 通常の method call

通常の、

```ruby
obj.foo(args)
```

については、その method に登録された invocation policy を参照する。

概念的には、

```ruby
case invocation_policy(:foo)
when :sync
  sync_send(:foo, ...)
when :async
  async_send(:foo, ...)
when :future
  future_send(:foo, ...)
end
```

に相当する。

ただし owner Ractor 上からの invocation はこの dispatch を行わず直接 method を実行する。

## 9. 状態の ownership

ActiveObject の instance variables およびそこから到達可能な mutable object graph は、原則として owner Ractor の private state とする。

例えば、

```ruby
class Cache < Ractor::ActiveObject
  def initialize
    @cache = {}
    @hits = 0
    @misses = 0
  end
end
```

では、

```text
@cache
@hits
@misses
```

を個別の共有 state と考えない。

`Cache` instance の state 全体を owner Ractor が所有する。

したがって TVar/STM のような、

```text
複数の独立した shared state location を transaction に参加させる
```

モデルではない。

ActiveObject 内の 1 回の method execution が、その object graph に対する serialized critical section に相当する。

## 10. method argument

remote invocation の argument は Ractor 間で送信可能でなければならない。

基本的には既存の Ractor send semantics に従う。

可能であれば、

```ruby
obj.foo(arg)
```

の argument transfer semantics は通常の `Ractor#send` と一致させる。

move/copy/shareable の扱いについて ActiveObject 独自のルールは極力導入しない。

block を remote invocation に渡す仕様については初期実装では必須としない。

特に arbitrary block を別 Ractor に送る場合は shareability の問題があるため、まずは positional/keyword arguments のみでもよい。

## 11. 戻り値

### sync

method result を caller Ractor に返す。

Ractor 間で返却可能である必要がある。

### async

method result は破棄する。

caller には `nil` を返す。

### future

method result を Future に保存する。

Future から値を取り出す際に caller へ転送する。

## 12. 例外

### sync

owner 上で method が例外終了した場合、その例外を caller 側で再送出する。

```ruby
cache.get(:broken)
# => owner で発生した exception を caller に raise
```

必要に応じて remote backtrace information を保持する。

### future

Future を rejected state にする。

```ruby
future.value
```

で exception を再送出する。

### async

caller はすでに戻っているため、例外を caller に直接返せない。

最低限、ActiveObject 側で unhandled async exception を検出できる仕組みを設ける。

初期実装では、

```text
warning を出す
```

または、

```text
ActiveObject の error handler に渡す
```

程度でもよい。

async method の例外を完全に無視する仕様にはしない。

この部分は後で error supervision API を追加可能な設計にしておく。

## 13. ordering

同一 ActiveObject に送信された request は owner Ractor 上で一度に 1 件だけ実行する。

したがって、

```ruby
cache.async_send(:set, :x, 1)
cache.sync_send(:get, :x)
```

について、同一 caller からこの順序で送信された request が mailbox 上でも同順序になるなら、`get` は先行する `set` の完了後に実行される。

これは async mutation の後に sync invocation を barrier として利用できることを意味する。

例えば、

```ruby
cache.set(:x, 1)       # async
cache.sync_send(:nop)  # ここまでの処理完了を待つ
```

のような利用が可能になる。

ordering semantics は可能な限り Ractor message ordering semantics と一致させる。

## 14. Future

`future` invocation 用に最低限以下の interface を提供する。

```ruby
future.value
```

値が未確定なら待つ。

確定済みなら即座に返す。

method execution が例外終了していた場合は exception を raise する。

将来的には、

```ruby
future.ready?
future.wait
```

等を追加してよいが、初期 API は最小限でよい。

Future 自体は複数 Ractor から安全に参照できる必要があるかどうかを検討する。

初期実装では Future を作成した caller Ractor だけが利用可能でもよい。

## 15. lifecycle

```ruby
obj = Cache.new
```

で ActiveObject 用 owner Ractor を作成する。

owner Ractor は object の request loop を実行する。

概念的には、

```ruby
loop do
  request = receive

  begin
    result = object.__send__(request.method, *request.args, **request.kwargs)
    request.reply(result)
  rescue Exception => e
    request.reply_exception(e)
  end
end
```

のような構造となる。

ただし `async` request は reply destination を持たない。

## 16. Proxy と servant

classical Active Object pattern では Proxy と Servant を別オブジェクトとして実装する場合が多い。

本 API では Ruby object 自体を proxy として利用しつつ、実際の instance state は owner Ractor 上で操作する構造を目指す。

利用者からは、

```ruby
obj.foo
```

という通常の method invocation に見えるようにする。

内部実装上、

```text
caller-visible proxy object
owner-side servant object
```

を分離する必要がある場合は分離してよい。

ただし public API ではその差を露出させない。

## 17. introspection

以下のような introspection があると便利。

```ruby
obj.owner
obj.owner?
```

または class side で、

```ruby
Cache.invocation_policy(:get)
# => :sync

Cache.invocation_policy(:set)
# => :async
```

ただし初期実装では必須ではない。

## 18. visibility

`private` / `protected` semantics は可能な限り通常の Ruby に合わせる。

特に、

```ruby
private async def foo
end
```

あるいは、

```ruby
async private def foo
end
```

等との組み合わせについて DSL の実装可能性を確認する。

最低限、

```ruby
async def foo
end
private :foo
```

が正常に動作すればよい。

## 19. inheritance

invocation policy は method とともに継承する。

```ruby
class A < Ractor::ActiveObject
  async def foo
  end
end

class B < A
end
```

では `B#foo` も async。

override した場合は、新しい method definition の policy を使用する。

```ruby
class B < A
  sync def foo
  end
end
```

この場合 `B#foo` は sync。

modifier なしで override した場合はデフォルトで sync とする。

## 20. 最小 MVP

最初の実装では以下に絞る。

```ruby
class Foo < Ractor::ActiveObject
  def initialize(...)
  end

  sync def a(...)
  end

  async def b(...)
  end

  future def c(...)
  end
end
```

および、

```ruby
obj.a(...)
obj.b(...)
obj.c(...)

obj.sync_send(:method, ...)
obj.async_send(:method, ...)
obj.future_send(:method, ...)
```

を実装する。

必要な semantics は、

```text
sync
  remote execution
  wait
  return result
  propagate exception

async
  remote execution
  do not wait
  return nil
  no reply channel

future
  remote execution
  immediately return Future
  Future#value waits
  Future propagates result/exception
```

とする。

また、

```text
owner Ractor からの self-call / direct call
```

は mailbox を経由せず通常の Ruby invocation とする。

## 21. 非目標

初期実装では以下は対象外としてよい。

```text
STM
複数 ActiveObject にまたがる atomic transaction
distributed execution
network RPC
persistent storage
automatic sharding
priority scheduling
cancellation
deadline
supervision tree
transparent migration
```

これらは `Ractor::ActiveObject` の基本 abstraction とは独立した上位機能として考える。

## 22. 設計上の位置付け

`Ractor::ActiveObject` の中心的な abstraction は、

> shared state を複数 Ractor が直接操作するのではなく、その state を所有する Ractor に method invocation を送る。

ことである。

つまり、

```text
move data to computation
```

ではなく、

```text
move computation/request to the data owner
```

というモデルを採用する。

TVar/STM が複数 shared state location の atomic update を提供するのに対し、ActiveObject は 1 owner が保持する arbitrary Ruby object graph に対する serialized method execution を提供する。

Ruby 利用者から見た最終的な API は、

```ruby
class Cache < Ractor::ActiveObject
  async def set(key, value)
    @cache[key] = value
  end

  sync def get(key)
    @cache[key]
  end

  future def expensive_get(key)
    ...
  end
end
```

という、通常の Ruby class に invocation policy をわずかに付加した形を目標とする。


