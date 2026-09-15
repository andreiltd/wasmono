def third_party_rust_cxx_library(name, **kwargs):
    # @lint-ignore BUCKLINT
    native.cxx_library(name = name, **kwargs)

def third_party_rust_prebuilt_cxx_library(name, **kwargs):
    # @lint-ignore BUCKLINT
    native.prebuilt_cxx_library(name = name, **kwargs)

# A single generated import stays used when only one C++ rule kind is needed.
third_party_rust = struct(
    cxx_library = third_party_rust_cxx_library,
    prebuilt_cxx_library = third_party_rust_prebuilt_cxx_library,
)
