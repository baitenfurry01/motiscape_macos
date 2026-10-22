set(CMAKE_POLICY_DEFAULT_CMP0077 NEW)

# Runtime dependency sources are vendored locally; configuration does not fetch.
set(ENABLE_HLSL ON CACHE INTERNAL "")
set(ENABLE_OPT OFF CACHE INTERNAL "")
set(GLSLANG_ENABLE_INSTALL OFF CACHE INTERNAL "")
set(BUILD_SHARED_LIBS OFF CACHE BOOL "Build shared dependency libraries")

add_subdirectory(rstd)
add_subdirectory(wavsen)
add_subdirectory(spirv_reflect)
add_subdirectory(glslang)
add_subdirectory(quickjs)

# Eigen is header-only; expose its core headers without its standalone project.
add_library(eigen INTERFACE)
add_library(Eigen3::Eigen ALIAS eigen)
target_include_directories(eigen SYSTEM INTERFACE ${CMAKE_CURRENT_SOURCE_DIR}/eigen)
