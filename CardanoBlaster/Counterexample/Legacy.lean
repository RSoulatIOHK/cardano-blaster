import CardanoLedgerApi.V3
import PlutusCore.UPLC.BlueprintEncoding.Counterexample

namespace CardanoBlaster.Counterexample
open Blaster.Counterexample
open CardanoLedgerApi.IsData.Class

-- Keep the ledger wire encoding for legacy ScriptContexts as well. The
-- source exporter emits a matching FromData attempt; the raw Lean model may
-- include Data fields that do not decode as Haskell ledger types.
instance : ToCEX CardanoLedgerApi.V1.Contexts.ScriptContext := ⟨fun ctx =>
  .encoded "PlutusLedgerApi.V1.ScriptContext" "plutus-data"
    (toCEX (IsData.toData ctx))⟩

instance : ToCEX CardanoLedgerApi.V2.Contexts.ScriptContext := ⟨fun ctx =>
  .encoded "PlutusLedgerApi.V2.ScriptContext" "plutus-data"
    (toCEX (IsData.toData ctx))⟩

end CardanoBlaster.Counterexample
