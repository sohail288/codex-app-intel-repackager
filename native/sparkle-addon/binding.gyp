{
  "targets": [
    {
      "target_name": "sparkle",
      "sources": [
        "sparkle.mm"
      ],
      "defines": [
        "BUILDING_SPARKLE_SOURCES_EXTERNALLY=1"
      ],
      "include_dirs": [
        "<!(printf '%s/Sparkle.framework/Headers' \"$SPARKLE_FRAMEWORK_DIR\")"
      ],
      "cflags": [
        "-fobjc-arc",
        "-F<!(printf '%s' \"$SPARKLE_FRAMEWORK_DIR\")"
      ],
      "cflags_cc": [
        "-std=c++20",
        "-fobjc-arc",
        "-F<!(printf '%s' \"$SPARKLE_FRAMEWORK_DIR\")"
      ],
      "ldflags": [
        "-F<!(printf '%s' \"$SPARKLE_FRAMEWORK_DIR\")",
        "-Wl,-rpath,@loader_path/../../Frameworks",
        "-Wl,-rpath,@loader_path/../../../Frameworks"
      ],
      "libraries": [
        "-framework Cocoa",
        "-framework Sparkle"
      ],
      "xcode_settings": {
        "CLANG_CXX_LANGUAGE_STANDARD": "c++20",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "GCC_ENABLE_CPP_EXCEPTIONS": "YES",
        "LD_RUNPATH_SEARCH_PATHS": [
          "@loader_path/../../Frameworks",
          "@loader_path/../../../Frameworks"
        ],
        "OTHER_CFLAGS": [
          "-F<!(printf '%s' \"$SPARKLE_FRAMEWORK_DIR\")"
        ],
        "OTHER_CPLUSPLUSFLAGS": [
          "-std=c++20",
          "-F<!(printf '%s' \"$SPARKLE_FRAMEWORK_DIR\")"
        ],
        "OTHER_LDFLAGS": [
          "-F<!(printf '%s' \"$SPARKLE_FRAMEWORK_DIR\")",
          "-framework",
          "Cocoa",
          "-framework",
          "Sparkle"
        ]
      }
    }
  ]
}
