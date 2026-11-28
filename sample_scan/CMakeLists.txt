cmake_minimum_required(VERSION 3.15)
project(adtf_sample_scan LANGUAGES CXX)

find_package(adtf_file CONFIG REQUIRED)
add_executable(adtf_sample_scan sample_scan.cpp)
target_compile_features(adtf_sample_scan PRIVATE cxx_std_17)
target_link_libraries(adtf_sample_scan PRIVATE adtf_file)