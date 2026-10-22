cmake_minimum_required(VERSION 3.16)
project(spirv-reflect LANGUAGES C CXX)

option(SPIRV_REFLECT_ENABLE_ASAN "Use address sanitization" OFF)
if(SPIRV_REFLECT_ENABLE_ASAN)
    add_compile_options(-fsanitize=address -fno-omit-frame-pointer)
    add_link_options(-fsanitize=address)
endif()

add_library(spirv-reflect-static STATIC spirv_reflect.h spirv_reflect.c)
target_include_directories(spirv-reflect-static PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
set_target_properties(spirv-reflect-static PROPERTIES PUBLIC_HEADER "${CMAKE_CURRENT_SOURCE_DIR}/spirv_reflect.h")
