{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
module Main where
import Data.Aeson (encode, object, (.=))
import Data.ByteString.Lazy.Char8 qualified as BS
import PlutusLedgerApi.V3 qualified as V3
import SourceTypes (sourceTypes, sourceCases)
import System.Environment (getArgs)
main :: IO ()
main = do
  args <- getArgs
  case args of
    [] -> BS.putStrLn $ encode $ object
      [ "format" .= ("haskell-source-types-v1" :: String)
      , "package" .= ("plutus-ledger-api-1.72.0.0" :: String)
      , "types" .= $(sourceTypes [[t|V3.ScriptContext|], [t|V3.TxInfo|], [t|V3.ScriptInfo|]])
      ]
    ["--fixtures"] -> BS.putStrLn $ encode
      $(sourceCases [[t|V3.ScriptContext|], [t|V3.TxInfo|], [t|V3.ScriptInfo|]])
    _ -> fail "GenerateSourceTypes [--fixtures]"
