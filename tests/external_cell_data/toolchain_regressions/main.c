#include <stdio.h>

int registered = 0;

int main(void) {
    printf("whole archive constructor: %d\n", registered);
    return registered == 42 ? 0 : 1;
}
