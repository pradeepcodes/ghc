{-# LANGUAGE PatternGuards #-}
module Supercompile.Evaluator.Evaluate (normalise, step) where

#include "HsVersions.h"

import Supercompile.Evaluator.Deeds
import Supercompile.Evaluator.FreeVars
import Supercompile.Evaluator.Residualise
import Supercompile.Evaluator.Syntax

import Supercompile.Core.Renaming
import Supercompile.Core.Syntax

import Supercompile.StaticFlags
import Supercompile.Utilities

import qualified Data.Map as M

import qualified CoreSyn as CoreSyn
import Coercion
import TyCon
import Type
import PrelRules
import Id
import DataCon
import Pair
import Util (splitAtList)


evaluatePrim :: Tag -> PrimOp -> [Answer] -> Maybe (Anned Answer)
evaluatePrim tg pop args = do
    args' <- mapM to args
    (res:_) <- return [res | CoreSyn.BuiltinRule { CoreSyn.ru_nargs = nargs, CoreSyn.ru_try = f }
                          <- primOpRules pop (error "evaluatePrim: dummy primop name")
                      , nargs == length args
                      , Just res <- [f (const CoreSyn.NoUnfolding) args']]
    fmap (annedAnswer tg) $ fro res
  where
    to :: Answer -> Maybe CoreSyn.CoreExpr
    to (mb_co, (rn, v)) = fmap (maybe id (flip CoreSyn.Cast . fst) mb_co) $ case v of
        Literal l      -> Just (CoreSyn.Lit l)
        Data dc tys xs -> Just (CoreSyn.Var (dataConWrapId dc) `CoreSyn.mkTyApps` tys `CoreSyn.mkVarApps` map (rename rn) xs)
        _              -> Nothing
    
    fro :: CoreSyn.CoreExpr -> Maybe Answer
    fro (CoreSyn.Cast e co) = fmap (\(mb_co', in_v) -> (Just (maybe co (\(co', _) -> co' `mkTransCo` co) mb_co', tg), in_v)) $ fro e
    fro (CoreSyn.Lit l)     = Just (Nothing, (emptyRenaming, Literal l))
    fro e | CoreSyn.Var f <- e_fun, Just dc <- isDataConId_maybe f, [] <- e_args'' = Just (Nothing, (mkIdentityRenaming (unionVarSets (map tyVarsOfType tys) `extendVarSetList` xs), Data dc tys xs))
          | otherwise = Nothing
      where (e_fun, e_args) = CoreSyn.collectArgs e
            (tys, e_args') = takeWhileJust toType_maybe e_args
            (xs, e_args'') = takeWhileJust toVar_maybe  e_args'
            
            toType_maybe (CoreSyn.Type ty) = Just ty
            toType_maybe _                 = Nothing
            
            toVar_maybe (CoreSyn.Var x) = Just x
            toVar_maybe _               = Nothing

castAnswer :: Answer -> Maybe (Out Coercion, Tag) -> Answer
castAnswer (mb_co, in_v) mb_co' = (plusMaybe (\(co, _tg) (co', tg') -> (co `mkTransCo` co', tg')) mb_co mb_co', in_v)


-- | Non-expansive simplification we can do everywhere safely
--
-- Normalisation only ever releases deeds: it is *never* a net consumer of deeds. So normalisation
-- will never be impeded by a lack of deeds.
normalise :: UnnormalisedState -> State
normalise = snd . step' True

-- | Possibly non-normalising simplification we can only do if we are allowed to by a termination test
--
-- Unlike normalisation, stepping may be a net consumer of deeds and thus be impeded by a lack of them.
step :: State -> Maybe State
step s = guard reduced >> return result
  where (reduced, result) = step' False $ denormalise s

step' :: Bool -> UnnormalisedState -> (Bool, State) -- The flag indicates whether we managed to reduce any steps *at all*
step' normalising state =
    (\res@(_reduced, stepped_state) -> ASSERT2(noChange (releaseUnnormalisedStateDeed state) (releaseStateDeed stepped_state),
                                               hang (text "step': deeds lost or gained:") 2 (pPrintFullUnnormalisedState state $$ pPrintFullState stepped_state))
                                       ASSERT2(subVarSet (stateFreeVars stepped_state) (unnormalisedStateFreeVars state),
                                               text "step': FVs" $$ pPrint (unnormalisedStateFreeVars state) $$ pPrintFullUnnormalisedState state $$ pPrint (stateFreeVars stepped_state) $$ pPrintFullState stepped_state)
                                       -- traceRender (text "normalising" $$ nest 2 (pPrintFullUnnormalisedState state) $$ text "to" $$ nest 2 (pPrintFullState stepped_state)) $
                                       res) $
    go state
  where
    go :: (Deeds, Heap, Stack, In AnnedTerm) -> (Bool, State)
    go (deeds, h@(Heap _ ids), k, (rn, e)) 
     | Just anned_a <- termToAnswer ids (rn, e) = go_answer (deeds, h, k, anned_a)
     | otherwise = case annee e of
        Var x             -> go_question (deeds, h, k, fmap (const (rename rn x)) e)
        TyApp e ty        -> go (deeds, h, Tagged tg (TyApply (renameType ids rn ty))                             : k, (rn, e))
        App e x           -> go (deeds, h, Tagged tg (Apply (rename rn x))                                        : k, (rn, e))
        PrimOp pop (e:es) -> go (deeds, h, Tagged tg (PrimApply pop [] (map ((,) rn) es))                         : k, (rn, e))
        Case e x ty alts  -> go (deeds, h, Tagged tg (Scrutinise (rename rn x) (renameType ids rn ty) (rn, alts)) : k, (rn, e))
        Cast e co         -> go (deeds, h, Tagged tg (CastIt (renameCoercion ids rn co))                          : k, (rn, e))
        LetRec xes e      -> go (allocate (deeds + 1) h k (rn, (xes, e)))
        _                 -> panic "reduced" (text "Impossible expression" $$ ppr1 e)
      where tg = annedTag e

    go_question (deeds, h, k, anned_x) = maybe (False, (deeds, h, k, fmap Question anned_x)) (\s -> (True, normalise s)) $ force  deeds h k (annedTag anned_x) (annee anned_x)
    go_answer   (deeds, h, k, anned_a) = maybe (False, (deeds, h, k, fmap Answer anned_a))   (\s -> (True, normalise s)) $ unwind deeds h k (annedTag anned_a) (annee anned_a)

    allocate :: Deeds -> Heap -> Stack -> In ([(Var, AnnedTerm)], AnnedTerm) -> UnnormalisedState
    allocate deeds (Heap h ids) k (rn, (xes, e)) = (deeds, Heap (h `M.union` M.fromList [(x', internallyBound in_e) | (x', in_e) <- xes']) ids', k, (rn', e))
      where (ids', rn', xes') = renameBounds ids rn xes

    prepareAnswer :: Deeds
                  -> Out Var -- ^ Name to which the value is bound
                  -> Answer  -- ^ Bound value, which we have *exactly* 1 deed for already that is not recorded in the Deeds itself
                  -> Maybe (Deeds, Answer) -- Outgoing deeds have that 1 latent deed included in them, and we have claimed deeds for the outgoing value
    prepareAnswer deeds x' a
      | dUPLICATE_VALUES_EVALUATOR = fmap (flip (,) a) $ claimDeeds (deeds + 1) (answerSize' a)
       -- Avoid creating indirections to indirections: implements indirection compression
      | (_, (_, Indirect _)) <- a  = return (deeds, a)
      | otherwise                  = return (deeds, (Nothing, (mkIdentityRenaming (unitVarSet x'), Indirect x')))

    -- We have not yet claimed deeds for the result of this function
    lookupAnswer :: Heap -> Out Var -> Maybe (Anned Answer)
    lookupAnswer (Heap h ids) x' = do
        hb <- M.lookup x' h
        case heapBindingTerm hb of
          Just in_e -> termToAnswer ids in_e -- FIXME: it would be cooler if we could exploit cheap non-values in unfoldings as well..
          Nothing   -> Nothing
    
    -- Deal with a variable at the top of the stack
    -- Might have to claim deeds if inlining a non-value non-internally-bound thing here
    force :: Deeds -> Heap -> Stack -> Tag -> Out Var -> Maybe UnnormalisedState
    force deeds (Heap h ids) k tg x'
      -- NB: inlining values is non-normalising if dUPLICATE_VALUES_EVALUATOR is on (since doing things the long way would involve executing an update frame)
      | not (dUPLICATE_VALUES_EVALUATOR && normalising)
      , Just anned_a <- lookupAnswer (Heap h ids) x' -- NB: don't unwind *immediately* because we want that changing a Var into a Value in an empty stack is seen as a reduction 'step'
      = do { (deeds, a) <- prepareAnswer deeds x' (annee anned_a); return $ denormalise (deeds, Heap h ids, k, fmap Answer $ annedAnswer (annedTag anned_a) a) }
      | otherwise = do
        hb <- M.lookup x' h
        -- NB: we MUST NOT create update frames for non-concrete bindings!! This has bitten me in the past, and it is seriously confusing. 
        guard (howBound hb == InternallyBound)
        in_e <- heapBindingTerm hb
        return $ case k of
             -- Avoid creating consecutive update frames: implements "stack squeezing"
            kf : _ | Update y' <- tagee kf -> (deeds, Heap (M.insert x' (internallyBound (mkIdentityRenaming (unitVarSet y'), annedTerm (tag kf) (Var y'))) h) ids,                         k, in_e)
            _                              -> (deeds, Heap (M.delete x' h)                                                                          ids, Tagged tg (Update x') : k, in_e)

    -- Deal with a value at the top of the stack
    unwind :: Deeds -> Heap -> Stack -> Tag -> Answer -> Maybe UnnormalisedState
    unwind deeds h k tg_v in_v = uncons k >>= \(kf, k) -> case tagee kf of
        TyApply ty'               -> tyApply    (deeds + 1)          h k      in_v ty'
        Apply x2'                 -> apply      deeds       (tag kf) h k      in_v x2'
        Scrutinise x' ty' in_alts -> scrutinise (deeds + 1)          h k tg_v in_v x' ty' in_alts
        PrimApply pop in_vs in_es -> primop     deeds       (tag kf) h k tg_v pop in_vs in_v in_es
        CastIt co'                -> cast       deeds       (tag kf) h k      in_v co'
        Update x'
          | normalising, dUPLICATE_VALUES_EVALUATOR -> Nothing -- If duplicating values, we ensure normalisation by not executing updates
          | otherwise                               -> update deeds h k tg_v x' in_v
      where
        -- When derereferencing an indirection, it is important that the resulting value is not stored anywhere. The reasons are:
        --  1) That would cause allocation to be duplicated if we residualised immediately afterwards, because the value would still be in the heap
        --  2) It would cause a violation of the deeds invariant because *syntax* would be duplicate
        --  3) It feels a bit weird because it might turn phantom stuff into real stuff
        --
        -- Indirections do not change the deeds story much (at all). You have to pay a deed per indirection, which is released
        -- whenever the indirection dies in the process of evaluation (e.g. in the function position of an application). The deeds
        -- that the indirection "points to" are not affected by any of this. The exception is if we *retain* any subcomponent
        -- of the dereferenced thing - in this case we have to be sure to claim some deeds for that subcomponent. For example, if we
        -- dereference to get a lambda in our function application we had better claim deeds for the body.
        dereference :: Heap -> Answer -> Answer
        dereference h (mb_co, (rn, Indirect x)) | Just anned_a <- lookupAnswer h (rename rn x) = dereference h (annee anned_a `castAnswer` mb_co)
        dereference _ a = a
    
        deferenceLambdaish :: Heap -> Answer -> Maybe Answer
        deferenceLambdaish h a@(_, (_, v))
          | normalising, not dUPLICATE_VALUES_EVALUATOR, Indirect _ <- v = Nothing -- If not duplicating values, we ensure normalisation by not executing applications to non-explicit-lambdas
          | otherwise = Just (dereference h a)
    
        tyApply :: Deeds -> Heap -> Stack -> Answer -> Out Type -> Maybe UnnormalisedState
        tyApply deeds h k in_v@(_, (_, v)) ty' = do
            (mb_co, (rn, TyLambda x e_body)) <- deferenceLambdaish h in_v
            fmap (\deeds -> (deeds, h, case mb_co of Nothing -> k; Just (co', tg_co) -> Tagged tg_co (CastIt (co' `mkInstCo` ty')) : k, (insertTypeSubst rn x ty', e_body))) $
                 claimDeeds (deeds + annedValueSize' v) (annedSize e_body)

        apply :: Deeds -> Tag -> Heap -> Stack -> Answer -> Out Var -> Maybe UnnormalisedState
        apply deeds tg_v (Heap h ids) k in_v@(_, (_, v)) x' = do
            (mb_co, (rn, Lambda x e_body)) <- deferenceLambdaish (Heap h ids) in_v
            case mb_co of
              Nothing -> fmap (\deeds -> (deeds, Heap h ids, k, (insertRenaming rn x x', e_body))) $
                              claimDeeds (deeds + 1 + annedValueSize' v) (annedSize e_body)
              Just (co', tg_co) -> fmap (\deeds -> (deeds, Heap (M.insert y' (internallyBound (mkIdentityRenaming (annedTermFreeVars e_arg), e_arg)) h) ids', Tagged tg_co (CastIt res_co') : k, (rn', e_body))) $
                                        claimDeeds (deeds + 1 + annedValueSize' v) (annedSize e_arg + annedSize e_body)
                where (ids', rn', [y']) = renameNonRecBinders ids rn [x `setIdType` arg_co_from_ty']
                      Pair arg_co_from_ty' _arg_co_to_ty' = coercionKind arg_co'
                      [arg_co', res_co'] = decomposeCo 2 co'
                      e_arg = annedTerm tg_co (annedTerm tg_v (Var x') `Cast` mkSymCo arg_co')

        scrutinise :: Deeds -> Heap -> Stack -> Tag -> Answer -> Out Var -> Out Type -> In [AnnedAlt] -> Maybe UnnormalisedState
        scrutinise deeds0 (Heap h0 ids) k tg_v (mb_co_v, (rn_v, v)) wild' _ty' (rn_alts, alts)
           -- Literals are easy -- we can make the simplifying assumption that the types of literals are
           -- always simple TyCons without any universally quantified type variables.
          | Literal l <- v_deref
          , case mb_co_deref_kind of Nothing -> True; Just (_, _, Pair from_ty' to_ty') -> from_ty' `eqType` to_ty'
          , (deeds2, alt_e):_ <- [(deeds1 + annedAltsSize rest, (rn_alts, alt_e)) | ((LiteralAlt alt_l, alt_e), rest) <- bagContexts alts, alt_l == l]
          = Just (deeds2, Heap h1 ids, k, alt_e)
          
           -- Data is a big stinking mess! I hate you, KPush rule.
          | Data dc tys xs <- v_deref
           -- a) Ensure that the coercion on the data (if any) lets us do the reduction, and determine
           --    the appropriate coercions to use (if any) on each value argument to the DataCon
          , Just mb_dc_cos <- case mb_co_deref_kind of
                                    Nothing -> return Nothing
                                    Just (co', tg_co, Pair from_ty' to_ty') -> do
                                      (from_tc, _from_tc_arg_tys') <- splitTyConApp_maybe from_ty'
                                      (to_tc,   _to_tc_arg_tys')   <- splitTyConApp_maybe to_ty'
                                      guard $ from_tc == to_tc
                                      return $ Just $
                                        let -- Substantially copied from CoreUnfold.exprIsConApp_maybe:
                                            tc_arity       = tyConArity from_tc
                                            dc_univ_tyvars = dataConUnivTyVars dc
                                            dc_ex_tyvars   = dataConExTyVars dc
                                            arg_tys        = dataConRepArgTys dc
                                        
                                            -- Make the "theta" from Fig 3 of the paper
                                            gammas = decomposeCo tc_arity co'
                                            theta  = zipOpenCvSubst (dc_univ_tyvars ++ dc_ex_tyvars)
                                                                    (gammas         ++ map mkReflCo tys)
                                        in map (\arg_ty -> (liftCoSubst theta arg_ty, tg_co)) arg_tys -- Use tag from the original coercion everywhere
           -- b) Identify the first appropriate branch of the case and reduce -- apply the discovered coercions if necessary
          , (deeds3, h', ids', alt_e):_ <- [ res
                                           | ((DataAlt alt_dc alt_xs, alt_e), rest) <- bagContexts alts
                                           , alt_dc == dc
                                           , let xs' = map (rename rn_v_deref) xs
                                                 (alt_as, alt_ys) = splitAtList tys alt_xs
                                                 rn_alts' = insertTypeSubsts rn_alts (alt_as `zip` tys)
                                                 deeds2 = deeds1 + annedAltsSize rest
                                           , Just res <- [do (deeds3, h', ids', rn_alts') <- case mb_dc_cos of
                                                               Nothing     -> return (deeds2, h1, ids, insertRenamings rn_alts' (alt_ys `zip` xs'))
                                                               Just dc_cos -> foldM (\(deeds, h, ids, rn_alts) (x', alt_y, (dc_co, tg_co)) -> let Pair _dc_co_from_ty' dc_co_to_ty' = coercionKind dc_co -- TODO: use to_tc_arg_tys' from above?
                                                                                                                                                  (ids', rn_alts', [y']) = renameNonRecBinders ids rn_alts [alt_y `setIdType` dc_co_to_ty']
                                                                                                                                                  e_arg = annedTerm tg_co (annedTerm tg_v (Var x') `Cast` dc_co)
                                                                                                                                              in fmap (\deeds' -> (deeds', M.insert y' (internallyBound (mkIdentityRenaming (annedTermFreeVars e_arg), e_arg)) h, ids', rn_alts')) $ claimDeeds deeds (annedSize e_arg))
                                                                                    (deeds2, h1, ids, rn_alts') (zip3 xs' alt_ys dc_cos)
                                                             return (deeds3, h', ids', (rn_alts', alt_e))]
                                           ]
          = Just (deeds3, Heap h' ids', k, alt_e)
          
           -- Thank god, default alternatives are trivial:
          | (deeds2, alt_e):_ <- [(deeds1 + annedAltsSize rest, (rn_alts, alt_e)) | ((DefaultAlt, alt_e), rest) <- bagContexts alts]
          = Just (deeds2, Heap h1 ids, k, alt_e)
          
           -- This can legitimately occur, e.g. when supercompiling (if x then (case x of False -> 1) else 2)
          | otherwise
          = Nothing
          where (mb_co_deref, (rn_v_deref, v_deref)) = dereference (Heap h0 ids) (mb_co_v, (rn_v, v))
                mb_co_deref_kind = fmap (\(co, tg_co) -> (co, tg_co, coercionKind co)) mb_co_deref
                (deeds1, h1) | isDeadBinder wild' = (deeds0 + annedValueSize' v, h0)
                             | otherwise          = (deeds0, M.insert wild' (internallyBound (rn_v, annedTerm tg_v (Value v))) h0)
                               -- NB: we add the *non-dereferenced* value to the heap for a case wildcard, because anything else may duplicate allocation

        primop :: Deeds -> Tag -> Heap -> Stack -> Tag -> PrimOp -> [Anned Answer] -> Answer -> [In AnnedTerm] -> Maybe UnnormalisedState
        primop deeds tg_kf h k tg_a pop anned_as a [] = do
            guard eVALUATE_PRIMOPS -- NB: this is not faithful to paper 1 because we still turn primop expressions into
                                   -- stack frames.. this is bad because it will impede good specilations (without smart generalisation)
            let as' = map (dereference h) $ map annee anned_as ++ [a]
                tg_kf' = tg_kf { tagOccurrences = if oCCURRENCE_GENERALISATION then tagOccurrences tg_kf + sum (map tagOccurrences (tg_a : map annedTag anned_as)) else 1 }
            a' <- evaluatePrim tg_kf' pop as'
            deeds <- claimDeeds (deeds + sum (map annedSize anned_as) + answerSize' a + 1) (annedSize a') -- I don't think this can ever fail
            return (denormalise (deeds, h, k, fmap Answer a'))
        primop deeds tg_kf h k tg_a pop anned_as a (in_e:in_es) = Just (deeds, h, Tagged tg_kf (PrimApply pop (anned_as ++ [annedAnswer tg_a a]) in_es) : k, in_e)

        cast :: Deeds -> Tag -> Heap -> Stack -> Answer -> Coercion -> Maybe UnnormalisedState
        cast deeds tg_kf (Heap h ids) k (mb_co, in_v) co' = Just (deeds', Heap h ids, k, annedAnswerToAnnedTerm ids (annedAnswer tg_kf ans'))
          where (deeds', ans') = case mb_co of
                    Nothing           -> (deeds,     (Just (co',                tg_kf), in_v))
                    Just (co, _tg_co) -> (deeds + 1, (Just (co `mkTransCo` co', tg_kf), in_v))

        update :: Deeds -> Heap -> Stack -> Tag -> Out Var -> Answer -> Maybe UnnormalisedState
        update deeds (Heap h ids) k tg_a x' a = do
            (deeds', prepared_in_v) <- case prepareAnswer deeds x' a of
                Nothing                      -> pprTrace "update-deeds:" (pPrint x') Nothing
                Just (deeds', prepared_in_v) -> Just (deeds', prepared_in_v)
            return (deeds', Heap (M.insert x' (internallyBound (annedAnswerToAnnedTerm ids (annedAnswer tg_a a))) h) ids, k, annedAnswerToAnnedTerm ids (annedAnswer tg_a prepared_in_v))
