module Oden.Output.Infer where

import Text.PrettyPrint

import Oden.Infer
import Oden.Infer.Subsumption
import Oden.Output
import Oden.Pretty
import Oden.SourceInfo
import Oden.Type.Polymorphic

instance OdenOutput TypeError where
  outputType _ = Error

  name (UnificationFail _ _ _)                              = "Infer.UnificationFail"
  name (InfiniteType _ _ _)                                 = "Infer.InfiniteType"
  name (InvalidPackageReference _ _)                        = "Infer.InvalidPackageReference"
  name (NotInScope _ _)                                     = "Infer.NotInScope"
  name (MemberNotInPackage _ _ _)                           = "Infer.MemberNotInPackage"
  name (PackageNotInScope _ _)                              = "Infer.PackageNotInScope"
  name (UnificationMismatch _ _ _)                          = "Infer.UnificationMismatch"
  name (ArgumentCountMismatch _ _ _)                        = "Infer.ArgumentCountMismatch"
  name (TypeSignatureSubsumptionError _ SubsumptionError{}) = "Infer.TypeSignatureSubsumptionError"
  name (ValueUsedAsType _ _)                                = "Infer.ValueUsedAsType"
  name (TypeIsNotAnExpression _ _)                          = "Infer.TypeIsNotAnExpression"
  name (InvalidTypeInStructInitializer _ _)                 = "Infer.InvalidTypeInStructInitializer"
  name (StructInitializerFieldCountMismatch _ _ _)          = "Infer.StructInitializerFieldCountMismatch"
  name (NoSuchFieldInStruct _ _ _ _)                        = "Infer.NoSuchFieldInStruct"

  header (UnificationFail _ t1 t2) s = text "Cannot unify types"
    <+> code s (pp t1) <+> text "and" <+> code s (pp t2)
  header (InfiniteType _ _ _) _ = text "Cannot construct an infinite type"
  header (InvalidPackageReference _ p) s = text "Invalid reference to package" <+> code s (text p)
  header (NotInScope _ i) s = code s (pp i) <+> text "is not in scope"
  header (PackageNotInScope _ p) s = text "Package" <+> code s (text p) <+> text "is not in scope"
  header (MemberNotInPackage _ p m) s = code s (text m) <+> text "is not a member of package" <+> code s (text p)
  header (UnificationMismatch _ _ _) _ = text "Types do not match"
  header (ArgumentCountMismatch _ as ps) _ | length as > length ps =
    text "Function is applied to too few arguments"
  header (ArgumentCountMismatch _ _ _) _ =
    text "Function is applied to too many arguments"
  header (TypeSignatureSubsumptionError n SubsumptionError{}) s =
    text "Type signature for" <+> strCode s n
    <+> text "does not subsume the type of the definition"
  header (ValueUsedAsType _ n) s =
    text "The value" <+> strCode s n
    <+> text "cannot be used as a type"
  header (TypeIsNotAnExpression _ n) s =
    text "The type" <+> strCode s n
    <+> text "is not an expression"
  header (InvalidTypeInStructInitializer _ t) s =
    text "Type" <+> code s (pp t) <+> text "cannot be initialized as a struct"
  header (StructInitializerFieldCountMismatch _ _ _) _ =
    text "Struct is initialized with too many values"
  header (NoSuchFieldInStruct _ valueName fieldName structType) s =
    text "Value " <+> strCode s valueName
    <+> text "with type" <+> code s (pp structType)
    <+> text "has no field" <+> strCode s fieldName

  details (UnificationFail _ _ _) _ = empty
  details (InfiniteType _ v t) s = code s (pp v) <+> equals <+> code s (pp t)
  details (InvalidPackageReference _ _) _ = text "Packages cannot be referenced as values"
  details (NotInScope _ _) _ = empty
  details (PackageNotInScope _ _) _ = empty
  details (MemberNotInPackage _ _ _) _ = empty
  details (UnificationMismatch _ ts1 ts2) s = vcat (zipWith formatTypes ts1 ts2)
    where formatTypes t1 t2 | t1 == t2 = code s (pp t1) <+> text "==" <+> code s (pp t2)
          formatTypes t1 t2 = code s (pp t1) <+> text "!=" <+> code s (pp t2)
  details (ArgumentCountMismatch _ as1 as2) s =
    text "Expected:" <+> vcat (map (code s . pp) as1)
    $+$ text "Actual:" <+> vcat (map (code s . pp) as2)
    -- TODO: Print something like "In the expression: ..."
  details (TypeSignatureSubsumptionError _ (SubsumptionError _ t1 t2)) s =
    text "Type" <+> code s (pp t1) <+> text "does not subsume" <+> code s (pp t2)
  details ValueUsedAsType{} _ = empty
  details TypeIsNotAnExpression{} _ = empty
  details (InvalidTypeInStructInitializer _ t@TNamed{}) s =
    code s (pp t) <+> text "is a type alias for" <+> code s (pp (underlying t))
  details InvalidTypeInStructInitializer{} _ = empty
  details (StructInitializerFieldCountMismatch _ structType types) s =
    text "Struct:" <+> (code s (pp structType))
    $+$ text "Initialized with:" <+> vcat (map (code s . pp) types)
  details NoSuchFieldInStruct{} _ = empty

  sourceInfo (ArgumentCountMismatch e _ _)                               = Just (getSourceInfo e)
  sourceInfo (UnificationFail si _ _)                                    = Just si
  sourceInfo (UnificationMismatch si _ _)                                = Just si
  sourceInfo (NotInScope si _)                                           = Just si
  sourceInfo (PackageNotInScope si _)                                    = Just si
  sourceInfo (MemberNotInPackage si _ _)                                 = Just si
  sourceInfo (InfiniteType si _ _)                                       = Just si
  sourceInfo (InvalidPackageReference si _)                              = Just si
  sourceInfo (TypeSignatureSubsumptionError _ (SubsumptionError si _ _)) = Just si
  sourceInfo (ValueUsedAsType si _)                                      = Just si
  sourceInfo (TypeIsNotAnExpression si _)                                = Just si
  sourceInfo (InvalidTypeInStructInitializer si _)                       = Just si
  sourceInfo (StructInitializerFieldCountMismatch si _ _)                = Just si
  sourceInfo (NoSuchFieldInStruct si _ _ _)                              = Just si
