# Standalone script: cmake -D MODEL_DIR=path -P download_model.cmake
# Downloads and extracts SenseVoice ASR model if not present.

cmake_minimum_required(VERSION 3.13)

if(EXISTS "${MODEL_DIR}/model.int8.onnx" AND EXISTS "${MODEL_DIR}/tokens.txt")
  message(STATUS "ASR model already exists, skipping download")
  return()
endif()

set(MODEL_URL "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17.tar.bz2")
get_filename_component(PARENT "${MODEL_DIR}" DIRECTORY)
set(ARCHIVE "${PARENT}/sense-voice-model.tar.bz2")
set(EXTRACT "${PARENT}/_cmake_extract_tmp")

message(STATUS "Downloading ASR model (~200MB)...")
file(DOWNLOAD "${MODEL_URL}" "${ARCHIVE}" SHOW_PROGRESS)

message(STATUS "Extracting...")
file(MAKE_DIRECTORY "${EXTRACT}")
execute_process(COMMAND tar xf "${ARCHIVE}" -C "${EXTRACT}"
                RESULT_VARIABLE TAR_RESULT)
if(NOT TAR_RESULT EQUAL 0)
  file(REMOVE_RECURSE "${EXTRACT}" "${ARCHIVE}")
  message(FATAL_ERROR "Extraction failed (tar exited ${TAR_RESULT})")
endif()

file(GLOB_RECURSE MODEL_ENTRY "${EXTRACT}/model.int8.onnx")
if(NOT MODEL_ENTRY)
  file(REMOVE_RECURSE "${EXTRACT}" "${ARCHIVE}")
  message(FATAL_ERROR "model.int8.onnx not found in archive")
endif()

get_filename_component(SRC "${MODEL_ENTRY}" DIRECTORY)
file(COPY "${SRC}/model.int8.onnx" "${SRC}/tokens.txt" DESTINATION "${MODEL_DIR}")

file(REMOVE_RECURSE "${EXTRACT}" "${ARCHIVE}")
message(STATUS "ASR model ready at ${MODEL_DIR}")
