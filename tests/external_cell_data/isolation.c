#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    if (argc != 3 || strcmp(argv[1], "--dir") || strcmp(argv[2], "fixtures")) {
        fprintf(stderr, "guest arguments were changed\n");
        return 1;
    }

    FILE *input = fopen("fixtures/data.txt", "r");
    if (!input) {
        perror("fixtures/data.txt");
        return 2;
    }
    char data[32];
    // WASI libc does not perform Windows text-mode newline conversion.
    int matches = fgets(data, sizeof(data), input) &&
                  (!strcmp(data, "isolated fixture\n") ||
                   !strcmp(data, "isolated fixture\r\n"));
    fclose(input);

    if (!matches) {
        fprintf(stderr, "unexpected isolated fixture contents\n");
        return 3;
    }

    return 0;
}
