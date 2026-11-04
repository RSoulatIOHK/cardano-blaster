import Lake
open Lake DSL

package «CardanoBlaster» where
  moreLeanArgs := #["--threads=4"]

require Blaster from git "https://github.com/input-output-hk/Lean-blaster" @ "1cb5a63e0416f336caa3104c2654718e6f971bc9"
require PlutusCore from git "https://github.com/input-output-hk/PlutusCoreBlaster" @ "eed6584454a5c76de20f5b316fea203553d38452"
require CardanoLedgerApi from git "https://github.com/input-output-hk/CardanoLedgerApiBlaster" @ "0f3d284160b63b0d6b99219cc1fcccc80fe781e7"

lean_lib CardanoBlaster

lean_lib CardanoBlasterTests where
  srcDir := "Tests"

lean_exe «native-tests» where
  root := `Tests.Main
  supportInterpreter := true

@[default_target]
lean_exe «cardano-blaster» where
  root := `CardanoBlaster.Main
  supportInterpreter := true
