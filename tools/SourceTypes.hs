{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}

-- Developer-only reflection against the pinned Haskell ledger API. The shipped
-- CLI embeds the result; users do not need GHC to reconstruct a counterexample.
module SourceTypes (sourceTypes, sourceCases) where

import Control.Monad (forM)
import Data.Aeson (Value, object, (.=))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Language.Haskell.TH qualified as TH
import Language.Haskell.TH.Datatype qualified as D
import PlutusLedgerApi.V3 qualified as V3
import PlutusTx.AssocMap qualified as AM
import PlutusTx.Ratio qualified as Ratio

typeKey :: TH.Type -> String
typeKey = TH.pprint

headArgs :: TH.Type -> (TH.Type, [TH.Type])
headArgs = go [] where
  go args (TH.AppT f x) = go (x : args) f
  go args t = (t, args)

subst :: Map.Map TH.Name TH.Type -> TH.Type -> TH.Type
subst env = \case
  TH.VarT n -> Map.findWithDefault (TH.VarT n) n env
  TH.AppT a b -> TH.AppT (subst env a) (subst env b)
  TH.SigT t _ -> subst env t
  t -> t

datatype :: TH.Type -> TH.Q [(TH.Name, [(Maybe TH.Name, TH.Type)])]
datatype ty = do
  let (TH.ConT n, args) = headArgs ty
  info <- D.reifyDatatype n
  let env = Map.fromList (zip (D.datatypeVars info >>= \case
        TH.PlainTV v _ -> [v]
        TH.KindedTV v _ _ -> [v]) args)
  forM (D.datatypeCons info) $ \c -> do
    fs <- traverse (D.resolveTypeSynonyms . subst env) (D.constructorFields c)
    let labels = case D.constructorVariant c of
          D.RecordConstructor ns -> map Just ns
          _ -> repeat Nothing
    pure (D.constructorName c, zip labels fs)

atom :: TH.Type -> Maybe String
atom ty = case headArgs ty of
  (TH.ConT n, []) | n == ''Integer -> Just "integer"
  (TH.ConT n, []) | n == ''V3.BuiltinByteString -> Just "bytes"
  (TH.ConT n, []) | n == ''V3.BuiltinData -> Just "data"
  _ -> Nothing

special :: TH.Type -> Maybe (String, [TH.Type])
special ty = case headArgs ty of
  (TH.ListT, [a]) -> Just ("list", [a])
  (TH.ConT n, [k,v]) | n == ''AM.Map -> Just ("map", [k,v])
  (TH.ConT n, []) | n == ''Ratio.Rational -> Just ("ratio", [])
  _ -> Nothing

-- Representatives are used only to ask the real ToData instance for its wire
-- layout and constructor index. Neither declaration order nor display titles
-- are used as an encoding authority.
sample :: Int -> TH.Type -> TH.ExpQ
sample depth raw = do
  ty <- D.resolveTypeSynonyms raw
  case atom ty of
    Just "integer" -> [| 0 :: Integer |]
    Just "bytes" -> [| V3.toBuiltin (mempty :: ByteString) :: V3.BuiltinByteString |]
    Just "data" -> [| V3.dataToBuiltinData (V3.I 0) |]
    _ -> case special ty of
      Just ("list", _) -> [| [] |]
      Just ("map", _) -> [| AM.unsafeFromList [] |]
      Just ("ratio", _) -> [| Ratio.unsafeRatio 0 1 |]
      _ | depth <= 0 -> fail ("No finite source representative for " ++ typeKey ty)
      _ -> do
        cs <- case headArgs ty of
          (TH.TupleT 2, [a,b]) -> pure [('(,), [(Nothing,a),(Nothing,b)])]
          _ -> datatype ty
        let build (c,fs) = foldl TH.appE (TH.conE c) (map (sample (depth-1) . snd) fs)
        foldr TH.recover (fail ("No source representative for " ++ typeKey ty)) (map build cs)

layout :: V3.Data -> [V3.Data] -> Value
layout wire fields = case wire of
  V3.Constr index xs | xs == fields -> object ["kind" .= ("constructor" :: String), "index" .= index]
  V3.List xs | xs == fields -> object ["kind" .= ("tuple-list" :: String)]
  _ | [wire] == fields -> object ["kind" .= ("transparent" :: String)]
  _ -> error "The source codec is not a structural constructor/list/newtype encoding"

sourceTypes :: [TH.TypeQ] -> TH.ExpQ
sourceTypes roots = do
  initial <- traverse (>>= D.resolveTypeSynonyms) roots
  nodes <- walk Set.empty initial
  TH.listE nodes
  where
    walk _ [] = pure []
    walk seen (ty:rest)
      | Set.member (typeKey ty) seen = walk seen rest
      | otherwise = do
          let key = typeKey ty
              seen' = Set.insert key seen
          (body, children) <- case atom ty of
            Just kind -> pure ([| object ["kind" .= (kind :: String)] |], [])
            Nothing -> case special ty of
              Just (kind, children) ->
                let keys = map typeKey children
                in if kind == "ratio"
                  then pure ([| object ["kind" .= (kind :: String),
                    "layout" .= layout (V3.toData (Ratio.unsafeRatio 0 1)) [V3.I 0, V3.I 1]] |], children)
                  else pure ([| object ["kind" .= (kind :: String), "args" .= (keys :: [String])] |], children)
              _ -> do
                cs <- case headArgs ty of
                  (TH.TupleT 2, [a,b]) -> pure [('(,), [(Nothing,a),(Nothing,b)])]
                  _ -> datatype ty
                constructors <- forM cs $ \(c, fs) -> do
                  let label n = maybe "" TH.nameBase n
                      names = map (label . fst) fs
                      types = map (typeKey . snd) fs
                      ctor = TH.nameBase c
                      modName = maybe "Prelude" id (TH.nameModule c)
                  fields <- traverse (sample 30 . snd) fs
                  let value = foldl TH.AppE (TH.ConE c) fields
                  pure [| object ["name" .= (ctor :: String), "module" .= (modName :: String),
                    "fields" .= zip (names :: [String]) (types :: [String]),
                    "layout" .= layout (V3.toData ($(pure value) :: $(pure ty)))
                      $(TH.listE (zipWith (\f (_, t) -> [| V3.toData ($(pure f) :: $(pure t)) |]) fields fs))] |]
                pure ([| object ["kind" .= ("variants" :: String), "constructors" .= $(TH.listE constructors)] |],
                  concatMap (map snd . snd) cs)
          remaining <- walk seen' (children ++ rest)
          pure ([| (key :: String, $body) |] : remaining)

portableData :: V3.Data -> Value
portableData = \case
  V3.I i -> con "I" [("value", object ["kind" .= ("integer" :: String), "value" .= show i])]
  V3.B b -> con "B" [("value", object ["kind" .= ("bytes" :: String), "hex" .= concatMap byteHex (BS.unpack b)])]
  V3.List xs -> con "List" [("values", list (map portableData xs))]
  V3.Map xs -> con "Map" [("entries", list [object ["kind" .= ("constructor" :: String),
    "type" .= ("Prod" :: String), "constructor" .= ("Prod.mk" :: String),
    "fields" .= fields [("fst", portableData a), ("snd", portableData b)]] | (a,b) <- xs])]
  V3.Constr n xs -> con "Constr" [("index", object ["kind" .= ("integer" :: String), "value" .= show n]),
    ("fields", list (map portableData xs))]
  where
    list xs = object ["kind" .= ("list" :: String), "values" .= xs]
    fields xs = [object ["name" .= (n :: String), "value" .= v] | (n,v) <- xs]
    con n fs = object ["kind" .= ("constructor" :: String), "type" .= ("PlutusCore.Data" :: String),
      "constructor" .= (n :: String), "fields" .= fields fs]
    byteHex n = ["0123456789abcdef" !! (fromIntegral n `div` 16), "0123456789abcdef" !! (fromIntegral n `mod` 16)]

-- Independent test inputs encoded by Haskell, including every reachable sum
-- constructor, rather than just the constructors present in the Auction demo.
sourceCases :: [TH.TypeQ] -> TH.ExpQ
sourceCases roots = do
  initial <- traverse (>>= D.resolveTypeSynonyms) roots
  walk Set.empty initial >>= TH.listE
  where
    walk _ [] = pure []
    walk seen (ty:rest)
      | Set.member (typeKey ty) seen = walk seen rest
      | otherwise = do
          let key = typeKey ty
          (values, children) <- case atom ty of
            Just _ -> pure ([sample 30 ty], [])
            Nothing -> case special ty of
              Just (_, ts) -> pure ([sample 30 ty], ts)
              _ -> do
                cs <- datatype ty
                let build (c,fs) = foldl TH.appE (TH.conE c) (map (sample 30 . snd) fs)
                pure (map build cs, concatMap (map snd . snd) cs)
          let cases = map (\v -> [| object ["type" .= (key :: String),
                "wire" .= portableData (V3.toData ($v :: $(pure ty))) ] |]) values
          (cases ++) <$> walk (Set.insert key seen) (children ++ rest)
