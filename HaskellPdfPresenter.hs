{-# LANGUAGE TemplateHaskell, PatternGuards, TupleSections #-}
import Codec.Compression.Zlib.Raw
import Control.Exception (catch)
import Control.Monad
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import qualified Data.ByteString.Unsafe as BSU
import Data.Char (toLower, isSpace)
import Data.IORef
import Data.List (sort, sortBy, nub)
import qualified Data.Map as Map
import Data.Ord (comparing)
import Data.Time.LocalTime (getCurrentTimeZone, utcToLocalTime)
import Data.Time.Clock (getCurrentTime)
import qualified Data.Time.Format (formatTime, defaultTimeLocale)
import Foreign.Ptr (castPtr)
import Graphics.Rendering.Cairo
import Graphics.UI.Gtk
import Graphics.UI.Gtk.Gdk.GC
import Graphics.UI.Gtk.Poppler.Document
import Graphics.UI.Gtk.Poppler.Page
import Language.Haskell.TH (Exp(LitE), Lit(StringL), runIO)
import Language.Haskell.TH.Syntax (addDependentFile)
import System.Console.GetOpt
import System.Directory (canonicalizePath)
import System.Exit (exitSuccess, exitFailure)
import System.FilePath (takeFileName)
import System.Glib
import Text.Printf (printf)
import qualified Data.Text as T

data TimerState =
  Counting Integer{-starting microseconds-} Integer{-ending microseconds-} |
  Stopped Bool{-soft pause-} Integer{-elapsed microseconds-} Integer{-remaining microseconds-}
data VideoMuteState = MuteOff | MuteBlack | MuteWhite deriving (Eq)
data ClockState = RemainingTime | ElapsedTime | WallTime12 | WallTime24

data State = State
-- Settings that are used only at program initialization
 { initSlide :: IORef Int
 , initPreviewPercentage :: IORef Int
 , initPresenterMonitor :: IORef Int
 , initAudienceMonitor :: IORef Int
 , initTimerMode :: IORef (TimerState -> IO TimerState)

-- Settable on command line
 , startTime :: IORef Integer{-microseconds-}
 , warningTime :: IORef Integer{-microseconds-}
 , endTime :: IORef Integer{-microseconds-}
 , documentURL :: IORef (Maybe String)
 , compression :: IORef Int

-- Dynamic State
 , timer :: IORef TimerState -- 'Maybe' for "dont" display or haven't started counting yet? Or as a seperate flag?
 , clock :: IORef ClockState
 , videoMute :: IORef VideoMuteState
 , fullscreen :: IORef Bool
 , mouseTimeout :: IORef Integer
 , history :: IORef ([Int]{-back-}, [Int]{-forward-})

-- UI State
 , builder :: Builder

-- Render State
 , views :: IORef (Map.Map Widget (Int{-width-}, Int{-height-}))
 , document :: IORef (Maybe Document)
 , pages :: IORef (Map.Map (Int{-page number-}, Int{-width-}, Int{-height-})
                          (BSL.ByteString, Int{-width-}, Int{-height-}, Int{-stride-}))
 , pageAdjustment :: Adjustment
}

header = "Haskell Pdf Presenter, version 0.2.5, <http://michaeldadams.org/projects/haskell-pdf-presenter>\nUsage: hpdfp [OPTION...] file"
options = [
   Option "h?" ["help"] (NoArg (const $ putStr (usageInfo header options) >> exitSuccess)) "Display usage message"
 , Option "s" ["slide"] (argOption initSlide "slide" maybeRead "INT") "Initial slide number (default 1)"
 , Option "t" ["start-time", "starting-time"] (argOption startTime "start-time" parseTime "TIME")
              "Start time (default 10:00)"
 , Option "w" ["warn-time", "warning-time"] (argOption warningTime "warning-time" parseTime "TIME")
              "Warning time (default 5:00)"
 , Option "e" ["end-time", "ending-time"] (argOption endTime "end-time" parseTime "TIME")
              "End time (default 0:00)"
 , Option "f" ["fullscreen"] (setOption fullscreen True) "Start in full screen mode"
 , Option "p" ["preview-percentage"] (argOption initPreviewPercentage "preview-percentage" maybeRead "INT")
              "Initial preview splitter percentage (default 50)"
 , Option "" ["presenter-monitor"] (argOption initPresenterMonitor "presenter-monitor" maybeRead "INT")
              "Initial monitor for presenter window (default 0)"
 , Option "" ["audience-monitor"] (argOption initAudienceMonitor "audience-monitor" maybeRead "INT")
              "Initial monitor for audience window (default 1)"
 , Option "" ["video-mute"] (enumOption videoMute "mute" [("black", MuteBlack), ("white", MuteWhite), ("off", MuteOff)] "MODE")
              "Initial video mute mode: \"black\", \"white\" or \"off\" (default)"
 , Option "" ["clock-mode"] (enumOption clock "clock-mode" [("remaining", RemainingTime), ("elapsed", ElapsedTime), ("12hour", WallTime12), ("24hour", WallTime24)] "MODE")
              "Initial clock mode: \"remaining\" (default), \"elapsed\", \"12hour\" or \"24hour\""
 , Option "" ["timer-mode"] (enumOption initTimerMode "timer-mode" (
                  map (,startTimer) ["play", "playing", "running", "start", "started"] ++
                  map (,pauseTimer) ["pause", "paused"] ++ map (,stopTimer) ["stop", "stopped"]) "MODE")
              "Initial timer mode: \"play\", \"pause\" (default) or \"stop\""
 , Option "" ["compression"] (argOption compression "compression" (maybeRead >=> maybeRange 0 9) "[0-9]")
              "Cache compression level: 0 is none, 1 is fastest (default), 9 is best"
 ]

----------------
-- Utils and constants
----------------

-- TODO: cleanup
heightFromWidth w = w * 3 `div` 4
numColumns = 4
textSize = 60
mouseTimeoutDelay = 3 * 1000 * 1000 {-microseconds-}
appName = "Haskell Pdf Presenter"

-- Color constants
red = Color 0xffff 0x0000 0x0000
purple = Color 0x8888 0x3333 0xffff
white = Color 0xffff 0xffff 0xffff
black = Color 0x0000 0x0000 0x0000

incMod x n = (x + 1) `mod` n
decMod x n = (x - 1) `mod` n

-- Like "read" but returns "Nothing" instead of throwing an exception
maybeRead :: (Read a) => String -> Maybe a
maybeRead str | [(n, "")] <- reads str = Just n
              | otherwise = Nothing

-- Like "Just" but returns "Nothing" if a value is outside a range
maybeRange :: Int -> Int -> Int -> Maybe Int
maybeRange lo hi x | lo <= x && x <= hi = Just x
                   | otherwise = Nothing

-- A list of the top level windows
-- NOTE: Order of windows effects which window is on top in fullscreen
mainWindows state = mapM ($ state) [presenterWindow, audienceWindow]
--  mapM (builderGetObject (builder state) castToWindow) [presenterWindow, audienceWindow]
presenterWindow state = builderGetObject (builder state) castToWindow "presenterWindow"
audienceWindow state = builderGetObject (builder state) castToWindow "audienceWindow"

-- Set an option to a given value when a command line flag is set
setOption opt val = NoArg $ \state -> writeIORef (opt state) val

-- Set an option based on the argument given to a command line
argOption :: (State -> IORef a) -> String -> (String -> Maybe a) -> String -> ArgDescr (State -> IO ())
argOption opt name f = ReqArg (\val state -> case f val of
    Nothing -> putStrLn ("ERROR: Invalid argument to option \""++name++"\": "++show val) >>
               putStr ("\n" ++ usageInfo header options) >> exitFailure
    Just val' -> writeIORef (opt state) val')

-- Set an option from a list of valid option values
enumOption :: (State -> IORef a) -> String -> [(String, a)] -> String -> ArgDescr (State -> IO ())
enumOption opt name optList = argOption opt name (`lookup` optList)

----------------
-- Main Program
----------------

main :: IO ()
main = do
  -- Set initialize application and get program arguments
  setApplicationName appName
  args <- initGUI

  -- Initialize shared state
  state <- return State
    `ap` newIORef 1 {-init slide-}
    `ap` newIORef 50 {-init preview percentage-}
    `ap` newIORef 0 {-init presenter monitor-}
    `ap` newIORef 1 {-init audience monitor-}
    `ap` newIORef pauseTimer

    `ap` newIORef (10 * 60 * 1000 * 1000) {-startTime-}
    `ap` newIORef (5 * 60 * 1000 * 1000) {-warningTime-}
    `ap` newIORef (0 * 60 * 1000 * 1000) {-20 * 60 * 1000 * 1000-} {-endTime-}
    `ap` newIORef Nothing {-file uri-}
    `ap` newIORef 1 {-compression-}

    `ap` newIORef (error "internal error: undefined timer state")
    `ap` newIORef RemainingTime
    `ap` newIORef MuteOff {-videoMute-}
    `ap` newIORef False {-fullscreen-}
    `ap` newIORef 0 {-mouseTimeout-}
    `ap` newIORef ([], []) {-history-}

    `ap` builderNew

    `ap` newIORef Map.empty {-views-}
    `ap` newIORef Nothing {-document-}
    `ap` newIORef Map.empty {-pages-}
    `ap` adjustmentNew 0 0 0 1 10 1 {-pageAdjustment-}

  -- Parse command line options and call guiMain
  case getOpt Permute options args of
    (opts, [], []) -> mapM_ ($ state) opts >> guiMain state
    (opts, [file], []) -> do
      mapM_ ($ state) opts
      file' <- canonicalizePath file
      postGUIAsync (void $ openDoc state ("file://"++file'))
      guiMain state
    (_, [_,_], []) -> putStrLn "Error: Multiple files on command line" >> putStr (usageInfo header options)
    (_, _, errors) -> putStrLn (concat errors) >> putStr (usageInfo header options)

guiMain :: State -> IO ()
guiMain state = do
  -- Load and setup the GUI
  builderAddFromString (builder state)
    $(let f = "HaskellPdfPresenter.glade" in addDependentFile f >> liftM (LitE . StringL) (runIO $ readFile f))

  -- Finish setting up the state and configure gui to match state
  pageAdjustment state `set` [adjustmentUpper :=> liftM fromIntegral (readIORef (initSlide state)),
                              adjustmentValue :=> liftM fromIntegral (readIORef (initSlide state))]
  modifyTimerState state (const $ liftM (Stopped True 0) (readIORef (startTime state)))
  modifyTimerState state =<< readIORef (initTimerMode state)
  modifyVideoMute state return

  -- Connect the widgets to their events
  -- * Audience Window
  do window <- audienceWindow state
     view <- makeView state id (postDrawVideoMute state)
     window `containerAdd` view

  -- * Presenter window
  -- ** Views
  -- *** Previews
  do paned <- builderGetObject (builder state) castToPaned "preview.paned"
     view1 <- makeView state id postDrawNone
     view2 <- makeView state (+1) postDrawNone
     panedPack1 paned view1 True True
     panedPack2 paned view2 True True

  -- *** Thumbnails
  do oldWidth <- newIORef 0
     layout <- builderGetObject (builder state) castToLayout "thumbnails.layout"
     layout `onSizeAllocate` (\(Graphics.UI.Gtk.Rectangle _ _ newWidth _) -> do
       oldWidth' <- readIORef oldWidth
       writeIORef oldWidth newWidth
       when (oldWidth' /= newWidth) $ recomputeThumbnails state newWidth)
     pageAdjustment state `onAdjChanged` (readIORef oldWidth >>= recomputeThumbnails state)

     -- Set a handler that scrolls to keep the current slide visible
     adjustment <- scrolledWindowGetVAdjustment =<<
                   builderGetObject (builder state) castToScrolledWindow "thumbnails.scrolled"
     let update = do p <- liftM round $ pageAdjustment state `get` adjustmentValue
                     let row = (p-1) `div` numColumns
                     height <- liftM (heightFromWidth . (`div` numColumns)) $ readIORef oldWidth
                     adjustmentClampPage adjustment (fromIntegral $ row*height) (fromIntegral $ row*height+height)
     pageAdjustment state `onValueChanged` update
     pageAdjustment state `onAdjChanged` update

  -- ** Meta-data
  -- *** Current time
  do eventBox <- builderGetObject (builder state) castToEventBox "timeEventBox"
     eventBox `on` buttonPressEvent $ tryEvent $
       do DoubleClick <- eventClick; liftIO $ timerDialog state
     timeoutAdd (displayTime state >> return True) 100{-milliseconds-}
       -- ^ Really this should be run on redraw, but because the
       -- computation triggers more redraws, we have it here.  This
       -- may result in a 1/10 second lag before the label resizes.

  -- *** Current slide number
  do eventBox <- builderGetObject (builder state) castToEventBox "slideEventBox"
     eventBox `on` buttonPressEvent $ tryEvent $
       do DoubleClick <- eventClick; liftIO $ gotoSlideDialog state
     slideNum <- builderGetObject (builder state) castToLabel "slideLabel"
     let update = do p <- liftM round $ pageAdjustment state `get` adjustmentValue
                     n <- liftM round $ pageAdjustment state `get` adjustmentUpper
                     l <- liftM round $ pageAdjustment state `get` adjustmentLower
                     slideNum `set` [
                       labelText := if (l :: Integer) == 0 then "" else show (p :: Integer) ++ "/" ++ show (n :: Integer),
                       labelAttributes := [AttrSize 0 (negate 1) textSize, -- TODO: we have to do this to get the right font???
                                           AttrForeground 0 (negate 1) white]]
     pageAdjustment state `onValueChanged` update
     pageAdjustment state `onAdjChanged` update

  -- Setup the top-level windows
  do let setupWindow window = do
           -- Make the window fullscreen if needed
           f <- readIORef (fullscreen state)
           when f $ windowFullscreen window
           -- Make background black
           widgetModifyBg window StateNormal (Color 0 0 0)
           -- Add event handlers
           window `onDestroy` mainQuit
           window `on` keyPressEvent $ do
             mods <- eventModifier
             name <- eventKeyName
             b <- liftIO $ handleKey state mods (map toLower (T.unpack name))
             liftIO $ mapM_ widgetQueueDraw =<< mainWindows state
             return b
           -- Redraw the window when we switch slides.  Most (though not all)
           -- of it needs to be redrawn so we redraw the entire window.
           pageAdjustment state `onValueChanged` widgetQueueDraw window
           pageAdjustment state `onAdjChanged` widgetQueueDraw window
           -- Show the window
           widgetShowAll window
     mapM_ setupWindow =<< mainWindows state

  -- * Put windows on correct monitors
  join $ return moveWindow `ap` presenterWindow state `ap` readIORef (initPresenterMonitor state)
  join $ return moveWindow `ap` audienceWindow state `ap` readIORef (initAudienceMonitor state)

  -- * Adjust the preview splitter (must be done after windows are shown)
  do paned <- builderGetObject (builder state) castToPaned "preview.paned"
     maxPos <- paned `get` panedMaxPosition
     percentage <- readIORef (initPreviewPercentage state)
     paned `set` [panedPosition := maxPos * percentage `div` 100]

  -- * Setup about dialog
  do dialog <- builderGetObject (builder state) castToAboutDialog "aboutDialog"
     dialog `on` response $ const $ widgetHideAll dialog
     dialog `on` deleteEvent $ liftIO (widgetHideAll dialog) >> return True

  -- * Make sure the screen saver doesn't start by moving the cursor.
  --   Since we move the mouse by zero pixels, this shouldn't effect the user.
  --   Also set up the handler for hiding the mouse after a delay.
  do w <- audienceWindow state
     dw <- widgetGetDrawWindow w
     blankCursor <- cursorNew BlankCursor
     timeoutAdd (do -- Move the cursor by zero pixels
                    display <- screenGetDisplay =<< windowGetScreen w
                    (screen, _, x, y) <- displayGetPointer display
                    displayWarpPointer display screen x y
                    -- Hide the mouse if needed.
                    mouseTimeout' <- readIORef (mouseTimeout state)
                    currTime <- getMicroseconds
                    fullscreen' <- readIORef (fullscreen state)
                    when (fullscreen' && currTime > mouseTimeout') $
                      dw `drawWindowSetCursor` Just blankCursor
                    return True) (5000{-milliseconds-})
     w `widgetAddEvents` [PointerMotionMask]
     oldCoordRef <- newIORef (0, 0)
     let update = do dw `drawWindowSetCursor` Nothing
                     writeIORef (mouseTimeout state) =<< liftM (+ mouseTimeoutDelay) getMicroseconds
     w `on` enterNotifyEvent $ liftIO update >> return False
     -- Reset the timeout if the user moves the mouse
     w `on` motionNotifyEvent $ do
       coord <- eventRootCoordinates
       oldCoord <- liftIO $ readIORef oldCoordRef
       liftIO $ writeIORef oldCoordRef coord
       when (oldCoord /= coord) $ liftIO update
       return False

  -- Schedule rendering, and start main loop
  startRenderThread state =<< builderGetObject (builder state) castToProgressBar "renderingProgressbar"
  mainGUI

-- Recompute thumbnails when sizes need to change
recomputeThumbnails state newWidth = do
  layout <- builderGetObject (builder state) castToLayout "thumbnails.layout"
  -- Remove the old thumbnails
  containerForeach layout (containerRemove layout)
  -- Figure out how big the thumbnails and thumbnail panel should be
  numPages <- pageAdjustment state `get` adjustmentUpper
  let width = newWidth `div` numColumns
      height = heightFromWidth width
      numRows = round numPages `div` numColumns + 1
  layoutSetSize layout newWidth (height*numRows)
  -- Add thumbnails for the new sizes
  sequence_ [ do
    let page = numColumns*row+col+1
    view <- makeView state (const page) (postDrawBorder page state)
    widgetSetSizeRequest view width height
    layoutPut layout view (col*width) (row*height)
    view `widgetAddEvents` [ButtonPressMask, ButtonReleaseMask]
    view `on` buttonReleaseEvent $ tryEvent $ liftIO $ gotoPage state (const page)
    --view `set` [widgetTooltipText := Just ("Slide " ++ show page)] -- TODO: this triggers a bug where window drawing does not update
    | row <- [0..numRows-1], col <- [0..numColumns-1]]
  widgetShowAll layout

-- Apply "f" to the current page number
gotoPage state f = do
  oldPage <- liftM round $ pageAdjustment state `get` adjustmentValue
  pageAdjustment state `set` [adjustmentValue := fromIntegral ((f :: Int -> Int) oldPage)]
  newPage <- liftM round $ pageAdjustment state `get` adjustmentValue
  -- Update the history if needed
  when (oldPage /= newPage) $ do
    (back, _) <- readIORef (history state)
    writeIORef (history state) (oldPage : back, [])

------------------------
-- User Event handling
------------------------

-- Handler for key presses from the user
handleKey :: State -> [Modifier] -> String -> IO Bool
handleKey state [Control] "q" = mainQuit >> return True
handleKey state _ "h" = builderGetObject (builder state) castToAboutDialog "aboutDialog" >>= widgetShowAll >> return True
handleKey state _ "question" = builderGetObject (builder state) castToAboutDialog "aboutDialog" >>= widgetShowAll >> return True

-- Switching slides
handleKey state [] key | key `elem` ["left", "up", "page_up", "backspace"] =
  gotoPage state (+(-1)) >> modifyTimerState state unpauseTimer >> return True
handleKey state [] key | key `elem` ["right", "down", "page_down", "right", "space", "return"] =
  gotoPage state (+1) >> modifyTimerState state unpauseTimer >> return True
handleKey state [Shift] key | key `elem` ["left", "up", "page_up", "backspace"] =
  gotoPage state (+(-10)) >> modifyTimerState state unpauseTimer >> return True
handleKey state [Shift] key | key `elem` ["right", "down", "page_down", "right", "space", "return"] =
  gotoPage state (+10) >> modifyTimerState state unpauseTimer >> return True
handleKey state [] "home" = gotoPage state (const 0) >> return True
handleKey state [] "end" =
  do p <- pageAdjustment state `get` adjustmentUpper; gotoPage state (const (round p)); return True
handleKey state [Control] "g" = gotoSlideDialog state >> return True
handleKey state [Alt] "left" = historyBack state >> return True
handleKey state [] "xf86back" = historyBack state >> return True
handleKey state [Alt] "right" = historyForward state >> return True
handleKey state [] "xf86forward" = historyForward state >> return True

-- Clock/timer control
handleKey state [] "p" = modifyTimerState state togglePauseTimer >> return True
handleKey state [Shift] "p" = modifyTimerState state toggleStopTimer >> return True
handleKey state [Control] "p" = modifyTimerState state toggleStopTimer >> return True
handleKey state [] "pause" = modifyTimerState state togglePauseTimer >> return True
handleKey state [] "c" = modifyClockState state (\c -> case c of
                              RemainingTime -> ElapsedTime
                              ElapsedTime -> WallTime12
                              WallTime12 -> WallTime24
                              WallTime24 -> RemainingTime) >> return True
handleKey state [Shift] "c" = modifyTimerState state (const $ liftM (Stopped True 0) (readIORef (startTime state))) >> return True
handleKey state [Control] "c" = timerDialog state >> return True

-- Video mute
handleKey state [] "b" = modifyVideoMute state (\b -> return $ if b == MuteBlack then MuteOff else MuteBlack) >> return True
handleKey state [] "w" = modifyVideoMute state (\b -> return $ if b == MuteWhite then MuteOff else MuteWhite) >> return True

-- Presenter window
handleKey state [] "tab" =
  builderGetObject (builder state) castToNotebook "presenter.notebook" >>=
    (`set` [notebookCurrentPage :~ (`mod` 2) . (+ 1)]) >> return True
handleKey state [] "bracketleft" =
  builderGetObject (builder state) castToPaned "preview.paned" >>= (`set` [panedPosition :~ max 0 . (+(-20))]) >> return True
handleKey state [] "bracketright" =
  builderGetObject (builder state) castToPaned "preview.paned" >>= (`set` [panedPosition :~ (+20)]) >> return True
handleKey state [Shift] "braceleft" =
  builderGetObject (builder state) castToPaned "preview.paned" >>= (`set` [panedPosition :~ max 0 . (+(-1))]) >> return True
handleKey state [Shift] "braceright" =
  builderGetObject (builder state) castToPaned "preview.paned" >>= (`set` [panedPosition :~ (+1)]) >> return True
handleKey state [] "equal" = panedStops state >> return True

-- Files
handleKey state [Shift] "q" = setDocument state makeTitle 0 0 Nothing Nothing where
  makeTitle t = t ++ " Window - " ++ appName
handleKey state [Control] "r" = readIORef (documentURL state) >>=
  maybe (errorDialog "Cannot open file: No file selected" >> return False) (openDoc state) >> return True
handleKey state [Control] "o" = openFileDialog state >> return True

-- Window control
handleKey state [] "escape" = do f <- readIORef (fullscreen state); when f (toggleFullScreen state); return True
handleKey state [] "f" = toggleFullScreen state >> return True
handleKey state [] "f11" = toggleFullScreen state >> return True
handleKey state [Alt] "return" = toggleFullScreen state >> return True
handleKey state [Control] "l" = toggleFullScreen state >> return True
handleKey state [] "m" = changeMonitors state f where
  f mP mA n = if mA `incMod` n == mP then (mP `incMod` n, mP `incMod` n) else (mP, mA `incMod` n)
handleKey state [Shift] "m" = changeMonitors state f where
  f mP mA n = if mA == mP then (mP `decMod` n, mP `decMod` n `decMod` n) else (mP, mA `decMod` n)
handleKey state [Control] "m" = changeMonitors state f where f mP mA n = (mP `incMod` n, mA)
handleKey state [Shift,Control] "m" = changeMonitors state f where f mP mA n = (mP `decMod` n, mA)
handleKey state [Alt] "m" = changeMonitors state f where f mP mA n = (mP, mA `incMod` n)
handleKey state [Shift,Alt] "m" = changeMonitors state f where f mP mA n = (mP, mA `decMod` n)

handleKey _ _ name | name `elem` [ -- Ignore modifier keys
  "shift_l", "shift_r", "control_l", "control_r", "alt_l", "alt_r",
  "super_l", "super_r", "caps_lock", "menu", "xf86wakeup"]
  = return True
handleKey state mods name = putStrLn ("Unknown key \""++name++"\" with mods "++show mods) >> return False

-- Move back one slide in the history
historyBack state = do
  (back, forward) <- readIORef (history state)
  currPage <- liftM round $ pageAdjustment state `get` adjustmentValue
  case back of
    [] -> return ()
    prevPage : back -> do pageAdjustment state `set` [adjustmentValue := fromIntegral prevPage]
                          writeIORef (history state) (back, currPage : forward)

-- Move forward one slide in the history
historyForward state = do
  (back, forward) <- readIORef (history state)
  currPage <- liftM round $ pageAdjustment state `get` adjustmentValue
  case forward of
    [] -> return ()
    nextPage : forward -> do pageAdjustment state `set` [adjustmentValue := fromIntegral nextPage]
                             writeIORef (history state) (currPage : back, forward)

-- Toggle whether we are in fullscreen mode
toggleFullScreen state = do
  f <- readIORef (fullscreen state)
  mapM_ (if f then windowUnfullscreen else windowFullscreen) =<< mainWindows state
  writeIORef (fullscreen state) $ not f

-- Move the divider on the preview window to the next logical division point.
-- These points are:
--   - All the way to the left
--   - Perfectly fit the right preview
--   - 1/3 of the way from the left
--   - Centered
--   - 1/3 of the way from the right
--   - Perfectly fit the left preview
--   - All the way to the right
panedStops state = do
  -- Get the current position and size of the divider
  paned <- builderGetObject (builder state) castToPaned "preview.paned"
  maxPos <- liftM fromIntegral $ paned `get` panedMaxPosition
  oldPos <- liftM fromIntegral $ paned `get` panedPosition
  (_, panedHeight) <- widgetGetSize paned
  -- Get the page number of the current and last pages
  p <- liftM round $ pageAdjustment state `get` adjustmentValue
  pLast <- liftM round $ pageAdjustment state `get` adjustmentUpper
  -- Compute where do divide to get perfect fits and store them in "stops"
  document <- readIORef (document state)
  stops <- case document of
    Nothing -> return [] -- If there is no document, then there are no stops
    Just document -> do
      (pageWidth1, pageHeight1) <- pageGetSize =<< documentGetPage document (p - 1)
      (pageWidth2, pageHeight2) <- pageGetSize =<< documentGetPage document (p `min` pLast - 1)
      return [round (fromIntegral panedHeight * pageWidth1 / pageHeight1),
              maxPos - round (fromIntegral panedHeight * pageWidth2 / pageHeight2)]
  -- Store the other divisions in stops'
  let stops' = [maxPos `div` 3, maxPos `div` 2, maxPos * 2 `div` 3, maxPos]
  -- Move to the next stop greater than the current stop.
  paned `set` [panedPosition := case sort $ filter (> oldPos) $ stops ++ stops' of
                                  [] -> 0 -- If no more stops, go fully left
                                  (x:_) -> x]

-- Move the windows between the available monitors according to the
-- provided f function.  For forwards movement, the order is that we
-- always move the audience window first, but if the audience window would
-- move to the same monitor as the presenter window then we advance the
-- presenter window and also move the audience window to that monitor.
changeMonitors state f = do
  wP <- presenterWindow state
  wA <- audienceWindow state
  screenP <- wP `get` windowScreen
  screenA <- wA `get` windowScreen
  if screenP /= screenA
    then do errorDialog ("Cannot move windows as the presenter and audience windows are on different screens.\n\n"++
                         "Contact the developer if you want support for this.")
            return True
    else do
      dwP <- widgetGetDrawWindow wP
      dwA <- widgetGetDrawWindow wA
      mP <- screenGetMonitorAtWindow screenP dwP
      mA <- screenGetMonitorAtWindow screenA dwA
      -- There are render glitches if we move the windows while in full screen
      -- so we have to move out of full screen before moving.
      -- It would be nice if we could move back into full screen after moving
      -- but that also triggers render errors.  I don't know why.
      readIORef (fullscreen state) >>= flip when (toggleFullScreen state)
      n <- screenGetNMonitors screenP
      let (mP', mA') = f mP mA n
      moveWindow wP mP'
      moveWindow wA mA'
      return True

-- Move a window to a given monitor (mod the number of monitors) if it is not already there
moveWindow w m = do
  screen <- w `get` windowScreen
  dw <- widgetGetDrawWindow w
  m' <- screenGetMonitorAtWindow screen dw
  n <- screenGetNMonitors screen
  when (m' /= m `mod` n) $ do
    Rectangle x y _ _ <- screenGetMonitorGeometry screen (m `mod` n)
    windowMove w x y

----------------
-- Dialogs
----------------

timerDialog state = do
  -- Get dialog and text fields from GUI builder
  dialog <- builderGetObject (builder state) castToDialog "timerDialog"
  [remainingTimeEntry, elapsedTimeEntry, startTimeEntry, warningTimeEntry, endTimeEntry] <-
    mapM (builderGetObject (builder state) castToEntry)
    ["remainingTimeEntry", "elapsedTimeEntry", "startTimeEntry", "warnTimeEntry", "endTimeEntry"]
  [running, paused, stopped] <-
    mapM (builderGetObject (builder state) castToRadioButton) ["runningRadio", "pausedRadio", "stoppedRadio"]
  [remainingTimeRadio, elapsedTimeRadio, h12ClockRadio, h24ClockRadio] <-
    mapM (builderGetObject (builder state) castToRadioButton)
    ["remainingTimeRadio", "elapsedTimeRadio", "12HourClockRadio", "24HourClockRadio"]

  -- Populate the GUI elements based on the state
  clock' <- readIORef (clock state)
  (case clock' of RemainingTime -> remainingTimeRadio; ElapsedTime -> elapsedTimeRadio;
                  WallTime12 -> h12ClockRadio; WallTime24 -> h24ClockRadio) `set` [toggleButtonActive := True]

  timer' <- readIORef (timer state)
  (case timer' of Stopped False _ _ -> stopped; Stopped True _ _ -> paused;
                  Counting {} -> running) `set` [toggleButtonActive := True]

  Stopped True timeElapsed timeRemaining <- pauseTimer =<< readIORef (timer state)
    -- ^ Get the amount of time remaining, don't actually pause anything
  remainingTimeEntry `set` [entryText := formatTime timeRemaining]
  elapsedTimeEntry `set` [entryText := formatTime (timeElapsed+1000*1000-1{-microseconds-})]
    -- ^ Compensate for rounding to we keep elapsed + remaining = total

  startTimeEntry `set` [entryText :=> liftM formatTime (readIORef (startTime state))]
  warningTimeEntry `set` [entryText :=> liftM formatTime (readIORef (warningTime state))]
  endTimeEntry `set` [entryText :=> liftM formatTime (readIORef (endTime state))]

  -- Set the default keyboard focus and display the dialog
  widgetGrabFocus remainingTimeEntry
  loopDialog dialog $ do -- NOTE: The "do" block runs when the user clicks "Okay"
    -- Get the values of the test fields
    [remainingTime'', elapsedTime'', startTime'', warningTime'', endTime''] <-
        mapM (`get` entryText) [remainingTimeEntry, elapsedTimeEntry, startTimeEntry, warningTimeEntry, endTimeEntry]
    -- Parse the time fields and report errors if needed
    case (parseTime remainingTime'', parseTime elapsedTime'', parseTime startTime'',
          parseTime warningTime'', parseTime endTime'') of
      (Nothing, _, _, _, _) -> errorDialog ("Error parsing remaining time: "++remainingTime'') >> return False
      (_, Nothing, _, _, _) -> errorDialog ("Error parsing elapsed time: "++elapsedTime'') >> return False
      (_, _, Nothing, _, _) -> errorDialog ("Error parsing start time: "++startTime'') >> return False
      (_, _, _, Nothing, _) -> errorDialog ("Error parsing warning time: "++warningTime'') >> return False
      (_, _, _, _, Nothing) -> errorDialog ("Error parsing end time: "++warningTime'') >> return False
      (Just remain, Just elapsed, Just start, Just warn, Just end) -> do
        -- Save the parsed time value to the state
        writeIORef (startTime state) start
        writeIORef (warningTime state) warn
        writeIORef (endTime state) end
        -- Set the timer state based the selected radio button
        do [r,p,s] <- mapM (`get` toggleButtonActive) [running, paused, stopped]
           when r $ modifyTimerState state (const $ return $ Stopped True elapsed remain) >>
                    modifyTimerState state startTimer
           when p $ modifyTimerState state (const $ return $ Stopped True elapsed remain)
           when s $ modifyTimerState state (const $ return $ Stopped False elapsed remain)
        -- Set the clock mode based on the selected radio button
        do [r,e,h12,h24] <- mapM (`get` toggleButtonActive) [
                             remainingTimeRadio, elapsedTimeRadio, h12ClockRadio, h24ClockRadio]
           modifyClockState state (const $ if r then RemainingTime 
                                      else if e then ElapsedTime
                                      else if h12 then WallTime12
                                      else if h24 then WallTime24
                                      else error "INTERNAL ERROR: No clock radio active")
        return True
  -- Close the dialog
  widgetHide dialog

gotoSlideDialog state = do
  -- Get dialog and text fields from GUI builder
  dialog <- builderGetObject (builder state) castToDialog "pageDialog"
  entry <- builderGetObject (builder state) castToSpinButton "pageDialogSpinButton"
  adjustment <- builderGetObject (builder state) castToAdjustment "pageDialogAdjustment"
  label <- builderGetObject (builder state) castToLabel "pageDialogLabel"

  -- Set the dialog spinner and label to correspond to the current and max page number of the document
  pageNum <- pageAdjustment state `get` adjustmentValue
  pageMax <- pageAdjustment state `get` adjustmentUpper
  adjustment `set` [adjustmentValue := pageNum, adjustmentUpper := pageMax]
  label `set` [labelText := "Go to slide (1-" ++ show (round pageMax :: Integer) ++ "):"]

  -- Show the dialog
  widgetShowAll dialog
  widgetGrabFocus entry
  r <- dialogRun dialog

  -- When the dialog closes, get the spinner value and set the current page
  value <- entry `get` spinButtonValue
  when (r == ResponseOk) $ gotoPage state (const (round value))
  widgetHide dialog

-- Open and run a modal file selection dialog and set load the PDF document that is selected.
openFileDialog state = do
  dialog <- fileChooserDialogNew (Just $ "Open - " ++ appName) Nothing FileChooserActionOpen
            [((T.unpack stockOpen), ResponseOk), ((T.unpack stockCancel), ResponseCancel)]
  maybe (return ()) (void . fileChooserSetURI dialog) =<< readIORef (documentURL state)
  loopDialog dialog (openDoc state . head =<< fileChooserGetURIs dialog)
  widgetDestroy dialog
  return True

-- Set the video mute state and the text of the video mute status label
modifyVideoMute state f = do
  mute <- f =<< readIORef (videoMute state)
  builderGetObject (builder state) castToLabel "videoMuteStatusLabel" >>= (`set` case mute of
    MuteOff -> [labelText := "\x2600", -- U+2600 = Black sun with rays (solid center)
                labelAttributes := [AttrSize 0 (negate 1) 30, AttrForeground 0 (negate 1) black]]
    MuteWhite -> [labelText := "\x2600", -- U+2600 = Black sun with rays (solid center)
                  labelAttributes := [AttrSize 0 (negate 1) 30, AttrForeground 0 (negate 1) white]]
    MuteBlack -> [labelText := "\x263C", -- U+263C = White sun with rays (hollow center)
                  labelAttributes := [AttrSize 0 (negate 1) 30, AttrForeground 0 (negate 1) white]])
  writeIORef (videoMute state) mute

-- Open and run a modal error dialog with a textual message.
errorDialog msg = do
  dialog <- messageDialogNew Nothing [DialogModal, DialogDestroyWithParent] MessageError ButtonsClose msg
  dialogRun dialog
  widgetDestroy dialog

-- Keep running a dialog until the user clicks "Okay" and "m" returns "True"
loopDialog d m = do
  r <- dialogRun d
  when (r == ResponseOk) $ do
    m' <- m
    unless m' $ loopDialog d m

------------------------
-- Views
------------------------

-- Make a widget that displays a slide.
--   - offset: computes the slide to display from the current slide number
--   - postDraw: extra drawing that should be done at the end
makeView :: State -> (Int -> Int) -> (DrawWindow -> GC -> DrawingArea -> EventM EExpose ()) -> IO DrawingArea
makeView state offset postDraw = do
  area <- drawingAreaNew
  widgetModifyBg area StateNormal black
  area `on` exposeEvent $ tryEvent $ drawView state offset postDraw area
  area `on` sizeAllocate $ \(Graphics.UI.Gtk.Rectangle _ _ width height) ->
    liftIO $ modifyIORef (views state) (Map.insert (castToWidget area) (width, height))
  area `on` unrealize $
    liftIO $ modifyIORef (views state) (Map.delete (castToWidget area))
  return area

-- Event handler for drawing a view
--   - offset: computes the slide to display from the current slide number
--   - postDraw: extra drawing that should be done at the end
--   - area: the widget that needs to be redrawn
drawView state offset postDraw area = do
  -- Get the maximum and current slide number
  n <- liftIO $ liftM round $ pageAdjustment state `get` adjustmentUpper
  p <- liftIO $ liftM (offset . round) $ pageAdjustment state `get` adjustmentValue
  -- Don't render if not in range.  Needed b/c the preview panel may
  -- go out of range when on the last slide.
  when (p <= n && p >= 1) $ do
    drawWindow <- eventWindow
    (w, h) <- liftIO $ widgetGetSize area
    cache' <- liftIO $ readIORef (pages state)
    gc <- liftIO $ gcNew drawWindow
    case Map.lookup (p, w, h) cache' of
      -- If we haven't rendered the slide yet, then use placeholder text
      Nothing -> do
        pc <- liftIO $ widgetGetPangoContext area
        doc <- liftIO $ readIORef (document state)
        layout <- liftIO $ layoutText pc $ case doc of
          Nothing -> "" -- No document so no text needed
          Just _  -> "Rendering slide "++show p++" of "++show n++"..."
        liftIO $ layoutSetAttributes layout [AttrForeground 0 (negate 1) white,
                                             AttrWeight 0 (negate 1) WeightBold,
                                             AttrSize 0 (negate 1) 24]
        liftIO $ drawLayout drawWindow gc 0 0 layout
        return ()
      -- If we have already rendered the slide, then uncompress and draw the data
      Just (pixels, width', height', stride) -> do
        (width, height) <- liftIO $ drawableGetSize drawWindow
        liftIO $ BSU.unsafeUseAsCString
          (BS.concat (BSL.toChunks (decompressWith (defaultDecompressParams { decompressBufferSize = height' * stride }) pixels)))
          (\pixelPtr ->
            withImageSurfaceForData (castPtr pixelPtr) FormatRGB24 width' height' stride (\surface ->
              renderWithDrawable drawWindow $ do
                translate (fromIntegral $ (width - width') `div` 2) (fromIntegral $ (height - height') `div` 2)
                setSourceSurface surface 0 0
                paint))
        return ()
    postDraw drawWindow gc area

-- The following functions are postDraw functions to be passed to drawView

-- No extra drawing to be done (used by preview views)
postDrawNone _ _ _ = return ()

-- Draw a border if the current slide is the shown slide (used by thumbnails)
postDrawBorder p state drawWindow gc area = do
  p' <- liftIO $ liftM round $ pageAdjustment state `get` adjustmentValue
  when (p == p') $ liftIO $ do
    color <- widgetGetStyle area >>= flip styleGetBackground StateSelected
    gcGetValues gc >>= \v -> gcSetValues gc (v { foreground = color, lineWidth = 6 })
    (width, height) <- drawableGetSize drawWindow
    drawRectangle drawWindow gc False 0 0 width height

-- Draw a blank screen if video mute is enabled (used by audience view)
postDrawVideoMute state drawWindow _gc _area = do
  videoMute' <- liftIO $ readIORef (videoMute state)
  case videoMute' of
    MuteOff -> return ()
    MuteBlack -> liftIO $ renderWithDrawable drawWindow (setSourceRGB 0.0 0.0 0.0 >> paint)
    MuteWhite -> liftIO $ renderWithDrawable drawWindow (setSourceRGB 1.0 1.0 1.0 >> paint)
    --MuteFreeze n -> drawView state (const n) postDrawNone area

------------------------
-- Clock/timer rendering and control
------------------------

-- Set the clock mode (e.g., 12 vs 24 hour)
modifyClockState state f = modifyIORef (clock state) f >> displayTime state

-- Functions that are used as parameter to modifyTimerState
startTimer (Counting start end) = return (Counting start end)
startTimer (Stopped _ elapsed remaining) = getMicroseconds >>= \t -> return (Counting (t-elapsed) (t+remaining))

pauseTimer (Counting start end) = getMicroseconds >>= \t -> return (Stopped True (t-start) (end-t))
pauseTimer (Stopped _ elapsed remaining) = return (Stopped True elapsed remaining)

stopTimer (Counting start end) = getMicroseconds >>= \t -> return (Stopped False (t-start) (end-t))
stopTimer (Stopped _ elapsed remaining) = return (Stopped False elapsed remaining)

unpauseTimer (Stopped False elapsed remaining) = return (Stopped False elapsed remaining)
unpauseTimer t = startTimer t

togglePauseTimer t@(Stopped True _ _) = startTimer t
togglePauseTimer t = pauseTimer t

toggleStopTimer t@(Stopped False _ _) = startTimer t
toggleStopTimer t = stopTimer t

-- Modifies the current timer state. "f" should be one of 'startTimer', etc.
modifyTimerState state f = do
  timerState <- f =<< readIORef (timer state)
  builderGetObject (builder state) castToLabel "timerStatusLabel" >>= (`set` case timerState of
    Stopped True _ _ -> [labelText := "\x25AE\x25AE", -- U+25AE = One bar of pause icon
                 labelAttributes := [AttrSize 0 (negate 1) 30, AttrForeground 0 (negate 1) white]]
    Stopped False _ _ -> [labelText := "\x25A0", -- U+25A0 = Stop
                 labelAttributes := [AttrSize 0 (negate 1) 30, AttrForeground 0 (negate 1) white]]
    Counting _ _ -> [labelText := "\x25B6", -- U+25B6 = Play
                   labelAttributes := [AttrSize 0 (negate 1) 30, AttrForeground 0 (negate 1) black]])
  writeIORef (timer state) timerState

-- Render the clock/timer
displayTime state = do
  -- Compute foreground and background colors based on timer status and times
  timer' <- readIORef (timer state)
  (elapsed, remaining) <- case timer' of
    Stopped _ elapsed remaining -> return (elapsed, remaining)
    Counting start end -> getMicroseconds >>= \t -> return (t - start, end - t)
  warningTime' <- readIORef (warningTime state)
  endTime' <- readIORef (endTime state)
  let (fg_color, bg_color) | remaining < endTime' = (white, red)
                           | remaining < warningTime' = (white, purple)
                           | otherwise = (white, black)

  -- Get time string based on clock mode
  clockMode <- readIORef (clock state)
  let clockStr = case clockMode of 
        RemainingTime -> " \x231B" -- U+231B = Hour glass
        ElapsedTime -> " \x231A" -- U+231A = Wall clock
        WallTime12 -> ""
        WallTime24 -> " (24H)"
  time <- case clockMode of
            RemainingTime -> return (formatTime remaining)
            ElapsedTime -> return (formatTime elapsed)
            WallTime12 -> getTime "%I:%M %p"
            WallTime24 -> getTime "%H:%M"

  -- Function for setting the text of a label at a given size
  let setLabel attrSize size label = label `set` [
        labelText := time++clockStr,
        labelAttributes := [attrSize 0 (length time) size, -- The first text is at full size
                            attrSize (length time) (negate 1) (size / 2), -- The second test is at half size
                            AttrForeground 0 (negate 1) fg_color,
                            AttrBackground 0 (negate 1) bg_color]]

  -- Set the hidden label so we maintain a minimum size
  setLabel AttrSize textSize =<< builderGetObject (builder state) castToLabel "hiddenTimeLabel"
  -- TODO: Why is AttrSize a different font than what the GUI builder makes?

  -- Initially set the size based on height
  label <- builderGetObject (builder state) castToLabel "timeLabel"
  (w, h) <- widgetGetSize label
  setLabel AttrAbsSize (fromIntegral h) label

  -- Then rescale the text to ensure it is not too wide
  (_, PangoRectangle _ _ iw _) <- layoutGetExtents =<< labelGetLayout label
  setLabel AttrAbsSize (fromIntegral (h `min` (h * w `div` round iw))) label

------------------------
-- Time formatting
------------------------

-- Parse time entered by the user.
-- The accepted format is "-* ((float :)? float :)? float" but whitespace is allowed anywhere.
-- I'd really prefer to use standard code for this, but I couldn't find any
parseTime :: String -> Maybe Integer{-microseconds-}
parseTime str = go (filter (not . isSpace) str) where
  go ('-' : str) = liftM negate (go str)
  go str = do
    let (sc, sc') = break (':'==) (reverse str)
        (mn, mn') = break (':'==) (if null sc' then "0" else drop 1 sc')
        hr = if null mn' then "0" else drop 1 mn'
    [Just h, Just m, Just s] <- return $ map (maybeRead . reverse) [hr, mn, sc]
    return $ round (1000 * 1000 * (s + 60 * (m + 60 * h)) :: Double)

-- Format time for display to user.  Format: H:MM:SS or -H:MM:SS
formatTime :: Integer -> String
formatTime microseconds = printf "%s%d:%02d:%02d" sign (abs hours) (abs minutes) (abs seconds) where
  sign = if microseconds < 0 then "-" else ""
  ((((hours, minutes), seconds), _tenths), _) = id // 60 // 60 // 10 // (100*1000) $ microseconds
  (//) f base val = (f q, r) where (q, r) = val `quotRem` base

-- Return current time in microseconds
getMicroseconds :: IO Integer
getMicroseconds = do
  GTimeVal { gTimeValSec = sec, gTimeValUSec = usec } <- gGetCurrentTime
  return (fromIntegral sec * 1000 * 1000 + fromIntegral usec)

-- Return the time of day according to "format"
getTime format = do
  tz <- getCurrentTimeZone
  utc <- getCurrentTime
  return $ Data.Time.Format.formatTime Data.Time.Format.defaultTimeLocale format (utcToLocalTime tz utc)

------------------------
-- Loading and Rendering the PDF document
------------------------

-- Load a new PDF document
openDoc state uri = do
  doc <- Control.Exception.catch (documentNewFromFile uri Nothing) -- Explicit name to avoid ambiguity in GHC 7.4
           (\x -> errorDialog ("Error opening \"" ++ uri ++ "\": " ++ show (x :: GError)) >> return Nothing)
  case doc of
    Nothing -> errorDialog ("Unknown error opening \"" ++ uri ++ "\"") >> return True
    Just doc -> do
      -- Use the document title or filename as the window title
      title <- doc `get` documentTitle
      let makeTitle t = (if null title then takeFileName uri else title) ++ " (" ++ t ++ " Window) - " ++ appName
      upper <- liftM fromIntegral (documentGetNPages doc)
      setDocument state makeTitle 1 upper (Just uri) (Just doc)

-- Set state variables for a new PDF document
setDocument state makeTitle lower upper uri doc = do
  audienceWindow state >>= (`windowSetTitle` makeTitle "Audience")
  presenterWindow state >>= (`windowSetTitle` makeTitle "Presenter")
  -- Ensure that the current page number is in bounds for the new document
  -- NOTE: we increment the current page number by 0 to trigger the range clamping on pageAdjustment
  pageAdjustment state `set` [adjustmentLower := lower, adjustmentUpper := upper, adjustmentValue :~ (+0)]
  -- Save the new state and return
  writeIORef (pages state) Map.empty
  writeIORef (documentURL state) uri
  writeIORef (document state) doc
  return True

-- We render in a timeout to keep the GUI responsive.  We move to a
-- slower timeout when everything is already rendered to avoid hogging
-- the CPU.  We avoid using a separate thread because that would
-- require using postGUISync which causes delays that slow down the
-- rendering.
startRenderThread state progress = renderThreadSoon where
  renderThreadSoon = widgetShow progress >> void (timeoutAdd (renderThread >> return False) 1{-milliseconds-})
  renderThreadDelayed = widgetHide progress >> void (timeoutAdd (renderThread >> return False) 100{-milliseconds-})
  renderThread = do
    doc <- readIORef (document state)
    case doc of
      Nothing -> renderThreadDelayed -- We have no document to render
      Just doc -> do
        numPages <- liftM round $ pageAdjustment state `get` adjustmentUpper
        currPage <- liftM round $ pageAdjustment state `get` adjustmentValue
        -- Get the sizes of views and clean the cache of sizes with no views
        views <- liftM (nub . Map.elems) $ readIORef (views state)
        cache <- liftM (Map.filterWithKey (\(_, w, h) _ -> (w, h) `elem` views)) $ readIORef (pages state)
        -- Select a page to be rendered for a view that is not in the cache.
        -- Choose the view close to the current page if possible.
        case [(page,w,h) |
              page <- sortBy (comparing (\i -> max (i - currPage) (2 * (currPage - i)))) [1..numPages],
              (w,h) <- sortBy (flip compare) views,
              (page,w,h) `Map.notMember` cache] of
          -- If nothing to be rendered, then move to the slower timeout to avoid hogging the CPU.
          [] -> renderThreadDelayed
          -- Otherwise, render that page and store a compressed copy in the cache.
          work@((pageNum, width, height) : _) -> do
            progressBarSetFraction progress (1 - fromIntegral (length work) / fromIntegral (numPages * length views))
            page <- documentGetPage doc (pageNum-1)
            (docWidth, docHeight) <- pageGetSize page
            -- Find a scaling factor that fits in the view while preserving aspect ratio
            let scaleFactor = min (fromIntegral width  / docWidth)
                                  (fromIntegral height / docHeight)
            -- Render the page to an image surface
            -- NOTE: we use 24 bits instead of 32 to cut down on size and time
            (pixels, w, h, stride) <- withImageSurface FormatRGB24
              (round $ scaleFactor * docWidth) (round $ scaleFactor * docHeight) (\surface -> do
                renderWith surface $ do scale scaleFactor scaleFactor
                                        setSourceRGB 1.0 1.0 1.0 >> paint -- draw a white page background
                                        pageRender page -- draw page
                return (,,,) `ap` imageSurfaceGetData surface
                             `ap` imageSurfaceGetWidth surface
                             `ap` imageSurfaceGetHeight surface
                             `ap` imageSurfaceGetStride surface)
            -- Compress the data stored in the image surface
            compression' <- readIORef (compression state)
            let pixels' = compressWith (defaultCompressParams { compressLevel = compressionLevel compression' })
                                       (BSL.fromChunks [pixels])
            BSL.length pixels' `seq` return () -- avoid memory leak due to not being strict enough
            writeIORef (pages state) (Map.insert (pageNum,width,height) (pixels', w, h, stride) cache)
            -- Redraw the windows and re-enter the render thread quickly in case their is more to render
            mainWindows state >>= mapM_ widgetQueueDraw
            renderThreadSoon
