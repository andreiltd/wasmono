#include "validator_cpp.h" // Generated bindings

wit::string exports::wasmono::validator::validate::ValidateText(wit::string text) {
    auto regex_pattern = "^[a-zA-Z0-9\\s]+$"; // alphanumeric validation
    auto result = ::wasmono::regex::matcher::FirstMatch(regex_pattern, text.get_view());

    if (result.empty()) {
        auto *err = "INVALID: Text contains non-alphanumeric characters";
        return wit::string(err, strlen(err));
    } else {
        auto msg = "VALID: " + result.to_string();
        return wit::string(msg.c_str(), msg.size());
    }
}

