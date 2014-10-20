module GF.CompileOne(-- ** Compiling a single module
                     OneOutput,CompiledModule,
                     compileOne,reuseGFO,useTheSource
                     --, CompileSource, compileSourceModule
                     ) where

-- The main compiler passes
import GF.Compile.GetGrammar(getSourceModule)
import GF.Compile.Rename(renameModule)
import GF.Compile.CheckGrammar(checkModule)
import GF.Compile.Optimize(optimizeModule)
import GF.Compile.SubExOpt(subexpModule,unsubexpModule)
import GF.Compile.GeneratePMCFG(generatePMCFG)
import GF.Compile.Update(extendModule,rebuildModule)
import GF.Compile.Tags(writeTags,gf2gftags)

import GF.Grammar.Grammar
import GF.Grammar.Printer(ppModule,TermPrintQual(..))
import GF.Grammar.Binary(decodeModule,encodeModule)

import GF.Infra.Option
import GF.Infra.UseIO(FullPath,IOE,isGFO,gf2gfo,MonadIO(..),Output(..),putPointE)
import GF.Infra.CheckM(runCheck')
import GF.Data.Operations(ErrorMonad,liftErr,(+++),done)

import GF.System.Directory(doesFileExist,getCurrentDirectory,renameFile)
import qualified Data.Map as Map
import GF.Text.Pretty(render,(<+>),($$)) --Doc,
import Control.Monad((<=<))

type OneOutput = (Maybe FullPath,CompiledModule)
type CompiledModule = SourceModule

compileOne, reuseGFO, useTheSource ::
    (Output m,ErrorMonad m,MonadIO m) =>
    Options -> SourceGrammar -> FullPath -> m OneOutput

-- | Compile a given source file (or just load a .gfo file),
-- given a 'SourceGrammar' containing everything it depends on.
-- Calls 'reuseGFO' or 'useTheSource'.
compileOne opts srcgr file =
    if isGFO file
    then reuseGFO opts srcgr file
    else do b1 <- doesFileExist file
            if b1 then useTheSource opts srcgr file
                  else reuseGFO opts srcgr (gf2gfo opts file)

-- | Read a compiled GF module.
-- Also undo common subexp optimization, to enable normal computations.
reuseGFO opts srcgr file =
  do sm00 <- putPointE Verbose opts ("+ reading" +++ file) $
             decodeModule file
     let sm0 = (fst sm00,(snd sm00){mflags=mflags (snd sm00) `addOptions` opts})

     idump opts Source sm0

     let sm1 = unsubexpModule sm0
     cwd <- getCurrentDirectory
     (sm,warnings) <- -- putPointE Normal opts "creating indirections" $ 
                      runCheck' opts $ extendModule cwd srcgr sm1
     warnOut opts warnings

     if flag optTagsOnly opts
       then writeTags opts srcgr (gf2gftags opts file) sm1
       else done

     return (Just file,sm)

--useTheSource :: Options -> SourceGrammar -> FullPath -> IOE OneOutput
-- | Compile GF module from source. It both returns the result and
-- stores it in a @.gfo@ file
-- (or a tags file, if running with the @-tags@ option)
useTheSource opts srcgr file =
      do sm <- putpOpt ("- parsing" +++ file)
                       ("- compiling" +++ file ++ "... ")
                       (getSourceModule opts file)
         idump opts Source sm
         cwd <- getCurrentDirectory
         compileSourceModule opts cwd (Just file) srcgr sm
  where
    putpOpt v m act
       | verbAtLeast opts Verbose = putPointE Normal opts v act
       | verbAtLeast opts Normal  = putStrE m >> act
       | otherwise                = putPointE Verbose opts v act

type CompileSource = SourceGrammar -> SourceModule -> IOE OneOutput

--compileSourceModule :: Options -> FilePath -> Maybe FilePath -> CompileSource
compileSourceModule opts cwd mb_gfFile gr =
    if flag optTagsOnly opts
    then generateTags <=< ifComplete middle               <=< frontend
    else generateGFO  <=< ifComplete (backend <=< middle) <=< frontend
  where
    -- Apply to all modules
    frontend = runPass Extend  "" . extendModule cwd gr
           <=< runPass Rebuild "" . rebuildModule cwd gr

    -- Apply to complete modules
    middle   = runPass TypeCheck "type checking" . checkModule opts cwd gr
           <=< runPass Rename    "renaming"      . renameModule cwd gr

    -- Apply to complete modules when not generating tags
    backend mo3 =
      do mo4 <- runPassE id Optimize "optimizing" $ optimizeModule opts gr mo3
         if isModCnc (snd mo4) && flag optPMCFG opts
          then runPassI "generating PMCFG" $ generatePMCFG opts gr mb_gfFile mo4
          else runPassI "" $ return mo4

    ifComplete yes mo@(_,mi) =
      if isCompleteModule mi then yes mo else return mo

    generateGFO mo =
      do let mb_gfo = fmap (gf2gfo opts) mb_gfFile
         maybeM (flip (writeGFO opts) mo) mb_gfo
         return (mb_gfo,mo)

    generateTags mo =
      do maybeM (flip (writeTags opts gr) mo . gf2gftags opts) mb_gfFile
         return (Nothing,mo)

    putpp s = if null s then id else putPointE Verbose opts ("  "++s++" ")

    -- * Running a compiler pass, with impedance matching
    runPass = runPass' fst fst snd (liftErr . runCheck' opts)
    runPassE = runPass2e liftErr
    runPassI = runPass2e id id Canon
    runPass2e lift f = runPass' id f (const "") lift

    runPass' ret dump warn lift pass pp m =
        do out <- putpp pp $ lift m
           warnOut opts (warn out)
           idump opts pass (dump out)
           return (ret out)

    maybeM f = maybe done f


--writeGFO :: Options -> FilePath -> SourceModule -> IOE ()
writeGFO opts file mo =
    putPointE Normal opts ("  write file" +++ file) $
      do encodeModule tmp mo2
         renameFile tmp file
  where
    tmp = file++".tmp"
    mo2 = (m,mi{jments=Map.filter notAnyInd (jments mi)})
    (m,mi) = subexpModule mo

    notAnyInd x = case x of AnyInd{} -> False; _ -> True

-- to output an intermediate stage
--intermOut :: Options -> Dump -> Doc -> IOE ()
intermOut opts d doc
  | dump opts d = ePutStrLn (render ("\n\n--#" <+> show d $$ doc))
  | otherwise   = done

idump opts pass = intermOut opts (Dump pass) . ppModule Internal

warnOut opts warnings
  | null warnings = done
  | otherwise     = do ePutStr "\ESC[34m";ePutStr ws;ePutStrLn "\ESC[m"
  where
    ws = if flag optVerbosity opts == Normal
         then '\n':warnings
         else warnings
