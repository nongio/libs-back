/* XGServerWindows - methods for window/screen handling

   Copyright (C) 1999 Free Software Foundation, Inc.

   Written by:  Adam Fedor <fedor@gnu.org>
   Date: Nov 1999
   
   This file is part of GNUstep

   This library is free software; you can redistribute it and/or
   modify it under the terms of the GNU Library General Public
   License as published by the Free Software Foundation; either
   version 2 of the License, or (at your option) any later version.
   
   This library is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
   Library General Public License for more details.
   
   You should have received a copy of the GNU Library General Public
   License along with this library; if not, write to the Free
   Software Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
   */

#include "config.h"
#include <math.h>
#include <Foundation/NSString.h>
#include <Foundation/NSArray.h>
#include <Foundation/NSValue.h>
#include <Foundation/NSProcessInfo.h>
#include <Foundation/NSUserDefaults.h>
#include <Foundation/NSAutoreleasePool.h>
#include <Foundation/NSDebug.h>
#include <Foundation/NSException.h>
#include <AppKit/DPSOperators.h>
#include <AppKit/NSApplication.h>
#include <AppKit/NSCursor.h>
#include <AppKit/NSGraphics.h>
#include <AppKit/NSWindow.h>
#include <AppKit/NSImage.h>
#include <AppKit/NSBitmapImageRep.h>

#ifdef HAVE_UNISTD_H
#include <unistd.h>
#endif

#ifdef HAVE_WRASTER_H
#include "wraster.h"
#else
#include "x11/wraster.h"
#endif
#include <X11/cursorfont.h>

#include <X11/extensions/shape.h>

#include "x11/XGDragView.h"
#include "x11/XGInputServer.h"

#define	ROOT generic.appRootWindow


static BOOL handlesWindowDecorations = YES;


/*
 * Name for application root window.
 */
static char	*rootName = 0;

#define WINDOW_WITH_TAG(windowNumber) (gswindow_device_t *)NSMapGet(windowtags, (void *)windowNumber) 

/* Current mouse grab window */
static gswindow_device_t *grab_window = NULL;

/* Keep track of windows */
static NSMapTable *windowmaps = NULL;
static NSMapTable *windowtags = NULL;

@interface NSCursor (BackendPrivate)
- (void *)_cid;
@end

void __objc_xgcontextwindow_linking (void)
{
}

/*
 * The next two functions derived from WindowMaker by Alfredo K. Kojima
 */
static unsigned char*
PropGetCheckProperty(Display *dpy, Window window, Atom hint, Atom type,
		     int format, int count, int *retCount)
{
  Atom type_ret;
  int fmt_ret;
  unsigned long nitems_ret;
  unsigned long bytes_after_ret;
  unsigned char *data;
  int tmp;

  if (count <= 0)
    tmp = 0xffffff;
  else
    tmp = count;

  if (XGetWindowProperty(dpy, window, hint, 0, tmp, False, type,
			 &type_ret, &fmt_ret, &nitems_ret, &bytes_after_ret,
			 (unsigned char **)&data)!=Success || !data)
    return NULL;

  if ((type!=AnyPropertyType && type!=type_ret)
    || (count > 0 && nitems_ret != (unsigned long)count)
    || (format != 0 && format != fmt_ret))
    {
      XFree(data);
      return NULL;
    }

  if (retCount)
    *retCount = nitems_ret;

  return data;
}

static void
setNormalHints(Display *d, gswindow_device_t *w)
{
  if (w->siz_hints.flags & (USPosition | PPosition))
    NSDebugLLog(@"XGTrace", @"Hint posn %d: %d, %d",
      w->number, w->siz_hints.x, w->siz_hints.y);
  if (w->siz_hints.flags & (USSize | PSize))
    NSDebugLLog(@"XGTrace", @"Hint size %d: %d, %d",
      w->number, w->siz_hints.width, w->siz_hints.height);
  if (w->siz_hints.flags & PMinSize)
    NSDebugLLog(@"XGTrace", @"Hint mins %d: %d, %d",
      w->number, w->siz_hints.min_width, w->siz_hints.min_height);
  if (w->siz_hints.flags & PMaxSize)
    NSDebugLLog(@"XGTrace", @"Hint maxs %d: %d, %d",
      w->number, w->siz_hints.max_width, w->siz_hints.max_height);
  if (w->siz_hints.flags & PResizeInc)
    NSDebugLLog(@"XGTrace", @"Hint incr %d: %d, %d",
      w->number, w->siz_hints.width_inc, w->siz_hints.height_inc);
  XSetWMNormalHints(d, w->ident, &w->siz_hints);
}

/*
 * Setting Motif Hints for Window Managers (Nicola Pero, July 2000)
 */

/*
 * Motif window hints to communicate to a window manager 
 * that we want a window to have a titlebar/resize button/etc.
 */

/* Motif window hints struct */
typedef struct {
  unsigned long flags;
  unsigned long functions;
  unsigned long decorations;
  long input_mode;
  unsigned long status;
} MwmHints;

/* Number of entries in the struct */
#define PROP_MWM_HINTS_ELEMENTS 5

/* Now for each field in the struct, meaningful stuff to put in: */

/* flags */
#define MWM_HINTS_FUNCTIONS   (1L << 0)
#define MWM_HINTS_DECORATIONS (1L << 1)
#define MWM_HINTS_INPUT_MODE  (1L << 2)
#define MWM_HINTS_STATUS      (1L << 3)

/* functions */
#define MWM_FUNC_ALL          (1L << 0)
#define MWM_FUNC_RESIZE       (1L << 1)
#define MWM_FUNC_MOVE         (1L << 2)
#define MWM_FUNC_MINIMIZE     (1L << 3)
#define MWM_FUNC_MAXIMIZE     (1L << 4)
#define MWM_FUNC_CLOSE        (1L << 5)

/* decorations */
#define MWM_DECOR_ALL         (1L << 0)
#define MWM_DECOR_BORDER      (1L << 1)
#define MWM_DECOR_RESIZEH     (1L << 2)
#define MWM_DECOR_TITLE       (1L << 3)
#define MWM_DECOR_MENU        (1L << 4)
#define MWM_DECOR_MINIMIZE    (1L << 5)
#define MWM_DECOR_MAXIMIZE    (1L << 6)

/* We don't use the input_mode and status fields */

/* The atom */
#define _XA_MOTIF_WM_HINTS "_MOTIF_WM_HINTS"


Pixmap
xgps_cursor_mask(Display *xdpy, Drawable draw, const char *data,
                  int w, int h, int colors);

/* Now the code */

/* Set the style `styleMask' for the XWindow `window' using motif
 * window hints.  This makes an X call, please make sure you do it
 * only once.
 */
static void setWindowHintsForStyle (Display *dpy, Window window, 
				 unsigned int styleMask)
{
  MwmHints *hints;
  BOOL needToFreeHints = YES;
  Atom type_ret;
  int format_ret, success;
  unsigned long nitems_ret;
  unsigned long bytes_after_ret;
  static Atom mwhints_atom = None;

  /* Initialize the atom if needed */
  if (mwhints_atom == None)
    mwhints_atom = XInternAtom (dpy,_XA_MOTIF_WM_HINTS, False);
  
  /* Get the already-set window hints */
  success = XGetWindowProperty (dpy, window, mwhints_atom, 0, 
		      sizeof (MwmHints) / sizeof (long),
		      False, AnyPropertyType, &type_ret, &format_ret, 
		      &nitems_ret, &bytes_after_ret, 
		      (unsigned char **)&hints);

  /* If no window hints were set, create new hints to 0 */
  if (success != Success || type_ret == None)
    {
      needToFreeHints = NO;
      hints = alloca (sizeof (MwmHints));
      memset (hints, 0, sizeof (MwmHints));
    }

  /* Remove the hints we want to change */
  hints->flags &= ~MWM_HINTS_DECORATIONS;
  hints->flags &= ~MWM_HINTS_FUNCTIONS;
  hints->decorations = 0;
  hints->functions = 0;

  /* Now add to the hints from the styleMask */
  if (styleMask == NSBorderlessWindowMask
      || !handlesWindowDecorations)
    {
      hints->flags |= MWM_HINTS_DECORATIONS;
      hints->flags |= MWM_HINTS_FUNCTIONS;
      hints->decorations = 0;
      hints->functions = 0;
    }
  else
    {
      /* These need to be on all windows except mini and icon windows,
	 where they are specifically set to 0 (see below) */
      hints->flags |= MWM_HINTS_DECORATIONS;
      hints->decorations |= (MWM_DECOR_TITLE | MWM_DECOR_BORDER);
      if (styleMask & NSTitledWindowMask)
	{
	  // Without this, iceWM does not let you move the window!
	  // [idem below]
	  hints->flags |= MWM_HINTS_FUNCTIONS;
	  hints->functions |= MWM_FUNC_MOVE;
	}
      if (styleMask & NSClosableWindowMask)
	{
	  hints->flags |= MWM_HINTS_FUNCTIONS;
	  hints->functions |= MWM_FUNC_CLOSE;
	  hints->functions |= MWM_FUNC_MOVE;
	}
      if (styleMask & NSMiniaturizableWindowMask)
	{
	  hints->flags |= MWM_HINTS_DECORATIONS;
	  hints->flags |= MWM_HINTS_FUNCTIONS;
	  hints->decorations |= MWM_DECOR_MINIMIZE;
	  hints->functions |= MWM_FUNC_MINIMIZE;
	  hints->functions |= MWM_FUNC_MOVE;
	}
      if (styleMask & NSResizableWindowMask)
	{
	  hints->flags |= MWM_HINTS_DECORATIONS;
	  hints->flags |= MWM_HINTS_FUNCTIONS;
	  hints->decorations |= MWM_DECOR_RESIZEH;
	  hints->decorations |= MWM_DECOR_MAXIMIZE;
	  hints->functions |= MWM_FUNC_RESIZE;
	  hints->functions |= MWM_FUNC_MAXIMIZE;
	  hints->functions |= MWM_FUNC_MOVE;
        }
      if (styleMask & NSIconWindowMask)
	{
	  // FIXME
	  hints->flags |= MWM_HINTS_DECORATIONS;
	  hints->flags |= MWM_HINTS_FUNCTIONS;
	  hints->decorations = 0;
	  hints->functions = 0;
	}
      if (styleMask & NSMiniWindowMask)
	{
	  // FIXME
	  hints->flags |= MWM_HINTS_DECORATIONS;
	  hints->flags |= MWM_HINTS_FUNCTIONS;
	  hints->decorations = 0;
	  hints->functions = 0;
	}
    }  
  
  /* Set the hints */
  XChangeProperty (dpy, window, mwhints_atom, mwhints_atom, 32, 
		   PropModeReplace, (unsigned char *)hints, 
		   sizeof (MwmHints) / sizeof (long));
  
  /* Free the hints if allocated by the X server for us */
  if (needToFreeHints == YES)
    XFree (hints);  
}

/*
 * End of motif hints for window manager code
 */

@interface NSEvent (WindowHack)
- (void) _patchLocation: (NSPoint)loc;
@end

@implementation NSEvent (WindowHack)
- (void) _patchLocation: (NSPoint)loc
{
  location_point = loc;
}
@end

@implementation XGServer (WindowOps)

-(BOOL) handlesWindowDecorations
{
  return handlesWindowDecorations;
}


/*
 * Where a window has been reparented by the wm, we use this method to
 * locate the window given knowledge of its border window.
 */
+ (gswindow_device_t *) _windowForXParent: (Window)xWindow
{
  NSMapEnumerator	enumerator;
  Window		x;
  gswindow_device_t	*d;

  enumerator = NSEnumerateMapTable(windowmaps);
  while (NSNextMapEnumeratorPair(&enumerator, (void**)&x, (void**)&d) == YES)
    {
      if (d->root != d->parent && d->parent == xWindow)
	{
	  return d;
	}
    }
  return 0;
}

+ (gswindow_device_t *) _windowForXWindow: (Window)xWindow
{
  return NSMapGet(windowmaps, (void *)xWindow);
}

+ (gswindow_device_t *) _windowWithTag: (int)windowNumber
{
  return WINDOW_WITH_TAG(windowNumber);
}

/*
 * Convert a window frame in OpenStep absolute screen coordinates to
 * a frame in X absolute screen coordinates by flipping an applying
 * offsets to allow for the X window decorations.
 */
- (NSRect) _OSFrameToXFrame: (NSRect)o for: (void*)window
{
  gswindow_device_t	*win = (gswindow_device_t*)window;
  NSRect	x;

  x = o;
  x.origin.y = x.origin.y + o.size.height;
  x.origin.y = DisplayHeight(dpy, win->screen) - x.origin.y;
NSDebugLLog(@"Frame", @"O2X %d, %@, %@", win->number,
  NSStringFromRect(o), NSStringFromRect(x));
  return x;
}

/*
 * Convert a window frame in OpenStep absolute screen coordinates to
 * a frame suitable for setting X hints for a window manager.
 */
- (NSRect) _OSFrameToXHints: (NSRect)o for: (void*)window
{
  gswindow_device_t	*win = (gswindow_device_t*)window;
  NSRect	x;
  float	t, b, l, r;

  [self styleoffsets: &l : &r : &t : &b : win->win_attrs.window_style];

  x.size.width = o.size.width;
  x.size.height = o.size.height;
  x.origin.x = o.origin.x - l;
  x.origin.y = o.origin.y + o.size.height;
  x.origin.y = DisplayHeight(dpy, win->screen) - x.origin.y - t;
NSDebugLLog(@"Frame", @"O2H %d, %@, %@", win->number,
  NSStringFromRect(o), NSStringFromRect(x));
  return x;
}

/*
 * Convert a window frame in X  coordinates relative to the X-window to a frame
 * in OpenStep  coordinates relative to the window by flipping.
 */
- (NSRect) _XWinFrameToOSWinFrame: (NSRect)x for: (void*)window
{
  gswindow_device_t	*win = (gswindow_device_t*)window;
  NSRect	o;
  o.size.width = x.size.width;
  o.size.height = x.size.height;
  o.origin.x = x.origin.x;
  o.origin.y = win->siz_hints.height - x.origin.y;
  o.origin.y = o.origin.y - o.size.height;
  NSDebugLLog(@"GGFrame", @"%@ %@", NSStringFromRect(x), NSStringFromRect(o));
  return o;
}

/*
 * Convert a window frame in X absolute screen coordinates to a frame
 * in OpenStep absolute screen coordinates by flipping an applying
 * offsets to allow for the X window decorations.
 */
- (NSRect) _XFrameToOSFrame: (NSRect)x for: (void*)window
{
  gswindow_device_t	*win = (gswindow_device_t*)window;
  NSRect	o;

  o = x;
  o.origin.y = DisplayHeight(dpy, win->screen) - o.origin.y;
  o.origin.y = o.origin.y - o.size.height;
NSDebugLLog(@"Frame", @"X2O %d, %@, %@", win->number,
  NSStringFromRect(x), NSStringFromRect(o));
  return o;
}


- (XGWMProtocols) _checkWindowManager
{
  int wmflags;
  Window root;
  Window *win;
  Atom	*data;
  Atom	atom;
  int	count;

  root = DefaultRootWindow(dpy);
  wmflags = XGWM_UNKNOWN;

  /* Check for WindowMaker */
  atom = XInternAtom(dpy, "_WINDOWMAKER_WM_PROTOCOLS", False);
  data = (Atom*)PropGetCheckProperty(dpy, root, atom, XA_ATOM, 32, -1, &count);
  if (data != 0)
    {
      Atom	noticeboard;
      int	i = 0;

      noticeboard = XInternAtom(dpy, "_WINDOWMAKER_NOTICEBOARD", False);
      while (i < count && data[i] != noticeboard)
	{
	  i++;
	}
      XFree(data);

      if (i < count)
	{
	  Window	*win;
	  void		*d;

	  win = (Window*)PropGetCheckProperty(dpy, root, 
	    noticeboard, XA_WINDOW, 32, -1, &count);

	  if (win != 0)
	    {
	      d = PropGetCheckProperty(dpy, *win, noticeboard,
		XA_WINDOW, 32, 1, NULL);
	      if (d != 0)
		{
		  XFree(d);
		  wmflags |= XGWM_WINDOWMAKER;
		}
	      XFree(win);
	    }
	}
      else
	{
	  wmflags |= XGWM_WINDOWMAKER;
	}
    }

  /* Now check for Gnome */
  atom = XInternAtom(dpy, "_WIN_SUPPORTING_WM_CHECK", False);
  win = (Window*)PropGetCheckProperty(dpy, root, atom, 
				      XA_CARDINAL, 32, -1, &count);
  if (win != 0)
    {
      Window *win1;

      win1 = (Window*)PropGetCheckProperty(dpy, *win, atom, 
					   XA_CARDINAL, 32, -1, &count);
      // If the two are not identical, the flag on the root window, was
      // a left over from an old window manager.
      if (win1 && *win1 == *win)
        {
	  wmflags |= XGWM_GNOME;

	  generic.wintypes.win_type_atom = 
	      XInternAtom(dpy, "_WIN_LAYER", False);
	}
      if (win1)
        {
	  XFree(win1);
	}
      XFree(win);
    }

  /* Now check for NET (EWMH) compliant window manager */
  atom = XInternAtom(dpy, "_NET_SUPPORTING_WM_CHECK", False);
  win = (Window*)PropGetCheckProperty(dpy, root, atom, 
				      XA_WINDOW, 32, -1, &count);

  if (win != 0)
    {
      Window *win1;

      win1 = (Window*)PropGetCheckProperty(dpy, *win, atom, 
					   XA_WINDOW, 32, -1, &count);
      // If the two are not identical, the flag on the root window, was
      // a left over from an old window manager.
      if (win1 && *win1 == *win)
        {
	  wmflags |= XGWM_EWMH;

	  // Store window type Atoms for this WM
	  generic.wintypes.win_type_atom = 
	      XInternAtom(dpy, "_NET_WM_WINDOW_TYPE", False);
	  generic.wintypes.win_desktop_atom = 
	      XInternAtom(dpy, "_NET_WM_WINDOW_TYPE_DESKTOP", False);
	  generic.wintypes.win_dock_atom = 
	      XInternAtom(dpy, "_NET_WM_WINDOW_TYPE_DOCK", False);
	  generic.wintypes.win_floating_atom = 
	      XInternAtom(dpy, "_NET_WM_WINDOW_TYPE_TOOLBAR", False);
	  generic.wintypes.win_menu_atom = 
	      XInternAtom(dpy, "_NET_WM_WINDOW_TYPE_MENU", False);
	  generic.wintypes.win_modal_atom = 
	      XInternAtom(dpy, "_NET_WM_WINDOW_TYPE_DIALOG", False);
	  generic.wintypes.win_normal_atom = 
	      XInternAtom(dpy, "_NET_WM_WINDOW_TYPE_NORMAL", False);
	  // New in wmspec 1.2
	  generic.wintypes.win_utility_atom = 
	      XInternAtom(dpy, "_NET_WM_WINDOW_TYPE_UTILITY", False);
	  generic.wintypes.win_splash_atom = 
	      XInternAtom(dpy, "_NET_WM_WINDOW_TYPE_SPLASH", False);
	  //KDE extensions
	  generic.wintypes.win_override_atom = 
	      XInternAtom(dpy, "_KDE_NET_WM_WINDOW_TYPE_OVERRIDE", False);
	  generic.wintypes.win_topmenu_atom = 
	      XInternAtom(dpy, "_KDE_NET_WM_WINDOW_TYPE_TOPMENU", False);
	}
      if (win1)
        {
	  XFree(win1);
	}
      XFree(win);
    }

  NSDebugLLog(@"WM", 
	      @"WM Protocols: WindowMaker=(%s) GNOME=(%s) KDE=(%s) EWMH=(%s)",
	      (wmflags & XGWM_WINDOWMAKER) ? "YES" : "NO",
	      (wmflags & XGWM_GNOME) ? "YES" : "NO",
	      (wmflags & XGWM_KDE) ? "YES" : "NO",
	      (wmflags & XGWM_EWMH) ? "YES" : "NO");

  return wmflags;
}

- (gswindow_device_t *)_rootWindowForScreen: (int)screen
{
  int x, y, width, height;
  gswindow_device_t *window;

  /* Screen number is negative to avoid conflict with windows */
  window = WINDOW_WITH_TAG(-screen);
  if (window)
    return window;

  window = objc_malloc(sizeof(gswindow_device_t));
  memset(window, '\0', sizeof(gswindow_device_t));

  window->display = dpy;
  window->screen = screen;
  window->ident  = RootWindow(dpy, screen);
  window->root   = window->ident;
  window->type   = NSBackingStoreNonretained;
  window->number = -screen;
  window->map_state = IsViewable;
  window->visibility = -1;
  if (window->ident)
    XGetGeometry(dpy, window->ident, &window->root, 
		 &x, &y, &width, &height,
		 &window->border, &window->depth);

  window->xframe = NSMakeRect(x, y, width, height);
  NSMapInsert (windowtags, (void*)window->number, window);
  NSMapInsert (windowmaps, (void*)window->ident,  window);
  return window;
}

/* Create the window and screen list if necessary, add the root window to
   the window list as window 0 */
- (void) _checkWindowlist
{
  if (windowmaps)
    return;

  windowmaps = NSCreateMapTable(NSNonOwnedPointerMapKeyCallBacks,
				 NSNonOwnedPointerMapValueCallBacks, 20);
  windowtags = NSCreateMapTable(NSIntMapKeyCallBacks,
				 NSNonOwnedPointerMapValueCallBacks, 20);
}

- (void) _setupMouse
{
  int			numButtons;
  unsigned char		mouseNumbers[5];
  unsigned char		buttons[5] = {
			  Button1,
			  Button2,
			  Button3,
			  Button4,
			  Button5
			};
  int			masks[5] = {
			  Button1Mask,
			  Button2Mask,
			  Button3Mask,
			  Button4Mask,
			  Button5Mask
			};
  /*
   * Get pointer information - so we know which mouse buttons we have.
   * With a two button
   */
  numButtons = XGetPointerMapping(dpy, mouseNumbers, 5);
  if (numButtons > 5)
    {
      NSLog(@"Warning - mouse/pointer seems to have more than 5 buttons"
	@" - just using one to five");
      numButtons = 5;
    }
  generic.lMouse = buttons[0];
  generic.lMouseMask = masks[0];
  if (numButtons >= 5)
    {
      generic.upMouse = buttons[3];
      generic.downMouse = buttons[4];
      generic.rMouse = buttons[2];
      generic.rMouseMask = masks[2];
      generic.mMouse = buttons[1];
      generic.mMouseMask = masks[1];
    }
  else if (numButtons == 3)
    {
// FIXME: Button4 and Button5 are ScrollWheel up and ScrollWheel down 
//      generic.rMouse = buttons[numButtons-1];
//      generic.rMouseMask = masks[numButtons-1];
      generic.upMouse = 0;
      generic.downMouse = 0;
      generic.rMouse = buttons[2];
      generic.rMouseMask = masks[2];
      generic.mMouse = buttons[1];
      generic.mMouseMask = masks[1];
    }
  else if (numButtons == 2)
    {
      generic.upMouse = 0;
      generic.downMouse = 0;
      generic.rMouse = buttons[1];
      generic.rMouseMask = masks[1];
      generic.mMouse = 0;
      generic.mMouseMask = 0;
    }
  else if (numButtons == 1)
    {
      generic.upMouse = 0;
      generic.downMouse = 0;
      generic.rMouse = 0;
      generic.rMouseMask = 0;
      generic.mMouse = 0;
      generic.mMouseMask = 0;
    }
  else
    {
      NSLog(@"Warning - mouse/pointer seems to have NO buttons");
    }
}

- (void) _setupRootWindow
{
  NSProcessInfo		*pInfo = [NSProcessInfo processInfo];
  NSArray		*args;
  unsigned int		i;
  unsigned int		argc;
  char			**argv;
  XClassHint		classhint; 
  XTextProperty		windowName;
  NSUserDefaults	*defs;
  const char *host_name = [[pInfo hostName] UTF8String];

  /*
   * Initialize time of last events to be the start of time - not
   * the current time!
   */
  if (CurrentTime == 0)
    {
      generic.lastClick = 1;
      generic.lastMotion = 1;
      generic.lastTime = 1;
    }

  /*
   * Set up standard atoms.
   */
  generic.protocols_atom = XInternAtom(dpy, "WM_PROTOCOLS", False);
  generic.take_focus_atom = XInternAtom(dpy, "WM_TAKE_FOCUS", False);
  generic.delete_win_atom = XInternAtom(dpy, "WM_DELETE_WINDOW", False);
  generic.miniaturize_atom
    = XInternAtom(dpy, "_GNUSTEP_WM_MINIATURIZE_WINDOW", False);
  generic.win_decor_atom = XInternAtom(dpy,"_GNUSTEP_WM_ATTR", False);
  generic.titlebar_state_atom
    = XInternAtom(dpy, "_GNUSTEP_TITLEBAR_STATE", False);

  [self _setupMouse];
  [self _checkWindowlist];

  /*
   * determine window manager in use.
   */
  generic.wm = [self _checkWindowManager];

  /*
   * Now check user defaults.
   */
  defs = [NSUserDefaults standardUserDefaults];

  if ([defs objectForKey: @"GSX11HandlesWindowDecorations"])
    handlesWindowDecorations = [defs boolForKey: @"GSX11HandlesWindowDecorations"];

  generic.flags.useWindowMakerIcons = NO;
  if ((generic.wm & XGWM_WINDOWMAKER) != 0)
    {
      generic.flags.useWindowMakerIcons = YES;
      if ([defs stringForKey: @"UseWindowMakerIcons"] != nil
	&& [defs boolForKey: @"UseWindowMakerIcons"] == NO)
	{
	  generic.flags.useWindowMakerIcons = NO;
	}
    }
  generic.flags.appOwnsMiniwindow = YES;
  if ([defs stringForKey: @"GSAppOwnsMiniwindow"] != nil
    && [defs boolForKey: @"GSAppOwnsMiniwindow"] == NO)
    {
      generic.flags.appOwnsMiniwindow = NO;
    }
  generic.flags.doubleParentWindow = NO;
  if ([defs stringForKey: @"GSDoubleParentWindows"] != nil
    && [defs boolForKey: @"GSDoubleParentWindows"] == YES)
    {
      generic.flags.doubleParentWindow = YES;
    }


  /*
   * make app root window
   */
  ROOT = XCreateSimpleWindow(dpy,RootWindow(dpy,defScreen),0,0,1,1,0,0,0);

  /*
   * set hints for root window
   */
  {
    XWMHints		gen_hints;

    gen_hints.flags = WindowGroupHint | StateHint;
    gen_hints.initial_state = WithdrawnState;
    gen_hints.window_group = ROOT;
    XSetWMHints(dpy, ROOT, &gen_hints);
  }

  /*
   * Mark this as a GNUstep app with the current application name.
   */
  if (rootName == 0)
    {
      const char	*str = [[pInfo processName] UTF8String];

      rootName = objc_malloc(strlen(str) + 1);
      strcpy(rootName, str);
    }
  classhint.res_name = rootName;
  classhint.res_class = "GNUstep";
  XSetClassHint(dpy, ROOT, &classhint);

  /*
   * Set app name as root window title - probably unused unless
   * the window manager wants to keep us in a menu or something like that.
   */
  XStringListToTextProperty((char**)&classhint.res_name, 1, &windowName);
  XSetWMName(dpy, ROOT, &windowName);
  XSetWMIconName(dpy, ROOT, &windowName);
  XFree(windowName.value);

  /*
   * Record the information used to start this app.
   * If we have a user default set up (eg. by the openapp script) use it.
   * otherwise use the process arguments.
   */
  args = [defs arrayForKey: @"GSLaunchCommand"];
  if (args == nil)
    {
      args = [pInfo arguments];
    }
  argc = [args count];
  argv = (char**)objc_malloc(argc*sizeof(char*));
  for (i = 0; i < argc; i++)
    {
      argv[i] = (char*)[[args objectAtIndex: i] UTF8String];
    }
  XSetCommand(dpy, ROOT, argv, argc);
  objc_free(argv);

  // Store the host name of the machine we a running on
  XStringListToTextProperty((char**)&host_name, 1, &windowName);
  XSetWMClientMachine(dpy, ROOT, &windowName);
  XFree(windowName.value);

  // Always send GNUstepWMAttributes
  {
    GNUstepWMAttributes	win_attrs;

    /*
     * Tell WindowMaker not to set up an app icon for us - we'll make our own.
     */
    win_attrs.flags = GSExtraFlagsAttr;
    win_attrs.extra_flags = GSNoApplicationIconFlag;
    XChangeProperty(dpy, ROOT,
	generic.win_decor_atom, generic.win_decor_atom,
	32, PropModeReplace, (unsigned char *)&win_attrs,
	sizeof(GNUstepWMAttributes)/sizeof(CARD32));
  }

  if ((generic.wm & XGWM_EWMH) != 0)
    {
      // Store the id of our process
      Atom pid_atom = XInternAtom(dpy, "_NET_WM_PID", False);
      int pid = [pInfo processIdentifier];

      XChangeProperty(dpy, ROOT,
		      pid_atom, XA_CARDINAL,
		      32, PropModeReplace, 
		      (unsigned char*)&pid, 1);

      // We should store the GNUStepMenuImage in the root window
      // and use that as our title bar icon
      //  pid_atom = XInternAtom(dpy, "_NET_WM_ICON", False);
    }
}

/* Destroys all the windows and other window resources that belong to
   this context */
- (void) _destroyServerWindows
{
  int num;
  gswindow_device_t *d;
  NSMapEnumerator   enumerator;
  NSMapTable        *mapcopy;

  /* Have to get a copy, since termwindow will remove them from
     the map table */
  mapcopy = NSCopyMapTableWithZone(windowtags, [self zone]);
  enumerator = NSEnumerateMapTable(mapcopy);
  while (NSNextMapEnumeratorPair(&enumerator, (void**)&num, (void**)&d) == YES)
    {
      if (d->display == dpy && d->ident != d->root)
	[self termwindow: num];
    }
  NSFreeMapTable(mapcopy);
}

/* Sets up a backing pixmap when a window is created or resized.  This is
   only done if the Window is buffered or retained. */
- (void) _createBuffer: (gswindow_device_t *)window
{
  if (window->type == NSBackingStoreNonretained
      || (window->gdriverProtocol & GDriverHandlesBacking))
    return;

  if (window->depth == 0)
    window->depth = DefaultDepth(dpy, window->screen);
  if (NSWidth(window->xframe) == 0 && NSHeight(window->xframe) == 0)
    {
      NSDebugLLog(@"NSWindow", @"Cannot create buffer for ZeroRect frame");
      return;
    }

  window->buffer = XCreatePixmap(dpy, window->root,
				 NSWidth(window->xframe),
				 NSHeight(window->xframe),
				 window->depth);

  if (!window->buffer)
    {
      NSLog(@"DPS Windows: Unable to create backing store\n");
      return;
    }

  XFillRectangle(dpy,
		 window->buffer,
		 window->gc,
		 0, 0, 
		 NSWidth(window->xframe),
		 NSHeight(window->xframe));
}

- (int) window: (NSRect)frame : (NSBackingStoreType)type : (unsigned int)style
	      : (int)screen
{
  static int		last_win_num = 0;
  gswindow_device_t	*window;
  gswindow_device_t	*root;
  XGCValues		values;
  unsigned long		valuemask;
  XClassHint		classhint;
  RContext              *context;

  NSDebugLLog(@"XGTrace", @"DPSwindow: %@ %d", NSStringFromRect(frame), type);
  root = [self _rootWindowForScreen: screen];
  context = [self xrContextForScreen: screen];

  /* Create the window structure and set the style early so we can use it to
  convert frames. */
  window = objc_malloc(sizeof(gswindow_device_t));
  memset(window, '\0', sizeof(gswindow_device_t));
  window->display = dpy;
  window->screen = screen;

  window->win_attrs.flags |= GSWindowStyleAttr;
  if (handlesWindowDecorations)
    window->win_attrs.window_style = style;
  else
    window->win_attrs.window_style = style & (NSIconWindowMask | NSMiniWindowMask);

  frame = [self _OSFrameToXFrame: frame for: window];

  /* We're not allowed to create a zero rect window */
  if (NSWidth(frame) <= 0 || NSHeight(frame) <= 0)
    {
      frame.size.width = 2;
      frame.size.height = 2;
    }
  window->xframe = frame;
  window->type = type;
  window->root = root->ident;
  window->parent = root->ident;
  window->depth = context->depth;
  window->xwn_attrs.border_pixel = context->black;
  window->xwn_attrs.background_pixel = context->white;
  window->xwn_attrs.colormap = context->cmap;

  window->ident = XCreateWindow(dpy, window->root,
				NSMinX(frame), NSMinY(frame), 
				NSWidth(frame), NSHeight(frame),
				0, 
				context->depth,
				CopyFromParent,
				context->visual,
				(CWColormap | CWBackPixel | CWBorderPixel),
				&window->xwn_attrs);

  /*
   * Mark this as a GNUstep app with the current application name.
   */
  classhint.res_name = rootName;
  classhint.res_class = "GNUstep";
  XSetClassHint(dpy, window->ident, &classhint);

  window->xwn_attrs.save_under = False;
  window->xwn_attrs.override_redirect = False;
  window->map_state = IsUnmapped;
  window->visibility = -1;

  // Create an X GC for the content view set it's colors
  values.foreground = window->xwn_attrs.background_pixel;
  values.background = window->xwn_attrs.background_pixel;
  values.function = GXcopy;
  valuemask = (GCForeground | GCBackground | GCFunction);
  window->gc = XCreateGC(dpy, window->ident, valuemask, &values);

  // Set the X event mask
  XSelectInput(dpy, window->ident, ExposureMask | KeyPressMask |
				KeyReleaseMask | ButtonPressMask |
			     ButtonReleaseMask | ButtonMotionMask |
			   StructureNotifyMask | PointerMotionMask |
			       EnterWindowMask | LeaveWindowMask |
			       FocusChangeMask | PropertyChangeMask |
			    ColormapChangeMask | KeymapStateMask |
			    VisibilityChangeMask);

  /*
   * Initial attributes for any GNUstep window tell Window Maker not to
   * create an app icon for us.
   */
  window->win_attrs.flags |= GSExtraFlagsAttr;
  window->win_attrs.extra_flags |= GSNoApplicationIconFlag;

  /*
   * Prepare size/position hints, but don't set them now - ordering
   * the window in should automatically do it.
   */
  frame = [self _XFrameToOSFrame: window->xframe for: window];
  frame = [self _OSFrameToXHints: frame for: window];
  window->siz_hints.x = NSMinX(frame);
  window->siz_hints.y = NSMinY(frame);
  window->siz_hints.width = NSWidth(frame);
  window->siz_hints.height = NSHeight(frame);
  window->siz_hints.flags = USPosition|PPosition|USSize|PSize;

  // Always send GNUstepWMAttributes
  XChangeProperty(dpy, window->ident, generic.win_decor_atom, 
		      generic.win_decor_atom, 32, PropModeReplace, 
		      (unsigned char *)&window->win_attrs,
		      sizeof(GNUstepWMAttributes)/sizeof(CARD32));

  // send to the WM window style hints
  if ((generic.wm & XGWM_WINDOWMAKER) == 0)
    {
      setWindowHintsForStyle (dpy, window->ident, style);
    }

  // Use the globally active input mode
  window->gen_hints.flags = InputHint;
  window->gen_hints.input = False;
  // All the windows of a GNUstep application belong to one group.
  window->gen_hints.flags |= WindowGroupHint;
  window->gen_hints.window_group = ROOT;

  /*
   * Prepare the protocols supported by the window.
   * These protocols should be set on the window when it is ordered in.
   */
  window->numProtocols = 0;
  window->protocols[window->numProtocols++] = generic.take_focus_atom;
  window->protocols[window->numProtocols++] = generic.delete_win_atom;
  if ((generic.wm & XGWM_WINDOWMAKER) != 0)
    {
      window->protocols[window->numProtocols++] = generic.miniaturize_atom;
    }
  // FIXME Add ping protocol for EWMH 
  XSetWMProtocols(dpy, window->ident, window->protocols, window->numProtocols);

  window->exposedRects = [NSMutableArray new];
  window->region = XCreateRegion();
  window->buffer = 0;
  window->alpha_buffer = 0;
  window->ic = 0;

  // make sure that new window has the correct cursor
  [self _initializeCursorForXWindow: window->ident];

  /*
   * FIXME - should this be protected by a lock for thread safety?
   * generate a unique tag for this new window.
   */
  do
    {
      last_win_num++;
    }
  while (last_win_num == 0 || WINDOW_WITH_TAG(last_win_num) != 0);
  window->number = last_win_num;

  // Insert window into the mapping
  NSMapInsert(windowmaps, (void*)window->ident, window);
  NSMapInsert(windowtags, (void*)window->number, window);
  [self _setWindowOwnedByServer: window->number];
  return window->number;
}

- (void) termwindow: (int)win
{
  gswindow_device_t *window;

  window = WINDOW_WITH_TAG(win);
  if (!window)
    return;

  if (window->root == window->ident)
    {
      NSLog(@"DPStermwindow: Trying to destroy root window");
      return;
    }

  NSDebugLLog(@"XGTrace", @"DPStermwindow: %d", win);
  if (window->ic)
    {
      [inputServer ximCloseIC: window->ic];
    }
  if (window->ident)
    {
      XDestroyWindow(dpy, window->ident);
      if (window->gc)
	XFreeGC (dpy, window->gc);
      NSMapRemove(windowmaps, (void*)window->ident);
    }

  if (window->buffer && (window->gdriverProtocol & GDriverHandlesBacking) == 0)
    XFreePixmap (dpy, window->buffer);
  if (window->alpha_buffer 
      && (window->gdriverProtocol & GDriverHandlesBacking) == 0)
    XFreePixmap (dpy, window->alpha_buffer);
  if (window->region)
    XDestroyRegion (window->region);
  RELEASE(window->exposedRects);
  NSMapRemove(windowtags, (void*)win);
  objc_free(window);
}

/*
 * Return the offsets between the window content-view and it's frame
 * depending on the window style.
 */
- (void) styleoffsets: (float *) l : (float *) r : (float *) t : (float *) b 
		     : (unsigned int) style
{
  if (!handlesWindowDecorations)
    {
      /*
      If we don't handle decorations, all our windows are going to be
      border- and decorationless. In that case, -gui won't call this method,
      but we still use it internally.
      */
      *l = *r = *t = *b = 0.0;
      return;
    }

  /* First try to get the offset information that we have obtained from
     the WM. This will only work if the application has already created
     a window that has been reparented by the WM. Otherwise we have to
     guess.
  */
  if (generic.parent_offset.x || generic.parent_offset.y)
    {
      if (style == NSBorderlessWindowMask
	  || (style & NSIconWindowMask) || (style & NSMiniWindowMask))
	{
	  *l = *r = *t = *b = 0.0;
	}
      else
	{
	  *l = *r = *t = *b = generic.parent_offset.x;
	  if (NSResizableWindowMask & style)
	    {
	      /* We just have to guess this. Usually it doesn't matter */
	      if ((generic.wm & XGWM_WINDOWMAKER) != 0)
		*b = 9;
	      else if ((generic.wm & XGWM_EWMH) != 0)
		*b = 7;
	    }
	  if ((style & NSTitledWindowMask) || (style & NSClosableWindowMask)
	      || (style & NSMiniaturizableWindowMask))
	    {
	      *t = generic.parent_offset.y;
	    }
	}
    }
  else if ((generic.wm & XGWM_WINDOWMAKER) != 0)
    {
      if (style == NSBorderlessWindowMask
	  || (style & NSIconWindowMask) || (style & NSMiniWindowMask))
	{
	  *l = *r = *t = *b = 0.0;
	}
      else
	{
	  *l = *r = *t = *b = 0;
	  if (NSResizableWindowMask & style)
	    {
	      *b = 9;
	    }
	  if ((style & NSTitledWindowMask) || (style & NSClosableWindowMask)
	      || (style & NSMiniaturizableWindowMask))
	    {
	      *t = 22;
	    }
	}
    }
  else if ((generic.wm & XGWM_EWMH) != 0)
    {
      if (style == NSBorderlessWindowMask
	  || (style & NSIconWindowMask) || (style & NSMiniWindowMask))
	{
	  *l = *r = *t = *b = 0.0;
	}
      else
	{
	  *l = *r = *t = *b = 4;
	  if (NSResizableWindowMask & style)
	    {
	      *b = 7;
	    }
	  if ((style & NSTitledWindowMask) || (style & NSClosableWindowMask)
	      || (style & NSMiniaturizableWindowMask))
	    {
	      *t = 20;
	    }
	}
    }
  else
    {
      /* No known WM protocols */
      /*
       * FIXME
       * This should make a good guess - at the moment use no offsets.
       */
      *l = *r = *t = *b = 0.0;
    }
}

- (void) stylewindow: (unsigned int)style : (int) win
{
  gswindow_device_t	*window;

  NSAssert(handlesWindowDecorations, @"-stylewindow:: called when handlesWindowDecorations==NO");

  window = WINDOW_WITH_TAG(win);
  if (!window)
    return;

  NSDebugLLog(@"XGTrace", @"DPSstylewindow: %d : %d", style, win);
  if (window->win_attrs.window_style != style
    || (window->win_attrs.flags & GSWindowStyleAttr) == 0)
    {
      NSRect h;
      window->win_attrs.flags |= GSWindowStyleAttr;
      window->win_attrs.window_style = style;

      /* Fix up hints */
      h = [self _XFrameToOSFrame: window->xframe for: window];
      h = [self _OSFrameToXHints: h for: window];
      window->siz_hints.x = NSMinX(h);
      window->siz_hints.y = NSMinY(h);
      window->siz_hints.width = NSWidth(h);
      window->siz_hints.height = NSHeight(h);

      // send to the WM window style hints
      XChangeProperty(dpy, window->ident, generic.win_decor_atom, 
			  generic.win_decor_atom, 32, PropModeReplace, 
			  (unsigned char *)&window->win_attrs,
			  sizeof(GNUstepWMAttributes)/sizeof(CARD32));
   
      // send to the WM window style hints
      if ((generic.wm & XGWM_WINDOWMAKER) == 0)
	{
	  setWindowHintsForStyle (dpy, window->ident, style);
	}
    }
}

- (void) setbackgroundcolor: (NSColor *)color : (int)win
{
  XColor xf;
  gswindow_device_t *window;

  window = WINDOW_WITH_TAG(win);
  if (!window)
    return;


  color = [color colorUsingColorSpaceName: NSDeviceRGBColorSpace];
  xf.red   = 65535 * [color redComponent];
  xf.green = 65535 * [color greenComponent];
  xf.blue  = 65535 * [color blueComponent];
  NSDebugLLog(@"XGTrace", @"setbackgroundcolor: %@ %d", color, win);
  xf = [self xColorFromColor: xf forScreen: window->screen];
  window->xwn_attrs.background_pixel = xf.pixel;
  XSetWindowBackground(dpy, window->ident, window->xwn_attrs.background_pixel);
}

- (void) windowbacking: (NSBackingStoreType)type : (int) win
{
  gswindow_device_t *window;

  window = WINDOW_WITH_TAG(win);
  if (!window)
    return;

  NSDebugLLog(@"XGTrace", @"DPSwindowbacking: %@ : %d", type, win);

  if ((window->gdriverProtocol & GDriverHandlesBacking))
    {
      window->type = type;
      return;
    }

  if (window->buffer && type == NSBackingStoreNonretained)
    {
      XFreePixmap (dpy, window->buffer);
      window->buffer = 0;
    }
  window->type = type;
  [self _createBuffer: window];
}

- (void) titlewindow: (NSString *)window_title : (int) win
{
  XTextProperty windowName;
  gswindow_device_t *window;

  window = WINDOW_WITH_TAG(win);
  if (!window)
    return;

  NSDebugLLog(@"XGTrace", @"DPStitlewindow: %@ : %d", window_title, win);
  if (window_title && window->ident)
    {
      const char *title = [window_title lossyCString];
      XStringListToTextProperty((char**)&title, 1, &windowName);
      XSetWMName(dpy, window->ident, &windowName);
      XSetWMIconName(dpy, window->ident, &windowName);
      XFree(windowName.value);
    }
}

- (void) docedited: (int)edited : (int) win
{
  gswindow_device_t *window;

  window = WINDOW_WITH_TAG(win);
  if (!window)
    return;

  NSDebugLLog(@"XGTrace", @"DPSdocedited: %d : %d", edited, win);
  window->win_attrs.flags |= GSExtraFlagsAttr;
  if (edited)
    {
      window->win_attrs.extra_flags |= GSDocumentEditedFlag;
    }
  else
    {
      window->win_attrs.extra_flags &= ~GSDocumentEditedFlag;
    }

  // send WindowMaker WM window style hints
  // Always send GNUstepWMAttributes
  XChangeProperty(dpy, window->ident,
	generic.win_decor_atom, generic.win_decor_atom,
	32, PropModeReplace, (unsigned char *)&window->win_attrs,
	sizeof(GNUstepWMAttributes)/sizeof(CARD32));
}

- (BOOL) appOwnsMiniwindow
{
  return generic.flags.appOwnsMiniwindow;
}

- (void) miniwindow: (int) win
{
  gswindow_device_t	*window;

  window = WINDOW_WITH_TAG(win);
  if (window == 0 || (window->win_attrs.window_style & NSIconWindowMask) != 0)
    {
      return;
    }
  NSDebugLLog(@"XGTrace", @"DPSminiwindow: %d ", win);
  /*
   * If we haven't already done so - set the icon window hint for this
   * window so that the GNUstep miniwindow is displayed (if supported).
   */
  if (generic.flags.appOwnsMiniwindow
      && (window->gen_hints.flags & IconWindowHint) == 0)
    {
      NSWindow		*nswin;

      nswin = GSWindowWithNumber(window->number);
      if (nswin != nil)
	{
	  int			iNum = [[nswin counterpart] windowNumber];
	  gswindow_device_t	*iconw = WINDOW_WITH_TAG(iNum);

	  if (iconw != 0)
	    {
	      window->gen_hints.flags |= IconWindowHint;
	      window->gen_hints.icon_window = iconw->ident;
	      XSetWMHints(dpy, window->ident, &window->gen_hints);
	    }
	}
    }
  XIconifyWindow(dpy, window->ident, window->screen);
}

/**
   Make sure we have the most up-to-date window information and then
   make sure the current context has our new information
*/
- (void) windowdevice: (int)win
{
  unsigned width, height;
  gswindow_device_t *window;
  NSGraphicsContext *ctxt;

  NSDebugLLog(@"XGTrace", @"DPSwindowdevice: %d ", win);
  window = WINDOW_WITH_TAG(win);
  if (!window)
    {
      NSLog(@"Invalidparam: Invalid window number %d", win);
      return;
    }

  if (!window->ident)
    return;

  width = NSWidth(window->xframe);
  height = NSHeight(window->xframe);

  if (window->buffer
      && (window->buffer_width != width || window->buffer_height != height)
      && (window->gdriverProtocol & GDriverHandlesBacking) == 0)
    {
      [isa waitAllContexts];
      XFreePixmap(dpy, window->buffer);
      window->buffer = 0;
      if (window->alpha_buffer)
	XFreePixmap (dpy, window->alpha_buffer);
      window->alpha_buffer = 0;
    }

  window->buffer_width = width;
  window->buffer_height = height;

  if (window->buffer == 0)
    {
      [self _createBuffer: window];
    }

  ctxt = GSCurrentContext();
  GSSetDevice(ctxt, window, 0, NSHeight(window->xframe));
  DPSinitmatrix(ctxt);
  DPSinitclip(ctxt);
}

/*
Build a Pixmap of our icon so the windowmaker dock will remember our
icon when we quit.

ICCCM really only allows 1-bit pixmaps for IconPixmapHint, but this code is
only used if windowmaker is the window manager, and windowmaker can handle
real color pixmaps.
*/
static Pixmap xIconPixmap;
static Pixmap xIconMask;
static BOOL didCreatePixmaps;

-(int) _createAppIconPixmaps
{
  NSImage *image;
  NSBitmapImageRep *rep;
  int i, j, w, h, samples, screen;
  unsigned char *data;
  XColor pixelColor;
  GC pixgc;
  RColor pixelRColor;
  RContext *rcontext;

  NSAssert(!didCreatePixmaps, @"called _createAppIconPixmap twice");
  
  didCreatePixmaps = YES;
  
  image = [NSApp applicationIconImage];
  rep = (NSBitmapImageRep *)[image bestRepresentationForDevice:nil];
  
  if (![rep isKindOfClass: [NSBitmapImageRep class]])
    return 0;

  if ([rep bitsPerSample] != 8
      || (![[rep colorSpaceName] isEqual: NSDeviceRGBColorSpace]
	  && ![[rep colorSpaceName] isEqual: NSCalibratedRGBColorSpace])
      || [rep isPlanar])
    return 0;
  
  data = [rep bitmapData];
  screen = [[[self screenList] objectAtIndex: 0] intValue];
  xIconPixmap = XCreatePixmap(dpy,
                      [self xDisplayRootWindowForScreen:screen],
                      [rep pixelsWide], [rep pixelsHigh],
                      DefaultDepth(dpy, screen));
  pixgc = XCreateGC(dpy, xIconPixmap, 0, NULL);

  h = [rep pixelsHigh];
  w = [rep pixelsWide];
  samples = [rep samplesPerPixel];
  rcontext = [self xrContextForScreen: screen];

  for (i = 0; i < h; i++)
    {
      unsigned char *d = data;
      for (j = 0; j < w; j++)
	{
	  pixelRColor.red = d[0];
	  pixelRColor.green = d[1];
	  pixelRColor.blue = d[2];

	  RGetClosestXColor(rcontext, &pixelRColor, &pixelColor);
	  XSetForeground(dpy, pixgc, pixelColor. pixel);
	  XDrawPoint(dpy, xIconPixmap, pixgc, j, i);
	  d += samples;
	}
      data += [rep bytesPerRow];
    }
  
  XFreeGC(dpy, pixgc);
 
  xIconMask = xgps_cursor_mask(dpy, ROOT, [rep bitmapData],
			       [rep pixelsWide],
			       [rep pixelsHigh],
			       [rep samplesPerPixel]);

  return 1;
}   

- (void) orderwindow: (int)op : (int)otherWin : (int)winNum
{
  gswindow_device_t	*window;
  gswindow_device_t	*other;
  int		level;

  window = WINDOW_WITH_TAG(winNum);
  if (winNum == 0 || window == NULL)
    {
      NSLog(@"Invalidparam: Ordering invalid window %d", winNum);
      return;
    }

  if (op != NSWindowOut)
    {
      /*
       * Some window managers ignore any hints and properties until the
       * window is actually mapped, so we need to set them all up
       * immediately before mapping the window ...
       */

      setNormalHints(dpy, window);
      XSetWMHints(dpy, window->ident, &window->gen_hints);

      /*
       * If we are asked to set hints for the appicon and Window Maker is
       * to control it, we must let Window maker know that this window is
       * the icon window for the app root window.
       */
      if ((window->win_attrs.window_style & NSIconWindowMask) != 0
	&& generic.flags.useWindowMakerIcons == 1)
	{
	  XWMHints gen_hints;

	  gen_hints.flags = WindowGroupHint | StateHint | IconWindowHint;
	  gen_hints.initial_state = WithdrawnState;
	  gen_hints.window_group = ROOT;
	  gen_hints.icon_window = window->ident;

	  if (!didCreatePixmaps)
	    {
	      [self _createAppIconPixmaps];
	    }  

	  if (xIconPixmap)
	    {
	      gen_hints.flags |= IconPixmapHint;
	      gen_hints.icon_pixmap = xIconPixmap;
	    }
	  if (xIconMask);
	    {
	      gen_hints.flags |= IconMaskHint;
	      gen_hints.icon_mask = xIconMask;
	    }

	  XSetWMHints(dpy, ROOT, &gen_hints);
	}

      /*
       * Tell the window manager what protocols this window conforms to.
       */
      XSetWMProtocols(dpy, window->ident, window->protocols,
	window->numProtocols);
    }

  if (generic.flags.useWindowMakerIcons == 1)
    {
      /*
       * Icon windows are mapped/unmapped by the window manager - so we
       * mustn't do anything with them here - though we can raise the
       * application root window to let Window Maker know it should use
       * our appicon window.
       */
      if ((window->win_attrs.window_style & NSIconWindowMask) != 0)
	{
#if 0
	  /* This doesn't appear to do anything useful, and, at least
	     with WindowMaker, can cause the app to flicker and spuriously
	     lose focus if the app icon is already visible.  */
	  if (op != NSWindowOut)
	    {
	      XMapRaised(dpy, ROOT);
	    }
#endif
	  return;
	}
      if ((window->win_attrs.window_style & NSMiniWindowMask) != 0)
	{
	  return;
	}
    }

  NSDebugLLog(@"XGTrace", @"DPSorderwindow: %d : %d : %d",op,otherWin,winNum);
  level = window->win_attrs.window_level;
  if (otherWin > 0)
    {
      other = WINDOW_WITH_TAG(otherWin);
      if (other)
	level = other->win_attrs.window_level;
    }
  else if (otherWin == 0 && op == NSWindowAbove)
    {
      /* Don't let the window go in front of the current key/main window.  */
      /* FIXME: Don't know how to get the current main window.  */
      Window keywin;
      int revert, status;
      status = XGetInputFocus(dpy, &keywin, &revert);
      other = NULL;
      if (status == True)
	{
	  /* Alloc a temporary window structure */
	  other = GSAutoreleasedBuffer(sizeof(gswindow_device_t));
	  other->ident = keywin;
	  op = NSWindowBelow;
	}
    }
  else
    {
      other = NULL;
    }
  [self setwindowlevel: level : winNum];

  /*
   * When we are ordering a window in, we must ensure that the position
   * and size hints are set for the window - the window could have been
   * moved or resized by the window manager before it was ordered out,
   * in which case, we will have been notified of the new position, but
   * will not yet have updated the window hints, so if the window manager
   * looks at the existing hints when re-mapping the window it will
   * place the window in an old location.
   * We also set other hints and protocols supported by the window.
   */
  if (op != NSWindowOut && window->map_state != IsViewable)
    {
      XMoveWindow(dpy, window->ident, window->siz_hints.x,
      	window->siz_hints.y);
      setNormalHints(dpy, window);
      /* Set this to ignore any take focus events for this window */
      generic.desiredOrderedWindow = winNum;
    }

  switch (op)
    {
      case NSWindowBelow:
        if (other != 0)
	  {
	    XWindowChanges chg;
	    chg.sibling = other->ident;
	    chg.stack_mode = Below;
	    XReconfigureWMWindow(dpy, window->ident, window->screen,
	      CWSibling|CWStackMode, &chg);
	  }
	else
	  {
	    XWindowChanges chg;
	    chg.stack_mode = Below;
	    XReconfigureWMWindow(dpy, window->ident, window->screen,
	      CWStackMode, &chg);
	  }
	XMapWindow(dpy, window->ident);
	break;

      case NSWindowAbove:
        if (other != 0)
	  {
	    XWindowChanges chg;
	    chg.sibling = other->ident;
	    chg.stack_mode = Above;
	    XReconfigureWMWindow(dpy, window->ident, window->screen,
	      CWSibling|CWStackMode, &chg);
	  }
	else
	  {
	    XWindowChanges chg;
	    chg.stack_mode = Above;
	    XReconfigureWMWindow(dpy, window->ident, window->screen,
	      CWStackMode, &chg);
	  }
	XMapWindow(dpy, window->ident);
	break;

      case NSWindowOut:
        XWithdrawWindow (dpy, window->ident, window->screen);
	break;
    }
  /*
   * When we are ordering a window in, we must ensure that the position
   * and size hints are set for the window - the window could have been
   * moved or resized by the window manager before it was ordered out,
   * in which case, we will have been notified of the new position, but
   * will not yet have updated the window hints, so if the window manager
   * looks at the existing hints when re-mapping the window it will
   * place the window in an old location.
   */
  if (op != NSWindowOut && window->map_state != IsViewable)
    {
      XMoveWindow(dpy, window->ident, window->siz_hints.x,
	window->siz_hints.y);
      setNormalHints(dpy, window);
      /*
       * Do we need to setup drag types when the window is mapped or will
       * they work on the set up before mapping?
       *
       * [self _resetDragTypesForWindow: GSWindowWithNumber(window->number)];
       */
    }
  XFlush(dpy);
}

#define ALPHA_THRESHOLD 158

/* Restrict the displayed part of the window to the given image.
   This only yields usefull results if the window is borderless and 
   displays the image itself */
- (void) restrictWindow: (int)win toImage: (NSImage*)image
{
  gswindow_device_t	*window;
  Pixmap pixmap = 0;

  window = WINDOW_WITH_TAG(win);
  if (win == 0 || window == NULL)
    {
      NSLog(@"Invalidparam: Restricting invalid window %d", win);
      return;
    }

  if ([[image backgroundColor] alphaComponent] * 256 <= ALPHA_THRESHOLD)
    {
      // The mask computed here is only correct for unscaled images.
      NSImageRep *rep = [image bestRepresentationForDevice: nil];

      if ([rep isKindOfClass: [NSBitmapImageRep class]])
        {
	    if (![(NSBitmapImageRep*)rep isPlanar] && 
		([(NSBitmapImageRep*)rep samplesPerPixel] == 4))
	      {
		pixmap = xgps_cursor_mask(dpy, GET_XDRAWABLE(window),
					  [(NSBitmapImageRep*)rep bitmapData], 
					  [rep pixelsWide], [rep pixelsHigh], 
					  [(NSBitmapImageRep*)rep samplesPerPixel]);
	      }
	}
    }

  XShapeCombineMask(dpy, window->ident, ShapeBounding, 0, 0,
		    pixmap, ShapeSet);

  if (pixmap)
    {
      XFreePixmap(dpy, pixmap);
    }
}

/* This method is a fast implementation of move that only works 
   correctly for borderless windows. Use with caution. */
- (void) movewindow: (NSPoint)loc : (int)win
{
  gswindow_device_t	*window;

  window = WINDOW_WITH_TAG(win);
  if (win == 0 || window == NULL)
    {
      NSLog(@"Invalidparam: Moving invalid window %d", win);
      return;
    }

  window->siz_hints.x = (int)loc.x;
  window->siz_hints.y = (int)(DisplayHeight(dpy, window->screen) - 
			      loc.y - window->siz_hints.height);
  XMoveWindow (dpy, window->ident, window->siz_hints.x, window->siz_hints.y);
  setNormalHints(dpy, window);
}

- (void) placewindow: (NSRect)rect : (int)win
{
  NSEvent *e;
  NSRect xVal;
  gswindow_device_t *window;
  NSWindow *nswin;
  NSRect frame;
  BOOL resize = NO;
  BOOL move = NO;

  window = WINDOW_WITH_TAG(win);
  if (win == 0 || window == NULL)
    {
      NSLog(@"Invalidparam: Placing invalid window %d", win);
      return;
    }

  NSDebugLLog(@"XGTrace", @"DPSplacewindow: %@ : %d", NSStringFromRect(rect), 
	      win);
  nswin  = GSWindowWithNumber(win);
  frame = [nswin frame];
  if (NSEqualRects(rect, frame) == YES)
    return;
  if (NSEqualSizes(rect.size, frame.size) == NO)
    {
      resize = YES;
      move = YES;
    }
  if (NSEqualPoints(rect.origin, frame.origin) == NO)
    {
      move = YES;
    }

  xVal = [self _OSFrameToXHints: rect for: window];
  window->siz_hints.width = (int)xVal.size.width;
  window->siz_hints.height = (int)xVal.size.height;
  window->siz_hints.x = (int)xVal.origin.x;
  window->siz_hints.y = (int)xVal.origin.y;
  xVal = [self _OSFrameToXFrame: rect for: window];

  NSDebugLLog(@"Moving", @"Place %d - o:%@, x:%@", window->number,
    NSStringFromRect(rect), NSStringFromRect(xVal));
  XMoveResizeWindow (dpy, window->ident,
    window->siz_hints.x, window->siz_hints.y,
    window->siz_hints.width, window->siz_hints.height);
  setNormalHints(dpy, window);

  /* Update xframe right away. We optimistically assume that we'll get the
  frame we asked for. If we're right, -gui can update/redraw right away,
  and we don't have to do anything when the ConfigureNotify arrives later.
  If we're wrong, the ConfigureNotify will have the exact coordinates, and
  at that point, we'll send new GSAppKitWindow* events to -gui. */
  window->xframe = xVal;

  if (resize == YES)
    {
      NSDebugLLog(@"Moving", @"Fake size %d - %@", window->number,
	NSStringFromSize(rect.size));
      e = [NSEvent otherEventWithType: NSAppKitDefined
			     location: rect.origin
			modifierFlags: 0
			    timestamp: 0
			 windowNumber: win
			      context: GSCurrentContext()
			      subtype: GSAppKitWindowResized
				data1: rect.size.width
				data2: rect.size.height];
      [nswin sendEvent: e];
    }
  else if (move == YES)
    {
      NSDebugLLog(@"Moving", @"Fake move %d - %@", window->number,
	NSStringFromPoint(rect.origin));
      e = [NSEvent otherEventWithType: NSAppKitDefined
			     location: NSZeroPoint
			modifierFlags: 0
			    timestamp: 0
			 windowNumber: win
			      context: GSCurrentContext()
			      subtype: GSAppKitWindowMoved
				data1: rect.origin.x
				data2: rect.origin.y];
      [nswin sendEvent: e];
    }
}

- (BOOL) findwindow: (NSPoint)loc : (int) op : (int) otherWin : (NSPoint *)floc 
: (int*) winFound
{
  return NO;
}

- (NSRect) windowbounds: (int)win
{
  gswindow_device_t *window;
  int screenHeight;
  NSRect rect;

  window = WINDOW_WITH_TAG(win);
  if (!window)
    return NSZeroRect;

  NSDebugLLog(@"XGTrace", @"DPScurrentwindowbounds: %d", win);
  screenHeight = DisplayHeight(dpy, window->screen);
  rect = window->xframe;
  rect.origin.y = screenHeight - NSMaxY(window->xframe);
  return rect;
}

- (void) setwindowlevel: (int)level : (int)win
{
  gswindow_device_t *window;

  window = WINDOW_WITH_TAG(win);
  if (!window)
    return;

  NSDebugLLog(@"XGTrace", @"DPSsetwindowlevel: %d : %d", level, win);
  if ((int)(window->win_attrs.window_level) != level
    || (window->win_attrs.flags & GSWindowLevelAttr) == 0)
    {
      window->win_attrs.flags |= GSWindowLevelAttr;
      window->win_attrs.window_level = level;

      // send WindowMaker WM window style hints
      // Always send GNUstepWMAttributes
      {
        XEvent	event;

        /*
	 * First change the window properties so that, if the window
	 * is not mapped, we have stored the required info for when
	 * the WM maps it.
	 */
        XChangeProperty(dpy, window->ident,
	    generic.win_decor_atom, generic.win_decor_atom,
	    32, PropModeReplace, (unsigned char *)&window->win_attrs,
	    sizeof(GNUstepWMAttributes)/sizeof(CARD32));
	/*
	 * Now send a message for rapid handling.
	 */
	event.xclient.type = ClientMessage;
	event.xclient.message_type = generic.win_decor_atom;
	event.xclient.format = 32;
	event.xclient.display = dpy;
	event.xclient.window = window->ident;
	event.xclient.data.l[0] = GSWindowLevelAttr;
	event.xclient.data.l[1] = window->win_attrs.window_level;
	event.xclient.data.l[2] = 0;
	event.xclient.data.l[3] = 0;
	XSendEvent(dpy, DefaultRootWindow(dpy), False,
	    SubstructureRedirectMask, &event);
      }

      if ((generic.wm & XGWM_EWMH) != 0)
	{
	  int len;
	  long data[2];

	  data[0] = generic.wintypes.win_normal_atom;
	  data[1] = None;
	  len = 1;

	  if (level == NSModalPanelWindowLevel)
	    {
	      data[0] = generic.wintypes.win_modal_atom;
	    }
	  else if (level == NSMainMenuWindowLevel)
	    {
	      // For strange reasons menu level does not work out for the main menu
	      //data[0] = generic.wintypes.win_topmenu_atom;
	      data[0] = generic.wintypes.win_dock_atom;
	      //len = 2;
	    }
	  else if (level == NSSubmenuWindowLevel ||
		   level == NSFloatingWindowLevel ||
		   level == NSTornOffMenuWindowLevel)
	    {
	      data[0] = generic.wintypes.win_override_atom;
	      //data[0] = generic.wintypes.win_utility_atom;
	      data[1] = generic.wintypes.win_menu_atom;
	      len = 2;
	    }
	  else if (level == NSDockWindowLevel ||
		   level == NSStatusWindowLevel)
	    {
	      data[0] =generic.wintypes.win_dock_atom;
	    }
	  // Does this belong into a different category?
	  else if (level == NSPopUpMenuWindowLevel)
	    {
	      data[0] = generic.wintypes.win_override_atom;
	      data[1] = generic.wintypes.win_floating_atom;
	      len = 2;
	    }
	  else if (level == NSDesktopWindowLevel)
	    {
	      data[0] = generic.wintypes.win_desktop_atom;
	    }

	  XChangeProperty(dpy, window->ident, generic.wintypes.win_type_atom,
			  XA_ATOM, 32, PropModeReplace, 
			  (unsigned char *)&data, len);
	}
      else if ((generic.wm & XGWM_GNOME) != 0)
	{
	  XEvent event;
	  int    flag = WIN_LAYER_NORMAL;

	  if (level == NSDesktopWindowLevel)
	    flag = WIN_LAYER_DESKTOP;
	  else if (level == NSSubmenuWindowLevel 
		   || level == NSFloatingWindowLevel 
		   || level == NSTornOffMenuWindowLevel)
	    flag = WIN_LAYER_ONTOP;
	  else if (level == NSMainMenuWindowLevel)
	    flag = WIN_LAYER_MENU;
	  else if (level == NSDockWindowLevel
		   || level == NSStatusWindowLevel)
	    flag = WIN_LAYER_DOCK;
	  else if (level == NSModalPanelWindowLevel
		   || level == NSPopUpMenuWindowLevel)
	    flag = WIN_LAYER_ONTOP;
	  else if (level == NSScreenSaverWindowLevel)
	    flag = WIN_LAYER_ABOVE_DOCK;

	  XChangeProperty(dpy, window->ident, generic.wintypes.win_type_atom,
			  XA_CARDINAL, 32, PropModeReplace, 
			  (unsigned char *)&flag, 1);

	  event.xclient.type = ClientMessage;
	  event.xclient.window = window->ident;
	  event.xclient.display = dpy;
	  event.xclient.message_type = generic.wintypes.win_type_atom;
	  event.xclient.format = 32;
	  event.xclient.data.l[0] = flag;
	  XSendEvent(dpy, window->root, False, 
		     SubstructureNotifyMask, &event);
	}
    }
}

- (int) windowlevel: (int)win
{
  gswindow_device_t *window;

  window = WINDOW_WITH_TAG(win);
  /*
   * If we have previously set a level for this window - return the value set.
   */
  if (window != 0 && (window->win_attrs.flags & GSWindowLevelAttr))
    return window->win_attrs.window_level;
  return 0;
}

- (NSArray *) windowlist
{
  return nil;
}

- (int) windowdepth: (int)win
{
  gswindow_device_t *window;

  window = WINDOW_WITH_TAG(win);
  if (!window)
    return 0;

  return window->depth;
}

- (void) setmaxsize: (NSSize)size : (int)win
{
  gswindow_device_t	*window;
  NSRect		r;

  window = WINDOW_WITH_TAG(win);
  if (window == 0)
    {
      return;
    }
  r = NSMakeRect(0, 0, size.width, size.height);
  r = [self _OSFrameToXFrame: r for: window];
  window->siz_hints.flags |= PMaxSize;
  window->siz_hints.max_width = r.size.width;
  window->siz_hints.max_height = r.size.height;
  setNormalHints(dpy, window);
}

- (void) setminsize: (NSSize)size : (int)win
{
  gswindow_device_t	*window;
  NSRect		r;

  window = WINDOW_WITH_TAG(win);
  if (window == 0)
    {
      return;
    }
  r = NSMakeRect(0, 0, size.width, size.height);
  r = [self _OSFrameToXFrame: r for: window];
  window->siz_hints.flags |= PMinSize;
  window->siz_hints.min_width = r.size.width;
  window->siz_hints.min_height = r.size.height;
  setNormalHints(dpy, window);
}

- (void) setresizeincrements: (NSSize)size : (int)win
{
  gswindow_device_t *window;

  window = WINDOW_WITH_TAG(win);
  if (window == 0)
    {
      return;
    }
  window->siz_hints.flags |= PResizeInc;
  window->siz_hints.width_inc = size.width;
  window->siz_hints.height_inc = size.height;
  setNormalHints(dpy, window);
}

// process expose event
- (void) _addExposedRectangle: (XRectangle)rectangle : (int)win
{
  gswindow_device_t *window;

  window = WINDOW_WITH_TAG(win);
  if (!window)
    return;

  if (window->type != NSBackingStoreNonretained)
    {
      XGCValues values;
      unsigned long valuemask;

      // window has a backing store so just copy the exposed rect from the
      // pixmap to the X window

      NSDebugLLog (@"NSWindow", @"copy exposed area ((%d, %d), (%d, %d))",
		  rectangle.x, rectangle.y, rectangle.width, rectangle.height);

      values.function = GXcopy;
      values.plane_mask = AllPlanes;
      values.clip_mask = None;
      values.foreground = window->xwn_attrs.background_pixel;
      valuemask = (GCFunction | GCPlaneMask | GCClipMask | GCForeground);
      XChangeGC(dpy, window->gc, valuemask, &values);
      [isa waitAllContexts];
      if ((window->gdriverProtocol & GDriverHandlesExpose))
	{
	  /* Temporary protocol until we standardize the backing buffer */
	  NSRect rect = NSMakeRect(rectangle.x, rectangle.y, 
				   rectangle.width, rectangle.height);
	  [[GSCurrentContext() class] handleExposeRect: rect
			     forDriver: window->gdriver];
	}
      else
	XCopyArea (dpy, window->buffer, window->ident, window->gc,
		   rectangle.x, rectangle.y, rectangle.width, rectangle.height,
		   rectangle.x, rectangle.y);
    }
  else
    {
      NSRect	rect;

      // no backing store, so keep a list of exposed rects to be
      // processed in the _processExposedRectangles method
      // Add the rectangle to the region used in -_processExposedRectangles
      // to set the clipping path.
      XUnionRectWithRegion (&rectangle, window->region, window->region);

      // Transform the rectangle's coordinates to PS coordinates and add
      // this new rectangle to the list of exposed rectangles.
      {
 	rect = [self _XWinFrameToOSWinFrame: 
		       NSMakeRect(rectangle.x, rectangle.y,
				  rectangle.width, rectangle.height)
 		                        for: window];
	[window->exposedRects addObject: [NSValue valueWithRect: rect]];
      }
    }
}

- (void) flushwindowrect: (NSRect)rect : (int)win
{
  int xi, yi, width, height;
  XGCValues values;
  unsigned long valuemask;
  gswindow_device_t *window;

  window = WINDOW_WITH_TAG(win);
  if (win == 0 || window == NULL)
    {
      NSLog(@"Invalidparam: Placing invalid window %d", win);
      return;
    }

  NSDebugLLog(@"XGTrace", @"DPSflushwindowrect: %@ : %d", 
	      NSStringFromRect(rect), win);
  if (window->type == NSBackingStoreNonretained)
    {
      XFlush(dpy);
      return;
    }

  /* FIXME: Doesn't take into account any offset added to the window
     (from PSsetgcdrawable) or possible scaling (unlikely in X-windows,
     but what about other devices?) */
  rect.origin.y = NSHeight(window->xframe) - NSMaxY(rect);

  values.function = GXcopy;
  values.plane_mask = AllPlanes;
  values.clip_mask = None;
  valuemask = (GCFunction | GCPlaneMask | GCClipMask);
  XChangeGC(dpy, window->gc, valuemask, &values);

  xi = NSMinX(rect);		// width/height seems
  yi = NSMinY(rect);		// to require +1 pixel
  width = NSWidth(rect) + 1;	// to copy out
  height = NSHeight(rect) + 1;

  NSDebugLLog (@"NSWindow", 
	       @"copy X rect ((%d, %d), (%d, %d))", xi, yi, width, height);

  if (width > 0 || height > 0)
    {
      [isa waitAllContexts];
      if ((window->gdriverProtocol & GDriverHandlesBacking))
	{
	  /* Temporary protocol until we standardize the backing buffer */
	  [[GSCurrentContext() class] handleExposeRect: rect
			     forDriver: window->gdriver];
	}
	else
	  XCopyArea (dpy, window->buffer, window->ident, window->gc, 
		     xi, yi, width, height, xi, yi);
    }

  XFlush(dpy);
}

// handle X expose events
- (void) _processExposedRectangles: (int)win
{
  int n;
  gswindow_device_t *window;
  NSWindow *gui_win;

  window = WINDOW_WITH_TAG(win);
  if (!window)
    return;

  if (window->type != NSBackingStoreNonretained)
    return;

  // Set the clipping path to the exposed rectangles
  // so that further drawing will not affect the non-exposed region
  XSetRegion (dpy, window->gc, window->region);

  // We should determine the views that need to be redisplayed. Until we
  // fully support scalation and rotation of views redisplay everything.
  // FIXME: It seems wierd to trigger a front-end method from here...

  // We simply invalidate the 
  // corresponding rectangle of the contentview.

  gui_win = GSWindowWithNumber(win);

  n = [window->exposedRects count];
  if( n > 0 )
    {
      NSView *v;
      NSValue *val[n];
      int i;

      v = [gui_win contentView];
	
      [window->exposedRects getObjects: val];
      for( i = 0; i < n; ++i)
	{
	  NSRect rect = [val[i] rectValue];
	  [v setNeedsDisplayInRect: rect];
	}
    }
	    
  // Restore the exposed rectangles and the region
  [window->exposedRects removeAllObjects];
  XDestroyRegion (window->region);
  window->region = XCreateRegion();
  XSetClipMask (dpy, window->gc, None);
}

- (BOOL) capturemouse: (int)win
{
  int ret;
  gswindow_device_t *window;

  window = WINDOW_WITH_TAG(win);
  if (!window)
    return NO;

  ret = XGrabPointer(dpy, window->ident, False,
		     PointerMotionMask | ButtonReleaseMask | ButtonPressMask,
		     GrabModeAsync, GrabModeAsync, None, None, CurrentTime);

  if (ret != GrabSuccess)
    NSDebugLLog(@"XGTrace", @"Failed to grab pointer %d\n", win);
  else
    {
      grab_window = window;
      NSDebugLLog(@"XGTrace", @"Grabbed pointer %d\n", win);
    }
  return (ret == GrabSuccess) ? YES : NO;
}

- (void) releasemouse
{
  NSDebugLLog(@"XGTrace", @"Released pointer\n");
  XUngrabPointer(dpy, CurrentTime);
  grab_window = NULL;
}

- (void) setinputfocus: (int)win
{
  gswindow_device_t *window = WINDOW_WITH_TAG(win);

  if (win == 0 || window == 0)
    {
      NSDebugLLog(@"Focus", @"Setting focus to unknown win %d", win);
      return;
    }

  NSDebugLLog(@"XGTrace", @"DPSsetinputfocus: %d", win);
  /*
   * If we have an outstanding request to set focus to this window,
   * we don't want to do it again.
   */
  if (win == generic.desiredFocusWindow && generic.focusRequestNumber != 0)
    {
      NSDebugLLog(@"Focus", @"Focus already set on %d", window->number);
      return;
    }
  
  NSDebugLLog(@"Focus", @"Setting focus to %d", window->number);
  generic.desiredFocusWindow = win;
  generic.focusRequestNumber = XNextRequest(dpy);
  generic.desiredOrderedWindow = 0;
  XSetInputFocus(dpy, window->ident, RevertToParent, generic.lastTime);
  [inputServer ximFocusICWindow: window];
}

/*
 * Instruct window manager that the specified window is 'key', 'main', or
 * just a normal window.
 */
- (void) setinputstate: (int)st : (int)win
{
  if (!handlesWindowDecorations)
    return;

  NSDebugLLog(@"XGTrace", @"DPSsetinputstate: %d : %d", st, win);
  if ((generic.wm & XGWM_WINDOWMAKER) != 0)
    {
      gswindow_device_t *window = WINDOW_WITH_TAG(win);
      XEvent		event;

      if (win == 0 || window == 0)
	{
	  return;
	}

      event.xclient.type = ClientMessage;
      event.xclient.message_type = generic.titlebar_state_atom;
      event.xclient.format = 32;
      event.xclient.display = dpy;
      event.xclient.window = window->ident;
      event.xclient.data.l[0] = st;
      event.xclient.data.l[1] = 0;
      event.xclient.data.l[2] = 0;
      event.xclient.data.l[3] = 0;
      XSendEvent(dpy, DefaultRootWindow(dpy), False,
		 SubstructureRedirectMask, &event);
    }
}

- (void *) serverDevice
{
  return dpy;
}

- (void *) windowDevice: (int)win
{
  static Window ptrloc;
  gswindow_device_t *window;

  window = WINDOW_WITH_TAG(win);
  if (window != NULL)
    ptrloc = window->ident;
  else
    ptrloc = 0;
  return &ptrloc;
}

/* Cursor Ops */
typedef struct _xgps_cursor_id_t {
  Cursor c;
} xgps_cursor_id_t;

static char xgps_blank_cursor_bits [] = {
0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00};

static Cursor xgps_blank_cursor = None;
static BOOL   cursor_hidden = NO;

- (Cursor) _blankCursor
{
  if (xgps_blank_cursor == None)
    {
      Pixmap shape, mask;
      XColor black, white;
      Drawable drw = [self xDisplayRootWindowForScreen: defScreen];
      
      shape = XCreatePixmapFromBitmapData(dpy, drw,
					  xgps_blank_cursor_bits, 
					  16, 16, 1, 0, 1);
      mask = XCreatePixmapFromBitmapData(dpy, drw,
					 xgps_blank_cursor_bits, 
					 16, 16, 1, 0, 1);
      black.red = black.green = black.blue = 0;
      black = [self xColorFromColor: black forScreen: defScreen];
      white.red = white.green = white.blue = 65535;
      white = [self xColorFromColor: white forScreen: defScreen];
      
      xgps_blank_cursor = XCreatePixmapCursor(dpy, shape, mask, 
					      &white, &black,  0, 0);
      XFreePixmap(dpy, shape);
      XFreePixmap(dpy, mask);
    }
  return xgps_blank_cursor;
}

/*
  set the cursor for a newly created window.
*/

- (void) _initializeCursorForXWindow: (Window) win
{
  if (cursor_hidden)
    {
      XDefineCursor (dpy, win, [self _blankCursor]);
    }
  else
    {
      xgps_cursor_id_t *cid = [[NSCursor currentCursor] _cid];
      
      XDefineCursor (dpy, win, cid->c);
    }
}


/*
  set cursor on all XWindows we own.  if `set' is NO
  the cursor is unset on all windows.
  Normally the cursor `c' correspond to the [NSCursor currentCursor]
  The only exception should be when the cursor is hidden.
  In that case `c' will be a blank cursor.
*/

- (void) _DPSsetcursor: (Cursor)c : (BOOL)set
{
  Window win;
  NSMapEnumerator enumerator;
  gswindow_device_t  *d;

  NSDebugLLog (@"NSCursor", @"_DPSsetcursor: cursor = %p, set = %d", c, set);
  
  enumerator = NSEnumerateMapTable (windowmaps);
  while (NSNextMapEnumeratorPair (&enumerator, (void**)&win, (void**)&d) == YES)
    {
      if (set)
        XDefineCursor(dpy, win, c);
      else
        XUndefineCursor(dpy, win); 
    }
}

#define ALPHA_THRESHOLD 158

Pixmap
xgps_cursor_mask(Display *xdpy, Drawable draw, const char *data, 
		  int w, int h, int colors)
{
  int j, i;
  unsigned char	ialpha;
  Pixmap pix;
  int bitmapSize = ((w + 7) >> 3) * h; // (w/8) rounded up times height
  char *aData = calloc(1, bitmapSize);
  char *cData = aData;

  if (colors == 4)
    {
      int k;
      for (j = 0; j < h; j++)
	{
	  k = 0;
	  for (i = 0; i < w; i++, k++)
	    {
	      if (k > 7)
		{
	      	  cData++;
	      	  k = 0;
	      	}
	      data += 3;
	      ialpha = (unsigned short)((char)*data++);
	      if (ialpha > ALPHA_THRESHOLD)
		{
		  *cData |= (0x01 << k);
		}
	    }
	  cData++;
	}
    }
  else
    {
      for (j = 0; j < bitmapSize; j++)
	{
	  *cData++ = 0xff;
	}
    }

  pix = XCreatePixmapFromBitmapData(xdpy, draw, (char *)aData, w, h, 
				    1L, 0L, 1);
  free(aData);
  return pix;
}

Pixmap
xgps_cursor_image(Display *xdpy, Drawable draw, const unsigned char *data, 
		  int w, int h, int colors, XColor *fg, XColor *bg)
{
  int j, i, min, max;
  Pixmap pix;
  int bitmapSize = ((w + 7) >> 3) * h; // w/8 rounded up multiplied by h
  char *aData = calloc(1, bitmapSize);
  char *cData = aData;

  min = 1 << 16;
  max = 0;
  if (colors == 4 || colors == 3)
    {
      int k;
      for (j = 0; j < h; j++)
	{
	  k = 0;
	  for (i = 0; i < w; i++, k++)
	    {
	      /* colors is in the range 0..65535 
		 and value is the percieved brightness, obtained by
		 averaging 0.3 red + 0.59 green + 0.11 blue 
	      */
	      int color = ((77 * data[0]) + (151 * data[1]) + (28 * data[2]));

	      if (k > 7)
		{
		  cData++;
		  k = 0;
		}
	      if (color > (1 << 15))
		{
		  *cData |= (0x01 << k);
		}
	      if (color < min)
		{
		  min = color;
		  bg->red = (int)data[0] * 256; 
		  bg->green = (int)data[1] * 256; 
		  bg->blue = (int)data[2] * 256;
		}
	      else if (color > max)
		{
		  max = color;
		  fg->red = (int)data[0] * 256; 
		  fg->green = (int)data[1] * 256; 
		  fg->blue = (int)data[2] * 256;
		}
	      data += 3;
	      if (colors == 4)
		{
		  data++;
		}
	    }
	  cData++;
	}
    }
  else
    {
      for (j = 0; j < bitmapSize; j++)
	{
	  if ((unsigned short)((char)*data++) > 128)
	    {
	      *cData |= (0x01 << j);
	    }
	  cData++;
	}
    }
  
  pix = XCreatePixmapFromBitmapData(xdpy, draw, (char *)aData, w, h, 
				    1L, 0L, 1);
  free(aData);
  return pix;
}

- (void) hidecursor
{
  if (cursor_hidden)
    return;

  [self _DPSsetcursor: [self _blankCursor] : YES];
  cursor_hidden = YES;
}

- (void) showcursor
{
  if (cursor_hidden)
    {
      /* This just resets the cursor to the parent window's cursor.
	 I'm not even sure it's needed */
      [self _DPSsetcursor: None : NO];
      /* Reset the current cursor */
      [[NSCursor currentCursor] set];
    }
  cursor_hidden = NO;
}

- (void) standardcursor: (int)style : (void **)cid
{
  xgps_cursor_id_t *cursor;
  cursor = NSZoneMalloc([self zone], sizeof(xgps_cursor_id_t));
  switch (style)
    {
    case GSArrowCursor:
      cursor->c = XCreateFontCursor(dpy, XC_left_ptr);     
      break;
    case GSIBeamCursor:
      cursor->c = XCreateFontCursor(dpy, XC_xterm);
      break;
    case GSCrosshairCursor:
      cursor->c = XCreateFontCursor(dpy, XC_crosshair);
      break;
    case GSDisappearingItemCursor:
      cursor->c = XCreateFontCursor(dpy, XC_shuttle);
      break;
    case GSPointingHandCursor:
      cursor->c = XCreateFontCursor(dpy, XC_hand1);
      break;
    case GSResizeDownCursor:
      cursor->c = XCreateFontCursor(dpy, XC_bottom_side);
      break;
    case GSResizeLeftCursor:
      cursor->c = XCreateFontCursor(dpy, XC_left_side);
      break;
    case GSResizeLeftRightCursor:
      cursor->c = XCreateFontCursor(dpy, XC_sb_h_double_arrow);
      break;
    case GSResizeRightCursor:
      cursor->c = XCreateFontCursor(dpy, XC_right_side);
      break;
    case GSResizeUpCursor:
      cursor->c = XCreateFontCursor(dpy, XC_top_side);
      break;
    case GSResizeUpDownCursor:
      cursor->c = XCreateFontCursor(dpy, XC_sb_v_double_arrow);
      break;
    default:
      cursor->c = XCreateFontCursor(dpy, XC_left_ptr);     
      break;
    }
  if (cid)
    *cid = (void *)cursor;
}

- (void) imagecursor: (NSPoint)hotp : (int) w :  (int) h : (int)colors : (const char *)image : (void **)cid
{
  xgps_cursor_id_t *cursor;
  Pixmap source, mask;
  unsigned int maxw, maxh;
  XColor fg, bg;

  /* FIXME: We might create a blank cursor here? */
  if (image == NULL || w <= 0 || h <= 0)
    {
      *cid = NULL;
      return;
    }

  /* FIXME: Handle this better or return an error? */
  XQueryBestCursor(dpy, ROOT, w, h, &maxw, &maxh);
  if ((unsigned int)w > maxw)
    w = maxw;
  if ((unsigned int)h > maxh)
    h = maxh;

  cursor = NSZoneMalloc([self zone], sizeof(xgps_cursor_id_t));
  source = xgps_cursor_image(dpy, ROOT, image, w, h, colors, &fg, &bg);
  mask = xgps_cursor_mask(dpy, ROOT, image, w, h, colors);
  bg = [self xColorFromColor: bg forScreen: defScreen];
  fg = [self xColorFromColor: fg forScreen: defScreen];

  cursor->c = XCreatePixmapCursor(dpy, source, mask, &fg, &bg, 
				  (int)hotp.x, (int)(h - hotp.y));
  XFreePixmap(dpy, source);
  XFreePixmap(dpy, mask);
  if (cid)
    *cid = (void *)cursor;
}

- (void) setcursorcolor: (NSColor *)fg : (NSColor *)bg : (void*) cid
{
  XColor xf, xb;
  xgps_cursor_id_t *cursor;

  cursor = (xgps_cursor_id_t *)cid;
  if (cursor == NULL)
    NSLog(@"Invalidparam: Invalid cursor");

  [self _DPSsetcursor: cursor->c : YES];
  /* Special hack: Don't set the color when fg == nil. Used by NSCursor
     to just set the cursor but not the color. */
  if (fg == nil)
    {
      return;
    }

  fg = [fg colorUsingColorSpaceName: NSDeviceRGBColorSpace];
  bg = [bg colorUsingColorSpaceName: NSDeviceRGBColorSpace];
  xf.red   = 65535 * [fg redComponent];
  xf.green = 65535 * [fg greenComponent];
  xf.blue  = 65535 * [fg blueComponent];
  xb.red   = 65535 * [bg redComponent];
  xb.green = 65535 * [bg greenComponent];
  xb.blue  = 65535 * [bg blueComponent];
  xf = [self xColorFromColor: xf forScreen: defScreen];
  xb = [self xColorFromColor: xb forScreen: defScreen];

  XRecolorCursor(dpy, cursor->c, &xf, &xb);
}

static NSWindowDepth
_computeDepth(int class, int bpp)
{
  int		spp = 0;
  int		bitValue = 0;
  int		bps = 0;
  NSWindowDepth	depth = 0;

  switch (class)
    {
      case GrayScale:
      case StaticGray:
	bitValue = _GSGrayBitValue;
	spp = 1;
	break;
      case PseudoColor:
      case StaticColor:
	bitValue = _GSCustomBitValue;
	spp = 1;
	break;
      case DirectColor:
      case TrueColor:
	bitValue = _GSRGBBitValue;
	spp = 3;
	break;
      default:
	break;
    }

  bps = (bpp/spp);
  depth = (bitValue | bps);

  return depth;
}

- (NSArray *)screenList
{
  /* I guess screen numbers are in order starting from zero, but we
     put the main screen first */
 int i;
 int count = ScreenCount(dpy);
 NSMutableArray *screens = [NSMutableArray arrayWithCapacity: count];
 if (count > 0)
   [screens addObject: [NSNumber numberWithInt: defScreen]];
 for (i = 0; i < count; i++)
   {
     if (i != defScreen)
       [screens addObject: [NSNumber numberWithInt: i]];
   }
 return screens;
}

- (NSWindowDepth) windowDepthForScreen: (int) screen_num
{ 
  Screen	*screen;
  int		 class = 0, bpp = 0;

  screen = XScreenOfDisplay(dpy, screen_num);
  if (screen == NULL)
    {
      return 0;
    }

  bpp = screen->root_depth;
  class = screen->root_visual->class;

  return _computeDepth(class, bpp);
}

- (const NSWindowDepth *) availableDepthsForScreen: (int) screen_num
{  
  Screen	*screen;
  int		 class = 0;
  int		 index = 0;
  int		 ndepths = 0;
  NSZone	*defaultZone = NSDefaultMallocZone();
  NSWindowDepth	*depths = 0;

  if (dpy == NULL)
    {
      return NULL;
    }

  screen = XScreenOfDisplay(dpy, screen_num);
  if (screen == NULL)
    {
      return NULL;
    }

  // Allocate the memory for the array and fill it in.
  ndepths = screen->ndepths;
  class = screen->root_visual->class;
  depths = NSZoneMalloc(defaultZone, sizeof(NSWindowDepth)*(ndepths + 1));
  for (index = 0; index < ndepths; index++)
    {
      int depth = screen->depths[index].depth;
      depths[index] = _computeDepth(class, depth);
    }
  depths[index] = 0; // terminate with a zero.

  return depths;
}

- (NSSize) resolutionForScreen: (int)screen_num
{ 
  int res_x, res_y;

  if (screen_num < 0 || screen_num >= ScreenCount(dpy))
    {
      NSLog(@"Invalidparam: no screen %d", screen_num);
      return NSMakeSize(0,0);
    }
  // This does not take virtual displays into account!! 
  res_x = DisplayWidth(dpy, screen_num) / 
      (DisplayWidthMM(dpy, screen_num) / 25.4);
  res_y = DisplayHeight(dpy, screen_num) / 
      (DisplayHeightMM(dpy, screen_num) / 25.4);
	
  return NSMakeSize(res_x, res_y);
}

- (NSRect) boundsForScreen: (int)screen
{
 if (screen < 0 || screen >= ScreenCount(dpy))
   {
     NSLog(@"Invalidparam: no screen %d", screen);
     return NSZeroRect;
   }
 return NSMakeRect(0, 0, DisplayWidth(dpy, screen), 
		   DisplayHeight(dpy, screen));
}

- (NSImage *) iconTileImage
{
  Atom noticeboard_atom;
  Atom icon_tile_atom;
  Atom rgba_image_atom;
  Window win;
  int count;
  unsigned char *tile;
  NSImage *iconTileImage;
  NSBitmapImageRep *imageRep;
  unsigned int width, height;

  if (((generic.wm & XGWM_WINDOWMAKER) == 0)
      || generic.flags.useWindowMakerIcons == NO)
    return [super iconTileImage];

  noticeboard_atom = XInternAtom(dpy,"_WINDOWMAKER_NOTICEBOARD", False);
  icon_tile_atom = XInternAtom(dpy,"_WINDOWMAKER_ICON_TILE", False);
  rgba_image_atom = XInternAtom(dpy,"_RGBA_IMAGE", False);
  
  win = DefaultRootWindow(dpy);
  win = *(Window *)PropGetCheckProperty(dpy, win, noticeboard_atom, XA_WINDOW,
					32, -1, &count);
  if (win == (Window)NULL) 
    return [super iconTileImage];
  
  tile = PropGetCheckProperty(dpy, win, icon_tile_atom, rgba_image_atom,
			      8, -1, &count);
  if (tile == NULL || count < 4)
    return [super iconTileImage];
  
  width = (tile[0] << 8) + tile[1];
  height = (tile[2] << 8) + tile[3];
  
  if (count > 4 + width * height * 4)
    return [super iconTileImage];
  
  iconTileImage = [[NSImage alloc] init];
  imageRep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes: NULL
                                                     pixelsWide: width 
                                                     pixelsHigh: height 
                                                  bitsPerSample: 8
                                                samplesPerPixel: 4
                                                       hasAlpha: YES
                                                       isPlanar: NO
                                                 colorSpaceName: NSDeviceRGBColorSpace
                                                    bytesPerRow: width * 4
                                                   bitsPerPixel: 32];
  memcpy([imageRep bitmapData], &tile[4], width * height * 4);
  XFree(tile);
  [iconTileImage addRepresentation:imageRep];
  RELEASE(imageRep);

  return AUTORELEASE(iconTileImage);
}

- (NSSize) iconSize
{
  XIconSize *xiconsize;
  int count_return;
  int status;
  
  status = XGetIconSizes(dpy,
                         DefaultRootWindow(dpy),
			 &xiconsize,
			 &count_return);
  if (status)
    {
      if ((generic.wm & XGWM_WINDOWMAKER) != 0) 
        {
	  /* must add 4 pixels for the border which windowmaker leaves out
	     but gnustep draws over. */
          return NSMakeSize(xiconsize[0].max_width + 4,
			    xiconsize[0].max_height + 4);
	}
    }
  return [super iconSize];
}

@end

