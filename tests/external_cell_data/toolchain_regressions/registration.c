extern int registered;

__attribute__((constructor))
static void register_archive(void) {
    registered = 42;
}
