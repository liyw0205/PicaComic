cmake_minimum_required(VERSION 3.22)

project(pica_curl LANGUAGES C)

set(CMAKE_SKIP_RPATH TRUE)

add_library(pica_curl SHARED pica_curl.c)
target_link_libraries(pica_curl android log)

if(ANDROID_ABI STREQUAL "arm64-v8a")
    set(CURL_LIB "${CMAKE_CURRENT_SOURCE_DIR}/../jniLibs/${ANDROID_ABI}/libcurl.so")
    if(EXISTS "${CURL_LIB}")
        add_library(curl SHARED IMPORTED)
        set_target_properties(curl PROPERTIES IMPORTED_LOCATION "${CURL_LIB}")
        target_compile_definitions(pica_curl PRIVATE PICA_USE_LIBCURL=1)
        target_include_directories(pica_curl PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/include")
        target_link_libraries(pica_curl curl)
    endif()
endif()
