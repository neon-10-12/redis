# Alloyによる形式検証の実習
## 検証対象のOSS

Redis は、キーバリュー型のインメモリデータストアであり、高速な読書き性能と豊富なデータ型をサポートする OSS である。主な特徴・機能は以下のとおり。

* データはメモリ上に保持し、必要に応じてディスクに保存（RDBスナップショットやAOF方式など）
* シンプルなトランザクション機構（MULTI / EXEC / WATCH など）を備えている

今回は、この Redisのトランザクション機構（MULTI / EXEC / WATCH） を簡易的にモデル化し、競合が起きた場合には WATCH による「条件付きトランザクション」が適切に失敗(Abort)する という性質を検証したい。

Redis の WATCH 機能は、特定のキーを監視し、もし別クライアントが監視中にそのキーを変更したら、後続の EXEC が失敗する（トランザクション全体が取り消し）という動作を行う。
これは「悲観的ロック」ではなく「楽観的制御」に近く、複数クライアントが同時に WATCH & 更新をしようとすると、競合したものは自動的に失敗する。
ここでは、このWATCH 機能が正しく動作して競合を防いでいるかを Alloy で抽象化し、競合バグの有無を形式的に検証する。

## 検証すべき性質

1. Redisトランザクションに関する性質：
あるクライアントが WATCH keyA を行ったあとに MULTI → (書き込みコマンド) → EXEC を実行しようとする。
その間に 別のクライアントが keyA を変更 すると、最初のクライアントの EXEC は自動的に失敗する。
これにより、衝突が起きた際にはトランザクションが部分的に成功することがなく、安全に失敗する。
EXEC の呼び出し時に、WATCH したキーが変更されなかった場合のみコマンドが一括実行される。途中での部分的成功・失敗はない。

2. 仕様として妥当である理由：
[Redis公式ドキュメント](https://redis.io/docs/manual/transactions/)により、WATCH はキーの変更が起こらないことを前提にトランザクションを実行する仕組み、とされている。
衝突が起きた場合はトランザクション全体がアボートし、再試行（ロジック側でリトライ）するのが基本的な使用法。
もし WATCH が意図通りに機能しなかった場合は、複数クライアントの同時書き込み競合が起きてデータ破壊（整合性欠如）を起こしうる。


## モデル化

1. モデル化の方針
実際の Redis をすべて Alloy に落とし込むのは大変なので、WATCH の動作に絞って抽象化する。以下のように設計する：

* TxState
    + Active：トランザクションが実行中であること。
    + Committed：トランザクションが問題なく完了したこと。
    + Aborted：トランザクションが失敗し、実行されなかったこと。

* Key
    + 単純なキーの集合。
    + 実際の値やデータ型は無視し、キーが書き換えられたかどうかだけを検証対象にする。

* Client：Redisに接続して操作を行うクライアント。
    + watchSet：監視しているキーの集合。
    + modifiedKeys：そのクライアントが書き込もうとしているキー集合。
    + txState：トランザクションの状態を { Active, Committed, Aborted } の3種類で抽象化。

* watchInvalidation
    + あるキー k を WATCH しているクライアントがいる状態で、別のクライアントが k を変更した場合、WATCH していたクライアントのトランザクションは必ず Aborted になる（もしくはEXEC時に失敗する）。
    + “C1があるキーKをWATCHしている最中に、C2が同じKを変更する” → C2が実際にコミット/アクティブなら、C1は Committed になれない。
    実際のRedisでは EXEC 時に失敗するが、Alloyモデルでは「C1が Committed になるのを禁止する」 という形で表現。

* atomicity
    + トランザクションが Committed 状態になるためには、監視中のキー（watchSet）が他のクライアントによって変更されていないことを要求。
    + “Committed” なクライアントは、WATCH 中のキーが他クライアントに書き換えられていないはず。
    もし書き換えがあったら C1は本来失敗すべきなので、モデル上も Committed として成立しないようにしている。

上記のように設計した Alloy コード(Redis.als)を alloy-practice ディレクトリ内においておく。


## 検証手法

小スコープ仮説に基づいて、スコープを for 10 など小規模に設定し、全ての Client / Key の組み合わせを網羅的に探索する。
また、安全性の検証のために alloy の check 機能で assert した不変条件を満たすかを検証する。
もし2つのクライアントが同じキーを WATCH & 書き込みしたのに両方 Committed しちゃうようなモデルがあれば、それは反例として出力される。

## 補足事項

Alloy の実行結果を以下に示す。

```planintext
Executing "Check noDoubleCommitOnWatchedKey for 10"
   Actual scopes: exactly 3 TxState, exactly 1 Active, exactly 1 Committed, exactly 1 Aborted, 10 Key, 10 Client, exactly 1 ordering/Ord
   Solver=sat4j Bitwidth=4 MaxSeq=7 SkolemDepth=1 Symmetry=20 Mode=batch
   4682 vars. 270 primary vars. 7863 clauses. 156ms.
   No counterexample found. Assertion may be valid. 24ms.
```

上記の結果から、同じキーを WATCH している複数のクライアントが、両方とも Committed 状態になるような競合状態は存在しないと考えられる。