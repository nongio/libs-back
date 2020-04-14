/*
   Copyright (C) 2016 Sergio L. Pascual <slp@sinrega.org>
*/

#define _GNU_SOURCE

#include "wayland/WaylandServer.h"
#include "cairo/WaylandCairoSurface.h"
#include <cairo/cairo.h>

#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>

#define GSWINDEVICE ((struct window *)gsDevice)

/* Linux specific version */
static int
os_create_anonymous_file(off_t size)
{
    static const char template[] = "/weston-shared-XXXXXX";
    const char *path;
    char *name;
    int fd;

    path = getenv("XDG_RUNTIME_DIR");
    if (!path) {
	errno = ENOENT;
	return -1;
    }

    name = malloc(strlen(path) + sizeof(template));
    if (!name)
	return -1;

    strcpy(name, path);
    strcat(name, template);

    fd = memfd_create(name, MFD_CLOEXEC);

    free(name);

    if (fd < 0)
	return -1;

    if (ftruncate(fd, size) != 0) {
	close(fd);
	return -1;
    }

    return fd;
}

static cairo_surface_t *
create_shm_buffer(struct window *window)
{
    struct wl_shm_pool *pool;
    cairo_surface_t *surface;
    int fd, size, stride;

    stride = window->width * 4;
    size = stride * window->height;

    NSDebugLog(@"WaylandCairoSurface: creating shm buffer of %d bytes", size);
    fd = os_create_anonymous_file(size);
    if (fd < 0) {
	NSLog(@"creating a buffer file for surface failed");
	return NULL;
    }

    window->data =
	mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (window->data == MAP_FAILED) {
	NSLog(@"error mapping anonymous file");
	close(fd);
	return NULL;
    }

    pool = wl_shm_create_pool(window->wlconfig->shm, fd, size);

    surface = cairo_image_surface_create_for_data(window->data,
						  CAIRO_FORMAT_ARGB32,
						  window->width,
						  window->height,
						  stride);

    window->buffer =
	wl_shm_pool_create_buffer(pool, 0,
				  window->width, window->height, stride,
				  WL_SHM_FORMAT_ARGB8888);
    wl_shm_pool_destroy(pool);

    close(fd);

    return surface;
}

@implementation WaylandCairoSurface

- (id) initWithDevice: (void*)device
{
    struct window *window = (struct window *) device;
    NSDebugLog(@"WaylandCairoSurface: initWithDevice win=%d", window->window_id);

    gsDevice = device;

    _surface = create_shm_buffer(window);
    if (_surface == NULL) {
	NSDebugLog(@"can't create cairo surface");
	return 0;
    }

    wl_surface_attach(window->surface, window->buffer, 0, 0);
    window->wcs = self;

    return self;
}

- (void) dealloc
{
    struct window *window = (struct window*) gsDevice;
    NSDebugLog(@"WaylandCairoSurface: dealloc win=%d", window->window_id);

    // FIXME: This is leaking memory. We need to implement counterpart to
    // create_shm_buffer.

    [super dealloc];
}

- (NSSize) size
{
    NSDebugLog(@"WaylandCairoSurface: size");
    struct window *window = (struct window*) gsDevice;
    return NSMakeSize(window->width, window->height);
}

- (void) setSurface: (cairo_surface_t*)surface
{
    NSDebugLog(@"WaylandCairoSurface: setSurface");
    _surface = surface;
}

- (void) handleExposeRect: (NSRect)rect
{
    NSDebugLog(@"handleExposeRect");
    struct window *window = (struct window*) gsDevice;
    cairo_surface_t *cairo_surface = _surface;
    double  backupOffsetX = 0;
    double  backupOffsetY = 0;
    int x = NSMinX(rect);
    int y = NSMinY(rect);
    int width = NSWidth(rect);
    int height = NSHeight(rect);

    NSDebugLog(@"updating region: %dx%d %dx%d", x, y, width, height);

    if (cairo_surface_status(cairo_surface) != CAIRO_STATUS_SUCCESS)
    {
	NSWarnMLog(@"cairo initial window error status: %s\n",
		   cairo_status_to_string(cairo_surface_status(_surface)));
    }

    cairo_surface_get_device_offset(cairo_surface, &backupOffsetX, &backupOffsetY);
    cairo_surface_set_device_offset(cairo_surface, 0, 0);

    cairo_t *cr = cairo_create(cairo_surface);
    if (width != window->width && 0) {
        // FIXME: remove this dead fake-drawing branch.
	NSDebugLog(@"fake drawing");
	cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE);

	cairo_rectangle(cr, 0, 0, width, height);
	cairo_set_source_rgba(cr, 0, 0, 0, 0.8);
	cairo_fill(cr);

	cairo_rectangle(cr, 10, 10, width - 20, height - 20);
	cairo_set_source_rgba(cr, 1.0, 0, 0, 1);
	cairo_fill(cr);

	cairo_select_font_face(cr, "sans",
			       CAIRO_FONT_SLANT_NORMAL,
			       CAIRO_FONT_WEIGHT_NORMAL);
	cairo_set_font_size(cr, 12);
	cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 1.0);
	cairo_move_to(cr, 30, 30);
	cairo_show_text(cr, "Hello, world!");
    } else {
	NSDebugLog(@"real drawing");

	cairo_rectangle(cr, x, y, width, height);
	cairo_clip(cr);
	cairo_set_source_surface(cr, cairo_surface, 0, 0);
	cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE);
	cairo_paint(cr);
    }

    cairo_destroy(cr);

    wl_surface_commit(window->surface);
    wl_display_dispatch_pending(window->wlconfig->display);
    wl_display_flush(window->wlconfig->display);

    cairo_surface_set_device_offset(_surface, backupOffsetX, backupOffsetY);

    NSDebugLog(@"handleExposeRect exit");
}

@end
