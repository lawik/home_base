// Read pixels from what the CRTC is scanning out right now (kernel side, not emerge).
// usage: drmgrab /dev/dri/card0 x y [x y ...]  -> prints "fb=<id> WxH" and "x,y=RRGGBB"
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <drm/drm.h>
#include <drm/drm_mode.h>

int main(int argc, char **argv) {
  int fd = open(argv[1], O_RDWR | O_CLOEXEC);
  if (fd < 0) { perror("open"); return 1; }
  struct drm_mode_card_res res = {0};
  if (ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &res)) { perror("res"); return 1; }
  unsigned int crtcs[16];
  res.crtc_id_ptr = (unsigned long)crtcs;
  res.count_fbs = res.count_connectors = res.count_encoders = 0;
  if (ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &res)) { perror("res2"); return 1; }
  struct drm_mode_crtc crtc = {.crtc_id = crtcs[0]};
  if (ioctl(fd, DRM_IOCTL_MODE_GETCRTC, &crtc)) { perror("crtc"); return 1; }
  struct drm_mode_fb_cmd2 fb = {.fb_id = crtc.fb_id};
  if (ioctl(fd, DRM_IOCTL_MODE_GETFB2, &fb)) { perror("getfb2"); return 1; }
  printf("fb=%u %ux%u pitch=%u format=%.4s handle=%u\n", fb.fb_id, fb.width, fb.height,
         fb.pitches[0], (char *)&fb.pixel_format, fb.handles[0]);
  if (!fb.handles[0]) { fprintf(stderr, "no handle (not master/admin)\n"); return 1; }
  struct drm_mode_map_dumb map = {.handle = fb.handles[0]};
  if (ioctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &map)) { perror("map_dumb"); return 1; }
  size_t size = (size_t)fb.pitches[0] * fb.height;
  unsigned char *p = mmap(0, size, PROT_READ, MAP_SHARED, fd, map.offset);
  if (p == MAP_FAILED) { perror("mmap"); return 1; }
  for (int i = 2; i + 1 < argc; i += 2) {
    int x = atoi(argv[i]), y = atoi(argv[i + 1]);
    unsigned char *px = p + (size_t)y * fb.pitches[0] + (size_t)x * 4;  // XR24: B G R X
    printf("%d,%d=%02x%02x%02x\n", x, y, px[2], px[1], px[0]);
  }
  return 0;
}
