{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
module DA.Daml.LF.Simplifier2 (
    simplifyModule
) where

import Control.Lens
import Control.Monad.State.Strict
import DA.Daml.LF.Ast
import qualified  DA.Daml.LF.Ast.Subst as Subst
import Data.Bifunctor
import Data.Functor.Foldable
import Data.Map.Strict (Map)
import Data.Set (Set)
import Data.Tuple (swap)
import qualified Data.Map.Strict as Map
import qualified Data.NameMap as NM
import qualified Data.Set as Set
import qualified Data.Text.Extended as T

data FreshState = FreshState
    { tmVarCounter :: Int
    }

newtype FreshM a = FreshM{unFreshM :: State FreshState a}
    deriving (Functor, Applicative, Monad)

runFreshM :: FreshM a -> a
runFreshM act = evalState (unFreshM act) FreshState
    { tmVarCounter = 0
    }

freshTmVar :: FreshM ExprVarName
freshTmVar = FreshM $ do
    n <- state (\st -> let k = tmVarCounter st + 1 in (k, st{tmVarCounter = k}))
    pure (ExprVarName ("$v" <> T.show n))

simplifyModule :: World -> Version -> Module -> Module
simplifyModule world _version m = runFreshM $ do
    let worldForAnf = extendWorldSelf m world
    m <- onBodies (anfExpr Map.empty worldForAnf) m
    let worldForInline = extendWorldSelf m world
    m <- onBodies (inlineExpr worldForInline) m
    let worldForClean = extendWorldSelf m world
    m <- onBodies (pure . cleanExpr worldForClean) m
    pure m
  where
    onBodies :: (Expr -> FreshM Expr) -> Module -> FreshM Module
    onBodies f m = do
        let fOnDefValue d = do
            e <- f (dvalBody d)
            pure d{dvalBody = e}
        ds <- NM.traverse fOnDefValue (moduleValues m)
        pure m{moduleValues = ds}

------------------------------------------------------------
-- CLEANER
------------------------------------------------------------

data CleanerEnv = CleanerEnv
    { cRenamings :: Map ExprVarName ExprVarName
    , cWorld :: World
    }

cleanExpr :: World -> Expr -> Expr
cleanExpr world = fst . clean CleanerEnv{cRenamings = Map.empty, cWorld = world}

clean :: CleanerEnv -> Expr -> (Expr, Set ExprVarName)
clean env e0 = case e0 of
    EVar x -> case Map.lookup x (cRenamings env) of
        Just y -> (EVar y, Set.singleton y)
        Nothing -> (e0, Set.singleton x)
    -- let x = y in e1
    ELet (Binding (x, _) (EVar y)) e1 -> clean (cIntroRenaming x y env) e1
    ELet (Binding (x, t) e1) e2 ->
        let (e2', fvs2) = clean env e2 in
        if x `Set.member` fvs2 || mayDiverge (cWorld env) e1 then
            let (e1', fvs1) = clean env e1 in
            (ELet (Binding (x, t) e1') e2', fvs1 `Set.union` Set.delete x fvs2)
        else
            (e2', fvs2)
    ETmLam (x, t) e1 ->
        let (e1', fvs) = clean env e1 in
        (ETmLam (x, t) e1', Set.delete x fvs)
    ECase e1 as ->
        let (e1', fvs1) = clean env e1 in
        let handleAlt (CaseAlternative p e) =
                let (e', fvs) = clean env e in
                (CaseAlternative p e', fvs `Set.difference` patternVars p)
        in
        let (as', fvss) = unzip (map handleAlt as) in
        (ECase e1' as', fvs1 `Set.union` Set.unions fvss)
    _ ->
        let efvs = fmap (clean env) (project e0) in
        (embed (fmap fst efvs), Set.unions (fmap snd efvs))

cIntroRenaming :: ExprVarName -> ExprVarName -> CleanerEnv -> CleanerEnv
cIntroRenaming x y env = env{cRenamings = Map.insert x y (cRenamings env)}

mayDiverge :: World -> Expr -> Bool
mayDiverge world e = case e of
    EVal q -> case lookupValue q world of
        Left _ -> True
        Right d -> syntacticArity (dvalBody d) == 0
    EApp{} -> True
    ECase{} -> True -- TODO(MH): This is _very_ conservative.
    ELet{} -> error "let under let"
    _ -> False

------------------------------------------------------------
-- INLINER
------------------------------------------------------------

data VarInfo
    = AbstractVar
    | LetBoundVar{iArity :: Int, iExpr :: Expr}

infoArity :: VarInfo -> Int
infoArity info = case info of
    AbstractVar -> 0
    LetBoundVar{iArity = n} -> n

data InlineEnv = InlineEnv
    { iBoundVars :: Map ExprVarName VarInfo
    , iWorld :: World
    }

inlineExpr :: World -> Expr -> FreshM Expr
inlineExpr world e = do
    let env0 = InlineEnv
            { iBoundVars = Map.empty
            , iWorld = world
            }
    inline env0 e

inline :: InlineEnv -> Expr -> FreshM Expr
inline env e0 = case e0 of
    ELet b@(Binding (x, t) e1) e2 -> case e1 of
        -- let x = y in e2
        EVar y -> case Map.lookup y (iBoundVars env) of
            Just info -> ELet b <$> inline (iIntroTmVar x info env) e2
            Nothing -> error "Reference to unbound variable"
        EVal q
            | Right d <- lookupValue q (iWorld env)
            , let n = syntacticArity (dvalBody d)
            , n > 0
            -> ELet b <$> inline (iIntroTmVar x (LetBoundVar n (dvalBody d)) env) e2
        ETyLam{} -> handleLetLam b e2
        ETmLam{} -> handleLetLam b e2
        EApp{} -> case handleApp e1 of
            Just e1' -> do
                let bvs = Map.map infoArity (iBoundVars env)
                -- TODO(MH): We don't need a full ANF transformation here but
                -- only the lifting of the outermost lets and the alpha renaming.
                e0' <- anfExpr bvs (iWorld env) (ELet (Binding (x, t) e1') e2)
                inline env e0'
            Nothing -> ELet b <$> inline (iIntroTmVar x (LetBoundVar 0 e1) env) e2
        _ -> ELet <$> (Binding (x, t) <$> inline env e1) <*> inline (iIntroTmVar x (LetBoundVar 0 e1) env) e2
    ETmLam (x, t) e1 -> ETmLam (x, t) <$> inline (iIntroTmVar x AbstractVar env) e1
    ETyLam (t, k) e1 -> ETyLam (t, k) <$> inline env e1
    ECase e1 as -> do
        let handleAlt (CaseAlternative p e2) =
                CaseAlternative p <$> inline (iIntroAbstractTmVars (patternVars p) env) e2
        ECase <$> inline env e1 <*> traverse handleAlt as
    EApp{}
        | Just e0' <- handleApp e0 -> do
            let bvs = Map.map infoArity (iBoundVars env)
            -- TODO(MH): We don't need a full ANF transformation here but
            -- only the alpha renaming.
            e0'' <- anfExpr bvs (iWorld env) e0'
            inline env e0''
    _ -> pure e0
  where
    handleLetLam (Binding (x, t) e1) e2 = do
        e1' <- inline env e1
        let n = syntacticArity e1'
        ELet (Binding (x, t) e1') <$> inline (iIntroTmVar x (LetBoundVar n e1') env) e2
    handleApp e0 =
        let (f, as) = takeEApps e0 in
        case f of
            EVar x
                | Just LetBoundVar{iArity = n, iExpr = e1} <- Map.lookup x (iBoundVars env)
                , n == length as -- TODO(MH): Check that we never have more than `n` args.
                -> Just (apply e1 as)
            _ -> Nothing
    apply :: Expr -> [Arg] -> Expr
    apply e0 as = case as of
        [] -> e0
        TmArg e1:as -> case e0 of
            ETmLam (x, t) e2 -> ELet (Binding (x, Just t) e1) (apply e2 as)
            _ -> error $ "type or arity error: applying expr " ++ show e1 ++ " to " ++ show e0
        TyArg t1:as -> case e0 of
            -- TODO(MH): Repeated substitution is not efficient.
            ETyLam (v, _) e1 -> apply (Subst.applySubstInExpr (Subst.typeSubst v t1) e1) as
            _ -> error $ "type or arity error: applying type " ++ show t1 ++ " to " ++ show e0

iIntroTmVar :: ExprVarName -> VarInfo -> InlineEnv -> InlineEnv
iIntroTmVar x info env = env{iBoundVars = Map.insert x info (iBoundVars env)}

iIntroAbstractTmVars :: Set ExprVarName -> InlineEnv -> InlineEnv
iIntroAbstractTmVars xs env = env{iBoundVars = Map.fromSet (const AbstractVar) xs `Map.union` iBoundVars env}

------------------------------------------------------------
-- ANF TRANSFORMATION
------------------------------------------------------------

data AnfEnv = AnfEnv
    { aBoundVars :: Map ExprVarName Int -- arity of the free variable
    , aRenamings :: Map ExprVarName ExprVarName
    , aWorld :: World
    }

anfExpr :: Map ExprVarName Int -> World -> Expr -> FreshM Expr
anfExpr bvs world e =
    let env0 = AnfEnv
            { aBoundVars = bvs
            , aRenamings = Map.empty
            , aWorld = world
            }
    in
    fst <$> anf env0 e

anf :: AnfEnv -> Expr -> FreshM (Expr, Int)
anf env e0 = do
    (bs, e1, n) <- anf' env e0
    pure (mkELets bs e1, n)

anf' :: AnfEnv -> Expr -> FreshM ([Binding], Expr, Int)
anf' env e = case e of
    EVar x ->
        let x' = Map.findWithDefault x x (aRenamings env) in
        let n = Map.findWithDefault 0 x' (aBoundVars env) in
        pure ([], EVar x', n)
    EVal q -> do
        let n = case lookupValue q (aWorld env) of
                Left _ -> 0
                Right d -> runtimeArity (dvalBody d)
        pure ([], e, n)
    ETmLam (x, t) e0 -> aIntroTmVar env x 0 $ \env x -> do
        (e1, n) <- anf env e0
        pure ([], ETmLam (x, t) e1, n+1)
    ETyLam (t, k) e0 -> do
        (e1, n) <- anf env e0
        pure ([], ETyLam (t, k) e1, n)
    ELet (Binding (x, t) e1) e2 -> do
        (bs1, e1', n) <- anf' env e1
        aIntroTmVar env x n $ \env x -> do
            (bs2, e2', _) <- anf' env e2
            pure (bs1 ++ [Binding (x, t) e1'] ++ bs2, e2', 0)
    ECase e0 as0 -> do
        anfAtomic env e0 $ \_ bs e1 _ -> do
            let anfAlt (CaseAlternative p e) =
                    aIntroPattern env p $ \env p -> first (CaseAlternative p) <$> anf env e
            (as1, ns) <- unzip <$> traverse anfAlt as0
            pure (bs, ECase e1 as1, if null ns then 0 else minimum ns)
    ETyApp{} -> handleApp
    ETmApp{} -> handleApp
    EUpdate{} -> pure ([], e, 0)
    EScenario{} -> pure ([], e, 0)
    ELocation _ e' -> anf' env e'
    EBuiltin{} -> defaultAnf
    ERecCon{} -> defaultAnf
    ERecProj{} -> defaultAnf
    ERecUpd{} -> defaultAnf
    EVariantCon{} -> defaultAnf
    EEnumCon{} -> defaultAnf
    EStructCon{} -> defaultAnf
    EStructProj{} -> defaultAnf
    EStructUpd{} -> defaultAnf
    ENil{} -> defaultAnf
    ECons{} -> defaultAnf
    ESome{} -> defaultAnf
    ENone{} -> defaultAnf
    EToAny{} -> defaultAnf
    EFromAny{} -> defaultAnf
    ETypeRep{} -> defaultAnf
  where
    defaultAnf = do
        (bs, e') <- anfMany env (project e)
        pure (bs, embed e', 0)
    handleApp = do
        let (f0, as0) = takeEApps e
        anfAtomic env f0 $ \_ bsf f1 n -> do
            let k = max 1 n -- we must consume at least one argument, otherwise we'll loop
            let (as1, zs1) = splitAt k as0
            (bsas, as2) <- anfArgs env as1
            let (bs, e1) = (bsf ++ bsas, mkEApps f1 as2)
            if null zs1 then
                pure (bs, e1, k - length as1)
            else do
                x <- freshTmVar
                aIntroTmVar env x 0 $ \env x -> do
                    (bs', e2, _) <- anf' env (mkEApps (EVar x) zs1)
                    pure (bs ++ [Binding (x, Nothing) e1] ++ bs', e2, 0)

anfAtomic :: AnfEnv -> Expr -> (AnfEnv -> [Binding] -> Expr -> Int -> FreshM a) -> FreshM a
anfAtomic env e0 cont = do
    (bs, e1, n) <- anf' env e0
    if isAtomic e1 then
        cont env bs e1 n
    else do
        x <- freshTmVar
        aIntroTmVar env x n $ \env x -> do
        cont env (bs ++ [Binding (x, Nothing) e1]) (EVar x) n

anfMany :: Traversable t => AnfEnv -> t Expr -> FreshM ([Binding], t Expr)
anfMany env e0s = do
    let step env e0 = anfAtomic env e0 $ \env bs e1 _ -> pure (env, (bs, e1))
    (_, bse1s) <- mapAccumLM step env e0s
    pure (concatMap fst bse1s, fmap snd bse1s)

anfArgs :: AnfEnv -> [Arg] -> FreshM ([Binding], [Arg])
anfArgs env a0s = do
    let step env a0 = case a0 of
            TmArg e0 -> anfAtomic env e0 $ \env bs e1 _ -> pure (env, (bs, TmArg e1))
            TyArg{} -> pure (env, ([], a0))
    (_, bsa1s) <- mapAccumLM step env a0s
    pure (concatMap fst bsa1s, fmap snd bsa1s)

aIntroTmVar :: AnfEnv -> ExprVarName -> Int -> (AnfEnv -> ExprVarName -> FreshM a) -> FreshM a
aIntroTmVar env x n cont
    | x `Map.member` aBoundVars env = do
        y <- freshTmVar
        let env' = env
                { aBoundVars = Map.insert y n (aBoundVars env)
                , aRenamings = Map.insert x y (aRenamings env)
                }
        cont env' y
    | otherwise = do
        let env' = env{aBoundVars = Map.insert x n (aBoundVars env)}
        cont env' x

aIntroPattern :: AnfEnv -> CasePattern -> (AnfEnv -> CasePattern -> FreshM a) -> FreshM a
aIntroPattern env p cont = case p of
    CPVariant t c x -> aIntroTmVar env x 0 $ \env x -> cont env (CPVariant t c x)
    CPEnum{} -> cont env p
    CPUnit{} -> cont env p
    CPBool{} -> cont env p
    CPNil -> cont env p
    CPCons x y -> aIntroTmVar env x 0 $ \env x -> aIntroTmVar env y 0 $ \env y -> cont env (CPCons x y)
    CPNone -> cont env p
    CPSome x -> aIntroTmVar env x 0 $ \env x -> cont env (CPSome x)
    CPDefault -> cont env p

isAtomic :: Expr -> Bool
isAtomic e = case e of
    EVar{} -> True
    EBuiltin{} -> True
    ENil{} -> True
    ENone{} -> True
    _ -> False

------------------------------------------------------------
-- UTILITIES
------------------------------------------------------------

-- | Lower bound on the arity of the expression once it has been evaluated.
runtimeArity :: Expr -> Int
runtimeArity e0 = case e0 of
    ETyLam{} -> syntacticArity e0
    ETmLam{} -> syntacticArity e0
    ELet _ e1 -> runtimeArity e1
    ELocation _ e1 -> runtimeArity e1
    -- TODO(MH): Take partially applied top-level values into account
    _ -> 0

-- | Number of leading lambdas of the expression.
syntacticArity :: Expr -> Int
syntacticArity e0 = case e0 of
    ETmLam _ e1 -> syntacticArity e1 + 1
    ETyLam _ e1 -> syntacticArity e1 + 1
    ELocation _ e1 -> syntacticArity e1
    _ -> 0

patternVars :: CasePattern -> Set ExprVarName
patternVars p = case p of
    CPVariant _ _ x -> Set.singleton x
    CPEnum _ _ -> Set.empty
    CPUnit -> Set.empty
    CPBool _ -> Set.empty
    CPNil -> Set.empty
    CPCons x y -> Set.fromList [x, y]
    CPNone -> Set.empty
    CPSome x -> Set.singleton x
    CPDefault -> Set.empty

pattern EApp :: Expr -> Arg -> Expr
pattern EApp fun arg <- (matching _EApp -> Right (fun, arg))
  where
    EApp fun arg = mkEApp fun arg

-- | Monadic version of mapAccumL
mapAccumLM :: forall t m acc x y. (Traversable t, Monad m) =>
    (acc -> x -> m (acc, y)) -> acc -> t x -> m (acc, t y)
mapAccumLM f z0 xs =
    let g x = StateT $ \z -> swap <$> f z x in
    swap <$> runStateT (traverse g xs) z0