#include "user.h"

void main(int argc, char *argv[]) {
  *((volatile int *)0x80200000) = 0x1234;
  for (;;)
    ;
}
