module GHCVM.CodeGen.Bind where

import StgSyn
import Id
import GHCVM.CodeGen.ArgRep
import GHCVM.CodeGen.Types
import GHCVM.CodeGen.Monad
import GHCVM.CodeGen.Rts
import GHCVM.CodeGen.Expr
import GHCVM.CodeGen.Env
import GHCVM.CodeGen.Name
import GHCVM.CodeGen.Layout
import GHCVM.Util
import Codec.JVM
import Control.Monad (forM)
import Data.Text (append, pack)
import Data.Foldable (fold)
import Data.Maybe (mapMaybe, maybe, fromJust)
import Data.Monoid ((<>))

closureCodeBody
  :: Bool                  -- whether this is a top-level binding
  -> Id                    -- the closure's name
  -> LambdaFormInfo        -- Lots of information about this closure
  -> [NonVoid Id]          -- incoming args to the closure
  -> Int                   -- arity, including void args
  -> StgExpr               -- body
  -> [Id]                  -- the closure's free vars
  -> CodeGen ()
closureCodeBody topLevel id lfInfo args arity body fvs = do
  setClosureClass $ idNameText id
  (fvLocs, initCodes) <- generateFVs fvs
  thisClass <- getClass
  if arity == 0 then
    thunkCode lfInfo fvLocs body
  else do
    setSuperClass stgFun
    defineMethod $ mkMethodDef thisClass [Public] "getArity" [] (ret jint)
                 $  iconst jint (fromIntegral arity)
                 <> greturn jint
    withMethod [Public] "enter" [contextType] void $ do
      n <- peekNextLocal
      let (argLocs, code, n') = mkCallEntry n args
          (_ , cgLocs) = unzip argLocs
      emit code
      setNextLocal n'
      bindArgs argLocs
      -- TODO: Implement marking for self loop
      -- markOffset
      withSelfLoop (id, cgLocs) $ do
        mapM_ bindFV fvLocs
        cgExpr body
    return ()
  -- Generate constructor
  let thisFt = obj thisClass
  let (fts, _) = unzip initCodes
  let codes = flip concatMap (indexList initCodes) $ \(i, (ft, code)) ->
        [
          gload thisFt 0,
          gload ft i,
          code
        ]
  superClass <- getSuperClass
  defineMethod . mkMethodDef thisClass [Public] "<init>" fts void $ fold
    [
       gload thisFt 0,
       invokespecial $ mkMethodRef superClass "<init>" [] void,
       fold codes,
       vreturn
    ]
  return ()

generateFVs :: [Id] -> CodeGen ([(NonVoid Id, CgLoc)], [(FieldType, Code)])
generateFVs fvs = do
  clClass <- getClass
  result <- forM (indexList nonVoidFvs) $ \(i, (nvId, ft)) -> do
    let fieldName = append "x" . pack . show $ i
    defineField $ mkFieldDef [Public, Final] fieldName ft
    let code = putfield $ mkFieldRef clClass fieldName ft
    return ((nvId, LocField ft clClass fieldName), (ft, code))
  return $ unzip result
  where nonVoidFvs = mapMaybe filterNonVoid fvs
        filterNonVoid fv = fmap (NonVoid fv,) ft
          where ft = repFieldType . idType $ fv

-- TODO: Implement eager blackholing
thunkCode :: LambdaFormInfo -> [(NonVoid Id, CgLoc)] -> StgExpr -> CodeGen ()
thunkCode lfInfo fvs body =
  setupUpdate lfInfo $ do
    mapM_ bindFV fvs
    cgExpr body

bindFV :: (NonVoid Id, CgLoc) -> CodeGen ()
bindFV (id, cgLoc)= rebindId id cgLoc

setupUpdate :: LambdaFormInfo -> CodeGen () -> CodeGen ()
setupUpdate lfInfo body
  -- ASSERT lfInfo is of form LFThunk
  | not (lfUpdatable lfInfo) = withEnterMethod stgThunk "enter"
  | lfStaticThunk lfInfo = withEnterMethod stgIndStatic "thunkEnter"
  | otherwise = withEnterMethod stgInd "thunkEnter"
  where withEnterMethod thunkType name = do
          setSuperClass thunkType
          withMethod [Public] "thunkEnter" [contextType] void body
          return ()