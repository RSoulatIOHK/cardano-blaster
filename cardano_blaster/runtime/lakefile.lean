import Lake
open Lake DSL

package «CardanoBlaster» where
  moreLeanArgs := #["--threads=4"]

require Blaster from git "https://github.com/input-output-hk/Lean-blaster" @ "1cb5a63e0416f336caa3104c2654718e6f971bc9"
require PlutusCore from git "https://github.com/input-output-hk/PlutusCoreBlaster" @ "8ceb98c71a279a2796bbffe26720a454971fdddc"
require CardanoLedgerApi from git "https://github.com/input-output-hk/CardanoLedgerApiBlaster" @ "5492bb0d8e5ee01587303c153440636e5f8ee933"
