{-
waymonad A wayland compositor in the spirit of xmonad
Copyright (C) 2017  Markus Ongyerth

This library is free software; you can redistribute it and/or
modify it under the terms of the GNU Lesser General Public
License as published by the Free Software Foundation; either
version 2.1 of the License, or (at your option) any later version.

This library is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
Lesser General Public License for more details.

You should have received a copy of the GNU Lesser General Public
License along with this library; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

Reach us at https://github.com/ongy/waymonad
-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE NumDecimals #-}
{-# LANGUAGE FlexibleContexts #-}
module Main
where

import Control.Applicative ((<|>))
import Data.Monoid ((<>))
import Data.Text (Text)
import System.IO
import System.Environment (lookupEnv)

import Text.XkbCommon.InternalTypes (Keysym(..))
import Text.XkbCommon.KeysymList
import Graphics.Wayland.WlRoots.Input.Keyboard (WlrModifier(..))
import Graphics.Wayland.WlRoots.Render.Color (Color (..))

import Data.String (IsString)
import Fuse.Main
import Waymonad.GlobalFilter
import Waymonad.Hooks.EnterLeave (enterLeaveHook)
import Waymonad.Hooks.FocusFollowPointer
import Waymonad.Hooks.KeyboardFocus
import Waymonad.Hooks.ScaleHook
import Waymonad.Input (attachDevice)
import Waymonad.Input.Keyboard (setSubMap, resetSubMap, getSubMap)
import Waymonad.Layout.SmartBorders
import Waymonad.Layout.Choose
import Waymonad.Layout.Mirror (mkMirror, ToggleMirror (..))
import Waymonad.Layout.Spiral
import Waymonad.Layout.AvoidStruts
import Waymonad.Layout.Tall (Tall (..))
import Waymonad.Layout.ToggleFull (mkTFull, ToggleFullM (..))
import Waymonad.Layout.TwoPane (TwoPane (..))
import Waymonad.Layout.Ratio
import Waymonad.Navigation2D
import Waymonad.Output (Output (outputRoots), addOutputToWork, setPreferdMode)
import Waymonad.Protocols.GammaControl
import Waymonad.Protocols.Screenshooter
import Waymonad.Actions.Startup.Environment
import Waymonad.Actions.Spawn (spawn, manageSpawnOn)
import Waymonad.Actions.Spawn.X11 (manageX11SpawnOn)
import Waymonad.ViewSet (WSTag, Layouted, FocusCore, ListLike (..))
import Waymonad.Utility (sendMessage, focusNextOut, sendTo, closeCurrent, closeCompositor)
import Waymonad.Utility.Timing
import Waymonad.Utility.View
import Waymonad.Utility.ViewSet (modifyFocusedWS)
import Waymonad (Way, KeyBinding)
import Waymonad.Types (WayHooks (..), BindingMap)
import Waymonad.ViewSet.XMonad (ViewSet, sameLayout)

import qualified Data.Map as M

import qualified Waymonad.Hooks.OutputAdd as H
import qualified Waymonad.Hooks.SeatMapping as SM
import qualified Waymonad.Shells.XWayland as XWay
import qualified Waymonad.Shells.XdgShell as Xdg
import qualified Waymonad.Shells.WlShell as Wl

import Waymonad.Main
import Config

import Graphics.Wayland.WlRoots.Util
import Waymonad.Output.DamageDisplay

wsSyms :: [Keysym]
wsSyms =
    [ keysym_1
    , keysym_2
    , keysym_3
    , keysym_4
    , keysym_5
    , keysym_6
    , keysym_7
    , keysym_8
    , keysym_9
    , keysym_0
    ]

workspaces :: IsString a => [a]
workspaces = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]

makeListNavigation :: (ListLike vs ws, FocusCore vs ws, WSTag ws)
                   => WlrModifier -> Way vs ws (BindingMap vs ws)
makeListNavigation modi = do
    let listNav = makeBindingMap
            [ (([modi], keysym_j), modifyFocusedWS $ flip _moveFocusRight)
            , (([modi], keysym_k), modifyFocusedWS $ flip _moveFocusLeft )
            , (([modi, Shift], keysym_h), resetSubMap)
            , (([], keysym_Escape), resetSubMap)
            ]
    current <- getSubMap
    pure (M.union listNav current)


-- Use Logo as modifier when standalone, but Alt when started as child
getModi :: IO WlrModifier
getModi = do
    way <- lookupEnv "WAYLAND_DISPLAY"
    x11 <- lookupEnv "DISPLAY"
    pure . maybe Logo (const Alt) $ way <|> x11

bindings :: (Layouted vs ws, ListLike vs ws, FocusCore vs ws, IsString ws, WSTag ws)
         => WlrModifier -> [(([WlrModifier], Keysym), KeyBinding vs ws)]
bindings modi =
    [ (([modi], keysym_k), moveUp)
    , (([modi], keysym_j), moveDown)
    , (([modi], keysym_h), moveLeft)
    , (([modi], keysym_l), moveRight)
    , (([modi, Shift], keysym_k), modifyFocusedWS $ flip _moveFocusedLeft )
    , (([modi, Shift], keysym_j), modifyFocusedWS $ flip _moveFocusedRight)
    , (([modi, Shift], keysym_h), setSubMap =<< makeListNavigation modi)
    , (([modi], keysym_f), sendMessage ToggleFullM)
    , (([modi], keysym_m), sendMessage ToggleMirror)
    , (([modi], keysym_space), sendMessage NextLayout)
    , (([modi], keysym_Left), sendMessage $ DecreaseRatio 0.1)
    , (([modi], keysym_Right), sendMessage $ IncreaseRatio 0.1)

    , (([modi], keysym_Return), spawn "weston-terminal")
    , (([modi], keysym_d), spawn "rofi -show run")

    , (([modi], keysym_n), focusNextOut)
    , (([modi], keysym_q), closeCurrent)
    , (([modi, Shift], keysym_e), closeCompositor)
    ] ++ concatMap (\(sym, ws) -> [(([modi], sym), greedyView ws), (([modi, Shift], sym), sendTo ws), (([modi, Ctrl], sym), copyView ws)]) (zip wsSyms workspaces)

myConf :: WlrModifier -> WayUserConf (ViewSet Text) Text
myConf modi = WayUserConf
    { wayUserConfWorkspaces  = workspaces
    , wayUserConfLayouts     = sameLayout . avoidStruts . mkSmartBorders 2 . mkMirror . mkTFull $ (Tall 0.5 ||| TwoPane 0.5 ||| Spiral 0.618)
    , wayUserConfManagehook  = XWay.overrideXRedirect <> manageSpawnOn <> manageX11SpawnOn
    , wayUserConfEventHook   = const $ pure ()
    , wayUserConfKeybinds    = bindings modi

    , wayUserConfInputAdd    = flip attachDevice "seat0"
    , wayUserConfDisplayHook =
        [ getFuseBracket
        , getGammaBracket
        , getFilterBracket filterUser
        , baseTimeBracket
        , envBracket [ ("QT_QPA_PLATFORM", "wayland-egl")
                     -- breaks firefox (on arch) :/
                     --, ("GDK_BACKEND", "wayland")
                     , ("SDL_VIDEODRIVER", "wayland")
                     , ("CLUTTER_BACKEND", "wayland")
                     ]
        ]
    , wayUserConfBackendHook = []
    , wayUserConfPostHook    = [getScreenshooterBracket]
    , wayUserConfCoreHooks   = WayHooks
        { wayHooksVWSChange       = wsScaleHook
        , wayHooksOutputMapping   = enterLeaveHook <> handlePointerSwitch <> SM.mappingChangeEvt
        , wayHooksSeatWSChange    = SM.wsChangeLogHook <> handleKeyboardSwitch
        , wayHooksSeatOutput      = SM.outputChangeEvt {-<> handleKeyboardPull-}
        , wayHooksSeatFocusChange = focusFollowPointer
        , wayHooksNewOutput       = H.outputAddHook
        }
    , wayUserConfShells = [Xdg.makeShell, Wl.makeShell, XWay.makeShell]
    , wayUserConfLog = pure ()
    , wayUserConfOutputAdd = \out -> do
        setPreferdMode (outputRoots out)
        addOutputToWork out Nothing
    , wayUserconfLoggers = Nothing
    , wayUserconfColor = Color 0.5 0 0 1
    , wayUserconfColors = mempty
    , wayUserconfFramerHandler = Nothing -- Just $ damageDisplay 30
    }

main :: IO ()
main = do
    setLogPrio Debug
    modi <- getModi
    confE <- loadConfig
    case confE of
        Left err -> do
            hPutStrLn stderr "Couldn't load config:"
            hPutStrLn stderr err
            printConfigInfo
        Right conf -> wayUserMain $ modifyConfig conf (myConf modi)
