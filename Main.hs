-----------------------------------------------------------------------------
-- |
-- Module      :  Main.hs
-- Copyright   :  (c) Spencer Janssen 2007
-- License     :  BSD3-style (see LICENSE)
-- 
-- Maintainer  :  sjanssen@cse.unl.edu
-- Stability   :  unstable
-- Portability :  not portable, uses mtl, X11, posix
--
-----------------------------------------------------------------------------
--
-- thunk, a minimal window manager for X11
--

import Data.Bits hiding (rotate)

import System.IO
import System.Process (runCommand)
import System.Exit

import Graphics.X11.Xlib
import Graphics.X11.Xlib.Extras

import Control.Monad.State

import W

--
-- let's get underway
-- 
main :: IO ()
main = do
    dpy <- openDisplay ""
    let dflt      = defaultScreen dpy
        initState = WState
            { display      = dpy
            , screenWidth  = displayWidth  dpy dflt
            , screenHeight = displayHeight dpy dflt
            , windows      = [] }

    runW initState $ do
        root <- io $ rootWindow dpy dflt
        io $ do selectInput dpy root (substructureRedirectMask .|. substructureNotifyMask)
                sync dpy False
        registerKeys dpy root
        go dpy

    return ()
  where
    -- The main loop
    go dpy = forever $ do
        e <- io $ allocaXEvent $ \ev -> nextEvent dpy ev >> getEvent ev
        handle e

--
-- | grabkeys. Register key commands
--
registerKeys :: Display -> Window -> W ()
registerKeys dpy root =
    forM_ keys $ \(mod, sym, _) -> do
        kc <- io (keysymToKeycode dpy sym)
        io $ grabKey dpy kc mod root True grabModeAsync grabModeAsync

keys :: [(KeyMask, KeySym, W ())]
keys =
    [ (mod1Mask .|. shiftMask, xK_Return, spawn "xterm")
    , (mod1Mask,               xK_p,      spawn "exe=`dmenu_path | dmenu` && exec $exe")
    , (controlMask,            xK_space,  spawn "gmrun")
    , (mod1Mask,               xK_Tab,    focus 1)
    , (mod1Mask,               xK_j,      focus 1)
    , (mod1Mask,               xK_k,      focus (-1))
    , (mod1Mask .|. shiftMask, xK_q,      io $ exitWith ExitSuccess)
    ]

--
-- The event handler
-- 
handle :: Event -> W ()
handle (MapRequestEvent {window = w}) = manage w

handle (DestroyWindowEvent {window = w}) = do
    ws <- gets windows
    when (elem w ws) (unmanage w)

handle (UnmapEvent {window = w}) = do
    ws <- gets windows
    when (elem w ws) (unmanage w)

handle (KeyEvent {event_type = t, state = mod, keycode = code})
    | t == keyPress = do
        dpy <- gets display
        sym <- io $ keycodeToKeysym dpy code 0
        case filter (\(mod', sym', _) -> mod == mod' && sym == sym') keys of
            []              -> return ()
            ((_, _, act):_) -> act

handle e@(ConfigureRequestEvent {}) = do
    dpy <- gets display
    io $ configureWindow dpy (window e) (value_mask e) $
        WindowChanges
            { wcX = x e
            , wcY = y e
            , wcWidth = width e
            , wcHeight = height e
            , wcBorderWidth = border_width e
            , wcSibling = above e
            , wcStackMode = detail e
            }
    io $ sync dpy False

handle _ = return ()

-- ---------------------------------------------------------------------
-- Managing windows

--
-- | refresh. Refresh the currently focused window. Resizes to full
-- screen and raises the window.
--
refresh :: W ()
refresh = do
    ws <- gets windows
    case ws of
        []    -> return ()
        (w:_) -> do
            d  <- gets display
            sw <- liftM fromIntegral (gets screenWidth)
            sh <- liftM fromIntegral (gets screenHeight)
            io $ do moveResizeWindow d w 0 0 sw sh
                    raiseWindow d w

-- | Modify the current window list with a pure funtion, and refresh
withWindows :: (Windows -> Windows) -> W ()
withWindows f = do
    modifyWindows f
    refresh

-- | manage. Add a new window to be managed
manage :: Window -> W ()
manage w = do
    trace "manage"
    d  <- gets display
    withWindows (nub . (w :))
    io $ mapWindow d w

-- | unmanage, a window no longer exists, remove it from the stack
unmanage :: Window -> W ()
unmanage w = do
    dpy <- gets display
    io $ do grabServer dpy
            sync dpy False
            ungrabServer dpy
    withWindows $ filter (/= w)

-- | focus. focus to window at offset 'n' in list.
-- The currently focused window is always the head of the list
focus :: Int -> W ()
focus n = withWindows (rotate n)

-- | spawn. Launch an external application
spawn :: String -> W ()
spawn = io_ . runCommand
