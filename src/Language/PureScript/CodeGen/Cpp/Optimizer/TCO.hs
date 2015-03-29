-----------------------------------------------------------------------------
--
-- Module      :  Language.PureScript.CodeGen.Cpp.Optimizer.TCO
-- Copyright   :  (c) Phil Freeman 2013-14
-- License     :  MIT
--
-- Maintainer  :  Phil Freeman <paf31@cantab.net>
-- Stability   :  experimental
-- Portability :
--
-- |
-- This module implements tail call elimination.
--
-----------------------------------------------------------------------------

module Language.PureScript.CodeGen.Cpp.Optimizer.TCO (tco) where

import Language.PureScript.Options
import Language.PureScript.CodeGen.Cpp.AST

-- |
-- Eliminate tail calls
--
tco :: Options mode -> Cpp -> Cpp
tco opts | optionsNoTco opts = id
         | otherwise = tco'

tco' :: Cpp -> Cpp
tco' = everywhereOnCpp convert
  where
  tcoLabel :: String
  tcoLabel = "tco"
  tcoVar :: String -> String
  tcoVar arg = "__tco_" ++ arg
  copyVar :: String -> String
  copyVar arg = "__copy_" ++ arg
  convert :: Cpp -> Cpp
  convert cpp@(CppVariableIntroduction name (Just fn@CppFunction {})) =
    let
      (argss, body', replace) = collectAllFunctionArgs [] id fn
    in case () of
      _ | isTailCall name body' ->
            let
              allArgs = concat $ reverse argss
            in
              CppVariableIntroduction name (Just (replace (toLoop name allArgs body')))
        | otherwise -> cpp
  convert cpp = cpp
  collectAllFunctionArgs :: [[String]] -> (Cpp -> Cpp) -> Cpp -> ([[String]], Cpp, Cpp -> Cpp)
  collectAllFunctionArgs allArgs f (CppFunction ident args (CppBlock (body@(CppReturn _):_))) =
    collectAllFunctionArgs (args : allArgs) (\b -> f (CppFunction ident (map copyVar args) (CppBlock [b]))) body
  collectAllFunctionArgs allArgs f (CppFunction ident args body@(CppBlock _)) =
    (args : allArgs, body, f . CppFunction ident (map copyVar args))
  collectAllFunctionArgs allArgs f (CppReturn (CppFunction ident args (CppBlock [body]))) =
    collectAllFunctionArgs (args : allArgs) (\b -> f (CppReturn (CppFunction ident (map copyVar args) (CppBlock [b])))) body
  collectAllFunctionArgs allArgs f (CppReturn (CppFunction ident args body@(CppBlock _))) =
    (args : allArgs, body, f . CppReturn . CppFunction ident (map copyVar args))
  collectAllFunctionArgs allArgs f body = (allArgs, body, f)
  isTailCall :: String -> Cpp -> Bool
  isTailCall ident cpp =
    let
      numSelfCalls = everythingOnCpp (+) countSelfCalls cpp
      numSelfCallsInTailPosition = everythingOnCpp (+) countSelfCallsInTailPosition cpp
      numSelfCallsUnderFunctions = everythingOnCpp (+) countSelfCallsUnderFunctions cpp
    in
      numSelfCalls > 0
      && numSelfCalls == numSelfCallsInTailPosition
      && numSelfCallsUnderFunctions == 0
    where
    countSelfCalls :: Cpp -> Int
    countSelfCalls (CppApp (CppVar ident') _) | ident == ident' = 1
    countSelfCalls _ = 0
    countSelfCallsInTailPosition :: Cpp -> Int
    countSelfCallsInTailPosition (CppReturn ret) | isSelfCall ident ret = 1
    countSelfCallsInTailPosition _ = 0
    countSelfCallsUnderFunctions (CppFunction _ _ cpp') = everythingOnCpp (+) countSelfCalls cpp'
    countSelfCallsUnderFunctions _ = 0
  toLoop :: String -> [String] -> Cpp -> Cpp
  toLoop ident allArgs cpp = CppBlock $
        map (\arg -> CppVariableIntroduction arg (Just (CppVar (copyVar arg)))) allArgs ++
        [ CppLabel tcoLabel $ CppWhile (CppBooleanLiteral True) (CppBlock [ everywhereOnCpp loopify cpp ]) ]
    where
    loopify :: Cpp -> Cpp
    loopify (CppReturn ret) | isSelfCall ident ret =
      let
        allArgumentValues = concat $ collectSelfCallArgs [] ret
      in
        CppBlock $ zipWith (\val arg ->
                    CppVariableIntroduction (tcoVar arg) (Just val)) allArgumentValues allArgs
                  ++ map (\arg ->
                    CppAssignment (CppVar arg) (CppVar (tcoVar arg))) allArgs
                  ++ [ CppContinue tcoLabel ]
    loopify other = other
    collectSelfCallArgs :: [[Cpp]] -> Cpp -> [[Cpp]]
    collectSelfCallArgs allArgumentValues (CppApp fn args') = collectSelfCallArgs (args' : allArgumentValues) fn
    collectSelfCallArgs allArgumentValues _ = allArgumentValues
  isSelfCall :: String -> Cpp -> Bool
  isSelfCall ident (CppApp (CppVar ident') args) | ident == ident' && not (any isFunction args) = True
  isSelfCall ident (CppApp fn args) | not (any isFunction args) = isSelfCall ident fn
  isSelfCall _ _ = False
  isFunction :: Cpp -> Bool
  isFunction (CppFunction _ _ _) = True
  isFunction _ = False