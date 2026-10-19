// A uinput touchscreen. Reads "tap x y" lines on stdin (display pixels), "quit" ends.
#include <fcntl.h>
#include <linux/uinput.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <stdlib.h>

static int fd;
static void emit(int type, int code, int val) {
  struct input_event ie = {0};
  ie.type = type; ie.code = code; ie.value = val;
  if (write(fd, &ie, sizeof(ie)) < 0) perror("write");
}

int main(int argc, char **argv) {
  int w = 1280, h = 800;
  if (argc > 2) { w = atoi(argv[1]); h = atoi(argv[2]); }
  fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
  if (fd < 0) { perror("uinput"); return 1; }
  ioctl(fd, UI_SET_EVBIT, EV_KEY); ioctl(fd, UI_SET_KEYBIT, BTN_TOUCH);
  ioctl(fd, UI_SET_EVBIT, EV_ABS);
  ioctl(fd, UI_SET_ABSBIT, ABS_X); ioctl(fd, UI_SET_ABSBIT, ABS_Y);
  ioctl(fd, UI_SET_ABSBIT, ABS_MT_SLOT); ioctl(fd, UI_SET_ABSBIT, ABS_MT_TRACKING_ID);
  ioctl(fd, UI_SET_ABSBIT, ABS_MT_POSITION_X); ioctl(fd, UI_SET_ABSBIT, ABS_MT_POSITION_Y);
  ioctl(fd, UI_SET_PROPBIT, INPUT_PROP_DIRECT);
  struct uinput_abs_setup abs = {0};
  int codes[] = {ABS_X, ABS_Y, ABS_MT_POSITION_X, ABS_MT_POSITION_Y};
  for (int i = 0; i < 4; i++) {
    memset(&abs, 0, sizeof(abs)); abs.code = codes[i];
    abs.absinfo.maximum = (i % 2 == 0) ? w - 1 : h - 1; abs.absinfo.resolution = 10;
    ioctl(fd, UI_ABS_SETUP, &abs);
  }
  memset(&abs, 0, sizeof(abs)); abs.code = ABS_MT_SLOT; abs.absinfo.maximum = 4; ioctl(fd, UI_ABS_SETUP, &abs);
  memset(&abs, 0, sizeof(abs)); abs.code = ABS_MT_TRACKING_ID; abs.absinfo.maximum = 65535; ioctl(fd, UI_ABS_SETUP, &abs);
  struct uinput_setup us = {0};
  us.id.bustype = BUS_VIRTUAL; us.id.vendor = 0x1234; us.id.product = 0x5678;
  strcpy(us.name, "home-test-touch");
  ioctl(fd, UI_DEV_SETUP, &us); ioctl(fd, UI_DEV_CREATE);
  printf("ready\n"); fflush(stdout);
  char line[128]; int id = 1;
  while (fgets(line, sizeof line, stdin)) {
    int x, y;
    if (sscanf(line, "tap %d %d", &x, &y) == 2) {
      emit(EV_ABS, ABS_MT_SLOT, 0); emit(EV_ABS, ABS_MT_TRACKING_ID, id++);
      emit(EV_ABS, ABS_MT_POSITION_X, x); emit(EV_ABS, ABS_MT_POSITION_Y, y);
      emit(EV_ABS, ABS_X, x); emit(EV_ABS, ABS_Y, y);
      emit(EV_KEY, BTN_TOUCH, 1); emit(EV_SYN, SYN_REPORT, 0);
      usleep(50000);
      emit(EV_ABS, ABS_MT_TRACKING_ID, -1); emit(EV_KEY, BTN_TOUCH, 0); emit(EV_SYN, SYN_REPORT, 0);
      printf("tapped %d %d\n", x, y); fflush(stdout);
    } else if (!strncmp(line, "quit", 4)) break;
  }
  ioctl(fd, UI_DEV_DESTROY); close(fd);
  return 0;
}
