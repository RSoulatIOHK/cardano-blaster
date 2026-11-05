use cardano/transaction.{OutputReference, Transaction}

validator locked {
  spend(datum: Option<Int>, claim: Int, _utxo: OutputReference, _tx: Transaction) {
    when datum is {
      None -> False
      Some(limit) -> {
        let above_limit = claim > limit
        let at_or_below_limit = claim <= limit
        above_limit && at_or_below_limit
      }
    }
  }
}
