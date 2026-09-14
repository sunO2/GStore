# 最小 CONFIG 包：ggml-vulkan 只要求 find_package(SPIRV-Headers CONFIG) 成功
# （实际头文件搜索路径由 llama-cpp-sys-2 通过 SPIRV_HEADERS_INCLUDE_DIR 注入 -I）。
set(SPIRV-Headers_FOUND TRUE)
set(SPIRV-Headers_VERSION "1.3.275")
if(NOT TARGET SPIRV-Headers::SPIRV-Headers)
  add_library(SPIRV-Headers::SPIRV-Headers INTERFACE IMPORTED)
  set_target_properties(SPIRV-Headers::SPIRV-Headers PROPERTIES
    INTERFACE_INCLUDE_DIRECTORIES "${CMAKE_CURRENT_LIST_DIR}/include")
endif()
