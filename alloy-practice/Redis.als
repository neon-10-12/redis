module redisWatchModel

-- トランザクション状態を列挙
enum TxState {
  Active,
  Committed,
  Aborted
}

-- Redisのキーを抽象化
sig Key {}

-- Redisクライアント
sig Client {
  -- このクライアントが現在WATCHしているキー
  watchSet: set Key,
  -- このクライアントが書き込もうとしているキー
  modifiedKeys: set Key,
  -- トランザクション状態
  txState: TxState
}

fact watchInvalidation {
  all c1, c2: Client | 
    (c1 != c2 && some (c1.watchSet & c2.modifiedKeys)) => 
    -- c2がActiveやCommitted(=変更を実行した)なら c1はComittedになれない
    (c2.txState in (Active + Committed)) implies (c1.txState != Committed)
}


fact atomicity {
  all c: Client |
    (c.txState = Committed) implies 
      no disj c2: Client | 
        -- c2がWATCH対象のキーを変更した場合(かつActive/Committed)は衝突
        (some (c.watchSet & c2.modifiedKeys))
        && (c2.txState in (Active + Committed))
}


assert noDoubleCommitOnWatchedKey {
  no disj c1, c2: Client |
    (some (c1.watchSet & c2.modifiedKeys)) &&
    (c1.txState = Committed && c2.txState = Committed)
}

check noDoubleCommitOnWatchedKey for 4

---------------------------------------------------
