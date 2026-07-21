cmake_minimum_required(VERSION 3.25)
project(PetRunnerNative VERSION 0.2.2 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")

find_package(nlohmann_json CONFIG REQUIRED)
find_path(LIBWEBP_INCLUDE_DIR NAMES webp/decode.h REQUIRED)
find_library(LIBWEBP_LIBRARY NAMES webp REQUIRED)

add_library(petrunner_core src/core.cpp)
target_include_directories(petrunner_core PUBLIC include PRIVATE ${LIBWEBP_INCLUDE_DIR})
target_link_libraries(petrunner_core PUBLIC nlohmann_json::nlohmann_json ${LIBWEBP_LIBRARY})
target_compile_definitions(petrunner_core PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX)

add_executable(PetRunner WIN32 src/main.cpp)
target_link_libraries(PetRunner PRIVATE petrunner_core d2d1 windowscodecs comctl32 shell32 user32 gdi32)
target_compile_definitions(PetRunner PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX UNICODE _UNICODE)

include(CTest)
if(BUILD_TESTING)
  add_executable(petrunner_tests tests/core_tests.cpp)
  target_link_libraries(petrunner_tests PRIVATE petrunner_core)
  add_test(NAME petrunner_tests COMMAND petrunner_tests)
endif()
