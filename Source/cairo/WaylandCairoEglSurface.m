/* WaylandCairoEglSurface

   WaylandCairoEglSurface - A cairo surface backed by an EGL surface.
   The egl surface allows the transfer to a wayland compositor gpu to gpu
   using linux dmabuf.
   The class currently uses two cairo surfaces: one for in memory drawing
   not visible on the screen and one for in screen rendering linked to
   a window.
   When the surface needs to appear on screen the in memory surface is
   blitted into the egl surface.
   The egl window surface is double buffered (based on GLES2 docs).

   Copyright (C) 2021 Free Software Foundation, Inc.

   Author: Riccardo Canalicchio <riccardo.canalicchio(at)gmail.com>
   Date: December 2021

   This file is part of the GNU Objective C Backend Library.

   This library is free software; you can redistribute it and/or
   modify it under the terms of the GNU Lesser General Public
   License as published by the Free Software Foundation; either
   version 2 of the License, or (at your option) any later version.

   This library is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
   Lesser General Public License for more details.

   You should have received a copy of the GNU Lesser General Public
   License along with this library; see the file COPYING.LIB.
   If not, see <http://www.gnu.org/licenses/> or write to the
   Free Software Foundation, 51 Franklin Street, Fifth Floor,
   Boston, MA 02110-1301, USA.
*/

#define _GNU_SOURCE

#include "wayland/WaylandServer.h"

#include "cairo/WaylandCairoEglSurface.h"
#include <wayland-egl.h>
#include <cairo/cairo-gl.h>
#include <cairo/cairo.h>

#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <EGL/egl.h>
#include <EGL/eglplatform.h>
#include <GLES2/gl2.h>
#include "cairo/CairoGState.h"
#include "cairo/CairoContext.h"

#define GL_BIT EGL_OPENGL_ES2_BIT

struct ESContext
{
  /// Native System informations
  EGLNativeDisplayType native_display;
  EGLNativeWindowType  native_window;
  uint16_t	       window_width, window_height;
  EGLDisplay	       display;
  EGLContext	       context;
  EGLSurface	       surface;
  EGLConfig	       config;
};

// helper function to debug configs available in a system
void
printContextConfigs(struct ESContext *escontext, EGLConfig *configs,
		    int numConfigs)
{
  for (int i = 0; i < numConfigs; i++)
    {
      EGLBoolean result;
      EGLint	 value;
      EGLConfig	 config = configs[i];
      NSDebugLog(@"----------------------------");
      eglGetConfigAttrib(escontext->display, config, EGL_CONFIG_ID, &value);
      NSDebugLog(@"EGL_CONFIG_ID %d", value);
      eglGetConfigAttrib(escontext->display, config, EGL_SURFACE_TYPE, &value);
      NSDebugLog(@"EGL_WINDOW_BIT %d",
		 (value & EGL_WINDOW_BIT) == EGL_WINDOW_BIT);
      NSDebugLog(@"EGL_SWAP_BEHAVIOR_PRESERVED_BIT %d",
		 (value & EGL_SWAP_BEHAVIOR_PRESERVED_BIT)
		   == EGL_SWAP_BEHAVIOR_PRESERVED_BIT);
      eglGetConfigAttrib(escontext->display, config, EGL_BUFFER_SIZE, &value);
      NSDebugLog(@"EGL_BUFFER_SIZE %d", value);
      eglGetConfigAttrib(escontext->display, config, EGL_RED_SIZE, &value);
      NSDebugLog(@"EGL_RED_SIZE %d", value);
      eglGetConfigAttrib(escontext->display, config, EGL_GREEN_SIZE, &value);
      NSDebugLog(@"EGL_GREEN_SIZE %d", value);
      eglGetConfigAttrib(escontext->display, config, EGL_BLUE_SIZE, &value);
      NSDebugLog(@"EGL_BLUE_SIZE %d", value);
      eglGetConfigAttrib(escontext->display, config, EGL_ALPHA_SIZE, &value);
      NSDebugLog(@"EGL_ALPHA_SIZE %d", value);
      eglGetConfigAttrib(escontext->display, config, EGL_DEPTH_SIZE, &value);
      NSDebugLog(@"EGL_DEPTH_SIZE %d", value);
      eglGetConfigAttrib(escontext->display, config, EGL_STENCIL_SIZE, &value);
      NSDebugLog(@"EGL_STENCIL_SIZE %d", value);
      eglGetConfigAttrib(escontext->display, config, EGL_SAMPLE_BUFFERS,
			 &value);
      NSDebugLog(@"EGL_SAMPLE_BUFFERS %d", value);
      eglGetConfigAttrib(escontext->display, config, EGL_SAMPLES, &value);
      NSDebugLog(@"EGL_SAMPLES %d", value);
    }
}

void
initEGLContext(struct ESContext *escontext)
{
  EGLint     numConfigs;
  EGLint     majorVersion;
  EGLint     minorVersion;
  EGLContext context;
  EGLSurface surface;
  EGLConfig  config;
  EGLint     fbAttribs[] = {EGL_SURFACE_TYPE,
			    EGL_WINDOW_BIT,
			    EGL_RED_SIZE,
			    8,
			    EGL_GREEN_SIZE,
			    8,
			    EGL_BLUE_SIZE,
			    8,
			    EGL_ALPHA_SIZE,
			    8,
			    EGL_RENDERABLE_TYPE,
			    GL_BIT,
			    EGL_NONE};
  EGLint contextAttribs[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE, EGL_NONE};

  EGLDisplay display = eglGetDisplay(escontext->native_display);
  if (display == EGL_NO_DISPLAY)
    {
      NSDebugLog(@"EGLContext: No EGL Display...\n");
    }

  // Initialize EGL
  if (!eglInitialize(display, &majorVersion, &minorVersion))
    {
      NSDebugLog(@"EGLContext: No Initialisation...\n");
    }
  NSDebugLog(@"EGLContext v%d.%d", majorVersion, minorVersion);

  // Get configs
  eglGetConfigs(display, NULL, 0, &numConfigs);
  //    EGLConfig * configs = (EGLConfig*)malloc(sizeof(EGLConfig)*numConfigs);
  //    eglGetConfigs(display, configs, 12, &numConfigs) != EGL_TRUE);
  if ((eglGetConfigs(display, NULL, 0, &numConfigs) != EGL_TRUE)
      || (numConfigs == 0))
    {
      NSDebugLog(@"EGLContext: No configuration...\n");
    }

  // Choose config
  if ((eglChooseConfig(display, fbAttribs, &config, 1, &numConfigs) != EGL_TRUE)
      || (numConfigs != 1))
    {
      EGLint err = eglGetError();

      NSDebugLog(@"EGLContext: configuration problem, number of configs %d",
		 numConfigs);
      NSDebugLog(@"Error: %d", err);
      NSDebugLog(@"Error: EGL_BAD_ATTRIBUTE %d", err == EGL_BAD_ATTRIBUTE);
      NSDebugLog(@"Error: EGL_BAD_DISPLAY %d", err == EGL_BAD_DISPLAY);
      NSDebugLog(@"Error: EGL_NOT_INITIALIZED %d", err == EGL_NOT_INITIALIZED);
      NSDebugLog(@"Error: EGL_BAD_PARAMETER %d", err == EGL_BAD_PARAMETER);
    }

  // Create a GL context
  context = eglCreateContext(display, config, EGL_NO_CONTEXT, contextAttribs);
  if (context == EGL_NO_CONTEXT)
    {
      NSDebugLog(@"EGLContext: No context...\n");
    }

  escontext->display = display;
  escontext->context = context;
  escontext->config = config;
}

void
makeCurrent(struct ESContext *_escontext)
{
  // Make the context current
  if (!eglMakeCurrent(_escontext->display, _escontext->surface,
		      _escontext->surface, _escontext->context))
    {
      NSDebugLog(@"EGLContext: Could not make the current window current !");
      EGLint err = eglGetError();
      NSDebugLog(@"Error: %d", err);
      switch (err)
	{
	case EGL_BAD_MATCH:
	  NSDebugLog(@"Error: EGL_BAD_MATCH");
	  break;
	case EGL_BAD_ACCESS:
	  NSDebugLog(@"Error: EGL_BAD_ACCESS");
	  break;
	case EGL_BAD_SURFACE:
	  NSDebugLog(@"Error: EGL_BAD_SURFACE");
	  break;
	case EGL_BAD_NATIVE_WINDOW:
	  NSDebugLog(@"Error: EGL_BAD_NATIVE_WINDOW");
	  break;
	case EGL_BAD_CURRENT_SURFACE:
	  NSDebugLog(@"Error: EGL_BAD_CURRENT_SURFACE");
	  break;
	case EGL_BAD_ALLOC:
	  NSDebugLog(@"Error: EGL_BAD_ALLOC");
	  break;
	case EGL_CONTEXT_LOST:
	  NSDebugLog(@"Error: EGL_CONTEXT_LOST");
	  break;
	}
    }
}

// creates a cairo surface linked to an egl window
cairo_surface_t *
createCairoEglWindowSurface(struct window *window, struct ESContext *_escontext,
		      cairo_device_t *cairo_device)
{
  if (window->surface == NULL)
    {
      NSDebugLog(@"surface is null");
      return NULL;
    }

  struct wl_egl_window *egl_window
    = wl_egl_window_create(window->surface, window->width, window->height);
  if (egl_window == EGL_NO_SURFACE)
    {
      NSDebugLog(@"egl_window == EGL_NO_SURFACE\n");
    }
  _escontext->window_width = window->width;
  _escontext->window_height = window->height;
  _escontext->native_window = egl_window;

  // Create an egl surface double buffered
  // OpenglES2 supports only DOUBLE BUFFERED surfaces
  // https://www.khronos.org/registry/EGL/specs/EGLTechNote0001.html
  _escontext->surface
    = eglCreateWindowSurface(_escontext->display, _escontext->config,
			     _escontext->native_window, NULL);

  if (_escontext->surface == EGL_NO_SURFACE)
    {
      NSDebugLog(@"EGLContext: No surface...\n");
    }

  makeCurrent(_escontext);

  if (cairo_device_status(cairo_device) != CAIRO_STATUS_SUCCESS)
    {
      NSDebugLog(@"failed to get cairo EGL device");
      NSDebugLog(@"%s",
		 cairo_status_to_string(cairo_device_status(cairo_device)));
    }

  cairo_surface_t *surface
    = cairo_gl_surface_create_for_egl(cairo_device, _escontext->surface,
				      window->width, window->height);

  if (surface == NULL)
    {
      NSDebugLog(@"can't create cairo surface");
    }
  return surface;
}

void blitSurface(cairo_surface_t *source, cairo_surface_t *destination, int width, int height)
{
  cairo_t *cr = cairo_create(destination);
  cairo_surface_set_device_offset(source, 0, 0);
  cairo_rectangle(cr, 0, 0, width, height);
  cairo_clip(cr);
  cairo_set_source_surface(cr, source, 0, 0);
  cairo_paint_with_alpha(cr, 1.0);
  int err;
  if (err = cairo_status(cr) != CAIRO_STATUS_SUCCESS)
    {
      NSDebugLog(@"##### Cairo error after set source %s",
		 cairo_status_to_string(err));
    }
  cairo_destroy(cr);
}

@implementation WaylandCairoEglSurface
{
  struct ESContext _escontext;
  cairo_device_t  *_cairo_device;
  cairo_surface_t *_eglSurface;
  cairo_surface_t *_memSurface;
}
- (id)initWithDevice:(void *)device
{
  gsDevice = device;

  struct window *window = (struct window *) device;

  _escontext.native_display = window->wlconfig->display;
  _escontext.window_width = window->width;
  _escontext.window_height = window->height;
  _escontext.display = NULL;
  _escontext.context = NULL;
  _escontext.surface = NULL;
  _escontext.native_window = 0;

  initEGLContext(&_escontext);

  _cairo_device
    = cairo_egl_device_create(_escontext.display, _escontext.context);

  // from cairo documentation:
  // If your application is not multithreading, add
  // cairo_gl_device_set_thread_aware (device, FALSE) to your code to reduce
  // context switches
  //
  // FIXME setting this to false breaks everything
  // cairo_gl_device_set_thread_aware(_cairo_device, FALSE);

  _memSurface
    = cairo_gl_surface_create(_cairo_device, CAIRO_CONTENT_COLOR_ALPHA,
			      window->width, window->height);
  // the egl window surface is going to be created when we need to display
  // the surface on screen
  _eglSurface = NULL;

  _surface = _memSurface;

  window->wcs = self;

  return self;
}

- (NSSize)size
{
  struct window *window = (struct window *) gsDevice;
  return NSMakeSize(window->width, window->height);
}

- (void)setSize:(NSSize)newSize
{
  struct window *window = (struct window *) gsDevice;
  NSDebugLog(@"[%d] cairo surface set size", window->window_id);
}

- (BOOL)isDrawingToScreen
{
  return _eglSurface != NULL;
}

- (void)handleExposeRect:(NSRect)rect
{
  struct window *window = (struct window *) gsDevice;

  window->buffer_needs_attach = YES;
  NSDebugLog(@"[%d] handleExposeRect", window->window_id);
  if (window->configured)
    {
      // if the window is configured, it's time to display the content on screen
      // we are creating a window surface
      if (_eglSurface == NULL)
        {
          NSDebugLog(@"[%d] createCairoEglWindowSurface", window->window_id);
          _eglSurface = createCairoEglWindowSurface(window, &(self->_escontext),
                            self->_cairo_device);
        }
      // make the context current
      makeCurrent(&(_escontext));
      // blit the mem surface to egl surface
      blitSurface(_memSurface, _eglSurface, window->width, window->height);

      cairo_gl_surface_swapbuffers(_eglSurface);

      // FIXME we should damage only the rectange passed
      wl_surface_damage(window->surface, 0, 0, window->width, window->height);

      window->buffer_needs_attach = NO;

      wl_surface_commit(window->surface);
      wl_display_dispatch_pending(window->wlconfig->display);
      wl_display_flush(window->wlconfig->display);
    }
  else
    {
      if (_eglSurface)
        {
          // if the window is not configured and there is an eglsurface
          // means that the shell role has been destroyed and should not
          // appear on screen
          [self destroySurface];
        }
    }
}
- (void)destroySurface
{
  if (_eglSurface)
    {
      eglDestroySurface(_escontext.display, _escontext.surface);
      wl_egl_window_destroy(_escontext.native_window);
      _escontext.native_window = NULL;
      cairo_surface_destroy(_eglSurface);
      _eglSurface = NULL;
    }
}

- (void)dealloc
{
  [self destroySurface];
  cairo_device_destroy(_cairo_device);

  [super dealloc];
}

@end
