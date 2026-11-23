# Robz Play frame generation module.
#
# robzfg       static library: RIFE interpolation (ncnn / Vulkan) + repeated-frame detection
# robzfg-lab   command line tool to measure speed and quality on video files

cmake_minimum_required(VERSION 3.16)

if(NOT DEFINED PROJECT_NAME)
	project(robzfg LANGUAGES C CXX)
endif()

if(APPLE)
	enable_language(OBJCXX)
endif()

option(ROBZFG_BUILD_LAB "Build the robzfg-lab measurement tool" ON)

set(ROBZFG_NCNN_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../_deps/ncnn-install" CACHE PATH "ncnn install prefix (built with NCNN_VULKAN=ON)")
find_package(ncnn REQUIRED PATHS "${ROBZFG_NCNN_ROOT}/lib/cmake/ncnn" NO_DEFAULT_PATH)

# Embed each compute shader as a C++ raw string literal.
set(ROBZFG_SHADER_DIR "${CMAKE_CURRENT_BINARY_DIR}/shaders")
file(MAKE_DIRECTORY "${ROBZFG_SHADER_DIR}")
function(robzfg_embed_shader name)
	set(src "${CMAKE_CURRENT_SOURCE_DIR}/src/shaders/${name}.comp")
	file(READ "${src}" content)
	file(WRITE "${ROBZFG_SHADER_DIR}/${name}.comp.h"
		"// generated from src/shaders/${name}.comp - do not edit\nstatic const char ${name}_comp_data[] = R\"ROBZFG(${content})ROBZFG\";\n")
	set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${src}")
endfunction()
robzfg_embed_shader(warp)
robzfg_embed_shader(warp_pack4)
robzfg_embed_shader(rife_v4_timestep)
robzfg_embed_shader(robzfg_nv12_to_net)
robzfg_embed_shader(robzfg_synthesize)

add_library(robzfg STATIC
	src/dedup.cpp
	src/rife_interpolator.cpp
	src/warp_layer.cpp)
if(APPLE)
	target_sources(robzfg PRIVATE
		src/rife_metal.h
		src/rife_metal.mm)
	set_source_files_properties(src/rife_metal.mm PROPERTIES COMPILE_FLAGS "-fobjc-arc")
endif()
target_compile_features(robzfg PUBLIC cxx_std_17)
target_include_directories(robzfg
	PUBLIC include
	PRIVATE src "${ROBZFG_SHADER_DIR}")
target_link_libraries(robzfg PUBLIC ncnn)
if(APPLE)
	target_link_libraries(robzfg PUBLIC
		"-framework Foundation"
		"-framework Metal"
		"-framework MetalPerformanceShaders"
		"-framework MetalPerformanceShadersGraph")
endif()

if(ROBZFG_BUILD_LAB)
	find_package(PkgConfig REQUIRED)
	pkg_check_modules(ROBZFG_FFMPEG REQUIRED IMPORTED_TARGET libavformat libavcodec libavutil)
	add_executable(robzfg-lab tools/lab_main.cpp)
	target_link_libraries(robzfg-lab PRIVATE robzfg PkgConfig::ROBZFG_FFMPEG)
endif()
