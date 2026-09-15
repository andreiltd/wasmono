#include <cstdio>
#include <string>

extern "C" {
int registered = 0;
}

int main() {
    const std::string message = "whole archive constructor";
    std::printf("%s: %d\n", message.c_str(), registered);
    return registered == 42 ? 0 : 1;
}
